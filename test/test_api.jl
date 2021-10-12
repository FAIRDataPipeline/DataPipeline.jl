module TestAPI

using DataPipeline
using HDF5
using TOML
using Test

uid = DataPipeline._randomhash()

Test.@testset "link_write()" begin
    config = "test.yaml"
    data_product = "data_product/link_write/$uid"
    file_type = "txt"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", file_type = file_type, 
                           use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Test that returned file path matches handle
    path = link_write!(handle, data_product)    
    @test path == handle.outputs[data_product]["path"]

    open(path, "w") do file
        println(file, uid)
    end

    # Test that returned file path is correct 
    datastore = handle.config["run_metadata"]["write_data_store"]
    namespace = handle.config["run_metadata"]["default_output_namespace"]
    test_path = joinpath("$(datastore)$(namespace)", "$data_product", 
                         "xxxxxxxxxx.$file_type")
    @test path == test_path

    # Finalise Code Run
    finalise(handle)
end

Test.@testset "link_read()" begin
    config = "test.yaml"
    data_product = "data_product/link_write/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addread(config, data_product, use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.inputs == Dict()

    # Test that returned file path matches handle
    path = link_read!(handle, data_product)
    @test collect(keys(handle.inputs))[1] == data_product

    dat = open(path) do file
        read(file, String)
    end

    @test chomp(dat) == uid

    # Finalise Code Run
    finalise(handle)
end

Test.@testset "write_array()" begin
    config = "test.yaml"
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # First component
    component1 = "component/1"
    data1 = reshape(rand(10), 2, :)  
    write_array(handle, data1, data_product, component1, "description1")
    
    # Second component
    component2 = "component/2"
    data2 = reshape(rand(10), 2, :)  
    write_array(handle, data2, data_product, component2, "description2")

    # Test that data in component1 of hdf5 file matches data1
    path1 = handle.outputs[(data_product, component1)]["path"]
    c1 = HDF5.h5open(path1, "r") do file
        read(file, component1)
    end
    @test data1 == c1

    # Test that data in component2 of hdf5 file matches data2
    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    c2 = HDF5.h5open(path2, "r") do file
        read(file, component2)
    end
    @test data2 == c2    

    # Finalise Code Run
    finalise(handle)

    # Check that the handle has been updated
    hash = DataPipeline._getfilehash(path1)
    should_be_here = joinpath(handle.config["run_metadata"]["default_output_namespace"],
                              data_product, "$hash.h5")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check that file exists 
    datastore = handle.config["run_metadata"]["write_data_store"]
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_array()" begin
    config = "test.yaml"
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addread(config, data_product, use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # First component
    dat1 = read_array(handle, data_product, component1)
    @test dat1 == data1

    # Second component
    dat2 = read_array(handle, data_product, component2)
    @test dat2 == data2

    # Finalise Code Run
    finalise(handle)

    # Check that the handle has been updated
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
end

Test.@testset "write_estimate()" begin
    config = "test.yaml"
    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # First component
    component1 = "component/1"
    data1 = 1
    write_estimate(handle, data1, data_product, component1, "description1")
    
    # Second component
    component2 = "component/2"
    data2 = 2
    write_estimate(handle, data2, data_product, component2, "description2")

    # Test that data in component1 of toml file matches data1
    path1 = handle.outputs[(data_product, component1)]["path"]
    c1 = TOML.parsefile(path1)[component1]["value"]
    @test data1 == c1

    # Test that data in component2 of hdf5 file matches data2
    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    c2 = TOML.parsefile(path2)[component2]["value"]
    @test data2 == c2

     # Finalise Code Run
     finalise(handle)

     # Check that the handle has been updated
     hash = DataPipeline._getfilehash(path1)
     should_be_here = joinpath(handle.config["run_metadata"]["default_output_namespace"],
                               data_product, "$hash.toml")
     @test handle.outputs[(data_product, component1)]["path"] == should_be_here
end

Test.@testset "write_distribution()" begin
    config = "test.yaml"
    data_product = "data_product/write_distribution/$uid"

    parameters = Dict("mean" => -16.08, "SD" => 30)
    distribution = "Gaussian"
    compare = Dict("parameters" => parameters, 
                   "distribution" => distribution, 
                   "type" => "distribution")

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # First component
    component1 = "component/1"
    write_distribution(handle, distribution, parameters, data_product, component1, 
                       "symptom-delay")
    
    # Second component
    component2 = "component/2"
    write_distribution(handle, distribution, parameters, data_product, component2, 
                       "symptom-delay")

    # Test that data in component1 of toml file matches data1
    path1 = handle.outputs[(data_product, component1)]["path"]
    c1 = TOML.parsefile(path1)[component1]
    @test c1 == compare

    # Test that data in component2 of hdf5 file matches data2
    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    c2 = TOML.parsefile(path2)[component2]
    @test c2 == compare

     # Finalise Code Run
     finalise(handle)

     # Check that the handle has been updated
     hash = DataPipeline._getfilehash(path1)
     should_be_here = joinpath(handle.config["run_metadata"]["default_output_namespace"],
                               data_product, "$hash.toml")
     @test handle.outputs[(data_product, component1)]["path"] == should_be_here
end

end