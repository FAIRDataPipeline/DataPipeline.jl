# SPDX-License-Identifier: LGPL-3.0-or-later

module TestSources

using DataPipeline
using Dates
using Test

const URIs = DataPipeline.URIs
const ReadWriteException = DataPipeline.ReadWriteException

uid = DataPipeline._randomhash()
cpath = joinpath("coderun", Dates.format(Dates.now(), "yyyymmdd-HHMMSS"),
                 "sources.yaml")
config = DataPipeline._createconfig(cpath)
launch = DataPipeline.initialise(config, config)
registry = launch.registry
datastore = launch.config["run_metadata"]["write_data_store"]
namespace = launch.config["run_metadata"]["default_output_namespace"]

# A deposit of several files, cited by a DOI that belongs to this run alone,
# with a person and an organisation as its authors; and a page with none
doi = "10.5555/deposit.$uid"
person = "Ada Person $uid"
organisation = "An Example Organisation $uid"
orcid = "https://orcid.org/$(uid[1:16])"
ror = "https://ror.org/$(uid[1:9])"
spdx = "https://spdx.org/licenses/"
own_terms = "https://example.org/$uid/terms.html"
citations = """
@dataset{deposit,
  author = {{Person $uid}, Ada and {$organisation}},
  title = {A deposit of several files $uid},
  date = {2021-03-04},
  doi = {$(uppercase(doi))},
  version = {2.1}
}
@misc{page,
  title = {A page with no author $uid},
  year = {2020},
  url = {https://example.org/$uid/page}
}
@misc{twice,
  author = {{$organisation} and {$organisation}},
  title = {A page that names its author twice $uid},
  year = {2019},
  url = {https://example.org/$uid/twice}
}
"""

# A code run whose config offers each of these names at a version, to be
# written as text unless as another type, with the citations and the person's
# identifier registered
function offering(versions::Pair{String, String}...; file_type = "txt")
    config = DataPipeline._createconfig(cpath)
    for (name, version) in versions
        DataPipeline._addwrite(config, name, "description",
                               file_type = file_type, use_version = version)
    end
    handle = DataPipeline.initialise(config, config)
    register_citations!(handle, citations)
    register_authors!(handle, person => orcid)
    return handle
end

# A file of this text, outside the data store
outside = mktempdir()
function file_of(text::AbstractString)
    path = tempname(outside) * ".txt"
    write(path, text)
    return path
end

# The registry's entry at a URL, and its entry for a version of a data product
entry(url) = DataPipeline._getentry(registry, URIs.URI(url))
function registered(name, version)
    return only(product
                for product in DataPipeline._getentries(registry,
                                                        "data_product",
                                                        Dict("name" => name,
                                                             "version" =>
                                                                 version))
                if product["name"] == name)
end

# The versions of a data product that are registered
function registered_versions(name)
    return sort([product["version"]
                 for product in DataPipeline._getentries(registry,
                                                         "data_product",
                                                         Dict("name" => name))])
end

# The source of a registered data product, and its object
source_of(product) = entry(product["external_object"])
object_of(product) = entry(product["object"])

# The registry's authors with this identifier, and by this name alone
function author(identifier)
    return DataPipeline._getentry(registry, "author",
                                  Dict("identifier" => identifier))["url"]
end
function author_named(name)
    return only(author["url"]
                for author in DataPipeline._getentries(registry, "author",
                                                       Dict("name" => name))
                if isnothing(author["identifier"]))
end

# The licences of a registered object, as (name, identifier)
function licences_of(object)
    return [(licence["licence_info"], licence["identifier"])
            for licence in entry.(object["licences"])]
end

# The message of the exception of this type that a call throws
function message_of(call::Function, type::Type{<:Exception})
    try
        call()
    catch e
        e isa type || rethrow()
        return e.msg
    end
    return error("nothing was thrown")
end

Test.@testset "a file registered with its source" begin
    full, plain = "sources/recorded/full/$uid", "sources/recorded/plain/$uid"
    handle = offering(full => "0.0.1", plain => "0.0.1")
    @test handle.citations["deposit"].authors == [person, organisation]
    first_file, second_file = file_of("one $uid\n"), file_of("two $uid\n")
    fetched_from = "https://example-$uid.org/data/one.txt?x=1&y=2"

    # Everything that can be said of a source, and nothing but what must be
    stored = link_write!(handle, full, path = first_file, bibtex = "deposit",
                         title = "File one $uid", primary = false,
                         description = "requested as: one",
                         original_store = fetched_from,
                         licence = "cc-by-4.0",
                         release_date = Date(2022, 5, 6),
                         release_version = "3")
    @test read(stored, String) == "one $uid\n"
    link_write!(handle, plain, path = second_file, bibtex = "deposit",
                primary = true)
    # The authors are found as the call is made, one of them registered then
    @test handle.outputs[(full, nothing)]["source"].authors ==
          [author(orcid), author_named(organisation)]
    DataPipeline.finalise(handle)

    product = registered(full, "0.0.1")
    source = source_of(product)
    @test source["identifier"] == "https://doi.org/$doi"
    @test source["title"] == "File one $uid"
    @test source["version"] == "3.0.0"
    @test source["release_date"] == "2022-05-06T00:00:00Z"
    @test source["primary_not_supplement"] == false
    @test source["description"] == "requested as: one"
    @test source["data_products"] == [product["url"]]
    # Where it was fetched from: a root that is not local, the rest of the
    # address under it, and the file's own hash
    location = entry(source["original_store"])
    root = entry(location["storage_root"])
    @test root["root"] == "https://example-$uid.org/" && !root["local"]
    @test location["path"] == "data/one.txt?x=1&y=2"
    @test location["hash"] == DataPipeline._getfilehash(first_file)
    # The file's authors are the source's and not the user's; its licence
    object = object_of(product)
    @test sort(object["authors"]) ==
          sort([author(orcid), author_named(organisation)])
    @test !(DataPipeline._getauthorurl(registry) in object["authors"])
    @test licences_of(object) == [("CC-BY-4.0", spdx * "CC-BY-4.0")]
    # identify gives the data product's source, with where the file was
    # fetched from: the second location with its hash, holding no object
    identified = DataPipeline.identify(registry, first_file)
    found = only(record
                 for object in identified.objects
                 for record in object.data_products if record.name == full)
    @test found.source.url == found.external_object ==
          product["external_object"]
    @test found.source.identifier == "https://doi.org/$doi"
    @test found.source.title == "File one $uid"
    @test found.source.version == "3.0.0"
    @test !found.source.primary
    @test found.source.location == fetched_from
    shown = sprint(show, MIME"text/plain"(), identified)
    @test occursin("source:    https://doi.org/$doi (supplement)", shown)
    @test occursin("fetched from: $fetched_from", shown)

    # What the citation says stands where the call says nothing: the
    # deposit's title, its version in full and its date
    product = registered(plain, "0.0.1")
    source = source_of(product)
    @test source["identifier"] == "https://doi.org/$doi"
    @test source["title"] == "A deposit of several files $uid"
    @test source["version"] == "2.1.0"
    @test source["release_date"] == "2021-03-04T00:00:00Z"
    @test source["primary_not_supplement"] == true
    @test isnothing(source["description"])
    @test isnothing(source["original_store"])
    identified = DataPipeline.identify(registry, second_file)
    found = only(record
                 for object in identified.objects
                 for record in object.data_products if record.name == plain)
    @test found.source.primary && isnothing(found.source.location)
    @test !occursin("fetched from",
                    sprint(show, MIME"text/plain"(), identified))
    @test isempty(object_of(product)["licences"])
    @test length(object_of(product)["authors"]) == 2

    # Both are outputs of the code run, and a file with no source keeps the
    # user as its author
    run = entry(handle.code_run_obj)
    @test length(run["outputs"]) == 2
    @test entry(launch.config_obj)["authors"] ==
          [DataPipeline._getauthorurl(registry)]
end

