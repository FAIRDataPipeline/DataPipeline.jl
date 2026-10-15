# SPDX-License-Identifier: LGPL-3.0-or-later

"""
    RegistryEndpoint(url, api_version = "$DEFAULT_API_VERSION"; token = nothing)

A data registry to talk to: the base `url` of its REST API (with a trailing
slash, e.g. `"http://127.0.0.1:8000/api/"`), the `api_version` sent in the
`Accept` header of every request, and the access `token` sent with them, if
there is one. Reading needs no token; registering anything does.
[`initialise`](@ref) builds one from `run_metadata.local_data_registry_url` and
`run_metadata.api_version` in the working config, with the token that
`fair run` puts in `FDP_LOCAL_TOKEN`.

The token is never shown when the endpoint is printed.
"""
struct RegistryEndpoint
    url::String
    api_version::String
    token::Union{Nothing, String}

    function RegistryEndpoint(url::AbstractString,
                              api_version::AbstractString = DEFAULT_API_VERSION;
                              token::Union{Nothing, AbstractString} = nothing)
        return new(endswith(url, "/") ? String(url) : string(url, "/"),
                   String(api_version),
                   isnothing(token) ? nothing : String(token))
    end
end

"""
    RegistryEndpoint(; remote = nothing, token = nothing)

The registry the FAIR CLI is configured to use, found as `fair` finds it: the
local registry, `registries.local.uri` in `~/.fair/cli/cli-config.yaml` (or
`$DEFAULT_REGISTRY_URL` when there is no such file); or, when `remote` names
one, that remote registry, `registries.<remote>.uri` in the
`.fair/cli-config.yaml` of the project found by walking up from the current
directory. The API version is the default. The `token` is as for
[`RegistryEndpoint`](@ref); given none, it is read from the file that the same
entry names as `token` - the local registry's, written as it starts, or the
file a remote was added with - when there is one and it exists, so that a
registry is written to with the token the CLI holds for it and no other.
"""
function RegistryEndpoint(; remote::Union{Nothing, AbstractString} = nothing,
                          token::Union{Nothing, AbstractString} = nothing)
    entry = _cliregistry(remote)
    return RegistryEndpoint(entry.uri,
                            token = isnothing(token) ? entry.token : token)
end

function Base.show(io::IO, registry::RegistryEndpoint)
    return print(io, "RegistryEndpoint(", registry.url, ", version ",
                 registry.api_version,
                 isnothing(registry.token) ? ", no token)" : ", with token)")
end

function Base.show(io::IO, ::MIME"text/plain", registry::RegistryEndpoint)
    println(io, "RegistryEndpoint")
    println(io, "  url: ", registry.url)
    println(io, "  api_version: ", registry.api_version)
    return print(io, "  token: ",
                 isnothing(registry.token) ? "none" : "set (not shown)")
end

"""
    AbstractIssueTarget

The thing a registry issue is raised against. Concrete targets are
[`WorkingConfig`](@ref), [`SubmissionScript`](@ref), [`CodeRepository`](@ref),
[`ConfigDataProduct`](@ref) and [`ExistingDataProduct`](@ref). Each resolves,
at [`finalise`](@ref), to the object components the issue is attached to.
"""
abstract type AbstractIssueTarget end

"""
    WorkingConfig()

Target for [`raise_issue!`](@ref): this code run's working config file.
"""
struct WorkingConfig <: AbstractIssueTarget end

"""
    SubmissionScript()

Target for [`raise_issue!`](@ref): this code run's submission script.
"""
struct SubmissionScript <: AbstractIssueTarget end

"""
    CodeRepository()

Target for [`raise_issue!`](@ref): the code repository this run was made from.
"""
struct CodeRepository <: AbstractIssueTarget end

