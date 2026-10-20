# SPDX-License-Identifier: LGPL-3.0-or-later

# Where a data product came from: the registry's provenance report, read into
# a trace of data products, runs and issues, and printed as a tree.

"""
    AbstractTraceDirection

The direction a [`Trace`](@ref) was made in: [`Upstream`](@ref), back from a
data product through the runs that made it to what they read, or
[`Downstream`](@ref), forward through the runs that read it to what they made.
"""
abstract type AbstractTraceDirection end

"""
    Upstream()

The direction of the [`Trace`](@ref) that [`provenance`](@ref) makes: back
from a data product to what it was made from.
"""
struct Upstream <: AbstractTraceDirection end

"""
    Downstream()

The direction of the [`Trace`](@ref) that [`downstream`](@ref) makes: forward
from a data product to what was made from it.
"""
struct Downstream <: AbstractTraceDirection end

"""
    TraceSource

The source of a data product in a [`Trace`](@ref): the external object it was
registered from.

# Fields
- `url`: the external object's registry URL
- `identifier`: its DOI or other identifier, or `nothing`
- `title`: its title, or `nothing`
- `version`: the source's own release version, or `nothing`
- `date`: its release date, or `nothing`
- `location`: where the file was fetched from, or `nothing`
- `primary`: `true` when the registered bytes are the identified item or one
  of its files, `false` for a supplement requested or derived from it
"""
struct TraceSource
    url::String
    identifier::Union{Nothing, String}
    title::Union{Nothing, String}
    version::Union{Nothing, String}
    date::Union{Nothing, DateTime}
    location::Union{Nothing, String}
    primary::Bool
end

"""
    TraceRelease

The release of the code that a commit is, as a run in a [`Trace`](@ref), or a
commit that [`identify`](@ref) reports, was made from it; see
[`register_release!`](@ref).

# Fields
- `name`: the release's name, the path of the repository's remote, as
  `FAIRDataPipeline/DataPipeline.jl`
- `version`: its version, the highest the registry holds for the commit
- `website`: its web page, or `nothing`
- `doi`: the DOI it is cited by, as a URL, or `nothing`
"""
struct TraceRelease
    name::String
    version::VersionNumber
    website::Union{Nothing, String}
    doi::Union{Nothing, String}
end

function Base.show(io::IO, release::TraceRelease)
    print(io, release.name, " ", release.version)
    isnothing(release.doi) ||
        print(io, ", doi:",
              replace(release.doi, r"^https?://(dx\.)?doi\.org/" => ""))
    return nothing
end

"""
    TraceProduct

One version of a data product in a [`Trace`](@ref).

# Fields
- `url`: its registry URL, the key it has in the trace
- `namespace`, `name`, `version`: what names it
- `hash`: the SHA-1 of its file - for a code repository's release, its
  commit - or `nothing` for a data product with no file
- `location`: where the registry says the file is, or `nothing`
- `description`: its description, or `nothing`
- `format`: the extension of its file type, as `txt`, or `nothing`
- `source`: its [`TraceSource`](@ref), or `nothing` when it has none
- `superseded_by`: the highest version of its name in its namespace, when
  that is a newer one, else `nothing`
- `made_by`: the registry URL of the run in the trace that made it, or
  `nothing` when the trace holds none
- `beyond`: `true` when the trace was cut at this data product by its
  `depth`: a run that made it, going upstream, or that read it, going
  downstream, is not held
- `issues`: the registry URLs of the issues raised on it or its components
"""
struct TraceProduct
    url::String
    namespace::String
    name::String
    version::VersionNumber
    hash::Union{Nothing, String}
    location::Union{Nothing, String}
    description::Union{Nothing, String}
    format::Union{Nothing, String}
    source::Union{Nothing, TraceSource}
    superseded_by::Union{Nothing, VersionNumber}
    made_by::Union{Nothing, String}
    beyond::Bool
    issues::Vector{String}
end

