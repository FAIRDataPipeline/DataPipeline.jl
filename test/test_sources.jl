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
    path = joinpath(outside, "$(DataPipeline._randomhash()).txt")
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
    # A licence that is neither an identifier in the SPDX list nor a URL;
    # and one given under both spellings of the keyword
    for words in (" ", "Creative Commons Attribution 4.0", "CC-BY-4")
        @test occursin("not an identifier in the SPDX licence list",
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

Test.@testset "a registry that keeps sources as rows of their own" begin
    # This registry is one; one before v1.4.0 is refused with an error saying
    # so, which no registry these tests run against can show
    @test isnothing(DataPipeline._checksourcerows(registry))
end

Test.@testset "a licence" begin
    cc0 = (info = "CC0-1.0", identifier = spdx * "CC0-1.0")
    # One in the SPDX list is known by its identifier there, in any case or
    # as the address of its page, and is identified by that page
    for written in ("CC0-1.0", "cc0-1.0", spdx * "CC0-1.0",
        spdx * "CC0-1.0.html", "http://spdx.org/licenses/cc0-1.0")
        @test DataPipeline._licence(written) == cc0
    end
    # ... one that the list has deprecated included
    @test DataPipeline._licence("GPL-3.0").info == "GPL-3.0"
    # Any other is the URL of a licence, whether or not it is at spdx.org
    for url in (own_terms, spdx * "Not-Yet-In-The-Copy-1.0")
        @test DataPipeline._licence(url) == (info = url, identifier = url)
    end
    @test isnothing(DataPipeline._licence(nothing))
    @test_throws ArgumentError DataPipeline._licence("CC0")
    @test length(DataPipeline.SPDX_IDENTIFIERS) > 700

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
        # ends its lines
        copy = replace(read(DataPipeline.SPDX_LIST, String), "\r\n" => "\n")
        @test (DataPipeline._spdxlisttext(published) == copy) == true
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

Test.@testset "the version of a file with a source" begin
    name = "sources/versions/$uid"
    file, changed = file_of("first $uid\n"), file_of("second $uid\n")
    function of(; keywords...)
        return (; bibtex = "deposit", primary = true,
                title = "Versions $uid", keywords...)
    end

    handle = offering(name => "0.0.1")
    link_write!(handle, name; path = file, of()...)
    DataPipeline.finalise(handle)
    stored = handle.outputs[(name, nothing)]["path"]
    first_source = source_of(registered(name, "0.0.1"))["url"]

    # The same bytes of the same source, with the same authors and licence,
    # are not registered again, whatever version the config offers
    for offered in ("0.0.2", "0.0.1")
        handle = offering(name => offered)
        @test link_write!(handle, name; path = file_of("first $uid\n"),
                          of()...) == stored
        @test isempty(handle.outputs)
        DataPipeline.finalise(handle)
    end
    @test registered_versions(name) == ["0.0.1"]
    # ... nor with no source, a file with none being compared by its bytes
    handle = offering(name => "0.0.2")
    @test link_write!(handle, name, path = file) == stored
    @test isempty(handle.outputs)

    # Other bytes of the same source are an error: a source is one file
    @test_throws ReadWriteException link_write!(handle, name; path = changed,
                                                of()...)
    @test isempty(handle.outputs)
    # ... and of another release of it, the next version
    link_write!(handle, name; path = changed, of(release_version = "2.2")...)
    DataPipeline.finalise(handle)
    @test registered_versions(name) == ["0.0.1", "0.0.2"]
    second_source = source_of(registered(name, "0.0.2"))
    @test second_source["url"] != first_source
    @test second_source["version"] == "2.2.0"

    # The same bytes and source under another licence are the next version,
    # of the same source
    handle = offering(name => "0.0.3")
    link_write!(handle, name; path = changed,
                of(release_version = "2.2", licence = "CC0-1.0")...)
    DataPipeline.finalise(handle)
    @test registered_versions(name) == ["0.0.1", "0.0.2", "0.0.3"]
    @test source_of(registered(name, "0.0.3"))["url"] == second_source["url"]
    @test licences_of(object_of(registered(name, "0.0.3"))) ==
          [("CC0-1.0", spdx * "CC0-1.0")]
    # ... and so are they with other authors, the organisation now having an
    # identifier
    handle = offering(name => "0.0.4")
    register_authors!(handle, organisation => ror)
    link_write!(handle, name; path = changed,
                of(release_version = "2.2", licence = "CC0-1.0")...)
    DataPipeline.finalise(handle)
    @test registered_versions(name) == ["0.0.1", "0.0.2", "0.0.3", "0.0.4"]
    @test sort(object_of(registered(name, "0.0.4"))["authors"]) ==
          sort([author(orcid), author(ror)])
    # ... while what else is said of the source makes no version: the
    # registry keeps what it was first told
    handle = offering(name => "0.0.5")
    register_authors!(handle, organisation => ror)
    link_write!(handle, name; path = changed,
                of(release_version = "2.2", licence = "CC0-1.0",
                   primary = false,
                   description = "said later",
                   release_date = "2023")...)
    @test isempty(handle.outputs)
    # The same bytes of another release of the source are the next version
    link_write!(handle, name; path = changed,
                of(release_version = "2.3", licence = "CC0-1.0")...)
    DataPipeline.finalise(handle)
    @test last(registered_versions(name)) == "0.0.5"
    @test source_of(registered(name, "0.0.5"))["version"] == "2.3.0"

    # An author that a citation names twice is the file's author once, so
    # that the file is found unchanged
    twice = "sources/versions/twice/$uid"
    handle = offering(twice => "0.0.1")
    link_write!(handle, twice, path = file_of("twice $uid\n"),
                bibtex = "twice", primary = true)
    DataPipeline.finalise(handle)
    @test object_of(registered(twice, "0.0.1"))["authors"] ==
          [author_named(organisation)]
    handle = offering(twice => "0.0.2")
    link_write!(handle, twice, path = file_of("twice $uid\n"),
                bibtex = "twice", primary = true)
    @test isempty(handle.outputs)

    # A source for bytes that were registered with none is the next version
    bare = "sources/versions/bare/$uid"
    handle = offering(bare => "0.0.1")
    link_write!(handle, bare, path = file_of("bare $uid\n"))
    DataPipeline.finalise(handle)
    handle = offering(bare => "0.0.2")
    link_write!(handle, bare; path = file_of("bare $uid\n"),
                of(title = "Bare $uid")...)
    DataPipeline.finalise(handle)
    @test registered_versions(bare) == ["0.0.1", "0.0.2"]
    @test isnothing(registered(bare, "0.0.1")["external_object"])
    @test source_of(registered(bare, "0.0.2"))["title"] == "Bare $uid"

    # A file that is written after the call is found unchanged by `finalise`
    # in the same way: by its bytes and by what is said of its source
    later = "sources/versions/later/$uid"
    for (offered, licence, versions) in (("0.0.1", nothing, ["0.0.1"]),
        ("0.0.2", nothing, ["0.0.1"]),
        ("0.0.2", "CC0-1.0", ["0.0.1", "0.0.2"]))
        handle = offering(later => offered)
        written = link_write!(handle, later;
                              of(title = "Later $uid", licence = licence)...)
        write(written, "later $uid\n")
        DataPipeline.finalise(handle)
        @test registered_versions(later) == versions
        @test isempty(handle.unchanged) == (offered == "0.0.1" ||
               !isnothing(licence))
    end
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
    write_estimate(handle, 1.5, tabled, "an/estimate", "an estimate")
    DataPipeline.finalise(handle)
    @test source_of(registered(tabled, "0.0.1"))["title"] == "Tabled $uid"
    @test length(entry(handle.code_run_obj)["outputs"]) == 2
end

end
