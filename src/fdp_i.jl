# SPDX-License-Identifier: LGPL-3.0-or-later

# The registry side of the API: registering objects, data products and issues,
# and resolving the entries of the working config against the registry.

"""
    ReadWriteException(msg)

Thrown when the registry or the data store does not hold what a read or write
needs: a missing data product, a version already registered, a registry that
is not running, a write with no registry token; or when a read or write asks
for what is not yet implemented, such as a table.
"""
struct ReadWriteException <: Exception
    msg::String
end

"""
    ConfigFileException(msg)

Thrown when a configuration file - the working config, or the CLI's own - lacks
the section or entry a call refers to.
"""
struct ConfigFileException <: Exception
    msg::String
end

# == Functions ==

# Whether what a `catch` caught is an interrupt, as a Ctrl-C makes, to rethrow
# rather than handle: an `InterruptException`, or a `Base.CancellationRequest`,
# which a SIGINT reaching a waiting task is from Julia 1.14. Anything may be
# thrown, so `err` is any value
@static if isdefined(Base, :CancellationRequest)
    _interrupted(err) = err isa InterruptException ||
                        err isa Base.CancellationRequest
else
    _interrupted(err) = err isa InterruptException
end

# The extension of a file name, the part after its last dot
_extension(path::AbstractString) = String(match(r"([^.]+)$", basename(path))[1])

# The job folder of the run this script is in: the session's rehearsal's, else
# the one `fair run` launched this script with and names in FDP_CONFIG_DIR;
# with neither, no run was prepared
function _launchedjob()
    job = _sessionjob()
    isnothing(job) && haskey(ENV, "FDP_CONFIG_DIR") && (job = FDP_CONFIG_DIR())
    isnothing(job) || return job
    return throw(ConfigFileException(string("DataPipeline.initialise() is called by a script that `fair run` launches, ",
                                            "which sets FDP_CONFIG_DIR to the folder holding the run's working config: ",
                                            "run the script with `fair run`, prepare a rehearsal with ",
                                            "DataPipeline.rehearse, or give initialise the working config ",
                                            "and the submission script")))
end

# The job folder of the session's rehearsal, if one is prepared and not ended
function _sessionjob()
    session = SESSION[]
    (isnothing(session) || session.ended) && return nothing
    return session.job
end

# The mode a run opens in, or the error that it cannot: a session's one run
# is opened once, however `initialise` is given its files
_runmode(::Nothing) = RecordedRun()
_runmode(session::SessionRun) = _runmode(session.mode, session)
function _runmode(mode::Rehearsal, session::SessionRun)
    isnothing(session.handle) && return mode
    session.ended &&
        throw(ReadWriteException("the rehearsal has ended: call DataPipeline.rehearse again to prepare another"))
    return throw(ReadWriteException("the rehearsal's handle is open: finalise or discard it, or call rehearse again with restart = true"))
end
function _runmode(::RecordedRun, session::SessionRun)
    session.ended &&
        throw(ReadWriteException("a code run was recorded in this session already: a script making several runs is not supported, and whether it should be is undecided"))
    return throw(ReadWriteException("code run $(session.handle.code_run_uuid) is open: finalise it before another initialise"))
end

# The token the run's registry holds, which a rehearsal never has, whatever
# the environment holds
_runtoken(::RecordedRun, token::Union{Nothing, AbstractString}) = token
_runtoken(::Rehearsal, ::Union{Nothing, AbstractString}) = nothing

# The session's run once `initialise` has opened one: the rehearsal's handle,
# or the recorded run, in the folder its files are in
function _opened(handle::DataRegistryHandle{Rehearsal}, ::Nothing)
    session = SESSION[]
    SESSION[] = SessionRun(session.mode, session.job, session.prepared,
                           session.inblock, handle, false, session.hold)
    return nothing
end
function _opened(handle::DataRegistryHandle{RecordedRun},
                 hold::Union{Nothing, AbstractRegistryHold})
    SESSION[] = SessionRun(RecordedRun(), handle.config_dir, false, false,
                           handle, false, hold)
    return nothing
end

# Forget the session's run, so that `initialise` opens another: for the
# tests, which open many runs in one process, and for whoever else knows
# what that means - a run left open is not ended by it, though its hold on
# the registry is released
_resetsession!() = (_releasehold!(); SESSION[] = nothing; nothing)

# ... and ended, where it was the session's
function _ended(handle::DataRegistryHandle)
    session = SESSION[]
    (!isnothing(session) && session.handle === handle) ||
        return nothing
    SESSION[] = SessionRun(session.mode, session.job, session.prepared,
                           session.inblock, handle, true, session.hold)
    return nothing
end

# The submission script of a working config: the copy in its job folder that
# `fair run` names as `run_metadata.script_path`, whatever shell runs it. For a
# config naming none, `script.sh` (`script.bat` on Windows) in its job folder
# `job`, or with none known, in FDP_CONFIG_DIR
function _submissionscript(config::AbstractDict, job::Union{Nothing, String})
    path = get(config["run_metadata"], "script_path", nothing)
    isnothing(path) || return String(path)
    isnothing(job) || return joinpath(job, FDP_SUBMISSION_SCRIPT)
    haskey(ENV, "FDP_CONFIG_DIR") && return FDP_PATH_SUBMISSION()
    return throw(ConfigFileException(string("initialise was given a working config that names no submission script, ",
                                            "and FDP_CONFIG_DIR is not set to find one beside it: give both")))
end

# The working config at `path`, the one `fair run` writes. A file that is not
# there is a job folder that is gone; one without the data store and the commit
# that `fair run` fills in is a user config, and no run was launched from it.
function _workingconfig(path::AbstractString)
    isfile(path) ||
        throw(ConfigFileException(string("no working config at ", path,
                                         " - a job folder that is gone, or a place `fair run` wrote none: ",
                                         "run the script with `fair run`")))
    config = YAML.load_file(path)
    if !_isworkingconfig(config)
        throw(ConfigFileException(string(path,
                                         " is not a working config: it lacks the data store and the commit ",
                                         "that `fair run` fills in when it writes the working config it ",
                                         "launches a script with - run the script with `fair run`")))
    end
    return config
end

# Whether a config read from YAML is a working config: one with the data store
# and the commit that `fair run` fills in
function _isworkingconfig(config)
    run_metadata = config isa AbstractDict ?
                   get(config, "run_metadata", nothing) :
                   nothing
    return run_metadata isa AbstractDict &&
           haskey(run_metadata, "write_data_store") &&
           haskey(run_metadata, "latest_commit")
