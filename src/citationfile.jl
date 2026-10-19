# SPDX-License-Identifier: LGPL-3.0-or-later

# A paper's citation in `CITATION.cff`: drafted from the paper's LaTeX, compared
# with it - its authors' names and order, and its title - and brought into line
# with it by rewriting those alone, every other byte of the file kept. The
# paper's citation is the file's `preferred-citation` where it has one, else its
# top level (`_papercitation`).

# == Functions ==

# Whether the repository at `top` holds a package, whose citation the top level
# of `CITATION.cff` then is: one described by `codemeta.json`, or a Julia
# package, whose project file names it with a `uuid` - an environment's project
# file has neither
function _holdspackage(top::AbstractString)
    isfile(joinpath(top, "codemeta.json")) && return true
    for name in ("JuliaProject.toml", "Project.toml")
        path = joinpath(top, name)
        isfile(path) || continue
        project = try
            TOML.parsefile(path)
        catch
            continue
        end
        haskey(project, "name") && haskey(project, "uuid") && return true
    end
    return false
end

# A draft `CITATION.cff` for a paper whose front matter `front` gives its title,
# authors and their affiliations: the paper at the top level, or, where
# `package` gives the title, authors and their identifiers of a package the
# repository holds, as its `RepositoryMetadata` does, the package at the top
# level, as the format requires one there, and the paper as its
# `preferred-citation`
function _draftcitation(front::NamedTuple, package::Union{Nothing, NamedTuple})
    _checkcitable(front)
    lines = ["cff-version: 1.2.0"]
    if isnothing(package)
        push!(lines,
              "message: \"If you use this paper, please cite it as below.\"",
              "title: $(_yamlquoted(front.title))", "authors:")
        append!(lines, _authorentries(front, 2))
    else
        push!(lines,
              "message: \"If you use this software, please cite the paper in preferred-citation, and the software itself.\"",
              "title: $(_yamlquoted(package.title))", "authors:")
        for name in package.authors
            orcid = get(package.identifiers, name, nothing)
            isnothing(orcid) || startswith(orcid, "https://orcid.org/") ||
                (orcid = nothing)
            append!(lines, _authorentry(name, String[], 2, 4; orcid))
        end
        append!(lines, _preferredlines(front))
    end
    return join(lines, "\n") * "\n"
end

# Check that a paper's front matter gives what its citation needs, a title and
# authors, saying all that is missing and how to give it
function _checkcitable(front::NamedTuple)
    missing = String[]
    isnothing(front.title) && push!(missing, "no \\title")
    isempty(front.authors) && push!(missing, "no \\author")
    isempty(missing) ||
        throw(ReadWriteException("the paper has $(join(missing, " and ")), which its citation needs: give its title with \\title{...} and each author with an \\author{...} of their own - in the preamble they put nothing on the page unless \\maketitle is used, so a title and authors typeset by hand can stay as they are"))
    return nothing
end

# The lines of a `preferred-citation` for a paper
function _preferredlines(front::NamedTuple)
    lines = ["preferred-citation:", "  type: article",
        "  title: $(_yamlquoted(front.title))", "  authors:"]
    return append!(lines, _authorentries(front, 4))
end

# `CITATION.cff`'s text with a `preferred-citation` for the paper added at its
# end, the file having none; everything before it is kept as it is
function _addpreferred(text::AbstractString, front::NamedTuple)
    _checkcitable(front)
    head = endswith(text, "\n") || isempty(text) ? text : text * "\n"
    return head * join(_preferredlines(front), "\n") * "\n"
end

# The lines of the author entries for a front matter's authors, each dash
# indented by `indent`
function _authorentries(front::NamedTuple, indent::Integer)
    lines = String[]
    for (name, affiliations) in zip(front.authors, front.affiliations)
        append!(lines, _authorentry(name, affiliations, indent, indent + 2))
    end
    return lines
end

# The lines of one author's entry: the dash indented by `dash`, the keys after
# the first by `keys`; a best guess at the parts of the name, the affiliations
# joined, and the ORCID where one is known
function _authorentry(name::AbstractString, affiliations::AbstractVector,
                      dash::Integer, keys::Integer;
                      orcid::Union{Nothing, AbstractString} = nothing)
    fields = _cffperson(name)
    isnothing(orcid) || push!(fields, "orcid" => orcid)
    isempty(affiliations) ||
        push!(fields, "affiliation" => join(affiliations, "; "))
    lines = String[]
    for (k, (key, value)) in enumerate(fields)
        lead = k == 1 ? " "^dash * "- " : " "^keys
        push!(lines, lead * "$key: $(_yamlquoted(value))")
    end
    return lines
