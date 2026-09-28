# SPDX-License-Identifier: LGPL-3.0-or-later

# Asking the registry what it knows about a file or a git repository on disk,
# and tracing issues through provenance.

"""
    IssueRecord

A problem recorded against something a file is registered as.

# Fields
- `severity`: how bad it is, as the registry holds it (larger is worse)
- `description`: what the problem is
- `component`: the name of the object component it was raised against, or
  `nothing` when raised against the file as a whole
"""
struct IssueRecord
    severity::Int
    description::String
    component::Union{Nothing, String}
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
    print(io, dp.namespace, "/", dp.name, " v", dp.version)
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
    FileIdentification

What a registry knows about one file on disk, as returned by
[`identify`](@ref). `objects` is empty when the registry has never been told
about a file with these contents.

# Fields
- `path`: the file asked about
- `hash`: its SHA-1, which is how the registry identifies it
- `objects`: the [`RegisteredObject`](@ref)s registered with that hash
"""
struct FileIdentification
    path::String
    hash::String
    objects::Vector{RegisteredObject}
end

function Base.show(io::IO, id::FileIdentification)
    isempty(id.objects) && return print(io, basename(id.path), ": unknown")
    return print(io, basename(id.path), ": ",
                 join(sprint.(show, id.objects), "; "))
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
            println(io, "    data product: ", dp.namespace, "/", dp.name)
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

function Base.show(io::IO, selection::AbstractCommitSelection)
    return print(io, nameof(typeof(selection)),
                 selection.dirty ? "(dirty = true)" : "()")
end

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

What a registry knows about a git repository on disk, as returned by
[`identify`](@ref). `commits` is empty when no run was made from any of the
commits selected.

# Fields
- `path`: the repository's top-level folder
- `remote`: the URL of the git remote the registry knows it by
- `head`: the checked-out commit
- `dirty`: whether the working tree has uncommitted changes to tracked files
- `selection`: the [`AbstractCommitSelection`](@ref) asked for
- `commits`: the [`RegisteredCommit`](@ref)s selected, newest commit first;
  those the local clone does not have come last, newest first by their
  earliest run
"""
struct RepositoryIdentification
    path::String
    remote::String
    head::String
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
    println(io, "  checked out: ", id.head,
            id.dirty ? " (with uncommitted changes)" : "")
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
                  IssueRecord(issue["severity"], issue["description"], name))
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
    identify(path; remote = nothing, commits = AncestorCommits())
    identify(registry, path; commits = AncestorCommits())
    identify(handle, path; commits = AncestorCommits())

Ask a registry what it knows about a file or a git repository on disk.

For a **file**, return a [`FileIdentification`](@ref): the data products it is
registered as, where the registry expects to find it, whether a newer version
of any of those data products exists, and any issues raised against it.
`isempty(result.objects)` means the registry has no record of a file with these
contents. The file is identified by the SHA-1 of its contents, as everything in
the pipeline is, so a copy under another name is recognised and an edited file
is not.

For the **top-level folder of a git repository**, return a
[`RepositoryIdentification`](@ref): the code runs made from its commits, with
their outputs, and any issues raised against those commits. The repository is
known to the registry by the URL of its git remote - the one named by
`git.remote` in its `.fair/cli-config.yaml`, else `origin` - and `commits`
chooses which of its commits to report. Runs made with uncommitted changes are
included only when `commits` is given `dirty = true`. When the checkout itself
has uncommitted changes, `AncestorCommits` and `CheckedOutCommit` warn and use
its commit as committed.

# Arguments
- `path::String`: the file, or the repository's top-level folder, to ask about.
  Any other folder is an `ArgumentError`, including one inside a repository.
- `registry::RegistryEndpoint`: the registry to ask, which needs no token,
  e.g. `RegistryEndpoint("http://127.0.0.1:8000/api/")`; a
  `DataRegistryHandle` may be given instead, and its registry is used.
- `remote`: with `path` alone, the registry is the CLI's local registry, or the
  remote registry of that name in the current project's CLI configuration; see
  [`RegistryEndpoint`](@ref).
- `commits::AbstractCommitSelection`: for a repository,
  [`AncestorCommits()`](@ref AncestorCommits) (the default),
  [`CheckedOutCommit()`](@ref CheckedOutCommit) or
  [`AllCommits()`](@ref AllCommits), each optionally with `dirty = true`; for a
  file, an `ArgumentError`.
