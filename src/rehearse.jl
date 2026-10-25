# SPDX-License-Identifier: LGPL-3.0-or-later

# A rehearsal: a script run through the pipeline as `fair run` would run it,
# registering nothing. `rehearse` prepares the session, the script's
# `initialise` then opens a rehearsal handle, and `finalise` or `discard` ends
# it; in a block, `rehearse` opens the handle itself and discards it as the
# block ends. The methods here are the rehearsal's side of what a recorded run
# registers; the recorded side is beside each call.

"""
    rehearse(path; outputs = nothing, local_only = false, restart = false)
    rehearse(f, [path]; outputs = nothing, local_only = false, restart = false)

Prepare this session to run a script through the pipeline without recording
it. The script then runs unchanged: its [`initialise`](@ref) opens a
[`Rehearsal`](@ref) rather than a recorded code run, its reads and writes go
as they would, and its [`finalise`](@ref) collects the outputs in a folder and
registers nothing. `path` is a user config, which is prepared as `fair run`
prepares one, from the project the config is in and with `--local` if
`local_only` is true: by `fair run --rehearse`, which writes the working config
and the script into a new job folder, registers and stages nothing, and makes
no git check, and which `fair-cli` has from 0.11.0. Or `path` is that job
folder itself, or the working config in it. Return the job folder.

`outputs` is the folder the outputs are collected in, made if need be; by
default a new folder under the system's temporary directory, which lasts as
long as the system keeps it. The session keeps the rehearsal - the job
folder, the outputs folder, and the handle once opened - and `initialise()`
opens it once: a second call is an error until `finalise` or
[`discard`](@ref) has ended it, and after that too, until `rehearse` is
called again. A second `rehearse` before the rehearsal has ended is an error
unless `restart` is true, when the rehearsal in progress is discarded first:
its handle's files removed from the data store, and its job folder deleted if
`rehearse` had `fair` prepare it. A job folder given as `path` is not deleted.
A session that has recorded a code run cannot rehearse. A token in the
environment is not used by a rehearsal.

With a function `f` first, as a `do` block, the rehearsal is a check: its
handle is opened at once and passed to `f`, the rehearsal is discarded when
`f` returns or throws - what `f` wrote removed from the data store - and `f`'s
value is returned. The session is then empty, so that a script's
`initialise()` opens the run it was launched for. With no `path`, the
rehearsal is of that run, the job folder `fair run` names in `FDP_CONFIG_DIR`,
so that a script can find out whether it has anything to do before a code run
exists:

```julia
nothing_to_do = DataPipeline.rehearse() do handle
    return isempty(missing_inputs(handle))    # the script's own check
end
nothing_to_do && exit()
handle = DataPipeline.initialise()
```

A block prints one line, the run after it saying again what a rehearsal says
as it opens, and an outputs folder made for it is removed if `f` left nothing
there. A script that `fair run` launched, which sets `FDP_SESSION` for it,
rehearses in a block only: `rehearse(path)` there is an error, since its
`initialise()` would open the rehearsal in place of the run `fair run`
prepared, and record nothing.

The rehearsal's script reads the local registry, so the rehearsal keeps it
running until `finalise` or `discard` ends it: through a session of the
CLI's, which ends with it - and, run by `fair run`, through the run's own
session. A registry that `fair registry start` started runs until `fair
registry stop` either way.

The `fair` that prepares a user config is the one [`set_cli!`](@ref)
recorded, else the `fair` on the path, else the copy [`install_cli`](@ref)
made, and with none of those the call fails saying so. Julia started from an
editor has no virtual environment on its path, which is what the last two are
for. [`@fair_str`](@ref) runs the same `fair` with any arguments.
"""
function rehearse(path::AbstractString;
                  outputs::Union{Nothing, AbstractString} = nothing,
                  local_only::Bool = false, restart::Bool = false)
    haskey(ENV, "FDP_SESSION") &&
        throw(ReadWriteException("this script was launched by `fair run`, whose run its `initialise()` opens: a rehearsal prepared here would open in that run's place and record nothing. To check something before the run, rehearse in a block, `DataPipeline.rehearse() do handle ... end`, which ends before the run opens"))
    job = _preparerehearsal(path, outputs, local_only, restart, false)
    println("rehearsing the run prepared in ", job)
    println("run the script, or its lines, in this session: ",
            "DataPipeline.finalise collects its outputs in ",
            SESSION[].mode.outputs,
            ", and DataPipeline.discard throws them away")
    return job
