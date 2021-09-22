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
    register_object(path, hash, description, root_uri, public)

Register object in local registry and return the URL of the entry.
"""
function register_object(path::String, hash::String, description::String, root_uri::String; public::Bool=true)
   # Register storage location
   storage_loc_query = Dict("path" => path, "hash" => hash, "public" => public, "storage_root" => root_uri)
   storage_loc_uri = DataPipeline.http_post_data("storage_location", storage_loc_query)

   # Get author URL
   authors_url = DataPipeline.get_author_url()

   # Register object
   object_query = Dict("description" => description, "storage_location" => storage_loc_uri, "authors" => [authors_url])
   object_url = DataPipeline.http_post_data("object", object_query)

   return object_url
end

"""
    register_object(path, hash, description, root_uri, file_type, public)

Register object in local registry and return the URL of the entry.
"""
function register_object(path::String, hash::String, description::String, root_uri::String, file_type::String; public::Bool=true)
   # Register storage location
   storage_loc_query = Dict("path" => path, "hash" => hash, "public" => public, "storage_root" => root_uri)
   storage_loc_uri = DataPipeline.http_post_data("storage_location", storage_loc_query)

   # Get author URL
   authors_url = DataPipeline.get_author_url()

   # Register / get file_type entry
   file_type_url = DataPipeline.get_url("file_type", Dict("extension" => file_type))
   ft_query = Dict("name" => file_type, "extension" => file_type)
   if isnothing(file_type_url)
      file_type_url = http_post_data("file_type", ft_query)
   end

   # Register object
   object_query = Dict("description" => description, "storage_location" => storage_loc_uri, "authors" => [authors_url], "file_type" => file_type_url)
   object_url = http_post_data("object", object_query)

   return object_url
end

"""
    patch_code_run(handle, inputs, outputs)

Register code run
"""
function patch_code_run(handle::DataRegistryHandle, inputs, outputs)
   coderun_url = handle.code_run_obj
   token = get_access_token()
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
    get_author_url()

Get author url
"""
function get_author_url()
   users_id = DataPipeline.get_id("users", Dict("username" => "admin"))
   user_author_url = DataPipeline.get_url("user_author", Dict("user" => users_id))
   author_entry = DataPipeline.http_get_json(user_author_url)
   author_url = author_entry["author"]
   return author_url
end

## read dp and return sl - for internal use
function read_data_product(handle::DataRegistryHandle, data_product::String, component::String)
   # Get metadata
   rmd = DataPipeline.get_dp_metadata(handle, data_product, "read")
   use_data_product = get(rmd["use"], "data_product", data_product)
   use_component = get(rmd["use"], "component", component)
   use_namespace = get(rmd["use"], "namespace", handle.config["run_metadata"]["default_input_namespace"])
   use_version = rmd["use"]["version"]
   
   # Is the data product already in the registry?
   namespace_id = get_id("namespace", Dict("name" => use_namespace))
   dp_entry = DataPipeline.get_entry("data_product", Dict("name" => use_data_product, "namespace" => namespace_id, "version" => use_version))

   if isnothing(dp_entry)
      # If the data product isn't in the registry, throw an error
      msg = string("no data products found matching: ", use_data_product, " :-(ns: ", use_namespace, " - v: ", use_version, ")")
      throw(ReadWriteException(msg))
   else 
      # Get object entry
      obj_url = dp_entry["object"]
      obj_id = extract_id(obj_url)
      component_url = get_url("object_component", Dict("name" => use_component, "object" => obj_id))
      println("data product found: ", use_data_product, " (url: ", obj_url, ")")
      
      # Get storage location
      path = DataPipeline.get_storage_loc(obj_url)
      
      # Add metadata to handle
      metadata = Dict("use_dp" => use_data_product, "use_namespace" => use_namespace, "use_version" => use_version, "component_url" => component_url)
      handle.inputs[data_product] = metadata

      return path
   end
end

function read_toml(handle::DataRegistryHandle, data_product::String, component)
   ## 1. API call to LDR
   tmp = read_data_product(handle, data_product, component)
   ## 2. read estimate from TOML file and return
   output = TOML.parsefile(tmp)
   isnothing(component) && (return output)
   return output[component]
end

function get_dp_metadata(handle::DataRegistryHandle, data_product::String, section::String)
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
    register_data_product(handle, data_product)

