module TestAPI

using DataPipeline
using HDF5
using Test

Test.@testset "link_write()" begin
    config = "test.yaml"
    data_product = DataPipeline._randomhash()
    file_type = "csv"

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", file_type = file_type, 
                           use_version = "0.0.1")
    handle = initialise(config, config)

    # Test that returned file path matches handle
    path = link_write!(handle, data_product)    
    @test path == handle.outputs[data_product]["path"]

    # Test that returned file path is correct 
    datastore = handle.config["run_metadata"]["write_data_store"]
    namespace = handle.config["run_metadata"]["default_output_namespace"]
    test_path = joinpath("$(datastore)$(namespace)", "$data_product", 
                         "xxxxxxxxxx.$file_type")
    @test path == test_path
end

Test.@testset "write_array()" begin
    config = "test.yaml"
    data_product = DataPipeline._randomhash()

    # Create working config.yaml
    DataPipeline._createconfig(config)
    DataPipeline._addwrite(config, data_product, "description", use_version = "0.0.1")
    handle = initialise(config, config)

    # First component
    component1 = "component/1"
    data1 = reshape(rand(10), 2, :)  
    write_array(handle, data1, data_product, component1)
    
    # Second component
    component2 = "component/2"
    data2 = reshape(rand(10), 2, :)  
    write_array(handle, data2, data_product, component2)

    # Test that data in component1 of hdf5 file matches data1
    h5_path = handle.outputs[data_product]["path"]
    c1 = HDF5.h5open(h5_path, "r") do file
        read(file, component1)
    end
    @test data1 == c1

    # Test that data in component2 of hdf5 file matches data2
    c2 = HDF5.h5open(h5_path, "r") do file
        read(file, component2)
    end
    @test data2 == c2    
    
end

end