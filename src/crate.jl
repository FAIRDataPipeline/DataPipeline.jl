# SPDX-License-Identifier: LGPL-3.0-or-later

# The RO-Crate the registry builds for data products, fetched for the files of
# a paper: its metadata, or the zip that packs the files with it.

"""
    crate(paths...; remote = nothing, depth = 100, level = nothing,
          pack = nothing, to = nothing, strict = true)
    crate(registry, paths...; depth = 100, level = nothing, pack = nothing,
          to = nothing, strict = true)
    crate(handle, paths...; depth = 100, level = nothing, pack = nothing,
          to = nothing, strict = true)

Fetch the RO-Crate the registry builds for data products: a package of their
files with the provenance of each, as a crate's metadata describes it, in
which every run with its code at its commit, everything it read, each data
product with its source and its issues travel together.

Each of `paths` is a file, a folder, or a data product named
`namespace:name@version` (`namespace:name` for its newest version). A file is
identified by its contents, as [`identify`](@ref) identifies one, and every
data product it is registered as is a root of the crate; a folder means
every file under it, the paper's figures in one folder being the case in
mind. Files and folders whose names begin with a dot are left out and
reported. A file the registry does not know is an error; with
`strict = false` such files are left out and reported, so that a folder may
hold the paper's sources beside its figures.

`depth` is how many runs back the crate goes along any path, 100 by default.
`level` and `pack` are the registry's: `level` 1 or 2, what travels with each
file, and `pack` one of `"none"`, `"roots"`, `"supplements"` and `"all"`,
whose bytes a zip holds; left out, the registry's defaults apply.

Without `to`, return the crate's metadata, its `ro-crate-metadata.json`,
parsed: a dictionary with `"@context"` and `"@graph"`. With `to`, a path ending
in `.zip`, save the crate there as that zip, the metadata and the files
`pack` chooses, and return the path; a path ending in `.json` saves the
metadata there. The registry is the one the FAIR CLI is configured to use,
or the project's remote named by `remote`, or `registry`, or the one `handle`
was opened on; no token is needed.
"""
function crate(registry::RegistryEndpoint, paths::AbstractString...;
               depth::Integer = 100, level::Union{Nothing, Integer} = nothing,
               pack::Union{Nothing, AbstractString} = nothing,
               to::Union{Nothing, AbstractString} = nothing,
               strict::Bool = true)
    _checkdepth(depth)
    isempty(paths) &&
        throw(ArgumentError("name at least one file, folder or data product to build the crate for"))
    roots = _crateroots(registry, String.(collect(paths)), strict)
    query = _cratequery(registry, roots, depth, level, pack)
    isnothing(to) &&
        return JSON.parse(String(_cratebytes(registry, query * "&format=json")))
    extension = lowercase(last(splitext(to)))
    if extension == ".zip"
        write(to,
              _cratebytes(registry, query * "&format=zip",
                          accept = "application/zip"))
    elseif extension == ".json"
        write(to, _cratebytes(registry, query * "&format=json"))
    else
        throw(ArgumentError("`to` is the path of a .zip to save the crate as, or of a .json for its metadata alone: $to"))
    end
    return String(to)
end
function crate(handle::DataRegistryHandle, paths::AbstractString...;
               depth::Integer = 100, level::Union{Nothing, Integer} = nothing,
               pack::Union{Nothing, AbstractString} = nothing,
               to::Union{Nothing, AbstractString} = nothing,
               strict::Bool = true)
    return crate(handle.registry, paths...; depth, level, pack, to, strict)
end
function crate(paths::AbstractString...;
               remote::Union{Nothing, AbstractString} = nothing,
               depth::Integer = 100, level::Union{Nothing, Integer} = nothing,
               pack::Union{Nothing, AbstractString} = nothing,
               to::Union{Nothing, AbstractString} = nothing,
               strict::Bool = true)
    return registry_session(remote = remote) do registry
        return crate(registry, paths...; depth, level, pack, to, strict)
    end
end