"""
function identify(registry::RegistryEndpoint, path::String;
                  commits::Union{Nothing, AbstractCommitSelection} = nothing)
    if isfile(path)
        isnothing(commits) ||
            throw(ArgumentError("`commits` selects commits of a git repository, and $path is a file"))
        return _identifyfile(registry, path)
    end
    isdir(path) || throw(ReadWriteException("no file or folder at $path"))
    return _identifyrepository(registry, path,
                               something(commits, AncestorCommits()))
end
function identify(handle::DataRegistryHandle, path::String;
                  commits::Union{Nothing, AbstractCommitSelection} = nothing)
    return identify(handle.registry, path, commits = commits)
end
function identify(path::String;
                  remote::Union{Nothing, AbstractString} = nothing,
                  commits::Union{Nothing, AbstractCommitSelection} = nothing)
    return identify(RegistryEndpoint(remote = remote), path, commits = commits)
end

# What a registry knows about the file at `path`, by its hash
function _identifyfile(registry::RegistryEndpoint, path::String)
    hash = _getfilehash(path)
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
    return FileIdentification(path, hash, objects)
end

# What a registry knows about the git repository whose top-level folder is
# `path`, for the commits `selection` chooses
function _identifyrepository(registry::RegistryEndpoint, path::String,
                             selection::AbstractCommitSelection)
    top = _gittoplevel(path)
    isnothing(top) &&
        throw(ArgumentError("$path is neither a file nor the top level of a git repository"))
    samefile(top, path) ||
        throw(ArgumentError("$path is inside the git repository at $top - identify that folder instead"))
    return LibGit2.with(LibGit2.GitRepo(top)) do repo
        LibGit2.isorphan(repo) &&
            throw(ArgumentError("the git repository at $top has no commits"))
        head = string(LibGit2.head_oid(repo))
        dirty = LibGit2.isdirty(repo)
        dirty && _warnifdirty(selection, top, head)
        remote = _gitremoteurl(repo, top)
        location = _repositorylocation(remote)
        root_id = _getid(registry, "storage_root",
                         Dict("root" => location.root))
        locations = isnothing(root_id) ? Dict[] :
                    _commitlocations(registry, selection, root_id,
                                     _repositorypaths(location), head)
        commits = RegisteredCommit[]
        for ((sha, commit_dirty), group) in _groupbycommit(locations)
            _selects(selection, repo, head, sha, commit_dirty) || continue
            push!(commits,
                  _registeredcommit(registry, repo, sha, commit_dirty,
                                    group))
        end
        sort!(commits, by = _commitorder)
        return RepositoryIdentification(top, remote, head, dirty, selection,
                                        commits)
    end
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
function _commitlocations(registry::RegistryEndpoint,
                          selection::CheckedOutCommit, root_id::AbstractString,
                          paths::Vector{String}, head::AbstractString)
    hashes = selection.dirty ? [head, "$head-dirty"] : [head]
    return [location
            for hash in hashes
            for location in _getentries(registry, "storage_location",
                                        Dict("hash" => hash,
                                             "storage_root" => root_id))
            if location["path"] in paths]
end

# The storage locations registered for every commit of the repository, found by
# its paths
function _commitlocations(registry::RegistryEndpoint,
                          ::AbstractCommitSelection, root_id::AbstractString,
                          paths::Vector{String}, head::AbstractString)
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
function _selects(selection::AbstractCommitSelection, repo::LibGit2.GitRepo,
                  head::AbstractString, sha::AbstractString, dirty::Bool)
    return (!dirty || selection.dirty) &&
           _selectscommit(selection, repo, head, sha)
end

# Whether a commit is one of those the selection reaches
function _selectscommit(::AllCommits, repo::LibGit2.GitRepo,
                        head::AbstractString, sha::AbstractString)
    return true
end
function _selectscommit(::CheckedOutCommit, repo::LibGit2.GitRepo,
                        head::AbstractString, sha::AbstractString)
    return sha == head
end
function _selectscommit(::AncestorCommits, repo::LibGit2.GitRepo,
                        head::AbstractString, sha::AbstractString)
    return LibGit2.iscommit(sha, repo) &&
           LibGit2.is_ancestor_of(sha, head, repo)
end

# One registered commit: its date if the clone has it, and the runs made from
# and issues raised against every object standing for it
function _registeredcommit(registry::RegistryEndpoint, repo::LibGit2.GitRepo,
                           sha::String, dirty::Bool, locations::AbstractVector)
    date = nothing
    if LibGit2.iscommit(sha, repo)
        date = LibGit2.with(LibGit2.GitCommit(repo, sha)) do commit
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

# ---- provenance tracing ----
# Written against the registry's 2021 schema and **not run since**: issues are
# read from an object, where they now hang off each object component, and
# `inputs`/`outputs` from an object, where provenance is now the `inputs_of`
# and `outputs_of` of a component. Rebuilding it is an open item.

# Count and print the issues of one object or component, once each
function record_issues!(registry::RegistryEndpoint, issues::Dict, obj)
    print(" - checking: ", obj["url"])
    length(obj["issues"]) == 0 && println(" - no issues detected.")
    output = 0
    for issue_url in obj["issues"]
        if haskey(issues, issue_url)
            issues[issue_url] += 1
        else
            issue = _getentry(registry, URIs.URI(issue_url))
            println("\n -- ISSUE DETECTED - SEVERITY := ", issue["severity"])
            println(" --- ", issue["description"])
            println(" --- last updated: ", issue["last_updated"])
            issues[issue_url] = 1
            output += 1
        end
    end
    return output
end

# Count the issues on the `trace` ("inputs" or "outputs") of an object, and
# on theirs in turn
function registry_audit_recursive(registry::RegistryEndpoint, obj,
                                  trace::String)
    haskey(obj, trace) || (return 0)
    ic = 0
    obj_urls = String[]
    issues = Dict{String, Int64}()
    for component_url in obj[trace]
        obj_c = _getentry(registry, URIs.URI(component_url))
        ic += record_issues!(registry, issues, obj_c)
        push!(obj_urls, obj_c["object"])
    end
    for obj_url in obj_urls
        obj2 = _getentry(registry, URIs.URI(obj_url))
        ic += registry_audit_recursive(registry, obj2, trace)
    end
    return ic
end

"""
    registry_audit(registry, url; trace = "both")