"""
    TraceRun

A code run in a [`Trace`](@ref).

# Fields
- `url`: its registry URL, the key it has in the trace
- `uuid`: its uuid
- `date`: when it started, in UTC
- `description`: its description
- `repository`: the URL of the code repository it ran from, or `nothing`
- `commit`: the commit it ran at, `<sha>-dirty` for a working tree with
  uncommitted changes, or `nothing`
- `release`: the [`TraceRelease`](@ref) that commit is, or `nothing`
- `config`: where the registry says its working config is, or `nothing`
- `script`: where the registry says its submission script is, or `nothing`
- `inputs`: the registry URLs of the data products it read that the trace
  holds
- `outputs`: the registry URLs of the data products it wrote that the trace
  holds
- `objects`: the registry URLs of the objects that stand for its repository,
  config and script, those it has, which an issue on any of them names
- `issues`: the registry URLs of the issues raised on its repository, config
  or script
"""
struct TraceRun
    url::String
    uuid::String
    date::DateTime
    description::String
    repository::Union{Nothing, String}
    commit::Union{Nothing, String}
    release::Union{Nothing, TraceRelease}
    config::Union{Nothing, String}
    script::Union{Nothing, String}
    inputs::Vector{String}
    outputs::Vector{String}
    objects::Vector{String}
    issues::Vector{String}
end

"""
    TraceTarget

One thing a [`TraceIssue`](@ref) is raised on.

# Fields
- `url`: the registry URL of the data product, or of the object for a code
  repository, working config or submission script
- `label`: the data product as `namespace:name@vX.Y.Z`, else the object's
  description and where it is
- `component`: the named component the issue is on, or `nothing` for the
  whole thing
"""
struct TraceTarget
    url::String
    label::String
    component::Union{Nothing, String}
end

"""
    TraceIssue

An issue in a [`Trace`](@ref): a problem recorded in the registry against one
or more things, whether or not the trace holds them all.

# Fields
- `url`: its registry URL, the key it has in the trace
- `uuid`: its uuid
- `severity`: how bad it is, larger for worse
- `description`: what the problem is
- `targets`: everything it is raised on, as [`TraceTarget`](@ref)s
"""
struct TraceIssue
    url::String
    uuid::String
    severity::Int
    description::String
    targets::Vector{TraceTarget}
end

"""
    Trace{D <: AbstractTraceDirection}

What [`provenance`](@ref) and [`downstream`](@ref) return: the data products,
runs and issues reached from one or more data products in one direction, `D`,
each kept once by its registry URL. Printed as a tree from the roots.

# Fields
- `registry`: the [`RegistryEndpoint`](@ref) it was read from
- `roots`: the registry URLs of the data products it starts from
- `products`: every [`TraceProduct`](@ref) reached, by URL
- `runs`: every [`TraceRun`](@ref) reached, by URL
- `issues`: every [`TraceIssue`](@ref) raised on any of them, by URL
- `depth`: the number of runs along any path it was cut at, or `nothing`
  for a trace that reaches the end of every path
"""
struct Trace{D <: AbstractTraceDirection}
    registry::RegistryEndpoint
    roots::Vector{String}
    products::Dict{String, TraceProduct}
    runs::Dict{String, TraceRun}
    issues::Dict{String, TraceIssue}
    depth::Union{Nothing, Int}

    # The direction is not among the fields, so it must be written, and it
    # must be one direction: the methods that print and walk a trace are
    # defined for each
    function Trace{D}(registry::RegistryEndpoint, roots::Vector{String},
                      products::Dict{String, TraceProduct},
                      runs::Dict{String, TraceRun},
                      issues::Dict{String, TraceIssue},
                      depth::Union{Nothing, Int}) where {D <:
                                                         AbstractTraceDirection}
        isconcretetype(D) ||
            throw(ArgumentError("a trace is made in one direction, Trace{Upstream} or Trace{Downstream}, not Trace{$D}"))
        return new{D}(registry, roots, products, runs, issues, depth)
    end
end

