# SPDX-License-Identifier: LGPL-3.0-or-later

# Releases of a code repository: the version a commit is released as, read from
# its tags, in a clone or at a remote with no clone, and the release registered
# with its data product.

"""
    RegisteredRelease

A release of the code that the registry holds, as [`register_release!`](@ref)
returns it: the registry's record that a commit of a code repository is a
release, and the data product registered with it, which carries its source.

# Fields
- `url`: the registry URL of the release record, which holds `version` unless
  `register_release!` warned that it could not be changed
- `name`: the release's name, the remote's path, as
  `FAIRDataPipeline/DataPipeline.jl`
- `version`: the version released
- `website`: the release's web page, or `nothing`
- `path`: the top-level folder of the clone it was registered from, or
  `nothing` where it was registered by the remote's URL
- `repository`: the URL of the repository's remote
- `commit`: the commit released
- `object`: the registry URL of the repository's object at that commit, which
  the release record and the data product are on
- `data_product`: the [`DataProductRecord`](@ref) of the release's data
  product, `<organisation>:<repository>@<version>`
- `source`: the registry URL of the release's source, or `nothing`
"""
struct RegisteredRelease
    url::String
    name::String
    version::VersionNumber
    website::Union{Nothing, String}
    path::Union{Nothing, String}
    repository::String
    commit::String
    object::String
    data_product::DataProductRecord
    source::Union{Nothing, String}
end

function Base.show(io::IO, release::RegisteredRelease)
    return print(io, release.name, " ", release.version, " (commit ",
                 first(release.commit, 8), ")")
end

function Base.show(io::IO, ::MIME"text/plain", release::RegisteredRelease)
    println(io, release.name, " ", release.version)
    println(io, "  commit:       ", release.commit)
    println(io, "  repository:   ", release.repository)
    isnothing(release.path) || println(io, "  clone:        ", release.path)
    println(io, "  data product: ", release.data_product)
    println(io, "  website:      ", something(release.website, "none"))
    println(io, "  source:       ", something(release.source, "none"))
    return print(io, "  registered:   ", release.url)
end

# A release names its commit, of the clone it was registered from, else of
# its remote
function NamedCommit(release::RegisteredRelease; dirty::Bool = false)
    return NamedCommit(release.commit,
                       repo = something(release.path, release.repository),
                       dirty = dirty)
end

# ... and an `AncestorCommits` of a release starts from its commit, in the
# clone it was registered from, which a `repo` given beside it must be
function _ancestorstart(release::RegisteredRelease, repo)
    isnothing(release.path) &&
        throw(ArgumentError("$release was registered by its remote's URL, with no clone, and finding ancestors needs one: give the clone's folder as `repo` with `of` the release's commit"))
    isnothing(repo) ||
        (!_isremoteurl(repo) && isdir(repo) &&
         samefile(repo, release.path)) ||
        throw(ArgumentError("$release was registered from the clone at $(release.path), not $repo"))
    return (of = release.commit, repo = release.path)
end

# == Functions ==

"""
    register_release!(commit = CheckedOutCommit(); website = nothing,
                      remote = nothing)
    register_release!(registry, commit = CheckedOutCommit(); website = nothing)
    register_release!(handle, commit = CheckedOutCommit(); website = nothing)

Register a commit of a code repository as a release of the code, and return
the [`RegisteredRelease`](@ref). The version is the commit's tag that reads as
a semantic version - `v1.2.0`, `1.2.0-beta2` - written in full; a commit with
none cannot be released.

Registered, each found rather than made where the registry holds it already:
the repository's object at the commit, made as [`initialise`](@ref) makes
one, with the authors, licence and keywords of the repository's metadata
files; the registry's record that the commit is a release, named by the
remote's path, as `FAIRDataPipeline/DataPipeline.jl`; and a data product of
the release, `<organisation>:<repository>@<version>`, on the same object, so
that a trace and a crate take the release as they take any data product. A
second call on a release changes nothing.

A commit released already under another version - a beta, say, retagged as a
release - has the new version's data product registered and its release
record changed to the new version, where the registry allows it; where not,
a warning says that the record keeps the old version.

`fair-cli` 0.10.2 neither pushes a release record nor moves a release's data
product properly between registries: register a release on each registry it
belongs on, with `remote` naming the CLI's remote registry, and do not
`fair add` its data product. While the session rehearses a run, what would be
registered is printed, and nothing is.

# Arguments
- `commit`: the commit to release: [`CheckedOutCommit`](@ref), the default,
  which a checkout with uncommitted changes cannot be, or a
  [`NamedCommit`](@ref) - a tag, a branch or a hash - whatever the checkout
  holds. Either holds its repository: a clone, or for a `NamedCommit` the URL
  of its remote, whose tags are then listed over the network and, on GitHub,
  whose metadata files are read at the commit.
- `website`: the release's web page; by default, for a remote on GitHub, the
  page of the release of its tag.
- `registry::RegistryEndpoint`: the registry to register it in, which needs
  its token; a `DataRegistryHandle` may be given instead, and its registry is
  used.
- `remote`: with no registry given, the remote registry of that name in the
  current project's CLI configuration, else the CLI's local registry.
"""
function register_release!(registry::RegistryEndpoint,
                           commit::Union{CheckedOutCommit, NamedCommit} = CheckedOutCommit();
                           website::Union{Nothing, AbstractString} = nothing)
    target = _releasetarget(registry, commit)
    return _registerrelease(_sessionmode(), registry, target,
                            isnothing(website) ? target.website :
                            String(website))
