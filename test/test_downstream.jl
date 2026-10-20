# SPDX-License-Identifier: LGPL-3.0-or-later

module TestDownstream

using DataPipeline
using Dates
using SHA
using Test

const D = DataPipeline
const ReadWriteException = DataPipeline.ReadWriteException

uid = DataPipeline._randomhash()
cpath = joinpath("coderun", Dates.format(Dates.now(), "yyyymmdd-HHMMSS"),
                 "downstream.yaml")
config = DataPipeline._createconfig(cpath)
launch = DataPipeline.initialise(config, config)
registry = launch.registry
datastore = launch.config["run_metadata"]["write_data_store"]
namespace = launch.config["run_metadata"]["default_output_namespace"]
commit = launch.config["run_metadata"]["latest_commit"]
remote_repo = launch.config["run_metadata"]["remote_repo"]

# A repository of this test's own, for the start from a repository's runs:
# its commit from this file's name, since every test file draws the same
# random hashes and a commit is one location under a root whatever its path
fixture_sha = bytes2hex(SHA.sha1("downstream fixture $uid"))
fixture_remote = "https://github.com/FAIRDataPipeline/downstream-fixture-$uid.git"

outside = mktempdir()
function file_of(text::AbstractString)
    path = tempname(outside) * ".txt"
    write(path, text)
    return path
end

# A code run that writes each of these names as text at a version and reads
# each of `reads` at the version given, from a commit and a remote
function run_with(writes::Pair{String, String}...;
                  reads::Vector{Pair{String, String}} = Pair{String, String}[],
                  from::String = commit, remote::String = remote_repo)
    config = DataPipeline._createconfig(cpath, latest_commit = from,
                                        remote_repo = remote)
    for (name, version) in writes
        DataPipeline._addwrite(config, name, "downstream description",
                               file_type = "txt", use_version = version)
    end
    for (name, version) in reads
        DataPipeline._addread(config, name, use_version = version)
    end
    return DataPipeline.initialise(config, config)
end

# A run that reads what it is told and writes what it is told, with the
# text naming the run
function run!(handle::DataPipeline.DataRegistryHandle, reads::Vector{String},
              writes::Vector{String})
    for name in reads
        link_read!(handle, name)
    end
    for name in writes
        write(link_write!(handle, name), "downstream $name $(rand()) $uid\n")
    end
    return handle
end

