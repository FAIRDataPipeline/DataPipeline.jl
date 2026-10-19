# SPDX-License-Identifier: LGPL-3.0-or-later

module TestCitationFile

using DataPipeline
using Test

const ReadWriteException = DataPipeline.ReadWriteException

# A paper's front matter as `_frontmatter` gives it
function front_matter(title, authors...;
                      affiliations = [String[] for _ in authors])
    return (title = title, authors = collect(String, authors),
            affiliations = affiliations)
end

# The paper's citation in a `CITATION.cff` text, as the package reads it
function said(text)
    return DataPipeline._citationcffsays(DataPipeline._papercitation(DataPipeline._cffmapping(text)))
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

# A file as a person keeps one: comments, ORCIDs, an affiliation, keys before
# and after the authors, and a comment under `authors:`
const KEPT = """
cff-version: 1.2.0
message: "Please cite this paper."
title: "An old title"
license: CC-BY-4.0
authors:
  # The authors, as the paper lists them
  - family-names: Fairlie
    given-names: Morag
    orcid: "https://orcid.org/0000-0002-1825-0097"
  # A comment about Oskar
  - family-names: Lindqvist
    given-names: Oskar
    affiliation: "Museum of Imaginary Things"
  - family-names: Quennell
    given-names: Tobias
    orcid: "https://orcid.org/0000-0000-0000-0001"
keywords:
  - biodiversity
"""