"""
    ConfigDataProduct(data_product; component = nothing)

Target for [`raise_issue!`](@ref): a data product of this code run, named as it
is in the working config's `read:` or `write:` section (the name passed to
[`link_read!`](@ref), [`link_write!`](@ref) and the `read_*`/`write_*`
functions), and optionally one named `component` of it. Resolved at
[`finalise`](@ref), so it may name an output that is not yet written. A bare
`String` given to `raise_issue!` means this target.
"""
struct ConfigDataProduct <: AbstractIssueTarget
    data_product::String
    component::Union{Nothing, String}

    function ConfigDataProduct(data_product::AbstractString;
                               component::Union{Nothing, AbstractString} = nothing)
        return new(String(data_product),
                   isnothing(component) ? nothing : String(component))
    end
end

"""
    ExistingDataProduct(data_product; component = nothing)

Target for [`raise_issue!`](@ref): a data product already in the registry,
whether or not this code run uses it, named as the pipeline names one -
`namespace:name@version`, or `namespace:name` for its newest version - and
optionally one named `component` of it. A `String` of that form given to
`raise_issue!` means this target.
"""
struct ExistingDataProduct <: AbstractIssueTarget
    namespace::String
    data_product::String
    version::Union{Nothing, String}
    component::Union{Nothing, String}

    function ExistingDataProduct(data_product::AbstractString;
                                 component::Union{Nothing, AbstractString} = nothing)
        named = _parsedataproduct(data_product)
        return new(named.namespace, named.name, named.version,
                   isnothing(component) ? nothing : String(component))
    end
end

# An issue queued by `raise_issue`, registered by `finalise` once its targets exist
struct PendingIssue
    targets::Vector{AbstractIssueTarget}
    description::String
    severity::Int
    all_versions::Bool
end

"""
    SourceCitation

What a citation says of the source it describes, as far as it goes: what the
registry's record of a file's source is drawn from.

# Fields
- `key`: the key of the BibTeX entry it was read from
- `identifier`: the source's DOI as a URL, in lower case, else its URL, else
  `nothing`
- `title`: its title, or `nothing`
- `authors`: its authors in order, a person as given names then family name,
  an organisation as it is written
- `release_date`: when it was released, a missing month or day being the
  first, or `nothing`
- `release_version`: its version as the citation writes it, or `nothing`
- `description`: the citation's note or abstract, or `nothing`
- `licence`: its licence, an identifier in the SPDX licence list or a URL, or
  `nothing`
- `identifiers`: the ORCIDs and ROR ids the citation gives its authors, by
  name
"""
struct SourceCitation
    key::String
    identifier::Union{Nothing, String}
    title::Union{Nothing, String}
    authors::Vector{String}
    release_date::Union{Nothing, DateTime}
    release_version::Union{Nothing, String}
    description::Union{Nothing, String}
    licence::Union{Nothing, String}
    identifiers::Dict{String, String}
end

"""
    SourceRecord

What the registry is to record of the source that a registered file comes
from, as a link call's citation and keywords give it.

# Fields
- `identifier`, `title`, `version`: what makes it one source in the registry -
  its DOI as a URL, or other URL; the file's own title; and the source's
  release version, in full
- `release_date`: when the source was released
- `description`: more about it, or `nothing`
- `primary`: whether the file is the identified item or one of its files, as
  against something requested or derived from it
- `authors`: registry URLs of its authors, who are the registered file's
- `original_store`: where the file was fetched from, as the storage root and
  the path under it that the registry records, or `nothing` where that is
  nowhere other people can reach
- `licence`: the licence's name - its identifier in the SPDX licence list,
  or its URL where it has none - and the URL that identifies it, or `nothing`
  with no licence
"""
struct SourceRecord
    identifier::String
    title::String
    version::String
    release_date::DateTime
    description::Union{Nothing, String}
    primary::Bool
    authors::Vector{String}
    original_store::Union{Nothing, @NamedTuple{root::String, path::String}}
    licence::Union{Nothing, @NamedTuple{info::String, identifier::String}}
