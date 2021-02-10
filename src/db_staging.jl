### DATA PRODUCT

### CODE REPO RELEASE

## stage data product (internal)
# - low level first (i.e. format agnostic)
function register_data_product(db::SQLite.DB, dp_name::String,
    version::String, filepath::String; namespace="SCRC")

    ## process file and load
    # file_hash =

end

## stage data product (internal)
# - e.g. table, array, kv, etc.
# function register_data_product(db::SQLite.DB,
#     dp_name::String, component::String, version::String,
#     data::Array, titles::Array{String,1}, names::Array{Array,1};
#     namespace="SCRC", data_dir=get_session_data_dir(db))
#
#     ## convert data
# end

## stage model as 'code repo release' (internal)
function stage_github_model(db::SQLite.DB, model_name::String, model_version::String, model_repo::String,
    model_hash::String; model_description::String=DF_MODEL_REL_DESC, model_website::String=model_repo
    , storage_root_url="https://github.com/", storage_root_id=STR_RT_GITHUB)

    ## search local db:
    sel_stmt = SQLite.Stmt(db, "SELECT crr_id, crr_repo, registered FROM code_repo_rel WHERE crr_name=? AND crr_version=?")
    df = SQLite.DBInterface.execute(sel_stmt, (model_name, model_version)) |> DataFrames.DataFrame
    if DataFrames.nrow(df)==0   # stage model
        ins_stmt = SQLite.Stmt(db, "INSERT INTO code_repo_rel(crr_name, crr_version, crr_repo, crr_hash, crr_desc, crr_website, storage_root_url, storage_root_id) VALUES(?,?,?,?,?,?,?,?)")
        SQLite.DBInterface.execute(ins_stmt, (model_name, model_version, model_repo, model_hash, model_description, model_website, storage_root_url, storage_root_id))
        return SQLite.last_insert_rowid(db)
    else                        # else return db staging id
        msg = string("WARNING: this model name and version are already ", df[1,:registered]==0 ? "staged" : "registered", " as repo :=\n - ", df[1,:crr_repo])
        model_repo==df[1,:crr_repo] || println(msg)
        return df[1,:crr_id]
    end
end

## stage by congig file
"""
    register_github_model(model_config, scrc_access_tkn; ... )
    register_github_model(db, model_config, scrc_access_tkn; ... )
    register_github_model(db, model_name, model_version, model_repo, scrc_access_tkn; ... )

Stage model code as a `code_repo_release` for upload the SCRC data registry.

The staged `code_repo_release` can then be pushed to the main Data Registry using e.g. the `commit_staged_model` function. If used, the `model_config` file should include (at a minimum) the ``model_name``, ``model_version`` and ``model_repo`` fields. Else these can be passed directly to the function.

**Parameters**
- `db`                  -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `model_config`        -- path to the model config .yaml file.
- `model_name`          -- label for the model release.
- `model_version`       -- version number in the format 'n.n.n', e.g. ``0.0.1``.
- `model_repo`          -- url of the model [e.g. GitHub] repo.
- `model_hash`          -- arbitrary identifying 'hash' string of the model.
**Named parameters**
- `model_description`   -- (optional) description of the model.
- `model_website`       -- (optional) website, e.g. for an accompanying paper, blog, or model documentation -- `model_repo` by default.
- `storage_root_url`    -- E.g. `"https://github.com/"` -- also the default.
- `storage_root_id`     -- Data Registry storage root identifier, `"https://data.scrc.uk/api/storage_root/11/"` by default.

"""
function register_github_model(db::SQLite.DB, model_config::String;
    storage_root_url="https://github.com/", storage_root_id=STR_RT_GITHUB)

    model_hash = get_file_hash(model_config)
    ## read optional params
    mc = YAML.load_file(model_config)
    model_description = haskey(mc, "model_description") ? mc["model_description"] : DF_MODEL_REL_DESC
    model_website = haskey(mc, "model_website") ? mc["model_website"] : mc["model_repo"]
    ## call function
    return stage_github_model(db, mc["model_name"], mc["model_version"], mc["model_repo"], model_hash,
        model_description=model_description, model_website=model_website,
        storage_root_url=storage_root_url, storage_root_id=storage_root_id)
end

## register staged model
# ADD DOCS ****
function commit_staged_model(db::SQLite.DB, staging_id::Int64, scrc_access_tkn::String)
    sel_stmt = SQLite.Stmt(db, "SELECT * FROM code_repo_rel WHERE crr_id=?")
    df = SQLite.DBInterface.execute(sel_stmt, (staging_id, )) |> DataFrames.DataFrame
    if DataFrames.nrow(df)==0   # handle bad id
        println("ERROR: model id not recognised")
        return nothing
    else
        ## check [internal] registry status
        if df[1, :registered]==0    # commit to registry
            return commit_github_model(df[1,:crr_name], df[1,:crr_version], df[1,:crr_repo],
                df[1,:crr_hash], scrc_access_tkn, df[1,:crr_desc], df[1,:crr_website],
                df[1,:storage_root_url], df[1,:storage_root_id])
        else                        # found:
            println("NB. model code already registered as := ", df[1,:crr_url])
            return df[1,:crr_url]
        end
    end
end

