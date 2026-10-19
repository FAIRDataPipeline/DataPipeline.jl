# SPDX-License-Identifier: LGPL-3.0-or-later

module TestRehearse

using DataPipeline
using Dates
using Test

const URIs = DataPipeline.URIs
const Rehearsal = DataPipeline.Rehearsal
const RecordedRun = DataPipeline.RecordedRun
const ConfigFileException = DataPipeline.ConfigFileException
const ReadWriteException = DataPipeline.ReadWriteException

uid = DataPipeline._randomhash()
datetime = Dates.format(Dates.now(), "yyyymmdd-HHMMSS")
config = DataPipeline._createconfig(joinpath("coderun", datetime,
                                             "rehearse.yaml"))
launch = DataPipeline.initialise(config, config)
registry = launch.registry
datastore = launch.config["run_metadata"]["write_data_store"]
namespace = launch.config["run_metadata"]["default_output_namespace"]

# The session's rehearsal, which each test below ends, leaving none for the
# next
current() = DataPipeline.SESSION[]

# A folder laid out like a job folder, holding a working config made from the
# launch config, under the data store but not under its jobs/
function job_folder(name::AbstractString)
    path = DataPipeline._createconfig(joinpath("coderun", datetime,
                                               "rehearse-$name",
                                               "config.yaml"))
    return dirname(path)
end

# How many rows the registry holds in each table a rehearsal must leave alone
tables = ("code_run", "data_product", "object", "storage_location",
          "object_component", "external_object", "author", "issue",
          "namespace")
function counts()
    return Dict(table => DataPipeline._getentry(registry,
                                       URIs.URI(string(registry.url,
                                                       table,
                                                       "/")))["count"]
                for table in tables)
end

# A file of this text, outside the data store
outside = mktempdir()
function file_of(text::AbstractString)
    path = joinpath(outside, "$(DataPipeline._randomhash()).txt")
    write(path, text)
    return path
end

# A deposit cited by a DOI that belongs to this file alone, with an author
# whose identifier the registry lacks
doi = "10.5555/rehearsal.$uid"
person = "Rehearsal Person $uid"
orcid = "https://orcid.org/$(uid[1:16])"
citations = """
@dataset{deposit,
  author = {{Person $uid}, Rehearsal},
  title = {A rehearsed deposit $uid},
  date = {2022-05-06},
  doi = {$doi},
  version = {1.0}
}
"""

