import SQLite
import DataFrames

## ddl SQL
include("../db/ddl.sql")

# const DB_TYPE_MAP = Dict(String => "TEXT", Int32 => "INTEGER", Float64 => "REAL")
const DB_FLAT_ARR_APX = "_arr"
const DB_H5_TABLE_APX = "_tbl"
const DB_CSV_TABLE_APX = "_csv"

# const DB_VAL_COL = "val"

## insert sql helper
# function get_values_str(n::Int64)
#     output = "VALUES("
#     for i in 1:n
#         output = string(output, "?,")
#     end
#     return string(rstrip(output, ','), ")")
# end

##
function get_session_data_dir(db::SQLite.DB)
    stmt = SQLite.Stmt(db, "SELECT data_dir FROM session_view")
    df = SQLite.DBInterface.execute(stmt) |> DataFrames.DataFrame
    return df[1,1]
end

## split sql statements into array
function get_sql_stmts_from_str(sql::String)
    # sql = strip(replace(read(f, String), "\n" => " "), ' ')
    sql = strip(strip(sql, ' '), '\n')
    return split(rstrip(sql, ';'), ';')
end

## execute sql
function proc_sql!(cn::SQLite.DB, sql::Array{SubString{String},1})
    for i in eachindex(sql)
        SQLite.execute(cn, sql[i])
    end
end

## process statements from single string
function proc_sql_str!(cn::SQLite.DB, sql::String)
    proc_sql!(cn, get_sql_stmts_from_str(sql))
end

## read sql from file
function get_sql_stmts_from_file(fp::String)
    f = open(fp)
    sql = get_sql_stmts_from_str(read(f, String))
    close(f)
    return sql
end

## process sql file
function proc_sql_file!(cn::SQLite.DB, fp::String)
    proc_sql!(cn, get_sql_stmts_from_file(fp))
end

## initialise db from file
function init_yaml_db(db_path::String)
    output = SQLite.DB(db_path)
    proc_sql_str!(output, DDL_SQL)
    return output
end

## load toml data product component
function process_toml_file!(cn::SQLite.DB, filepath::String, dp_id::Int64)
    d = TOML.parsefile(filepath)
    components = collect(keys(d))
    stmt = SQLite.Stmt(cn, "INSERT INTO toml_component(dp_id, comp_name) VALUES(?, ?)")
    kv_stmt = SQLite.Stmt(cn, "INSERT INTO toml_keyval(comp_id, key, val) VALUES(?, ?, ?)")
    for i in eachindex(components)
        SQLite.execute(stmt, (dp_id, components[i]))
        comp_id = SQLite.last_insert_rowid(cn)
        fields = collect(keys(d[components[i]]))
        for f in eachindex(fields)
            SQLite.execute(kv_stmt, (comp_id, fields[f], d[components[i]][fields[f]]))
        end
    end
end

## 'meta' load component from [h5] object d
function meta_load_component!(cn::SQLite.DB, dp_id::Int64, comp_name::String, comp_type::String, data_obj::String, meta_obj::Bool=true)
    stmt = SQLite.Stmt(cn, "INSERT INTO h5_component(dp_id, comp_name, comp_type, meta_src, data_obj) VALUES(?,?,?,?,?)")
    SQLite.execute(stmt, (dp_id, comp_name, comp_type, meta_obj, data_obj))
    return SQLite.last_insert_rowid(cn)
end

## load component from [h5] object d
function load_component!(cn::SQLite.DB, dp_id::Int64, comp_name::String, comp_type::String, tablename::String, d)
    SQLite.drop!(cn, tablename, ifexists=true)
    SQLite.load!(d, cn, tablename)
    return meta_load_component!(cn, dp_id, comp_name, comp_type, tablename, false)
end

## db table labeller
clean_path(x::String) = replace(replace(strip(x, '/'), "/" => "_"), " " => "_")

## format table name
function get_table_name(tablestub::String, gnm::String, apx::String)
    return string(rstrip(string(clean_path(tablestub), "_", clean_path(gnm)), '_'), apx)
end

## recursively search and load table/array
function process_h5_file_group!(cn::SQLite.DB, name::String, h5, dp_id::Int64, verbose::Bool)
    gnm = HDF5.name(h5)
    if haskey(h5, TABLE_OBJ_NAME)
        tablestub = clean_path(name)
        tablename = get_table_name(tablestub, gnm, DB_H5_TABLE_APX)
        d = read_h5_table(h5, false)
        verbose && println(" - loading table := ", tablename)
        load_component!(cn, dp_id, gnm, TABLE_OBJ_NAME, tablename, d)
    elseif (haskey(h5, ARRAY_OBJ_NAME) && typeof(h5[ARRAY_OBJ_NAME])!=HDF5.Group)
        verbose && println(" - array found := ", gnm)
        meta_load_component!(cn, dp_id, gnm, ARRAY_OBJ_NAME, gnm)
    else
        for g in keys(h5)     # group - recurse
            process_h5_file_group!(cn, name, h5[g], dp_id, verbose)
        end
    end
