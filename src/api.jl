# SPDX-License-Identifier: LGPL-3.0-or-later

"""
    initialise(config_file = \$FDP_CONFIG_DIR/config.yaml,
               submission_script = its run_metadata.script_path;
               token = \$FDP_LOCAL_TOKEN)

Read the working config that `fair run` wrote, register the config, the
submission script and the code repository with the local registry, open a new
code run, dated in UTC, and return the [`DataRegistryHandle`](@ref) the rest of
the API works on. The registry is `run_metadata.local_data_registry_url` (default
`$DEFAULT_REGISTRY_URL`) and the API version `run_metadata.api_version`
(default `$DEFAULT_API_VERSION`). `token` is the registry's access token, which
registering needs; `fair run` sets `FDP_LOCAL_TOKEN` to it.

With no arguments, the files are those in the folder `fair run` names in
`FDP_CONFIG_DIR` when it launches a script: a call with that unset, or with a
file that is not a working config, throws a [`ConfigFileException`](@ref)
saying so. So does a working config that gives the run no `description`, which
the registry requires of a code run; nothing is then registered. The
submission script is the one the working config names as
`run_metadata.script_path` - the copy `fair run` wrote in that folder,
`script.sh`, or `script.jl` for a user config with `shell: julia`, and so on -
else `script.sh` (`script.bat` on Windows) in the folder. After [`rehearse`](@ref) the same call opens a
[`Rehearsal`](@ref) instead, from the job folder it prepared: nothing is
registered, and the handle holds no token, whatever is given or set.

A session has one run, opened once, however the files are given: a second
call while the run is open, or after `finalise` or [`discard`](@ref) has
ended it, is a [`ReadWriteException`](@ref) - for a rehearsal, to `rehearse`
again; for a recorded run, since a script making several runs is not
supported.

The code repository is registered at its commit as one object, kept where the
registry holds one already. A new one has the repository's own authors, read
from the first of its metadata files that it has - `codemeta.json`,
`.zenodo.json`, `CITATION.cff`, `JuliaProject.toml`, `Project.toml` - as it is
at the commit in the clone `run_metadata.local_repo`, or in its working tree
for a run from uncommitted changes; where that file lists none, the runner.
The licence and keywords that file gives are added to the object either way.
Nothing is taken from the files after it, even what it lacks, and what they
say more or otherwise is told; that file being unreadable is an error.

A code repository with uncommitted changes, which `fair run --dirty` records as
a `<commit>-dirty` commit, gets a warning and an issue saying that the code
that ran cannot be recovered from its commit.

The clone `run_metadata.local_repo` is looked at as the run opens, and again as
[`finalise`](@ref) ends it. A commit other than the run's checked out as it
opens, another checked out as it ends, or a tracked file whose state or bytes
differ between the two - untracked and ignored files apart, and changes the
script made before the run opened allowed - gets a warning, and `finalise`
raises one issue on the run's outputs saying so.
"""
function initialise(config_file::Union{Nothing, String} = nothing,
                    submission_script::Union{Nothing, String} = nothing;
                    token::Union{Nothing, AbstractString} = FDP_LOCAL_TOKEN())
    mode = _runmode(SESSION[])
    job = nothing
    if isnothing(config_file)
        job = _launchedjob()
        config_file = joinpath(job, "config.yaml")
    end
    _inblock() || println("processing config file: ", config_file)
    config = _workingconfig(config_file)
    isnothing(submission_script) &&
        (submission_script = _submissionscript(config, job))
    run_metadata = config["run_metadata"]
    _checkrundescription(run_metadata, config_file)
    registry = RegistryEndpoint(get(run_metadata, "local_data_registry_url",
                                    DEFAULT_REGISTRY_URL),
                                get(run_metadata, "api_version",
                                    DEFAULT_API_VERSION),
                                token = _runtoken(mode, token))
    hold = _runhold(mode)
    handle = try
        _openrun(mode, config, config_file, submission_script, registry)
    catch
        _releaseregistry(hold)
        rethrow()
    end
    _opened(handle, hold)
    return handle
end

# Refuse a working config whose run has no description, which the registry
# requires of every code run
function _checkrundescription(run_metadata::AbstractDict,
                              config_file::AbstractString)
    description = get(run_metadata, "description", nothing)
    description isa AbstractString && !isempty(strip(description)) &&
        return nothing
    return throw(ConfigFileException("the working config at $config_file gives the run no description, which the registry requires of every code run: add one as `description` under `run_metadata` in the config given to `fair run`"))
end

# What holds the local registry for a run `initialise` opens: for a recorded
# run, the run that launched this process, or else a session of its own, as in
# a job `fair run --ci` prepared, closed at `finalise`. A rehearsal's hold is
# the one `rehearse` opened
_runhold(::RecordedRun) = _holdregistry()
_runhold(::Rehearsal) = nothing

# Open a recorded code run: look at the checkout, register the data store,
# the config, the script and the repository, raise the issue on a repository
# with uncommitted changes, and post the code run
function _openrun(mode::RecordedRun, config::Dict, config_file::String,
                  submission_script::String, registry::RegistryEndpoint)
    run_metadata = config["run_metadata"]
    datastore = run_metadata["write_data_store"]
    checkout = _watchcheckout(run_metadata)
    _saycheckout(mode, checkout)

    datastore_url = _postentry(registry, "storage_root",
                               Dict("root" => datastore,
                                    "local" => true))["url"]
    config_url = _registerobject(registry, config_file, datastore,
                                 "Working config file")["url"]
    script_url = _registerobject(registry, submission_script, datastore,
                                 "Submission script")["url"]

    repo_url = _registerrepository(registry, run_metadata)
    endswith(run_metadata["latest_commit"], "-dirty") &&
        _flagdirtyrepository(registry, repo_url, run_metadata["latest_commit"])

    code_run = _newcoderun(registry, run_metadata["description"], repo_url,
                           config_url, script_url)
    println("pipeline initialised.")

    return _newhandle(mode, config, config_file, registry,
                      (config = config_url, script = script_url,
                       repository = repo_url, datastore = datastore_url,
                       code_run = code_run["url"]), code_run["uuid"], checkout)