function Base.show(io::IO, trace::Trace{Upstream})
    labels = join((_productlabel(trace.products[url]) for url in trace.roots),
                  ", ")
    return print(io, "Provenance of ", labels, ": ",
                 _counted(length(trace.runs), "run"), ", ",
                 _counted(length(trace.products), "data product"), ", ",
                 _counted(length(trace.issues), "issue"))
end
function Base.show(io::IO, ::MIME"text/plain", trace::Trace{Upstream})
    seen = Set{String}()
    for (i, root) in enumerate(trace.roots)
        i > 1 && println(io)
        print(io, "Provenance of ")
        _printupstream(io, trace, root, 0, seen)
    end
    return nothing
end

# "3 runs", "1 issue"
function _counted(n::Integer, noun::AbstractString)
    return string(n, " ", noun, n == 1 ? "" : "s")
end

# A data product's name as the tree prints it
function _productlabel(product::TraceProduct)
    return _dataproductname(product.namespace, product.name, product.version)
end

# What a data product's line of a tree says after its name: its file - a code
# repository's being its commit - whether a newer version exists, and its
# source, ending the line
function _printproductdetails(io::IO, product::TraceProduct)
    print(io, "  ",
          isnothing(product.hash) ? "no file" :
          product.description == REPOSITORY_DESCRIPTION ?
          "commit " * first(product.hash, 8) :
          "sha1 " * first(product.hash, 8))
    isnothing(product.superseded_by) ||
        print(io, "  superseded by v", product.superseded_by)
    source = product.source
    if !isnothing(source)
        print(io, "  from ",
              something(source.identifier, source.title, source.url),
              " (", source.primary ? "primary" : "supplement", ")")
    end
    return println(io)
end

# A data product's line of the tree: its name, its file, whether a newer
# version exists, and its source; then its issues, its run and what the run
# read, each data product expanded once
function _printupstream(io::IO, trace::Trace, url::String, indent::Int,
                        seen::Set{String})
    product = trace.products[url]
    print(io, _productlabel(product))
    if url in seen
        println(io, "  (above)")
        return nothing
    end
    push!(seen, url)
    _printproductdetails(io, product)
    for issue in product.issues
        _printissue(io, trace.issues[issue], indent + 4)
    end
    if !isnothing(product.made_by)
        run = trace.runs[product.made_by]
        println(io, " "^indent, "<- ", _runline(run))
        for issue in run.issues
            _printissue(io, trace.issues[issue], indent + 5)
        end
        for input in run.inputs
            print(io, " "^(indent + 3), "used ")
            _printupstream(io, trace, input, indent + 3, seen)
        end
    elseif product.beyond
        println(io, " "^indent, "<- a run beyond depth ", trace.depth)
    end
    return nothing
end

# A run's line of the tree: its uuid, when it ran, its repository at its
# commit, and the release that commit is
function _runline(run::TraceRun)
    line = string("run ", first(run.uuid, 8), " on ",
                  Dates.format(run.date, "yyyy-mm-dd HH:MM"), " UTC")
    isnothing(run.repository) && return line
    repository = replace(run.repository, r"^[a-z]+://" => "")
    commit = isnothing(run.commit) ? "" :
             string(" at ", first(run.commit, 8),
                    endswith(run.commit, "-dirty") ? "-dirty" : "")
    release = isnothing(run.release) ? "" : string(", ", run.release)
    return string(line, ", ", repository, commit, release)
end

# An issue's line of the tree, under the thing it is raised on
function _printissue(io::IO, issue::TraceIssue, indent::Int)
    return println(io, " "^indent, "issue, severity ", issue.severity, ": ",
                   issue.description)
end

