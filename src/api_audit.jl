# SPDX-License-Identifier: LGPL-3.0-or-later

# Asking the registry what it knows about a file on disk, and tracing issues
# through provenance.

"""
    IssueRecord

A problem recorded against something a file is registered as.

# Fields
- `severity`: how bad it is, as the registry holds it (larger is worse)
- `description`: what the problem is
- `component`: the name of the object component it was raised against, or
  `nothing` when raised against the file as a whole
"""
struct IssueRecord
    severity::Int
    description::String
    component::Union{Nothing, String}
end

function Base.show(io::IO, issue::IssueRecord)
    where_ = isnothing(issue.component) ? "whole file" : issue.component
    return print(io, "issue (severity ", issue.severity, ") on ", where_, ": ",
                 issue.description)
end

"""
    DataProductRecord

A data product a file is registered as.

# Fields
- `namespace`: the namespace it is registered in
- `name`: its registered name
- `version`: the version this file is
- `newest`: the newest version of the same name in the same namespace, which
  is `version` itself unless the registry holds a later one
- `url`: its URL in the registry
- `external_object`: the URL of its external object record, if it came from
  outside the pipeline, else `nothing`
"""
struct DataProductRecord
    namespace::String
    name::String
    version::VersionNumber
    newest::VersionNumber
    url::String
    external_object::Union{Nothing, String}
end

function Base.show(io::IO, dp::DataProductRecord)
    print(io, dp.namespace, "/", dp.name, " v", dp.version)
    dp.version < dp.newest && print(io, " (superseded by v", dp.newest, ")")
    return nothing
end

"""
    RegisteredObject

One registry object a file is registered as: its description, where the
registry expects to find it, what data products it serves and what problems
are recorded against it. An object with no data products is one of a code
run's own files - a working config, a submission script or a repository.

# Fields
- `description`: the object's description
- `url`: the object's URL in the registry
- `root`: the storage root the file is registered under
- `local_root`: whether that root is on this machine
- `stored_path`: the file's path within that root
- `data_products`: the [`DataProductRecord`](@ref)s it serves, if any
- `issues`: the [`IssueRecord`](@ref)s against it and its components
"""
struct RegisteredObject
    description::String
    url::String
    root::String
    local_root::Bool
    stored_path::String
    data_products::Vector{DataProductRecord}
    issues::Vector{IssueRecord}
end

function Base.show(io::IO, obj::RegisteredObject)
    print(io,
          isempty(obj.data_products) ? obj.description :
          join(sprint.(show, obj.data_products), ", "))
    isempty(obj.issues) || print(io, ", ", length(obj.issues), " issue",
          length(obj.issues) == 1 ? "" : "s")
    return nothing
end

"""
    FileIdentification

What a registry knows about one file on disk, as returned by
[`identify`](@ref). `objects` is empty when the registry has never been told
about a file with these contents.

# Fields
- `path`: the file asked about
- `hash`: its SHA-1, which is how the registry identifies it
- `objects`: the [`RegisteredObject`](@ref)s registered with that hash
"""
struct FileIdentification
    path::String
    hash::String
    objects::Vector{RegisteredObject}
end

function Base.show(io::IO, id::FileIdentification)
    isempty(id.objects) && return print(io, basename(id.path), ": unknown")
    return print(io, basename(id.path), ": ",
                 join(sprint.(show, id.objects), "; "))
end

function Base.show(io::IO, ::MIME"text/plain", id::FileIdentification)
    println(io, id.path)
    println(io, "  sha1: ", id.hash)
    if isempty(id.objects)
        return print(io, "  not registered in this registry")
    end
    for obj in id.objects
        println(io, "  registered as:")
        println(io, "    description: ", obj.description)
        println(io, "    stored:      ", obj.root, obj.stored_path,
                obj.local_root ? "" : " (not on this machine)")
        for dp in obj.data_products
            println(io, "    data product: ", dp.namespace, "/", dp.name)
            println(io, "      version:   ", dp.version,
                    dp.version < dp.newest ?
                    " - SUPERSEDED, newest is $(dp.newest)" : " (newest)")
            isnothing(dp.external_object) ||
                println(io, "      external object: ", dp.external_object)
        end
        for issue in obj.issues
            println(io, "    ", issue)
        end
    end
    return nothing
end

# == Functions ==

# The issues recorded against an object's components, naming the component
# unless it stands for the whole file
function _objectissues(registry::RegistryEndpoint, object::AbstractDict)
    issues = IssueRecord[]
    for component_url in object["components"]
        component = _getentry(registry, URIs.URI(component_url))
        name = component["whole_object"] ? nothing : String(component["name"])
        for issue_url in component["issues"]
            issue = _getentry(registry, URIs.URI(issue_url))
            push!(issues,
                  IssueRecord(issue["severity"], issue["description"], name))
        end
    end
    return issues
end

# A data product, with the newest version of the same name in its namespace
function _dataproductrecord(registry::RegistryEndpoint, url::String)
    entry = _getentry(registry, URIs.URI(url))
    namespace = _getentry(registry, URIs.URI(entry["namespace"]))["name"]
    versions = [VersionNumber(other["version"])
                for other in _getentries(registry, "data_product",
                                         Dict("name" => entry["name"],
                                              "namespace" =>
                                                  _extractid(entry["namespace"])))]
    version = VersionNumber(entry["version"])
    return DataProductRecord(namespace, entry["name"], version,
                             maximum(versions, init = version), entry["url"],
                             entry["external_object"])