end

"""
    _registerobject(registry, path, root, description;
                    hash, local_root, public, file_type, new_object, authors)

Register a storage root, a storage location and an object in the registry,
reusing any of the three that already exist, and return the object entry.

# Arguments
- `path::String`: the file's full path, or its path within `root`.
- `root::String`: the storage root: a directory for a local file, a host URL
  for a repository.
- `description`: the object's description, or `nothing` for none.
- `hash::String`: the storage location's hash; the SHA-1 of the file unless
  given, so a repository passes its commit.
- `local_root::Bool`: whether the storage root is on this machine.
- `public::Bool`: whether the storage location is public.
- `file_type`: the extension registered as the object's file type; the
  file's own unless given, `nothing` to register none.
- `new_object::Bool`: post a new object even if an identical one exists,
  as every data product wants its own; the config, script and repository
  objects are reused.
- `authors::Vector{String}`: registry URLs of the object's authors; the
  author that `fair init` attached to the user unless given.
"""
function _registerobject(registry::RegistryEndpoint, path::String,
                         root::String, description::Union{Nothing, String};
                         hash::String = _getfilehash(joinpath(root, path)),
                         local_root::Bool = true, public::Bool = true,
                         file_type::Union{Nothing, String} = _extension(path),
                         new_object::Bool = false,
                         authors::Vector{String} = [_getauthorurl(registry)])
    root_entry = _postentry(registry, "storage_root",
                            Dict("root" => root, "local" => local_root))
    root_url = root_entry["url"]

    # Reuse a storage location with the same root, hash and visibility
    location_url = _geturl(registry, "storage_location",
                           Dict("hash" => hash, "public" => public,
                                "storage_root" => _extractid(root_url)))
    if isnothing(location_url)
        storage_loc = lstrip(replace(path, root => "", count = 1), '/')
        location_url = _postentry(registry, "storage_location",
                                  Dict("path" => storage_loc, "hash" => hash,
                                       "public" => public,
                                       "storage_root" => root_url))["url"]
    end

    object_query = Dict{String, Any}("storage_location" => location_url,
                                     "authors" => authors)
    isnothing(description) || (object_query["description"] = description)
    if !isnothing(file_type)
        object_query["file_type"] = _getfiletype(registry, file_type)
    end
    return new_object ? _createentry(registry, "object", object_query) :
           _postentry(registry, "object", object_query)
end

"""
    _patchcoderun(handle, inputs, outputs)

Attach the input and output component URLs to the code run and return its URL.
"""
function _patchcoderun(handle::DataRegistryHandle, inputs::Vector{String},
                       outputs::Vector{String})
    _requiretoken(handle.registry)
    body = JSON.json(Dict("inputs" => inputs, "outputs" => outputs))
    r = _registryrequest(handle.registry, "PATCH", handle.code_run_obj,
                         body = body)
    return JSON.parse(String(r.body))["url"]
end

"""
    _getauthorurl(registry)

Return the URL of the author that `fair init` attached to the `admin` user.
"""
function _getauthorurl(registry::RegistryEndpoint)
    users_id = _getid(registry, "users", Dict("username" => "admin"))
    user_author_url = _geturl(registry, "user_author", Dict("user" => users_id))
    if isnothing(user_author_url)
        throw(ReadWriteException("no author for user admin - has fair init been run?"))
    end
    return _getentry(registry, URIs.URI(user_author_url))["author"]
end

"""
    _repositorylocation(remote_repo)

Split a code repository's remote into the storage root it is registered under
(scheme and host, with a trailing slash) and its path there, as
`(root, path)`. A URL keeps its scheme; an scp-style SSH remote such as
`git@github.com:org/repo.git` is registered under `https://<host>/`.
"""
function _repositorylocation(remote_repo::AbstractString)
    url = match(r"^([A-Za-z][A-Za-z0-9+.-]*://[^/]+/)(.*)$", remote_repo)
    isnothing(url) || return (root = String(url[1]), path = String(url[2]))
    scp = match(r"^[^@/:]+@([^:/]+):/?(.*)$", remote_repo)
    isnothing(scp) ||
        return (root = "https://$(scp[1])/", path = String(scp[2]))
    return throw(ConfigFileException("cannot find the host in remote_repo '$remote_repo'"))
end

"""
    _readmetadata(handle, data_product, component = nothing)

Resolve a `read:` entry of the working config to the registry name, namespace,
version and component it refers to, as a named tuple. `component` is the one
the caller asked for, which the entry's `use:` block may rename.
"""
function _readmetadata(handle::DataRegistryHandle, data_product::String,
                       component::Union{Nothing, String} = nothing)
    rmd = _getmetadata(handle, data_product, "read")
    use = get(rmd, "use", Dict())
    return (data_product = get(use, "data_product", data_product),
            namespace = get(use, "namespace",
                            handle.config["run_metadata"]["default_input_namespace"]),
            version = use["version"],
            component = get(use, "component", component))
end

"""
    _finddataproduct(registry, namespace, data_product, version)

Return the registry entry of a data product, or throw if there is none.
"""
function _finddataproduct(registry::RegistryEndpoint, namespace::String,
                          data_product::String, version::String)
    dp_entry = _versioneddataproduct(registry, namespace, data_product,
                                     version)
    if isnothing(dp_entry)
        msg = string("no data products found matching: ", data_product,
                     " :-(ns: ", namespace, " - v: ", version, ")")
        throw(ReadWriteException(msg))
    end
    return dp_entry
end

# The registry entry of a data product at a version, or `nothing` where there
# is none
function _versioneddataproduct(registry::RegistryEndpoint, namespace::String,
                               data_product::String, version::String)
    namespace_id = _getid(registry, "namespace", Dict("name" => namespace))
    isnothing(namespace_id) && return nothing
    return _getentry(registry, "data_product",
                     Dict("name" => data_product,
                          "namespace" => namespace_id,
                          "version" => version))
end

"""
    _componenturl(registry, object_url, component)

Return the URL of the named `component` of an object, or of its `whole_object`
component when `component` is `nothing`; throw if there is no such component.
"""
function _componenturl(registry::RegistryEndpoint, object_url::String,
                       component::Union{Nothing, String})
    url = isnothing(component) ? _wholeobjectcomponent(registry, object_url) :
          _geturl(registry, "object_component",
                  Dict("name" => component,
                       "object" => _extractid(object_url)))
    if isnothing(url)
        throw(ReadWriteException("no component $component in object $object_url"))
    end
    return url