end

# Warn as a run opens that its checkout is not at the run's commit
_saycheckout(::AbstractRunMode, ::Nothing) = nothing
function _saycheckout(::RecordedRun, checkout::NamedTuple)
    isempty(checkout.found) && return nothing
    @warn "the code repository's checkout is not what the run records ($(only(checkout.found))): an issue will be raised on the run's outputs"
    return nothing
end

# Register a new code run started at `run_date`, in UTC, and return its entry:
# always a new one, since two runs of one config may start in the same second,
# and an entry found by these fields would be the other's
function _newcoderun(registry::RegistryEndpoint, description::AbstractString,
                     repo_url::AbstractString, config_url::AbstractString,
                     script_url::AbstractString;
                     run_date::DateTime = Dates.now(Dates.UTC))
    return _createentry(registry, "code_run",
                        Dict("run_date" => Dates.format(run_date,
                                          "yyyy-mm-ddTHH:MM:SSZ"),
                             "description" => description,
                             "code_repo" => repo_url,
                             "model_config" => config_url,
                             "submission_script" => script_url))
end

# A handle at the start of a run: the mode, the config and where it was read
# from, the registry, the URLs of what `initialise` registered - `config`,
# `script`, `repository`, `datastore` and `code_run`, each `nothing` where it
# registered nothing - the run's uuid and its checkout as it opened, with
# nothing read or written yet
function _newhandle(mode::AbstractRunMode, config::Dict, config_file::String,
                    registry::RegistryEndpoint, registered::NamedTuple,
                    uuid::String, checkout::Union{Nothing, NamedTuple})
    return DataRegistryHandle(mode, config, dirname(abspath(config_file)),
                              registry, registered.config, registered.script,
                              registered.repository, registered.datastore,
                              registered.code_run, uuid,
                              Dict(), Dict(), Dict(), PendingIssue[],
                              Dict{String, SourceCitation}(),
                              Dict{String, SourceCitation}(),
                              Dict{String, Vector{String}}(), checkout)
end

"""
    finalise(handle)

Complete the code run: name every output file by its hash and register it,
register the issues raised, attach the inputs and outputs to the code run,
and append the code run's uuid to `coderuns.txt` beside the working config,
where the CLI's `fair add` and `fair push` find it. Return the data store's
root, the folder under which the output files now sit, by namespace and data
product. In a [`Rehearsal`](@ref) nothing is registered and the outputs are
collected in its folder instead, which is returned.

Every output is registered as a new version: one written as a version that
is registered already is an error, raised before anything is registered. An
output whose file is that of a version registered before - its bytes, and
where a link call named its source, the same source, authors and licence - is
said to be identical to it and recorded in the handle's `identical`, its bytes
stored once; where every output is, the run is said to need no adding and
pushing. Where the run's checkout of its code repository was not what the run
records, as [`initialise`](@ref) describes, one issue saying so is raised on
the outputs.
"""
function finalise(handle::DataRegistryHandle{RecordedRun})
    moves = _checkoutmoves(handle.checkout)
    _checksources(handle)
    _checkversions(handle)
    previous = _previousversions(handle)
    # In name order, so which of two identical outputs keeps its file, and the
    # order of the code run's inputs and outputs, are the same on every machine
    for (data_product, component) in sort(collect(keys(handle.outputs)),
                                          by = string)
        _registerdataproduct(handle, data_product, component)
    end
    _supersedeoutputs!(handle, previous)
    outputs = String[handle.outputs[key]["component_url"]
                     for key in sort(collect(keys(handle.outputs)),
                                     by = string)]
    inputs = String[handle.inputs[key]["component_url"]
                    for key in sort(collect(keys(handle.inputs)), by = string)]
    _registerissues(handle)
    _flagmovedcheckout(handle, moves, outputs)
    url = _patchcoderun(handle, inputs, outputs)

    open(joinpath(handle.config_dir, "coderuns.txt"), "a") do io
        return println(io, handle.code_run_uuid)
    end
    _copyregistered(handle)
    println("finished - code run locally registered as: ", url, "\n")
    _allidentical(handle) &&
        @info "every output of this code run is identical to a version registered before it, so the run need not be added and pushed (`fair add`, `fair push`)"
    _ended(handle)
    session = SESSION[]
    !isnothing(session) && session.handle === handle && _releasehold!()
    return handle.config["run_metadata"]["write_data_store"]
end

"""
    link_read!(handle, data_product; path = nothing, force = false)
    link_read!(handle, pattern)

Return the path of the file behind a `read:` data product of the working
config, recording it as an input of the code run. A data product with no
file, such as a deposit, which a `register:` entry with `no_file: true` or
[`link_register!`](@ref) with no `path` registers, is recorded as an input in
the same way, and `nothing` is returned.

The file is the data store's own, named by its hash, so it must not be
written to; reading it copies nothing. For code that needs its input under a
name or in a place of its own, `path` asks for a file of its own there, and
is what is then returned:
- with nothing at `path`, a copy is put there, any missing directories being
  made - on macOS a clone where the file system makes one, which shares the
  data store's disk space until either file is written;
- a file already there with the same contents is left as it is, but for the
  data store's file under another name or a link to it, which is replaced by
  a copy;
- a file there with other contents is an error, and nothing is overwritten,
  unless `force` is `true`, when it is replaced by the registered file. A
  directory there is always an error.
The file at `path` may then be written to without changing the data store's.
`force` does nothing without `path`. A data product with no file takes no
`path`.

Given a pattern instead - a name with one or more `*`, each matching one
segment of a name, so that `era5/t2m/*` matches `era5/t2m/1940-1949` but not
`era5/t2m/a/b` - return the path of a temporary directory holding the file of
every `read:` data product that matches, each recorded as an input (the
directory itself is not), a data product with no file being recorded and
given none. Each is a symbolic link to the data store's file where one can be
made, so it must not be written to, else a copy, as on a Windows machine that
allows no symbolic links. Where the working config keeps the pattern's own entry, as a
CLI may, a pattern that matches nothing gives an empty directory; where it
does not, that is an error. Each is named after its data product with `/`
replaced by `_`, plus the file's extension; the directory is named by the
SHA-1 of the sorted list of those names and the files' hashes, so the same set
of files gives the same name. The directory is removed when Julia
exits. A pattern takes no `path`.

See also: [`canread`](@ref)
"""
function link_read!(handle::DataRegistryHandle, data_product::String;
                    path::Union{Nothing, AbstractString} = nothing,
                    force::Bool = false)
    return _linkread!(handle, data_product, path, force)