"""
    provenance(x; remote = nothing, depth = nothing)
    provenance(registry, x; depth = nothing)
    provenance(handle, x; depth = nothing)

Trace where a data product came from: the run that made it, what that run
read, the runs that made those, and so on back to the data products that no
run made, each with its source. Return a [`Trace`](@ref)`{Upstream}`, which
prints as a tree, and holds every data product, run and issue reached, keyed
by registry URL.

`x` names the data product: a file, whose contents identify it as
[`identify`](@ref) does, every data product it is registered as being a root
of the trace; or `namespace:name@version`, as the pipeline names one, with
`namespace:name` meaning its newest version. The registry is the one the
FAIR CLI is configured to use, or the project's remote named by `remote`, or
`registry`, or the one `handle` was opened on; no token is needed.

`depth` is how many runs back along any path to go. By default the trace
goes to the end of every path, and a data product that no run made is a
root; with `depth` given, a data product at that depth that a run made is
marked `beyond`, and the tree says so.

Every data product's line says whether a newer version of its name has been
registered since, and the issues raised on it; an issue raised on several
things is one issue, with each of them among its targets.
"""
function provenance(registry::RegistryEndpoint, x::AbstractString;
                    depth::Union{Nothing, Integer} = nothing)
    _checkdepth(depth)
    roots = _traceroots(registry, String(x))
    return _upstream(registry, roots, depth)
end
function provenance(handle::DataRegistryHandle, x::AbstractString;
                    depth::Union{Nothing, Integer} = nothing)
    return provenance(handle.registry, x; depth)
end
function provenance(x::AbstractString;
                    remote::Union{Nothing, AbstractString} = nothing,
                    depth::Union{Nothing, Integer} = nothing)
    return registry_session(remote = remote) do registry
        return provenance(registry, x; depth)
    end
end

# `depth` is a number of runs, 1 or more, when given
function _checkdepth(depth::Union{Nothing, Integer})
    isnothing(depth) || depth >= 1 ||
        throw(ArgumentError("`depth` is a number of runs, 1 or more"))
    return nothing
end

# The data products a trace starts from: those a file is registered as, or
# the one a `namespace:name@version` names
function _traceroots(registry::RegistryEndpoint, x::String)
    if isfile(x)
        roots = [product.url
                 for object in _registeredobjects(registry, _getfilehash(x))
                 for product in object.data_products]
        isempty(roots) &&
            throw(ReadWriteException("$x is not registered as a data product in this registry"))
        return roots
    end
    named = try
        _parsedataproduct(x)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("no file at '$x', and it is not a data product name: $(err.msg)"))
    end
    if isnothing(named.version)
        entry = _latestdataproduct(registry, named.namespace, named.name)
        isnothing(entry) &&
            throw(ReadWriteException("no data product $x is registered in this registry"))
    else
        entry = _finddataproduct(registry, named.namespace, named.name,
                                 named.version)
    end
    return [entry["url"]]
end

# == Reading the report ==

# What the report says of a data product, a run and a file object (a code
# repository, a working config or a submission script) before the nodes are
# made: filled in as the report's relations are read
mutable struct _ProductPart
    url::String
    namespace::String
    name::String
    version::VersionNumber
    hash::Union{Nothing, String}
    location::Union{Nothing, String}
    description::Union{Nothing, String}
    format::Union{Nothing, String}
    source::Union{Nothing, TraceSource}
    made_by::Union{Nothing, String}
    beyond::Bool
    checked::Bool
    issues::Vector{String}
end
mutable struct _RunPart
    url::String
    date::DateTime
    description::String
    repository::Union{Nothing, String}
    config::Union{Nothing, String}
    script::Union{Nothing, String}
    inputs::Vector{String}
    outputs::Vector{String}
end
struct _FilePart
    url::String
    location::Union{Nothing, String}
    hash::Union{Nothing, String}
    commit::Union{Nothing, String}
    description::Union{Nothing, String}
    issues::Vector{String}
end

# Everything read from one or more reports, keyed by registry URL, with a
# cache of the registry's own entries fetched on the way
struct _TraceParts
    products::Dict{String, _ProductPart}
    runs::Dict{String, _RunPart}
    files::Dict{String, _FilePart}
    sources::Dict{String, TraceSource}
    cache::Dict{String, Any}
