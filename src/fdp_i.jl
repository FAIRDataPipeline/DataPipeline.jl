# SPDX-License-Identifier: LGPL-3.0-or-later

# The registry side of the API: registering objects, data products and issues,
# and resolving the entries of the working config against the registry.

"""
    ReadWriteException(msg)

Thrown when the registry or the data store does not hold what a read or write
needs: a missing data product, a version already registered, a registry that
is not running.
"""
struct ReadWriteException <: Exception
    msg::String
end

"""
    ConfigFileException(msg)

Thrown when the working config lacks the section or entry a call refers to.
"""
struct ConfigFileException <: Exception
    msg::String
end

# == Functions ==

# The extension of a file name, the part after its last dot
_extension(path::AbstractString) = String(match(r"([^.]+)$", basename(path))[1])

"""
    _registerobject(registry, path, root, description;
                    hash, local_root, public, file_type)

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
"""
function _registerobject(registry::RegistryEndpoint, path::String,
                         root::String, description::String;
                         hash::String = _getfilehash(joinpath(root, path)),
                         local_root::Bool = true, public::Bool = true,
                         file_type::Union{Nothing, String} = _extension(path),
                         new_object::Bool = false)
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
                                     "authors" => [_getauthorurl(registry)])
    if !isnothing(file_type)
        # Extensions are unique, so match on that alone: another API may have
        # registered this one under a different name
        file_type_url = _geturl(registry, "file_type",
                                Dict("extension" => file_type))
        if isnothing(file_type_url)
            file_type_url = _postentry(registry, "file_type",
                                       Dict("name" => file_type,
                                            "extension" => file_type))["url"]
        end
        object_query["file_type"] = file_type_url
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
working config, or throw a [`ConfigFileException`](@ref).
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
`\${{RUN_ID}}` in its registered name; move its file to its hash name, or, if
the same bytes are already in the store, delete it and point at them; register
the object and the data product, once per data product however many
components it has; and register the component (the `whole_object` component
when `component` is `nothing`). Record the registered name, the object URL and
the component URL in the handle and return the component URL.
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
    use_namespace = wmd["use_namespace"]
    use_version = wmd["use_version"]
    filepath = wmd["path"]

    # Another component of the same data product may have registered its file
    # and object already
    registered = [value
                  for (key, value) in handle.outputs
                  if key[1] == data_product && haskey(value, "object_url")]
    if !isempty(registered)
        new_filepath = registered[1]["path"]
        obj_url = registered[1]["object_url"]
    else
        if !isfile(filepath)
            msg = string("File not found: ", use_data_product,
                         " is present in handle but not in data store.")
            throw(ReadWriteException(msg))
        end
        hash = _getfilehash(filepath)
        existing = _getentry(registry, "storage_location",
                             Dict("hash" => hash, "public" => wmd["public"],
                                  "storage_root" =>
                                      _extractid(handle.datastore_obj_url)))
        if isnothing(existing)
            # Name the file by its hash
            new_filepath = joinpath(datastore, use_namespace, use_data_product,
                                    "$hash.$(_extension(filepath))")
            mkpath(dirname(new_filepath))
            mv(filepath, new_filepath, force = true)
        else
            # The same bytes are already in the store: point at them and drop
            # the duplicate
            new_filepath = joinpath(datastore, existing["path"])
            rm(filepath)
        end
        _pruneempty(dirname(filepath), datastore)

        obj_url = _registerobject(registry, new_filepath, datastore,
                                  wmd["dataproduct_description"], hash = hash,
                                  public = wmd["public"],
                                  new_object = true)["url"]
        ns_url = _postentry(registry, "namespace",
                            Dict("name" => use_namespace))["url"]
        _postentry(registry, "data_product",
                   Dict("namespace" => ns_url, "name" => use_data_product,
                        "object" => obj_url, "version" => use_version))
    end
    wmd["path"] = new_filepath
    wmd["object_url"] = obj_url

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

"""
    _resolvewrite(handle, data_product, component, file_type, description)

Return the metadata for writing `component` (`nothing` for a whole file) of a
`write:` data product of the working config: where its file goes (a new
temporary file, or the file another component of the same data product
already started in this code run) and the names it will be registered under.
"""
function _resolvewrite(handle::DataRegistryHandle, data_product::String,
                       component::Union{Nothing, String},
                       file_type::String, description::Union{Nothing, String})
    wmd = _getmetadata(handle, data_product, "write")
    use = get(wmd, "use", Dict())
    data_store = handle.config["run_metadata"]["write_data_store"]
    default_namespace = handle.config["run_metadata"]["default_output_namespace"]
    use_namespace = get(use, "namespace", default_namespace)
    use_data_product = get(use, "data_product", data_product)
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
    for table in (handle.inputs, handle.outputs)
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
        entry = _postentry(handle.registry, "issue",
                           Dict("severity" => issue.severity,
                                "description" => issue.description,
                                "component_issues" => components))
        println("issue registered as ", entry["url"])
    end
    return nothing
end
