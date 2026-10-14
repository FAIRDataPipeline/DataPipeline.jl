# SPDX-License-Identifier: LGPL-3.0-or-later

# The registry side of the API: registering objects, data products and issues,
# and resolving the entries of the working config against the registry.

"""
    ReadWriteException(msg)

Thrown when the registry or the data store does not hold what a read or write
needs: a missing data product, a version already registered, a registry that
is not running, a write with no registry token.
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

# The extension of a file name, the part after its last dot
_extension(path::AbstractString) = String(match(r"([^.]+)$", basename(path))[1])

"""
    _registerobject(registry, path, root, description;
                    hash, local_root, public, file_type, new_object, authors)

Register a storage root, a storage location and an object in the registry,
reusing any of the three that already exist, and return the object entry.

# Arguments
- `path::String`: the file's full path, or its path within `root`.
- `root::String`: the storage root: a directory for a local file, a host URL
  for a repository.
- `description::String`: the object's description.
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
                         root::String, description::String;
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

    object_query = Dict{String, Any}("description" => description,
                                     "storage_location" => location_url,
                                     "authors" => authors)
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
    r = HTTP.request("PATCH", handle.code_run_obj,
                     headers = _headers(handle.registry), body = body)
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
    namespace_id = _getid(registry, "namespace", Dict("name" => namespace))
    dp_entry = isnothing(namespace_id) ? nothing :
               _getentry(registry, "data_product",
                         Dict("name" => data_product,
                              "namespace" => namespace_id,
                              "version" => version))
    if isnothing(dp_entry)
        msg = string("no data products found matching: ", data_product,
                     " :-(ns: ", namespace, " - v: ", version, ")")
        throw(ReadWriteException(msg))
    end
    return dp_entry
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
return the path of its file.
"""
function _readdataproduct(handle::DataRegistryHandle, data_product::String,
                          component::Union{Nothing, String})
    rmd = _readmetadata(handle, data_product, component)
    dp_entry = _finddataproduct(handle.registry, rmd.namespace,
                                rmd.data_product, rmd.version)
    obj_url = dp_entry["object"]
    component_url = _componenturl(handle.registry, obj_url, rmd.component)
    location = _getstoragelocation(handle.registry, obj_url)

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
    path = _readdataproduct(handle, data_product, component)
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
    entries = handle.config["write"]

    for entry in entries
        if entry["data_product"] == data_product
            use = get(entry, "use", Dict())
            return (entry = entry,
                    name = get(use, "data_product", data_product))
        end
    end

    patterns = [entry
                for entry in entries
                if occursin('*', entry["data_product"]) &&
        occursin(_globregex(entry["data_product"]), data_product)]
    if length(patterns) == 1
        return (entry = only(patterns), name = data_product)
    elseif isempty(patterns)
        throw(ConfigFileException("'$data_product' not found in 'write' - check config file."))
    end
    matched = join(("'$(entry["data_product"])'" for entry in patterns), ", ")
    msg = string("'", data_product, "' matches more than one wildcard in ",
                 "'write' (", matched, ") - check config file.")
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
                        source::Union{Nothing, SourceRecord})
    latest = _latestdataproduct(registry, namespace, data_product)
    isnothing(latest) && return nothing
    object = _getentry(registry, URIs.URI(latest["object"]))
    isnothing(object["storage_location"]) && return nothing
    location = _getstoragelocation(registry, latest["object"])
    location.hash == hash || return nothing
    _recordssource(registry, latest, object, source) || return nothing
    return (path = location.path, version = String(latest["version"]),
            object = String(latest["object"]))
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

# The placeholder in a `write:` name that stands for the code run's uuid, which
# the CLI leaves for the API to fill in at `finalise`
const RUN_ID_PLACEHOLDER = r"\$\{\{\s*RUN_ID\s*\}\}"

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
        held = _unchangedfile(registry, wmd["use_namespace"], use_data_product,
                              hash, source)
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
                       hash::String, source::Union{Nothing, SourceRecord})
    registry = handle.registry
    datastore = handle.config["run_metadata"]["write_data_store"]
    filepath = wmd["path"]
    existing = _getentry(registry, "storage_location",
                         Dict("hash" => hash, "public" => wmd["public"],
                              "storage_root" =>
                                  _extractid(handle.datastore_obj_url)))
    if isnothing(existing)
        # Name the file by its hash
        path = joinpath(datastore, wmd["use_namespace"], wmd["use_dp"],
                        "$hash.$(_extension(filepath))")
        mkpath(dirname(path))
        mv(filepath, path, force = true)
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
    use_namespace = _writenamespace(handle, wmd)
    use_component = get(use, "component", component)
    use_version = use["version"]
    public = get(use, "public", handle.config["run_metadata"]["public"])

    # A data product written to earlier in this code run keeps its file
    paths = unique(value["path"]
                   for (key, value) in handle.outputs if key[1] == data_product)
    if isempty(paths)
        namespace_id = _getid(handle.registry, "namespace",
                              Dict("name" => use_namespace))
        exists = isnothing(namespace_id) ? nothing :
                 _getentry(handle.registry, "data_product",
                           Dict("name" => use_data_product,
                                "version" => use_version,
                                "namespace" => namespace_id))
        if !isnothing(exists)
            msg = string("data product already exists in registry: ",
                         use_data_product,
                         " :-(ns: ", use_namespace, " - v: ", use_version, ")")
            throw(ReadWriteException(msg))
        end
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
                "dataproduct_description" => wmd["description"],
                "component_description" => description)
end

"""
    _writekeyval(handle, data, data_product, component, description)

