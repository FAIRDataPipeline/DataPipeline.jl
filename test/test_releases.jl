# SPDX-License-Identifier: LGPL-3.0-or-later

module TestReleases

using DataPipeline
using Dates
using Test

const LibGit2 = DataPipeline.LibGit2

@testset "releases" begin
    # A clone with a commit for each case, tagged as the case needs, both
    # lightweight and annotated
    dir = mktempdir()
    repo = LibGit2.init(dir)
    signature = LibGit2.Signature("Test", "test@example.com", 1_000_000_000, 0)
    parent = String[]
    function commit!(content)
        write(joinpath(dir, "a.txt"), content)
        LibGit2.add!(repo, "a.txt")
        sha = string(LibGit2.commit(repo, content, author = signature,
                                    committer = signature,
                                    parent_ids = LibGit2.GitHash.(parent)))
        parent = [sha]
        return sha
    end
    lightweight!(name, sha) = close(LibGit2.GitReference(repo,
                                                         LibGit2.GitHash(sha),
                                                         "refs/tags/$name"))
    annotated!(name, sha) = LibGit2.tag_create(repo, name, sha,
                                               sig = signature, msg = name)
    same = commit!("two tags of one version")
    lightweight!("v1.2", same)
    annotated!("v1.2.0", same)
    lightweight!("paper-submission", same)
    promoted = commit!("a beta promoted")
    annotated!("v2.0.0-beta2", promoted)
    lightweight!("2.0.0", promoted)
    two = commit!("two releases")
    lightweight!("v3.0.0", two)
    lightweight!("v3.1.0", two)
    betas = commit!("two betas")
    lightweight!("v4.0.0-rc1", betas)
    lightweight!("v4.0.0-rc2", betas)
    beta = commit!("one beta")
    annotated!("v5.0.0-beta.1", beta)
    untagged = commit!("no version")
    lightweight!("not-a-version", untagged)

    @testset "the version from a clone's tags" begin
        tags = DataPipeline._repositorytags(repo)
        @test tags["v1.2.0"] == same            # an annotated tag's commit
        @test tags["v1.2"] == same
        # Tags of one version give it, in full, with every tag that gives it;
        # a tag that is no version is passed over
        @test DataPipeline._commitversion(tags, same) ==
              (version = "1.2.0", tags = ["v1.2", "v1.2.0"])
        # A full release is preferred over a pre-release of the commit, a
        # leading `v` or none
        @test DataPipeline._commitversion(tags, promoted) ==
              (version = "2.0.0", tags = ["2.0.0"])
        # ... unless the pre-release is the tag named
        @test DataPipeline._commitversion(tags, promoted, "v2.0.0-beta2") ==
              (version = "2.0.0-beta2", tags = ["v2.0.0-beta2"])
        # A pre-release alone is the version
        @test DataPipeline._commitversion(tags, beta).version == "5.0.0-beta.1"
        # Several releases, or several pre-releases alone, need one named
        for sha in (two, betas)
            err = @test_throws ArgumentError DataPipeline._commitversion(tags,
                                                                         sha)
            @test occursin("tagged with several versions", err.value.msg)
        end
        @test DataPipeline._commitversion(tags, two, "v3.1.0").version ==
              "3.1.0"
        err = @test_throws ArgumentError DataPipeline._commitversion(tags, two)
        @test occursin("v3.0.0, v3.1.0: name the one to release, as NamedCommit(\"v3.0.0\")",
                       err.value.msg)
        # A name that is no version tag of this commit counts for nothing
        @test DataPipeline._commitversion(tags, promoted, "v1.2").version ==
              "2.0.0"
        # No version tag at all
        err = @test_throws ArgumentError DataPipeline._commitversion(tags,
                                                                     untagged)
        @test occursin("no tag that reads as a semantic version", err.value.msg)
    end

    @testset "at a remote with no clone" begin
        # A bare clone reached by a file URL, which needs no network
        bare = joinpath(mktempdir(), "bare.git")
        close(LibGit2.clone(dir, bare, isbare = true))
        url = "file://" * (Sys.iswindows() ? "/" * replace(bare, '\\' => '/') :
               bare)
        # The remote's tags are the clone's, an annotated tag by its commit
        @test DataPipeline._repositorytags(url) ==
              DataPipeline._repositorytags(repo)
        @test DataPipeline._commitversion(DataPipeline._repositorytags(url),
                                          promoted).version == "2.0.0"
        # A tag or a branch names its commit; anything else nothing
        branch = LibGit2.headname(repo)
        @test DataPipeline._remotecommit(url, "v1.2.0") == same
        @test DataPipeline._remotecommit(url, branch) == untagged
        @test isnothing(DataPipeline._remotecommit(url, "no-such-tag"))
        # A remote that cannot be listed is warned of and names nothing
        absent = "file://" *
                 (Sys.iswindows() ? "/" * replace(mktempdir(), '\\' => '/') :
                  mktempdir()) * "/absent.git"
        @test_logs((:warn, r"^cannot list the tags and branches of "),
                   @test isnothing(DataPipeline._remotecommit(absent, "v1.2.0")))
        @test_throws DataPipeline.ReadWriteException DataPipeline._repositorytags(absent)
        # An scp-like SSH address is listed at its HTTPS form, which needs no
        # keys
        @test DataPipeline._listingurl("git@github.com:FAIRDataPipeline/DataPipeline.jl.git") ==
              "https://github.com/FAIRDataPipeline/DataPipeline.jl.git"
        @test DataPipeline._listingurl(url) == url
    end
    close(repo)

    @testset "the names a release is registered by" begin
        @test DataPipeline._releasenames("https://github.com/FAIRDataPipeline/DataPipeline.jl.git") ==
              (release = "FAIRDataPipeline/DataPipeline.jl",
               namespace = "FAIRDataPipeline", data_product = "DataPipeline.jl")
        # Deeper than an organisation: the first part the namespace, the rest
        # the name, the whole path the release
        @test DataPipeline._releasenames("git@gitlab.com:group/sub/repo.git") ==
              (release = "group/sub/repo", namespace = "group",
               data_product = "sub/repo")
        @test_throws ArgumentError DataPipeline._releasenames("https://github.com/repo.git")
        @test_throws ArgumentError DataPipeline._releasenames("https://gitlab.com/a.b/repo.git")
        # The web page of a release on GitHub, by the tag named, else `v` and
        # the version in full, else the first
        page(tags,
             named = nothing) = DataPipeline._releasewebsite("git@github.com:org/repo.git",
                                                             "1.2.0",
                                                             tags, named)
        @test page(["1.2", "v1.2.0"]) ==
              "https://github.com/org/repo/releases/tag/v1.2.0"
        @test page(["1.2", "v1.2.0"], "1.2") ==
              "https://github.com/org/repo/releases/tag/1.2"
        @test page(["1.2", "1.2.0"]) ==
              "https://github.com/org/repo/releases/tag/1.2"
        @test isnothing(DataPipeline._releasewebsite("https://gitlab.com/org/repo",
                                                     "1.2.0", ["v1.2.0"],
                                                     nothing))
    end
