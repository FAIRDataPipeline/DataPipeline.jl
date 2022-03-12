### new interface for FAIR data pipeline ###
# - implements: https://fairdatapipeline.github.io/docs/interface/example0/

## BASELINE FDP FUNCTIONALITY:
# fdp pull config.yaml
# fdp run config.yaml
# fdp push config.yaml
## NB. 'fdp' -> FAIR

## LOCAL DR INSTRUCTIONS:
# - start using: ~/.fair/registry/scripts/start_fair_registry
# - stop using: ~/.fair/registry/scripts/stop_fair_registry
# - view tcp using: sudo netstat -ntap | grep LISTEN

struct ReadWriteException <: Exception
    msg::String
end

##
struct ConfigFileException <: Exception
    msg::String
end

"""
    _registerobject(path, hash, description, root_uri, file_type[, public])

Register object in local registry and return the URL of the entry.
...
# Arguments
- `path::String`: the full storage path of the file associated with the object.
- `root::String`: the storage root of the file associated with the object.
- `description::String`: the object description.
- `public::Bool=true`: (optional) public flag denoting whether the storage location is  
  public (`true`) or not (`false`).
...
"""
function _registerobject(path::String, root::String, description::String; 
                         public::Bool=true)

    full_path = joinpath(root, path)
    hash = _getfilehash(full_path)

    # Register storage root 
    storage_root_query = Dict("root" => root, "local" => true)
    root_uri = _postentry("storage_root", storage_root_query)

    # Does a storage location already exist with the same `root`, `hash`, `public`?
    storage_root_id = _extractid(root_uri)
    script_exists = _geturl("storage_location", Dict("hash" => hash, 
                            "public" => true, "storage_root" => storage_root_id))
    
    # If it doesn't, then register storage location
    if isnothing(script_exists)    
        storage_loc = replace(path, root => s"")
        storage_loc_query = Dict("path" => storage_loc, "hash" => hash, "public" => public, 
                                 "storage_root" => root_uri)
        storage_loc_uri = _postentry("storage_location", storage_loc_query)
    else
        storage_loc_uri = script_exists
    end

    # Get author URL
    authors_url = _getauthorurl()

    # Register / get file_type entry
    file_type = match(r"([^.]+)$", path)[1]
    file_type_url = _geturl("file_type", Dict("extension" => file_type))
    ft_query = Dict("name" => file_type, "extension" => file_type)
    if isnothing(file_type_url)
        file_type_url = _postentry("file_type", ft_query)
    end

    # Register object
    object_query = Dict("description" => description, "storage_location" => storage_loc_uri, 
                        "authors" => [authors_url], "file_type" => file_type_url)
    object_url = _postentry("object", object_query)

    return object_url
end

"""
    _registerrepo(path, hash, description, root_uri, file_type[, public])

Register object in local registry and return the URL of the entry.
...
# Arguments
- `path::String`: the full storage path of the file associated with the object.
- `root::String`: the storage root of the file associated with the object.
- `description::String`: the object description.
- `hash::String`: most recent commit.
- `public::Bool=true`: (optional) public flag denoting whether the storage location is  
  public (`true`) or not (`false`).
...
"""
function _registerrepo(path::String, root::String, description::String, hash::String, 
                       public::Bool=true)

    # Register storage root 
    storage_root_query = Dict("root" => root, "local" => false)
    root_uri = _postentry("storage_root", storage_root_query)

    # Does a storage location already exist with the same `root`, `hash`, `public`?
    storage_root_id = _extractid(root_uri)
    script_exists = _geturl("storage_location", Dict("hash" => hash, 
                            "public" => true, "storage_root" => storage_root_id))
    
    # If it doesn't, then register storage location
    if isnothing(script_exists)    
        storage_loc = replace(path, root => s"")
        storage_loc_query = Dict("path" => storage_loc, "hash" => hash, "public" => public, 
                                 "storage_root" => root_uri)
        storage_loc_uri = _postentry("storage_location", storage_loc_query)
    else
        storage_loc_uri = script_exists
    end

    # Get author URL
    authors_url = _getauthorurl()

    # Register / get file_type entry
    file_type = match(r"([^.]+)$", path)[1]
    file_type_url = _geturl("file_type", Dict("extension" => file_type))
    ft_query = Dict("name" => file_type, "extension" => file_type)
    if isnothing(file_type_url)
        file_type_url = _postentry("file_type", ft_query)
    end

    # Register object
    object_query = Dict("description" => description, "storage_location" => storage_loc_uri, 
                        "authors" => [authors_url], "file_type" => file_type_url)
    object_url = _postentry("object", object_query)

    return object_url
