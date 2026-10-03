# SPDX-License-Identifier: LGPL-3.0-or-later

module TestAPI

using DataPipeline
using HDF5
using TOML
using Test
using Dates

uid = DataPipeline._randomhash()
datetime = Dates.format(Dates.now(), "yyyymmdd-HHMMSS")
cpath = joinpath("coderun", datetime, "config.yaml")

config = DataPipeline._createconfig(cpath)
handle = DataPipeline.initialise(config, config)
datastore = handle.config["run_metadata"]["write_data_store"]
namespace = handle.config["run_metadata"]["default_output_namespace"]
launch_url = handle.registry.url
version = "0.0.1"
const URIs = DataPipeline.URIs
const LibGit2 = DataPipeline.LibGit2

component1 = "component/1"
component2 = "component/2"
component3 = "component/3"

data1 = reshape(rand(10), 2, :)
data2 = reshape(rand(10), 2, :)

estimate1 = rand(1)
estimate2 = rand(1)

distribution = Dict("parameters" => Dict("mean" => rand(1), "SD" => rand(1)),
                    "distribution" => "Gaussian", "type" => "distribution")

Test.@testset "link_write()" begin
    data_product = "data_product/link_write/$uid"
    data_product2 = "$data_product/2"
    file_type = "txt"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           file_type = file_type,
                           use_version = version)
    DataPipeline._addwrite(config, data_product2, "description",
                           file_type = file_type,
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Check function output
    path1 = link_write!(handle, data_product)
    @test path1 == handle.outputs[(data_product, nothing)]["path"]
    @test length(handle.outputs) == 1
    path1 = link_write!(handle, data_product)
    @test length(handle.outputs) == 1
    path2 = link_write!(handle, data_product2)
    @test length(handle.outputs) == 2

    open(path1, "w") do file
        println(file, uid)
    end

    open(path2, "w") do file
        println(file, "$uid/2")
    end

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check path: a temporary name in the data product's directory
    @test dirname(path1) == joinpath(datastore, namespace, data_product)
    @test startswith(basename(path1), "dat-")
    @test endswith(basename(path1), ".$file_type")
    @test dirname(path2) == joinpath(datastore, namespace, data_product2)
    @test path1 != path2

    # The code run's uuid is appended to coderuns.txt beside the config
    coderuns = joinpath(dirname(config), "coderuns.txt")
    @test isfile(coderuns)
    @test handle.code_run_uuid in readlines(coderuns)
    @test length(handle.code_run_uuid) == 36

    # Check file
    should_be_here = joinpath(datastore,
                              handle.outputs[(data_product, nothing)]["path"])
    @test isfile(should_be_here)

    should_be_here = joinpath(datastore,
                              handle.outputs[(data_product2, nothing)]["path"])
    @test isfile(should_be_here)
end

Test.@testset "link_read()" begin
    data_product = "data_product/link_write/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.inputs == Dict()

    # Check function output
    path1 = link_read!(handle, data_product)
    @test handle.inputs[(data_product, nothing)]["use_dp"] == data_product
    @test length(handle.inputs) == 1
    path1 = link_read!(handle, data_product)
    @test length(handle.inputs) == 1

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check data
    dat = open(path1) do file
        read(file, String)
    end
    @test chomp(dat) == uid

    # Check handle 
    hash = DataPipeline._getfilehash(path1)
    should_be_here = joinpath(datastore, namespace, data_product, "$hash.txt")
    @test handle.inputs[(data_product, nothing)]["path"] == should_be_here
end

Test.@testset "write_array()" begin
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_array(handle, data1, data_product, component1, "description1")
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_array(handle, data1, data_product, component1, "description1")
    @test length(handle.outputs) == 1
    write_array(handle, data2, data_product, component2, "description2")
    @test length(handle.outputs) == 2

    path1 = handle.outputs[(data_product, component1)]["path"]
    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    isfile(path1)

    # Finalise Code Run
    DataPipeline.finalise(handle)

    newpath1 = handle.outputs[(data_product, component1)]["path"]
    newpath2 = handle.outputs[(data_product, component2)]["path"]

    # Check data
    c1 = HDF5.h5open(newpath1, "r") do file
        read(file, component1)
    end
    @test data1 == c1

    c2 = HDF5.h5open(newpath2, "r") do file
        read(file, component2)
    end
    @test data2 == c2

    # Check handle 
    hash = DataPipeline._getfilehash(newpath1)
    should_be_here = joinpath(datastore, namespace, data_product, "$hash.h5")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_array()" begin
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_array(handle, data_product, component1)
    dat2 = read_array(handle, data_product, component2)
    @test dat1 == data1
    @test dat2 == data2
    # A second read returns the data again, not the handle key
    @test read_array(handle, data_product, component1) == data1
    @test length(handle.inputs) == 2

    # A component is compulsory
    @test_throws MethodError read_array(handle, data_product)

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check handle
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
    @test startswith(handle.inputs[(data_product, component1)]["component_url"],
                     handle.registry.url * "object_component/")
end

Test.@testset "write_estimate()" begin
    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_estimate(handle, estimate1, data_product, component1, "description1")
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_estimate(handle, estimate1, data_product, component1, "description1")
    @test length(handle.outputs) == 1
    write_estimate(handle, estimate2, data_product, component2, "description2")
    @test length(handle.outputs) == 2

    # Check data
    path1 = handle.outputs[(data_product, component1)]["path"]
    c1 = TOML.parsefile(path1)[component1]["value"]
    @test c1 == estimate1

    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    c2 = TOML.parsefile(path2)[component2]["value"]
    @test c2 == estimate2

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check handle 
    newpath1 = handle.outputs[(data_product, component1)]["path"]

    hash = DataPipeline._getfilehash(newpath1)
    should_be_here = joinpath(datastore, namespace, data_product, "$hash.toml")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_estimate()" begin
    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_estimate(handle, data_product, component1)
    dat2 = read_estimate(handle, data_product, component2)
    @test dat1 == estimate1
    @test dat2 == estimate2
    @test read_estimate(handle, data_product, component1) == estimate1

    @test_throws MethodError read_estimate(handle, data_product)

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check handle 
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
end

Test.@testset "write_distribution()" begin
    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_distribution(handle, distribution["distribution"],
                       distribution["parameters"],
                       data_product, component1, "symptom-delay")
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_distribution(handle, distribution["distribution"],
                       distribution["parameters"],
                       data_product, component1, "symptom-delay")
    @test length(handle.outputs) == 1
    write_distribution(handle, distribution["distribution"],
                       distribution["parameters"],
                       data_product, component2, "symptom-delay")
    @test length(handle.outputs) == 2

    # Check data
    path1 = handle.outputs[(data_product, component1)]["path"]
    c1 = TOML.parsefile(path1)[component1]
    @test c1 == distribution

    path2 = handle.outputs[(data_product, component2)]["path"]
    @test path1 == path2
    c2 = TOML.parsefile(path2)[component2]
    @test c2 == distribution

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check handle 
    newpath1 = handle.outputs[(data_product, component1)]["path"]
    hash = DataPipeline._getfilehash(newpath1)
    should_be_here = joinpath(datastore, namespace, data_product, "$hash.toml")
    @test handle.outputs[(data_product, component1)]["path"] == should_be_here

    # Check file exists 
    @test isfile(joinpath(datastore, should_be_here))
end

Test.@testset "read_distribution()" begin
    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_distribution(handle, data_product, component1)
    dat2 = read_distribution(handle, data_product, component2)
    @test dat1 == distribution
    @test dat2 == distribution

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check handle
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
end

# If an attempt is made to write a new component to a data product that was createtd in 
# a previous Code Run, then an error should be thrown.
Test.@testset "new components aren't added to existing data products" begin

    # write_array() -------------------------------------------------------------------

    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)

    # Write component
    msg = string("data product already exists in registry: ", data_product,
                 " :-(ns: ",
                 namespace, " - v: ", version, ")")
    @test_throws DataPipeline.ReadWriteException(msg) write_array(handle, data1,
                                                                  data_product,
                                                                  component3,
                                                                  "description3")

    # write_estimate() ----------------------------------------------------------------

    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)

    # Write component
    msg = string("data product already exists in registry: ", data_product,
                 " :-(ns: ",
                 namespace, " - v: ", version, ")")
    @test_throws DataPipeline.ReadWriteException(msg) write_estimate(handle,
                                                                     estimate1,
                                                                     data_product,
                                                                     component3,
                                                                     "description3")

    # write_distribution() ------------------------------------------------------------

    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)

    # Write component
    msg = string("data product already exists in registry: ", data_product,
                 " :-(ns: ",
                 namespace, " - v: ", version, ")")
    @test_throws DataPipeline.ReadWriteException(msg) write_distribution(handle,
                                                                         distribution["distribution"],
                                                                         distribution["parameters"],
                                                                         data_product,
                                                                         component3,
                                                                         "symptom-delay")
