# SPDX-License-Identifier: LGPL-3.0-or-later

# What was made from a data product: a walk forward over the registry's own
# entries, there being no report of that direction, into a trace of data
# products, runs and issues, printed as a tree.

function Base.show(io::IO, trace::Trace{Downstream})
    labels = join((_productlabel(trace.products[url]) for url in trace.roots),
                  ", ")
    made = [product
            for (url, product) in trace.products if !(url in trace.roots)]
    newest = count(product -> isnothing(product.superseded_by), made)
    return print(io, "Downstream of ", labels, ": ",
                 _counted(length(trace.runs), "run"), ", ",
                 _counted(length(made), "data product"), " made, ", newest,
                 " newest, ", _counted(length(trace.issues), "issue"))
end
function Base.show(io::IO, ::MIME"text/plain", trace::Trace{Downstream})
    readers = _readers(trace)
    seen = Set{String}()
    seen_runs = Set{String}()
    for (i, root) in enumerate(trace.roots)
        i > 1 && println(io)
        print(io, "Downstream of ")
        _printdownstream(io, trace, readers, root, 0, seen, seen_runs)
    end
    return nothing
end

# The runs of a trace that read each data product, earliest first
function _readers(trace::Trace)
    readers = Dict{String, Vector{TraceRun}}()
    for run in values(trace.runs), input in run.inputs
        push!(get!(Vector{TraceRun}, readers, input), run)
    end
    for runs in values(readers)
        sort!(runs, by = run -> (run.date, run.uuid))
    end
    return readers
end

# A data product's line of the tree, then its issues, then each run that read
# it with what the run made, each data product and each run expanded once
function _printdownstream(io::IO, trace::Trace,
                          readers::Dict{String, Vector{TraceRun}},
                          url::String, indent::Int, seen::Set{String},
                          seen_runs::Set{String})
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
    for run in get(readers, url, TraceRun[])
        print(io, " "^indent, "-> ", _runline(run))
        if run.url in seen_runs
            println(io, "  (above)")
            continue
        end
        push!(seen_runs, run.url)
        println(io)
        for issue in run.issues
            _printissue(io, trace.issues[issue], indent + 5)
        end
        for output in run.outputs
            print(io, " "^(indent + 3), "made ")
            _printdownstream(io, trace, readers, output, indent + 3, seen,
                             seen_runs)
        end
    end
    product.beyond &&
        println(io, " "^indent, "-> runs beyond depth ", trace.depth)
    return nothing
end

"""
    downstream(x; remote = nothing, depth = nothing)
    downstream(registry, x; depth = nothing)
    downstream(handle, x; depth = nothing)
    downstream(; repo, remote = nothing, commits = nothing, depth = nothing)
    downstream(registry; repo, commits = nothing, depth = nothing)
    downstream(handle; repo, commits = nothing, depth = nothing)

Trace what was made from a data product: the runs that read it, what they
wrote, the runs that read those, and so on to the end of every path. Return
a [`Trace`](@ref)`{Downstream}`, which prints as a tree, and holds every data
product, run and issue reached, keyed by registry URL. What must be made
again, now that a problem is known in the start, is every data product
reached that no newer version has superseded.

`x` names the start: a file, whose contents identify it as [`identify`](@ref)
does, every data product it is registered as being a root; or
`namespace:name@version`, as the pipeline names one, with `namespace:name`
meaning its newest version. With `repo`, the start is everything the runs of
a git repository wrote: the repository and `commits` are as `identify` takes
them, by the folder of a clone or the URL of its remote. The registry is the
one the FAIR CLI is configured to use, or the project's remote named by
`remote`, or `registry`, or the one `handle` was opened on; no token is
needed.

`depth` is how many runs forward along any path to go. By default the trace
goes to the end of every path; with `depth` given, a data product at that
depth that a run read is marked `beyond`, and the tree says so. Every data
product's line says whether a newer version of its name has been registered
since, and the issues raised on it.
"""
function downstream(registry::RegistryEndpoint, x::AbstractString;
                    depth::Union{Nothing, Integer} = nothing)
    _checkdepth(depth)
    return _downstream(registry, _traceroots(registry, String(x)), depth)
end
function downstream(handle::DataRegistryHandle, x::AbstractString;
                    depth::Union{Nothing, Integer} = nothing)
    return downstream(handle.registry, x; depth)
end
function downstream(x::AbstractString;
                    remote::Union{Nothing, AbstractString} = nothing,
                    depth::Union{Nothing, Integer} = nothing)
    return downstream(RegistryEndpoint(remote = remote), x; depth)
end
function downstream(registry::RegistryEndpoint; repo::AbstractString,
                    commits::Union{Nothing, AbstractString,
                                   AbstractCommitSelection} = nothing,
                    depth::Union{Nothing, Integer} = nothing)
    _checkdepth(depth)
    identification = identify(registry; repo, commits)
    roots = unique(product.url
                   for commit in identification.commits
                   for run in commit.runs for product in run.outputs)
    isempty(roots) &&
        throw(ReadWriteException("no registered run of $(identification.remote) from $(_describe(identification.selection)) wrote a data product"))
    return _downstream(registry, roots, depth)
end
function downstream(handle::DataRegistryHandle; repo::AbstractString,
                    commits::Union{Nothing, AbstractString,
                                   AbstractCommitSelection} = nothing,
                    depth::Union{Nothing, Integer} = nothing)
    return downstream(handle.registry; repo, commits, depth)
end
function downstream(; repo::AbstractString,
                    remote::Union{Nothing, AbstractString} = nothing,
                    commits::Union{Nothing, AbstractString,
                                   AbstractCommitSelection} = nothing,
                    depth::Union{Nothing, Integer} = nothing)
    return downstream(RegistryEndpoint(remote = remote); repo, commits, depth)
