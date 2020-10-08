module DataRegistryUtils

import YAML
import HTTP
import JSON
import FTPClient
import SHA

API_ROOT = "https://data.scrc.uk/api/"
NS_ROOT = string(API_ROOT, "namespace/")
SCRC_NS_CD = 2
DATA_OUT = "./out/"

## get namespace id (or use default)
function get_ns_cd(dpd, df_cd)
    try
        url = string(API_ROOT, "namespace/?name=", dpd["use"]["namespace"])
        r = HTTP.request("GET", url)
        resp = JSON.parse(String(r.body))
        ns_url = resp["results"][1]["url"]
        ns_cd = replace(replace(ns_url, NS_ROOT => ""), "/" => "")
        # ns_cd = replace(ns_cd, "/" => "")
        return parse(Int, ns_cd)
    catch error
        isa(error, KeyError) || println("ERROR: using default namespace - ", error)
        return df_cd
    end
end

## storage root
# "https://data.scrc.uk/api/storage_root/14/" - "https://raw.githubusercontent.com/ScottishCovidResponse/DataRepository/"
# "https://data.scrc.uk/api/storage_root/9/" - "ftp://boydorr.gla.ac.uk/scrc/"
function get_storage_type(rt_url)
    if rt_url == string(API_ROOT, "storage_root/14/")
        return 1    # http / toml
    elseif rt_url == "https://data.scrc.uk/api/storage_root/9/"
        return 2    # ftp / hdf5
    else
        println("ERROR: unknown storage root: ", rt_url)
        return -1
    end
end


## get storage location
function get_storage_loc(obj_url)
    # println(obj_url)
    r = HTTP.request("GET", obj_url)                    # object
    resp = JSON.parse(String(r.body))
    r = HTTP.request("GET", resp["storage_location"])   # storage location
    resp = JSON.parse(String(r.body))
    filepath = resp["path"]
    filehash = resp["hash"]
    rt_url = resp["storage_root"]
    r = HTTP.request("GET", rt_url)       # storage root
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
    end
end

## hash check and download
# add break
function check_file(storage_info, out_dir)
    isdir(out_dir) || mkpath(out_dir)   # check dir
    fp = string(out_dir, replace(storage_info.s_fp, "/" => "_"))
    if isfile(fp)   # exists - checksum
        ff = open(fp) do f
            bytes2hex(SHA.sha1(f)) == storage_info.s_hs
        end
        ff && (return true)
    end
    download_file(storage_info, fp)
    return false
end

## download data
function download_dp(dp, ns_cd, out_dir)
    url = string(API_ROOT, "data_product/?name=", dp, "&namespace=", ns_cd)
    # println(url)
    r = HTTP.request("GET", url)
    resp = JSON.parse(String(r.body))
    if resp["count"] == 0
        println("ERROR: no results found for ", url)
    else
        resp["count"] == 1 || println("warning - found ", resp["count"], " results for ", url)
        ## get storage location
        obj_url = resp["results"][1]["object"]
        s = get_storage_loc(obj_url)
        # println(" --- ", s)
        ## download
        println("CHECK: ", check_file(s, out_dir))
    end
end

## process yaml
# - downloads data
function proc_yaml(data, out_dir = DATA_OUT)
    rd = data["read"]
    df_ns = data["namespace"]
    df_ns_cd = get_ns_cd(df_ns, SCRC_NS_CD)
    # println("DF NS: ", df_ns_cd)
    for dp in keys(rd)
        dpd = rd[dp]
        ns_cd = get_ns_cd(dpd, df_ns_cd)
        # println(dpd["where"]["data_product"], " - ")
        download_dp(dpd["where"]["data_product"], ns_cd, out_dir)
    end
end

export proc_yaml

end # module
