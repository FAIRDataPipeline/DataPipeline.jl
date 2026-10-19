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

Test.@testset "install_cli(), set_cli!() and install_cli!()" begin
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
    # The copy runs, with its own git and nothing else on the path
    @test isfile(DataPipeline._cligit(DataPipeline._clifolder()))
    @test isnothing(DataPipeline._fair("--version", cli = executable))
    withenv("PATH" => "") do
        @test isnothing(DataPipeline._fair("--version", cli = executable))
    end

    # With nothing recorded and fair off the path, the copy is the fair run.
    # The path keeps everything but fair, since the CLI needs git on it
    @test isnothing(DataPipeline._preferredcli())
    separator = Sys.iswindows() ? ';' : ':'
    without_fair = join(filter(dir -> isnothing(Sys.which(joinpath(dir,
                                                                   "fair"))),
                               split(ENV["PATH"], separator)), separator)
    withenv("PATH" => without_fair) do
        @test isnothing(Sys.which("fair"))
        @test isnothing(DataPipeline.fair"--version")
    end

    # set_cli! records a fair that runs, and the record comes first; a path
    # it refuses leaves the record as it was; nothing removes it
    @test DataPipeline.set_cli!(executable) == executable
    try
        @test DataPipeline._preferredcli() == executable
        @test isnothing(DataPipeline.fair"--version")
        @test_throws ArgumentError DataPipeline.set_cli!(joinpath(tempdir(),
                                                                  "missing-$uid"))
        @test DataPipeline._preferredcli() == executable
    finally
        @test isnothing(DataPipeline.set_cli!(nothing))
    end
    @test isnothing(DataPipeline._preferredcli())

    # install_cli! installs, or finds the copy installed, and records it
    @test DataPipeline.install_cli!() == executable
    @test DataPipeline._preferredcli() == executable
    DataPipeline.set_cli!(nothing)

    # A version asked for is the one installed, and the newest brought back
    DataPipeline.install_cli(version = "0.10.2")
    @test occursin("0.10.2", DataPipeline._cliversion())
    @test DataPipeline.install_cli() == executable
    @test DataPipeline._cliversion() == version
    # Not tested: a change of Python, which fetches another interpreter, and
    # an environment whose interpreter no longer runs, which is rebuilt
end

Test.@testset "registry_session() and the registry outside a run" begin
    if Sys.iswindows()
        @info "the stand-ins for fair are shell scripts: not on Windows"
    else
        # A stand-in for a fair with the session commands, logging each call,
        # its session naming the suite's own registry and a file of its token
        bin = mktempdir()
        calls_file = joinpath(bin, "calls")
        token_file = joinpath(bin, "token")
        write(token_file, ENV["FDP_LOCAL_TOKEN"] * "\n")
        url = DataPipeline.RegistryEndpoint().url
        sessions = joinpath(bin, "fair")
        write(sessions,
              """
              #!/bin/sh
              echo "\$*" >> $calls_file
              case "\$1 \$2 \$3" in
                "registry session open")
                  echo '{"session": "s1", "registry_url": "$url", "token_file": "$token_file"}' ;;
                "registry session close") ;;
                *) echo "fair, version 9.9.9" ;;
              esac
              """)
        chmod(sessions, 0o755)
        calls() = isfile(calls_file) ? readlines(calls_file) : String[]
        opening = "registry session open --pid $(getpid()) --json"
        unregistered = joinpath(bin, "unregistered.txt")
        write(unregistered, "registered nowhere $uid\n")
        config = DataPipeline._createconfig(joinpath("coderun",
                                                     "cli-session-$uid",
                                                     "config.yaml"))
        @test DataPipeline.set_cli!(sessions) == sessions
        # Recording the stand-in asks its version, which is no session call
        rm(calls_file)
        # A session's endpoint is the address and token it names, not the
        # configuration's
        named = DataPipeline._heldendpoint(DataPipeline.RegistryHeldBySession("s0",
                                                                              Cmd([sessions]),
                                                                              "http://example.org/api",
                                                                              token_file))
        @test named.url == "http://example.org/api/"
        @test named.token == ENV["FDP_LOCAL_TOKEN"]
        try
            withenv("FDP_SESSION" => nothing) do
                # The block is given the registry the session names, with
                # the token its file holds, and the session closes when the
                # block returns, or throws
                found = DataPipeline.registry_session() do registry
                    @test calls() == [opening]
                    @test registry.url == url
                    @test registry.token == ENV["FDP_LOCAL_TOKEN"]
                    return 42
                end
                @test found == 42
                @test calls() == [opening, "registry session close s1"]
                @test_throws ErrorException DataPipeline.registry_session() do _
                    return error("inside the block")
                end
                @test calls()[end] == "registry session close s1"

                # A function outside a run given no endpoint holds a session
                # for the call
                before = length(calls())
                @test isempty(DataPipeline.identify(unregistered).objects)
                @test calls()[(before + 1):end] ==
                      [opening, "registry session close s1"]

                # A run initialise() opens outside fair run, as in a job that
                # `fair run --ci` prepared, holds one until finalise
                before = length(calls())
                handle = DataPipeline.initialise(config, config)
                @test calls()[(before + 1):end] == [opening]
                DataPipeline.finalise(handle)
                @test calls()[end] == "registry session close s1"
            end
            # Under fair run, whose own session holds the registry, nothing is
            # opened, and the block has the configuration's registry
            withenv("FDP_SESSION" => "the-run") do
                before = length(calls())
                DataPipeline.registry_session() do registry
                    @test registry.url == url
                end
                DataPipeline._resetsession!()
                DataPipeline.finalise(DataPipeline.initialise(config, config))
                @test length(calls()) == before
            end
        finally
            DataPipeline.set_cli!(nothing)
        end

        # A fair with no session commands is asked once, and the block has the
        # configuration's registry
        old = joinpath(bin, "old")
        write(old,
              "#!/bin/sh\necho \"\$*\" >> $calls_file\n" *
              "[ \"\$1 \$2\" = \"registry session\" ] && " *
              "{ echo \"Error: No such command 'session'.\" >&2; exit 2; }\n" *
              "echo \"fair, version 0.10.2\"\n")
        chmod(old, 0o755)
        @test DataPipeline.set_cli!(old) == old
        try
            withenv("FDP_SESSION" => nothing) do
                before = length(calls())
                for _ in 1:2
                    DataPipeline.registry_session() do registry
                        @test registry.url == url
                    end
                end
                @test length(calls()) == before + 1
            end
        finally
            DataPipeline.set_cli!(nothing)
        end
    end
end

end
