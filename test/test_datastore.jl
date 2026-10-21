# SPDX-License-Identifier: LGPL-3.0-or-later

module TestDatastore

using DataPipeline
using Dates
using SHA
using Test

uid = DataPipeline._randomhash()
cpath = joinpath("coderun", Dates.format(Dates.now(), "yyyymmdd-HHMMSS"),
                 "datastore.yaml")
config = DataPipeline._createconfig(cpath)
launch = DataPipeline.initialise(config, config)
registry = launch.registry
namespace = launch.config["run_metadata"]["default_output_namespace"]

sha1of(text) = bytes2hex(SHA.sha1(text))

# A file of this text at `path` in the store `root`, made with its folders
function made(text::AbstractString, path::AbstractString, root::AbstractString)
    full = normpath(joinpath(root, path))
    mkpath(dirname(full))
    write(full, text)
    return full
end

# A file of this text registered at `path` in the store `root`, as an object
# of its own
function stored(text::AbstractString, path::AbstractString,
                root::AbstractString)
    full = made(text, path, root)
    DataPipeline._registerobject(registry, path, root, "datastore $uid",
                                 new_object = true)
    return full
end

# A file of this text at `path` in the store `root`, with a storage location
# and no object, and the location's URL
function located(text::AbstractString, path::AbstractString,
                 root::AbstractString)
    full = made(text, path, root)
    root_url = DataPipeline._postentry(registry, "storage_root",
                                       Dict("root" => root,
                                            "local" => true))["url"]
    location = DataPipeline._postentry(registry, "storage_location",
                                       Dict("path" => path,
                                            "hash" => sha1of(text),
                                            "public" => true,
                                            "storage_root" => root_url))
    return full, location["url"]
end

# What a check found in one store, each a path as the check gives it
function paths_in(found, root)
    return filter(path -> startswith(path, normpath(root)),
                  [file isa AbstractString ? file : file.path
                   for file in found])
end