end

# The file in the data store, or for a pattern a directory of links to them
function _linkread!(handle::DataRegistryHandle, data_product::String,
                    ::Nothing, ::Bool)
    occursin('*', data_product) && return _link_read_directory!(handle,
                                 data_product)
    key = (data_product, nothing)
    haskey(handle.inputs, key) && return handle.inputs[key]["path"]
    path = _readdataproduct(handle, data_product, nothing)
    println("data product found: ", handle.inputs[key]["use_dp"])
    return path
end

# The file made available at `path`, where the caller wants it
function _linkread!(handle::DataRegistryHandle, data_product::String,
                    path::AbstractString, force::Bool)
    occursin('*', data_product) &&
        throw(ArgumentError("a path cannot be given with a pattern: $data_product"))
    path = String(path)
    key = (data_product, nothing)
    recorded = haskey(handle.inputs, key)
    stored = _linkread!(handle, data_product, nothing, force)
    if isnothing(stored)
        # A refused call leaves the run's inputs as they were
        recorded || delete!(handle.inputs, key)
        throw(ReadWriteException("'$data_product' is a data product with no file, so there is nothing to put at $path"))
    end
    input = handle.inputs[key]
    isfile(stored) ||
        throw(ReadWriteException("the file of '$data_product' is not in the data store: $stored"))
    if isdir(path)
        throw(ReadWriteException("cannot put '$data_product' at $path, which is a directory"))
    elseif isfile(path) && samefile(path, stored)
        # The data store's file itself, else that file under another name or
        # a link to it, replaced by a file of its own, so that nothing
        # written at `path` reaches the store
        !islink(path) && realpath(path) == realpath(stored) && return path
        rm(path)
    elseif ispath(path) || islink(path)
        isfile(path) && _getfilehash(path) == input["hash"] && return path
        if !force
            msg = string(path, " exists and is not ", input["use_dp"],
                         " (namespace ", input["use_namespace"], ", version ",
                         input["use_version"], "): remove it, or pass ",
                         "force = true to replace it")
            throw(ReadWriteException(msg))
        end
        rm(path)
    else
        mkpath(dirname(path))
    end
    _placefile(stored, path)
    return path
end

"""
    link_read_files!(handle, pattern)

Return the paths of the files behind every `read:` data product of the working
config whose name matches `pattern`, in name order, recording each as an
input of the code run. A pattern is a name with one or more `*`, each
matching one segment of a name, and one that matches nothing gives no paths
or an error, as for [`link_read!`](@ref). A data product with no file is
recorded and gives no path.
"""
function link_read_files!(handle::DataRegistryHandle, pattern::String)
    paths = String[]
    for name in _matchingreads(handle, pattern)
        path = link_read!(handle, name)
        isnothing(path) || push!(paths, path)
    end
    return paths
end

# The directory of links `link_read!` returns for a pattern, with no link for a
# data product with no file
function _link_read_directory!(handle::DataRegistryHandle, pattern::String)
    names = _matchingreads(handle, pattern)
    found = [(name, link_read!(handle, name)) for name in names]
    held = [(name, path) for (name, path) in found if !isnothing(path)]
    links = [replace(name, "/" => "_") * "." * _extension(path)
             for (name, path) in held]
    hashes = [handle.inputs[(name, nothing)]["hash"] for (name, _) in held]
    manifest = join(("$link\t$hash\n" for (link, hash) in zip(links, hashes)))
    directory = joinpath(mktempdir(), bytes2hex(SHA.sha1(manifest)))
    mkdir(directory)
    for (link, (_, path)) in zip(links, held)
        _placelink(path, joinpath(directory, link))
    end
    return directory
end

"""
    canread(handle, data_product)
    canread(handle, pattern)

Return whether the working config has a `read:` entry for `data_product`, or
for `pattern`: whether [`link_read!`](@ref) would succeed. A pattern the
config holds is readable though it matches nothing, giving an empty result. Only the working config is consulted, and nothing is
recorded, so a script can check every name it will read before it does any
work.

See also: [`canwrite`](@ref)
"""
function canread(handle::DataRegistryHandle, data_product::String)
    return _covered() do
        return occursin('*', data_product) ?
               _matchingreads(handle, data_product) :
               _getmetadata(handle, data_product, "read")
    end
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
    read_array!(handle, data_product, component)

Read `component` of an HDF5 `read:` data product of the working config as an
array, recording it as an input.
"""
function read_array!(handle::DataRegistryHandle, data_product::String,
                     component::String)
    path = _inputpath(handle, data_product, component)
    return process_h5_file(path)["/$component"]
end

"""
    read_table!(handle, data_product, component)

Read the table that is `component` of `data_product`. Not yet implemented: it
throws a [`ReadWriteException`](@ref) saying so. A table kept as a file of its
own, such as a CSV, is read from the path [`link_read!`](@ref) gives.

