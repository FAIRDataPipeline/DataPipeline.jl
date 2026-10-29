# SPDX-License-Identifier: LGPL-3.0-or-later

# The source of a registered file: what a link call says of it, the rule that
# a source is one file, and how it reaches the registry at `finalise`.

"""
    _source(handle; doi, bibtex, title, primary, description, original_store,
            licence, release_date, release_version,
            authorurl = _sourceauthorurl)

Return the [`SourceRecord`](@ref) that the source keywords of a link call
describe, or `nothing` when they name no source. The link calls say what each
keyword is. The source's authors are found in the registry as the call is
made, by `authorurl(handle, name, identifier)`: by default those it has not
got are registered, and with `_heldauthorurl` nothing is. With `compared`,
return only what `isregistered` compares, a `_ComparedSource`, for which
`primary` and a release date may be left out; what is given is checked
either way.
"""
function _source(handle::DataRegistryHandle; doi, bibtex, title, primary,
                 description, original_store, licence, license, release_date,
                 release_version, authorurl::Function = _sourceauthorurl,
                 compared::Bool = false)
    if isnothing(doi) && isnothing(bibtex)
        said = (; title, primary, description, original_store, licence,
                license, release_date, release_version)
        given = [keyword for keyword in keys(said) if !isnothing(said[keyword])]
        isempty(given) ||
            throw(ArgumentError("`$(join(given, "`, `"))` given of a source that is not named: give its `doi` or its `bibtex` key"))
        return nothing
    end
    _checksourcerows(handle.registry)
    citation = _citation(handle, doi, bibtex)
    isnothing(primary) && !compared &&
        throw(ArgumentError("say what the file is to its source: `primary = true` if it is the cited item or one of its files, `primary = false` if it was requested or derived from it"))
    # A comparison reads no `primary`, so may be given none
    facts = _sourcefacts(citation; primary = something(primary, false), title,
                         description, release_date, release_version,
                         dated = !compared)
    store = _originalstore(original_store)
    given = _eitherspelling(licence, license)
    terms = _licence(something(given, facts.licence, Some(nothing)))
    # Nothing is registered until everything that was said has been read
    authors = unique!(String[authorurl(handle, name,
                                       get(facts.identifiers, name, nothing))
                             for name in facts.authors])
    compared && return _ComparedSource(facts.identifier, facts.title,
                           facts.version, authors, terms)
    description = isnothing(facts.description) ? nothing :
                  String(facts.description)
    return SourceRecord(facts.identifier, facts.title, facts.version,
                        facts.release_date, description, facts.primary,
                        authors, store, terms)
end

# Throw unless the registry keeps one row for each source, shared by the data
# products registered from it, as a registry does from v1.4.0: only such a
# registry takes a query for the sources of a data product, whatever data
# products it holds
function _checksourcerows(registry::RegistryEndpoint)
    try
        _getentry(registry,
                  URIs.URI(string(registry.url,
                                  "external_object/?data_products=0")))
    catch e
        (e isa HTTP.StatusError && e.status == 400) || rethrow()
        throw(ReadWriteException("the registry at $(registry.url) keeps a source for each data product, as a registry before v1.4.0 does, so a source's own release version cannot be recorded: registering a file with its source needs a registry at v1.4.0 or later"))
    end
    return nothing
end

# The registry's author for an author of a source: the one with the identifier
# that the source's own metadata gives, registered as `register_authors!` would
# register it, since that metadata is taken to be right; else the one the name
# gives
function _sourceauthorurl(handle::DataRegistryHandle, name::AbstractString,
                          ::Nothing)
    return _authorurl(handle, name)
end
function _sourceauthorurl(handle::DataRegistryHandle, name::AbstractString,
                          identifier::AbstractString)
    author = _author(name, identifier)
    _registerauthor!(handle, author.first, author.second)
    url = _geturl(handle.registry, "author",
                  Dict("identifier" => author.second))
    # Only a rehearsal leaves an author unregistered
    return something(url, _unregisteredauthor(author.first))
end

# ... as `_sourceauthorurl` finds it, but registering nothing and changing
# nothing in the handle: an author the registry has not got stands as one
# unregistered, which no registered file has
function _heldauthorurl(handle::DataRegistryHandle, name::AbstractString,
                        ::Nothing)
    return _authorurl(handle, name) do
        return _unregisteredauthor(name)
    end
end
function _heldauthorurl(handle::DataRegistryHandle, name::AbstractString,
                        identifier::AbstractString)
    author = _author(name, identifier)
    url = _geturl(handle.registry, "author",
                  Dict("identifier" => author.second))
    return something(url, _unregisteredauthor(author.first))
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
function _identity(source::Union{SourceRecord, _ComparedSource})
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

function _checksamesource(handle::DataRegistryHandle,
                          data_product::AbstractString,
                          described::OutputDescription)
    held = _outputsource(handle, data_product)
    (held isa OutputDescription &&
     all(getfield(held, field) == getfield(described, field)
         for field in fieldnames(OutputDescription))) ||
        throw(ReadWriteException("'$data_product' is already being written by this code run, described otherwise"))
    return nothing
end

