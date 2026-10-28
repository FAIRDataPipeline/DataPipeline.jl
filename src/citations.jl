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
# The most characters the registry takes in a source's title
const SOURCE_TITLE_LENGTH = 1024
# A URL as the registry takes one to identify a source: an http, https, ftp or
# ftps address with a host, and no white space
const SOURCE_URL = r"^(?:https?|ftps?)://[^\s/?#]+\S*$"i
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
`version`; its `note`, as a description; and its `license` or `copyright`, as
its licence, when that is an identifier or a name in the SPDX licence list, or
a URL - any other is warned of and passed over. Braces are dropped, and LaTeX
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

# What a parsed BibTeX entry says of its source. BibTeX gives no identifiers
# for its authors.
function _sourcecitation(entry::BibInternal.Entry)
    authors = String[name
                     for name in map(_personname, entry.authors)
                     if !isnothing(name)]
    return SourceCitation(entry.id, _entryidentifier(entry),
                          _unbrace(entry.title), authors, _entrydate(entry),
                          _unbrace(get(entry.fields, "version", "")),
                          _unbrace(entry.note), _bibtexlicence(entry),
                          Dict{String, String}())
end

# The licence that a BibTeX entry gives in a `license` or `copyright` field,
# as it is recorded, if it is one that can be: one in the SPDX licence list,
# by its identifier or its name, or a URL. Any other is warned of, and is no
# licence.
function _bibtexlicence(entry::BibInternal.Entry)
    for field in ("license", "copyright")
        written = _unbrace(get(entry.fields, field, ""))
        isnothing(written) && continue
        try
            return _licence(written).info
        catch e
            e isa ArgumentError || rethrow()
            @warn "the citation '$(entry.id)' gives its licence as '$written', which is neither an identifier nor a name in the SPDX licence list nor a URL, so it is not recorded: give `licence` to record one"
            return nothing
        end
    end
    return nothing
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
    date = _isodate(get(entry.fields, "date", ""))
    isnothing(date) || return date
    return _dateasfaras(_number(entry.date.year),
                        _monthnumber(entry.date.month),
                        _number(entry.date.day))
end

# The date that text starting with one in ISO form gives, as far as it goes,
# or `nothing` if it does not start with a year
function _isodate(text::AbstractString)
    iso = match(r"^\s*(\d{4})(?:-(\d{1,2})(?:-(\d{1,2}))?)?", text)
    isnothing(iso) && return nothing
    return _dateasfaras(parse(Int, iso[1]), _number(iso[2]), _number(iso[3]))
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
    _doicitation(handle, doi; fetch = _fetchmetadata)

Return the citation of a DOI, given bare or as a URL. A registered citation of
that DOI is the one, so that a run with no network can use a DOI whose
citation it was given; several registered for it must say the same of it,
nothing else saying which is meant.

