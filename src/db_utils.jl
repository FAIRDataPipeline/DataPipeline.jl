import SQLite
import DataFrames

# const DDL_SQL = "db/ddl.sql"
include("../db/ddl.sql")

const DB_TYPE_MAP = Dict(String => "TEXT", Int32 => "INTEGER", Float64 => "REAL")
const DB_FLAT_ARR_APX = "_arr"
const DB_H5_TABLE_APX = "_tbl"
const DB_VAL_COL = "val"

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

## load component from [h5] object d
function load_component!(cn::SQLite.DB, dp_id::Int64, tablename::String, d)
    SQLite.drop!(cn, tablename, ifexists=true)
    SQLite.load!(d, cn, tablename)
    stmt = SQLite.Stmt(cn, "INSERT INTO h5_component(dp_id, tbl_name) VALUES(?, ?)")
    SQLite.execute(stmt, (dp_id, tablename))
end

## insert sql helper
function get_values_str(n::Int64)
    output = "VALUES("
    for i in 1:n
        output = string(output, "?,")
    end
    return string(rstrip(output, ','), ")")
end

## placeholder
function flat_load_array!(cn::SQLite.DB, tablestub::String, gnm::String, h5::HDF5.File, verbose::Bool)
    println("*** h5 group type: ", typeof(h5), " - TO BE ADDED ***")
end

## try get dim titles, else give generic column name
function get_dim_title(h5, d::Int64, verbose::Bool)
    ttl = string("Dimension_", d, "_title")
    if haskey(h5, ttl)
        return replace(HDF5.read(h5[ttl])[1], " " => "_");
    else
        cn = string("col", d)
        verbose && println(" - nb. no metadata found for ", cn)
        return cn
    end
end

## try get dim labels, else give generic labels
function get_dim_names(h5, d::Int64, s::Int64)
    nms = string("Dimension_", d, "_names")
    if HDF5.exists(h5, nms)
        return HDF5.read(h5[nms]);
    else
        return String[string("grp", i) for i in 1:s]
    end
end

## db table labeller
clean_path(x::String) = replace(replace(strip(x, '/'), "/" => "_"), " " => "_")

## flatten Nd array and load as 2d table
function flat_load_array!(cn::SQLite.DB, dp_id::Int64, tablename::String, h5::HDF5.Group, verbose::Bool)
    arr = read_h5_array(h5)
    verbose && println(" - loading array : ", size(arr), " => ", tablename)
    nd = ndims(arr)                             # fetch columns names
    dim_titles = String[]
    for d in 1:nd
        push!(dim_titles, clean_path(get_dim_title(h5, d, verbose)))
    end
    push!(dim_titles, DB_VAL_COL)               # measure column
    ## ddl / dml
    idc = Tuple.(CartesianIndices(arr)[:])      # dimension indices
    dims = Array{Array{Any,1}}(undef, nd)
    for d in 1:nd                               # fetch named dimensions
        dim_names = get_dim_names(h5, d, size(arr)[d])
        idx = Int64[t[d] for t in idc]
        dims[d] = dim_names[idx]                # 'named' dimension d
    end
    verbose && println(" - dims := ", typeof(dims))
    df = DataFrames.DataFrame(dims)             # convert to df
    df.val = [arr[i] for i in eachindex(arr)]   # add data
    DataFrames.rename!(df, Symbol.(dim_titles)) # column names
    load_component!(cn, dp_id, tablename, df)   # load to db
end

## format table name
function get_table_name(tablestub::String, gnm::String, apx::String)
    return string(rstrip(string(clean_path(tablestub), "_", clean_path(gnm)), '_'), apx)
end

## recursively search and load table/array
function process_h5_file_group!(cn::SQLite.DB, tablestub::String, h5, dp_id::Int64, verbose::Bool)
    gnm = HDF5.name(h5)
    if Base.haskey(h5, TABLE_OBJ_NAME)
        tablename = get_table_name(tablestub, gnm, DB_H5_TABLE_APX)
        d = read_h5_table(h5, false)
        verbose && println(" - loading table := ", tablename)
        load_component!(cn, dp_id, tablename, d)
    elseif (haskey(h5, ARRAY_OBJ_NAME) && typeof(h5[ARRAY_OBJ_NAME])!=HDF5.Group)
        tablename = get_table_name(tablestub, gnm, DB_FLAT_ARR_APX)
        flat_load_array!(cn, dp_id, tablename, h5, verbose)
    else
        for g in HDF5.names(h5)     # group - recurse
            process_h5_file_group!(cn, tablestub, h5[g], dp_id, verbose)
        end
    end
end

## wrapper for recursive processing
function process_h5_file!(cn::SQLite.DB, name::String, filepath::String, dp_id::Int64, verbose::Bool)
    tablestub = clean_path(name)
    f = HDF5.h5open(filepath)
    process_h5_file_group!(cn, tablestub, f, dp_id, verbose)
    HDF5.close(f)
end

