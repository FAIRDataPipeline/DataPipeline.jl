# SPDX-License-Identifier: LGPL-3.0-or-later

# The repository checks: every `test/clean_*.jl`, each named after what it
# checks. They rewrite files - the formatter, the metadata crosswalk - and
# then require the working tree to be clean, so they mean something only on a
# tree whose changes are staged or committed; unstaged edits fail them.
#
# On their own, with no registry needed:
#
#     julia --project -e 'using Pkg; Pkg.test(test_args = ["extras_clean.jl"])'
#
# `runtests.jl` runs them last in a full run. On a CI runner they run only
# when named, as the metadata workflow names them, so that no other job
# repeats them.

module ExtrasClean

using Test

const ASKED_FOR = any(a -> occursin("extras_clean", a), ARGS)

if !ASKED_FOR && haskey(ENV, "RUNNER_OS")
    @info "Skipping the repository checks: this is a CI runner, and the metadata workflow runs them"
else
    cleanbase = map(file -> replace(file, r"clean_(.*).jl$" => s"\1"),
                    filter(str -> occursin(r"^clean_.*\.jl$", str),
                           readdir(@__DIR__)))
    println()
    @info "Running the repository checks:"
    for c in cleanbase
        println("    = $c")
    end
    println()
    @testset "* Checking $c" for c in cleanbase
        include(joinpath(@__DIR__, "clean_$c.jl"))
    end
end

end
