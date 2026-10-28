# SPDX-License-Identifier: LGPL-3.0-or-later

module TestCitations

using DataPipeline
using Dates
using Test

# In test/citations: examples.bib, written for these tests, and what
# https://doi.org returned for five DOIs, kept as it came - as BibTeX on
# 2026-10-12 (the .bib files), and as DataCite's record or, for the Crossref
# DOI, CSL on 2026-10-14 (the .json files):
#   era5-monthly      10.24381/cds.f17050d7                         (DataCite)
#   modis-mod13c1     10.5067/MODIS/MOD13C1.061                     (DataCite)
#   pydatapipeline    10.5281/zenodo.5562602                        (DataCite)
#   eidc-envelopes    10.5285/ca339c86-3674-4030-b891-35326e71141e  (DataCite)
#   worldclim2        10.1002/joc.5086                              (Crossref)
saved(name) = joinpath(@__DIR__, "citations", name)
const LOOKED_UP = ("era5-monthly.bib" => "10.24381/cds.f17050d7",
                   "modis-mod13c1.bib" => "10.5067/MODIS/MOD13C1.061",
                   "pydatapipeline.bib" => "10.5281/zenodo.5562602",
                   "worldclim2.bib" => "10.1002/joc.5086")
const DATACITE = "application/vnd.datacite.datacite+json"
const CSL = "application/vnd.citationstyles.csl+json"
const METADATA = ("era5-monthly.datacite.json" => "10.24381/cds.f17050d7",
                  "modis-mod13c1.datacite.json" => "10.5067/MODIS/MOD13C1.061",
                  "pydatapipeline.datacite.json" => "10.5281/zenodo.5562602",
                  "eidc-envelopes.datacite.json" => "10.5285/ca339c86-3674-4030-b891-35326e71141e",
                  "worldclim2.csl.json" => "10.1002/joc.5086")

# What a saved reply of DataCite's or CSL says, read as a DOI's lookup reads it
function read_saved(file, doi)
    reader = endswith(file, ".csl.json") ? DataPipeline._cslcitation :
             DataPipeline._datacitecitation
    return reader(DataPipeline.JSON.parse(read(saved(file), String)),
                  DataPipeline._doiurl(doi))
end

cpath = joinpath("coderun", Dates.format(Dates.now(), "yyyymmdd-HHMMSS"),
                 "citations.yaml")

# A handle for a new code run with nothing read, written or cited
function new_handle()
    config = DataPipeline._createconfig(cpath)
    return DataPipeline.initialise(config, config)
end

# The message of the error a call throws, which must be of the given type
function message_of(call::Function, type::Type{<:Exception} = ArgumentError)
    try
        call()
    catch e
        e isa type || rethrow()
        return e.msg
    end
    return error("nothing was thrown")
end

Test.@testset "a DOI in one form" begin
    url = "https://doi.org/10.24381/cds.f17050d7"
    for doi in ("10.24381/cds.f17050d7", "10.24381/CDS.F17050D7",
        "doi:10.24381/cds.f17050d7", "https://doi.org/10.24381/CDS.F17050D7",
        "http://dx.doi.org/10.24381/cds.f17050d7", "  10.24381/cds.f17050d7 ")
        @test DataPipeline._doiurl(doi) == url
    end
    for not_a_doi in ("", "cds.f17050d7", "10.24381",
        "https://example.org/10.24381/cds.f17050d7")
        @test_throws ArgumentError DataPipeline._doiurl(not_a_doi)
    end
end