Test.@testset "rehearse() and a rehearsal's finalise" begin
    job = job_folder("main")
    working = joinpath(job, "config.yaml")
    whole = "rehearse/whole/$uid"
    estimate = "rehearse/estimate/$uid"
    again = "rehearse/parameters-again/$uid"
    deposit = "rehearse/deposit/$uid"
    external = "rehearse/external/$uid"
    DataPipeline._addread(working, "parameters",
                          use_data_product = "SEIRS_model/parameters",
                          use_namespace = "PSU", use_version = "1.0.0")
    DataPipeline._addwrite(working, whole, "a rehearsed file",
                           file_type = "txt", use_version = "0.0.1")
    DataPipeline._addwrite(working, estimate, "a rehearsed estimate",
                           file_type = "toml", use_version = "0.0.1")
    DataPipeline._addwrite(working, again, "the parameters again",
                           file_type = "csv",
                           use_data_product = "SEIRS_model/parameters",
                           use_namespace = "PSU", use_version = "1.0.1")
    outputs = mktempdir()
    before = counts()

    # The session holds the rehearsal from here: its folders, no handle yet
    @test DataPipeline.rehearse(job, outputs = outputs) == job
    @test current().job == job
    @test current().mode.outputs == outputs
    @test isnothing(current().handle)

    # A rehearsal handle: no token, whatever the environment holds, and
    # nothing registered
    @test haskey(ENV, "FDP_LOCAL_TOKEN")
    handle = DataPipeline.initialise()
    @test handle isa DataPipeline.DataRegistryHandle{Rehearsal}
    @test current().handle === handle
    @test handle.mode.outputs == outputs
    @test isnothing(handle.registry.token)
    @test isnothing(handle.code_run_obj) && isnothing(handle.config_obj)
    @test occursin("rehearsal", sprint(show, handle))
    @test occursin("registering nothing",
                   sprint(show, MIME("text/plain"), handle))
    @test counts() == before

    # Reads and writes go as they would
    parameters = link_read!(handle, "parameters")
    @test isfile(parameters)
    path = link_write!(handle, whole)
    @test startswith(basename(path), "dat-")
    write(path, "a rehearsed file $uid\n")
    @test write_estimate!(handle, 4.2, estimate, "point",
                          "a rehearsed estimate") == (estimate, "point")
    copied = link_write!(handle, again)
    cp(parameters, copied, force = true)
    raise_issue!(handle, whole, "a rehearsed issue $uid")

    # What registers at the call registers nothing: an author, a deposit
    # with no file and a file from elsewhere, the file given back as it is
    register_citations!(handle, citations)
    @test register_authors!(handle, person => orcid) == [person]
    @test isnothing(link_register!(handle, deposit, bibtex = "deposit",
                                   primary = true))
    file = file_of("a rehearsed external file $uid")
    @test link_register!(handle, external, path = file,
                         bibtex = "deposit", primary = true,
                         title = "An external file $uid") == file
    @test handle.inputs[(external, nothing)]["path"] == file
    @test isnothing(handle.inputs[(external, nothing)]["component_url"])
    @test counts() == before

    # finalise collects the outputs by namespace, name and version, the
    # unchanged one too, with the working config beside them, registers
    # nothing, and ends the session's rehearsal
    @test DataPipeline.finalise(handle) == outputs
    placed = joinpath(outputs, namespace, whole, "0.0.1.txt")
    @test read(placed, String) == "a rehearsed file $uid\n"
    @test handle.outputs[(whole, nothing)]["path"] == placed
    @test isfile(joinpath(outputs, namespace, estimate, "0.0.1.toml"))
    @test isfile(joinpath(outputs, "PSU", "SEIRS_model", "parameters",
                          "1.0.1.csv"))
    @test haskey(handle.unchanged, (again, nothing))
    @test !haskey(handle.outputs, (again, nothing))
    @test isfile(joinpath(outputs, "config.yaml"))
    @test !isfile(path)
    @test !isfile(copied)
    @test counts() == before
    @test current().ended
    # The job folder is not under jobs/, so it stays
    @test isfile(working)

    # A finalised handle cannot be finalised again, and the rehearsal that
    # has ended opens no other handle: rehearse again
    err = @test_throws ReadWriteException DataPipeline.finalise(handle)
    @test occursin("ended", err.value.msg)
    err = @test_throws ReadWriteException DataPipeline.initialise()
    @test occursin("rehearse again", err.value.msg)
end

Test.@testset "a rehearsal writing a version that exists" begin
    versioned = "rehearse/versions/$uid"
    placed = "rehearse/placed/$uid"
    # Two versions of a name, recorded
    for (version, text) in (("0.0.1", "first"), ("0.0.2", "second"))
        config = DataPipeline._createconfig(joinpath("coderun", datetime,
                                                     "rehearse-versions",
                                                     "$version.yaml"))
        DataPipeline._addwrite(config, versioned, "a recorded version",
                               file_type = "txt", use_version = version)
        recorded = DataPipeline.initialise(config, config)
        write(link_write!(recorded, versioned), "$text $uid\n")
        DataPipeline.finalise(recorded)
    end
    # A rehearsal that writes the first version again, with a new file whose
    # label sorts before it, which finalise places first
    function rehearsing(name)
        job = job_folder(name)
        working = joinpath(job, "config.yaml")
        DataPipeline._addwrite(working, "reproduced", "the first version",
                               file_type = "txt", use_data_product = versioned,
                               use_version = "0.0.1")
        DataPipeline._addwrite(working, "placed", "a new file",
                               file_type = "txt", use_data_product = placed,
                               use_version = "0.0.1")
        DataPipeline.rehearse(job, outputs = mktempdir())
        handle = DataPipeline.initialise()
        write(link_write!(handle, "placed"), "placed $name $uid\n")
        return handle
    end
    before = counts()

    # The same bytes are a reproduction, though not of the highest version,
    # placed as that version
    handle = rehearsing("reproduced")
    write(link_write!(handle, "reproduced"), "first $uid\n")
    DataPipeline.finalise(handle)
    @test haskey(handle.unchanged, ("reproduced", nothing))
    @test read(joinpath(handle.mode.outputs, namespace, versioned, "0.0.1.txt"),
               String) == "first $uid\n"
    @test isfile(joinpath(handle.mode.outputs, namespace, placed, "0.0.1.txt"))

    # Other bytes are refused at finalise, before anything is placed, leaving
    # the rehearsal to be discarded
    handle = rehearsing("changed")
    write(link_write!(handle, "reproduced"), "second $uid\n")
    err = @test_throws ReadWriteException DataPipeline.finalise(handle)
    @test startswith(err.value.msg,
                     "$namespace:$versioned@v0.0.1 is registered already")
    @test isempty(readdir(handle.mode.outputs))
    @test !current().ended
    DataPipeline.discard(handle)
    @test counts() == before