end
function _TraceParts()
    return _TraceParts(Dict{String, _ProductPart}(), Dict{String, _RunPart}(),
                       Dict{String, _FilePart}(), Dict{String, TraceSource}(),
                       Dict{String, Any}())
end

# A registry entry, fetched once
function _cached(registry::RegistryEndpoint, parts::_TraceParts, url::String)
    return get!(parts.cache, url) do
        return _getentry(registry, URIs.URI(url))
    end
end

# The registry's report for a data product, `depth` runs back
function _fetchreport(registry::RegistryEndpoint, product_url::String,
                      depth::Integer)
    url = string(registry.url, "prov-report/", _extractid(product_url),
                 "/?depth=", depth, "&format=json")
    return _getentry(registry, URIs.URI(url))
end

# The registry URL an entity key of the report names, `lreg:api/data_product/5`
# with `lreg` a prefix the report declares; and the table such a key names
function _reporturl(prefixes::AbstractDict, key::AbstractString)
    colon = findfirst(':', key)
    isnothing(colon) &&
        throw(ReadWriteException("the provenance report names '$key' with no prefix"))
    prefix = key[1:prevind(key, colon)]
    haskey(prefixes, prefix) ||
        throw(ReadWriteException("the provenance report names '$key' with a prefix it does not declare"))
    return string(prefixes[prefix], key[nextind(key, colon):end], "/")
end
_reporttable(key::AbstractString) = String(split(key, '/')[end - 1])

# An attribute of the report, which may be written as a value with a type;
# `nothing` where there is none
function _reportvalue(attributes::AbstractDict, name::AbstractString)
    value = get(attributes, name, nothing)
    return value isa AbstractDict ? value["\$"] : value
end

# A date the report writes, to the second, with the zone dropped
_reportdate(text::AbstractString) = DateTime(first(text, 19))

# The issues an entity of the report carries - one string, or a list of them,
# each packed as the description, the severity and the registry's id - as
# their registry URLs
function _reportissues(prefixes::AbstractDict, attributes::AbstractDict)
    packed = get(attributes, "fair:issue", nothing)
    isnothing(packed) && return String[]
    packed isa AbstractString && (packed = [packed])
    issues = String[]
    for text in packed
        found = match(r"^(.*) severity: (\d+) ID: (\d+)$"s, text)
        isnothing(found) &&
            throw(ReadWriteException("the provenance report writes an issue in a form this package does not read: '$text'"))
        push!(issues, _reporturl(prefixes, "lreg:api/issue/" * found[3]))
    end
    return issues
end

