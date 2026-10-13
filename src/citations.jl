# SPDX-License-Identifier: LGPL-3.0-or-later

# Citations of the sources that registered files come from: reading them from
# BibTeX, looking one up from its DOI, and drawing from one the facts of a
# source as the registry records them.

# Where a DOI resolves, and so the form its URL takes as an identifier
const DOI_RESOLVER = "https://doi.org/"
# A DOI, bare or as the URL or `doi:` form of one
const DOI_NAME = r"^(?:https?://(?:dx\.)?doi\.org/|doi:\s*)?(10\.\d{4,9}/\S+)$"i
# The version the registry gives a source that has none
const DEFAULT_RELEASE_VERSION = "1.0.0"
# English month names, which a BibTeX month may be written as or abbreviated to
const MONTH_NAMES = lowercase.(monthname.(1:12))

"""
    register_citations!(handle, citations...)

Read citations of the sources that files come from, and keep them in the
handle for the rest of the code run, each under its own key. Return the keys
of the entries read, in order.

Each of `citations` is BibTeX text if it starts with `@`, and otherwise the
path of a BibTeX file; either may hold several entries. An entry of any type
is accepted, `@dataset` among them. A value written as an abbreviation must
be defined in the same text, by `@string` with its value in quotes; a month
may be a number, a name or an abbreviation of one. An entry may be read more
than once, but two different entries with one key are an error, and so is a
citation from which no entry can be read; a call that fails keeps nothing.
Nothing is sent to the registry.

From an entry are taken its `doi`, as a URL in lower case, or else its `url`,
to identify the source; its `title`; its `author`s, a person as given names
then family name and an organisation as it is written; its `date`, or its
`year`, `month` and `day` as far as they go, as the source's release date; its
`version`; and its `note`, as a description. Braces are dropped, and LaTeX
commands are left as they are.
"""
function register_citations!(handle::DataRegistryHandle,
                             citations::AbstractString...)
    found = SourceCitation[]
    for citation in citations
        append!(found, _readcitations(citation))
    end
    known = copy(handle.citations)
    for citation in found
        _addcitation!(known, citation)
    end
    merge!(handle.citations, known)
    return [citation.key for citation in found]
end

# The citations in one argument of `register_citations!`: BibTeX text if it
# starts with `@`, else the path of a BibTeX file
function _readcitations(citation::AbstractString)
    startswith(lstrip(citation), '@') &&
        return _parsecitations(citation, "the BibTeX text")
    # Text that is not a path can be more than the file system will look up
    found = try
        isfile(citation)
    catch e
        e isa Base.IOError || rethrow()
        false
    end
    if !found
        # Text of several lines was never a path: its first line says enough
        shown = occursin('\n', citation) ?
                first(split(citation, '\n')) * "..." : citation
        throw(ArgumentError("no BibTeX file at '$shown': a citation that does not start with @ is taken for the path of a file"))
    end
    return _parsecitations(read(citation, String), "the BibTeX file $citation")
end

# Add a citation to those held by key. The same citation again changes
# nothing; a different one under a key that is taken is an error.
function _addcitation!(citations::Dict{String, SourceCitation},
                       citation::SourceCitation)
    held = get!(citations, citation.key, citation)
    _samecitation(held, citation) ||
        throw(ArgumentError("two different citations have the key '$(citation.key)'"))
    return citations
end

# Whether two citations have one key and say the same of their source
function _samecitation(a::SourceCitation, b::SourceCitation)
    return a.key == b.key && _samesource(a, b)
end

# Whether two citations say the same of their source, field by field,
# whatever their keys
function _samesource(a::SourceCitation, b::SourceCitation)
    return all(getfield(a, name) == getfield(b, name)
               for name in fieldnames(SourceCitation) if name != :key)
end