See also: [`write_table!`](@ref), [`read_array!`](@ref).
"""
function read_table!(handle::DataRegistryHandle, data_product::String,
                     component::String)
    return throw(ReadWriteException("tables are not yet implemented, so component $(repr(component)) of $(repr(data_product)) cannot be read as one: read a table kept as a file, such as a CSV, from the path link_read!(handle, $(repr(data_product))) gives"))
end

"""
    read_estimate!(handle, data_product, component)

Read the value of the point estimate `component` of a TOML `read:` data
product of the working config, recording it as an input.
"""
function read_estimate!(handle::DataRegistryHandle, data_product::String,
                        component::String)
    return _readtoml(handle, data_product, component)["value"]
end

"""
    read_distribution!(handle, data_product, component)

Read the distribution `component` of a TOML `read:` data product of the
working config as a `Dict` with `distribution`, `parameters` and `type`,
recording it as an input.
"""
function read_distribution!(handle::DataRegistryHandle, data_product::String,
                            component::String)
    return _readtoml(handle, data_product, component)
end

"""
    link_write!(handle, data_product; path = nothing, supersede = false,
                doi = nothing, bibtex = nothing, title = nothing,
                primary = nothing, description = nothing,
                original_store = nothing, licence = nothing, license = nothing,
                release_date = nothing, release_version = nothing)

Return a path to write a `write:` data product of the working config to, in
the data store, recording it as an output. `finalise` names the file by its
hash and registers it, replacing `\${{RUN_ID}}` in the registered name with
the code run's uuid. A file written there is never copied.

`path` names a file that exists already, to be registered as the data product
in place of one the caller writes. A copy of it is put in the data store - on
macOS a clone where the file system makes one, which shares the file's disk
space until either is written - and its path there is returned; the file at
`path` is left as it was, and may be written to afterwards without changing
the registered file. Its extension must be the entry's file type.

Each run registers its output as a new version, so the version the `write:`
entry names must not be registered already, or the call is an error. A file
whose bytes are those of a version registered before - and where the call
names a source, with the same source, authors and licence - is registered as
the new version all the same, and `finalise` says that it is identical.

A file that comes from somewhere else is registered with its source. The
source is named by its `doi`, or by `bibtex`, the key of a citation that
[`register_citations!`](@ref) has read - one or the other. A DOI with no
citation registered for it is looked up: its formal metadata, DataCite's
record of it or else its CSL record, gives what it has of the title, the
description, the licence, the release date and version, and the authors with
their ORCIDs or ROR ids. Each keyword below takes the place of what the
citation says, and the title and the release date must come from one or the
other. The authors of the registered file are the citation's, found when the
call is made - by the identifier the citation gives one, which is registered
and comes before any that [`register_authors!`](@ref) was given, else as
[`register_authors!`](@ref) describes - and not the user. Of a source:

- `primary` must be given: `true` if the file is the cited item or one of its
  files, so that the same bytes can be fetched again; `false` if it was
  requested or derived from it, as an extract is.
- `title` is the file's own, where the citation's is that of a whole deposit:
  the files of one deposit are told apart by their titles.
- `description` says more of it; for an extract, the request that made it.
- `original_store` is the URL that the file was fetched from. It is recorded
  when it is one that other people can reach, and not for a file on this
  machine.
- `licence`, which may be written `license`, is the licence's identifier in
  the SPDX licence list, https://spdx.org/licenses/, as `CC-BY-4.0`, or its
  name there; or the URL of a licence that is not in the list. A licence in
  the list is looked for in the copy that the package keeps, in any case and
  with any dash, and is recorded by its identifier, or by that of the licence
  the list has replaced it by.
- `release_date` and `release_version` are the source's own, in place of
  what the citation says or lacks: a `Date`, a `DateTime` or text in ISO form
  as far as it goes; and a version, which is written in full, `2.1` as
  `2.1.0`, and is `1.0.0` when there is none.

A source is one file: its identifier, title and release version may be held
by any number of data products, all of the same bytes, and another file under
the same three is an error, raised by this call when it has a `path` and
otherwise by `finalise` before it registers anything. Such a file needs a
`title` of its own, or the `release_version` it was taken from.

`data_product` may also be a name that a wildcard `write:` entry stands for -
one whose name holds `*`s, each matching one segment - in which case that
entry's file type, description and `use:` block are used and the name is
registered as given. A name matching the patterns of several entries is an
error, since nothing distinguishes them: the file type comes from the entry
found, not from the caller.

`supersede = true` says that this version supersedes the one before it for
everything made from that: once the new version is registered at
[`finalise`](@ref), an issue reading `Superseded by namespace:name@vX.Y.Z` is
raised on the highest version before it, at severity 0, the lowest, so that
[`identify`](@ref) of anything made from the old version reports it. Where
there is nothing to supersede - the file is identical to that version, the
name has no version before, or the version written is not above the highest -
nothing is raised, and an info message says so.