end

Test.@testset "a rehearsal repeated into the same folder replaces its files" begin
    job = job_folder("again")
    working = joinpath(job, "config.yaml")
    whole = "rehearse/replaced/$uid"
    DataPipeline._addwrite(working, whole, "a rehearsed file",
                           file_type = "txt", use_version = "0.0.1")
    outputs = mktempdir()
    placed = joinpath(outputs, namespace, whole, "0.0.1.txt")
    for text in ("first $uid\n", "second $uid\n")
        DataPipeline.rehearse(job, outputs = outputs)
        handle = DataPipeline.initialise()
        write(link_write!(handle, whole), text)
        @test DataPipeline.finalise(handle) == outputs
        @test read(placed, String) == text
    end
end

Test.@testset "discard()" begin
    job = job_folder("discard")
    working = joinpath(job, "config.yaml")
    whole = "rehearse/discarded/$uid"
    DataPipeline._addwrite(working, whole, "a discarded file",
                           file_type = "txt", use_version = "0.0.1")
    outputs = mktempdir()
    before = counts()
    DataPipeline.rehearse(job, outputs = outputs)
    handle = DataPipeline.initialise()
    path = link_write!(handle, whole)
    write(path, "a discarded file $uid\n")
    @test isnothing(DataPipeline.discard(handle))
    @test !isfile(path)
    @test !isdir(dirname(path))
    @test isempty(readdir(outputs))
    @test isempty(handle.outputs)
    @test current().ended
    @test counts() == before
    # Discarded again, it has nothing to do
    @test isnothing(DataPipeline.discard(handle))

    # A recorded run is registered already
    err = @test_throws ReadWriteException DataPipeline.discard(launch)
    @test occursin("finalise", err.value.msg)
end

Test.@testset "a second rehearse(), and restart = true" begin
    job = job_folder("restart")
    working = joinpath(job, "config.yaml")
    whole = "rehearse/restarted/$uid"
    DataPipeline._addwrite(working, whole, "a restarted file",
                           file_type = "txt", use_version = "0.0.1")
    other = job_folder("restart-other")

    # Prepared but never opened: a second rehearse refuses, and with restart
    # discards it - its job folder, not being under jobs/, stays
    DataPipeline.rehearse(job)
    err = @test_throws ReadWriteException DataPipeline.rehearse(other)
    @test occursin(job, err.value.msg)
    @test occursin("restart = true", err.value.msg)
    @test current().job == job
    @test DataPipeline.rehearse(other, restart = true) == other
    @test current().job == other
    @test isfile(working)

    # Opened and written to: restart removes what was written
    DataPipeline.rehearse(job, restart = true)
    handle = DataPipeline.initialise()
    path = link_write!(handle, whole)
    write(path, "restarted $uid\n")
    @test DataPipeline.rehearse(other, restart = true) == other
    @test !isfile(path)
    @test isempty(handle.outputs)
    @test isnothing(current().handle)
    DataPipeline._discardcurrent()
    @test isnothing(current())
end