Test.@testset "downstream() of a chain" begin
    root = "downstream/root/$uid"
    second = "downstream/second/$uid"
    third = "downstream/third/$uid"
    fourth = "downstream/fourth/$uid"

    # A run of the fixture repository writes the root; four runs read on
    # from it: two read the root, one of them the second product too (a
    # diamond), one reads the second product, and one reads the root and
    # writes the second product again at a new version
    starting = run!(run_with(root => "0.0.1", from = fixture_sha,
                             remote = fixture_remote), String[], [root])
    DataPipeline.finalise(starting)
    making = run!(run_with(second => "0.0.1", reads = [root => "0.0.1"]),
                  [root], [second])
    DataPipeline.finalise(making)
    joining = run!(run_with(third => "0.0.1",
                            reads = [root => "0.0.1", second => "0.0.1"]),
                   [root, second], [third])
    DataPipeline.finalise(joining)
    using_second = run_with(fourth => "0.0.1", reads = [second => "0.0.1"])
    run!(using_second, [second], [fourth])
    raise_issue!(using_second, "$namespace:$second", "downstream issue $uid",
                 severity = 2)
    DataPipeline.finalise(using_second)
    remaking = run!(run_with(second => "0.0.2", reads = [root => "0.0.1"]),
                    [root], [second])
    DataPipeline.finalise(remaking)

    trace = DataPipeline.downstream(registry, "$namespace:$root")
    @test trace isa DataPipeline.Trace{DataPipeline.Downstream}
    @test isnothing(trace.depth)
    @test length(trace.roots) == 1
    @test length(trace.runs) == 4
    @test length(trace.products) == 5
    by_version = Dict((product.name, product.version) => product
                      for product in values(trace.products))
    start = trace.products[only(trace.roots)]
    @test start === by_version[(root, v"0.0.1")]
    @test isnothing(start.made_by) && !start.beyond
    @test isnothing(start.superseded_by)
    first_second = by_version[(second, v"0.0.1")]
    newer_second = by_version[(second, v"0.0.2")]
    made_third = by_version[(third, v"0.0.1")]
    made_fourth = by_version[(fourth, v"0.0.1")]
    # Each product made by its run, and the superseded one marked
    runs = Dict(run.uuid => run for run in values(trace.runs))
    @test first_second.made_by == runs[making.code_run_uuid].url
    @test newer_second.made_by == runs[remaking.code_run_uuid].url
    @test made_third.made_by == runs[joining.code_run_uuid].url
    @test made_fourth.made_by == runs[using_second.code_run_uuid].url
    @test first_second.superseded_by == v"0.0.2"
    @test isnothing(newer_second.superseded_by)
    @test isnothing(made_third.superseded_by)
    @test !any(product.beyond for product in values(trace.products))
    @test first_second.hash ==
          DataPipeline._getfilehash(making.outputs[(second, nothing)]["path"])
    @test first_second.format == "txt"
    # Each run with what it read of the trace and what it wrote
    @test runs[making.code_run_uuid].inputs == [start.url]
    @test runs[making.code_run_uuid].outputs == [first_second.url]
    @test Set(runs[joining.code_run_uuid].inputs) ==
          Set([start.url, first_second.url])
    @test runs[joining.code_run_uuid].outputs == [made_third.url]
    @test runs[using_second.code_run_uuid].inputs == [first_second.url]
    @test runs[remaking.code_run_uuid].inputs == [start.url]
    @test all(run.commit == commit for run in values(trace.runs))
    @test all(run.repository == remote_repo for run in values(trace.runs))
    @test length(runs[joining.code_run_uuid].objects) == 3
    # The issue on the second product, with its target
    issue_named = Dict(issue.description => issue
                       for issue in values(trace.issues))
    found = issue_named["downstream issue $uid"]
    @test found.severity == 2
    @test found.targets ==
          [DataPipeline.TraceTarget(first_second.url,
                                    "$namespace:$second@v0.0.1", nothing)]
    @test first_second.issues == [found.url]

    # Printed as a tree from the start, each product and each run once: the
    # run that read the root and the second product is expanded where it is
    # first reached and noted the second time; which run comes first under
    # the root is decided by their dates, to the second
    text = sprint(show, MIME("text/plain"), trace)
    @test startswith(text,
                     "Downstream of $namespace:$root@v0.0.1  sha1 $(first(start.hash, 8))\n-> run ")
    for handle in (making, joining, remaking)
        @test occursin("\n-> run $(first(handle.code_run_uuid, 8)) on ", text)
    end
    @test occursin(replace(remote_repo, r"^[a-z]+://" => "") * " at " *
                   first(commit, 8), text)
    @test occursin("   made $namespace:$second@v0.0.1  sha1 $(first(first_second.hash, 8))  superseded by v0.0.2\n       issue, severity 2: downstream issue $uid\n",
                   text)
    @test occursin(Regex("\\n +made $namespace:$third@v0.0.1  sha1 "), text)
    @test occursin(Regex("   -> run $(first(using_second.code_run_uuid, 8)) on \\d{4}-\\d\\d-\\d\\d \\d\\d:\\d\\d UTC"),
                   text)
    @test occursin("      made $namespace:$fourth@v0.0.1  sha1 ", text)
    @test occursin("  (above)\n", text)
    @test count("(above)", text) == 1
    @test count("run $(first(joining.code_run_uuid, 8)) on ", text) == 2
    @test occursin("   made $namespace:$second@v0.0.2  sha1 ", text)
    @test !occursin("beyond", text)
    @test sprint(show, trace) ==
          "Downstream of $namespace:$root@v0.0.1: 4 runs, 4 data products made, 3 newest, $(length(trace.issues)) issues"

    # Named by its file, through a handle; and from the commit of the
    # repository whose run wrote the root, by the remote's URL
    stored = joinpath(datastore, namespace, root, start.hash * ".txt")
    @test DataPipeline.downstream(remaking, stored).roots == trace.roots
    from_repo = DataPipeline.downstream(registry,
                                        DataPipeline.NamedCommit(fixture_sha,
                                                                 repo = fixture_remote))
    @test from_repo.roots == trace.roots
    @test length(from_repo.runs) == 4
    @test_throws ReadWriteException DataPipeline.downstream(registry,
                                                            DataPipeline.NamedCommit(DataPipeline._randomhash(),
                                                                                     repo = fixture_remote))

    # Cut at a depth: the products one run on are held, and those a further
    # run read are marked
    cut = DataPipeline.downstream(registry, "$namespace:$root", depth = 1)
    @test cut.depth == 1
    @test length(cut.runs) == 3
    @test Set(keys(cut.products)) ==
          Set([start.url, first_second.url, made_third.url, newer_second.url])
    @test cut.products[first_second.url].beyond
    @test !cut.products[made_third.url].beyond
    @test !cut.products[newer_second.url].beyond
    @test occursin("   -> runs beyond depth 1\n",
                   sprint(show, MIME("text/plain"), cut))
    @test length(DataPipeline.downstream(registry, "$namespace:$root",
                                         depth = 2).runs) == 4

    # From an issue: everything the issue is raised on, by the issue as a
    # trace found it, as identify found it, by its uuid, its URL or its
    # number; the second product's readers and what they made, the issue
    # itself in the trace
    second_file = joinpath(datastore, namespace, second,
                           first_second.hash * ".txt")
    recorded = only(only(DataPipeline.identify(registry, second_file).objects).issues)
    @test recorded.uuid == found.uuid && recorded.url == found.url
    for named in (found, recorded, found.uuid, found.url,
                  parse(Int, DataPipeline._extractid(found.url)))
        from_issue = DataPipeline.downstream(registry; issue = named)
        @test from_issue.roots == [first_second.url]
        @test Set(run.uuid for run in values(from_issue.runs)) ==
              Set([joining.code_run_uuid, using_second.code_run_uuid])
        @test Set(keys(from_issue.products)) ==
              Set([first_second.url, made_third.url, made_fourth.url])
        @test haskey(from_issue.issues, found.url)
    end
    @test DataPipeline.downstream(remaking; issue = found).roots ==
          [first_second.url]
    @test startswith(sprint(show, MIME("text/plain"),
                            DataPipeline.downstream(registry; issue = found)),
                     "Downstream of $namespace:$second@v0.0.1  sha1 ")

    # An issue on a run's code or config starts from everything the runs
    # made that ran from it: another run of the fixture repository, so that
    # its root and the new run's output both start the trace, each with the
    # run that made it
    fifth = "downstream/fifth/$uid"
    coding = run_with(fifth => "0.0.1", from = fixture_sha,
                      remote = fixture_remote)
    run!(coding, String[], [fifth])
    raise_issue!(coding, DataPipeline.CodeRepository(),
                 "downstream code issue $uid", severity = 5)
    raise_issue!(coding, DataPipeline.WorkingConfig(),
                 "downstream config issue $uid", severity = 6)
    DataPipeline.finalise(coding)
    code_issue = DataPipeline._getentry(registry, "issue",
                                        Dict("description" => "downstream code issue $uid"))
    from_code = DataPipeline.downstream(registry; issue = code_issue["uuid"])
    fifth_url = only(url
                     for (url, product) in from_code.products
                     if product.name == fifth)
    @test Set(from_code.roots) == Set([start.url, fifth_url])
    @test from_code.products[start.url].made_by ==
          Dict(run.uuid => run.url for run in values(from_code.runs))[starting.code_run_uuid]
    @test from_code.products[fifth_url].made_by ==
          Dict(run.uuid => run.url for run in values(from_code.runs))[coding.code_run_uuid]
    @test length(from_code.runs) == 6
    @test haskey(from_code.issues, code_issue["url"])
    code_text = sprint(show, MIME("text/plain"), from_code)
    @test occursin("\n   made by run $(first(coding.code_run_uuid, 8)) on ",
                   code_text)
    @test occursin("issue, severity 5: downstream code issue $uid\n",
                   code_text)
    config_issue = DataPipeline._getentry(registry, "issue",
                                          Dict("description" => "downstream config issue $uid"))
    from_config = DataPipeline.downstream(registry; issue = config_issue["url"])
    @test from_config.roots == [fifth_url]
    @test length(from_config.runs) == 1

    # One start at a time, an issue that is not there, and a name that is
    # not an issue's
    @test_throws MethodError DataPipeline.downstream(registry,
                                                     DataPipeline.NamedCommit(fixture_sha,
                                                                              repo = fixture_remote),
                                                     issue = found)
    @test_throws UndefKeywordError DataPipeline.downstream(registry)
    @test_throws ReadWriteException DataPipeline.downstream(registry;
                                                            issue = 0)
    @test_throws ReadWriteException DataPipeline.downstream(registry;
                                                            issue = "00000000-0000-0000-0000-000000000000")
    @test_throws ArgumentError DataPipeline.downstream(registry;
                                                       issue = "not an issue")

    # What cannot be traced
    @test_throws ReadWriteException DataPipeline.downstream(registry,
                                                            "$namespace:downstream/absent/$uid")
    @test_throws ArgumentError DataPipeline.downstream(registry,
                                                       "$namespace:$root",
                                                       depth = 0)
    @test_throws ArgumentError DataPipeline.downstream(registry,
                                                       "nothing/here/$uid")
end

end
