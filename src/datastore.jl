# SPDX-License-Identifier: LGPL-3.0-or-later

# The data stores on this machine checked against the local registry: the
# registered files that are gone or altered, and the files there that are not
# registered.

# A registered file as a check reports it: where it should be, its storage
# location's URL and the SHA-1 the registry holds
const _StoredFile = @NamedTuple{path::String, location::String, hash::String}

"""
    StoreCheck

What [`check_store`](@ref) found in the data stores on this machine, shown as
a report.

# Fields
- `roots`: each data store checked, as `(root, folder, exists, locations)`:
  its storage root, the folder that is, whether the folder exists, and how
  many storage locations the registry holds under it
- `missing`: each registered file that is not there, as `(path, location,
  hash)`: where it should be, the URL of its storage location and the SHA-1
  registered
- `changed`: each registered file whose contents are not those registered,
  as `(path, location, hash, found, links)`: also its SHA-1 now and how many
  names it has, more than one where it is hard-linked; empty when the check
  was made with `hashes = false`
- `unknown`: each file in a data store that the registry has no storage
  location for, other than those in `unfinished` and `cli_files`
- `unused`: each storage location that nothing uses - no object, and no
  source as where it was fetched from - as `(path, location, hash)`; its file
  is not checked further
- `unfinished`: each output that a run left under its temporary name,
  `dat-...`, as `(path, modified)`, its modification time in UTC; a run in
  progress has them too
- `cli_files`: each file under a store's `jobs/` folder that is not
  registered, which the CLI keeps there, such as a run's `coderuns.txt`
- `hashes`: whether the registered files were hashed, so that `changed` was
  checked
- `quiet`: whether the report leaves out the CLI's files and summarises the
  missing files rather than listing each
"""
struct StoreCheck
    roots::Vector{@NamedTuple{root::String, folder::String, exists::Bool,
                              locations::Int}}
    missing::Vector{_StoredFile}
    changed::Vector{@NamedTuple{path::String, location::String, hash::String,
                                found::String, links::Int}}
    unknown::Vector{String}
    unused::Vector{_StoredFile}
    unfinished::Vector{@NamedTuple{path::String, modified::DateTime}}
    cli_files::Vector{String}
    hashes::Bool
    quiet::Bool
end

# How many missing files a quiet report lists for a store whose folder exists
const QUIET_MISSING = 5

function Base.show(io::IO, check::StoreCheck)
    return print(io, "StoreCheck(", _counted(length(check.roots), "data store"),
                 ": ", _storesummary(check), ")")
end

function Base.show(io::IO, ::MIME"text/plain", check::StoreCheck)
    lines = ["Check of $(_counted(length(check.roots), "data store")): $(_storesummary(check))"]
    folders = unique(_folderkey(root.folder) for root in check.roots)
    instore(found, folder) = filter(file -> _storeof(_findingpath(file),
                                                     folders) == folder, found)
    for folder in folders
        held = filter(root -> _folderkey(root.folder) == folder, check.roots)
        gone = _bypath(instore(check.missing, folder))
        if !first(held).exists
            push!(lines,
                  "  $folder: the folder is gone, and with it $(_counted(length(gone), "registered file"))")
            check.quiet && continue
        else
            locations = sum(root.locations for root in held)
            push!(lines,
                  "  $folder ($(_counted(locations, "storage location")))")
        end
        shown = check.quiet ? first(gone, QUIET_MISSING) : gone
        for (path, files) in shown
            push!(lines,
                  "    missing: $(relpath(path, folder))$(_shared(files))")
        end
        length(gone) > length(shown) &&
            push!(lines,
                  "    missing: $(length(gone) - length(shown)) more, listed with quiet = false")
        for (path, files) in _bypath(instore(check.changed, folder))
            summarised = check.quiet && length(files) > 1
            for file in (summarised ? first(files, 1) : files)
                registered = summarised ?
                             "registered with $(length(files)) other contents, listed with quiet = false" :
                             "registered $(first(file.hash, 8))"
                line = "    changed: $(relpath(path, folder)) - sha1 $(first(file.found, 8)), $registered"
                file.links > 1 &&
                    (line *= "; it has $(file.links) hard links, so may have been written to through another")
                push!(lines, line)
            end
        end
        for path in instore(check.unknown, folder)
            push!(lines, "    unknown: $(relpath(path, folder))")
        end
        for (path, files) in _bypath(instore(check.unused, folder))
            push!(lines,
                  "    unused: $(relpath(path, folder))$(_shared(files))")
        end
        for file in instore(check.unfinished, folder)
            push!(lines,
                  "    unfinished: $(relpath(file.path, folder)), modified $(Dates.format(file.modified, "yyyy-mm-dd HH:MM")) UTC")
        end
        cli = instore(check.cli_files, folder)
        if check.quiet
            isempty(cli) ||
                push!(lines,
                      "    and $(_counted(length(cli), "file")) of the CLI's own under jobs/, listed with quiet = false")
        else
            for path in cli
                push!(lines, "    the CLI's: $(relpath(path, folder))")
            end
        end
    end
    return join(io, lines, "\n")
