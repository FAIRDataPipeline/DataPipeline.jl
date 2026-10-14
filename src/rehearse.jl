# SPDX-License-Identifier: LGPL-3.0-or-later

# A rehearsal: a script run through the pipeline as `fair run` would run it,
# registering nothing. `rehearse` prepares the session, the script's
# `initialise` then opens a rehearsal handle, and `finalise` or `discard` ends
# it. The methods here are the rehearsal's side of what a recorded run
# registers; the recorded side is beside each call.

"""
    rehearse(path; outputs = nothing)

Prepare this session to run a script through the pipeline without recording
it. The script then runs unchanged: its [`initialise`](@ref) opens a
[`Rehearsal`](@ref) rather than a recorded code run, its reads and writes go
as they would, and its [`finalise`](@ref) collects the outputs in a folder and
registers nothing. `path` is the job folder that `fair run --ci` wrote,
holding the working config and the script, or that working config itself.
Return the job folder.

`outputs` is the folder the outputs are collected in, made if need be; by
default a new folder under the system's temporary directory, which lasts as
long as the system keeps it. The folder's path is kept in `FDP_REHEARSAL` and
the job folder's in `FDP_CONFIG_DIR`, the variables `initialise` reads; a
`FDP_LOCAL_TOKEN` in the session is removed, with a warning, since a
rehearsal holds no token. [`discard`](@ref) ends a rehearsal without
collecting its outputs.
"""
function rehearse(path::AbstractString;
                  outputs::Union{Nothing, AbstractString} = nothing)
    job = _jobfolder(path)
    folder = _outputsfolder(outputs)
    if haskey(ENV, "FDP_LOCAL_TOKEN")
        @warn "FDP_LOCAL_TOKEN was set in this session and is removed: a rehearsal holds no token"
        delete!(ENV, "FDP_LOCAL_TOKEN")
    end
    ENV["FDP_CONFIG_DIR"] = job
    ENV["FDP_REHEARSAL"] = folder
    println("rehearsing the run prepared in ", job)
    println("run the script, or its lines, in this session: ",
            "DataPipeline.finalise collects its outputs in ", folder,
            ", and DataPipeline.discard throws them away")
    return job
end

"""
    discard(handle)

End a rehearsal without collecting its outputs: remove the files it wrote to
the data store, delete the job folder it ran from if `fair run --ci` made it
under the data store's `jobs/`, and clear `FDP_CONFIG_DIR` and
`FDP_REHEARSAL` from the session. Return `nothing`. A recorded code run,
being registered already at `initialise`, cannot be discarded: it ends with
[`finalise`](@ref).
"""
function discard(handle::DataRegistryHandle{Rehearsal})
    datastore = handle.config["run_metadata"]["write_data_store"]
    for metadata in values(handle.outputs)
        path = metadata["path"]
        isfile(path) && rm(path)
        isdir(dirname(path)) && _pruneempty(dirname(path), datastore)
    end
    empty!(handle.outputs)
    _closerehearsal(handle)
    println("rehearsal discarded")
    return nothing
end
function discard(handle::DataRegistryHandle{RecordedRun})
    return throw(ReadWriteException("code run $(handle.code_run_uuid) is registered already, so cannot be discarded: a recorded run ends with finalise"))
end

# The job folder that `path` names: a folder holding a working config, or a
# working config, whose folder it is
function _jobfolder(path::AbstractString)
    if isdir(path)
        isfile(joinpath(path, "config.yaml")) ||
            throw(ArgumentError("$path holds no config.yaml: a job folder is one that `fair run --ci` wrote"))
        return abspath(path)
    elseif isfile(path)
        _isworkingconfig(YAML.load_file(path)) &&
            return dirname(abspath(path))
        throw(ArgumentError("$path is not a working config: run `fair run --ci --dirty` on it and give rehearse the job folder it prints"))
    end
    return throw(ArgumentError("no file or folder at $path"))
end

