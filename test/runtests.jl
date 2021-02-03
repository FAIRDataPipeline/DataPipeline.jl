## package tests
using DataRegistryUtils
using SQLite, DataFrames
import Test
### 1. prelim: import packages ###
import DataRegistryUtils    # pipeline stuff
import DiscretePOMP         # simulation of epidemiological models
import YAML                 # for reading model config file
import Random               # other assorted packages used incidentally

## tests

Test.@testset "package tests" begin
    ## simple example s2; s4
    Test.@testset "simple example" begin
        ### 2. specify config files, scripts and data directory ###
        model_config = "examples/simple/model_config.yaml"
        data_config = "examples/simple/data_config.yaml"
        data_dir = "examples/simple/data/"
        submission_script = "julia examples/simple/main.jl"

        ### 4. download data products ###
        db = DataRegistryUtils.fetch_data_per_yaml(data_config, data_dir, use_sql=true, verbose=false)
        Test.@test true

        ## display parameter search
        # NB. based on *downloaded* data products
        Test.@testset "read estimates" begin
            sars_cov2_search = "human/infection/SARS-CoV-2/%"
            sars_cov2 = DataRegistryUtils.read_estimate(db, sars_cov2_search)
            println("\n search: human/infection/SARS-CoV-2/* := ", DataFrames.first(sars_cov2, 6),"\n")

            ## read some parameters and convert from hours => days
            inf_period_days = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "infectious-duration", data_type=Float64)[1] / 24
            lat_period_days = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "latent-period", data_type=Float64)[1] / 24
            Test.@test true
        end
    end

    ## code snippets
    Test.@testset "code snippets" begin
        TEST_FILE = "examples/data_config.yaml"
        DATA_OUT = "out/"

        ### read data
        data = DataRegistryUtils.fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_axis_arrays=true, verbose=false)
        Test.@test true

        ### Example: access data product by name
        Test.@testset "dp_by_name" begin
            data_product = data["human/infection/SARS-CoV-2/symptom-delay"]
            component = data_product["symptom-delay"]
            component_type = component["type"]
            distribution_name = component["distribution"]
            Test.@test true ## FIX THIS ***
        end

        ### Example: read individual HDF5 or TOML file
        # Test.@testset "read_from_file" begin
        #     fp = "/path/to/some/file.h5"
        #     dp = DataRegistryUtils.read_data_product_from_file(fp, use_axis_arrays = true, verbose = false)
        #     component = dp["/conversiontable/scotland"]
        #     Test.@test true
        # end

        ### Example: read data as SQLite connection
        Test.@testset "sql" begin
            db = DataRegistryUtils.fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_sql = true)
            x = DBInterface.execute(db, "SELECT * FROM data_product") |> DataFrame
            Test.@test true
        end
    end
end