end

# In test/releases, what was answered on 2026-10-16 for this package's own
# release v0.54.1: GitHub's record of the repository (its id alone kept),
# Zenodo's record 23129599, its search for that version and for one it has not
# got, and DataCite's metadata of the DOI 10.5281/zenodo.23129599; and the
# package's `.zenodo.json` at that release
saved(name) = read(joinpath(@__DIR__, "releases", name), String)
const DATACITE = "application/vnd.datacite.datacite+json"

# Zenodo and GitHub as they answered, the search finding `found`, the DOI of
# the version of the tag, or nothing
function answers(found::Union{Nothing, String}; github::Int = 200,
                 badge::Union{Nothing, String} = "https://doi.org/10.5281/zenodo.23129599")
    search = DataPipeline.JSON.parse(saved("zenodo-search-v0.54.1.json"))
    search["hits"]["hits"][1]["doi"] = something(found, "")
    asked = String[]
    function reply(url)
        push!(asked, url)
        startswith(url, "https://api.github.com/repos/") &&
            return (status = github, location = nothing,
                    body = saved("github-repository.json"))
        startswith(url, "https://zenodo.org/badge/latestdoi/302237736") &&
            return (status = isnothing(badge) ? 404 : 302, location = badge,
                    body = "")
        url == "https://zenodo.org/api/records/23129599" &&
            return (status = 200, location = nothing,
                    body = saved("zenodo-record.json"))
        if startswith(url, "https://zenodo.org/api/records?q=")
            isnothing(found) && return (status = 200, location = nothing,
                    body = saved("zenodo-search-none.json"))
            return (status = 200, location = nothing,
                    body = DataPipeline.JSON.json(search))
        end
        return error("asked of no answer: $url")
    end
    return (reply = reply, asked = asked)