Write `data` as the table `component` of a TOML data product, record the
output in the handle and return its metadata.
"""
function _writekeyval(handle::DataRegistryHandle, data::Dict,
                      data_product::String,
                      component::String, description::String)
    metadata = _resolvewrite(handle, data_product, component, "toml",
                             description)
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
    root = replace(storage_root_entry["root"], "file://" => "")
    return (path = joinpath(root, storage_loc_entry["path"]),
            hash = String(storage_loc_entry["hash"]))
end

"""
    _globregex(pattern)

Return the anchored regular expression for a data product name pattern, in
which each `*` matches one segment of the name (one or more characters other
than `/`) and every other character is literal.
"""
function _globregex(pattern::AbstractString)
    occursin('*', pattern) ||
        throw(ArgumentError("a pattern needs at least one *: $pattern"))
    literal(s) = replace(s, r"([\\^\$.|?+()\[\]{}])" => s"\\\1")
    return Regex("^" * join(map(literal, split(pattern, '*')), "[^/]+") * "\$")
end

"""
    _matchingreads(handle, pattern)

Return the names of the `read:` data products of the working config that
match a pattern, sorted; throw if there is none.
"""
function _matchingreads(handle::DataRegistryHandle, pattern::AbstractString)
    regex = _globregex(pattern)
    names = sort!([String(entry["data_product"])
                   for entry in get(handle.config, "read", [])
                   if occursin(regex, entry["data_product"])])
    isempty(names) &&
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
function _issuecomponents(handle::DataRegistryHandle, ::CodeRepository)
    return [_wholeobjectcomponent(handle.registry, handle.repo_obj)]
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
        existing = ExistingDataProduct(rmd.namespace, rmd.data_product,
                                       rmd.version,
                                       component = target.component)
        return _issuecomponents(handle, existing)
    end
    return throw(ReadWriteException("$(target.data_product) was not read or written in this code run"))
end
function _issuecomponents(handle::DataRegistryHandle,
                          target::ExistingDataProduct)
    dp_entry = _finddataproduct(handle.registry, target.namespace,
                                target.data_product, target.version)
    return [_componenturl(handle.registry, dp_entry["object"],
                          target.component)]
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
        entry = _postissue(handle.registry, issue.severity, issue.description,
                           components)
        println("issue registered as ", entry["url"])
    end
    return nothing
end