end
function rehearse(f::Function, path::AbstractString;
                  outputs::Union{Nothing, AbstractString} = nothing,
                  local_only::Bool = false, restart::Bool = false)
    job = _preparerehearsal(path, outputs, local_only, restart, true)
    folder = SESSION[].mode.outputs
    println("checking the run prepared in ", job,
            " by a rehearsal, which registers nothing")
    try
        return f(initialise())
    finally
        _endblock()
        isnothing(outputs) && isdir(folder) && isempty(readdir(folder)) &&
            rm(folder)
    end
end
function rehearse(f::Function;
                  outputs::Union{Nothing, AbstractString} = nothing,
                  local_only::Bool = false, restart::Bool = false)
    haskey(ENV, "FDP_CONFIG_DIR") ||
        throw(ArgumentError("no run was launched to rehearse: `fair run` names its job folder in FDP_CONFIG_DIR, which is not set - give rehearse the job folder or the user config"))
    return rehearse(f, FDP_CONFIG_DIR(); outputs, local_only, restart)
end

# Prepare the session's rehearsal of `path`, a block's where `inblock` is true,
# and return its job folder. A session that has recorded a code run is
# refused, and so is one with a rehearsal in progress, unless `restart`, when
# that rehearsal is discarded.
function _preparerehearsal(path::AbstractString,
                           outputs::Union{Nothing, AbstractString},
                           local_only::Bool, restart::Bool, inblock::Bool)
    session = SESSION[]
    in_progress = false
    if !isnothing(session)
        session.mode isa RecordedRun &&
            throw(ReadWriteException("this session has recorded a code run: a rehearsal belongs in a session that records nothing"))
        if !session.ended
            restart ||
                throw(ReadWriteException("a rehearsal prepared in $(session.job) is in progress: finalise or discard its handle, or call rehearse with restart = true to discard it"))
            in_progress = true
        end
    end
    # Held before the rehearsal being restarted lets its hold go, so that a
    # registry that hold started is not stopped and started again
    hold = _holdregistry()
    job, folder = try
        in_progress && _discardcurrent()
        (_jobfolder(path, local_only), _outputsfolder(outputs))
    catch
        _releaseregistry(hold)
        rethrow()
    end
    SESSION[] = SessionRun(Rehearsal(folder), job.folder, job.prepared,
                           inblock, nothing, false, hold)
    return job.folder
end

# End a block's rehearsal, however the block ended: where the block left its
# handle open, what the handle wrote to the data store is removed and the
# rehearsal closed; where no handle was opened, the rehearsal is discarded as
# `restart` discards one; and the session is left empty. A session that is not
# a block's - one the block itself replaced - is left as it is.
function _endblock()
    session = SESSION[]
    (isnothing(session) || !session.inblock) && return nothing
    if isnothing(session.handle)
        _discardcurrent()
    elseif !session.ended
        _removeoutputs(session.handle)
        _closerehearsal(session.handle)
    end
    SESSION[] = nothing
    return nothing
end

# Whether the session's rehearsal is a block's, which says little as it opens:
# the run after the block says it again
function _inblock()
    session = SESSION[]
    return !isnothing(session) && session.inblock
end

