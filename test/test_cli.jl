# SPDX-License-Identifier: LGPL-3.0-or-later

module TestCLI

using DataPipeline
using Test

const ReadWriteException = DataPipeline.ReadWriteException

uid = DataPipeline._randomhash()

Test.@testset "fair\"...\"" begin
    # The fair on the path, which the suite runs under, with the text split
    # as a command line is: quoting and interpolation
    @test isnothing(fair"--version")
    flag = "--version"
    @test isnothing(fair"$flag")
    @test isnothing(fair"$(flag)")
    @test isnothing(fair" --version ")
    err = @test_throws ReadWriteException fair"no-such-command --with-option"
    @test occursin("no-such-command --with-option", err.value.msg)
    # A quoted word stays one argument, which the CLI refuses as one
    err = @test_throws ReadWriteException fair"'no such command'"
    @test occursin("no such command", err.value.msg)
end

# Before the copy of fair is installed anew, so that a suite run under a branch
# of the CLI lists its runs with the branch
Test.@testset "code_runs() with the fair the suite runs under" begin
    # The fair the suite runs under, which lists the runs where its help
    # names the option, and is refused where it does not: its version does
    # not say, a branch claiming the release it works towards
    command = DataPipeline._faircommand(nothing)
    help = DataPipeline._capturefair(command, "list", "code-runs", "--help")
    if occursin("--json", help.printed)
        runs = DataPipeline.code_runs()
        @test runs isa Vector{DataPipeline.CodeRunStatus}
        # The run of the example, which the pipeline is set up with, finished
        @test any(run -> run.finished, runs)
        @test issorted(runs, by = run -> run.run_date)
        @test allunique(run.uuid for run in runs)
        @test all(run -> run.on_remote in (nothing, "whole", "part", "none"),
                  runs)
    else
        err = @test_throws ReadWriteException DataPipeline.code_runs()
        @test occursin("fair-cli 0.12.0", err.value.msg)
        @test occursin("--json", err.value.msg)
    end
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
        @test isnothing(fair"--version")
    end

    # set_cli! records a fair that runs, and the record comes first; a path
    # it refuses leaves the record as it was; nothing removes it
    @test DataPipeline.set_cli!(executable) == executable
    try
        @test DataPipeline._preferredcli() == executable
        @test isnothing(fair"--version")
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
    @test isnothing(DataPipeline._cliinstalled().url)

    # A branch: refused with a version, and refused where the repository has
    # none of that name, before anything is installed
    @test_throws ArgumentError DataPipeline.install_cli(version = "0.11.0",
                                                        branch = "Dev")
    err = @test_throws ArgumentError DataPipeline.install_cli(branch = "no-such-branch-$uid")
    @test occursin("no-such-branch-$uid", err.value.msg)
    @test occursin("Dev", err.value.msg)
    @test isnothing(DataPipeline._cliinstalled().url)
    # A branch installed is at its newest commit, and a second call finds it
    # up to date. A branch claiming the release's version, as `Dev` does
    # between releases, is the case pip unforced gets wrong: it would keep the
    # release here, and the branch after. Only where asked for, so that CI
    # tests the released CLI and never waits on a branch
    branch = get(ENV, "FDP_TEST_CLI_BRANCH", "")
    if isempty(branch)
        @info "a branch of the CLI is installed only with FDP_TEST_CLI_BRANCH naming one, such as Dev"
    else
        head = DataPipeline._branchhead(branch)
        try
            @test DataPipeline.install_cli(branch = branch) == executable
            installed = DataPipeline._cliinstalled()
            @test installed.branch == branch
            @test installed.commit == head
            @test occursin("FAIRDataPipeline/FAIR-CLI", installed.url)
            @test DataPipeline.install_cli(branch = branch) == executable
            @test DataPipeline._cliinstalled() == installed
        finally
            @test DataPipeline.install_cli() == executable
        end
        @test isnothing(DataPipeline._cliinstalled().url)
        @test DataPipeline._cliversion() == version
    end
    # Not tested: a change of Python, which fetches another interpreter, and
    # an environment whose interpreter no longer runs, which is rebuilt
end

