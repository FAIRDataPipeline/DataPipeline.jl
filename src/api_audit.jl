# SPDX-License-Identifier: LGPL-3.0-or-later

# Asking the registry what it knows about a file or a git repository on disk,
# and what lies behind a file.

"""
    IssueRecord

A problem recorded against something a file is registered as.

# Fields
- `severity`: how bad it is, as the registry holds it (larger is worse)
- `description`: what the problem is
- `component`: the name of the object component it was raised against, or
  `nothing` when raised against the file as a whole
- `url`: its registry URL
- `uuid`: its uuid

An `IssueRecord` names the issue to [`downstream`](@ref), as its `issue`.
"""
struct IssueRecord
    severity::Int
    description::String
    component::Union{Nothing, String}
    url::String
    uuid::String
end

function Base.show(io::IO, issue::IssueRecord)
    where_ = isnothing(issue.component) ? "whole file" : issue.component
    return print(io, "issue (severity ", issue.severity, ") on ", where_, ": ",
                 issue.description)
end

"""
    DataProductRecord

A data product a file is registered as.

# Fields
- `namespace`: the namespace it is registered in
- `name`: its registered name
- `version`: the version this file is
- `newest`: the newest version of the same name in the same namespace, which
  is `version` itself unless the registry holds a later one
- `url`: its URL in the registry
- `external_object`: the URL of its external object record, if it came from
  outside the pipeline, else `nothing`
"""
struct DataProductRecord
    namespace::String
    name::String
    version::VersionNumber
    newest::VersionNumber
    url::String
    external_object::Union{Nothing, String}
end

function Base.show(io::IO, dp::DataProductRecord)
    print(io, _dataproductname(dp.namespace, dp.name, dp.version))
    dp.version < dp.newest && print(io, " (superseded by v", dp.newest, ")")
    return nothing
end

"""
    RegisteredObject

One registry object a file is registered as: its description, where the
registry expects to find it, what data products it serves and what problems
are recorded against it. An object with no data products is one of a code
run's own files - a working config, a submission script or a repository.

# Fields
- `description`: the object's description
- `url`: the object's URL in the registry
- `root`: the storage root the file is registered under
- `local_root`: whether that root is on this machine
- `stored_path`: the file's path within that root
- `data_products`: the [`DataProductRecord`](@ref)s it serves, if any
- `issues`: the [`IssueRecord`](@ref)s against it and its components
"""
struct RegisteredObject
    description::String
    url::String
    root::String
    local_root::Bool
    stored_path::String
    data_products::Vector{DataProductRecord}
    issues::Vector{IssueRecord}
end

function Base.show(io::IO, obj::RegisteredObject)
    print(io,
          isempty(obj.data_products) ? obj.description :
          join(sprint.(show, obj.data_products), ", "))
    isempty(obj.issues) || print(io, ", ", length(obj.issues), " issue",
          length(obj.issues) == 1 ? "" : "s")
    return nothing
end

"""
    UpstreamIssue

An issue [`identify`](@ref) found behind a file: raised on something a run on
the way to the file read, at the version it read, or on a run's own code
repository, working config or submission script.

# Fields
- `issue`: the [`TraceIssue`](@ref)
- `on`: the [`TraceTarget`](@ref) of the issue that lies upstream of the file
- `through`: the [`TraceRun`](@ref) it reaches the file through - the run
  that read the thing, or whose own file it is
- `making`: the [`TraceProduct`](@ref) that run made on the way to the file
- `input`: `true` when the thing is a data product the run read, `false`
  when it is the run's repository, config or script
"""
struct UpstreamIssue
    issue::TraceIssue
    on::TraceTarget
    through::TraceRun
    making::TraceProduct
    input::Bool
end

function Base.show(io::IO, found::UpstreamIssue)
    print(io, "severity ", found.issue.severity, " on ", found.on.label)
    isnothing(found.on.component) || print(io, " (", found.on.component, ")")
    return print(io, ": ", found.issue.description)
end

"""
    OutdatedInput

A data product read on the way to a file, as [`identify`](@ref) finds with
`superseded = true`, that a newer version of has been registered since.

# Fields
- `input`: the [`TraceProduct`](@ref) read, with `superseded_by` the newer
  version
- `through`: the [`TraceRun`](@ref) that read it
- `making`: the [`TraceProduct`](@ref) that run made on the way to the file
"""
struct OutdatedInput
    input::TraceProduct
    through::TraceRun
    making::TraceProduct
end

function Base.show(io::IO, outdated::OutdatedInput)
    return print(io, _productlabel(outdated.input), ", superseded by v",
                 outdated.input.superseded_by)
end

