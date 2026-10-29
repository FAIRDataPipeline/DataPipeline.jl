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

    # Finalise Code Run, which returns the data store the outputs are under
    @test DataPipeline.finalise(handle) == datastore

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

Test.@testset "write_array!()" begin
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_array!(handle, data1, data_product, component1, "description1")
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_array!(handle, data1, data_product, component1, "description1")
    @test length(handle.outputs) == 1
    write_array!(handle, data2, data_product, component2, "description2")
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

Test.@testset "read_array!()" begin
    data_product = "data_product/write_array/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_array!(handle, data_product, component1)
    dat2 = read_array!(handle, data_product, component2)
    @test dat1 == data1
    @test dat2 == data2
    # A second read returns the data again, not the handle key
    @test read_array!(handle, data_product, component1) == data1
    @test length(handle.inputs) == 2

    # A component is compulsory
    @test_throws MethodError read_array!(handle, data_product)

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check handle
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
    @test startswith(handle.inputs[(data_product, component1)]["component_url"],
                     handle.registry.url * "object_component/")
end

Test.@testset "write_estimate!()" begin
    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_estimate!(handle, estimate1, data_product, component1, "description1")
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_estimate!(handle, estimate1, data_product, component1, "description1")
    @test length(handle.outputs) == 1
    write_estimate!(handle, estimate2, data_product, component2, "description2")
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

Test.@testset "read_estimate!()" begin
    data_product = "data_product/write_estimate/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_estimate!(handle, data_product, component1)
    dat2 = read_estimate!(handle, data_product, component2)
    @test dat1 == estimate1
    @test dat2 == estimate2
    @test read_estimate!(handle, data_product, component1) == estimate1

    @test_throws MethodError read_estimate!(handle, data_product)

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check handle 
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
end

Test.@testset "write_distribution!()" begin
    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, data_product, "description",
                           use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Write components
    write_distribution!(handle, distribution["distribution"],
                        distribution["parameters"],
                        data_product, component1, "symptom-delay")
    @test handle.outputs[(data_product, component1)]["use_dp"] == data_product
    @test length(handle.outputs) == 1
    write_distribution!(handle, distribution["distribution"],
                        distribution["parameters"],
                        data_product, component1, "symptom-delay")
    @test length(handle.outputs) == 1
    write_distribution!(handle, distribution["distribution"],
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

Test.@testset "read_distribution!()" begin
    data_product = "data_product/write_distribution/$uid"

    # Create working config.yaml
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, data_product, use_version = version)
    handle = DataPipeline.initialise(config, config)
    @test handle.outputs == Dict()

    # Read components
    dat1 = read_distribution!(handle, data_product, component1)
    dat2 = read_distribution!(handle, data_product, component2)
    @test dat1 == distribution
    @test dat2 == distribution

    # Finalise Code Run
    DataPipeline.finalise(handle)

    # Check handle
    @test handle.inputs[(data_product, component1)]["use_dp"] == data_product
    @test handle.inputs[(data_product, component2)]["use_dp"] == data_product
end

# A version that exists is never written again, so a component added to one
# is refused at the write, before anything is registered
Test.@testset "new components aren't added to existing data products" begin
    registry = handle.registry
    writers = ("write_array" =>
                   (handle, name) -> write_array!(handle, data1,
                                                  name,
                                                  component3,
                                                  "description3"),
               "write_estimate" =>
                   (handle, name) -> write_estimate!(handle,
                                                     estimate1,
                                                     name,
                                                     component3,
                                                     "description3"),
               "write_distribution" =>
                   (handle, name) -> write_distribution!(handle,
                                                         distribution["distribution"],
                                                         distribution["parameters"],
                                                         name,
                                                         component3,
                                                         "symptom-delay"))
    for (writer, writing) in writers
        data_product = "data_product/$writer/$uid"
        config = DataPipeline._createconfig(cpath)
        DataPipeline._addwrite(config, data_product, "description",
                               use_version = version)
        handle = DataPipeline.initialise(config, config)
        err = @test_throws DataPipeline.ReadWriteException writing(handle,
                                                                   data_product)
        @test startswith(err.value.msg,
                         "$namespace:$data_product@v$version is registered already")
        @test isempty(handle.outputs)
        DataPipeline.finalise(handle)

        # The version is as it was, and the code run has no outputs
        entries = DataPipeline._getentries(registry, "data_product",
                                           Dict("name" => data_product))
        @test [entry["version"] for entry in entries] == [version]
        object = DataPipeline._extractid(only(entries)["object"])
        @test isnothing(DataPipeline._getentry(registry, "object_component",
                                               Dict("object" => object,
                                                    "name" => component3)))
        @test isempty(DataPipeline._getentry(registry,
                                             URIs.URI(handle.code_run_obj))["outputs"])
    end
end

# The issues of a component, as the registry holds them
function issues_of(registry, component_url)
    return DataPipeline._getentry(registry, URIs.URI(component_url))["issues"]
end

Test.@testset "names outside the convention are refused at a write" begin
    # The convention: a namespace of ASCII letters, digits, '_' and '-'; a
    # data product name of parts of the same joined by '/'; a component the
    # same. Checked where a name is registered, not where one is read.
    config = DataPipeline._createconfig(cpath)
    spaced = "data_product/refused name/$uid"
    dotted = "data_product/refused/$uid"
    spaced_namespace = "data_product/refused_namespace/$uid"
    accepted = "data_product/refused_accepted/$uid"
    DataPipeline._addwrite(config, spaced, "refused description",
                           file_type = "txt", use_version = version)
    DataPipeline._addwrite(config, dotted, "refused description",
                           file_type = "txt", use_version = version,
                           use_data_product = "$dotted/.txt")
    DataPipeline._addwrite(config, spaced_namespace, "refused description",
                           file_type = "toml", use_version = version,
                           use_namespace = "no such namespace")
    DataPipeline._addwrite(config, accepted, "refused description",
                           file_type = "toml", use_version = version)
    handle = DataPipeline.initialise(config, config)
    err = @test_throws ArgumentError link_write!(handle, spaced)
    @test occursin("is not a data product name", err.value.msg)
    err = @test_throws ArgumentError link_write!(handle, dotted)
    @test occursin("'$dotted/.txt' is not a data product name", err.value.msg)
    err = @test_throws ArgumentError write_estimate!(handle, 1.0,
                                                     spaced_namespace, "point",
                                                     "refused")
    @test occursin("is not a namespace", err.value.msg)
    err = @test_throws ArgumentError write_estimate!(handle, 1.0, accepted,
                                                     "a point", "refused")
    @test occursin("'a point' is not a component name", err.value.msg)
    @test isempty(handle.outputs)
    write_estimate!(handle, 1.0, accepted, "a/point-1_2", "accepted")
    @test haskey(handle.outputs, (accepted, "a/point-1_2"))
    DataPipeline.finalise(handle)
end

Test.@testset "supersede = true" begin
    registry = handle.registry
    name = "data_product/supersede/$uid"
    estimates = "data_product/supersede_estimate/$uid"
    writing(name, version) = begin
        config = DataPipeline._createconfig(cpath)
        DataPipeline._addwrite(config, name, "supersede description",
                               file_type = "txt", use_version = version)
        DataPipeline.initialise(config, config)
    end
    superseding(version) = "Superseded by $namespace:$name@v$version"

    # The first version of a name supersedes nothing, and says so at finalise
    first_handle = writing(name, "0.0.1")
    write(link_write!(first_handle, name, supersede = true),
          "supersede first $uid\n")
    @test_logs (:info, r"first version of its name") match_mode=:any DataPipeline.finalise(first_handle)
    @test isempty(first_handle.issues)
    first_file = first_handle.outputs[(name, nothing)]["path"]

    # A second version supersedes the first: an issue on the first, at the
    # lowest severity, registered at finalise and reported by identify
    second = writing(name, "0.0.2")
    write(link_write!(second, name, supersede = true),
          "supersede second $uid\n")
    DataPipeline.finalise(second)
    issue = only(second.issues)
    @test issue.severity == 0
    @test issue.description == superseding("0.0.2")
    @test issue.targets ==
          [DataPipeline.ExistingDataProduct("$namespace:$name@v0.0.1")]
    registered = DataPipeline._getentry(registry, "issue",
                                        Dict("description" =>
                                                 superseding("0.0.2")))
    @test registered["severity"] == 0
    first_product = DataPipeline._finddataproduct(registry, namespace, name,
                                                  "0.0.1")
    @test registered["component_issues"] ==
          [DataPipeline._wholeobjectcomponent(registry,
                                              first_product["object"])]
    found = only(DataPipeline.identify(registry, first_file).objects)
    @test any(issue.severity == 0 && issue.description == superseding("0.0.2")
              for issue in found.issues)

    # The same bytes again are a version identical to the one before, which
    # they do not supersede, said at finalise, a path given or not
    third = writing(name, "0.0.3")
    write(link_write!(third, name, supersede = true),
          "supersede second $uid\n")
    @test_logs (:info, r"@v0.0.3 is identical to v0.0.2") match_mode=:any DataPipeline.finalise(third)
    @test isempty(third.issues)
    @test third.identical == Dict((name, nothing) => "0.0.2")
    same = joinpath(mktempdir(), "same.txt")
    write(same, "supersede second $uid\n")
    by_path = writing(name, "0.0.4")
    link_write!(by_path, name, path = same, supersede = true)
    @test_logs (:info, r"@v0.0.4 is identical to v0.0.3") match_mode=:any DataPipeline.finalise(by_path)
    @test isempty(by_path.issues)
    # A version above the highest supersedes it; one below does not
    above = writing(name, "0.1.0")
    write(link_write!(above, name, supersede = true), "supersede above $uid\n")
    DataPipeline.finalise(above)
    @test only(above.issues).targets ==
          [DataPipeline.ExistingDataProduct("$namespace:$name@v0.0.4")]
    below = writing(name, "0.0.5")
    write(link_write!(below, name, supersede = true), "supersede below $uid\n")
    @test_logs (:info, r"not above the highest version, 0.1.0") match_mode=:any DataPipeline.finalise(below)
    @test isempty(below.issues)
    # Without the keyword nothing is said or raised
    plain = writing(name, "0.2.0")
    write(link_write!(plain, name), "supersede plain $uid\n")
    @test_logs DataPipeline.finalise(plain)
    @test isempty(plain.issues)
    # Bytes of an older version, not the highest's, supersede the highest
    older = writing(name, "0.3.0")
    write(link_write!(older, name, supersede = true),
          "supersede second $uid\n")
    DataPipeline.finalise(older)
    @test older.identical == Dict((name, nothing) => "0.0.4")
    @test only(older.issues).targets ==
          [DataPipeline.ExistingDataProduct("$namespace:$name@v0.2.0")]

    # A component writer supersedes the same way, once for the data product
    estimating = writing(estimates, "0.0.1")
    write_estimate!(estimating, 1.0, estimates, "point", "first estimate")
    DataPipeline.finalise(estimating)
    again = writing(estimates, "0.0.2")
    write_estimate!(again, 2.0, estimates, "point", "second estimate",
                    supersede = true)
    write_estimate!(again, 3.0, estimates, "other", "second estimate")
    DataPipeline.finalise(again)
    @test only(again.issues).description ==
          "Superseded by $namespace:$estimates@v0.0.2"
    @test only(again.issues).targets ==
          [DataPipeline.ExistingDataProduct("$namespace:$estimates@v0.0.1")]
end

