# SPDX-License-Identifier: LGPL-3.0-or-later

module TestProvenance

using DataPipeline
using Dates
using JSON
using Test

const D = DataPipeline
const ReadWriteException = DataPipeline.ReadWriteException

uid = DataPipeline._randomhash()
cpath = joinpath("coderun", Dates.format(Dates.now(), "yyyymmdd-HHMMSS"),
                 "provenance.yaml")
config = DataPipeline._createconfig(cpath)
launch = DataPipeline.initialise(config, config)
registry = launch.registry
datastore = launch.config["run_metadata"]["write_data_store"]
namespace = launch.config["run_metadata"]["default_output_namespace"]
commit = launch.config["run_metadata"]["latest_commit"]
remote_repo = launch.config["run_metadata"]["remote_repo"]

# A deposit cited by a DOI of this run's own
doi = "10.5555/provenance.$uid"
citations = """
@dataset{deposit,
  author = {{Provenance Person $uid}},
  title = {A provenance deposit $uid},
  date = {2022-01-02},
  doi = {$doi},
  version = {1.0}
}
"""

outside = mktempdir()
function file_of(text::AbstractString)
    path = joinpath(outside, DataPipeline._randomhash() * ".txt")
    write(path, text)
    return path
end

# A code run that writes each of these names as text at a version, and reads
# each of `reads` at its first version, with the citation registered
function run_with(writes::Pair{String, String}...; reads = String[])
    config = DataPipeline._createconfig(cpath)
    for (name, version) in writes
        DataPipeline._addwrite(config, name, "provenance description",
                               file_type = "txt", use_version = version)
    end
    for name in reads
        DataPipeline._addread(config, name, use_version = "0.0.1")
    end
    handle = DataPipeline.initialise(config, config)
    register_citations!(handle, citations)
    return handle
end