end

"""
    _readdataproduct(handle, data_product, component)

Find a `read:` data product of the working config in the registry, record it
(and `component`, `nothing` for the whole file) as an input in the handle, and
return the path of its file, or `nothing` for a data product with no file,
such as a deposit, which has no component to read either.
"""
function _readdataproduct(handle::DataRegistryHandle, data_product::String,
                          component::Union{Nothing, String})
    rmd = _readmetadata(handle, data_product, component)
    dp_entry = _finddataproduct(handle.registry, rmd.namespace,
                                rmd.data_product, rmd.version)
    obj_url = dp_entry["object"]
    object = _getentry(handle.registry, URIs.URI(obj_url))
    fileless = isnothing(object["storage_location"])
    fileless && !isnothing(rmd.component) &&
        throw(ReadWriteException("'$data_product' is a data product with no file, so it has no component $(rmd.component) to read"))
    component_url = _componenturl(handle.registry, obj_url, rmd.component)
    location = fileless ? (path = nothing, hash = nothing) :
               _getstoragelocation(handle.registry, obj_url)

    handle.inputs[(data_product, component)] = Dict("use_dp" =>
                                                        rmd.data_product,
                                                    "use_namespace" =>
                                                        rmd.namespace,
                                                    "use_version" =>
                                                        rmd.version,
                                                    "use_component" =>
                                                        rmd.component,
                                                    "component_url" =>
                                                        component_url,
                                                    "path" => location.path,
                                                    "hash" => location.hash)
    return location.path
end

"""
    _readtoml(handle, data_product, component)

Read a TOML data product and return the table of `component`.
"""
function _readtoml(handle::DataRegistryHandle, data_product::String,
                   component::String)
    path = _inputpath(handle, data_product, component)
    return TOML.parsefile(path)[component]
end

"""
    _getmetadata(handle, data_product, section)

Return the entry for `data_product` in the `read` or `write` `section` of the
working config, or throw a [`ConfigFileException`](@ref). Matches the name
exactly, so the write side goes through [`_writemetadata`](@ref) instead, which
also covers a name a wildcard entry stands for.
"""
function _getmetadata(handle::DataRegistryHandle, data_product::String,
                      section::String)
    if haskey(handle.config, section)
        for entry in handle.config[section]
            entry["data_product"] == data_product && return entry
        end
        msg = string("'", data_product, "' not found in '", section,
                     "' - check config file.")
    else
        msg = string("no '", section, "' section found - check config file.")
    end
    return throw(ConfigFileException(msg))
end

"""
    _writemetadata(handle, data_product)

Return the `write:` entry of the working config that covers `data_product`, and
the name the data product is to be registered under, as `(entry, name)`.

An entry naming it exactly is used as it stands, under the name its `use:`
block gives. Otherwise the one wildcard entry whose pattern matches is used,
and the name is `data_product` itself: a pattern entry's `use.data_product` is
the pattern, which is a template rather than a name. Throw a
[`ConfigFileException`](@ref) if no entry covers the name, or if the patterns of
several do - a name a caller passes can never itself contain `*`, so the
ambiguity is the config's to resolve.
"""
function _writemetadata(handle::DataRegistryHandle, data_product::String)
    if !haskey(handle.config, "write")
        throw(ConfigFileException("no 'write' section found - check config file."))
    end
    found = _writeentry(handle, data_product)
    isnothing(found) &&
        throw(ConfigFileException("'$data_product' not found in 'write' - check config file."))
    return found
end

# The `write:` entry covering `data_product` and the name it is registered
# under, as `_writemetadata` finds them, or `nothing` where no entry covers it
function _writeentry(handle::DataRegistryHandle, data_product::String)
    entries = get(handle.config, "write", [])
    for entry in entries
        if entry["data_product"] == data_product
            use = get(entry, "use", Dict())
            return (entry = entry,
                    name = get(use, "data_product", data_product))
        end
    end
    pattern = _coveringpattern(entries, data_product, "write")
    return isnothing(pattern) ? nothing :
           (entry = pattern, name = data_product)
end

# The registry name, namespace and version that the `read:` entry naming
# `data_product` stands for, as `link_read!` resolves it; else, where the
# pattern of a kept entry covers the name, the name itself in that entry's
# namespace, at no version, a pattern's own version meaning nothing; else
# `nothing`
function _readentry(handle::DataRegistryHandle, data_product::String)
    entries = get(handle.config, "read", [])
    default = handle.config["run_metadata"]["default_input_namespace"]
    for entry in entries
        entry["data_product"] == data_product || continue
        use = get(entry, "use", Dict())
        version = get(use, "version", nothing)
        return (namespace = get(use, "namespace", default),
                name = get(use, "data_product", data_product),
                version = isnothing(version) ? nothing : string(version))
    end
    pattern = _coveringpattern(entries, data_product, "read")
    isnothing(pattern) && return nothing
    return (namespace = get(get(pattern, "use", Dict()), "namespace", default),
            name = data_product, version = nothing)
end

# The one entry of a config section whose pattern matches `data_product`, or
# `nothing`; the patterns of several matching it are a `ConfigFileException`,
# since a name a caller passes never itself holds `*`, so the ambiguity is the
# config's to resolve
function _coveringpattern(entries::AbstractVector, data_product::String,
                          section::String)
    patterns = [entry
                for entry in entries
                if occursin('*', entry["data_product"]) &&
        occursin(_globregex(entry["data_product"]), data_product)]
    isempty(patterns) && return nothing
    length(patterns) == 1 && return only(patterns)
    matched = join(("'$(entry["data_product"])'" for entry in patterns), ", ")
    msg = string("'", data_product, "' matches more than one wildcard in '",
                 section, "' (", matched, ") - check config file.")
    return throw(ConfigFileException(msg))
end

# The namespace a `write:` entry registers under: its own, else the run's
# default for outputs
function _writenamespace(handle::DataRegistryHandle, entry::AbstractDict)
    use = get(entry, "use", Dict())
    return get(use, "namespace",
               handle.config["run_metadata"]["default_output_namespace"])
end

# Whether a lookup in the working config finds its entry, where not finding
# one is a `ConfigFileException`
function _covered(lookup::Function)
    try
        lookup()
        return true
    catch e
        e isa ConfigFileException || rethrow()
        return false
    end
end

