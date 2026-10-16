# SPDX-License-Identifier: LGPL-3.0-or-later

module TestReleases

using DataPipeline
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
                                                         false)
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
    end
end

end