end

"""
    _patchcoderun(handle, inputs, outputs)

Register code run
"""
function _patchcoderun(handle::DataRegistryHandle, inputs, outputs)
    coderun_url = handle.code_run_obj
    token = _gettoken()
    headers = Dict("Authorization" => token, "Content-Type" => "application/json")
    data = Dict("inputs" => inputs, "outputs" => outputs)
    body = JSON.json(data)
  
    r = HTTP.request("PATCH", coderun_url, headers=headers, body=body)
    resp = String(r.body)
    json_resp = JSON.parse(resp)
    entry_url = json_resp["url"]
   
    return entry_url
end

"""
    _getauthorurl()

Get author url
"""
function _getauthorurl()
    users_id = _getid("users", Dict("username" => "admin"))
    user_author_url = _geturl("user_author", Dict("user" => users_id))
    author_entry = _getentry(URIs.URI(user_author_url))
    author_url = author_entry["author"]
    return author_url
end

"""
    _readdataproduct(handle, data_product, component)

Get data product path
"""
function _readdataproduct(handle::DataRegistryHandle, data_product::String, 
                          component::String)
    # Get metadata
    rmd = _getmetadata(handle, data_product, "read")
    use_data_product = get(rmd["use"], "data_product", data_product)
    use_component = get(rmd["use"], "component", component)
    use_namespace = get(rmd["use"], "namespace", 
                        handle.config["run_metadata"]["default_input_namespace"])
    use_version = rmd["use"]["version"]
   
    # Is the data product in the registry?
    namespace_id = _getid("namespace", Dict("name" => use_namespace))
    dp_entry = _getentry("data_product", Dict("name" => use_data_product, 
                                              "namespace" => namespace_id, 
                                              "version" => use_version))

    if isnothing(dp_entry)
        # If the data product isn't in the registry, throw an error
        msg = string("no data products found matching: ", use_data_product, " :-(ns: ", 
                     use_namespace, " - v: ", use_version, ")")
        throw(ReadWriteException(msg))
    else 
        # Get object entry
        obj_url = dp_entry["object"]
        obj_id = _extractid(obj_url)
        component_url = _geturl("object_component", Dict("name" => use_component, 
                                                         "object" => obj_id))
      
        # Get storage location
        path = _getstoragelocation(obj_url)
      
        # Write to handle
        metadata = Dict("use_dp" => use_data_product, "use_namespace" => use_namespace, 
                        "use_version" => use_version, "component_url" => component_url)
        handle.inputs[(data_product, component)] = metadata

        return path
    end
end

"""
    _readtoml(handle, data_product, component)

Read toml file
"""
function _readtoml(handle::DataRegistryHandle, data_product::String, component)
    ## 1. API call to LDR
    tmp = _readdataproduct(handle, data_product, component)
    ## 2. read estimate from TOML file and return
    output = TOML.parsefile(tmp)
    isnothing(component) && (return output)
    return output[component]
end

"""
    _getmetadata(handle, data_product, section)

Get data product metadata
"""
function _getmetadata(handle::DataRegistryHandle, data_product::String, section::String)
    if haskey(handle.config, section)
        wmd = handle.config[section]
        for i in eachindex(wmd)
            if wmd[i]["data_product"] == data_product
                return wmd[i]
            end
        end
        msg = string(data_product, "' not found in '", section, "' - check config file.")
    else
        msg = string("no '", section, "' section found - check config file.")
    end
    throw(ConfigFileException(msg))
