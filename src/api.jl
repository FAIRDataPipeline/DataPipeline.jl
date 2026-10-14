# SPDX-License-Identifier: LGPL-3.0-or-later

"""
    initialise(config_file = \$FDP_CONFIG_DIR/config.yaml,
               submission_script = \$FDP_CONFIG_DIR/script.sh;
               token = \$FDP_LOCAL_TOKEN)

Read the working config that `fair run` wrote, register the config, the
submission script and the code repository with the local registry, open a new
code run, and return the [`DataRegistryHandle`](@ref) the rest of the API
works on. The registry is `run_metadata.local_data_registry_url` (default
`$DEFAULT_REGISTRY_URL`) and the API version `run_metadata.api_version`
(default `$DEFAULT_API_VERSION`). `token` is the registry's access token, which
registering needs; `fair run` sets `FDP_LOCAL_TOKEN` to it.

A code repository with uncommitted changes, which `fair run --dirty` records as
a `<commit>-dirty` commit, gets a warning and an issue saying that the code
that ran cannot be recovered from its commit.
"""
function initialise(config_file::String = FDP_PATH_CONFIG(),
                    submission_script::String = FDP_PATH_SUBMISSION();
                    token::Union{Nothing, AbstractString} = FDP_LOCAL_TOKEN())
    print("processing config file: ", config_file)
    config = YAML.load_file(config_file)
    run_metadata = config["run_metadata"]
    registry = RegistryEndpoint(get(run_metadata, "local_data_registry_url",
                                    DEFAULT_REGISTRY_URL),
                                get(run_metadata, "api_version",
                                    DEFAULT_API_VERSION),
                                token = token)
    datastore = run_metadata["write_data_store"]

    datastore_url = _postentry(registry, "storage_root",
                               Dict("root" => datastore,
                                    "local" => true))["url"]
    config_url = _registerobject(registry, config_file, datastore,
                                 "Working config file")["url"]
    script_url = _registerobject(registry, submission_script, datastore,
                                 "Submission script")["url"]

    repo = _repositorylocation(run_metadata["remote_repo"])
    repo_url = _registerobject(registry, repo.path, repo.root,
                               "Remote code repository.",
                               hash = run_metadata["latest_commit"],
                               local_root = false, file_type = nothing)["url"]
    endswith(run_metadata["latest_commit"], "-dirty") &&
        _flagdirtyrepository(registry, repo_url, run_metadata["latest_commit"])

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
                              Dict(), Dict(), Dict(), PendingIssue[],
                              Dict{String, SourceCitation}(),
                              Dict{String, SourceCitation}(),
                              Dict{String, Vector{String}}())
end

