# SPDX-License-Identifier: LGPL-3.0-or-later

# The repository's metadata - `Project.toml`, `codemeta.json`, `LICENSE` and
# the licence line of every Julia file - must be as ResearchSoftwareMetadata's
# crosswalk would write it, so that a version cannot be released with its
# `codemeta.json` left behind. The crosswalk asks orcid.org, ror.org and
# General, so this needs the network.

module CleanRSMD

using Test
using Git
using Logging
using ResearchSoftwareMetadata

include("GitUtils.jl")
using .GitUtils

@testset "RSMD" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    # `@test_logs`, not `@test_nowarn`: the crosswalk's warnings are log
    # records, which `@test_nowarn` sees only as stderr, and so not at all
    # under a logger holding a stream of its own
    cd(git_dir) do
        @test_logs min_level=Logging.Warn ResearchSoftwareMetadata.crosswalk(git_dir)
    end
    @test is_repo_clean(git_dir, strict = haskey(ENV, "RUNNER_OS"))
end

end