# How an upstream thing reaches the file: the run, and what it made on the way
function _throughline(through::TraceRun, making::TraceProduct, input::Bool)
    return string(input ? "used by " : "in ", "run ", first(through.uuid, 8),
                  " on ", Dates.format(through.date, "yyyy-mm-dd HH:MM"),
                  ", which made ", _productlabel(making))
end

"""
    FileIdentification

What a registry knows about one file on disk, as returned by
[`identify`](@ref). `objects` is empty when the registry has never been told
about a file with these contents.

# Fields
- `path`: the file asked about
- `hash`: its SHA-1, which is how the registry identifies it
- `objects`: the [`RegisteredObject`](@ref)s registered with that hash
- `provenance`: the [`Trace`](@ref) back from every data product the file is
  registered as, or `nothing` for a file the registry does not know
- `upstream`: every [`UpstreamIssue`](@ref) the trace finds, nearest the
  file first
- `outdated`: every [`OutdatedInput`](@ref) the trace finds, when asked for
  with `superseded = true`, else `nothing`
"""
struct FileIdentification
    path::String
    hash::String
    objects::Vector{RegisteredObject}
    provenance::Union{Nothing, Trace{Upstream}}
    upstream::Vector{UpstreamIssue}
    outdated::Union{Nothing, Vector{OutdatedInput}}
end

function Base.show(io::IO, id::FileIdentification)
    isempty(id.objects) && return print(io, basename(id.path), ": unknown")
    print(io, basename(id.path), ": ", join(sprint.(show, id.objects), "; "))
    isempty(id.upstream) ||
        print(io, "; ", _counted(length(id.upstream), "upstream issue"))
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", id::FileIdentification)
    println(io, id.path)
    println(io, "  sha1: ", id.hash)
    if isempty(id.objects)
        return print(io, "  not registered in this registry")
    end
    for obj in id.objects
        println(io, "  registered as:")
        println(io, "    description: ", obj.description)
        println(io, "    stored:      ", obj.root, obj.stored_path,
                obj.local_root ? "" : " (not on this machine)")
        for dp in obj.data_products
            println(io, "    data product: ", dp.namespace, ":", dp.name)
            println(io, "      version:   ", dp.version,
                    dp.version < dp.newest ?
                    " - SUPERSEDED, newest is $(dp.newest)" : " (newest)")
            isnothing(dp.external_object) ||
                println(io, "      external object: ", dp.external_object)
        end
        for issue in obj.issues
            println(io, "    ", issue)
        end
    end
    if isempty(id.upstream)
        println(io, "  upstream: no issues")
    else
        println(io, "  upstream: ", _counted(length(id.upstream), "issue"))
        for found in id.upstream
            println(io, "    ", found)
            println(io, "      ",
                    _throughline(found.through, found.making, found.input))
        end
    end
    if !isnothing(id.outdated)
        if isempty(id.outdated)
            println(io, "  outdated inputs: none")
        else
            println(io, "  outdated inputs: ", length(id.outdated))
            for outdated in id.outdated
                println(io, "    ", outdated)
                println(io, "      ",
                        _throughline(outdated.through, outdated.making, true))
            end
        end
    end
    return nothing
end

"""
    AbstractCommitSelection

Which commits of a git repository [`identify`](@ref) reports, and whether it
includes the runs made from them with uncommitted changes, which the registry
records as `<sha>-dirty`: [`AncestorCommits`](@ref), [`CheckedOutCommit`](@ref)
or [`AllCommits`](@ref). Each has a `dirty` field saying which, set by its
constructor's `dirty` keyword.
"""
abstract type AbstractCommitSelection end

"""
    AncestorCommits(; dirty = false)

Select the checked-out commit and every commit it descends from - the code the
checkout grew from - and, if `dirty`, the runs made from them with uncommitted
changes too. What [`identify`](@ref) reports for a repository unless told
otherwise.
"""
struct AncestorCommits <: AbstractCommitSelection
    dirty::Bool

    AncestorCommits(; dirty::Bool = false) = new(dirty)
end

"""
    CheckedOutCommit(; dirty = false)

Select only the checked-out commit and, if `dirty`, the runs made from it with
uncommitted changes too.
"""
struct CheckedOutCommit <: AbstractCommitSelection
    dirty::Bool

    CheckedOutCommit(; dirty::Bool = false) = new(dirty)
end

"""
    AllCommits(; dirty = false)

Select every commit of the repository that the registry holds runs for,
whether or not the local clone has it, and, if `dirty`, the runs made from them
with uncommitted changes too.
"""
struct AllCommits <: AbstractCommitSelection
    dirty::Bool

    AllCommits(; dirty::Bool = false) = new(dirty)
end

