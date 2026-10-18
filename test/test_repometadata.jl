# SPDX-License-Identifier: LGPL-3.0-or-later

module TestRepoMetadata

using DataPipeline
using Test

const LibGit2 = DataPipeline.LibGit2

# A repository holding `files`, a name to its text, committed once, and the
# commit's hash
function committed(files::AbstractDict)
    dir = mktempdir()
    repo = LibGit2.init(dir)
    for (name, text) in files
        write(joinpath(dir, name), text)
        LibGit2.add!(repo, name)
    end
    signature = LibGit2.Signature("Test", "test@example.com", 1_000_000_000, 0)
    sha = string(LibGit2.commit(repo, "metadata", author = signature,
                                committer = signature))
    return (dir = dir, repo = repo, sha = sha)
end

const CODEMETA = """
{
    "@context": "https://w3id.org/codemeta/3.0",
    "type": "SoftwareSourceCode",
    "name": "Example.jl",
    "description": "An <em>example</em> package",
    "softwareVersion": "v1.2.0",
    "license": "https://spdx.org/licenses/MIT",
    "keywords": ["julia", "examples"],
    "author": [
        {"type": "Person", "givenName": ["Ada", "M"], "familyName": "Lovelace",
         "id": "https://orcid.org/0000-0002-1825-0097",
         "affiliation": [{"type": "Organization", "name": "Somewhere"}]},
        {"type": "Person", "givenName": "Charles", "familyName": "Babbage"},
        {"type": "Organization", "name": "An Example Institute",
         "identifier": "https://ror.org/000000000"},
        {"type": "Person", "givenName": "No", "familyName": "Identifier",
         "id": "mailto:someone@example.com"}
    ]
}
"""

const ZENODO = """
{
    "title": "Example.jl from Zenodo",
    "description": "<p>Zenodo's description</p>",
    "version": "1.2.0",
    "license": {"id": "Apache-2.0"},
    "keywords": ["zenodo"],
    "creators": [
        {"name": "Lovelace, Ada M.", "orcid": "0000-0002-1825-0097"},
        {"name": "Babbage, Charles", "orcid": "0000-0001-5109-3700",
         "affiliation": "Somewhere"},
        {"name": "Somebody Else"}
    ]
}
"""

const CITATION_CFF = """
cff-version: 1.2.0
title: Example.jl from CFF
abstract: CFF's abstract
version: "1.2.0"
license: [GPL-3.0-only, MIT]
keywords: [cff, citation]
authors:
  - given-names: Ludwig
    name-particle: van
    family-names: Beethoven
    name-suffix: Jr.
    orcid: "http://orcid.org/0000-0002-9079-593X"
  - name: An Example Entity
"""

const PROJECT = """
name = "Example"
uuid = "00000000-0000-0000-0000-000000000000"
license = "LGPL-3.0-or-later"
version = "1.2.1"
authors = ["Ada M Lovelace <ada@example.com>", "Charles Babbage"]

[rsmd]
keywords = ["not", "read"]
"""

