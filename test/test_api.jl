module TestAPI

using DataPipeline
using HDF5
using TOML
using Test

uid = DataPipeline._randomhash()
config = "test.yaml"

DataPipeline._createconfig(config)
handle = initialise(config, config)
datastore = handle.config["run_metadata"]["write_data_store"]
namespace = handle.config["run_metadata"]["default_output_namespace"]

component1 = "component/1"
component2 = "component/2"

data1 = reshape(rand(10), 2, :)  
data2 = reshape(rand(10), 2, :)  

estimate1 = 1
estimate2 = 2

distribution = Dict("parameters" => Dict("mean" => -16.08, "SD" => 30), 
                    "distribution" => "Gaussian", "type" => "distribution")

Test.@testset "link_write()" begin
    data_product = "data_product/link_write/$uid"
    file_type = "txt"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", file_type = file_type, 
                           use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Check function output
    path = link_write!(handle, data_product)    
    @test path == handle.outputs[data_product]["path"]
    @test length(handle.outputs) == 1
    path = link_write!(handle, data_product)    
    @test length(handle.outputs) == 1
    
    # Write data product
    open(path, "w") do file
        println(file, uid)
    end

    # Test that returned file path is correct 
    test_path = joinpath("$(datastore)$(namespace)", "$data_product", 
                         "xxxxxxxxxx.$file_type")
    @test path == test_path

    # Finalise Code Run
    finalise(handle)
end

Test.@testset "link_read()" begin
    data_product = "data_product/link_write/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addread(config, data_product, use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.inputs == Dict()

    # Check function output
    path = link_read!(handle, data_product)
    @test handle.inputs[data_product]["use_dp"] == data_product
    @test length(handle.inputs) == 1
    path = link_read!(handle, data_product)    
    @test length(handle.inputs) == 1

    # Check data
    dat = open(path) do file
        read(file, String)
    end
    @test chomp(dat) == uid

    # Finalise Code Run
    finalise(handle)
end

Test.@testset "write_array()" begin
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_array(handle, data1, data_product, component1, "description1")
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_array(handle, data1, data_product, component1, "description1")
    @test length(handle.outputs) == 1
    write_array(handle, data2, data_product, component2, "description2")
    @test length(handle.outputs) == 2

    # Check data
    path1 = handle.outputs[(data_product, component1)]["path"]
    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2

    c1 = HDF5.h5open(path1, "r") do file
        read(file, component1)
    end
    @test data1 == c1

    c2 = HDF5.h5open(path2, "r") do file
        read(file, component2)
    end
    @test data2 == c2    

    # Finalise Code Run
    finalise(handle)

    # Check handle 
    hash = DataPipeline._getfilehash(path1)
    should_be_here = joinpath(namespace, data_product, "$hash.h5")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_array()" begin
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addread(config, data_product, use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_array(handle, data_product, component1)
    dat2 = read_array(handle, data_product, component2)
    @test dat1 == data1
    @test dat2 == data2

    # Finalise Code Run
    finalise(handle)

    # Check handle 
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
end

Test.@testset "write_estimate()" begin
    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_estimate(handle, estimate1, data_product, component1, "description1")    
    write_estimate(handle, estimate2, data_product, component2, "description2")

    # Check data
    path1 = handle.outputs[(data_product, component1)]["path"]
    c1 = TOML.parsefile(path1)[component1]["value"]
    @test c1 == estimate1

    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    c2 = TOML.parsefile(path2)[component2]["value"]
    @test c2 == estimate2

    # Finalise Code Run
    finalise(handle)

    # Check handle 
    hash = DataPipeline._getfilehash(path1)
    should_be_here = joinpath(namespace, data_product, "$hash.toml")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_estimate()" begin
    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addread(config, data_product, use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_estimate(handle, data_product, component1)
    dat2 = read_estimate(handle, data_product, component2)
    @test dat1 == estimate1
    @test dat2 == estimate2
  
    # Finalise Code Run
    finalise(handle)

    # Check handle 
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
end

Test.@testset "write_distribution()" begin
    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_distribution(handle, distribution["distribution"], distribution["parameters"], 
                       data_product, component1, "symptom-delay")    
    write_distribution(handle, distribution["distribution"], distribution["parameters"], 
                       data_product, component2, "symptom-delay")

    # Check data
    path1 = handle.outputs[(data_product, component1)]["path"]
    c1 = TOML.parsefile(path1)[component1]
    @test c1 == distribution

    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    c2 = TOML.parsefile(path2)[component2]
    @test c2 == distribution

    # Finalise Code Run
    finalise(handle)

    # Check handle 
    hash = DataPipeline._getfilehash(path1)
    should_be_here = joinpath(namespace, data_product, "$hash.toml")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_distribution()" begin
    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addread(config, data_product, use_version = "0.0.1")
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_distribution(handle, data_product, component1)
    dat2 = read_distribution(handle, data_product, component2)
    @test dat1 == distribution
    @test dat2 == distribution

    # Finalise Code Run
    finalise(handle)

    # Check handle
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
end

end