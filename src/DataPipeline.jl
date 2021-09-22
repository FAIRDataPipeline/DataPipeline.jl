module DataPipeline

using YAML
using HTTP
using JSON
using FTPClient
using SHA
using Dates
using CSV
using DataFrames
using URIs
using Plots

const C_DEBUG_MODE = false
const LOCAL_DR_STEM = "http://localhost"
const LOCAL_DR_PORTLESS = string(LOCAL_DR_STEM, "/api/")
const API_ROOT = string(LOCAL_DR_STEM, ":8000", "/api/")
const NS_ROOT = string(API_ROOT, "namespace/")
const STR_ROOT = string(LOCAL_DR_PORTLESS, "storage_root/")
const STR_MATCH = Regex(string(LOCAL_DR_STEM, ".*storage_root/"))
const SL_ROOT = string(LOCAL_DR_PORTLESS, "storage_location/")
const TF_ROOT = string(API_ROOT, "text_file/")
const TEST_NAMESPACE = "data_processing_test"
const DATA_OUT = "./out/"
const NULL_HASH = "na"
const NULL_FILE = "no_match"
const VERSION_LATEST = "latest"
const STR_RT_GITHUB = string(STR_ROOT, "11/")
const STR_RT_TEXTFILE = string(STR_ROOT, "203/")
const STR_RT_BOYDORR = string(STR_ROOT, "9/")
const DF_MODEL_REL_DESC = "Julia model."
const DF_MR_SUB_SCR_DESC = "Submission script."
const FILE_SR_STEM = "file://"

include("core.jl")
export convert_query
export http_get_json, get_entry, get_url, get_id
export extract_id
export check_exists
export http_post_data
export get_file_hash, get_access_token


include("data_prod_proc.jl")    # dp file handling
include("api_audit.jl")         # DR audits

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

## get object_component
function add_object_component!(array::Array, obj_url::String, post_component::Bool, component=nothing)
    # Post component to registry
    if post_component && !isnothing(component)  # post component
        body = (object=obj_url, name=component)
        rc = http_post_data("object_component", body)
    end
    # Get object entry
    resp = DataPipeline.http_get_json(obj_url)  # object
    # Get component entry
    for i in length(resp["components"])         # all components
        if !post_component && !isnothing(component)
            rc = http_get_json(resp["components"][i])
            # println("TESTING: ", rc["name"], " VS. ", component)
            rc["name"] == component && push!(array, resp["components"][i])
        else
            push!(array, resp["components"][i])
        end
    end
end


## get index of most recent version
function get_most_recent_index(resp)
    resp["count"] == 1 && (return 1)
    v = String[]
    for i in 1:length(resp["results"])
        push!(v, resp["results"][i]["version"])
    end
    return findmax(v)[2]
end

## get version index, default to most recent
function get_version_index(resp, version::String)
    for i in 1:length(resp["results"])
        resp["results"][i]["version"] == version && (return i)
    end
    return get_most_recent_index(resp)
end

## try get version label
function get_version_str(dpd)
    try
        return dpd["where"]["version"]
    catch error
        isa(error, KeyError) || println("NB. DEFAULTING TO MOST RECENT DP VERSION DUE TO ERROR := ", error)
        return VERSION_LATEST
    end
end

## fdp interface
include("fdp_i.jl")

## public functions and types:
export initialise_local_registry, read_data_product_from_file
export fetch_data_per_yaml  # deprecated
export read_estimate, read_table, read_array, load_array!
export initialise_data_log, finish_data_log
export register_data_product, register_text_file
export register_github_model, register_model_run
# export stage_github_model, stage_model_run
# export register_staged_model, register_staged_run
export commit_staged_data_product
export commit_staged_model, commit_staged_run
export registry_commit_status, commit_all
export whats_my_file, registry_audit
## fdp interface:
export initialise, finalise
export read_array, read_table, read_estimate, read_distribution
export write_array, write_table, write_estimate, write_distribution
export link_read, link_write
export raise_issue
export SEIRS_model, plot_SEIRS, convert_query

end # module
