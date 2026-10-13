# SPDX-License-Identifier: LGPL-3.0-or-later

module TestCitations

using DataPipeline
using Dates
using Test

# In test/citations: examples.bib, written for these tests, and what
# https://doi.org returned as BibTeX for four DOIs on 2026-10-12, kept as it
# came:
#   era5-monthly.bib    10.24381/cds.f17050d7      (DataCite)
#   modis-mod13c1.bib   10.5067/MODIS/MOD13C1.061  (DataCite)
#   pydatapipeline.bib  10.5281/zenodo.5562602     (DataCite)
#   worldclim2.bib      10.1002/joc.5086           (Crossref)
saved(name) = joinpath(@__DIR__, "citations", name)
const LOOKED_UP = ("era5-monthly.bib" => "10.24381/cds.f17050d7",
                   "modis-mod13c1.bib" => "10.5067/MODIS/MOD13C1.061",
                   "pydatapipeline.bib" => "10.5281/zenodo.5562602",
                   "worldclim2.bib" => "10.1002/joc.5086")

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

Test.@testset "what doi.org returns" begin
    handle = new_handle()
    keys = register_citations!(handle, saved.(first.(LOOKED_UP))...)
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

    # Crossref writes the entry on one line, the month as a bare `May`
    @test worldclim.identifier == "https://doi.org/10.1002/joc.5086"
    @test startswith(worldclim.title, "WorldClim 2: new 1")
    @test worldclim.authors == ["Stephen E. Fick", "Robert J. Hijmans"]
    @test worldclim.release_date == DateTime(2017, 5)
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
    asked = String[]
    function era5(url)
        push!(asked, url)
        return read(saved("era5-monthly.bib"), String)
    end

    # The DOI's own URL is asked, in lower case, and what it returns is read;
    # a reply naming the same DOI in another case is warned of no more than
    # one naming it exactly
    citation = @test_logs DataPipeline._doicitation(handle,
                                                    "doi:10.24381/CDS.F17050D7",
                                                    fetch = era5)
    @test asked == ["https://doi.org/10.24381/cds.f17050d7"]
    @test citation.identifier == "https://doi.org/10.24381/cds.f17050d7"
    @test citation.authors == ["Copernicus Climate Change Service"]
    # ... once in a code run, however the DOI is written, and apart from the
    # citations that were registered
    @test DataPipeline._doicitation(handle, asked[1], fetch = era5) ===
          citation
    @test length(asked) == 1
    @test isempty(handle.citations)

    # The identifier is the DOI asked for, whatever the citation returned
    # says; one that names another DOI is warned of, with both
    worldclim(url) = read(saved("worldclim2.bib"), String)
    both = r"10\.1234/another names another DOI, https://doi\.org/10\.1002/joc\.5086"
    other = @test_logs (:warn, both) DataPipeline._doicitation(handle,
                                                               "10.1234/Another",
                                                               fetch = worldclim)
    @test other.identifier == "https://doi.org/10.1234/another"
    @test other.authors == ["Stephen E. Fick", "Robert J. Hijmans"]
    # ... and one that names a page only, or nothing, is not
    page = "@misc{k, title = {T}, url = {https://example.org/landing}}"
    for (doi, reply) in ("10.1234/page" => page,
        "10.1234/bare" => "@misc{k, title = {T}}")
        unnamed = @test_logs DataPipeline._doicitation(handle, doi,
                                                       fetch = url -> reply)
        @test unnamed.identifier == "https://doi.org/$doi"
    end

    # A lookup that fails is not remembered; one entry must come back
    @test_throws ErrorException DataPipeline._doicitation(handle,
                                                          "10.1234/failing",
                                                          fetch = url -> error("no network"))
    @test_throws ArgumentError DataPipeline._doicitation(handle,
                                                         "10.1234/nothing",
                                                         fetch = url -> "<html></html>")
    @test_throws DataPipeline.ReadWriteException DataPipeline._doicitation(handle,
                                                                           "10.1234/several",
                                                                           fetch = url -> read(saved("examples.bib"),
                                                                                               String))
    @test_throws ArgumentError DataPipeline._doicitation(handle, "not a DOI",
                                                         fetch = era5)
    @test length(handle.doi_lookups) == 4
    @test length(asked) == 1

    # Asking a URL that has no citation to give, and one that cannot be
    # reached, both say that BibTeX can be given instead
    for url in (handle.registry.url * "no-such-table/",
        "http://127.0.0.1:1/10.1234/unreachable")
        msg = message_of(DataPipeline.ReadWriteException) do
            return DataPipeline._fetchbibtex(url)
        end
        @test occursin(url, msg) && occursin("as BibTeX", msg)
    end
end

Test.@testset "a DOI whose citation is registered" begin
    handle = new_handle()
    asked = String[]
    function era5(url)
        push!(asked, url)
        return read(saved("era5-monthly.bib"), String)
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
        for (file, doi) in LOOKED_UP
            live = DataPipeline._citation(handle, doi, nothing)
            kept = only(DataPipeline._parsecitations(read(saved(file), String),
                                                     file))
            @test live.identifier == DataPipeline._doiurl(doi)
            @test live.title == kept.title
            @test live.authors == kept.authors
            @test live.release_date == kept.release_date
        end
        @test length(handle.doi_lookups) == length(LOOKED_UP)
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
           authors = ["An Example Organisation"])
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
           primary = false, authors = ["An Example Organisation"])
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
end

end