end

@testset "a release's DOI" begin
    remote = "https://github.com/FAIRDataPipeline/DataPipeline.jl.git"
    # Zenodo's version of a tag, the tags tried in turn, by the repository's
    # id, its newest version's record and that record's concept
    found = answers("10.5281/zenodo.23129599")
    @test DataPipeline._zenododoi(remote, ["0.54.1", "v0.54.1"];
                                  fetch = found.reply) ==
          "10.5281/zenodo.23129599"
    @test found.asked[1:3] ==
          ["https://api.github.com/repos/FAIRDataPipeline/DataPipeline.jl",
        "https://zenodo.org/badge/latestdoi/302237736",
        "https://zenodo.org/api/records/23129599"]
    @test found.asked[4] ==
          "https://zenodo.org/api/records?q=parent.id%3A5270282%20AND%20metadata.version%3A%220.54.1%22&allversions=true&size=1"
    # None yet, no release archived at all, a repository GitHub has not got,
    # and a remote elsewhere: each said, and no DOI
    @test_logs((:info,
                r"^Zenodo has no version of FAIRDataPipeline/DataPipeline.jl for v9.9.9 yet"),
               @test isnothing(DataPipeline._zenododoi(remote, ["v9.9.9"];
                                                       fetch = answers(nothing).reply)))
    @test_logs((:info, r"^Zenodo has archived no release"),
               @test isnothing(DataPipeline._zenododoi(remote, ["v0.54.1"];
                                                       fetch = answers(nothing,
                                                                       badge = nothing).reply)))
    @test_logs((:warn,
                r"^GitHub's record of FAIRDataPipeline/DataPipeline.jl is not to be had now \(HTTP status 404\)"),
               @test isnothing(DataPipeline._zenododoi(remote, ["v0.54.1"];
                                                       fetch = answers(nothing,
                                                                       github = 404).reply)))
    @test_logs((:info, r"from GitHub, and https://gitlab.com/a/b is elsewhere"),
               @test isnothing(DataPipeline._zenododoi("https://gitlab.com/a/b",
                                                       ["v1.0.0"])))

    # Licences compared as SPDX now writes them
    @test DataPipeline._licencekey("LGPL-3.0+") ==
          DataPipeline._licencekey("https://spdx.org/licenses/LGPL-3.0-or-later")
    @test DataPipeline._licencekey("GPL-3.0") ==
          DataPipeline._licencekey("gpl-3.0-only")
    @test DataPipeline._licencekey("MIT") !=
          DataPipeline._licencekey("Apache-2.0")

    # The DOI's metadata compared with the repository's files
    identifier = "https://doi.org/10.5281/zenodo.23129599"
    citation = DataPipeline._datacitecitation(DataPipeline.JSON.parse(saved("datapipeline-v0.54.1.datacite.json")),
                                              identifier)
    sonia = "https://orcid.org/0000-0003-1536-2066"
    martin = "https://orcid.org/0000-0002-0460-7139"
    richard = "https://orcid.org/0000-0003-2589-8091"
    files(authors, identifiers; licence = "LGPL-3.0-or-later",
          title = "DataPipeline.jl") = (metadata = DataPipeline.RepositoryMetadata(authors,
                                                                                   identifiers,
                                                                                   licence,
                                                                                   String[],
                                                                                   nothing,
                                                                                   nothing,
                                                                                   title,
                                                                                   [".zenodo.json"]),
                                        version = "0.54.1")
    same = files(["Sonia Mitchell", "Martin J. Burke", "Richard Reeve"],
                 Dict("Sonia Mitchell" => sonia, "Richard Reeve" => richard,
                      "Martin J. Burke" => martin))
    @test_logs DataPipeline._comparerelease(identifier, citation, same)
    # An author named by one alone, an identifier only one gives, another
    # title, licence and version
    differing = files(["Sonia Mitchell", "Richard Reeve", "Ada Lovelace"],
                      Dict("Richard Reeve" => richard); licence = "MIT",
                      title = "Something else")
    differing = (metadata = differing.metadata, version = "0.55.0")
    @test_logs((:warn,
                Regex("^the release's DOI $identifier and the repository's metadata files differ: " *
                      "the DOI names Martin J Burke and the files do not; " *
                      "the files name Ada Lovelace and the DOI does not; " *
                      "the DOI's title is 'DataPipeline.jl' and the files' 'Something else'; " *
                      "the DOI's licence is LGPL-3.0\\+ and the files' MIT; " *
                      "the DOI is of version v0.54.1 and the release 0.55.0\$")),
               (:info,
                Regex("^the release's DOI $identifier and the repository's metadata files: " *
                      "the DOI identifies Sonia Mitchell as $sonia and the files do not\$")),
               DataPipeline._comparerelease(identifier, citation, differing))

    # Asking Zenodo and GitHub themselves, only when asked to, as the DOI
    # lookup of a source is
    if get(ENV, "FDP_TEST_DOI_LOOKUP", "false") == "true"
        @test DataPipeline._zenododoi(remote, ["v0.54.1"]) ==
              "10.5281/zenodo.23129599"
    end