# Read one report into `parts`: its entities, then its relations. A data
# product already read keeps what it has, but a run that this report shows
# made it is recorded
function _readreport!(parts::_TraceParts, report::AbstractDict)
    prefixes = get(report, "prefix", Dict{String, Any}())
    sources = Dict{String, Dict{String, Any}}()
    for (key, attributes) in get(report, "entity", Dict())
        url = _reporturl(prefixes, key)
        table = _reporttable(key)
        if table == "data_product"
            haskey(parts.products, url) && continue
            haskey(attributes, "fair:namespace") ||
                throw(ReadWriteException("the provenance report is of a shape this package does not read: registry v1.4.0 or later is wanted"))
            parts.products[url] = _ProductPart(url,
                                               _reportvalue(attributes,
                                                            "fair:namespace"),
                                               _reportvalue(attributes,
                                                            "dcterms:title"),
                                               VersionNumber(_reportvalue(attributes,
                                                                          "dcat:hasVersion")),
                                               _reportvalue(attributes,
                                                            "fair:hash"),
                                               _reportvalue(attributes,
                                                            "prov:atLocation"),
                                               _reportvalue(attributes,
                                                            "dcterms:description"),
                                               _reportvalue(attributes,
                                                            "dcterms:format"),
                                               nothing, nothing, false, false,
                                               _reportissues(prefixes,
                                                             attributes))
        elseif table == "external_object"
            sources[url] = attributes
        elseif table == "object"
            haskey(parts.files, url) && continue
            parts.files[url] = _FilePart(url,
                                         _reportvalue(attributes,
                                                      "prov:atLocation"),
                                         _reportvalue(attributes, "fair:hash"),
                                         _reportvalue(attributes,
                                                      "fair:commit"),
                                         _reportvalue(attributes,
                                                      "dcterms:description"),
                                         _reportissues(prefixes, attributes))
        end
    end
    for (key, attributes) in get(report, "activity", Dict())
        url = _reporturl(prefixes, key)
        haskey(parts.runs, url) && continue
        parts.runs[url] = _RunPart(url,
                                   _reportdate(_reportvalue(attributes,
                                                            "prov:startTime")),
                                   something(_reportvalue(attributes,
                                                          "dcterms:description"),
                                             ""), nothing, nothing, nothing,
                                   String[], String[])
    end
    for relation in values(get(report, "wasGeneratedBy", Dict()))
        product = _reporturl(prefixes, relation["prov:entity"])
        run = _reporturl(prefixes, relation["prov:activity"])
        parts.products[product].made_by = run
        run in parts.runs[run].outputs ||
            push!(parts.runs[run].outputs, product)
    end
    for relation in values(get(report, "used", Dict()))
        run = parts.runs[_reporturl(prefixes, relation["prov:activity"])]
        entity = _reporturl(prefixes, relation["prov:entity"])
        role = _reportvalue(relation, "prov:role")
        if role == "fair:input_data"
            entity in run.inputs || push!(run.inputs, entity)
        elseif role == "fair:software"
            run.repository = entity
        elseif role == "fair:model_configuration"
            run.config = entity
        elseif role == "fair:submission_script"
            run.script = entity
        end
    end
    for (name, ends, primary) in (("wasDerivedFrom",
                                   ("prov:generatedEntity", "prov:usedEntity"),
                                   false),
                                  ("specializationOf",
                                   ("prov:specificEntity",
                                    "prov:generalEntity"),
                                   true))
        for relation in values(get(report, name, Dict()))
            first_url = _reporturl(prefixes, relation[ends[1]])
            second_url = _reporturl(prefixes, relation[ends[2]])
            # The source is whichever end is the external object
            if haskey(sources, second_url)
                product_url, source_url = first_url, second_url
            elseif haskey(sources, first_url)
                product_url, source_url = second_url, first_url
            else
                continue
            end
            haskey(parts.products, product_url) || continue
            attributes = sources[source_url]
            issued = _reportvalue(attributes, "dcterms:issued")
            parts.products[product_url].source = TraceSource(source_url,
                                                             _reportvalue(attributes,
                                                                          "dcterms:identifier"),
                                                             _reportvalue(attributes,
                                                                          "dcterms:title"),
                                                             _reportvalue(attributes,
                                                                          "dcat:hasVersion"),
                                                             isnothing(issued) ?
                                                             nothing :
                                                             _reportdate(issued),
                                                             _reportvalue(attributes,
                                                                          "prov:atLocation"),
                                                             primary)
        end
    end
    return parts
end

# == Building the trace ==

# The trace back from `roots`: each root's report, read `asked` runs back,
# then the data products at that depth that the report shows no run for
# asked whether a run made them - fetched from in turn when the trace is to
# reach the end of every path, else marked as beyond its depth
function _upstream(registry::RegistryEndpoint, roots::Vector{String},
                   depth::Union{Nothing, Integer})
    asked = isnothing(depth) ? 100 : Int(depth)
    parts = _TraceParts()
    pending = copy(roots)
    while !isempty(pending)
        start = popfirst!(pending)
        _readreport!(parts, _fetchreport(registry, start, asked))
        for url in _frontier(parts, start, asked)
            part = parts.products[url]
            part.checked = true
            _madebyarun(registry, parts, part) || continue
            if isnothing(depth)
                push!(pending, url)
            else
                part.beyond = true
            end
        end
    end
    return _buildtrace(Upstream, registry, parts, roots, depth)
end

