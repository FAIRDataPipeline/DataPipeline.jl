# SPDX-License-Identifier: LGPL-3.0-or-later

module TestTesting

using DataPipeline
using Test

@testset "a test config comes only from a working config" begin
    # Outside `fair run` there is none, and nothing is written anywhere, so a
    # plain run cannot reach the real home's data store or registry
    launch = mktempdir()
    config = joinpath("coderun", "never", "config.yaml")
    withenv("FDP_CONFIG_DIR" => launch) do
        @test_throws DataPipeline.ConfigFileException DataPipeline._createconfig(config)
    end
    # Nor is a user config, which `fair run` has not filled in, a working one
    write(joinpath(launch, "config.yaml"),
          "run_metadata:\n  description: a user config\n")
    withenv("FDP_CONFIG_DIR" => launch) do
        @test_throws DataPipeline.ConfigFileException DataPipeline._createconfig(config)
    end
    @test readdir(launch) == ["config.yaml"]
end

end