end
function register_release!(handle::DataRegistryHandle,
                           commit::Union{CheckedOutCommit, NamedCommit} = CheckedOutCommit();
                           website::Union{Nothing, AbstractString} = nothing)
    return register_release!(handle.registry, commit; website)
end
function register_release!(commit::Union{CheckedOutCommit, NamedCommit} = CheckedOutCommit();
                           website::Union{Nothing, AbstractString} = nothing,
                           remote::Union{Nothing, AbstractString} = nothing)
    return register_release!(RegistryEndpoint(remote = remote), commit;
                             website)
end

# The tags of a clone, by name, each with the commit it names
function _repositorytags(clone::LibGit2.GitRepo)
    tags = Dict{String, String}()
    for name in LibGit2.tag_list(clone)
        sha = _clonecommit(clone, "refs/tags/$name")
        isnothing(sha) || (tags[name] = sha)
    end
    return tags
end
# ... or of a remote, as it advertises them, which needs the network
function _repositorytags(remote::AbstractString)
    return Dict(String(chopprefix(name, "refs/tags/")) => sha
                for (name, sha) in _remoterefs(remote)
                if startswith(name, "refs/tags/"))
end

# Every reference a remote advertises, by name, each with the commit it names -
# for an annotated tag the commit, which the remote gives as `<tag>^{}`, not the
# tag object. Listed with no clone and offering no credentials, so that nothing
# waits for a password: a remote that asks for one is a `ReadWriteException`.
function _remoterefs(remote::AbstractString)
    heads = try
        LibGit2.with(LibGit2.GitRemoteDetached(_listingurl(remote))) do connection
            LibGit2.connect(connection, LibGit2.Consts.DIRECTION_FETCH,
                            LibGit2.RemoteCallbacks())
            listed = [(head.name, string(head.oid))
                      for head in LibGit2.ls(connection)]
            LibGit2.disconnect(connection)
            return listed
        end
    catch err
        err isa LibGit2.GitError || rethrow()
        throw(ReadWriteException("cannot list the tags and branches of $remote with no clone: $(err.msg)"))
    end
    refs = Dict(name => sha for (name, sha) in heads if !endswith(name, "^{}"))
    for (name, sha) in heads
        endswith(name, "^{}") && (refs[chop(name, tail = 3)] = sha)
    end
    return refs
end

# The address a remote is listed at: the HTTPS form of an scp-like SSH address,
# which would need keys, else the address as it is
function _listingurl(remote::AbstractString)
    occursin(r"^[^@/:]+@[^:/]+:", remote) || return String(remote)
    location = _repositorylocation(remote)
    return location.root * location.path
end

# The commit a tag or a branch of a remote names, or `nothing` where it has
# neither; a remote that cannot be listed is warned of, and names nothing
function _remotecommit(remote::AbstractString, name::AbstractString)
    refs = try
        _remoterefs(remote)
    catch err
        err isa ReadWriteException || rethrow()
        @warn err.msg
        return nothing
    end
    return get(refs, "refs/tags/$name", get(refs, "refs/heads/$name", nothing))
end

# The version a tag is, read as a semantic version with or without a leading
# `v`, or `nothing`
function _tagversion(tag::AbstractString)
    return tryparse(VersionNumber, lstrip(tag, ['v', 'V']))
end