With none registered it is what the DOI's formal metadata says - DataCite's
record of it, or for a DOI that is not DataCite's its CSL record - its
identifier the DOI as asked for. Metadata that names another DOI - as that of
an alias would, or that is mistaken - is warned of, since which of the two is
meant is the caller's to say. A DOI is looked up once in a code run. `fetch`
asks a URL for metadata of a type, as `_fetchmetadata` does.
"""
function _doicitation(handle::DataRegistryHandle, doi::AbstractString;
                      fetch::Function = _fetchmetadata)
    identifier = _doiurl(doi)
    registered = _registeredcitation(handle, identifier)
    isnothing(registered) || return registered
    return get!(handle.doi_lookups, identifier) do
        citation = _lookupcitation(identifier, fetch)
        named = something(citation.identifier, identifier)
        if named != identifier && startswith(named, DOI_RESOLVER)
            @warn "the metadata of $identifier names another DOI, $named: the source is recorded under the one asked for - if the other is the one meant, give that"
        end
        return SourceCitation(citation.key, identifier, citation.title,
                              citation.authors, citation.release_date,
                              citation.release_version, citation.description,
                              citation.licence, citation.identifiers)
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

# Ask a URL for metadata of one type, which a DOI's URL gives when asked for
# it, and return it as text: `nothing` when it is not to be had in that type,
# answered with a 406 or with something else. Needs a network, and says so
# when it cannot be reached.
function _fetchmetadata(url::AbstractString, type::AbstractString)
    response = try
        HTTP.get(url, ["Accept" => type])
    catch e
        e isa HTTP.StatusError && e.status == 406 && return nothing
        if e isa HTTP.StatusError
            throw(ReadWriteException("no citation is to be had from $url (HTTP status $(e.status)): give the citation itself, as BibTeX"))
        elseif e isa Union{Base.IOError, HTTP.ConnectError, HTTP.TimeoutError}
            throw(ReadWriteException("cannot reach $url to look the citation up: with no network, give the citation itself, as BibTeX"))
        end
        rethrow()
    end
    occursin("json", HTTP.header(response, "Content-Type", "")) ||
        return nothing
    return String(response.body)
end

# The citation that a DOI's formal metadata gives, from the first of the
# types in `METADATA_READERS` that `fetch` has for it
function _lookupcitation(identifier::AbstractString, fetch::Function)
    for (type, reader) in METADATA_READERS
        reply = fetch(identifier, type)
        isnothing(reply) || return reader(JSON.parse(reply), identifier)
    end
    return throw(ReadWriteException("no metadata is to be had from $identifier as DataCite's record or as CSL: give the citation itself, as BibTeX"))
end

# The dates of a DataCite record that say when a source was released, in the
# order they are looked for
const RELEASE_DATE_TYPES = ("Issued", "Available", "Created", "Submitted")

"""
    _datacitecitation(record, doi)