Test.@testset "what may be said of a source" begin
    name = "sources/said/$uid"
    handle = offering(name => "0.0.1")
    file = file_of("said $uid\n")
    function refused(; keywords...)
        return message_of(ArgumentError) do
            return link_write!(handle, name; path = file, keywords...)
        end
    end

    # Something said of a source that is not named
    @test occursin("`title`", refused(title = "A title"))
    @test occursin("`primary`, `licence`",
                   refused(primary = true, licence = "CC0-1.0"))
    @test occursin("`license`", refused(license = "CC0-1.0"))
    # A source named twice over, or by a key that is not registered
    @test occursin("not both",
                   refused(doi = doi, bibtex = "deposit",
                           primary = true))
    @test occursin("no citation 'absent'",
                   refused(bibtex = "absent", primary = true))
    # Nothing saying what the file is to its source
    @test occursin("`primary = true`", refused(bibtex = "deposit"))
    # A licence that is neither an identifier nor a name in the SPDX list nor
    # a URL; and one given under both spellings of the keyword
    for words in (" ", "Creative Commons Attribution 4.0", "CC-BY-4")
        @test occursin("neither an identifier nor a name in the SPDX licence list",
                       refused(bibtex = "deposit", primary = true,
                               licence = words))
    end
    @test occursin("not both",
                   refused(bibtex = "deposit", primary = true,
                           licence = "CC-BY-4.0", license = "CC-BY-4.0"))
    # A version that cannot be written in full as it stands, and no date
    @test occursin("not a version",
                   refused(bibtex = "deposit", primary = true,
                           release_version = "061"))
    @test occursin("not a date",
                   refused(bibtex = "deposit", primary = true,
                           release_date = "last year"))
    @test isempty(handle.outputs)

    # A place that other people can reach is the URL of a file on a host
    @test DataPipeline._originalstore("ftp://ftp.example.org/pub/a.nc") ==
          (root = "ftp://ftp.example.org/", path = "pub/a.nc")
    for unreachable in (nothing, "/data/a.nc", "data/a.nc",
        "file:///data/a.nc", "FILE://host/data/a.nc",
        "https://example.org/", "https://example.org")
        @test isnothing(DataPipeline._originalstore(unreachable))
    end

    # A DOI is cited by the citation registered for it, with no lookup; one
    # with no authors gives the file none; a file on this machine is fetched
    # from nowhere that is recorded; and a licence that the SPDX list has not
    # got is known by its URL, the keyword spelt either way
    page = "sources/said/page/$uid"
    handle = offering(name => "0.0.1", page => "0.0.1")
    link_write!(handle, name, path = file, doi = "https://doi.org/$doi",
                title = "Said $uid", primary = true,
                original_store = "file://$file",
                license = own_terms)
    link_write!(handle, page, path = file_of("page $uid\n"), bibtex = "page",
                primary = false)
    @test isempty(handle.doi_lookups)
    DataPipeline.finalise(handle)
    product = registered(name, "0.0.1")
    @test source_of(product)["identifier"] == "https://doi.org/$doi"
    @test isnothing(source_of(product)["original_store"])
    @test licences_of(object_of(product)) == [(own_terms, own_terms)]
    product = registered(page, "0.0.1")
    @test source_of(product)["identifier"] == "https://example.org/$uid/page"
    @test source_of(product)["release_date"] == "2020-01-01T00:00:00Z"
    @test isempty(object_of(product)["authors"])

    # A file with a source that is never written is missed as any other is
    handle = offering(name => "0.0.2")
    link_write!(handle, name, bibtex = "page", primary = false)
    @test occursin("File not found",
                   message_of(() -> DataPipeline.finalise(handle),
                              ReadWriteException))
end

Test.@testset "what a source's own metadata says" begin
    named, overridden = "sources/metadata/$uid", "sources/metadata/given/$uid"
    handle = offering(named => "0.0.1", overridden => "0.0.1")
    # A DOI's metadata, as a lookup of it would have read it: a creator with
    # an ORCID, one with none, a date, and a licence by its SPDX identifier
    doi = "https://doi.org/10.5555/metadata.$uid"
    ada, unidentified = "Ada Example $uid", "Unidentified Example $uid"
    from_doi, from_file = "$orcid-dc", "$orcid-file"
    record = Dict("doi" => "10.5555/metadata.$uid",
                  "titles" => [Dict("title" => "From its metadata $uid")],
                  "creators" => [
                      Dict("givenName" => "Ada",
                           "familyName" => "Example $uid",
                           "nameIdentifiers" =>
                               [Dict("nameIdentifier" => from_doi,
                                     "nameIdentifierScheme" => "ORCID")]),
                      Dict("name" => unidentified)],
                  "dates" =>
                      [Dict("date" => "2024-01-02", "dateType" => "Issued")],
                  "rightsList" => [Dict("rightsIdentifier" => "cc-by-4.0",
                        "rightsIdentifierScheme" => "SPDX")])
    handle.doi_lookups[doi] = DataPipeline._datacitecitation(record, doi)
    register_authors!(handle, ada => from_file)

    # What the metadata says fills in what the call does not; the ORCID it
    # gives is registered and is the author's, before the run's own
    link_write!(handle, named, path = file_of("named $uid\n"), doi = doi,
                primary = true)
    # ... and what the call says takes the place of the metadata's
    link_write!(handle, overridden, path = file_of("given $uid\n"), doi = doi,
                primary = true, title = "Given $uid", licence = "CC0-1.0")
    DataPipeline.finalise(handle)
    product = registered(named, "0.0.1")
    source = source_of(product)
    @test source["title"] == "From its metadata $uid"
    @test source["release_date"] == "2024-01-02T00:00:00Z"
    @test licences_of(object_of(product)) == [("CC-BY-4.0", spdx * "CC-BY-4.0")]
    @test sort(object_of(product)["authors"]) ==
          sort([author(from_doi), author_named(unidentified)])
    @test !(author(from_file) in object_of(product)["authors"])
    @test handle.authors[ada] == [from_file, from_doi]
    given = registered(overridden, "0.0.1")
    @test source_of(given)["title"] == "Given $uid"
    @test licences_of(object_of(given)) == [("CC0-1.0", spdx * "CC0-1.0")]
end

Test.@testset "a registry that keeps sources as rows of their own" begin
    # This registry is one; one before v1.4.0 is refused with an error saying
    # so, which no registry these tests run against can show
    @test isnothing(DataPipeline._checksourcerows(registry))
end

