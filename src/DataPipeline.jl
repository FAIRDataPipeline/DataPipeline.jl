module DataPipeline

import YAML
import HTTP
import JSON
import FTPClient
import SHA
import Dates
import CSV
import DataFrames
using Plots
# import PrettyTables

const C_DEBUG_MODE = false
# const API_ROOT = "https://data.scrc.uk/api/"
const LOCAL_DR_STEM = "http://localhost"
const LOCAL_DR_PORTLESS = string(LOCAL_DR_STEM, "/api/")
# const LOCAL_DR_PORT = 8000
const API_ROOT = string(LOCAL_DR_STEM, ":8000", "/api/")

const NS_ROOT = string(API_ROOT, "namespace/")
const STR_ROOT = string(LOCAL_DR_PORTLESS, "storage_root/")
const STR_MATCH = Regex(string(LOCAL_DR_STEM, ".*storage_root/"))
const SL_ROOT = string(LOCAL_DR_PORTLESS, "storage_location/")
const TF_ROOT = string(API_ROOT, "text_file/")
# const OBJ_ROOT = string(API_ROOT, "object/")
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

## file hash check results
struct DPHashCheck
    pass::Bool
    file_path::String
    file_hash::String
end

include("data_prod_proc.jl")    # dp file handling
include("db_utils.jl")          # db output
include("data_log.jl")          # access logging
include("api_audit.jl")         # DR audits

## function get id from uri
function get_id_from_root(url::String, root::String)
    return replace(replace(url, root => ""), "/" => "")
end

function get_id_from_root(url::String, root::Regex)
    return replace(replace(url, root => s""), "/" => "")
end

## get file hash
function get_file_hash(fp::String)
    fhash = bytes2hex(SHA.sha2_256(fp))
    return fhash
end

## read data registry
function http_get_json(url::String)
    url = replace(url, LOCAL_DR_PORTLESS => API_ROOT)
    try
        r = HTTP.request("GET", url)
        return JSON.parse(String(r.body))
    catch e
        msg = "couldn't connect to local web server... have you run the start script?"
        isa(e, Base.IOError) && throw(ReadWriteException(msg))
        println("ET: ", typeof(e))
        throw(e)
    end
end

## upload to data registry
function http_post_data(table::String, data, scrc_access_tkn::String)
    url = string(API_ROOT, table, "/")
    headers = Dict("Authorization"=>scrc_access_tkn, "Content-Type" => "application/json")
    body = JSON.json(data)
    C_DEBUG_MODE && println(" POSTing data to := ", url, ": \n ", body)
    r = HTTP.request("POST", url, headers=headers, body=body)
    resp = JSON.parse(String(r.body))
    C_DEBUG_MODE && println(" - response: \n ", resp)
    return resp
end


"""
    convert_query(data)

Convert dictionary to url query.
"""
function convert_query(data::Dict) 
    url = "?"
    for (key, value) in data
        if isa(value, Bool)
            query = value
        elseif all(contains.(value, API_ROOT))
            query = extract_id(value)
            query = isa(query, Vector) ? join(query, ",") : query
        else
            query = URIs.escapeuri(value)
        end
        url = "$url$key=$query&"
    end
    url = chop(url, tail = 1)
    return url
end
## register stuff:
include("api_upload.jl")

## register namespace (added 13/7)
function register_namespace(name::String, full_name::String=name)#, website=nothing
   body = Dict("name"=>name, "full_name"=>full_name)
   # if !isnothing(website) then
   #     body["website"] = website
   # end
   resp = http_post_data("namespace", body)
   return resp["url"]
end

## get namespace url
function get_ns_url(ns_name)
    url = string(API_ROOT, "namespace/?name=", ns_name)
    resp = http_get_json(url)
    if resp["count"] == 0
        return register_namespace(ns_name)
    else
        return resp["results"][1]["url"]
    end
end

## replacement for local registry
function get_ns_id(ns_name)
    df = registry_query("SELECT id FROM data_management_namespace WHERE name=?", (ns_name, ))
    DataFrames.nrow(df) == 0 && (return 0)
    return df[1,1]
end

