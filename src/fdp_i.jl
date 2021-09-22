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

## produced by initialise
# NB. add code run id
struct DataRegistryHandle
   config::Dict            # working config file data
   config_obj::String      # config file object id
   script_obj::String      # submission script object file id
   repo_obj::String        # code repo object file id (optional)
   write_data_store::String          
   # user_id               # [local registry] user_id
   code_run_obj::String
   inputs::Dict
   outputs::Dict
end
# - NB. FAIR RUN [server] gets called by user using CI tool

##
struct ReadWriteException <: Exception
   msg::String
end

##
struct ConfigFileException <: Exception
   msg::String
end

"""
    register_storage_root()

Register storage root
"""
function register_storage_root(path_root::String, is_local::Bool)
   body = Dict("root"=>path_root, "local"=>is_local)
   resp = http_post_data("storage_root", body)
   return resp["url"]
end

"""
    search_storage_root()

Check storage location
"""
function search_storage_root(path::String, is_local::Bool)
    search_url = string(API_ROOT, "storage_root/?root=", HTTP.escapeuri(path), "&local=", is_local)
    return http_get_json(search_url)
end

"""
    get_local_sroot()

Return default SR URI
"""
function get_local_sroot(path::String) #, handle::DataRegistryHandle
   file_path = string(FILE_SR_STEM, path)
   resp = search_storage_root(file_path, true)
   if resp["count"]==0  # add
      return register_storage_root(file_path, true)
   else                 # retrieve
      return resp["results"][1]["url"]
   end
end

"""
    get_storage_location()

Register/retrieve storage location and return uri
"""
function get_storage_location(path::String, hash::String, root_id::String, public::Bool)
   # resp = search_storage_location(path, hash, root_id)
   resp = search_storage_location(hash, root_id, public)
   if resp["count"]==0  # add SL
      body = Dict("path"=>path, "hash"=>hash, "storage_root"=>root_id, "public"=>public)
      resp = http_post_data("storage_location", body)
      return resp["url"]
   else                 # SL already registered:
      # path == resp["results"][1]["path"] || println("NB. duplicate data product - original path: ", path)
      return resp["results"][1]["url"]
   end
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


## replacement for fetch_data_per_yaml
## 1. download data/metadata from RDR and register: sources
# fdp pull config_file
## 2. read [user] config_file and generate working config .yaml
# fdp run config_file
## 3. initialise:
"""
    initialise(config_file, submission_script)

Read [working] config.yaml file. Returns a `DataRegistryHandle` containing:
- the working config.yaml file contents
- the object id for this file
- the object id for the submission script file
"""
function initialise(config_file::String, submission_script::String)
   # Read working config file
   print("processing config file: ", config_file)
   config = YAML.load_file(config_file)

   # Register datastore 
   datastore = config["run_metadata"]["write_data_store"]
   register_path = "file://$datastore"
   storage_root_query = Dict("root" => register_path, "local" => true)
   storage_root_uri = DataPipeline.http_post_data("storage_root", storage_root_query)
   
   # Register config file
   config_hash = DataPipeline.get_file_hash(config_file)
   config_obj_uri = DataPipeline.register_object(config_file, config_hash, "Working config file.", storage_root_uri, "yaml")
   
   # Register submission script   
   script_hash = DataPipeline.get_file_hash(submission_script)
   script_obj_uri = DataPipeline.register_object(submission_script, script_hash, "Submission script (Julia.)", storage_root_uri, "sh")

   # Register remote repository
   remote_repo = config["run_metadata"]["remote_repo"]
   repo_root = match(r"([a-z]*://[a-z]*.[a-z]*/).*", remote_repo)[1]
   remote_repo = replace(remote_repo, repo_root => "")
   repo_root_query = Dict("root" => repo_root, "local" => false)
   repo_root_uri = DataPipeline.http_post_data("storage_root", repo_root_query)
   latest_commit = config["run_metadata"]["latest_commit"]
   repo_obj_url = DataPipeline.register_object(remote_repo, latest_commit, "Remote code repository.", repo_root_uri, public=false)

   # Register code run
   rt = Dates.now()
   rt = Dates.format(rt, "yyyy-mm-dd HH:MM:SS")
   coderun_description = config["run_metadata"]["description"]
   body = Dict("run_date" => rt, "description" => coderun_description, "code_repo" => repo_obj_url, "model_config" => config_obj_uri, 
   "submission_script" => script_obj_uri)

   coderun_url = DataPipeline.http_post_data("code_run", body)

   println(" - pipeline initialised.")
   
   # Write to handle
   return DataRegistryHandle(config, config_obj_uri, script_obj_uri, repo_obj_url, storage_root_uri, coderun_url, Dict(), Dict())
end

