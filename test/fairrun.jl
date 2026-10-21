# SPDX-License-Identifier: LGPL-3.0-or-later

# The suite run as the script of a `fair run`, which `runtests.jl` hands over
# to when the test arguments hold `--fair`, any others being passed on to the
# `Pkg.test` inside the run:
#
#     julia --project -e 'using Pkg; Pkg.test(test_args = ["--fair"])'
#     julia --project -e 'using Pkg; Pkg.test(test_args = ["--fair", "test_api.jl"])'
#
# The pipeline is the tests' own, kept in DataPipeline's scratch space so that
# nothing of the user's is written to: a home for every `fair` command and what
# it runs, holding a registry installed the first time, on a free port rather
# than 8000, its data store, and a copy of the repository, made afresh each
# time, to `fair init` in. Deleting the space starts the pipeline afresh.
# `fair` itself is the user's to install.

module FairRun

using DataPipeline
using Git
using Sockets

const D = DataPipeline

# Run the suite with `arguments` as its test arguments inside a `fair run` of
# the tests' own pipeline, throwing if it fails
function fairrun(arguments::Vector{String})
    cli = try
        D._faircommand(nothing)
    catch e
        e isa ArgumentError || rethrow()
        error("`--fair` runs the tests under `fair run`, so needs `fair`: $(e.msg); then run them again")
    end
    space = D._testingspace()
    # The copy is within the home, where the CLI's search for a project above
    # it stops, as it would not below the user's own home and its `.fair`
    home = joinpath(space, "home")
    repo = joinpath(home, "repo")
    registry = joinpath(home, ".fair", "registry")
    separator = Sys.iswindows() ? ";" : ":"
    # Every `fair` command, and what it runs, has the tests' home - `HOME`, or
    # `USERPROFILE` on Windows - with this Julia first on the path, its depot
    # and its standard libraries, and an identity for the commits the tests'
    # fixtures make. A `julia` that is juliaup's launcher would install a Julia
    # of its own under the changed home
    environment = ["HOME" => home, "USERPROFILE" => home,
        "PATH" => string(Sys.BINDIR, separator, get(ENV, "PATH", "")),
        "JULIA_DEPOT_PATH" => join(DEPOT_PATH, separator),
        "JULIA_LOAD_PATH" => join(["@", "@stdlib"], separator),
        "GIT_AUTHOR_NAME" => "Interface Test",
        "GIT_AUTHOR_EMAIL" => "test@noreply.com",
        "GIT_COMMITTER_NAME" => "Interface Test",
        "GIT_COMMITTER_EMAIL" => "test@noreply.com"]
    fair(words...; dir = repo) = D._fair(words...; cli, dir)
    return withenv(environment...) do
        if !isfile(joinpath(registry, "manage.py"))
            @info "Installing the tests' own registry at $registry, once: a few minutes"
            rm(registry, recursive = true, force = true)
            mkpath(home)
            fair("registry", "install"; dir = space)
        end

        # The repository as it stands, but for any pipeline of its own
        rm(repo, recursive = true, force = true)
        mkpath(repo)
        for entry in readdir(pkgdir(D))
            entry == ".fair" ||
                cp(joinpath(pkgdir(D), entry), joinpath(repo, entry))
        end
        remote = try
            readchomp(`$(Git.git()) -C $repo remote get-url origin`)
        catch
            "https://github.com/FAIRDataPipeline/DataPipeline.jl"
        end

        # The CLI's configuration, as `fair init --ci` writes but for the port,
        # which `--ci` fixes at 8000, where the user's own registry may be
        port, server = listenany(ip"127.0.0.1", 8010)
        close(server)
        # The data store is kept beside the registry, which records its files
        function store(folder)
            return joinpath(home, folder) * Base.Filesystem.path_separator
        end
        config = Dict("namespaces" => Dict("input" => "testing",
                           "output" => "testing"),
                      "registries" => Dict("local" =>
                               Dict("uri" => "http://127.0.0.1:$port/api/",
                                    "directory" => registry,
                                    "data_store" => store("data_store"),
                                    "token" => joinpath(registry,
                                                        "token")),
                           "origin" =>
                               Dict("uri" => "http://127.0.0.1:$(port + 1)/api/",
                                    "data_store" => store("origin"),
                                    "token" => joinpath(registry,
                                                        "token"))),
                      "user" => Dict("email" => "test@noreply.com",
                           "family_name" => "Test",
                           "given_names" => "Interface",
                           "orcid" => "000-0000-0000-0000",
                           "uri" => "https://github.com/FAIRDataPipeline",
                           "uuid" => "2ddb2358-84bf-43ff-b2aa-3ac7dc3b49f1",
                           "remote_user" => "FAIRDataPipeline"),
                      "git" =>
                          Dict("local_repo" => repo, "remote" => "origin",
                               "remote_repo" => remote))
        using_file = joinpath(space, "cli-config.yaml")
        D.YAML.write_file(using_file, config)
        fair("init", "--using", using_file, "--local")

        # `--dirty` where a tracked file has changes, as `fair run` requires
        status = readlines(`$(Git.git()) -C $repo status --porcelain`)
        flags = any(line -> !startswith(line, "??"), status) ?
                ["--local", "--dirty"] : ["--local"]
        fair("pull", "--local", "examples/fdp/SEIRSconfig.yaml")
        fair("run", flags..., "examples/fdp/SEIRSconfig.yaml")

        # The script runs a file rather than `julia -e`, so that no quotes nest
        # in a script that may be run by cmd.exe
        inner = joinpath(space, "runtests.jl")
        write(inner, "using Pkg\nPkg.test(test_args = $(repr(arguments)))\n")
        script = "\"$(Base.julia_cmd()[1])\" --project=. \"$inner\""
        pre = read(joinpath(repo, "test", "pre_config.yaml"), String)
        write(joinpath(repo, "test", "config.yaml"),
              replace(pre, "\$TEST_SCRIPT" => script))
        return fair("run", flags..., joinpath("test", "config.yaml"))
    end
end

end
