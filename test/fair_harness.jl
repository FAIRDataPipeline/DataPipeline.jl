# SPDX-License-Identifier: LGPL-3.0-or-later

# What `Pkg.test(test_args = ["--fair", "fair_harness.jl"])` runs inside the
# tests' own pipeline: a check of the pipeline that `fairrun.jl` builds, not of
# the package - that the run is a `fair run` on a registry of the tests' own,
# in a home of their own, and that a code run reads what was pulled and is
# recorded. Not named `test_*.jl`, so only run when named.

module FairHarness

using DataPipeline
using Test

@testset "the fair harness" begin
    config = DataPipeline._workingconfig(DataPipeline.FDP_PATH_CONFIG())
    # The tests' own registry and home, never the user's: their registry is
    # given a port of its own, not 8000
    @test !occursin(":8000/", config["run_metadata"]["local_data_registry_url"])
    @test startswith(homedir(), DataPipeline._testingspace())
    @test !isnothing(DataPipeline.FDP_LOCAL_TOKEN())
    # The `julia` a script runs is this one, not a launcher
    @test realpath(dirname(Sys.which("julia"))) == realpath(Sys.BINDIR)

    # A code run reads the parameters the harness pulled, and is recorded
    handle = DataPipeline.initialise()
    @test isfile(link_read!(handle, "parameters"))
    DataPipeline.finalise(handle)
    recorded = joinpath(DataPipeline.FDP_CONFIG_DIR(), "coderuns.txt")
    @test handle.code_run_uuid in readlines(recorded)
end

end
