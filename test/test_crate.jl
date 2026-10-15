# SPDX-License-Identifier: LGPL-3.0-or-later

module TestCrate

using DataPipeline
using Dates
using Test

const D = DataPipeline
const ReadWriteException = DataPipeline.ReadWriteException

uid = DataPipeline._randomhash()
cpath = joinpath("coderun", Dates.format(Dates.now(), "yyyymmdd-HHMMSS"),
                 "crate.yaml")
config = DataPipeline._createconfig(cpath)
launch = DataPipeline.initialise(config, config)
registry = launch.registry
datastore = launch.config["run_metadata"]["write_data_store"]
namespace = launch.config["run_metadata"]["default_output_namespace"]

# A code run that writes each of these names as text at 0.0.1 and reads each
# of `reads` at 0.0.1
function run_with(writes::String...; reads::Vector{String} = String[])
    config = DataPipeline._createconfig(cpath)
    for name in writes
        DataPipeline._addwrite(config, name, "crate description",
                               file_type = "txt", use_version = "0.0.1")
    end
    for name in reads
        DataPipeline._addread(config, name, use_version = "0.0.1")
    end
    return DataPipeline.initialise(config, config)
end

# The entities of a crate's graph of a type
function entities(crate, type)
    return [entity
            for entity in crate["@graph"] if entity["@type"] == type]
end

