# SPDX-License-Identifier: LGPL-3.0-or-later

module TestCLI

using DataPipeline
using Test

const ReadWriteException = DataPipeline.ReadWriteException

uid = DataPipeline._randomhash()

Test.@testset "DataPipeline.fair\"...\"" begin
    # The fair on the path, which the suite runs under, with the text split
    # as a command line is: quoting and interpolation
    @test isnothing(DataPipeline.fair"--version")
    flag = "--version"
    @test isnothing(DataPipeline.fair"$flag")
    @test isnothing(DataPipeline.fair"$(flag)")
    @test isnothing(DataPipeline.fair" --version ")
    err = @test_throws ReadWriteException DataPipeline.fair"no-such-command --with-option"
    @test occursin("no-such-command --with-option", err.value.msg)
    # A quoted word stays one argument, which the CLI refuses as one
    err = @test_throws ReadWriteException DataPipeline.fair"'no such command'"
    @test occursin("no such command", err.value.msg)
end

Test.@testset "install_cli()" begin
    # The copy is installed from the network, with its Python, into the
    # package's own scratch space, where a user has it too
    executable = DataPipeline.install_cli()
    @test isfile(executable)
    @test executable == DataPipeline._installedcli()
    @test DataPipeline._clipythonversion(DataPipeline._clifolder()) ==
          DataPipeline.CLI_PYTHON
    version = DataPipeline._cliversion()
    @test occursin(r"\d+\.\d+\.\d+", version)
    # Run again, the copy is up to date, and the call quick
    @test DataPipeline.install_cli() == executable
    # The copy runs
    @test isnothing(DataPipeline._fair("--version", cli = executable))
    # ... and is the second place looked: after the path, before FDP_FAIR_CLI.
    # The path keeps everything but fair, since the CLI needs git on it
    separator = Sys.iswindows() ? ';' : ':'
    without_fair = join(filter(dir -> isnothing(Sys.which(joinpath(dir,
                                                                   "fair"))),
                               split(ENV["PATH"], separator)), separator)
    withenv("PATH" => without_fair,
            "FDP_FAIR_CLI" => joinpath(tempdir(), "missing-$uid")) do
        @test isnothing(Sys.which("fair"))
        @test isnothing(DataPipeline.fair"--version")
    end
    # A version asked for is the one installed, and the newest brought back
    DataPipeline.install_cli(version = "0.10.2")
    @test occursin("0.10.2", DataPipeline._cliversion())
    @test DataPipeline.install_cli() == executable
    @test DataPipeline._cliversion() == version
    # Not tested: a change of Python, which fetches another interpreter, and
    # an environment whose interpreter no longer runs, which is rebuilt
end

end