Test.@testset "BibTeX as doi.org gives it" begin
    handle = new_handle()
    # Zenodo's licence is its name in the SPDX list, read with nothing said
    keys = @test_logs register_citations!(handle,
                                          saved.(first.(LOOKED_UP))...)
    @test keys == ["https://doi.org/10.24381/cds.f17050d7",
        "https://doi.org/10.5067/modis/mod13c1.061",
        "https://doi.org/10.5281/zenodo.5562602", "Fick_2017"]
    era5, modis, zenodo, worldclim = (handle.citations[key] for key in keys)

    # DataCite writes the DOI in upper case and an organisation in braces
    @test era5.identifier == "https://doi.org/10.24381/cds.f17050d7"
    @test era5.title ==
          "ERA5 monthly averaged data on single levels from 1940 to present"
    @test era5.authors == ["Copernicus Climate Change Service"]
    @test era5.release_date == DateTime(2019)
    @test isnothing(era5.release_version) && isnothing(era5.description)
    @test modis.identifier == "https://doi.org/10.5067/modis/mod13c1.061"
    @test modis.authors == ["Kamel Didan"]
    @test zenodo.authors == ["Ryan Field", "Dennis Reddyhoff"]
    @test isempty(zenodo.identifiers)
    # ... a name that the list's deprecated GPL-3.0+ shares with the licence
    # replacing it, which is the one recorded
    @test zenodo.licence == "GPL-3.0-or-later"

    # Crossref writes the entry on one line, the month as a bare `May`
    @test worldclim.identifier == "https://doi.org/10.1002/joc.5086"
    @test startswith(worldclim.title, "WorldClim 2: new 1")
    @test worldclim.authors == ["Stephen E. Fick", "Robert J. Hijmans"]
    @test worldclim.release_date == DateTime(2017, 5)
end

Test.@testset "a licence in BibTeX" begin
    handle = new_handle()
    entries = """
              @misc{spdx, title = {S}, License = {cc-by-4.0}, copyright = {Words}}
              @misc{address, title = {A}, copyright = {https://example.org/terms}}
              @misc{words, title = {W}, copyright = {All rights reserved}}
              @misc{none, title = {N}}
              """
    # An SPDX identifier, as the list writes it, before a copyright; a URL;
    # and words, which are warned of and are no licence
    words = (:warn, r"'words' gives its licence as 'All rights reserved'")
    @test_logs words register_citations!(handle, entries)
    @test [handle.citations[key].licence
           for key in ("spdx", "address", "words", "none")] ==
          ["CC-BY-4.0", "https://example.org/terms", nothing, nothing]
end

