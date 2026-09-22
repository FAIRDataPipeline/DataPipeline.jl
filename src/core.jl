# SPDX-License-Identifier: LGPL-3.0-or-later

"""
    RegistryEndpoint(url, api_version)

The local data registry that a code run talks to: the base `url` of its REST
API (with a trailing slash, e.g. `"http://127.0.0.1:8000/api/"`) and the
`api_version` sent in the `Accept` header of every request. Built by
[`initialise`](@ref) from `run_metadata.local_data_registry_url` and
`run_metadata.api_version` in the working config.
"""
struct RegistryEndpoint
    url::String
    api_version::String

    function RegistryEndpoint(url::AbstractString,
                              api_version::AbstractString = DEFAULT_API_VERSION)
        return new(endswith(url, "/") ? String(url) : string(url, "/"),
                   String(api_version))
    end
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

Target for [`raise_issue`](@ref): this code run's working config file.
"""
struct WorkingConfig <: AbstractIssueTarget end

"""
    SubmissionScript()

Target for [`raise_issue`](@ref): this code run's submission script.
"""
struct SubmissionScript <: AbstractIssueTarget end

"""
    CodeRepository()

Target for [`raise_issue`](@ref): the code repository this run was made from.
"""
struct CodeRepository <: AbstractIssueTarget end

"""
    ConfigDataProduct(data_product; component = nothing)

Target for [`raise_issue`](@ref): a data product of this code run, named as it
is in the working config's `read:` or `write:` section (the name passed to
[`link_read!`](@ref), [`link_write!`](@ref) and the `read_*`/`write_*`
functions), and optionally one named `component` of it. Resolved at
[`finalise`](@ref), so it may name an output that is not yet written. A bare
`String` given to `raise_issue` means this target.
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
    ExistingDataProduct(namespace, data_product, version; component = nothing)

Target for [`raise_issue`](@ref): a data product already in the registry,
whether or not this code run uses it, identified by its `namespace`, registry
name and `version`, and optionally one named `component` of it.
"""
struct ExistingDataProduct <: AbstractIssueTarget
    namespace::String
    data_product::String
    version::String
    component::Union{Nothing, String}

    function ExistingDataProduct(namespace::AbstractString,
                                 data_product::AbstractString,
                                 version::AbstractString;
                                 component::Union{Nothing, AbstractString} = nothing)
        return new(String(namespace), String(data_product), String(version),
                   isnothing(component) ? nothing : String(component))
    end
end

# An issue queued by `raise_issue`, registered by `finalise` once its targets exist
struct PendingIssue
    targets::Vector{AbstractIssueTarget}
    description::String
    severity::Int
end

"""
    DataRegistryHandle

The state of one code run, created by [`initialise`](@ref) and completed by
[`finalise`](@ref). Every other function in the API takes one.

# Fields
- `config`: the working config, as read from `config.yaml`
- `config_dir`: the directory the working config was read from, where
  `coderuns.txt` is appended to at `finalise`
- `registry`: the [`RegistryEndpoint`](@ref) every request goes to
- `config_obj`: registry URL of the object for the working config file
- `script_obj`: registry URL of the object for the submission script
- `repo_obj`: registry URL of the object for the remote code repository
- `datastore_obj_url`: registry URL of the storage root for the data store
- `code_run_obj`: registry URL of the code run
- `code_run_uuid`: the code run's uuid, as the CLI's staging refers to it
- `inputs`, `outputs`: metadata of what has been read and written so far,
  keyed by `(data_product, component)`, with `component` `nothing` for a whole
  file
- `issues`: issues raised so far, registered at `finalise`
"""
struct DataRegistryHandle
    config::Dict
    config_dir::String
    registry::RegistryEndpoint
    config_obj::String
    script_obj::String
    repo_obj::String
    datastore_obj_url::String
    code_run_obj::String
    code_run_uuid::String
    inputs::Dict
    outputs::Dict
    issues::Vector{PendingIssue}
end

function Base.show(io::IO, handle::DataRegistryHandle)
    return print(io, "DataRegistryHandle(", handle.code_run_uuid, ", ",
                 length(handle.inputs), " inputs, ",
                 length(handle.outputs), " outputs, ",
                 length(handle.issues), " issues)")
end

function Base.show(io::IO, ::MIME"text/plain", handle::DataRegistryHandle)
    println(io, "DataRegistryHandle for code run ", handle.code_run_uuid)
    println(io, "  registry: ", handle.registry.url)
    println(io, "  code run: ", handle.code_run_obj)
    for (label, table) in (("inputs", handle.inputs),
        ("outputs", handle.outputs))
        println(io, "  ", label, ": ", length(table))
        for (dp, component) in sort(collect(keys(table)),
                                    by = key -> string(key))
            println(io, "    ", dp,
                    isnothing(component) ? "" : " / " * component)
        end
    end
    return print(io, "  issues: ", length(handle.issues))
end

# == Functions ==

# The headers every registry request carries
function _headers(registry::RegistryEndpoint)
    return Dict("Authorization" => _gettoken(),
                "Content-Type" => "application/json",
                "Accept" => "application/json; version=$(registry.api_version)")
end

"""
    _postentry(registry, table, data)

Get or create an entry in `table` of the registry: look it up by every field
of `data` and post it only if nothing matches. Return the entry.
"""
function _postentry(registry::RegistryEndpoint, table::String, query::Dict)
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
    else
        results = r["results"]
        @assert length(results) == 1
        return results[1]
    end
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
    _getfilehash(filepath)

Return the SHA-1 hash of a file's bytes, as the registry stores it.
"""
function _getfilehash(filepath::String)
    return open(filepath) do file
        return bytes2hex(SHA.sha1(file))
    end
end

"""
    _gettoken()

Return the registry access token as an `Authorization` header value.
"""
function _gettoken()
    return string("token ", FDP_LOCAL_TOKEN())
end
