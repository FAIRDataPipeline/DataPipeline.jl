"""
This is an `X`

# Fields
- a: First letter of the English alphabet
- b: Second letter of the English alphabet
- c: C is for cookie
"""
struct DataRegistryHandle
    config::Dict            # working config file data
    config_obj::String      # config file object id
    script_obj::String      # submission script object file id
    repo_obj::String        # code repo object file id (optional)
    write_data_store::String          
    # user_id               # [local registry] user_id
    code_run_obj::String
    inputs::Dict
    outputs::Dict
end

"""
 _postentry(table, data)

Upload to data registry
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

Use query to get entry from local registry
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
        return results[1]
    end 
end

"""
    _getentry(url)

Read data registry
"""
function _getentry(url::URIs.URI)
    token = _gettoken()
    headers = Dict("Authorization" => token, "Content-Type" => "application/json")
    try
        r = HTTP.request("GET", url, headers)
        return JSON.parse(String(r.body))
    catch e
        msg = "couldn't connect to local web server... have you run the start script?"
        isa(e, Base.IOError) && throw(ReadWriteException(msg))
        println("ET: ", typeof(e))
        throw(e)
    end
end

"""
    _geturl(table, query)

Use query to get entry url from local registry
"""
function _geturl(table::String, query::Dict)
    entry = _getentry(table, query)
    output = isnothing(entry) ? nothing : entry["url"] 
    return output
end

"""
    _getid(table, query)

Use query to get entry id from local registry
"""
function _getid(table::String, query::Dict)
    url = _geturl(table, query)
    output = isnothing(url) ? nothing :  _extractid(url)
    return output
end

"""
    _extractid(url)

Extract id from url
"""
function _extractid(url)
    if !isa(url, Vector)
        tmp = match(r".*/([0-9]*)/", url)
        return String(tmp[1])
    else
        output = Char[]
        for i in url
            tmp = match(r".*/([0-9]*)/", i)
            append!(output, tmp[1])
        end
        return output
    end
end

"""
    _checkexists(table, query)

Use query to check whether entry exists in local registry
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

Get file hash
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
    token = open(fp) do file
        read(file, String)
    end
    return string("token ", chomp(token))
end
