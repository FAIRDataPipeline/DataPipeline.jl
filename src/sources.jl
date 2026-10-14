# SPDX-License-Identifier: LGPL-3.0-or-later

# The source of a registered file: what a link call says of it, the rule that
# a source is one file, and how it reaches the registry at `finalise`.

"""
    _source(handle; doi, bibtex, title, primary, description, original_store,
            licence, release_date, release_version)

Return the [`SourceRecord`](@ref) that the source keywords of a link call
describe, or `nothing` when they name no source. The link calls say what each
keyword is. The source's authors are found in the registry as the call is
made, those it has not got being registered.
"""
function _source(handle::DataRegistryHandle; doi, bibtex, title, primary,
                 description, original_store, licence, license, release_date,
                 release_version)
    if isnothing(doi) && isnothing(bibtex)
        said = (; title, primary, description, original_store, licence,
                license, release_date, release_version)
        given = [keyword for keyword in keys(said) if !isnothing(said[keyword])]
        isempty(given) ||
            throw(ArgumentError("`$(join(given, "`, `"))` given of a source that is not named: give its `doi` or its `bibtex` key"))
        return nothing
    end
    citation = _citation(handle, doi, bibtex)
    isnothing(primary) &&
        throw(ArgumentError("say what the file is to its source: `primary = true` if it is the cited item or one of its files, `primary = false` if it was requested or derived from it"))
    facts = _sourcefacts(citation; primary, title, description, release_date,
                         release_version)
    store = _originalstore(original_store)
    terms = _licence(_eitherspelling(licence, license))
    # Nothing is registered until everything that was said has been read
    authors = unique!(String[_authorurl(handle, name)
                             for name in facts.authors])
    description = isnothing(facts.description) ? nothing :
                  String(facts.description)
    return SourceRecord(facts.identifier, facts.title, facts.version,
                        facts.release_date, description, facts.primary,
                        authors, store, terms)
end

# Where a file was fetched from, as the storage root and the path under it
# that the registry records: `nothing` unless it is the URL of a file on a
# host, which is all that anyone else could fetch it from
_originalstore(::Nothing) = nothing
function _originalstore(url::AbstractString)
    startswith(lowercase(url), "file:") && return nothing
    remote = match(r"^([A-Za-z][A-Za-z0-9+.-]*://[^/]+/)(.+)$", url)
    isnothing(remote) && return nothing
    return (root = String(remote[1]), path = String(remote[2]))
end

# What makes a source one source in the registry
function _identity(source::SourceRecord)
    return (source.identifier, source.title, source.version)
end

# Whether two calls say the same of a source
function _samerecord(a::SourceRecord, b::SourceRecord)
    return all(getfield(a, field) == getfield(b, field)
               for field in fieldnames(SourceRecord))
end

# Throw unless a further call for a data product that a code run is writing
# names the source that the first did, or none
_checksamesource(::DataRegistryHandle, ::AbstractString, ::Nothing) = nothing
function _checksamesource(handle::DataRegistryHandle,
                          data_product::AbstractString, source::SourceRecord)
    held = _outputsource(handle, data_product)
    (!isnothing(held) && _samerecord(held, source)) ||
        throw(ReadWriteException("'$data_product' is already being written by this code run, $(isnothing(held) ? "with no source" : "with another source")"))
    return nothing
end

# The source that a code run's link call gave for a data product it is
# writing, or `nothing`
function _outputsource(handle::DataRegistryHandle, data_product::AbstractString)
    for (key, metadata) in handle.outputs
        key[1] == data_product && haskey(metadata, "source") &&
            return metadata["source"]
    end
    return nothing
end

"""
    _checkonefile(handle, source, hash, data_product)

Throw a [`ReadWriteException`](@ref) if `source` - its identifier, title and
release version - is that of a file other than the one with this `hash`: one
the registry holds, or one that this code run is registering under another
name. A source is one file, which any number of data products may hold;
`data_product` is the one being registered. With no source there is nothing
to check.
"""
function _checkonefile(::DataRegistryHandle, ::Nothing, ::AbstractString,
                       ::AbstractString)
    return nothing
end
function _checkonefile(handle::DataRegistryHandle, source::SourceRecord,
                       hash::AbstractString, data_product::AbstractString)
    registry = handle.registry
    differs(held) = ReadWriteException("cannot register '$data_product': its source - $(source.identifier), '$(source.title)', release $(source.version) - is that of a different file, $held. A source is one file: give this one a `title` of its own, or the `release_version` it was taken from")
    rows = _getentries(registry, "external_object",
                       Dict("identifier" => source.identifier,
                            "title" => source.title,
                            "version" => source.version))
    for row in rows, url in get(row, "data_products", [])
        registered = _getentry(registry, URIs.URI(url))
        object = _getentry(registry, URIs.URI(registered["object"]))
        # A data product with no file holds none to differ from
        isnothing(object["storage_location"]) && continue
        location = _getentry(registry, URIs.URI(object["storage_location"]))
        location["hash"] == hash && continue
        namespace = _getentry(registry, URIs.URI(registered["namespace"]))
        throw(differs("registered as $(namespace["name"]):$(registered["name"]) version $(registered["version"])"))
    end
    for key in sort(collect(keys(handle.outputs)), by = string)
        metadata = handle.outputs[key]
        other = get(metadata, "source", nothing)
        (key[1] == data_product || isnothing(other)) && continue
        (_identity(other) == _identity(source) && isfile(metadata["path"])) ||
            continue
        _getfilehash(metadata["path"]) == hash ||
            throw(differs("which this code run is registering as '$(key[1])'"))
    end
    return nothing