Test.@testset "reading a report" begin
    fixture(name) = JSON.parsefile(joinpath(@__DIR__, "provenance", name))
    lreg = "http://127.0.0.1:8000/api/"
    product(n) = "$(lreg)data_product/$n/"
    run(n) = "$(lreg)code_run/$n/"
    issue(n) = "$(lreg)issue/$n/"

    # A chain of three runs, the third's output asked about, read whole
    parts = D._readreport!(D._TraceParts(), fixture("report.json"))
    @test length(parts.products) == 4
    @test length(parts.runs) == 3
    @test length(parts.files) == 7
    report = parts.products[product(5)]
    @test report.namespace == "testing"
    @test report.name == "SEIRS_model/report/julia"
    @test report.version == v"0.0.1"
    @test report.hash == "c896cfb94dd9dfaa3f52a5920bb8801834eed74a"
    @test endswith(report.location, "/$(report.hash).txt")
    @test report.description == "Measurement report"
    @test report.format == "txt"
    @test report.made_by == run(3)
    @test isnothing(report.source) && isempty(report.issues)
    @test !report.beyond && !report.checked
    # The input pulled from elsewhere: no run made it, and it has its source,
    # a supplement of the cited item
    parameters = parts.products[product(1)]
    @test isnothing(parameters.made_by)
    @test parameters.source.identifier ==
          "https://doi.org/10.1038/s41592-020-0856-2"
    @test parameters.source.title == "Static parameters of the model"
    @test parameters.source.version == "1.0.0"
    @test parameters.source.date == DateTime(2020, 6, 1, 12)
    @test startswith(parameters.source.location,
                     "https://raw.githubusercontent.com/")
    @test !parameters.source.primary
    @test parameters.issues == [issue(2)]
    # One issue over two data products is the same URL on each
    @test parts.products[product(3)].issues == [issue(4)]
    @test parts.products[product(4)].issues == [issue(4)]
    # A run: its date, what it read with the input role, its files by role
    second = parts.runs[run(2)]
    @test second.date == DateTime(2026, 10, 15, 11, 33, 34)
    @test second.description == "Measurement run 2"
    @test Set(second.inputs) == Set([product(1), product(3)])
    @test second.outputs == [product(4)]
    @test second.repository == "$(lreg)object/4/"
    @test second.config == "$(lreg)object/7/"
    @test second.script == "$(lreg)object/8/"
    repository = parts.files[second.repository]
    @test repository.commit == "34d3bdca22f0273bc78be0a24bb93eb5baf1d2d7-dirty"
    @test repository.location ==
          "https://github.com/FAIRDataPipeline/DataPipeline.jl.git"
    @test Set(repository.issues) == Set([issue(1), issue(3)])
    @test parts.files[second.config].description == "Working config file"
    @test length(parts.files[second.config].hash) == 40
    # Nothing is cut in the whole chain: no data product at the depth asked
    # lacks its run
    @test isempty(D._frontier(parts, product(5), 100))
    @test isempty(D._frontier(parts, product(5), 3))
    # The same chain asked one run back: the input of that run has no run in
    # the report, and is where a cut may be
    shallow = D._readreport!(D._TraceParts(), fixture("report-depth1.json"))
    @test length(shallow.runs) == 1
    @test isnothing(shallow.products[product(4)].made_by)
    @test D._frontier(shallow, product(5), 1) == [product(4)]
    @test isempty(D._frontier(shallow, product(5), 2))
    # Read again, a report adds what the parts lack
    D._readreport!(shallow, fixture("report.json"))
    @test shallow.products[product(4)].made_by == run(2)
    @test length(shallow.runs) == 3

    # The packed issue strings, one or several; a prefix the report does not
    # declare; a report of another shape
    prefixes = Dict("lreg" => "http://127.0.0.1:8000/")
    @test D._reportissues(prefixes,
                          Dict("fair:issue" => "a problem severity: 2 ID: 7")) ==
          [issue(7)]
    @test D._reportissues(prefixes,
                          Dict("fair:issue" => [
                                   "one severity: 1 ID: 1",
                                   "two: severity: 9 ID: 12 severity: 3 ID: 2"
                               ])) == [issue(1), issue(2)]
    @test isempty(D._reportissues(prefixes, Dict()))
    @test_throws ReadWriteException D._reportissues(prefixes,
                                                    Dict("fair:issue" => "unpacked"))
    @test D._reporturl(prefixes, "lreg:api/data_product/5") == product(5)
    @test_throws ReadWriteException D._reporturl(prefixes, "other:api/x/1")
    @test_throws ReadWriteException D._reporturl(prefixes, "noprefix")
    @test D._reporttable("lreg:api/external_object/12") == "external_object"
    old = Dict("prefix" => prefixes,
               "entity" => Dict("lreg:api/data_product/1" =>
                        Dict("dcterms:title" => "x")))
    @test_throws ReadWriteException D._readreport!(D._TraceParts(), old)

    # A trace is made in one direction, written as its parameter
    empty = (registry, String[], Dict{String, D.TraceProduct}(),
             Dict{String, D.TraceRun}(), Dict{String, D.TraceIssue}(), nothing)
    @test D.Trace{D.Upstream}(empty...) isa D.Trace{D.Upstream}
    @test_throws MethodError D.Trace(empty...)
    err = @test_throws ArgumentError D.Trace{D.AbstractTraceDirection}(empty...)
    @test occursin("one direction", err.value.msg)
end