Test.@testset "cli_installed() and cli_version()" begin
    # The fair the suite runs under
    @test DataPipeline.cli_installed()
    version = DataPipeline.cli_version()
    @test version isa VersionNumber
    said = DataPipeline._capturefair(DataPipeline._faircommand(nothing),
                                     "--version").printed
    @test occursin(replace(string(version), "-" => ""), said)
    if Sys.iswindows()
        @info "the stand-ins for fair are shell scripts: not on Windows"
    else
        # A stand-in for a fair, recorded, that says this of its version
        standin = joinpath(mktempdir(), "fair")
        function saying(text)
            write(standin, "#!/bin/sh\n$text\n")
            return chmod(standin, 0o755)
        end
        saying("echo 'fair, version 0.12.0'")
        DataPipeline.set_cli!(standin)
        try
            @test DataPipeline.cli_installed()
            @test DataPipeline.cli_version() == v"0.12.0"
            # A release candidate is a pre-release, before its release
            saying("echo 'fair, version 0.12.0rc1'")
            @test DataPipeline.cli_version() == v"0.12.0-rc1"
            @test DataPipeline.cli_version() < v"0.12.0"
            # A version Julia does not read, and no version at all
            saying("echo 'fair, version 0.12.0.dev1'")
            err = @test_throws ReadWriteException DataPipeline.cli_version()
            @test occursin("0.12.0.dev1", err.value.msg)
            saying("echo 'something else'")
            err = @test_throws ReadWriteException DataPipeline.cli_version()
            @test occursin("something else", err.value.msg)
            # A fair that is found and does not run
            saying("echo 'no git $uid' >&2; exit 3")
            @test DataPipeline.cli_installed()
            err = @test_throws ReadWriteException DataPipeline.cli_version()
            @test occursin("exit status 3", err.value.msg)
            @test occursin("no git $uid", err.value.msg)
            # A record of a file that is gone is no fair, though one is on
            # the path, as it is for `fair"..."`
            rm(standin)
            @test !isnothing(Sys.which("fair"))
            @test !DataPipeline.cli_installed()
            @test isnothing(DataPipeline.cli_version())
            @test_throws ArgumentError fair"--version"
        finally
            DataPipeline.set_cli!(nothing)
        end
        @test DataPipeline.cli_installed()
    end
    # Not tested: no fair at all, with nothing recorded, none on the path and
    # no copy, since the copy the tests above install is a user's too
end

Test.@testset "code_runs() of what a fair lists" begin
    if Sys.iswindows()
        @info "the stand-ins for fair are shell scripts: not on Windows"
    else
        # A stand-in for a fair, recorded, that answers so whatever it is asked
        standin = joinpath(mktempdir(), "fair")
        function answering(text)
            write(standin, "#!/bin/sh\n$text\n")
            return chmod(standin, 0o755)
        end
        listing = joinpath(mktempdir(), "runs.json")
        write(listing, """
        [{"uuid": "aaaaaaaa-$uid", "run_date": "2026-11-12T13:14:15.123456Z",
          "description": "first $uid", "finished": true, "staged": false,
          "on_remote": "part"},
         {"uuid": "bbbbbbbb-$uid", "run_date": "2026-11-13T01:02:03Z",
          "description": null, "finished": false, "staged": true,
          "on_remote": null}]
        """)
        answering("cat '$listing'")
        DataPipeline.set_cli!(standin)
        try
            first_run, second_run = DataPipeline.code_runs()
            @test first_run.uuid == "aaaaaaaa-$uid"
            @test first_run.run_date ==
                  DataPipeline.Dates.DateTime(2026, 11, 12, 13, 14, 15)
            @test first_run.description == "first $uid"
            @test first_run.finished && !first_run.staged
            @test first_run.on_remote == "part"
            @test second_run.description == ""
            @test !second_run.finished && second_run.staged
            @test isnothing(second_run.on_remote)
            # One line where it may be nested, several alone
            @test sprint(show, first_run) ==
                  "run aaaaaaaa (2026-11-12T13:14:15 UTC, finished, not staged, on origin: part): first $uid"
            @test occursin("on origin: unknown", sprint(show, second_run))
            plain = sprint(show, MIME"text/plain"(), second_run)
            @test occursin("code run bbbbbbbb-$uid\n", plain)
            @test occursin("  finished: no\n  staged: yes\n", plain)
            # No runs is an empty list
            answering("echo '[]'")
            @test isempty(DataPipeline.code_runs())
            # A fair with no such option, as click refuses one
            answering("echo 'Error: No such option: --json' >&2; exit 2")
            err = @test_throws ReadWriteException DataPipeline.code_runs()
            @test occursin("fair-cli 0.12.0", err.value.msg)
            @test occursin(standin, err.value.msg)
            # A listing that fails, and one that is no list of runs
            answering("echo 'not a project $uid' >&2; exit 1")
            err = @test_throws ReadWriteException DataPipeline.code_runs()
            @test occursin("exit status 1", err.value.msg)
            @test occursin("not a project $uid", err.value.msg)
            for printed in ("something else $uid", "{\"uuid\": \"$uid\"}",
                "[\"$uid\"]")
                answering("echo '$printed'")
                err = @test_throws ReadWriteException DataPipeline.code_runs()
                @test occursin(uid, err.value.msg)
            end
        finally
            DataPipeline.set_cli!(nothing)
        end
    end
    # Not tested: what fair writes as errors being printed, and anything
    # on Windows
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

        # A fair with no session commands, which fair-cli has from 0.11.0, is
        # refused, naming the version needed
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
                err = @test_throws ReadWriteException DataPipeline.registry_session(identity)
                @test occursin("has no session commands", err.value.msg)
                @test occursin("fair-cli 0.11.0 or later", err.value.msg)
            end
        finally
            DataPipeline.set_cli!(nothing)
        end
        # A branch installed without them is refused too, saying how to put
        # the release back. A fair with them is not refused, and one failing
        # otherwise is refused for that failure
        err = @test_throws ReadWriteException DataPipeline._checkinstalledbranch(old,
                                                                                 "old-branch")
        @test occursin("branch old-branch", err.value.msg)
        @test occursin("has no session commands", err.value.msg)
        @test occursin("install_cli()", err.value.msg)
        @test isnothing(DataPipeline._checkinstalledbranch(sessions, "new"))
        failing = joinpath(bin, "failing")
        write(failing, "#!/bin/sh\necho 'broken' >&2\nexit 1\n")
        chmod(failing, 0o755)
        err = @test_throws ReadWriteException DataPipeline._checkinstalledbranch(failing,
                                                                                 "broken-branch")
        @test occursin("exit status 1", err.value.msg)
        @test occursin("broken", err.value.msg)
    end