end

# Registering a release needs a registry: the suite's, when `fair run` launches
# it; on its own this file tests the rest
if haskey(ENV, "FDP_CONFIG_DIR")
    @testset "register_release!" begin
        DataPipeline._resetsession!()
        launch = DataPipeline.YAML.load_file(DataPipeline.FDP_PATH_CONFIG())["run_metadata"]
        registry = DataPipeline.RegistryEndpoint(launch["local_data_registry_url"],
                                                 token = DataPipeline.FDP_LOCAL_TOKEN())
        entry(url) = DataPipeline._getentry(registry,
                                            DataPipeline.URIs.URI(url))
        uid = DataPipeline._randomhash()
        name = "release-fixture-$(first(uid, 12))"
        remote = "https://github.com/FAIRDataPipeline/$name.git"
        ada = "https://orcid.org/0000-0002-1825-0097"

        # A clone with metadata files, its commits naming the run so that
        # they are new to the registry
        dir = mktempdir()
        repo = LibGit2.init(dir)
        close(LibGit2.GitRemote(repo, "origin", remote))
        write(joinpath(dir, "codemeta.json"),
              """{"license": "MIT", "author": [{"name": "Ada Lovelace", "id": "$ada"}]}""")
        LibGit2.add!(repo, "codemeta.json")
        signature = LibGit2.Signature("Test", "test@example.com",
                                      1_000_000_000, 0)
        commit!(content) = (write(joinpath(dir, "a.txt"), "$content $uid\n");
                            LibGit2.add!(repo, "a.txt");
                            string(LibGit2.commit(repo, content,
                                                  author = signature,
                                                  committer = signature)))
        first_commit = commit!("first")
        LibGit2.tag_create(repo, "v1.0.0", first_commit, sig = signature,
                           msg = "v1.0.0")

        # The checked-out commit: its repository object, made with the
        # repository's authors and licence; the release record, named by the
        # remote's path, with its GitHub page; and the data product on the
        # same object
        release = DataPipeline.register_release!(registry,
                                                 DataPipeline.CheckedOutCommit(repo = dir))
        @test release isa DataPipeline.RegisteredRelease
        @test release.name == "FAIRDataPipeline/$name"
        @test release.version == v"1.0.0"
        @test release.commit == first_commit
        @test samefile(release.path, dir)
        @test release.repository == remote
        @test release.website ==
              "https://github.com/FAIRDataPipeline/$name/releases/tag/v1.0.0"
        @test isnothing(release.source)
        @test string(release.data_product) == "FAIRDataPipeline:$name@v1.0.0"
        object = entry(release.object)
        @test object["description"] == DataPipeline.REPOSITORY_DESCRIPTION
        @test [(author["name"], author["identifier"])
               for author in entry.(object["authors"])] ==
              [("Ada Lovelace", ada)]
        @test entry(object["storage_location"])["hash"] == first_commit
        record = entry(release.url)
        @test (record["name"], record["version"], record["website"],
               record["object"]) ==
              (release.name, "1.0.0", release.website, release.object)
        @test entry(release.data_product.url)["object"] == release.object
        @test sprint(show, release) ==
              "FAIRDataPipeline/$name 1.0.0 (commit $(first(first_commit, 8)))"
        @test occursin("  data product: FAIRDataPipeline:$name@v1.0.0\n",
                       sprint(show, MIME("text/plain"), release))

        # A second call changes nothing
        again = DataPipeline.register_release!(registry,
                                               DataPipeline.CheckedOutCommit(repo = dir))
        @test (again.url, again.object, again.data_product.url) ==
              (release.url, release.object, release.data_product.url)
        @test length(DataPipeline._getentries(registry, "code_repo_release",
                                              Dict("name" => release.name))) ==
              1

        # A checkout with uncommitted changes is not released; a commit named
        # is, whatever the checkout holds
        write(joinpath(dir, "a.txt"), "edited")
        err = @test_throws ArgumentError DataPipeline.register_release!(registry,
                                                                        DataPipeline.CheckedOutCommit(repo = dir))
        @test occursin("has uncommitted changes", err.value.msg)
        @test DataPipeline.register_release!(registry,
                                             DataPipeline.NamedCommit("v1.0.0",
                                                                      repo = dir)).url ==
              release.url

        # A commit with no version tag is not released
        untagged = commit!("untagged")
        err = @test_throws ArgumentError DataPipeline.register_release!(registry,
                                                                        DataPipeline.NamedCommit(untagged,
                                                                                                 repo = dir))
        @test occursin("no tag that reads as a semantic version",
                       err.value.msg)

        # A beta, then the same commit retagged as the release: its data
        # product is registered, and the release record, which this registry
        # cannot change, keeps the beta's version and says so
        beta_commit = commit!("beta")
        LibGit2.tag_create(repo, "v2.0.0-beta2", beta_commit, sig = signature,
                           msg = "beta")
        beta = DataPipeline.register_release!(registry,
                                              DataPipeline.NamedCommit("v2.0.0-beta2",
                                                                       repo = dir))
        @test beta.version == v"2.0.0-beta2"
        LibGit2.tag_create(repo, "v2.0.0", beta_commit, sig = signature,
                           msg = "release")
        promoted = @test_logs((:warn, r"cannot change a release record"),
                              DataPipeline.register_release!(registry,
                                                             DataPipeline.CheckedOutCommit(repo = dir)))
        @test promoted.version == v"2.0.0"
        @test promoted.object == beta.object
        @test string(promoted.data_product) == "FAIRDataPipeline:$name@v2.0.0"
        @test promoted.url == beta.url
        @test entry(beta.url)["version"] == "2.0.0-beta2"

        # The same version on another commit is refused
        clash_dir = mktempdir()
        clash = LibGit2.init(clash_dir)
        close(LibGit2.GitRemote(clash, "origin", remote))
        write(joinpath(clash_dir, "b.txt"), "another commit $uid\n")
        LibGit2.add!(clash, "b.txt")
        other = LibGit2.commit(clash, "other", author = signature,
                               committer = signature)
        LibGit2.tag_create(clash, "v1.0.0", other, sig = signature, msg = "v1")
        err = @test_throws DataPipeline.ReadWriteException DataPipeline.register_release!(registry,
                                                                                          DataPipeline.CheckedOutCommit(repo = clash_dir))
        @test occursin("registered already as the release of another commit",
                       err.value.msg)
        close(clash)

        # A release names its commit, and the commits before it
        @test DataPipeline.NamedCommit(release) ==
              DataPipeline.NamedCommit(first_commit, repo = dir)
        before = DataPipeline.AncestorCommits(of = release, including = false)
        @test before == DataPipeline.AncestorCommits(of = first_commit,
                                           including = false,
                                           repo = dir)
        @test_throws ArgumentError DataPipeline.AncestorCommits(of = release,
                                                                repo = mktempdir())
        # ... and a registered release resolves by URL with no clone
        @test [commit.sha
               for commit in DataPipeline.identify(registry,
                                                   DataPipeline.NamedCommit("v1.0.0",
                                                                            repo = remote)).commits] ==
              [first_commit]
        # A trace prints a release's commit as a commit
        @test occursin("commit $(first(first_commit, 8))",
                       sprint(show, MIME("text/plain"),
                              DataPipeline.provenance(registry,
                                                      "FAIRDataPipeline:$name@v1.0.0")))

        # A remote that cannot be listed gives no tags, so no release by URL
        @test_throws DataPipeline.ReadWriteException DataPipeline.register_release!(registry,
                                                                                    DataPipeline.NamedCommit(first_commit,
                                                                                                             repo = remote))
        # With no token nothing is registered
        third = commit!("third")
        LibGit2.tag_create(repo, "v3.0.0", third, sig = signature, msg = "v3")
        @test_throws DataPipeline.ReadWriteException DataPipeline.register_release!(DataPipeline.RegistryEndpoint(registry.url),
                                                                                    DataPipeline.CheckedOutCommit(repo = dir))
        # While the session rehearses, said and not registered
        DataPipeline.SESSION[] = DataPipeline.SessionRun(DataPipeline.Rehearsal(mktempdir()),
                                                         mktempdir(), nothing,
                                                         false, nothing)
        said = mktemp() do path, io
            result = redirect_stdout(io) do
                return DataPipeline.register_release!(registry,
                                                      DataPipeline.CheckedOutCommit(repo = dir))
            end
            close(io)
            return (result = result, text = read(path, String))
        end
        DataPipeline._resetsession!()
        @test isnothing(said.result)
        @test occursin("would register the release FAIRDataPipeline/$name 3.0.0 of commit $third",
                       said.text)
        @test occursin("on a new object for the commit, its authors Ada Lovelace",
                       said.text)
        @test isnothing(DataPipeline._getentry(registry, "code_repo_release",
                                               Dict("name" => release.name,
                                                    "version" => "3.0.0")))
        close(repo)

        # A DOI, for a repository Zenodo archives: its `.zenodo.json` the one
        # this package had at v0.54.1, so that it agrees with the DOI's
        # metadata. The DOI is made from this run's id, so that its source is
        # new to the registry, and answered with the saved metadata.
        zenodo_dir = mktempdir()
        zenodo_repo = LibGit2.init(zenodo_dir)
        zenodo_name = "zenodo-fixture-$(first(uid, 12))"
        close(LibGit2.GitRemote(zenodo_repo, "origin",
                                "https://github.com/FAIRDataPipeline/$zenodo_name.git"))
        write(joinpath(zenodo_dir, ".zenodo.json"),
              saved("datapipeline-v0.54.1.zenodo.json"))
        write(joinpath(zenodo_dir, "run.txt"), "zenodo $uid\n")
        LibGit2.add!(zenodo_repo, ".zenodo.json")
        LibGit2.add!(zenodo_repo, "run.txt")
        archived = string(LibGit2.commit(zenodo_repo, "archived",
                                         author = signature,
                                         committer = signature))
        LibGit2.tag_create(zenodo_repo, "v0.54.1", archived, sig = signature,
                           msg = "v0.54.1")
        doi = "10.5281/zenodo.$(parse(Int, first(uid, 10), base = 16))"
        doi_url = "https://doi.org/$doi"
        metadata(url, type) = type == DATACITE ?
                              saved("datapipeline-v0.54.1.datacite.json") :
                              nothing
        nothing_to_be_had(url, type) = nothing
        archive(found; doi = nothing,
                fetch = metadata) = DataPipeline._registerrelease(registry,
                                                                  DataPipeline.CheckedOutCommit(repo = zenodo_dir),
                                                                  nothing,
                                                                  doi;
                                                                  fetch,
                                                                  reply = answers(found).reply)
        # Zenodo has no version yet: the release is registered without a
        # source, and that said
        unarchived = @test_logs((:info,
                                 r"^Zenodo has no version of FAIRDataPipeline/zenodo-fixture"),
                                archive(nothing))
        @test isnothing(unarchived.source)
        # Called again once it has, the source is attached: the version DOI,
        # primary, the DOI's title and date, the release's version
        sourced = @test_logs archive(doi)
        @test sourced.url == unarchived.url
        @test !isnothing(sourced.source)
        source = entry(sourced.source)
        @test (source["identifier"], source["title"], source["version"],
               source["primary_not_supplement"]) ==
              (doi_url, "DataPipeline.jl", "0.54.1", true)
        @test startswith(source["release_date"], "2026-10-04")
        @test entry(sourced.data_product.url)["external_object"] ==
              sourced.source
        # ... and once it has one, it is not looked up again, and another
        # DOI is refused
        @test archive(nothing).source == sourced.source
        err = @test_throws DataPipeline.ReadWriteException archive(nothing,
                                                                   doi = "10.5281/zenodo.1")
        @test occursin("has the source $doi_url already", err.value.msg)
        # A DOI given that cannot be looked up is an error, and nothing is
        # registered
        unknown = string(LibGit2.commit(zenodo_repo, "unknown",
                                        author = signature,
                                        committer = signature))
        LibGit2.tag_create(zenodo_repo, "v0.54.2", unknown, sig = signature,
                           msg = "v0.54.2")
        err = @test_throws DataPipeline.ReadWriteException archive(nothing,
                                                                   doi = doi,
                                                                   fetch = nothing_to_be_had)
        @test occursin("cannot be looked up, so the release is not registered",
                       err.value.msg)
        @test isnothing(DataPipeline._getentry(registry, "code_repo_release",
                                               Dict("name" => "FAIRDataPipeline/$zenodo_name",
                                                    "version" => "0.54.2")))
        # A DOI given whose metadata is of another version is warned of
        given = @test_logs((:warn,
                            r"the DOI is of version v0.54.1 and the release 0.54.2$"),
                           archive(nothing, doi = doi))
        @test entry(given.source)["identifier"] == doi_url
        # A rehearsal says the source it would attach
        DataPipeline.SESSION[] = DataPipeline.SessionRun(DataPipeline.Rehearsal(mktempdir()),
                                                         mktempdir(), nothing,
                                                         false, nothing)
        rehearsed = string(LibGit2.commit(zenodo_repo, "rehearsed",
                                          author = signature,
                                          committer = signature))
        LibGit2.tag_create(zenodo_repo, "v0.54.3", rehearsed, sig = signature,
                           msg = "v0.54.3")
        said = mktemp() do path, io
            redirect_stdout(io) do
                @test_logs((:warn, r"the DOI is of version v0.54.1"),
                           archive(nothing,
                                   doi = "$(doi)9"))
            end
            close(io)
            return read(path, String)
        end
        DataPipeline._resetsession!()
        @test occursin("  with the source $(doi_url)9", said)
        close(zenodo_repo)

        # A run from a released commit is traced with its release - the
        # highest version on the commit, with its DOI - and one from a commit
        # that is no release without
        datetime = Dates.format(Dates.now(), "yyyymmdd-HHMMSS")
        cpath = joinpath("coderun", datetime, "config.yaml")
        function run_from(clone_dir, remote_url, sha, name)
            config = DataPipeline._createconfig(cpath, latest_commit = sha,
                                                local_repo = clone_dir,
                                                remote_repo = remote_url)
            data_product = "release-trace/$(first(uid, 12))/$name"
            DataPipeline._addwrite(config, data_product, "release trace",
                                   file_type = "txt", use_version = "0.0.1")
            handle = DataPipeline.initialise(config, config)
            write(DataPipeline.link_write!(handle, data_product),
                  "$name $uid\n")
            DataPipeline.finalise(handle)
            namespace = handle.config["run_metadata"]["default_output_namespace"]
            return "$namespace:$data_product@v0.0.1"
        end
        released_output = run_from(zenodo_dir,
                                   "https://github.com/FAIRDataPipeline/$zenodo_name.git",
                                   archived, "released")
        released_trace = DataPipeline.provenance(registry, released_output)
        made = only(values(released_trace.runs))
        # The report names the run's code by its release record, which stands
        # for the repository's object at the commit
        @test made.commit == archived
        @test sourced.object in made.objects
        @test made.release ==
              DataPipeline.TraceRelease("FAIRDataPipeline/$zenodo_name",
                                        v"0.54.1",
                                        "https://github.com/FAIRDataPipeline/$zenodo_name/releases/tag/v0.54.1",
                                        doi_url)
        @test sprint(show, made.release) ==
              "FAIRDataPipeline/$zenodo_name 0.54.1, doi:$doi"
        @test occursin(", FAIRDataPipeline/$zenodo_name 0.54.1, doi:$doi\n",
                       sprint(show, MIME("text/plain"), released_trace))
        # ... the same going forward, from an issue on the released code, which
        # holds the run that the code made its output in
        issue = raise_issue!(registry,
                             DataPipeline.NamedCommit(archived,
                                                      repo = zenodo_dir),
                             "an issue on release 0.54.1 $uid")
        forward = DataPipeline.downstream(registry, issue = issue)
        @test only(values(forward.runs)).release == made.release
        # ... with the release's own data product among what the issue is on
        @test "$(sourced.data_product)" in
              [DataPipeline._dataproductname(product.namespace, product.name,
                                             product.version)
               for product in values(forward.products)]
        # An issue on released code is behind what the code made, as the
        # object of the run's code, whatever releases the object carries
        @test any(found.issue.description == "an issue on release 0.54.1 $uid"
                  for found in DataPipeline._upstreamissues(DataPipeline.provenance(registry,
                                                                                    released_output)))
        # ... and none for a commit that is no release
        unreleased_output = run_from(dir, remote, untagged, "unreleased")
        unreleased = only(values(DataPipeline.provenance(registry,
                                                         unreleased_output).runs))
        @test isnothing(unreleased.release)

        # An issue on the promoted beta's code reaches both its versions on
        # the one object, and warns of no other version holding its bytes
        @test_logs raise_issue!(registry,
                                DataPipeline.NamedCommit(beta_commit,
                                                         repo = dir),
                                "an issue on the promoted beta $uid")

        # identify gives each commit its release: the promoted beta its
        # release, the record's page being the beta's, not shown
        promoted_commit = only(DataPipeline.identify(registry,
                                                     DataPipeline.NamedCommit(beta_commit,
                                                                              repo = dir)).commits)
        @test promoted_commit.release ==
              DataPipeline.TraceRelease("FAIRDataPipeline/$name", v"2.0.0",
                                        nothing, nothing)
        archived_text = sprint(show, MIME("text/plain"),
                               DataPipeline.identify(registry,
                                                     DataPipeline.NamedCommit(archived,
                                                                              repo = zenodo_dir)))
        @test occursin(", release FAIRDataPipeline/$zenodo_name 0.54.1, doi:$doi\n",
                       archived_text)
        @test isnothing(only(DataPipeline.identify(registry,
                                                   DataPipeline.NamedCommit(untagged,
                                                                            repo = dir)).commits).release)
    end
end

end
