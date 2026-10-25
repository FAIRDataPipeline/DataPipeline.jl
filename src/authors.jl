# SPDX-License-Identifier: LGPL-3.0-or-later

# The authors of the sources that registered files come from: registering
# them with the identifiers that say who they are, and finding the registry's
# author for the name that a citation gives.

# Characters the registry takes in no name, since it reads them as a pattern
# when a name is looked up
const UNNAMEABLE = ('[', ']', '?', '*')

"""
    register_authors!(handle, authors...)

Register authors with the registry together with the identifiers that say who
they are - an ORCID for a person, a ROR id for an organisation - and return
their names, sorted. A citation in BibTeX gives its authors by name alone: a
name registered here stands, for the rest of the run, for the author with
its identifier, and any other name is an author by the name alone, whatever
the registry holds under it. Where a DOI's metadata identifies one of its
authors, that identifier is the one for that author.

Each of `authors` is a `name => identifier` pair, or the path of a TOML file
with a line for each author:

    "Josiah Carberry" = "https://orcid.org/0000-0002-1825-0097"
    "An Example Institute" = "https://ror.org/000000000"

A name is written as a citation's author is read: a person's given names and
then family name, an organisation as it stands. An identifier is a URL, and
one written with `http:` is registered with `https:`. If any of `authors`
cannot be read, nothing is registered.

An identifier may be given several names, the spellings that citations use.
The registry keeps one name for it: the one it holds already, or else the
first given here, taking the arguments in order and a file's authors in order
of name. A message says when another name stands for that author.

Several authors may share a name, each with an identifier of its own. A
citation of a name that the run has registered with several identifiers
cannot say which of them is meant: its author is recorded by the name alone,
and a warning says so.

Call this before a source that names these authors is cited: an author
recorded by name alone is not given an identifier afterwards.
"""
function register_authors!(handle::DataRegistryHandle,
                           authors::Union{AbstractString,
                                          Pair{<:AbstractString,
                                               <:AbstractString}}...)
    found = Pair{String, String}[]
    for author in authors
        append!(found, _readauthors(author))
    end
    for (name, identifier) in found
        _registerauthor!(handle, name, identifier)
    end
    return sort!(unique!(first.(found)))
end

# The authors in one argument of `register_authors!`, as `name => identifier`:
# those of a TOML file of names and identifiers, in order of name
function _readauthors(file::AbstractString)
    isfile(file) || throw(ArgumentError("no file of authors at '$file'"))
    table = try
        TOML.parsefile(file)
    catch e
        e isa TOML.ParserError || rethrow()
        throw(ArgumentError("cannot read the file of authors $file: $(sprint(showerror, e))"))
    end
    authors = Pair{String, String}[]
    for name in sort!(collect(keys(table)))
        identifier = table[name]
        identifier isa AbstractString ||
            throw(ArgumentError("in $file, '$name' has no identifier in text: a line is \"name\" = \"https://...\""))
        push!(authors, _author(name, identifier))
    end
    return authors
end

# ... or the one author that a pair is
function _readauthors(author::Pair{<:AbstractString, <:AbstractString})
    return [_author(author.first, author.second)]
end

# A name and an identifier as the registry is to hold them, the identifier
# with `https:`, or an error if it cannot hold them
function _author(name::AbstractString, identifier::AbstractString)
    _checkauthorname(name)
    occursin(r"^https?://\S+$", identifier) ||
        throw(ArgumentError("the identifier of '$name' is not a URL: '$identifier' - write an ORCID or ROR id in full, as https://orcid.org/..."))
    return String(name) => replace(identifier, r"^http:" => "https:")
end

# Throw unless the registry can hold an author of this name
function _checkauthorname(name::AbstractString)
    isempty(strip(name)) && throw(ArgumentError("an author has no name"))
    _nameable(name) ||
        throw(ArgumentError("the registry cannot hold an author named '$name': it takes none of $(join(UNNAMEABLE, " ")) in a name"))
    return nothing
end

# Whether the registry can hold this text as a name, holding none of the
# characters it reads as a pattern
_nameable(name::AbstractString) = !any(in(UNNAMEABLE), name)

# Register an author with an identifier, unless the registry holds the
# identifier already, and have the name stand for that author in this run. An
# identifier keeps the name the registry has for it, which cannot be changed:
# another name is told of.
function _registerauthor!(handle::DataRegistryHandle, name::AbstractString,
                          identifier::AbstractString)
    query = Dict("identifier" => identifier)
    held = _getentry(handle.registry, "author", query)
    if isnothing(held)
        _createauthor(handle, name, identifier)
    elseif held["name"] != name
        known = isnothing(held["name"]) ? "with no name" :
                "as '$(held["name"])'"
        @info "the registry holds $identifier $known: an author cited as '$name' is recorded as that author"
    end
    identifiers = get!(handle.authors, name, String[])
    identifier in identifiers || push!(identifiers, identifier)
    return nothing
end

# Create the author in the registry
function _createauthor(handle::DataRegistryHandle{RecordedRun},
                       name::AbstractString, identifier::AbstractString)
    _createentry(handle.registry, "author",
                 Dict("name" => name, "identifier" => identifier))
    return nothing
end

"""
    _authorurl(handle, name)

Return the URL of the registry's author for a name that a citation gives. A
name registered in this run with one identifier is the author with that
identifier, whatever name the registry has for it. Any other name is an
author by the name alone, with a warning where the run has registered the
name with several identifiers, since it cannot say which of them is meant.
"""
function _authorurl(handle::DataRegistryHandle, name::AbstractString)
    return _authorurl(handle, name) do
        return _newnamedauthor(handle, name)
    end
end
# ... `create()` giving the author by the name alone where the registry has
# none
function _authorurl(create::Function, handle::DataRegistryHandle,
                    name::AbstractString)
    identifiers = get(handle.authors, name, String[])
    # Only a rehearsal leaves an identifier given in the run unregistered
    length(identifiers) == 1 &&
        return something(_geturl(handle.registry, "author",
                                 Dict("identifier" => only(identifiers))),
                         _unregisteredauthor(name))
    isempty(identifiers) ||
        @warn "'$name' is registered in this run with $(length(identifiers)) identifiers, $(join(identifiers, ", ")): a citation cannot say which is meant, so its author is recorded by the name alone"
    return _namedauthorurl(create, handle.registry, name)
end

# The URL of the registry's author of exactly this name and no identifier:
# the first that was registered, or a new one
function _namedauthorurl(handle::DataRegistryHandle, name::AbstractString)
    return _namedauthorurl(handle.registry, name) do
        return _newnamedauthor(handle, name)
    end
end
# ... in a registry, `create()` making the author where it has none
function _namedauthorurl(create::Function, registry::RegistryEndpoint,
                         name::AbstractString)
    # With no pattern character in it, a name is looked up as it is written
    _checkauthorname(name)
    unidentified = [author
                    for author in _getentries(registry, "author",
                                              Dict("name" => name))
                    if isnothing(author["identifier"])]
    isempty(unidentified) && return create()
    # The first is the one that stays the same when another is registered
    oldest = argmin(unidentified) do author
        return parse(Int, _extractid(author["url"]))
    end
    return oldest["url"]
end

# Create an author of this name alone and return its URL
function _newnamedauthor(handle::DataRegistryHandle{RecordedRun},
                         name::AbstractString)
    return _createentry(handle.registry, "author", Dict("name" => name))["url"]
end