Test.@testset "what a DOI's metadata gives" begin
    era5, modis, zenodo, eidc, worldclim = (read_saved(file, doi)
                                            for (file, doi) in METADATA)

    # ERA5 and MODIS: a title, a creator and a year, and nothing else
    @test era5.identifier == "https://doi.org/10.24381/cds.f17050d7"
    @test era5.title ==
          "ERA5 monthly averaged data on single levels from 1940 to present"
    @test era5.authors == ["Copernicus Climate Change Service"]
    @test era5.release_date == DateTime(2019)
    @test all(isnothing,
              (era5.release_version, era5.description, era5.licence))
    @test isempty(era5.identifiers)
    # ... a person's name being given name then family name, its spaces
    # tidied
    @test modis.authors == ["Kamel Didan"]
    @test modis.release_date == DateTime(2021)

    # EIDC: a Submitted date, the abstract and not the methods, the licence
    # by its SPDX identifier as the list writes it, and an ORCID for three of
    # the four creators
    @test eidc.authors ==
          ["C. Harris", "N. Brummitt", "C.A. Cobbold", "R. Reeve"]
    @test eidc.release_date == DateTime(2022, 6, 22)
    @test startswith(eidc.description, "Bioclimatic envelopes for over")
    @test !occursin("were extracted", eidc.description)
    @test eidc.licence == "OGL-UK-3.0"
    @test eidc.identifiers ==
          Dict("C. Harris" => "https://orcid.org/0000-0003-0852-2340",
               "C.A. Cobbold" => "https://orcid.org/0000-0001-8814-7688",
               "R. Reeve" => "https://orcid.org/0000-0003-2589-8091")

    # Zenodo: a version, a full date, and the SPDX right, not "Open Access",
    # its deprecated GPL-3.0+ recorded as the licence replacing it, as the
    # BibTeX of the same DOI gives it by name
    @test zenodo.release_version == "v0.2.0"
    @test zenodo.release_date == DateTime(2021, 10, 11)
    @test zenodo.licence == "GPL-3.0-or-later"
    @test zenodo.licence ==
          only(DataPipeline._readcitations(saved("pydatapipeline.bib"))).licence
    @test zenodo.description ==
          "Package for interfacing with the FAIR Data Pipeline in Python"
    @test length(zenodo.identifiers) == 2

    # Crossref's CSL: the date in full, the abstract without its markup or
    # heading, an ORCID, and no licence, which is the article's
    @test worldclim.authors == ["Stephen E. Fick", "Robert J. Hijmans"]
    @test worldclim.release_date == DateTime(2017, 5, 15)
    @test startswith(worldclim.description, "We created a new dataset")
    @test !occursin('<', worldclim.description)
    @test isnothing(worldclim.licence)
    @test worldclim.identifiers ==
          Dict("Stephen E. Fick" => "https://orcid.org/0000-0002-3548-6966")

    # The rules, on records written for them: the date of the first kind
    # that says when, the start of a range; a main title before others; a
    # person's name turned round; identifiers made whole, of ORCID and ROR
    # only; an SPDX identifier the list has not got giving way to an address
    # that is a web page; and the abstract, whichever comes first, its HTML
    # taken out
    record = Dict("doi" => "10.5555/RULES",
                  "titles" => [Dict("title" => "A subtitle",
                        "titleType" => "Subtitle"),
                      Dict("title" => "  The   main title ")],
                  "creators" => [
                      Dict("name" => "Person, Ada",
                           "nameType" => "Personal",
                           "nameIdentifiers" =>
                               [Dict("nameIdentifier" => "0000-0001",
                                     "nameIdentifierScheme" => "ORCID",
                                     "schemeUri" => "http://orcid.org/")]),
                      Dict("name" => "An Institute, Somewhere",
                           "nameIdentifiers" => [
                               Dict("nameIdentifier" => "https://isni.org/1",
                                    "nameIdentifierScheme" => "ISNI"),
                               Dict("nameIdentifier" => "05abc",
                                    "nameIdentifierScheme" => "ROR")])],
                  "dates" =>
                      [Dict("date" => "2020-01-02", "dateType" => "Submitted"),
                          Dict("date" => "2019-05/2019-06",
                               "dateType" => "Created"),
                          Dict("date" => "2018", "dateType" => "Updated")],
                  "publicationYear" => 2021,
                  "descriptions" =>
                      [
                          Dict("description" => "How it was made",
                               "descriptionType" => "Methods"),
                          Dict("description" => "<p>Values &lt; 5 &amp; more</p>",
                               "descriptionType" => "Abstract")],
                  "rightsList" => [
                      Dict("rightsIdentifier" => "not-yet-listed-1.0",
                           "rightsIdentifierScheme" => "SPDX",
                           "rightsUri" => "info:eu-repo/x"),
                      Dict("rightsUri" => "https://example.org/terms")])
    rules = DataPipeline._datacitecitation(record,
                                           "https://doi.org/10.5555/rules")
    @test rules.identifier == "https://doi.org/10.5555/rules"
    @test rules.title == "The main title"
    @test rules.authors == ["Ada Person", "An Institute, Somewhere"]
    @test rules.identifiers ==
          Dict("Ada Person" => "https://orcid.org/0000-0001",
               "An Institute, Somewhere" => "https://ror.org/05abc")
    @test rules.release_date == DateTime(2019, 5)
    @test rules.description == "Values < 5 & more"
    @test rules.licence == "https://example.org/terms"
    # ... an Issued date before any other, a year where there is none, and
    # nothing at all
    issued = merge(record,
                   Dict("dates" => [
                            Dict("date" => "2020-01-02",
                                 "dateType" => "Submitted"),
                            Dict("date" => "2022", "dateType" => "Issued")]))
    @test DataPipeline._datacitecitation(issued, "k").release_date ==
          DateTime(2022)
    @test DataPipeline._datacitecitation(merge(record,
                                               Dict("dates" => nothing)),
                                         "k").release_date == DateTime(2021)
    empty = DataPipeline._datacitecitation(Dict{String, Any}(), "k")
    @test all(isnothing,
              (empty.identifier, empty.title, empty.release_date,
               empty.description, empty.licence))
    @test isempty(empty.authors)
    # ... and CSL: a title in a list, an author by name alone, a year only
    csl = Dict("title" => ["Listed"], "DOI" => "10.5555/CSL",
               "author" => [Dict("literal" => "An Organisation"),
                   Dict("given" => "Ada", "family" => "Person",
                        "ORCID" => "http://orcid.org/0000-0002")],
               "issued" => Dict("date-parts" => [[2018]]))
    listed = DataPipeline._cslcitation(csl, "k")
    @test listed.title == "Listed"
    @test listed.identifier == "https://doi.org/10.5555/csl"
    @test listed.authors == ["An Organisation", "Ada Person"]
    @test listed.identifiers ==
          Dict("Ada Person" => "https://orcid.org/0000-0002")
    @test listed.release_date == DateTime(2018)
