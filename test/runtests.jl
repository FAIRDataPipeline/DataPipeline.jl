# SPDX-License-Identifier: LGPL-3.0-or-later

using Test

# Whether the suite is the script of a `fair run`, which hands it a working
# config and a registry token: every test file but those that need no
# registry opens code runs as it loads, so outside one only those run
const UNDER_FAIR_RUN = haskey(ENV, "FDP_CONFIG_DIR") &&
                       haskey(ENV, "FDP_LOCAL_TOKEN") &&
                       isfile(joinpath(ENV["FDP_CONFIG_DIR"], "config.yaml"))
const REGISTRY_FREE = ["test_DataPipeline.jl", "test_citationfile.jl",
    "test_latex.jl", "test_repometadata.jl", "test_testing.jl"]
registryfree(fn) = fn in REGISTRY_FREE || startswith(fn, r"extras_|clean_")
const HOW_TO = """
    The other test files open code runs: to run the suite as the script of a
    `fair run` of the tests' own pipeline, with any other test arguments passed on,

        julia --project -e 'using Pkg; Pkg.test(test_args = ["--fair"])'"""

# `--fair` runs the suite inside a `fair run` of the tests' own pipeline
if "--fair" in ARGS
    UNDER_FAIR_RUN &&
        error("`--fair` asks for a `fair run`, and the tests are inside one already")
    include("fairrun.jl")
    FairRun.fairrun(filter(!=("--fair"), ARGS))
    exit()
end

# A test argument names a test file to run instead of the whole suite, under
# the load path `Pkg.test` gives, the `.jl` optional:
#     julia --project -e 'using Pkg; Pkg.test(test_args = ["test_api.jl"])'
requested = map(a -> endswith(a, ".jl") ? a : a * ".jl", ARGS)
for fn in requested
    isfile(fn) ||
        error("`$fn` was asked for with `test_args`, but there is no such file in `test/`")
    UNDER_FAIR_RUN || registryfree(fn) ||
        error("`$fn` was asked for outside `fair run`, and needs a registry.\n" *
              HOW_TO)
end
if !isempty(requested)
    @info "Running only the requested test file(s): " * join(requested, ", ")
    @testset "DataPipeline" begin
        @testset "* Testing $fn" for fn in requested
            include(fn)
        end
    end
    exit()
end

# Identify files in test/ that are testing matching files in src/
#  - src/Source.jl will be matched by test/test_Source.jl

filebase = map(file -> replace(file, r"(.*).jl$" => s"\1"),
               filter(file -> occursin(r".*\.jl$", file),
                      readdir("../src")))
testbase = map(file -> replace(file, r"test_(.*).jl$" => s"\1"),
               filter(str -> occursin(r"^test_.*\.jl$", str), readdir()))
torun = UNDER_FAIR_RUN ? testbase :
        filter(t -> registryfree("test_$t.jl"), testbase)
UNDER_FAIR_RUN ||
    @warn "Not inside `fair run`, so only the test files that need no registry run.\n" *
          HOW_TO

println()
@info "Running tests for files:"
for t in torun
    println("    = $t.jl")
end
println()

# One testset over the files, so that a file with a failure does not stop
# the files after it: a testset at the top level throws at its end
@testset "DataPipeline" begin
    @testset "* Testing $t.jl" for t in torun
        include("test_$t.jl")
    end
end

# Identify tests with no matching file
superfluous = filter(f -> f ∉ filebase, testbase)
if length(superfluous) > 0
    println()
    @info "Potentially superfluous tests:"
    for f in superfluous
        println("    + $f.jl")
    end
    println()
end

# Identify files with no matching test
missing = filter(f -> f ∉ testbase, filebase)
if length(missing) > 0
    println()
    @info "Potentially missing tests:"
    for f in missing
        println("    - $f.jl")
    end
    println()
end

# Identify files that are cross-validating results against other packages
# test/pkg_Package.jl should validate results against the Package package

pkgbase = map(file -> replace(file, r"pkg_(.*).jl$" => s"\1"),
              filter(str -> occursin(r"^pkg_.*\.jl$", str),
                     readdir()))

if length(pkgbase) > 0
    @info "Running cross-validation against:"
    for p in pkgbase
        println("    = $p")
    end
    println()

    @testset " * Validating against $p" for p in pkgbase
        include("pkg_$p.jl")
    end
end

# The extra sets - every `extras_*.jl` - come last, and only once the tests
# above have passed: they check the repository rather than the package, and
# rewrite files in it, so unstaged edits fail them
extrabase = sort(filter(str -> occursin(r"^extras_.*\.jl$", str), readdir()))
if length(extrabase) > 0
    @info "Running the extra sets:"
    for e in extrabase
        println("    = $e")
    end
    println()
    @testset "* $e" for e in extrabase
        include(e)
    end
end

UNDER_FAIR_RUN ||
    @warn "Only $(length(torun)) of the $(length(testbase)) test files ran, outside `fair run`.\n" *
          HOW_TO
