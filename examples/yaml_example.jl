import DataRegistryUtils
import SQLite
import DataFrames

#### loading data ####

TEST_FILE = "/home/martin/AtomProjects/DataRegistryUtils.jl/examples/data_config.yaml"
DATA_OUT = "/home/martin/AtomProjects/DataRegistryUtils.jl/out/"

#### examples for usage ####

## default behaviour
function vanilla_example()
    data = DataRegistryUtils.fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_axis_arrays=false, verbose=true)
    # access data product by name
    println("\nExample one - access data product / component by name:")
    dp = data["human/infection/SARS-CoV-2/symptom-delay"]
    println(" ", dp)
    println(" - e.g. distribution name: ", dp["symptom-delay"]["distribution"])

    # loop through Dict of data products
    println("\n\nExample two - loop through Dict of data products:")
    data_product_names = collect(keys(data))
    for i in eachindex(data_product_names)
        println("\n data product: ", data_product_names[i])
        sizeof(data[data_product_names[i]]) == 0 || println(" - components: ", collect(keys(data[data_product_names[i]])))
    end
    # - hint: you can use the same approach to loop through any Dict()
    #           e.g. individual components of a data product
end

## via SQLite layer (WIP)
function db_example()
    # custom views (optional)
    sql_views = "/home/martin/AtomProjects/DataRegistryUtils.jl/examples/views.sql"
    # connect
    db = DataRegistryUtils.fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_sql=true, sql_file=sql_views, force_db_refresh=false, verbose=true)
    # get some data
    query = "SELECT * FROM toml_view"
    results = SQLite.DBInterface.execute(db, query) |> DataFrames.DataFrame
    println(DataFrames.first(results, 9))
end

## run examples
# vanilla_example()
db_example()