"""
    _parsecitations(text, what)

Return the citations in BibTeX `text`, in order, a key that is repeated with
the same fields being read once. `what` says where the text came from, for the
error thrown when it holds no entry that can be read, uses an abbreviation it
does not define, or uses one key for two different entries.
"""
function _parsecitations(text::AbstractString, what::AbstractString)
    document = try
        # An IO, since a string on one line is first tried as a path
        BibParser.parse_bibliography(IOBuffer(_bracemonths(text)),
                                     format = :BibTeX, check = :none)
    catch e
        e isa KeyError || rethrow()
        throw(ArgumentError("cannot read $what: it uses the abbreviation \"$(e.key)\", which it does not define"))
    end
    isempty(document.entries) &&
        throw(ArgumentError("no BibTeX entry can be read from $what"))

    # The parser gives a repeated key the first entry's contents, so the
    # fields as written are what tell two entries apart
    fields = Dict{String, Set{Tuple{String, String}}}()
    citations = SourceCitation[]
    for entry in document.entries
        key = entry.raw.key
        written = Set((lowercase(field.name), field.value)
                      for field in entry.raw.fields)
        if haskey(fields, key)
            fields[key] == written ||
                throw(ArgumentError("the key '$key' is used for two different entries in $what"))
        else
            fields[key] = written
            push!(citations, _sourcecitation(entry.canonical))
        end
    end
    return citations
end

# Put braces round a month written as a bare word. BibTeX takes a bare word
# for an abbreviation and defines only the twelve lower-case ones, so a month
# written `May`, as Crossref writes it, cannot otherwise be read.
function _bracemonths(text::AbstractString)
    return replace(text,
                   r"(\bmonth\s*=\s*)([A-Za-z]+)(\s*[,}])"i => s"\1{\2}\3")
end

# What a parsed BibTeX entry says of its source
function _sourcecitation(entry::BibInternal.Entry)
    authors = String[name
                     for name in map(_personname, entry.authors)
                     if !isnothing(name)]
    return SourceCitation(entry.id, _entryidentifier(entry),
                          _unbrace(entry.title), authors, _entrydate(entry),
                          _unbrace(get(entry.fields, "version", "")),
                          _unbrace(entry.note))
end

# A field of an entry as plain text: its braces dropped and its white space
# single, or `nothing` if that leaves nothing
function _unbrace(text::AbstractString)
    plain = strip(replace(text, r"[{}]" => "", r"\s+" => " "))
    return isempty(plain) ? nothing : String(plain)
end

# An author as the registry names one: a person's given names and then family
# name, and an organisation, which BibTeX holds whole as a family name, as it
# is written
function _personname(name::BibInternal.Name)
    parts = (name.first, name.middle, name.particle, name.last, name.junior)
    return _unbrace(join(parts, " "))
end

# What identifies an entry's source: its DOI as a URL, else its URL - as a DOI
# again if it is the URL of one - else nothing
function _entryidentifier(entry::BibInternal.Entry)
    doi = _trydoiurl(entry.access.doi)
    isnothing(doi) || return doi
    url = strip(entry.access.url)
    isempty(url) && return nothing
    return something(_trydoiurl(url), String(url))
end

# The URL of a DOI in the one form used to identify a source, or `nothing` if
# the text is not a DOI. A DOI is the same in any case, and a source's
# identity is a string, so lower case is used throughout.
function _trydoiurl(doi::AbstractString)
    name = match(DOI_NAME, strip(doi))
    return isnothing(name) ? nothing : DOI_RESOLVER * lowercase(name[1])
end

# The same, for a DOI that the caller gave
function _doiurl(doi::AbstractString)
    url = _trydoiurl(doi)
    isnothing(url) && throw(ArgumentError("not a DOI: '$doi'"))
    return url
end

# The release date an entry gives: its `date`, which starts with a date in ISO
# form, or else its year, month and day
function _entrydate(entry::BibInternal.Entry)
    iso = match(r"^\s*(\d{4})(?:-(\d{1,2})(?:-(\d{1,2}))?)?",
                get(entry.fields, "date", ""))
    isnothing(iso) ||
        return _dateasfaras(parse(Int, iso[1]), _number(iso[2]),
                            _number(iso[3]))
    return _dateasfaras(_number(entry.date.year),
                        _monthnumber(entry.date.month),
                        _number(entry.date.day))
end