end

"""
    AbstractRunMode

The way a code run is being made, which decides what the API registers. A
[`DataRegistryHandle`](@ref) carries its run's mode as its type parameter.
A [`RecordedRun`](@ref) registers everything; a [`Rehearsal`](@ref) nothing.
"""
abstract type AbstractRunMode end

"""
    RecordedRun()

The mode of a code run made under `fair run`: its working config, script,
repository and code run are registered at [`initialise`](@ref), and its
outputs, issues, inputs and outputs at [`finalise`](@ref).
"""
struct RecordedRun <: AbstractRunMode end

"""
    Rehearsal(outputs)

The mode of a run that registers nothing, prepared by [`rehearse`](@ref): the
script runs as `fair run` would run it, reading what the registry holds and
writing to the data store, and [`finalise`](@ref) collects what it wrote in
the folder `outputs`, as `<namespace>/<data product>/<version>.<extension>`,
beside the working config it ran under. The handle holds no registry token.
"""
struct Rehearsal <: AbstractRunMode
    outputs::String
end

"""
    DataRegistryHandle{M <: AbstractRunMode}

The state of one code run, created by [`initialise`](@ref) and completed by
[`finalise`](@ref). Every other function in the API takes one. `M` is the
run's [`AbstractRunMode`](@ref), which decides what the run registers.

# Fields
- `mode`: the run's mode, an `M`
- `config`: the working config, as read from `config.yaml`
- `config_dir`: the directory the working config was read from, where
  `coderuns.txt` is appended to at `finalise`
- `registry`: the [`RegistryEndpoint`](@ref) every request goes to
- `config_obj`: registry URL of the object for the working config file, or
  `nothing` in a run that registers none
- `script_obj`: registry URL of the object for the submission script, or
  `nothing`
- `repo_obj`: registry URL of the object for the remote code repository, or
  `nothing`
- `datastore_obj_url`: registry URL of the storage root for the data store,
  or `nothing`
- `code_run_obj`: registry URL of the code run, or `nothing`
- `code_run_uuid`: the code run's uuid, as the CLI's staging refers to it
- `inputs`, `outputs`: metadata of what has been read and written so far,
  keyed by `(data_product, component)`, with `component` `nothing` for a whole
  file
- `unchanged`: what was written and found to be registered already, so that
  no version was made of it and it is no output of the code run; keyed as
  `outputs` is
- `issues`: issues raised so far, registered at `finalise`
- `citations`: the citations read by [`register_citations!`](@ref), by key
- `doi_lookups`: the citations looked up from a DOI so far, by the DOI's URL
- `authors`: the identifiers that [`register_authors!`](@ref) has been given
  for each author's name
"""
struct DataRegistryHandle{M <: AbstractRunMode}
    mode::M
    config::Dict
    config_dir::String
    registry::RegistryEndpoint
    config_obj::Union{Nothing, String}
    script_obj::Union{Nothing, String}
    repo_obj::Union{Nothing, String}
    datastore_obj_url::Union{Nothing, String}
    code_run_obj::Union{Nothing, String}
    code_run_uuid::String
    inputs::Dict
    outputs::Dict
    unchanged::Dict
    issues::Vector{PendingIssue}
    citations::Dict{String, SourceCitation}
    doi_lookups::Dict{String, SourceCitation}
    authors::Dict{String, Vector{String}}
end

function Base.show(io::IO, handle::DataRegistryHandle)
    return print(io, "DataRegistryHandle(", _runlabel(handle), ", ",
                 length(handle.inputs), " inputs, ",
                 length(handle.outputs), " outputs, ",
                 length(handle.issues), " issues)")
end