Test.@testset "a licence" begin
    cc0 = (info = "CC0-1.0", identifier = spdx * "CC0-1.0")
    # One in the SPDX list is known by its identifier there, in any case,
    # with any dash or as the address of its page, and is identified by that
    # page
    for written in ("CC0-1.0", "cc0-1.0", spdx * "CC0-1.0",
        spdx * "CC0-1.0.html", "http://spdx.org/licenses/cc0-1.0",
        "CC0\u20101.0", "cc0\u22121.0")
        @test DataPipeline._licence(written) == cc0
    end
    # ... or by its name there, in any case, with its runs of white space and
    # dashes as any others, the list's own stray spaces among them
    for written in ("Creative Commons Zero v1.0 Universal",
                    " creative commons  ZERO v1.0\tuniversal")
        @test DataPipeline._licence(written) == cc0
    end
    for written in ("Data licence Germany \u2013 attribution \u2013 version 2.0",
        "Data licence Germany - attribution - version 2.0",
        "Data licence Germany--attribution--version 2.0")
        @test DataPipeline._licence(written).info == "DL-DE-BY-2.0"
    end
    @test DataPipeline._licence("Creative Commons Public Domain Mark 1.0 Universal").info ==
          "CC-PDM-1.0"
    @test DataPipeline._licence("Licence Libre du Qu\u00e9bec - Permissive version 1.1").info ==
          "LiLiQ-P-1.1"
    # One that the list has deprecated in favour of one other is that other,
    # by identifier or by the name the two share
    for written in ("GPL-3.0+", spdx * "GPL-3.0+",
        "GNU General Public License v3.0 or later", "GPL-3.0-or-later")
        @test DataPipeline._licence(written).info == "GPL-3.0-or-later"
    end
    @test DataPipeline._licence("GPL-3.0").info == "GPL-3.0-only"
    @test DataPipeline._licence("Nunit").info == "zlib-acknowledgement"
    # ... and as it is where the list replaces it by an expression, or by none
    @test DataPipeline._licence("eCos-2.0").info == "eCos-2.0"
    @test DataPipeline._licence("Net-SNMP").info == "Net-SNMP"
    # Any other is the URL of a licence, whether or not it is at spdx.org
    for url in (own_terms, spdx * "Not-Yet-In-The-Copy-1.0")
        @test DataPipeline._licence(url) == (info = url, identifier = url)
    end
    @test isnothing(DataPipeline._licence(nothing))
    # Not a licence: an abbreviation, an identifier with spaces for dashes,
    # part of a name, a name with an accent written as a letter and a
    # combining mark where the list has one character
    for written in ("CC0", "CC0 1.0", "Creative Commons Zero",
                    "Licence Libre du Que\u0301bec - Permissive version 1.1")
        @test_throws ArgumentError DataPipeline._licence(written)
    end
    @test length(DataPipeline.SPDX_IDENTIFIERS) > 700

    # A licence the registry holds is as it would be recorded now, or as it
    # is held where it cannot be read
    @test DataPipeline._heldlicence(Dict("licence_info" => "GPL-3.0+",
                                         "identifier" => spdx * "GPL-3.0+")) ==
          DataPipeline._licence("GPL-3.0-or-later")
    @test DataPipeline._heldlicence(Dict("licence_info" => "Our terms",
                                         "identifier" => nothing)) ==
          (info = "Our terms", identifier = nothing)

    # In the copy, each licence replacing another is in it and not replaced
    # itself, and a name that several identifiers share is one licence's
    replacements = DataPipeline.SPDX_REPLACEMENTS
    @test length(replacements) >= 20
    listed(identifier) = haskey(DataPipeline.SPDX_IDENTIFIERS,
                                DataPipeline._spdxidkey(identifier))
    @test filter(!listed, collect(values(replacements))) == String[]
    @test filter(in(keys(replacements)), collect(values(replacements))) ==
          String[]
    named = Dict{String, Set{String}}()
    for entry in DataPipeline.SPDX_ENTRIES
        push!(get!(named, DataPipeline._spdxnamekey(entry[2]), Set{String}()),
              get(replacements, entry[1], entry[1]))
    end
    @test [name for (name, licences) in named if length(licences) > 1] ==
          String[]

    # The source of a licence's entry names what replaces it in the element
    # with no `expression`: the one licence, if any
    @test DataPipeline._obsoletedby("""
    <obsoletedBys>
      <obsoletedBy>GPL-2.0-only</obsoletedBy>
      <obsoletedBy expression="GPL-2.0+">GPL-2.0-or-later</obsoletedBy>
    </obsoletedBys>
    """) == "GPL-2.0-only"
    @test isnothing(DataPipeline._obsoletedby("<crossRefs></crossRefs>"))
    @test isnothing(DataPipeline._obsoletedby("<obsoletedBy>A</obsoletedBy>\n<obsoletedBy>B</obsoletedBy>"))

    # The copy of the list that the package keeps is the list as it is
    # published. With no network there is nothing to compare it with, and
    # nothing is checked
    published = try
        DataPipeline._publishedspdxlist()
    catch e
        e isa Union{Base.IOError, DataPipeline.HTTP.ConnectError,
              DataPipeline.HTTP.TimeoutError} || rethrow()
        nothing
    end
    if isnothing(published)
        @test_skip published["licenseListVersion"] ==
                   DataPipeline.SPDX_LIST_VERSION
    else
        kept = values(DataPipeline.SPDX_IDENTIFIERS)
        listed = [licence["licenseId"] for licence in published["licenses"]]
        # What differs is the list's to add or the copy's to lose:
        # `DataPipeline._updatespdxlist()` writes the copy afresh
        @test published["licenseListVersion"] == DataPipeline.SPDX_LIST_VERSION
        @test sort!(symdiff(kept, listed)) == String[]
        # ... and writing it afresh would change nothing, however a checkout
        # ends its lines. The replacements are the copy's own: they come from
        # the source of the list at its version, which does not change
        copy = replace(read(DataPipeline.SPDX_LIST, String), "\r\n" => "\n")
        @test (DataPipeline._spdxlisttext(published, replacements) == copy) ==
              true
    end
end

Test.@testset "a source is one file" begin
    one, two = "sources/onefile/one/$uid", "sources/onefile/two/$uid"
    again, slip = "sources/onefile/again/$uid", "sources/onefile/slip/$uid"
    first_file, second_file = file_of("one $uid\n"), file_of("two $uid\n")
    host = "https://files-$uid.org"
    function of(title; keywords...)
        return (; bibtex = "deposit", primary = true, title = "$title $uid",
                keywords...)
    end

    # Two files of one DOI, a title each, are two sources, each with its own
    # data product and the place it was fetched from
    handle = offering(one => "0.0.1", two => "0.0.1", again => "0.0.1",
                      slip => "0.0.1")
    link_write!(handle, one; path = first_file,
                of("One"; original_store = "$host/one.txt")...)
    link_write!(handle, two; path = second_file,
                of("Two"; original_store = "$host/two.txt")...)
    # The same file under a second name shares its source
    link_write!(handle, again; path = file_of("one $uid\n"), of("One")...)
    # Another file under that source is refused as the call is made, having
    # a path, and leaves nothing behind
    msg = message_of(ReadWriteException) do
        return link_write!(handle, slip; path = second_file, of("One")...)
    end
    @test occursin("which this code run is registering as '$again'", msg)
    @test occursin("`title` of its own", msg)
    @test sort(first.(collect(keys(handle.outputs)))) ==
          sort([one, two, again])
    @test !isdir(joinpath(datastore, namespace, slip))
    DataPipeline.finalise(handle)

    sources = [source_of(registered(name, "0.0.1"))
               for name in (one, two, again)]
    @test sources[1]["url"] != sources[2]["url"]
    @test sources[1]["url"] == sources[3]["url"]
    @test sort(sources[1]["data_products"]) ==
          sort([registered(one, "0.0.1")["url"],
                   registered(again, "0.0.1")["url"]])
    @test sources[2]["data_products"] == [registered(two, "0.0.1")["url"]]
    locations = [entry(source["original_store"]) for source in sources[1:2]]
    @test [location["path"] for location in locations] ==
          ["one.txt", "two.txt"]
    @test [location["hash"] for location in locations] ==
          DataPipeline._getfilehash.([first_file, second_file])

    # Once it is registered the registry says so, naming what holds it
    handle = offering(slip => "0.0.1")
    msg = message_of(ReadWriteException) do
        return link_write!(handle, slip; path = second_file, of("One")...)
    end
    held = "registered as $namespace:sources/onefile/(one|again)/$uid version 0.0.1"
    @test occursin(Regex(held), msg)
    @test isempty(handle.outputs)
    # ... unless it is another release of the source
    link_write!(handle, slip; path = second_file,
                of("One"; release_version = "2.2")...)
    DataPipeline.finalise(handle)
    @test source_of(registered(slip, "0.0.1"))["version"] == "2.2.0"

    # A file that is written after the call is checked by `finalise`, before
    # it registers anything: here an output that comes first by name
    early, late = "sources/onefile/a/$uid", "sources/onefile/b/$uid"
    handle = offering(early => "0.0.1", late => "0.0.1")
    write(link_write!(handle, early), "no source $uid\n")
    written = link_write!(handle, late; of("One")...)
    write(written, "three $uid\n")
    msg = message_of(ReadWriteException) do
        return DataPipeline.finalise(handle)
    end
    @test occursin("cannot register '$late'", msg)
    @test isempty(registered_versions(early))
    @test isempty(entry(handle.code_run_obj)["outputs"])
    # ... and one that is the same file is registered with the source
    handle = offering(late => "0.0.1")
    write(link_write!(handle, late; of("One")...), "one $uid\n")
    DataPipeline.finalise(handle)
    @test source_of(registered(late, "0.0.1"))["url"] == sources[1]["url"]

    # One that is not yet written cannot be compared with another of this
    # code run as a call is made: `finalise` compares them too
    unwritten, given = "sources/onefile/c/$uid", "sources/onefile/d/$uid"
    handle = offering(unwritten => "0.0.1", given => "0.0.1")
    written = link_write!(handle, unwritten; of("Pair")...)
    link_write!(handle, given; path = file_of("pair $uid\n"), of("Pair")...)
    write(written, "not the pair $uid\n")
    msg = message_of(ReadWriteException) do
        return DataPipeline.finalise(handle)
    end
    @test occursin("which this code run is registering as '$given'", msg)
    @test isempty(registered_versions(given))

    # A data product with no file, as the entry of a whole deposit is, holds
    # none for a file of its source to differ from
    whole = "sources/onefile/whole/$uid"
    object = DataPipeline._createentry(registry, "object",
                                       Dict("description" => "a deposit",
                                            "authors" => []))
    space = DataPipeline._getentry(registry, "namespace",
                                   Dict("name" => namespace))
    deposit = DataPipeline._createentry(registry, "data_product",
                                        Dict("name" => "$whole/entry",
                                             "version" => "0.0.1",
                                             "object" => object["url"],
                                             "namespace" => space["url"]))
    DataPipeline._createentry(registry, "external_object",
                              Dict("data_product" => deposit["url"],
                                   "identifier" => "https://doi.org/$doi",
                                   "title" => "Whole $uid",
                                   "version" => "2.1.0",
                                   "release_date" => "2021-03-04T00:00:00Z"))
    handle = offering(whole => "0.0.1")
    link_write!(handle, whole; path = file_of("whole $uid\n"), of("Whole")...)
    DataPipeline.finalise(handle)
    @test sort(source_of(registered(whole, "0.0.1"))["data_products"]) ==
          sort([deposit["url"], registered(whole, "0.0.1")["url"]])

    # A file found at a second address on a host keeps the first, and a
    # warning says so
    moved = "sources/onefile/moved/$uid"
    handle = offering(moved => "0.0.1")
    link_write!(handle, moved; path = second_file,
                of("Moved"; original_store = "$host/mirror/two.txt")...)
    kept = "$host/mirror/two.txt is already recorded at $host/two.txt"
    @test_logs (:warn, Regex(kept)) DataPipeline.finalise(handle)
    @test source_of(registered(moved, "0.0.1"))["original_store"] ==
          locations[2]["url"]