end

"""
    identify(registry, path)
    identify(handle, path)

Ask a registry what it knows about the file at `path`, and return a
[`FileIdentification`](@ref): the data products it is registered as, where the
registry expects to find it, whether a newer version of any of those data
products exists, and any issues raised against it. `isempty(result.objects)`
means the registry has no record of a file with these contents.

The file is identified by the SHA-1 of its contents, as everything in the
pipeline is, so a copy under another name is recognised and an edited file is
not.

# Arguments
- `registry::RegistryEndpoint`: the registry to ask, which needs no token,
  e.g. `RegistryEndpoint("http://127.0.0.1:8000/api/")`; a
  `DataRegistryHandle` may be given instead, and its registry is used.
- `path::String`: the file to ask about.
"""
function identify(registry::RegistryEndpoint, path::String)
    isfile(path) || throw(ReadWriteException("no file at $path"))
    hash = _getfilehash(path)
    objects = RegisteredObject[]
    for location in _getentries(registry, "storage_location",
                                Dict("hash" => hash))
        root_entry = _getentry(registry, URIs.URI(location["storage_root"]))
        for object in _getentries(registry, "object",
                                  Dict("storage_location" =>
                                           _extractid(location["url"])))
            products = [_dataproductrecord(registry, url)
                        for url in object["data_products"]]
            push!(objects,
                  RegisteredObject(object["description"], object["url"],
                                   root_entry["root"], root_entry["local"],
                                   location["path"], products,
                                   _objectissues(registry, object)))
        end
    end
    return FileIdentification(path, hash, objects)
end
function identify(handle::DataRegistryHandle, path::String)
    return identify(handle.registry, path)
end

# ---- provenance tracing ----
# Written against the registry's 2021 schema and **not run since**: issues are
# read from an object, where they now hang off each object component, and
# `inputs`/`outputs` from an object, where provenance is now the `inputs_of`
# and `outputs_of` of a component. Rebuilding it is an open item.

# Count and print the issues of one object or component, once each
function record_issues!(registry::RegistryEndpoint, issues::Dict, obj)
    print(" - checking: ", obj["url"])
    length(obj["issues"]) == 0 && println(" - no issues detected.")
    output = 0
    for issue_url in obj["issues"]
        if haskey(issues, issue_url)
            issues[issue_url] += 1
        else
            issue = _getentry(registry, URIs.URI(issue_url))
            println("\n -- ISSUE DETECTED - SEVERITY := ", issue["severity"])
            println(" --- ", issue["description"])
            println(" --- last updated: ", issue["last_updated"])
            issues[issue_url] = 1
            output += 1
        end
    end
    return output
end

# Count the issues on the `trace` ("inputs" or "outputs") of an object, and
# on theirs in turn
function registry_audit_recursive(registry::RegistryEndpoint, obj,
                                  trace::String)
    haskey(obj, trace) || (return 0)
    ic = 0
    obj_urls = String[]
    issues = Dict{String, Int64}()
    for component_url in obj[trace]
        obj_c = _getentry(registry, URIs.URI(component_url))
        ic += record_issues!(registry, issues, obj_c)
        push!(obj_urls, obj_c["object"])
    end
    for obj_url in obj_urls
        obj2 = _getentry(registry, URIs.URI(obj_url))
        ic += registry_audit_recursive(registry, obj2, trace)
    end
    return ic
end

"""
    registry_audit(registry, url; trace = "both")

Search the registry for known issues with a data product, code repo release
or code run, and with everything upstream and downstream of it in provenance,
printing what is found.

# Arguments
- `registry::RegistryEndpoint`: the registry to search.
- `url::String`: the registry URL of the thing to audit.
- `trace::String`: `"inputs"`, `"outputs"` or `"both"`, the default.
"""
function registry_audit(registry::RegistryEndpoint, url::String;
                        trace::String = "both")
    function print_thing(resp, thing::String, lbl = thing)
        return haskey(resp, thing) && println(" - ", lbl, ": ", resp[thing])
    end
    el_count(cnt) = string(cnt == 0 ? "no issues" :
                           (cnt == 1 ? "one issue" : string(cnt, " issues")))
    resp = _getentry(registry, URIs.URI(url))
    println("DATA REGISTRY AUDIT: ", url)
    print_thing(resp, "name")
    print_thing(resp, "version")
    print_thing(resp, "last_updated", "last updated")
    ic = zeros(Int64, 3)
    obj = _getentry(registry, URIs.URI(resp["object"]))
    issues = Dict{String, Int64}()
    ic[1] += record_issues!(registry, issues, obj)
    for component_url in obj["components"]
        obj_c = _getentry(registry, URIs.URI(component_url))
        ic[1] += record_issues!(registry, issues, obj_c)
    end
    status = string(" - directly affected by ", el_count(ic[1]), ".")
    if trace != "outputs"
        println("AUDITING INPUTS:")
        ic[2] += registry_audit_recursive(registry, obj, "inputs")
        status = string(status, "\n - inputs affected by ", el_count(ic[2]),
                        ".")
    end
    if trace != "inputs"
        println("AUDITING OUTPUTS:")
        ic[3] += registry_audit_recursive(registry, obj, "outputs")
        status = string(status, "\n - outputs affected by ", el_count(ic[3]),
                        ".")
    end
    println("AUDIT COMPLETE - ", el_count(sum(ic)), " detected for ", url)
    return sum(ic) > 0 && println(status)
end