Test.@testset "provenance() of a chain" begin
    deposit = "provenance/deposit/$uid"
    fetched = "provenance/fetched/$uid"
    result = "provenance/result/$uid"
    final = "provenance/final/$uid"

    # A fetch run registers the deposit and a file of it, primary
    fetching = run_with(fetched => "0.0.1")
    link_register!(fetching, deposit, bibtex = "deposit", primary = true)
    file = file_of("provenance fetched $uid\n")
    link_write!(fetching, fetched, path = file, bibtex = "deposit",
                primary = true, title = "Fetched file $uid")
    DataPipeline.finalise(fetching)
    # A model run reads the file and writes a result, with issues: on the
    # registered file, on its repository, and one over its input and output
    modelling = run_with(result => "0.0.1", reads = [fetched])
    link_read!(modelling, fetched)
    write(link_write!(modelling, result), "provenance result $uid\n")
    raise_issue(modelling, "$namespace:$fetched", "fetched issue $uid",
                severity = 2)
    raise_issue(modelling, DataPipeline.CodeRepository(),
                "repository issue $uid", severity = 4)
    raise_issue(modelling, [fetched, result], "pair issue $uid", severity = 3)
    DataPipeline.finalise(modelling)
    # A third run reads the result and the file itself: a diamond
    summarising = run_with(final => "0.0.1", reads = [result, fetched])
    link_read!(summarising, result)
    link_read!(summarising, fetched)
    write(link_write!(summarising, final), "provenance final $uid\n")
    DataPipeline.finalise(summarising)

    trace = DataPipeline.provenance(registry, "$namespace:$final")
    @test trace isa DataPipeline.Trace{DataPipeline.Upstream}
    @test trace.registry === registry
    @test isnothing(trace.depth)
    @test length(trace.roots) == 1
    @test length(trace.products) == 4
    @test length(trace.runs) == 3
    by_name = Dict(product.name => product
                   for product in values(trace.products))
    root = trace.products[only(trace.roots)]
    @test root === by_name[final]
    @test root.namespace == namespace && root.version == v"0.0.1"
    @test root.hash == DataPipeline._getfilehash(summarising.outputs[(final,
                                                         nothing)]["path"])
    @test root.format == "txt" && root.description == "provenance description"
    @test isnothing(root.source) && isnothing(root.superseded_by)
    @test !root.beyond
    # Each run with its uuid, commit and repository, reading what it read
    third = trace.runs[root.made_by]
    @test third.uuid == summarising.code_run_uuid
    @test third.commit == commit
    @test third.repository == remote_repo
    @test Set(third.inputs) == Set([by_name[result].url, by_name[fetched].url])
    @test third.outputs == [root.url]
    @test !isnothing(third.config) && !isnothing(third.script)
    second = trace.runs[by_name[result].made_by]
    @test second.uuid == modelling.code_run_uuid
    @test second.inputs == [by_name[fetched].url]
    first_run = trace.runs[by_name[fetched].made_by]
    @test first_run.uuid == fetching.code_run_uuid
    @test first_run.inputs == [by_name[deposit].url]
    @test first_run.outputs == [by_name[fetched].url]
    # The fetched file with its source, primary; the deposit with no file,
    # which no run made: a root of the trace
    @test by_name[fetched].hash == DataPipeline._getfilehash(file)
    @test by_name[fetched].source.primary
    @test by_name[fetched].source.identifier == "https://doi.org/$doi"
    @test by_name[fetched].source.title == "Fetched file $uid"
    @test by_name[fetched].source.version == "1.0.0"
    @test isnothing(by_name[deposit].hash)
    @test isnothing(by_name[deposit].made_by) && !by_name[deposit].beyond
    @test by_name[deposit].source.title == "A provenance deposit $uid"
    @test by_name[deposit].source.primary
    # The issues, each once, with everything it is raised on
    issue_named = Dict(issue.description => issue
                       for issue in values(trace.issues))
    fetched_issue = issue_named["fetched issue $uid"]
    @test fetched_issue.severity == 2
    @test length(fetched_issue.uuid) == 36
    @test fetched_issue.targets ==
          [DataPipeline.TraceTarget(by_name[fetched].url,
                                    "$namespace:$fetched@v0.0.1", nothing)]
    @test fetched_issue.url in by_name[fetched].issues
    @test length(by_name[fetched].issues) == 2
    pair_issue = issue_named["pair issue $uid"]
    @test Set(target.url for target in pair_issue.targets) ==
          Set([by_name[fetched].url, by_name[result].url])
    @test by_name[result].issues == [pair_issue.url]
    @test pair_issue.url in by_name[fetched].issues
    repository_issue = issue_named["repository issue $uid"]
    @test repository_issue.url in second.issues
    @test only(repository_issue.targets).url == modelling.repo_obj
    @test startswith(only(repository_issue.targets).label,
                     "Remote code repository.")
    @test occursin(commit, only(repository_issue.targets).label)
    if endswith(commit, "-dirty")
        @test any(occursin("uncommitted changes", issue.description)
                  for issue in values(trace.issues))
    end
    @test all(isnothing(product.superseded_by)
              for product in values(trace.products))

    # Printed as a tree from the root, a data product expanded once
    text = sprint(show, MIME("text/plain"), trace)
    @test startswith(text,
                     "Provenance of $namespace:$final@v0.0.1  sha1 $(first(root.hash, 8))\n<- run $(first(third.uuid, 8)) on ")
    @test occursin(replace(remote_repo, r"^[a-z]+://" => "") * " at " *
                   first(commit, 8), text)
    @test occursin("   used $namespace:$result@v0.0.1  sha1 ", text)
    @test occursin("   <- run $(first(second.uuid, 8)) on ", text)
    @test occursin("used $namespace:$fetched@v0.0.1  sha1 $(first(by_name[fetched].hash, 8))  from https://doi.org/$doi (primary)\n",
                   text)
    @test occursin("used $namespace:$fetched@v0.0.1  (above)\n", text)
    @test occursin("used $namespace:$deposit@v0.0.1  no file  from https://doi.org/$doi (primary)\n",
                   text)
    @test occursin("issue, severity 2: fetched issue $uid\n", text)
    @test occursin("issue, severity 4: repository issue $uid\n", text)
    @test count("pair issue $uid", text) == 2
    @test sprint(show, trace) ==
          "Provenance of $namespace:$final@v0.0.1: 3 runs, 4 data products, $(length(trace.issues)) issues"

    # Named by its file, through a handle, and by its newest version
    stored = joinpath(datastore, namespace, final, root.hash * ".txt")
    @test isfile(stored)
    @test DataPipeline.provenance(summarising, stored).roots == trace.roots
    @test DataPipeline.provenance(registry, "$namespace:$final@0.0.1").roots ==
          trace.roots

    # identify of the file reports what the trace finds behind it: each issue
    # once per run it reaches the file through, nearest first, and the diamond
    # reaches the fetched file's issue through both runs that read it
    found = DataPipeline.identify(registry, stored)
    @test found.provenance isa DataPipeline.Trace{DataPipeline.Upstream}
    @test found.provenance.roots == trace.roots
    @test isnothing(found.outdated)
    @test only(found.objects).data_products[1].url == root.url
    reported = [(f.issue.description, f.on.label, f.through.uuid,
                 f.making.name, f.input) for f in found.upstream]
    @test ("fetched issue $uid", "$namespace:$fetched@v0.0.1",
           summarising.code_run_uuid, final, true) in reported
    @test ("fetched issue $uid", "$namespace:$fetched@v0.0.1",
           modelling.code_run_uuid, result, true) in reported
    @test ("pair issue $uid", "$namespace:$result@v0.0.1",
           summarising.code_run_uuid, final, true) in reported
    @test ("pair issue $uid", "$namespace:$fetched@v0.0.1",
           modelling.code_run_uuid, result, true) in reported
    @test any(description == "repository issue $uid" && !input &&
                  uuid == modelling.code_run_uuid && made == result
              for (description, label, uuid, made, input) in reported)
    @test found.upstream[1].through.uuid == summarising.code_run_uuid
    @test allunique(reported)
    @test Set(third.objects) ==
          Set([summarising.repo_obj, summarising.config_obj,
                  summarising.script_obj])
    text = sprint(show, MIME("text/plain"), found)
    @test occursin("  upstream: $(length(found.upstream)) issues\n", text)
    @test occursin("    severity 2 on $namespace:$fetched@v0.0.1: fetched issue $uid\n      used by run $(first(modelling.code_run_uuid, 8)) on ",
                   text)
    @test occursin(", which made $namespace:$result@v0.0.1\n", text)
    @test occursin("severity 4 on Remote code repository.", text)
    @test occursin("\n      in run $(first(modelling.code_run_uuid, 8)) on ",
                   text)
    @test !occursin("outdated", text)
    @test endswith(sprint(show, found),
                   "; $(length(found.upstream)) upstream issues")
    # Asked for, outdated inputs are reported, and here there are none yet;
    # a file the registry does not know has nothing behind it
    none = DataPipeline.identify(summarising, stored, superseded = true)
    @test isempty(none.outdated)
    @test occursin("  outdated inputs: none\n",
                   sprint(show, MIME("text/plain"), none))
    unknown = DataPipeline.identify(registry,
                                    file_of("provenance unknown $uid\n"),
                                    superseded = true)
    @test isnothing(unknown.provenance) && isempty(unknown.upstream)
    @test isempty(unknown.outdated)
    @test !occursin("upstream", sprint(show, MIME("text/plain"), unknown))

    # Cut at a depth: what a run beyond it made is marked, not fetched
    cut = DataPipeline.provenance(registry, "$namespace:$final", depth = 1)
    @test cut.depth == 1
    @test length(cut.runs) == 1 && length(cut.products) == 3
    @test cut.products[by_name[result].url].beyond
    @test isnothing(cut.products[by_name[result].url].made_by)
    @test cut.products[by_name[fetched].url].beyond
    @test occursin("<- a run beyond depth 1\n",
                   sprint(show, MIME("text/plain"), cut))
    # Two runs back reaches the fetch run through the diamond, and the
    # deposit, which no run made, is a root and not beyond
    two = DataPipeline.provenance(registry, "$namespace:$final", depth = 2)
    @test length(two.runs) == 3
    @test !any(product.beyond for product in values(two.products))

    # A newer version of the fetched file registered since is noted on the
    # version that was used
    refetching = run_with(fetched => "0.0.2")
    link_write!(refetching, fetched,
                path = file_of("provenance fetched again $uid\n"),
                bibtex = "deposit", primary = true,
                title = "Fetched file $uid", release_version = "2.0")
    DataPipeline.finalise(refetching)
    later = DataPipeline.provenance(registry, "$namespace:$final")
    @test later.products[by_name[fetched].url].superseded_by == v"0.0.2"
    @test isnothing(later.products[root.url].superseded_by)
    @test occursin("$namespace:$fetched@v0.0.1  sha1 $(first(by_name[fetched].hash, 8))  superseded by v0.0.2  from",
                   sprint(show, MIME("text/plain"), later))
    newest = DataPipeline.provenance(registry, "$namespace:$fetched")
    @test only(values(newest.products)).version == v"0.0.2"
    # ... and identify reports it as an outdated input, through each run that
    # read it, only when asked
    @test isnothing(DataPipeline.identify(registry, stored).outdated)
    with = DataPipeline.identify(registry, stored, superseded = true)
    @test length(with.outdated) == 2
    @test all(outdated.input.url == by_name[fetched].url &&
                  outdated.input.superseded_by == v"0.0.2"
              for outdated in with.outdated)
    @test Set((outdated.through.uuid, outdated.making.name)
              for outdated in with.outdated) ==
          Set([(summarising.code_run_uuid, final),
                  (modelling.code_run_uuid, result)])
    @test occursin("  outdated inputs: 2\n    $namespace:$fetched@v0.0.1, superseded by v0.0.2\n      used by run $(first(summarising.code_run_uuid, 8)) on ",
                   sprint(show, MIME("text/plain"), with))

    # What cannot be traced
    @test_throws ReadWriteException DataPipeline.provenance(registry,
                                                            "$namespace:$fetched@v9.9.9")
    @test_throws ReadWriteException DataPipeline.provenance(registry,
                                                            "$namespace:provenance/absent/$uid")
    err = @test_throws ArgumentError DataPipeline.provenance(registry,
                                                             "nothing/here/$uid")
    @test occursin("no file at", err.value.msg)
    @test_throws ReadWriteException DataPipeline.provenance(registry,
                                                            file_of("provenance unknown $uid\n"))
    @test_throws ArgumentError DataPipeline.provenance(registry,
                                                       "$namespace:$final",
                                                       depth = 0)
end

end