Test.@testset "the released names, deprecated, and a repeated read" begin
    estimates = "data_product/deprecated/$uid"
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, estimates, "deprecated description",
                           file_type = "toml", use_version = version)
    writing = DataPipeline.initialise(config, config)
    @test write_estimate(writing, 1.5, estimates, "point", "d") ==
          (estimates, "point")
    @test write_distribution(writing, "Gaussian", Dict("mean" => 1.0),
                             estimates, "spread", "d") == (estimates, "spread")
    @test_throws DataPipeline.ReadWriteException write_table(writing, nothing,
                                                             estimates, "table")
    # Tables are not yet implemented: the error says what to do instead
    err = @test_throws DataPipeline.ReadWriteException write_table!(writing,
                                                                    nothing,
                                                                    estimates,
                                                                    "table")
    @test occursin("tables are not yet implemented", err.value.msg)
    @test occursin("link_write!(handle, \"$estimates\")", err.value.msg)
    raise_issue(writing, DataPipeline.WorkingConfig(), "deprecated $uid")
    @test length(writing.issues) == 1
    DataPipeline.finalise(writing)
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, estimates, use_version = version)
    reading = DataPipeline.initialise(config, config)
    @test read_estimate(reading, estimates, "point") == 1.5
    @test read_distribution(reading, estimates, "spread")["distribution"] ==
          "Gaussian"
    @test_throws DataPipeline.ReadWriteException read_table(reading, estimates,
                                                            "table")
    err = @test_throws DataPipeline.ReadWriteException read_table!(reading,
                                                                   estimates,
                                                                   "table")
    @test occursin("link_read!(handle, \"$estimates\")", err.value.msg)
    # A repeated read leaves the recorded input as it was
    recorded = reading.inputs[(estimates, "point")]
    @test read_estimate!(reading, estimates, "point") == 1.5
    @test reading.inputs[(estimates, "point")] === recorded
    DataPipeline.finalise(reading)
end

Test.@testset "raise_issue!() on bytes other versions share" begin
    registry = handle.registry
    name = "data_product/same_bytes/$uid"
    function writing(text, use_version)
        config = DataPipeline._createconfig(cpath)
        DataPipeline._addwrite(config, name, "same bytes description",
                               file_type = "txt", use_version = use_version)
        run = DataPipeline.initialise(config, config)
        write(link_write!(run, name), text)
        return run
    end
    whole(run) = run.outputs[(name, nothing)]["component_url"]
    first_x = writing("same bytes x $uid\n", "0.0.1")
    DataPipeline.finalise(first_x)
    first_y = writing("same bytes y $uid\n", "0.0.2")
    DataPipeline.finalise(first_y)
    # The bytes of 0.0.1 again at 0.0.3: the issue is on 0.0.3 alone, with a
    # warning naming the keyword and 0.0.1
    second_x = writing("same bytes x $uid\n", "0.0.3")
    raise_issue!(second_x, name, "same bytes $uid")
    @test_logs (:warn, r"@v0.0.1 has the same bytes.*all_versions = true") match_mode=:any DataPipeline.finalise(second_x)
    @test DataPipeline._getentry(registry, "issue",
                                 Dict("description" => "same bytes $uid"))["component_issues"] ==
          [whole(second_x)]
    # Asked for, the issue reaches every version with those bytes, with no
    # warning; the one output being identical is said
    second_y = writing("same bytes y $uid\n", "0.0.4")
    raise_issue!(second_y, name, "all versions $uid", all_versions = true)
    @test_logs (:info, r"every output of this code run is identical") DataPipeline.finalise(second_y)
    @test Set(DataPipeline._getentry(registry, "issue",
                                     Dict("description" => "all versions $uid"))["component_issues"]) ==
          Set([whole(second_y), whole(first_y)])
end

Test.@testset "raise_issue!()" begin
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
    raise_issue!(handle, DataPipeline.WorkingConfig(), "config $uid",
                 severity = 3)
    raise_issue!(handle,
                 [
                     DataPipeline.SubmissionScript(),
                     DataPipeline.CodeRepository()
                 ], "run $uid",
                 severity = 7)
    raise_issue!(handle, written, "input $uid")
    raise_issue!(handle,
                 DataPipeline.ConfigDataProduct(data_product,
                                                component = component1),
                 "output $uid", severity = 1)
    raise_issue!(handle,
                 DataPipeline.ExistingDataProduct("$namespace:$estimates@v$version",
                                                  component = component2),
                 "existing $uid", severity = 2)
    # A string holding a colon names a registered data product: its newest
    # version, with none given
    raise_issue!(handle, "$namespace:$estimates", "newest $uid")
    @test length(handle.issues) == 6
    @test handle.issues[6].targets ==
          [DataPipeline.ExistingDataProduct("$namespace:$estimates")]
    @test handle.issues[3].targets == [DataPipeline.ConfigDataProduct(written)]
    @test handle.issues[3].severity == DataPipeline.DEFAULT_ISSUE_SEVERITY
    @test isnothing(DataPipeline._getentry(registry, "issue",
                                           Dict("description" => "config $uid")))

    # A data product not in the config is rejected at once
    @test_throws DataPipeline.ConfigFileException raise_issue!(handle,
                                                               "not/in/config",
                                                               "bad")
    @test_throws ArgumentError raise_issue!(handle, "no such:name", "bad")
    @test length(handle.issues) == 6

    link_read!(handle, written)
    write_estimate!(handle, estimate1, data_product, component1, "description1")
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
    newest = DataPipeline._latestdataproduct(registry, namespace, estimates)
    @test issue("newest $uid")["component_issues"] ==
          [DataPipeline._wholeobjectcomponent(registry, newest["object"])]
    @test issue("run $uid")["url"] in
          issues_of(registry, whole(handle.repo_obj))

    # Several targets at once take the same default severity as one
    DataPipeline._resetsession!()
    several = DataPipeline.initialise(config, config)
    raise_issue!(several, [DataPipeline.WorkingConfig()], "default $uid")
    @test only(several.issues).severity == DataPipeline.DEFAULT_ISSUE_SEVERITY
    DataPipeline.finalise(several)

    # Raised again on exactly the same components, an issue is the one already
    # there; on other components, even overlapping ones, it is another
    DataPipeline._resetsession!()
    shared = DataPipeline.initialise(config, config)
    raise_issue!(shared,
                 [
                     DataPipeline.WorkingConfig(),
                     DataPipeline.SubmissionScript()
                 ],
                 "shared $uid")
    raise_issue!(shared, DataPipeline.WorkingConfig(), "shared $uid")
    raise_issue!(shared, DataPipeline.WorkingConfig(), "shared $uid")
    DataPipeline.finalise(shared)
    function shared_on(component_url)
        return [entry
                for entry in (DataPipeline._getentry(registry, URIs.URI(url))
                              for url in issues_of(registry, component_url))
                if entry["description"] == "shared $uid"]
    end
    on_config = shared_on(whole(shared.config_obj))
    @test sort([length(entry["component_issues"]) for entry in on_config]) ==
          [1, 2]
    @test length(shared_on(whole(shared.script_obj))) == 1
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

Test.@testset "a pattern read under each kind of working config" begin
    written = "data_product/link_write/$uid"
    arrays = "data_product/write_array/$uid"
    both = "data_product/*/$uid"
    nothing_yet = "data_product/nothing_yet/*"
    # A working config holding these read entries, each a name, or a name
    # with the mark of the pattern it was expanded from, or a pattern's own
    # entry as a CLI may keep it
    function opened(entries::Vector)
        config = DataPipeline._createconfig(cpath)
        for (name, mark) in entries
            DataPipeline._addread(config, name,
                                  use_version = occursin('*', name) ? nothing :
                                                version)
        end
        data = DataPipeline.YAML.load_file(config)
        for (entry, (_, mark)) in zip(data["read"], entries)
            isnothing(mark) || (entry["wildcard"] = mark)
        end
        DataPipeline.YAML.write_file(config, data)
        return DataPipeline.initialise(config, config)
    end
    path_of(handle, name) = (link_read!(handle, name);
                             handle.inputs[(name, nothing)]["path"])

    # As fair-cli 0.10.2 writes it - no pattern entries: names are matched,
    # and a pattern that matches none is an error
    handle = opened([written => nothing, arrays => nothing])
    @test length(link_read_files!(handle, both)) == 2
    @test_throws DataPipeline.ConfigFileException link_read_files!(handle,
                                                                   nothing_yet)
    @test !DataPipeline.canread(handle, nothing_yet)
    DataPipeline.finalise(handle)

    # With the patterns' own entries kept: still matched by name, the pattern
    # entry not among its matches; a kept pattern that matches nothing is an
    # empty result, and one never configured still an error
    handle = opened([written => nothing, arrays => nothing, both => nothing,
                        nothing_yet => nothing])
    @test link_read_files!(handle, both) ==
          [path_of(handle, written), path_of(handle, arrays)]
    @test link_read_files!(handle, nothing_yet) == String[]
    empty = link_read!(handle, nothing_yet)
    @test isdir(empty) && isempty(readdir(empty))
    @test DataPipeline.canread(handle, nothing_yet)
    @test_throws DataPipeline.ConfigFileException link_read_files!(handle,
                                                                   "data_product/never/*")
    # A pattern names no single data product, so takes no issue
    err = @test_throws ArgumentError raise_issue!(handle, both,
                                                  "a pattern $uid")
    @test occursin("is a pattern, which names no single data product",
                   err.value.msg)
    DataPipeline.finalise(handle)

    # With the expanded entries marked: a pattern's entries are those marked
    # with it, whatever else its matching would find - here `arrays`, which it
    # matches but is no expansion of it - and none marked is an empty result
    handle = opened([written => both, arrays => nothing, both => nothing,
                        nothing_yet => nothing])
    @test link_read_files!(handle, both) == [path_of(handle, written)]
    @test link_read_files!(handle, nothing_yet) == String[]
    @test DataPipeline.canread(handle, nothing_yet)
    DataPipeline.finalise(handle)
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
    @test isnothing(product.external_object) && isnothing(product.source)
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
    @test sprint(show, superseded) ==
          "$namespace:$data_product@v$version (superseded by v0.0.2)"
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

Test.@testset "initialise() opens a new code run, dated in UTC" begin
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, "data_product/new_run/$uid", "a new run",
                           file_type = "txt", use_version = version)
    # The code run of a handle, as the registry holds it
    run_of(handle) = DataPipeline._getentry(handle.registry,
                                            URIs.URI(handle.code_run_obj))

    # The registry records the date to the second. Where the machine's own
    # zone is UTC this cannot tell local time from UTC
    before = floor(now(UTC), Second)
    handle = DataPipeline.initialise(config, config)
    @test before <= DateTime(first(run_of(handle)["run_date"], 19)) <= now(UTC)

    # Two runs of one config started in the same second are two code runs
    moment = floor(now(UTC), Second)
    runs = [DataPipeline._newcoderun(handle.registry, "one second $uid",
                                     handle.repo_obj, handle.config_obj,
                                     handle.script_obj, run_date = moment)
            for _ in 1:2]
    @test runs[1]["run_date"] == runs[2]["run_date"]
    @test runs[1]["uuid"] != runs[2]["uuid"]
    DataPipeline._resetsession!()
end

Test.@testset "initialise() takes the script the working config names" begin
    job = joinpath(datastore, "coderun", datetime, "another-shell")
    script = joinpath(job, "script.jl")
    config = DataPipeline._createconfig(joinpath("coderun", datetime,
                                                 "another-shell",
                                                 "config.yaml"),
                                        script_path = script)
    write(script, "println(\"a script in another shell $uid\")\n")
    # The hash of the script a handle's run registered
    script_hash(handle) = DataPipeline._getstoragelocation(handle.registry,
                                                           handle.script_obj).hash

    # Launched by fair run, or given the working config alone, the script is
    # the one the working config names, not script.sh beside it
    handle = withenv("FDP_CONFIG_DIR" => job) do
        return DataPipeline.initialise()
    end
    @test script_hash(handle) == DataPipeline._getfilehash(script)
    DataPipeline._resetsession!()
    handle = withenv("FDP_CONFIG_DIR" => nothing) do
        return DataPipeline.initialise(config)
    end
    @test script_hash(handle) == DataPipeline._getfilehash(script)

    # A working config naming none has script.sh (script.bat on Windows)
    # beside it, and given alone with no FDP_CONFIG_DIR is an error
    data = DataPipeline.YAML.load_file(config)
    delete!(data["run_metadata"], "script_path")
    DataPipeline.YAML.write_file(config, data)
    beside = joinpath(job, DataPipeline.FDP_SUBMISSION_SCRIPT)
    write(beside, "a script beside its config $uid\n")
    DataPipeline._resetsession!()
    handle = withenv("FDP_CONFIG_DIR" => job) do
        return DataPipeline.initialise()
    end
    @test script_hash(handle) == DataPipeline._getfilehash(beside)
    DataPipeline._resetsession!()
    withenv("FDP_CONFIG_DIR" => nothing) do
        @test_throws DataPipeline.ConfigFileException DataPipeline.initialise(config)
    end
    DataPipeline._resetsession!()