"""
    NamedCommit(name; dirty = false)

Select one commit by name: a full commit hash, as it is; a tag, a branch or an
abbreviated hash, resolved by the local clone; or the version of a release of
the code that the registry holds, with or without a leading `v`, which
resolves with no clone at all. A `String` given as `commits` means this. If
`dirty`, the runs made from the commit with uncommitted changes too.
"""
struct NamedCommit <: AbstractCommitSelection
    name::String
    dirty::Bool

    function NamedCommit(name::AbstractString; dirty::Bool = false)
        return new(String(name), dirty)
    end
end

function Base.show(io::IO, selection::AbstractCommitSelection)
    return print(io, nameof(typeof(selection)),
                 selection.dirty ? "(dirty = true)" : "()")
end
function Base.show(io::IO, selection::NamedCommit)
    print(io, "NamedCommit(", repr(selection.name))
    selection.dirty && print(io, ", dirty = true")
    return print(io, ")")
end

# What `commits` names: a selection as given, a string the commit so named
_asselection(selection::AbstractCommitSelection) = selection
_asselection(name::AbstractString) = NamedCommit(name)

"""
    CodeRunRecord

A code run the registry holds.

# Fields
- `uuid`: its uuid, by which `fair` and `coderuns.txt` refer to it
- `run_date`: when it ran, as the registry records it
- `description`: its description
- `url`: its URL in the registry
- `outputs`: the [`DataProductRecord`](@ref)s it wrote
"""
struct CodeRunRecord
    uuid::String
    run_date::DateTime
    description::String
    url::String
    outputs::Vector{DataProductRecord}
end

function Base.show(io::IO, run::CodeRunRecord)
    return print(io, "run ", first(run.uuid, 8), " (", run.run_date, "): ",
                 run.description)
end

"""
    RegisteredCommit

A commit of a git repository that the registry holds runs for.

# Fields
- `sha`: the commit's hash
- `dirty`: whether its runs were made from a working tree with uncommitted
  changes, which the registry records as `<sha>-dirty`
- `date`: its commit date, or `nothing` when the local clone does not have it
- `objects`: the URLs of the registry objects that stand for it
- `runs`: the [`CodeRunRecord`](@ref)s made from it, newest first
- `issues`: the [`IssueRecord`](@ref)s raised against it
"""
struct RegisteredCommit
    sha::String
    dirty::Bool
    date::Union{Nothing, DateTime}
    objects::Vector{String}
    runs::Vector{CodeRunRecord}
    issues::Vector{IssueRecord}
end

function Base.show(io::IO, commit::RegisteredCommit)
    print(io, first(commit.sha, 10), commit.dirty ? "-dirty" : "", ": ",
          length(commit.runs), " run", length(commit.runs) == 1 ? "" : "s")
    isempty(commit.issues) || print(io, ", ", length(commit.issues), " issue",
          length(commit.issues) == 1 ? "" : "s")
    return nothing
end

"""
    RepositoryIdentification

What a registry knows about a git repository, as returned by
[`identify`](@ref). `commits` is empty when no run was made from any of the
commits selected.

# Fields
- `path`: the repository's top-level folder, or its URL when it was named by
  that alone
- `remote`: the URL of the git remote the registry knows it by
- `head`: the checked-out commit, or `nothing` with no clone
- `dirty`: whether the working tree has uncommitted changes to tracked files;
  `false` with no clone
- `selection`: the [`AbstractCommitSelection`](@ref) asked for
- `commits`: the [`RegisteredCommit`](@ref)s selected, newest commit first;
  those the local clone does not have come last, newest first by their
  earliest run
"""
struct RepositoryIdentification
    path::String
    remote::String
    head::Union{Nothing, String}
    dirty::Bool
    selection::AbstractCommitSelection
    commits::Vector{RegisteredCommit}
end

function Base.show(io::IO, id::RepositoryIdentification)
    runs = sum(length(commit.runs) for commit in id.commits; init = 0)
    return print(io, basename(id.path), ": ", length(id.commits), " commit",
                 length(id.commits) == 1 ? "" : "s", " registered, ", runs,
                 " run", runs == 1 ? "" : "s")
end

function Base.show(io::IO, ::MIME"text/plain", id::RepositoryIdentification)
    println(io, id.path)
    println(io, "  remote:      ", id.remote)
    if isnothing(id.head)
        println(io, "  no clone: the registry's record alone")
    else
        println(io, "  checked out: ", id.head,
                id.dirty ? " (with uncommitted changes)" : "")
    end
    println(io, "  selected:    ", _describe(id.selection),
            id.selection.dirty ? ", with runs made with uncommitted changes" :
            "")
    isempty(id.commits) && return print(io, "  no run registered from them")
    for commit in id.commits
        println(io, "  commit ", commit.sha, commit.dirty ? "-dirty" : "",
                isnothing(commit.date) ? ", not in this clone" :
                ", committed $(commit.date)",
                commit.sha == id.head ? " (checked out)" : "")
        for issue in commit.issues
            println(io, "    issue (severity ", issue.severity, "): ",
                    issue.description)
        end
        for run in commit.runs
            println(io, "    ", run)
            for output in run.outputs
                println(io, "      output: ", output)
            end
        end
    end
    return nothing
