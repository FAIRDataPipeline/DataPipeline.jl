module DataRegistryUtils

import YAML
import HTTP
import JSON
import FTPClient
import SHA

### YAML file processing ###

const API_ROOT = "https://data.scrc.uk/api/"
const NS_ROOT = string(API_ROOT, "namespace/")
const DATA_OUT = "./out/"
const NULL_HASH = "na"
const NULL_FILE = "no_match"
const VERSION_LATEST = "latest"

## file hash check results
struct DPHashCheck
    pass::Bool
    file_path::String
    file_hash::String
end

## dp file handling:
include("data_prod_proc.jl")

## db output
include("db_utils.jl")

## get namespace id (or use default)
function get_ns_cd(ns_name)
    url = string(API_ROOT, "namespace/?name=", ns_name)
    r = HTTP.request("GET", url)
    resp = JSON.parse(String(r.body))
    ns_url = resp["results"][1]["url"]
    ns_cd = replace(replace(ns_url, NS_ROOT => ""), "/" => "")
    return parse(Int, ns_cd)
end
# - as above
function get_ns_cd(dpd, df_cd)
    try
        return get_ns_cd(dpd["use"]["namespace"])
    catch error
        isa(error, KeyError) || println("ERROR: using default namespace - ", error)
        return df_cd
    end
end

## storage root
# 1 - https://raw.githubusercontent.com/ScottishCovidResponse/temporary_data/master/
# 14 - https://raw.githubusercontent.com/ScottishCovidResponse/DataRepository/
# 9 - ftp://boydorr.gla.ac.uk/scrc/
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
    r = HTTP.request("GET", obj_url)                    # object
    resp = JSON.parse(String(r.body))
    r = HTTP.request("GET", resp["storage_location"])   # storage location
    resp = JSON.parse(String(r.body))
    filepath = resp["path"]
    filehash = resp["hash"]
    rt_url = resp["storage_root"]
    r = HTTP.request("GET", rt_url)                     # storage root
    resp = JSON.parse(String(r.body))
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
    r = HTTP.request("GET", url)
    resp = JSON.parse(String(r.body))
    if resp["count"] == 0   # nothing found
        println("WARNING: no results found for ", url)
        return DPHashCheck(false, NULL_FILE, NULL_HASH)
    else                    # get storage location of most recent dp
        idx = version == VERSION_LATEST ? get_most_recent_index(resp) : get_version_index(resp, version)
        s = get_storage_loc(resp["results"][idx]["object"])
        chk = check_file(s, out_dir, fail_on_hash_mismatch) # download and check
        verbose && println(" - ", s.s_fp, " hash check := ", chk.pass)
        return chk
    end
end

## process yaml
# - downloads data
# - returns tuple of arrays: data product names, filepaths, hashes
# - TBA: access log
# - TBD: add temp file option?
function process_yaml_file(d::String, out_dir::String, verbose::Bool)
    println("processing config file: ", d)
    verbose || println(" - hint: use the 'verbose' option to see more stuff")
    data = YAML.load_file(d)
    rd = data["read"]
    df_ns_cd = get_ns_cd(data["namespace"])
    fail_on_hash_mismatch = data["fail_on_hash_mismatch"]
    err_cnt = 0
    fps = String[]
    dpnms = String[]
    fhs = String[]
    dp_version = String[]
    for dp in keys(rd)
        dpd = rd[dp]
        push!(dpnms, dpd["where"]["data_product"])
        push!(dp_version, get_version_str(dpd))
        verbose && println(" - data product: ", dpnms[end], " : version := ", dp_version[end])
        res = refresh_dp(dpnms[end], get_ns_cd(dpd, df_ns_cd), dp_version[end], out_dir, verbose, fail_on_hash_mismatch)
        res.pass || (err_cnt += 1)
        push!(fps, res.file_path)
        push!(fhs, res.file_hash)
    end
    println(" - files refreshed", err_cnt == 0 ? "." : ", but issues were detected.")
    return (dp_name=dpnms, dp_file=fps, dp_hash=fhs, dp_version=dp_version)
end

## public function
"""
    fetch_data_per_yaml(yaml_filepath, out_dir = "./out/"; use_axis_arrays::Bool = false, verbose = false, ...)

Refresh and load data products from the SCRC data registry. Checks the file hash for each data product and downloads anew any that are determined to be out-of-date.

**Parameters**
- `yaml_filepath`       -- the location of a .yaml file.
- `out_dir`             -- the local system directory where data will be stored.
- `use_axis_arrays`     -- convert the output to AxisArrays, where applicable.
- `use_sql`             -- load SQLite database and return connection.
- `sql_file`            -- (optional) SQL file for e.g. custom SQLite views, indexes, or whatever.
- `force_db_refresh`    -- overide filehash check on database insert.
- `verbose`             -- set to `true` to show extra output in the console.
"""
function fetch_data_per_yaml(yaml_filepath::String, out_dir::String = DATA_OUT; use_axis_arrays::Bool=false, use_sql::Bool = false, sql_file::String="", force_db_refresh::Bool=false, verbose::Bool=false)
    out_dir = string(rstrip(out_dir, '/'), "/")
    md = process_yaml_file(yaml_filepath, out_dir, verbose)
    if use_sql                      # SQLite connection
        db_path = string(out_dir, basename(yaml_filepath), ".db")
        output = load_data_per_yaml(md, db_path, force_db_refresh, verbose)
        if length(sql_file) > 0     # optional sql file
            print(" - running: ", sql_file)
            try
                proc_sql_file!(output, sql_file)
                println(" - done.")
            catch e
                println(" - SQL ERROR:\n -- ", e)
            end
        end
        return output
    else                            # return data in memory
        output = Dict()
        for i in eachindex(md.dp_name)
            dp = read_data_product(md.dp_file[i]; verbose)
            output[md.dp_name[i]] = dp
        end
        return output
    end
end

export fetch_data_per_yaml, read_data_product

end # module