end

# The issues of a component, as the registry holds them
function issues_of(registry, component_url)
    return DataPipeline._getentry(registry, URIs.URI(component_url))["issues"]
end

Test.@testset "raise_issue()" begin
    written = "data_product/link_write/$uid"
    estimates = "data_product/write_estimate/$uid"
    data_product = "data_product/raise_issue/$uid"

    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, written, use_version = version)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    registry = handle.registry
    @test isempty(handle.issues)

    # Queued, not registered, until finalise
    raise_issue(handle, DataPipeline.WorkingConfig(), "config $uid",
                severity = 3)
    raise_issue(handle,
                [
                    DataPipeline.SubmissionScript(),
                    DataPipeline.CodeRepository()
                ], "run $uid",
                severity = 7)
    raise_issue(handle, written, "input $uid")
    raise_issue(handle,
                DataPipeline.ConfigDataProduct(data_product,
                                               component = component1),
                "output $uid", severity = 1)
    raise_issue(handle,
                DataPipeline.ExistingDataProduct(namespace, estimates, version,
                                                 component = component2),
                "existing $uid", severity = 2)
    @test length(handle.issues) == 5
    @test handle.issues[3].targets == [DataPipeline.ConfigDataProduct(written)]
    @test handle.issues[3].severity == DataPipeline.DEFAULT_ISSUE_SEVERITY
    @test isnothing(DataPipeline._getentry(registry, "issue",
                                           Dict("description" => "config $uid")))

    # A data product not in the config is rejected at once
    @test_throws DataPipeline.ConfigFileException raise_issue(handle,
                                                              "not/in/config",
                                                              "bad")
    @test length(handle.issues) == 5

    link_read!(handle, written)
    write_estimate(handle, estimate1, data_product, component1, "description1")
    DataPipeline.finalise(handle)

    # Each call is one registry issue, on the components of its targets
    whole(object_url) = DataPipeline._wholeobjectcomponent(registry,
                                                           object_url)
    issue(description) = DataPipeline._getentry(registry, "issue",
                                                Dict("description" =>
                                                         description))
    config_issue = issue("config $uid")
    @test config_issue["severity"] == 3
    @test config_issue["component_issues"] == [whole(handle.config_obj)]
    run_issue = issue("run $uid")
    @test Set(run_issue["component_issues"]) ==
          Set([whole(handle.script_obj), whole(handle.repo_obj)])
    @test issue("input $uid")["component_issues"] ==
          [handle.inputs[(written, nothing)]["component_url"]]
    @test issue("output $uid")["component_issues"] ==
          [handle.outputs[(data_product, component1)]["component_url"]]
    existing = issue("existing $uid")["component_issues"]
    @test length(existing) == 1
    @test DataPipeline._getentry(registry, URIs.URI(existing[1]))["name"] ==
          component2
    @test issue("run $uid")["url"] in
          issues_of(registry, whole(handle.repo_obj))

    # Several targets at once take the same default severity as one
    several = DataPipeline.initialise(config, config)
    raise_issue(several, [DataPipeline.WorkingConfig()], "default $uid")
    @test only(several.issues).severity == DataPipeline.DEFAULT_ISSUE_SEVERITY
    DataPipeline.finalise(several)
