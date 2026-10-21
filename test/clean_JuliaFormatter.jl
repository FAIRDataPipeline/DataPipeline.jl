# SPDX-License-Identifier: LGPL-3.0-or-later

# Every Julia file of the repository must be as the formatter, with
# `.JuliaFormatter.toml`, would write it.

module CleanJuliaFormatter

using Test
using DataPipeline
using Git
using JuliaFormatter

include("GitUtils.jl")
using .GitUtils

@testset "JuliaFormatter" begin
    git_dir = readchomp(`$(Git.git()) rev-parse --show-toplevel`)
    @test_nowarn format(DataPipeline)
    @test is_repo_clean(git_dir, strict = haskey(ENV, "RUNNER_OS"))
end

end
