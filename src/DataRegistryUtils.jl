module DataRegistryUtils

import YAML
import HTTP
import JSON
import FTPClient
import SHA
import Dates

### YAML file processing ###

const API_ROOT = "https://data.scrc.uk/api/"
const NS_ROOT = string(API_ROOT, "namespace/")
const STR_ROOT = string(API_ROOT, "storage_root/")
const SL_ROOT = string(API_ROOT, "storage_location/")
const TF_ROOT = string(API_ROOT, "text_file/")
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

## dp file handling:
include("data_prod_proc.jl")

## db output
include("db_utils.jl")

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

## register storage location and return object id
function insert_storage_location(path::String, hash::String, description::String, root_id::String, scrc_access_tkn::String)
    body = Dict("path"=>path, "hash"=>hash, "storage_root"=>root_id)
    resp = http_post_data("storage_location", body, scrc_access_tkn)
    sl_id = resp["url"]
    ## add object
    body = (description=description, storage_location=sl_id)
    resp = http_post_data("object", body, scrc_access_tkn)
    return resp["url"]
end

## check storage location
function search_storage_location(path::String, hash::String, root_id::String)
    tf_sr_id = get_id_from_root(root_id, STR_ROOT)
    search_url = string(API_ROOT, "storage_location/?path=", HTTP.escapeuri(path), "&hash=", hash, "&storage_root=", tf_sr_id)
    return http_get_json(search_url)
end

## check repo release key (name and version)
function search_code_repo_release(name::String, version::String)
    search_url = string(API_ROOT, "code_repo_release/?name=", HTTP.escapeuri(name), "&version=", HTTP.escapeuri(version))
    return http_get_json(search_url)
end

## register model as 'code repo release'
"""
    register_github_model(model_config, scrc_access_tkn; ... )
    register_github_model(model_name, model_version, model_repo, scrc_access_tkn; ... )

Register model as a `code_repo_release` in the SCRC data registry, from GitHub (default) or another source.

If used, the `model_config` file should include (at a minimum) the ``model_name``, ``model_version`` and ``model_repo`` fields. Else these can be passed directly to the function.

**Parameters**
- `model_config`        -- path to the model config .yaml file.
- `model_name`          -- label for the model release.
- `model_version`       -- version number in the format 'n.n.n', e.g. ``0.0.1``.
- `model_repo`          -- url of the model [e.g. GitHub] repo.
- `scrc_access_tkn`     -- access token (see https://data.scrc.uk/docs/.)
- `model_description`   -- (optional) description of the model.
- `model_website`       -- (optional) website, e.g. for an accompanying paper, blog, or model documentation.
"""
function register_github_model(model_name::String, model_version::String, model_repo::String,
    model_hash::String, scrc_access_tkn::String; model_description::String=DF_MODEL_REL_DESC,
    model_website::String=model_repo, storage_root_url="https://github.com/", storage_root_id=STR_RT_GITHUB)

    ## UPDATE: check name/version
    crr_chk = search_code_repo_release(model_name, model_version)
    sl_path = replace(model_repo, storage_root_url => "")
    if crr_chk["count"] == 0
        obj_id = insert_storage_location(sl_path, model_hash, model_description, storage_root_id, scrc_access_tkn)
        ## register release
        body = (name=model_name, version=model_version, object=obj_id, website=model_website)
        resp = http_post_data("code_repo_release", body, scrc_access_tkn)
        println("NB. new code repo release registered. URI := ", resp["url"])
        return resp["url"]
    else
        ## check model_repo is the same
        # NB. check SR match?
        resp = http_get_json(crr_chk["results"][1]["object"])
        resp = http_get_json(resp["storage_location"])
        sl_path  == resp["path"] || println("WARNING: repo mismatch detected := ", sl_path, " != ", resp["path"])
        println("NB. code repo release := ", crr_chk["results"][1]["url"])
        return crr_chk["results"][1]["url"]
    end
    # ## check storage location
    # sl_path = replace(model_repo, storage_root_url => "")
    # resp = search_storage_location(sl_path, model_hash, storage_root_id)
    # if resp["count"] == 0  ## add storage location
    #     obj_id = insert_storage_location(sl_path, model_hash, model_description, storage_root_id, scrc_access_tkn)
    #     ## register release
    #     body = (name=model_name, version=model_version, object=obj_id, website=model_website)
    #     resp = http_post_data("code_repo_release", body, scrc_access_tkn)
    #     println("NB. code repo release URI := ", resp["url"])
    #     return resp["url"]
    # else                ## match found, return object id
    #     sl_id = resp["results"][1]["url"]
    #     obj_search = string(API_ROOT, "object/?storage_location=", get_id_from_root(sl_id, SL_ROOT))
    #     resp = http_get_json(obj_search)
    #     return resp["results"][1]["code_repo_release"]
    # end
