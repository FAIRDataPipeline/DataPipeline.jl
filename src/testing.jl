# SPDX-License-Identifier: LGPL-3.0-or-later

# Helpers for the test suite, which runs as the script of a `fair run` and
# builds its own working configs from the one it was launched with.

"""
    _startregistry()

Start the FAIR registry installed under `~/.fair`.
"""
function _startregistry()
    path = expanduser("~/.fair/registry/scripts/start_fair_registry")
    run(`sh $path`)
    return nothing
end

"""
    _createconfig(path; kwargs...)

Write a working config holding only a `run_metadata` section at `path` under
the data store, and return its full path. The metadata is that of the working
config the tests were launched with (`\$FDP_CONFIG_DIR/config.yaml`) when
there is one, else a fixed stand-in; any keyword overrides one key of it.
"""
function _createconfig(path; kwargs...)
    launch_config = FDP_PATH_CONFIG()
    if isfile(launch_config)
        run_metadata = YAML.load_file(launch_config)["run_metadata"]
    else
        write_data_store = expanduser("~/.fair/registry/datastore/")
        run_metadata = Dict("public" => true,
                            "latest_commit" => "b8af9e4c5d77521c608188ba63273f959149b532",
                            "local_repo" => pwd(),
                            "remote_data_registry_url" => "http://localhost:8001/api/",
                            "default_input_namespace" => "testing",
                            "default_output_namespace" => "testing",
                            "write_data_store" => write_data_store,
                            "script_path" => joinpath(write_data_store,
                                     "script.sh"),
                            "description" => "A description",
                            "script" => "julia examples/fdp/seirs_sim.jl",
                            "remote_repo" => "https://github.com/FAIRDataPipeline/DataPipeline.jl.git",
                            "local_data_registry_url" => DEFAULT_REGISTRY_URL)
    end
    for (key, value) in kwargs
        run_metadata[String(key)] = value
    end
    data = Dict("run_metadata" => run_metadata)

    fullpath = joinpath(run_metadata["write_data_store"], path)
    mkpath(dirname(fullpath))
    YAML.write_file(fullpath, data)
    return fullpath
end

"""
    _addwrite(path, data_product, description; version, file_type,
              use_data_product, use_component, use_version, use_namespace)

Append a `write:` entry to the working config at `path` and return `path`.
"""
function _addwrite(path::String, data_product::String, description::String;
                   version = nothing, file_type = nothing,
                   use_data_product = nothing, use_component = nothing,
                   use_version = nothing, use_namespace = nothing)
    data = YAML.load_file(path)
    writes = get(data, "write", Vector{Dict}())

    new_write = Dict{String, Any}("data_product" => data_product,
                                  "description" => description)
    isnothing(version) || (new_write["version"] = version)
    isnothing(file_type) || (new_write["file_type"] = file_type)
    new_write["use"] = _usesection(use_data_product, use_component,
                                   use_version, use_namespace)

    push!(writes, new_write)
    data["write"] = writes
    YAML.write_file(path, data)
    return path
end

"""
    _addread(path, data_product; version, use_data_product, use_component,
             use_version, use_namespace)

Append a `read:` entry to the working config at `path` and return `path`.
"""
function _addread(path::String, data_product::String; version = nothing,
                  use_data_product = nothing,
                  use_component = nothing, use_version = nothing,
                  use_namespace = nothing)
    data = YAML.load_file(path)
    reads = get(data, "read", Vector{Dict}())

    new_read = Dict{String, Any}("data_product" => data_product)
    isnothing(version) || (new_read["version"] = version)
    new_read["use"] = _usesection(use_data_product, use_component,
                                  use_version, use_namespace)

    push!(reads, new_read)
    data["read"] = reads
    YAML.write_file(path, data)
    return path
end

# The `use:` block of a config entry, holding only the keys that were given
function _usesection(data_product, component, version, namespace)
    use = Dict{String, Any}()
    isnothing(data_product) || (use["data_product"] = data_product)
    isnothing(component) || (use["component"] = component)
    isnothing(version) || (use["version"] = version)
    isnothing(namespace) || (use["namespace"] = namespace)
    return use
end

"""
    _randomhash()

Return a random 40-character hexadecimal string, for temporary file names,
the length of the SHA-1 the Python and R APIs use for the same purpose.
"""
function _randomhash()
    return bytes2hex(rand(UInt8, 20))
end