end

Test.@testset "set_cli!() records the fair where the package is" begin
    if Sys.iswindows()
        @info "the stand-in for fair is a shell script: not on Windows"
    else
        # A user's project that does not name DataPipeline, which comes from
        # the suite's own environment stacked behind it, as from a default
        # environment
        user = mktempdir()
        project = """
                  # A user's project
                  [deps]
                  TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"

                  [compat]
                  julia = "1.11"
                  """
        write(joinpath(user, "Project.toml"), project)
        first, standin = joinpath(mktempdir(), "fair"),
                         joinpath(mktempdir(), "fair")
        for file in (first, standin)
            write(file, "#!/bin/sh\necho \"fair, version 9.9.9\"\n")
            chmod(file, 0o755)
        end
        stacked = dirname(Base.active_project())
        # What a Julia in the user's project prints, running `code`
        function in_user_project(code)
            command = `$(Base.julia_cmd()) --startup-file=no --project=$user -e $code`
            return read(addenv(command,
                               "JULIA_LOAD_PATH" => "@:$stacked:@stdlib"),
                        String)
        end
        try
            # One recorded, then another in its place: in the suite's
            # environment, the user's project left as it was
            in_user_project("using DataPipeline; DataPipeline.set_cli!($(repr(first))); DataPipeline.set_cli!($(repr(standin)))")
            @test read(joinpath(user, "Project.toml"), String) == project
            @test !isfile(joinpath(user, "LocalPreferences.toml"))
            @test DataPipeline._preferredcli() == standin
            # ... and read in the user's project by a later session
            @test in_user_project("using DataPipeline; print(DataPipeline._preferredcli())") ==
                  standin
        finally
            in_user_project("using DataPipeline; DataPipeline.set_cli!(nothing)")
        end
        @test isnothing(DataPipeline._preferredcli())
        @test read(joinpath(user, "Project.toml"), String) == project
    end
end