"""
    _latestdataproduct(registry, namespace, data_product)

Return the registry entry of the highest version of a data product in a
namespace, or `nothing` if the name is not registered there.
"""
function _latestdataproduct(registry::RegistryEndpoint, namespace::String,
                            data_product::String)
    namespace_id = _getid(registry, "namespace", Dict("name" => namespace))
    isnothing(namespace_id) && return nothing
    # The registry matches names as globs, so keep the exact name only
    entries = [entry
               for entry in _getentries(registry, "data_product",
                                        Dict("name" => data_product,
                                             "namespace" => namespace_id))
               if entry["name"] == data_product]
    isempty(entries) && return nothing
    return argmax(entry -> VersionNumber(entry["version"]), entries)
end

"""
    _unchangedfile(registry, namespace, data_product, hash, source)

Return the path, the version and the object's URL of the file registered as
the highest version of a data product, as `(path, version, object)`, if its
bytes have the given `hash` and what `source` says of it is what is
registered with it: the same source, authors and licence, a `source` of
`nothing` being a file compared by its bytes alone. Return `nothing` if either
differs, if that version has no file, or if the name is not registered.
"""
function _unchangedfile(registry::RegistryEndpoint, namespace::String,
                        data_product::String, hash::String,
                        source::Union{Nothing, SourceRecord, OutputDescription})
    latest = _latestdataproduct(registry, namespace, data_product)
    isnothing(latest) && return nothing
    return _registeredfile(registry, latest, hash, source)
end

# The path, the version and the object's URL of the file a registered data
# product holds, as `(path, version, object)`, if it is this file - these
# bytes, with what `source` says of it registered with it; else `nothing`, as
# for a data product with no file
function _registeredfile(registry::RegistryEndpoint, data_product::AbstractDict,
                         hash::String,
                         source::Union{Nothing, SourceRecord,
                                       OutputDescription})
    object = _getentry(registry, URIs.URI(data_product["object"]))
    isnothing(object["storage_location"]) && return nothing
    location = _getstoragelocation(registry, data_product["object"])
    location.hash == hash || return nothing
    _recordssource(registry, data_product, object, source) || return nothing
    return (path = location.path, version = String(data_product["version"]),
            object = String(data_product["object"]))
end

# What the registry holds of an output of these bytes written as `version`, as
# `(path, version, object)`, or `nothing` for an output that is a new version.
# Where that version exists it must be this file - a version is registered
# once, so a run may reproduce it and not change it - or this is an error;
# where it does not, the highest version is the output if it is this file
function _heldfile(registry::RegistryEndpoint, namespace::String,
                   data_product::String, version::String, hash::String,
                   source::Union{Nothing, SourceRecord, OutputDescription})
    namespace_id = _getid(registry, "namespace", Dict("name" => namespace))
    existing = isnothing(namespace_id) ? nothing :
               _getentry(registry, "data_product",
                         Dict("name" => data_product, "version" => version,
                              "namespace" => namespace_id))
    isnothing(existing) &&
        return _unchangedfile(registry, namespace, data_product, hash, source)
    held = _registeredfile(registry, existing, hash, source)
    isnothing(held) &&
        throw(ReadWriteException("$(_dataproductname(namespace, data_product, version)) is registered already, as another file or with another source, authors or licence: a run may reproduce a version that exists, byte for byte, and not change it"))
    return held
end

# Check, before a code run registers any output, that each written as a
# version that exists reproduces it, keeping the hash it was checked by
function _checkversions(handle::DataRegistryHandle)
    checked = Set{String}()
    for key in sort(collect(keys(handle.outputs)), by = string)
        metadata = handle.outputs[key]
        (key[1] in checked || !isfile(metadata["path"])) && continue
        push!(checked, key[1])
        hash = get!(metadata, "hash") do
            return _getfilehash(metadata["path"])
        end
        _heldfile(handle.registry, metadata["use_namespace"],
                  replace(metadata["use_dp"],
                          RUN_ID_PLACEHOLDER => handle.code_run_uuid),
                  String(metadata["use_version"]), hash,
                  _outputsource(handle, key[1]))
    end
    return nothing
end

# Make the file at `source` available at `destination`, which must not exist:
# a hard link where one can be made, so that no bytes are copied, else a copy.
# A symbolic link is resolved first, so that it is the file that arrives.
function _placefile(source::AbstractString, destination::AbstractString)
    source = realpath(source)
    try
        hardlink(source, destination)
    catch e
        isa(e, Base.IOError) || rethrow()
        cp(source, destination)
    end
    return destination
end

# Whether `destination`, the data store's name for the bytes of `file` by their
# hash `hash`, holds those bytes already - the same file or a copy - though the
# registry has no location for them, as where a run's registration was lost. A
# file there with other bytes is deleted, with a warning: its name says what it
# must hold.
function _storedalready(destination::String, file::AbstractString,
                        hash::AbstractString)
    isfile(destination) || return false
    samefile(destination, file) && return true
    found = _getfilehash(destination)
    found == hash && return true
    @warn "replacing the file at $destination, whose bytes have the SHA-1 hash $found where its name gives $hash"
    rm(destination)
    return false
end

# Make the file at `source` available at `destination` in a folder of links: a
# symbolic link where one can be made, else as `_placefile` places it, since
# Windows may refuse one. `link` makes the symbolic link; the tests replace it
# with one that fails.
function _placelink(source::AbstractString, destination::AbstractString;
                    link::Function = symlink)
    try
        link(source, destination)
    catch e
        isa(e, Base.IOError) || rethrow()
        _placefile(source, destination)
    end
    return destination
end

# Remove `directory` and its parents while they are empty, stopping at `stop`
function _pruneempty(directory::AbstractString, stop::AbstractString)
    stop = rstrip(normpath(stop), '/')
    directory = rstrip(normpath(directory), '/')
    while directory != stop && startswith(directory, stop) &&
          isdir(directory) &&
          isempty(readdir(directory))
        rm(directory)
        directory = dirname(directory)
    end
    return nothing
end