end

Test.@testset "a file with a source identical to a version" begin
    name = "sources/versions/$uid"
    file, changed = file_of("first $uid\n"), file_of("second $uid\n")
    function of(; keywords...)
        return (; bibtex = "deposit", primary = true,
                title = "Versions $uid", keywords...)
    end
    # Write `path` as `version` of `product`, with `authors` registered and
    # what `said` of it, and return the version it is identical to, or
    # `nothing`
    function identical_to(path, version, product = name; authors = nothing,
                          said...)
        handle = offering(product => version)
        isnothing(authors) || register_authors!(handle, authors)
        link_write!(handle, product; path, said...)
        DataPipeline.finalise(handle)
        return get(handle.identical, (product, nothing), nothing)
    end
    # The path of the file a version holds
    function registered_path(product, version)
        return DataPipeline._getstoragelocation(registry,
                                                registered(product,
                                                           version)["object"]).path
    end

    @test isnothing(identical_to(file, "0.0.1"; of()...))
    stored = registered_path(name, "0.0.1")
    first_source = source_of(registered(name, "0.0.1"))["url"]

    # A version that exists is refused at the call, whatever is written
    handle = offering(name => "0.0.1")
    msg = message_of(ReadWriteException) do
        return link_write!(handle, name; path = file_of("first $uid\n"),
                           of()...)
    end
    @test startswith(msg, "$namespace:$name@v0.0.1 is registered already")
    DataPipeline.finalise(handle)

    # The same bytes of the same source, with the same authors and licence,
    # are a version identical to the first, of the same source and file
    @test identical_to(file_of("first $uid\n"), "0.0.2"; of()...) == "0.0.1"
    @test source_of(registered(name, "0.0.2"))["url"] == first_source
    @test registered_path(name, "0.0.2") == stored
    # ... as with no source, a file with none being compared by its bytes
    @test identical_to(file, "0.0.3") == "0.0.2"

    # Other bytes of the same source are an error: a source is one file
    handle = offering(name => "0.0.4")
    @test_throws ReadWriteException link_write!(handle, name; path = changed,
                                                of()...)
    @test isempty(handle.outputs)
    # ... and of another release of it, identical to nothing
    link_write!(handle, name; path = changed, of(release_version = "2.2")...)
    DataPipeline.finalise(handle)
    @test isempty(handle.identical)
    second_source = source_of(registered(name, "0.0.4"))
    @test second_source["url"] != first_source
    @test second_source["version"] == "2.2.0"

    # The same bytes and source under another licence are identical to
    # nothing, of the same source
    licensed = of(release_version = "2.2", licence = "CC0-1.0")
    @test isnothing(identical_to(changed, "0.0.5"; licensed...))
    @test source_of(registered(name, "0.0.5"))["url"] == second_source["url"]
    @test licences_of(object_of(registered(name, "0.0.5"))) ==
          [("CC0-1.0", spdx * "CC0-1.0")]
    # ... and so are they with other authors, the organisation now having an
    # identifier
    @test isnothing(identical_to(changed, "0.0.6"; licensed...,
                                 authors = organisation => ror))
    @test sort(object_of(registered(name, "0.0.6"))["authors"]) ==
          sort([author(orcid), author(ror)])
    # ... while what else is said of the source makes no difference: the
    # registry keeps what it was first told
    @test identical_to(changed, "0.0.7"; licensed...,
                       authors = organisation => ror, primary = false,
                       description = "said later",
                       release_date = "2023") == "0.0.6"
    # The same bytes of another release of the source are identical to nothing
    @test isnothing(identical_to(changed, "0.0.8";
                                 of(release_version = "2.3",
                                    licence = "CC0-1.0")...))
    @test source_of(registered(name, "0.0.8"))["version"] == "2.3.0"

    # An author that a citation names twice is the file's author once, so
    # that the file is found identical
    twice = "sources/versions/twice/$uid"
    @test isnothing(identical_to(file_of("twice $uid\n"), "0.0.1", twice;
                                 bibtex = "twice", primary = true))
    @test object_of(registered(twice, "0.0.1"))["authors"] ==
          [author_named(organisation)]
    @test identical_to(file_of("twice $uid\n"), "0.0.2", twice;
                       bibtex = "twice", primary = true) == "0.0.1"

    # A source for bytes that were registered with none is identical to
    # nothing
    bare = "sources/versions/bare/$uid"
    @test isnothing(identical_to(file_of("bare $uid\n"), "0.0.1", bare))
    @test isnothing(identical_to(file_of("bare $uid\n"), "0.0.2", bare;
                                 of(title = "Bare $uid")...))
    @test isnothing(registered(bare, "0.0.1")["external_object"])
    @test source_of(registered(bare, "0.0.2"))["title"] == "Bare $uid"

    # A file that is written after the call is found identical by `finalise`
    # in the same way: by its bytes and by what is said of its source
    later = "sources/versions/later/$uid"
    for (offered, licence, identical) in (("0.0.1", nothing, nothing),
        ("0.0.2", nothing, "0.0.1"),
        ("0.0.3", "CC0-1.0", nothing))
        handle = offering(later => offered)
        written = link_write!(handle, later;
                              of(title = "Later $uid", licence = licence)...)
        write(written, "later $uid\n")
        DataPipeline.finalise(handle)
        @test get(handle.identical, (later, nothing), nothing) == identical
    end
    @test registered_versions(later) == ["0.0.1", "0.0.2", "0.0.3"]
end

Test.@testset "one source for a data product in a code run" begin
    name, unsourced = "sources/again/$uid", "sources/again/bare/$uid"
    handle = offering(name => "0.0.1", unsourced => "0.0.1")
    file = file_of("again $uid\n")
    of(title) = (bibtex = "deposit", primary = true, title = "$title $uid")

    # A further call for the data product may name its source again, or none
    stored = link_write!(handle, name; path = file, of("Again")...)
    @test link_write!(handle, name; path = file, of("Again")...) == stored
    @test link_write!(handle, name; of("Again")...) == stored
    @test link_write!(handle, name, path = file) == stored
    @test link_write!(handle, name) == stored
    # ... but not another, nor one where the first call named none
    for other in (of("Other"), (; of("Again")..., licence = "CC0-1.0"))
        for call in (() -> link_write!(handle, name; path = file, other...),
                     () -> link_write!(handle, name; other...))
            @test occursin("with another source",
                           message_of(call, ReadWriteException))
        end
    end
    link_write!(handle, unsourced, path = file_of("bare $uid\n"))
    msg = message_of(ReadWriteException) do
        return link_write!(handle, unsourced; of("Again")...)
    end
    @test occursin("with no source", msg)
    @test handle.outputs[(name, nothing)]["source"].title == "Again $uid"
    @test !haskey(handle.outputs[(unsourced, nothing)], "source")

    # The source is registered with the data product whatever else of it the
    # code run writes
    tabled = "sources/again/tabled/$uid"
    handle = offering(tabled => "0.0.1", file_type = "toml")
    link_write!(handle, tabled; of("Tabled")...)
    write_estimate!(handle, 1.5, tabled, "an/estimate", "an estimate")
    DataPipeline.finalise(handle)
    @test source_of(registered(tabled, "0.0.1"))["title"] == "Tabled $uid"
    @test length(entry(handle.code_run_obj)["outputs"]) == 2
end

# The whole-object component of a registered data product, which is what a
# code run lists among its inputs and outputs
whole(product) = DataPipeline._wholeobjectcomponent(registry, product["object"])
inputs_namespace = launch.config["run_metadata"]["default_input_namespace"]