# A whole number written as text, or `nothing` if it is not one
_number(text::AbstractString) = tryparse(Int, strip(text))
_number(::Nothing) = nothing

# The number of a month written as a number or as an English month name or
# the start of one, three letters at least; `nothing` if it is neither
function _monthnumber(month::AbstractString)
    month = lowercase(strip(month))
    number = tryparse(Int, month)
    isnothing(number) || return number
    length(month) >= 3 || return nothing
    return findfirst(startswith(month), MONTH_NAMES)
end

# The date that a year, month and day give as far as they go, a month or day
# that is missing or impossible being taken as the first; `nothing` with no
# year
function _dateasfaras(year::Union{Nothing, Int}, month::Union{Nothing, Int},
                      day::Union{Nothing, Int})
    isnothing(year) && return nothing
    (isnothing(month) || !(1 <= month <= 12)) && return DateTime(year)
    (isnothing(day) || !(1 <= day <= daysinmonth(year, month))) &&
        return DateTime(year, month)
    return DateTime(year, month, day)
end

# The citation a source is named by: a registered one by its key, or the one
# its DOI gives; it must be one or the other
function _citation(handle::DataRegistryHandle, ::Nothing,
                   bibtex::AbstractString)
    haskey(handle.citations, bibtex) && return handle.citations[bibtex]
    known = isempty(handle.citations) ? "none" :
            join(sort!(collect(keys(handle.citations))), ", ")
    return throw(ArgumentError("no citation '$bibtex' is registered (registered: $known)"))
end
function _citation(handle::DataRegistryHandle, doi::AbstractString, ::Nothing)
    return _doicitation(handle, doi)
end
function _citation(::DataRegistryHandle, ::Nothing, ::Nothing)
    return throw(ArgumentError("a source needs a citation: give its doi or its bibtex key"))
end
function _citation(::DataRegistryHandle, ::AbstractString, ::AbstractString)
    return throw(ArgumentError("give a source's doi or its bibtex key, not both"))
end

"""
    _doicitation(handle, doi; fetch = _fetchbibtex)

Return the citation of a DOI, given bare or as a URL. A registered citation of
that DOI is the one, so that a run with no network can use a DOI whose
citation it was given; several registered for it must say the same of it,
nothing else saying which is meant.

With none registered it is the BibTeX that the DOI's own URL returns, read as
any other, its identifier the DOI as asked for. A citation that names another
DOI - as that of an alias would, or one that is mistaken - is warned of, since
which of the two is meant is the caller's to say. A DOI is looked up once in a
code run. `fetch` is what asks for the BibTeX at a URL.
"""
function _doicitation(handle::DataRegistryHandle, doi::AbstractString;
                      fetch::Function = _fetchbibtex)
    identifier = _doiurl(doi)
    registered = _registeredcitation(handle, identifier)
    isnothing(registered) || return registered
    return get!(handle.doi_lookups, identifier) do
        found = _parsecitations(fetch(identifier),
                                "the citation returned for $identifier")
        length(found) == 1 ||
            throw(ReadWriteException("$(length(found)) citations were returned for $identifier"))
        citation = only(found)
        named = something(citation.identifier, identifier)
        if named != identifier && startswith(named, DOI_RESOLVER)
            @warn "the citation returned for $identifier names another DOI, $named: the source is recorded under the one asked for - if the other is the one meant, give that"
        end
        return SourceCitation(citation.key, identifier, citation.title,
                              citation.authors, citation.release_date,
                              citation.release_version, citation.description)
    end
end

# The registered citation of the source with an identifier, or `nothing` if
# there is none. Several are one citation only if they say the same of the
# source: otherwise an error naming them, for the caller to choose by key.
function _registeredcitation(handle::DataRegistryHandle,
                             identifier::AbstractString)
    keys = sort!([key
                  for (key, citation) in handle.citations
                  if citation.identifier == identifier])
    isempty(keys) && return nothing
    chosen = handle.citations[first(keys)]
    all(key -> _samesource(handle.citations[key], chosen), keys) ||
        throw(ArgumentError("the citations $(join(keys, ", ")) are registered for $identifier and differ: name the one that is meant by its bibtex key"))
    return chosen