end

Test.@testset "link_read!() with a pattern and link_read_files!()" begin
    written = "data_product/link_write/$uid"          # three segments
    written2 = "$written/2"                            # four
    arrays = "data_product/write_array/$uid"           # three

    config = DataPipeline._createconfig(cpath)
    for name in (written, written2, arrays)
        DataPipeline._addread(config, name, use_version = version)
    end
    handle = DataPipeline.initialise(config, config)

    # A * matches one segment, so the four-segment name is left out
    @test link_read_files!(handle, "data_product/link_write/*") ==
          [link_read!(handle, written)]
    @test length(handle.inputs) == 1
    # Anchored at both ends: the middle segment varies, the ends are fixed
    paths = link_read_files!(handle, "data_product/*/$uid")
    @test paths == [link_read!(handle, written), link_read!(handle, arrays)]
    @test length(handle.inputs) == 2
    @test_throws DataPipeline.ConfigFileException link_read_files!(handle,
                                                                   "nothing/*")
    @test_throws ArgumentError link_read_files!(handle, written)

    # The same pattern through link_read! gives a directory of links
    directory = link_read!(handle, "data_product/*/$uid")
    @test isdir(directory)
    links = sort(readdir(directory))
    @test links == ["data_product_link_write_$uid.txt",
        "data_product_write_array_$uid.h5"]
    # readlink normalises separators, and a storage path keeps the / of the
    # data product name, so compare normalised paths
    @test [normpath(readlink(joinpath(directory, link))) for link in links] ==
          normpath.(paths)
    @test read(joinpath(directory, links[1]), String) == read(paths[1], String)
    @test length(handle.inputs) == 2

    # The directory is named by the hash of what it links to
    manifest = join("$link\t$(DataPipeline._getfilehash(path))\n"
                    for (link, path) in zip(links, paths))
    @test basename(directory) == bytes2hex(DataPipeline.SHA.sha1(manifest))
    @test handle.inputs[(written, nothing)]["hash"] ==
          DataPipeline._getfilehash(paths[1])
    # The same set again gives the same name in a new temporary parent
    again = link_read!(handle, "data_product/*/$uid")
    @test basename(again) == basename(directory)
    @test again != directory

    # A pattern reaching the four-segment name links only that one
    only2 = link_read!(handle, "$written/*")
    @test readdir(only2) == ["data_product_link_write_$(uid)_2.txt"]
    @test length(handle.inputs) == 3

    DataPipeline.finalise(handle)
    code_run = DataPipeline._getentry(handle.registry,
                                      URIs.URI(handle.code_run_obj))
    @test length(code_run["inputs"]) == 3
