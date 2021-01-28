## package tests
using DataRegistryUtils
using SQLite, DataFrames
import Test

## sim test
## include("test_integration.jl")

## main package test
Test.@testset "package_test" begin
    TEST_FILE = "examples/data_config.yaml"
    DATA_OUT = "out/"

    ### read data
    data = DataRegistryUtils.fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_axis_arrays=true, verbose=false)

    ### Example: access data product by name
    Test.@testset "eg_dp_by_name" begin
        data_product = data["human/infection/SARS-CoV-2/symptom-delay"]
        component = data_product["symptom-delay"]
        component_type = component["type"]
        distribution_name = component["distribution"]
        Test.@test true ## FIX THIS ***
    end

    ### Example: read individual HDF5 or TOML file
    # Test.@testset "eg_read_from_file" begin
    #     fp = "/path/to/some/file.h5"
    #     dp = DataRegistryUtils.read_data_product_from_file(fp, use_axis_arrays = true, verbose = false)
    #     component = dp["/conversiontable/scotland"]
    #     Test.@test true
    # end

    ### Example: read data as SQLite connection
    Test.@testset "eg_sql" begin
        db = DataRegistryUtils.read_data_product_from_file(fp, use_sql = true)
        x = DBInterface.execute(db, "SELECT * FROM data_product") |> DataFrame
        Test.@test true
    end
end