Return what DataCite's record of a DOI says of its source, as a citation keyed
by the DOI: its main title; its creators, a person as given names then family
name and an organisation as it is written, with the ORCIDs and ROR ids the
record gives them; the first of its Issued, Available, Created and Submitted
dates, or else its year; its version; its abstract; and its licence, by its
identifier in the SPDX licence list where a right gives one that the list
has, as `_licence` records it, else by the first right whose address is a web
page.
"""
function _datacitecitation(record::AbstractDict, doi::AbstractString)
    authors = String[]
    identifiers = Dict{String, String}()
    for creator in _items(record, "creators")
        name = _creatorname(creator)
        isnothing(name) && continue
        push!(authors, name)
        identifier = _creatoridentifier(creator)
        isnothing(identifier) || get!(identifiers, name, identifier)
    end
    titles = _items(record, "titles")
    main = findfirst(title -> isnothing(get(title, "titleType", nothing)),
                     titles)
    title = isempty(titles) ? nothing :
            get(titles[something(main, 1)], "title", nothing)
    abstract = findfirst(_items(record, "descriptions")) do description
        return get(description, "descriptionType", nothing) == "Abstract"
    end
    description = isnothing(abstract) ? nothing :
                  get(_items(record, "descriptions")[abstract], "description",
                      nothing)
    return SourceCitation(doi, _named(get(record, "doi", nothing)),
                          _plain(title), authors, _datacitedate(record),
                          _plain(get(record, "version", nothing)),
                          _markupless(description),
                          _datacitelicence(_items(record, "rightsList")),
                          identifiers)
end

# The entries of a list in parsed JSON, none where it is missing or null
function _items(record::AbstractDict, key::AbstractString)
    items = get(record, key, nothing)
    return isnothing(items) ? [] : items
end

# A DOI that metadata names, as a URL in the one form, or `nothing`
_named(doi::AbstractString) = _trydoiurl(doi)
_named(::Nothing) = nothing

# Text from metadata with its white space single, or `nothing` if that leaves
# nothing
_plain(::Nothing) = nothing
function _plain(text::AbstractString)
    plain = strip(replace(text, r"\s+" => " "))
    return isempty(plain) ? nothing : String(plain)
end
# ... and of anything else JSON holds, as a year may be written as a number
_plain(value) = _plain(string(value))

# Text from metadata with its markup taken out - the HTML of a description,
# the JATS of an abstract, a heading of one dropped - and its white space
# single
_markupless(::Nothing) = nothing
function _markupless(text::AbstractString)
    text = replace(text, r"<(jats:)?title>.*?</(jats:)?title>"is => " ")
    text = replace(text, r"<[^<>]*>" => " ")
    for (entity, character) in ("&lt;" => "<", "&gt;" => ">", "&quot;" => "\"",
        "&#39;" => "'", "&amp;" => "&")
        text = replace(text, entity => character)
    end
    return _plain(text)
end

# A creator of a DataCite record as the registry names an author: a person's
# given names and then family name, an organisation as it is written
function _creatorname(creator::AbstractDict)
    given = _plain(get(creator, "givenName", nothing))
    family = _plain(get(creator, "familyName", nothing))
    !isnothing(given) && !isnothing(family) && return "$given $family"
    name = _plain(get(creator, "name", nothing))
    isnothing(name) && return nothing
    parts = split(name, ',', limit = 2)
    (get(creator, "nameType", nothing) == "Personal" && length(parts) == 2) ||
        return name
    return _plain(string(parts[2], " ", parts[1]))
end

# The ORCID or ROR id that a DataCite record gives a creator, as a URL with
# `https:`, or `nothing`
function _creatoridentifier(creator::AbstractDict)
    for given in _items(creator, "nameIdentifiers")
        scheme = lowercase(something(get(given, "nameIdentifierScheme",
                                         nothing),
                                     ""))
        scheme in ("orcid", "ror") || continue
        value = something(_plain(get(given, "nameIdentifier", nothing)), "")
        isempty(value) && continue
        if !occursin(r"^https?://", value)
            base = something(_plain(get(given, "schemeUri", nothing)),
                             "https://$scheme.org/")
            value = string(rstrip(base, '/'), "/", value)
        end
        occursin(r"^https?://\S+$", value) &&
            return replace(value, r"^http:" => "https:")
    end
    return nothing
end

# The date that a DataCite record gives for a source's release: the first of
# the kinds that say so, as far as it goes, else its year
function _datacitedate(record::AbstractDict)
    for kind in RELEASE_DATE_TYPES, entry in _items(record, "dates")
        get(entry, "dateType", nothing) == kind || continue
        date = _isodate(something(_plain(get(entry, "date", nothing)), ""))
        isnothing(date) || return date
    end
    return _isodate(something(_plain(get(record, "publicationYear", nothing)),
                              ""))
end

# The licence that a DataCite record's rights give: an identifier in the SPDX
# licence list, as `_licence` records it, else the first right's web address
function _datacitelicence(rights::AbstractVector)
    for right in rights
        scheme = something(get(right, "rightsIdentifierScheme", nothing), "")
        identifier = something(get(right, "rightsIdentifier", nothing), "")
        lowercase(scheme) == "spdx" || continue
        listed = _spdxidentifier(identifier)
        isnothing(listed) || return listed
    end
    for right in rights
        address = something(get(right, "rightsUri", nothing), "")
        occursin(r"^https?://\S+$", address) && return String(address)
    end
    return nothing
end

"""
    _cslcitation(record, doi)