end

Test.@testset "a run from uncommitted changes" begin
    registry = handle.registry
    # What `fair run --dirty` records for a working tree with uncommitted
    # changes: a warning, and an issue raised at once against the repository.
    # The commit is made up, so the checkout is not at it, which is said first
    config = DataPipeline._createconfig(cpath,
                                        latest_commit = DataPipeline._randomhash() *
                                                        "-dirty")
    elsewhere = (:warn, r"checkout is not what the run records")
    dirty = @test_logs elsewhere (:warn, r"uncommitted changes") DataPipeline.initialise(config,
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
    DataPipeline._resetsession!()
    again = @test_logs elsewhere (:warn, r"uncommitted changes") DataPipeline.initialise(config,
                                                                                         config)
    @test again.repo_obj == dirty.repo_obj
    @test length(issue_urls()) == 1
    DataPipeline.finalise(again)

    # A run from another state with uncommitted changes gets an issue of its
    # own, although the registry already holds one with the same text
    other_config = DataPipeline._createconfig(cpath,
                                              latest_commit = DataPipeline._randomhash() *
                                                              "-dirty")
    other = @test_logs elsewhere (:warn, r"uncommitted changes") DataPipeline.initialise(other_config,
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

    # A clean commit: no warning and no issue - a commit of a clone of its own,
    # which holds no metadata files, so that the run reads that clone
    clean_dir = mktempdir()
    clean_repo = LibGit2.init(clean_dir)
    write(joinpath(clean_dir, "a.txt"), "a clean commit $uid\n")
    LibGit2.add!(clean_repo, "a.txt")
    clean_sha = string(LibGit2.commit(clean_repo, "clean",
                                      author = LibGit2.Signature("Test",
                                                                 "test@example.com"),
                                      committer = LibGit2.Signature("Test",
                                                                    "test@example.com")))
    close(clean_repo)
    config = DataPipeline._createconfig(cpath, latest_commit = clean_sha,
                                        local_repo = clean_dir)
    clean = @test_logs DataPipeline.initialise(config, config)
    @test isempty(DataPipeline._getentry(registry,
                                         URIs.URI(DataPipeline._wholeobjectcomponent(registry,
                                                                                     clean.repo_obj)))["issues"])
    DataPipeline.finalise(clean)
end

# Not seen, by what is compared: a file changed and changed back between the
# two looks, and an untracked file the run reads. Not tested: a clone gone by
# `finalise`
Test.@testset "a checkout that moves during a run" begin
    registry = handle.registry
    # A clone of its own, its files naming the run: seven tracked text files
    # and an ignored one
    dir = mktempdir()
    repo = LibGit2.init(dir)
    signature = LibGit2.Signature("Test", "test@example.com")
    tracked = ["f$i.txt" for i in 1:7]
    file(name) = joinpath(dir, name)
    function commit!(text)
        for name in tracked
            write(file(name), "$text $name $uid\n")
        end
        write(file(".gitignore"), "ignored.txt\n")
        LibGit2.add!(repo, tracked..., ".gitignore")
        return string(LibGit2.commit(repo, text, author = signature,
                                     committer = signature))
    end
    restore!() = foreach(name -> write(file(name), "first $name $uid\n"),
                         tracked)
    first_sha = commit!("first")
    head() = string(LibGit2.head_oid(repo))
    # A run of the clone from `commit`, writing an output unless `output` is
    # false, with `before` done before it opens and `during` while it is open
    function moving(case; commit = head(), before = () -> nothing,
                    during = () -> nothing, output = true)
        before()
        config = DataPipeline._createconfig(cpath, latest_commit = commit,
                                            local_repo = dir,
                                            remote_repo = "https://github.com/FAIRDataPipeline/checkout-fixture-$uid.git")
        written = "data_product/checkout/$case/$uid"
        output && DataPipeline._addwrite(config, written, "checkout",
                               file_type = "txt",
                               use_version = "0.0.1")
        run = DataPipeline.initialise(config, config)
        output && write(link_write!(run, written), "checkout $case $uid\n")
        during()
        return run
    end
    # The descriptions of the issues on a run's outputs
    function raised_on(run)
        outputs = DataPipeline._getentry(registry,
                                         URIs.URI(run.code_run_obj))["outputs"]
        return [DataPipeline._getentry(registry, URIs.URI(url))["description"]
                for component in outputs
                for url in issues_of(registry, component)]
    end
    changed(names) = DataPipeline._movedcheckoutissue(["tracked files changed between the run opening and ending: $names"])

    # Left alone, or given untracked and ignored files: nothing said or raised
    run = @test_logs moving("still",
                            during = () -> begin
                                write(file("untracked.txt"), "u $uid\n")
                                write(file("ignored.txt"), "i $uid\n")
                            end)
    @test_logs DataPipeline.finalise(run)
    @test isempty(raised_on(run))

    # A tracked file changed during the run: a warning and one issue on the
    # outputs; more than five are named by the first five and a count
    run = moving("edited", during = () -> write(file("f1.txt"), "edited\n"))
    @test_logs (:warn,
                r"tracked files changed between the run opening and ending: f1\.txt\): raising an issue on the run's outputs") DataPipeline.finalise(run)
    @test raised_on(run) == [changed("f1.txt")]
    run = moving("many",
                 during = () -> foreach(name -> write(file(name), "many\n"),
                                        tracked))
    DataPipeline.finalise(run)
    @test raised_on(run) ==
          [changed("f1.txt, f2.txt, f3.txt, f4.txt, f5.txt and 2 more")]
    restore!()

    # Changed before the run opens, as a script may, and left alone: the
    # commit is the run's and nothing has changed while it ran
    run = @test_logs moving("before",
                            before = () -> write(file("f2.txt"), "before\n"))
    @test_logs DataPipeline.finalise(run)
    @test isempty(raised_on(run))
    # ... but changed again during it, it has
    run = moving("before-during",
                 during = () -> write(file("f2.txt"), "during\n"))
    DataPipeline.finalise(run)
    @test raised_on(run) == [changed("f2.txt")]
    restore!()

    # A commit made during the run: named, with the one before it
    second_sha = Ref("")
    run = moving("committed", during = () -> (second_sha[] = commit!("second")))
    @test_logs (:warn,
                r"checked out as the run opened and [0-9a-f]{40} as it ended") DataPipeline.finalise(run)
    @test raised_on(run) ==
          [DataPipeline._movedcheckoutissue(["it had $first_sha checked out as the run opened and $(second_sha[]) as it ended"])]

    # A run from a commit other than the one checked out: said as it opens,
    # and raised as it ends - or only said, with no output to raise it on
    elsewhere = "it had $(second_sha[]) checked out as the run opened, not the run's commit, $first_sha"
    run = @test_logs (:warn,
                      "the code repository's checkout is not what the run records ($elsewhere): an issue will be raised on the run's outputs") moving("elsewhere",
                                                                                                                                                      commit = first_sha)
    DataPipeline.finalise(run)
    @test raised_on(run) == [DataPipeline._movedcheckoutissue([elsewhere])]
    run = moving("elsewhere-nothing", commit = first_sha, output = false)
    @test_logs (:warn, r"and the run registered no output to raise an issue on") DataPipeline.finalise(run)

    # A run from uncommitted changes that change during it has both issues:
    # the one on the repository, and this one on its outputs
    run = @test_logs (:warn, r"uncommitted changes") moving("dirty",
                                                            commit = head() *
                                                                     "-dirty",
                                                            before = () -> write(file("f3.txt"),
                                                                                 "dirty\n"),
                                                            during = () -> write(file("f3.txt"),
                                                                                 "dirtier\n"))
    DataPipeline.finalise(run)
    @test raised_on(run) == [changed("f3.txt")]
    repository = DataPipeline._wholeobjectcomponent(registry, run.repo_obj)
    @test [DataPipeline._getentry(registry, URIs.URI(url))["description"]
           for url in issues_of(registry, repository)] ==
          [DataPipeline.DIRTY_REPOSITORY_ISSUE]
    close(repo)
end

Test.@testset "initialise() registers the code repository at its commit" begin
    registry = handle.registry
    # A clone of its own for each case, at a remote of its own, its files
    # naming the run so that its commit is new to the registry
    signature = LibGit2.Signature("Test", "test@example.com", 1_000_000_000, 0)
    fixtures = Ref(0)
    function fixture(files::Pair{String, String}...)
        fixtures[] += 1
        dir = mktempdir()
        repo = LibGit2.init(dir)
        for (name, text) in (files..., "run.txt" => "$uid $(fixtures[])\n")
            write(joinpath(dir, name), text)
            LibGit2.add!(repo, name)
        end
        sha = string(LibGit2.commit(repo, "fixture", author = signature,
                                    committer = signature))
        close(repo)
        return (dir = dir, sha = sha,
                remote = "https://github.com/FAIRDataPipeline/repository-fixture-$uid-$(fixtures[]).git")
    end
    function run_from(clone; commit = clone.sha)
        config = DataPipeline._createconfig(cpath, latest_commit = commit,
                                            local_repo = clone.dir,
                                            remote_repo = clone.remote)
        return config
    end
    function opened(config)
        run_handle = DataPipeline.initialise(config, config)
        DataPipeline.finalise(run_handle)
        return run_handle.repo_obj
    end
    entry(url) = DataPipeline._getentry(registry, URIs.URI(url))
    authors(object) = Set((author["name"], author["identifier"])
                          for author in entry.(entry(object)["authors"]))
    licences(object) = [(licence["licence_info"], licence["identifier"])
                        for licence in entry.(entry(object)["licences"])]
    keywords(object) = sort([keyword["keyphrase"]
                             for keyword in entry.(entry(object)["keywords"])])
    runner = entry(DataPipeline._getauthorurl(registry))
    ada = "https://orcid.org/0000-0002-1825-0097"
    codemeta = """
    {"name": "Fixture", "license": "https://spdx.org/licenses/MIT",
     "keywords": ["fixture", "repository $uid"],
     "author": [{"givenName": "Ada", "familyName": "Lovelace", "id": "$ada"},
                {"givenName": "Unidentified", "familyName": "Author $uid"}]}
    """

    # A new object has the repository's authors, by identifier where the
    # metadata gives one and by name alone where not, with its licence and
    # keywords
    with_metadata = fixture("codemeta.json" => codemeta)
    object = opened(run_from(with_metadata))
    @test entry(object)["description"] == DataPipeline.REPOSITORY_DESCRIPTION
    @test authors(object) == Set([("Ada Lovelace", ada),
                  ("Unidentified Author $uid", nothing)])
    @test licences(object) == [("MIT", "https://spdx.org/licenses/MIT")]
    @test keywords(object) == ["fixture", "repository $uid"]
    location = entry(entry(object)["storage_location"])
    @test location["hash"] == with_metadata.sha
    @test location["path"] ==
          "FAIRDataPipeline/repository-fixture-$uid-$(fixtures[]).git"

    # Another run from that commit keeps the object, and adds nothing to it
    # that it has
    @test opened(run_from(with_metadata)) == object
    @test length(licences(object)) == 1 && length(keywords(object)) == 2

    # ... nor a licence it holds under an identifier that the SPDX list has
    # since replaced, given by the identifier replacing it or by name
    replaced = DataPipeline._createentry(registry, "object",
                                         Dict("description" => "replaced licence $uid",
                                              "authors" => [runner["url"]]))["url"]
    gpl = ("GPL-3.0+", "https://spdx.org/licenses/GPL-3.0+")
    DataPipeline._createentry(registry, "licence",
                              Dict("object" => replaced,
                                   "licence_info" => gpl[1],
                                   "identifier" => gpl[2]))
    for given in ("GPL-3.0-or-later", "GNU General Public License v3.0 or later")
        DataPipeline._addlicence!(registry, replaced, given)
    end
    @test licences(replaced) == [gpl]
    DataPipeline._addlicence!(registry, replaced, "MIT")
    @test Set(licences(replaced)) ==
          Set([gpl, ("MIT", "https://spdx.org/licenses/MIT")])

    # An object the registry holds at the commit already is kept, whatever its
    # authors, and given the licence and keywords
    held_clone = fixture("codemeta.json" => codemeta)
    root = DataPipeline._postentry(registry, "storage_root",
                                   Dict("root" => "https://github.com/",
                                        "local" => false))["url"]
    held_location = DataPipeline._createentry(registry, "storage_location",
                                              Dict("path" => "another/path",
                                                   "hash" => held_clone.sha,
                                                   "public" => true,
                                                   "storage_root" => root))["url"]
    make_object() = DataPipeline._createentry(registry, "object",
                                              Dict("description" =>
                                                       DataPipeline.REPOSITORY_DESCRIPTION,
                                                   "storage_location" =>
                                                       held_location,
                                                   "authors" => [runner["url"]]))["url"]
    held = make_object()
    @test opened(run_from(held_clone)) == held
    @test authors(held) == Set([(runner["name"], runner["identifier"])])
    @test licences(held) == [("MIT", "https://spdx.org/licenses/MIT")]
    # Of several, the oldest; but one a release is registered on before it
    newer = make_object()
    @test opened(run_from(held_clone)) == held
    DataPipeline._createentry(registry, "code_repo_release",
                              Dict("name" => "repository fixture $uid",
                                   "version" => "1.0.0", "object" => newer))
    @test opened(run_from(held_clone)) == newer

    # A run from uncommitted changes reads the working tree, which is what ran
    edited = fixture("codemeta.json" => codemeta)
    write(joinpath(edited.dir, "codemeta.json"),
          """{"author": [{"name": "Edited Author $uid"}]}""")
    dirty_object = @test_logs((:warn, r"uncommitted changes"),
                              opened(run_from(edited,
                                              commit = "$(edited.sha)-dirty")))
    @test authors(dirty_object) == Set([("Edited Author $uid", nothing)])
    # ... and a clean run of the same commit the commit's files
    @test authors(opened(run_from(edited))) ==
          Set([("Ada Lovelace", ada), ("Unidentified Author $uid", nothing)])

    # No metadata files: the runner, as for any repository that is no package
    bare = fixture()
    @test authors(@test_logs(opened(run_from(bare)))) ==
          Set([(runner["name"], runner["identifier"])])

    # A clone without the commit, or no clone, is warned of, and the runner
    # is the author; a clone without it is at another commit, so its checkout
    # is warned of too, as the run opens and as it ends
    elsewhere = fixture("codemeta.json" => codemeta)
    absent = (dir = with_metadata.dir,
              sha = bytes2hex(DataPipeline.SHA.sha1("test_api.jl absent commit $uid")),
              remote = elsewhere.remote)
    @test authors(@test_logs((:warn, r"checkout is not what the run records"),
                             (:warn, r"does not have the run's commit"),
                             (:warn, r"no output to raise an issue on"),
                             opened(run_from(absent)))) ==
          Set([(runner["name"], runner["identifier"])])
    nowhere = (dir = joinpath(mktempdir(), "absent"), sha = elsewhere.sha,
               remote = elsewhere.remote)
    @test authors(@test_logs((:warn, r"names no clone"),
                             opened(run_from(nowhere)))) ==
          Set([(runner["name"], runner["identifier"])])

    # An author the registry cannot name, and a licence it cannot record, are
    # warned of and passed over
    odd = fixture("codemeta.json" => """
    {"license": "Not a licence $uid",
     "author": [{"name": "Star * Author"}, {"name": "Plain Author $uid"}]}
    """)
    odd_object = @test_logs((:warn,
                             r"cannot hold an author named 'Star \* Author'"),
                            (:warn,
                             r"licence 'Not a licence .*' is not recorded"),
                            opened(run_from(odd)))
    @test authors(odd_object) == Set([("Plain Author $uid", nothing)])
    @test isempty(licences(odd_object))

    # A rehearsal says what a recorded run would do, and registers nothing
    said(clone) = mktemp() do path, io
        redirect_stdout(io) do
            DataPipeline._rehearserepository(registry,
                                             DataPipeline.YAML.load_file(run_from(clone))["run_metadata"])
        end
        close(io)
        return read(path, String)
    end
    unregistered = fixture("codemeta.json" => codemeta)
    text = said(unregistered)
    @test occursin("would register the code repository at $(unregistered.sha), its authors Ada Lovelace, Unidentified Author $uid (from codemeta.json)",
                   text)
    @test occursin("  with the licence https://spdx.org/licenses/MIT", text)
    @test isnothing(DataPipeline._heldrepository(registry,
                                                 DataPipeline.YAML.load_file(run_from(unregistered))["run_metadata"]).object)
    @test occursin("would keep the code repository's object at $(with_metadata.sha), $object",
                   said(with_metadata))
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
                                            remote_repo = remote,
                                            local_repo = dir)
        data_product = "data_product/identify-repository/$uid/$name"
        DataPipeline._addwrite(config, data_product, "repository fixture",
                               file_type = "txt", use_version = version)
        run_handle = DataPipeline.initialise(config, config)
        write(link_write!(run_handle, data_product), "$name $uid\n")
        isnothing(issue) ||
            raise_issue!(run_handle, DataPipeline.CodeRepository(), issue,
                         severity = 4)
        DataPipeline.finalise(run_handle)
        return data_product
    end
    second_output = run_from!(head_sha, "second", issue = "commit issue $uid")
    run_from!(side_sha, "side")
    run_from!("$head_sha-dirty", "dirty")
    run_from!(absent_sha, "absent")
    sleep(1)                               # run dates have whole seconds
    run_from!(later_absent_sha, "later-absent")
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
                            Dict("run_date" => Dates.format(now(UTC),
                                              "yyyy-mm-ddTHH:MM:SSZ"),
                                 "description" => "python-style run $uid",
                                 "code_repo" => object_url,
                                 "model_config" => handle.config_obj,
                                 "submission_script" => handle.script_obj))

    # The checked-out commit and its ancestors, newest first, whichever way
    # their paths were registered
    found = DataPipeline.identify(registry,
                                  DataPipeline.AncestorCommits(repo = dir))
    @test found isa DataPipeline.RepositoryIdentification
    @test samefile(found.path, dir)
    @test found.remote == remote
    @test found.head == head_sha
    @test !found.dirty
    @test found.selection == DataPipeline.AncestorCommits(repo = dir)
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
    # The commits of a selection, and with whether each was dirty
    ids(selection) = [commit.sha
                      for commit in DataPipeline.identify(registry,
                                                          selection).commits]
    shas(selection) = [(commit.sha, commit.dirty)
                       for commit in DataPipeline.identify(registry,
                                                           selection).commits]
    # A handle may be given instead of a registry
    @test [commit.sha
           for commit in DataPipeline.identify(handle,
                                               DataPipeline.AncestorCommits(repo = dir)).commits] ==
          [head_sha, parent_sha]

    # Only the checked-out commit
    @test ids(DataPipeline.CheckedOutCommit(repo = dir)) == [head_sha]

    # Only what came before the checked-out commit, without the runs made from
    # it with uncommitted changes, which grew from it
    before_head = DataPipeline.AncestorCommits(including = false, repo = dir,
                                               dirty = true)
    @test shas(before_head) == [(parent_sha, false)]
    @test occursin("selected:    the ancestors of the checked-out commit,",
                   sprint(show, MIME("text/plain"),
                          DataPipeline.identify(registry, before_head)))

    # Every commit: those in the clone by commit date, then those the clone
    # lacks, newest first by their earliest run
    every = DataPipeline.identify(registry,
                                  DataPipeline.AllCommits(repo = dir)).commits
    @test [(commit.sha, commit.dirty) for commit in every] ==
          [(head_sha, false), (side_sha, false), (parent_sha, false),
        (later_absent_sha, false), (absent_sha, false)]
    @test isnothing(every[end].date)

    # Runs with uncommitted changes only when asked for, each beside its commit,
    # whichever commits are selected
    @test shas(DataPipeline.AncestorCommits(repo = dir, dirty = true)) ==
          [(head_sha, false), (head_sha, true), (parent_sha, false)]
    @test shas(DataPipeline.CheckedOutCommit(repo = dir, dirty = true)) ==
          [(head_sha, false), (head_sha, true)]
    @test shas(DataPipeline.AllCommits(repo = dir, dirty = true)) ==
          [(head_sha, false), (head_sha, true), (side_sha, false),
        (parent_sha, false), (later_absent_sha, false), (absent_sha, false)]
    @test occursin("with runs made with uncommitted changes",
                   sprint(show, MIME("text/plain"),
                          DataPipeline.identify(registry,
                                                DataPipeline.AllCommits(repo = dir,
                                                                        dirty = true))))

    # A selection is made with keywords, holds its repository as an absolute
    # path, and prints as it is written, with that path
    @test sprint(show, DataPipeline.AncestorCommits(repo = dir)) ==
          "AncestorCommits(repo = $(repr(dir)))"
    @test sprint(show,
                 DataPipeline.CheckedOutCommit(repo = dir, dirty = true)) ==
          "CheckedOutCommit(dirty = true, repo = $(repr(dir)))"
    @test DataPipeline.AllCommits(repo = dir, dirty = false) ==
          DataPipeline.AllCommits(repo = dir)
    @test DataPipeline.AllCommits(repo = joinpath(dir, "")) ==
          DataPipeline.AllCommits(repo = dir)
    @test_throws MethodError DataPipeline.AllCommits(true)

    # A repository given must be a top-level folder; left out, it is the
    # repository holding the current directory, found by walking up
    mkdir(joinpath(dir, "sub"))
    for folder in (joinpath(dir, "sub"), mktempdir(), joinpath(dir, "absent"))
        @test_throws ArgumentError DataPipeline.AllCommits(repo = folder)
    end
    cd(joinpath(dir, "sub")) do
        @test samefile(DataPipeline.AncestorCommits().repo, dir)
        @test samefile(DataPipeline.NamedCommit("v1.0").repo, dir)
    end
    cd(mktempdir()) do
        err = @test_throws ArgumentError DataPipeline.AllCommits()
        @test occursin("is not in a git repository: give `repo`",
                       err.value.msg)
    end

    # Uncommitted changes in the checkout: a warning, and its commit taken as
    # committed
    write(joinpath(dir, "a.txt"), "edited")
    edited = @test_logs (:warn, r"uncommitted changes") DataPipeline.identify(registry,
                                                                              DataPipeline.AncestorCommits(repo = dir))
    @test edited.dirty
    @test [commit.sha for commit in edited.commits] == [head_sha, parent_sha]
    write(joinpath(dir, "a.txt"), committed("second"))
    @test !DataPipeline.identify(registry,
                                 DataPipeline.AncestorCommits(repo = dir)).dirty

    # A commit nothing was run from
    commit!("third", t = t0 + 20)
    unrun = DataPipeline.identify(registry,
                                  DataPipeline.CheckedOutCommit(repo = dir))
    @test isempty(unrun.commits)
    @test occursin("no run registered", sprint(show, MIME("text/plain"), unrun))
    @test ids(DataPipeline.AncestorCommits(repo = dir)) ==
          [head_sha, parent_sha]

    # The repository is known by the remote its CLI configuration names, as
    # `fair run` records it, and by `origin` only when there is none
    LibGit2.set_remote_url(repo, "origin", "https://github.com/elsewhere/$uid")
    close(LibGit2.GitRemote(repo, "upstream", remote))
    @test isempty(ids(DataPipeline.AncestorCommits(repo = dir)))
    mkpath(joinpath(dir, ".fair"))
    DataPipeline.YAML.write_file(joinpath(dir, ".fair", "cli-config.yaml"),
                                 Dict("git" => Dict("remote" => "upstream")))
    by_upstream = DataPipeline.identify(registry,
                                        DataPipeline.AncestorCommits(repo = dir))
    @test by_upstream.remote == remote
    @test [commit.sha for commit in by_upstream.commits] ==
          [head_sha, parent_sha]

    # A commit by name - a full hash, a short hash, a tag, a branch - resolved
    # by the clone, with the runs made from it with uncommitted changes when
    # asked; the selection printed as written
    LibGit2.tag_create(repo, "v1.0", head_sha, sig = signature(t0 + 20))
    named(name; dirty = false) = DataPipeline.NamedCommit(name, repo = dir,
                                                          dirty = dirty)
    by_hash = DataPipeline.identify(registry, named(head_sha))
    @test [commit.sha for commit in by_hash.commits] == [head_sha]
    @test by_hash.selection == named(head_sha)
    @test ids(named(first(head_sha, 7))) == [head_sha]
    @test ids(named("v1.0")) == [head_sha]
    @test ids(named("side")) == [side_sha]
    tagged = DataPipeline.identify(registry, named("v1.0", dirty = true))
    @test [(commit.sha, commit.dirty) for commit in tagged.commits] ==
          [(head_sha, false), (head_sha, true)]
    @test sprint(show, named("v1.0")) ==
          "NamedCommit(\"v1.0\", repo = $(repr(dir)))"
    @test sprint(show, named("v1.0", dirty = true)) ==
          "NamedCommit(\"v1.0\", dirty = true, repo = $(repr(dir)))"
    @test occursin("selected:    the commit named \"v1.0\", with runs made",
                   sprint(show, MIME("text/plain"), tagged))

    # The ancestors of a commit by name rather than the checked-out one, with
    # or without it
    function ancestors(; kw...)
        return shas(DataPipeline.AncestorCommits(; repo = dir, kw...))
    end
    @test ancestors(of = "side") == [(side_sha, false), (parent_sha, false)]
    @test ancestors(of = "v1.0", dirty = true) ==
          [(head_sha, false), (head_sha, true), (parent_sha, false)]
    @test ancestors(of = first(head_sha, 7), including = false, dirty = true) ==
          [(parent_sha, false)]
    @test ancestors(of = parent_sha, including = false) == []
    side_text = sprint(show, MIME("text/plain"),
                       DataPipeline.identify(registry,
                                             DataPipeline.AncestorCommits(of = "side",
                                                                          repo = dir)))
    @test occursin("selected:    the commit named \"side\" and its ancestors\n",
                   side_text)
    @test sprint(show,
                 DataPipeline.AncestorCommits(of = "v1.0", including = false,
                                              repo = dir, dirty = true)) ==
          "AncestorCommits(of = \"v1.0\", including = false, dirty = true, repo = $(repr(dir)))"
    @test DataPipeline.AncestorCommits(of = SubString("v1.0"), repo = dir) ==
          DataPipeline.AncestorCommits(of = "v1.0", repo = dir)
    # Named, they are not about the checkout, so its uncommitted changes go
    # unremarked
    write(joinpath(dir, "a.txt"), "edited")
    @test_logs DataPipeline.identify(registry,
                                     DataPipeline.AncestorCommits(of = "v1.0",
                                                                  repo = dir))
    write(joinpath(dir, "a.txt"), committed("third"))
    # A name that resolves to no commit, or to one the clone lacks
    for selection in (named("no-such-ref-$uid"),
                      DataPipeline.AncestorCommits(of = "no-such-ref-$uid",
                                                   repo = dir))
        err = @test_throws ArgumentError DataPipeline.identify(registry,
                                                               selection)
        @test occursin("no such tag, branch or commit", err.value.msg)
    end
    err = @test_throws ArgumentError ancestors(of = absent_sha)
    @test occursin("which the clone at", err.value.msg)

    # By the URL of its remote, with no clone: every commit the registry
    # holds, with no dates, or a full hash; a selection that needs the clone
    # cannot be made, and a tag is asked of the remote, which this one, on no
    # host that answers for it, cannot be: a warning, and no commit
    by_url = DataPipeline.identify(registry,
                                   DataPipeline.AllCommits(repo = remote))
    @test by_url.selection == DataPipeline.AllCommits(repo = remote)
    @test by_url.path == remote && by_url.remote == remote
    @test isnothing(by_url.head) && !by_url.dirty
    @test Set(commit.sha for commit in by_url.commits) ==
          Set([head_sha, side_sha, parent_sha, absent_sha, later_absent_sha])
    @test all(isnothing(commit.date) for commit in by_url.commits)
    @test occursin("  no clone: the registry's record alone\n",
                   sprint(show, MIME("text/plain"), by_url))
    @test ids(DataPipeline.NamedCommit(head_sha, repo = remote)) == [head_sha]
    for make in (() -> DataPipeline.AncestorCommits(repo = remote),
        () -> DataPipeline.CheckedOutCommit(repo = remote),
        () -> DataPipeline.AncestorCommits(of = head_sha, repo = remote))
        err = @test_throws ArgumentError make()
        @test occursin("needs a clone", err.value.msg)
    end
    err = @test_logs((:warn, r"^cannot list the tags and branches of "),
                     @test_throws ArgumentError DataPipeline.identify(registry,
                                                                      DataPipeline.NamedCommit("v1.0",
                                                                                               repo = remote)))
    @test occursin("the remote at $remote has no such tag or branch",
                   err.value.msg)
    # A release the registry holds resolves its version with no clone, and
    # with a clone that has no such tag
    DataPipeline._postentry(registry, "code_repo_release",
                            Dict("name" => "identify fixture $uid",
                                 "version" => "3.1.4",
                                 "object" => object_url))
    @test ids(DataPipeline.NamedCommit("v3.1.4", repo = remote)) == [parent_sha]
    @test ids(named("3.1.4")) == [parent_sha]
    @test ancestors(of = "v3.1.4") == [(parent_sha, false)]

    # An issue on commits of the repository, raised outside a run at once: one
    # issue on the whole of every object standing for a selected commit,
    # returned as its URL
    components(url) = Set(DataPipeline._getentry(registry,
                                                 URIs.URI(url))["component_issues"])
    whole(sha) = Set(DataPipeline._wholeobjectcomponent(registry, object)
                     for commit in DataPipeline.identify(registry,
                                                         named(sha)).commits
                     for object in commit.objects)
    issues(sha) = [issue.description
                   for issue in only(DataPipeline.identify(registry,
                                                           named(sha)).commits).issues]
    before = DataPipeline.AncestorCommits(of = "v1.0", including = false,
                                          repo = dir)
    url = raise_issue!(registry, before, "before v1.0 $uid", severity = 3)
    @test url isa String
    @test components(url) == whole(parent_sha)
    issue = only(issue
                 for issue in only(DataPipeline.identify(registry,
                                                         named(parent_sha)).commits).issues
                 if issue.description == "before v1.0 $uid")
    @test issue.severity == 3
    @test !("before v1.0 $uid" in issues(head_sha))
    # The same issue again is the one registered, whether the selection is
    # given as it is or as the target it stands for
    @test raise_issue!(registry, DataPipeline.CodeRepository(before),
                       "before v1.0 $uid", severity = 3) == url
    # Several commits, one issue; by the remote's URL, with no clone
    from_tag = raise_issue!(registry,
                            DataPipeline.AncestorCommits(of = "v1.0",
                                                         repo = dir),
                            "from v1.0 $uid")
    @test components(from_tag) == union(whole(parent_sha), whole(head_sha))
    by_url_issue = raise_issue!(registry,
                                DataPipeline.NamedCommit(side_sha,
                                                         repo = remote),
                                "side by URL $uid")
    @test components(by_url_issue) == whole(side_sha)
    # With no registry given, the CLI's local registry and its token
    @test components(raise_issue!(named("side"), "side by CLI $uid")) ==
          whole(side_sha)
    # A data product registered already needs no run either, and goes into one
    # issue with commits
    second = only(only(only(DataPipeline.identify(registry,
                                                  named(head_sha)).commits).runs).outputs)
    second_name = DataPipeline._dataproductname(second.namespace, second.name,
                                                string(second.version))
    second_component = DataPipeline._wholeobjectcomponent(registry,
                                                          DataPipeline._getentry(registry,
                                                                                 URIs.URI(second.url))["object"])
    @test components(raise_issue!(registry, [second_name],
                                  "on the output $uid")) ==
          Set([second_component])
    @test components(raise_issue!(registry, [second_name, named("side")],
                                  "on the output and side $uid")) ==
          union(Set([second_component]), whole(side_sha))
    # What only a run has is refused by name, before anything is registered;
    # a selection that holds no registered commit is an error; and with no
    # token nothing is posted
    for target in (DataPipeline.CodeRepository(), DataPipeline.WorkingConfig(),
        "data_product/in/a/config")
        @test_throws ArgumentError raise_issue!(registry, target,
                                                "refused $uid")
    end
    err = @test_throws DataPipeline.ReadWriteException raise_issue!(registry,
                                                                    DataPipeline.CheckedOutCommit(repo = dir),
                                                                    "unrun $uid")
    @test occursin("holds no run of $remote from the checked-out commit",
                   err.value.msg)
    err = @test_throws DataPipeline.ReadWriteException raise_issue!(DataPipeline.RegistryEndpoint(registry.url),
                                                                    before,
                                                                    "no token $uid")
    @test occursin("no token", err.value.msg)
    # While the session rehearses, printed and not registered
    saved = DataPipeline.SESSION[]
    DataPipeline.SESSION[] = DataPipeline.SessionRun(DataPipeline.Rehearsal(mktempdir()),
                                                     mktempdir(), false, false,
                                                     nothing, false, nothing)
    printed = mktemp() do path, io
        result = redirect_stdout(io) do
            return raise_issue!(registry, before, "rehearsed $uid")
        end
        close(io)
        return (result = result, text = read(path, String))
    end
    DataPipeline.SESSION[] = saved
    @test isnothing(printed.result)
    @test occursin("registering nothing", printed.text)
    @test occursin(sprint(show, DataPipeline.CodeRepository(before)),
                   printed.text)
    @test !("rehearsed $uid" in issues(parent_sha))

    # Inside a run a selection is queued like any target and registered at
    # finalise, and one made while the run is open is of the run's own clone
    # unless `repo` says otherwise; the run's commit is drawn from this file's
    # name, which no other file's is
    run_sha = bytes2hex(DataPipeline.SHA.sha1("test_api.jl issue in a run $uid"))
    config = DataPipeline._createconfig(cpath, latest_commit = run_sha,
                                        remote_repo = remote, local_repo = dir)
    in_run = DataPipeline.initialise(config, config)
    before_side = DataPipeline.AncestorCommits(of = "side", including = false)
    @test samefile(before_side.repo, dir)
    raise_issue!(in_run, before_side, "in a run $uid")
    raise_issue!(in_run, DataPipeline.NamedCommit(side_sha, repo = remote),
                 "in a run by URL $uid")
    DataPipeline.finalise(in_run)
    @test "in a run $uid" in issues(parent_sha)
    @test "in a run by URL $uid" in issues(side_sha)
    # Once the run has ended, the default is the current directory's again
    @test !samefile(DataPipeline.AllCommits().repo, dir)

    # A repository named by position still works, as a deprecation, with the
    # selection's own repository replaced by it; `commits` for a file is a
    # mistake
    @test DataPipeline.identify(registry, dir).remote == remote
    by_position = DataPipeline.identify(registry, dir,
                                        commits = DataPipeline.AllCommits(repo = remote))
    @test samefile(by_position.path, dir)
    @test by_position.selection == DataPipeline.AllCommits(repo = dir)
    @test_throws ArgumentError DataPipeline.identify(registry,
                                                     joinpath(dir, "a.txt"),
                                                     commits = DataPipeline.AllCommits(repo = dir))
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