function Base.show(io::IO, ::MIME"text/plain", handle::DataRegistryHandle)
    _showrun(io, handle)
    for (label, table) in (("inputs", handle.inputs),
        ("outputs", handle.outputs), ("unchanged", handle.unchanged))
        println(io, "  ", label, ": ", length(table))
        for (dp, component) in sort(collect(keys(table)),
                                    by = key -> string(key))
            println(io, "    ", dp,
                    isnothing(component) ? "" : " / " * component)
        end
    end
    println(io, "  issues: ", length(handle.issues))
    println(io, "  citations: ", length(handle.citations))
    return print(io, "  authors: ", length(handle.authors))
end

# What the compact display names a run by
_runlabel(handle::DataRegistryHandle{RecordedRun}) = handle.code_run_uuid
_runlabel(::DataRegistryHandle{Rehearsal}) = "rehearsal"

# The first lines of the full display: what run this is, and where it goes
function _showrun(io::IO, handle::DataRegistryHandle{RecordedRun})
    println(io, "DataRegistryHandle for code run ", handle.code_run_uuid)
    println(io, "  registry: ", handle.registry.url)
    return println(io, "  code run: ", handle.code_run_obj)
end
function _showrun(io::IO, handle::DataRegistryHandle{Rehearsal})
    println(io, "DataRegistryHandle for a rehearsal, registering nothing")
    println(io, "  registry: ", handle.registry.url)
    return println(io, "  outputs: ", handle.mode.outputs)
end

"""
    SessionRun(mode, job, handle, ended)

The run this session is in, kept in `SESSION`: a recorded run opened by the
script's `initialise()`, or a rehearsal from [`rehearse`](@ref) on. `mode` is
its [`AbstractRunMode`](@ref); `job` the folder its files are in - the job
folder a rehearsal was prepared in, known before its handle is; `handle` the
[`DataRegistryHandle`](@ref) once `initialise` has opened one; `ended`
whether `finalise` or `discard` has ended it. A session has one run, opened
once: `initialise` refuses while it is open and after it has ended.
"""
struct SessionRun
    mode::AbstractRunMode
    job::Union{Nothing, String}
    handle::Union{Nothing, DataRegistryHandle}
    ended::Bool
end
const SESSION = Ref{Union{Nothing, SessionRun}}(nothing)

# == Functions ==

# The headers every registry request carries, with the endpoint's own token
# when it has one
function _headers(registry::RegistryEndpoint)
    headers = Dict("Content-Type" => "application/json",
                   "Accept" => "application/json; version=$(registry.api_version)")
    isnothing(registry.token) ||
        (headers["Authorization"] = "token $(registry.token)")
    return headers
end

# Throw unless `registry` has a token, which every write needs, before any
# request is made
function _requiretoken(registry::RegistryEndpoint)
    isnothing(registry.token) || return nothing
    return throw(ReadWriteException(string("no token for the registry at ",
                                           registry.url,
                                           " - registering anything needs one: ",
                                           "run inside `fair run`, which sets ",
                                           "FDP_LOCAL_TOKEN, or pass `token`")))
end

# The local registry in the CLI's global configuration - its URL and the token
# its file holds - or the CLI's default and no token when there is none
function _cliregistry(::Nothing)
    path = joinpath(homedir(), ".fair", "cli", "cli-config.yaml")
    isfile(path) || return (uri = DEFAULT_REGISTRY_URL, token = nothing)
    return _registryentry(path, "local")
end

# The registry called `remote` in the configuration of the project the current
# directory belongs to
function _cliregistry(remote::AbstractString)
    project = _fairroot(pwd())
    isnothing(project) &&
        throw(ConfigFileException("no `.fair` folder in $(pwd()) or above it - run `fair init` in the project"))
    path = joinpath(project, ".fair", "cli-config.yaml")
    isfile(path) ||
        throw(ConfigFileException("no CLI configuration at $path - run `fair init` in the project"))
    return _registryentry(path, remote)
end