"""
    finalise(handle)

Complete the code run: name every output file by its hash and register it,
register the issues raised, attach the inputs and outputs to the code run,
and append the code run's uuid to `coderuns.txt` beside the working config,
where the CLI's `fair add` and `fair push` find it.

A file whose bytes are those of the highest version of its data product
already registered is not registered again: no version is made, the file
written is removed, and it is not an output of the code run. Where a link
call named its source, the source, authors and licence registered with that
version must be the same as well.
"""
function finalise(handle::DataRegistryHandle)
    _checksources(handle)
    # In name order, so which of two identical outputs keeps its file, and the
    # order of the code run's inputs and outputs, are the same on every machine
    for (data_product, component) in sort(collect(keys(handle.outputs)),
                                          by = string)
        _registerdataproduct(handle, data_product, component)
    end
    # What was registered already is no output of this code run
    for (key, metadata) in collect(handle.outputs)
        metadata["unchanged"] || continue
        handle.unchanged[key] = pop!(handle.outputs, key)
    end
    outputs = String[handle.outputs[key]["component_url"]
                     for key in sort(collect(keys(handle.outputs)),
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
    link_read!(handle, data_product; path = nothing, force = false)
    link_read!(handle, pattern)

Return the path of the file behind a `read:` data product of the working
config, recording it as an input of the code run.

The file is in the data store, named by its hash. For code that needs its
input under a name or in a place of its own, `path` asks for the file there,
and is what is then returned:
- with nothing at `path`, the file is put there, any missing directories
  being made: as a hard link to the data store's file where one can be made,
  so that no bytes are copied, else as a copy;
- a file already there with the same contents is left exactly as it is,
  whether it is the data store's file under a second name or a copy of it;
- a file there with other contents is an error, and nothing is overwritten,
  unless `force` is `true`, when it is replaced by the registered file. A
  directory there is always an error.
A file that is a hard link is the data store's own, so it must not be written
to. `force` does nothing without `path`.

Given a pattern instead - a name with one or more `*`, each matching one
segment of a name, so that `era5/t2m/*` matches `era5/t2m/1940-1949` but not
`era5/t2m/a/b` - return the path of a temporary directory holding a symbolic
link to the file of every `read:` data product that matches, each recorded as
an input (the directory itself is not). A link is named after its data
product with `/` replaced by `_`, plus the file's extension; the directory is
named by the SHA-1 of the sorted list of link names and file hashes, so the
same set of files gives the same name. The directory is removed when Julia
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
    stored = _linkread!(handle, data_product, nothing, force)
    input = handle.inputs[(data_product, nothing)]
    isfile(stored) ||
        throw(ReadWriteException("the file of '$data_product' is not in the data store: $stored"))
    if isdir(path)
        throw(ReadWriteException("cannot put '$data_product' at $path, which is a directory"))
    elseif ispath(path) || islink(path)
        isfile(path) &&
            (samefile(path, stored) || _getfilehash(path) == input["hash"]) &&
            return path
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

"""
    canread(handle, data_product)
    canread(handle, pattern)

Return whether the working config has a `read:` entry for `data_product`, or
one that matches `pattern`: whether [`link_read!`](@ref) would find something
to read under that name. Only the working config is consulted, and nothing is
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
    link_write!(handle, data_product; path = nothing, doi = nothing,
                bibtex = nothing, title = nothing, primary = nothing,
                description = nothing, original_store = nothing,
                licence = nothing, license = nothing, release_date = nothing,
                release_version = nothing)

Return a path to write a `write:` data product of the working config to, in
the data store, recording it as an output. `finalise` names the file by its
hash and registers it, replacing `\${{RUN_ID}}` in the registered name with
the code run's uuid.

`path` names a file that exists already, to be registered as the data product
in place of one the caller writes. It is put in the data store - as a hard
link where one can be made, so that no bytes are copied, else as a copy - and
its path there is returned; the file at `path` is left as it was. Its
extension must be the entry's file type. A hard link is the same file under a
second name, so the file must not be written to afterwards.

A file whose bytes are those of the highest version of the data product
already registered is not registered again: no version is made and it is not
an output of the code run. Where the call names a source, the source, authors
and licence registered with that version must be the same as well. With a
`path` this is found as the call is made, and the path returned is that of
the registered file; a file that is written afterwards is found so by
`finalise`.

A file that comes from somewhere else is registered with its source. The
source is named by its `doi`, or by `bibtex`, the key of a citation that
[`register_citations!`](@ref) has read - one or the other. The authors of the
registered file are then the citation's, found as
[`register_authors!`](@ref) describes when the call is made, and not the
user. Of a source:

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
  the SPDX licence list, https://spdx.org/licenses/, as `CC-BY-4.0`; or the
  URL of a licence that is not in the list. An identifier is looked for in
  the copy of the list that the package keeps.
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

See also: [`canwrite`](@ref)
"""
function link_write!(handle::DataRegistryHandle, data_product::String;
                     path::Union{Nothing, AbstractString} = nothing,
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
    return _linkwrite!(handle, data_product, path, source)
end

# A new file in the data store, for the caller to write
function _linkwrite!(handle::DataRegistryHandle, data_product::String,
                     ::Nothing, source::Union{Nothing, SourceRecord})
    key = (data_product, nothing)
    if haskey(handle.outputs, key)
        _checksamesource(handle, data_product, source)
        return handle.outputs[key]["path"]
    end
    wmd = _writemetadata(handle, data_product).entry
    metadata = _resolvewrite(handle, data_product, nothing, wmd["file_type"],
                             nothing)
    isnothing(source) || (metadata["source"] = source)
    handle.outputs[key] = metadata
    return metadata["path"]
end

# A file that exists already, linked or copied into the data store
function _linkwrite!(handle::DataRegistryHandle, data_product::String,
                     path::AbstractString,
                     source::Union{Nothing, SourceRecord})
    path = String(path)
    isfile(path) || throw(ReadWriteException("no file to register at $path"))
    wmd, name = _writemetadata(handle, data_product)
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
        return file
    end

    _checkonefile(handle, source, hash, data_product)
    unchanged = _unchangedfile(handle.registry, _writenamespace(handle, wmd),
                               name, hash, source)
    if !isnothing(unchanged)
        println("data product unchanged: ", name, " (", unchanged.version, ")")
        whole = _wholeobjectcomponent(handle.registry, unchanged.object)
        found = Dict("path" => unchanged.path,
                     "object_url" => unchanged.object,
                     "component_url" => whole)
        handle.unchanged[(data_product, nothing)] = found
        return unchanged.path
    end

    metadata = _resolvewrite(handle, data_product, nothing, wmd["file_type"],
                             nothing)
    _placefile(path, metadata["path"])
    isnothing(source) || (metadata["source"] = source)
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
    raise_issue(handle, target, description; severity = $DEFAULT_ISSUE_SEVERITY)
    raise_issue(handle, targets, description; severity = $DEFAULT_ISSUE_SEVERITY)

Raise an issue with one thing, or with several at once as one registry issue.
A target is an [`AbstractIssueTarget`](@ref) - [`WorkingConfig`](@ref),
[`SubmissionScript`](@ref), [`CodeRepository`](@ref),
[`ConfigDataProduct`](@ref) or [`ExistingDataProduct`](@ref) - or a `String`,
which names a data product of this run as [`ConfigDataProduct`](@ref) does.
`severity` is an integer, larger for worse, by default the registry's own
default. Issues are queued in the handle
and registered by [`finalise`](@ref), so an output can be named before it
is written.
"""
function raise_issue(handle::DataRegistryHandle, targets::AbstractVector,
                     description::String;
                     severity::Integer = DEFAULT_ISSUE_SEVERITY)
    resolved = AbstractIssueTarget[_astarget(target) for target in targets]
    for target in resolved
        _checktarget(handle, target)
    end
    push!(handle.issues, PendingIssue(resolved, description, severity))
    return nothing
end
function raise_issue(handle::DataRegistryHandle,
                     target::Union{AbstractIssueTarget, AbstractString},
                     description::String;
                     severity::Integer = DEFAULT_ISSUE_SEVERITY)
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
