module DataRegistryUtils

import YAML
import HTTP
import JSON
import FTPClient
import SHA
import Dates
# import PrettyTables

const API_ROOT = "https://data.scrc.uk/api/"
const NS_ROOT = string(API_ROOT, "namespace/")
const STR_ROOT = string(API_ROOT, "storage_root/")
const SL_ROOT = string(API_ROOT, "storage_location/")
const TF_ROOT = string(API_ROOT, "text_file/")
# const OBJ_ROOT = string(API_ROOT, "object/")
const DATA_OUT = "./out/"
const NULL_HASH = "na"
const NULL_FILE = "no_match"
const VERSION_LATEST = "latest"
const STR_RT_GITHUB = "https://data.scrc.uk/api/storage_root/11/"
const STR_RT_TEXTFILE = "https://data.scrc.uk/api/storage_root/203/"
const DF_MODEL_REL_DESC = "Julia model."
const DF_MR_SUB_SCR_DESC = "Submission script."

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

## get file hash
function get_file_hash(fp::String)
    fhash = open(fp) do f
        return bytes2hex(SHA.sha1(f))
    end
    return fhash
end

## read data registry
function http_get_json(url::String)
    r = HTTP.request("GET", url)
    return JSON.parse(String(r.body))
end

### upload to data registry
function http_post_data(table::String, data, scrc_access_tkn::String)
    url = string(API_ROOT, table)
    # println(" posting data to table := ", url, ": \n", data)
    headers = Dict("Authorization"=>scrc_access_tkn, "Content-Type" => "application/json")
    r = HTTP.request("POST", url, headers=headers, body=JSON.json(data))
    resp = JSON.parse(String(r.body))
    # println(" - response: \n ", resp)
    return resp
end

## register stuff:
include("api_upload.jl")

## get namespace id (or use default)
function get_ns_cd(ns_name)
    url = string(API_ROOT, "namespace/?name=", ns_name)
    resp = http_get_json(url)
    ns_url = resp["results"][1]["url"]
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
function get_storage_type(rt_url)
    if (rt_url == string(API_ROOT, "storage_root/1/") || rt_url == string(API_ROOT, "storage_root/14/"))
        return 1    # http / toml
    elseif rt_url == string(API_ROOT, "storage_root/9/")
        return 2    # ftp / hdf5
    else
        println("ERROR: unknown storage root: ", rt_url)
        return -1
    end
end

## get storage location
function get_storage_loc(obj_url)
    resp = http_get_json(obj_url)                       # object
    resp = http_get_json(resp["storage_location"])      # storage location
    filepath = resp["path"]
    filehash = resp["hash"]
    rt_url = resp["storage_root"]
    resp = http_get_json(rt_url)                        # storage root
    return (s_rt = resp["root"], s_fp = filepath, s_hs = filehash, rt_tp = get_storage_type(rt_url))
end

## download file
function download_file(storage_info, fp::String, fail_on_hash_mismatch::Bool)
    isdir(dirname(fp)) || mkpath(dirname(fp))   # check dir
    if storage_info.rt_tp == 1                  # HTTP
        url = string(storage_info.s_rt, storage_info.s_fp)
        HTTP.download(url, fp)
    elseif storage_info.rt_tp == 2              # FTP
        ftp = FTPClient.FTP(storage_info.s_rt)
        download(ftp, storage_info.s_fp, fp)
        close(ftp)
    else
        println("WARNING: unknown storage root type - couldn't download.")
        return DPHashCheck(false, fp, NULL_HASH)
    end
    fhash = open(fp) do f                          # hash check
        fh = bytes2hex(SHA.sha1(f))
        if fh != storage_info.s_hs
            println("WARNING - HASH DISCREPANCY DETECTED:\n server file := ", storage_info.s_fp, "\n hash: ", storage_info.s_hs, "\n downloaded: ", fp, "\n hash: ", fh)
            fail_on_hash_mismatch && throw("Hash error. Hint: set 'fail_on_hash_mismatch = false' to ignore this error.")
        end
        return fh
    end
    return DPHashCheck(fhash == storage_info.s_hs, fp, fhash)
end

## hash check and download
function check_file(storage_info, out_dir, fail_on_hash_mismatch::Bool)
    fp = string(out_dir, storage_info.s_fp)
    if isfile(fp)   # exists - checksum
        fhash = open(fp) do f
            fh = bytes2hex(SHA.sha1(f))
            fh == storage_info.s_hs || println(" - downloading ", storage_info.s_fp, ", please wait...")
            return fh
        end
        fhash == storage_info.s_hs && (return DPHashCheck(true, fp, fhash))
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
function refresh_dp(dp, ns_cd, version::String, out_dir::String, verbose::Bool, fail_on_hash_mismatch::Bool)
    url = string(API_ROOT, "data_product/?name=", dp, "&namespace=", ns_cd)
    resp = http_get_json(url)
    if resp["count"] == 0   # nothing found
        println("WARNING: no results found for ", url)
        return (version=version, chk=DPHashCheck(false, NULL_FILE, NULL_HASH))
    else                    # get storage location of most recent dp
        idx = version == VERSION_LATEST ? get_most_recent_index(resp) : get_version_index(resp, version)
        s = get_storage_loc(resp["results"][idx]["object"])
        chk = check_file(s, out_dir, fail_on_hash_mismatch) # download and check
        verbose && println(" - ", s.s_fp, " hash check := ", chk.pass)
        return (version=resp["results"][idx]["version"], chk=chk)
    end
