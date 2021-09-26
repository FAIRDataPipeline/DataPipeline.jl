### THIS IS DEPRECATED

import DataPipeline
import SQLite
import DataFrames

#### code snippets ####
TEST_FILE = "examples/data_config.yaml"
DATA_OUT = "out/"

### loading data
data = DataPipeline.initialise_local_registry(DATA_OUT, data_config=TEST_FILE, verbose=false)

### Example: reading arrays
dp = "records/SARS-CoV-2/scotland/cases_and_management"
comp_name = "/test_result/date-cumulative"

## read array by dp
some_arrays = DataPipeline.read_array(data, dp)
one_array = some_arrays[comp_name]
println("type := ", typeof(one_array), " - keys := ", keys(one_array))

## read array by component name
one_array = DataPipeline.read_array(data, dp, comp_name)
println("type := ", typeof(one_array), " - keys := ", keys(one_array))

## read array as flat table
one_array = DataPipeline.read_array(data, dp, comp_name; flatten=true)
println("type := ", typeof(one_array), " - size := ", size(one_array))

### Example: read individual HDF5 or TOML file
# fp = "out/records/SARS-CoV-2/scotland/cases_and_management/0.20200825.0.h5"
# dp = DataPipeline._readdataproduct_from_file(fp, use_axis_arrays=true, verbose=false)
# component = dp["/test_result/date-cumulative"]

#### examples for usage ####

## default behaviour
# function vanilla_example()
#     data = DataPipeline.fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_axis_arrays=false, verbose=true)
#     # access data product by name
#     println("\nExample one - access data product / component by name:")
#     dp = data["human/infection/SARS-CoV-2/infectious-duration"]
#     println(" ", dp)
#     println(" - e.g. component type: ", dp["infectious-duration"]["type"])
#
#     # loop through Dict of data products
#     println("\n\nExample two - loop through Dict of data products:")
#     data_product_names = collect(keys(data))
#     for i in eachindex(data_product_names)
#         println("\n data product: ", data_product_names[i])
#         sizeof(data[data_product_names[i]]) == 0 || println(" - components: ", collect(keys(data[data_product_names[i]])))
#     end
#     # - hint: you can use the same approach to loop through any Dict()
#     #           e.g. individual components of a data product
# end
#
# ## via SQLite layer (WIP)
# function db_example()
#     # custom views (optional)
#     sql_views = "/home/martin/AtomProjects/DataPipeline.jl/examples/views.sql"
#     # connect
#     db = DataPipeline.fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_sql=true, sql_file=sql_views, force_db_refresh=false, verbose=false)
#     # get some data
#     query = "SELECT * FROM toml_view"
#     results = SQLite.DBInterface.execute(db, query) |> DataFrames.DataFrame
#     println(DataFrames.first(results, 9))
# end
#
# ## run examples
# # vanilla_example()
# db_example()