end

"""
    _registerdataproduct(handle, data_product)

Register data product (from `link_write()`)
"""
function _registerdataproduct(handle::DataRegistryHandle, data_product::String, 
                              component::Any)
    # Get metadata
    wmd = handle.outputs[(data_product, component)]
    datastore = handle.config["run_metadata"]["write_data_store"]
    use_data_product = wmd["use_dp"]
    use_component = wmd["use_component"]
    use_namespace = wmd["use_namespace"]
    use_version = wmd["use_version"]
    filepath = joinpath(datastore, wmd["path"])
      
    if isfile(filepath)
        # Rename file
        oldname = split.(basename(filepath), ".")[1]
        hash = _getfilehash(filepath)
        new_filepath = replace(filepath, oldname => hash)
        isfile(filepath) ? mv(filepath, new_filepath, force=true) : nothing
    else
        # Is the data product already in the registry?
        namespace_id = _getid("namespace", Dict("name" => use_namespace))
        dp_entry = _getentry("data_product", Dict("name" => use_data_product, 
                                                  "namespace" => namespace_id, 
                                                  "version" => use_version))

        # If file doesn't exist but the data product is listed in the handle, then
        # the user may have forgotten to write the file after !link_write() was called
        if isnothing(dp_entry)
            msg = string("File not found: ", use_data_product, "is present in handle ",
            "but not in data store.")
            throw(ReadWriteException(msg))
        end
        
        obj_entry = DataPipeline._getentry(URIs.URI(dp_entry["object"]))
        location_entry = DataPipeline._getentry(URIs.URI(obj_entry["storage_location"]))
        root_entry = DataPipeline._getentry(URIs.URI(location_entry["storage_root"]))
        root = replace(root_entry["root"], "file://" => "")
        new_filepath = joinpath(root, location_entry["path"])
    end

    # Update handle
    handle.outputs[(data_product, component)]["path"] = new_filepath

    # Register Object
    new_path = replace(new_filepath, datastore => s"")
    obj_url = _registerobject(new_path, 
                              datastore, 
                              wmd["dataproduct_description"], 
                              public = wmd["public"])

    # Register DataProduct
    ns_url = _geturl("namespace", Dict("name" => use_namespace))
    if isnothin(ns_url)
        body = (name = use_namespace)
        ns_url = _postentry("namespace", body)
    body = Dict("namespace" => ns_url, "name" => use_data_product, "object" => obj_url, 
                "version" => use_version)
    resp = _postentry("data_product", body)
   
    # Register Component
    if isnothing(use_component)
        obj_entry = _getentry(URIs.URI(obj_url))
        component_url = obj_entry["components"]
        @assert length(component_url) == 1
        component_url = component_url[1]
    else
        component_query = Dict("object" => obj_url, "name" => use_component)
        component_url = _postentry("object_component", component_query)
    end

    return component_url
end