end

# The words that join a family name rather than start one
const _NAME_PARTICLES = ("van", "von", "der", "den", "de", "del", "della", "di",
                         "da", "du", "la", "le", "ten", "ter", "op", "zu",
                         "dos", "das", "do", "y")

# A person's name as `CITATION.cff` holds one, a best guess for a draft: the
# last word the family name, a suffix such as `Jr.` after it kept apart, the
# lower-case particles before it as `name-particle`, the rest given names
function _cffperson(name::AbstractString)
    words = split(name)
    suffix = nothing
    if length(words) > 2 &&
       occursin(r"^(Jr|Sr)\.?$|^(II|III|IV)$", last(words))
        suffix = pop!(words)
    end
    length(words) == 1 && return ["family-names" => String(only(words))]
    family = pop!(words)
    particle = String[]
    while !isempty(words) && lowercase(last(words)) in _NAME_PARTICLES &&
          islowercase(first(last(words)))
        pushfirst!(particle, pop!(words))
    end
    fields = Pair{String, String}["family-names" => String(family)]
    isempty(words) || push!(fields, "given-names" => join(words, " "))
    isempty(particle) || push!(fields, "name-particle" => join(particle, " "))
    isnothing(suffix) || push!(fields, "name-suffix" => String(suffix))
    return fields
end

# A string as YAML writes it double-quoted, so that no name or title is read as
# anything else
function _yamlquoted(text::AbstractString)
    return "\"" *
           replace(text, "\\" => "\\\\", "\"" => "\\\"") *
           "\""
end

# A name as two lists of authors are compared by it, whichever way its accents
# are encoded
_authorkey(name::AbstractString) = _namekey(Base.Unicode.normalize(name, :NFC))

# How the paper's citation in `CITATION.cff`'s text differs from its front
# matter `front`: the title where it differs, as `(file, latex)`; the names
# the LaTeX has that the file does not, and those the file has that the LaTeX
# does not; whether the names the two share are in another order; whether names are both added and removed, which may be
# a renaming; and the authors the file gives no ORCID
function _comparecitation(text::AbstractString, front::NamedTuple)
    return _comparecitation(_citationcffsays(_papercitation(_cffmapping(text))),
                            front)
end
# ... or how what metadata says of the paper - its authors, their identifiers
# and its title - differs from it
function _comparecitation(said::Union{NamedTuple, RepositoryMetadata},
                          front::NamedTuple)
    filekeys = _authorkey.(said.authors)
    latexkeys = _authorkey.(front.authors)
    added = [name
             for (name, key) in zip(front.authors, latexkeys)
             if !(key in filekeys)]
    removed = [name
               for (name, key) in zip(said.authors, filekeys)
               if !(key in latexkeys)]
    shared_file = [key for key in filekeys if key in latexkeys]
    shared_latex = [key for key in latexkeys if key in filekeys]
    title = isnothing(front.title) || said.title == front.title ? nothing :
            (file = said.title, latex = front.title)
    unidentified = [name
                    for name in said.authors
                    if !haskey(said.identifiers, name) &&
        _authorkey(name) in latexkeys]
    return (title = title, added = added, removed = removed,
            reordered = shared_file != shared_latex,
            renaming = !isempty(added) && !isempty(removed),
            unidentified = unidentified)
end

# `CITATION.cff`'s text with the paper's citation brought into line with its
# front matter `front`, and what was changed, as `(text, changes)`. Only the
# citation's author entries and its title are rewritten: an author's entry is
# moved whole, an author added has an entry drafted, without an ORCID, and one
# removed has theirs dropped; names both added and removed may be a renaming,
# so the authors are then left as they are, and both are said. The new text is
# read back, and must give the LaTeX's names and title with everything else in
# the file as it was, or nothing is changed and this is an error
function _updatecitation(text::AbstractString, front::NamedTuple)
    compared = _comparecitation(text, front)
    lines = split(text, '\n'; keepempty = true)
    changes = String[]
    citation = _citationrange(lines)
    if compared.renaming
        push!(changes,
              "authors left as they are, since $(join(compared.removed, ", ")) removed and $(join(compared.added, ", ")) added may be a renaming: change the file by hand")
    elseif compared.reordered || !isempty(compared.added) ||
           !isempty(compared.removed)
        lines = _rewriteauthors(lines, citation, front)
        compared.reordered && push!(changes, "authors put in the LaTeX's order")
        for name in compared.added
            push!(changes, "$name added, with no ORCID")
        end
        for name in compared.removed
            push!(changes, "$name removed")
        end
        citation = _citationrange(lines)
    end
    if !isnothing(compared.title)
        lines = _rewritetitle(lines, citation, front.title)
        push!(changes,
              "title changed from $(repr(compared.title.file)) to $(repr(compared.title.latex))")
    end
    updated = join(lines, '\n')
    _checkupdate(text, updated, front, compared.renaming)
    return (text = updated, changes = changes)