end

## register by config file
# - returns code_repo_release uri
function register_github_model(model_config::String, scrc_access_tkn::String;
    storage_root_url="https://github.com/", storage_root_id=STR_RT_GITHUB)

    model_hash = get_file_hash(model_config)
    ## read optional params
    mc = YAML.load_file(model_config)
    model_description = haskey(mc, "model_description") ? mc["model_description"] : DF_MODEL_REL_DESC
    model_website = haskey(mc, "model_website") ? mc["model_website"] : mc["model_repo"]
    ## call function
    return register_github_model(mc["model_name"], mc["model_version"], mc["model_repo"], model_hash,
        scrc_access_tkn, model_description=model_description, model_website=model_website,
        storage_root_url=storage_root_url, storage_root_id=storage_root_id)
end

## insert text file
function insert_text_file(text::String, description::String, hash_val::String, scrc_access_tkn::String)
    ## add, e.g. model config, as text file
    body = Dict("text"=>text)
    resp = http_post_data("text_file", body, scrc_access_tkn)
    tf_id = resp["url"]
    path = get_id_from_root(tf_id, TF_ROOT)#, "/?format=text")
    ## add storage location
    body = Dict("path"=>path, "hash"=>hash_val, "storage_root"=>STR_RT_TEXTFILE)
    resp = http_post_data("storage_location", body, scrc_access_tkn)
    sl_id = resp["url"]
    ## add object and return id
    body = (description=description, storage_location=sl_id)
    resp = http_post_data("object", body, scrc_access_tkn)
    return resp["url"]
end

"""
    register_text_file(text, code_repo_release_uri, model_run_description, scrc_access_tkn, search=true)

Post an entry to the ``text_file`` endpoint of the SCRC Data Registry.

Note that according to the docs, "".

**Parameters**
- `text`            -- text file contents.
- `description`     -- object description.
- `scrc_access_tkn` -- access token (see https://data.scrc.uk/docs/.)
- `search`          -- (optional, default=`true`) check for existing entry by path and file hash.
- `hash_val`        -- (optional) specify the file hash, else it is computed based on `text`.
"""
function register_text_file(text::String, description::String, scrc_access_tkn::String, search::Bool=true, hash_val::String=bytes2hex(SHA.sha1(text)))
    tf_sr_id = get_id_from_root(STR_RT_TEXTFILE, STR_ROOT)
    ## check storage location
    search_url = string(API_ROOT, "storage_location/?hash=", hash_val, "&storage_root=", tf_sr_id)
    resp = http_get_json(search_url)
    search_cnt::Int64 = resp["count"]
    if search_cnt == 0              ## no matching entry found, insert new one
        return insert_text_file(text, description, hash_val, scrc_access_tkn)
    else                            ## else get existing text file object uri
        for i in 1:search_cnt
            txt_search = string(API_ROOT, "text_file/", resp["results"][i]["path"])
            try
                rs = http_get_json(txt_search)
                if text == rs["text"]
                    sl_id = resp["results"][i]["url"]
                    obj_search = string(API_ROOT, "object/?storage_location=", get_id_from_root(sl_id, SL_ROOT))
                    return http_get_json(obj_search)["results"][1]["url"]
                end
            catch err
                isa(err, HTTP.ExceptionRequest.StatusError) || rethrow(err)
                # println(" WARNING api error: ", txt_search)
            end
        end     ## no match found
        return insert_text_file(text, description, hash_val, scrc_access_tkn)
    end