"""
    _commitversion(tags, sha, named = nothing)

Return the version a commit `sha` is released as, written in full, with the
tags that give it, as `(version, tags)`, from `tags`, a tag's name to the
commit it names. Only the tags naming the commit that read as a semantic
version count, with or without a leading `v`, lightweight or annotated alike.
`named`, the name a selection gave the commit, is that tag where it is one of
them; otherwise their one version, a full release preferred over
pre-releases. None, or several that differ, is an `ArgumentError`.
"""
function _commitversion(tags::AbstractDict{String, String},
                        sha::AbstractString,
                        named::Union{Nothing, AbstractString} = nothing)
    versions = Dict{VersionNumber, Vector{String}}()
    for (tag, commit) in tags
        commit == sha || continue
        version = _tagversion(tag)
        isnothing(version) ||
            push!(get!(Vector{String}, versions, version), tag)
    end
    isempty(versions) &&
        throw(ArgumentError("commit $sha has no tag that reads as a semantic version, such as v1.2.0: tag it with the version to release it"))
    if !isnothing(named) && any(named in tagged for tagged in values(versions))
        version = _tagversion(named)
        return (version = string(version), tags = sort(versions[version]))
    end
    full = [version
            for version in keys(versions) if isempty(version.prerelease)]
    candidates = isempty(full) ? collect(keys(versions)) : full
    if length(candidates) > 1
        listed = sort!([tag for version in candidates
                        for tag in versions[version]])
        throw(ArgumentError("commit $sha is tagged with several versions, $(join(listed, ", ")): name the one to release, as NamedCommit($(repr(first(listed))))"))
    end
    version = only(candidates)
    return (version = string(version), tags = sort(versions[version]))
end

# What a release of the selected commit is: the commit, its version and the
# tags giving it, the clone (or `nothing`) and the remote's URL, what the
# repository's files say at the commit, the names it is registered by and its
# default web page; found by clone, or by URL ...
function _releasetarget(registry::RegistryEndpoint,
                        commit::Union{CheckedOutCommit, NamedCommit})
    named = commit isa NamedCommit ? commit.name : nothing
    if _isremoteurl(commit.repo)
        remote = commit.repo
        sha = _namedreleasecommit(registry, commit, nothing, remote)
        return _releaseat(sha, named, nothing, remote,
                          _repositorytags(remote),
                          _repositorymetadata(remote, sha))
    end
    return LibGit2.with(LibGit2.GitRepo(commit.repo)) do clone
        remote = _gitremoteurl(clone, commit.repo)
        sha = _selectedreleasecommit(registry, commit, clone, remote)
        return _releaseat(sha, named, commit.repo, remote,
                          _repositorytags(clone),
                          _repositorymetadata(clone, sha))
    end
end
# ... from the commit, the tags, the files and where they were read
function _releaseat(sha::String, named::Union{Nothing, String},
                    path::Union{Nothing, String}, remote::String,
                    tags::AbstractDict, metadata::RepositoryMetadata)
    version = _commitversion(tags, sha, named)
    names = _releasenames(remote)
    return (commit = sha, version = version.version, tags = version.tags,
            path = path, remote = remote, metadata = metadata,
            release = names.release, namespace = names.namespace,
            data_product = names.data_product,
            website = _releasewebsite(remote, version.version, version.tags,
                                      named))
end

# The commit of a clone that a selection releases: the checked-out one, which
# uncommitted changes make no release of ...
function _selectedreleasecommit(::RegistryEndpoint, commit::CheckedOutCommit,
                                clone::LibGit2.GitRepo, ::String)
    LibGit2.isdirty(clone) &&
        throw(ArgumentError("the checkout at $(commit.repo) has uncommitted changes, so its commit is not in a state to release: commit them, or name the commit to release with NamedCommit"))
    return string(LibGit2.head_oid(clone))
end
# ... or the one a name names, which the clone must hold
function _selectedreleasecommit(registry::RegistryEndpoint,
                                commit::NamedCommit,
                                clone::LibGit2.GitRepo, remote::String)
    sha = _namedreleasecommit(registry, commit, clone, remote)
    LibGit2.iscommit(sha, clone) ||
        throw(ArgumentError("'$(commit.name)' names commit $sha, which the clone at $(commit.repo) does not have"))
    return sha
end