"""
    _registerdataproduct(handle, data_product, component)

Register one output of the handle: substitute the code run's uuid for
`\${{RUN_ID}}` in its registered name; register its file, object and data
product, once per data product however many components it has, unless the
file is that of the highest version registered already, when no version is
made and the file written is removed; and register the component (the
`whole_object` component when `component` is `nothing`). Record the
registered name, the file's path, the object URL, the component URL and
whether it was unchanged in the handle, and return the component URL.
"""
function _registerdataproduct(handle::DataRegistryHandle, data_product::String,
                              component::Union{Nothing, String})
    registry = handle.registry
    wmd = handle.outputs[(data_product, component)]
    datastore = handle.config["run_metadata"]["write_data_store"]
    use_data_product = replace(wmd["use_dp"],
                               RUN_ID_PLACEHOLDER => handle.code_run_uuid)
    wmd["use_dp"] = use_data_product
    use_component = wmd["use_component"]
    filepath = wmd["path"]

    # Another component of the same data product may have registered its file
    # and object already, or found them registered
    registered = [value
                  for (key, value) in handle.outputs
                  if key[1] == data_product && haskey(value, "object_url")]
    if !isempty(registered)
        new_filepath = registered[1]["path"]
        obj_url = registered[1]["object_url"]
        unchanged = registered[1]["unchanged"]
    else
        if !isfile(filepath)
            msg = string("File not found: ", use_data_product,
                         " is present in handle but not in data store.")
            throw(ReadWriteException(msg))
        end
        # A file with a source was hashed when its source was checked
        hash = get(wmd, "hash") do
            return _getfilehash(filepath)
        end
        source = _outputsource(handle, data_product)
        held = _heldfile(registry, wmd["use_namespace"], use_data_product,
                         String(wmd["use_version"]), hash, source)
        unchanged = !isnothing(held)
        if unchanged
            println("data product unchanged: ", use_data_product, " (",
                    held.version, ")")
            rm(filepath)
            new_filepath = held.path
            obj_url = held.object
        else
            stored = _registerfile(handle, wmd, hash, source)
            new_filepath = stored.path
            obj_url = stored.object
        end
        _pruneempty(dirname(filepath), datastore)
    end
    wmd["path"] = new_filepath
    wmd["object_url"] = obj_url
    wmd["unchanged"] = unchanged

    if isnothing(use_component)
        component_url = _wholeobjectcomponent(registry, obj_url)
    else
        component_url = _postentry(registry, "object_component",
                                   Dict("object" => obj_url,
                                        "name" => use_component))["url"]
    end
    wmd["component_url"] = component_url
    return component_url
end

# Put the file of an output in the data store under its hash, or, if the same
# bytes are already in the store, delete it and point at them; and register
# its object, its data product and its source. Return the file's path and
# the object's URL, as `(path, object)`.
function _registerfile(handle::DataRegistryHandle, wmd::AbstractDict,
                       hash::String,
                       source::Union{Nothing, SourceRecord, OutputDescription})
    registry = handle.registry
    datastore = handle.config["run_metadata"]["write_data_store"]
    filepath = wmd["path"]
    existing = _getentry(registry, "storage_location",
                         Dict("hash" => hash, "public" => wmd["public"],
                              "storage_root" =>
                                  _extractid(handle.datastore_obj_url)))
    if isnothing(existing)
        # Name the file by its hash, unless the file under that name holds its
        # bytes already
        path = joinpath(datastore, wmd["use_namespace"], wmd["use_dp"],
                        "$hash.$(_extension(filepath))")
        mkpath(dirname(path))
        if _storedalready(path, filepath, hash)
            rm(filepath)
        else
            mv(filepath, path)
        end
    else
        # The same bytes are already in the store: point at them and drop
        # the duplicate
        path = joinpath(datastore, existing["path"])
        rm(filepath)
    end

    obj_url = _registerobject(registry, path, datastore,
                              wmd["dataproduct_description"], hash = hash,
                              public = wmd["public"], new_object = true,
                              authors = _fileauthors(registry, source))["url"]
    ns_url = _postentry(registry, "namespace",
                        Dict("name" => wmd["use_namespace"]))["url"]
    registered_url = _postentry(registry, "data_product",
                                Dict("namespace" => ns_url,
                                     "name" => wmd["use_dp"],
                                     "object" => obj_url,
                                     "version" => wmd["use_version"]))["url"]
    _registersource(registry, source, registered_url, obj_url, hash,
                    wmd["public"])
    return (path = path, object = obj_url)
end

"""
    _resolvewrite(handle, data_product, component, file_type, description)

Return the metadata for writing `component` (`nothing` for a whole file) of a
`write:` data product of the working config, or of one a wildcard entry covers:
where its file goes (a new temporary file, or the file another component of the
same data product already started in this code run) and the names it will be
registered under.
"""
function _resolvewrite(handle::DataRegistryHandle, data_product::String,
                       component::Union{Nothing, String},
                       file_type::String, description::Union{Nothing, String})
    wmd, use_data_product = _writemetadata(handle, data_product)
    use = get(wmd, "use", Dict())
    data_store = handle.config["run_metadata"]["write_data_store"]
    use_namespace = _checknamespace(_writenamespace(handle, wmd))
    _checkdataproduct(use_data_product)
    use_component = get(use, "component", component)
    isnothing(use_component) || _checkcomponent(use_component)
    use_version = use["version"]
    public = get(use, "public", handle.config["run_metadata"]["public"])

    # A data product written to earlier in this code run keeps its file. One
    # written as a version that exists is compared with it at `finalise`, when
    # its bytes are known
    paths = unique(value["path"]
                   for (key, value) in handle.outputs if key[1] == data_product)
    if isempty(paths)
        directory = joinpath(data_store, use_namespace, use_data_product)
        mkpath(directory)
        path = joinpath(directory, "dat-$(_randomhash()).$file_type")
    else
        path = only(paths)
    end

    return Dict("use_dp" => use_data_product,
                "use_component" => use_component,
                "use_namespace" => use_namespace,
                "use_version" => use_version,
                "path" => path,
                "public" => public,
                "dataproduct_description" => get(wmd, "description", nothing),
                "component_description" => description)
end

"""
    _writekeyval(handle, data, data_product, component, description)

Write `data` as the table `component` of a TOML data product, record the
output in the handle and return its metadata.
"""
function _writekeyval(handle::DataRegistryHandle, data::Dict,
                      data_product::String,
                      component::String, description::String,
                      supersede::Bool)
    metadata = _resolvewrite(handle, data_product, component, "toml",
                             description)
    metadata["supersede"] = supersede
    use_component = metadata["use_component"]
    path = metadata["path"]

    if isfile(path)
        output = TOML.parsefile(path)
        if haskey(output, use_component)
            throw(ReadWriteException("Component $use_component already exists in $path."))
        end
        output[use_component] = data
    else
        output = Dict(use_component => data)
    end
    open(path, "w") do io
        return TOML.print(io, output)
    end

    handle.outputs[(data_product, component)] = metadata
    return metadata
end

