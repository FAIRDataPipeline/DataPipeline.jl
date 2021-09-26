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
 postentry(table, data)

Upload to data registry
"""
function postentry(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    token = gettoken()
    headers = Dict("Authorization" => token, "Content-Type" => "application/json")
    body = JSON.json(query)
 
    resolved_query = DataPipeline.convertquery(query)
    r = DataPipeline.getentry(URIs.URI("$url$resolved_query"))

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
    convertquery(query)

Convert dictionary to url query.
"""
function convertquery(query::Dict) 
    url = "?"
    for (key, value) in query
        if isa(value, Bool)
            tmp = value
        elseif all(occursin.(API_ROOT, value))
            tmp = extractid(value)
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
    getentry(table, query)

Use query to get entry from local registry
"""
function getentry(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    resolved_query = convertquery(query)
    r = getentry(URIs.URI("$url$resolved_query"))

    if r["count"] == 0
        return nothing
    else
        results = r["results"]
        @assert length(results) == 1
        return results[1]
    end 
end

"""
    getentry(url)

Read data registry
"""
function getentry(url::URIs.URI)
    token = gettoken()
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
    geturl(table, query)

Use query to get entry url from local registry
"""
function geturl(table::String, query::Dict)
    entry = getentry(table, query)
    output = isnothing(entry) ? nothing : entry["url"] 
    return output
end

"""
    getid(table, query)

Use query to get entry id from local registry
"""
function getid(table::String, query::Dict)
    url = geturl(table, query)
    output = isnothing(url) ? nothing :  extractid(url)
    return output
end

"""
    extractid(url)

Extract id from url
"""
function extractid(url)
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
    checkexists(table, query)

Use query to check whether entry exists in local registry
"""
function checkexists(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    resolved_query = convertquery(query)
    r = getentry(URIs.URI("$url$resolved_query"))
    exists = r["count"] == 0 ? false : true
    return exists
end

"""
    getfilehash(filepath)

Get file hash
"""
function getfilehash(filepath::String)
fhash = bytes2hex(SHA.sha2_256(filepath))
    return fhash
end

"""
    gettoken()

Get local repository access token.
"""
function gettoken()
    fp = expanduser("~/.fair/registry/token")
    token = open(fp) do file
        read(file, String)
    end
    return string("token ", chomp(token))
end