end

# == Functions ==

# How a commit selection reads in a report
_describe(::AncestorCommits) = "the checked-out commit and its ancestors"
_describe(::CheckedOutCommit) = "the checked-out commit"
_describe(::AllCommits) = "every commit of the repository"
_describe(selection::NamedCommit) = "the commit named $(repr(selection.name))"

# The issues recorded against an object's components, naming the component
# unless it stands for the whole file
function _objectissues(registry::RegistryEndpoint, object::AbstractDict)
    issues = IssueRecord[]
    for component_url in object["components"]
        component = _getentry(registry, URIs.URI(component_url))
        name = component["whole_object"] ? nothing : String(component["name"])
        for issue_url in component["issues"]
            issue = _getentry(registry, URIs.URI(issue_url))
            push!(issues,
                  IssueRecord(issue["severity"], issue["description"], name,
                              issue["url"], issue["uuid"]))
        end
    end
    return issues
end

# A data product, with the newest version of the same name in its namespace
function _dataproductrecord(registry::RegistryEndpoint, url::String)
    entry = _getentry(registry, URIs.URI(url))
    namespace = _getentry(registry, URIs.URI(entry["namespace"]))["name"]
    versions = [VersionNumber(other["version"])
                for other in _getentries(registry, "data_product",
                                         Dict("name" => entry["name"],
                                              "namespace" =>
                                                  _extractid(entry["namespace"])))]
    version = VersionNumber(entry["version"])
    return DataProductRecord(namespace, entry["name"], version,
                             maximum(versions, init = version), entry["url"],
                             entry["external_object"])
end

"""
    identify(path; remote = nothing, superseded = false)
    identify(registry, path; superseded = false)
    identify(handle, path; superseded = false)
    identify(; repo, remote = nothing, commits = AncestorCommits())
    identify(registry; repo, commits = AncestorCommits())
    identify(handle; repo, commits = AncestorCommits())

Ask a registry what it knows about a file, or about a git repository, on
disk.

For a **file**, return a [`FileIdentification`](@ref): the data products it is
registered as, where the registry expects to find it, whether a newer version
of any of those data products exists, the issues raised against it, and the
issues raised on anything behind it - the inputs read on the way to it, at
the versions read, and the code, config and script of the runs on the way -
each with the run it reaches the file through. With `superseded = true`, the
inputs read on the way that a newer version of has been registered since are
reported too, as outdated rather than wrong. `isempty(result.objects)` means
the registry has no record of a file with these contents. The file is
identified by the SHA-1 of its contents, as everything in the pipeline is, so
a copy under another name is recognised and an edited file is not.

For a **git repository**, named by the path of its top-level folder as
`repo`, return a [`RepositoryIdentification`](@ref): the code runs made from
its commits, with their outputs, and any issues raised against those commits.
The repository is known to the registry by the URL of its git remote - the
one named by `git.remote` in its `.fair/cli-config.yaml`, else `origin` - and
`commits` chooses which of its commits to report. Runs made with uncommitted
changes are included only when `commits` is given `dirty = true`. When the
checkout itself has uncommitted changes, `AncestorCommits` and
`CheckedOutCommit` warn and use its commit as committed.

# Arguments
- `path::String`: the file to ask about.
- `repo`: the git repository to ask about: the top-level folder of a clone,
  or the URL of its remote, which asks the registry's record alone. Any other
  folder is an `ArgumentError`, including one inside a repository.
- `registry::RegistryEndpoint`: the registry to ask, which needs no token,
  e.g. `RegistryEndpoint("http://127.0.0.1:8000/api/")`; a
  `DataRegistryHandle` may be given instead, and its registry is used.
- `remote`: with no registry given, the registry is the CLI's local registry,
  or the remote registry of that name in the current project's CLI
  configuration; see [`RegistryEndpoint`](@ref).
- `superseded`: for a file, whether to report the inputs behind it that have
  been superseded.
- `commits`: for a repository, [`AncestorCommits()`](@ref AncestorCommits)
  (the default with a clone), [`CheckedOutCommit()`](@ref CheckedOutCommit),
  [`AllCommits()`](@ref AllCommits) (the default by URL) or a commit by name -
  a tag, a branch, a commit hash or the version of a registered release of
  the code, as a string or as [`NamedCommit`](@ref) - each optionally with
  `dirty = true`. By URL there is no clone, so the checked-out commit and its
  ancestors are an `ArgumentError`, and a name resolves only as a full hash
  or a registered release.
"""
function identify(registry::RegistryEndpoint, path::String;
                  commits::Union{Nothing, AbstractString,
                                 AbstractCommitSelection} = nothing,
                  superseded::Bool = false)
    if isfile(path)
        isnothing(commits) ||
            throw(ArgumentError("`commits` selects commits of a git repository, and $path is a file"))
        return _identifyfile(registry, path; superseded)
    end
    isdir(path) || throw(ReadWriteException("no file or folder at $path"))
    # A repository named by position: deprecated in 0.55.0, named by `repo`
    Base.depwarn("`identify(folder)` is deprecated: name a git repository by `identify(repo = folder)`",
                 :identify)
    return identify(registry; repo = path, commits)
