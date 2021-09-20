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
   config::Dict         # working config file data
   config_obj::String   # config file object id
   script_obj::String   # submission script object file id
   repo_obj             # code repo object file id (optional)
   write_data_store::String          
   # user_id            # [local registry] user_id
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

## registry query
function registry_query(q::String, vals=nothing)
   db_path = string(homedir(), "/.fair/registry/db.sqlite3")
   db = SQLite.DB(db_path)
   sel_stmt = SQLite.Stmt(db, q)
   if isnothing(vals)
      df = SQLite.DBInterface.execute(sel_stmt, vals) |> DataFrames.DataFrame
   else
      df = SQLite.DBInterface.execute(sel_stmt, vals) |> DataFrames.DataFrame
   end
   return df
end

## registry token
function get_access_token(user_id::Int=1)
   fp = expanduser("~/.fair/registry/token")
   token = open(fp) do file
     read(file, String)
   end
   return string("token ", chomp(token))
end

### upload to data registry
# - NB. what about user ID? Always == 1?
function http_post_data(endpoint::String, data)
   url = string(API_ROOT, endpoint, "/")
   headers = Dict("Authorization" => DataPipeline.get_access_token(), "Content-Type" => "application/json")
   body = JSON.json(data)
   C_DEBUG_MODE && println(" POSTing data to := ", url, ": \n ", body)
   
   try
      r = HTTP.request("POST", url, headers=headers, body=body)
      resp = String(r.body)
      C_DEBUG_MODE && println(" - Response: \n ", resp)
      return JSON.parse(resp)
   catch y
      r = HTTP.get(url)
      return r
   end

end

## register code repo release (i.e. model code)
# - PP per meeting 29/6
# function register_code_repo(name::String, version::String, repo::String,
#    hash::String, scrc_access_tkn::String, description::String,
#    website::String, storage_root_url::String, storage_root_id::String)
#
#    ## UPDATED: check name/version
#    crr_chk = search_code_repo_release(name, version)
#    sl_path = replace(repo, storage_root_url => "")
#    if crr_chk["count"] == 0
#       obj_id = insert_storage_location(sl_path, hash, description, storage_root_id, scrc_access_tkn)
#       ## register release
#       body = (name=name, version=version, object=obj_id, website=website)
#       resp = http_post_data("code_repo_release", body, scrc_access_tkn)
#       println("NB. new code repo release registered. URI := ", resp["url"])
#       return resp["url"]
#    else
#       ## check repo is the same
#       # NB. check SR match?
#       resp = http_get_json(crr_chk["results"][1]["object"])
#       resp = http_get_json(resp["storage_location"])
#       sl_path  == resp["path"] || println("WARNING: repo mismatch detected := ", sl_path, " != ", resp["path"])
#       println("NB. code repo release := ", crr_chk["results"][1]["url"])
#       return crr_chk["results"][1]["url"]
#    end
# end

## register storage root
function register_storage_root(path_root::String, is_local::Bool)
   # il = is_local ? "True" : "False"
   body = Dict("root"=>path_root, "local"=>is_local)
   resp = http_post_data("storage_root", body)
   return resp["url"]
end

## check storage location
function search_storage_root(path::String, is_local::Bool)
    search_url = string(API_ROOT, "storage_root/?root=", HTTP.escapeuri(path), "&local=", is_local)
    return http_get_json(search_url)
end

## return default SR URI
function get_local_sroot(path::String) #, handle::DataRegistryHandle
   file_path = string(FILE_SR_STEM, path)
   resp = search_storage_root(file_path, true)
   if resp["count"]==0  # add
      return register_storage_root(file_path, true)
   else                 # retrieve
      return resp["results"][1]["url"]
   end
end

## register/retrieve storage location and return uri
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

## register and return object uri
# NB. what about authors / filetype?
function register_object(path::String, hash::String, description::String, root_uri::String, public::Bool)
   sl_uri = get_storage_location(path, hash, root_uri, public)
   ## add object
   body = (description=description, storage_location=sl_uri)
   resp = http_post_data("object", body)
   return resp["url"]
end

## called by finalise
function register_code_run(handle::DataRegistryHandle, inputs, outputs)
    rt = Dates.now()
    coderun_description = handle.config["run_metadata"]["description"]

    ## prepare submission
    body = (run_date=rt, description=coderun_description, model_config=handle.config_obj, 
            submission_script=handle.script_obj, inputs=inputs, outputs=outputs)
    if !isnothing(handle.repo_obj)
      # body["code_repo"] = handle.repo_obj
      body = (;body..., code_repo=handle.repo_obj)
    end
    resp = http_post_data("code_run", body)
    return resp["url"]
end

## yaml config ifnull helper
function ifnull_prop(data::Dict, property::String, ifnull::String="default")
   if haskey(data, property)
      return data[property]
   else
      return ifnull
   end
end

