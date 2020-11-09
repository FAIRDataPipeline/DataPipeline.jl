module DataRegistryUtils

import YAML
import HTTP
import JSON
import FTPClient
import SHA

### YAML file processing ###

API_ROOT = "https://data.scrc.uk/api/"
NS_ROOT = string(API_ROOT, "namespace/")
DATA_OUT = "./out/"

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
        return false
    end
    ff = open(fp) do f                          # hash check
        fh = bytes2hex(SHA.sha1(f))
        if fh != storage_info.s_hs
            println("WARNING - HASH DISCREPANCY DETECTED:\n server file := ", storage_info.s_fp, "\n hash: ", storage_info.s_hs, "\n downloaded: ", fp, "\n hash: ", fh)
            fail_on_hash_mismatch && throw("Hash error. Hint: set 'fail_on_hash_mismatch = false' to ignore this error.")
        end
        return (fh == storage_info.s_hs)
    end
    return ff
end

## hash check and download
# - returns file check and filepath
function check_file(storage_info, out_dir, fail_on_hash_mismatch::Bool)
    fp = string(out_dir, storage_info.s_fp)
    if isfile(fp)   # exists - checksum
        ff = open(fp) do f
            fh = bytes2hex(SHA.sha1(f))
            fh == storage_info.s_hs || println(" - downloading ", storage_info.s_fp, ", please wait...")
            return (fh == storage_info.s_hs)
        end
        ff && (return (true, fp))
    end
    return (download_file(storage_info, fp), fp, fail_on_hash_mismatch)
end

## choose most recent index
function get_most_recent_index(resp)
    resp["count"] == 1 && (return 1)
    v = String[]
    for i in 1:length(resp["results"])
        push!(v, resp["results"][i]["version"])
    end
    return findmax(v)[2]
end

## download data (if out of date)
function refresh_dp(dp, ns_cd, out_dir::String, verbose::Bool, fail_on_hash_mismatch::Bool)
    url = string(API_ROOT, "data_product/?name=", dp, "&namespace=", ns_cd)
    r = HTTP.request("GET", url)
    resp = JSON.parse(String(r.body))
    if resp["count"] == 0   # nothing found
        println("WARNING: no results found for ", url)
        return (1, "na")
    else                    # get storage location of most recent dp
        idx = get_most_recent_index(resp)
        s = get_storage_loc(resp["results"][idx]["object"])
        chk = check_file(s, out_dir, fail_on_hash_mismatch) # download and check
        verbose && println(" - ", s.s_fp, " hash check := ", chk)
        return (chk[1] ? 0 : 1, chk[2])
    end
end

## process yaml
# - downloads data
# - returns tuple of arrays: data product names and filepaths
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
    for dp in keys(rd)
        dpd = rd[dp]
        dpn = dpd["where"]["data_product"]
        verbose && println(" - data product: ", dpn)
        res = refresh_dp(dpn, get_ns_cd(dpd, df_ns_cd), out_dir, verbose, fail_on_hash_mismatch)
        err_cnt += res[1]
        push!(dpnms, dpn)
        push!(fps, res[2])
    end
    println(" - data refreshed", err_cnt == 0 ? "." : ", but issues were detected.")
    return (dpnms, fps)
end



## public function
"""
    fetch_data_per_yaml(yaml_filepath, out_dir = "./out/"; use_axis_arrays::Bool = false, verbose = false)

Refresh and load data products from the SCRC data registry. Checks the file hash for each data product and downloads anew any that are determined to be out-of-date.

**Parameters**
- `yaml_filepath`   -- the location of a .yaml file.
- `out_dir`         -- the local system directory where data will be stored.
- `use_axis_arrays` -- convert the output to AxisArrays, where applicable.
- `use_sql`         -- load SQLite database and return connection.
- `sql_file`        -- (optional) SQL file for e.g. custom SQLite views, indexes, or whatever.
- `verbose`         -- set to `true` to show extra output in the console.
"""
function fetch_data_per_yaml(yaml_filepath::String, out_dir::String = DATA_OUT; use_axis_arrays::Bool = false, use_sql::Bool = false, sql_file::String = "", verbose::Bool = false)
    out_dir = string(rstrip(out_dir, '/'), "/")
    dp_fps = process_yaml_file(yaml_filepath, out_dir, verbose)
    if use_sql
        db_path = string(out_dir, basename(yaml_filepath), ".db")
        output = load_data_per_yaml(dp_fps, db_path, verbose)
        if length(sql_file) > 0     # optional sql file
            println(" - running: ", sql_file)
            try
                proc_sql_file!(output, sql_file)
            catch e
                println(" -- ERROR: ", e)
            end
        end
        println(" - done.")
        return output
    else
        output = Dict()
        for i in eachindex(dp_fps[1])
            dp = read_data_product(dp_fps[2][i]; verbose)
            output[dp_fps[1][i]] = dp
        end
        return output
    end
end

export fetch_data_per_yaml, read_data_product

end # module