end

Test.@testset "identify()" begin
    data_product = "data_product/identify/$uid"
    registry = handle.registry

    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "identify description",
                           file_type = "txt", use_version = version)
    run_handle = DataPipeline.initialise(config, config)
    path = link_write!(run_handle, data_product)
    write(path, "identify $uid\n")
    DataPipeline.finalise(run_handle)
    stored = run_handle.outputs[(data_product, nothing)]["path"]

    # What the registry knows about the file it has just registered
    id = DataPipeline.identify(registry, stored)
    @test id.path == stored
    @test id.hash == DataPipeline._getfilehash(stored)
    @test length(id.objects) == 1
    object = only(id.objects)
    @test object.description == "identify description"
    @test object.local_root
    @test isdirpath(replace(object.root, "file://" => ""))
    @test isfile(joinpath(replace(object.root, "file://" => ""),
                          object.stored_path))
    product = only(object.data_products)
    @test (product.namespace, product.name) == (namespace, data_product)
    @test product.version == VersionNumber(version)
    @test product.newest == product.version          # nothing newer yet
    @test isnothing(product.external_object)
    @test isempty(object.issues)
    # A handle may be given instead of a registry
    @test DataPipeline.identify(run_handle, stored).hash == id.hash

    # A file the registry has never seen, and one that is not there at all
    unknown = joinpath(mktempdir(), "unknown.txt")
    write(unknown, "nothing knows about me $uid\n")
    @test isempty(DataPipeline.identify(registry, unknown).objects)
    @test occursin("unknown",
                   sprint(show, DataPipeline.identify(registry,
                                                      unknown)))
    @test_throws DataPipeline.ReadWriteException DataPipeline.identify(registry,
                                                                       joinpath(mktempdir(),
                                                                                "absent"))

    # A newer version of the same name makes this one superseded
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "identify description",
                           file_type = "txt", use_version = "0.0.2")
    newer_handle = DataPipeline.initialise(config, config)
    newer = link_write!(newer_handle, data_product)
    write(newer, "identify newer $uid\n")
    DataPipeline.finalise(newer_handle)
    superseded = only(only(DataPipeline.identify(registry,
                                                 stored).objects).data_products)
    @test superseded.version == VersionNumber(version)
    @test superseded.newest == v"0.0.2"
    @test occursin("SUPERSEDED",
                   sprint(show, MIME("text/plain"),
                          DataPipeline.identify(registry, stored)))

    # An issue raised against it is reported, named by component
    DataPipeline._postentry(registry, "issue",
                            Dict("severity" => 7,
                                 "description" => "identify issue $uid",
                                 "component_issues" =>
                                     [DataPipeline._wholeobjectcomponent(registry,
                                                                         object.url)]))
    issues = only(DataPipeline.identify(registry, stored).objects).issues
    @test length(issues) == 1
    @test only(issues).severity == 7
    @test only(issues).description == "identify issue $uid"
    @test isnothing(only(issues).component)
    @test occursin("1 issue",
                   sprint(show, DataPipeline.identify(registry, stored)))

    # What a user outside `fair run` has: no token at all, which a read needs
    # none of
    tokenless = DataPipeline.RegistryEndpoint(registry.url,
                                              registry.api_version)
    withenv("FDP_LOCAL_TOKEN" => nothing) do
        found = only(DataPipeline.identify(tokenless, stored).objects)
        @test found.url == object.url
        @test only(found.issues).description == "identify issue $uid"
    end

    # With a path alone, the registry is the CLI's: its local registry, or a
    # remote named in the current project's configuration. A home and a
    # project of our own, so that nothing depends on the machine's
    home = mktempdir()
    mkpath(joinpath(home, ".fair", "cli"))
    DataPipeline.YAML.write_file(joinpath(home, ".fair", "cli",
                                          "cli-config.yaml"),
                                 Dict("registries" =>
                                          Dict("local" =>
                                                   Dict("uri" => registry.url))))
    project = joinpath(home, "project")
    mkpath(joinpath(project, ".fair"))
    DataPipeline.YAML.write_file(joinpath(project, ".fair", "cli-config.yaml"),
                                 Dict("registries" =>
                                          Dict("origin" =>
                                                   Dict("uri" => registry.url))))
    withenv("HOME" => home, "USERPROFILE" => home,
            "FDP_LOCAL_TOKEN" => nothing) do
        @test only(DataPipeline.identify(stored).objects).url == object.url
        cd(project) do
            @test only(DataPipeline.identify(stored,
                                             remote = "origin").objects).url ==
                  object.url
        end
    end
end