Search the registry for known issues with a data product, code repo release
or code run, and with everything upstream and downstream of it in provenance,
printing what is found.

# Arguments
- `registry::RegistryEndpoint`: the registry to search.
- `url::String`: the registry URL of the thing to audit.
- `trace::String`: `"inputs"`, `"outputs"` or `"both"`, the default.
"""
function registry_audit(registry::RegistryEndpoint, url::String;
                        trace::String = "both")
    function print_thing(resp, thing::String, lbl = thing)
        return haskey(resp, thing) && println(" - ", lbl, ": ", resp[thing])
    end
    el_count(cnt) = string(cnt == 0 ? "no issues" :
                           (cnt == 1 ? "one issue" : string(cnt, " issues")))
    resp = _getentry(registry, URIs.URI(url))
    println("DATA REGISTRY AUDIT: ", url)
    print_thing(resp, "name")
    print_thing(resp, "version")
    print_thing(resp, "last_updated", "last updated")
    ic = zeros(Int64, 3)
    obj = _getentry(registry, URIs.URI(resp["object"]))
    issues = Dict{String, Int64}()
    ic[1] += record_issues!(registry, issues, obj)
    for component_url in obj["components"]
        obj_c = _getentry(registry, URIs.URI(component_url))
        ic[1] += record_issues!(registry, issues, obj_c)
    end
    status = string(" - directly affected by ", el_count(ic[1]), ".")
    if trace != "outputs"
        println("AUDITING INPUTS:")
        ic[2] += registry_audit_recursive(registry, obj, "inputs")
        status = string(status, "\n - inputs affected by ", el_count(ic[2]),
                        ".")
    end
    if trace != "inputs"
        println("AUDITING OUTPUTS:")
        ic[3] += registry_audit_recursive(registry, obj, "outputs")
        status = string(status, "\n - outputs affected by ", el_count(ic[3]),
                        ".")
    end
    println("AUDIT COMPLETE - ", el_count(sum(ic)), " detected for ", url)
    return sum(ic) > 0 && println(status)
end