Test.@testset "link_write!() with a wildcard entry" begin
    pattern = "data_product/wild/$uid/*"
    covered = "data_product/wild/$uid/covered"
    exact = "data_product/wild/$uid/exact"
    aliased = "data_product/wild/$uid/aliased"

    config = DataPipeline._createconfig(cpath)
    # The CLI leaves a pattern entry whose use.data_product is the pattern
    # itself, and an exact entry for every name that already exists
    DataPipeline._addwrite(config, pattern, "wildcard description",
                           file_type = "txt", use_version = version,
                           use_data_product = pattern)
    DataPipeline._addwrite(config, exact, "exact description",
                           file_type = "csv", use_version = version,
                           use_data_product = aliased)
    handle = DataPipeline.initialise(config, config)

    # A name the pattern covers is written under its own name, with the
    # pattern entry's file type and description
    path = link_write!(handle, covered)
    @test dirname(path) == joinpath(datastore, namespace, covered)
    @test endswith(basename(path), ".txt")
    wmd = handle.outputs[(covered, nothing)]
    @test wmd["use_dp"] == covered
    @test wmd["dataproduct_description"] == "wildcard description"
    @test link_write!(handle, covered) == path

    # An entry naming it exactly wins, and keeps its own use: block
    path2 = link_write!(handle, exact)
    @test endswith(basename(path2), ".csv")
    @test handle.outputs[(exact, nothing)]["use_dp"] == aliased
    @test dirname(path2) == joinpath(datastore, namespace, aliased)

    # A component write reaches the same lookup
    estimates = "data_product/wild/$uid/estimates"
    write_estimate!(handle, estimate1, estimates, component1, "description1")
    @test handle.outputs[(estimates, component1)]["use_dp"] == estimates
    @test endswith(handle.outputs[(estimates, component1)]["path"], ".toml")

    write(path, "covered $uid\n")
    write(path2, "exact $uid\n")
    DataPipeline.finalise(handle)

    # The concrete names are registered, the pattern is not
    for name in (covered, aliased, estimates)
        @test DataPipeline._finddataproduct(handle.registry, namespace, name,
                                            version)["name"] == name
    end
    # The registry filters names with fnmatch, so querying the pattern lists
    # its matches - and shows that the pattern itself is not one of them
    matches = DataPipeline._getentry(handle.registry,
                                     URIs.URI(handle.registry.url *
                                              "data_product/" *
                                              DataPipeline._convertquery(handle.registry,
                                                                         Dict("name" =>
                                                                                  pattern))))
    @test Set(entry["name"] for entry in matches["results"]) ==
          Set([covered, estimates, aliased])
    @test !isdir(joinpath(datastore, namespace, pattern))

    # A name no entry covers, and one covered by two patterns, are refused
    @test_throws DataPipeline.ConfigFileException link_write!(handle,
                                                              "data_product/elsewhere/$uid")
    # A * matches one segment, so a deeper name is not covered
    @test_throws DataPipeline.ConfigFileException link_write!(handle,
                                                              "data_product/wild/$uid/a/b")

    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, "data_product/two/$uid/*", "first",
                           file_type = "txt", use_version = version)
    DataPipeline._addwrite(config, "data_product/*/$uid/both", "second",
                           file_type = "csv", use_version = version)
    handle = DataPipeline.initialise(config, config)
    err = nothing
    try
        link_write!(handle, "data_product/two/$uid/both")
    catch e
        err = e
    end
    @test err isa DataPipeline.ConfigFileException
    @test occursin("data_product/two/$uid/*", err.msg) &&
          occursin("data_product/*/$uid/both", err.msg)

    # Under the pattern alone, at the version its names now have, a name is
    # refused at the call, whatever it would have been written with
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, pattern, "wildcard description",
                           file_type = "txt", use_version = version,
                           use_data_product = pattern)
    again = DataPipeline.initialise(config, config)
    err = @test_throws DataPipeline.ReadWriteException link_write!(again,
                                                                   covered)
    @test startswith(err.value.msg,
                     "$namespace:$covered@v$version is registered already")
    @test isempty(again.outputs)
    DataPipeline.finalise(again)
