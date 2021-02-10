# ## try get dim titles, else give generic column name
# # - deprecate this ***
# function get_dim_title(h5, d::Int64, verbose::Bool)
#     ttl = string("Dimension_", d, "_title")
#     if haskey(h5, ttl)
#         return replace(HDF5.read(h5[ttl])[1], " " => "_");
#     else
#         cn = string("col", d)
#         verbose && println(" - nb. no metadata found for ", cn)
#         return cn
#     end
# end
## try get dim labels, else give generic labels
# - deprecate this? ***
# function get_dim_names(h5, d::Int64, s::Int64)
#     nms = string("Dimension_", d, "_names")
#     if haskey(h5, nms)
#         return HDF5.read(h5[nms]);
#     else
#         return String[string("grp", i) for i in 1:s]
#     end
# end

## flatten Nd array and load as 2d table
# - NB. TBO *****
# function flat_load_array!(cn::SQLite.DB, dp_id::Int64, tablename::String, h5::HDF5.Group, verbose::Bool)
#     arr = read_h5_array(h5)
#     verbose && println(" - loading array : ", size(arr), " => ", tablename)
#     nd = ndims(arr)                             # fetch columns names
#     dim_titles = String[]
#     for d in 1:nd
#         push!(dim_titles, clean_path(get_dim_title(h5, d, verbose)))
#     end
#     push!(dim_titles, DB_VAL_COL)               # measure column
#     ## ddl / dml
#     idc = Tuple.(CartesianIndices(arr)[:])      # dimension indices
#     dims = Array{Array{Any,1}}(undef, nd)
#     for d in 1:nd                               # fetch named dimensions
#         dim_names = get_dim_names(h5, d, size(arr)[d])
#         idx = Int64[t[d] for t in idc]
#         dims[d] = dim_names[idx]                # 'named' dimension d
#     end
#     verbose && println(" - dims := ", typeof(dims))
#     df = DataFrames.DataFrame(dims)             # convert to df
#     df.val = [arr[i] for i in eachindex(arr)]   # add data
#     DataFrames.rename!(df, Symbol.(dim_titles)) # column names
#     load_component!(cn, dp_id, tablename, df)   # load to db
# end
# replacement:
# - load data (indices + msr) > new tbl
# - load named dims (exists and not int?)
# - define view
# - ALT: store each as single column table (plus md, dim size, names) - as module
# - NB. even worse performance wise! (insert is the bottle neck)
# function flat_load_array!(cn::SQLite.DB, dp_id::Int64, tablename::String, h5::HDF5.Group, verbose::Bool)
#     arrd = HDF5.read(h5)    # > Dict
#     arr = arrd[ARRAY_OBJ_NAME]
#     arr_size = size(arr)
#     ## load data to db
#     verbose && println(" - loading array : ", arr_size, " => ", tablename)
#     data = DataFrames.DataFrame((val=arr[:]))
#     # data = Dict("val"=>arr[:])
#     comp_id = load_component!(cn, dp_id, ARRAY_OBJ_NAME, tablename, data)
#     ## load dims
#     dim_sql = "INSERT INTO array_dim(comp_id, dim_index, dim_type, dim_title, dim_size) VALUES(?,?,?,?,?)"
#     nm_sql = "INSERT INTO array_dim_name(dim_id, dim_val) VALUES(?,?)"
#     dim_stmt = SQLite.Stmt(cn, dim_sql)
#     nm_stmt = SQLite.Stmt(cn, nm_sql)
#     for d in eachindex(arr_size)
#         ttl = string("Dimension_", d, "_title")
#         dim_type = haskey(arrd, ttl) ? 1 : 0
#         dim_title = dim_type == 0 ? "Index" : arrd[ttl][1]
#         SQLite.execute(dim_stmt, (comp_id, d, dim_type, dim_title, arr_size[d]))
#         dim_id = SQLite.last_insert_rowid(cn)
#         ## load dim names
#         if dim_type == 1
#             nms = string("Dimension_", d, "_names")
#             @assert haskey(arrd, nms)
#             for i in eachindex(arrd[nms])
#                 SQLite.execute(nm_stmt, (dim_id, arrd[nms][i]))
#             end
#         end
#     end
# end
# ## WIP > metadata load only - meta_load_component?
# function flat_load_array2!(cn::SQLite.DB, dp_id::Int64, tablename::String, h5::HDF5.Group, verbose::Bool)
#     ## extract meta?
#     arrd = HDF5.read(h5)    # > Dict
#     arr = arrd[ARRAY_OBJ_NAME]
#     verbose && println(" - loading array : ", size(arr), " => ", tablename)
#     idc = Tuple.(CartesianIndices(arr)[:])      # dimension indices
#     df = DataFrames.DataFrame(idc)
#     df.val = arr[:]
# end