end

Test.@testset "the fields of a citation" begin
    handle = new_handle()
    @test register_citations!(handle, saved("examples.bib")) ==
          ["example_dataset", "example_article", "example_page",
        "example_unaddressed"]

    # Braces and spare spaces go; year, month and day make the date
    dataset = handle.citations["example_dataset"]
    @test dataset.key == "example_dataset"
    @test dataset.identifier == "https://doi.org/10.1234/example.dataset"
    @test dataset.title == "An Example dataset, with spaces"
    @test dataset.authors == ["An Example Organisation"]
    @test dataset.release_date == DateTime(2019, 4, 18)
    @test dataset.release_version == "2.1"
    @test dataset.description == "The note of the example dataset"

    # A url that is a DOI's is the DOI; a date field is read as it stands;
    # a person is given names, then particle, family name and suffix
    article = handle.citations["example_article"]
    @test article.identifier == "https://doi.org/10.1234/example.article"
    @test article.authors ==
          ["Given M. Surname", "Anna van der Example", "John Sample Jr."]
    @test article.release_date == DateTime(2017, 5, 15)
    @test isnothing(article.release_version) && isnothing(article.description)

    # Any other url identifies as written; an impossible month is passed over
    page = handle.citations["example_page"]
    @test page.identifier == "https://example.org/data/page"
    @test isempty(page.authors)
    @test page.release_date == DateTime(2020)

    unaddressed = handle.citations["example_unaddressed"]
    @test isnothing(unaddressed.identifier)
    @test isnothing(unaddressed.release_date)
end

