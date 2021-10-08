"""
    DataRegistryHandle

# Fields
- `config`: working config.yaml file
- `config_obj`: object url associated with working config.yaml file
- `script_obj`: object url associated with submission script file
- `repo_obj`: object url associated with remote repository
- `code_run_obj`: object url associated with code run
- `inputs`: metadata associated with code run inputs
- `outputs`: metadata associated with code run outputs
"""
struct DataRegistryHandle
    config::Dict
    config_obj::String
    script_obj::String
    repo_obj::String
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
    token = _gettoken()
    headers = Dict("Authorization" => token, "Content-Type" => "application/json")
    body = JSON.json(query)
 
    resolved_query = _convertquery(query)
    r = _getentry(URIs.URI("$url$resolved_query"))

    if r["count"] == 1
        entry_url = r["results"][1]["url"]

    elseif r["count"] == 0
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
    fhash = bytes2hex(SHA.sha2_256(filepath))
    return fhash
end

"""
    _gettoken()

Get local repository access token.
"""
function _gettoken()
    fp = expanduser("~/.fair/registry/token")
    if isfile(fp)
        token = open(fp) do file
            read(file, String)
        end
        output = string("token ", chomp(token))
    else
        token = ENV["FDP_LOCAL_TOKEN"]
        output = string("token ", token)
    end
    return output
end