end

## (register) fetch model config id
function search_model_config(model_config::String, scrc_access_tkn::String; add_description::String="Model config file.")
    fh = get_file_hash(model_config)
    tf_rt = get_id_from_root(STR_RT_TEXTFILE, STR_ROOT)
    mc_text = read(model_config, String)
    return register_text_file(mc_text, add_description, scrc_access_tkn, true, fh)
end

## register model run as 'code_run'
"""
    register_model_run(model_config, code_repo_release_uri, model_run_description, scrc_access_tkn)

Upload model run to the ``code_run`` endpoint of the SCRC Data Registry.

**Parameters**
- `model_config`            -- path to the model config .yaml file.
- `submission_script_text`  -- e.g. 'julia my/julia/code.jl'.
- `code_repo_release_uri`   -- Data Registry uri of the model ``code_repo_release``, i.e. the model code such as an (already registered) GitHub repo.
- `model_run_description`   -- description of the model run.
- `scrc_access_tkn`         -- access token (see https://data.scrc.uk/docs/.)
"""
function register_model_run(model_config::String, submission_script_text::String, code_repo_release_uri::String, model_run_description::String, scrc_access_tkn::String;
    submission_script_uri::String="")

    rt = Dates.now()
    ## get model config object id
    mc_id = search_model_config(model_config::String, scrc_access_tkn)
    ## get submission script object id
    submission_script_uri = register_text_file(submission_script_text, DF_MR_SUB_SCR_DESC, scrc_access_tkn, true)
    ## get code repo object id
    resp = http_get_json(code_repo_release_uri)
    repo_obj_id = resp["object"]

    ## inputs / outputs - TBA ****
    # - OBJECT COMPONENTS
    # body = (object=run_obj_id, name=inputs, description=)
    # resp = http_post_data("object_component", body, scrc_access_tkn)
    inputs = []
    outputs = []

    body = (run_date=rt, description=model_run_description, code_repo=repo_obj_id, model_config=mc_id, submission_script=submission_script_uri, inputs=inputs, outputs=outputs)
    resp = http_post_data("code_run", body, scrc_access_tkn)
    return resp["url"]
end

### END


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
        return get_ns_cd(dpd["use"]["namespace"])
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
# - TBA: error handling and default yaml properties
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
    return (dp_name=dpnms, dp_file=fps, dp_hash=fhs, dp_version=dp_version, config=data)
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
- `db_path`             -- (optional) specify the filepath of the database to use (or create.)
- `force_db_refresh`    -- overide filehash check on database insert.
- 'access_log_path'     -- filepath of .yaml access log.
- `verbose`             -- set to `true` to show extra output in the console.
"""
function fetch_data_per_yaml(yaml_filepath::String, out_dir::String = DATA_OUT; use_axis_arrays::Bool=false,
    use_sql::Bool = false, sql_file::String="", db_path::String=string(string(rstrip(out_dir, '/'), "/"), basename(yaml_filepath), ".db"),
    force_db_refresh::Bool=false, access_log_path::String=string(rstrip(out_dir, '/'), "/access-log.yaml"), verbose::Bool=false)

    st = Dates.now()                                        # initialise
    out_dir = string(rstrip(out_dir, '/'), "/")
    md = process_yaml_file(yaml_filepath, out_dir, verbose) # read yaml
    function write_log()                                    # write access log
        # TO DO: version #s? ***
        run_md = Dict("open_timestamp"=>st, "close_timestamp"=>Dates.now(), "data_directory"=>out_dir)
        YAML.write_file(access_log_path, Dict("run_metadata"=>run_md, "config"=>md.config))
    end
    if use_sql                                          # SQLite connection
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
        write_log()
        return output
    else                            # return data in memory
        output = Dict()
        for i in eachindex(md.dp_name)
            dp = read_data_product_from_file(md.dp_file[i]; verbose)
            output[md.dp_name[i]] = dp
        end
        write_log()
        return output
    end
end

export fetch_data_per_yaml, read_data_product_from_file
export read_estimate, read_table
export register_github_model, register_model_run, register_text_file

end # module