Test.@testset "initialise() once per rehearsal" begin
    job = job_folder("once")
    working = joinpath(job, "config.yaml")
    whole = "rehearse/once/$uid"
    DataPipeline._addwrite(working, whole, "a file written once",
                           file_type = "txt", use_version = "0.0.1")
    outputs = mktempdir()
    DataPipeline.rehearse(job, outputs = outputs)
    handle = DataPipeline.initialise()
    path = link_write!(handle, whole)
    write(path, "once $uid\n")

    # The script run again by mistake: the open handle stays, and the error
    # says what to do
    err = @test_throws ReadWriteException DataPipeline.initialise()
    @test occursin("restart = true", err.value.msg)
    @test current().handle === handle
    @test isfile(path)
    @test DataPipeline.finalise(handle) == outputs
    # Ended, the rehearsal opens no other: rehearse again, which needs no
    # restart
    err = @test_throws ReadWriteException DataPipeline.initialise()
    @test occursin("rehearse again", err.value.msg)
    DataPipeline.rehearse(job, outputs = outputs)
    again = DataPipeline.initialise()
    @test current().handle === again
    write(link_write!(again, whole), "again $uid\n")
    @test DataPipeline.finalise(again) == outputs
    @test read(joinpath(outputs, namespace, whole, "0.0.1.txt"), String) ==
          "again $uid\n"
end

Test.@testset "what rehearse() accepts" begin
    # A refused call leaves the session's run, ended by the test before, as
    # it is
    before = current()
    @test_throws ArgumentError DataPipeline.rehearse(joinpath(outside,
                                                              "nowhere"))
    # A folder with no config.yaml
    @test_throws ArgumentError DataPipeline.rehearse(outside)
    # A user config outside any project, so that fair cannot prepare it
    user = joinpath(outside, "user.yaml")
    DataPipeline.YAML.write_file(user,
                                 Dict("run_metadata" =>
                                          Dict("description" => "A user config",
                                               "script" => "julia script.jl")))
    err = @test_throws ArgumentError DataPipeline.rehearse(user)
    @test occursin("fair init", err.value.msg)
    @test current() === before
    # A working config is taken as its folder, and the default outputs folder
    # is a new temporary one. That it outlives the session (made with
    # `cleanup = false`) is not tested here: it would take a second process
    job = job_folder("config")
    @test DataPipeline.rehearse(joinpath(job, "config.yaml")) == job
    @test current().job == job
    folder = current().mode.outputs
    @test isdir(folder)
    @test startswith(basename(folder), "fdp-rehearsal-")
    DataPipeline._discardcurrent()
    @test isnothing(current())
end

# A user config inside the project, as a user's would be, reading the SEIRS
# parameters and writing one text file, its script run by `shell` where one is
# given
function user_config(name::AbstractString, data_product::AbstractString;
                     shell = nothing, script = "julia script.jl")
    path = joinpath(pwd(), "rehearse-$name-$uid.yaml")
    run_metadata = Dict("description" => "A rehearsed run $uid",
                        "script" => script,
                        "default_input_namespace" => "testing",
                        "default_output_namespace" => "testing")
    isnothing(shell) || (run_metadata["shell"] = shell)
    DataPipeline.YAML.write_file(path,
                                 Dict("run_metadata" => run_metadata,
                                      "read" =>
                                          [Dict("data_product" => "parameters",
                                                "use" =>
                                                    Dict("namespace" => "PSU",
                                                         "data_product" => "SEIRS_model/parameters"))],
                                      "write" =>
                                          [Dict("data_product" => data_product,
                                                "description" => "a file rehearsed through fair",
                                                "file_type" => "txt")]))
    return path
end