Test.@testset "a run from uncommitted changes" begin
    registry = handle.registry
    # What `fair run --dirty` records for a working tree with uncommitted
    # changes: a warning, and an issue raised at once against the repository
    config = DataPipeline._createconfig(cpath,
                                        latest_commit = DataPipeline._randomhash() *
                                                        "-dirty")
    dirty = @test_logs (:warn, r"uncommitted changes") DataPipeline.initialise(config,
                                                                               config)
    @test isempty(dirty.issues)          # not queued with the script's own
    component = DataPipeline._wholeobjectcomponent(registry, dirty.repo_obj)
    issue_urls() = DataPipeline._getentry(registry,
                                          URIs.URI(component))["issues"]
    issue = DataPipeline._getentry(registry, URIs.URI(only(issue_urls())))
    @test issue["severity"] == DataPipeline.DEFAULT_ISSUE_SEVERITY
    @test issue["description"] == DataPipeline.DIRTY_REPOSITORY_ISSUE
    DataPipeline.finalise(dirty)

    # Another run from the same state shares the one issue
    again = @test_logs (:warn, r"uncommitted changes") DataPipeline.initialise(config,
                                                                               config)
    @test again.repo_obj == dirty.repo_obj
    @test length(issue_urls()) == 1
    DataPipeline.finalise(again)

    # A run from another state with uncommitted changes gets an issue of its
    # own, although the registry already holds one with the same text
    other_config = DataPipeline._createconfig(cpath,
                                              latest_commit = DataPipeline._randomhash() *
                                                              "-dirty")
    other = @test_logs (:warn, r"uncommitted changes") DataPipeline.initialise(other_config,
                                                                               other_config)
    other_issues = DataPipeline._getentry(registry,
                                          URIs.URI(DataPipeline._wholeobjectcomponent(registry,
                                                                                      other.repo_obj)))["issues"]
    @test length(other_issues) == 1
    @test only(other_issues) != only(issue_urls())
    DataPipeline.finalise(other)

    # Its severity is the one the registry gives an issue when none is set
    unset = DataPipeline._postentry(registry, "issue",
                                    Dict("description" => "no severity $uid",
                                         "component_issues" => [component]))
    @test unset["severity"] == DataPipeline.DEFAULT_ISSUE_SEVERITY

    # A clean commit: no warning and no issue
    config = DataPipeline._createconfig(cpath,
                                        latest_commit = DataPipeline._randomhash())
    clean = @test_logs DataPipeline.initialise(config, config)
    @test isempty(DataPipeline._getentry(registry,
                                         URIs.URI(DataPipeline._wholeobjectcomponent(registry,
                                                                                     clean.repo_obj)))["issues"])
    DataPipeline.finalise(clean)
end