end

## wrapper for recursive processing
function process_h5_file!(cn::SQLite.DB, name::String, filepath::String, dp_id::Int64, verbose::Bool)
    # tablestub = clean_path(name)
    f = HDF5.h5open(filepath)
    process_h5_file_group!(cn, name, f, dp_id, verbose)
    HDF5.close(f)
end

## tabular data
# - NEED TO REDESIGN THIS FOR SEP DB *******
function process_csv_file!(cn::SQLite.DB, filepath::String, dp_id::Int64)
    df = CSV.read(filepath, DataFrames.DataFrame)
    tablestub = clean_path(basename(filepath))
    tablename = string(tablestub, DB_CSV_TABLE_AP)
    load_component!(cn, dp_id, tablestub, CSV_OBJ_NAME, tablename, df)
end

## load yaml data to sqlite db
function load_data_per_yaml(md, db_path::String, force_refresh::Bool, verbose::Bool)
    println(" - checking database: ", db_path)
    output = init_yaml_db(db_path)      # initialise db
    ## for loading dp to db
    sel_stmt = SQLite.Stmt(output, "SELECT * FROM data_product WHERE dp_name=? AND dp_version=? AND dp_hash=? AND dp_hash != ?")
    del_stmt = SQLite.Stmt(output, "DELETE FROM data_product WHERE dp_name=? AND dp_version=?")
    ins_stmt = SQLite.Stmt(output, "INSERT INTO data_product(namespace, dp_name, filepath, dp_hash, dp_version, sr_url, sl_path, description, registered, dp_url) VALUES(?,?,?,?,?,?,?,?,?,?)")
    # function load_data_product!(namespace::String, name::String, filepath::String, filehash::String, version::String, url::String, chk::Bool)
    function load_data_product!(metadata::NamedTuple)
        verbose && println(" - processing file: ", metadata.filepath)
        # println("metadata: ", metadata)
        function insert_dp()            # function: insert dp and return id
            # SQLite.execute(ins_stmt, (namespace, name, filepath, filehash, version, chk, url))
            SQLite.execute(ins_stmt, values(metadata))
            return SQLite.last_insert_rowid(output)
        end
        if !force_refresh               # check hash (unless forced db refresh)
            vals = (metadata.dp_name, metadata.dp_version, metadata.dp_hash, NULL_HASH)
            qr = SQLite.DBInterface.execute(sel_stmt, vals) |> DataFrames.DataFrame
            verbose && println(" - searching db := found ", DataFrames.nrow(qr), " matching, up-to-date data products.")
            DataFrames.nrow(qr) == 0 || (return false)
        end                             # else load from scratch
        SQLite.execute(del_stmt, (metadata.dp_name, metadata.dp_version))
        if HDF5.ishdf5(metadata.filepath) # occursin(".h5", filepath)
            process_h5_file!(output, metadata.dp_name, metadata.filepath, insert_dp(), verbose)
        elseif (occursin(".toml", metadata.filepath) || occursin(".tml", metadata.filepath))
            process_toml_file!(output, metadata.filepath, insert_dp())
        elseif occursin(".csv", metadata.filepath)
            process_csv_file!(output, metadata.filepath, insert_dp())
        else    # TBA: TSV? ***
            metadata.filepath == NULL_FILE || println(" -- WARNING - UNKNOWN FILE TYPE - skipping: ", metadata.filepath)
            return false
        end
        return true
    end
    ## process file metadata
    updated = 0
    for i in eachindex(md.metadata)
        ## get namespace
        # load_data_product!(md.dp_namespace[i], md.dp_name[i], md.dp_file[i], md.dp_hash[i], md.dp_version[i], md.dp_url[i], md.chk[i]) && (updated += 1)
        load_data_product!(md.metadata[i]) && (updated += 1)
    end
    ## clean up
    SQLite.execute(output, "DELETE FROM h5_component WHERE dp_id NOT IN(SELECT DISTINCT dp_id FROM data_product)")
    SQLite.execute(output, "DELETE FROM toml_component WHERE dp_id NOT IN(SELECT DISTINCT dp_id FROM data_product)")
    SQLite.execute(output, "DELETE FROM toml_keyval WHERE comp_id NOT IN(SELECT DISTINCT comp_id FROM toml_component)")
    println(" - finished, ", updated, " data products were updated.")
    return output
end

### helper functions ###