# The source that a code run's link call gave for a data product it is
# writing, or the description of one with none; `nothing` with neither
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
to check, nor with an `OutputDescription`, which is no source.
"""
function _checkonefile(::DataRegistryHandle,
                       ::Union{Nothing, OutputDescription}, ::AbstractString,
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
        (key[1] == data_product || !(other isa SourceRecord)) && continue
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
                        object::AbstractDict,
                        source::Union{SourceRecord, _ComparedSource})
    url = get(data_product, "external_object", nothing)
    isnothing(url) && return false
    held = _getentry(registry, URIs.URI(url))
    (held["identifier"], held["title"], held["version"]) == _identity(source) ||
        return false
    return _recordsauthorship(registry, object, source.authors, source.licence)
end
# ... and a file described with no source, which the registered one must not
# have either
function _recordssource(registry::RegistryEndpoint, data_product::AbstractDict,
                        object::AbstractDict, described::OutputDescription)
    isnothing(get(data_product, "external_object", nothing)) || return false
    return _recordsauthorship(registry, object, described.authors,
                              described.licence)
end

# Whether a registered object has these authors, in any order, as the
# registry keeps them in none, and this licence alone, or none, a licence held
# as `_licence` would record it now
function _recordsauthorship(registry::RegistryEndpoint, object::AbstractDict,
                            authors::Vector{String},
                            licence::Union{Nothing, NamedTuple})
    sort(object["authors"]) == sort(authors) || return false
    licences = [_heldlicence(_getentry(registry, URIs.URI(licence_url)))
                for licence_url in object["licences"]]
    return licences == (isnothing(licence) ? [] : [licence])
end

# The authors of a registered file: its source's or its description's, or
# with neither the user
_fileauthors(registry::RegistryEndpoint, ::Nothing) = [_getauthorurl(registry)]
_fileauthors(::RegistryEndpoint, source::SourceRecord) = source.authors
function _fileauthors(::RegistryEndpoint, described::OutputDescription)
    return described.authors
end

"""
    _registersource(registry, source, data_product_url, object_url, hash,
                    public)

Register what `source` says of a data product that has just been registered:
where its file, of this `hash`, was fetched from; the source itself, which the
registry keeps once and links to each data product registered from it; and
the licence on the file's object. With no source nothing is registered.
"""
function _registersource(::RegistryEndpoint, ::Nothing, ::AbstractString,
                         ::AbstractString, ::Union{Nothing, AbstractString},
                         ::Bool)
    return nothing
end
# ... and for a file described with no source, its licence and keywords on its
# object
function _registersource(registry::RegistryEndpoint,
                         described::OutputDescription, ::AbstractString,
                         object_url::AbstractString,
                         ::Union{Nothing, AbstractString}, ::Bool)
    isnothing(described.licence) ||
        _createentry(registry, "licence",
                     Dict("object" => object_url,
                          "licence_info" => described.licence.info,
                          "identifier" => described.licence.identifier))
    _addkeywords!(registry, String(object_url), described.keywords)
    return nothing
end
function _registersource(registry::RegistryEndpoint, source::SourceRecord,
                         data_product_url::AbstractString,
                         object_url::AbstractString,
                         hash::Union{Nothing, AbstractString}, public::Bool)
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
function _originallocation(::RegistryEndpoint, ::Nothing,
                           ::Union{Nothing, AbstractString}, ::Bool)
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

# A file to be registered as coming from elsewhere, as its path and its hash,
# or `nothing` where there is no file
_externalfile(::Nothing) = nothing
function _externalfile(path::AbstractString)
    isfile(path) || throw(ReadWriteException("no file to register at $path"))
    return (path = String(path), hash = _getfilehash(path))
end

"""
    _linkregister!(handle, data_product, namespace, version, file, source,
                   supersede)

