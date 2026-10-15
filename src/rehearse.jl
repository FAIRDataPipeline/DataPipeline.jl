# SPDX-License-Identifier: LGPL-3.0-or-later

# A rehearsal: a script run through the pipeline as `fair run` would run it,
# registering nothing. `rehearse` prepares the session, the script's
# `initialise` then opens a rehearsal handle, and `finalise` or `discard` ends
# it. The methods here are the rehearsal's side of what a recorded run
# registers; the recorded side is beside each call.

"""
    rehearse(path; outputs = nothing, local_only = false, restart = false)

Prepare this session to run a script through the pipeline without recording
it. The script then runs unchanged: its [`initialise`](@ref) opens a
[`Rehearsal`](@ref) rather than a recorded code run, its reads and writes go
as they would, and its [`finalise`](@ref) collects the outputs in a folder and
registers nothing. `path` is a user config, which is prepared as `fair run`
prepares one - `fair run --ci --dirty`, with `--local` if `local_only` is true,
run from the project the config is in, which writes the working config and
the script into a new job folder and registers nothing - or that job folder
itself, or the working config in it. Return the job folder.

`outputs` is the folder the outputs are collected in, made if need be; by
default a new folder under the system's temporary directory, which lasts as
long as the system keeps it. The session keeps the rehearsal - the job
folder, the outputs folder, and the handle once opened - and `initialise()`
opens it once: a second call is an error until `finalise` or
[`discard`](@ref) has ended it, and after that too, until `rehearse` is
called again. A second `rehearse` before the rehearsal has ended is an error
unless `restart` is true, when the rehearsal in progress is discarded first:
its handle's files removed from the data store, and its job folder deleted if
`fair run --ci` made it. A session that has recorded a code run cannot
rehearse. A token in the environment is not used by a rehearsal.

The `fair` that prepares a user config is the one [`set_cli!`](@ref)
recorded, else the `fair` on the path, else the copy [`install_cli`](@ref)
made, and with none of those the call fails saying so. Julia started from an
editor has no virtual environment on its path, which is what the last two are
for. [`@fair_str`](@ref) runs the same `fair` with any arguments.
"""
function rehearse(path::AbstractString;
                  outputs::Union{Nothing, AbstractString} = nothing,
                  local_only::Bool = false, restart::Bool = false)
    session = SESSION[]
    if !isnothing(session)
        session.mode isa RecordedRun &&
            throw(ReadWriteException("this session has recorded a code run: a rehearsal belongs in a session that records nothing"))
        if !session.ended
            restart ||
                throw(ReadWriteException("a rehearsal prepared in $(session.job) is in progress: finalise or discard its handle, or call rehearse with restart = true to discard it"))
            _discardcurrent()
        end
    end
    job = _jobfolder(path, local_only)
    folder = _outputsfolder(outputs)
    SESSION[] = SessionRun(Rehearsal(folder), job, nothing, false)
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
under the data store's `jobs/`, and end the session's rehearsal. Return
`nothing`. A handle whose rehearsal has ended only has its files removed. A
recorded code run, being registered already at `initialise`, cannot be
discarded: it ends with [`finalise`](@ref).
"""
function discard(handle::DataRegistryHandle{Rehearsal})
    _removeoutputs(handle)
    if _sessionsopen(handle)
        _closerehearsal(handle)
        println("rehearsal discarded")
    else
        println("this handle's rehearsal had ended already")
    end
    return nothing
end

# Whether `handle` is the session's run, and open
function _sessionsopen(handle::DataRegistryHandle)
    session = SESSION[]
    return !isnothing(session) && session.handle === handle && !session.ended
end
function discard(handle::DataRegistryHandle{RecordedRun})
    return throw(ReadWriteException("code run $(handle.code_run_uuid) is registered already, so cannot be discarded: a recorded run ends with finalise"))
end

# Discard the session's rehearsal where `rehearse` is told to start again:
# through its handle, if one was opened, else by deleting the job folder that
# `fair run --ci` made, there being nothing else
function _discardcurrent()
    session = SESSION[]
    isnothing(session) && return nothing
    if isnothing(session.handle)
        working = joinpath(session.job, "config.yaml")
        isfile(working) &&
            _deletejob(session.job,
                       YAML.load_file(working)["run_metadata"]["write_data_store"])
    else
        discard(session.handle)
    end
    SESSION[] = nothing
    return nothing
end

# Remove what a rehearsal's handle wrote to the data store, and prune the
# store's empty directories: a file already moved to the outputs folder is
# not in the store, and stays
function _removeoutputs(handle::DataRegistryHandle{Rehearsal})
    datastore = handle.config["run_metadata"]["write_data_store"]
    for metadata in values(handle.outputs)
        path = metadata["path"]
        _within(path, datastore) || continue
        isfile(path) && rm(path)
        isdir(dirname(path)) && _pruneempty(dirname(path), datastore)
    end
    empty!(handle.outputs)
    return nothing
end

# The job folder that `path` names: a folder holding a working config; a
# working config, whose folder it is; or a user config, for which `fair` makes
# one
function _jobfolder(path::AbstractString, local_only::Bool)
    if isdir(path)
        isfile(joinpath(path, "config.yaml")) ||
            throw(ArgumentError("$path holds no config.yaml: a job folder is one that `fair run --ci` wrote"))
        return abspath(path)
    elseif isfile(path)
        _isworkingconfig(YAML.load_file(path)) &&
            return dirname(abspath(path))
        return _preparejob(abspath(path), local_only)
    end
    return throw(ArgumentError("no file or folder at $path"))
end

# Have `fair run --ci --dirty` prepare a job for a user config, from the root
# of the project the config is in, and return the job folder it prints as its
# last line, having checked that the folder is there: `fair` can fail and
# still exit 0. Its other lines, the warnings about the repository among
# them, are printed.
function _preparejob(config::String, local_only::Bool)
    root = _fairroot(dirname(config))
    isnothing(root) &&
        throw(ArgumentError("$config is in no FAIR project: run `fair init` in the repository that holds it"))
    command = _withenvironment(`$(_faircommand(nothing)) run --ci --dirty $(local_only ? ["--local"] : String[]) $config`)
    output = IOBuffer()
    process = run(pipeline(Cmd(ignorestatus(command), dir = root),
                           stdout = output, stderr = output))
    text = String(take!(output))
    success(process) ||
        throw(ReadWriteException("`fair run --ci` failed in $root:\n$text"))
    lines = filter(!isempty, strip.(split(text, '\n')))
    job = isempty(lines) ? "" : String(last(lines))
    if !(isdir(job) && isfile(joinpath(job, "config.yaml")))
        throw(ReadWriteException("`fair run --ci` in $root printed no job folder:\n$text"))
    end
    foreach(println, lines[1:(end - 1)])
    return job
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
if `fair run --ci` made it under the data store's `jobs/`, and the session's
rehearsal ended. Return the outputs folder. A handle whose rehearsal has
ended cannot be finalised again.
"""
function finalise(handle::DataRegistryHandle{Rehearsal})
    _sessionsopen(handle) ||
        throw(ReadWriteException("this handle's rehearsal has ended: rehearse again for another"))
    _checksources(handle)
    previous = _previousversions(handle)
    for (data_product, component) in sort(collect(keys(handle.outputs)),
                                          by = string)
        _placeoutput(handle, data_product, component)
    end
    # What is registered already would be no output of a recorded run
    for (key, metadata) in collect(handle.outputs)
        metadata["unchanged"] || continue
        handle.unchanged[key] = pop!(handle.outputs, key)
    end
    _supersedeoutputs!(handle, previous)
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

# End the session's rehearsal: delete the job folder where `fair run --ci`
# made it, and mark the run ended, so that another `initialise()` is told to
# rehearse again rather than finding no file
function _closerehearsal(handle::DataRegistryHandle{Rehearsal})
    _deletejob(handle.config_dir,
               handle.config["run_metadata"]["write_data_store"])
    _ended(handle)
    return nothing
end

# Delete a rehearsal's job folder where `fair run --ci` made it, under the
# data store's `jobs/`; one made elsewhere is the user's and stays
function _deletejob(job::AbstractString, datastore::AbstractString)
    jobs = joinpath(datastore, "jobs")
    if _within(job, jobs)
        rm(job, recursive = true)
    else
        println("  the job folder ", job, " is not under ", jobs,
                " and is left as it is")
    end
    return nothing
end

# Whether `path` lies under the folder `root`, both resolved where they exist.
# On Windows, `relpath` across drives gives the path back absolute, which is
# not under anything.
function _within(path::AbstractString, root::AbstractString)
    isdir(root) || return false
    resolved = isdir(path) ? realpath(path) : abspath(path)
    relative = relpath(resolved, realpath(root))
    return relative != "." && !startswith(relative, "..") &&
           !isabspath(relative)
end