See also: [`canwrite`](@ref)
"""
function link_write!(handle::DataRegistryHandle, data_product::String;
                     path::Union{Nothing, AbstractString} = nothing,
                     supersede::Bool = false,
                     doi::Union{Nothing, AbstractString} = nothing,
                     bibtex::Union{Nothing, AbstractString} = nothing,
                     title::Union{Nothing, AbstractString} = nothing,
                     primary::Union{Nothing, Bool} = nothing,
                     description::Union{Nothing, AbstractString} = nothing,
                     original_store::Union{Nothing, AbstractString} = nothing,
                     licence::Union{Nothing, AbstractString} = nothing,
                     license::Union{Nothing, AbstractString} = nothing,
                     release_date::Union{Nothing, Date, DateTime,
                                         AbstractString} = nothing,
                     release_version::Union{Nothing, VersionNumber,
                                            AbstractString} = nothing)
    source = _source(handle; doi, bibtex, title, primary, description,
                     original_store, licence, license, release_date,
                     release_version)
    return _linkwrite!(handle, data_product, path, source, supersede)
end

# A new file in the data store, for the caller to write
function _linkwrite!(handle::DataRegistryHandle, data_product::String,
                     ::Nothing,
                     source::Union{Nothing, SourceRecord, OutputDescription},
                     supersede::Bool)
    key = (data_product, nothing)
    if haskey(handle.outputs, key)
        _checksamesource(handle, data_product, source)
        supersede && (handle.outputs[key]["supersede"] = true)
        return handle.outputs[key]["path"]
    end
    wmd = _writemetadata(handle, data_product).entry
    metadata = _resolvewrite(handle, data_product, nothing, wmd["file_type"],
                             nothing)
    isnothing(source) || (metadata["source"] = source)
    metadata["supersede"] = supersede
    handle.outputs[key] = metadata
    return metadata["path"]
end

# A file that exists already, linked or copied into the data store
function _linkwrite!(handle::DataRegistryHandle, data_product::String,
                     path::AbstractString,
                     source::Union{Nothing, SourceRecord, OutputDescription},
                     supersede::Bool)
    path = String(path)
    isfile(path) || throw(ReadWriteException("no file to register at $path"))
    wmd = _writemetadata(handle, data_product).entry
    if _extension(path) != wmd["file_type"]
        msg = string("'", data_product, "' is written as a ", wmd["file_type"],
                     " file in 'write', which ", path,
                     " is not - check config file.")
        throw(ConfigFileException(msg))
    end
    hash = _getfilehash(path)

    # A data product has one file in a code run, so a second call must bring
    # the same bytes
    started = unique(value["path"]
                     for (key, value) in handle.outputs
                     if key[1] == data_product)
    if !isempty(started)
        file = only(started)
        (isfile(file) && _getfilehash(file) == hash) ||
            throw(ReadWriteException("'$data_product' is already being written by this code run, from another file"))
        _checksamesource(handle, data_product, source)
        if supersede
            for (key, value) in handle.outputs
                key[1] == data_product && (value["supersede"] = true)
            end
        end
        return file
    end

    _checkonefile(handle, source, hash, data_product)
    metadata = _resolvewrite(handle, data_product, nothing, wmd["file_type"],
                             nothing)
    _placefile(path, metadata["path"])
    isnothing(source) || (metadata["source"] = source)
    metadata["supersede"] = supersede
    handle.outputs[(data_product, nothing)] = metadata
    return metadata["path"]
end

"""
    canwrite(handle, data_product)

Return whether the working config has a `write:` entry that covers
`data_product` - one naming it exactly, or one wildcard entry whose pattern
it matches: whether [`link_write!`](@ref) would find an entry to write it
under. A name that the patterns of several entries match is not covered. Only
the working config is consulted, and nothing is recorded, so a script can
check every name it will write before it does any work.

See also: [`canread`](@ref)
"""
function canwrite(handle::DataRegistryHandle, data_product::String)
    return _covered() do
        return _writemetadata(handle, data_product)
    end
end

"""
    link_register!(handle, data_product; path = nothing, supersede = false,
                   doi = nothing, bibtex = nothing, title = nothing,
                   primary = nothing, description = nothing,
                   original_store = nothing, licence = nothing,
                   license = nothing, release_date = nothing,
                   release_version = nothing)

Register something that comes from outside the pipeline, with its source, as
the data product `data_product`, which the working config does not name, and
record it as an input of the code run. No run made it: it is this run's
input and no run's output. The data product is named as the pipeline names
one, `namespace:name@version`, and may leave out the namespace, the version
or both: `name`, `name@1.2.3`, `namespace:name`.

With no `path` it is a data product with no file - the deposit that a
source's files belong to, which a run that fetches them reads, so that each
file it registers as an output is derived from it - and nothing is returned.
With a `path` it is that file, put in the data store as [`link_write!`](@ref)
puts one, a copy - on macOS a clone where the file system makes one - and its
path there is returned; the file at `path` may be written to afterwards
without changing the registered file.

The namespace is by default the run's default input namespace. The version
is the data product's in the pipeline - the source's own is
`release_version`. With none given, a name not yet registered is version
0.0.1; a name whose highest version is registered with the same file, or
with none, and the same source, authors and licence is that version, and
nothing new is registered; any other is the highest version's next patch. A
version given that is registered already must be registered so too, or it is
an error.

The source is named by `doi` or `bibtex`, and must be: `title`, `primary`,
`description`, `original_store`, `licence` or `license`, `release_date` and
`release_version` say of it what they say for [`link_write!`](@ref), and
`primary` must be given here too. `original_store`, where a file was fetched
from, needs a `path`. A source is one file, as there. `supersede = true` is as
there too: a new version registered by the call supersedes the highest before
it, with an issue on that version raised at [`finalise`](@ref), and an info
message where there is nothing to supersede.
"""
function link_register!(handle::DataRegistryHandle, data_product::String;
                        path::Union{Nothing, AbstractString} = nothing,
                        supersede::Bool = false,
                        doi::Union{Nothing, AbstractString} = nothing,
                        bibtex::Union{Nothing, AbstractString} = nothing,
                        title::Union{Nothing, AbstractString} = nothing,
                        primary::Union{Nothing, Bool} = nothing,
                        description::Union{Nothing, AbstractString} = nothing,
                        original_store::Union{Nothing, AbstractString} = nothing,
                        licence::Union{Nothing, AbstractString} = nothing,
                        license::Union{Nothing, AbstractString} = nothing,
                        release_date::Union{Nothing, Date, DateTime,
                                            AbstractString} = nothing,
                        release_version::Union{Nothing, VersionNumber,
                                               AbstractString} = nothing)
    occursin('*', data_product) &&
        throw(ArgumentError("'$data_product' is a pattern: a data product registered has a name of its own"))
    isnothing(path) && !isnothing(original_store) &&
        throw(ArgumentError("`original_store` is where a file was fetched from, and a data product with no `path` has no file"))
    named = _parsedataproduct(data_product,
                              default = handle.config["run_metadata"]["default_input_namespace"])
    file = _externalfile(path)
    isnothing(doi) && isnothing(bibtex) &&
        throw(ArgumentError("'$data_product' is registered as coming from elsewhere: name its source, by its `doi` or its `bibtex` key"))
    source = _source(handle; doi, bibtex, title, primary, description,
                     original_store, licence, license, release_date,
                     release_version)
    return _linkregister!(handle, named.name, named.namespace, named.version,
                          file, source, supersede)
end

"""
    isregistered(handle, data_product; doi = nothing, bibtex = nothing,
                 title = nothing, primary = nothing, description = nothing,
                 original_store = nothing, licence = nothing,
                 license = nothing, release_date = nothing,
                 release_version = nothing)

