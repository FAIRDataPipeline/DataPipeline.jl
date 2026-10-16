# SPDX-License-Identifier: LGPL-3.0-or-later

# Releases of a code repository: the version a commit is released as, read from
# its tags, in a clone or at a remote with no clone.

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