"""
    finalise(handle)

Complete (i.e. finish) code run.
"""
function finalise(handle::DataRegistryHandle)

   # Register inputs
   inputs = Vector{String}()
   for (key, value) in handle.inputs
      dp_url = handle.inputs[key]["component_url"]
      dp_url = isa(dp_url, Vector) ? dp_url[1] : dp_url
      push!(inputs, dp_url)
   end
   
   # Register outputs
   outputs = Vector{String}()
   for (key, value) in handle.outputs
      dp_url = DataPipeline.register_data_product(handle, key)
      push!(outputs, dp_url)
   end
   
   # Register code run
   url = DataPipeline.patch_code_run(handle, inputs, outputs)
   println("finished - code run locally registered as: ", url, "\n")
   #output = (code_run=url, config_obj=handle.config_obj, script_obj=handle.script_obj)
   #isnothing(handle.repo_obj) && (return output)
   #return (; output..., repo_obj=handle.repo_obj)
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

## return path of data product
"""
    link_read(handle, data_product)

Returns the file path of a data product that has been registered in the local data registry, either directly or via the CLI.
"""
function link_read(handle::DataRegistryHandle, data_product::String)
   # Get metadata
   rmd = get_dp_metadata(handle, data_product, "read")
   use_data_product = get(rmd["use"], "data_product", data_product)
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
      println("data product found: ", use_data_product, " (url: ", dp_entry["url"], ")")
       
      # Get component url 
      object_entry = DataPipeline.http_get_json(obj_url)
      component_url = object_entry["components"]
      @assert length(component_url) == 1

      # Get storage location
      sl = get_storage_loc(obj_url)
      root = replace(sl.sr_root, "file://" => "")
      path = joinpath(root, sl.sl_path)
      
      # Add metadata to handle
      metadata = Dict("use_dp" => use_data_product, "use_namespace" => use_namespace, "use_version" => use_version, "component_url" => component_url)
      handle.inputs[data_product] = metadata
      
      # Return storage location
      return path
   end
end
#- If the alias is already recorded in the handle, returns the path. If not, find the location of the file referenced by its alias.

## add alias?
"""
    read_array(handle, data_product, [component])

Read [array] data product.
- note that it must already have been downloaded from the remote data store using `fdp pull`.
- the latest version of the data is read unless otherwise specified.
"""
function read_array(handle::DataRegistryHandle, data_product::String, component=nothing)
   ## 1. API call to LDR
   tmp = DataPipeline.read_data_product(handle, data_product, component)
   # println("RDP: ", tmp)
   ## 2. read array from file -> process
   output = process_h5_file(tmp, false, C_DEBUG_MODE)
   return output
end

## add alias?
"""
    read_table(handle, data_product; component, version)

Read [table] data product.
- note that it must already have been downloaded from the remote data store using `fdp pull`.
- the latest version of the data is read unless otherwise specified.
"""
function read_table(handle::DataRegistryHandle, data_product::String, component=nothing)
   ## 1. API call to LDR
   tmp = read_data_product(handle, data_product, component)
   ## 2. read array from file -> process
   output = CSV.read(tmp, DataFrames.DataFrame)
   return output
end
# read_h5_table

## read TOML - internal use
function read_toml(handle::DataRegistryHandle, data_product::String, component)
   ## 1. API call to LDR
   tmp = read_data_product(handle, data_product, component)
   ## 2. read estimate from TOML file and return
   output = TOML.parsefile(tmp)
   isnothing(component) && (return output)
   return output[component]
end

## wrapper
"""
    read_estimate(handle, data_product, [component])

Read TOML-based data product.
- note that it must already have been downloaded from the remote data store using `fdp pull`.
- the specific version can be specified in the config file (else the latest version is used.)
"""
function read_estimate(handle::DataRegistryHandle, data_product::String, component=nothing)
   output = read_toml(handle, data_product, component)
   isnothing(component) && (return output)
   return output["value"]
end

## wrapper
"""
   read_distribution(handle, data_product, [component])

Read TOML-based data product.
- note that it must already have been downloaded from the remote data store using `fdp pull`.
- the specific version can be specified in the config file (else the latest version is used.)
"""
function read_distribution(handle::DataRegistryHandle, data_product::String, component=nothing)
   return read_toml(handle, data_product, component)
end

## helper for retrieving info from config
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

## register [generic] data product
# NB. need to add outputs to handle prior to this point ***
function register_data_product(handle::DataRegistryHandle, data_product::String)#, component::String) 
   # Get metadata
   wmd = handle.outputs[data_product]
   storage_root_uri = handle.write_data_store
   datastore = handle.config["run_metadata"]["write_data_store"]
   use_data_product = wmd["use_dp"]
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
   
   obj_entry = DataPipeline.http_get_json(obj_url)
   component_url = obj_entry["components"]
   @assert length(component_url) == 1

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

