# SPDX-License-Identifier: LGPL-3.0-or-later

# The licence of a registered file: its identifier in the SPDX licence list,
# of which the package keeps a copy, or the URL of a licence that the list has
# not got.

# Where the SPDX licence list has a page for each licence, by its identifier,
# and where it publishes the list itself
const SPDX_LICENCES = "https://spdx.org/licenses/"
const SPDX_PUBLISHED = SPDX_LICENCES * "licenses.json"

# The package's copy of the list: a header, then an identifier to a line. It
# is read as the package is compiled; `_updatespdxlist` brings it up to date.
const SPDX_LIST = joinpath(@__DIR__, "spdx_licences.txt")
include_dependency(SPDX_LIST)

# The version of the list that the copy is of
const SPDX_LIST_VERSION = String(match(r"version (\S+),",
                                       first(eachline(SPDX_LIST)))[1])

# The identifiers in the copy, by their lower-case forms: an identifier is the
# same in any case, and is recorded as the list writes it
const SPDX_IDENTIFIERS = Dict(lowercase(line) => line
                              for line in eachline(SPDX_LIST)
                              if !startswith(line, '#'))

# The licence that a call names, under either spelling of the keyword
_eitherspelling(::Nothing, ::Nothing) = nothing
_eitherspelling(licence::AbstractString, ::Nothing) = licence
_eitherspelling(::Nothing, license::AbstractString) = license
function _eitherspelling(::AbstractString, ::AbstractString)
    return throw(ArgumentError("give a source's `licence` or its `license`, not both"))
end

# A licence as the registry records one, its name and the URL that identifies
# it. One in the SPDX list is named by its identifier there, given in any
# case or as the address of its page, and identified by that page. Any other
# is the URL of a licence that the list has not got, which is both.
_licence(::Nothing) = nothing
function _licence(licence::AbstractString)
    page = match(r"^https?://spdx\.org/licenses/([^/]+?)(?:\.html)?$", licence)
    name = isnothing(page) ? licence : page[1]
    identifier = get(SPDX_IDENTIFIERS, lowercase(name), nothing)
    isnothing(identifier) ||
        return (info = identifier, identifier = SPDX_LICENCES * identifier)
    occursin(r"^https?://\S+$", licence) ||
        throw(ArgumentError("not a licence: '$licence' is not an identifier in the SPDX licence list (version $SPDX_LIST_VERSION, $SPDX_LICENCES) - give one, as CC-BY-4.0, or the URL of a licence that the list has not got"))
    return (info = String(licence), identifier = String(licence))
end

# The list as SPDX publishes it. Needs a network.
_publishedspdxlist() = JSON.parse(String(HTTP.get(SPDX_PUBLISHED).body))

# The text of the package's copy of the list, from the list as published:
# every identifier in it, those that the list has deprecated included
function _spdxlisttext(published::AbstractDict)
    identifiers = sort!(String[licence["licenseId"]
                               for licence in published["licenses"]])
    released = first(published["releaseDate"], 10)
    header = [
        "# SPDX License List version $(published["licenseListVersion"]), released $released: its licence identifiers",
        "# From $SPDX_PUBLISHED - to bring this file up to date, run",
        "# DataPipeline._updatespdxlist() in a checkout of the package"]
    return join(vcat(header, identifiers), "\n") * "\n"
end

"""
    _updatespdxlist()

Bring the package's copy of the SPDX licence list up to date with the list
published at `$SPDX_PUBLISHED`, and return the version it is then of. To be
run in a checkout of the package: the copy is a file among its sources.
"""
function _updatespdxlist()
    published = _publishedspdxlist()
    write(SPDX_LIST, _spdxlisttext(published))
    return String(published["licenseListVersion"])
end
