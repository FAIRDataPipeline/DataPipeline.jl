### what's my file
# NB. THIS IS NOW BROKEN DUE TO CHANGES TO THE DR SCHEMA ***********
function whats_my_hash(fh::String)
    search_url = string(API_ROOT, "storage_location/?hash=", fh)
    return _getentry(URIs.URI(search_url))
end
# NB. add option for staged objects?
"""
    whats_my_file(path::String; show_path=false)

Search the Data Registry for matches with a given local file (or directory of files.)

**Parameters**
- `path`        -- local file path, or directory.
- `show_path`   -- (optional) display the [remote] path of any matching files.
"""
function whats_my_file(path::String; show_path=false)
    if isfile(path)     ## single file
        # ft = get_file_type(path)
        println("Searching the Data Registry for files similar to ", basename(path))
        println(" - filepath: ", path)
        println(" - type:     ", get_file_type(path))
        fh = _getfilehash(path)
        resp = whats_my_hash(fh)
        ## process results
        println(" -> Results: ", resp["count"], " matching data product", resp["count"]==1 ? "" : "s")
        for i in eachindex(resp["results"])
            ## get object
            sl = resp["results"][i]["url"]
            println("SL: ", resp["results"][i])
            obj_url = string(API_ROOT, "object/?storage_location=", get_id_from_root(sl, SL_ROOT))
            obj_resp = _getentry(URIs.URI(obj_url)["results"][1])
            dp_resp = _getentry(URIs.URI(obj_resp["data_product"]))
            ns_resp = _getentry(URIs.URI(dp_resp["namespace"]))
            sr_resp = _getentry(URIs.URI(resp["results"][i]["storage_root"]))
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
            show_path && println(" -- path:    ", joinpath(sr_resp["root"], resp["results"][i]["path"]))
        end
    elseif isdir(path)  ## recurse
        println("Scanning directory... ")
        none = true
        for (root, dirs, files) in walkdir(path)
            # println("Searching $root")
            for file in files
                none || println()
                none = false
                whats_my_file(joinpath(root, file), show_path=show_path)
            end
        end
        none && println(" - no files found.")
    else
        println("ERROR: invalid path:", path)
    end
end


### audit trail ph
# NB - what about auth for user info? ***
# - TBA: versioning ******

## record object / component issues
function record_issues!(issues::Dict, obj)
    print(" - checking: ", obj["url"])
    length(obj["issues"])==0 && println(" - no issues detected.")
    output = 0
    for i in eachindex(obj["issues"])
        if haskey(issues, obj["issues"][i])
            issues[obj["issues"][i]] += 1
        else
            issue = _getentry(URIs.URI(obj["issues"][i]))
            println("\n -- ISSUE DETECTED - SEVERITY := ", issue["severity"])
            println(" --- ", issue["description"])
            println(" --- last updated: ", issue["last_updated"])
            issues[obj["issues"][i]] = 1
            output += 1
        end
    end
    return output
end

## recurse over input / outputs
# NB. obj - issues..?
function registry_audit_recursive(obj, trace::String)
    haskey(obj, trace) || (return 0)
    ic = 0
    obj_urls = String[]
    issues = Dict{String, Int64}()
    for c in eachindex(obj[trace])
        obj_c = _getentry(URIs.URI(obj[trace][c]))
        ic += record_issues!(issues, obj_c)
        push!(obj_urls, obj_c["object"])
    end
    ## recurse over distinct object urls
    for o in eachindex(obj_urls)
        obj2 = _getentry(URIs.URI(obj_urls[o]))
        ic += registry_audit_recursive(obj2, trace)
    end
    return ic
end

## audit e.g. data product
"""
    registry_audit(url; trace="both")

Search the Data Registry for known issues with, e.g. data products, code repo releases or code runs.

Any issues that impact upon provenance (i.e. [a subset of] the graph of Registry objects associated with this one) can also be displayed w.r.t. "inputs", "outputs" or "both".

**Parameters**
- `url`     -- the URL of e.g. a data product or code repo release in the Data Registry.
- `trace`   -- `"inputs"`, `"outputs"` or `"both"` -- also the default.
"""
function registry_audit(url::String; trace::String="both")
    function print_thing(resp, thing::String, lbl=thing)
        haskey(resp, thing) && println(" - ", lbl, ": ", resp[thing])
    end
    el_count(cnt) = string(cnt==0 ? "no issues" : (cnt==1 ? "one issue" : string(cnt, " issues")))
    ## fetch e.g. data product
    # - ADD ERROR HANDLING
    resp = _getentry(URIs.URI(url))
    println("DATA REGISTRY AUDIT: ", url)
    print_thing(resp, "name")
    print_thing(resp, "version")
    print_thing(resp, "last_updated", "last updated")
    ## record object issues
    ic = zeros(Int64, 3)
    obj = _getentry(URIs.URI(resp["object"]))
    issues = Dict{String,Int64}()
    ic[1] += record_issues!(issues, obj)
    ## record component issues
    for c in eachindex(obj["components"])
        obj_c = _getentry(URIs.URI(obj["components"][c]))
        ic[1] += record_issues!(issues, obj_c)
    end
    status = string(" - directly affected by ", el_count(ic[1]), ".")
    ## recurse
    if trace!="outputs"
        println("AUDITING INPUTS:")
        ic[2] += registry_audit_recursive(obj, "inputs")
        status = string(status, "\n - inputs affected by ", el_count(ic[2]), ".")
    end
    if trace!="inputs"
        println("AUDITING OUTPUTS:")
        ic[3] += registry_audit_recursive(obj, "outputs")
        status = string(status, "\n - outputs affected by ", el_count(ic[3]), ".")
    end
    ## print end status
    println("AUDIT COMPLETE - ", el_count(sum(ic)), " detected for ", url)
    sum(ic) > 0 && println(status)
end