Test.@testset "link_register!() with no file" begin
    deposit = "sources/register/deposit/$uid"
    of(; keywords...) = (; bibtex = "deposit", primary = true, keywords...)

    # A data product with no file, its source the deposit's, registered in
    # the run's input namespace and read by the run, which made nothing
    handle = offering()
    @test isnothing(link_register!(handle, deposit; of()...))
    @test handle.inputs[(deposit, nothing)]["use_version"] == "0.0.1"
    DataPipeline.finalise(handle)
    product = registered(deposit, "0.0.1")
    @test isnothing(object_of(product)["storage_location"])
    @test entry(product["namespace"])["name"] == inputs_namespace
    source = source_of(product)
    @test source["identifier"] == "https://doi.org/$doi"
    @test source["title"] == "A deposit of several files $uid"
    @test sort(object_of(product)["authors"]) ==
          sort([author(orcid), author_named(organisation)])
    run = entry(handle.code_run_obj)
    @test run["inputs"] == [whole(product)] && isempty(run["outputs"])

    # The same again is that version, nothing new being registered, however
    # often a run asks
    handle = offering()
    for _ in 1:2
        @test isnothing(link_register!(handle, deposit; of()...))
    end
    DataPipeline.finalise(handle)
    @test registered_versions(deposit) == ["0.0.1"]
    @test entry(handle.code_run_obj)["inputs"] == [whole(product)]

    # Other terms are the next patch version
    handle = offering()
    link_register!(handle, deposit; of(licence = "CC0-1.0")...)
    DataPipeline.finalise(handle)
    @test registered_versions(deposit) == ["0.0.1", "0.0.2"]
    @test licences_of(object_of(registered(deposit, "0.0.2"))) ==
          [("CC0-1.0", spdx * "CC0-1.0")]

    # A version asked for: registered so already, it is that one; registered
    # otherwise, an error; not registered, it is registered
    handle = offering()
    link_register!(handle, "$deposit@0.0.1"; of()...)
    @test handle.inputs[(deposit, nothing)]["use_version"] == "0.0.1"
    msg = message_of(ReadWriteException) do
        return link_register!(offering(), "$deposit@v0.0.2"; of()...)
    end
    @test occursin("version 0.0.2 of $inputs_namespace:$deposit", msg)
    link_register!(offering(), "$deposit@1.0"; of()...)
    @test registered_versions(deposit) == ["0.0.1", "0.0.2", "1.0.0"]
    # ... and one run reads one version of a name
    msg = message_of(ReadWriteException) do
        return link_register!(handle, "$deposit@1.0.0"; of()...)
    end
    @test occursin("already an input of this code run, as version 0.0.1", msg)

    # In a namespace of its own, named before the colon
    elsewhere = "elsewhere-$(uid[1:8])"
    link_register!(offering(), "$elsewhere:$deposit"; of()...)
    space = DataPipeline._getid(registry, "namespace",
                                Dict("name" => elsewhere))
    @test !isnothing(DataPipeline._getentry(registry, "data_product",
                                            Dict("name" => deposit,
                                                 "namespace" => space,
                                                 "version" => "0.0.1")))
end

Test.@testset "link_read!() of a data product with no file" begin
    deposit = "sources/read/deposit/$uid"
    beside = "sources/read/file/$uid"

    # The deposit registered by one run, and a file by another
    handle = offering()
    link_register!(handle, deposit, bibtex = "deposit", primary = true)
    DataPipeline.finalise(handle)
    product = registered(deposit, "0.0.1")
    writing = offering(beside => "0.0.1")
    link_write!(writing, beside, path = file_of("read beside a deposit $uid\n"))
    DataPipeline.finalise(writing)
    # A run offered these names by its read: entries
    function reading(names...)
        config = DataPipeline._createconfig(cpath)
        for name in names
            DataPipeline._addread(config, name, use_version = "0.0.1",
                                  use_namespace = name == deposit ?
                                                  inputs_namespace : namespace)
        end
        return DataPipeline.initialise(config, config)
    end

    # The next run reads the deposit: nothing returned, and the deposit the
    # run's input, as link_register! records it
    handle = reading(deposit)
    @test isnothing(link_read!(handle, deposit))
    @test isnothing(handle.inputs[(deposit, nothing)]["path"])
    @test isnothing(link_read!(handle, deposit))
    @test DataPipeline.canread(handle, deposit)
    DataPipeline.finalise(handle)
    run = entry(handle.code_run_obj)
    @test run["inputs"] == [whole(product)] && isempty(run["outputs"])

    # It has no file to put anywhere, which leaves the run's inputs as they
    # were, nor a component to read
    handle = reading(deposit)
    msg = message_of(ReadWriteException) do
        return link_read!(handle, deposit,
                          path = joinpath(mktempdir(), "deposit.txt"))
    end
    @test occursin("is a data product with no file, so there is nothing to put at",
                   msg)
    @test isempty(handle.inputs)
    msg = message_of(() -> read_estimate!(handle, deposit, "rate"),
                     ReadWriteException)
    @test occursin("is a data product with no file, so it has no component rate",
                   msg)
    DataPipeline.finalise(handle)

    # A pattern matching it and the file records both, linking and listing
    # the file alone
    handle = reading(deposit, beside)
    pattern = "sources/read/*/$uid"
    folder = link_read!(handle, pattern)
    @test readdir(folder) == [replace(beside, "/" => "_") * ".txt"]
    @test link_read_files!(handle, pattern) ==
          [handle.inputs[(beside, nothing)]["path"]]
    @test sort(collect(keys(handle.inputs))) ==
          sort([(deposit, nothing), (beside, nothing)])
    DataPipeline.finalise(handle)
    @test sort(entry(handle.code_run_obj)["inputs"]) ==
          sort([whole(product), whole(registered(beside, "0.0.1"))])
end

Test.@testset "a deposit that fair pull registers from a no_file entry" begin
    deposit = "sources/pulled/deposit/$uid"
    pulling = joinpath(mktempdir(), "pull.yaml")
    write(pulling,
          """
          run_metadata:
            description: A deposit registered by the CLI
            script: |
              echo pulled
          register:
          - namespace: $inputs_namespace
            full_name: The suite's input namespace
          - external_object: $deposit
            namespace_name: $inputs_namespace
            title: A deposit with no file $uid
            description: A deposit with no file of its own
            identifier: https://doi.org/10.1038/s41592-020-0856-2
            release_date: 2026-01-01T12:00
            version: "1.0.0"
            primary: True
            no_file: true
          """)
    pulled = DataPipeline._capturefair(DataPipeline._faircommand(nothing),
                                       "pull", "--local", pulling,
                                       dir = DataPipeline._fairroot(pwd()))
    said = pulled.printed * pulled.errors
    if pulled.status != 0 && occursin("not a valid identifier", said)
        @info "the CLI could not check the deposit's identifier online: not reading a deposit it registered"
    else
        # The run fair run would prepare reads it through its read: entry; a
        # pull that failed otherwise fails here, saying what fair said
        @test pulled.status == 0
        pulled.status == 0 || @info "fair pull said: $said"
        if pulled.status == 0
            config = DataPipeline._createconfig(cpath)
            DataPipeline._addread(config, deposit, use_version = "1.0.0",
                                  use_namespace = inputs_namespace)
            handle = DataPipeline.initialise(config, config)
            @test isnothing(link_read!(handle, deposit))
            DataPipeline.finalise(handle)
            product = registered(deposit, "1.0.0")
            @test isnothing(object_of(product)["storage_location"])
            @test entry(handle.code_run_obj)["inputs"] == [whole(product)]
        end
    end
end

