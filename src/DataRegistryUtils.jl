module DataRegistryUtils

import YAML
import HTTP
import JSON
import FTPClient
import SHA

API_ROOT = "https://data.scrc.uk/api/"
NS_ROOT = string(API_ROOT, "namespace/")
# SCRC_NS_CD = 2
DATA_OUT = "./out/"

## get namespace id (or use default)
function get_ns_cd(ns_name)
    url = string(API_ROOT, "namespace/?name=", ns_name)
    r = HTTP.request("GET", url)
    resp = JSON.parse(String(r.body))
    ns_url = resp["results"][1]["url"]
    ns_cd = replace(replace(ns_url, NS_ROOT => ""), "/" => "")
    return parse(Int, ns_cd)
end

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
function download_file(storage_info, fp)
    if storage_info.rt_tp == 1          # HTTP
        url = string(storage_info.s_rt, storage_info.s_fp)
        HTTP.download(url, fp)
    elseif storage_info.rt_tp == 2      # FTP
        ftp = FTPClient.FTP(storage_info.s_rt)
        download(ftp, storage_info.s_fp, fp)
        close(ftp)
    else
        println("WARNING: unknown storage root type - couldn't download.")
        return false
    end
    ff = open(fp) do f                  # hash check
        fh = bytes2hex(SHA.sha1(f))
        fh == storage_info.s_hs || println("WARNING - HASH DISCREPANCY DETECTED:\n server file := ", storage_info.s_fp, "\n hash: ", storage_info.s_hs, "\n downloaded: ", fp, "\n hash: ", fh)
        return (fh == storage_info.s_hs)
    end
    return ff
end

## hash check and download
function check_file(storage_info, out_dir)
    isdir(out_dir) || mkpath(out_dir)   # check dir
    fp = string(out_dir, replace(storage_info.s_fp, "/" => "_"))
    if isfile(fp)   # exists - checksum
        ff = open(fp) do f
            fh = bytes2hex(SHA.sha1(f))
            fh == storage_info.s_hs || println(" - downloading ", storage_info.s_fp, ", please wait...")
            return (fh == storage_info.s_hs)
        end
        ff && (return true)
    end
    return download_file(storage_info, fp)
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

## download data
function download_dp(dp, ns_cd, out_dir, verbose)
    url = string(API_ROOT, "data_product/?name=", dp, "&namespace=", ns_cd)
    r = HTTP.request("GET", url)
    resp = JSON.parse(String(r.body))
    if resp["count"] == 0   # nothing found
        println("WARNING: no results found for ", url)
        return 1
    else                    # get storage location of most recent dp
        idx = get_most_recent_index(resp)
        s = get_storage_loc(resp["results"][idx]["object"])
        chk = check_file(s, out_dir)    # [download and] check
        verbose && println(" - ", s.s_fp, " hash check := ", chk)
        return chk ? 0 : 1
    end
end

## process yaml
# - downloads data
function process_yaml_file(d, out_dir = DATA_OUT, verbose = false)
    println("processing ", d)
    data = YAML.load_file(d)
    rd = data["read"]
    df_ns_cd = get_ns_cd(data["namespace"])
    err_cnt = 0
    for dp in keys(rd)
        dpd = rd[dp]
        err_cnt += download_dp(dpd["where"]["data_product"], get_ns_cd(dpd, df_ns_cd), out_dir, verbose)
    end
    println("finished", err_cnt == 0 ? "." : ", but issues were detected.")

end

export process_yaml_file

## ph's for public functions
# function read_estimate(args)
#     body
# end

end # module