Test.@testset "a fair interrupted ends with its job" begin
    # A stand-in for a `fair run`: a Julia process waiting for a job of its
    # own, a Julia process that writes its id where it is told and waits
    dir = mktempdir()
    write(joinpath(dir, "job.jl"),
          "write(ARGS[1], string(getpid())); sleep(120)\n")
    write(joinpath(dir, "fair.jl"),
          "run(`\$(Base.julia_cmd()) --startup-file=no \$(joinpath(@__DIR__, \"job.jl\")) \$(ARGS[2])`)\n")
    standin = `$(Base.julia_cmd()) --startup-file=no $(joinpath(dir, "fair.jl"))`
    # Whether a process of this id is running
    function running(pid)
        Sys.iswindows() &&
            return occursin(string(pid),
                            read(`tasklist /FI "PID eq $pid" /NH`, String))
        return ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
    end
    # The id the job writes, once it has
    function jobid(file)
        @test timedwait(() -> isfile(file) && !isempty(read(file, String)),
                        120.0) === :ok
        return parse(Int, read(file, String))
    end

    # Ended as Julia's exit ends it: the job with it, nothing left recorded,
    # and the call an error
    file = joinpath(dir, "ended.pid")
    call = @async try
        DataPipeline._fair("run", file, cli = standin)
    catch err
        err
    end
    job = jobid(file)
    @test running(job)
    DataPipeline._endfair(only(DataPipeline.RUNNING_FAIR))
    @test timedwait(() -> !running(job), 30.0) === :ok
    @test fetch(call) isa ReadWriteException
    @test isempty(DataPipeline.RUNNING_FAIR)

    if Sys.iswindows()
        @info "an interrupt is a signal elsewhere than on Windows: not tried there"
    else
        # A stand-in whose job ignores SIGTERM is made to end after a few
        # seconds
        write(joinpath(dir, "stubborn.sh"),
              "trap '' TERM\nprintf %s \$\$ > \"\$2\"\nsleep 120\n")
        stubborn = `sh $(joinpath(dir, "stubborn.sh"))`
        file = joinpath(dir, "stubborn-ended.pid")
        call = @async try
            DataPipeline._fair("run", file, cli = stubborn)
        catch err
            err
        end
        job = jobid(file)
        DataPipeline._endfair(only(DataPipeline.RUNNING_FAIR))
        @test timedwait(() -> !running(job), 30.0) === :ok
        @test fetch(call) isa ReadWriteException

        # A Julia running `code`, interrupted once the job it starts has
        # written its id to `file`: what it printed, and the job's id. What it
        # prints goes to a file, since a pipe would be held open by the job it
        # hands its output to, and waiting for the Julia would wait for the job
        stacked = dirname(Base.active_project())
        function interrupting(code, file, name)
            output = joinpath(dir, "$name.out")
            interrupted = run(pipeline(addenv(`$(Base.julia_cmd()) --startup-file=no -e $code`,
                                              "JULIA_LOAD_PATH" => "@:$stacked:@stdlib"),
                                       stdout = output, stderr = devnull),
                              wait = false)
            job = jobid(file)
            kill(interrupted, Base.SIGINT)
            wait(interrupted)
            return (printed = read(output, String), job)
        end

        # Interrupted in the REPL as `fair` starts, before it is recorded -
        # here `started` pauses there - the interrupt is held until it is, so
        # that the job ends. Removing the hold alone is not caught: beyond
        # this it covers the gap inside `run`, which no pause reaches
        write(joinpath(dir, "prompt.sh"),
              "printf %s \$\$ > \"\$2\"\nsleep 120\n")
        file = joinpath(dir, "starting.pid")
        starting = `sh $(joinpath(dir, "prompt.sh")) run $file`
        code = """
               using DataPipeline
               Base.exit_on_sigint(false)
               try
                   DataPipeline._runfair($(repr(starting)),
                                         started = () -> Libc.systemsleep(5))
               catch err
                   print(DataPipeline._interrupted(err))
               end
               """
        found = interrupting(code, file, "starting")
        @test found.printed == "true"
        @test timedwait(() -> !running(found.job), 30.0) === :ok

        # A Julia running a stand-in through fair"...", interrupted while it
        # waits: as in the REPL, where an interrupt is an exception, rethrown
        # as one, and as a script, which exits; the job ends either way, the
        # stubborn one too, though from Julia 1.14 the cleanup after an
        # interrupt is in a cancelled scope
        if VERSION < v"1.12"
            @info "Julia 1.11 delivers no interrupt to a task waiting for a process: an interrupted fair\"...\" is not tried there"
        else
            for (repl, name, cli) in ((true, "repl", standin),
                (false, "script", standin), (true, "stubborn", stubborn))
                file = joinpath(dir, "$name.pid")
                code = """
                       using DataPipeline
                       Base.exit_on_sigint($(!repl))
                       try
                           DataPipeline._fair("run", $(repr(file)), cli = $(repr(cli)))
                       catch err
                           print(DataPipeline._interrupted(err))
                       end
                       """
                found = interrupting(code, file, name)
                repl && @test found.printed == "true"
                @test timedwait(() -> !running(found.job), 30.0) === :ok
            end
        end
    end
end

end
