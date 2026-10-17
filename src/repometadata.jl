# SPDX-License-Identifier: LGPL-3.0-or-later

# What a code repository says of itself in its metadata files - its authors,
# licence, keywords, description, version and title - read from the files as
# they are at a commit of a clone, in a working tree, or at a commit on GitHub.

"""
    RepositoryMetadata

What a code repository's metadata files say of it. Each field is taken from
the first file, in the order of `REPOSITORY_METADATA_FILES`, that holds it;
the authors are the list of the first file that has one, a later file only
adding an identifier to an author it names the same way.

# Fields
- `authors`: the authors in order, a person as given names then family name,
  an organisation as it is written
- `identifiers`: the ORCID or ROR id of an author, by name, as a URL
- `licence`: the licence as written, an SPDX identifier or a URL, or `nothing`
- `keywords`: the keywords, none where no file has any
- `description`: what the code is, or `nothing`
- `version`: the version as written, or `nothing`
- `title`: the code's name or title, or `nothing`
- `files`: the files read, in order
"""
struct RepositoryMetadata
    authors::Vector{String}
    identifiers::Dict{String, String}
    licence::Union{Nothing, String}
    keywords::Vector{String}
    description::Union{Nothing, String}
    version::Union{Nothing, String}
    title::Union{Nothing, String}
    files::Vector{String}
end

# == Functions ==

# What a repository's metadata files say at a commit of a clone ...
function _repositorymetadata(clone::LibGit2.GitRepo, commit::AbstractString)
    return _repositorymetadata("commit $commit") do name
        return _committedtext(clone, commit, name)
    end
end
# ... in a working tree, the folder at its top level ...
function _repositorymetadata(folder::AbstractString)
    return _repositorymetadata("the working tree at $folder") do name
        path = joinpath(folder, name)
        return isfile(path) ? read(path, String) : nothing
    end
end
# ... or at a commit of a repository named by its remote's URL, whose files
# can be had with no clone only from GitHub, at the commit's own hash; `fetch`
# gives a URL's text, or `nothing`
function _repositorymetadata(remote::AbstractString, commit::AbstractString;
                             fetch::Function = _fetchtext)
    path = _githubpath(remote)
    isnothing(path) && return _repositorymetadata(_ -> nothing, remote)
    return _repositorymetadata("commit $commit of $remote") do name
        return fetch("https://raw.githubusercontent.com/$path/$commit/$name")
    end
end

# What the metadata files say, `text(name)` giving each file's text or
# `nothing` where there is none, `place` saying where they are read from
function _repositorymetadata(text::Function, place::AbstractString)
    authors = String[]
    authors_from = nothing
    identifiers = Dict{String, String}()
    fields = Dict{Symbol, Any}()
    keywords = String[]
    files = String[]
    for (name, reader) in REPOSITORY_METADATA_FILES
        content = text(name)
        isnothing(content) && continue
        said = try
            reader(content)
        catch err
            err isa InterruptException && rethrow()
            @warn "cannot read $name at $place, so it is passed over: $(sprint(showerror, err))"
            continue
        end
        push!(files, name)
        if isnothing(authors_from)
            if !isempty(said.authors)
                append!(authors, said.authors)
                merge!(identifiers, said.identifiers)
                authors_from = name
            end
        else
            _addidentifiers!(identifiers, authors, authors_from, said, name)
        end
        for field in (:licence, :description, :version, :title)
            value = getfield(said, field)
            isnothing(value) || get!(fields, field, value)
        end
        isempty(keywords) && append!(keywords, said.keywords)
    end
    return RepositoryMetadata(authors, identifiers,
                              get(fields, :licence, nothing), keywords,
                              get(fields, :description, nothing),
                              get(fields, :version, nothing),
                              get(fields, :title, nothing), files)
end

# Give the authors read already the identifiers that a later file gives the
# same names, telling of each, since the earlier file is trusted more and
# lacked it; an identifier that differs from the earlier file's is passed over
function _addidentifiers!(identifiers::Dict{String, String},
                          authors::Vector{String}, authors_from::String,
                          said::NamedTuple, name::String)
    for (author, identifier) in said.identifiers
        index = findfirst(==(_namekey(author)), _namekey.(authors))
        isnothing(index) && continue
        known = authors[index]
        held = get(identifiers, known, nothing)
        if isnothing(held)
            identifiers[known] = identifier
            @info "$name gives $known the identifier $identifier, which $authors_from lacks"
        elseif held != identifier
            @warn "$name gives $known the identifier $identifier, and $authors_from gives $held, which is kept"
        end
    end
    return nothing