@testset "repository metadata" begin
    @testset "each file alone" begin
        meta(name,
             text) = DataPipeline._repositorymetadata(committed(Dict(name =>
                                                                         text)).dir)

        # codemeta.json: a person by given and family names, either of them a
        # list; an organisation by name; identifiers only where ORCID or ROR;
        # affiliations dropped; markup taken out; `softwareVersion` when there
        # is no `version`
        codemeta = meta("codemeta.json", CODEMETA)
        @test codemeta.authors == ["Ada M Lovelace", "Charles Babbage",
            "An Example Institute", "No Identifier"]
        @test codemeta.identifiers ==
              Dict("Ada M Lovelace" => "https://orcid.org/0000-0002-1825-0097",
                   "An Example Institute" => "https://ror.org/000000000")
        @test codemeta.licence == "https://spdx.org/licenses/MIT"
        @test codemeta.keywords == ["julia", "examples"]
        @test codemeta.description == "An example package"
        @test codemeta.version == "v1.2.0"
        @test codemeta.title == "Example.jl"
        @test codemeta.files == ["codemeta.json"]

        # .zenodo.json: a creator as "Family, Given", a bare ORCID made a URL,
        # a licence given as an object
        zenodo = meta(".zenodo.json", ZENODO)
        @test zenodo.authors == ["Ada M. Lovelace", "Charles Babbage",
            "Somebody Else"]
        @test zenodo.identifiers ==
              Dict("Ada M. Lovelace" => "https://orcid.org/0000-0002-1825-0097",
                   "Charles Babbage" => "https://orcid.org/0000-0001-5109-3700")
        @test zenodo.licence == "Apache-2.0"
        @test zenodo.keywords == ["zenodo"]
        @test zenodo.description == "Zenodo's description"
        @test zenodo.version == "1.2.0"
        @test zenodo.title == "Example.jl from Zenodo"

        # CITATION.cff: a name in its parts, an entity by name, an ORCID with
        # `http:` given `https:`, the first of several licences
        cff = meta("CITATION.cff", CITATION_CFF)
        @test cff.authors == ["Ludwig van Beethoven Jr.", "An Example Entity"]
        @test cff.identifiers ==
              Dict("Ludwig van Beethoven Jr." => "https://orcid.org/0000-0002-9079-593X")
        @test cff.licence == "GPL-3.0-only"
        @test cff.keywords == ["cff", "citation"]
        @test cff.description == "CFF's abstract"
        @test cff.version == "1.2.0"

        # A Julia project file: Pkg's own fields only, so neither `license`
        # nor an `[rsmd]` table is read
        project = meta("Project.toml", PROJECT)
        @test project.authors == ["Ada M Lovelace", "Charles Babbage"]
        @test isempty(project.identifiers)
        @test isnothing(project.licence)
        @test isempty(project.keywords)
        @test project.version == "1.2.1"
        @test project.title == "Example"
        @test meta("JuliaProject.toml", PROJECT).files == ["JuliaProject.toml"]

        # Keywords may be one string of them
        @test meta("codemeta.json",
                   """{"keywords": "one, two ,three"}""").keywords ==
              ["one", "two", "three"]
    end

    @testset "the files together, most trusted first" begin
        all = committed(Dict("codemeta.json" => CODEMETA,
                             ".zenodo.json" => ZENODO,
                             "CITATION.cff" => CITATION_CFF,
                             "JuliaProject.toml" => replace(PROJECT,
                                     "1.2.1" => "9.9.9"),
                             "Project.toml" => PROJECT))
        # Everything is codemeta.json's; what each later file says more or
        # otherwise is told, in one message: other authors, an identifier
        # for an author named the same way, another licence and keywords
        meta = @test_logs((:info,
                           r"^the repository's metadata at the working tree at .* is codemeta\.json's alone, and files trusted less say more or otherwise: \.zenodo\.json gives the authors Ada M\. Lovelace, Charles Babbage, Somebody Else, where codemeta\.json gives Ada M Lovelace, Charles Babbage, An Example Institute, No Identifier; \.zenodo\.json gives Charles Babbage the identifier https://orcid\.org/0000-0001-5109-3700, which codemeta\.json lacks; \.zenodo\.json gives the licence Apache-2\.0, where codemeta\.json gives https://spdx\.org/licenses/MIT; \.zenodo\.json gives the keywords zenodo, where codemeta\.json gives julia, examples; CITATION\.cff gives the authors Ludwig van Beethoven Jr\., An Example Entity, where .*; JuliaProject\.toml gives the authors Ada M Lovelace, Charles Babbage, where .*; Project\.toml gives the authors Ada M Lovelace, Charles Babbage, where codemeta\.json gives Ada M Lovelace, Charles Babbage, An Example Institute, No Identifier$"),
                          DataPipeline._repositorymetadata(all.dir))
        @test meta.authors == ["Ada M Lovelace", "Charles Babbage",
            "An Example Institute", "No Identifier"]
        @test !haskey(meta.identifiers, "Charles Babbage")
        @test meta.files == ["codemeta.json", ".zenodo.json", "CITATION.cff",
            "JuliaProject.toml", "Project.toml"]
        @test meta.licence == "https://spdx.org/licenses/MIT"
        @test meta.keywords == ["julia", "examples"]
        @test meta.title == "Example.jl"
        @test meta.version == "v1.2.0"
        # A field the first file lacks stays empty, whatever a later file says
        sparse = committed(Dict("codemeta.json" => """{"name": "Sparse"}""",
                                ".zenodo.json" => ZENODO))
        lacking = r"^the repository's metadata at the working tree at .* is codemeta\.json's alone, and files trusted less say more or otherwise: \.zenodo\.json gives the authors Ada M\. Lovelace, Charles Babbage, Somebody Else, which codemeta\.json lacks; \.zenodo\.json gives the licence Apache-2\.0, which codemeta\.json lacks; \.zenodo\.json gives the keywords zenodo, which codemeta\.json lacks"
        unfilled = @test_logs((:info, Regex(lacking.pattern * "\$")),
                              DataPipeline._repositorymetadata(sparse.dir))
        @test unfilled.title == "Sparse"
        @test isempty(unfilled.authors) && isempty(unfilled.identifiers)
        @test isnothing(unfilled.licence) && isempty(unfilled.keywords)
        @test isnothing(unfilled.version) && isnothing(unfilled.description)
        # The title is told only where it is asked for, as for a release
        @test_logs((:info,
                    Regex(lacking.pattern *
                          "; \\.zenodo\\.json gives the title 'Example\\.jl from Zenodo', where codemeta\\.json gives 'Sparse'\$")),
                   DataPipeline._repositorymetadata(sparse.dir, title = true))
        # A later file that says nothing more or otherwise is not told of:
        # the same authors by the same names, and a title, not asked for
        agree = committed(Dict("codemeta.json" => CODEMETA,
                               "Project.toml" => """
                               name = "Example"
                               authors = ["Ada M. Lovelace <ada@example.com>",
                                          "Charles Babbage", "An Example Institute",
                                          "No Identifier"]
                               """))
        @test_logs DataPipeline._repositorymetadata(agree.dir)
        # A different identifier for an author is told of, the first file's
        # kept
        clash = committed(Dict(".zenodo.json" => ZENODO,
                               "CITATION.cff" => """
                               authors:
                                 - given-names: Charles
                                   family-names: Babbage
                                   orcid: https://orcid.org/0000-0000-0000-0000
                               """))
        clashed = @test_logs((:info,
                              r"; CITATION\.cff gives Charles Babbage the identifier https://orcid\.org/0000-0000-0000-0000, where \.zenodo\.json gives https://orcid\.org/0000-0001-5109-3700$"),
                             DataPipeline._repositorymetadata(clash.dir))
        @test clashed.identifiers["Charles Babbage"] ==
              "https://orcid.org/0000-0001-5109-3700"
    end

    @testset "where the files are read" begin
        fixture = committed(Dict("Project.toml" => PROJECT))
        # At the commit, whatever the working tree now holds
        write(joinpath(fixture.dir, "Project.toml"),
              replace(PROJECT, "1.2.1" => "2.0.0"))
        write(joinpath(fixture.dir, ".zenodo.json"), ZENODO)
        at_commit = DataPipeline._repositorymetadata(fixture.repo, fixture.sha)
        @test at_commit.version == "1.2.1"
        @test at_commit.files == ["Project.toml"]
        in_tree = @test_logs((:info,
                              r"^the repository's metadata at the working tree at .* is \.zenodo\.json's alone, and files trusted less say more or otherwise: Project\.toml gives the authors Ada M Lovelace, Charles Babbage, where \.zenodo\.json gives Ada M\. Lovelace, Charles Babbage, Somebody Else$"),
                             DataPipeline._repositorymetadata(fixture.dir))
        @test in_tree.version == "1.2.0"
        @test in_tree.files == [".zenodo.json", "Project.toml"]
        # No files, nothing said
        empty = DataPipeline._repositorymetadata(mktempdir())
        @test isempty(empty.authors) && isempty(empty.files)
        @test isnothing(empty.licence) && isnothing(empty.version)
        # The first file that exists being unreadable is an error, not a
        # reason to read the next
        broken = committed(Dict("codemeta.json" => "{ not json",
                                "Project.toml" => PROJECT))
        unread = try
            DataPipeline._repositorymetadata(broken.repo, broken.sha)
        catch err
            err
        end
        @test unread isa DataPipeline.ReadWriteException
        @test startswith(unread.msg,
                         "cannot read codemeta.json at commit $(broken.sha), the most trusted of the repository's metadata files there: ")
        # A later file that cannot be read is warned of and passed over
        later = committed(Dict("codemeta.json" => CODEMETA,
                               ".zenodo.json" => "{ not json"))
        read_on = @test_logs((:warn,
                              r"^cannot read \.zenodo\.json at commit [0-9a-f]+, so it is passed over: "),
                             DataPipeline._repositorymetadata(later.repo,
                                                              later.sha))
        @test read_on.files == ["codemeta.json"]
        @test read_on.licence == "https://spdx.org/licenses/MIT"
        close(fixture.repo)
        close(broken.repo)
        close(later.repo)
    end

    @testset "at a commit on GitHub" begin
        sha = "60a9c046c988abe9f6ab76370e643383e721e7ef"
        asked = String[]
        fetch(url) = (push!(asked, url);
                      endswith(url, "/Project.toml") ? PROJECT : nothing)
        for remote in ("https://github.com/FAIRDataPipeline/DataPipeline.jl.git",
                       "git@github.com:FAIRDataPipeline/DataPipeline.jl.git")
            empty!(asked)
            meta = DataPipeline._repositorymetadata(remote, sha; fetch)
            @test asked ==
                  ["https://raw.githubusercontent.com/FAIRDataPipeline/DataPipeline.jl/$sha/$name"
                   for name in first.(DataPipeline.REPOSITORY_METADATA_FILES)]
            @test meta.files == ["Project.toml"]
            @test meta.version == "1.2.1"
        end
        # Another host has nothing to read without a clone
        empty!(asked)
        elsewhere = DataPipeline._repositorymetadata("https://gitlab.com/group/sub/repo.git",
                                                     sha; fetch)
        @test isempty(asked) && isempty(elsewhere.files)
        # A file that cannot be fetched may exist: before any is found, an
        # error; after, warned of and passed over
        remote = "https://github.com/FAIRDataPipeline/DataPipeline.jl.git"
        down(url) = throw(DataPipeline.ReadWriteException("cannot reach $url: down"))
        first_down(url) = endswith(url, "/codemeta.json") ? down(url) :
                          endswith(url, "/Project.toml") ? PROJECT : nothing
        @test_throws DataPipeline.ReadWriteException DataPipeline._repositorymetadata(remote,
                                                                                      sha;
                                                                                      fetch = first_down)
        later_down(url) = endswith(url, "/Project.toml") ? down(url) :
                          endswith(url, "/codemeta.json") ? CODEMETA : nothing
        found = @test_logs((:warn,
                            r"^cannot read Project\.toml at commit [0-9a-f]+ of .*, so it is passed over: cannot reach .*: down$"),
                           DataPipeline._repositorymetadata(remote, sha;
                                                            fetch = later_down))
        @test found.files == ["codemeta.json"]
    end

    @testset "identifiers and names" begin
        @test DataPipeline._authoridentifier("0000-0002-1825-009X") ==
              "https://orcid.org/0000-0002-1825-009X"
        @test DataPipeline._authoridentifier(" http://ror.org/000000000 ") ==
              "https://ror.org/000000000"
        @test isnothing(DataPipeline._authoridentifier("https://example.com/me"))
        @test isnothing(DataPipeline._authoridentifier(42))
        @test DataPipeline._namekey("Martin J. Burke") ==
              DataPipeline._namekey("martin  j burke")
    end
end

end