"""
    _getstoragelocation(registry, object_url)

Return the path on disk of the file behind a registry object and the hash the
registry holds for it, as `(path, hash)`.
"""
function _getstoragelocation(registry::RegistryEndpoint, object_url::String)
    obj_entry = _getentry(registry, URIs.URI(object_url))
    storage_loc_entry = _getentry(registry,
                                  URIs.URI(obj_entry["storage_location"]))
    storage_root_entry = _getentry(registry,
                                   URIs.URI(storage_loc_entry["storage_root"]))
    return (path = joinpath(_rootfolder(storage_root_entry["root"]),
                            storage_loc_entry["path"]),
            hash = String(storage_loc_entry["hash"]))
end

"""
    _globregex(pattern)

Return the anchored regular expression for a data product name pattern, in
which each `*` matches one segment of the name and every other character is
literal. A segment is one or more characters other than `/` and the four the
registry refuses in a name, `[`, `]`, `?` and `*`, so that no registered name
is passed over and a pattern never matches itself.
"""
function _globregex(pattern::AbstractString)
    occursin('*', pattern) ||
        throw(ArgumentError("a pattern needs at least one *: $pattern"))
    literal(s) = replace(s, r"([\\^\$.|?+()\[\]{}])" => s"\\\1")
    return Regex("^" *
                 join(map(literal, split(pattern, '*')), "[^/\\[\\]?*]+") *
                 "\$")
end

"""
    _matchingreads(handle, pattern)

Return the names of the `read:` data products of the working config that a
pattern stands for, sorted. Where any entry is marked with the pattern it was
expanded from, as `wildcard:`, they are the entries marked with this one;
otherwise those whose names match it. A name holding `*` - a pattern's own
entry, kept by the CLI - is never one of them. None is an empty result where
the config holds the pattern's own entry, and an error where it does not, so
that a pattern never configured is not taken for one that matched nothing.
"""
function _matchingreads(handle::DataRegistryHandle, pattern::AbstractString)
    regex = _globregex(pattern)
    entries = get(handle.config, "read", [])
    marked = any(entry -> haskey(entry, "wildcard"), entries)
    names = sort!([String(entry["data_product"])
                   for entry in entries
                   if !occursin('*', entry["data_product"]) &&
                      (marked ? get(entry, "wildcard", nothing) == pattern :
                       occursin(regex, entry["data_product"]))])
    isempty(names) &&
        !any(entry -> entry["data_product"] == pattern, entries) &&
        throw(ConfigFileException("no read data product matches '$pattern' - check config file"))
    return names
end

"""
    _issuecomponents(handle, target)

Return the URLs of the registry components an issue target refers to. Called
by `finalise` after the outputs are registered, so a target can name one.
"""
function _issuecomponents(handle::DataRegistryHandle, ::WorkingConfig)
    return [_wholeobjectcomponent(handle.registry, handle.config_obj)]
end
function _issuecomponents(handle::DataRegistryHandle, ::SubmissionScript)
    return [_wholeobjectcomponent(handle.registry, handle.script_obj)]
end
function _issuecomponents(handle::DataRegistryHandle, target::CodeRepository)
    isnothing(target.commits) &&
        return [_wholeobjectcomponent(handle.registry, handle.repo_obj)]
    return _repositorycomponents(handle.registry, target.commits)
end
function _issuecomponents(registry::RegistryEndpoint, target::CodeRepository)
    return _repositorycomponents(registry, target.commits)
end
function _issuecomponents(handle::DataRegistryHandle,
                          target::ConfigDataProduct)
    key = (target.data_product, target.component)
    for table in (handle.inputs, handle.outputs, handle.unchanged)
        haskey(table, key) && return [table[key]["component_url"]]
    end
    # Not read or written in this run: a read entry can still be resolved
    if any(entry["data_product"] == target.data_product
           for entry in get(handle.config, "read", []))
        rmd = _readmetadata(handle, target.data_product)
        existing = ExistingDataProduct(_dataproductname(rmd.namespace,
                                                        rmd.data_product,
                                                        rmd.version),
                                       component = target.component)
        return _issuecomponents(handle, existing)
    end
    return throw(ReadWriteException("$(target.data_product) was not read or written in this code run"))
end
function _issuecomponents(handle::DataRegistryHandle,
                          target::ExistingDataProduct)
    return _issuecomponents(handle.registry, target)
end
function _issuecomponents(registry::RegistryEndpoint,
                          target::ExistingDataProduct)
    if isnothing(target.version)
        dp_entry = _latestdataproduct(registry, target.namespace,
                                      target.data_product)
        isnothing(dp_entry) &&
            throw(ReadWriteException("no data product $(_dataproductname(target.namespace, target.data_product)) is registered"))
    else
        dp_entry = _finddataproduct(registry, target.namespace,
                                    target.data_product, target.version)
    end
    return [_componenturl(registry, dp_entry["object"], target.component)]
end

# The whole components of the objects standing for the registered commits a
# selection chooses, of which there must be some
function _repositorycomponents(registry::RegistryEndpoint,
                               commits::AbstractCommitSelection)
    found = _identifyrepository(registry, commits)
    isempty(found.commits) &&
        throw(ReadWriteException("the registry holds no run of $(found.remote) from $(_describe(commits)), so there is nothing to raise the issue on"))
    return [_wholeobjectcomponent(registry, object)
            for commit in found.commits for object in commit.objects]
end

# The severity of the issue `supersede = true` raises on a superseded version:
# the lowest, below the default, since the old data is not wrong
const SUPERSEDED_ISSUE_SEVERITY = 0

# What `supersede = true` does once a data product's version is settled: queue
# the issue on the version it supersedes - the highest before, `previous` as
# the registry holds it or `nothing` - or say that there was nothing to
# supersede: the file was registered already, unchanged, there was no version
# before, or the version is not above the highest
function _supersede!(handle::DataRegistryHandle, namespace::String,
                     name::String, version::String,
                     previous::Union{Nothing, AbstractDict}, unchanged::Bool)
    label = _dataproductname(namespace, name, version)
    if unchanged
        @info "nothing to supersede: the file written as $label is registered already, unchanged"
    elseif isnothing(previous)
        @info "nothing to supersede: $label is the first version of its name"
    elseif VersionNumber(previous["version"]) >= VersionNumber(version)
        @info "nothing to supersede: $label is not above the highest version, $(previous["version"])"
    else
        superseded = _dataproductname(namespace, name, previous["version"])
        push!(handle.issues,
              PendingIssue([ExistingDataProduct(superseded)],
                           "Superseded by " * label,
                           SUPERSEDED_ISSUE_SEVERITY, false))
    end
    return nothing