Return what the CSL record of a DOI says of its source, as a citation keyed by
the DOI: its title; its authors, with the ORCIDs it gives them; the date it
was issued, as far as it goes; its version; and its abstract. A CSL record's
licence is the publisher's terms for the work, not for data, and is not taken.
"""
function _cslcitation(record::AbstractDict, doi::AbstractString)
    authors = String[]
    identifiers = Dict{String, String}()
    for author in _items(record, "author")
        family = _plain(get(author, "family", nothing))
        name = isnothing(family) ? _plain(get(author, "literal", nothing)) :
               _plain(string(something(_plain(get(author, "given", nothing)),
                                       ""), " ", family))
        isnothing(name) && continue
        push!(authors, name)
        orcid = something(_plain(get(author, "ORCID", nothing)), "")
        occursin(r"^https?://\S+$", orcid) &&
            get!(identifiers, name, replace(orcid, r"^http:" => "https:"))
    end
    title = get(record, "title", nothing)
    title isa AbstractVector &&
        (title = isempty(title) ? nothing : first(title))
    issued = get(something(get(record, "issued", nothing), Dict()),
                 "date-parts",
                 [])
    parts = isempty(issued) ? [] :
            [_number(_plain(part)) for part in first(issued)]
    date = isempty(parts) ? nothing :
           _dateasfaras(parts[1], get(parts, 2, nothing),
                        get(parts, 3, nothing))
    return SourceCitation(doi, _named(get(record, "DOI", nothing)),
                          _plain(title), authors, date,
                          _plain(get(record, "version", nothing)),
                          _markupless(get(record, "abstract", nothing)),
                          nothing, identifiers)
end

# The types of metadata a DOI is asked for, in order, and what reads each
const METADATA_READERS = ("application/vnd.datacite.datacite+json" =>
                              _datacitecitation,
                          "application/vnd.citationstyles.csl+json" =>
                              _cslcitation)

"""
    _sourcefacts(citation; primary, title, description, release_date,
                 release_version)

Return what the registry records of a source, drawn from its citation and
from what the caller says of it, as `(identifier, title, version,
release_date, description, primary, authors, licence, identifiers)` - the last
two the licence the citation gives, or `nothing`, and the identifiers it gives
its authors, by name.

`primary` says whether the registered file is the cited item itself or one of
its files, as against something requested or derived from it. Each other
keyword, when given, takes the place of what the citation says: `title`, since
a file of a deposit has a title of its own; `description`; `release_date`, a
`Date`, a `DateTime` or text in ISO form as far as it goes; and
`release_version`. The version is written in full, `2.1` as `2.1.0`, and is
the registry's default when neither gives one; one that is not a version, or
that has a leading zero, as `061`, is an error, since writing it in full
would alter it. A source with no identifier, title or release date from
either is an error, as are those the registry refuses: an identifier that is
not a URL with a host, and a title that is blank or longer than
$SOURCE_TITLE_LENGTH characters. The title is stripped of the white space around
it, as the registry stores it.
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
    occursin(SOURCE_URL, citation.identifier) ||
        throw(ArgumentError("the citation '$(citation.key)' identifies its source as '$(citation.identifier)', which the registry refuses: give its url in full, as `https://` and a host"))
    title = something(title, citation.title, Some(nothing))
    isnothing(title) && throw(lacks("title", "title"))
    title = strip(title)
    isempty(title) &&
        throw(ArgumentError("the source's title is blank, which the registry refuses: give `title`"))
    length(title) <= SOURCE_TITLE_LENGTH ||
        throw(ArgumentError("the source's title has $(length(title)) characters, more than the $SOURCE_TITLE_LENGTH the registry takes: give a shorter `title`"))
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
            primary = primary, authors = citation.authors,
            licence = citation.licence, identifiers = citation.identifiers)
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
# a number does not. That one is refused, with what is not a version at all,
# the error naming the keyword to give it by.
function _releaseversion(version::VersionNumber;
                         keyword::AbstractString = "release_version")
    return string(version)
end
function _releaseversion(version::AbstractString;
                         keyword::AbstractString = "release_version")
    written = lstrip(strip(version), ['v', 'V'])
    parsed = tryparse(VersionNumber, written)
    numbers, rest = match(r"^([^-+]*)(.*)$", written)
    if isnothing(parsed) ||
       !any(string(parsed) == numbers * added * rest
            for added in ("", ".0", ".0.0"))
        throw(ArgumentError("not a version the registry can take as it stands: '$version' - give `$keyword` in full, as major.minor.patch"))
    end
    return string(parsed)
end
