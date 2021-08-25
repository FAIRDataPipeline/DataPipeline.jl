# import DataRegistryUtils
# import SQLite
# import DataFrames
# import Test

## NB. called by pkg_test.jl
Test.@testset "simulationdata" begin
    config = "test/data_config.yaml"
    dataout = "test/data/"
    accessfile = "test/access-example.yaml"
    covid_inf_dur = 321.6
    remove_accessfile() = rm(accessfile, force=true)
    remove_data() = rm("test/data", recursive=true)

    ### Basic tests to check integration ###

    # parameter estimate from file
    Test.@testset "File usage" begin
        prm = DataRegistryUtils.read_data_product_from_file("test/parameter/example.toml")
        Test.@test prm["example-estimate"]["value"] == 1.0
    end

    # read estimate via db
    Test.@testset "Database usage" begin
        remove_accessfile()
        Test.@test !isfile(accessfile)
        db = DataRegistryUtils.fetch_data_per_yaml(config, dataout, use_sql=true, access_log_path=accessfile)
        x = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/", "infectious-duration", data_type=Float64)[1]
        Test.@test x == covid_inf_dur
        Test.@test isfile(accessfile)
        remove_accessfile()
        remove_data()
    end

    # ditto, via do-block
    # Test.@testset "Do-block usage" begin
    #     DataRegistryUtils.fetch_data_per_yaml(config, dataout, use_sql=true) do db
    #         x = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/", "infectious-duration", data_type=Float64)[1]
    #         Test.@test x == covid_inf_dur
    #     end
    # end

    # scottish population data
    Test.@testset "Population data" begin
        dataconfig = "test/demographics/data_config.yaml"
        view_sql = "test/demographics/views.sql"
        remove_accessfile()
        # remove_data()
        Test.@test !isfile(accessfile)
        db = DataRegistryUtils.fetch_data_per_yaml(dataconfig, dataout, use_sql=true, sql_file=view_sql, access_log_path=accessfile)
        #     @test_broken size(scotpop) == (465, 691, 10)
        rs = SQLite.DBInterface.execute(db, "SELECT max(grid_x), max(grid_y) FROM scottish_population_view") |> DataFrames.DataFrame
        Test.@test rs[1,1] == 465
        Test.@test rs[1,2] == 691
        rs = SQLite.DBInterface.execute(db, "SELECT COUNT(rowid) FROM scottish_population_view WHERE val<0") |> DataFrames.DataFrame
        Test.@test rs[1,1] == 0
        rs = SQLite.DBInterface.execute(db, "SELECT SUM(val) FROM scottish_population_view") |> DataFrames.DataFrame
        Test.@test rs[1,1] > 5e6
        Test.@test isfile(accessfile)
        remove_accessfile()
        remove_data()
    end
end
