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

## check data products
function search_data_product(namespace::String, name::String, version::String)
    search_url = string(API_ROOT, "data_product/?namespace=", HTTP.escapeuri(namespace), "&name=", HTTP.escapeuri(name), "&version=", HTTP.escapeuri(version))
    return http_get_json(search_url)
end

## register data product (internal use only)
function register_data_product(namespace::String, name::String, version::String,
    path::String, file_hash::String, description::String, scrc_access_tkn::String,
    storage_root_id::String) #storage_root_url::String

    ## FTP file fn here?

    ## search
    chk = search_data_product(namespace, name, version)
    if chk["count"] == 0
        ## register storage location
        obj_url = insert_storage_location(path, hash, description, storage_root_id, scrc_access_tkn)
        ## register dp
        body = (namespace=namespace, name=name, version=version, object=obj_url)
        resp = http_post_data("data_product", body, scrc_access_tkn)
        println("NB. new data found registered. URI := ", resp["url"])
        return resp["url"]
    else
        ## check hash
        resp = http_get_json(chk["results"][1]["object"])
        resp = http_get_json(resp["storage_location"])
        file_hash == resp["hash"] || println("WARNING: hash mismatch detected :=\n - ", sl_path, "\n -- ", file_hash, "\n - ", chk["results"][1]["url"], " -- ". resp["hash"])
        return chk["results"][1]["url"]
    end

end

## register 'GitHub model' i.e. code repo release (internal use only)
function commit_github_model(model_name::String, model_version::String, model_repo::String,
    model_hash::String, scrc_access_tkn::String, model_description::String,
    model_website::String, storage_root_url::String, storage_root_id::String)

    ## UPDATED: check name/version
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

end

## no-SQL register by config file -> for workflow using fetch_registered_model_id()
# NB. docs now merged with SQL-function
# - returns code_repo_release uri
# register_github_model(model_name, model_version, model_repo, model_hash, scrc_access_tkn; ... )
# - `model_name`          -- label for the model release.
# - `model_version`       -- version number in the format 'n.n.n', e.g. ``0.0.1``.
# - `model_repo`          -- url of the model [e.g. GitHub] repo.
# - `model_hash`          -- arbitrary identifying 'hash' string of the model.
# - `model_description`   -- (optional) description of the model.
# - `model_website`       -- (optional) website, e.g. for an accompanying paper, blog, or model documentation.
# """
#     register_github_model(model_config, scrc_access_tkn; ... )
#
# Register model as a `code_repo_release` in the SCRC data registry, from GitHub (default) or another source.
#
# The `model_config` file should include (at a minimum) the ``model_name``, ``model_version`` and ``model_repo`` fields.
#
# **Parameters**
# - `model_config`        -- path to the model config .yaml file.
# - `scrc_access_tkn`     -- access token (see https://data.scrc.uk/docs/.)
# **Named parameters**
# - `storage_root_url`    -- E.g. `"https://github.com/"` -- also the default.
# - `storage_root_id`     -- Data Registry storage root identifier, `"https://data.scrc.uk/api/storage_root/11/"` by default.
# """
function register_github_model(model_config::String, scrc_access_tkn::String;
    storage_root_url="https://github.com/", storage_root_id=STR_RT_GITHUB)

    model_hash = get_file_hash(model_config)
    ## read optional params
    mc = YAML.load_file(model_config)
    model_description = haskey(mc, "model_description") ? mc["model_description"] : DF_MODEL_REL_DESC
    model_website = haskey(mc, "model_website") ? mc["model_website"] : mc["model_repo"]
    ## call function
    return commit_github_model(mc["model_name"], mc["model_version"], mc["model_repo"], model_hash,
        scrc_access_tkn, model_description, model_website,
        storage_root_url, storage_root_id)
end

# INSERT INTO code_repo_rel(crr_name, crr_version, crr_repo, crr_desc, crr_website, registered)

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

## NB. stage these?
# """
#     register_text_file(text, code_repo_release_uri, model_run_description, scrc_access_tkn, search=true)
#
# Post an entry to the ``text_file`` endpoint of the SCRC Data Registry.
#
# Note that according to the docs, "".
#
# **Parameters**
# - `text`            -- text file contents.
# - `description`     -- object description.
# - `scrc_access_tkn` -- access token (see https://data.scrc.uk/docs/.)
# - `search`          -- (optional, default=`true`) check for existing entry by path and file hash.
# - `hash_val`        -- (optional) specify the file hash, else it is computed based on `text`.
# """
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
# """
#     register_model_run(model_config, code_repo_release_uri, model_run_description, scrc_access_tkn)
#
# Upload model run to the ``code_run`` endpoint of the SCRC Data Registry.
#
# **Parameters**
# - `model_config`            -- path to the model config .yaml file.
# - `submission_script_text`  -- e.g. 'julia my/julia/code.jl'.
# - `code_repo_release_uri`   -- Data Registry uri of the model ``code_repo_release``, i.e. the model code such as an (already registered) GitHub repo.
# - `model_run_description`   -- description of the model run.
# - `scrc_access_tkn`         -- access token (see https://data.scrc.uk/docs/.)
# """
function register_model_run(model_config::String, submission_script_text::String
    , code_repo_release_uri::String, model_run_description::String, scrc_access_tkn::String)

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