Return whether the registry holds `data_product`, registering and recording
nothing. It is named as [`link_register!`](@ref) names one,
`namespace:name@version`: the namespace by default the run's default input
namespace, and with no version the highest. Or it is a
[`ConfigDataProduct`](@ref), the label a script gives [`link_write!`](@ref)
or `link_read!`, resolved as the run resolves it: the `write:` entry naming it,
or the one pattern covering it, under the name its `use:` block gives and in
its namespace, else the run's default output namespace; else the `read:`
entry naming it, or the kept entry whose pattern covers it. Its version is the
entry's where that version is registered, else the highest. A label no entry
covers, or several patterns cover, is a [`ConfigFileException`](@ref), and a
component of one an `ArgumentError`.

With no source keyword, whether anything is registered under the name, or at
the version a name asks for. With the keywords `link_register!` or `link_write!`
would be given, but no file, whether the version asked about records the
same source - its identifier, title and release version, from the citation
that `doi` or `bibtex` names and from `title` and `release_version` - the
same authors, and the same licence, `licence` or `license`. `primary`,
`description`, `release_date` and `original_store` are not compared, the
registry keeping the last three as a first registration said them, so may be
left out, though what is given is checked as the link calls check it; nor are
the file's bytes compared. An author the registry has not got is not
registered, and makes the answer false, as registering would add one. A `doi`
with no citation is looked up at `doi.org` as the link calls look it up.

So a script can ask before it fetches anything whether there is anything to
fetch, and why: false by the name, nothing is registered; true by the name and
false with the source, it is registered with other facts.

See also: [`canread`](@ref), [`identify`](@ref)
"""
function isregistered(handle::DataRegistryHandle,
                      data_product::Union{String, ConfigDataProduct};
                      doi::Union{Nothing, AbstractString} = nothing,
                      bibtex::Union{Nothing, AbstractString} = nothing,
                      title::Union{Nothing, AbstractString} = nothing,
                      primary::Union{Nothing, Bool} = nothing,
                      description::Union{Nothing, AbstractString} = nothing,
                      original_store::Union{Nothing, AbstractString} = nothing,
                      licence::Union{Nothing, AbstractString} = nothing,
                      license::Union{Nothing, AbstractString} = nothing,
                      release_date::Union{Nothing, Date, DateTime,
                                          AbstractString} = nothing,
                      release_version::Union{Nothing, VersionNumber,
                                             AbstractString} = nothing)
    asked = _askedname(handle, data_product)
    # The source is read whether or not the name is registered, so that what
    # was said of it is checked either way
    source = _source(handle; doi, bibtex, title, primary, description,
                     original_store, licence, license, release_date,
                     release_version, authorurl = _heldauthorurl,
                     compared = true)
    registry = handle.registry
    product = isnothing(asked.version) ? nothing :
              _versioneddataproduct(registry, asked.namespace, asked.name,
                                    asked.version)
    if isnothing(product) && (isnothing(asked.version) || asked.fallback)
        product = _latestdataproduct(registry, asked.namespace, asked.name)
    end
    isnothing(product) && return false
    isnothing(source) && return true
    object = _getentry(registry, URIs.URI(product["object"]))
    return _recordssource(registry, product, object, source)
end

# The registry name `isregistered` asks about, as `(namespace, name, version,
# fallback)`: a version a name asks for must be registered, where one a config
# entry gives falls back to the highest
function _askedname(handle::DataRegistryHandle, data_product::String)
    occursin('*', data_product) &&
        throw(ArgumentError("'$data_product' is a pattern: a data product is looked up by a name of its own"))
    named = _parsedataproduct(data_product,
                              default = handle.config["run_metadata"]["default_input_namespace"])
    return (namespace = named.namespace, name = named.name,
            version = named.version, fallback = false)
end
function _askedname(handle::DataRegistryHandle, target::ConfigDataProduct)
    label = target.data_product
    isnothing(target.component) ||
        throw(ArgumentError("'$label' is asked about with its component '$(target.component)', which is not registered apart from its data product: ask about the data product"))
    occursin('*', label) &&
        throw(ArgumentError("'$label' is a pattern, which names no single data product: ask about the names it matches"))
    written = _writeentry(handle, label)
    if !isnothing(written)
        version = get(get(written.entry, "use", Dict()), "version", nothing)
        return (namespace = _writenamespace(handle, written.entry),
                name = replace(written.name,
                               RUN_ID_PLACEHOLDER => handle.code_run_uuid),
                version = isnothing(version) ? nothing : string(version),
                fallback = true)
    end
    read = _readentry(handle, label)
    isnothing(read) &&
        throw(ConfigFileException("'$label' not found in 'write' or 'read' - check config file."))
    return (namespace = read.namespace, name = read.name,
            version = read.version, fallback = true)
end

"""
    write_array!(handle, data, data_product, component, description;
                supersede = false)

Write `data` as `component` of an HDF5 `write:` data product of the working
config, recording it as an output, and return `(data_product, component)`.
The file records no times, so that the same arrays give the same bytes and
are found identical to a version registered before. `supersede` is as for
[`link_write!`](@ref): the data product's new version supersedes the one
before it.