Test.@testset "rehearse() from a user config, through fair" begin
    name = "rehearse/via-fair/$uid"
    user = user_config("fair", name)
    outputs = mktempdir()
    before = counts()
    # A fair with `fair run --rehearse` stages nothing; one without, preparing
    # the job with `fair run --ci`, adds it to the project's staging
    staging = joinpath(DataPipeline._fairroot(pwd()), ".fair", "staging")
    staged() = isfile(staging) ? read(staging, String) : ""
    staged_before = staged()
    rehearses = occursin("--rehearse",
                         read(DataPipeline._withenvironment(`$(DataPipeline._faircommand(nothing)) run --help`),
                              String))
    # fair prepares the job under the data store's jobs/
    job = DataPipeline.rehearse(user, outputs = outputs, local_only = true)
    rehearses && @test staged() == staged_before
    @test isdir(job)
    @test !startswith(relpath(job, joinpath(datastore, "jobs")), "..")
    @test isfile(joinpath(job, "config.yaml"))
    @test current().job == job
    handle = DataPipeline.initialise()
    @test handle isa DataPipeline.DataRegistryHandle{Rehearsal}
    @test isfile(link_read!(handle, "parameters"))
    write(link_write!(handle, name), "rehearsed through fair $uid\n")
    @test DataPipeline.finalise(handle) == outputs
    @test read(joinpath(outputs, "testing", name, "0.0.1.txt"), String) ==
          "rehearsed through fair $uid\n"
    # The job folder, being under jobs/, is deleted
    @test !isdir(job)
    @test current().ended
    @test counts() == before

    # Prepared twice: restart deletes the first job folder, under jobs/
    first = DataPipeline.rehearse(user, local_only = true)
    second = DataPipeline.rehearse(user, local_only = true, restart = true)
    @test !isdir(first)
    @test isdir(second)
    DataPipeline._discardcurrent()
    @test !isdir(second)
    @test isnothing(current())
    rm(user)
end

Test.@testset "rehearse() of a script in another shell, through fair" begin
    name = "rehearse/via-fair-julia/$uid"
    user = user_config("julia", name, shell = "julia",
                       script = "println(\"a rehearsed Julia script $uid\")\n")
    outputs = mktempdir()
    # fair writes the script as script.jl, which the working config names
    job = DataPipeline.rehearse(user, outputs = outputs, local_only = true)
    @test isfile(joinpath(job, "script.jl"))
    handle = DataPipeline.initialise()
    write(link_write!(handle, name), "rehearsed in another shell $uid\n")
    @test DataPipeline.finalise(handle) == outputs
    @test occursin("a rehearsed Julia script $uid",
                   read(joinpath(outputs, "script.jl"), String))
    rm(user)
end

Test.@testset "rehearse() through the package's copy of fair" begin
    # Installed by the tests of cli.jl, which run before these; recorded by
    # set_cli!, it is the fair used whatever the path holds
    copy = DataPipeline._installedcli()
    @test !isnothing(copy)
    name = "rehearse/via-copy/$uid"
    user = user_config("copy", name)
    outputs = mktempdir()
    @test DataPipeline.set_cli!(copy) == copy
    try
        job = DataPipeline.rehearse(user, outputs = outputs,
                                    local_only = true)
        @test isfile(joinpath(job, "config.yaml"))
        handle = DataPipeline.initialise()
        write(link_write!(handle, name), "rehearsed through the copy $uid\n")
        @test DataPipeline.finalise(handle) == outputs
        @test isfile(joinpath(outputs, "testing", name, "0.0.1.txt"))
    finally
        DataPipeline.set_cli!(nothing)
    end
    rm(user)
end

# What a stand-in for a fair with neither session commands nor `fair run
# --rehearse` says to them, as such a fair does: a usage error
no_sessions = "[ \"\$1 \$2\" = \"registry session\" ] && " *
              "{ echo \"Error: No such command 'session'.\" >&2; exit 2; }\n" *
              "[ \"\$1 \$2\" = \"run --rehearse\" ] && " *
              "{ echo \"Error: No such option '--rehearse'.\" >&2; exit 2; }\n"

# What `f` prints
function printed_by(f::Function)
    return mktemp() do path, io
        redirect_stdout(f, io)
        flush(io)
        return read(path, String)
    end
end

