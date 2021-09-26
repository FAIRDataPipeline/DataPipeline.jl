"""
    _startregistry()

Start FAIR registry.
""" 
function _startregistry()
    path = expanduser("~/.fair/registry/scripts/start_fair_registry")
    if !ispath(path) 
        path = joinpath("/home/runner/work/DataPipeline.jl/DataPipeline.jl", 
                        ".fair/registry/scripts/start_fair_registry")
    end
    cmd = `sh $path`
    run(cmd)
    return nothing
end

"""
    _createconfig()

Generate `run_metadata` section of (user-written) config.yaml file.
""" 
function _createconfig(path)
    run_metadata = Dict("public" => true,
                        "latest_commit" => "b8af9e4c5d77521c608188ba63273f959149b532",
                        "local_repo" => "/Users/Soniam/Desktop/git/FAIRDataPipeline/DataPipeline.jl",
                        "remote_data_registry_url" => "http://localhost:8001/api/",
                        "default_input_namespace" => "testing", 
                        "default_output_namespace" => "testing", 
                        "write_data_store" => expanduser("~/.fair/registry/datastore/"),
                        "script_path" => expanduser("~/.fair/registry/datastore/script.sh"),
                        "description" => "A description", 
                        "script" => "julia examples/fdp/seirs_sim.jl",
                        "remote_repo" => "https://github.com/FAIRDataPipeline/DataPipeline.jl.git",
                        "local_data_registry_url" => "http://localhost:8000/api/")
    data = Dict("run_metadata" => run_metadata)
    YAML.write_file(path, data)
    return(nothing)
end

"""
    _addwrite()

Add `write` section to (user-written) config.yaml file.
""" 
function _addwrite(path::String, data_product::String, description::String; 
                   version=nothing, file_type=nothing, 
                   use_data_product=nothing, use_component=nothing, 
                   use_version=nothing, use_namespace=nothing)
    # Read in config file 
    data = YAML.load_file(path)

    # Existing writes
    writes = get(data, "write", Vector{Dict}())

    # Add new write
    new_write = Dict()
    new_write["data_product"] = data_product
    new_write["description"] = description
    if !isnothing(version)
        new_write["version"] = version
    end

    if !isnothing(file_type) 
        new_write["file_type"] = file_type 
    end

    if !isnothing(use_data_product)
        new_write["use"] = Dict("data_product" => use_data_product)
    end

    if !isnothing(use_component)
        new_write["use"] = Dict("component" => use_component) 
    end

    if !isnothing(use_version)
        new_write["use"] = Dict("version" => use_version) 
    end

    if !isnothing(use_namespace)
        new_write["use"] = Dict("namespace" => use_namespace)
    end
        
    push!(writes, new_write)
    data["write"] = writes

    # Write to config file
    YAML.write_file(path, data)
    return(nothing)
end

"""
    _addread()

Add `read` section to (user-written) config.yaml file.
""" 
function _addread(path::String, data_product::String; version=nothing, 
                  file_type=nothing, use_data_product=nothing, 
                  use_component=nothing, use_version=nothing, 
                  use_namespace=nothing)
    # Read in config file 
    data = YAML.load_file(path)

    # Existing reads
    reads = get(data, "read", Vector{Dict}())

    # Add new read
    new_read = Dict()
    new_read["data_product"] = data_product
    new_read["description"] = description
    if !isnothing(version) new_read["version"] = version end
    if !isnothing(file_type) new_read["file_type"] = file_type end
    if !isnothing(use_data_product) new_read["use_data_product"] = use_data_product end
    if !isnothing(use_component) new_read["use_component"] = use_component end
    if !isnothing(use_version) new_read["use_version"] = use_version end
    if !isnothing(use_namespace) new_read["use_namespace"] = use_namespace end
    push!(reads, new_read)
    data["read"] = reads

    # Write to config file
    YAML.write_file(path, data)
    return(nothing)
end

"""
    _randomhash()

Generate random hash.
"""
function _randomhash()
    date = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    hash = bytes2hex(SHA.sha2_256(date))
    return hash
end