## used for submission script
function get_text_file(sst::String)
   temp_fp = tempname()
   ssf = open(temp_fp, "w")
   write(ssf, sst)
   close(ssf)
   return temp_fp
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
   storage_root_uri = get_local_sroot(datastore)

   # Register config file
   config_hash = get_file_hash(config_file)
   config_obj_uri = register_object(config_file, config_hash, "Working config file.", storage_root_uri, true)
   
   # Register submission script   
   script_hash = get_file_hash(submission_script)
   script_obj_uri = register_object(submission_script, script_hash, "Submission script (Julia.)", storage_root_uri, true)
   
   # Register remote repository
   rr = get(config["run_metadata"], "remote_repo", "")
   if length(rr) == 0
      crr_obj_uri = nothing      # TEMP: code_repo[_release]
   else
      rrsr = get_local_sroot(dirname(rr))
      lc = get(config["run_metadata"], "latest_commit", "na")
      crr_obj_uri = register_object(basename(rr), lc, "Remote code repository.", rrsr, true)
   end
   println(" - pipeline initialised.")
   return DataRegistryHandle(config, config_obj_uri, script_obj_uri, crr_obj_uri, storage_root_uri, Dict(), Dict())
end

"""
    finalise(handle)

Complete (i.e. finish) code run.
"""
function finalise(handle::DataRegistryHandle; comments::String="Julia code run.")

   # Register outputs
   inputs = []
   for (key, value) in handle.inputs
      dp_url = handle.inputs[key]["component_url"]
      append!(inputs, dp_url)
   end
   
   # Register outputs
   outputs = []
   for (key, value) in handle.outputs
      dp_url = register_data_product(handle, key)
      append!(outputs, dp_url)
   end
   
   # Register code run
   url = DataPipeline.register_code_run(handle, inputs, outputs)
   println("finished - code run locally registered as: ", url, "\n")
   #output = (code_run=url, config_obj=handle.config_obj, script_obj=handle.script_obj)
   #isnothing(handle.repo_obj) && (return output)
   #return (; output..., repo_obj=handle.repo_obj)
end

## read dp and return sl - for internal use
function read_data_product(handle::DataRegistryHandle, data_product::String, component)
   # Get metadata
   rmd = get_dp_metadata(handle, data_product, "read")
   use_data_product = get(rmd["use"], "data_product", data_product)
   use_namespace = get(rmd["use"], "namespace", handle.config["run_metadata"]["default_input_namespace"])
   use_version = rmd["use"]["version"]
   
   # Is the data product already in the registry?
   resp = search_data_product(use_namespace, use_data_product, use_version)
   
   if resp["count"] == 0 
      # If the data product isn't in the registry, throw an error
      msg = string("no data products found matching: ", use_data_product, " :-(ns: ", use_namespace, " - v: ", use_version, ")")
      throw(ReadWriteException(msg))
   else 
      # Get object entry
      @assert length(resp["results"]) == 1
      obj_url = resp["results"][1]["object"]
      obj_entry = http_get_json(obj_url)
      println("data product found: ", use_data_product, " (url: ", resp["results"][1]["url"], ")")
      # Get storage location
      sl = get_storage_loc(obj_url)
      root = replace(sl.sr_root, "file://" => "")
      path = joinpath(root, sl.sl_path)
      # Add metadata to handle
      add_object_component!(handle.inputs, resp["results"][1]["object"], false, component)
      #a = Dict("data_product" = Dict("use_dp" => use_data_product, "use_namespace" => use_namespace, "use_version" => use_version))
      push!(handle.inputs, resp["components"][i])
      # Return storage locationz
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
   rmd = DataPipeline.get_dp_metadata(handle, data_product, "read")
   use_data_product = get(rmd["use"], "data_product", data_product)
   use_namespace = get(rmd["use"], "namespace", handle.config["run_metadata"]["default_input_namespace"])
   use_version = rmd["use"]["version"]
   
   # Is the data product already in the registry?
   resp = DataPipeline.search_data_product(use_namespace, use_data_product, use_version)
   
   if resp["count"] == 0 
      # If the data product isn't in the registry, throw an error
      msg = string("no data products found matching: ", use_data_product, " :-(ns: ", use_namespace, " - v: ", use_version, ")")
      throw(ReadWriteException(msg))
   else 
      # Get object entry
      @assert length(resp["results"]) == 1
      obj_url = resp["results"][1]["object"]
      println("data product found: ", use_data_product, " (url: ", resp["results"][1]["url"], ")")
       
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
   tmp = read_data_product(handle, data_product, component)
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
   datastore = handle.config["run_metadata"]["write_data_store"]
   storage_root_uri = DataPipeline.get_local_sroot(datastore)
   use_data_product = wmd["use_dp"]
   use_namespace = wmd["use_namespace"]
   use_version = wmd["use_version"]
   filepath = wmd["path"]

   # Get hash
   resp = DataPipeline.search_data_product(use_namespace, use_data_product, wmd["use_version"])
   hash = DataPipeline.get_file_hash(filepath)
   
   # if resp["count"] == 0   
   
   # Rename file
   oldname = split.(basename(filepath), ".")[1]
   new_filepath = replace(filepath, oldname => hash)
   mv(filepath, new_filepath)

   # Register Object
   obj_url = DataPipeline.register_object(new_filepath, hash, wmd["description"], storage_root_uri, wmd["public"])
   
   # Register DataProduct
   ns_url = DataPipeline.get_ns_url(use_namespace)
   body = (namespace=ns_url, name=use_data_product, object=obj_url, version=use_version)
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