"""
    discard(handle)

End a rehearsal without collecting its outputs: remove the files it wrote to
the data store, delete the job folder it ran from if [`rehearse`](@ref) had
`fair` prepare it, and end the session's rehearsal. Return `nothing`. A handle whose rehearsal has ended only has its files removed. A
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
# `rehearse` had `fair` prepare, there being nothing else
function _discardcurrent()
    session = SESSION[]
    isnothing(session) && return nothing
    if isnothing(session.handle)
        working = joinpath(session.job, "config.yaml")
        session.prepared && isfile(working) &&
            _deletejob(session.job,
                       YAML.load_file(working)["run_metadata"]["write_data_store"])
    else
        discard(session.handle)
    end
    _releasehold!()
    SESSION[] = nothing
    return nothing
end

# Release the session's hold on the local registry, once
function _releasehold!()
    session = SESSION[]
    (isnothing(session) || isnothing(session.hold)) && return nothing
    SESSION[] = SessionRun(session.mode, session.job, session.prepared,
                           session.inblock, session.handle, session.ended,
                           nothing)
    _releaseregistry(session.hold)
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

# The job folder that `path` names, as `(folder, prepared)`, `prepared` saying
# whether `fair` made it here: a folder holding a working config; a working
# config, whose folder it is; or a user config, for which `fair` makes one
function _jobfolder(path::AbstractString, local_only::Bool)
    if isdir(path)
        isfile(joinpath(path, "config.yaml")) ||
            throw(ArgumentError("$path holds no config.yaml: a job folder is one that `fair run --rehearse` or `fair run --ci` wrote"))
        return (folder = abspath(path), prepared = false)
    elseif isfile(path)
        _isworkingconfig(YAML.load_file(path)) &&
            return (folder = dirname(abspath(path)), prepared = false)
        return (folder = _preparejob(abspath(path), local_only),
                prepared = true)
    end
    return throw(ArgumentError("no file or folder at $path"))
end

# Have `fair` prepare a job for a user config, from the root of the project
# the config is in, and return the job folder
function _preparejob(config::String, local_only::Bool)
    root = _fairroot(dirname(config))
    isnothing(root) &&
        throw(ArgumentError("$config is in no FAIR project: run `fair init` in the repository that holds it"))
    options = local_only ? ["--local"] : String[]
    return _rehearsedjob(_faircommand(nothing), root, config, options)
end

# The job folder `fair run --rehearse` prepares, named in the one JSON object
# it prints, what it wrote as its log being printed. A `fair` with no such
# option, told by its usage error, is refused; a failure is an error carrying
# what it wrote, and so is an exit of 0 naming no job folder, which is how it
# ends having written a warning and prepared nothing
function _rehearsedjob(command::Cmd, root::AbstractString,
                       config::AbstractString, options::Vector{String})
    prepared = _capturefair(command, "run", "--rehearse", options..., config;
                            dir = root)
    (prepared.status == 2 &&
     occursin(r"[Nn]o such option", prepared.errors) &&
     occursin("--rehearse", prepared.errors)) &&
        throw(_oldcli(command, "`fair run --rehearse`"))
    prepared.status == 0 ||
        throw(ReadWriteException("`fair run --rehearse` failed in $root with exit status $(prepared.status):\n$(prepared.errors)"))
    reply = try
        JSON.parse(prepared.printed)
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
    job = reply isa AbstractDict ? get(reply, "job_dir", nothing) : nothing
    if !(job isa AbstractString && isfile(joinpath(job, "config.yaml")))
        throw(ReadWriteException("`fair run --rehearse` in $root prepared no job folder:\n$(prepared.printed)$(prepared.errors)"))
    end
    foreach(println, filter(!isempty, strip.(split(prepared.errors, '\n'))))
    return String(job)
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
    if !_inblock()
        commit = config["run_metadata"]["latest_commit"]
        endswith(commit, "-dirty") &&
            @warn "the code repository has uncommitted changes ($commit): a recorded run would raise an issue against it"
        println("rehearsal: nothing is registered, and the outputs go to ",
                mode.outputs)
        _rehearserepository(registry, config["run_metadata"])
    end
    return _newhandle(mode, config, config_file, registry,
                      (config = nothing, script = nothing,
                       repository = nothing, datastore = nothing,
                       code_run = nothing), string(uuid4()))
end

# What a recorded run would register of the code repository at its commit,
# said rather than done: the object the registry holds kept, or one made with
# the authors the repository's metadata gives; its licence and keywords
function _rehearserepository(registry::RegistryEndpoint, run_metadata::Dict)
    metadata = _runrepositorymetadata(run_metadata)
    commit = run_metadata["latest_commit"]
    held = _heldrepository(registry, run_metadata).object
    if isnothing(held)
        authors = isempty(metadata.authors) ? "the runner" :
                  join(metadata.authors, ", ")
        println("would register the code repository at ", commit,
                ", its authors ", authors,
                isempty(metadata.files) ? "" :
                " (from $(first(metadata.files)))")
    else
        println("would keep the code repository's object at ", commit, ", ",
                held)
    end
    isnothing(metadata.licence) ||
        println("  with the licence ", metadata.licence)
    isempty(metadata.keywords) ||
        println("  with the keywords ", join(metadata.keywords, ", "))
    return nothing
end

# What `register_release!` would register, said rather than done, and
# `nothing` in place of the release
function _registerrelease(::Rehearsal, registry::RegistryEndpoint,
                          target::NamedTuple,
                          website::Union{Nothing, String},
                          source::Union{Nothing, NamedTuple})
    held = _heldrepository(registry, target.remote, target.commit).object
    println("would register the release ", target.release, " ",
            target.version, " of commit ", target.commit, ", its data product ",
            _dataproductname(target.namespace, target.data_product,
                             target.version),
            isnothing(website) ? "" : ", its website $website")
    if isnothing(held)
        authors = target.metadata.authors
        println("  on a new object for the commit, its authors ",
                isempty(authors) ? "the runner" : join(authors, ", "))
    else
        println("  on the commit's object ", held)
    end
    isnothing(source) ||
        println("  with the source ", source.identifier)
    return nothing
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
run checks them: that each source is one file, that each written as a version
registered already reproduces it, and whether each file is the one
registered as the highest version of its data product, which is reported.
They are then moved to the outputs folder as
`<namespace>/<data product>/<version>.<extension>`, replacing what is there,
with the working config and the script copied beside them. The issues raised
are printed, the data store's empty directories pruned, the job folder deleted
if [`rehearse`](@ref) had `fair` prepare it, and the session's rehearsal
ended. Return the outputs folder. A handle whose rehearsal has
ended cannot be finalised again.
"""
function finalise(handle::DataRegistryHandle{Rehearsal})
    _sessionsopen(handle) ||
        throw(ReadWriteException("this handle's rehearsal has ended: rehearse again for another"))
    _checksources(handle)
    _checkversions(handle)
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
        held = _heldfile(handle.registry, wmd["use_namespace"],
                         use_data_product, String(wmd["use_version"]), hash,
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
    for file in (joinpath(handle.config_dir, "config.yaml"),
                 _submissionscript(handle.config, handle.config_dir))
        isfile(file) &&
            cp(file, joinpath(handle.mode.outputs, basename(file)),
               force = true)
    end
    return nothing
end

# An issue raised outside a run while rehearsing: printed as what would be
# raised, and nothing registered
function _raiseoutsiderun(::Rehearsal, ::RegistryEndpoint, issue::PendingIssue,
                          ::Vector{String})
    println("rehearsing, so registering nothing: an issue of severity ",
            issue.severity, " on ",
            join((sprint(show, target) for target in issue.targets),
                 ", "), ": ", issue.description)
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

# End the session's rehearsal, whose handle this is: delete the job folder
# where `rehearse` had `fair` prepare it, mark the run ended, so that another
# `initialise()` is told to rehearse again rather than finding no file, and
# release its hold on the registry
function _closerehearsal(handle::DataRegistryHandle{Rehearsal})
    SESSION[].prepared &&
        _deletejob(handle.config_dir,
                   handle.config["run_metadata"]["write_data_store"])
    _ended(handle)
    _releasehold!()
    return nothing
end

# Delete a job folder that `fair run --rehearse` prepared, which it writes
# under the data store's `jobs/`; a folder anywhere else is not known to hold
# the job alone, so stays
function _deletejob(job::AbstractString, datastore::AbstractString)
    _within(job, joinpath(datastore, "jobs")) && rm(job, recursive = true)
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