Test.@testset "check_store()" begin
    # Stores of this test's own, so that the suite's do not decide anything
    store, gone, crowded = (joinpath(mktempdir(), "") for _ in 1:3)

    kept = stored("datastore kept $uid\n", "testing/kept/$uid/kept.txt", store)
    deleted = stored("datastore deleted $uid\n",
                     "testing/deleted/$uid/deleted.txt", store)
    rm(deleted)
    rewritten = stored("datastore rewritten $uid\n",
                       "testing/rewritten/$uid/rewritten.txt", store)
    write(rewritten, "datastore rewritten again $uid\n")
    # A path registered, rewritten and registered again, then rewritten once
    # more, and one registered twice so and deleted
    again = stored("datastore again 1 $uid\n", "testing/again/$uid/again.txt",
                   store)
    stored("datastore again 2 $uid\n", "testing/again/$uid/again.txt", store)
    write(again, "datastore again 3 $uid\n")
    twice = stored("datastore twice 1 $uid\n", "testing/twice/$uid/twice.txt",
                   store)
    stored("datastore twice 2 $uid\n", "testing/twice/$uid/twice.txt", store)
    rm(twice)
    # Registered as a hard link to a file elsewhere, which is then written to
    elsewhere = joinpath(mktempdir(), "linked.txt")
    write(elsewhere, "datastore linked $uid\n")
    linked = normpath(joinpath(store, "testing/linked/$uid/linked.txt"))
    mkpath(dirname(linked))
    hardlink(elsewhere, linked)
    DataPipeline._registerobject(registry, "testing/linked/$uid/linked.txt",
                                 store, "datastore $uid", new_object = true)
    write(elsewhere, "datastore linked, written to $uid\n")
    # A location nothing uses, and one that a source uses as where its file
    # was fetched from
    unused, _ = located("datastore unused $uid\n",
                        "testing/unused/$uid/unused.txt", store)
    _, fetched = located("datastore fetched $uid\n",
                         "testing/fetched/$uid/fetched.txt", store)
    deposit = DataPipeline._createentry(registry, "object",
                                        Dict("description" => "datastore deposit $uid",
                                             "authors" => []))
    space = DataPipeline._postentry(registry, "namespace",
                                    Dict("name" => namespace))
    product = DataPipeline._createentry(registry, "data_product",
                                        Dict("name" => "datastore/deposit/$uid",
                                             "version" => "0.0.1",
                                             "object" => deposit["url"],
                                             "namespace" => space["url"]))
    DataPipeline._createentry(registry, "external_object",
                              Dict("data_product" => product["url"],
                                   "identifier" => "https://example.org/datastore/$uid",
                                   "title" => "Datastore $uid",
                                   "release_date" => "2021-03-04T00:00:00Z",
                                   "primary_not_supplement" => true,
                                   "original_store" => fetched))
    # A code repository's location is a commit: never hashed, and the files
    # of its folder are not unknown
    made("datastore repository $uid\n", "repositories/$uid/README.md", store)
    DataPipeline._registerobject(registry, "repositories/$uid", store,
                                 DataPipeline.REPOSITORY_DESCRIPTION,
                                 hash = sha1of("datastore commit $uid"),
                                 file_type = nothing, new_object = true)
    # Files the registry does not know
    stray = made("datastore stray $uid\n", "testing/stray/$uid.txt", store)
    unfinished = made("datastore unfinished $uid\n",
                      "testing/kept/$uid/dat-$uid.txt", store)
    job = made("datastore job $uid\n",
               "jobs/2026-10-20_12_00_00_000000/coderuns.txt", store)

    # A store whose folder has gone, and one with more missing files than a
    # quiet report lists
    lost = stored("datastore lost $uid\n", "testing/lost/$uid.txt", gone)
    rm(gone, recursive = true)
    absent = [stored("datastore absent $i $uid\n", "testing/absent/$uid/$i.txt",
                     crowded)
              for i in 1:(DataPipeline.QUIET_MISSING + 2)]
    rm.(absent)

    check = DataPipeline.check_store(registry)
    @test check.hashes && check.quiet
    ours = only(filter(root -> root.folder == store, check.roots))
    @test ours.root == "file://$store" && ours.exists && ours.locations == 11
    @test !only(filter(root -> root.folder == gone, check.roots)).exists
    @test paths_in(check.missing, store) == sort([deleted, twice, twice])
    @test paths_in(check.missing, gone) == [lost]
    @test paths_in(check.missing, crowded) == sort(absent)
    missed = only(filter(file -> file.path == deleted, check.missing))
    @test missed.hash == sha1of("datastore deleted $uid\n")
    @test startswith(missed.location, registry.url)
    @test paths_in(check.changed, store) ==
          sort([again, again, linked, rewritten])
    found = only(filter(file -> file.path == rewritten, check.changed))
    @test found.hash == sha1of("datastore rewritten $uid\n")
    @test found.found == sha1of("datastore rewritten again $uid\n")
    @test found.links == 1
    @test only(filter(file -> file.path == linked, check.changed)).links == 2
    @test paths_in(check.unknown, store) == [stray]
    @test paths_in(check.unused, store) == [unused]
    @test paths_in(check.unfinished, store) == [unfinished]
    left = only(filter(file -> file.path == unfinished, check.unfinished))
    @test abs(left.modified - Dates.now(Dates.UTC)) < Dates.Minute(10)
    @test paths_in(check.cli_files, store) == [job]
    @test isempty(paths_in(check.missing, joinpath(store, "repositories")))

    # Existence alone, without reading the files
    unhashed = DataPipeline.check_store(registry, hashes = false)
    @test !unhashed.hashes && isempty(unhashed.changed)
    @test paths_in(unhashed.missing, store) == sort([deleted, twice, twice])
    @test occursin(", contents not checked)", sprint(show, unhashed))
    # A handle gives its registry, and with neither the local registry is held
    @test DataPipeline.check_store(launch, hashes = false).roots ==
          unhashed.roots
    @test DataPipeline.check_store(hashes = false).roots == unhashed.roots

    # The report: quiet, then everything
    @test startswith(sprint(show, check), "StoreCheck(")
    report = sprint(show, MIME"text/plain"(), check)
    in_store(path) = relpath(path, store)
    @test occursin("\n  $store (11 storage locations)\n", report)
    @test occursin("\n    missing: $(in_store(deleted))\n", report)
    @test occursin("\n    changed: $(in_store(linked)) - sha1 $(first(sha1of("datastore linked, written to $uid\n"), 8)), registered $(first(sha1of("datastore linked $uid\n"), 8)); it has 2 hard links",
                   report)
    @test occursin("\n    changed: $(in_store(rewritten)) - sha1 ", report)
    @test occursin("\n    changed: $(in_store(again)) - sha1 $(first(sha1of("datastore again 3 $uid\n"), 8)), registered with 2 other contents, listed with quiet = false\n",
                   report)
    @test occursin("\n    missing: $(in_store(twice)) (2 storage locations)\n",
                   report)
    @test occursin("\n    unknown: $(in_store(stray))\n", report)
    @test occursin("\n    unused: $(in_store(unused))\n", report)
    @test occursin("\n    unfinished: $(in_store(unfinished)), modified ",
                   report)
    @test occursin("\n    and 1 file of the CLI's own under jobs/, listed with quiet = false",
                   report)
    @test !occursin("the CLI's: $(in_store(job))", report)
    @test occursin("\n  $gone: the folder is gone, and with it 1 registered file",
                   report)
    @test !occursin("missing: $(relpath(lost, gone))", report)
    in_crowded = joinpath("testing", "absent", uid)
    @test count("\n    missing: $in_crowded", report) ==
          DataPipeline.QUIET_MISSING
    @test occursin("\n    missing: 2 more, listed with quiet = false", report)
    loud = sprint(show, MIME"text/plain"(),
                  DataPipeline.check_store(registry, quiet = false))
    @test occursin("\n    the CLI's: $(in_store(job))", loud)
    @test count("\n    changed: $(in_store(again)) - sha1 ", loud) == 2
    @test occursin("\n    missing: $(relpath(lost, gone))", loud)
    @test count("\n    missing: $in_crowded", loud) == length(absent)
end

end
