# SPDX-License-Identifier: LGPL-3.0-or-later

# The licence of a registered file: its identifier in the SPDX licence list,
# of which the package keeps a copy, or the URL of a licence that the list has
# not got.

# Where the SPDX licence list has a page for each licence, by its identifier,
# and where it publishes the list itself
const SPDX_LICENCES = "https://spdx.org/licenses/"
const SPDX_PUBLISHED = SPDX_LICENCES * "licenses.json"
# Where the source of the list is kept, by its version: which licence replaces
# one that the list has deprecated is said only there
const SPDX_SOURCE = "https://raw.githubusercontent.com/spdx/license-list-XML/"

# The package's copy of the list: a header, then a line to each licence, its
# identifier, its name and, where the list has deprecated it in favour of one
# other licence, that licence's identifier, separated by tabs. It is read as
# the package is compiled; `_updatespdxlist` brings it up to date.
const SPDX_LIST = joinpath(@__DIR__, "spdx_licences.txt")
include_dependency(SPDX_LIST)

# The version of the list that the copy is of
const SPDX_LIST_VERSION = String(match(r"version (\S+),",
                                       first(eachline(SPDX_LIST)))[1])

# The copy's lines, each split into its fields
const SPDX_ENTRIES = [String.(split(line, '\t'))
                      for line in eachline(SPDX_LIST)
                      if !startswith(line, '#')]

# An identifier as it is looked up: one is the same in any case and with any
# dash, of Unicode's dash punctuation or the minus sign, in place of `-`
function _spdxidkey(written::AbstractString)
    return lowercase(replace(written, r"[\p{Pd}\u2212]" => "-"))
end

# A licence's name as it is looked up: in any case, each run of white space
# and dashes one space, none at either end
function _spdxnamekey(written::AbstractString)
    return lowercase(strip(replace(written, r"[\s\p{Pd}\u2212]+" => " ")))
end

# The identifiers in the copy by their keys, each as the list writes it
const SPDX_IDENTIFIERS = Dict(_spdxidkey(entry[1]) => entry[1]
                              for entry in SPDX_ENTRIES)

# The identifiers by the keys of their licences' names. A name shared by
# several identifiers is that of a licence the list has deprecated and of the
# one replacing it, so either stands for the same licence.
const SPDX_NAMES = Dict(_spdxnamekey(entry[2]) => entry[1]
                        for entry in SPDX_ENTRIES)

# The licence that replaces each one the list has deprecated for one other
const SPDX_REPLACEMENTS = Dict(entry[1] => entry[3]
                               for entry in SPDX_ENTRIES if length(entry) == 3)

# The licence that a call names, under either spelling of the keyword
_eitherspelling(::Nothing, ::Nothing) = nothing
_eitherspelling(licence::AbstractString, ::Nothing) = licence
_eitherspelling(::Nothing, license::AbstractString) = license
function _eitherspelling(::AbstractString, ::AbstractString)
    return throw(ArgumentError("give a source's `licence` or its `license`, not both"))
end

# The identifier in the SPDX list of the licence that `written` gives by its
# identifier or its name there, the licence replacing it where the list has
# deprecated it for one other; or `nothing`
function _spdxidentifier(written::AbstractString)
    listed = get(SPDX_IDENTIFIERS, _spdxidkey(written)) do
        return get(SPDX_NAMES, _spdxnamekey(written), nothing)
    end
    isnothing(listed) && return nothing
    return get(SPDX_REPLACEMENTS, listed, listed)
end

# A licence as the registry records one, its name and the URL that identifies
# it. One in the SPDX list is given by its identifier there, as the address of
# its page, or by its name, and is named by its identifier and identified by
# that page, a licence the list has replaced by one other as that other. Any
# other is the URL of a licence that the list has not got, which is both.
_licence(::Nothing) = nothing
function _licence(licence::AbstractString)
    page = match(r"^https?://spdx\.org/licenses/([^/]+?)(?:\.html)?$", licence)
    identifier = _spdxidentifier(isnothing(page) ? licence : page[1])
    isnothing(identifier) ||
        return (info = identifier, identifier = SPDX_LICENCES * identifier)
    occursin(r"^https?://\S+$", licence) ||
        throw(ArgumentError("not a licence: '$licence' is neither an identifier nor a name in the SPDX licence list (version $SPDX_LIST_VERSION, $SPDX_LICENCES) - give one, as CC-BY-4.0, or the URL of a licence that the list has not got"))
    return (info = String(licence), identifier = String(licence))
