### STORAGE ROOTS
function get_storage_root(storage_root_id, offline_mode=false)

end

### STORAGE LOCATIONS
# function register_data_product(db::SQLite.DB,

### DATA PRODUCT

## stage data product (internal)
# - low level first (i.e. format agnostic)
"""
    register_data_product(db, dp_name, version, filepath; namespace="SCRC")

Stage a data set (i.e. a local file) for upload to the ``data_product`` endpoint of the SCRC Data Registry.

**Parameters**
- `db`              -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `dp_name`         -- data product name.
- `version`         -- e.g. `"0.0.1"`
- `filepath`        -- path of the e.g. HDF5 file.
- `namespace`       -- (optionally) specify the namespace, `"SCRC"` by default.
- `storage_root_id` -- Data Registry storage root identifier, `"https://data.scrc.uk/api/storage_root/11/"` (GitHub) by default.
"""
function register_data_product(db::SQLite.DB, dp_name::String,
    version::String, filepath::String; namespace="SCRC", description="",
    storage_location_id=nothing, storage_root_id=STR_RT_BOYDORR, remote_path=dp_name,
    check_hash=true, ftp_transfer=storage_root_id==STR_RT_BOYDORR)

    ## storage
    isnothing(storage_location_id)
    # -

    ## hash search
    fh = get_file_hash(filepath)
    if check_hash
        sel_stmt = SQLite.Stmt(db, "SELECT dp_id, dp_name, namespace, registered FROM data_product WHERE dp_hash=?")
        df = SQLite.DBInterface.execute(sel_stmt, (fh, )) |> DataFrames.DataFrame
        if DataFrames.nrow(df)>0   # stage data product
            println("WARNING: a file with this checksum is already ", df[1,:registered]==0 ? "staged" : "registered", " as :=\n - ", df[1,:dp_name], "in the ", namespace, "namespace")
            # model_repo==df[1,:crr_repo] || println(msg)
            return df[1,:dp_id]
        end
    end
    ## search local db:
    sel_stmt = SQLite.Stmt(db, "SELECT dp_id, registered FROM data_product WHERE dp_name=? AND dp_version=?")
    df = SQLite.DBInterface.execute(sel_stmt, (dp_name, version)) |> DataFrames.DataFrame
    if DataFrames.nrow(df)==0   # stage data product
        ins_stmt = SQLite.Stmt(db, "INSERT INTO data_product(namespace, dp_name, filepath, dp_hash, dp_version, sr_url, sl_path, description) VALUES(?,?,?,?,?,?,?,?)")
        SQLite.DBInterface.execute(ins_stmt, (namespace, dp_name, filepath, fh, version, storage_root_id, remote_path, description))
        return SQLite.last_insert_rowid(db)
    else                        # else return db staging id
        println("WARNING: this data product name and version is already ", df[1,:registered]==0 ? "staged" : "registered")
        return df[1,:dp_id]
    end
end
## NB. add FTP staging table? ***

## register staged model
"""
    commit_staged_data_product(db, staging_id, scrc_access_tkn)

Commit staged [local] file to the ``data_product`` endpoint of the SCRC Data Registry.

**Parameters**
- `db`                      -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `staging_id`              -- data product id, obtained when the model was [pre-]registered.
- `scrc_access_tkn`         -- access token (see https://data.scrc.uk/docs/.)
"""
function commit_staged_data_product(db::SQLite.DB, staging_id::Integer,
    scrc_access_tkn::String, ftp_username=nothing, ftp_password=nothing)

    sel_stmt = SQLite.Stmt(db, "SELECT * FROM data_product WHERE dp_id=?")
    df = SQLite.DBInterface.execute(sel_stmt, (staging_id, )) |> DataFrames.DataFrame
    if DataFrames.nrow(df)==0   # handle bad id
        println("ERROR: id not recognised")
        return nothing
    else
        ## check [internal] registry status
        if df[1, :registered]==0    # commit to registry
            ## ftp transfer
            if !isnothing(ftp_username)
                ftp_transfer_file(storage_root_id, local_path, name, ftp_username, ftp_password)
            end
            ## commit to registry
            return commit_data_product(df[1,:namespace], df[1,:dp_name], df[1,:version],
                df[1,:version]local_path, df[1,:dp_hash], df[1,:description], scrc_access_tkn,
                df[1,:sr_url], check_hash)
        else                        # found:
            println("NB. already registered as := ", df[1,:dp_url])
            return df[1,:dp_url]
        end
    end
end