Test.@testset "crate()" begin
    input = "crate/input/$uid"
    result = "crate/result/$uid"
    figure = "crate/figure/$uid"

    # A run writes an input; a second reads it and writes two outputs, which
    # a folder holds copies of, beside a file the registry does not know and
    # files and folders named with a leading dot
    first_run = run_with(input)
    write(link_write!(first_run, input), "crate input $uid\n")
    DataPipeline.finalise(first_run)
    second_run = run_with(result, figure, reads = [input])
    link_read!(second_run, input)
    write(link_write!(second_run, result), "crate result $uid\n")
    write(link_write!(second_run, figure), "crate figure $uid\n")
    DataPipeline.finalise(second_run)
    folder = mktempdir()
    mkpath(joinpath(folder, "figures", ".cache"))
    mkpath(joinpath(folder, ".git", "objects"))
    write(joinpath(folder, "figures", "result.txt"), "crate result $uid\n")
    write(joinpath(folder, "figures", "figure.txt"), "crate figure $uid\n")
    write(joinpath(folder, "paper.tex"), "the paper $uid\n")
    write(joinpath(folder, ".fair"), "hidden $uid\n")
    write(joinpath(folder, "figures", ".cache", "stale.txt"), "stale $uid\n")
    write(joinpath(folder, ".git", "objects", "x"), "git $uid\n")

    # The crate's metadata for the folder's files: the two outputs, the run
    # that made them and the run before it, and the input, as entities
    crate = DataPipeline.crate(registry, folder, strict = false)
    @test crate isa AbstractDict
    @test haskey(crate, "@context") && haskey(crate, "@graph")
    files = entities(crate, "File")
    @test Set(file["@id"] for file in files) ==
          Set(["$namespace/$result/0.0.1.txt", "$namespace/$figure/0.0.1.txt",
                  "$namespace/$input/0.0.1.txt"])
    @test Set(file["name"] for file in files) == Set([result, figure, input])
    @test all(length(file["sha1"]) == 40 for file in files)
    @test !any(haskey(file, "contentUrl") for file in files)
    runs = entities(crate, "CreateAction")
    @test Set(run["identifier"] for run in runs) ==
          Set([first_run.code_run_uuid, second_run.code_run_uuid])
    # What is left out is said: the unregistered file, and the dot-named
    # file and folders, each once
    log = joinpath(mktempdir(), "said.log")
    open(log, "w") do io
        redirect_stdout(io) do
            return DataPipeline.crate(registry, folder, strict = false)
        end
    end
    said = read(log, String)
    @test occursin("left out, not registered in this registry: $(joinpath(folder, "paper.tex"))\n",
                   said)
    @test occursin("left out, named with a leading dot: ", said)
    for name in (".fair", ".git", joinpath("figures", ".cache"))
        @test occursin(joinpath(folder, name), said)
    end
    @test !occursin("stale.txt", said) && !occursin("objects", said)
    # Strict, the unregistered file is an error naming it
    err = @test_throws ReadWriteException DataPipeline.crate(registry, folder)
    @test occursin("paper.tex", err.value.msg)
    @test occursin("strict = false", err.value.msg)
    # The folder of figures alone is strict enough; a file, whose crate holds
    # the run's other output too, and data products by name, through a handle
    @test length(entities(DataPipeline.crate(registry,
                                             joinpath(folder, "figures")),
                          "File")) == 3
    by_file = DataPipeline.crate(second_run,
                                 joinpath(folder, "figures", "figure.txt"))
    @test Set(file["name"] for file in entities(by_file, "File")) ==
          Set([figure, result, input])
    by_name = DataPipeline.crate(registry, "$namespace:$result@0.0.1",
                                 "$namespace:$figure")
    @test Set(file["name"] for file in entities(by_name, "File")) ==
          Set([result, figure, input])

    # The depth, the level and the pack are the registry's: one run back
    # leaves the first run out, level 2 adds where each file is, a pack the
    # registry does not know is refused with its reason
    shallow = DataPipeline.crate(registry, joinpath(folder, "figures"),
                                 depth = 1)
    @test [run["identifier"] for run in entities(shallow, "CreateAction")] ==
          [second_run.code_run_uuid]
    addressed = DataPipeline.crate(registry, joinpath(folder, "figures"),
                                   level = 2)
    @test all(haskey(file, "contentUrl")
              for file in entities(addressed, "File"))
    err = @test_throws ReadWriteException DataPipeline.crate(registry,
                                                             joinpath(folder,
                                                                      "figures"),
                                                             pack = "everything")
    @test occursin("pack must be one of", err.value.msg)

    # Saved as a zip, with `pack` passed through - what the registry packs
    # for each choice is its own, and not checked beyond the zip being one
    # and no smaller with the files than without, since one Windows runner
    # packed no bytes for `roots` where every other did; or its metadata as
    # a file
    packed = DataPipeline.crate(registry, joinpath(folder, "figures"),
                                to = joinpath(folder, "paper.zip"))
    @test packed == joinpath(folder, "paper.zip")
    @test isfile(packed)
    @test read(packed, 4) == UInt8['P', 'K', 0x03, 0x04]
    unpacked = DataPipeline.crate(registry, joinpath(folder, "figures"),
                                  to = joinpath(folder, "metadata.zip"),
                                  pack = "none")
    @test read(unpacked, 4) == UInt8['P', 'K', 0x03, 0x04]
    @test 0 < filesize(unpacked) <= filesize(packed)
    metadata = DataPipeline.crate(registry, joinpath(folder, "figures"),
                                  to = joinpath(folder,
                                                "ro-crate-metadata.json"))
    @test startswith(read(metadata, String), "{")
    @test_throws ArgumentError DataPipeline.crate(registry,
                                                  joinpath(folder, "figures"),
                                                  to = joinpath(folder,
                                                                "paper.tar"))

    # What cannot be crated
    @test_throws ArgumentError DataPipeline.crate(registry)
    @test_throws ReadWriteException DataPipeline.crate(registry,
                                                       "$namespace:crate/absent/$uid")
    err = @test_throws ArgumentError DataPipeline.crate(registry,
                                                        "nothing/here/$uid")
    @test occursin("no file or folder at", err.value.msg)
    @test_throws ReadWriteException DataPipeline.crate(registry,
                                                       joinpath(folder,
                                                                "paper.tex"),
                                                       strict = false)
    @test_throws ArgumentError DataPipeline.crate(registry, folder, depth = 0)
end

end
