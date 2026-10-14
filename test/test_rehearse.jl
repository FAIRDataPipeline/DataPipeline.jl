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

# The environment this run was launched with, which each rehearsal below
# changes and which the test files after this one need back; and the same
# with no token, for a rehearsal prepared without the warning about it
launch_dir = ENV["FDP_CONFIG_DIR"]
launch_token = ENV["FDP_LOCAL_TOKEN"]
quiet = ("FDP_CONFIG_DIR" => launch_dir, "FDP_LOCAL_TOKEN" => nothing,
         "FDP_REHEARSAL" => nothing)

# A folder laid out like a job folder, holding a working config made from the
# launch config, under the data store but not under its jobs/: made while
# FDP_CONFIG_DIR still names the launch config
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

    withenv("FDP_CONFIG_DIR" => launch_dir, "FDP_LOCAL_TOKEN" => launch_token,
            "FDP_REHEARSAL" => nothing) do
        # The token in the session is removed, with a warning, and the two
        # variables set
        @test (@test_logs (:warn, r"FDP_LOCAL_TOKEN") DataPipeline.rehearse(job,
                                                                            outputs = outputs)) ==
              job
        @test ENV["FDP_CONFIG_DIR"] == job
        @test ENV["FDP_REHEARSAL"] == outputs
        @test !haskey(ENV, "FDP_LOCAL_TOKEN")

        # A rehearsal handle: no token, nothing registered
        handle = DataPipeline.initialise()
        @test handle isa DataPipeline.DataRegistryHandle{Rehearsal}
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
        @test write_estimate(handle, 4.2, estimate, "point",
                             "a rehearsed estimate") == (estimate, "point")
        copied = link_write!(handle, again)
        cp(parameters, copied, force = true)
        raise_issue(handle, whole, "a rehearsed issue $uid")

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
        # unchanged one too, with the working config beside them, and
        # registers nothing
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
        @test !haskey(ENV, "FDP_CONFIG_DIR")
        @test !haskey(ENV, "FDP_REHEARSAL")
        # The job folder is not under jobs/, so it stays
        @test isfile(working)

        # A second finalise has nothing to do with no run: the clear error
        @test_throws ConfigFileException DataPipeline.initialise()
    end
end

Test.@testset "a rehearsal repeated into the same folder replaces its files" begin
    job = job_folder("again")
    working = joinpath(job, "config.yaml")
    whole = "rehearse/replaced/$uid"
    DataPipeline._addwrite(working, whole, "a rehearsed file",
                           file_type = "txt", use_version = "0.0.1")
    outputs = mktempdir()
    placed = joinpath(outputs, namespace, whole, "0.0.1.txt")
    withenv(quiet...) do
        for text in ("first $uid\n", "second $uid\n")
            DataPipeline.rehearse(job, outputs = outputs)
            handle = DataPipeline.initialise()
            write(link_write!(handle, whole), text)
            @test DataPipeline.finalise(handle) == outputs
            @test read(placed, String) == text
        end
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
    withenv(quiet...) do
        DataPipeline.rehearse(job, outputs = outputs)
        handle = DataPipeline.initialise()
        path = link_write!(handle, whole)
        write(path, "a discarded file $uid\n")
        @test isnothing(DataPipeline.discard(handle))
        @test !isfile(path)
        @test !isdir(dirname(path))
        @test isempty(readdir(outputs))
        @test isempty(handle.outputs)
        @test !haskey(ENV, "FDP_CONFIG_DIR")
        @test !haskey(ENV, "FDP_REHEARSAL")
        @test counts() == before
    end

    # A recorded run is registered already
    err = @test_throws ReadWriteException DataPipeline.discard(launch)
    @test occursin("finalise", err.value.msg)
end

Test.@testset "what rehearse() accepts" begin
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
    # A working config is taken as its folder
    job = job_folder("config")
    withenv(quiet...) do
        @test DataPipeline.rehearse(joinpath(job, "config.yaml")) == job
        @test ENV["FDP_CONFIG_DIR"] == job
        # ... and the default outputs folder is a new temporary one. That it
        # outlives the session (made with `cleanup = false`) is not tested
        # here: it would take a second Julia process
        folder = ENV["FDP_REHEARSAL"]
        @test isdir(folder)
        @test startswith(basename(folder), "fdp-rehearsal-")
    end
end