end

# == The walk ==

# The trace forward from `roots`, breadth first: each data product's readers,
# each reader's outputs, each data product once; a data product `depth` runs
# on is not walked, and is marked beyond when a run read it
function _downstream(registry::RegistryEndpoint, roots::Vector{String},
                     depth::Union{Nothing, Integer})
    parts = _TraceParts()
    for root in roots
        _productpart!(parts, registry, root)
    end
    queue = [(root, 0) for root in roots]
    visited = Set{String}()
    while !isempty(queue)
        url, level = popfirst!(queue)
        url in visited && continue
        push!(visited, url)
        readers = _readingruns(registry, parts, url)
        if !isnothing(depth) && level >= depth
            parts.products[url].checked = true
            parts.products[url].beyond = !isempty(readers)
            continue
        end
        for run_url in readers
            haskey(parts.runs, run_url) || _runpart!(parts, registry, run_url)
            run = parts.runs[run_url]
            url in run.inputs || push!(run.inputs, url)
            for output in _writtenproducts(registry, parts, run_url)
                _productpart!(parts, registry, output)
                parts.products[output].made_by = run_url
                output in run.outputs || push!(run.outputs, output)
                push!(queue, (output, level + 1))
            end
        end
    end
    return _buildtrace(Downstream, registry, parts, roots, depth)
end

# The runs that read any component of a data product's object
function _readingruns(registry::RegistryEndpoint, parts::_TraceParts,
                      product_url::String)
    product = _cached(registry, parts, product_url)
    object = _cached(registry, parts, product["object"])
    runs = String[]
    for component_url in object["components"]
        for run_url in _cached(registry, parts, component_url)["inputs_of"]
            run_url in runs || push!(runs, run_url)
        end
    end
    return runs
end

# The data products a run wrote: those of the objects its output components
# belong to
function _writtenproducts(registry::RegistryEndpoint, parts::_TraceParts,
                          run_url::String)
    run = _cached(registry, parts, run_url)
    products = String[]
    for component_url in run["outputs"]
        component = _cached(registry, parts, component_url)
        object = _cached(registry, parts, component["object"])
        for product_url in object["data_products"]
            product_url in products || push!(products, product_url)
        end
    end
    return products
end

# Where an object's file is, as the registry's root and path, and its hash;
# both `nothing` for an object with no file
function _objectfile(registry::RegistryEndpoint, parts::_TraceParts,
                     object::AbstractDict)
    isnothing(object["storage_location"]) && return (nothing, nothing)
    stored = _cached(registry, parts, object["storage_location"])
    root = _cached(registry, parts, stored["storage_root"])["root"]
    return (root * stored["path"], stored["hash"])
end

# The issues raised on any component of an object
function _componentissues(registry::RegistryEndpoint, parts::_TraceParts,
                          object::AbstractDict)
    issues = String[]
    for component_url in object["components"]
        for issue_url in _cached(registry, parts, component_url)["issues"]
            issue_url in issues || push!(issues, issue_url)
        end
    end
    return issues
end

# A data product's part from the registry's own entries, once
function _productpart!(parts::_TraceParts, registry::RegistryEndpoint,
                       url::String)
    haskey(parts.products, url) && return parts.products[url]
    product = _cached(registry, parts, url)
    namespace = _cached(registry, parts, product["namespace"])["name"]
    object = _cached(registry, parts, product["object"])
    location, hash = _objectfile(registry, parts, object)
    format = isnothing(object["file_type"]) ? nothing :
             _cached(registry, parts, object["file_type"])["extension"]
    source = isnothing(product["external_object"]) ? nothing :
             _sourcepart(registry, parts, product["external_object"])
    part = _ProductPart(url, namespace, product["name"],
                        VersionNumber(product["version"]), hash, location,
                        object["description"], format, source, nothing, false,
                        false, _componentissues(registry, parts, object))
    parts.products[url] = part
    return part
end

# A data product's source from its external object entry
function _sourcepart(registry::RegistryEndpoint, parts::_TraceParts,
                     url::String)
    external = _cached(registry, parts, url)
    location = nothing
    if !isnothing(external["original_store"])
        stored = _cached(registry, parts, external["original_store"])
        root = _cached(registry, parts, stored["storage_root"])["root"]
        location = root * stored["path"]
    end
    released = external["release_date"]
    return TraceSource(url, external["identifier"], external["title"],
                       external["version"],
                       isnothing(released) ? nothing :
                       DateTime(first(released, 19)), location,
                       external["primary_not_supplement"])
end

# A run's part from its entry, with the objects standing for its repository,
# config and script
function _runpart!(parts::_TraceParts, registry::RegistryEndpoint,
                   url::String)
    run = _cached(registry, parts, url)
    for (key, repository) in (("code_repo", true), ("model_config", false),
        ("submission_script", false))
        isnothing(run[key]) || _filepart!(parts, registry, run[key], repository)
    end
    part = _RunPart(url, DateTime(first(run["run_date"], 19)),
                    something(run["description"], ""), run["code_repo"],
                    run["model_config"], run["submission_script"], String[],
                    String[])
    parts.runs[url] = part
    return part
end

# The part of an object standing for a run's repository - whose file's hash
# is the commit - or its config or script, once
function _filepart!(parts::_TraceParts, registry::RegistryEndpoint,
                    url::String, repository::Bool)
    haskey(parts.files, url) && return parts.files[url]
    object = _cached(registry, parts, url)
    location, hash = _objectfile(registry, parts, object)
    part = _FilePart(url, location, repository ? nothing : hash,
                     repository ? hash : nothing, object["description"],
                     _componentissues(registry, parts, object))
    parts.files[url] = part
    return part
end