Test.@testset "register_citations!()" begin
    handle = new_handle()
    one = "@misc{one, title = {One}, url = {https://example.org/one}}"
    more = "  \n@misc{two, title = {Two}}\n@misc{three, title = {Three}}"
    @test register_citations!(handle) == String[]
    @test isempty(handle.citations)
    @test register_citations!(handle, one, more) == ["one", "two", "three"]
    @test sort!(collect(keys(handle.citations))) == ["one", "three", "two"]

    # Text and files together; an entry read again is the same entry
    again = register_citations!(handle, one, saved("examples.bib"), one)
    @test length(again) == 6 && again[1] == again[end] == "one"
    @test length(handle.citations) == 7
    @test isempty(handle.doi_lookups)

    # A different entry under a key that is taken is refused, and the call
    # that brought it keeps nothing
    other = "@misc{one, title = {Another}, url = {https://example.org/one}}"
    msg = message_of() do
        return register_citations!(handle, "@misc{four, title = {Four}}", other)
    end
    @test occursin("'one'", msg)
    @test handle.citations["one"].title == "One"
    @test !haskey(handle.citations, "four")

    # Within one text a key may be repeated only with the same fields
    @test register_citations!(handle,
                              "@misc{five, title = {5}}\n@misc{five, Title = {5}}") ==
          ["five"]
    msg = message_of() do
        return register_citations!(handle,
                                   "@misc{six, title = {6}}\n@misc{six, title = {VI}}")
    end
    @test occursin("'six'", msg) && occursin("the BibTeX text", msg)
    @test !haskey(handle.citations, "six")

    # An abbreviation defined in the text, its value in quotes, is written out
    defined = """
              @string{org = "An Example Organisation"}
              @misc{by_org, title = {T}, author = org}
              """
    @test register_citations!(handle, defined) == ["by_org"]
    @test handle.citations["by_org"].authors == ["An Example Organisation"]

    # What cannot be read says what it was taken for: a path with no file,
    # which is what text not starting with @ is; text with no whole entry;
    # and a file using an abbreviation it does not define
    absent = joinpath(mktempdir(), "absent.bib")
    @test occursin("no BibTeX file at '$absent'",
                   message_of() do
                       return register_citations!(handle, absent)
                   end)
    @test occursin("no BibTeX file at '% a comment",
                   message_of() do
                       return register_citations!(handle,
                                                  "% a comment\n" * one)
                   end)
    @test occursin("from the BibTeX text",
                   message_of() do
                       return register_citations!(handle,
                                                  "@misc{broken, title = {Broken}")
                   end)
    abbreviated = joinpath(mktempdir(), "abbreviated.bib")
    write(abbreviated, "@misc{short, title = {T}, publisher = unknown}")
    msg = message_of() do
        return register_citations!(handle, abbreviated)
    end
    @test occursin("\"unknown\"", msg) && occursin(abbreviated, msg)
    @test length(handle.citations) == 9
end

Test.@testset "the citation a source is named by" begin
    handle = new_handle()
    register_citations!(handle, saved("examples.bib"))
    @test DataPipeline._citation(handle, nothing, "example_page") ===
          handle.citations["example_page"]

    # A key that is not registered is reported with those that are
    msg = message_of() do
        return DataPipeline._citation(handle, nothing, "example_pages")
    end
    @test occursin("'example_pages'", msg) && occursin("example_page,", msg)
    @test occursin("registered: none",
                   message_of() do
                       return DataPipeline._citation(new_handle(), nothing,
                                                     "example_page")
                   end)

    # One of a key and a DOI, not neither and not both
    @test_throws ArgumentError DataPipeline._citation(handle, nothing, nothing)
    @test_throws ArgumentError DataPipeline._citation(handle, "10.1234/x",
                                                      "example_page")
end

