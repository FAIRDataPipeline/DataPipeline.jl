module TestAPI

using DataPipeline
using HDF5
using Test

DataPipeline._startregistry()

Test.@testset "write_array()" begin
    config = "test.yaml"
    data_product = DataPipeline._randomhash()

    # Create config.yaml
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

    h5_path = handle.outputs[data_product]["path"]
    
    c1 = HDF5.h5open(h5_path, "r") do file
        read(file, component1)
    end
    @test data1 == c1

    c2 = HDF5.h5open(h5_path, "r") do file
        read(file, component2)
    end
    @test data2 == c2    
    
end

end