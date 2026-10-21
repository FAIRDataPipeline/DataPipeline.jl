# SPDX-License-Identifier: LGPL-3.0-or-later

# The package as a whole: what is public and how it is documented, method
# ambiguities, Aqua's checks of the project, and the deprecations file. None of
# it needs a registry.

module TestDataPipeline

using DataPipeline
using Aqua
using Test
# `Base.Docs.doc(::Binding)`, which the docstring checks call, is a method
# REPL defines
import REPL

const D = DataPipeline

# Whether `n` has a docstring in `m`, looked up by its binding: `@doc` is a
# macro over an expression, and given a variable documents the variable
hasdoc(m, n) = haskey(Base.Docs.meta(m), Base.Docs.Binding(m, n))

# The names `m` exports or declares `public`, but for its own
function publicnames(m)
    return [n
            for n in names(m, all = false)
            if isdefined(m, n) && n !== nameof(m)]
end

docof(m, n) = string(Base.Docs.doc(Base.Docs.Binding(m, n)))

# Whether a docstring is the placeholder `@doc (@doc name)` publishes for a
# `name` that does not exist, which is a docstring as far as `hasdoc` can tell
function placeholding(m, n)
    text = docof(m, n)
    return occursin("No documentation found", text) &&
           occursin("does not exist", text)
end

# The placeholder detector's controls, here at the top level, where `@doc`
# registers: one docstring taken from a binding that does not exist, one real
_placeholder_control_() = nothing
@doc (@doc _no_such_binding_anywhere_) _placeholder_control_
"""    _documented_control_() - a real docstring, which the detector must not flag"""
_documented_control_() = nothing

# Whether a docstring names keyword `k` in backticks, alone or as `k = ...`; a
# bare substring would take `hashes` for `hash`
function documents(text::AbstractString, k::Symbol)
    return occursin(Regex("`\\s*" * String(k) * "\\s*(`|=|,|\\))"), text)
end

@testset "every public name has a docstring, and none is a placeholder" begin
    undocumented = sort([n for n in publicnames(D) if !hasdoc(D, n)])
    # Named, so that a new gap has to be looked at and a shim's removal
    # shortens the list: the `@deprecate`d names, whose redirect is their
    # documentation, and which `Base.isdeprecated` does not mark
    known = [:raise_issue, :read_array, :read_distribution, :read_estimate,
        :read_table, :write_array, :write_distribution, :write_estimate,
        :write_table]
    @test undocumented == known
    @test isempty([n
                   for n in publicnames(D)
                   if hasdoc(D, n) && placeholding(D, n)])

    # Not vacuous: what is documented is found, and the placeholder is told
    # from a real docstring by its text alone
    @test length(publicnames(D)) > 50
    @test !hasdoc(D, :_no_such_name_)
    @test all(n -> hasdoc(D, n),
              (:initialise, :link_read!, :check_store, :identify))
    @test hasdoc(@__MODULE__, :_placeholder_control_)
    @test placeholding(@__MODULE__, :_placeholder_control_)
    @test !placeholding(@__MODULE__, :_documented_control_)
end

@testset "every keyword of a public function is in its docstring" begin
    missed = Tuple{Symbol, Symbol}[]
    for n in publicnames(D)
        f = getfield(D, n)
        (f isa Function && hasdoc(D, n)) || continue
        text = docof(D, n)
        for m in methods(f)
            parentmodule(m) === D || continue
            for k in Base.kwarg_decl(m)
                # A splat names nothing a caller could look up
                endswith(String(k), "...") || documents(text, k) ||
                    push!(missed, (n, k))
            end
        end
    end
    # Named: `commits` is the keyword of `identify`'s deprecated folder form
    known = [(:identify, :commits)]
    @test sort(unique(missed)) == known

    # Not vacuous, and not a substring search: `check_store` documents
    # `hashes`, which holds `hash`
    @test documents(docof(D, :check_store), :hashes)
    @test !documents(docof(D, :check_store), :hash)
    @test !documents(docof(D, :check_store), :never_documented)
end

@testset "abstract types are neither public nor exported" begin
    # A supertype annotates arguments and is not for extending, so none is
    # written by a user. Read through `isdeprecated` first: reading a
    # deprecated binding warns
    abstracts = filter(names(D, all = true, imported = false)) do n
        Base.isgensym(n) && return false
        (isdefined(D, n) && !Base.isdeprecated(D, n)) || return false
        v = getfield(D, n)
        return v isa Type && isabstracttype(v) && parentmodule(v) === D
    end
    @test length(abstracts) >= 5
    # `ispublic` holds for an exported name too
    @test isempty(filter(n -> Base.ispublic(D, n), abstracts))
end

@testset "no method ambiguities" begin
    @test isempty(Test.detect_ambiguities(D, recursive = false))
    # Not vacuous: two methods that cannot be ordered are reported
    @eval module _AmbiguityControl
    f(::Integer, ::Any) = 1
    f(::Any, ::Integer) = 2
    end
    @test length(Test.detect_ambiguities(_AmbiguityControl,
                                         recursive = false)) == 1
end

@testset "Aqua" begin
    Aqua.test_unbound_args(D)
    Aqua.test_undefined_exports(D)
    Aqua.test_project_extras(D)
    Aqua.test_stale_deps(D)
    Aqua.test_deps_compat(D)
    Aqua.test_piracies(D)
    Aqua.test_persistent_tasks(D)
end

@testset "deprecations are labelled by release, newest first" begin
    lines = readlines(pkgdir(D, "src", "deprecated.jl"))
    headings = [(i, m.captures[1])
                for (i, line) in enumerate(lines)
                for m in (match(r"^# == (.*) ==$", line),) if !isnothing(m)]
    labels = [match(r"^Deprecated in (\d+\.\d+\.\d+)$", heading)
              for (_, heading) in headings]
    @test all(!isnothing, labels)
    versions = [VersionNumber(label.captures[1]) for label in labels]
    # Named, so that a typo cannot pass as a release: deleting a release's
    # section shortens it
    @test versions == [v"0.55.0"]
    @test issorted(versions, rev = true)
    @test all(<=(pkgversion(D)), versions)
    # Every shim is in a section
    shims = [i
             for (i, line) in enumerate(lines)
             if startswith(line, "@deprecate")]
    @test length(shims) >= 9
    @test minimum(shims) > first(first(headings))
end

end