## register staged model
# function register_staged_model(db::SQLite.DB, staging_id::Int64, scrc_access_tkn::String)
#     sel_stmt = SQLite.Stmt(db, "SELECT * FROM code_repo_rel WHERE crr_id=?")
#     df = SQLite.DBInterface.execute(sel_stmt, (staging_id, )) |> DataFrames.DataFrame
#     if DataFrames.nrow(df)==0
#         ## ADD ERR HANDLING
#     else
#         ## call function
#         return register_github_model(df[1,"model_name"], df[1,"model_version"], df[1,"model_repo"], model_hash,
#             scrc_access_tkn, model_description, model_website,
#             storage_root_url, storage_root_id)
#     end
# end

#########################################################

## stage model run as 'code_run'
"""
    register_model_run(db, model_staging_id, submission_script_text, model_run_description)

Stage a model run for subsequent upload to the ``code_run`` endpoint of the SCRC Data Registry.

**Parameters**
- `db`                      -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `model_id`                -- [Internal] model id.
- `model_config`            -- path to the model config .yaml file.
- `submission_script_text`  -- e.g. 'julia my/julia/code.jl'.
- `model_run_description`   -- description of the model run.
"""
function register_model_run(db::SQLite.DB, model_id::Int64, model_config::String, submission_script_text::String, model_run_description::String)
    ins_stmt = SQLite.Stmt(db, "INSERT INTO code_run(crr_id, model_config, run_desc, ss_text) VALUES(?,?,?,?)")
    SQLite.DBInterface.execute(ins_stmt, (model_id, model_config, model_run_description, submission_script_text))
    return SQLite.last_insert_rowid(db)
end

## TBA: for already registered model (online only)
# - `code_repo_release_url`   -- Data Registry uri of the model ``code_repo_release``, i.e. the model code such as an (already registered) GitHub repo.
# function fetch_registered_model_id(code_repo_release_url)
# end

## register staged run as 'code_run' -> INTERNAL ***
"""
    commit_staged_run(model_config, code_repo_release_uri, model_run_description, scrc_access_tkn)

Upload model run to the ``code_run`` endpoint of the SCRC Data Registry.

**Parameters**
- `db`                      -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `model_config`            -- path to the model config .yaml file.
- `submission_script_text`  -- e.g. 'julia my/julia/code.jl'.
- `scrc_access_tkn`         -- access token (see https://data.scrc.uk/docs/.)
"""
function commit_staged_run(db::SQLite.DB, staging_id::Int64, scrc_access_tkn::String)
    ## register / fetch model release url
    function get_crr_url(crr_id)
        sl_stmt = SQLite.Stmt(db, "SELECT * FROM code_repo_rel WHERE crr_id=?")
        df = SQLite.DBInterface.execute(sl_stmt, (crr_id, )) |> DataFrames.DataFrame
        if df[1,:registered]==1
            return df[1,:crr_url]
        else
            ## call function
            crr_url = commit_github_model(df[1,:crr_name], df[1,:crr_version], df[1,:crr_repo],
                df[1,:crr_hash], scrc_access_tkn, df[1,:crr_desc], df[1,:crr_website],
                df[1,:storage_root_url], df[1,:storage_root_id])
            ## update db and return
            upd_stmt = SQLite.Stmt(db, "UPDATE code_repo_rel SET registered=?, crr_url=? WHERE crr_id=?")
            SQLite.DBInterface.execute(upd_stmt, (true, crr_url, staging_id))
            return crr_url
        end
    end
    ## search for staged model run:
    sel_stmt = SQLite.Stmt(db, "SELECT * FROM code_run WHERE run_id=?")
    dff = SQLite.DBInterface.execute(sel_stmt, (staging_id, )) |> DataFrames.DataFrame
    m_url = get_crr_url(dff[1,:crr_id])
    ## run
    if DataFrames.nrow(dff)==0
        ## ADD ERROR HANDLING
        println("WARNING - RUN STAGING ID: ", staging_id, " NOT RECOGNISED")
    else
        run_url = register_model_run(dff[1,:model_config], dff[1,:ss_text], m_url, dff[1,:run_desc], scrc_access_tkn)
        upd_stmt = SQLite.Stmt(db, "UPDATE code_run SET registered=?, run_url=? WHERE run_id=?")
        SQLite.DBInterface.execute(upd_stmt, (true, run_url, staging_id))
        return run_url
    end
end

## print staging status
# NB. to do: docs ***
# NB. use pretty tables?
function registry_commit_status(db::SQLite.DB)
    ## data products
    ## models and runs
    sl_stmt = SQLite.Stmt(db, string("SELECT * FROM crr_view")) # WHERE registered=FALSE
    df = SQLite.DBInterface.execute(sl_stmt) |> DataFrames.DataFrame
    println(df)
end
# h = ["θ", "E[θ]", ":σ", "E[f(θ)]", ":σ", "SRE", "SRE975"]
#         PrettyTables.pretty_table(d, h)

## register all staged objects
# NB. to do: docs ***
# function commit_all_to_registry(df::DataFrames.DataFrame)
# end

## register everything
# function register_all_staged(db::SQLite.DB; since=nothing)
#     sl_stmt(tbl) = SQLite.Stmt(db, string("SELECT * FROM ", tbl, " WHERE registered=FALSE")
#     df = SQLite.DBInterface.execute(sl_stmt("code_run")) |> DataFrames.DataFrame
#     for i in 1:DataFrames.nrow(df)  ## register model runs
#
#     end
#     ## register leftover models
#     df = SQLite.DBInterface.execute(sl_stmt("code_repo_rel")) |> DataFrames.DataFrame
#     for i in 1:DataFrames.nrow(df)  ## register model runs
#
#     end
# end