# The data products the crate is for: those the files among `paths` are
# registered as, every file under a folder, and those named - files and
# folders named with a leading dot left out and reported, files the registry
# does not know an error unless `strict` is off, when they are reported too
function _crateroots(registry::RegistryEndpoint, paths::Vector{String},
                     strict::Bool)
    roots = String[]
    unknown = String[]
    hidden = String[]
    for path in paths
        if isdir(path)
            _folderroots!(roots, unknown, hidden, registry, path)
        elseif isfile(path)
            if _hiddenname(path)
                push!(hidden, path)
            else
                _fileroots!(roots, unknown, registry, path)
            end
        else
            push!(roots, _namedroot(registry, path))
        end
    end
    isempty(hidden) ||
        println("left out, named with a leading dot: ", join(hidden, ", "))
    if !isempty(unknown)
        strict &&
            throw(ReadWriteException("not registered as a data product in this registry: " *
                                     join(unknown, ", ") *
                                     " - give `strict = false` to leave such files out"))
        println("left out, not registered in this registry: ",
                join(unknown, ", "))
    end
    isempty(roots) &&
        throw(ReadWriteException("nothing to build a crate for: no registered data product among " *
                                 join(paths, ", ")))
    return unique(roots)
end

# Whether a file or folder is named with a leading dot
_hiddenname(path::AbstractString) = startswith(basename(path), ".")

# Every file under a folder, those under a folder named with a leading dot
# left out with that folder reported once
function _folderroots!(roots::Vector{String}, unknown::Vector{String},
                       hidden::Vector{String}, registry::RegistryEndpoint,
                       folder::String)
    for (directory, _, files) in walkdir(folder)
        parts = directory == folder ? String[] :
                splitpath(relpath(directory, folder))
        covered = findfirst(part -> startswith(part, "."), parts)
        if !isnothing(covered)
            covered == length(parts) &&
                push!(hidden, joinpath(folder, parts[1:covered]...))
            continue
        end
        for file in sort(files)
            path = joinpath(directory, file)
            if _hiddenname(file)
                push!(hidden, path)
            else
                _fileroots!(roots, unknown, registry, path)
            end
        end
    end
    return nothing
end

# The data products a file is registered as, or the file as unknown
function _fileroots!(roots::Vector{String}, unknown::Vector{String},
                     registry::RegistryEndpoint, path::String)
    found = [product.url
             for object in _registeredobjects(registry, _getfilehash(path))
             for product in object.data_products]
    isempty(found) ? push!(unknown, path) : append!(roots, found)
    return nothing
end

# The data product a `namespace:name@version` names, at its newest version
# with none
function _namedroot(registry::RegistryEndpoint, text::String)
    named = try
        _parsedataproduct(text)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("no file or folder at '$text', and it is not a data product name: $(err.msg)"))
    end
    if isnothing(named.version)
        entry = _latestdataproduct(registry, named.namespace, named.name)
        isnothing(entry) &&
            throw(ReadWriteException("no data product $text is registered in this registry"))
        return entry["url"]
    end
    return _finddataproduct(registry, named.namespace, named.name,
                            named.version)["url"]
end

# The crate's address on the registry, for these data products with these
# choices, the format still to be added
function _cratequery(registry::RegistryEndpoint, roots::Vector{String},
                     depth::Integer, level::Union{Nothing, Integer},
                     pack::Union{Nothing, AbstractString})
    query = string(registry.url, "ro-crate/?",
                   join(("data_product=" * _extractid(url) for url in roots),
                        "&"), "&depth=", depth)
    isnothing(level) || (query *= "&level=$level")
    isnothing(pack) || (query *= "&pack=$pack")
    return query
end

# The registry's answer at `url` as bytes - JSON unless `accept` says what
# else - a request it refuses as a `ReadWriteException` carrying its reason
function _cratebytes(registry::RegistryEndpoint, url::String;
                     accept::Union{Nothing, AbstractString} = nothing)
    headers = _headers(registry)
    isnothing(accept) ||
        (headers["Accept"] = "$accept; version=$(registry.api_version)")
    try
        return HTTP.request("GET", URIs.URI(url), headers).body
    catch err
        if err isa HTTP.StatusError && err.status == 400
            detail = try
                JSON.parse(String(err.response.body))["detail"]
            catch
                String(err.response.body)
            end
            throw(ReadWriteException("the registry refused the crate: $detail"))
        end
        (err isa Base.IOError || err isa HTTP.ConnectError) &&
            throw(_unreachable(registry))
        rethrow()
    end
end
