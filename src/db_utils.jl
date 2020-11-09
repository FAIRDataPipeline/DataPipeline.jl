import SQLite
# import DataFrames

const DDL_SQL = "db/ddl.sql"
const DB_TYPE_MAP = Dict(String => "TEXT", Int32 => "INTEGER", Float64 => "REAL")

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

## db table labeller
clean_path(x::String) = replace(replace(strip(x, '/'), "/" => "_"), " " => "_")

## load table from object
function load_table!(cn::SQLite.DB, tablestub::String, gnm::String, d, verbose::Bool)
    verbose && println(" - processing group := ", gnm)
    tablename = rstrip(string(tablestub, "_", clean_path(gnm)), '_')
    verbose && println(" - loading table := ", tablename)
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
    # println(" - tablestub := ", tablestub, " gnm := ", gnm)
end

## load array as flattened cube
# - TO DO: too slow atm, optimise via load_table! function ***
function flat_load_array!(cn::SQLite.DB, tablestub::String, gnm::String, h5::HDF5.HDF5Group, verbose::Bool)
    tablename = string(rstrip(string(tablestub, "_", clean_path(gnm)), '_'), "_cube")
    verbose && println(" - loading ", gnm, " => ", tablename)
    cube_sql = string("CREATE TABLE ", tablename, "(")
    ins_sql = string("INSERT INTO ", tablename, "(")
    arr = read_h5_array(h5)
    nd = ndims(arr)             # process columns
    dim_names = Array{Array{Any, 1}, 1}(undef, nd)
    for d in 1:nd
        dim_names[d] = HDF5.read(h5[string("Dimension_", d, "_names")])
        col_ttl = replace(HDF5.read(h5[string("Dimension_", d, "_title")])[1], " " => "_")
        cube_sql = string(cube_sql, col_ttl, " ", DB_TYPE_MAP[typeof(dim_names[d][1])], " NOT NULL,\n")
        ins_sql = string(ins_sql, col_ttl, ",")
    end
    # ddl
    SQLite.drop!(cn, tablename, ifexists=true)
    cube_sql = string(cube_sql, "val ", DB_TYPE_MAP[typeof(arr[1])], ")")
    SQLite.execute(cn, cube_sql)
    # dml
    ins_sql = string(ins_sql, "val) ", get_values_str(nd + 1))
    ins_stmt = SQLite.Stmt(cn, ins_sql)
    for i in eachindex(arr)
        ids = Tuple(CartesianIndices(arr)[i])
        vals = Any[dim_names[j][ids[j]] for j in eachindex(ids)]
        push!(vals, arr[i])
        SQLite.execute(ins_stmt, vals)
    end
    # load_table!(cn, tablestub, gnm, d, verbose)
end

## recursively search and load table/array
function process_h5_file_group!(cn::SQLite.DB, tablestub::String, h5, verbose::Bool)
    gnm = HDF5.name(h5)
    if HDF5.exists(h5, TABLE_OBJ_NAME)
        d = read_h5_table(h5, false)
        load_table!(cn, tablestub, gnm, d, verbose)
    elseif (HDF5.exists(h5, ARRAY_OBJ_NAME) && typeof(h5[ARRAY_OBJ_NAME])!=HDF5.HDF5Group)
        flat_load_array!(cn, tablestub, gnm, h5, verbose)
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

## load dp to db
function load_data_product!(cn::SQLite.DB, name::String, filepath::String, verbose::Bool)
    verbose && println(" - processing file: ", filepath)
    stmt = SQLite.Stmt(cn, "INSERT INTO data_product(dp_name, dp_path, dp_type) VALUES(?, ?, ?)")
    if occursin(".h5", filepath)
        SQLite.execute(stmt, (name, filepath, 1))
        process_h5_file!(cn, name, filepath, verbose)
    elseif occursin(".toml", filepath)
        SQLite.execute(stmt, (name, filepath, 2))
        dp_id = SQLite.last_insert_rowid(cn)
        process_toml_file!(cn, filepath, dp_id)
    else
        println(" -- WARNING - UNKNOWN FILE TYPE - skipping: ", filepath)
    end
end

## load yaml data to sqlite db
# - TO DO: remove warning when array loader has been optimised
function load_data_per_yaml(dp_fps, db_path::String, verbose::Bool)
    println(" - loading data: ", db_path)
    println(" - NB. this can take a while...")
    output = init_yaml_db(db_path)
    for i in eachindex(dp_fps[1])
        load_data_product!(output, dp_fps[1][i], dp_fps[2][i], verbose)
    end
    return output
end