end
function identify(handle::DataRegistryHandle, path::String;
                  commits::Union{Nothing, AbstractString,
                                 AbstractCommitSelection} = nothing,
                  superseded::Bool = false)
    return identify(handle.registry, path; commits, superseded)
end
function identify(path::String;
                  remote::Union{Nothing, AbstractString} = nothing,
                  commits::Union{Nothing, AbstractString,
                                 AbstractCommitSelection} = nothing,
                  superseded::Bool = false)
    return identify(RegistryEndpoint(remote = remote), path; commits,
                    superseded)
end
function identify(registry::RegistryEndpoint; repo::AbstractString,
                  commits::Union{Nothing, AbstractString,
                                 AbstractCommitSelection} = nothing)
    return _identifyrepository(registry, String(repo), commits)
end
function identify(handle::DataRegistryHandle; repo::AbstractString,
                  commits::Union{Nothing, AbstractString,
                                 AbstractCommitSelection} = nothing)
    return identify(handle.registry; repo, commits)
end
function identify(; repo::AbstractString,
                  remote::Union{Nothing, AbstractString} = nothing,
                  commits::Union{Nothing, AbstractString,
                                 AbstractCommitSelection} = nothing)
    return identify(RegistryEndpoint(remote = remote); repo, commits)
end

# What a registry knows about the file at `path`, by its hash: what it is
# registered as, and what lies behind it
function _identifyfile(registry::RegistryEndpoint, path::String;
                       superseded::Bool = false)
    hash = _getfilehash(path)
    objects = _registeredobjects(registry, hash)
    roots = [product.url
             for object in objects for product in object.data_products]
    trace = isempty(roots) ? nothing : _upstream(registry, roots, nothing)
    upstream = isnothing(trace) ? UpstreamIssue[] : _upstreamissues(trace)
    outdated = !superseded ? nothing :
               isnothing(trace) ? OutdatedInput[] : _outdatedinputs(trace)
    return FileIdentification(path, hash, objects, trace, upstream, outdated)
end

# Walk a trace back from its roots, calling `f(run, made, nothing)` once for
# each run on the way, with the data product it made on the way, and then
# `f(run, made, input)` for each data product the run read; each data product
# is expanded once, nearest the roots first
function _walkupstream(f::Function, trace::Trace{Upstream})
    queue = copy(trace.roots)
    expanded = Set{String}()
    while !isempty(queue)
        url = popfirst!(queue)
        url in expanded && continue
        push!(expanded, url)
        made = trace.products[url]
        isnothing(made.made_by) && continue
        run = trace.runs[made.made_by]
        f(run, made, nothing)
        for input in run.inputs
            f(run, made, trace.products[input])
            push!(queue, input)
        end
    end
    return nothing
end

# The issues behind a trace's roots: on a run's own files, or on what it
# read, each once per run it reaches a root through
function _upstreamissues(trace::Trace{Upstream})
    found = UpstreamIssue[]
    seen = Set{Tuple{String, String, Union{Nothing, String}, String}}()
    _walkupstream(trace) do run, made, input
        urls = isnothing(input) ? run.issues : input.issues
        for url in urls
            issue = trace.issues[url]
            for target in issue.targets
                if isnothing(input)
                    target.url in run.objects || continue
                else
                    target.url == input.url || continue
                end
                key = (url, target.url, target.component, run.url)
                key in seen && continue
                push!(seen, key)
                push!(found,
                      UpstreamIssue(issue, target, run, made,
                                    !isnothing(input)))
            end
        end
    end
    return found
end