end

## process yaml
# - downloads data
# - returns tuple of arrays: data product names, filepaths, hashes
# - TBA: access log
# - TBD: add temp file option?
# - TBA: error handling and default yaml properties
function process_data_config_yaml(d::String, out_dir::String, verbose::Bool)
    println("processing config file: ", d)
    verbose || println(" - hint: use the 'verbose' option to see more stuff")
    data = YAML.load_file(d)
    rd = data["read"]
    df_ns_cd = get_ns_cd(data["namespace"])
    fail_on_hash_mismatch = data["fail_on_hash_mismatch"]
    err_cnt = 0
    fps = String[]
    nss = String[]
    dpnms = String[]
    fhs = String[]
    dp_version = String[]
    for dp in keys(rd)
        dpd = rd[dp]
        ns = haskey(dpd, "namespace") ? dpd["namespace"] : data["namespace"]
        (haskey(dpd, "use") && haskey(dpd["use"], "namespace")) && (ns = dpd["use"]["namespace"])
        push!(nss, ns)
        push!(dpnms, dpd["where"]["data_product"])
        fetch_version = get_version_str(dpd)
        verbose && println(" - fetching data: ", dpnms[end], " : version := ", fetch_version)
        res = refresh_dp(dpnms[end], get_ns_cd(dpd, df_ns_cd), fetch_version, out_dir, verbose, fail_on_hash_mismatch)
        push!(dp_version, res.version)
        res.chk.pass || (err_cnt += 1)
        push!(fps, res.chk.file_path)
        push!(fhs, res.chk.file_hash)
    end
    println(" - files refreshed", err_cnt == 0 ? "." : ", but issues were detected.")
    return (dp_namespace=nss, dp_name=dpnms, dp_file=fps, dp_hash=fhs, dp_version=dp_version, config=data)
end

## public function
# - `use_sql`             -- load SQLite database and return connection (`true` by default.)
# - `use_axis_arrays`     -- convert the output to AxisArrays, where applicable.
# - `data_log_path`       -- filepath of .yaml access log.
"""
    fetch_data_per_yaml(yaml_filepath, out_dir = "./out/"; ... )

Refresh and load data products from the SCRC data registry.

Checks the file hash for each data product and downloads anew any that are determined to be out-of-date. Allowing that the function has been called previously (i.e. so that the data has already been downloaded,)

**Parameters**
- `yaml_filepath`       -- the location of a .yaml file.
- `out_dir`             -- the local system directory where data will be stored.

**Named parameters**
- `offline_mode`        -- set `true` when the Data Registry's RESTful API is inaccessible, e.g. no internet connection.
- `sql_file`            -- (optional) SQL file for e.g. custom SQLite views, indexes, or whatever.
- `db_path`             -- (optionally) specify the filepath of the database to use (or create.)
- `force_db_refresh`    -- set `true` to overide file hash check on database inserts.
- `auto_logging`        -- set `true` to enable automatic data access logging.
- `verbose`             -- set to `true` to show extra output in the console.
"""
function fetch_data_per_yaml(yaml_filepath::String, out_dir::String = DATA_OUT; offline_mode::Bool=false,
    sql_file::String="", db_path::String=string(string(rstrip(out_dir, '/'), "/"), basename(yaml_filepath), ".db"),
    force_db_refresh::Bool=false, auto_logging::Bool=false, verbose::Bool=false)

    # st = Dates.now()
    ## SQLite connection:
    function get_db()
        if offline_mode
            return init_yaml_db(db_path)    # refresh db views only
        else                                # online refresh:
            out_dir = string(rstrip(out_dir, '/'), "/")
            md = process_data_config_yaml(yaml_filepath, out_dir, verbose) # read yaml
            return load_data_per_yaml(md, db_path, force_db_refresh, verbose)
        end
    end
    ## initialise
    db = get_db()
    stmt = SQLite.Stmt(db, "INSERT INTO session(data_dir) VALUES(?)")
    SQLite.DBInterface.execute(stmt, (out_dir, ))
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
    # else                            # return data in memory
    #     output = Dict()
    #     for i in eachindex(md.dp_name)
    #         dp = read_data_product_from_file(md.dp_file[i]; verbose)
    #         output[md.dp_name[i]] = dp
    #     end
    #     write_log()
    #     return output
    # end
end

## db staging
include("db_staging.jl")

export fetch_data_per_yaml, read_data_product_from_file
export read_estimate, read_table, read_array
export initialise_data_log, finish_data_log
export register_github_model, register_model_run, register_text_file
export stage_github_model, stage_model_run
export register_staged_model, register_staged_run


end # module
