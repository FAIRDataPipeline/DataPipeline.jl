# SPDX-License-Identifier: LGPL-3.0-or-later

# Audit tools: finding a local file in the registry and tracing issues through
# provenance. Unexported, and `whats_my_file` has not been checked against the
# registry's schema since the object/data_product relation changed.

# The storage locations in the registry holding a file of hash `fh`
function whats_my_hash(registry::RegistryEndpoint, fh::String)
    search_url = string(registry.url, "storage_location/?hash=", fh)
    return _getentry(registry, URIs.URI(search_url))
end

"""
    whats_my_file(registry, path; show_path = false)

Search the registry for matches with a local file, or every file under a
directory, printing what is found.

# Arguments
- `registry::RegistryEndpoint`: the registry to search.
- `path::String`: a file, or a directory to walk.
- `show_path::Bool`: also print the stored path of each match.
"""
function whats_my_file(registry::RegistryEndpoint, path::String;
                       show_path::Bool = false)
    if isfile(path)
        println("Searching the Data Registry for files similar to ",
                basename(path))
        println(" - filepath: ", path)
        println(" - type:     ", _extension(path))
        resp = whats_my_hash(registry, _getfilehash(path))
        println(" -> Results: ", resp["count"], " matching data product",
                resp["count"] == 1 ? "" : "s")
        for result in resp["results"]
            sl = result["url"]
            obj_url = string(registry.url, "object/?storage_location=",
                             _extractid(sl))
            obj_resp = _getentry(registry, URIs.URI(obj_url))["results"][1]
            dp_resp = _getentry(registry, URIs.URI(obj_resp["data_product"]))
            ns_resp = _getentry(registry, URIs.URI(dp_resp["namespace"]))
            sr_resp = _getentry(registry, URIs.URI(result["storage_root"]))
            println("\n ", dp_resp["url"])
            println(" - name:         ", dp_resp["name"])
            println(" -- version:     ", dp_resp["version"])
            println(" -- namespace:   ", ns_resp["name"])
            println(" -- description: ", obj_resp["description"])
            println(" - last updated: ", obj_resp["last_updated"])
            println(" -- by:          ", obj_resp["updated_by"])
            println(" - object:     ", obj_resp["url"])
            println(" - storage:  ", sl)
            println(" -- root:    ", sr_resp["name"])
            show_path && println(" -- path:    ",
                    joinpath(sr_resp["root"], result["path"]))
        end
    elseif isdir(path)
        println("Scanning directory... ")
        none = true
        for (root, dirs, files) in walkdir(path)
            for file in files
                none || println()
                none = false
                whats_my_file(registry, joinpath(root, file),
                              show_path = show_path)
            end
        end
        none && println(" - no files found.")
    else
        println("ERROR: invalid path:", path)
    end
end

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