# The data products read on the way to a trace's roots that a newer version
# of exists, each once per run that read them
function _outdatedinputs(trace::Trace{Upstream})
    found = OutdatedInput[]
    seen = Set{Tuple{String, String}}()
    _walkupstream(trace) do run, made, input
        isnothing(input) && return nothing
        isnothing(input.superseded_by) && return nothing
        key = (input.url, run.url)
        key in seen && return nothing
        push!(seen, key)
        push!(found, OutdatedInput(input, run, made))
        return nothing
    end
    return found
end

# What a registry has registered with this hash, as objects with their data
# products and issues
function _registeredobjects(registry::RegistryEndpoint, hash::String)
    objects = RegisteredObject[]
    for location in _getentries(registry, "storage_location",
                                Dict("hash" => hash))
        root_entry = _getentry(registry, URIs.URI(location["storage_root"]))
        for object in _getentries(registry, "object",
                                  Dict("storage_location" =>
                                           _extractid(location["url"])))
            products = [_dataproductrecord(registry, url)
                        for url in object["data_products"]]
            push!(objects,
                  RegisteredObject(object["description"], object["url"],
                                   root_entry["root"], root_entry["local"],
                                   location["path"], products,
                                   _objectissues(registry, object)))
        end
    end
    return objects
end

# What a registry knows about the git repository whose top-level folder is
# `path`, for the commits `selection` chooses
function _identifyrepository(registry::RegistryEndpoint, repo::String,
                             commits::Union{Nothing, AbstractString,
                                            AbstractCommitSelection})
    if _isremoteurl(repo)
        selection = isnothing(commits) ? AllCommits() : _asselection(commits)
        selection isa Union{AncestorCommits, CheckedOutCommit} &&
            throw(ArgumentError("$(_describe(selection)) needs a clone of the repository, and $repo is a URL: give the clone's folder, or AllCommits() or a commit by name"))
        return _identifycommits(registry, nothing, repo, repo, nothing, false,
                                selection)
    end
    selection = isnothing(commits) ? AncestorCommits() : _asselection(commits)
    top = _gittoplevel(repo)
    isnothing(top) &&
        throw(ArgumentError("$repo is not the top level of a git repository"))
    samefile(top, repo) ||
        throw(ArgumentError("$repo is inside the git repository at $top - identify that folder instead"))
    return LibGit2.with(LibGit2.GitRepo(top)) do clone
        LibGit2.isorphan(clone) &&
            throw(ArgumentError("the git repository at $top has no commits"))
        head = string(LibGit2.head_oid(clone))
        dirty = LibGit2.isdirty(clone)
        dirty && _warnifdirty(selection, top, head)
        return _identifycommits(registry, clone, top,
                                _gitremoteurl(clone, top), head, dirty,
                                selection)
    end
end

# Whether a repository is named by the URL of its remote rather than a folder:
# a scheme, or the scp-like form `user@host:path`
function _isremoteurl(text::AbstractString)
    return occursin(r"^[A-Za-z][A-Za-z0-9+.-]*://", text) ||
           occursin(r"^[^/\\:@]+@[^/\\:]+:", text)
end

# The registered runs of the selected commits of the repository at `remote`,
# with the clone, where there is one, for the commits' dates and for resolving
# a name
function _identifycommits(registry::RegistryEndpoint,
                          clone::Union{Nothing, LibGit2.GitRepo},
                          path::String, remote::String,
                          head::Union{Nothing, String}, dirty::Bool,
                          selection::AbstractCommitSelection)
    location = _repositorylocation(remote)
    root_id = _getid(registry, "storage_root", Dict("root" => location.root))
    paths = _repositorypaths(location)
    named = _resolvename(selection, clone, path, registry, root_id, paths)
    locations = isnothing(root_id) ? Dict[] :
                _commitlocations(registry, root_id, paths,
                                 _selectedhashes(selection, head, named))
    commits = RegisteredCommit[]
    for ((sha, commit_dirty), group) in _groupbycommit(locations)
        _selects(selection, clone, head, named, sha, commit_dirty) || continue
        push!(commits,
              _registeredcommit(registry, clone, sha, commit_dirty, group))
    end
    sort!(commits, by = _commitorder)
    return RepositoryIdentification(path, remote, head, dirty, selection,
                                    commits)
end

# The commit a named selection names, else `nothing`: a full hash as it is,
# then what the clone makes of the name, then a registered release of the
# repository at that version
function _resolvename(::AbstractCommitSelection, clone, path, registry, root_id,
                      paths)
    return nothing
