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
    convert_query(query)

Convert dictionary to url query.
"""
function convert_query!(query::Dict) 
    url = "?"
    for (key, value) in query
        if isa(value, Bool)
            query = value
        elseif all(contains.(value, API_ROOT))
            query = extract_id(value)
            query = isa(query, Vector) ? join(query, ",") : query
        else
            query = URIs.escapeuri(value)
        end
        url = "$url$key=$query&"
    end
    url = chop(url, tail = 1)
    return url
end

"""
    get_entry(table, query)

Use query to get entry from local registry
"""
function get_entry(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    convert_query!(query)
    r = DataPipeline.http_get_json("$url$query")

    if r["count"] == 0
        return nothing
    else
        results = r["results"]
        @assert length(results) == 1
        return results[1]
    end 
end

"""
    get_url(table, query)

Use query to get entry url from local registry
"""
function get_url(table::String, query::Dict)
    entry = DataPipeline.get_entry(table, query)
    output = isnothing(entry) ? nothing : entry["url"] 
    return output
end

"""
    get_id(table, query)

Use query to get entry id from local registry
"""
function get_id(table::String, query::Dict)
    url = DataPipeline.get_url(table, query)
    output = isnothing(url) ? nothing :  extract_id(url)
    return output
end

"""
    extract_id(url)

Extract id from url
"""
function extract_id(url)
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
    check_exists(table, query)

Use query to check whether entry exists in local registry
"""
function check_exists(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    convert_query!(query)
    r = DataPipeline.http_get_json("$url$query")
    exists = r["count"]==0 ? false : true
    return exists
end

"""
    http_post_data(table, data)

Upload to data registry
"""
function http_post_data(table::String, query::Dict)
    url = string(API_ROOT, table, "/")
    token = DataPipeline.get_access_token()
    headers = Dict("Authorization" => token, "Content-Type" => "application/json")
    body = JSON.json(query)
    
    convert_query!(query)
    r = DataPipeline.http_get_json("$url$query")

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
    http_get_json(url)

Read data registry
"""
function http_get_json(url::String)
    url = replace(url, LOCAL_DR_PORTLESS => API_ROOT)
    token = DataPipeline.get_access_token()
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
    get_file_hash(filepath)

Get file hash
"""
function get_file_hash(filepath::String)
    fhash = bytes2hex(SHA.sha2_256(filepath))
    return fhash
end

"""
    get_access_token()

Get local repository access token.
"""
function get_access_token()
   fp = expanduser("~/.fair/registry/token")
   token = open(fp) do file
     read(file, String)
   end
   return string("token ", chomp(token))
end