end

Test.@testset "\${{RUN_ID}} in a wildcard-covered name" begin
    pattern = "data_product/wildrun/$uid/*"
    name = "data_product/wildrun/$uid/run-\${{RUN_ID}}"

    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, pattern, "description", file_type = "txt",
                           use_version = version, use_data_product = pattern)
    handle = DataPipeline.initialise(config, config)
    path = link_write!(handle, name)
    # Bytes no other test writes: two outputs with the same bytes are
    # deduplicated, which would point this one at the other test's file
    write(path, "wildcard run id $uid\n")
    DataPipeline.finalise(handle)

    registered = replace(name, "\${{RUN_ID}}" => handle.code_run_uuid)
    @test handle.outputs[(name, nothing)]["use_dp"] == registered
    @test DataPipeline._finddataproduct(handle.registry, namespace, registered,
                                        version)["name"] == registered
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
    raise_issue!(handle, data_product, "run id issue $uid")
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

# The versions of a data product that the registry holds, in order
function registered_versions(registry, name)
    return sort([entry["version"]
                 for entry in DataPipeline._getentries(registry, "data_product",
                                                       Dict("name" => name))])
end

# The code run of a handle, as the registry holds it
function code_run_of(handle)
    return DataPipeline._getentry(handle.registry,
                                  URIs.URI(handle.code_run_obj))