end

# A licence that the registry holds, as `_licence` would record it now - one
# held under an identifier that the list has since replaced is the licence
# replacing it - or as it is held, where `_licence` cannot read it
function _heldlicence(held::AbstractDict)
    recorded = (info = held["licence_info"], identifier = held["identifier"])
    recorded.info isa AbstractString || return recorded
    return try
        _licence(recorded.info)
    catch err
        err isa ArgumentError || rethrow()
        recorded
    end
end

# The list as SPDX publishes it. Needs a network.
_publishedspdxlist() = JSON.parse(String(HTTP.get(SPDX_PUBLISHED).body))

# The licence replacing each that the published list has deprecated, where its
# source at the list's version names one licence that the list has not
# deprecated. Needs a network.
function _spdxreplacements(published::AbstractDict)
    current = Set(licence["licenseId"]
                  for licence in published["licenses"]
                  if !licence["isDeprecatedLicenseId"])
    replacements = Dict{String, String}()
    for licence in published["licenses"]
        licence["isDeprecatedLicenseId"] || continue
        identifier = licence["licenseId"]
        source = string(SPDX_SOURCE, "v", published["licenseListVersion"],
                        "/src/", URIs.escapeuri(identifier), ".xml")
        replacement = _obsoletedby(String(HTTP.get(source).body))
        replacement in current && (replacements[identifier] = replacement)
    end
    return replacements
end

# What the source of a licence's entry in the list says replaces it, in its
# `obsoletedBy` element with no `expression` attribute - one with it says what
# replaces that expression - or `nothing` where it names none or several
function _obsoletedby(xml::AbstractString)
    pattern = r"<obsoletedBy(\s[^>]*)?>\s*([^<]*?)\s*</obsoletedBy>"
    named = [found[2]
             for found in eachmatch(pattern, xml)
             if isnothing(found[1]) || !occursin("expression", found[1])]
    return length(named) == 1 ? String(only(named)) : nothing
end

# The text of the package's copy of the list, from the list as published and
# the licences replacing those it has deprecated: every licence in it, those
# deprecated included, its name with its white space single
function _spdxlisttext(published::AbstractDict, replacements::AbstractDict)
    licences = sort(published["licenses"], by = licence -> licence["licenseId"])
    lines = map(licences) do licence
        identifier = licence["licenseId"]
        name = strip(replace(licence["name"], r"\s+" => " "))
        replacement = get(replacements, identifier, nothing)
        return join(isnothing(replacement) ? (identifier, name) :
                    (identifier, name, replacement), '\t')
    end
    released = first(published["releaseDate"], 10)
    header = [
        "# SPDX License List version $(published["licenseListVersion"]), released $released: each licence's identifier, its name and,",
        "# where the list has deprecated it in favour of one other licence, that licence's, separated by tabs. From",
        "# $SPDX_PUBLISHED, and $SPDX_SOURCE for the replacements -",
        "# to bring this file up to date, run DataPipeline._updatespdxlist() in a checkout of the package"
    ]
    return join(vcat(header, lines), "\n") * "\n"
end

"""
    _updatespdxlist()

Bring the package's copy of the SPDX licence list up to date with the list
published at `$SPDX_PUBLISHED`, and with the licence replacing each that it has
deprecated from the list's source at `$SPDX_SOURCE`, and return the version
the copy is then of. To be run in a checkout of the package: the copy is a
file among its sources.
"""
function _updatespdxlist()
    published = _publishedspdxlist()
    write(SPDX_LIST, _spdxlisttext(published, _spdxreplacements(published)))
    return String(published["licenseListVersion"])
end