# A user config inside the project, as a user's would be, reading the SEIRS
# parameters and writing one text file
function user_config(name::AbstractString, data_product::AbstractString)
    path = joinpath(pwd(), "rehearse-$name-$uid.yaml")
    DataPipeline.YAML.write_file(path,
                                 Dict("run_metadata" =>
                                          Dict("description" => "A rehearsed run $uid",
                                               "script" => "julia script.jl",
                                               "default_input_namespace" => "testing",
                                               "default_output_namespace" => "testing"),
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

Test.@testset "fair()" begin
    # The fair on the path, which the suite runs under
    @test isnothing(DataPipeline.fair("--version"))
    err = @test_throws ReadWriteException DataPipeline.fair("no-such-command")
    @test occursin("no-such-command", err.value.msg)
end

Test.@testset "rehearse() from a user config, through fair" begin
    name = "rehearse/via-fair/$uid"
    user = user_config("fair", name)
    outputs = mktempdir()
    before = counts()
    withenv(quiet...) do
        # fair run --ci prepares the job under the data store's jobs/
        job = DataPipeline.rehearse(user, outputs = outputs, local_only = true)
        @test isdir(job)
        @test !startswith(relpath(job, joinpath(datastore, "jobs")), "..")
        @test isfile(joinpath(job, "config.yaml"))
        @test ENV["FDP_CONFIG_DIR"] == job
        handle = DataPipeline.initialise()
        @test handle isa DataPipeline.DataRegistryHandle{Rehearsal}
        @test isfile(link_read!(handle, "parameters"))
        write(link_write!(handle, name), "rehearsed through fair $uid\n")
        @test DataPipeline.finalise(handle) == outputs
        @test read(joinpath(outputs, "testing", name, "0.0.1.txt"), String) ==
              "rehearsed through fair $uid\n"
        # The job folder, being under jobs/, is deleted
        @test !isdir(job)
        @test counts() == before
    end
    rm(user)
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
                        "echo Running run please wait\necho $prepared\n")
        failing = stand_in("failing", "echo no such thing >&2\nexit 1\n")
        silent = stand_in("silent", "echo Running run please wait\n")
        user = user_config("fake", "rehearse/fake/$uid")

        withenv(quiet...) do
            # The keyword first, whatever the path holds
            @test DataPipeline.rehearse(user, cli = fake) == prepared
            @test DataPipeline.rehearse(user, cli = `$fake`) == prepared
            @test_throws ArgumentError DataPipeline.rehearse(user,
                                                             cli = joinpath(fakebin,
                                                                            "missing"))
            # Then the path
            withenv("PATH" => fakebin) do
                @test DataPipeline.rehearse(user) == prepared
            end
            # Then, with no copy of the package's own, the variable
            withenv("PATH" => "", "FDP_FAIR_CLI" => fake) do
                @test DataPipeline.rehearse(user) == prepared
            end
            withenv("PATH" => "",
                    "FDP_FAIR_CLI" => joinpath(fakebin, "missing")) do
                err = @test_throws ArgumentError DataPipeline.rehearse(user)
                @test occursin("FDP_FAIR_CLI", err.value.msg)
            end
            withenv("PATH" => "", "FDP_FAIR_CLI" => nothing) do
                err = @test_throws ArgumentError DataPipeline.rehearse(user)
                @test occursin("none on the path", err.value.msg)
            end
            # fair() runs the same fair, and fails as it fails
            @test isnothing(DataPipeline.fair("--version", cli = fake))
            err = @test_throws ReadWriteException DataPipeline.fair("anything",
                                                                    cli = failing)
            @test occursin("exit status 1", err.value.msg)
            # A fair that fails, and one that exits 0 printing no folder
            err = @test_throws ReadWriteException DataPipeline.rehearse(user,
                                                                        cli = failing)
            @test occursin("no such thing", err.value.msg)
            err = @test_throws ReadWriteException DataPipeline.rehearse(user,
                                                                        cli = silent)
            @test occursin("no job folder", err.value.msg)
            # A config in no project
            elsewhere = joinpath(outside, "elsewhere.yaml")
            cp(user, elsewhere)
            err = @test_throws ArgumentError DataPipeline.rehearse(elsewhere,
                                                                   cli = fake)
            @test occursin("fair init", err.value.msg)
        end
        rm(user)
    end
end

Test.@testset "a rehearsal and a token together" begin
    withenv("FDP_REHEARSAL" => mktempdir()) do
        err = @test_throws ConfigFileException DataPipeline.initialise(config,
                                                                       config)
        @test occursin("FDP_REHEARSAL", err.value.msg)
        @test occursin("FDP_LOCAL_TOKEN", err.value.msg)
    end
end

DataPipeline.finalise(launch)

end