## convert SQL DataFrame |> AxisArray
"""
    get_axis_array(cn::SQLite.DB, dims::Array{String,1}, msr::String, tbl::String)

SQLite Data Registry helper function. Aggregate measure column `msr` from table (or view) `tbl`, along dimension columns specified by `dims` and return the results as an AxisArray.

**Parameters**
- `cn`      -- SQLite.DB object.
- `dims`    -- data product search string, e.g. `"human/infection/SARS-CoV-2/%"`.
- `msr`     -- as above, optional search string for components names.
- `tbl`     -- table or view name.
"""
function get_axis_array(cn::SQLite.DB, dims::Array{String,1}, msr::String, tbl::String)
    sel_sql = ""
    dim_ax = []
    for i in eachindex(dims)
        sel_sql = string(sel_sql, dims[i], ",")
        dim_st = SQLite.Stmt(cn, string("SELECT DISTINCT ", dims[i], " AS val FROM ", tbl, " ORDER BY ", dims[i]))
        dim_vals = SQLite.DBInterface.execute(dim_st) |> DataFrames.DataFrame
        push!(dim_ax, AxisArrays.Axis{Symbol(dims[i])}(dim_vals.val))
    end
    sel_sql = string("SELECT ", sel_sql, " SUM(", msr, ") AS val\nFROM ", tbl, "\nGROUP BY ", rstrip(sel_sql, ','))
    stmt = SQLite.Stmt(cn, sel_sql)
    df = SQLite.DBInterface.execute(stmt) |> DataFrames.DataFrame
    axis_size = Tuple(Int64[length(d) for d in dim_ax])
    data = zeros(typeof(df.val[1]), axis_size)
    ## build and populate array
    output = AxisArrays.AxisArray(data, Tuple(dim_ax))
    for row in eachrow(df)  ## HACK: reminder - figure out how to index n dimension axis array
        length(dims) == 1 && (output[AxisArrays.atvalue(row[Symbol(dims[1])])] = row.val)
        length(dims) == 2 && (output[AxisArrays.atvalue(row[Symbol(dims[1])]), AxisArrays.atvalue(row[Symbol(dims[2])])] = row.val)
        length(dims) == 3 && (output[AxisArrays.atvalue(row[Symbol(dims[1])]), AxisArrays.atvalue(row[Symbol(dims[2])]), AxisArrays.atvalue(row[Symbol(dims[3])])] = row.val)
        length(dims) == 4 && (output[AxisArrays.atvalue(row[Symbol(dims[1])]), AxisArrays.atvalue(row[Symbol(dims[2])]), AxisArrays.atvalue(row[Symbol(dims[3])]), AxisArrays.atvalue(row[Symbol(dims[4])])] = row.val)
    end
    length(dims) > 4 && println("WARNING - AXIS ARRAY NOT POPULATED - ndims > 4 not supported")
    return output
end

## array handling: db metadata => Dict{String, Any}
function read_array(df::DataFrames.DataFrame, use_axis_arrays::Bool, verbose::Bool)
    if DataFrames.nrow(df)==1      # return individual component
        dpp::String = df[1, :filepath]
        output = process_h5_file(dpp, use_axis_arrays, verbose)
        return output[df[1, :data_obj]]
    end
    output = Dict{String, Any}()
    hf = nothing
    for i in 1:DataFrames.nrow(df) # return dictionary of matching components
        proc::Bool = (i==1 || df[i,:filepath]!=df[i-1,:filepath])
        hf = proc ? process_h5_file(df[i,:filepath], use_axis_arrays, verbose) : hf
        output[df[i, :data_obj]] = hf[df[i, :data_obj]]
    end
    return output
end

## array by data product / component name
"""
    read_array(cn::SQLite.DB, data_product::String[, component::String]; use_axis_arrays=false, verbose=false)

Load HDF5 array(s) data resource.

SQLite Data Registry helper function. Optionally specify the individual component.

**Parameters**
- `cn`              -- SQLite.DB object yielded by previous call to `fetch_data_per_yaml`.
- `data_product`    -- data product search string, e.g. `"human/infection/SARS-CoV-2/%"`.
- `component`       -- [optionally] specify the component name.
- `use_axis_arrays` -- set `true` to return the matching data as `AxisArray` types.
"""
function read_array(cn::SQLite.DB, data_product::String, component=nothing;
    use_axis_arrays::Bool=false, verbose::Bool=false, log_access=true, data_log_id=get_log_id(cn::SQLite.DB))

    ## prepare sql
    sel_sql = "SELECT DISTINCT filepath, data_obj FROM h5_view\n"
    sql_args = string("WHERE comp_type=? AND dp_name=?", isnothing(component) ? "" : " AND data_obj=?")
    stmt = SQLite.Stmt(cn, string(sel_sql, sql_args))
    vals = Any[ARRAY_OBJ_NAME, data_product]
    isnothing(component) || push!(vals, component)
    ## execute
    df = SQLite.DBInterface.execute(stmt, vals) |> DataFrames.DataFrame
    if DataFrames.nrow(df)==0
        println("WARNING: no matching data products found for '", data_product, component, "'")
        return nothing
    else # log and return results:
        log_access && log_data_access(cn, data_log_id, "h5_view", sql_args, vals)
        return read_array(df, use_axis_arrays, verbose)
    end