Test.@testset "link_register!() with a file" begin
    fetched = "sources/register/file/$uid"
    file = file_of("registered file $uid\n")
    changed = file_of("registered file again $uid\n")
    host = "https://fetched-$uid.org"
    function of(; keywords...)
        return (; bibtex = "deposit", primary = true,
                title = "Registered file $uid", keywords...)
    end

    # A copy of the file is put in the data store by its hash, its path there
    # returned, and it is the run's input, with its source
    handle = offering()
    stored = link_register!(handle, fetched;
                            of(path = file,
                               original_store = "$host/files/f.txt")...)
    @test stored ==
          joinpath(datastore, inputs_namespace, fetched,
                   DataPipeline._getfilehash(file) * ".txt")
    @test read(stored, String) == "registered file $uid\n"
    @test !samefile(stored, file)
    write(file, "registered file, written in place $uid\n")
    @test read(stored, String) == "registered file $uid\n"
    write(file, "registered file $uid\n")
    @test handle.inputs[(fetched, nothing)]["path"] == stored
    DataPipeline.finalise(handle)
    product = registered(fetched, "0.0.1")
    location = entry(object_of(product)["storage_location"])
    @test location["hash"] == DataPipeline._getfilehash(file)
    @test entry(source_of(product)["original_store"])["path"] == "files/f.txt"
    run = entry(handle.code_run_obj)
    @test run["inputs"] == [whole(product)] && isempty(run["outputs"])
    @test sort(object_of(product)["authors"]) ==
          sort([author(orcid), author_named(organisation)])

    # Bytes that the store holds already are pointed at, not put there again
    again = "$fetched/again"
    @test link_register!(offering(), again;
                         of(path = file_of("registered file $uid\n"),
                            title = "The same bytes $uid")...) == stored
    @test !isdir(joinpath(datastore, inputs_namespace, again))

    # The same file again is the registered one; another file of the same
    # source is refused; of another release of it, the next version
    handle = offering()
    @test link_register!(handle, fetched;
                         of(path = file_of("registered file $uid\n"))...) ==
          stored
    @test_throws ReadWriteException link_register!(offering(), fetched;
                                                   of(path = changed)...)
    @test registered_versions(fetched) == ["0.0.1"]
    link_register!(offering(), fetched;
                   of(path = changed, release_version = "2.2")...)
    @test registered_versions(fetched) == ["0.0.1", "0.0.2"]

    # A version with a file and one with none are never the same: each in
    # turn is the next version
    link_register!(offering(), fetched; of(release_version = "2.2")...)
    @test registered_versions(fetched) == ["0.0.1", "0.0.2", "0.0.3"]
    @test isnothing(object_of(registered(fetched, "0.0.3"))["storage_location"])
    link_register!(offering(), fetched;
                   of(path = changed, release_version = "2.2")...)
    @test registered_versions(fetched) == ["0.0.1", "0.0.2", "0.0.3", "0.0.4"]
end

Test.@testset "link_register!() of a file the store holds unregistered" begin
    # As where an earlier run's registration was lost: a file under the hash
    # in the data store, which the registry has no location for, left there
    # by `left(file, stored)`; whatever was there, the file's bytes are then
    # registered there. Return the two files, and the stored file's inode
    # before and after
    function registering(case, left)
        name = "sources/register/unregistered/$case/$uid"
        file = file_of("held unregistered, $case $uid\n")
        hash = DataPipeline._getfilehash(file)
        stored = joinpath(datastore, inputs_namespace, name, "$hash.txt")
        mkpath(dirname(stored))
        left(file, stored)
        before = stat(stored).inode
        handle = offering()
        @test link_register!(handle, name, path = file, bibtex = "deposit",
                             primary = true,
                             title = "Held unregistered, $case $uid") == stored
        @test read(stored, String) == "held unregistered, $case $uid\n"
        DataPipeline.finalise(handle)
        product = registered(name, "0.0.1")
        @test entry(object_of(product)["storage_location"])["hash"] == hash
        return (; file, stored, before, after = stat(stored).inode)
    end

    # A copy is kept
    held = registering("copied", cp)
    @test held.after == held.before
    # A link to the file, through which writing to the file would change the
    # registered one, is replaced by a file of its own; a copy where no link
    # can be made
    for (case, link) in (("linked", hardlink), ("symlinked", symlink))
        function linked(file, stored)
            try
                link(file, stored)
            catch e
                e isa Base.IOError || rethrow()
                cp(file, stored)
            end
        end
        held = registering(case, linked)
        @test !islink(held.stored) && !samefile(held.stored, held.file)
    end

    # Other bytes under the hash's name are replaced, with a warning
    @test_logs (:warn,
                r"^replacing the file at .*, whose bytes have the SHA-1 hash") match_mode=:any registering("other",
                                                                                                           (file,
                                                                                                            stored) -> write(stored,
                                                                                                                             "other $uid\n"))
end

Test.@testset "a source the registry would refuse" begin
    # Refused at the call, before anything is registered, so that no data
    # product is left without its source: here a blank title, of a source the
    # registry holds nothing of, so that no other lookup refuses it first
    registering = "sources/refused/registered/$uid"
    writing = "sources/refused/written/$uid"
    handle = offering(writing => "0.0.1")
    register_citations!(handle,
                        """
                        @misc{refused, title = {Refused $uid}, year = 2020,
                              url = {https://example.org/$uid/refused}}
                        """)
    @test_throws ArgumentError link_register!(handle, registering,
                                              path = file_of("refused, registered $uid\n"),
                                              bibtex = "refused",
                                              primary = true, title = " ")
    @test !isdir(joinpath(datastore, inputs_namespace, registering))
    @test_throws ArgumentError link_write!(handle, writing,
                                           path = file_of("refused, written $uid\n"),
                                           bibtex = "refused", primary = true,
                                           title = "")
    @test isempty(handle.outputs)
    DataPipeline.finalise(handle)
    @test isempty(registered_versions(registering))
    @test isempty(registered_versions(writing))
end

Test.@testset "a title with white space around it" begin
    # Stored stripped, as the registry keeps it, so that the same call again
    # finds the source registered and registers nothing new
    padded = "sources/register/padded/$uid"
    file = file_of("a padded title $uid\n")
    for _ in 1:2
        handle = offering()
        link_register!(handle, padded, path = file, bibtex = "deposit",
                       primary = true, title = "  A padded title $uid ")
        DataPipeline.finalise(handle)
    end
    @test registered_versions(padded) == ["0.0.1"]
    @test source_of(registered(padded, "0.0.1"))["title"] ==
          "A padded title $uid"
end

Test.@testset "a licence held under an identifier the list has replaced" begin
    replaced = "sources/register/replaced/$uid"
    file = file_of("replaced licence $uid\n")
    function of(; keywords...)
        return (; bibtex = "deposit", primary = true,
                title = "Replaced licence $uid", keywords...)
    end

    # Registered with no licence, then given one under an identifier that the
    # SPDX list has since replaced by another, as an earlier version of the
    # package or another client records it
    handle = offering()
    link_register!(handle, replaced; of(path = file)...)
    DataPipeline.finalise(handle)
    object = registered(replaced, "0.0.1")["object"]
    DataPipeline._createentry(registry, "licence",
                              Dict("object" => object,
                                   "licence_info" => "GPL-3.0+",
                                   "identifier" => spdx * "GPL-3.0+"))

    # It is the licence replacing it, however that is given, and registering
    # the file with that licence registers nothing new
    handle = offering()
    for licence in ("GPL-3.0-or-later", "GPL-3.0+",
        "GNU General Public License v3.0 or later")
        @test DataPipeline.isregistered(handle, replaced; of(; licence)...)
    end
    @test !DataPipeline.isregistered(handle, replaced;
                                     of(licence = "GPL-3.0-only")...)
    link_register!(handle, replaced;
                   of(path = file, licence = "GPL-3.0-or-later")...)
    DataPipeline.finalise(handle)
    @test registered_versions(replaced) == ["0.0.1"]
    @test licences_of(object_of(registered(replaced, "0.0.1"))) ==
          [("GPL-3.0+", spdx * "GPL-3.0+")]
end

Test.@testset "link_register!() with supersede = true" begin
    name = "sources/register/supersede/$uid"
    of(; keywords...) = (; bibtex = "deposit", primary = true,
                         supersede = true, keywords...)

    # The first version supersedes nothing; the next patch supersedes it,
    # with an issue queued for finalise; the same again is unchanged
    handle = offering()
    @test_logs (:info, r"first version of its name") match_mode=:any link_register!(handle,
                                                                                    name;
                                                                                    of()...)
    @test isempty(handle.issues)
    DataPipeline.finalise(handle)
    handle = offering()
    link_register!(handle, name; of(licence = "CC0-1.0")...)
    issue = only(handle.issues)
    @test issue.severity == 0
    @test issue.description == "Superseded by $inputs_namespace:$name@v0.0.2"
    @test issue.targets ==
          [DataPipeline.ExistingDataProduct("$inputs_namespace:$name@v0.0.1")]
    DataPipeline.finalise(handle)
    posted = DataPipeline._getentry(registry, "issue",
                                    Dict("description" =>
                                             issue.description))
    @test posted["component_issues"] == [whole(registered(name, "0.0.1"))]
    handle = offering()
    @test_logs (:info, r"registered already, unchanged") match_mode=:any link_register!(handle,
                                                                                        name;
                                                                                        of(licence = "CC0-1.0")...)
    @test isempty(handle.issues)
    DataPipeline.finalise(handle)
end