end

Test.@testset "several versions of one data product in one config" begin
    name = "data_product/versions/$uid"
    label_older = "versions/older/$uid"
    label_newer = "versions/newer/$uid"
    older, newer, newest = "1.0.0", "2.0.0", "2.0.1"
    labelled = ((label_older, older), (label_newer, newer))

    # Two versions written by one run: a label each, both naming the data
    # product in their use: block
    config = DataPipeline._createconfig(cpath)
    for (label, use_version) in labelled
        DataPipeline._addwrite(config, label, "description", file_type = "txt",
                               use_data_product = name,
                               use_version = use_version)
    end
    handle = DataPipeline.initialise(config, config)
    path_older = link_write!(handle, label_older)
    path_newer = link_write!(handle, label_newer)
    @test dirname(path_older) == joinpath(datastore, namespace, name)
    @test dirname(path_newer) == dirname(path_older)
    @test path_newer != path_older
    write(path_older, "older version $uid\n")
    write(path_newer, "newer version $uid\n")
    DataPipeline.finalise(handle)

    outputs = [handle.outputs[(label, nothing)] for (label, _) in labelled]
    @test registered_versions(handle.registry, name) == [older, newer]
    @test [DataPipeline._finddataproduct(handle.registry, namespace, name,
                                         use_version)["object"]
           for (_, use_version) in labelled] ==
          [wmd["object_url"] for wmd in outputs]
    @test outputs[1]["object_url"] != outputs[2]["object_url"]
    @test read(outputs[1]["path"], String) == "older version $uid\n"
    @test read(outputs[2]["path"], String) == "newer version $uid\n"
    written = [wmd["component_url"] for wmd in outputs]
    @test sort(code_run_of(handle)["outputs"]) == sort(written)

    # Both read by one run, under the same two labels
    config = DataPipeline._createconfig(cpath)
    for (label, use_version) in labelled
        DataPipeline._addread(config, label, use_data_product = name,
                              use_version = use_version)
    end
    handle = DataPipeline.initialise(config, config)
    @test read(link_read!(handle, label_older), String) ==
          "older version $uid\n"
    @test read(link_read!(handle, label_newer), String) ==
          "newer version $uid\n"
    @test [handle.inputs[(label, nothing)]["use_version"]
           for (label, _) in labelled] == [older, newer]
    DataPipeline.finalise(handle)
    @test sort(code_run_of(handle)["inputs"]) == sort(written)

    # One label in both blocks: read at the version that exists and written at
    # a new one, so the run's input and its output are different files
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, name, use_version = newer)
    DataPipeline._addwrite(config, name, "description", file_type = "txt",
                           use_version = newest)
    handle = DataPipeline.initialise(config, config)
    path_read = link_read!(handle, name)
    path_write = link_write!(handle, name)
    @test path_read == outputs[2]["path"]
    @test path_write != path_read
    @test link_read!(handle, name) == path_read
    write(path_write, "newest version $uid\n")
    DataPipeline.finalise(handle)

    code_run = code_run_of(handle)
    @test code_run["inputs"] == [written[2]]
    @test code_run["outputs"] ==
          [handle.outputs[(name, nothing)]["component_url"]]
    @test isdisjoint(code_run["inputs"], code_run["outputs"])
    @test registered_versions(handle.registry, name) == [older, newer, newest]
    @test read(path_read, String) == "newer version $uid\n"
    @test read(handle.outputs[(name, nothing)]["path"], String) ==
          "newest version $uid\n"
end

# A function that puts a link to a file, made by `link`, at a path, or a copy
# where no link can be made: across file systems, or a symbolic link on
# Windows without the privilege
function linking(link)
    return function (file, destination)
        try
            link(file, destination)
        catch e
            e isa Base.IOError || rethrow()
            cp(file, destination)
        end
    end
end

Test.@testset "a file placed is a file of its own" begin
    # Never a link, so that writing to either file in place leaves the other
    # as it was: on macOS a clone, which APFS, the runners' file system, makes
    # within a volume; else, or where no clone is made, a copy
    folder = mktempdir()
    source = joinpath(folder, "source-$uid.txt")
    write(source, "placed $uid\n")
    cloned = joinpath(folder, "cloned.txt")
    @test DataPipeline._clonefile(source, cloned) == Sys.isapple()
    @test isfile(cloned) == Sys.isapple()
    placed = DataPipeline._placefile(source, joinpath(folder, "placed.txt"))
    noclone(from, to) = false
    copied = DataPipeline._placefile(source, joinpath(folder, "copied.txt"),
                                     clone = noclone)
    for file in (placed, copied)
        @test read(file, String) == "placed $uid\n"
        @test !samefile(file, source)
    end
    write(source, "written in place $uid\n")
    @test read(placed, String) == read(copied, String) == "placed $uid\n"
    Sys.isapple() && @test read(cloned, String) == "placed $uid\n"
    write(placed, "placed, written in place $uid\n")
    @test read(source, String) == "written in place $uid\n"
    # A file there is never replaced, and no copy is left beside it
    @test_throws ArgumentError DataPipeline._placefile(source, copied,
                                                       clone = noclone)
    @test !DataPipeline._clonefile(source, copied)
    @test read(copied, String) == "placed $uid\n"
    @test sort(readdir(folder)) ==
          sort(["source-$uid.txt", "placed.txt", "copied.txt",
                   (Sys.isapple() ? ["cloned.txt"] : [])...])
end

Test.@testset "a folder of links where no symbolic link can be made" begin
    # As on Windows without the privilege: a file of its own, placed as
    # `_placefile` places one. A folder of a pattern read is placed this way,
    # which the pattern test checks only where symbolic links can be made
    source = joinpath(mktempdir(), "source-$uid.txt")
    write(source, "a folder of links $uid\n")
    folder = mktempdir()
    placed = joinpath(folder, "placed.txt")
    refused(from, to) = throw(Base.IOError("no symbolic links here", -1))
    @test DataPipeline._placelink(source, placed, link = refused) == placed
    @test !islink(placed)
    @test read(placed, String) == "a folder of links $uid\n"
    @test !samefile(placed, source)
    # Where one can be made, it is a symbolic link
    linked = DataPipeline._placelink(source, joinpath(folder, "linked.txt"))
    @test islink(linked) && normpath(readlink(linked)) == normpath(source)
    # Any other failure is not taken for a refusal
    broken(from, to) = error("not a refusal")
    @test_throws ErrorException DataPipeline._placelink(source,
                                                        joinpath(folder,
                                                                 "broken.txt"),
                                                        link = broken)
end