See also: [`write_table!`](@ref), [`read_array!`](@ref), [`read_table!`](@ref)
"""
function write_array!(handle::DataRegistryHandle, data::Array,
                      data_product::String,
                      component::String, description::String;
                      supersede::Bool = false)
    key = (data_product, component)
    if haskey(handle.outputs, key)
        supersede && (handle.outputs[key]["supersede"] = true)
        return key
    end
    metadata = _resolvewrite(handle, data_product, component, "h5",
                             description)
    metadata["supersede"] = supersede
    path = metadata["path"]
    if isfile(path)
        HDF5.h5open(path, "r+") do file
            return _writeuntimed(file, metadata["use_component"], data)
        end
    else
        # The root group of a new file records no times either
        HDF5.h5open(path, "w", obj_track_times = false) do file
            return _writeuntimed(file, metadata["use_component"], data)
        end
    end
    handle.outputs[key] = metadata
    return key
end

"""
    write_table!(handle, data, data_product, component)

Write `data` as the table that is `component` of `data_product`. Not yet
implemented: it throws a [`ReadWriteException`](@ref) saying so. A table is
written as a file of its own, such as a CSV, to the path
[`link_write!`](@ref) gives.

See also: [`write_array!`](@ref), [`read_array!`](@ref), [`read_table!`](@ref)
"""
function write_table!(handle::DataRegistryHandle, data, data_product::String,
                      component::String)
    return throw(ReadWriteException("tables are not yet implemented, so component $(repr(component)) of $(repr(data_product)) cannot be written as one: write the table to a file, such as a CSV, at the path link_write!(handle, $(repr(data_product))) gives"))
end

"""
    write_estimate!(handle, value, data_product, component, description;
                   supersede = false)

Write `value` as the point estimate `component` of a TOML `write:` data
product of the working config, recording it as an output, and return
`(data_product, component)`. `supersede` is as for [`link_write!`](@ref):
the data product's new version supersedes the one before it.
"""
function write_estimate!(handle::DataRegistryHandle, value,
                         data_product::String,
                         component::String, description::String;
                         supersede::Bool = false)
    key = (data_product, component)
    if haskey(handle.outputs, key)
        supersede && (handle.outputs[key]["supersede"] = true)
        return key
    end
    data = Dict{String, Any}("value" => value, "type" => "point-estimate")
    _writekeyval(handle, data, data_product, component, description,
                 supersede)
    return key
end

"""
    write_distribution!(handle, distribution, parameters, data_product,
                       component, description; supersede = false)

Write a `distribution` (its name, and a `Dict` of `parameters`) as
`component` of a TOML `write:` data product of the working config, recording
it as an output, and return `(data_product, component)`. `supersede` is as
for [`link_write!`](@ref): the data product's new version supersedes the one
before it.
"""
function write_distribution!(handle::DataRegistryHandle, distribution::String,
                             parameters,
                             data_product::String, component::String,
                             description::String; supersede::Bool = false)
    key = (data_product, component)
    if haskey(handle.outputs, key)
        supersede && (handle.outputs[key]["supersede"] = true)
        return key
    end
    data = Dict{String, Any}("distribution" => distribution,
                             "parameters" => parameters,
                             "type" => "distribution")
    _writekeyval(handle, data, data_product, component, description,
                 supersede)
    return key
end

"""
    raise_issue!(handle, target, description; severity = $DEFAULT_ISSUE_SEVERITY,
                 all_versions = false)
    raise_issue!(handle, targets, description; severity = $DEFAULT_ISSUE_SEVERITY,
                 all_versions = false)
    raise_issue!(target, description; remote = nothing,
                 severity = $DEFAULT_ISSUE_SEVERITY, all_versions = false)
    raise_issue!(path, description; remote = nothing,
                 severity = $DEFAULT_ISSUE_SEVERITY)
    raise_issue!(registry, target, description;
                 severity = $DEFAULT_ISSUE_SEVERITY, all_versions = false)

Raise an issue with one thing, or with several at once as one registry issue.
A target is an [`AbstractIssueTarget`](@ref) - [`WorkingConfig`](@ref),
[`SubmissionScript`](@ref), [`CodeRepository`](@ref),
[`ConfigDataProduct`](@ref) or [`ExistingDataProduct`](@ref) - or a `String`:
the path of a file that exists, as [`identify`](@ref) takes one; a data
product of this run by its config name, as [`ConfigDataProduct`](@ref) names
one; or a registered data product as `namespace:name@version` (`namespace:name`
for its newest version), as [`ExistingDataProduct`](@ref) names one; or an
[`AbstractCommitSelection`](@ref), which stands for the
[`CodeRepository`](@ref) of the commits it selects.

An issue on a file is on every object the registry holds its bytes at - every
version of every data product with them - as they are when the issue is
registered, the file's bytes being taken when it is raised. The registry must
hold the file already, and a path that is also the name of a data product in
the working config is an `ArgumentError`, being both.
`severity` is an integer, larger for worse, by default the registry's own
default. Issues are queued in the handle
and registered by [`finalise`](@ref), so an output can be named before it
is written.

A data product's bytes may be registered as other versions of the same data
product too, which the issue would then not reach. `finalise` looks for them,
and warns of any; with `all_versions = true` it raises the issue on every
such version as well, as one issue over their components. There is no
prompt, since a script may run where no one can answer. An issue on a file is
on every such version already, so takes no `all_versions = true`.

Outside a run - given a registry, or none for the CLI's local registry or its
remote registry named `remote` - the issue is registered at once, and its URL
returned, which [`downstream`](@ref) takes as `issue`. Only a target that names
what it is on without a run can be raised so: a file, an
[`ExistingDataProduct`](@ref), or a string of its form, and commits - an
[`AbstractCommitSelection`](@ref), or a `CodeRepository` given one; any other
is an `ArgumentError`. So `raise_issue!("results/table.csv", "Wrong units")`
raises an issue on every version registered with that file's bytes. So
`raise_issue!(AncestorCommits(of = "v1.2", including = false), "Fixed in v1.2")`
raises an issue on the code that came before `v1.2`. Registering needs the registry's token, which
[`RegistryEndpoint`](@ref) reads from the CLI's configuration. While the
session is rehearsing a run, the issue is printed as what would be raised,
nothing is registered, and `nothing` is returned.