Test.@testset "what link_register!() refuses" begin
    handle = offering()
    name = "sources/register/refused/$uid"
    refused(type; keywords...) = message_of(type) do
        return link_register!(handle, name; keywords...)
    end
    # No source, a pattern, where a file came from with no file, a version
    # that is not one, no file at the path, and nothing said of the source's
    # relation to the file
    @test occursin("name its source", refused(ArgumentError, primary = true))
    @test occursin("is a pattern",
                   message_of(ArgumentError) do
                       return link_register!(handle, "$name/*",
                                             bibtex = "deposit",
                                             primary = true)
                   end)
    @test occursin("with no `path` has no file",
                   refused(ArgumentError, bibtex = "deposit", primary = true,
                           original_store = "https://example.org/f.txt"))
    @test occursin("`version`",
                   message_of(ArgumentError) do
                       return link_register!(handle, "$name@061",
                                             bibtex = "deposit",
                                             primary = true)
                   end)
    # A name outside the convention, in the name or the namespace
    @test occursin("is not a data product name",
                   message_of(ArgumentError) do
                       return link_register!(handle, "$name/.csv",
                                             bibtex = "deposit",
                                             primary = true)
                   end)
    @test occursin("is not a namespace",
                   message_of(ArgumentError) do
                       return link_register!(handle, "a space:$name",
                                             bibtex = "deposit",
                                             primary = true)
                   end)
    @test occursin("no file to register",
                   refused(ReadWriteException, bibtex = "deposit",
                           primary = true,
                           path = joinpath(mktempdir(), "absent.txt")))
    @test occursin("`primary = true`",
                   refused(ArgumentError, bibtex = "deposit"))
    @test isempty(handle.inputs) && isempty(registered_versions(name))
end

Test.@testset "a fetch run, and a run that reads what it fetched" begin
    deposit = "sources/chain/deposit/$uid"
    fetched = "sources/chain/file/$uid"
    result = "sources/chain/result/$uid"

    # The fetch run registers the deposit and reads it, and writes a file of
    # the deposit as its output, with a source of the file's own
    fetching = offering(fetched => "0.0.1")
    link_register!(fetching, deposit, bibtex = "deposit", primary = true)
    link_write!(fetching, fetched, path = file_of("chain $uid\n"),
                bibtex = "deposit", primary = true, title = "Chain file $uid")
    DataPipeline.finalise(fetching)

    # The model run reads the file and writes a result
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, fetched, use_version = "0.0.1")
    DataPipeline._addwrite(config, result, "a result", file_type = "txt",
                           use_version = "0.0.1")
    modelling = DataPipeline.initialise(config, config)
    input = link_read!(modelling, fetched)
    @test read(input, String) == "chain $uid\n"
    write(link_write!(modelling, result), "made from " * read(input, String))
    DataPipeline.finalise(modelling)

    # The result was made by the model run from the file, which the fetch
    # run made from the deposit; the file and the deposit have the one DOI
    # and a title each, and the deposit has no file
    entry_of, file_of_deposit, made = (registered(name, "0.0.1")
                                       for name in (deposit, fetched, result))
    fetch_run = entry(fetching.code_run_obj)
    model_run = entry(modelling.code_run_obj)
    @test fetch_run["inputs"] == [whole(entry_of)]
    @test fetch_run["outputs"] == [whole(file_of_deposit)]
    @test model_run["inputs"] == [whole(file_of_deposit)]
    @test model_run["outputs"] == [whole(made)]
    @test source_of(entry_of)["identifier"] ==
          source_of(file_of_deposit)["identifier"] == "https://doi.org/$doi"
    @test source_of(entry_of)["title"] == "A deposit of several files $uid"
    @test source_of(file_of_deposit)["title"] == "Chain file $uid"
    @test isnothing(object_of(entry_of)["storage_location"])
    @test isnothing(made["external_object"])
end

# How many rows the registry holds in each table a question must leave alone
tables = ("author", "data_product", "object", "external_object", "licence",
          "storage_location", "namespace")
function counts()
    return Dict(table => entry(string(registry.url, table, "/"))["count"]
                for table in tables)
end

Test.@testset "isregistered()" begin
    name = "sources/isregistered/file/$uid"
    deposit = "sources/isregistered/deposit/$uid"
    looked = "sources/isregistered/looked/$uid"
    dateless = "sources/isregistered/dateless/$uid"
    of(; keywords...) = (; bibtex = "deposit", primary = true,
                         title = "Asked about $uid", licence = "CC-BY-4.0",
                         keywords...)
    # The deposit's DOI cited with an author the registry has not got
    reauthored = """
    @dataset{reauthored,
      author = {{Unregistered $uid}, Ada},
      title = {A deposit of several files $uid},
      date = {2021-03-04},
      doi = {$doi},
      version = {2.1}
    }
    """
    # A citation that gives no date, so that registering needs one
    undated = """
    @misc{dateless,
      title = {A deposit with no date $uid},
      url = {https://example.org/$uid/dateless}
    }
    """
    # A DOI's metadata, as a lookup would read it, its creator with an ORCID
    md_doi = "https://doi.org/10.5555/isregistered.$uid"
    known, unknown = "$orcid-known", "$orcid-unknown"
    function metadata(identifier)
        record = Dict("doi" => "10.5555/isregistered.$uid",
                      "titles" => [Dict("title" => "Looked up $uid")],
                      "creators" => [
                          Dict("givenName" => "Ada",
                               "familyName" => "Looked $uid",
                               "nameIdentifiers" =>
                                   [Dict("nameIdentifier" => identifier,
                                         "nameIdentifierScheme" => "ORCID")])],
                      "dates" =>
                          [Dict("date" => "2024-01-02",
                                "dateType" => "Issued")])
        return DataPipeline._datacitecitation(record, md_doi)
    end

    # Registered: a file and a deposit with no file from the citation, a
    # deposit from the citation with no date, and a file from the DOI's
    # metadata, which registers its creator's ORCID
    handle = offering()
    register_citations!(handle, undated)
    link_register!(handle, name; of(path = file_of("asked about $uid\n"))...)
    link_register!(handle, deposit, bibtex = "deposit", primary = true)
    link_register!(handle, dateless, bibtex = "dateless", primary = true,
                   release_date = "2020")
    handle.doi_lookups[md_doi] = metadata(known)
    link_register!(handle, looked, path = file_of("looked up $uid\n"),
                   doi = md_doi, primary = true)
    DataPipeline.finalise(handle)

    # A rehearsal, from a job folder made like the runs' configs
    function rehearsing()
        job = dirname(DataPipeline._createconfig(joinpath(dirname(cpath),
                                                          "isregistered",
                                                          "config.yaml")))
        DataPipeline._replrehearse(job)
        rehearsal = DataPipeline.initialise()
        register_citations!(rehearsal, citations)
        register_authors!(rehearsal, person => orcid)
        return rehearsal
    end

    # Asked in a recorded run and in a rehearsal alike
    for make in (offering, rehearsing)
        asking = make()
        register_citations!(asking, reauthored, undated)
        before, authors = counts(), deepcopy(asking.authors)

        # By name: anything registered under it, or at that version, in the
        # run's default input namespace unless named
        @test DataPipeline.isregistered(asking, name)
        @test DataPipeline.isregistered(asking, "$inputs_namespace:$name")
        @test DataPipeline.isregistered(asking, "$name@0.0.1")
        @test !DataPipeline.isregistered(asking, "$name@0.0.2")
        @test !DataPipeline.isregistered(asking, "$name/never")
        @test !DataPipeline.isregistered(asking, "never_$(uid[1:8]):$name")
        @test DataPipeline.isregistered(asking, deposit)

        # With the source: the same identifier, title, release version,
        # authors and licence; what the registry keeps from the first
        # registration, and the bytes, not compared
        @test DataPipeline.isregistered(asking, name; of()...)
        @test DataPipeline.isregistered(asking, "$name@0.0.1"; of()...)
        @test DataPipeline.isregistered(asking, name;
                                        of(description = "said otherwise $uid",
                                           primary = false,
                                           release_date = "2000-01-01",
                                           original_store = "https://elsewhere-$uid.org/f.txt")...)
        @test DataPipeline.isregistered(asking, deposit, bibtex = "deposit",
                                        primary = true)
        @test !DataPipeline.isregistered(asking, name;
                                         of(title = "Another title $uid")...)
        @test !DataPipeline.isregistered(asking, name;
                                         of(release_version = "9.9")...)
        @test !DataPipeline.isregistered(asking, name;
                                         of(licence = "CC0-1.0")...)
        @test !DataPipeline.isregistered(asking, name; of(bibtex = "page")...)
        @test !DataPipeline.isregistered(asking, "$name/never"; of()...)
        # `primary` and a release date are not compared, so may be left out,
        # though what is given is checked as the link calls check it
        @test DataPipeline.isregistered(asking, name; of(primary = nothing)...)
        @test DataPipeline.isregistered(asking, deposit, bibtex = "deposit")
        @test DataPipeline.isregistered(asking, dateless, bibtex = "dateless")
        @test DataPipeline.isregistered(asking, dateless, bibtex = "dateless",
                                        primary = true)
        @test !DataPipeline.isregistered(asking, dateless, bibtex = "dateless",
                                         release_version = "9.9")
        @test_throws ArgumentError DataPipeline.isregistered(asking, name;
                                                             of(release_date = "June 2021")...)
        # An author the registry has not got, by name or by an ORCID the
        # metadata gives, makes it false and is not registered; the ORCID it
        # has makes it true
        @test !DataPipeline.isregistered(asking, name;
                                         of(bibtex = "reauthored")...)
        asking.doi_lookups[md_doi] = metadata(unknown)
        @test !DataPipeline.isregistered(asking, looked, doi = md_doi,
                                         primary = true)
        asking.doi_lookups[md_doi] = metadata(known)
        @test DataPipeline.isregistered(asking, looked, doi = md_doi,
                                        primary = true)
        @test isempty(DataPipeline._getentries(registry, "author",
                                               Dict("identifier" => unknown)))
        @test isempty(DataPipeline._getentries(registry, "author",
                                               Dict("name" => "Ada Unregistered $uid")))
        @test counts() == before
        @test asking.authors == authors

        # Refused as the link calls refuse: a pattern, and a source not named
        @test_throws ArgumentError DataPipeline.isregistered(asking,
                                                             "sources/*/$uid")
        @test_throws ArgumentError DataPipeline.isregistered(asking, name,
                                                             title = "Untold $uid")
        asking isa DataPipeline.DataRegistryHandle{DataPipeline.RecordedRun} ?
        DataPipeline.finalise(asking) : DataPipeline.discard(asking)
    end

    # A run whose default input namespace is another looks there by default
    config = DataPipeline._createconfig(cpath,
                                        default_input_namespace = "elsewhere_$(uid[1:8])")
    elsewhere = DataPipeline.initialise(config, config)
    @test !DataPipeline.isregistered(elsewhere, name)
    @test DataPipeline.isregistered(elsewhere, "$inputs_namespace:$name")
    DataPipeline.finalise(elsewhere)
