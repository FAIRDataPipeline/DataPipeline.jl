# SPDX-License-Identifier: LGPL-3.0-or-later

"""
    initialise(config_file = \$FDP_CONFIG_DIR/config.yaml,
               submission_script = \$FDP_CONFIG_DIR/script.sh)

Read the working config that `fair run` wrote, register the config, the
submission script and the code repository with the local registry, open a new
code run, and return the [`DataRegistryHandle`](@ref) the rest of the API
works on. The registry is `run_metadata.local_data_registry_url` (default
`$DEFAULT_REGISTRY_URL`) and the API version `run_metadata.api_version`
(default `$DEFAULT_API_VERSION`).
"""
function initialise(config_file::String = FDP_PATH_CONFIG(),
                    submission_script::String = FDP_PATH_SUBMISSION())
    print("processing config file: ", config_file)
    config = YAML.load_file(config_file)
    run_metadata = config["run_metadata"]
    registry = RegistryEndpoint(get(run_metadata, "local_data_registry_url",
                                    DEFAULT_REGISTRY_URL),
                                get(run_metadata, "api_version",
                                    DEFAULT_API_VERSION))
    datastore = run_metadata["write_data_store"]

    datastore_url = _postentry(registry, "storage_root",
                               Dict("root" => datastore,
                                    "local" => true))["url"]
    config_url = _registerobject(registry, config_file, datastore,
                                 "Working config file")["url"]
    script_url = _registerobject(registry, submission_script, datastore,
                                 "Submission script")["url"]

    remote_repo = run_metadata["remote_repo"]
    repo_root = String(match(r"([a-z]*://[a-z]*.[a-z]*/).*", remote_repo)[1])
    repo_url = _registerobject(registry, remote_repo, repo_root,
                               "Remote code repository.",
                               hash = run_metadata["latest_commit"],
                               local_root = false, file_type = nothing)["url"]

    run_date = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    code_run = _postentry(registry, "code_run",
                          Dict("run_date" => run_date,
                               "description" => run_metadata["description"],
                               "code_repo" => repo_url,
                               "model_config" => config_url,
                               "submission_script" => script_url))
    println(" - pipeline initialised.")

    return DataRegistryHandle(config, dirname(abspath(config_file)), registry,
                              config_url, script_url, repo_url, datastore_url,
                              code_run["url"], code_run["uuid"],
                              Dict(), Dict(), PendingIssue[])
end

"""
    finalise(handle)

Complete the code run: name every output file by its hash and register it,
register the issues raised, attach the inputs and outputs to the code run,
and append the code run's uuid to `coderuns.txt` beside the working config,
where the CLI's `fair add` and `fair push` find it.
"""
function finalise(handle::DataRegistryHandle)
    # In name order, so which of two identical outputs keeps its file, and the
    # order of the code run's inputs and outputs, are the same on every machine
    outputs = String[_registerdataproduct(handle, data_product, component)
                     for (data_product, component) in sort(collect(keys(handle.outputs)),
                                                           by = string)]
    inputs = String[handle.inputs[key]["component_url"]
                    for key in sort(collect(keys(handle.inputs)), by = string)]
    _registerissues(handle)
    url = _patchcoderun(handle, inputs, outputs)

    open(joinpath(handle.config_dir, "coderuns.txt"), "a") do io
        return println(io, handle.code_run_uuid)
    end
    println("finished - code run locally registered as: ", url, "\n")
    return nothing
end

"""
    link_read!(handle, data_product)
    link_read!(handle, pattern)

Return the path of the file behind a `read:` data product of the working
config, recording it as an input of the code run.

Given a pattern instead - a name with one or more `*`, each matching one
segment of a name, so that `era5/t2m/*` matches `era5/t2m/1940-1949` but not
`era5/t2m/a/b` - return the path of a temporary directory holding a symbolic
link to the file of every `read:` data product that matches, each recorded as
an input (the directory itself is not). A link is named after its data
product with `/` replaced by `_`, plus the file's extension; the directory is
named by the SHA-1 of the sorted list of link names and file hashes, so the
same set of files gives the same name. The directory is removed when Julia
exits.
"""
function link_read!(handle::DataRegistryHandle, data_product::String)
    occursin('*', data_product) && return _link_read_directory!(handle,
                                 data_product)
    key = (data_product, nothing)
    haskey(handle.inputs, key) && return handle.inputs[key]["path"]
    path = _readdataproduct(handle, data_product, nothing)
    println("data product found: ", handle.inputs[key]["use_dp"])
    return path