Test.@testset "link_write!() with a path" begin
    name = "data_product/path_write/$uid"
    outside = mktempdir()
    file = joinpath(outside, "fetched.txt")
    write(file, "fetched $uid\n")
    # A config with one write entry for the name, at the version offered
    function offering(use_version)
        config = DataPipeline._createconfig(cpath)
        DataPipeline._addwrite(config, name, "description", file_type = "txt",
                               use_version = use_version)
        return DataPipeline.initialise(config, config)
    end

    # A copy of the file is put in the data store under a temporary name,
    # and the file stays where it was
    handle = offering("0.0.1")
    stored = link_write!(handle, name, path = file)
    @test dirname(stored) == joinpath(datastore, namespace, name)
    @test startswith(basename(stored), "dat-") && endswith(stored, ".txt")
    @test read(stored, String) == "fetched $uid\n"
    @test !samefile(stored, file)
    @test length(handle.outputs) == 1
    # The same file again is the same output; another file is refused
    @test link_write!(handle, name, path = file) == stored
    @test link_write!(handle, name) == stored
    other = joinpath(outside, "other.txt")
    write(other, "other $uid\n")
    @test_throws DataPipeline.ReadWriteException link_write!(handle, name,
                                                             path = other)
    @test length(handle.outputs) == 1
    DataPipeline.finalise(handle)

    registered = handle.outputs[(name, nothing)]["path"]
    @test basename(registered) == DataPipeline._getfilehash(file) * ".txt"
    @test isfile(registered) && !isfile(stored)
    @test read(file, String) == "fetched $uid\n"
    @test !samefile(registered, file)
    # Writing to the file in place leaves the registered one as it was
    write(file, "fetched, written in place $uid\n")
    @test read(registered, String) == "fetched $uid\n"
    write(file, "fetched $uid\n")
    @test registered_versions(handle.registry, name) == ["0.0.1"]
    @test code_run_of(handle)["outputs"] ==
          [handle.outputs[(name, nothing)]["component_url"]]

    # The same bytes again are a new version, identical to the first and
    # sharing its file: the copy put in the store is dropped at finalise
    again = joinpath(outside, "again.txt")
    cp(file, again)
    handle = offering("0.0.2")
    staged = link_write!(handle, name, path = again)
    @test startswith(basename(staged), "dat-")
    @test_logs (:info, r"every output of this code run is identical") match_mode=:any DataPipeline.finalise(handle)
    @test handle.identical == Dict((name, nothing) => "0.0.1")
    @test handle.outputs[(name, nothing)]["path"] == registered
    @test !isfile(staged)
    @test code_run_of(handle)["outputs"] ==
          [handle.outputs[(name, nothing)]["component_url"]]
    @test registered_versions(handle.registry, name) == ["0.0.1", "0.0.2"]

    # A version that exists is refused at the call, whatever the bytes
    for (offered, path) in (("0.0.1", again), ("0.0.2", other))
        handle = offering(offered)
        err = @test_throws DataPipeline.ReadWriteException link_write!(handle,
                                                                       name,
                                                                       path = path)
        @test startswith(err.value.msg,
                         "$namespace:$name@v$offered is registered already")
        @test isempty(handle.outputs)
        DataPipeline.finalise(handle)
    end
    @test registered_versions(handle.registry, name) == ["0.0.1", "0.0.2"]

    # Other bytes are a new version, at the version the config offers
    changed = joinpath(outside, "changed.txt")
    write(changed, "fetched again $uid\n")
    handle = offering("0.0.3")
    link_write!(handle, name, path = changed)
    DataPipeline.finalise(handle)
    @test isempty(handle.identical)
    @test registered_versions(handle.registry, name) ==
          ["0.0.1", "0.0.2", "0.0.3"]
    @test read(registered, String) == "fetched $uid\n"

    # The first version's bytes again are identical to the highest version
    # holding them, though not the highest. They are in the store already,
    # so the copy made for them is removed, which leaves the original alone
    handle = offering("0.0.4")
    link_write!(handle, name, path = file)
    @test length(handle.outputs) == 1
    DataPipeline.finalise(handle)
    @test handle.identical == Dict((name, nothing) => "0.0.2")
    @test registered_versions(handle.registry, name) ==
          ["0.0.1", "0.0.2", "0.0.3", "0.0.4"]
    @test handle.outputs[(name, nothing)]["path"] == registered
    @test read(file, String) == "fetched $uid\n"
    @test readdir(dirname(registered)) ==
          sort([DataPipeline._getfilehash(path) * ".txt"
                for path in (file, changed)])

    # What cannot be registered: no file, a directory, a name no entry
    # covers, and a file that is not of the entry's file type
    handle = offering("0.0.5")
    wrong_type = joinpath(outside, "fetched.csv")
    write(wrong_type, "a,b\n")
    @test_throws DataPipeline.ReadWriteException link_write!(handle, name,
                                                             path = joinpath(outside,
                                                                             "absent.txt"))
    @test_throws DataPipeline.ReadWriteException link_write!(handle, name,
                                                             path = outside)
    @test_throws DataPipeline.ConfigFileException link_write!(handle,
                                                              "data_product/elsewhere/$uid",
                                                              path = file)
    @test_throws DataPipeline.ConfigFileException link_write!(handle, name,
                                                              path = wrong_type)
    @test isempty(handle.outputs)

    # A name a wildcard entry covers, from a symbolic link: it is the file
    # that arrives in the store, not the link
    pattern = "$name/*"
    covered = "$name/covered"
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, pattern, "description", file_type = "txt",
                           use_version = "0.0.1", use_data_product = pattern)
    handle = DataPipeline.initialise(config, config)
    target = joinpath(outside, "target.txt")
    write(target, "through a link $uid\n")
    symlink(target, joinpath(outside, "link.txt"))
    stored = link_write!(handle, covered, path = joinpath(outside, "link.txt"))
    @test dirname(stored) == joinpath(datastore, namespace, covered)
    @test !islink(stored)
    @test read(stored, String) == "through a link $uid\n"
    DataPipeline.finalise(handle)
    @test registered_versions(handle.registry, covered) == ["0.0.1"]
end

Test.@testset "an output whose file the store holds unregistered" begin
    # As where an earlier run's registration was lost: a file under the
    # output's hash in the data store, which the registry has no location for,
    # left there by `left(file, stored)`
    outside = mktempdir()
    function writing(case, left)
        name = "data_product/stored_unregistered/$case/$uid"
        file = joinpath(outside, "$case.txt")
        write(file, "stored unregistered, $case $uid\n")
        stored = joinpath(datastore, namespace, name,
                          DataPipeline._getfilehash(file) * ".txt")
        mkpath(dirname(stored))
        left(file, stored)
        config = DataPipeline._createconfig(cpath)
        DataPipeline._addwrite(config, name, "description", file_type = "txt",
                               use_version = "0.0.1")
        handle = DataPipeline.initialise(config, config)
        staged = link_write!(handle, name, path = file)
        return (; name, file, stored, handle, staged)
    end
    function check_registered(output)
        @test output.handle.outputs[(output.name, nothing)]["path"] ==
              output.stored
        @test !isfile(output.staged)
        @test read(output.stored, String) == read(output.file, String)
        @test registered_versions(output.handle.registry, output.name) ==
              ["0.0.1"]
        @test code_run_of(output.handle)["outputs"] ==
              [output.handle.outputs[(output.name, nothing)]["component_url"]]
    end

    # A link to the output's file, through which writing to that file would
    # change the registered one, is replaced by a file of its own; a copy
    # where no link can be made
    for (case, link) in (("linked", hardlink), ("symlinked", symlink))
        output = writing(case, linking(link))
        @test_logs DataPipeline.finalise(output.handle)
        check_registered(output)
        @test !islink(output.stored) && !samefile(output.stored, output.file)
    end

    # A copy is kept
    output = writing("copied", cp)
    inode = stat(output.stored).inode
    @test_logs DataPipeline.finalise(output.handle)
    check_registered(output)
    @test stat(output.stored).inode == inode

    # Other bytes under the hash's name are replaced, with a warning
    output = writing("other", (file, stored) -> write(stored, "other $uid\n"))
    @test_logs (:warn,
                r"^replacing the file at .*, whose bytes have the SHA-1 hash") DataPipeline.finalise(output.handle)
    check_registered(output)
    @test !samefile(output.stored, output.file)
end

Test.@testset "a write entry with no description" begin
    # The CLI's working config may give none, and the registry needs none
    name = "data_product/undescribed/$uid"
    config = DataPipeline._createconfig(cpath)
    DataPipeline._addwrite(config, name, nothing, file_type = "txt",
                           use_version = "0.0.1")
    handle = DataPipeline.initialise(config, config)
    write(link_write!(handle, name), "undescribed $uid\n")
    DataPipeline.finalise(handle)

    # Its object is registered with none, and read back as none
    component = DataPipeline._getentry(handle.registry,
                                       URIs.URI(only(code_run_of(handle)["outputs"])))
    object = DataPipeline._getentry(handle.registry,
                                    URIs.URI(component["object"]))
    @test isnothing(object["description"])
    stored = handle.outputs[(name, nothing)]["path"]
    @test only(DataPipeline.identify(handle.registry, stored).objects).description ==
          ""
    trace = DataPipeline.provenance(handle.registry, stored)
    @test isnothing(only(values(trace.products)).description)
end

Test.@testset "a run with no description" begin
    # The registry requires one of every code run, so a working config giving
    # none, or a blank one, is refused before anything is registered: its
    # bytes are its own, and nothing holds them
    registry = handle.registry
    for description in (nothing, " ")
        config = DataPipeline._createconfig(cpath)
        DataPipeline._addwrite(config, "data_product/undescribed_run/$uid",
                               "description", file_type = "txt",
                               use_version = "0.0.1")
        working = DataPipeline.YAML.load_file(config)
        if isnothing(description)
            delete!(working["run_metadata"], "description")
        else
            working["run_metadata"]["description"] = description
        end
        DataPipeline.YAML.write_file(config, working)
        err = @test_throws DataPipeline.ConfigFileException DataPipeline.initialise(config,
                                                                                    config)
        @test occursin("gives the run no description", err.value.msg)
        @test isempty(DataPipeline.identify(registry, config).objects)
    end
end