##
"""
   link_write(handle, filepath, data_product)

Registers a file-based data product based on information provided in the working config file, e.g. for writing external objects.
"""
function link_write(handle::DataRegistryHandle, data_product::String)
   # Get metadata
   wmd = DataPipeline.get_dp_metadata(handle, data_product, "write")
   data_store = handle.config["run_metadata"]["write_data_store"]
   use_namespace = get(wmd["use"], "namespace", handle.config["run_metadata"]["default_output_namespace"])
   use_data_product = get(wmd["use"], "data_product", data_product)
   use_version = wmd["use"]["version"]
   public = get(wmd["use"], "public", handle.config["run_metadata"]["public"])
   filetype = wmd["file_type"]
   description = wmd["description"]

   # Create storage location
   filename = "xxxxxxxxxx.$filetype"
   directory = joinpath(data_store, use_namespace, use_data_product)

   # Create directory
   mkpath(directory)
   path = joinpath(directory, filename)

   # Add metadata to handle
   metadata = Dict("use_dp" => use_data_product, "use_namespace" => use_namespace, "use_version" => use_version, "path" => path, "public" => public, "description" => description)
   handle.outputs[data_product] = metadata

   # Return path
   return path
end

"""
    write_array(handle, data, data_product, component; public)

Write an array as a component to an hdf5 file.
"""
function write_array(handle::DataRegistryHandle, data::Array, data_product::String, component::String; public::Bool=true)
   # Get metadata
   wmd = DataPipeline.get_dp_metadata(handle, data_product, "write")
   data_store = handle.config["run_metadata"]["write_data_store"]
   use_namespace = get(wmd["use"], "namespace", handle.config["run_metadata"]["default_output_namespace"])
   use_data_product = get(wmd["use"], "data_product", data_product)
   use_component = get(wmd["use"], "component", component)
   use_version = wmd["use"]["version"]
   public = get(wmd["use"], "public", handle.config["run_metadata"]["public"])
   description = wmd["description"]

   # Create storage location
   filename = "xxxxxxxxxx.h5"
   directory = joinpath(data_store, use_namespace, use_data_product)

   # Create directory
   mkpath(directory)
   path = joinpath(directory, filename)

   # Write array
   fid = HDF5.h5open(path, "w")
   fid[component] = data
   HDF5.close(fid)         

   # Add metadata to handle
   metadata = Dict("use_dp" => use_data_product, "use_component" => use_component, "use_namespace" => use_namespace, "use_version" => use_version, "path" => path, "public" => public, "description" => description)
   handle.outputs[data_product] = metadata
    
   return nothing
end

"""
    write_table(handle, table, data_product)

Write a Tables.jl interface input (https://github.com/JuliaData/Tables.jl) to file (and register a corresonding data product in the local Data Registry.)

"""
function write_table(handle::DataRegistryHandle, table, data_product::String; public::Bool=true)
   temp_fp = tempname()
   ## write to CSV file
   CSV.write(temp_fp, table)
   return register_data_product(handle, data_product, temp_fp, public, nothing)
   ## 1. API call to LDR (retrieve metadata)
   ## 2. register dp (possibly)
   # 3. register component (definitely)
end

## write key val (i.e. Dict) - internal
function write_keyval(handle::DataRegistryHandle, data::Dict, data_product::String, component::String, public::Bool)
   temp_fp = tempname()       # write to TOML
   open(temp_fp, "w") do io
      TOML.print(io, data)
   end                        # register data product
   return register_data_product(handle, data_product, temp_fp, public, component)
end

## write point estimate
"""
    write_estimate(handle, value, data_product, component)

Write point estimate to file (and register a corresonding data product in the local Data Registry.)

"""
function write_estimate(handle::DataRegistryHandle, value, data_product::String, component::String; public::Bool=true)
   data = Dict(component => Dict{String,Any}("value"=>value,"type"=>"point-estimate"))
   return write_keyval(handle, data, data_product, component, public)
end

## write distribution
"""
    write_distribution(handle, distribution, parameters, data_product, component)

Write specification of a statistical distribution to file (and register a corresonding data product in the local Data Registry.)

"""
function write_distribution(handle::DataRegistryHandle, distribution::String, parameters, data_product::String, component::String; public::Bool=true)
   data = Dict(component => Dict{String,Any}("distribution"=>distribution, "parameters"=>parameters, "type"=>"distribution"))
   return write_keyval(handle, data, data_product, component, public)
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

## register issue with data product; component; externalobject; or script
"""
    raise_issue(handle; ... )

Register issue with data product; component; external object; or script.

Pass the object URI as a named parameter[s], e.g. `raise_issue(handle; data_product=dp, component=comp)`.

**Optional parameters**
- `data_product`
- `component`
- `external_object`
- `script`
"""
function raise_issue(handle::DataRegistryHandle, url::String, description::String, severity=0)#data_product=nothing, component=nothing, external_object=nothing, script=nothing
   ## 1. API call to LDR (retrieve metadata)
   c = get_object_components(url)
   # println(c)
   ## 2. register issue to LDR
   body = (severity=severity, description=description, component_issues=c)
   resp = http_post_data("issue", body)
   println("nb. issue registered as ", resp["url"])
   return resp["url"]
end