Test.@testset "identify() a git repository" begin
    registry = handle.registry

    # A repository of our own: two commits on its branch, one on another, and
    # a remote the registry will know it by
    dir = mktempdir()
    repo = LibGit2.init(dir)
    remote = "https://github.com/FAIRDataPipeline/identify-fixture-$uid.git"
    close(LibGit2.GitRemote(repo, "origin", remote))
    # Committed long ago, so that every run is newer whatever time zone its
    # date was recorded in
    t0 = 1_000_000_000
    signature(t) = LibGit2.Signature("Test", "test@example.com", t, 0)
    # Each run's commits are new to the registry, although their dates are
    # fixed, because what they commit names the run
    committed(content) = "$content $uid\n"
    function commit!(content; t, refname = "HEAD", parents = String[])
        write(joinpath(dir, "a.txt"), committed(content))
        LibGit2.add!(repo, "a.txt")
        return string(LibGit2.commit(repo, content, refname = refname,
                                     author = signature(t),
                                     committer = signature(t),
                                     parent_ids = LibGit2.GitHash.(parents)))
    end
    parent_sha = commit!("first", t = t0)
    side_sha = commit!("side", t = t0 + 5, refname = "refs/heads/side",
                       parents = [parent_sha])
    head_sha = commit!("second", t = t0 + 10, parents = [parent_sha])
    # Two commits this clone lacks, the later-run one with the later hash, so
    # that only their run dates can order them newest first
    absent_sha, later_absent_sha = sort([DataPipeline._randomhash(),
                                            DataPipeline._randomhash()])

    # A run from a commit, writing one output
    function run_from!(commit, name; issue = nothing)
        config = DataPipeline._createconfig(cpath, latest_commit = commit,
                                            remote_repo = remote)
        data_product = "data_product/identify-repository/$uid/$name"
        DataPipeline._addwrite(config, data_product, "repository fixture",
                               file_type = "txt", use_version = version)
        run_handle = DataPipeline.initialise(config, config)
        write(link_write!(run_handle, data_product), "$name $uid\n")
        isnothing(issue) ||
            raise_issue(run_handle, DataPipeline.CodeRepository(), issue,
                        severity = 4)
        DataPipeline.finalise(run_handle)
        return data_product
    end
    second_output = run_from!(head_sha, "second", issue = "commit issue $uid")
    run_from!(side_sha, "side")
    run_from!("$head_sha-dirty", "dirty")
    run_from!(absent_sha, "absent")
    sleep(1)                               # run dates have whole seconds
    run_from!(later_absent_sha, "later absent")
    # The parent commit as Python registers a repository: the whole remote URL
    # as the path
    root_url = DataPipeline._postentry(registry, "storage_root",
                                       Dict("root" => "https://github.com/",
                                            "local" => false))["url"]
    location_url = DataPipeline._postentry(registry, "storage_location",
                                           Dict("path" => remote,
                                                "hash" => parent_sha,
                                                "public" => true,
                                                "storage_root" => root_url))["url"]
    object_url = DataPipeline._postentry(registry, "object",
                                         Dict("description" => "Remote code repository.",
                                              "storage_location" =>
                                                  location_url,
                                              "authors" =>
                                                  [DataPipeline._getauthorurl(registry)]))["url"]
    DataPipeline._postentry(registry, "code_run",
                            Dict("run_date" => Dates.format(now(),
                                              "yyyy-mm-dd HH:MM:SS"),
                                 "description" => "python-style run $uid",
                                 "code_repo" => object_url,
                                 "model_config" => handle.config_obj,
                                 "submission_script" => handle.script_obj))

    # By default the checked-out commit and its ancestors, newest first,
    # whichever way their paths were registered
    found = DataPipeline.identify(registry, dir)
    @test found isa DataPipeline.RepositoryIdentification
    @test samefile(found.path, dir)
    @test found.remote == remote
    @test found.head == head_sha
    @test !found.dirty
    @test found.selection == DataPipeline.AncestorCommits()
    @test [commit.sha for commit in found.commits] == [head_sha, parent_sha]
    @test !any(commit.dirty for commit in found.commits)
    @test found.commits[1].date == unix2datetime(t0 + 10)
    newest = only(found.commits[1].runs)
    @test only(newest.outputs).name == second_output
    @test only(found.commits[1].issues).description == "commit issue $uid"
    @test only(found.commits[2].runs).description == "python-style run $uid"
    text = sprint(show, MIME("text/plain"), found)
    @test occursin(remote, text)
    @test occursin("commit issue $uid", text)
    @test occursin(second_output, text)
    # A handle may be given instead of a registry
    @test [commit.sha
           for commit in DataPipeline.identify(handle, dir).commits] ==
          [head_sha, parent_sha]

    # Only the checked-out commit
    only_head = DataPipeline.identify(registry, dir,
                                      commits = DataPipeline.CheckedOutCommit())
    @test [commit.sha for commit in only_head.commits] == [head_sha]

    # Every commit: those in the clone by commit date, then those the clone
    # lacks, newest first by their earliest run
    every = DataPipeline.identify(registry, dir,
                                  commits = DataPipeline.AllCommits()).commits
    @test [(commit.sha, commit.dirty) for commit in every] ==
          [(head_sha, false), (side_sha, false), (parent_sha, false),
        (later_absent_sha, false), (absent_sha, false)]
    @test isnothing(every[end].date)

    # Runs with uncommitted changes only when asked for, each beside its commit,
    # whichever commits are selected
    shas(selection) = [(commit.sha, commit.dirty)
                       for commit in DataPipeline.identify(registry, dir,
                                                           commits = selection).commits]
    @test shas(DataPipeline.AncestorCommits(dirty = true)) ==
          [(head_sha, false), (head_sha, true), (parent_sha, false)]
    @test shas(DataPipeline.CheckedOutCommit(dirty = true)) ==
          [(head_sha, false), (head_sha, true)]
    @test shas(DataPipeline.AllCommits(dirty = true)) ==
          [(head_sha, false), (head_sha, true), (side_sha, false),
        (parent_sha, false), (later_absent_sha, false), (absent_sha, false)]
    @test occursin("with runs made with uncommitted changes",
                   sprint(show, MIME("text/plain"),
                          DataPipeline.identify(registry, dir,
                                                commits = DataPipeline.AllCommits(dirty = true))))

    # A selection is made with the keyword, and prints as it is written
    @test sprint(show, DataPipeline.AncestorCommits()) == "AncestorCommits()"
    @test sprint(show, DataPipeline.CheckedOutCommit(dirty = true)) ==
          "CheckedOutCommit(dirty = true)"
    @test DataPipeline.AllCommits(dirty = false) == DataPipeline.AllCommits()
    @test_throws MethodError DataPipeline.AllCommits(true)

    # Uncommitted changes in the checkout: a warning, and its commit taken as
    # committed
    write(joinpath(dir, "a.txt"), "edited")
    edited = @test_logs (:warn, r"uncommitted changes") DataPipeline.identify(registry,
                                                                              dir)
    @test edited.dirty
    @test [commit.sha for commit in edited.commits] == [head_sha, parent_sha]
    write(joinpath(dir, "a.txt"), committed("second"))
    @test !DataPipeline.identify(registry, dir).dirty

    # A commit nothing was run from
    commit!("third", t = t0 + 20)
    unrun = DataPipeline.identify(registry, dir,
                                  commits = DataPipeline.CheckedOutCommit())
    @test isempty(unrun.commits)
    @test occursin("no run registered", sprint(show, MIME("text/plain"), unrun))
    @test [commit.sha
           for commit in DataPipeline.identify(registry, dir).commits] ==
          [head_sha, parent_sha]

    # The repository is known by the remote its CLI configuration names, as
    # `fair run` records it, and by `origin` only when there is none
    LibGit2.set_remote_url(repo, "origin", "https://github.com/elsewhere/$uid")
    close(LibGit2.GitRemote(repo, "upstream", remote))
    @test isempty(DataPipeline.identify(registry, dir).commits)
    mkpath(joinpath(dir, ".fair"))
    DataPipeline.YAML.write_file(joinpath(dir, ".fair", "cli-config.yaml"),
                                 Dict("git" => Dict("remote" => "upstream")))
    by_upstream = DataPipeline.identify(registry, dir)
    @test by_upstream.remote == remote
    @test [commit.sha for commit in by_upstream.commits] ==
          [head_sha, parent_sha]

    # A folder inside the repository, a folder that is no repository, and
    # `commits` for a file are all mistakes
    mkdir(joinpath(dir, "sub"))
    @test_throws ArgumentError DataPipeline.identify(registry,
                                                     joinpath(dir, "sub"))
    @test_throws ArgumentError DataPipeline.identify(registry, mktempdir())
    @test_throws ArgumentError DataPipeline.identify(registry,
                                                     joinpath(dir, "a.txt"),
                                                     commits = DataPipeline.AllCommits())
    close(repo)