### CODE REPO RELEASES

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
# - `storage_root_url`    -- E.g.  -- also the default.
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
- `storage_root_id`     -- Data Registry storage root identifier, `"https://data.scrc.uk/api/storage_root/11/"` (GitHub) by default.
"""
function register_github_model(db::SQLite.DB, model_config::String; storage_root_id=STR_RT_GITHUB)
    # storage_root_url="https://github.com/",
    storage_root_url = get_storage_root(storage_root_id)

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
"""
    commit_staged_model(db, staging_id, scrc_access_tkn)

Upload model run to the ``code_run`` endpoint of the SCRC Data Registry.

**Parameters**
- `db`                      -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `staging_id`              -- model id, obtained when the model was [pre-]registered.
- `scrc_access_tkn`         -- access token (see https://data.scrc.uk/docs/.)
"""
function commit_staged_model(db::SQLite.DB, staging_id::Integer, scrc_access_tkn::String)
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
# function register_staged_model(db::SQLite.DB, staging_id::Integer, scrc_access_tkn::String)
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
    register_model_run(db, model_id, model_config, submission_script_text, model_run_description)

Stage a model run for subsequent upload to the ``code_run`` endpoint of the SCRC Data Registry.

**Parameters**
- `db`                      -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `model_id`                -- [Internal] model id.
- `model_config`            -- path to the model config .yaml file.
- `submission_script_text`  -- e.g. 'julia my/julia/code.jl'.
- `model_run_description`   -- description of the model run.
"""
function register_model_run(db::SQLite.DB, model_id::Integer, model_config::String, submission_script_text::String, model_run_description::String)
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
    commit_staged_run(db, staging_id, scrc_access_tkn)

Upload model run to the ``code_run`` endpoint of the SCRC Data Registry.

**Parameters**
- `db`                      -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `staging_id`              -- run id, obtained when the run was [pre-]registered.
- `scrc_access_tkn`         -- access token (see https://data.scrc.uk/docs/.)
"""
function commit_staged_run(db::SQLite.DB, staging_id::Integer, scrc_access_tkn::String)
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
        println("NB. model run registered as := ", run_url)
        return run_url
    end
end

## print staging status
"""
    registry_commit_status(db)

Display the current commit status of the local staging Registry.

**Parameters**
- `db`                      -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
"""
function registry_commit_status(db::SQLite.DB)
    ## data products
    ## models and runs
    sl_stmt = SQLite.Stmt(db, string("SELECT * FROM crr_view")) # WHERE registered=FALSE
    df = SQLite.DBInterface.execute(sl_stmt) |> DataFrames.DataFrame
    println(df)
    DataFrames.nrow(df)==0 || println("Hint: use `DataRegistryUtils.commit_all(...)` to commit staged objects.")
end
# h = ["θ", "E[θ]", ":σ", "E[f(θ)]", ":σ", "SRE", "SRE975"]
#         PrettyTables.pretty_table(d, h)

## register all staged objects
# NB. to do: docs ***
# function commit_all_to_registry(df::DataFrames.DataFrame)
# end

## register everything
"""
    commit_all(db, scrc_access_tkn)

Commit all outstanding (i.e. 'staged') objects to the Data Registry.

**Parameters**
- `db`                  -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `scrc_access_tkn`     -- access token (see https://data.scrc.uk/docs/.)
- `ftp_username`        -- optionally specify
- `ftp_password`        -- optionally specify
"""
function commit_all(db::SQLite.DB, scrc_access_tkn::String, ftp_username=nothing, ftp_password=nothing; since=nothing)
    sl_stmt(col, tbl) = SQLite.Stmt(db, string("SELECT ", col, " FROM ", tbl, " WHERE registered=FALSE"))
    println("Checking for staged objects...")
    ## register data products
    df = SQLite.DBInterface.execute(sl_stmt("dp_id", "data_product")) |> DataFrames.DataFrame
    for i in 1:DataFrames.nrow(df)
        commit_staged_data_product(db, df[i,:dp_id], scrc_access_tkn, ftp_username, ftp_password)
    end
    ## register model runs
    df = SQLite.DBInterface.execute(sl_stmt("run_id", "code_run")) |> DataFrames.DataFrame
    for i in 1:DataFrames.nrow(df)
        commit_staged_run(db, df[i,:run_id], scrc_access_tkn)
    end
    ## register leftover models
    df = SQLite.DBInterface.execute(sl_stmt("crr_id", "code_repo_rel")) |> DataFrames.DataFrame
    for i in 1:DataFrames.nrow(df)
        commit_staged_model(db, df[i,:run_id], scrc_access_tkn)
    end
    println(" - finished.")
end