# The data products `asked` runs back from `start` that no run in the parts
# made and that have not been asked about: where a report may have been cut
function _frontier(parts::_TraceParts, start::String, asked::Int)
    frontier = String[]
    level = Dict(start => 0)
    queue = [start]
    while !isempty(queue)
        url = popfirst!(queue)
        part = parts.products[url]
        if isnothing(part.made_by)
            level[url] == asked && !part.checked && push!(frontier, url)
            continue
        end
        for input in parts.runs[part.made_by].inputs
            haskey(level, input) && continue
            level[input] = level[url] + 1
            push!(queue, input)
        end
    end
    return frontier
end

# Whether a run made this data product: its whole-object component is an
# output of one
function _madebyarun(registry::RegistryEndpoint, parts::_TraceParts,
                     part::_ProductPart)
    product = _cached(registry, parts, part.url)
    component = _getentry(registry, "object_component",
                          Dict("object" => _extractid(product["object"]),
                               "whole_object" => true))
    return !isnothing(component) && !isempty(component["outputs_of"])
end

# The trace from its parts: runs given their uuids, data products the version
# that supersedes them, issues their targets
function _buildtrace(::Type{D}, registry::RegistryEndpoint,
                     parts::_TraceParts, roots::Vector{String},
                     depth::Union{Nothing, Integer}) where {D <:
                                                            AbstractTraceDirection}
    runs = Dict{String, TraceRun}()
    for (url, part) in parts.runs
        part.repository = _repositoryobject(registry, parts, part.repository)
        entry = _cached(registry, parts, url)
        objects = [file
                   for file in (part.repository, part.config, part.script)
                   if !isnothing(file)]
        files = [parts.files[file] for file in objects]
        repository = isnothing(part.repository) ? nothing :
                     parts.files[part.repository]
        runs[url] = TraceRun(url, entry["uuid"], part.date, part.description,
                             isnothing(repository) ? nothing :
                             repository.location,
                             isnothing(repository) ? nothing :
                             repository.commit,
                             isnothing(part.repository) ? nothing :
                             _cachedrelease(registry, parts, part.repository),
                             isnothing(part.config) ? nothing :
                             parts.files[part.config].location,
                             isnothing(part.script) ? nothing :
                             parts.files[part.script].location,
                             sort(part.inputs), sort(part.outputs), objects,
                             unique(reduce(vcat,
                                           (file.issues for file in files),
                                           init = String[])))
    end
    products = Dict{String, TraceProduct}()
    for (url, part) in parts.products
        products[url] = TraceProduct(url, part.namespace, part.name,
                                     part.version, part.hash, part.location,
                                     part.description,
                                     _formatextension(registry, parts,
                                                      part.format),
                                     part.source,
                                     _supersedingversion(registry, part),
                                     part.made_by, part.beyond, part.issues)
    end
    issues = Dict{String, TraceIssue}()
    for url in Iterators.flatten((product.issues
                                  for product in values(products)))
        haskey(issues, url) || (issues[url] = _traceissue(registry, parts, url))
    end
    for url in Iterators.flatten((run.issues for run in values(runs)))
        haskey(issues, url) || (issues[url] = _traceissue(registry, parts, url))
    end
    return Trace{D}(registry, roots, products, runs, issues,
                    isnothing(depth) ? nothing : Int(depth))
end

# The object of a run's code repository: the report names it by its release
# record where the object carries one, which is read for the object it is on
_repositoryobject(::RegistryEndpoint, ::_TraceParts, ::Nothing) = nothing
function _repositoryobject(registry::RegistryEndpoint, parts::_TraceParts,
                           url::String)
    occursin(r"/code_repo_release/\d+/$", url) || return url
    object_url = _cached(registry, parts, url)["object"]
    _filepart!(parts, registry, object_url, true)
    return object_url
end

# The release a run's repository object stands for, found once for each object
function _cachedrelease(registry::RegistryEndpoint, parts::_TraceParts,
                        url::String)
    return get!(parts.cache, "release of " * url) do
        return _objectrelease(_cached(registry, parts, url)) do entry_url
            return _cached(registry, parts, entry_url)
        end
    end