end

Test.@testset "several file types for one extension" begin
    # The registry is unique on (name, extension) and ships descriptively named
    # types, and other APIs add their own names, so an extension can have
    # several - which must not stop an output being registered
    registry = handle.registry
    extension = "dp13$(uid[1:8])"
    for name in ("Julia written", "another API's name")
        DataPipeline._postentry(registry, "file_type",
                                Dict("name" => name, "extension" => extension))
    end
    listed = DataPipeline._getentry(registry,
                                    URIs.URI(registry.url * "file_type/" *
                                             DataPipeline._convertquery(registry,
                                                                        Dict("extension" =>
                                                                                 extension))))
    @test listed["count"] == 2
    # One of them is taken, and no third is created
    chosen = DataPipeline._getfiletype(registry, extension)
    @test chosen in [entry["url"] for entry in listed["results"]]
    @test DataPipeline._getfiletype(registry, extension) == chosen
    @test DataPipeline._getentry(registry,
                                 URIs.URI(registry.url * "file_type/" *
                                          DataPipeline._convertquery(registry,
                                                                     Dict("extension" =>
                                                                              extension))))["count"] ==
          2
    # An extension the registry has never seen is created, named after itself
    fresh = "dp13new$(uid[1:8])"
    url = DataPipeline._getfiletype(registry, fresh)
    @test DataPipeline._getentry(registry, URIs.URI(url))["name"] == fresh

    # A whole code run with that extension, as a second language's run leaves it
    data_product = "data_product/filetype/$uid"
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           file_type = extension, use_version = version)
    run_handle = DataPipeline.initialise(config, config)
    path = link_write!(run_handle, data_product)
    write(path, "file type $uid\n")
    DataPipeline.finalise(run_handle)
    @test DataPipeline._finddataproduct(registry, namespace, data_product,
                                        version)["name"] == data_product
end

Test.@testset "a lookup matching several entries is reported" begin
    registry = handle.registry
    extension = "dp13amb$(uid[1:8])"
    for name in ("one", "two")
        DataPipeline._postentry(registry, "file_type",
                                Dict("name" => name, "extension" => extension))
    end
    err = nothing
    try
        DataPipeline._getentry(registry, "file_type",
                               Dict("extension" => extension))
    catch e
        err = e
    end
    @test err isa DataPipeline.ReadWriteException
    @test occursin("2 entries in file_type", err.msg)
    @test occursin("expected at most one", err.msg)
end

