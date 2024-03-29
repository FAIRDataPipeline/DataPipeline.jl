module TestAPI

using DataPipeline
using HDF5
using TOML
using Test
using Dates

uid = DataPipeline._randomhash()
datetime = Dates.format(Dates.now(), "yyyymmdd-HHMMSS")
cpath = joinpath("coderun", datetime, "config.yaml")

config = DataPipeline._createconfig(cpath)
handle = initialise(config, config)
datastore = handle.config["run_metadata"]["write_data_store"]
namespace = handle.config["run_metadata"]["default_output_namespace"]
version = "0.0.1"

component1 = "component/1"
component2 = "component/2"
component3 = "component/3"

data1 = reshape(rand(10), 2, :)  
data2 = reshape(rand(10), 2, :)  

estimate1 = rand(1)
estimate2 = rand(1)

distribution = Dict("parameters" => Dict("mean" => rand(1), "SD" => rand(1)), 
                    "distribution" => "Gaussian", "type" => "distribution")

Test.@testset "link_write()" begin
    data_product = "data_product/link_write/$uid"
    data_product2 = "$data_product/2"
    file_type = "txt"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description", file_type = file_type, 
                           use_version = version)
    DataPipeline._addwrite(config, data_product2, "description", file_type = file_type, 
                           use_version = version)
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Check function output
    path1 = link_write!(handle, data_product)    
    @test path1 == handle.outputs[(data_product, nothing)]["path"]
    @test length(handle.outputs) == 1
    path1 = link_write!(handle, data_product)    
    @test length(handle.outputs) == 1
    path2 = link_write!(handle, data_product2)   
    @test length(handle.outputs) == 2

    open(path1, "w") do file
        println(file, uid)
    end

    open(path2, "w") do file
        println(file, "$uid/2")
    end

    # Finalise Code Run
    finalise(handle)

    # Check path
    test_path = joinpath("$(datastore)$(namespace)", "$data_product", 
                         "xxxxxxxxxx.$file_type")
    @test path1 == test_path
    test_path2 = joinpath("$(datastore)$(namespace)", "$data_product2", 
                          "xxxxxxxxxx.$file_type")
    @test path2 == test_path2

    # Check file
    should_be_here = joinpath(datastore, handle.outputs[(data_product, nothing)]["path"])
    @test isfile(should_be_here)

    should_be_here = joinpath(datastore, handle.outputs[(data_product2, nothing)]["path"])
    @test isfile(should_be_here)
end

Test.@testset "link_read()" begin
    data_product = "data_product/link_write/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
    handle = initialise(config, config)
    @test handle.inputs == Dict()

    # Check function output
    path1 = link_read!(handle, data_product)
    @test handle.inputs[(data_product, nothing)]["use_dp"] == data_product
    @test length(handle.inputs) == 1
    path1 = link_read!(handle, data_product)  
    @test length(handle.inputs) == 1

    # Finalise Code Run
    finalise(handle)

    # Check data
    dat = open(path1) do file
        read(file, String)
    end
    @test chomp(dat) == uid

    # Check handle 
    hash = DataPipeline._getfilehash(path1)
    should_be_here = joinpath(datastore, namespace, data_product, "$hash.txt")
    @test handle.inputs[(data_product, nothing)]["path"] == should_be_here
end

Test.@testset "write_array()" begin
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description", use_version = version)
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

    path1 = handle.outputs[(data_product, component1)]["path"]
    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    isfile(path1)

    # Finalise Code Run
    finalise(handle)

    newpath1 = handle.outputs[(data_product, component1)]["path"]
    newpath2 = handle.outputs[(data_product, component2)]["path"]

    # Check data
    c1 = HDF5.h5open(newpath1, "r") do file
        read(file, component1)
    end
    @test data1 == c1

    c2 = HDF5.h5open(newpath2, "r") do file
        read(file, component2)
    end
    @test data2 == c2    

    # Check handle 
    hash = DataPipeline._getfilehash(newpath1)
    should_be_here = joinpath(datastore, namespace, data_product, "$hash.h5")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_array()" begin
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
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
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description", use_version = version)
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_estimate(handle, estimate1, data_product, component1, "description1")  
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_estimate(handle, estimate1, data_product, component1, "description1") 
    @test length(handle.outputs) == 1
    write_estimate(handle, estimate2, data_product, component2, "description2")
    @test length(handle.outputs) == 2

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
    newpath1 = handle.outputs[(data_product, component1)]["path"]

    hash = DataPipeline._getfilehash(newpath1)
    should_be_here = joinpath(datastore, namespace, data_product, "$hash.toml")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_estimate()" begin
    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
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
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description", use_version = version)
    handle = initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_distribution(handle, distribution["distribution"], distribution["parameters"], 
                       data_product, component1, "symptom-delay")    
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_distribution(handle, distribution["distribution"], distribution["parameters"], 
                       data_product, component1, "symptom-delay")    
    @test length(handle.outputs) == 1
    write_distribution(handle, distribution["distribution"], distribution["parameters"], 
                       data_product, component2, "symptom-delay")
    @test length(handle.outputs) == 2

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
    newpath1 = handle.outputs[(data_product, component1)]["path"]
    hash = DataPipeline._getfilehash(newpath1)
    should_be_here = joinpath(datastore, namespace, data_product, "$hash.toml")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_distribution()" begin
    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
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

# If an attempt is made to write a new component to a data product that was createtd in 
# a previous Code Run, then an error should be thrown.
Test.@testset "new components aren't added to existing data products" begin
    
    # write_array() -------------------------------------------------------------------

    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description", use_version = version)
    handle = initialise(config, config)

    # Write component
    msg = string("data product already exists in registry: ", data_product, " :-(ns: ",
                 namespace, " - v: ", version, ")")
    @test_throws DataPipeline.ReadWriteException(msg) write_array(
        handle, data1, data_product, component3, "description3")

    # write_estimate() ----------------------------------------------------------------

    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description", use_version = version)
    handle = initialise(config, config)

    # Write component
    msg = string("data product already exists in registry: ", data_product, " :-(ns: ",
                 namespace, " - v: ", version, ")")
    @test_throws DataPipeline.ReadWriteException(msg) write_estimate(
        handle, estimate1, data_product, component3, "description3") 

    # write_distribution() ------------------------------------------------------------
    
    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description", use_version = version)
    handle = initialise(config, config)

    # Write component
    msg = string("data product already exists in registry: ", data_product, " :-(ns: ",
                 namespace, " - v: ", version, ")")
    @test_throws DataPipeline.ReadWriteException(msg) write_distribution(
        handle, distribution["distribution"], distribution["parameters"], 
        data_product, component3, "symptom-delay")
end

end