# The outputs folder, made: the one asked for, else a new temporary one that
# outlives the session
function _outputsfolder(::Nothing)
    return mktempdir(tempdir(); prefix = "fdp-rehearsal-", cleanup = false)
end
function _outputsfolder(outputs::AbstractString)
    mkpath(outputs)
    return abspath(outputs)
end

# Open a rehearsal: a handle with no registry URLs, its uuid made here so that
# `${{RUN_ID}}` resolves, and a commit with uncommitted changes warned of
function _openrun(mode::Rehearsal, config::Dict, config_file::String,
                  ::String, registry::RegistryEndpoint)
    commit = config["run_metadata"]["latest_commit"]
    endswith(commit, "-dirty") &&
        @warn "the code repository has uncommitted changes ($commit): a recorded run would raise an issue against it"
    println("rehearsal: nothing is registered, and the outputs go to ",
            mode.outputs)
    return _newhandle(mode, config, config_file, registry,
                      (config = nothing, script = nothing,
                       repository = nothing, datastore = nothing,
                       code_run = nothing), string(uuid4()))
end

# What `link_register!` would register, said rather than done, and `nothing`
# in place of the data product's entry
function _registerexternal(::DataRegistryHandle{Rehearsal},
                           data_product::String, namespace::String,
                           version::String, file::Union{Nothing, NamedTuple},
                           source::SourceRecord)
    println("would register ", namespace, ":", data_product, " (", version,
            ") from ", source.identifier,
            isnothing(file) ? ", with no file" : ", the file " * file.path)
    return nothing
end

# An author the registry lacks is said to be wanted, not created
function _createauthor(::DataRegistryHandle{Rehearsal}, name::AbstractString,
                       identifier::AbstractString)
    println("would register the author ", name, " (", identifier, ")")
    return nothing
end
function _newnamedauthor(::DataRegistryHandle{Rehearsal}, name::AbstractString)
    println("would register an author named ", name)
    return _unregisteredauthor(name)
end

# What stands for an author the registry lacks in a rehearsal's source, where
# a recorded run would have the URL of the author it created: never a URL, so
# a registered file with that author is never found unchanged by it
_unregisteredauthor(name::AbstractString) = "unregistered author: " * name

"""
    finalise(handle::DataRegistryHandle{Rehearsal})

End a rehearsal, registering nothing. The outputs are checked as a recorded
run checks them - that each source is one file, and whether each file is the
one registered as the highest version of its data product, which is reported
- and moved to the outputs folder as
`<namespace>/<data product>/<version>.<extension>`, replacing what is there,
with the working config and the script copied beside them. The issues raised
are printed, the data store's empty directories pruned, the job folder deleted
if `fair run --ci` made it under the data store's `jobs/`, and `FDP_CONFIG_DIR`
and `FDP_REHEARSAL` cleared from the session. Return the outputs folder.
"""
function finalise(handle::DataRegistryHandle{Rehearsal})
    _checksources(handle)
    for (data_product, component) in sort(collect(keys(handle.outputs)),
                                          by = string)
        _placeoutput(handle, data_product, component)
    end
    # What is registered already would be no output of a recorded run
    for (key, metadata) in collect(handle.outputs)
        metadata["unchanged"] || continue
        handle.unchanged[key] = pop!(handle.outputs, key)
    end
    _copyjobfiles(handle)
    _printrehearsal(handle)
    _closerehearsal(handle)
    return handle.mode.outputs
end