@static if !Sys.iswindows()
    Test.@testset "how rehearse() finds fair" begin
        # Stand-ins for fair: one printing a prepared job folder as fair does,
        # one failing, one exiting 0 having printed no folder
        fakebin = mktempdir()
        prepared = job_folder("fake")
        function stand_in(name::AbstractString, script::AbstractString)
            path = joinpath(fakebin, name)
            write(path, "#!/bin/sh\n" * script)
            chmod(path, 0o755)
            return path
        end
        fake = stand_in("fair",
                        no_sessions *
                        "echo Running run please wait\necho $prepared\n")
        failing = stand_in("failing", "echo no such thing >&2\nexit 1\n")
        silent = stand_in("silent",
                          no_sessions * "echo Running run please wait\n")
        user = user_config("fake", "rehearse/fake/$uid")

        # The preference first, whatever the path holds; set_cli! records
        # only a fair that runs
        @test DataPipeline.set_cli!(fake) == fake
        try
            @test DataPipeline.rehearse(user) == prepared
            DataPipeline._discardcurrent()
            @test_throws ArgumentError DataPipeline.set_cli!(failing)
            @test_throws ArgumentError DataPipeline.set_cli!(joinpath(fakebin,
                                                                      "missing"))
            @test DataPipeline._preferredcli() == fake
            # One that exits 0 printing no folder passes set_cli!, and
            # prepares no job
            DataPipeline.set_cli!(silent)
            err = @test_throws ReadWriteException DataPipeline.rehearse(user)
            @test occursin("no job folder", err.value.msg)
            # The record of a file since gone
            DataPipeline.set_cli!(fake)
            mv(fake, fake * ".gone")
            try
                err = @test_throws ArgumentError DataPipeline.rehearse(user)
                @test occursin("set_cli!", err.value.msg)
            finally
                mv(fake * ".gone", fake)
            end
        finally
            DataPipeline.set_cli!(nothing)
        end
        @test isnothing(current())

        # Then the path
        withenv("PATH" => fakebin) do
            @test DataPipeline.rehearse(user) == prepared
            DataPipeline._discardcurrent()
        end

        # Then the package's copy, which the tests of cli.jl installed: set
        # aside here, so that the error after it is reached
        copy = DataPipeline._installedcli()
        @test !isnothing(copy)
        aside = copy * ".aside"
        mv(copy, aside)
        try
            withenv("PATH" => "") do
                err = @test_throws ArgumentError DataPipeline.rehearse(user)
                @test occursin("install_cli!", err.value.msg)
            end
        finally
            mv(aside, copy)
        end

        # The private worker runs any fair it is given, and fails as it fails
        @test isnothing(DataPipeline._fair("--version", cli = fake))
        err = @test_throws ReadWriteException DataPipeline._fair("anything",
                                                                 cli = failing)
        @test occursin("exit status 1", err.value.msg)

        # A failing fair, recorded directly since set_cli! would refuse it:
        # the error carries what it said
        DataPipeline.Preferences.set_preferences!(DataPipeline,
                                                  "cli" => failing,
                                                  force = true)
        try
            err = @test_throws ReadWriteException DataPipeline.rehearse(user)
            @test occursin("no such thing", err.value.msg)
        finally
            DataPipeline.set_cli!(nothing)
        end

        # A config in no project
        elsewhere = joinpath(outside, "elsewhere.yaml")
        cp(user, elsewhere)
        DataPipeline.set_cli!(fake)
        try
            err = @test_throws ArgumentError DataPipeline.rehearse(elsewhere)
            @test occursin("fair init", err.value.msg)
        finally
            DataPipeline.set_cli!(nothing)
        end
        @test isnothing(current())
        rm(user)
    end

    Test.@testset "how rehearse() holds the registry" begin
        # A stand-in for a fair with the session commands, logging each call
        # and numbering the sessions it opens
        bin = mktempdir()
        calls_file = joinpath(bin, "calls")
        count_file = joinpath(bin, "count")
        sessions = joinpath(bin, "fair")
        write(sessions,
              """
              #!/bin/sh
              echo "\$*" >> $calls_file
              case "\$1 \$2 \$3" in
                "registry session open")
                  n=\$((\$(cat $count_file 2>/dev/null || echo 0) + 1))
                  echo \$n > $count_file
                  echo "{\\"session\\": \\"s\$n\\", \\"registry_url\\": \\"http://127.0.0.1:8000/api/\\", \\"token_file\\": \\"/nowhere/token\\"}" ;;
                "registry session close") ;;
                *) echo "fair, version 9.9.9" ;;
              esac
              """)
        chmod(sessions, 0o755)
        calls() = isfile(calls_file) ? readlines(calls_file) : String[]
        opening = "registry session open --pid $(getpid()) --json"
        # Made first: making a job folder forgets the session's run
        folder = Dict(name => job_folder("held-$name")
                      for name in ("main", "earlier", "later", "run", "none",
                          "none-run", "refused"))
        @test DataPipeline.set_cli!(sessions) == sessions
        try
            withenv("FDP_SESSION" => nothing) do
                # Opened by rehearse in this process's name, closed by
                # finalise
                DataPipeline.rehearse(folder["main"])
                @test calls()[end] == opening
                @test current().hold isa DataPipeline.RegistryHeldBySession
                @test current().hold.id == "s1"
                DataPipeline.finalise(DataPipeline.initialise())
                @test calls()[end] == "registry session close s1"
                @test isnothing(current().hold)
                # Restarted, the new session opens before the old one closes,
                # so that the registry is held throughout; discarded, it
                # closes
                DataPipeline.rehearse(folder["earlier"])
                DataPipeline.rehearse(folder["later"], restart = true)
                @test calls()[(end - 2):end] ==
                      [opening, opening, "registry session close s2"]
                DataPipeline._discardcurrent()
                @test calls()[end] == "registry session close s3"
                @test isnothing(current())
            end
            # A run that names its session holds the registry: nothing opened
            withenv("FDP_SESSION" => "the-run") do
                before = length(calls())
                DataPipeline.rehearse(folder["run"])
                @test current().hold isa DataPipeline.RegistryHeldByRun
                DataPipeline._discardcurrent()
                @test length(calls()) == before
            end
            # A session whose fair has gone is warned of, not an error
            @test_logs((:warn,
                        r"^`fair registry session close s9` failed: "),
                       DataPipeline._releaseregistry(DataPipeline.RegistryHeldBySession("s9",
                                                                                        Cmd([joinpath(bin,
                                                                                                      "gone")]),
                                                                                        "http://127.0.0.1:8000/api/",
                                                                                        "/nowhere/token")))
        finally
            DataPipeline.set_cli!(nothing)
        end

        # A fair with no session commands holds nothing, and the end of a
        # rehearsal says how to stop a registry it may have left running -
        # unless this process was launched to run a job, as the tests are
        old = joinpath(bin, "old")
        write(old, "#!/bin/sh\n" * no_sessions * "echo fair, version 0.10.2\n")
        chmod(old, 0o755)
        @test DataPipeline.set_cli!(old) == old
        try
            withenv("FDP_SESSION" => nothing) do
                withenv("FDP_CONFIG_DIR" => nothing) do
                    DataPipeline.rehearse(folder["none"])
                    @test current().hold isa DataPipeline.RegistryNotHeld
                    @test occursin("`fair registry stop` stops it",
                                   printed_by(DataPipeline._discardcurrent))
                end
                @test haskey(ENV, "FDP_CONFIG_DIR")
                DataPipeline.rehearse(folder["none-run"])
                @test !occursin("fair registry stop",
                                printed_by(DataPipeline._discardcurrent))
            end
        finally
            DataPipeline.set_cli!(nothing)
        end

        # A fair that has the commands and refuses, or answers with no
        # session, stops the rehearsal before it starts
        refusing = joinpath(bin, "refusing")
        write(refusing,
              "#!/bin/sh\n[ \"\$1\" = --version ] && { echo fair; exit 0; }\n" *
              "echo 'the registry runs on another host' >&2\nexit 1\n")
        garbled = joinpath(bin, "garbled")
        write(garbled, "#!/bin/sh\necho not a session\n")
        for (cli, says) in ((refusing, "runs on another host"),
            (garbled, "printed no session"))
            chmod(cli, 0o755)
            DataPipeline.set_cli!(cli)
            try
                withenv("FDP_SESSION" => nothing) do
                    err = @test_throws ReadWriteException DataPipeline.rehearse(folder["refused"])
                    @test occursin(says, err.value.msg)
                end
                @test isnothing(current())
            finally
                DataPipeline.set_cli!(nothing)
            end
        end
    end

    Test.@testset "how rehearse() prepares a job" begin
        # Stand-ins for a fair, logging each call, whose `fair run --rehearse`
        # does as `rehearsal` says; their `fair run --ci` prints a prepared job
        # folder as fair does
        bin = mktempdir()
        calls_file = joinpath(bin, "calls")
        prepared = job_folder("prepared")
        user = user_config("prepared", "rehearse/prepared/$uid")
        function stand_in(name::AbstractString, rehearsal::AbstractString)
            path = joinpath(bin, name)
            write(path,
                  """
                  #!/bin/sh
                  echo "\$*" >> $calls_file
                  case "\$1 \$2" in
                    "run --rehearse") $rehearsal ;;
                    "run --ci") echo Running run please wait; echo $prepared ;;
                    *) echo "fair, version 9.9.9" ;;
                  esac
                  """)
            chmod(path, 0o755)
            return path
        end
        reply = string("{\\\"job_dir\\\": \\\"$prepared\\\", ",
                       "\\\"config\\\": \\\"$prepared/config.yaml\\\", ",
                       "\\\"script\\\": \\\"$prepared/script.sh\\\", ",
                       "\\\"data_store\\\": \\\"$datastore\\\", ",
                       "\\\"token_file\\\": \\\"/nowhere/token\\\"}")
        rehearsing = stand_in("rehearsing",
                              "echo 'a log line' >&2; echo \"$reply\"")
        lacking = stand_in("lacking",
                           "echo \"Error: No such option '--rehearse'.\" >&2; exit 2")
        unprepared = stand_in("unprepared",
                              "echo 'Warning: nothing to prepare' >&2")
        failing = stand_in("failing", "echo 'cannot prepare it' >&2; exit 1")
        calls() = isfile(calls_file) ? readlines(calls_file) : String[]
        # Held by the run, so that only the runs are called: with the option,
        # it alone, without `--ci` or `--dirty`, its log printed; without it,
        # `--ci --dirty` after it
        withenv("FDP_SESSION" => "the-run") do
            for (cli, prepares) in ((rehearsing,
                                     ["run --rehearse --local $user"]),
                                    (lacking,
                                     ["run --rehearse --local $user",
                                         "run --ci --dirty --local $user"]))
                @test DataPipeline.set_cli!(cli) == cli
                try
                    rm(calls_file, force = true)
                    said = printed_by() do
                        @test DataPipeline.rehearse(user, local_only = true) ==
                              prepared
                    end
                    @test calls() == prepares
                    cli == rehearsing && @test occursin("a log line", said)
                    DataPipeline._discardcurrent()
                finally
                    DataPipeline.set_cli!(nothing)
                end
            end
            # A fair without session commands is not asked for a rehearsal,
            # having neither
            without = joinpath(bin, "without")
            write(without,
                  "#!/bin/sh\necho \"\$*\" >> $calls_file\n" * no_sessions *
                  "[ \"\$1 \$2\" = \"run --ci\" ] && { echo $prepared; exit 0; }\n" *
                  "echo fair, version 0.10.2\n")
            chmod(without, 0o755)
            DataPipeline.set_cli!(without)
            try
                withenv("FDP_SESSION" => nothing) do
                    rm(calls_file, force = true)
                    @test DataPipeline.rehearse(user) == prepared
                    @test calls() ==
                          ["registry session open --pid $(getpid()) --json",
                        "run --ci --dirty $user"]
                    DataPipeline._discardcurrent()
                end
            finally
                DataPipeline.set_cli!(nothing)
            end
            # Exit 0 naming no job, and a failure, are errors carrying what
            # the fair wrote, and leave no rehearsal
            for (cli, says) in ((unprepared, "nothing to prepare"),
                (failing, "cannot prepare it"))
                DataPipeline.set_cli!(cli)
                try
                    err = @test_throws ReadWriteException DataPipeline.rehearse(user)
                    @test occursin(says, err.value.msg)
                    @test isnothing(current())
                finally
                    DataPipeline.set_cli!(nothing)
                end
            end
        end
        rm(user)
    end
end

Test.@testset "a token in the environment is not a rehearsal's" begin
    @test haskey(ENV, "FDP_LOCAL_TOKEN")
    DataPipeline.rehearse(job_folder("token"))
    handle = DataPipeline.initialise(token = "not used")
    @test handle isa DataPipeline.DataRegistryHandle{Rehearsal}
    @test isnothing(handle.registry.token)
    DataPipeline.discard(handle)
    @test current().ended
end

DataPipeline.finalise(launch)

end