## get namespace id (or use default)
function get_ns_cd(ns_name)
    ns_url = get_ns_url(ns_name)
    ns_cd = get_id_from_root(ns_url, NS_ROOT)
    return parse(Int, ns_cd)
end
# - as above
function get_ns_cd(dpd, df_cd)
    try
        haskey(dpd, "use") && (return get_ns_cd(dpd["use"]["namespace"]))
        return get_ns_cd(dpd["namespace"])
    catch error
        isa(error, KeyError) || println("ERROR: using default namespace - ", error)
        return df_cd
    end
end

## storage root types
# 1 - https://raw.githubusercontent.com/ScottishCovidResponse/temporary_data/master/
# 14 - https://raw.githubusercontent.com/ScottishCovidResponse/DataRepository/
# 9 - ftp://boydorr.gla.ac.uk/scrc/
# 11 - github
# 203 - https://data.scrc.uk/api/text_file/
# https://data.scrc.uk/api/storage_root/4472/
function get_storage_type(rt_url)
    if (rt_url == string(API_ROOT, "storage_root/1/") || rt_url == string(API_ROOT, "storage_root/14/") || rt_url == string(API_ROOT, "storage_root/4472/"))
        return 1    # http
    elseif rt_url == string(API_ROOT, "storage_root/9/")
        return 2    # ftp
    else
        println("ERROR: unknown storage root: ", rt_url)
        return -1
    end
end

## get storage location
function get_storage_loc(obj_url)
    obj_entry = http_get_json(obj_url)                       # object
    obj_desc = obj_entry["description"]
    sl_entry = http_get_json(obj_entry["storage_location"])      # storage location
    sl_path = sl_entry["path"]
    sl_hash = sl_entry["hash"]
    sr_url = sl_entry["storage_root"]
    sr_entry = http_get_json(sr_url)                        # storage root
    return (sr_root=sr_entry["root"], sr_url=sr_url, sl_path=sl_path, sl_hash=sl_hash,
        description=obj_desc) #, rt_tp=get_storage_type(sr_url)
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

## download file
function download_file(storage_info, fp::String, fail_on_hash_mismatch::Bool)
    isdir(dirname(fp)) || mkpath(dirname(fp))   # check dir
    if storage_info.rt_tp == 1                  # HTTP
        url = string(storage_info.sr_root, storage_info.sl_path)
        HTTP.download(url, fp)
    elseif storage_info.rt_tp == 2              # FTP
        ftp = FTPClient.FTP(storage_info.sr_root)
        download(ftp, storage_info.sl_path, fp)
        close(ftp)
    else
        println("WARNING: unknown storage root type - couldn't download.")
        return DPHashCheck(false, fp, NULL_HASH)
    end
    fhash = open(fp) do f                          # hash check
        fh = bytes2hex(SHA.sha1(f))
        if fh != storage_info.sl_hash
            println("WARNING - HASH DISCREPANCY DETECTED:\n server file := ", storage_info.sl_path, "\n hash: ", storage_info.sl_hash, "\n downloaded: ", fp, "\n hash: ", fh)
            fail_on_hash_mismatch && throw("Hash error. Hint: set 'fail_on_hash_mismatch = false' to ignore this error.")
        end
        return fh
    end
    return DPHashCheck(fhash == storage_info.sl_hash, fp, fhash)
end

## hash check and download
function check_file(storage_info, out_dir, fail_on_hash_mismatch::Bool)
    fp = string(out_dir, storage_info.sl_path)
    if isfile(fp)   # exists - checksum
        fhash = open(fp) do f
            fh = bytes2hex(SHA.sha1(f))
            fh == storage_info.sl_hash || println(" - downloading ", storage_info.sl_path, ", please wait...")
            return fh
        end
        fhash == storage_info.sl_hash && (return DPHashCheck(true, fp, fhash))
    end
    return download_file(storage_info, fp, fail_on_hash_mismatch)  #, fp, fail_on_hash_mismatch
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