end

# A name as two files are compared by it: in lower case, without full stops
# and with its white space single
function _namekey(name::AbstractString)
    return lowercase(join(split(replace(name, '.' => ' ')),
                          " "))
end

# The text of a file as it is at a commit, or `nothing` where the commit has
# no such file
function _committedtext(clone::LibGit2.GitRepo, commit::AbstractString,
                        path::AbstractString)
    object = try
        LibGit2.GitObject(clone, "$commit:$path")
    catch err
        (err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND) ||
            rethrow()
        return nothing
    end
    return LibGit2.with(object) do found
        return found isa LibGit2.GitBlob ? LibGit2.content(found) : nothing
    end
end

# The `<owner>/<repository>` of a remote on GitHub, without `.git`, or
# `nothing` for a remote anywhere else
function _githubpath(remote::AbstractString)
    location = _repositorylocation(remote)
    location.root == "https://github.com/" || return nothing
    return replace(location.path, r"\.git$" => "")
end

# The text at a URL, or `nothing` where there is none; a server or a network
# that cannot be reached is warned of, and gives nothing too
function _fetchtext(url::AbstractString)
    response = try
        HTTP.get(url, status_exception = false)
    catch err
        err isa Union{Base.IOError, HTTP.ConnectError, HTTP.TimeoutError} ||
            rethrow()
        @warn "cannot reach $url, so it is passed over: $(sprint(showerror, err))"
        return nothing
    end
    response.status == 404 && return nothing
    if response.status != 200
        @warn "$url answered HTTP status $(response.status), so it is passed over"
        return nothing
    end
    return String(response.body)
end

# What one metadata file says, any field that it does not hold empty
function _filesays(; authors = String[],
                   identifiers = Dict{String, String}(), licence = nothing,
                   keywords = String[], description = nothing,
                   version = nothing, title = nothing)
    return (authors = authors, identifiers = identifiers, licence = licence,
            keywords = keywords, description = description, version = version,
            title = title)
end

# Authors in order with their identifiers, `person(entry)` giving each entry's
# name and identifier, either `nothing` where it has none
function _authorsof(person::Function, entries::AbstractVector)
    authors = String[]
    identifiers = Dict{String, String}()
    for entry in entries
        entry isa AbstractDict || continue
        found = person(entry)
        isnothing(found.name) && continue
        push!(authors, found.name)
        isnothing(found.identifier) ||
            get!(identifiers, found.name, found.identifier)
    end
    return (authors = authors, identifiers = identifiers)
end

# An ORCID or ROR id as the registry holds one, a URL with `https:`, from its
# URL or a bare ORCID; `nothing` for anything else
function _authoridentifier(value::AbstractString)
    value = strip(value)
    occursin(r"^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$", value) &&
        return "https://orcid.org/$value"
    occursin(r"^https?://(orcid|ror)\.org/\S+$", value) &&
        return replace(value, r"^http:" => "https:")
    return nothing
end
_authoridentifier(::Any) = nothing

# A value that metadata may give as one item or a list, as a list
_aslist(::Nothing) = []
_aslist(items::AbstractVector) = items
_aslist(item) = [item]

# Keywords given as a list of words or as one string of them, comma-separated
function _keywordsof(value)
    words = String[]
    for item in _aslist(value)
        item isa AbstractString || continue
        for word in split(item, ',')
            plain = _plain(word)
            isnothing(plain) || push!(words, plain)
        end
    end
    return words
end

# A licence given as an identifier, a URL, a list of them or an object naming
# one, as the first identifier or URL given
function _licenceof(value)
    for item in _aslist(value)
        item isa AbstractString && return _plain(item)
        item isa AbstractDict || continue
        for key in ("@id", "id", "url")
            named = get(item, key, nothing)
            named isa AbstractString && return _plain(named)
        end
    end
    return nothing
end

# The text of a field, or `nothing` where it is missing or not text
_textof(value::Union{AbstractString, Number}) = _plain(value)
_textof(::Any) = nothing