# Move one output's file from the data store to the outputs folder, named by
# its data product and version, after comparing it with the highest version
# registered; a data product's components share its file, so the first of
# them moves it and the rest take its place
function _placeoutput(handle::DataRegistryHandle{Rehearsal},
                      data_product::String, component::Union{Nothing, String})
    wmd = handle.outputs[(data_product, component)]
    datastore = handle.config["run_metadata"]["write_data_store"]
    use_data_product = replace(wmd["use_dp"],
                               RUN_ID_PLACEHOLDER => handle.code_run_uuid)
    wmd["use_dp"] = use_data_product
    placed = [value
              for (key, value) in handle.outputs
              if key[1] == data_product && haskey(value, "unchanged")]
    if isempty(placed)
        filepath = wmd["path"]
        isfile(filepath) ||
            throw(ReadWriteException("File not found: $use_data_product is present in handle but not in data store."))
        hash = get(wmd, "hash") do
            return _getfilehash(filepath)
        end
        held = _unchangedfile(handle.registry, wmd["use_namespace"],
                              use_data_product, hash,
                              _outputsource(handle, data_product))
        unchanged = !isnothing(held)
        unchanged && println("data product unchanged: ", use_data_product,
                " (", held.version,
                "): a recorded run would not register it again")
        destination = joinpath(handle.mode.outputs, wmd["use_namespace"],
                               use_data_product,
                               string(wmd["use_version"], ".",
                                      _extension(filepath)))
        mkpath(dirname(destination))
        mv(filepath, destination, force = true)
        _pruneempty(dirname(filepath), datastore)
    else
        destination = placed[1]["path"]
        unchanged = placed[1]["unchanged"]
    end
    wmd["path"] = destination
    wmd["unchanged"] = unchanged
    wmd["component_url"] = nothing
    return nothing
end

# Copy the working config and the script from the job folder to the outputs
# folder, so that the outputs keep what they were made under
function _copyjobfiles(handle::DataRegistryHandle{Rehearsal})
    for name in ("config.yaml", FDP_SUBMISSION_SCRIPT)
        file = joinpath(handle.config_dir, name)
        isfile(file) && cp(file, joinpath(handle.mode.outputs, name),
           force = true)
    end
    return nothing
end

# Print what the rehearsal did: its inputs, its outputs and where they are,
# the issues a recorded run would have raised
function _printrehearsal(handle::DataRegistryHandle{Rehearsal})
    println("rehearsal finished - nothing registered")
    for (label, table) in (("inputs", handle.inputs),
        ("outputs", handle.outputs),
        ("unchanged, registered already", handle.unchanged))
        isempty(table) && continue
        println("  ", label, ":")
        for key in sort(collect(keys(table)), by = string)
            metadata = table[key]
            println("    ", metadata["use_namespace"], ":",
                    metadata["use_dp"],
                    isnothing(key[2]) ? "" : " / " * key[2], " (",
                    metadata["use_version"], ") ",
                    something(metadata["path"], "no file"))
        end
    end
    isempty(handle.issues) || println("  issues a recorded run would raise:")
    for issue in handle.issues
        println("    severity ", issue.severity, " on ",
                join((sprint(show, target) for target in issue.targets),
                     ", "), ": ", issue.description)
    end
    println("  outputs folder: ", handle.mode.outputs)
    return nothing
end

# End a rehearsal's hold on the session: delete the job folder where `fair run
# --ci` made it, under the data store's `jobs/` - one made elsewhere is the
# user's and stays - and clear the two variables, so that another
# `initialise()` is told there is no run rather than finding no file
function _closerehearsal(handle::DataRegistryHandle{Rehearsal})
    jobs = joinpath(handle.config["run_metadata"]["write_data_store"], "jobs")
    if _within(handle.config_dir, jobs)
        rm(handle.config_dir, recursive = true)
    else
        println("  the job folder ", handle.config_dir, " is not under ",
                jobs, " and is left as it is")
    end
    delete!(ENV, "FDP_CONFIG_DIR")
    delete!(ENV, "FDP_REHEARSAL")
    return nothing
end

# Whether `path` lies under the folder `root`, both resolved where they exist
function _within(path::AbstractString, root::AbstractString)
    isdir(root) || return false
    resolved = isdir(path) ? realpath(path) : abspath(path)
    relative = relpath(resolved, realpath(root))
    return relative != "." && !startswith(relative, "..")
end