## download data (if out of date)
# - rewrite this *
function refresh_dp(dp, ns_cd, version::String, out_dir::String, verbose::Bool, fail_on_hash_mismatch::Bool)
    url = string(API_ROOT, "data_product/?name=", dp, "&namespace=", ns_cd)
    resp = http_get_json(url)
    if resp["count"] == 0   # nothing found
        println("WARNING: no results found for ", url)
        return (url=url, version=version, chk=DPHashCheck(false, NULL_FILE, NULL_HASH), sl=nothing)
    else                    # get storage location of most recent dp
        idx = version==VERSION_LATEST ? get_most_recent_index(resp) : get_version_index(resp, version)
        sl = get_storage_loc(resp["results"][idx]["object"])
        chk = check_file(sl, out_dir, fail_on_hash_mismatch) # download and check
        verbose && println(" - ", sl.sl_path, " hash check := ", chk.pass)
        return (url=resp["results"][idx]["url"], version=resp["results"][idx]["version"], chk=chk, sl=sl)
    end
end

## process yaml
# - downloads data
# - returns array of tuples: data product names, filepaths, hashes
# - TBD: add temp file option?
# - TBD: better error handling / default yaml properties?
function process_data_config_yaml(d::String, out_dir::String, verbose::Bool)
    println("processing config file: ", d)
    verbose || println(" - hint: use the 'verbose' option to see more stuff")
    data = YAML.load_file(d)
    rd = data["read"]
    df_ns_cd = get_ns_cd(data["namespace"])
    fail_on_hash_mismatch = data["fail_on_hash_mismatch"]
    err_cnt = 0
    output = NamedTuple[]
    for dp in keys(rd)
        dpd = rd[dp]
        ns = haskey(dpd, "namespace") ? dpd["namespace"] : data["namespace"]
        (haskey(dpd, "use") && haskey(dpd["use"], "namespace")) && (ns = dpd["use"]["namespace"])
        dpnm = dpd["where"]["data_product"]
        fetch_version = get_version_str(dpd)
        verbose && println(" - fetching data: ", dpnm, " : version := ", fetch_version)
        res = refresh_dp(dpnm, get_ns_cd(dpd, df_ns_cd), fetch_version, out_dir, verbose, fail_on_hash_mismatch)
        res.chk.pass || (err_cnt += 1)
        sl_path = isnothing(res.sl) ? "" : res.sl.sl_path
        sr_url = isnothing(res.sl) ? "" : res.sl.sr_url
        description = isnothing(res.sl.description) ? "" : res.sl.description
        op = (namespace=ns, dp_name=dpd["where"]["data_product"], filepath=res.chk.file_path,
            dp_hash=res.chk.file_hash, dp_version=res.version, sr_url=sr_url,
            sl_path=sl_path, description=description, registered=res.chk.pass, dp_url=res.url)
        push!(output, op)
    end
    println(" - files refreshed", err_cnt == 0 ? "." : ", but issues were detected.")
    return (metadata=output, config=data)
end

## helpers
get_df_db_path(out_dir, data_config) = string(string(rstrip(out_dir, '/'), "/"), isnothing(data_config) ? "registry" : basename(data_config), ".db")
get_pkg_version = "0.50.5" # placeholder

## replacement for fetch_data_per_yaml
"""
    initialise_local_registry(out_dir = "./out/"; ... )

Refresh and load data products from the SCRC data registry.

Checks the file hash for each data product and downloads anew any that are determined to be out-of-date. Allowing that the function has been called previously (i.e. so that the data has already been downloaded,)

**Parameters**
- `out_dir`             -- the local system directory where data will be stored.
- `data_config`         -- the location of the .yaml config file (see the docs.)
- `offline_mode`        -- set `true` when the Data Registry's RESTful API is inaccessible, e.g. no internet connection.
- `sql_file`            -- (optional) SQL file for e.g. custom SQLite views, indexes, or whatever.
- `db_path`             -- (optionally) specify the filepath of the database to use (or create.)
- `auto_logging`        -- set `true` to enable automatic data access logging.
- `verbose`             -- set `true` to show extra output in the console.
- `force_db_refresh`    -- set `true` to overide file hash check on local refresh, debugging only (hint: in the event of corrupted data, it would be easier to clear the designated directory of all data files and start anew.)
"""
function initialise_local_registry(out_dir::String = DATA_OUT; data_config=nothing, offline_mode::Bool=false,
    sql_file::String="", db_path::String=get_df_db_path(out_dir, data_config),
    force_db_refresh::Bool=false, auto_logging::Bool=false, verbose::Bool=false)

    ## SQLite connection:
    function get_db()
        if (offline_mode || isnothing(data_config))
            return init_yaml_db(db_path)    # refresh db views only
        else                                # online refresh:
            out_dir = string(rstrip(out_dir, '/'), "/")
            md = process_data_config_yaml(data_config, out_dir, verbose) # read yaml
            return load_data_per_yaml(md, db_path, force_db_refresh, verbose)
        end
    end
    ## initialise
    db = get_db()
    stmt = SQLite.Stmt(db, "INSERT INTO session(data_dir, pkg_version) VALUES(?,?)")
    SQLite.DBInterface.execute(stmt, (out_dir, get_pkg_version))
    auto_logging && initialise_data_log(db, offline_mode)
    if length(sql_file) > 0     # optional sql file
        print(" - running: ", sql_file)
        try
            proc_sql_file!(db, sql_file)
            println(" - done.")
        catch e
            println(" - SQL ERROR:\n -- ", e)
        end
    end
    return db