# The commit a name names, as `identify` resolves it, by clone or by URL
function _namedreleasecommit(registry::RegistryEndpoint, commit::NamedCommit,
                             clone::Union{Nothing, LibGit2.GitRepo},
                             remote::String)
    location = _repositorylocation(remote)
    root_id = _getid(registry, "storage_root", Dict("root" => location.root))
    return _resolvecommit(commit.name, clone, commit.repo, registry, root_id,
                          _repositorypaths(location))
end

# The names a release of the repository at `remote` is registered by: the
# release by the remote's path without `.git`; its data product with the
# path's first part as the namespace and the rest as the name, each held to
# the naming convention
function _releasenames(remote::AbstractString)
    path = replace(strip(_repositorylocation(remote).path, '/'),
                   r"\.git$" => "")
    parts = split(path, '/', limit = 2)
    length(parts) == 2 ||
        throw(ArgumentError("the remote $remote has no organisation and repository in its path, which a release is named by"))
    return (release = String(path), namespace = _checknamespace(parts[1]),
            data_product = _checkdataproduct(parts[2]))
end

# The page of a release on GitHub, for its tag - the one named, else `v` and
# the version in full, else the first - or `nothing` for a remote elsewhere
function _releasewebsite(remote::AbstractString, version::String,
                         tags::Vector{String},
                         named::Union{Nothing, String})
    path = _githubpath(remote)
    isnothing(path) && return nothing
    tag = !isnothing(named) && named in tags ? named :
          "v$version" in tags ? "v$version" : first(tags)
    return "https://github.com/$path/releases/tag/$tag"
end

# Register a release: the repository's object at the commit, the release
# record and the release's data product
function _registerrelease(::RecordedRun, registry::RegistryEndpoint,
                          target::NamedTuple,
                          website::Union{Nothing, String})
    _requiretoken(registry)
    object_url = _registerrepository(registry, target.remote, target.commit,
                                     target.metadata)
    record = _registerreleaserecord(registry, object_url, target.release,
                                    target.version, website)
    product_url = _registerreleaseproduct(registry, object_url,
                                          target.namespace,
                                          target.data_product, target.version)
    product = _dataproductrecord(registry, product_url)
    return RegisteredRelease(record["url"], target.release,
                             VersionNumber(target.version), website,
                             target.path, target.remote, target.commit,
                             object_url, product, product.external_object)
end

# The release record of a version on the commit's object: found where the
# registry holds it; else made, or, where the object holds another version's,
# that record changed to this version, a registry that cannot change it warned
# of and its record kept
function _registerreleaserecord(registry::RegistryEndpoint,
                                object_url::String, name::String,
                                version::String,
                                website::Union{Nothing, String})
    held = _getentry(registry, "code_repo_release",
                     Dict("name" => name, "version" => version))
    if !isnothing(held)
        held["object"] == object_url ||
            throw(ReadWriteException("$name $version is registered already as the release of another commit, at $(held["object"])"))
        return held
    end
    previous_url = _getentry(registry, URIs.URI(object_url))["code_repo_release"]
    if isnothing(previous_url)
        data = Dict{String, Any}("name" => name, "version" => version,
                                 "object" => object_url)
        isnothing(website) || (data["website"] = website)
        return _createentry(registry, "code_repo_release", data)
    end
    previous = _getentry(registry, URIs.URI(previous_url))
    changed = _patchentry(registry, previous_url,
                          Dict("version" => version, "website" => website))
    if isnothing(changed)
        @warn "the commit is the release $(previous["name"]) $(previous["version"]) already, and this registry cannot change a release record: $version is registered as the release's data product only, and the record stays at $(previous["version"]). An admin of the registry can delete that record on its admin pages, and register_release! called again then records $version."
        return previous
    end
    @info "the commit's release record is changed from $(previous["version"]) to $version"
    return changed
end

# The data product of a release, on the commit's object: found where the
# registry holds it, else made; held by another object, an error
function _registerreleaseproduct(registry::RegistryEndpoint,
                                 object_url::String, namespace::String,
                                 name::String, version::String)
    namespace_url = _postentry(registry, "namespace",
                               Dict("name" => namespace))["url"]
    query = Dict("namespace" => namespace_url, "name" => name,
                 "version" => version)
    held = _getentry(registry, "data_product", query)
    if !isnothing(held)
        held["object"] == object_url ||
            throw(ReadWriteException("$(_dataproductname(namespace, name, version)) is registered already, for another object, $(held["object"])"))
        return held["url"]
    end
    return _createentry(registry, "data_product",
                        merge(query, Dict("object" => object_url)))["url"]
end