Test.@testset "a citation looked up from its DOI" begin
    handle = new_handle()
    asked = Tuple{String, String}[]
    # A DOI's URL asked for metadata of a type, which has only the saved
    # replies to give, each in its own type
    function replies(saved_files...)
        return function (url, type)
            push!(asked, (url, type))
            for file in saved_files
                (type == CSL) == endswith(file, ".csl.json") &&
                    return read(saved(file), String)
            end
            return nothing
        end
    end
    era5 = replies("era5-monthly.datacite.json")

    # The DOI's own URL is asked, in lower case, for DataCite's record; a
    # record naming the same DOI in another case is warned of no more than
    # one naming it exactly
    citation = @test_logs DataPipeline._doicitation(handle,
                                                    "doi:10.24381/CDS.F17050D7",
                                                    fetch = era5)
    @test asked == [("https://doi.org/10.24381/cds.f17050d7", DATACITE)]
    @test citation.identifier == "https://doi.org/10.24381/cds.f17050d7"
    @test citation.authors == ["Copernicus Climate Change Service"]
    # ... once in a code run, however the DOI is written, and apart from the
    # citations that were registered
    @test DataPipeline._doicitation(handle, asked[1][1], fetch = era5) ===
          citation
    @test length(asked) == 1
    @test isempty(handle.citations)

    # A DOI that is not DataCite's is asked for its CSL record
    worldclim = DataPipeline._doicitation(handle, "10.1002/joc.5086",
                                          fetch = replies("worldclim2.csl.json"))
    @test asked[2:3] == [("https://doi.org/10.1002/joc.5086", DATACITE),
        ("https://doi.org/10.1002/joc.5086", CSL)]
    @test worldclim.authors == ["Stephen E. Fick", "Robert J. Hijmans"]
    @test worldclim.release_date == DateTime(2017, 5, 15)

    # The identifier is the DOI asked for, whatever the record says; one
    # naming another DOI is warned of, with both
    both = r"10\.1234/another names another DOI, https://doi\.org/10\.24381/cds\.f17050d7"
    other = @test_logs (:warn, both) DataPipeline._doicitation(handle,
                                                               "10.1234/Another",
                                                               fetch = era5)
    @test other.identifier == "https://doi.org/10.1234/another"
    @test other.title == citation.title
    # ... and one that names no DOI is not
    bare = @test_logs DataPipeline._doicitation(handle, "10.1234/bare",
                                                fetch = (url, type) -> "{}")
    @test bare.identifier == "https://doi.org/10.1234/bare"

    # A lookup that fails is not remembered: no metadata of either type, a
    # fetch that fails, and what is not a DOI
    msg = message_of(DataPipeline.ReadWriteException) do
        return DataPipeline._doicitation(handle, "10.1234/nothing",
                                         fetch = (url, type) -> nothing)
    end
    @test occursin("10.1234/nothing", msg) && occursin("as BibTeX", msg)
    @test_throws ErrorException DataPipeline._doicitation(handle,
                                                          "10.1234/failing",
                                                          fetch = (url,
                                                                   type) -> error("no network"))
    @test_throws ArgumentError DataPipeline._doicitation(handle, "not a DOI",
                                                         fetch = era5)
    @test length(handle.doi_lookups) == 4

    # Asked of a server: what it has not got, and one that cannot be
    # reached, both say that BibTeX can be given instead; a 406, and a page
    # that is not JSON, are metadata it does not have in that type
    for url in (handle.registry.url * "no-such-table/",
        "http://127.0.0.1:1/10.1234/unreachable")
        msg = message_of(DataPipeline.ReadWriteException) do
            return DataPipeline._fetchmetadata(url, DATACITE)
        end
        @test occursin(url, msg) && occursin("as BibTeX", msg)
    end
    @test isnothing(DataPipeline._fetchmetadata(handle.registry.url, DATACITE))
    @test isnothing(DataPipeline._fetchmetadata(replace(handle.registry.url,
                                                        "api/" => ""), CSL))
    @test !isnothing(DataPipeline._fetchmetadata(handle.registry.url,
                                                 "application/json"))
end

Test.@testset "a DOI whose citation is registered" begin
    handle = new_handle()
    asked = String[]
    function era5(url, type)
        push!(asked, url)
        return read(saved("era5-monthly.datacite.json"), String)
    end
    register_citations!(handle, saved("examples.bib"))

    # The registered citation of a DOI is the one, however the DOI is
    # written and whether the entry gave it as a doi or as its url; nothing
    # is asked of doi.org
    @test DataPipeline._doicitation(handle, "doi:10.1234/EXAMPLE.dataset",
                                    fetch = era5) ===
          handle.citations["example_dataset"]
    @test DataPipeline._citation(handle, "10.1234/example.article", nothing) ===
          handle.citations["example_article"]
    @test isempty(asked) && isempty(handle.doi_lookups)
    # A DOI with none registered is looked up
    DataPipeline._doicitation(handle, "10.24381/cds.f17050d7", fetch = era5)
    @test length(asked) == 1

    # A second citation of the DOI that says the same of it changes nothing
    register_citations!(handle,
                        """
                        @misc{another_key,
                          author = {{An Example Organisation}},
                          title = {An Example dataset, with spaces},
                          year = 2019, month = 4, day = 18, version = {2.1},
                          url = {https://doi.org/10.1234/example.dataset},
                          note = {The note of the example dataset}}
                        """)
    same = DataPipeline._doicitation(handle, "10.1234/example.dataset",
                                     fetch = era5)
    @test DataPipeline._samesource(same, handle.citations["example_dataset"])
    # ... but one that says something else leaves the choice to the caller,
    # who is told the keys and can still name any of them
    register_citations!(handle,
                        "@misc{third_key, title = {Something else}, year = 2019, doi = {10.1234/example.dataset}}")
    msg = message_of() do
        return DataPipeline._doicitation(handle, "10.1234/example.dataset",
                                         fetch = era5)
    end
    @test occursin("another_key, example_dataset, third_key", msg)
    @test occursin("https://doi.org/10.1234/example.dataset", msg)
    @test DataPipeline._citation(handle, nothing, "third_key").title ==
          "Something else"
    @test length(asked) == 1