# The registry `name` in the CLI configuration file at `path`: its `uri`, and
# the token read from the file its `token` names
function _registryentry(path::AbstractString, name::AbstractString)
    config = something(YAML.load_file(path), Dict())
    registries = something(get(config, "registries", nothing), Dict())
    entry = get(registries, name, nothing)
    entry isa AbstractDict && haskey(entry, "uri") &&
        return (uri = String(entry["uri"]), token = _tokenfromfile(entry))
    return throw(ConfigFileException(string("no registry '", name, "' in the ",
                                            "CLI configuration at ", path,
                                            ", which has: ",
                                            join(sort!(string.(keys(registries))),
                                                 ", "))))
end

# The token in the file a configuration entry names as `token`, stripped as the
# CLI reads it, or `nothing` where the entry names none, or the file is missing
# or empty
function _tokenfromfile(entry::AbstractDict)
    file = get(entry, "token", nothing)
    file isa AbstractString && isfile(file) || return nothing
    token = strip(read(file, String))
    return isempty(token) ? nothing : String(token)
end

# The nearest folder at or above `dir` holding a `.fair` folder, as the CLI
# finds a project, or `nothing`. The search stops at the home directory, whose
# `.fair` is the CLI's global one rather than a project's.
function _fairroot(dir::AbstractString)
    home = homedir()
    current = abspath(dir)
    while !samefile(current, home)
        ispath(joinpath(current, ".fair")) && return current
        parent = dirname(current)
        parent == current && return nothing
        current = parent
    end
    return nothing
end

"""
    _postentry(registry, table, data)

Get or create an entry in `table` of the registry: look it up by every field
of `data` and post it only if nothing matches. Return the entry.
"""
function _postentry(registry::RegistryEndpoint, table::String, query::Dict)
    _requiretoken(registry)
    url = string(registry.url, table, "/")
    r = _getentry(registry, URIs.URI(url * _convertquery(registry, query)))

    if r["count"] == 1
        return r["results"][1]
    elseif r["count"] > 1
        throw(ReadWriteException("$(r["count"]) entries in $table match $query"))
    end

    if haskey(query, "root") && isnothing(match(r".*://.*", query["root"]))
        value = query["root"]
        query["root"] = "file://$value"
    end
    body = JSON.json(query)
    r = HTTP.request("POST", url, headers = _headers(registry), body = body)
    return JSON.parse(String(r.body))
end

"""
    _createentry(registry, table, data)

Post a new entry to `table` of the registry, without looking for an existing
one, and return it.
"""
function _createentry(registry::RegistryEndpoint, table::String, data::Dict)
    _requiretoken(registry)
    url = string(registry.url, table, "/")
    r = HTTP.request("POST", url, headers = _headers(registry),
                     body = JSON.json(data))
    return JSON.parse(String(r.body))
end

"""
    _convertquery(registry, query)

Convert a dictionary of registry fields into a URL query string. Registry URLs
become their integer ids, as the registry's filters want them.
"""
function _convertquery(registry::RegistryEndpoint, query::Dict)
    parts = String[]
    for (key, value) in query
        if !(isa(value, AbstractString) || isa(value, AbstractVector))
            tmp = string(value)
        elseif key == "root" && isnothing(match(r".*://.*", value))
            tmp = "file://$value"
        elseif all(startswith.(value, registry.url))
            tmp = _extractid(value)
            tmp = isa(tmp, Vector) ? join(tmp, ",") : tmp
        else
            tmp = URIs.escapeuri(value)
        end
        push!(parts, "$key=$tmp")
    end
    return "?" * join(parts, "&")
end

"""
    _getentry(registry, table, query)

Return the one entry of `table` matching `query`, or `nothing` if there is none.
"""
function _getentry(registry::RegistryEndpoint, table::String, query::Dict)
    url = string(registry.url, table, "/")
    r = _getentry(registry, URIs.URI(url * _convertquery(registry, query)))

    if r["count"] == 0
        return nothing
    elseif r["count"] > 1
        # Every table this is used on is unique on the fields queried, so more
        # than one match means the query is not the one the caller meant
        throw(ReadWriteException(string(r["count"], " entries in ", table,
                                        " match ", query,
                                        " - expected at most one")))
    end
    return r["results"][1]