# Not tested: the same bytes under another storage root, or at a location
# registered with the other `public`
Test.@testset "an output identical to a version registered already" begin
    name = "data_product/identical/$uid"
    tabled = "data_product/identical/tabled/$uid"
    # A config that offers both names at a version, one as text, one as TOML
    function offering(use_version)
        config = DataPipeline._createconfig(cpath)
        for (written, file_type) in ((name, "txt"), (tabled, "toml"))
            DataPipeline._addwrite(config, written, "description",
                                   file_type = file_type,
                                   use_version = use_version)
        end
        return DataPipeline.initialise(config, config)
    end

    handle = offering("0.0.1")
    registry = handle.registry
    # The descriptions of the issues raised with a registered component
    function raised(component_url)
        return [DataPipeline._getentry(registry, URIs.URI(url))["description"]
                for url in issues_of(registry, component_url)]
    end
    write(link_write!(handle, name), "written $uid\n")
    DataPipeline.finalise(handle)
    registered = handle.outputs[(name, nothing)]["path"]
    component = handle.outputs[(name, nothing)]["component_url"]
    @test isempty(handle.identical)

    # The same bytes written again are a new version, identical to the first:
    # the file written is removed, its bytes stored already, and the version
    # is an output of the code run. An issue raised with it is on it alone,
    # the first version being warned of
    handle = offering("0.0.2")
    written = link_write!(handle, name)
    write(written, "written $uid\n")
    raise_issue!(handle, name, "written twice $uid")
    @test_logs (:warn, r"@v0.0.1 has the same bytes") match_mode=:any DataPipeline.finalise(handle)
    @test !isfile(written)
    @test readdir(dirname(registered)) == [basename(registered)]
    @test registered_versions(registry, name) == ["0.0.1", "0.0.2"]
    @test handle.identical == Dict((name, nothing) => "0.0.1")
    @test handle.outputs[(name, nothing)]["path"] == registered
    second = handle.outputs[(name, nothing)]["component_url"]
    @test second != component
    @test code_run_of(handle)["outputs"] == [second]
    @test raised(second) == ["written twice $uid"]
    @test isempty(raised(component))
    shown = sprint(show, MIME("text/plain"), handle)
    @test occursin("$name (identical to v0.0.1)", shown)
    @test occursin("every output is identical", shown)

    # Other bytes are identical to nothing
    handle = offering("0.0.3")
    write(link_write!(handle, name), "written again $uid\n")
    DataPipeline.finalise(handle)
    @test registered_versions(registry, name) == ["0.0.1", "0.0.2", "0.0.3"]
    @test isempty(handle.identical) && length(handle.outputs) == 1
    @test !occursin("(identical to", sprint(show, MIME("text/plain"), handle))

    # A file given by its path is found identical by finalise too
    handle = offering("0.0.4")
    given = joinpath(mktempdir(), "given.txt")
    write(given, "written again $uid\n")
    stored = link_write!(handle, name, path = given)
    @test startswith(basename(stored), "dat-")
    DataPipeline.finalise(handle)
    @test handle.identical == Dict((name, nothing) => "0.0.3")
    @test !isfile(stored)

    # A version registered after the call - here by changing the version the
    # output is written as, not by another run registering it meanwhile - is
    # refused at finalise, naming it, before any output is registered: a new
    # name included, which finalise would otherwise register first, in name
    # order
    first_written = "data_product/identical-first/$uid"
    @test string((first_written, nothing)) < string((name, nothing))
    config = DataPipeline._createconfig(cpath)
    for written in (first_written, name)
        DataPipeline._addwrite(config, written, "description",
                               file_type = "txt", use_version = "0.0.5")
    end
    handle = DataPipeline.initialise(config, config)
    write(link_write!(handle, first_written), "written first $uid\n")
    write(link_write!(handle, name), "not the first version $uid\n")
    handle.outputs[(name, nothing)]["use_version"] = "0.0.1"
    err = @test_throws DataPipeline.ReadWriteException DataPipeline.finalise(handle)
    @test startswith(err.value.msg,
                     "$namespace:$name@v0.0.1 is registered already")
    @test registered_versions(registry, name) ==
          ["0.0.1", "0.0.2", "0.0.3", "0.0.4"]
    @test isempty(registered_versions(registry, first_written))
    @test isempty(code_run_of(handle)["outputs"])

    # A data product written by its components is one file, and all of them
    # are found identical with it
    estimates = ("a/b" => 1.5, "c/d" => 2.5)
    handle = offering("0.0.1")
    for (part, value) in estimates
        write_estimate!(handle, value, tabled, part, "an estimate")
    end
    DataPipeline.finalise(handle)
    @test length(code_run_of(handle)["outputs"]) == 2
    parts = Dict(key => metadata["component_url"]
                 for (key, metadata) in handle.outputs)
    handle = offering("0.0.2")
    for (part, value) in estimates
        write_estimate!(handle, value, tabled, part, "an estimate")
    end
    DataPipeline.finalise(handle)
    @test registered_versions(registry, tabled) == ["0.0.1", "0.0.2"]
    @test handle.identical == Dict(key => "0.0.1" for key in keys(parts))
    @test length(code_run_of(handle)["outputs"]) == 2
    @test all(handle.outputs[key]["component_url"] != url
              for (key, url) in parts)
    # ... and with one of them changed it is not; nor, with another output
    # identical, is every output of the run
    handle = offering("0.0.5")
    write_estimate!(handle, 1.5, tabled, "a/b", "an estimate")
    write_estimate!(handle, 3.5, tabled, "c/d", "an estimate")
    write(link_write!(handle, name), "written again $uid\n")
    DataPipeline.finalise(handle)
    @test registered_versions(registry, tabled) == ["0.0.1", "0.0.2", "0.0.5"]
    @test handle.identical == Dict((name, nothing) => "0.0.4")
    @test length(code_run_of(handle)["outputs"]) == 3
    @test !occursin("every output", sprint(show, MIME("text/plain"), handle))

    # Arrays are found identical too: an HDF5 file records no times, which
    # would make the same arrays other bytes a second later. Two components,
    # one in a group within a group, the second added to the file once made
    arrayed = "data_product/identical/arrayed/$uid"
    arrays = ("first/array" => [1.0 2.0; 3.0 4.0],
              "second/deeper/array" => collect(1:6))
    for offered in ("0.0.1", "0.0.2")
        config = DataPipeline._createconfig(cpath)
        DataPipeline._addwrite(config, arrayed, "description",
                               file_type = "h5", use_version = offered)
        handle = DataPipeline.initialise(config, config)
        # Times are kept to the second: the second run writes in another
        offered == "0.0.2" && sleep(1.5)
        for (part, array) in arrays
            write_array!(handle, array, arrayed, part, "an array")
        end
        DataPipeline.finalise(handle)
    end
    @test registered_versions(registry, arrayed) == ["0.0.1", "0.0.2"]
    @test handle.identical ==
          Dict((arrayed, part) => "0.0.1" for (part, _) in arrays)
    stored = only(unique(metadata["path"]
                         for metadata in values(handle.outputs)))
    @test all(HDF5.h5open(stored) do file
                  return [read(file, part) == array for (part, array) in arrays]
              end)
end

Test.@testset "link_read!() with a path" begin
    name = "data_product/path_write/$uid"
    outside = mktempdir()

    config = DataPipeline._createconfig(cpath)
    DataPipeline._addread(config, name, use_version = "0.0.1")
    handle = DataPipeline.initialise(config, config)

    # Nothing there: a file of its own arrives, with the directories it needs,
    # and the input is recorded
    wanted = joinpath(outside, "inputs", "deep", "fetched.txt")
    @test link_read!(handle, name, path = wanted) == wanted
    stored = link_read!(handle, name)
    @test handle.inputs[(name, nothing)]["path"] == stored
    @test length(handle.inputs) == 1
    @test read(wanted, String) == "fetched $uid\n"
    @test !samefile(wanted, stored)

    # The same contents there already are left as they are, the file as well
    # as the bytes
    placed = stat(wanted).inode
    @test link_read!(handle, name, path = wanted) == wanted
    @test stat(wanted).inode == placed
    # ... but for the data store's file under another name or a link to it,
    # which is replaced by a file of its own, and the data store's own path
    for (case, link) in (("linked", hardlink), ("symlinked", symlink))
        other = joinpath(outside, "$case.txt")
        linking(link)(stored, other)
        @test link_read!(handle, name, path = other) == other
        @test !islink(other) && !samefile(other, stored)
        @test read(other, String) == "fetched $uid\n"
    end
    @test stat(stored).nlink == 1
    @test link_read!(handle, name, path = stored) == stored
    @test isfile(stored)
    copy = joinpath(outside, "copy.txt")
    cp(stored, copy)
    @test link_read!(handle, name, path = copy) == copy
    @test link_read!(handle, name, path = copy, force = true) == copy
    @test !samefile(copy, stored)

    # Other contents are refused, naming what was asked for, and are kept
    different = joinpath(outside, "different.txt")
    write(different, "something else $uid\n")
    err = nothing
    try
        link_read!(handle, name, path = different)
    catch e
        err = e
    end
    @test err isa DataPipeline.ReadWriteException
    @test occursin(name, err.msg) && occursin("version 0.0.1", err.msg)
    @test read(different, String) == "something else $uid\n"
    # ... unless forced, when the registered file replaces them
    @test link_read!(handle, name, path = different, force = true) == different
    @test read(different, String) == "fetched $uid\n"
    @test !samefile(different, stored)

    # A directory is never replaced, and a pattern takes no path
    @test_throws DataPipeline.ReadWriteException link_read!(handle, name,
                                                            path = outside,
                                                            force = true)
    @test isdir(outside)
    @test_throws ArgumentError link_read!(handle, "data_product/*/$uid",
                                          path = joinpath(outside, "all"))
    @test !ispath(joinpath(outside, "all"))

    # The data store's file is as it was, the files put elsewhere written in
    # place notwithstanding, and the run has the one input
    write(wanted, "written in place $uid\n")
    write(different, "written in place $uid\n")
    @test DataPipeline._getfilehash(stored) ==
          handle.inputs[(name, nothing)]["hash"]
    DataPipeline.finalise(handle)
    @test length(code_run_of(handle)["inputs"]) == 1
end

Test.@testset "canread() and canwrite()" begin
    root = "data_product/can/$uid"
    pattern = "$root/wild/*"

    # A config with neither block lets nothing be read or written
    config = DataPipeline._createconfig(cpath)
    handle = DataPipeline.initialise(config, config)
    @test !DataPipeline.canread(handle, "$root/read")
    @test !DataPipeline.canread(handle, "$root/*")
    @test !DataPipeline.canwrite(handle, "$root/exact")

    DataPipeline._addread(config, "$root/read", use_version = version)
    DataPipeline._addwrite(config, "$root/exact", "description",
                           file_type = "txt", use_version = version)
    DataPipeline._addwrite(config, pattern, "description", file_type = "txt",
                           use_version = version, use_data_product = pattern)
    DataPipeline._resetsession!()
    handle = DataPipeline.initialise(config, config)

    # A read entry is found by its name, or by a pattern that matches it
    @test DataPipeline.canread(handle, "$root/read")
    @test !DataPipeline.canread(handle, "$root/exact")
    @test DataPipeline.canread(handle, "$root/*")
    @test !DataPipeline.canread(handle, "data_product/can/*")

    # A write entry covers the name it gives, or one its pattern matches
    @test DataPipeline.canwrite(handle, "$root/exact")
    @test !DataPipeline.canwrite(handle, "$root/read")
    @test DataPipeline.canwrite(handle, "$root/wild/covered")
    @test !DataPipeline.canwrite(handle, "$root/wild/a/b")
    @test !DataPipeline.canwrite(handle, "$root/wild")

    # Asking records nothing and makes nothing in the data store
    @test isempty(handle.inputs) && isempty(handle.outputs)
    @test !isdir(joinpath(datastore, namespace, root))

    # A name two patterns match is not covered, as link_write! refuses it
    DataPipeline._addwrite(config, "$root/*/covered", "description",
                           file_type = "txt", use_version = version)
    DataPipeline._resetsession!()
    handle = DataPipeline.initialise(config, config)
    @test !DataPipeline.canwrite(handle, "$root/wild/covered")
    @test DataPipeline.canwrite(handle, "$root/wild/other")
    @test_throws DataPipeline.ConfigFileException link_write!(handle,
                                                              "$root/wild/covered")
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

@testset "initialise() once per fair run" begin
    # A session has one run, opened once, however the files are given: not
    # again while it is open, nor after it has ended. The tests open many in
    # one process by forgetting the session's run, as the helper that makes
    # each test's config does.
    DataPipeline._resetsession!()
    @test isnothing(DataPipeline.SESSION[])
    launched = DataPipeline.initialise()
    @test launched isa DataPipeline.DataRegistryHandle{DataPipeline.RecordedRun}
    @test DataPipeline.SESSION[].handle === launched
    @test DataPipeline.SESSION[].job == launched.config_dir
    err = @test_throws DataPipeline.ReadWriteException DataPipeline.initialise()
    @test occursin("is open", err.value.msg)
    err = @test_throws DataPipeline.ReadWriteException DataPipeline.initialise(config,
                                                                               config)
    @test occursin("is open", err.value.msg)
    DataPipeline.finalise(launched)
    @test DataPipeline.SESSION[].ended
    err = @test_throws DataPipeline.ReadWriteException DataPipeline.initialise()
    @test occursin("recorded in this session already", err.value.msg)
    err = @test_throws DataPipeline.ReadWriteException DataPipeline.initialise(config,
                                                                               config)
    @test occursin("recorded in this session already", err.value.msg)
    err = @test_throws DataPipeline.ReadWriteException DataPipeline._replrehearse(dirname(config))
    @test occursin("has recorded a code run", err.value.msg)
    # Forgotten, the session opens another
    DataPipeline._resetsession!()
    another = DataPipeline.initialise(config, config)
    @test DataPipeline.SESSION[].handle === another
    DataPipeline.finalise(another)
end

@testset "initialise outside fair run" begin
    DataPipeline._resetsession!()
    withenv("FDP_CONFIG_DIR" => nothing, "FDP_LOCAL_TOKEN" => nothing) do
        # With nothing set, the call says what `fair run` would have set
        err = @test_throws DataPipeline.ConfigFileException DataPipeline.initialise()
        @test occursin("fair run", err.value.msg)
        @test occursin("FDP_CONFIG_DIR", err.value.msg)

        # A working config given alone takes the script it names, and with no
        # token goes no further than the first registration
        err = @test_throws DataPipeline.ReadWriteException DataPipeline.initialise(config)
        @test occursin("no token", err.value.msg)

        # A job folder that is gone
        withenv("FDP_CONFIG_DIR" => mktempdir()) do
            err = @test_throws DataPipeline.ConfigFileException DataPipeline.initialise()
            @test occursin("gone", err.value.msg)
        end

        # A user config, which no `fair run` has made a working config from
        user = joinpath(mktempdir(), "config.yaml")
        DataPipeline.YAML.write_file(user,
                                     Dict("run_metadata" =>
                                              Dict("description" => "A user config",
                                                   "script" => "julia script.jl")))
        err = @test_throws DataPipeline.ConfigFileException DataPipeline.initialise(user,
                                                                                    user)
        @test occursin("not a working config", err.value.msg)
    end
end

end