# Arguments
- `handle::DataRegistryHandle`: the code run the issue is raised in.
- `registry::RegistryEndpoint`: the registry to raise it in, outside a run.
- `target`, `targets`, `path`: what the issue is on, as above.
- `description::String`: the issue.
- `severity::Integer`: larger for worse.
- `all_versions::Bool`: whether to raise it on the other versions of a data
  product holding the same bytes too; not with a file, whose issue is on them
  already.
- `remote`: with no registry given, the remote registry of that name in the
  current project's CLI configuration, else the CLI's local registry.
"""
function raise_issue!(handle::DataRegistryHandle, targets::AbstractVector,
                      description::String;
                      severity::Integer = DEFAULT_ISSUE_SEVERITY,
                      all_versions::Bool = false)
    resolved = AbstractIssueTarget[_astarget(target) for target in targets]
    _checkallversions(resolved, all_versions)
    for target in resolved
        _checktarget(handle, target)
    end
    push!(handle.issues,
          PendingIssue(resolved, description, severity, all_versions))
    return nothing
end
function raise_issue!(handle::DataRegistryHandle,
                      target::_IssueTargetArgument, description::String;
                      severity::Integer = DEFAULT_ISSUE_SEVERITY,
                      all_versions::Bool = false)
    return raise_issue!(handle, [target], description; severity, all_versions)
end
function raise_issue!(registry::RegistryEndpoint, targets::AbstractVector,
                      description::String;
                      severity::Integer = DEFAULT_ISSUE_SEVERITY,
                      all_versions::Bool = false)
    resolved = AbstractIssueTarget[_astarget(target) for target in targets]
    _checkallversions(resolved, all_versions)
    for target in resolved
        _checkoutsiderun(target)
    end
    components = reduce(vcat,
                        (_issuecomponents(registry, target)
                         for target in resolved),
                        init = String[])
    issue = PendingIssue(resolved, description, severity, all_versions)
    return _raiseoutsiderun(_sessionmode(), registry, issue, components)
end
function raise_issue!(registry::RegistryEndpoint, target::_IssueTargetArgument,
                      description::String;
                      severity::Integer = DEFAULT_ISSUE_SEVERITY,
                      all_versions::Bool = false)
    return raise_issue!(registry, [target], description; severity,
                        all_versions)
end
function raise_issue!(targets::AbstractVector, description::String;
                      remote::Union{Nothing, AbstractString} = nothing,
                      severity::Integer = DEFAULT_ISSUE_SEVERITY,
                      all_versions::Bool = false)
    return registry_session(remote = remote) do registry
        return raise_issue!(registry, targets, description; severity,
                            all_versions)
    end
end
function raise_issue!(target::_IssueTargetArgument, description::String;
                      remote::Union{Nothing, AbstractString} = nothing,
                      severity::Integer = DEFAULT_ISSUE_SEVERITY,
                      all_versions::Bool = false)
    return registry_session(remote = remote) do registry
        return raise_issue!(registry, [target], description; severity,
                            all_versions)
    end
end

# A bare string names a file where one exists, told first since a Windows path
# holds a colon; else a data product: of this run by its config name, or a
# registered one as `namespace:name@version`, which no config name looks like.
# A commit selection names the commits of a code repository
_astarget(target::AbstractIssueTarget) = target
_astarget(commits::AbstractCommitSelection) = CodeRepository(commits)
function _astarget(named::AbstractString)
    isfile(named) && return _FileTarget(named)
    return occursin(':', named) ? ExistingDataProduct(named) :
           ConfigDataProduct(named)
end

# Refuse `all_versions = true` for an issue on a file, which is on every
# version holding its bytes already
function _checkallversions(targets::AbstractVector{AbstractIssueTarget},
                           all_versions::Bool)
    all_versions && any(target -> target isa _FileTarget, targets) &&
        throw(ArgumentError("an issue on a file is on every version holding its bytes already, so takes no `all_versions = true`"))
    return nothing
end

# A data product named by its config name must be in the working config, and
# be one: a pattern names none
function _checktarget(handle::DataRegistryHandle, target::ConfigDataProduct)
    occursin('*', target.data_product) &&
        throw(ArgumentError("'$(target.data_product)' is a pattern, which names no single data product: raise the issue on the names it matches"))
    for section in ("read", "write")
        any(entry["data_product"] == target.data_product
            for entry in get(handle.config, section, [])) && return nothing
    end
    return throw(ConfigFileException("'$(target.data_product)' not found in config file"))
end
# A file must be one the registry holds, and its path no data product's name in
# the working config, which the path would then stand for as well
function _checktarget(handle::DataRegistryHandle, target::_FileTarget)
    for section in ("read", "write")
        any(entry["data_product"] == target.given
            for entry in get(handle.config, section, [])) &&
            throw(ArgumentError("'$(target.given)' is both a file and the name of a data product in the working config: name the data product as ConfigDataProduct(\"$(target.given)\"), or the file by another path to it"))
    end
    _issuecomponents(handle.registry, target)
    return nothing
end
_checktarget(::DataRegistryHandle, ::AbstractIssueTarget) = nothing

# Throw unless a target names what it is on without a run, as an issue raised
# outside one needs
_checkoutsiderun(::ExistingDataProduct) = nothing
_checkoutsiderun(::_FileTarget) = nothing
function _checkoutsiderun(target::CodeRepository)
    isnothing(target.commits) &&
        throw(ArgumentError("CodeRepository() is the commit of a code run: outside a run, select commits, such as AncestorCommits()"))
    return nothing
end
function _checkoutsiderun(target::AbstractIssueTarget)
    return throw(ArgumentError("$target is part of a code run: raise it with the run's handle, as raise_issue!(handle, target, description)"))
end