## write file and register data product
"""
    write_array(handle, data, data_product, component)

Write an array as a component to an hdf5 file.

WIP.
"""
function write_array(handle::DataRegistryHandle, data::Array, data_product::String, component::String; public::Bool=true)
   temp_fp = tempname()    # write file
   fid = HDF5.h5open(temp_fp, "w")
   fid[component] = data
   HDF5.close(fid)         # register data product
   return register_data_product(handle, data_product, temp_fp, public, component)
end

## write table
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

## register code repo release
function register_git_repo_release(model_name::String, model_version::String, model_repo::String,
    model_description::String,
    model_website::String, storage_root_url::String, storage_root_id::String)

    ## testing
    this_file = @__FILE__
    model_hash = Base.run(string("git -C ", this_file, " rev-parse HEAD"))

    ## UPDATED: check name/version
    # crr_chk = search_code_repo_release(model_name, model_version)
    # sl_path = replace(model_repo, storage_root_url => "")
    # if crr_chk["count"] == 0
    #     obj_id = insert_storage_location(sl_path, model_hash, model_description, storage_root_id, scrc_access_tkn)
    #     ## register release
    #     body = (name=model_name, version=model_version, object=obj_id, website=model_website)
    #     resp = http_post_data("code_repo_release", body, scrc_access_tkn)
    #     println("NB. new code repo release registered. URI := ", resp["url"])
    #     return resp["url"]
    # else
    #     ## check model_repo is the same
    #     # NB. check SR match?
    #     resp = http_get_json(crr_chk["results"][1]["object"])
    #     resp = http_get_json(resp["storage_location"])
    #     sl_path  == resp["path"] || println("WARNING: repo mismatch detected := ", sl_path, " != ", resp["path"])
    #     println("NB. code repo release := ", crr_chk["results"][1]["url"])
    #     return crr_chk["results"][1]["url"]
    # end
end

function SEIRS_model(initial_state::Dict, timesteps::Int64, years::Int64,
   alpha::Float64, beta::Float64, inv_gamma::Float64,
   inv_omega::Float64, inv_mu::Float64, inv_sigma::Float64)

   S = initial_state["S"]
   E = initial_state["E"]
   I = initial_state["I"]
   R = initial_state["R"]
   time_unit_years = years / timesteps
   time_unit_days = time_unit_years * 365.25
 
   # Convert parameters to days
   alpha = alpha * time_unit_days
   beta = beta * time_unit_days
   gamma = time_unit_days / inv_gamma
   omega = time_unit_days / (inv_omega * 365.25)
   mu = time_unit_days / (inv_mu * 365.25)
   sigma = 1 / inv_sigma
   N = S + E + I + R
   birth = mu * N

   results = DataFrames.DataFrame(time = 0, S = S, E = E, I = I, R = R)

   for t = 1:timesteps
     infection = (beta * results.I[t] * results.S[t]) / N
     lost_immunity = omega * results.R[t]
     death_S = mu * results.S[t]
     death_E = mu * results.E[t]
     death_I = (mu * alpha) * results.I[t]
     death_R = mu * results.R[t]
     latency = sigma * results.E[t]
     recovery = gamma * results.I[t]
 
     S_rate = birth - infection + lost_immunity - death_S
     E_rate = infection - latency - death_E
     I_rate = latency - recovery - death_I
     R_rate = recovery - lost_immunity - death_R
 
     new_S = results.S[t] + S_rate
     new_E = results.E[t] + E_rate
     new_I = results.I[t] + I_rate
     new_R = results.R[t] + R_rate

     new = DataFrames.DataFrame(time = t * time_unit_days, 
     S = new_S, E = new_E, 
     I = new_I, R = new_R)

     results = vcat(results, new)
   end
 
   return results
end

function plot_SEIRS(results::DataFrames.DataFrame)
   # Left plot
   x = results.time / 365.25
   y1 = Matrix(results[:, 2:5]) .* 100
   p1 = plot(x, y1, label = ["S" "E" "I" "R"], lw = 3)
   xlabel!("Years")
   ylabel!("Relative group size (%)")

   # Right plot
   y2 = y1[:, 2:3]
   p2 = plot(x, y2, label = ["E" "I"], lw = 3)
   xlabel!("Years")
   ylabel!("Relative group size (%)")

   # Join plots together
   Plots.plot(p1, p2, plot_title = "SEIRS model trajectories")
end