end

"""
    link_read_files!(handle, pattern)

Return the paths of the files behind every `read:` data product of the working
config whose name matches `pattern`, in name order, recording each as an
input of the code run. A pattern is a name with one or more `*`, each
matching one segment of a name, as for [`link_read!`](@ref).
"""
function link_read_files!(handle::DataRegistryHandle, pattern::String)
    return [link_read!(handle, name)
            for name in _matchingreads(handle, pattern)]
end

# The directory of links `link_read!` returns for a pattern
function _link_read_directory!(handle::DataRegistryHandle, pattern::String)
    names = _matchingreads(handle, pattern)
    paths = [link_read!(handle, name) for name in names]
    links = [replace(name, "/" => "_") * "." * _extension(path)
             for (name, path) in zip(names, paths)]
    hashes = [handle.inputs[(name, nothing)]["hash"] for name in names]
    manifest = join(("$link\t$hash\n" for (link, hash) in zip(links, hashes)))
    directory = joinpath(mktempdir(), bytes2hex(SHA.sha1(manifest)))
    mkdir(directory)
    for (link, path) in zip(links, paths)
        try
            symlink(path, joinpath(directory, link))
        catch e
            isa(e, Base.IOError) || rethrow()
            throw(ReadWriteException("cannot make a symbolic link in $directory: $(e.msg)"))
        end
    end
    return directory
end

# The path of a `read:` data product's file, read on first use and recorded as
# an input keyed by `(data_product, component)`
function _inputpath(handle::DataRegistryHandle, data_product::String,
                    component::String)
    key = (data_product, component)
    haskey(handle.inputs, key) && return handle.inputs[key]["path"]
    return _readdataproduct(handle, data_product, component)
end

"""
    read_array(handle, data_product, component)

Read `component` of an HDF5 `read:` data product of the working config as an
array, recording it as an input.
"""
function read_array(handle::DataRegistryHandle, data_product::String,
                    component::String)
    path = _inputpath(handle, data_product, component)
    return process_h5_file(path, false)["/$component"]
end

"""
    read_table(handle, data_product, component)

Read a table data product. Not yet implemented: returns `nothing`.

See also: [`write_table`](@ref), [`read_array`](@ref).
"""
function read_table(handle::DataRegistryHandle, data_product::String,
                    component::String)
    return nothing
end

"""
    read_estimate(handle, data_product, component)

Read the value of the point estimate `component` of a TOML `read:` data
product of the working config, recording it as an input.
"""
function read_estimate(handle::DataRegistryHandle, data_product::String,
                       component::String)
    return _readtoml(handle, data_product, component)["value"]
end

"""
    read_distribution(handle, data_product, component)

Read the distribution `component` of a TOML `read:` data product of the
working config as a `Dict` with `distribution`, `parameters` and `type`,
recording it as an input.
"""
function read_distribution(handle::DataRegistryHandle, data_product::String,
                           component::String)
    return _readtoml(handle, data_product, component)
end

"""
    link_write!(handle, data_product)

Return a path to write a `write:` data product of the working config to, in
the data store, recording it as an output. `finalise` names the file by its
hash and registers it, replacing `\${{RUN_ID}}` in the registered name with
the code run's uuid.
"""
function link_write!(handle::DataRegistryHandle, data_product::String)
    key = (data_product, nothing)
    haskey(handle.outputs, key) && return handle.outputs[key]["path"]
    wmd = _getmetadata(handle, data_product, "write")
    metadata = _resolvewrite(handle, data_product, nothing, wmd["file_type"],
                             nothing)
    handle.outputs[key] = metadata
    return metadata["path"]
end