end

"""
    _getentry(registry, url)

Return the parsed JSON at a registry `url`.
"""
function _getentry(registry::RegistryEndpoint, url::URIs.URI)
    try
        r = HTTP.request("GET", url, _headers(registry))
        return JSON.parse(String(r.body))
    catch e
        msg = "couldn't connect to the local registry at $(registry.url) - is it running?"
        if isa(e, Base.IOError) || isa(e, HTTP.ConnectError)
            throw(ReadWriteException(msg))
        end
        rethrow()
    end
end

"""
    _getentries(registry, table, query)

Return every entry of `table` matching `query`, following the registry's
pagination rather than stopping at the first page of 100.
"""
function _getentries(registry::RegistryEndpoint, table::String, query::Dict)
    url = string(registry.url, table, "/", _convertquery(registry, query))
    entries = Vector{Any}()
    while !isnothing(url)
        r = _getentry(registry, URIs.URI(url))
        append!(entries, r["results"])
        url = r["next"]
    end
    return entries
end

"""
    _geturl(registry, table, query)

Return the URL of the one entry of `table` matching `query`, or `nothing`.
"""
function _geturl(registry::RegistryEndpoint, table::String, query::Dict)
    entry = _getentry(registry, table, query)
    return isnothing(entry) ? nothing : entry["url"]
end

"""
    _getid(registry, table, query)

Return the id of the one entry of `table` matching `query`, or `nothing`.
"""
function _getid(registry::RegistryEndpoint, table::String, query::Dict)
    url = _geturl(registry, table, query)
    return isnothing(url) ? nothing : _extractid(url)
end

"""
    _extractid(url)

Return the integer id at the end of a registry URL, as a `String`; for a
vector of URLs, a vector of ids.
"""
function _extractid(url::AbstractString)
    return String(match(r".*/([0-9]+)/", url)[1])
end
_extractid(urls::AbstractVector) = map(_extractid, urls)

"""
    _checkexists(registry, table, query)

Return whether any entry of `table` matches `query`.
"""
function _checkexists(registry::RegistryEndpoint, table::String, query::Dict)
    url = string(registry.url, table, "/")
    r = _getentry(registry, URIs.URI(url * _convertquery(registry, query)))
    return r["count"] != 0
end

"""
    _wholeobjectcomponent(registry, object_url)

Return the URL of the `whole_object` component of a registry object, which the
registry creates with the object.
"""
function _wholeobjectcomponent(registry::RegistryEndpoint, object_url::String)
    return _geturl(registry, "object_component",
                   Dict("object" => _extractid(object_url),
                        "whole_object" => true))
end

"""
    _getfiletype(registry, extension)

Return the URL of a registry file type for `extension`, creating one named
after the extension if the registry holds none.

The registry is unique on (name, extension) and ships a catalogue of
descriptively named types (`Comma-Separated Values File` for `csv`), and other
APIs add their own names for the same extension, so several entries for one
extension are ordinary and any of them serves.
"""
function _getfiletype(registry::RegistryEndpoint, extension::String)
    url = string(registry.url, "file_type/")
    r = _getentry(registry,
                  URIs.URI(url * _convertquery(registry,
                                         Dict("extension" => extension))))
    r["count"] == 0 || return r["results"][1]["url"]
    return _postentry(registry, "file_type",
                      Dict("name" => extension,
                           "extension" => extension))["url"]
end

"""
    _getfilehash(filepath)

Return the SHA-1 hash of a file's bytes, as the registry stores it.
"""
function _getfilehash(filepath::String)
    return open(filepath) do file
        return bytes2hex(SHA.sha1(file))
    end
end