end

## public function DEPRECATED
# - `use_sql`             -- load SQLite database and return connection (`true` by default.)
# - `use_axis_arrays`     -- convert the output to AxisArrays, where applicable.
# - `data_log_path`       -- filepath of .yaml access log.
# """
#     fetch_data_per_yaml(data_config, out_dir = "./out/"; ... )
#
# **DEPRECATED** - use `initialise_local_registry`
#
# Refresh and load data products from the SCRC data registry.
#
# Checks the file hash for each data product and downloads anew any that are determined to be out-of-date. Allowing that the function has been called previously (i.e. so that the data has already been downloaded,)
#
# **Parameters**
# - `data_config`         -- the location of the .yaml config file.
# - `out_dir`             -- the local system directory where data will be stored.
#
# **Named parameters**
# - `offline_mode`        -- set `true` when the Data Registry's RESTful API is inaccessible, e.g. no internet connection.
# - `sql_file`            -- (optional) SQL file for e.g. custom SQLite views, indexes, or whatever.
# - `db_path`             -- (optionally) specify the filepath of the database to use (or create.)
# - `force_db_refresh`    -- set `true` to overide file hash check on database inserts.
# - `auto_logging`        -- set `true` to enable automatic data access logging.
# - `verbose`             -- set to `true` to show extra output in the console.
# """
# function fetch_data_per_yaml(data_config::String, out_dir::String = DATA_OUT; offline_mode::Bool=false,
#     sql_file::String="", db_path::String=db_path::String=get_df_db_path(out_dir, data_config),
#     force_db_refresh::Bool=false, auto_logging::Bool=false, verbose::Bool=false)
#
#     # st = Dates.now()
#     ## SQLite connection:
#     function get_db()
#         if offline_mode
#             return init_yaml_db(db_path)    # refresh db views only
#         else                                # online refresh:
#             out_dir = string(rstrip(out_dir, '/'), "/")
#             md = process_data_config_yaml(data_config, out_dir, verbose) # read yaml
#             return load_data_per_yaml(md, db_path, force_db_refresh, verbose)
#         end
#     end
#     ## initialise
#     db = get_db()
#     stmt = SQLite.Stmt(db, "INSERT INTO session(data_dir) VALUES(?)")
#     SQLite.DBInterface.execute(stmt, (out_dir, ))
#     auto_logging && initialise_data_log(db, offline_mode)
#     if length(sql_file) > 0     # optional sql file
#         print(" - running: ", sql_file)
#         try
#             proc_sql_file!(db, sql_file)
#             println(" - done.")
#         catch e
#             println(" - SQL ERROR:\n -- ", e)
#         end
#     end
#     return db
#     # else                            # return data in memory
#     #     output = Dict()
#     #     for i in eachindex(md.dp_name)
#     #         dp = read_data_product_from_file(md.dp_file[i]; verbose)
#     #         output[md.dp_name[i]] = dp
#     #     end
#     #     write_log()
#     #     return output
#     # end
# end

## db staging
include("db_staging.jl")

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
export SEIRS_model, plot_SEIRS

end # module