end

# The path of a finding, which is a path or holds one
_findingpath(path::AbstractString) = path
_findingpath(file::NamedTuple) = file.path

# The findings grouped by path, each path once, in the order first found: a
# path registered, rewritten and registered again has several locations
function _bypath(found::AbstractVector)
    groups = Dict{String, Vector{eltype(found)}}()
    paths = String[]
    for file in found
        group = get!(groups, file.path) do
            push!(paths, file.path)
            return eltype(found)[]
        end
        push!(group, file)
    end
    return [(path, groups[path]) for path in paths]
end

# What a report adds to a path that several findings share: how many
function _shared(files)
    return length(files) > 1 ? " ($(length(files)) storage locations)" : ""
end

# What a store check found, in a few words: how many of each finding, or that
# everything is as registered, and whether the contents were checked
function _storesummary(check::StoreCheck)
    isempty(check.roots) && return "no data store is registered"
    counts = String[]
    for (found, word) in ((check.missing, "missing"), (check.changed, "changed"),
        (check.unknown, "unknown"), (check.unused, "unused"),
        (check.unfinished, "unfinished"))
        isempty(found) || push!(counts, "$(length(found)) $word")
    end
    summary = isempty(counts) ? "all as registered" : join(counts, ", ")
    return check.hashes ? summary : summary * ", contents not checked"
end

# The folder of the data store a path is in, of `folders` as `_folderkey`
# gives them: the longest that holds it, since one store's folder may lie
# inside another's
function _storeof(path::AbstractString, folders)
    holding = filter(folder -> startswith(normpath(path), folder), folders)
    return isempty(holding) ? nothing : argmax(length, holding)
end