end

# Where the paper's citation is in the lines of `CITATION.cff`: the lines its
# keys are on, as a range, and the indentation of its keys. The
# `preferred-citation`'s, where there is one, else the file's top level
function _citationrange(lines::AbstractVector)
    for (k, line) in enumerate(lines)
        occursin(r"^preferred-citation:\s*(#.*)?$", line) || continue
        last_line = k
        indent = nothing
        for j in (k + 1):length(lines)
            _isfiller(lines[j]) && continue
            _indent(lines[j]) == 0 && break
            last_line = j
            isnothing(indent) && (indent = _indent(lines[j]))
        end
        return (lines = (k + 1):last_line, indent = something(indent, 2))
    end
    return (lines = 1:length(lines), indent = 0)
end

# Whether a line holds nothing to read: blank, or a comment alone
_isfiller(line::AbstractString) = occursin(r"^\s*(#.*)?$", line)

# How far a line is indented
_indent(line::AbstractString) = length(line) - length(lstrip(line, ' '))

# The line of the key `key` in the citation `citation` covers, at its keys'
# indentation, or `nothing` where it has none
function _keyline(lines::AbstractVector, citation::NamedTuple,
                  key::AbstractString)
    pattern = Regex("^ {$(citation.indent)}" * key * ":(\\s|\$)")
    for k in citation.lines
        occursin(pattern, lines[k]) && return k
    end
    return nothing
end

# The citation's author entries: the line of the `authors` key, the column of
# the entries' dashes, and each entry as a range of lines, comments and blank
# lines just before an entry going with it, but for the first's, which stay
# under the key; a list written in flow style,
# `[...]`, is refused, since its entries cannot be moved one by one
function _authorblock(lines::AbstractVector, citation::NamedTuple)
    key = _keyline(lines, citation, "authors")
    isnothing(key) &&
        throw(ReadWriteException("the paper's citation in CITATION.cff has no authors list to update"))
    occursin(r"^\s*authors:\s*(#.*)?$", lines[key]) ||
        throw(ReadWriteException("the paper's citation in CITATION.cff writes its authors on the line of `authors:`, as a flow list: write each author's entry on lines of their own, beginning `- `, to have them updated"))
    dash = nothing
    starts = Int[]
    stop = key
    for j in (key + 1):last(citation.lines)
        line = lines[j]
        if _isfiller(line)
            continue
        end
        column = _indent(line)
        isdash = startswith(lstrip(line, ' '), "-")
        if isnothing(dash)
            (isdash && column >= citation.indent) || break
            dash = column
        end
        if isdash && column == dash
            push!(starts, j)
        elseif column <= dash
            break
        end
        stop = j
    end
    isempty(starts) &&
        throw(ReadWriteException("the paper's citation in CITATION.cff has no author entries to update"))
    entries = UnitRange{Int}[]
    for (n, start) in enumerate(starts)
        finish = n == length(starts) ? stop : starts[n + 1] - 1
        # The comments and blank lines just before the next entry are its own
        if n < length(starts)
            while finish > start && _isfiller(lines[finish])
                finish -= 1
            end
        end
        lead = start
        while n > 1 && _isfiller(lines[lead - 1]) &&
              lead - 1 > last(entries[n - 1])
            lead -= 1
        end
        push!(entries, lead:finish)
    end
    return (key = key, dash = dash, entries = entries)
end

# The name an author entry's lines give, read as `_citationcffsays` reads it
function _entryname(lines::AbstractVector, entry::UnitRange{Int}, dash::Integer)
    text = join([_isfiller(line) ? "" : line[(dash + 1):end]
                 for line in lines[entry]], '\n')
    parsed = YAML.load(text)
    said = _citationcffsays(Dict("authors" =>
                                     parsed isa AbstractVector ?
                                     parsed : Any[]))
    isempty(said.authors) &&
        throw(ReadWriteException("cannot tell whose entry the lines $(first(entry))-$(last(entry)) of CITATION.cff are"))
    return only(said.authors)