Register what `link_register!` describes - `file`, or `nothing` for a data
product with no file, and its source - as a version of `data_product` in
`namespace`, unless the version it comes to is registered so already; record
it as an input of the code run; and return the path of its file in the data
store, or `nothing`. `version` is the one asked for, or `nothing`.
"""
function _linkregister!(handle::DataRegistryHandle, data_product::String,
                        namespace::String, version::Union{Nothing, String},
                        file::Union{Nothing, NamedTuple}, source::SourceRecord,
                        supersede::Bool)
    registry = handle.registry
    hash = isnothing(file) ? nothing : file.hash
    isnothing(file) || _checkonefile(handle, source, hash, data_product)
    previous = supersede ?
               _latestdataproduct(registry, namespace, data_product) :
               nothing
    target = _registrationversion(registry, namespace, data_product, version,
                                  hash, source)
    key = (data_product, nothing)
    if haskey(handle.inputs, key) &&
       handle.inputs[key]["use_version"] != target.version
        throw(ReadWriteException("'$data_product' is already an input of this code run, as version $(handle.inputs[key]["use_version"])"))
    end
    product = target.held
    if isnothing(product)
        product = _registerexternal(handle, data_product, namespace,
                                    target.version, file, source)
    else
        println("data product unchanged: ", data_product, " (",
                target.version, ")")
    end
    supersede && _supersede!(handle, namespace, data_product, target.version,
                previous, !isnothing(target.held))

    if isnothing(product)
        # A rehearsal registered nothing: the input is the file as given
        stored = isnothing(file) ? nothing : file.path
        component_url = nothing
    else
        object = _getentry(registry, URIs.URI(product["object"]))
        stored = isnothing(object["storage_location"]) ? nothing :
                 _getstoragelocation(registry, product["object"]).path
        component_url = _wholeobjectcomponent(registry, product["object"])
    end
    handle.inputs[key] = Dict("use_dp" => data_product,
                              "use_namespace" => namespace,
                              "use_version" => target.version,
                              "use_component" => nothing,
                              "component_url" => component_url,
                              "path" => stored, "hash" => hash)
    return stored
end

# The version that a registration comes to, as `(version, held)`, `held` being
# the data product registered at it already when that is the one described,
# else `nothing`. With no version asked for: the highest version, if that is
# the one; else its next patch; and 0.0.1 for a name not yet registered.
function _registrationversion(registry::RegistryEndpoint, namespace::String,
                              data_product::String, ::Nothing,
                              hash::Union{Nothing, String},
                              source::SourceRecord)
    latest = _latestdataproduct(registry, namespace, data_product)
    isnothing(latest) && return (version = "0.0.1", held = nothing)
    _isregistration(registry, latest, hash, source) &&
        return (version = String(latest["version"]), held = latest)
    highest = VersionNumber(latest["version"])
    next = VersionNumber(highest.major, highest.minor, highest.patch + 1)
    return (version = string(next), held = nothing)
end
# ... and a version asked for, which if it is registered must be the one
function _registrationversion(registry::RegistryEndpoint, namespace::String,
                              data_product::String, version::String,
                              hash::Union{Nothing, String},
                              source::SourceRecord)
    namespace_id = _getid(registry, "namespace", Dict("name" => namespace))
    held = isnothing(namespace_id) ? nothing :
           _getentry(registry, "data_product",
                     Dict("name" => data_product, "version" => version,
                          "namespace" => namespace_id))
    isnothing(held) && return (version = version, held = nothing)
    _isregistration(registry, held, hash, source) &&
        return (version = version, held = held)
    return throw(ReadWriteException("version $version of $namespace:$data_product is registered already, with another file or another source, authors or licence: give another `version`, or none"))
end

# Whether a registered data product is the one a registration describes: with
# the file of this hash, or with none, and with the same source, authors and
# licence
function _isregistration(registry::RegistryEndpoint, product::AbstractDict,
                         hash::Union{Nothing, String}, source::SourceRecord)
    object = _getentry(registry, URIs.URI(product["object"]))
    location = object["storage_location"]
    if isnothing(hash)
        isnothing(location) || return false
    else
        isnothing(location) && return false
        _getentry(registry, URIs.URI(location))["hash"] == hash || return false
    end
    return _recordssource(registry, product, object, source)
end

# Register a version of a data product that comes from elsewhere: its object -
# its file put in the data store by its hash, or none - the data product, and
# its source. Return the data product's entry.
function _registerexternal(handle::DataRegistryHandle{RecordedRun},
                           data_product::String,
                           namespace::String, version::String,
                           file::Union{Nothing, NamedTuple},
                           source::SourceRecord)
    registry = handle.registry
    public = handle.config["run_metadata"]["public"]
    object_url = _externalobject(handle, namespace, data_product, file, source,
                                 public)
    namespace_url = _postentry(registry, "namespace",
                               Dict("name" => namespace))["url"]
    product = _createentry(registry, "data_product",
                           Dict("namespace" => namespace_url,
                                "name" => data_product, "object" => object_url,
                                "version" => version))
    _registersource(registry, source, product["url"], object_url,
                    isnothing(file) ? nothing : file.hash, public)
    return product
end

# The object of a data product that comes from elsewhere, described by its
# source's title and with its source's authors: with no file ...
function _externalobject(handle::DataRegistryHandle, ::String, ::String,
                         ::Nothing, source::SourceRecord, ::Bool)
    return _createentry(handle.registry, "object",
                        Dict("description" => source.title,
                             "authors" => source.authors))["url"]
end
# ... or with its file, under its hash, or where the store holds those bytes
function _externalobject(handle::DataRegistryHandle, namespace::String,
                         data_product::String, file::NamedTuple,
                         source::SourceRecord, public::Bool)
    registry = handle.registry
    datastore = handle.config["run_metadata"]["write_data_store"]
    held = _getentry(registry, "storage_location",
                     Dict("hash" => file.hash, "public" => public,
                          "storage_root" =>
                              _extractid(handle.datastore_obj_url)))
    if isnothing(held)
        stored = joinpath(datastore, namespace, data_product,
                          "$(file.hash).$(_extension(file.path))")
        mkpath(dirname(stored))
        _storedalready(stored, file.hash) ||
            _placefile(file.path, stored)
    else
        stored = joinpath(datastore, held["path"])
    end
    return _registerobject(registry, stored, datastore, source.title,
                           hash = file.hash, public = public, new_object = true,
                           authors = source.authors)["url"]
end