end

Test.@testset "isregistered() of a label in the config" begin
    other = "isregistered_$(uid[1:8])"
    aliased = "sources/isregistered/aliased/$uid"
    wild = "sources/isregistered/wild/$uid"
    of(; keywords...) = (; bibtex = "deposit", primary = true,
                         title = "Aliased $uid", licence = "CC-BY-4.0",
                         keywords...)
    # A run whose config gives `aliased_label` the name `aliased`, in another
    # namespace, at `version`; covers names under `wild`'s folder by a
    # pattern; has `aliased` at 0.0.1 under a `read:` label and a `read:`
    # pattern, a label in both blocks, a label whose name holds the run's
    # uuid, and a name two `write:` patterns cover
    function configured(version; rehearsal = false)
        config = DataPipeline._createconfig(rehearsal ?
                                            joinpath(dirname(cpath),
                                                     "isregistered-label",
                                                     "config.yaml") : cpath)
        DataPipeline._addwrite(config, "aliased_label", "an aliased file",
                               file_type = "txt", use_data_product = aliased,
                               use_namespace = other, use_version = version)
        DataPipeline._addwrite(config, "sources/isregistered/wild/*",
                               "files under a pattern", file_type = "txt",
                               use_version = "0.0.1")
        DataPipeline._addread(config, "read_label", use_data_product = aliased,
                              use_namespace = other, use_version = "0.0.1")
        DataPipeline._addread(config, "sources/isregistered/aliased/*",
                              use_namespace = other)
        DataPipeline._addwrite(config, "both_label", "written, and read",
                               file_type = "txt", use_data_product = wild,
                               use_version = "0.0.1")
        DataPipeline._addread(config, "both_label",
                              use_data_product = "$aliased/never",
                              use_namespace = other, use_version = "0.0.1")
        DataPipeline._addwrite(config, "run_label",
                               "a name with the run's uuid",
                               file_type = "txt",
                               use_data_product = "sources/isregistered/run/\${{RUN_ID}}",
                               use_version = "0.0.1")
        for pattern in ("sources/isregistered/two/*", "sources/isregistered/*/x")
            DataPipeline._addwrite(config, pattern, "one of two patterns",
                                   file_type = "txt", use_version = "0.0.1")
        end
        if rehearsal
            DataPipeline._replrehearse(dirname(config))
            handle = DataPipeline.initialise()
        else
            handle = DataPipeline.initialise(config, config)
        end
        register_citations!(handle, citations)
        register_authors!(handle, person => orcid)
        return handle
    end

    # Registered: `aliased` at 0.0.1, and at 0.0.2 from another release under
    # another licence; and a file under the pattern
    handle = configured("0.0.1")
    link_write!(handle, "aliased_label";
                of(path = file_of("aliased $uid\n"))...)
    link_write!(handle, wild;
                of(path = file_of("wild $uid\n"), title = "Wild $uid")...)
    DataPipeline.finalise(handle)
    handle = configured("0.0.2")
    link_write!(handle, "aliased_label";
                of(path = file_of("aliased again $uid\n"),
                   release_version = "2.2", licence = "CC0-1.0")...)
    DataPipeline.finalise(handle)
    label(name; keywords...) = DataPipeline.ConfigDataProduct(name; keywords...)
    first, second = of(), of(release_version = "2.2", licence = "CC0-1.0")

    for rehearsal in (false, true)
        # The label stands for the name and namespace its entry gives, which
        # the bare name in the default namespace is not; compared at the
        # entry's version, 0.0.1, though 0.0.2 is the highest
        asking = configured("0.0.1"; rehearsal)
        before, authors = counts(), deepcopy(asking.authors)
        @test DataPipeline.isregistered(asking, label("aliased_label"))
        @test !DataPipeline.isregistered(asking, aliased)
        @test DataPipeline.isregistered(asking, "$other:$aliased")
        @test DataPipeline.isregistered(asking, label("aliased_label");
                                        first...)
        @test !DataPipeline.isregistered(asking, label("aliased_label");
                                         second...)
        # A name a pattern covers, written or not
        @test DataPipeline.isregistered(asking, label(wild))
        @test DataPipeline.isregistered(asking, label(wild);
                                        of(title = "Wild $uid")...)
        @test !DataPipeline.isregistered(asking,
                                         label("sources/isregistered/wild/never"))
        # `read:` after `write:`: a label of its own, a name its pattern
        # covers, and a label in both blocks, taken as written
        @test DataPipeline.isregistered(asking, label("read_label"))
        @test DataPipeline.isregistered(asking, label(aliased))
        @test DataPipeline.isregistered(asking, label("both_label"))
        # A name holding the run's uuid is never registered
        @test !DataPipeline.isregistered(asking, label("run_label"))
        # Refused: a label no entry covers, or two patterns cover, a pattern,
        # and a component
        @test_throws DataPipeline.ConfigFileException DataPipeline.isregistered(asking,
                                                                                label("never_configured"))
        err = @test_throws DataPipeline.ConfigFileException DataPipeline.isregistered(asking,
                                                                                      label("sources/isregistered/two/x"))
        @test occursin("more than one wildcard in 'write'", err.value.msg)
        @test_throws ArgumentError DataPipeline.isregistered(asking,
                                                             label("sources/isregistered/wild/*"))
        @test_throws ArgumentError DataPipeline.isregistered(asking,
                                                             label("aliased_label",
                                                                   component = "part"))
        @test counts() == before
        @test asking.authors == authors
        rehearsal ? DataPipeline.discard(asking) : DataPipeline.finalise(asking)

        # At a version not registered, the highest
        asking = configured("0.0.3"; rehearsal)
        @test DataPipeline.isregistered(asking, label("aliased_label"))
        @test !DataPipeline.isregistered(asking, label("aliased_label");
                                         first...)
        @test DataPipeline.isregistered(asking, label("aliased_label");
                                        second...)
        rehearsal ? DataPipeline.discard(asking) : DataPipeline.finalise(asking)
    end

    # A name holding the run's uuid is that run's, registered once it ends
    asking = configured("0.0.1")
    write(link_write!(asking, "run_label"),
          "written under the run's uuid $uid\n")
    @test !DataPipeline.isregistered(asking, label("run_label"))
    DataPipeline.finalise(asking)
    @test DataPipeline.isregistered(asking, label("run_label"))
end

end
