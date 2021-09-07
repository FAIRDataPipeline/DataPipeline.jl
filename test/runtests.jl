## package tests
using DataPipeline
# using SQLite, DataFrames
import CSV
import DataFrames
import Random
import Test

## tests
Test.@testset "package tests" begin
    ## 1. Empty code run
    Test.@testset "empty code run" begin
        wc = "examples/simple2/working_config1.yaml"
        handle = initialise(wc)
        finalise(handle; comments="Empty code run example.")
        Test.@test true
    end

    ## 2. Write data product (HDF5)
    Test.@testset "write array" begin
        wc = "examples/simple2/working_config2.yaml"
        handle = initialise(wc)
        Random.seed!(0)
        tmp = reshape(rand(10), 2, :)       # create an array
        write_array(handle, tmp, "test/array", "component1/a/s/d/f/s")
        finalise(handle; comments="Write HDF5 example.")
        Test.@test true
    end

    ## 3. Read data product (HDF5)
    Test.@testset "write array" begin
        wc = "examples/simple2/working_config3.yaml"
        handle = initialise(wc)
        tmp2 = read_array(handle, "test/array", "component1/a/s/d/f/s")
        finalise(handle; comments="Read HDF5 example.")
        Test.@test tmp==tmp2
    end

    # ## simple example s2; s4
    # Test.@testset "simple example" begin
    #     ### 2. specify config files, scripts and data directory ###
    #     model_config = "examples/simple/model_config.yaml"
    #     data_config = "examples/simple/data_config.yaml"
    #     data_dir = "examples/simple/data/"
    #     submission_script = "julia examples/simple/main.jl"
    #
    #     ### 4. download data products ###
    #     db = initialise_local_registry(data_dir, data_config=data_config, verbose=false)
    #     Test.@test true
    #
    #     ## display parameter search
    #     # NB. based on *downloaded* data products
    #     Test.@testset "read estimates" begin
    #         sars_cov2_search = "human/infection/SARS-CoV-2/"
    #         sars_cov2 = read_estimate(db, sars_cov2_search)
    #         println("\n search: human/infection/SARS-CoV-2/* := ", DataFrames.first(sars_cov2, 6),"\n")
    #
    #         ## read some parameters and convert from hours => days
    #         inf_period_days = read_estimate(db, "human/infection/SARS-CoV-2/", "infectious-duration", key="value", data_type=Float64)[1] / 24
    #         lat_period_days = read_estimate(db, "human/infection/SARS-CoV-2/", "latent-period", key="value", data_type=Float64)[1] / 24
    #         Test.@test true
    #     end
    # end
    #
    # ## code snippets
    # Test.@testset "code snippets" begin
    #     TEST_FILE = "examples/data_config.yaml"
    #     DATA_OUT = "out/"
    #
    #     ### Example: no SQL
    #     # Test.@testset "read estimate (no sql)" begin
    #     #     data = fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_sql=false, use_axis_arrays=true)
    #     #     data_product = data["human/infection/SARS-CoV-2/symptom-delay"]
    #     #     component = data_product["symptom-delay"]
    #     #     component_type = component["type"]
    #     #     distribution_name = component["distribution"]
    #     #     Test.@test true ## FIX THIS ***
    #     # end
    #
    #     ### refresh data
    #     data = initialise_local_registry(DATA_OUT, data_config=TEST_FILE, verbose=false)
    #     # data = fetch_data_per_yaml(TEST_FILE, DATA_OUT)
    #     Test.@test true
    #
    #     ### Example: reading point estimates
    #     # Test.@testset "read estimate" begin
    #     #     read_estimate
    #     # end
    #
    #     ### Example: reading arrays
    #     Test.@testset "read arrays" begin
    #         dp = "records/SARS-CoV-2/scotland/cases_and_management"
    #         comp_name = "/test_result/date-cumulative"
    #         ## read array by dp
    #         some_arrays = read_array(data, dp)
    #         one_array = some_arrays[comp_name]
    #         Test.@test !isnothing(one_array)
    #         ## read array by component name
    #         one_array = read_array(data, dp, comp_name)
    #         Test.@test !isnothing(one_array)
    #         ## read array as flat table
    #         one_array = read_array(data, dp, comp_name; flatten=true)
    #         Test.@test !isnothing(one_array)
    #     end
    #
    #     ### Example: reading tables
    #     Test.@testset "read table" begin
    #         dp = "geography/scotland/lookup_table"
    #         comp_name = "/conversiontable/scotland"
    #         tbl = read_table(data, dp, comp_name)
    #         Test.@test !isnothing(tbl)
    #     end
    #
    #     ### Example: read individual HDF5 or TOML file
    #     Test.@testset "read from file" begin
    #         # fp = "out/records/SARS-CoV-2/scotland/cases_and_management/0.20200825.0.h5"
    #         fp = "out/fefe14d6a63b4dc1666f93e7d95367977969bdf7"
    #         dp = read_data_product_from_file(fp, use_axis_arrays=true, verbose=false)
    #         component = dp["/test_result/date-cumulative"]
    #         Test.@test !isnothing(component)
    #     end
    #
    #     ### Example: custom SQL query
    #     Test.@testset "sql" begin
    #         dp = "records/SARS-CoV-2/scotland/cases_and_management"
    #         comp_name = "/test_result/date-cumulative"
    #         ## load array as flat table
    #         tbl_name = load_array!(data, dp, comp_name; sql_alias="some_view")
    #         Test.@test tbl_name=="some_view"
    #         x = DBInterface.execute(data, "SELECT * FROM some_view") |> DataFrame
    #         Test.@test nrow(x) > 0
    #     end
    # end
end
