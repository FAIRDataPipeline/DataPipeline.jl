import SQLite
import DataFrames

const DDL_SQL = "db/ddl.sql"
const DB_TYPE_MAP = Dict(String => "TEXT", Int32 => "INTEGER", Float64 => "REAL")
const DB_FLAT_ARR_APX = "_arr"
const DB_H5_TABLE_APX = "_tbl"
const DB_VAL_COL = "val"

## read sql from file
function get_sql_stmts(fp::String)
    f = open(fp)
    sql = strip(replace(read(f, String), "\n" => " "), ' ')
    close(f)
    return split(rstrip(sql, ';'), ';')
end

## process sql file
function proc_sql_file!(cn::SQLite.DB, fp::String)
    sql = get_sql_stmts(fp)
    for i in eachindex(sql)
        SQLite.execute(cn, sql[i])
    end
end

## initialise from file
function init_yaml_db(db_path::String)
    output = SQLite.DB(db_path)
    proc_sql_file!(output, DDL_SQL)
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

## load table from object
function load_table!(cn::SQLite.DB, tablename::String, d)
    SQLite.drop!(cn, tablename, ifexists=true)
    SQLite.load!(d, cn, tablename)
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
function flat_load_array!(cn::SQLite.DB, tablestub::String, gnm::String, h5::HDF5.HDF5File, verbose::Bool)
    println("*** h5 group type: ", typeof(h5), " - TO BE ADDED ***")
end

## try get dim titles, else give generic column name
function get_dim_title(h5, d::Int64, verbose::Bool)
    ttl = string("Dimension_", d, "_title")
    if HDF5.exists(h5, ttl)
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

## load array as flattened cube
function flat_load_array!(cn::SQLite.DB, tablename::String, h5::HDF5.HDF5Group, verbose::Bool)
    arr = read_h5_array(h5)
    verbose && println(" - loading array : ", size(arr), " => ", tablename)
    nd = ndims(arr)             # process columns names
    dim_titles = String[]
    for d in 1:nd
        push!(dim_titles, clean_path(get_dim_title(h5, d, verbose)))
    end
    push!(dim_titles, DB_VAL_COL)
    # println("** arr cols: ", dim_titles)
    ## ddl
    idc = Tuple.(CartesianIndices(arr)[:])
    dims = Array[]
    for d in 1:nd
        dim_names = get_dim_names(h5, d, size(arr)[d])
        idx = Int64[t[d] for t in idc]
        nd = dim_names[idx]
        push!(dims, nd)
    end
    df = DataFrames.DataFrame(dims)
    df.val = [arr[i] for i in eachindex(arr)]
    DataFrames.rename!(df, Symbol.(dim_titles))
    # println("** array sample:\n", DataFrames.first(df, 3))
    load_table!(cn, tablename, df)
end

## recursively search and load table/array
function process_h5_file_group!(cn::SQLite.DB, tablestub::String, h5, verbose::Bool)
    gnm = HDF5.name(h5)
    if HDF5.exists(h5, TABLE_OBJ_NAME)
        tablename = string(rstrip(string(tablestub, "_", clean_path(gnm)), '_'), DB_H5_TABLE_APX)
        d = read_h5_table(h5, false)
        verbose && println(" - loading table := ", tablename)
        load_table!(cn, tablename, d)
    elseif (HDF5.exists(h5, ARRAY_OBJ_NAME) && typeof(h5[ARRAY_OBJ_NAME])!=HDF5.HDF5Group)
        tablename = string(rstrip(string(tablestub, "_", clean_path(gnm)), '_'), DB_FLAT_ARR_APX)
        flat_load_array!(cn, tablename, h5, verbose)
    else
        for g in HDF5.names(h5)     # group - recurse
            process_h5_file_group!(cn, tablestub, h5[g], verbose)
        end
    end
end

## wrapper for recursive processing
function process_h5_file!(cn::SQLite.DB, name::String, filepath::String, verbose::Bool)
    tablestub = clean_path(name)
    f = HDF5.h5open(filepath)
    process_h5_file_group!(cn, tablestub, f, verbose)
    HDF5.close(f)
end

## load yaml data to sqlite db
function load_data_per_yaml(md, db_path::String, force_refresh::Bool, verbose::Bool)
    println(" - checking database: ", db_path)
    output = init_yaml_db(db_path)
    ## load dp to db
    sel_stmt = SQLite.Stmt(output, "SELECT * FROM data_product WHERE dp_name = ? AND dp_version = ? AND dp_hash = ?")
    del_stmt = SQLite.Stmt(output, "DELETE FROM data_product WHERE dp_name = ? AND dp_version = ?")
    ins_stmt = SQLite.Stmt(output, "INSERT INTO data_product(dp_name, dp_path, dp_hash, dp_version) VALUES(?, ?, ?, ?)")
    function load_data_product!(name::String, filepath::String, filehash::String, version::String)
        verbose && println(" - processing file: ", filepath)
        if !force_refresh   # check hash (unless forced db refresh)
            qr = SQLite.DBInterface.execute(sel_stmt, (name, version, filehash)) |> DataFrames.DataFrame
            verbose && println(" - searching db := found ", DataFrames.nrow(qr), " matching, up-to-date data products.")
            DataFrames.nrow(qr) == 0 || (return false)
        end                 # else load from scratch
        SQLite.execute(del_stmt, (name, version))
        SQLite.execute(ins_stmt, (name, filepath, filehash, version))
        dp_id = SQLite.last_insert_rowid(output)
        if occursin(".h5", filepath)
            process_h5_file!(output, name, filepath, verbose)
        elseif occursin(".toml", filepath)
            process_toml_file!(output, filepath, dp_id)
        else
            println(" -- WARNING - UNKNOWN FILE TYPE - skipping: ", filepath)
        end
        return true
    end
    ## load
    updated = 0
    for i in eachindex(md.dp_name)
        load_data_product!(md.dp_name[i], md.dp_file[i], md.dp_hash[i], md.dp_version[i]) && (updated += 1)
    end
    ## clean up
    SQLite.execute(output, "DELETE FROM toml_component WHERE dp_id NOT IN(SELECT DISTINCT dp_id FROM data_product)")
    SQLite.execute(output, "DELETE FROM toml_keyval WHERE comp_id NOT IN(SELECT DISTINCT comp_id FROM toml_component)")
    verbose && println(" - finished, ", updated, " data products updated.")
    return output
end