end

# Check, before a code run registers any output, that each of those with a
# source is the one file of that source, keeping the hash it was checked by
function _checksources(handle::DataRegistryHandle)
    for key in sort(collect(keys(handle.outputs)), by = string)
        metadata = handle.outputs[key]
        source = get(metadata, "source", nothing)
        (isnothing(source) || !isfile(metadata["path"])) && continue
        metadata["hash"] = _getfilehash(metadata["path"])
        _checkonefile(handle, source, metadata["hash"], key[1])
    end
    return nothing
end

# Whether a registered data product and its object record what `source` says
# of it: the same source, authors and licence. A file with no source is
# compared by its bytes alone.
function _recordssource(::RegistryEndpoint, ::AbstractDict, ::AbstractDict,
                        ::Nothing)
    return true
end
function _recordssource(registry::RegistryEndpoint, data_product::AbstractDict,
                        object::AbstractDict, source::SourceRecord)
    url = get(data_product, "external_object", nothing)
    isnothing(url) && return false
    held = _getentry(registry, URIs.URI(url))
    (held["identifier"], held["title"], held["version"]) == _identity(source) ||
        return false
    # The registry keeps an object's authors in no order
    sort(object["authors"]) == sort(source.authors) || return false
    licences = [(info = licence["licence_info"],
                 identifier = licence["identifier"])
                for licence in (_getentry(registry, URIs.URI(licence_url))
                                for licence_url in object["licences"])]
    return licences == (isnothing(source.licence) ? [] : [source.licence])
end

# The authors of a registered file: its source's, or with no source the user
_fileauthors(registry::RegistryEndpoint, ::Nothing) = [_getauthorurl(registry)]
_fileauthors(::RegistryEndpoint, source::SourceRecord) = source.authors

"""
    _registersource(registry, source, data_product_url, object_url, hash,
                    public)

Register what `source` says of a data product that has just been registered:
where its file, of this `hash`, was fetched from; the source itself, which the
registry keeps once and links to each data product registered from it; and
the licence on the file's object. With no source nothing is registered.
"""
function _registersource(::RegistryEndpoint, ::Nothing, ::AbstractString,
                         ::AbstractString, ::AbstractString, ::Bool)
    return nothing
end
function _registersource(registry::RegistryEndpoint, source::SourceRecord,
                         data_product_url::AbstractString,
                         object_url::AbstractString, hash::AbstractString,
                         public::Bool)
    released = Dates.format(source.release_date, "yyyy-mm-ddTHH:MM:SS") * "Z"
    data = Dict{String, Any}("data_product" => data_product_url,
                             "identifier" => source.identifier,
                             "title" => source.title,
                             "version" => source.version,
                             "release_date" => released,
                             "primary_not_supplement" => source.primary)
    isnothing(source.description) ||
        (data["description"] = source.description)
    store = _originallocation(registry, source.original_store, hash, public)
    isnothing(store) || (data["original_store"] = store)
    _createentry(registry, "external_object", data)

    isnothing(source.licence) ||
        _createentry(registry, "licence",
                     Dict("object" => object_url,
                          "licence_info" => source.licence.info,
                          "identifier" => source.licence.identifier))
    return nothing
end

# The URL of the registry's storage location for where a file was fetched
# from, or `nothing` where that is not recorded. The registry holds a file
# once under a root, whatever its path there, so one already held is the one.
function _originallocation(::RegistryEndpoint, ::Nothing, ::AbstractString,
                           ::Bool)
    return nothing
end
function _originallocation(registry::RegistryEndpoint, store::NamedTuple,
                           hash::AbstractString, public::Bool)
    root_url = _postentry(registry, "storage_root",
                          Dict("root" => store.root, "local" => false))["url"]
    held = _getentry(registry, "storage_location",
                     Dict("hash" => hash, "public" => public,
                          "storage_root" => _extractid(root_url)))
    if isnothing(held)
        return _createentry(registry, "storage_location",
                            Dict("path" => store.path, "hash" => hash,
                                 "public" => public,
                                 "storage_root" => root_url))["url"]
    end
    held["path"] == store.path ||
        @warn "the file fetched from $(store.root)$(store.path) is already recorded at $(store.root)$(held["path"]), which is kept as where it came from"
    return held["url"]
end