end

# For each data product written with `supersede = true`, what the registry
# holds as its highest version before this run registers anything, with the
# name and version the run writes
function _previousversions(handle::DataRegistryHandle)
    previous = Dict{String, NamedTuple}()
    for (key, metadata) in handle.outputs
        get(metadata, "supersede", false) || continue
        haskey(previous, key[1]) && continue
        name = replace(metadata["use_dp"],
                       RUN_ID_PLACEHOLDER => handle.code_run_uuid)
        previous[key[1]] = (namespace = String(metadata["use_namespace"]),
                            name = name,
                            version = String(metadata["use_version"]),
                            latest = _latestdataproduct(handle.registry,
                                                        metadata["use_namespace"],
                                                        name))
    end
    return previous
end

# Once the outputs are settled, each data product written with
# `supersede = true` supersedes what it supersedes, or says it does not
function _supersedeoutputs!(handle::DataRegistryHandle,
                            previous::Dict{String, NamedTuple})
    for data_product in sort(collect(keys(previous)))
        before = previous[data_product]
        unchanged = any(key[1] == data_product
                        for key in keys(handle.unchanged))
        _supersede!(handle, before.namespace, before.name, before.version,
                    before.latest, unchanged)
    end
    return nothing
end

# The description every API gives a code repository's object
const REPOSITORY_DESCRIPTION = "Remote code repository."

# The object of the code repository at a run's commit: the one the registry
# holds there, else one made with the authors the repository's metadata gives;
# with its licence and keywords added either way
function _registerrepository(registry::RegistryEndpoint, run_metadata::Dict)
    return _registerrepository(registry, run_metadata["remote_repo"],
                               run_metadata["latest_commit"],
                               _runrepositorymetadata(run_metadata))
end
# ... at a commit of the repository at `remote`, with the metadata it gives
function _registerrepository(registry::RegistryEndpoint,
                             remote::AbstractString, commit::AbstractString,
                             metadata::RepositoryMetadata)
    held = _heldrepository(registry, remote, commit)
    object_url = held.object
    if isnothing(object_url)
        repo = _repositorylocation(remote)
        location_url = held.location
        if isnothing(location_url)
            root_url = _postentry(registry, "storage_root",
                                  Dict("root" => repo.root,
                                       "local" => false))["url"]
            location_url = _createentry(registry, "storage_location",
                                        Dict("path" => repo.path,
                                             "hash" => commit,
                                             "public" => true,
                                             "storage_root" => root_url))["url"]
        end
        object_url = _createentry(registry, "object",
                                  Dict("description" => REPOSITORY_DESCRIPTION,
                                       "storage_location" => location_url,
                                       "authors" =>
                                           _repositoryauthors(registry,
                                                              metadata)))["url"]
    end
    _addlicence!(registry, object_url, metadata.licence)
    _addkeywords!(registry, object_url, metadata.keywords)
    return object_url
end

# The storage location the registry holds for a run's commit and the object it
# keeps there, either `nothing` where there is none
function _heldrepository(registry::RegistryEndpoint, run_metadata::Dict)
    return _heldrepository(registry, run_metadata["remote_repo"],
                           run_metadata["latest_commit"])
end
# ... for a commit of the repository at `remote`: one location for a commit
# under its host, whatever path it was registered with, and of several objects
# at it, the one a release is registered on, else the oldest
function _heldrepository(registry::RegistryEndpoint, remote::AbstractString,
                         commit::AbstractString)
    repo = _repositorylocation(remote)
    root_id = _getid(registry, "storage_root", Dict("root" => repo.root))
    isnothing(root_id) && return (location = nothing, object = nothing)
    location_url = _geturl(registry, "storage_location",
                           Dict("hash" => commit, "public" => true,
                                "storage_root" => root_id))
    isnothing(location_url) && return (location = nothing, object = nothing)
    objects = _getentries(registry, "object",
                          Dict("storage_location" => _extractid(location_url)))
    isempty(objects) && return (location = location_url, object = nothing)
    released = filter(objects) do object
        return !isnothing(get(object, "code_repo_release", nothing))
    end
    kept = argmin(isempty(released) ? objects : released) do object
        return parse(Int, _extractid(object["url"]))
    end
    return (location = location_url, object = kept["url"])
end

# What the run's code repository says of itself: the working tree's files for
# a run from uncommitted changes, which are what ran, else the commit's; none,
# with a warning, where there is no clone holding the commit to read
function _runrepositorymetadata(run_metadata::Dict)
    folder = get(run_metadata, "local_repo", nothing)
    commit = run_metadata["latest_commit"]
    nothing_read = _repositorymetadata(_ -> nothing, "nowhere")
    top = isnothing(folder) || !isdir(folder) ? nothing : _gittoplevel(folder)
    if isnothing(top)
        @warn "the run names no clone of its code repository to read ($(repr(folder))), so its metadata files are not read and a new repository object takes the runner as its author"
        return nothing_read
    end
    endswith(commit, "-dirty") && return _repositorymetadata(top)
    return LibGit2.with(LibGit2.GitRepo(top)) do clone
        LibGit2.iscommit(commit, clone) &&
            return _repositorymetadata(clone, commit)
        @warn "the clone at $top does not have the run's commit $commit, so its metadata files are not read and a new repository object takes the runner as its author"
        return nothing_read
    end
end

# The registry's authors for a repository's own, as its metadata names them,
# an author the registry cannot name passed over with a warning; or, with
# none, the runner
function _repositoryauthors(registry::RegistryEndpoint,
                            metadata::RepositoryMetadata)
    authors = String[]
    for name in metadata.authors
        if !_nameable(name)
            @warn "the registry cannot hold an author named '$name', which the repository's metadata gives: it takes none of $(join(UNNAMEABLE, " ")) in a name, so that author is passed over"
            continue
        end
        identifier = get(metadata.identifiers, name, nothing)
        url = if isnothing(identifier)
            _namedauthorurl(registry, name) do
                return _createentry(registry, "author",
                                    Dict("name" => name))["url"]
            end
        else
            _geturl(registry, "author", Dict("identifier" => identifier))
        end
        if isnothing(url)
            url = _createentry(registry, "author",
                               Dict("name" => name,
                                    "identifier" => identifier))["url"]
        end
        url in authors || push!(authors, url)
    end
    return isempty(authors) ? [_getauthorurl(registry)] : authors
end

