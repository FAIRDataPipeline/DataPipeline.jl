"""
    DataRegistryHandle

# Fields
- `config`: working config.yaml file
- `config_obj`: object url associated with working config.yaml file
- `script_obj`: object url associated with submission script file
- `repo_obj`: object url associated with remote repository
- `datastore_obj_url`: object url associated with datastore
- `code_run_obj`: object url associated with code run
- `inputs`: metadata associated with code run inputs
- `outputs`: metadata associated with code run outputs
"""
struct DataRegistryHandle
    config::Dict
    config_obj::String
    script_obj::String
    repo_obj::String
    datastore_obj_url::String
    code_run_obj::String
    inputs::Dict
    outputs::Dict
end

"""
    _postentry(table, data)

Post entry to local data registry.
"""
function _postentry(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    resolved_query = DataPipeline._convertquery(query)
    r = DataPipeline._getentry(URIs.URI("$url$resolved_query"))

    if r["count"] == 1
        entry_url = r["results"][1]["url"]

    elseif r["count"] == 0
        if haskey(query, "root") && isnothing(match(r".*://.*", query["root"]))
            value = query["root"]
            query["root"] = "file://$value"
        end

        token = _gettoken()
        headers = Dict("Authorization" => token, "Content-Type" => "application/json",
                       "Accept" => "application/json; version=1.0.0")
        body = JSON.json(query)
        r = HTTP.request("POST", url, headers=headers, body=body)
        resp = String(r.body)
        json_resp = JSON.parse(resp)
        entry_url = json_resp["url"]
    end
    return entry_url
end

"""
    _convertquery(query)

Convert dictionary to url query.
"""
function _convertquery(query::Dict) 
    url = "?"

    for (key, value) in query
        if isa(value, Bool)
            tmp = value
        elseif key == "root" && isnothing(match(r".*://.*", value))
            tmp = "file://$value"
        elseif all(occursin.(API_ROOT, value))
            tmp = _extractid(value)
            tmp = isa(tmp, Vector) ? join(tmp, ",") : tmp
        else
            tmp = URIs.escapeuri(value)
        end
        url = "$url$key=$tmp&"
    end
    url = chop(url, tail=1)
    return url
end

"""
    _getentry(table, query)

Use query to get entry from local data registry.
"""
function _getentry(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    resolved_query = _convertquery(query)
    r = _getentry(URIs.URI("$url$resolved_query"))

    if r["count"] == 0
        return nothing
    else
        results = r["results"]
        @assert length(results) == 1
        entry = results[1]
        return entry
    end 
end

"""
    _getentry(url)

Use URL to get entry from local data registry.
"""
function _getentry(url::URIs.URI)
    token = _gettoken()
    headers = Dict("Authorization" => token, "Content-Type" => "application/json")
    try
        r = HTTP.request("GET", url, headers)
        entry = JSON.parse(String(r.body))
        return entry
    catch e
        msg = "couldn't connect to local web server... have you run the start script?"
        isa(e, Base.IOError) && throw(ReadWriteException(msg))
        println("ET: ", typeof(e))
        throw(e)
    end
end

"""
    _geturl(table, query)

Use query to get entry URL from local data registry.
"""
function _geturl(table::String, query::Dict)
    entry = _getentry(table, query)
    output = isnothing(entry) ? nothing : entry["url"] 
    return output
end

"""
    _getid(table, query)

Use query to get entry ID from local data registry.
"""
function _getid(table::String, query::Dict)
    url = _geturl(table, query)
    output = isnothing(url) ? nothing :  _extractid(url)
    return output
end

"""
    _extractid(url)

Extract ID from URL.
"""
function _extractid(url)
    if !isa(url, Vector)
        tmp = match(r".*/([0-9]*)/", url)
        output = String(tmp[1])
    else
        output = Char[]
        for i in url
            tmp = match(r".*/([0-9]*)/", i)
            append!(output, tmp[1])
        end
    end
    return output
end

"""
    _checkexists(table, query)

Use query to check whether entry exists in local registry.
"""
function _checkexists(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    resolved_query = _convertquery(query)
    r = _getentry(URIs.URI("$url$resolved_query"))
    exists = r["count"] == 0 ? false : true
    return exists
end

"""
    _getfilehash(filepath)

Get file hash.
"""
function _getfilehash(filepath::String)
    fhash = open(filepath) do file
        bytes2hex(SHA.sha1(file))
    end
    return fhash
end

"""
    _gettoken()

Get local repository access token.
"""
function _gettoken()
    return string("token ", FDP_LOCAL_TOKEN)
end