## load yaml data to sqlite db
function load_data_per_yaml(md, db_path::String, force_refresh::Bool, verbose::Bool)
    println(" - checking database: ", db_path)
    output = init_yaml_db(db_path)      # initialise db
    ## for loading dp to db
    sel_stmt = SQLite.Stmt(output, "SELECT * FROM data_product WHERE dp_name = ? AND dp_version = ? AND dp_hash = ? AND dp_hash != ?")
    del_stmt = SQLite.Stmt(output, "DELETE FROM data_product WHERE dp_name = ? AND dp_version = ?")
    ins_stmt = SQLite.Stmt(output, "INSERT INTO data_product(dp_name, dp_path, dp_hash, dp_version) VALUES(?, ?, ?, ?)")
    function load_data_product!(name::String, filepath::String, filehash::String, version::String)
        verbose && println(" - processing file: ", filepath)
        function insert_dp()            # function: insert dp and return id
            SQLite.execute(ins_stmt, (name, filepath, filehash, version))
            return SQLite.last_insert_rowid(output)
        end
        if !force_refresh               # check hash (unless forced db refresh)
            qr = SQLite.DBInterface.execute(sel_stmt, (name, version, filehash, NULL_HASH)) |> DataFrames.DataFrame
            verbose && println(" - searching db := found ", DataFrames.nrow(qr), " matching, up-to-date data products.")
            DataFrames.nrow(qr) == 0 || (return false)
        end                             # else load from scratch
        SQLite.execute(del_stmt, (name, version))
        if occursin(".h5", filepath)
            process_h5_file!(output, name, filepath, insert_dp(), verbose)
        elseif occursin(".toml", filepath)
            process_toml_file!(output, filepath, insert_dp())
        else    # TBA: CSV/TSV? ***
            filepath == NULL_FILE || println(" -- WARNING - UNKNOWN FILE TYPE - skipping: ", filepath)
            return false
        end
        return true
    end
    ## process file metadata
    updated = 0
    for i in eachindex(md.dp_name)
        load_data_product!(md.dp_name[i], md.dp_file[i], md.dp_hash[i], md.dp_version[i]) && (updated += 1)
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
- `dims`    -- data product search string, e.g. `'human/infection/SARS-CoV-2/%'`.
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
    for row in eachrow(df)  ## HACK: need to figure out how to index n dimension axis array
        length(dims) == 1 && (output[AxisArrays.atvalue(row[Symbol(dims[1])])] = row.val)
        length(dims) == 2 && (output[AxisArrays.atvalue(row[Symbol(dims[1])]), AxisArrays.atvalue(row[Symbol(dims[2])])] = row.val)
        length(dims) == 3 && (output[AxisArrays.atvalue(row[Symbol(dims[1])]), AxisArrays.atvalue(row[Symbol(dims[2])]), AxisArrays.atvalue(row[Symbol(dims[3])])] = row.val)
        length(dims) == 4 && (output[AxisArrays.atvalue(row[Symbol(dims[1])]), AxisArrays.atvalue(row[Symbol(dims[2])]), AxisArrays.atvalue(row[Symbol(dims[3])]), AxisArrays.atvalue(row[Symbol(dims[4])])] = row.val)
    end
    length(dims) > 4 && println("WARNING - AXIS ARRAY NOT POPULATED - ndims > 4 not supported")
    return output
end

##
# - add as float option
const READ_EST_SQL = "SELECT dp_name, comp_name, val FROM toml_view\nWHERE key='value' AND dp_name LIKE ?"
"""
    read_estimate(cn::SQLite.DB, data_product::String, [component::String]; data_type=nothing)

SQLite Data Registry helper function. Search TOML-based data resources stored in `cn`, a SQLite database created previously by a call to `fetch_data_per_yaml`.

**Parameters**
- `cn`              -- SQLite.DB object.
- `data_product`    -- data product search string, e.g. `'human/infection/SARS-CoV-2/%'`.
- `component`       -- as above, optional search string for components names.
- `data_type`       -- (optional) specify to return an array of this type, instead of a DataFrame.
"""
function read_estimate(cn::SQLite.DB, data_product::String; data_type=nothing)
    output = SQLite.DBInterface.execute(cn, READ_EST_SQL, (data_product, )) |> DataFrames.DataFrame
    isnothing(data_type) && return output
    return parse.(data_type, output.val)
end
function read_estimate(cn::SQLite.DB, data_product::String, component::String; data_type=nothing)
    sql = string(READ_EST_SQL, "\nAND comp_name LIKE ?")
    output = SQLite.DBInterface.execute(cn, sql, (data_product, component)) |> DataFrames.DataFrame
    isnothing(data_type) && return output
    return parse.(data_type, output.val)
end

# - tables
"""
    read_table(cn::SQLite.DB, data_product::String, [component::String]; data_type=nothing)

SQLite Data Registry helper function. Search and return HDF5-based table data resources registered in `cn`.

**Parameters**
- `cn`              -- SQLite.DB object.
- `data_product`    -- data product search string, e.g. `'human/infection/SARS-CoV-2/%'`.
- `component`       -- as above, [required] search string for components names.
"""
function read_table(cn::SQLite.DB, data_product::String, component::String)
    tablename = get_table_name(data_product, component, DB_H5_TABLE_APX)
    stmt = SQLite.Stmt(cn, string("SELECT * FROM ", tablename))
    return SQLite.DBInterface.execute(stmt) |> DataFrames.DataFrame
end