end
function _resolvename(selection::NamedCommit,
                      clone::Union{Nothing, LibGit2.GitRepo}, path::String,
                      registry::RegistryEndpoint,
                      root_id::Union{Nothing, AbstractString},
                      paths::Vector{String})
    name = selection.name
    occursin(r"^[0-9a-f]{40}$", name) && return name
    if !isnothing(clone)
        sha = _clonecommit(clone, name)
        isnothing(sha) || return sha
    end
    sha = _releasecommit(registry, root_id, paths, name)
    isnothing(sha) || return sha
    where = isnothing(clone) ?
            "there is no clone to resolve it with, $path being a URL" :
            "the clone at $path has no such tag, branch or commit"
    return throw(ArgumentError("'$name' names no commit of the repository: it is not a full commit hash, $where, and the registry holds no release of the repository at that version"))
end

# The commit a tag, a branch or an abbreviated hash names in the clone, or
# `nothing`
function _clonecommit(clone::LibGit2.GitRepo, name::AbstractString)
    try
        return LibGit2.with(LibGit2.GitObject(clone, name)) do object
            return LibGit2.with(LibGit2.peel(LibGit2.GitCommit, object)) do commit
                return string(LibGit2.GitHash(commit))
            end
        end
    catch err
        err isa LibGit2.GitError || rethrow()
        return nothing
    end
end

# The commit of a registered release of the repository at the version `name`,
# with or without a leading v, or `nothing`
function _releasecommit(registry::RegistryEndpoint,
                        root_id::Union{Nothing, AbstractString},
                        paths::Vector{String}, name::AbstractString)
    isnothing(root_id) && return nothing
    version = tryparse(VersionNumber, lstrip(name, ['v', 'V']))
    isnothing(version) && return nothing
    for release in _getentries(registry, "code_repo_release",
                               Dict("version" => string(version)))
        object = _getentry(registry, URIs.URI(release["object"]))
        isnothing(object["storage_location"]) && continue
        location = _getentry(registry, URIs.URI(object["storage_location"]))
        _extractid(location["storage_root"]) == root_id &&
        location["path"] in paths || continue
        return replace(location["hash"], r"-dirty$" => "")
    end
    return nothing
end

# The hashes a selection can be looked up by, with the dirty form when asked,
# or `nothing` for a selection that lists every location of the repository
function _selectedhashes(selection::CheckedOutCommit, head::AbstractString,
                         ::Nothing)
    return _withdirty(head, selection.dirty)
end
function _selectedhashes(selection::NamedCommit, head, named::AbstractString)
    return _withdirty(named, selection.dirty)
end
_selectedhashes(::AbstractCommitSelection, head, named) = nothing
function _withdirty(sha::AbstractString, dirty::Bool)
    return dirty ? [sha, "$sha-dirty"] : [sha]
end

# The top-level folder of the git repository holding `dir`, or `nothing`
function _gittoplevel(dir::AbstractString)
    current = abspath(dir)
    while true
        ispath(joinpath(current, ".git")) && return current
        parent = dirname(current)
        parent == current && return nothing
        current = parent
    end
end

# Warn that the checkout's uncommitted changes are being set aside; selecting
# every commit is not about the checkout, so says nothing
_warnifdirty(::AllCommits, top::AbstractString, head::AbstractString) = nothing
_warnifdirty(::NamedCommit, top::AbstractString, head::AbstractString) = nothing
function _warnifdirty(::AbstractCommitSelection, top::AbstractString,
                      head::AbstractString)
    @warn "the working tree at $top has uncommitted changes: identifying its checked-out commit $head as committed"
    return nothing
end

# The URL of the git remote the CLI records runs of this repository under: the
# one named by `git.remote` in its `.fair/cli-config.yaml`, else `origin`
function _gitremoteurl(repo::LibGit2.GitRepo, top::AbstractString)
    config_path = joinpath(top, ".fair", "cli-config.yaml")
    name = "origin"
    if isfile(config_path)
        config = something(YAML.load_file(config_path), Dict())
        git = something(get(config, "git", nothing), Dict())
        name = something(get(git, "remote", nothing), name)
    end
    url = LibGit2.getconfig(repo, "remote.$name.url", "")
    isempty(url) &&
        throw(ArgumentError("the git repository at $top has no remote '$name', which is what the registry would know it by"))
    return url
end

# Every path a repository's commits may be registered under, below its host's
# storage root: relative to the root, with and without `.git`, as this package
# and R write it, and the whole remote URL, HTTPS or SSH, as Python does
function _repositorypaths(location::NamedTuple)
    bare = replace(location.path, r"\.git$" => "")
    host = replace(match(r"^[^:]+://([^/]+)/", location.root)[1], r"^.*@" => "")
    return unique([form * suffix
                   for form in (bare, location.root * bare, "git@$host:$bare")
                   for suffix in ("", ".git")])
end