end

# The release of the code that a repository's object at a commit stands for,
# or `nothing`: the highest version among the data products on it, with its
# source's DOI, named by the release record where there is one and else by the
# data product; `fetch(url)` gives a registry entry
function _objectrelease(fetch::Function, object::AbstractDict)
    record_url = get(object, "code_repo_release", nothing)
    record = isnothing(record_url) ? nothing : fetch(record_url)
    products = [fetch(url) for url in get(object, "data_products", [])]
    if isempty(products)
        isnothing(record) && return nothing
        return TraceRelease(record["name"], VersionNumber(record["version"]),
                            record["website"], nothing)
    end
    highest = argmax(product -> VersionNumber(product["version"]), products)
    version = VersionNumber(highest["version"])
    source = highest["external_object"]
    doi = isnothing(source) ? nothing : fetch(source)["identifier"]
    name = isnothing(record) ?
           string(fetch(highest["namespace"])["name"], "/", highest["name"]) :
           record["name"]
    # The record's page is of its version, which a promoted beta's is not
    website = !isnothing(record) &&
              VersionNumber(record["version"]) == version ? record["website"] :
              nothing
    return TraceRelease(name, version, website, doi)
end

# A file type's extension: the report names a file type by its name, which
# the registry's own catalogue writes in words (a CSV file is "Comma-Separated
# Values File"), so a name the registry has a file type for becomes that
# type's extension, and anything else - an extension already - stays
function _formatextension(registry::RegistryEndpoint, parts::_TraceParts,
                          format::Union{Nothing, String})
    isnothing(format) && return nothing
    key = "file_type name: " * format
    return get!(parts.cache, key) do
        types = _getentries(registry, "file_type", Dict("name" => format))
        return isempty(types) ? format : String(first(types)["extension"])
    end
end

# The highest version of the data product's name in its namespace, when it
# is a newer one than this
function _supersedingversion(registry::RegistryEndpoint, part::_ProductPart)
    newest = _latestdataproduct(registry, part.namespace, part.name)
    isnothing(newest) && return nothing
    version = VersionNumber(newest["version"])
    return version > part.version ? version : nothing
end

# An issue as the registry holds it, with everything it is raised on
function _traceissue(registry::RegistryEndpoint, parts::_TraceParts,
                     url::String)
    entry = _cached(registry, parts, url)
    targets = TraceTarget[]
    for component_url in entry["component_issues"]
        component = _cached(registry, parts, component_url)
        name = component["whole_object"] ? nothing : String(component["name"])
        object = _cached(registry, parts, component["object"])
        # A code repository's object is the code of its runs whatever release
        # data products it carries, and is named as code as well
        if isempty(object["data_products"]) ||
           object["description"] == REPOSITORY_DESCRIPTION
            push!(targets,
                  TraceTarget(object["url"],
                              _objectlabel(registry, parts, object),
                              name))
        end
        if !isempty(object["data_products"])
            for product_url in object["data_products"]
                product = _cached(registry, parts, product_url)
                namespace = _cached(registry, parts, product["namespace"])["name"]
                push!(targets,
                      TraceTarget(product_url,
                                  _dataproductname(namespace, product["name"],
                                                   product["version"]), name))
            end
        end
    end
    return TraceIssue(url, entry["uuid"], entry["severity"],
                      entry["description"], targets)
end

# How an object that is no data product - a code repository, a working config
# or a submission script - is named among an issue's targets: its
# description, and where it is, a repository with its commit
function _objectlabel(registry::RegistryEndpoint, parts::_TraceParts,
                      object::AbstractDict)
    description = something(object["description"], "object")
    isnothing(object["storage_location"]) && return description
    location = _cached(registry, parts, object["storage_location"])
    root = _cached(registry, parts, location["storage_root"])
    return string(description, " ", root["root"], location["path"], ", ",
                  location["hash"])
end