# Add a repository's licence to its object unless the object has it, as
# `_licence` would record it now, a licence that is neither in the SPDX list
# nor a URL passed over with a warning
_addlicence!(::RegistryEndpoint, ::String, ::Nothing) = nothing
function _addlicence!(registry::RegistryEndpoint, object_url::String,
                      licence::String)
    named = try
        _licence(licence)
    catch err
        err isa ArgumentError || rethrow()
        @warn "the repository's licence '$licence' is not recorded: $(err.msg)"
        return nothing
    end
    held = _getentries(registry, "licence", Dict("object" => object_url))
    any(entry -> _heldlicence(entry) == named, held) ||
        _createentry(registry, "licence",
                     Dict("object" => object_url, "licence_info" => named.info,
                          "identifier" => named.identifier))
    return nothing
end

# Add a repository's keywords to its object, each unless the object has it,
# one the registry would read as a pattern passed over
function _addkeywords!(registry::RegistryEndpoint, object_url::String,
                       keywords::Vector{String})
    for keyword in keywords
        _nameable(keyword) || continue
        query = Dict("object" => object_url, "keyphrase" => keyword)
        isnothing(_getentry(registry, "keyword", query)) &&
            _createentry(registry, "keyword", query)
    end
    return nothing
end

# The issue raised against a code repository registered with uncommitted
# changes, shared by every run from that state, as they share its object
const DIRTY_REPOSITORY_ISSUE = "The code repository had uncommitted changes when this code ran, so the code that ran cannot be recovered from its commit."

# Warn that a run is being made from a working tree with uncommitted changes,
# and raise the issue against the repository object it is registered under
function _flagdirtyrepository(registry::RegistryEndpoint, repo_url::String,
                              commit::String)
    @warn "the code repository has uncommitted changes ($commit): raising an issue against it"
    _postissue(registry, DEFAULT_ISSUE_SEVERITY, DIRTY_REPOSITORY_ISSUE,
               [_wholeobjectcomponent(registry, repo_url)])
    return nothing
end

# Get or create the issue with this severity and description on exactly these
# components, and return it
function _postissue(registry::RegistryEndpoint, severity::Integer,
                    description::String,
                    components::AbstractVector{<:AbstractString})
    existing = _findissue(registry, severity, description, components)
    isnothing(existing) || return existing
    return _createentry(registry, "issue",
                        Dict("severity" => severity,
                             "description" => description,
                             "component_issues" => components))
end

# The issue already raised with this severity and description against exactly
# these components, or `nothing`. It is looked up through the first component's
# own issues, which every registry lists, because filtering issues by
# `component_issues` cannot match a set: registries before v1.3.0 ignore the
# filter, and v1.3.0 takes a single component and refuses a list.
function _findissue(registry::RegistryEndpoint, severity::Integer,
                    description::String,
                    components::AbstractVector{<:AbstractString})
    isempty(components) && return nothing
    for issue_url in _getentry(registry, URIs.URI(first(components)))["issues"]
        issue = _getentry(registry, URIs.URI(issue_url))
        issue["severity"] == severity && issue["description"] == description &&
            Set(issue["component_issues"]) == Set(components) &&
            return issue
    end
    return nothing
end

"""
    _registerissues(handle)

Post every issue queued in the handle, attached to the components its targets
resolve to.
"""
function _registerissues(handle::DataRegistryHandle)
    for issue in handle.issues
        components = reduce(vcat,
                            (_issuecomponents(handle, target)
                             for target in issue.targets),
                            init = String[])
        entry = _postpendingissue(handle.registry, issue, components)
        println("issue registered as ", entry["url"])
    end
    return nothing
end

# Post a queued issue on the components its targets resolve to, and on the
# other versions holding the same bytes if it asks, warning of them if not
function _postpendingissue(registry::RegistryEndpoint, issue::PendingIssue,
                           components::Vector{String})
    components = copy(components)
    for component in copy(components)
        for (label, other) in _samebytesversions(registry, component)
            if issue.all_versions
                other in components || push!(components, other)
            else
                @warn "$label has the same bytes as the data product the issue is on: raise the issue on every such version too with `all_versions = true`"
            end
        end
    end
    return _postissue(registry, issue.severity, issue.description, components)
end

# Register an issue raised outside a run at once and return its URL
function _raiseoutsiderun(::RecordedRun, registry::RegistryEndpoint,
                          issue::PendingIssue, components::Vector{String})
    return _postpendingissue(registry, issue, components)["url"]
end

# The mode of what the session is doing now: rehearsing, while a rehearsal is
# prepared and not ended, and otherwise recording
function _sessionmode()
    session = SESSION[]
    (isnothing(session) || session.ended || !(session.mode isa Rehearsal)) &&
        return RecordedRun()
    return session.mode
end

# The other versions of the data product a component belongs to that hold
# the same bytes, each as its name and the matching component's URL; none for
# a component of anything but a data product with a file
function _samebytesversions(registry::RegistryEndpoint, component_url::String)
    component = _getentry(registry, URIs.URI(component_url))
    object = _getentry(registry, URIs.URI(component["object"]))
    isempty(object["data_products"]) && return Tuple{String, String}[]
    isnothing(object["storage_location"]) && return Tuple{String, String}[]
    hash = _getentry(registry, URIs.URI(object["storage_location"]))["hash"]
    name = component["whole_object"] ? nothing : String(component["name"])
    found = Tuple{String, String}[]
    for product_url in object["data_products"]
        product = _getentry(registry, URIs.URI(product_url))
        namespace = _getentry(registry, URIs.URI(product["namespace"]))["name"]
        for other in _getentries(registry, "data_product",
                                 Dict("name" => product["name"],
                                      "namespace" =>
                                          _extractid(product["namespace"])))
            other["name"] == product["name"] || continue
            other["version"] == product["version"] && continue
            # Another version on this very object is covered already
            other["object"] == component["object"] && continue
            other_object = _getentry(registry, URIs.URI(other["object"]))
            isnothing(other_object["storage_location"]) && continue
            _getentry(registry, URIs.URI(other_object["storage_location"]))["hash"] ==
            hash ||
                continue
            matching = isnothing(name) ?
                       _wholeobjectcomponent(registry, other["object"]) :
                       _geturl(registry, "object_component",
                               Dict("name" => name,
                                    "object" => _extractid(other["object"])))
            isnothing(matching) && continue
            push!(found,
                  (_dataproductname(namespace, other["name"], other["version"]),
                   matching))
        end
    end
    return found
end
