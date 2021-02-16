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
            issue = http_get_json(obj["issues"][i])
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
        obj_c = http_get_json(obj[trace][c])
        ic += record_issues!(issues, obj_c)
        push!(obj_urls, obj_c["object"])
    end
    ## recurse over distinct object urls
    for o in eachindex(obj_urls)
        obj2 = http_get_json(obj_urls[o])
        ic += registry_audit_recursive(obj2, trace)
    end
    return ic
end

## audit e.g. data product
"""
    registry_audit(url; trace = "both")

Search the Data Registry for known issues with, e.g. data products, code repo releases or code runs.

**Parameters**
- `url`     -- the URL of e.g. a data product or code repo release in the Data Registry.
- `trace`   -- `String`: `"inputs"`, `"outputs"` or `"both"` (the default.)
"""
function registry_audit(url::String; trace::String="both")
    function print_thing(resp, thing::String, lbl=thing)
        haskey(resp, thing) && println(" - ", lbl, ": ", resp[thing])
    end
    el_count(cnt) = string(cnt==0 ? "no issues" : (cnt==1 ? "one issue" : string(cnt, " issues")))
    ## fetch e.g. data product
    # - ADD ERROR HANDLING
    resp = http_get_json(url)
    println("DATA REGISTRY AUDIT: ", url)
    print_thing(resp, "name")
    print_thing(resp, "version")
    print_thing(resp, "last_updated", "last updated")
    ## record object issues
    ic = zeros(Int64, 3)
    obj = http_get_json(resp["object"])
    issues = Dict{String,Int64}()
    ic[1] += record_issues!(issues, obj)
    ## record component issues
    for c in eachindex(obj["components"])
        obj_c = http_get_json(obj["components"][c])
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