end

# The live lookup needs a network and the DOIs' registration agencies, so it
# runs only when asked for
if get(ENV, "FDP_TEST_DOI_LOOKUP", "") == "true"
    Test.@testset "doi.org itself" begin
        handle = new_handle()
        for (file, doi) in METADATA
            live = DataPipeline._citation(handle, doi, nothing)
            kept = read_saved(file, doi)
            @test live.identifier == DataPipeline._doiurl(doi)
            for field in (:title, :authors, :release_date, :release_version,
                :description, :licence, :identifiers)
                @test getfield(live, field) == getfield(kept, field)
            end
        end
        @test length(handle.doi_lookups) == length(METADATA)
    end
end

Test.@testset "the facts of a source" begin
    handle = new_handle()
    register_citations!(handle, saved("examples.bib"),
                        saved("era5-monthly.bib"))
    dataset = handle.citations["example_dataset"]
    era5 = handle.citations["https://doi.org/10.24381/cds.f17050d7"]

    # From the citation alone, the version written in full
    @test DataPipeline._sourcefacts(dataset, primary = true) ==
          (identifier = "https://doi.org/10.1234/example.dataset",
           title = "An Example dataset, with spaces", version = "2.1.0",
           release_date = DateTime(2019, 4, 18),
           description = "The note of the example dataset", primary = true,
           authors = ["An Example Organisation"], licence = nothing,
           identifiers = Dict{String, String}())
    # With no version or note in it: the registry's default, and none
    facts = DataPipeline._sourcefacts(era5, primary = false)
    @test facts.version == "1.0.0"
    @test isnothing(facts.description)
    @test !facts.primary

    # What the caller says takes the place of what the citation says
    facts = DataPipeline._sourcefacts(dataset, primary = false,
                                      title = "One file of it",
                                      description = "The request",
                                      release_date = Date(2024, 2, 29),
                                      release_version = v"3")
    @test facts ==
          (identifier = "https://doi.org/10.1234/example.dataset",
           title = "One file of it", version = "3.0.0",
           release_date = DateTime(2024, 2, 29), description = "The request",
           primary = false, authors = ["An Example Organisation"],
           licence = nothing, identifiers = Dict{String, String}())
    # ... and the licence and the authors' identifiers are the citation's
    eidc = read_saved(METADATA[4]...)
    facts = DataPipeline._sourcefacts(eidc, primary = true)
    @test facts.licence == "OGL-UK-3.0" && facts.identifiers == eidc.identifiers
    for (given, taken) in ("2021" => DateTime(2021),
        "2021-06" => DateTime(2021, 6), "2021-06-30" => DateTime(2021, 6, 30),
        DateTime(2021, 6, 30, 12) => DateTime(2021, 6, 30, 12))
        @test DataPipeline._sourcefacts(era5, primary = true,
                                        release_date = given).release_date ==
              taken
    end
    @test_throws ArgumentError DataPipeline._sourcefacts(era5, primary = true,
                                                         release_date = "June 2021")
    @test_throws ArgumentError DataPipeline._sourcefacts(era5, primary = true,
                                                         release_date = "2021-13")
    # A version is written in full, but not altered: a leading zero, which
    # reading it would drop, is refused, as is what is no version at all
    for (given, taken) in ("3" => "3.0.0", "v2.1" => "2.1.0", "0.1" => "0.1.0",
        "10.0.1" => "10.0.1", "2019" => "2019.0.0",
        "1.0.0-beta" => "1.0.0-beta")
        @test DataPipeline._sourcefacts(era5, primary = true,
                                        release_version = given).version ==
              taken
    end
    for refused in ("061", "V061", "1.01", "2.1.00", "1.0.0-01", "the latest",
        "")
        @test_throws ArgumentError DataPipeline._sourcefacts(era5,
                                                             primary = true,
                                                             release_version = refused)
    end

    # What a citation lacks the caller must give, and is told which keyword
    register_citations!(handle,
                        """
                        @misc{undated, title = {No date}, url = {https://example.org/u}}
                        @misc{untitled, year = 2020, url = {https://example.org/u}}
                        @misc{misversioned, title = {V}, year = 2020, version = {Collection 6},
                              url = {https://example.org/u}}
                        @misc{zeroed, title = {Z}, year = 2020, version = {061},
                              url = {https://example.org/u}}
                        """)
    lacking = (("undated", "release_date", (release_date = "2020",)),
               ("untitled", "title", (title = "A title",)),
               ("misversioned", "release_version", (release_version = "6.1",)),
               ("zeroed", "release_version", (release_version = "6.1",)))
    for (key, keyword, given) in lacking
        citation = handle.citations[key]
        msg = message_of() do
            return DataPipeline._sourcefacts(citation, primary = true)
        end
        @test occursin("`$keyword`", msg)
        facts = DataPipeline._sourcefacts(citation; primary = true, given...)
        @test facts.identifier == "https://example.org/u"
    end
    # ... but nothing the caller says stands in for an identifier
    msg = message_of() do
        return DataPipeline._sourcefacts(handle.citations["example_unaddressed"],
                                         primary = true)
    end
    @test occursin("example_unaddressed", msg) && occursin("doi", msg)

    # What the registry would refuse, refused before anything is registered: a
    # blank title, one too long, and an identifier that is no URL with a host
    for blank in ("", " ")
        msg = message_of() do
            return DataPipeline._sourcefacts(dataset, primary = true,
                                             title = blank)
        end
        @test occursin("blank", msg) && occursin("`title`", msg)
    end
    # ... a title stripped of the white space around it, as the registry
    # stores it, before its length is counted
    @test DataPipeline._sourcefacts(dataset, primary = true,
                                    title = "  One file of it\n").title ==
          "One file of it"
    longest = "t"^DataPipeline.SOURCE_TITLE_LENGTH
    @test DataPipeline._sourcefacts(dataset, primary = true,
                                    title = " $longest ").title == longest
    @test DataPipeline._sourcefacts(dataset, primary = true,
                                    title = longest).title == longest
    msg = message_of() do
        return DataPipeline._sourcefacts(dataset, primary = true,
                                         title = longest * "t")
    end
    @test occursin("characters", msg) && occursin("`title`", msg)
    register_citations!(handle,
                        """
                        @misc{hostless, title = {H}, year = 2020, url = {example.org/h}}
                        @misc{spaced, title = {S}, year = 2020, url = {https://example.org/a b}}
                        @misc{ftp, title = {F}, year = 2020, url = {ftp://example.org/f}}
                        """)
    for key in ("hostless", "spaced")
        msg = message_of() do
            return DataPipeline._sourcefacts(handle.citations[key],
                                             primary = true)
        end
        @test occursin(key, msg) && occursin("refuses", msg)
    end
    @test DataPipeline._sourcefacts(handle.citations["ftp"],
                                    primary = true).identifier ==
          "ftp://example.org/f"
end

end