# The storage locations registered for the checked-out commit alone, found by
# its hash, and by `<hash>-dirty` if the selection includes those runs
function _commitlocations(registry::RegistryEndpoint, root_id::AbstractString,
                          paths::Vector{String}, hashes::Vector{String})
    return [location
            for hash in hashes
            for location in _getentries(registry, "storage_location",
                                        Dict("hash" => hash,
                                             "storage_root" => root_id))
            if location["path"] in paths]
end

# The storage locations registered for every commit of the repository, found by
# its paths
function _commitlocations(registry::RegistryEndpoint, root_id::AbstractString,
                          paths::Vector{String}, ::Nothing)
    return reduce(vcat,
                  [_getentries(registry, "storage_location",
                               Dict("path" => path, "storage_root" => root_id))
                   for path in paths])
end

# Storage locations grouped by the commit they stand for and whether its runs
# had uncommitted changes, which the registry records as `<sha>-dirty`
function _groupbycommit(locations::AbstractVector)
    groups = Dict{Tuple{String, Bool}, Vector{Any}}()
    for location in locations
        dirty = endswith(location["hash"], "-dirty")
        sha = dirty ? chop(location["hash"], tail = 6) : location["hash"]
        push!(get!(Vector{Any}, groups, (String(sha), dirty)), location)
    end
    return groups
end

# Whether a registered commit is one the selection asks for: runs with
# uncommitted changes only if it includes them, and then its own rule
function _selects(selection::AbstractCommitSelection,
                  clone::Union{Nothing, LibGit2.GitRepo},
                  head::Union{Nothing, AbstractString},
                  named::Union{Nothing, AbstractString}, sha::AbstractString,
                  dirty::Bool)
    return (!dirty || selection.dirty) &&
           _selectscommit(selection, clone, head, named, sha)
end

# Whether a commit is one of those the selection reaches
_selectscommit(::AllCommits, clone, head, named, sha::AbstractString) = true
function _selectscommit(::CheckedOutCommit, clone, head::AbstractString, named,
                        sha::AbstractString)
    return sha == head
end
function _selectscommit(::NamedCommit, clone, head, named::AbstractString,
                        sha::AbstractString)
    return sha == named
end
function _selectscommit(::AncestorCommits, clone::LibGit2.GitRepo,
                        head::AbstractString, named, sha::AbstractString)
    return LibGit2.iscommit(sha, clone) &&
           LibGit2.is_ancestor_of(sha, head, clone)
end

# One registered commit: its date if the clone has it, and the runs made from
# and issues raised against every object standing for it
function _registeredcommit(registry::RegistryEndpoint,
                           clone::Union{Nothing, LibGit2.GitRepo},
                           sha::String, dirty::Bool, locations::AbstractVector)
    date = nothing
    if !isnothing(clone) && LibGit2.iscommit(sha, clone)
        date = LibGit2.with(LibGit2.GitCommit(clone, sha)) do commit
            return unix2datetime(LibGit2.committer(commit).time)
        end
    end
    objects = String[]
    runs = CodeRunRecord[]
    issues = IssueRecord[]
    for location in locations
        for object in _getentries(registry, "object",
                                  Dict("storage_location" =>
                                           _extractid(location["url"])))
            push!(objects, object["url"])
            append!(issues, _objectissues(registry, object))
            for run in _getentries(registry, "code_run",
                                   Dict("code_repo" =>
                                            _extractid(object["url"])))
                push!(runs, _coderunrecord(registry, run))
            end
        end
    end
    sort!(runs, by = run -> run.run_date, rev = true)
    return RegisteredCommit(sha, dirty, date, objects, runs, issues)
end

# A code run, with the data products it wrote
function _coderunrecord(registry::RegistryEndpoint, run::AbstractDict)
    object_urls = unique(_getentry(registry, URIs.URI(url))["object"]
                         for url in run["outputs"])
    outputs = DataProductRecord[_dataproductrecord(registry, product_url)
                                for object_url in object_urls
                                for product_url in _getentry(registry,
                                                             URIs.URI(object_url))["data_products"]]
    return CodeRunRecord(run["uuid"], DateTime(first(run["run_date"], 19)),
                         something(run["description"], ""), run["url"],
                         outputs)
end

# Where a registered commit sorts in a report: those in the clone first, newest
# commit first; then the rest, newest first by their earliest run; then any
# with no run at all
function _commitorder(commit::RegisteredCommit)
    isnothing(commit.date) ||
        return (0, -Dates.value(commit.date), commit.sha, commit.dirty)
    isempty(commit.runs) && return (2, 0, commit.sha, commit.dirty)
    earliest = minimum(run.run_date for run in commit.runs)
    return (1, -Dates.value(earliest), commit.sha, commit.dirty)
end