"""
    write_array(handle, data, data_product, component, description)

Write `data` as `component` of an HDF5 `write:` data product of the working
config, recording it as an output, and return `(data_product, component)`.

See also: [`write_table`](@ref), [`read_array`](@ref), [`read_table`](@ref)
"""
function write_array(handle::DataRegistryHandle, data::Array,
                     data_product::String,
                     component::String, description::String)
    key = (data_product, component)
    haskey(handle.outputs, key) && return key
    metadata = _resolvewrite(handle, data_product, component, "h5",
                             description)
    path = metadata["path"]
    HDF5.h5open(path, isfile(path) ? "r+" : "w") do file
        return write(file, metadata["use_component"], data)
    end
    handle.outputs[key] = metadata
    return key
end

"""
    write_table(handle, data, data_product, component)

Write a table data product. Not yet implemented: returns `nothing`.

See also: [`write_array`](@ref), [`read_array`](@ref), [`read_table`](@ref)
"""
function write_table(handle::DataRegistryHandle, data, data_product::String,
                     component::String)
    return nothing
end

"""
    write_estimate(handle, value, data_product, component, description)

Write `value` as the point estimate `component` of a TOML `write:` data
product of the working config, recording it as an output, and return
`(data_product, component)`.
"""
function write_estimate(handle::DataRegistryHandle, value, data_product::String,
                        component::String, description::String)
    key = (data_product, component)
    haskey(handle.outputs, key) && return key
    data = Dict{String, Any}("value" => value, "type" => "point-estimate")
    _writekeyval(handle, data, data_product, component, description)
    return key
end

"""
    write_distribution(handle, distribution, parameters, data_product,
                       component, description)

Write a `distribution` (its name, and a `Dict` of `parameters`) as
`component` of a TOML `write:` data product of the working config, recording
it as an output, and return `(data_product, component)`.
"""
function write_distribution(handle::DataRegistryHandle, distribution::String,
                            parameters,
                            data_product::String, component::String,
                            description::String)
    key = (data_product, component)
    haskey(handle.outputs, key) && return key
    data = Dict{String, Any}("distribution" => distribution,
                             "parameters" => parameters,
                             "type" => "distribution")
    _writekeyval(handle, data, data_product, component, description)
    return key
end

"""
    raise_issue(handle, target, description; severity = 0)
    raise_issue(handle, targets, description; severity = 0)

Raise an issue with one thing, or with several at once as one registry issue.
A target is an [`AbstractIssueTarget`](@ref) - [`WorkingConfig`](@ref),
[`SubmissionScript`](@ref), [`CodeRepository`](@ref),
[`ConfigDataProduct`](@ref) or [`ExistingDataProduct`](@ref) - or a `String`,
which names a data product of this run as [`ConfigDataProduct`](@ref) does.
`severity` is an integer, larger for worse. Issues are queued in the handle
and registered by [`finalise`](@ref), so an output can be named before it
is written.
"""
function raise_issue(handle::DataRegistryHandle, targets::AbstractVector,
                     description::String; severity::Integer = 0)
    resolved = AbstractIssueTarget[_astarget(target) for target in targets]
    for target in resolved
        _checktarget(handle, target)
    end
    push!(handle.issues, PendingIssue(resolved, description, severity))
    return nothing
end
function raise_issue(handle::DataRegistryHandle,
                     target::Union{AbstractIssueTarget, AbstractString},
                     description::String; severity::Integer = 0)
    return raise_issue(handle, [target], description, severity = severity)
end

# A bare string names a data product of this run
_astarget(target::AbstractIssueTarget) = target
_astarget(data_product::AbstractString) = ConfigDataProduct(data_product)

# A data product named by its config name must be in the working config
function _checktarget(handle::DataRegistryHandle, target::ConfigDataProduct)
    for section in ("read", "write")
        any(entry["data_product"] == target.data_product
            for entry in get(handle.config, section, [])) && return nothing
    end
    return throw(ConfigFileException("'$(target.data_product)' not found in config file"))
end
_checktarget(::DataRegistryHandle, ::AbstractIssueTarget) = nothing