end

# The lines with the citation's author entries in the LaTeX's order: an entry
# kept whole, moved where its author is; one drafted for an author added, as
# indented as the others; and one of an author removed dropped
function _rewriteauthors(lines::AbstractVector, citation::NamedTuple,
                         front::NamedTuple)
    block = _authorblock(lines, citation)
    byname = Dict(_authorkey(_entryname(lines, entry, block.dash)) => entry
                  for entry in block.entries)
    first_entry = first(block.entries)
    dashline = lines[findfirst(k -> startswith(lstrip(lines[k], ' '), "-"),
                               collect(first_entry)) + first(first_entry) - 1]
    keys = block.dash + 2
    after = match(r"^\s*-\s+", dashline)
    isnothing(after) || (keys = length(after.match))
    rewritten = String[]
    for (name, affiliations) in zip(front.authors, front.affiliations)
        entry = get(byname, _authorkey(name), nothing)
        if isnothing(entry)
            append!(rewritten,
                    _authorentry(name, affiliations, block.dash, keys))
        else
            append!(rewritten, lines[entry])
        end
    end
    span = first(first(block.entries)):last(last(block.entries))
    return vcat(lines[1:(first(span) - 1)], rewritten,
                lines[(last(span) + 1):end])
end

# The lines with the citation's title rewritten as `title`, double-quoted on
# its key's line, any lines its old value went on over removed
function _rewritetitle(lines::AbstractVector, citation::NamedTuple,
                       title::AbstractString)
    key = _keyline(lines, citation, "title")
    pad = " "^citation.indent
    isnothing(key) &&
        throw(ReadWriteException("the paper's citation in CITATION.cff has no title to update"))
    finish = key
    for j in (key + 1):last(citation.lines)
        (_isfiller(lines[j]) || _indent(lines[j]) <= citation.indent) && break
        finish = j
    end
    return vcat(lines[1:(key - 1)], [pad * "title: " * _yamlquoted(title)],
                lines[(finish + 1):end])
end

# Check that an updated `CITATION.cff` gives the LaTeX's names, unless they
# were left for a possible renaming, and its title, and that everything else
# in it reads as it did
function _checkupdate(before::AbstractString, after::AbstractString,
                      front::NamedTuple, renaming::Bool)
    old = _cffmapping(before)
    new = try
        _cffmapping(after)
    catch err
        err isa InterruptException && rethrow()
        throw(ReadWriteException("updating CITATION.cff would leave it unreadable, so it is left as it was: $(sprint(showerror, err))"))
    end
    said = _citationcffsays(_papercitation(new))
    renaming ||
        _authorkey.(said.authors) == _authorkey.(front.authors) ||
        throw(ReadWriteException("updating CITATION.cff would not give the paper's authors as the LaTeX has them, so it is left as it was"))
    isnothing(front.title) || said.title == front.title ||
        throw(ReadWriteException("updating CITATION.cff would not give the paper's title as the LaTeX has it, so it is left as it was"))
    _withoutcitation(old) == _withoutcitation(new) ||
        throw(ReadWriteException("updating CITATION.cff would change more than the paper's authors and title, so it is left as it was"))
    kept = _entriesbyname(_papercitation(old))
    for (key, entry) in _entriesbyname(_papercitation(new))
        (haskey(kept, key) && kept[key] != entry) &&
            throw(ReadWriteException("updating CITATION.cff would change an author's entry, so it is left as it was"))
    end
    return nothing
end

# A citation's author entries, by the key of each author's name
function _entriesbyname(citation::AbstractDict)
    entries = Dict{String, Any}()
    for entry in _aslist(get(citation, "authors", nothing))
        entry isa AbstractDict || continue
        said = _citationcffsays(Dict("authors" => Any[entry]))
        isempty(said.authors) ||
            (entries[_authorkey(only(said.authors))] = entry)
    end
    return entries
end

# A `CITATION.cff` mapping without the paper's citation's authors and title,
# for comparing what else it holds
function _withoutcitation(meta::AbstractDict)
    copy = deepcopy(meta)
    citation = _papercitation(copy)
    delete!(citation, "authors")
    delete!(citation, "title")
    return copy
end
