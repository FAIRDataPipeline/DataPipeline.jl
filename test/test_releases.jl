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
end

end