@testset "a paper's CITATION.cff" begin
    @testset "names" begin
        person = DataPipeline._cffperson
        @test person("Morag Fairlie") ==
              ["family-names" => "Fairlie", "given-names" => "Morag"]
        @test person("Ines A. Valcourt") ==
              ["family-names" => "Valcourt", "given-names" => "Ines A."]
        @test person("Ludwig van Beethoven") ==
              ["family-names" => "Beethoven", "given-names" => "Ludwig",
            "name-particle" => "van"]
        @test person("Martin Luther King Jr.") ==
              ["family-names" => "King", "given-names" => "Martin Luther",
            "name-suffix" => "Jr."]
        @test person("Vincent Van Gogh") ==
              ["family-names" => "Gogh", "given-names" => "Vincent Van"]
        @test person("Plato") == ["family-names" => "Plato"]
        @test DataPipeline._yamlquoted("A \"quoted\" \\ title") ==
              "\"A \\\"quoted\\\" \\\\ title\""
    end

    @testset "drafts" begin
        front = front_matter("EcoSISTEM: a \"model\"", "Morag Fairlie",
                             "Ludwig van Beethoven",
                             "M\u00fcller-Smith Jr. III";
                             affiliations = [["Northhaven", "Invented Centre"],
                                 String[],
                                 ["Bonn"]])
        # The paper at the top level, read back as given
        draft = DataPipeline._draftcitation(front, nothing)
        found = said(draft)
        @test found.title == "EcoSISTEM: a \"model\""
        @test found.authors == front.authors
        @test DataPipeline._cffmapping(draft)["authors"][1]["affiliation"] ==
              "Northhaven; Invented Centre"
        compared = DataPipeline._comparecitation(draft, front)
        @test isnothing(compared.title) && isempty(compared.added) &&
              isempty(compared.removed) && !compared.reordered
        @test compared.unidentified == front.authors

        # Beside a package, the package at the top level with its own ORCIDs,
        # and the paper the preferred-citation
        package = (title = "EcoSISTEM.jl",
                   authors = ["Tobias Quennell", "A Lab"],
                   identifiers = Dict("Tobias Quennell" => "https://orcid.org/0000-0000-0000-0001",
                                      "A Lab" => "https://ror.org/000000000"))
        draft = DataPipeline._draftcitation(front, package)
        meta = DataPipeline._cffmapping(draft)
        @test meta["title"] == "EcoSISTEM.jl"
        @test meta["authors"][1]["orcid"] ==
              "https://orcid.org/0000-0000-0000-0001"
        @test !haskey(meta["authors"][2], "orcid")
        @test meta["preferred-citation"]["type"] == "article"
        @test said(draft).authors == front.authors

        # No title or no author, no citation: all that is missing is said,
        # with how to give it without changing the page
        neither = message_of(ReadWriteException) do
            return DataPipeline._draftcitation(front_matter(nothing), nothing)
        end
        @test occursin("has no \\title and no \\author", neither)
        @test occursin("unless \\maketitle is used", neither)
        @test occursin("has no \\title, which",
                       message_of(ReadWriteException) do
                           return DataPipeline._draftcitation(front_matter(nothing,
                                                                           "A B"),
                                                              nothing)
                       end)
        @test occursin("has no \\author, which",
                       message_of(ReadWriteException) do
                           return DataPipeline._addpreferred(KEPT,
                                                             front_matter("T"))
                       end)

        # A preferred-citation added to a package's file, which is kept
        added = DataPipeline._addpreferred(KEPT, front)
        @test startswith(added, KEPT)
        @test said(added).title == front.title
        @test DataPipeline._cffmapping(added)["title"] == "An old title"
    end

    @testset "a package in the repository" begin
        holds(files) = DataPipeline._holdspackage(let dir = mktempdir()
                                                      for (name, text) in files
                                                          write(joinpath(dir,
                                                                         name),
                                                                text)
                                                      end
                                                      dir
                                                  end)
        @test holds(Dict("codemeta.json" => "{}"))
        @test holds(Dict("Project.toml" => "name = \"X\"\nuuid = \"00000000-0000-0000-0000-000000000000\"\n"))
        # An environment's project file names no package
        @test !holds(Dict("Project.toml" => "[deps]\nDataPipeline = \"9ced6f0a-eb77-43a8-bbd1-bbf3031b0d12\"\n"))
        @test !holds(Dict("paper.tex" => ""))
    end

    @testset "comparing with the LaTeX" begin
        compare(names...;
                title = "An old title") = DataPipeline._comparecitation(KEPT,
                                                                        front_matter(title,
                                                                                     names...))
        same = compare("Morag Fairlie", "Oskar Lindqvist", "Tobias Quennell")
        @test isnothing(same.title) && !same.reordered && !same.renaming
        @test same.unidentified == ["Oskar Lindqvist"]
        # Compared whatever the case, full stops and the encoding of accents
        @test !compare("morag fairlie", "Oskar Lindqvist.", "Tobias Quennell").reordered
        @test compare("Oskar Lindqvist", "Morag Fairlie", "Tobias Quennell").reordered
        added = compare("Morag Fairlie", "Oskar Lindqvist", "Ada New",
                        "Tobias Quennell")
        @test added.added == ["Ada New"] && isempty(added.removed) &&
              !added.renaming && !added.reordered
        removed = compare("Morag Fairlie", "Tobias Quennell")
        @test removed.removed == ["Oskar Lindqvist"] && !removed.renaming
        renamed = compare("Morag Fairlie", "Oskar Lindquist", "Tobias Quennell")
        @test renamed.renaming
        @test compare("Morag Fairlie", "Oskar Lindqvist", "Tobias Quennell";
                      title = "A new title").title ==
              (file = "An old title", latex = "A new title")
    end

    @testset "updating" begin
        update(text, title, names...) = DataPipeline._updatecitation(text,
                                                                     front_matter(title,
                                                                                  names...))

        # Reordered: each entry moved whole, with its comment; the comment
        # under `authors:` and every other line kept
        moved = update(KEPT, "An old title", "Oskar Lindqvist",
                       "Tobias Quennell",
                       "Morag Fairlie")
        @test moved.changes == ["authors put in the LaTeX's order"]
        @test moved.text == """
              cff-version: 1.2.0
              message: "Please cite this paper."
              title: "An old title"
              license: CC-BY-4.0
              authors:
                # The authors, as the paper lists them
                # A comment about Oskar
                - family-names: Lindqvist
                  given-names: Oskar
                  affiliation: "Museum of Imaginary Things"
                - family-names: Quennell
                  given-names: Tobias
                  orcid: "https://orcid.org/0000-0000-0000-0001"
                - family-names: Fairlie
                  given-names: Morag
                  orcid: "https://orcid.org/0000-0002-1825-0097"
              keywords:
                - biodiversity
              """

        # Added, its entry as indented as the others, with no ORCID, and the
        # title rewritten on its own line
        changed = update(KEPT, "A new title", "Morag Fairlie", "Ada New",
                         "Oskar Lindqvist", "Tobias Quennell")
        @test changed.changes ==
              ["Ada New added, with no ORCID",
            "title changed from \"An old title\" to \"A new title\""]
        @test said(changed.text).authors ==
              ["Morag Fairlie", "Ada New", "Oskar Lindqvist", "Tobias Quennell"]
        @test occursin("\n  - family-names: \"New\"\n    given-names: \"Ada\"\n",
                       changed.text)
        @test occursin("\ntitle: \"A new title\"\n", changed.text)
        # ... and removed, the others' entries kept
        removed = update(KEPT, "An old title", "Morag Fairlie",
                         "Tobias Quennell")
        @test removed.changes == ["Oskar Lindqvist removed"]
        @test !occursin("Lindqvist", removed.text)
        @test occursin("orcid: \"https://orcid.org/0000-0000-0000-0001\"",
                       removed.text)

        # A removal and an addition at once may be a renaming: the authors
        # are left as they are and both names said, the title still updated
        renamed = update(KEPT, "Another title", "Morag Fairlie",
                         "Oskar Lindquist",
                         "Tobias Quennell")
        @test said(renamed.text).authors ==
              ["Morag Fairlie", "Oskar Lindqvist", "Tobias Quennell"]
        @test occursin("Oskar Lindqvist removed and Oskar Lindquist added may be a renaming",
                       join(renamed.changes))
        @test said(renamed.text).title == "Another title"

        # Nothing to change changes nothing
        unchanged = update(KEPT, "An old title", "Morag Fairlie",
                           "Oskar Lindqvist", "Tobias Quennell")
        @test unchanged.text == KEPT && isempty(unchanged.changes)

        # Dashes at the key's own indentation, and a title over two lines
        flush = """
                cff-version: 1.2.0
                title: A title
                  over two lines
                authors:
                - given-names: Ada
                  family-names: First
                - name: Second Lab
                """
        flushed = update(flush, "One line", "Second Lab", "Ada First")
        @test flushed.text == """
              cff-version: 1.2.0
              title: "One line"
              authors:
              - name: Second Lab
              - given-names: Ada
                family-names: First
              """

        # The preferred-citation is the paper's: it is updated, and the top
        # level, a package's, is left alone
        paper = DataPipeline._addpreferred(KEPT,
                                           front_matter("A paper", "Ada New",
                                                        "Morag Fairlie"))
        updated = update(paper, "A paper", "Morag Fairlie", "Ada New")
        @test said(updated.text).authors == ["Morag Fairlie", "Ada New"]
        @test DataPipeline._citationcffsays(updated.text).authors ==
              ["Morag Fairlie", "Oskar Lindqvist", "Tobias Quennell"]
        @test startswith(updated.text, KEPT)

        # The check on an update refuses a text that changes an author's entry
        # or anything else, or does not give the LaTeX's authors and title
        front = front_matter("An old title", "Morag Fairlie", "Oskar Lindqvist",
                             "Tobias Quennell")
        check(after) = message_of(ReadWriteException) do
            return DataPipeline._checkupdate(KEPT, after, front, false)
        end
        @test occursin("change an author's entry",
                       check(replace(KEPT,
                                     "0000-0000-0000-0001" => "0000-0000-0000-0009")))
        @test occursin("change more than",
                       check(replace(KEPT, "CC-BY-4.0" => "MIT")))
        @test occursin("authors as the LaTeX has them",
                       check(replace(KEPT, "Lindqvist" => "Lindquist")))
        @test occursin("title as the LaTeX has it",
                       check(replace(KEPT, "An old title" => "Another")))
        @test occursin("unreadable", check(KEPT * "  - : [\n"))
        @test isnothing(DataPipeline._checkupdate(KEPT, KEPT, front, false))

        # A flow list cannot be updated an entry at a time
        msg = message_of(ReadWriteException) do
            return update("cff-version: 1.2.0\ntitle: T\nauthors: [{name: A}, {name: B}]\n",
                          "T", "B", "A")
        end
        @test occursin("flow list", msg)
    end
end

end
