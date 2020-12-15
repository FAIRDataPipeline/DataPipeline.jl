import DataRegistryUtils
import Test

Test.@testset "simulationdata" begin
    # config = "test/config.yaml"
    dataconfig = "test/data_config.yaml"
    dataout = "test/data/"
    accessfile = "test/access-example.yaml"
    covid_inf_dur = 321.6
    remove_accessfile() = rm(accessfile, force=true)
    # remove_data() = rm("test/data", recursive=true)

    ### Basic tests to check integration ###

    # parameter estimate from file
    Test.@testset "File usage" begin
        prm = DataRegistryUtils.read_data_product("test/parameter/example.toml")
        Test.@test prm["example-estimate"]["value"] == 1.0
    end

    # read estimate via db
    Test.@testset "Database usage" begin
        remove_accessfile()
        Test.@test !isfile(accessfile)
        db = DataRegistryUtils.fetch_data_per_yaml(dataconfig, dataout, use_sql=true, access_log_path=accessfile)
        x = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "infectious-duration", data_type=Float64)[1]
        Test.@test x == covid_inf_dur
        Test.@test isfile(accessfile)
        # remove_accessfile()
    end

    # @testset "Do-block usage" begin
    #     DataRegistryUtils.fetch_data_per_yaml(dataconfig, dataout, use_sql=true) do api
    #         @test read_estimate(api, "parameter", "example-estimate") == 1.0
    #      end
    # end

    # @testset "Population data" begin
    #     try
    #         download_data_registry(dataconfig)
    #         api = StandardAPI(dataconfig, "test_uri", "test_git_sha")
    #         scotpop = parse_scottish_population(api)
    #     catch e
    #         println("Can't download from boydorr.gla.ac.uk ftp server")
    #         @test_broken isfile("simulationdata/demographics/human/demographics/population/scotland/1.0.0/1.0.0.h5")
    #         @test_broken size(scotpop) == (465, 691, 10)
    #         @test_broken sum(scotpop .< 0) == 0
    #         @test_broken sum(scotpop) > 5e6
    #     finally
    #         remove_data()
    #     end
    # end
end