Test.@testset "an output with already-registered bytes" begin
    first = "data_product/duplicate/$uid/first"
    second = "data_product/duplicate/$uid/second"

    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, first, "description", file_type = "txt",
                           use_version = version)
    DataPipeline._addwrite(config, second, "description", file_type = "txt",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    path1 = link_write!(handle, first)
    path2 = link_write!(handle, second)
    write(path1, "the same bytes $uid\n")
    write(path2, "the same bytes $uid\n")
    DataPipeline.finalise(handle)

    # One file in the store, both data products pointing at it; finalise
    # registers in name order, so it is the first's that is kept
    kept = handle.outputs[(first, nothing)]["path"]
    @test handle.outputs[(second, nothing)]["path"] == kept
    @test dirname(kept) == dirname(path1)
    @test isfile(kept)
    @test !isfile(path1) && !isfile(path2)
    @test !isdir(dirname(path2))
    @test isdir(joinpath(datastore, namespace, "data_product/duplicate/$uid"))
    registry = handle.registry
    objects = [DataPipeline._getentry(registry,
                                      URIs.URI(DataPipeline._finddataproduct(registry,
                                                                             namespace,
                                                                             name,
                                                                             version)["object"]))
               for name in (first, second)]
    @test objects[1]["url"] != objects[2]["url"]
    @test objects[1]["storage_location"] == objects[2]["storage_location"]
    @test length(unique(handle.outputs[key]["component_url"]
                        for key in keys(handle.outputs))) == 2
end

Test.@testset "\${{RUN_ID}} in an output name" begin
    data_product = "data_product/run_id/$uid"
    use_name = "data_product/run_id/$uid/run-\${{ RUN_ID }}"

    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           file_type = "txt", use_version = version,
                           use_data_product = use_name)
    handle = DataPipeline.initialise(config, config)
    path = link_write!(handle, data_product)
    # The placeholder is not known until finalise, so the temporary file sits
    # in a directory named with it
    @test occursin("\${{ RUN_ID }}", path)
    write(path, "run id $uid\n")
    raise_issue(handle, data_product, "run id issue $uid")
    DataPipeline.finalise(handle)

    registered = replace(use_name, "\${{ RUN_ID }}" => handle.code_run_uuid)
    wmd = handle.outputs[(data_product, nothing)]
    @test wmd["use_dp"] == registered
    @test !occursin("RUN_ID", wmd["path"])
    @test dirname(wmd["path"]) == joinpath(datastore, namespace, registered)
    @test isfile(wmd["path"])
    @test !isdir(dirname(path))
    entry = DataPipeline._finddataproduct(handle.registry, namespace,
                                          registered, version)
    @test entry["name"] == registered
    @test DataPipeline._getentry(handle.registry, "issue",
                                 Dict("description" => "run id issue $uid"))["component_issues"] ==
          [wmd["component_url"]]
end

Test.@testset "registry from the working config" begin
    data_product = "data_product/link_write/$uid"
    launched = DataPipeline.RegistryEndpoint(launch_url)
    # The same registry under its other host name
    other_host = occursin("127.0.0.1", launched.url) ? "localhost" : "127.0.0.1"
    other_url = replace(launched.url, r"//[^:/]+" => "//" * other_host)
    @test other_url != launched.url

    config = DataPipeline._createconfig(cpath,
                                        local_data_registry_url = other_url,
                                        api_version = "1.0.0")
    DataPipeline._addread(config, data_product, use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.registry.url == other_url
    @test handle.registry.api_version == "1.0.0"
    @test startswith(handle.code_run_obj, other_url)

    # Reads resolve, with ids extracted from URLs of that host
    path = link_read!(handle, data_product)
    @test isfile(path)
    @test startswith(handle.inputs[(data_product, nothing)]["component_url"],
                     other_url)
    DataPipeline.finalise(handle)
    code_run = DataPipeline._getentry(handle.registry,
                                      URIs.URI(handle.code_run_obj))
    @test length(code_run["inputs"]) == 1

    # A registry that is not there is reported as such
    config = DataPipeline._createconfig(cpath,
                                        local_data_registry_url = "http://127.0.0.1:1/api/")
    @test_throws DataPipeline.ReadWriteException DataPipeline.initialise(config,
                                                                         config)
end

Test.@testset "the registry token" begin
    config = DataPipeline._createconfig(cpath)

    # Taken from the environment that `fair run` set, unless one is given
    @test handle.registry.token == DataPipeline.FDP_LOCAL_TOKEN()
    # A token given is the one sent, so a wrong one is refused by the registry
    @test_throws DataPipeline.HTTP.StatusError DataPipeline.initialise(config,
                                                                       config,
                                                                       token = "not-a-token")

    # With none, registering fails before any request, saying why
    @test_throws DataPipeline.ReadWriteException DataPipeline.initialise(config,
                                                                         config,
                                                                         token = nothing)
    withenv("FDP_LOCAL_TOKEN" => nothing) do
        @test_throws DataPipeline.ReadWriteException DataPipeline.initialise(config,
                                                                             config)
    end

    # And so does the code run's update at `finalise`
    tokenless = DataPipeline.RegistryEndpoint(handle.registry.url)
    fields = (name == :registry ? tokenless : getfield(handle, name)
              for name in fieldnames(DataPipeline.DataRegistryHandle))
    @test_throws DataPipeline.ReadWriteException DataPipeline._patchcoderun(DataPipeline.DataRegistryHandle(fields...),
                                                                            String[],
                                                                            String[])
end

end
