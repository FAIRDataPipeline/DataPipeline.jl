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
    @test handle.issues[3].severity == 0
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

end
