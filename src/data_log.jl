#### access logs ####

## initialise and return log id
function initialise_data_log(cn::SQLite.DB, offline_mode::Bool=false)
    ## CLEAR PREVIOUS HERE? ***
    stmt = SQLite.Stmt(cn, "INSERT INTO access_log(offline_mode) VALUES(?)")
    SQLite.DBInterface.execute(stmt, (offline_mode, ))
    output = SQLite.last_insert_rowid(cn)
    println("NB. data log initialised, log_id := ", output)
    return output
end

## fetch active log id - NEED TO RESTRICT
function get_log_id(cn::SQLite.DB)
    stmt = SQLite.Stmt(cn, "SELECT ifnull(max(log_id),0) FROM access_log")
    df = SQLite.DBInterface.execute(stmt) |> DataFrames.DataFrame
    return df[1,1]
end

## write data access record
function log_data_access(cn::SQLite.DB, log_id::Int64, sel_vw::String, sql_args::String, vals) #get_log_id(cn::SQLite.DB)
    prepend!(vals, log_id)
    sql = "INSERT INTO access_log_data(log_id, dp_id, comp_id)\nSELECT ?, dp_id, comp_id FROM "
    SQLite.DBInterface.execute(cn, string(sql, sel_vw, "\n", sql_args), vals)
end

## print log to file (internal)
# data_log_path::String=string(rstrip(out_dir, '/'), "/access-log.yaml"),
function print_data_log(cn::SQLite.DB, log_id::Int64, filepath::String)
    ## log metadata (record data dir?)
    stmt = SQLite.Stmt(cn, "SELECT * FROM access_log WHERE log_id=?")
    df = SQLite.DBInterface.execute(stmt, (log_id, )) |> DataFrames.DataFrame
    run_md = Dict("file_type"=>"DataRegistryUtils.jl data access log",
        "open_timestamp"=>df[1,:row_added], "close_timestamp"=>df[1,:log_finished],
        "offline_mode"=>df[1,:offline_mode])#, "data_directory"=>out_dir

    ## retrieve log info
    stmt = SQLite.Stmt(cn, "SELECT * FROM log_component_view WHERE log_id=?")
    df = SQLite.DBInterface.execute(stmt, (log_id, )) |> DataFrames.DataFrame
    ## write to Dicts
    rlog = Dict[]
    for i in 1:DataFrames.nrow(df)
        r = Dict("where"=> Dict("namespace"=>df[i,:namespace], "data_product"=>df[i,:dp_name], "version"=>df[i,:dp_version]), "component"=>df[i,:comp_name])
        push!(rlog, r)
    end
    ## write to file
    YAML.write_file(filepath, Dict("run_metadata"=>run_md, "config"=>Dict("read"=>rlog)))
end

## finalise (i.e. timestamp) data log
function finish_data_log(db::SQLite.DB, log_id::Int64=get_log_id(db::SQLite.DB); filepath::String=nothing)
    ## check for active logs to finish
    sel_stmt = SQLite.Stmt(db, "SELECT *, (log_finished IS NULL) AS active FROM access_log WHERE log_id=?")
    df = SQLite.DBInterface.execute(sel_stmt, (log_id, )) |> DataFrames.DataFrame
    ## verify
    if DataFrames.nrow(df)==0
        # - NB. THROW ERROR? ***
        println("ERROR: no matching log found for log_id := ", log_id)
        return -1
    else
        if df[1,:active]==1
            ## finish here ********
            stmt = SQLite.Stmt(db, "UPDATE access_log SET log_finished=CURRENT_TIMESTAMP WHERE log_id=?")
            SQLite.DBInterface.execute(stmt, (log_id, ))
        else
            println("WARNING: log already finished on", df[1,:log_finished])
        end
        isnothing(filepath) || print_data_log(db, log_id, filepath)
        return log_id
    end
end