Register data product (from `link_write()`)
"""
function register_data_product(handle::DataRegistryHandle, data_product::String)
   # Get metadata
   wmd = handle.outputs[data_product]
   storage_root_uri = handle.write_data_store
   datastore = handle.config["run_metadata"]["write_data_store"]
   use_data_product = wmd["use_dp"]
   use_component = get(wmd, "use_component", nothing)
   use_namespace = wmd["use_namespace"]
   use_version = wmd["use_version"]
   filepath = wmd["path"]

   # Get hash
   hash = DataPipeline.get_file_hash(filepath)
   
   # Is the data product already in the registry?
   namespace_id = DataPipeline.get_id("namespace", Dict("name" => use_namespace))
   dp_entry = DataPipeline.get_entry("data_product", Dict("name" => use_data_product, "namespace" => namespace_id, "version" => use_version))
   
   exists = !ismissing(dp_entry)
   
   # Rename file
   oldname = split.(basename(filepath), ".")[1]
   new_filepath = replace(filepath, oldname => hash)
   isfile(filepath) ? mv(filepath, new_filepath, force = true) : nothing
   new_path = replace(new_filepath, datastore => "")

   # Get file type
   file_type = String(split.(new_path, ".")[2])

   # Register Object
   obj_url = DataPipeline.register_object(new_path, hash, wmd["description"], storage_root_uri, file_type, public=wmd["public"])
   
   # Register DataProduct
   ns_url = DataPipeline.get_url("namespace", Dict("name" => use_namespace))
   body = Dict("namespace" => ns_url, "name" => use_data_product, "object" => obj_url, "version" => use_version)
   resp = DataPipeline.http_post_data("data_product", body)
   
   if isnothing(use_component)
      obj_entry = DataPipeline.http_get_json(obj_url)
      component_url = obj_entry["components"]
      @assert length(component_url) == 1
      component_url = component_url[1]
   else
      component_query = Dict("object" => obj_url, "name" => use_component)
      component_url = DataPipeline.http_post_data("object_component", component_query)
   end

   return component_url

     # else  ## check hash and throw error if different
   #    url = resp["results"][1]["url"]
   #    obj_url = resp["results"][1]["object"]
   #    resp = http_get_json(obj_url)
   #    resp = http_get_json(resp["storage_location"])
   #    if hash == resp["hash"]
   #       println("nb. data product already registered as ", url)
   #       # add_object_component!(handle.outputs, obj_url)
   #       return url
   #    else
   #       println("HASH: ", hash, " vs:\n", resp)
   #       msg = string("a different data product is already registered to that namespace and version: ", url)
   #       throw(ReadWriteException(msg))
   #    end
   # end
end

"""
    resolve_write(handle, data_product, component, file_type)

Registers a file-based data product based on information provided in the working config file, e.g. for writing external objects.
"""
function resolve_write(handle::DataRegistryHandle, data_product::String, component::String, file_type::String)
   # Get metadata
   wmd = DataPipeline.get_dp_metadata(handle, data_product, "write")
   data_store = handle.config["run_metadata"]["write_data_store"]
   use_namespace = get(wmd["use"], "namespace", handle.config["run_metadata"]["default_output_namespace"])
   use_data_product = get(wmd["use"], "data_product", data_product)
   use_component = get(wmd["use"], "component", component)
   use_version = wmd["use"]["version"]
   public = get(wmd["use"], "public", handle.config["run_metadata"]["public"])
   description = wmd["description"]

   # Create directory
   directory = joinpath(data_store, use_namespace, use_data_product)
   mkpath(directory)

   # Create storage location
   filename = "xxxxxxxxxx.$file_type"
   path = joinpath(directory, filename)

   # Add metadata to handle
   metadata = Dict("use_dp" => use_data_product, "use_component" => use_component, "use_namespace" => use_namespace, "use_version" => use_version, "path" => path, "public" => public, "description" => description)
   handle.outputs[data_product] = metadata

   return path
end

"""
    write_keyval(handle, data, data_product, component)

Write key val (i.e. Dict) - internal
""" 
function write_keyval(handle::DataRegistryHandle, data::Dict, data_product::String, component::String)
   # Get storage location and write to metadata to handle
   path = resolve_write(handle, data_product, component, "toml")
   
   # Write data to TOML
   open(path, "w") do io
      TOML.print(io, data)
   end      
   
   return nothing
end

## get object associated with entity
function get_object_components(url::String)
   resp = http_get_json(url)
   haskey(resp, "whole_object") && (return [url])
   if haskey(resp, "object")
      resp = http_get_json(resp["object"])
      return resp["components"]
   else
      return resp["components"]
   end
end



## get object_component
# function add_object_component!(array::Array, obj_url::String, post_component::Bool, component=nothing)
#     # Post component to registry
#     if post_component && !isnothing(component)  # post component
#         body = (object=obj_url, name=component)
#         rc = http_post_data("object_component", body)
#     end
#     # Get object entry
#     resp = DataPipeline.http_get_json(obj_url)  # object
#     # Get component entry
#     for i in length(resp["components"])         # all components
#         if !post_component && !isnothing(component)
#             rc = http_get_json(resp["components"][i])
#             # println("TESTING: ", rc["name"], " VS. ", component)
#             rc["name"] == component && push!(array, resp["components"][i])
#         else
#             push!(array, resp["components"][i])
#         end
#     end
# end

## get storage location
function get_storage_loc(obj_url)
   obj_entry = http_get_json(obj_url)
   storage_loc_entry = http_get_json(obj_entry["storage_location"])
   storage_loc_path = storage_loc_entry["path"]
   storage_root_url = storage_loc_entry["storage_root"]
   storage_root_entry = http_get_json(storage_root_url)    
   storage_root = storage_root_entry["root"]
   root = replace(storage_root, "file://" => "")
   path = joinpath(root, storage_loc_path)
   return path
end