end

# Ask a URL for a citation as BibTeX, which a DOI's URL gives when asked for
# that type. Needs a network, and says so when it cannot be reached.
function _fetchbibtex(url::AbstractString)
    response = try
        HTTP.get(url, ["Accept" => "application/x-bibtex"])
    catch e
        if e isa HTTP.StatusError
            throw(ReadWriteException("no citation is to be had from $url (HTTP status $(e.status)): give the citation itself, as BibTeX"))
        elseif e isa Union{Base.IOError, HTTP.ConnectError, HTTP.TimeoutError}
            throw(ReadWriteException("cannot reach $url to look the citation up: with no network, give the citation itself, as BibTeX"))
        end
        rethrow()
    end
    return String(response.body)
end

"""
    _sourcefacts(citation; primary, title, description, release_date,
                 release_version)

Return what the registry records of a source, drawn from its citation and
from what the caller says of it, as `(identifier, title, version,
release_date, description, primary, authors)`.

`primary` says whether the registered file is the cited item itself or one of
its files, as against something requested or derived from it. Each other
keyword, when given, takes the place of what the citation says: `title`, since
a file of a deposit has a title of its own; `description`; `release_date`, a
`Date`, a `DateTime` or text in ISO form as far as it goes; and
`release_version`. The version is written in full, `2.1` as `2.1.0`, and is
the registry's default when neither gives one; one that is not a version, or
that has a leading zero, as `061`, is an error, since writing it in full
would alter it. A source with no identifier, title or release date from
either is an error.
"""
function _sourcefacts(citation::SourceCitation; primary::Bool,
                      title::Union{Nothing, AbstractString} = nothing,
                      description::Union{Nothing, AbstractString} = nothing,
                      release_date::Union{Nothing, Date, DateTime,
                                          AbstractString} = nothing,
                      release_version::Union{Nothing, VersionNumber,
                                             AbstractString} = nothing)
    lacks(what,
          keyword) = ArgumentError("the citation '$(citation.key)' gives no $what: give `$keyword`")
    isnothing(citation.identifier) &&
        throw(ArgumentError("the citation '$(citation.key)' gives neither a doi nor a url to identify its source by"))
    title = something(title, citation.title, Some(nothing))
    isnothing(title) && throw(lacks("title", "title"))
    release_date = something(release_date, citation.release_date,
                             Some(nothing))
    isnothing(release_date) && throw(lacks("date", "release_date"))
    version = something(release_version, citation.release_version,
                        DEFAULT_RELEASE_VERSION)
    return (identifier = citation.identifier, title = String(title),
            version = _releaseversion(version),
            release_date = _releasedate(release_date),
            description = something(description, citation.description,
                                    Some(nothing)),
            primary = primary, authors = citation.authors)
end

# A release date as the registry takes one, from a date, a date and time, or
# text in ISO form as far as it goes: `2019`, `2019-04`, `2019-04-18`
_releasedate(date::DateTime) = date
_releasedate(date::Date) = DateTime(date)
function _releasedate(date::AbstractString)
    parsed = tryparse(DateTime, strip(date))
    isnothing(parsed) && throw(ArgumentError("not a date: '$date'"))
    return parsed
end

# A release version as the registry takes one: major, minor and patch in full.
# A version is completed and never altered: with a missing minor or patch
# added it must read back as it was written, which one with a leading zero in
# a number does not. That one is refused, with what is not a version at all.
_releaseversion(version::VersionNumber) = string(version)
function _releaseversion(version::AbstractString)
    written = lstrip(strip(version), ['v', 'V'])
    parsed = tryparse(VersionNumber, written)
    numbers, rest = match(r"^([^-+]*)(.*)$", written)
    if isnothing(parsed) ||
       !any(string(parsed) == numbers * added * rest
            for added in ("", ".0", ".0.0"))
        throw(ArgumentError("not a version the registry can take as it stands: '$version' - give `release_version` in full, as major.minor.patch"))
    end
    return string(parsed)
end