"""
    check_store(; hashes = true, quiet = true)
    check_store(registry; hashes = true, quiet = true)
    check_store(handle; hashes = true, quiet = true)

Check the data stores on this machine against the local registry, and return
a [`StoreCheck`](@ref), shown as a report. A data store is a storage root
that is a folder on this machine - a `file://` root marked local, as `fair`
and the APIs register each project's - and every one is checked. Found are
the registered files that are missing, or whose contents are not those
registered; the files in a store that the registry does not know; the
storage locations that nothing uses; and the outputs that a run left under
their temporary names, `dat-...`, as one that fails before `finalise` does.
The check changes nothing: it deletes, moves, fetches and registers nothing.

A file put in a data store by [`link_write!`](@ref), [`link_register!`](@ref)
or [`link_read!`](@ref) with a `path` is a hard link where one could be made,
so writing to the file at that path changes the registered one; the report
says how many names a changed file has.

# Arguments
- `registry`: the registry whose data stores are checked, a
  [`RegistryEndpoint`](@ref), which needs no token; a `DataRegistryHandle`
  may be given instead, and its registry is used. With neither, the CLI's
  local registry, held through a session of the CLI's while the check runs.
- `hashes`: whether to hash each registered file, which reads every byte, to
  find those whose contents have changed; with `false`, only whether each is
  there is checked.
- `quiet`: whether the report leaves out the CLI's own files under `jobs/` -
  each run's `coderuns.txt`, the working config of a job no run registered -
  and summarises the missing files rather than listing each, giving a store
  whose folder has gone in one line. The check holds every finding either
  way.
"""
function check_store(registry::RegistryEndpoint; hashes::Bool = true,
                     quiet::Bool = true)
    roots = filter(root -> root["local"] && startswith(root["root"], "file://"),
                   _getentries(registry, "storage_root", Dict()))
    # What uses a location: an object, or a source as where it was fetched
    # from; a code repository's location is a commit, not a file
    used = Set{String}()
    repositories = Set{String}()
    for object in _getentries(registry, "object", Dict())
        location = object["storage_location"]
        isnothing(location) && continue
        push!(used, location)
        object["description"] == REPOSITORY_DESCRIPTION &&
            push!(repositories, location)
    end
    for external in _getentries(registry, "external_object", Dict())
        isnothing(external["original_store"]) ||
            push!(used, external["original_store"])
    end

    stores = @NamedTuple{root::String, folder::String, exists::Bool,
                         locations::Int}[]
    gone = _StoredFile[]
    changed = @NamedTuple{path::String, location::String, hash::String,
                          found::String, links::Int}[]
    unused = _StoredFile[]
    # The paths registered in each store's folder, as a walk of it gives them,
    # and the folders in it that are repositories rather than files
    registered = Dict{String, Set{String}}()
    pruned = Dict{String, Set{String}}()
    for root in roots
        folder = _rootfolder(root["root"])
        locations = _getentries(registry, "storage_location",
                                Dict("storage_root" => root["url"]))
        push!(stores,
              (root = root["root"], folder = folder, exists = isdir(folder),
               locations = length(locations)))
        known = get!(registered, _folderkey(folder)) do
            return Set{String}()
        end
        skipped = get!(pruned, _folderkey(folder)) do
            return Set{String}()
        end
        for location in locations
            path = normpath(joinpath(folder, location["path"]))
            if location["url"] in repositories
                push!(skipped, _folderkey(path))
                continue
            end
            push!(known, _storekey(location["path"]))
            file = (path = path, location = String(location["url"]),
                    hash = String(location["hash"]))
            if !(location["url"] in used)
                push!(unused, file)
            elseif !isfile(path)
                push!(gone, file)
            elseif hashes
                found = _getfilehash(path)
                found == file.hash ||
                    push!(changed,
                          (; file..., found, links = Int(stat(path).nlink)))
            end
        end
    end

    unknown = String[]
    unfinished = @NamedTuple{path::String, modified::DateTime}[]
    cli_files = String[]
    walked = Set{String}()
    for store in stores
        key = _folderkey(store.folder)
        (store.exists && !(key in walked)) || continue
        push!(walked, key)
        # A store's folder inside this one is walked as a store of its own
        inner = Set(_folderkey(other.folder) for other in stores)
        delete!(inner, key)
        for path in _storefiles(key, union(inner, pruned[key]))
            relative = _storekey(relpath(path, key))
            relative in registered[key] && continue
            if startswith(basename(path), "dat-")
                push!(unfinished,
                      (path = path,
                       modified = Dates.unix2datetime(mtime(path))))
            elseif startswith(relative, "jobs/")
                push!(cli_files, path)
            else
                push!(unknown, path)
            end
        end
    end
    bypath(found) = sort!(found, by = file -> file.path)
    return StoreCheck(stores, bypath(gone), bypath(changed), sort!(unknown),
                      bypath(unused), bypath(unfinished), sort!(cli_files),
                      hashes, quiet)
end
function check_store(handle::DataRegistryHandle; hashes::Bool = true,
                     quiet::Bool = true)
    return check_store(handle.registry; hashes, quiet)
end
function check_store(; hashes::Bool = true, quiet::Bool = true)
    return registry_session() do registry
        return check_store(registry; hashes, quiet)
    end
end

# The folder a `file://` storage root is
_rootfolder(root::AbstractString) = replace(root, "file://" => "")

# A folder as the check compares folders: normalised, ending in a separator
_folderkey(folder::AbstractString) = normpath(joinpath(folder, ""))

# A path within a store as the check compares it with a storage location's,
# which may have been registered on Windows with either separator
function _storekey(path::AbstractString)
    return Sys.iswindows() ? replace(path, '\\' => '/') : String(path)
end

# Every file under a folder, a symbolic link being one whatever it points to,
# but for the folders in `pruned`, as `_folderkey` gives them
function _storefiles(folder::AbstractString, pruned::Set{String})
    files = String[]
    for path in readdir(folder, join = true)
        if !islink(path) && isdir(path)
            _folderkey(path) in pruned ||
                append!(files, _storefiles(path, pruned))
        else
            push!(files, path)
        end
    end
    return files
end