end

# function read_array(cn::SQLite.DB, data_product::String; use_axis_arrays::Bool=false, verbose::Bool=false)
#     stmt = SQLite.Stmt(cn, search_arr_sql)
#     df = SQLite.DBInterface.execute(stmt, (ARRAY_OBJ_NAME, data_product)) |> DataFrames.DataFrame
#     DataFrames.nrow(df)==0 && println("WARNING: no matching data products found for '", data_product, "'")
#     return read_array(df, use_axis_arrays, verbose)
# end

## read .toml estimate
const READ_EST_SQL = "SELECT * FROM toml_view\n"
"""
    read_estimate(cn::SQLite.DB, data_product::String, [component::String]; data_type=nothing)

Read key-value pair, e.g. a point-estimate.

SQLite Data Registry helper function. Search TOML-based data resources stored in `cn`, a SQLite database created previously by a call to `fetch_data_per_yaml`.

**Parameters**
- `cn`              -- SQLite.DB object.
- `data_product`    -- data product search string, e.g. `"human/infection/SARS-CoV-2/%"`.
- `component`       -- as above, [optional] search string for components names.
- `key`             -- (optionally) specify to return .toml keys of a particular type, e.g. `"type"` or `"value"`.
- `data_type`       -- (optionally) specify to return an array of this type instead of a DataFrame.
- `log_access`      -- set `false` to supress data access logging.
- `data_log_id`     -- (optionally) specify the data log id.
"""
function read_estimate(cn::SQLite.DB, data_product::String, component=nothing;
    key=nothing, data_type=nothing, log_access=true, data_log_id=get_log_id(cn::SQLite.DB))

    ## prepare sql
    sql_args = string("WHERE dp_name LIKE ?", isnothing(component) ? "" : " AND comp_name LIKE ?", isnothing(key) ? "" : " AND key = ?")
    # sql = string(READ_EST_SQL, "\nAND comp_name LIKE ?", isnothing(key) ? "" : " AND key = ?")
    vals = Any[data_product]
    isnothing(component) || push!(vals, component)
    isnothing(key) || push!(vals, key)
    # isnothing(key) ? (data_product, component) : (data_product, component, key)
    ## execute
    output = SQLite.DBInterface.execute(cn, string(READ_EST_SQL, sql_args), vals) |> DataFrames.DataFrame
    # - write access log:
    log_access && log_data_access(cn, data_log_id, "toml_view", sql_args, vals)
    ## FN THIS
    # prepend!(vals, data_log_id)
    # sql = "INSERT INTO access_log_data(log_id, dp_id, comp_id)\nSELECT ?, dp_id, comp_id FROM "
    # sel_vw = "toml_view"
    # SQLite.DBInterface.execute(cn, string(sql, sel_vw, "\n", sql_args), vals)

    isnothing(data_type) && return output
    return parse.(data_type, output.val)
end

# function read_estimate(cn::SQLite.DB, data_product::String; key=nothing, data_type=nothing)
#     sql = string(READ_EST_SQL, isnothing(key) ? "" : " AND key = ?")
#     vals = isnothing(key) ? (data_product, ) : (data_product, key)
#     output = SQLite.DBInterface.execute(cn, sql, (data_product, )) |> DataFrames.DataFrame
#     ## write access log here *******
#     isnothing(data_type) && return output
#     return parse.(data_type, output.val)
# end

# - tables
"""
    read_table(cn::SQLite.DB, data_product::String, component::String)

SQLite Data Registry helper function. Search and return [HDF5] table data as a `DataFrame`.

**Parameters**
- `cn`              -- SQLite.DB object.
- `data_product`    -- data product search string, e.g. `"human/infection/SARS-CoV-2/%"`.
- `component`       -- as above, [required] search string for components names.
"""
function read_table(cn::SQLite.DB, data_product::String, component::String;
    log_access=true, data_log_id=get_log_id(cn::SQLite.DB))

    ##
    tablename = get_table_name(data_product, component, DB_H5_TABLE_APX)
    # - write access log:
    # log_access && log_data_access(cn, data_log_id, "toml_view", sql_args, vals)
    stmt = SQLite.Stmt(cn, string("SELECT * FROM ", tablename))
    return SQLite.DBInterface.execute(stmt) |> DataFrames.DataFrame
end