"""
    _resolvewrite(handle, data_product, component, file_type)

Registers a file-based data product based on information provided in the working config 
file, e.g. for writing external objects.
"""
function _resolvewrite(handle::DataRegistryHandle, data_product::String, component::String, 
                       file_type::String, description::String)
    # Get metadata
    wmd = _getmetadata(handle, data_product, "write")
    data_store = handle.config["run_metadata"]["write_data_store"]
    default_namespace = handle.config["run_metadata"]["default_output_namespace"]
    use_namespace = get(wmd["use"], "namespace", default_namespace)
    use_data_product = get(wmd["use"], "data_product", data_product)
    use_component = get(wmd["use"], "component", component)
    use_version = wmd["use"]["version"]
    public = get(wmd["use"], "public", handle.config["run_metadata"]["public"])
    dp_description = wmd["description"]

    # Check whether this data product has been written to in this Code Run
    # (could be a multi-component object) and return path if so
    path = []
    if length(handle.outputs) != 0
        result = Any[]
        for (key, value) in handle.outputs
            if collect(key)[1] == data_product
                push!(result, value["path"])
            end
        end
        path = unique(result)
        @assert length(path) == 1
        path = path[1]
    end

    # If data product has not been written to in this Code Run, create a new path
    if length(path) == 0

        # Does the data product already exist?
        namespace_id = DataPipeline._getid("namespace", Dict("name" => use_namespace))
        dataproduct_query = Dict("name" => use_data_product, 
                                 "version" => use_version, 
                                 "namespace" => namespace_id)
        exists = DataPipeline._getentry("data_product", dataproduct_query)
        if !isnothing(exists)
            msg = string("data product already exists in registry: ", use_data_product, 
                         " :-(ns: ", use_namespace, " - v: ", use_version, ")")
            throw(ReadWriteException(msg))
        end

        # Create storage location
        filename = _randomhash()
        filename = "dat-$filename.$file_type"

        # Create directory
        directory = joinpath(data_store, use_namespace, use_data_product)
        mkpath(directory)

        path = joinpath(directory, filename)
    end


  

    metadata = Dict("use_dp" => use_data_product, 
                    "use_component" => use_component, 
                    "use_namespace" => use_namespace, 
                    "use_version" => use_version, 
                    "path" => path, 
                    "public" => public, 
                    "dataproduct_description" => dp_description,
                    "component_description" => description)
    
    return metadata
end

"""
    _writekeyval(handle, data, data_product, component)

Write key val (i.e. Dict) - internal
""" 
function _writekeyval(handle::DataRegistryHandle, data::Dict, data_product::String, 
                      component::String, description::String)

    # Get metadata
    metadata = _resolvewrite(handle, data_product, component, "toml", description)
    use_component = metadata["use_component"]
    path = metadata["path"]

    # Does component already exist in toml file?
    if isfile(path)
        output = TOML.parsefile(path)
        if haskey(output, use_component)
            throw("Component already exists in toml file.")
        end
        output[use_component] = data
    else
        output = Dict(use_component => data)
    end
 
    # Write data to TOML
    open(path, "w") do io
        TOML.print(io, output)
    end

    # Write metadata to handle
    handle.outputs[(data_product, component)] = metadata

    return metadata
end

"""
    _getcomponents(url)

get object associated with entity
"""  
function _getcomponents(url::String)
    resp = _getentry(URIs.URI(url))
    haskey(resp, "whole_object") && (return [url])
    if haskey(resp, "object")
        resp = _getentry(URIs.URI(resp["object"]))
    end
    return resp["components"]
end

## get object_component
# function add_object_component!(array::Array, obj_url::String, post_component::Bool, 
#                                component=nothing)
#     # Post component to registry
#     if post_component && !isnothing(component)  # post component
#         body = (object=obj_url, name=component)
#         rc = _postentry("object_component", body)
#     end
#     # Get object entry
#     resp = _getentry(URIs.URI(obj_url))  # object
#     # Get component entry
#     for i in length(resp["components"])         # all components
#         if !post_component && !isnothing(component)
#             rc = _getentry(URIs.URI(resp["components"][i]))
#             # println("TESTING: ", rc["name"], " VS. ", component)
#             rc["name"] == component && push!(array, resp["components"][i])
#         else
#             push!(array, resp["components"][i])
#         end
#     end
# end

"""
    _getstoragelocation(object_url)

Get storage location
""" 
function _getstoragelocation(object_url)
    obj_entry = _getentry(URIs.URI(object_url))
    storage_loc_entry = _getentry(URIs.URI(obj_entry["storage_location"]))
    storage_loc_path = storage_loc_entry["path"]
    storage_root_url = storage_loc_entry["storage_root"]
    storage_root_entry = _getentry(URIs.URI(storage_root_url))
    storage_root = storage_root_entry["root"]
    root = replace(storage_root, s"file://" => s"")
    path = joinpath(root, storage_loc_path)
    return path
end