# What `codemeta.json` says: a person by `givenName` and `familyName` (either
# possibly a list) or `name`, identified by `@id`, `id` or `identifier`; an
# organisation by `name`
function _codemetasays(text::AbstractString)
    meta = JSON.parse(text)
    meta isa AbstractDict ||
        throw(ArgumentError("codemeta.json holds no JSON object"))
    people = _authorsof(_aslist(get(meta, "author", nothing))) do person
        given = _textof(join(filter(x -> x isa AbstractString,
                                    _aslist(get(person, "givenName",
                                                nothing))), " "))
        family = _textof(join(filter(x -> x isa AbstractString,
                                     _aslist(get(person, "familyName",
                                                 nothing))), " "))
        name = (!isnothing(given) && !isnothing(family)) ? "$given $family" :
               _textof(get(person, "name", nothing))
        identifier = nothing
        for key in ("@id", "id", "identifier")
            identifier = _authoridentifier(get(person, key, nothing))
            isnothing(identifier) || break
        end
        return (name = name, identifier = identifier)
    end
    version = _textof(get(meta, "version", nothing))
    return _filesays(authors = people.authors,
                     identifiers = people.identifiers,
                     licence = _licenceof(get(meta, "license", nothing)),
                     keywords = _keywordsof(get(meta, "keywords", nothing)),
                     description = _markupless(_textof(get(meta, "description",
                                                           nothing))),
                     version = isnothing(version) ?
                               _textof(get(meta, "softwareVersion", nothing)) :
                               version,
                     title = _textof(get(meta, "name", nothing)))
end

# What `.zenodo.json` says: a creator by `name`, "Family, Given" for a person,
# identified by `orcid`, bare or as a URL
function _zenodosays(text::AbstractString)
    meta = JSON.parse(text)
    meta isa AbstractDict ||
        throw(ArgumentError(".zenodo.json holds no JSON object"))
    people = _authorsof(_aslist(get(meta, "creators", nothing))) do creator
        written = _textof(get(creator, "name", nothing))
        isnothing(written) && return (name = nothing, identifier = nothing)
        parts = split(written, ',', limit = 2)
        name = length(parts) == 2 ? _plain(string(parts[2], " ", parts[1])) :
               written
        return (name = name,
                identifier = _authoridentifier(get(creator, "orcid", nothing)))
    end
    return _filesays(authors = people.authors,
                     identifiers = people.identifiers,
                     licence = _licenceof(get(meta, "license", nothing)),
                     keywords = _keywordsof(get(meta, "keywords", nothing)),
                     description = _markupless(_textof(get(meta, "description",
                                                           nothing))),
                     version = _textof(get(meta, "version", nothing)),
                     title = _textof(get(meta, "title", nothing)))
end

# What `CITATION.cff` says: a person by `given-names`, `name-particle`,
# `family-names` and `name-suffix`, identified by `orcid`; an entity by `name`
function _citationcffsays(text::AbstractString)
    meta = YAML.load(text)
    meta isa AbstractDict ||
        throw(ArgumentError("CITATION.cff holds no YAML mapping"))
    people = _authorsof(_aslist(get(meta, "authors", nothing))) do person
        parts = [_textof(get(person, key, nothing))
                 for key in ("given-names", "name-particle", "family-names",
                     "name-suffix")]
        name = isnothing(parts[3]) ? _textof(get(person, "name", nothing)) :
               join(filter(!isnothing, parts), " ")
        return (name = name,
                identifier = _authoridentifier(get(person, "orcid", nothing)))
    end
    return _filesays(authors = people.authors,
                     identifiers = people.identifiers,
                     licence = _licenceof(get(meta, "license", nothing)),
                     keywords = _keywordsof(get(meta, "keywords", nothing)),
                     description = _markupless(_textof(get(meta, "abstract",
                                                           nothing))),
                     version = _textof(get(meta, "version", nothing)),
                     title = _textof(get(meta, "title", nothing)))
end

# What a Julia project file says, from Pkg's own fields alone: its `name`,
# `version` and `authors`, each "Name <email>", with no identifiers
function _projectsays(text::AbstractString)
    project = TOML.parse(text)
    authors = String[]
    for written in _aslist(get(project, "authors", nothing))
        written isa AbstractString || continue
        name = _plain(replace(written, r"<[^<>]*>" => " "))
        isnothing(name) || push!(authors, name)
    end
    return _filesays(authors = authors,
                     version = _textof(get(project, "version", nothing)),
                     title = _textof(get(project, "name", nothing)))
end

# The files a repository's metadata is read from, most trusted first, with the
# reader of each; a Julia project file under either name Pkg reads it by, in
# Pkg's order
const REPOSITORY_METADATA_FILES = ("codemeta.json" => _codemetasays,
                                   ".zenodo.json" => _zenodosays,
                                   "CITATION.cff" => _citationcffsays,
                                   "JuliaProject.toml" => _projectsays,
                                   "Project.toml" => _projectsays)
