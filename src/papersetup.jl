# SPDX-License-Identifier: LGPL-3.0-or-later

# A LaTeX paper's own files outside a run: set up once so that it can be built
# in one, checked against its metadata, its repository and the registries, and
# brought up to date - its `CITATION.cff`, the files from the pipeline and the
# config that builds it.

"""
    PaperCheck

What [`check_paper`](@ref) found of a LaTeX paper, shown as a report.

# Fields
- `paper`: the [`LaTeXPaper`](@ref) checked
- `setup`: what building the paper in a run lacks - `fair`, the repository
  initialised by `fair init`, the remote's configuration and token, a local
  registry that answers - each with what supplies it; empty when nothing is
  lacking
- `uses`: the files a build of the paper uses, as `(pipeline, own,
  outside)`: those from its pipeline folder and the repository's own, as
  paths from the repository's top level, and how many others, such as TeX's
  own; `nothing` where the paper was not built
- `metadata`: the file the paper's metadata comes from, and for
  `CITATION.cff` where in it; `nothing` where there is none
- `actions`: what is to be done before the paper is built, each with how
- `notes`: what is worth knowing that asks nothing of this package
- `unchecked`: the checks not made, each with why
"""
struct PaperCheck
    paper::LaTeXPaper
    setup::Vector{String}
    uses::Union{Nothing,
                @NamedTuple{pipeline::Vector{String}, own::Vector{String},
                            outside::Int}}
    metadata::Union{Nothing, String}
    actions::Vector{String}
    notes::Vector{String}
    unchecked::Vector{String}
end

function Base.show(io::IO, check::PaperCheck)
    return print(io, "PaperCheck(", repr(basename(check.paper.tex)), ": ",
                 _checksummary(check), ")")
end

function Base.show(io::IO, ::MIME"text/plain", check::PaperCheck)
    lines = ["Check of the paper $(check.paper.tex): $(_checksummary(check))"]
    if isempty(check.setup)
        push!(lines,
              "  set up: fair, the project, the remote and the local registry are ready")
    else
        push!(lines, "  set up, but for:")
        append!(lines, "    - " .* check.setup)
    end
    uses = check.uses
    if !isnothing(uses)
        push!(lines,
              "  uses $(_counted(length(uses.pipeline), "file")) from the pipeline, $(length(uses.own)) of its own and $(uses.outside) from elsewhere:")
        append!(lines, "    " .* vcat(uses.pipeline, uses.own))
    end
    push!(lines, "  metadata: $(something(check.metadata, "none"))")
    for (heading, items) in (("to do", check.actions), ("notes", check.notes),
        ("not checked", check.unchecked))
        isempty(items) && continue
        push!(lines, "  $heading:")
        append!(lines, "    - " .* items)
    end
    return join(io, lines, "\n")
end

# What a check found, in a few words: ready, or how much is to be done and
# how much was not checked
function _checksummary(check::PaperCheck)
    counts = String[]
    isempty(check.setup) ||
        push!(counts, "$(length(check.setup)) missing from the setup")
    isempty(check.actions) || push!(counts, "$(length(check.actions)) to do")
    isempty(check.unchecked) ||
        push!(counts, "$(length(check.unchecked)) not checked")
    return isempty(counts) ? "ready" : join(counts, ", ")
end

# The remote registry a paper's files are identified in: a name in the
# project's CLI configuration, an endpoint, or `nothing` for the local
# registry alone
const PaperRemote = Union{Nothing, AbstractString, RegistryEndpoint}

# == Functions ==

"""
    setup_paper(paper; project = true, remote = "origin")
    setup_paper(registry, paper; project = true, remote = "origin")

Set the LaTeX paper `paper`, a [`LaTeXPaper`](@ref) or the path of its `.tex`
file, up to be built in a code run, creating the files that are then the
user's own, each only where it is missing: `CITATION.cff` at the top level of
its repository, drafted from the paper's title, authors and affiliations,
the authors' ORCIDs being left to be added by hand; the template of its
config, with the PDF's `write:` entry and a Julia script that builds it with
[`build_paper!`](@ref); and, with `project`, the script's environment in the
pipeline folder, a `Project.toml` and `Manifest.toml` holding DataPipeline.
Then write the config as [`update_paper`](@ref) does, where every file the
paper uses from its pipeline folder is registered; otherwise say which are
not, or why they could not be identified, and leave the config to a later
`update_paper`. Nothing that exists is overwritten, and what is kept is said.

Return `(created, kept, config, unregistered)`: the files created, and
`CITATION.cff` where a `preferred-citation` was added to it; the files kept as
they were; the config's path, or `nothing` where it was not written; and the
files from the pipeline that are not registered, or `nothing` where they could
not be identified.

In a repository holding a package - one with a `codemeta.json`, or a Julia
project file naming a package - the top level of `CITATION.cff` describes the
package, so the paper's citation is drafted as its `preferred-citation`, and
added to an existing file that has none. With `project = false` no Julia file
is created, and the script installs the newest DataPipeline into a temporary
environment each time it runs. `remote` names the remote registry the files
are identified in, and `registry` is the local registry; both are as for
[`check_paper`](@ref). The paper is built with `latexmk`, in a folder of its
own, to find the files it uses.
"""
function setup_paper(paper::LaTeXPaper; project::Bool = true,
                     remote::PaperRemote = "origin")
    return _setuppaper(paper, registry_session, remote, project)
end
function setup_paper(registry::RegistryEndpoint, paper::LaTeXPaper;
                     project::Bool = true, remote::PaperRemote = "origin")
    return _setuppaper(paper, f -> f(registry), remote, project)
end
function setup_paper(tex::AbstractString; project::Bool = true,
                     remote::PaperRemote = "origin")
    return setup_paper(LaTeXPaper(tex); project, remote)
end
function setup_paper(registry::RegistryEndpoint, tex::AbstractString;
                     project::Bool = true, remote::PaperRemote = "origin")
    return setup_paper(registry, LaTeXPaper(tex); project, remote)
end

"""
    check_paper(paper; remote = "origin")
    check_paper(registry, paper; remote = "origin")

Check the LaTeX paper `paper`, a [`LaTeXPaper`](@ref) or the path of its
`.tex` file, before it is built in a run, changing nothing, and return a
[`PaperCheck`](@ref), which shows as a report.

What building it lacks comes first: `fair`, the repository initialised by
`fair init`, the remote's configuration and its token, and a local registry
that answers. Then the files a build uses, found by building the paper with
`latexmk` in a folder of its own, and of each file from the pipeline folder:
whether it is registered in the remote, and as which version of what; whether
a newer version exists; the issues raised on it and on what lies behind it,
and the inputs behind it superseded since; and whether the local registry
holds it. Then whether the paper's title and authors, in order, are those of
its metadata, and what [`update_paper`](@ref) would do where they are not;
which file the metadata comes from; whether it gives a licence and the
authors' ORCIDs; how the authors differ from those of the PDF's version
registered last; the files the paper is built from that are not committed;
whether the config is what `update_paper` would write; the files the paper
uses from elsewhere in the repository that are registered, and so are
likely files from the pipeline; and the files in the pipeline folder that are
not registered, but for the environment there and any file git ignores. A
check that needs a registry that cannot be reached is said not to have been
made, and why.

`remote` names a remote registry in the CLI configuration of the paper's
project, `"origin"` being the one `fair init` writes, or is its
[`RegistryEndpoint`](@ref); with `nothing`, the files are checked in the
local registry alone. `registry` is the local registry's endpoint, as
[`registry_session`](@ref) gives it; without it, a session holds the local
registry for the call.
"""
function check_paper(paper::LaTeXPaper; remote::PaperRemote = "origin")
    hold = try
        _holdregistry()
    catch err
        err isa ReadWriteException || rethrow()
        return _checkpaper(paper, nothing, remote, held = err.msg)
    end
    try
        return _checkpaper(paper, _heldendpoint(hold), remote)
    finally
        hold isa RegistryHeldBySession && _releaseregistry(hold)
    end
end
function check_paper(registry::RegistryEndpoint, paper::LaTeXPaper;
                     remote::PaperRemote = "origin")
    return _checkpaper(paper, registry, remote)
end
function check_paper(tex::AbstractString; remote::PaperRemote = "origin")
    return check_paper(LaTeXPaper(tex); remote)
end
function check_paper(registry::RegistryEndpoint, tex::AbstractString;
                     remote::PaperRemote = "origin")
    return check_paper(registry, LaTeXPaper(tex); remote)
end

"""
    update_paper(paper; newest = false, remote = "origin")
    update_paper(registry, paper; newest = false, remote = "origin")

Bring the files of the LaTeX paper `paper`, a [`LaTeXPaper`](@ref) or the path
of its `.tex` file, up to date outside any run: its `CITATION.cff`, brought
into line with the paper's title and authors, and its config, written afresh
from its template with a `read:` block offering each file the paper uses from
its pipeline folder. Return `(config, files, citation)`: the config's path;
the files from the pipeline replaced, each with the data product it now is;
and the changes made to `CITATION.cff`.

In `CITATION.cff` only the paper's citation is changed - its
`preferred-citation` where it has one - and in it only the title and the
author entries: entries are moved into the LaTeX's order, one is drafted,
with no ORCID, for an author added, and one is dropped for an author
removed. Authors both removed and added may be a renaming, so they are left
to be changed by hand.

Each file from the pipeline is identified in the remote by its bytes, and the
config pins the version it is. With `newest = true` the config pins the
newest version of each instead, `fair pull` is run with it, and each newer
file is copied from the local data store over the old one under the same
name, so that the repository holds what the config offers. Refused, with the
config left as it was: a file that is not registered, bytes registered as
several data products, and with `newest` a newer version of another file
type.

The paper must have been set up by [`setup_paper`](@ref): the template and
`CITATION.cff` are never created here. `remote` and `registry` are as for
[`check_paper`](@ref); `fair pull` pulls from the project's `origin`, so
`newest = true` takes `remote = "origin"`, or `nothing`, which uses the local
registry alone and pulls nothing. The paper is built with `latexmk`, in a
folder of its own, to find the files it uses. The environment in the
pipeline folder is left as it is.
"""
function update_paper(paper::LaTeXPaper; newest::Bool = false,
                      remote::PaperRemote = "origin")
    return _updatepaper(paper, registry_session, remote, newest)
end
function update_paper(registry::RegistryEndpoint, paper::LaTeXPaper;
                      newest::Bool = false, remote::PaperRemote = "origin")
    return _updatepaper(paper, f -> f(registry), remote, newest)
end
function update_paper(tex::AbstractString; newest::Bool = false,
                      remote::PaperRemote = "origin")
    return update_paper(LaTeXPaper(tex); newest, remote)
end
function update_paper(registry::RegistryEndpoint, tex::AbstractString;
                      newest::Bool = false, remote::PaperRemote = "origin")
    return update_paper(registry, LaTeXPaper(tex); newest, remote)
end

# Set a paper up, as `setup_paper` says, `withlocal(f)` calling `f` with the
# local registry's endpoint where that is needed
function _setuppaper(paper::LaTeXPaper, withlocal::Function,
                     remote::PaperRemote, project::Bool)
    top = _papertop(paper)
    front = _frontmatter(_latexsource(paper.tex))
    _checkcitable(front)
    created, kept = String[], String[]
    _setupcitation!(created, kept, top, front)
    if isfile(paper.template)
        push!(kept, paper.template)
    else
        mkpath(dirname(paper.template))
        write(paper.template, _drafttemplate(paper, top, front, project))
        push!(created, paper.template)
    end
    if project
        environment = joinpath(paper.pipeline, "Project.toml")
        if isfile(environment)
            push!(kept, environment)
        else
            append!(created, _createenvironment(paper.pipeline))
        end
    end
    isempty(created) || @info "created $(join(created, ", "))"
    isempty(kept) || @info "kept $(join(kept, ", ")), which were there already"
    placed = _setupconfig(paper, top, withlocal, remote)
    return (created = created, kept = kept, config = placed.config,
            unregistered = placed.unregistered)
end

# The top level of the git repository holding a paper, from a commit of which
# a run builds it
function _papertop(paper::LaTeXPaper)
    top = _gittoplevel(dirname(paper.tex))
    isnothing(top) &&
        throw(ReadWriteException("$(paper.tex) is in no git repository: a paper is built in a run from a commit of its repository"))
    return top
end

# Draft `CITATION.cff` for a paper whose front matter is `front` where the
# repository at `top` has none, or add the paper's `preferred-citation` to one
# describing a package there, adding the file to `created` either way, else
# to `kept`
function _setupcitation!(created::Vector{String}, kept::Vector{String},
                         top::AbstractString, front::NamedTuple)
    path = joinpath(top, "CITATION.cff")
    package = _holdspackage(top)
    if !isfile(path)
        write(path,
              _draftcitation(front, package ? _packagecitation(top) : nothing))
        push!(created, path)
    elseif package && !_haspreferred(read(path, String))
        write(path, _addpreferred(read(path, String), front))
        @info "added the paper's preferred-citation to $path, whose top level describes the package the repository holds"
        push!(created, path)
    else
        push!(kept, path)
    end
    return nothing
end

# Whether `CITATION.cff`'s text has a `preferred-citation`
function _haspreferred(text::AbstractString)
    return get(_cffmapping(text), "preferred-citation", nothing) isa
           AbstractDict
end

# What `_draftcitation` takes of the package the repository at `top` holds:
# its title, authors and their identifiers, from its own metadata, its title
# the repository's folder's name where that gives none
function _packagecitation(top::AbstractString)
    meta = _repositorymetadata(top, title = true)
    return (title = something(meta.title, basename(top)),
            authors = meta.authors, identifiers = meta.identifiers)
end

# A draft of the template of the config that builds a paper: comments saying
# what it is, the run's metadata with a Julia script that builds the paper in
# the environment in its pipeline folder, or with `project` false in a
# temporary one, and the PDF's `write:` entry. Paths in the script are from the
# repository's top level `top`, where `fair run` runs it
function _drafttemplate(paper::LaTeXPaper, top::AbstractString,
                        front::NamedTuple, project::Bool)
    tex = _gitpath(paper.tex, top)
    config = _gitpath(paper.config, top)
    activate = if project
        environment = repr(_gitpath(paper.pipeline, top))
        ["Pkg.activate($environment)", "Pkg.instantiate()"]
    else
        ["Pkg.activate(temp = true)", "Pkg.add(\"DataPipeline\")"]
    end
    script = ["import Pkg"; activate; "using DataPipeline";
              "handle = DataPipeline.initialise()";
              "DataPipeline.build_paper!(handle, $(_paperargument(paper, top)))";
              "DataPipeline.finalise(handle)"]
    lines = ["# The template of the config that builds the paper $tex in a run",
        "# of the FAIR Data Pipeline. DataPipeline.update_paper writes",
        "# $config from it, adding a read: block for the files the paper",
        "# uses from the pipeline. Build the paper from the repository's top",
        "# level with `fair run $config`.",
        "run_metadata:",
        "  description: $(_yamlquoted("Build the paper $(front.title)"))",
        "  shell: julia",
        "  script: |",
        ("    " .* script)...,
        "write:",
        "- data_product: $(_paperdataproduct(paper, top))",
        "  description: $(_yamlquoted("The paper $(front.title), built from $tex"))",
        "  file_type: pdf"]
    return join(lines, "\n") * "\n"
end

# The paper as the build script names it: the path of its `.tex` file from the
# repository's top level, or a `LaTeXPaper` where its pipeline folder or its
# engine is not the default
function _paperargument(paper::LaTeXPaper, top::AbstractString)
    tex = repr(_gitpath(paper.tex, top))
    options = String[]
    pipeline = _gitpath(paper.pipeline, dirname(paper.tex))
    pipeline == "pipeline" || push!(options, "pipeline = $(repr(pipeline))")
    paper.engine isa PdfLaTeXEngine ||
        push!(options,
              "engine = DataPipeline.$(nameof(typeof(paper.engine)))()")
    isempty(options) && return tex
    return "DataPipeline.LaTeXPaper($tex, $(join(options, ", ")))"
end

# The name a drafted template gives the PDF's data product: the repository's,
# as its remote's URL names it or else its folder, then the `.tex` file's stem,
# each held to the naming convention
function _paperdataproduct(paper::LaTeXPaper, top::AbstractString)
    repository = basename(top)
    url = try
        LibGit2.with(LibGit2.GitRepo(top)) do repo
            return _gitremoteurl(repo, top)
        end
    catch err
        err isa ArgumentError || rethrow()
        nothing
    end
    isnothing(url) ||
        (repository = replace(last(split(rstrip(url, '/'), r"[/:]")),
                              r"\.git$" => ""))
    part(text) = strip(replace(text, r"[^A-Za-z0-9_.-]" => "_"), '.')
    name = join(filter(!isempty,
                       [part(repository),
                           part(splitext(basename(paper.tex))[1])]), "/")
    return occursin(DATA_PRODUCT_PATTERN, name) ? name : "paper"
end

# Create the environment a paper's build script activates, in the pipeline
# folder `folder`: a Julia project holding DataPipeline, resolved in a Julia
# process of its own, its packages left to be precompiled when the build first
# runs. Return the files created
function _createenvironment(folder::AbstractString)
    mkpath(folder)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    command = `$julia --startup-file=no --project=$folder -e 'import Pkg; Pkg.add("DataPipeline")'`
    run(addenv(command, "JULIA_PKG_PRECOMPILE_AUTO" => "0"))
    return [joinpath(folder, "Project.toml"), joinpath(folder, "Manifest.toml")]
end

# Write a paper's config where every file it uses from the pipeline folder is
# registered, giving its path and the files that are not, as `(config,
# unregistered)`; where the files cannot be listed, or identified, or the
# config cannot be written, say why and give `nothing` for what is not known
function _setupconfig(paper::LaTeXPaper, top::AbstractString,
                      withlocal::Function, remote::PaperRemote)
    left(reason, unregistered = nothing) = begin
        @warn "the config is left to a later update_paper: $reason"
        (config = nothing, unregistered = unregistered)
    end
    isnothing(Sys.which("latexmk")) &&
        return left("there is no `latexmk` on the path to find the files the paper uses")
    found = try
        uses = _paperuses(paper, top)
        _identifypipeline(top, uses.pipeline, withlocal, remote)
    catch err
        err isa Union{ReadWriteException, ConfigFileException} || rethrow()
        return left(err.msg)
    end
    refused = _refusals(found)
    isempty(refused) || return left(join(refused, "; "), found.unregistered)
    config = try
        _writepaperconfig(paper, _templatetext(paper), found.entries)
    catch err
        err isa ConfigFileException || rethrow()
        return left(err.msg, String[])
    end
    return (config = config, unregistered = String[])
end

# What stops a paper's config being written from its files' identification:
# files not registered, and the other problems found
function _refusals(found::NamedTuple)
    refused = copy(found.problems)
    isempty(found.unregistered) ||
        pushfirst!(refused, _unregisteredsaid(found.unregistered))
    return refused
end

# What is said of files the paper uses from the pipeline that are registered as
# no data product
function _unregisteredsaid(files::AbstractVector{String})
    return "files the paper uses from the pipeline are registered as no data product, so the build would refuse them: $(join(files, ", ")) - register each from the run that makes it, or move one that is the paper's own out of the pipeline folder"
end

# Update a paper's files, as `update_paper` says, `withlocal(f)` calling `f`
# with the local registry's endpoint where that is needed
function _updatepaper(paper::LaTeXPaper, withlocal::Function,
                      remote::PaperRemote, newest::Bool)
    (!newest || isnothing(remote) || remote == "origin") ||
        throw(ArgumentError("`fair pull` pulls from the project's remote `origin`, so `newest = true` takes `remote = \"origin\"`, or `nothing` for the local registry alone"))
    top = _papertop(paper)
    citation = _citationfile(top)
    template = _templatetext(paper)
    front = _frontmatter(_latexsource(paper.tex))
    changes = _updatecitationfile(citation, front)
    uses = _paperuses(paper, top)
    found = _identifypipeline(top, uses.pipeline, withlocal, remote; newest)
    refused = _refusals(found)
    isempty(refused) ||
        throw(ReadWriteException("the config is left as it was: $(join(refused, "; "))"))
    previous = isfile(paper.config) ? read(paper.config, String) : nothing
    config = _writepaperconfig(paper, template, found.entries)
    stale = filter(entry -> !entry.current, found.entries)
    isempty(stale) &&
        return (config = config, files = Pair{String, String}[],
                citation = changes)
    files = try
        isnothing(remote) || _fair("pull", config, dir = top)
        withlocal() do registry
            return _copynewer(registry, top, stale)
        end
    catch
        # The config offers what the repository holds, or nothing changes
        isnothing(previous) ? rm(config) : write(config, previous)
        rethrow()
    end
    return (config = config, files = files, citation = changes)
end

# The paper's `CITATION.cff`, at the top level `top`, as `setup_paper` leaves
# it: there, and where the repository holds a package, with a
# `preferred-citation` for the paper
function _citationfile(top::AbstractString)
    path = joinpath(top, "CITATION.cff")
    isfile(path) ||
        throw(ConfigFileException("there is no CITATION.cff in $top - run `DataPipeline.setup_paper` to draft one"))
    _holdspackage(top) && !_haspreferred(read(path, String)) &&
        throw(ConfigFileException("CITATION.cff in $top describes the package the repository holds and has no preferred-citation for the paper - run `DataPipeline.setup_paper` to add one"))
    return path
end

# Bring the paper's citation in the `CITATION.cff` at `path` into line with
# its front matter `front`, saying what changed, and give the changes
function _updatecitationfile(path::AbstractString, front::NamedTuple)
    text = read(path, String)
    updated = _updatecitation(text, front)
    updated.text == text || write(path, updated.text)
    isempty(updated.changes) ||
        @info "CITATION.cff: $(join(updated.changes, "; "))"
    return updated.changes
end

# The text of a paper's config's template, which must be YAML with no `read:`
# block of its own, since the config's is written from the files the paper uses
function _templatetext(paper::LaTeXPaper)
    isfile(paper.template) ||
        throw(ConfigFileException("there is no template at $(paper.template) to write the config from - run `DataPipeline.setup_paper` to draft one"))
    text = read(paper.template, String)
    parsed = try
        YAML.load(text)
    catch err
        err isa InterruptException && rethrow()
        throw(ConfigFileException("cannot read the template at $(paper.template): $(sprint(showerror, err))"))
    end
    parsed isa AbstractDict ||
        throw(ConfigFileException("the template at $(paper.template) holds no YAML mapping"))
    haskey(parsed, "read") &&
        throw(ConfigFileException("the template at $(paper.template) has a read: block, where the config's is written from the files the paper uses from the pipeline: take it out of the template"))
    return text
end

# The files a build of a paper uses, as `_sortdependencies` sorts them, the
# paper built with `latexmk` in a folder of its own, apart from a run's
function _paperuses(paper::LaTeXPaper, top::AbstractString)
    built = _latexmk(paper.tex, _paperfolder(paper) * "-check", paper.engine)
    return _sortdependencies(built.files, top, paper.pipeline)
end

# The files a paper uses from its pipeline folder, `files`, identified as
# `_pipelineentries` does: in the remote `remote` names, read from the CLI
# configuration of the project at or above `top`, or with `nothing` in the
# local registry, which `withlocal(f)` gives `f`; the registry must answer
function _identifypipeline(top::AbstractString, files::AbstractVector{String},
                           withlocal::Function, remote::PaperRemote;
                           newest::Bool = false)
    endpoint = _paperremote(remote, top)
    if isnothing(endpoint)
        return withlocal() do registry
            _answers(registry) ||
                throw(ReadWriteException("the local registry at $(registry.url) does not answer - start it with `DataPipeline.fair\"registry start\"`"))
            return _pipelineentries(registry, top, files; newest)
        end
    end
    _answers(endpoint) ||
        throw(ReadWriteException("the remote registry at $(endpoint.url) does not answer"))
    return _pipelineentries(endpoint, top, files; newest)
end

# The registry a paper's files are identified in: the remote that `remote`
# names in the CLI configuration of the project at or above `top`, with no
# token, since it is only read; the endpoint given; or with `nothing`, none,
# the local registry standing in
_paperremote(::Nothing, ::AbstractString) = nothing
_paperremote(remote::RegistryEndpoint, ::AbstractString) = remote
function _paperremote(remote::AbstractString, top::AbstractString)
    return RegistryEndpoint(_cliregistry(remote, top).uri)
end

# Whether a registry answers at its address, asked with no token, since one
# out of date would be refused where none is not
function _answers(registry::RegistryEndpoint)
    response = try
        HTTP.get(registry.url,
                 ["Accept" => "application/json; version=$(registry.api_version)"],
                 retry = false, connect_timeout = 5, status_exception = false)
    catch err
        err isa InterruptException && rethrow()
        return false
    end
    return response.status == 200
end

# Each file a paper uses from its pipeline folder, `files`, as paths from the
# top level `top`, identified in `registry` by its bytes, as `(entries,
# unregistered, problems)`. `entries` holds one entry for each data product
# the files are, sorted by namespace and name, as `(namespace, name, version,
# files, current)`: the version the highest with the files' bytes, or with
# `newest` the data product's newest, `current` saying whether the files have
# its bytes. `unregistered` holds the files no data product has the bytes of,
# and `problems` what is wrong with others: bytes of several data products,
# two versions of one, and with `newest` a newest version of another file type
function _pipelineentries(registry::RegistryEndpoint, top::AbstractString,
                          files::AbstractVector{String}; newest::Bool = false)
    unregistered = String[]
    problems = String[]
    byproduct = Dict{Tuple{String, String},
                     Vector{Pair{String, DataProductRecord}}}()
    for file in files
        records = _productrecords(registry, joinpath(top, file))
        if isempty(records)
            push!(unregistered, file)
            continue
        end
        names = unique((record.namespace, record.name) for record in records)
        if length(names) > 1
            push!(problems,
                  "$file has the bytes of several data products, $(join((_dataproductname(n...) for n in names), ", ")), so which it is cannot be told")
            continue
        end
        record = argmax(record -> record.version, records)
        push!(get!(byproduct, only(names),
                   Pair{String, DataProductRecord}[]), file => record)
    end
    entries = @NamedTuple{namespace::String, name::String,
                          version::VersionNumber, files::Vector{String},
                          current::Bool}[]
    for ((namespace, name), found) in sort!(collect(byproduct), by = first)
        versions = unique(record.version for record in last.(found))
        if length(versions) > 1
            push!(problems,
                  "$(join(first.(found), " and ")) are versions $(join(versions, ", ")) of $(_dataproductname(namespace, name)), where a paper uses one version of a data product")
            continue
        end
        record = last(first(found))
        version = newest ? record.newest : record.version
        if version != record.version
            extension = _productextension(registry, namespace, name, version)
            others = [file
                      for file in first.(found)
                      if lowercase(splitext(file)[2]) !=
                         "." * lowercase(extension)]
            if !isempty(others)
                push!(problems,
                      "the newest version of $(_dataproductname(namespace, name, version)) is a $extension file, so it cannot replace $(join(others, ", ")) under the same name - replace it by hand")
                continue
            end
        end
        push!(entries,
              (namespace = namespace, name = name, version = version,
               files = first.(found), current = version == record.version))
    end
    return (entries = entries, unregistered = unregistered,
            problems = problems)
end

# The data products a registry has registered with the bytes of the file at
# `path`
function _productrecords(registry::RegistryEndpoint, path::AbstractString)
    return [record
            for object in _registeredobjects(registry, _getfilehash(path))
            for record in object.data_products]
end

# The extension of the file a version of a data product is: its object's file
# type's, else its stored file's
function _productextension(registry::RegistryEndpoint, namespace::String,
                           name::String, version::VersionNumber)
    product = _finddataproduct(registry, namespace, name, string(version))
    object = _getentry(registry, URIs.URI(product["object"]))
    filetype = get(object, "file_type", nothing)
    isnothing(filetype) ||
        return String(_getentry(registry, URIs.URI(filetype))["extension"])
    location = _getentry(registry, URIs.URI(object["storage_location"]))
    return String(lstrip(splitext(location["path"])[2], '.'))
end

# Write a paper's config from its template's text and the entries for the
# data products it uses from the pipeline, and give its path
function _writepaperconfig(paper::LaTeXPaper, template::AbstractString,
                           entries::AbstractVector)
    text = _paperconfigtext(paper, template, entries)
    mkpath(dirname(paper.config))
    write(paper.config, text)
    @info "wrote $(paper.config), offering $(_counted(length(entries), "data product")) from the pipeline"
    return paper.config
end

# The text of a paper's config: a comment saying what wrote it, the template's
# text as it is, and a `read:` block with an entry for each data product the
# paper uses from the pipeline, pinned to its namespace and version, under a
# comment naming its files. An entry is labelled by the data product's name,
# or where two namespaces hold that name by its namespace and name
function _paperconfigtext(paper::LaTeXPaper, template::AbstractString,
                          entries::AbstractVector)
    source = _gitpath(paper.template, dirname(paper.config))
    names = [entry.name for entry in entries]
    lines = [
        "# Written by DataPipeline.update_paper from $source, adding a read:",
        "# block for the files the paper uses from the pipeline: change the",
        "# template, not this file, which is written afresh each time.",
        rstrip(template, '\n'),
        isempty(entries) ? "read: []" : "read:"]
    for entry in entries
        label = count(==(entry.name), names) > 1 ?
                "$(entry.namespace)/$(entry.name)" : entry.name
        append!(lines, "# " .* entry.files)
        push!(lines, "- data_product: $(_yamlquoted(label))", "  use:")
        label == entry.name ||
            push!(lines, "    data_product: $(_yamlquoted(entry.name))")
        push!(lines, "    namespace: $(_yamlquoted(entry.namespace))",
              "    version: $(_yamlquoted(string(entry.version)))")
    end
    text = join(lines, "\n") * "\n"
    parsed = YAML.load(text)
    reads = parsed isa AbstractDict ? get(parsed, "read", nothing) : nothing
    (reads isa AbstractVector && length(reads) == length(entries)) ||
        throw(ConfigFileException("the template at $(paper.template) does not end so that a read: block can follow it"))
    return text
end

# Copy the file of each of these data products from the local data store,
# where the local registry `registry` says it is, over the files from the
# pipeline it replaces, paths from the top level `top`; give each file with
# the data product it now is
function _copynewer(registry::RegistryEndpoint, top::AbstractString,
                    entries::AbstractVector)
    copied = Pair{String, String}[]
    for entry in entries
        label = _dataproductname(entry.namespace, entry.name, entry.version)
        namespace = _getid(registry, "namespace",
                           Dict("name" => entry.namespace))
        product = isnothing(namespace) ? nothing :
                  _getentry(registry, "data_product",
                            Dict("name" => entry.name,
                                 "namespace" => namespace,
                                 "version" => string(entry.version)))
        isnothing(product) &&
            throw(ReadWriteException("the local registry does not hold $label - `fair pull` brings it from the remote"))
        stored = _getstoragelocation(registry, product["object"])
        isfile(stored.path) ||
            throw(ReadWriteException("the local registry holds $label at $(stored.path), where there is no file"))
        for file in entry.files
            # Removed first, so that a file linked to another is not written
            # through
            cp(stored.path, joinpath(top, file), force = true)
            push!(copied, file => label)
        end
    end
    @info "replaced $(join(("$file with $label" for (file, label) in copied), ", "))"
    return copied
end

# Check a paper, as `check_paper` says: `registry` is the local registry's
# endpoint, or `nothing` where it could not be held, `held` saying why
function _checkpaper(paper::LaTeXPaper,
                     registry::Union{Nothing, RegistryEndpoint},
                     remote::PaperRemote;
                     held::Union{Nothing, String} = nothing)
    top = _papertop(paper)
    setup, actions, notes, unchecked = String[], String[], String[], String[]

    # What a run needs of the CLI, and the registries
    _clifound() ||
        push!(setup,
              "no `fair` found - install the package's own copy with `DataPipeline.install_cli!()`")
    initialised = isdir(joinpath(top, ".fair"))
    initialised ||
        push!(setup,
              "the repository at $top is not initialised for the pipeline - run `DataPipeline.fair\"init\"` there")
    if !isnothing(held)
        push!(setup, "the local registry cannot be held: $held")
    elseif !isnothing(registry) && !_answers(registry)
        push!(setup,
              "the local registry at $(registry.url) does not answer - start it with `DataPipeline.fair\"registry start\"`, after `DataPipeline.fair\"registry install\"` where none is installed")
        registry = nothing
    end
    localwhy = "the local registry cannot be reached"
    identifying, why = registry, localwhy
    if !isnothing(remote)
        identifying = _checkremote!(setup, top, remote, initialised)
        why = "the remote registry is not configured"
        if !isnothing(identifying) && !_answers(identifying)
            why = "the remote registry at $(identifying.url) does not answer"
            identifying = nothing
        end
    end

    # What the paper says of itself and what its metadata says
    front = try
        _frontmatter(_latexsource(paper.tex))
    catch err
        err isa ReadWriteException || rethrow()
        push!(actions, err.msg)
        nothing
    end
    told = String[]
    meta = try
        _papermetadata(top; told)
    catch err
        err isa ReadWriteException || rethrow()
        push!(actions, err.msg)
        nothing
    end
    _checksetup!(actions, paper, top)
    metadata = isnothing(meta) || isempty(meta.files) ? nothing :
               _metadataplace(top, first(meta.files))
    if !isnothing(metadata)
        append!(notes, told)
        isnothing(meta.licence) &&
            push!(actions, _nolicence(top, first(meta.files), metadata))
        if !isnothing(front)
            compared = _comparecitation(meta, front)
            said = _frontmatterreport(compared, first(meta.files))
            isnothing(said) || push!(actions, said)
            isempty(compared.unidentified) ||
                push!(notes,
                      "$metadata gives no ORCID for $(join(compared.unidentified, ", ")) - add them by hand")
        end
    end

    # The files a build uses, and what is not committed of them
    uses = nothing
    if isnothing(Sys.which("latexmk"))
        push!(unchecked,
              "the files the paper uses, and all that is said of them: there is no `latexmk` on the path - install a TeX distribution that has it, such as TeX Live")
    else
        try
            sorted = _paperuses(paper, top)
            uses = (pipeline = sorted.pipeline, own = sorted.own,
                    outside = length(sorted.outside))
        catch err
            err isa ReadWriteException || rethrow()
            push!(actions, "the paper does not build: $(err.msg)")
        end
    end
    _checkuncommitted!(actions, paper, top, meta, uses)

    # What the registries know of them
    if !isnothing(uses)
        if isnothing(identifying)
            push!(unchecked,
                  "the files from the pipeline - what each is registered as, newer versions, issues and what lies behind them - the config's read: block, and which files in and out of the pipeline folder are registered: $why")
        else
            holding = isnothing(remote) ? nothing : registry
            unregistered = String[]
            for file in uses.pipeline
                _checkpipelinefile!(actions, notes, unregistered, identifying,
                                    holding, paper, top, file)
            end
            isempty(unregistered) ||
                push!(actions, _unregisteredsaid(unregistered))
            if !isnothing(remote) && isnothing(registry)
                push!(unchecked,
                      "whether the local registry holds the files from the pipeline: $localwhy")
            end
            _checkconfig!(actions, identifying, paper, top, uses.pipeline)
            _checkplacement!(actions, identifying, paper, top, uses)
        end
    end
    if !isnothing(meta) && !isempty(meta.authors)
        if isnothing(identifying)
            push!(unchecked,
                  "how the authors differ from those of the PDF's version registered last: $why")
        else
            _checkpreviousauthors!(notes, identifying, paper, meta)
        end
    end
    return PaperCheck(paper, setup, uses, metadata, actions, notes, unchecked)
end

# Whether a `fair` can be found to run, as `fair"..."` finds one
function _clifound()
    try
        _faircommand(nothing)
        return true
    catch err
        err isa ArgumentError || rethrow()
        return false
    end
end

# The remote registry `remote` names in the CLI configuration of the project
# at `top`, or is, read with no token; adding to `setup` what its configuration
# lacks, its token included, and giving `nothing` where it names none. The
# configuration of a project not initialised, `initialised` false, is not
# looked for, its lack already said
function _checkremote!(::Vector{String}, ::AbstractString,
                       remote::RegistryEndpoint,
                       ::Bool)
    return remote
end
function _checkremote!(setup::Vector{String}, top::AbstractString,
                       remote::AbstractString, initialised::Bool)
    initialised || return nothing
    path = joinpath(top, ".fair", "cli-config.yaml")
    config = isfile(path) ? something(YAML.load_file(path), Dict()) : Dict()
    registries = something(get(config, "registries", nothing), Dict())
    entry = get(registries, remote, nothing)
    if !(entry isa AbstractDict && haskey(entry, "uri"))
        push!(setup,
              "the project's CLI configuration, $path, names no remote registry '$remote' - run `DataPipeline.fair\"init\"` in $top again to configure one")
        return nothing
    end
    if isnothing(_tokenfromfile(entry))
        file = get(entry, "token", nothing)
        push!(setup,
              "there is no token for the remote registry '$remote'$(file isa AbstractString ? " in $file" : ""), which pushing what the paper's run makes needs - put the token from the remote's web site there")
    end
    return RegistryEndpoint(String(entry["uri"]))
end

# Add to `actions` what is missing of the files `setup_paper` and
# `update_paper` write: `CITATION.cff` and the template, `CITATION.cff`'s
# `preferred-citation` where the repository holds a package, and the config
function _checksetup!(actions::Vector{String}, paper::LaTeXPaper,
                      top::AbstractString)
    citation = joinpath(top, "CITATION.cff")
    lacking = String[]
    isfile(citation) || push!(lacking, "CITATION.cff")
    isfile(paper.template) || push!(lacking, _gitpath(paper.template, top))
    # A file that cannot be read is said to be so where its metadata is read
    preferred() =
        try
            _haspreferred(read(citation, String))
        catch err
            err isa InterruptException && rethrow()
            true
        end
    if !isempty(lacking)
        push!(actions,
              "the paper is not set up: there is no $(join(lacking, " and ")) - run `DataPipeline.setup_paper` on it")
    elseif _holdspackage(top) && !preferred()
        push!(actions,
              "CITATION.cff describes the package the repository holds and has no preferred-citation for the paper - run `DataPipeline.setup_paper` to add one")
    elseif !isfile(paper.config)
        push!(actions,
              "there is no config at $(_gitpath(paper.config, top)) - run `DataPipeline.update_paper` to write it")
    end
    return nothing
end

# Where the paper's metadata comes from, said: the file `source`, and for
# `CITATION.cff` whether the paper's citation is its `preferred-citation` or
# its top level
function _metadataplace(top::AbstractString, source::AbstractString)
    source == "CITATION.cff" || return source
    preferred = try
        _haspreferred(read(joinpath(top, source), String))
    catch err
        err isa InterruptException && rethrow()
        false
    end
    return preferred ? "the preferred-citation of CITATION.cff" :
           "the top level of CITATION.cff"
end

# What `check_paper` says of the paper's metadata, from `source` and said as
# `metadata`, giving no licence, naming the files in the repository at `top`
# that do give one
function _nolicence(top::AbstractString, source::AbstractString,
                    metadata::AbstractString)
    giving = String[]
    if metadata == "the preferred-citation of CITATION.cff"
        said = _citationcffsays(_cffmapping(read(joinpath(top, source),
                                                 String)))
        isnothing(said.licence) ||
            push!(giving, "the top level of CITATION.cff gives $(said.licence)")
    end
    for (name, reader) in PAPER_METADATA_FILES
        name == source && continue
        path = joinpath(top, name)
        isfile(path) || continue
        said = try
            reader(read(path, String))
        catch err
            err isa InterruptException && rethrow()
            continue
        end
        isnothing(said) || isnothing(said.licence) ||
            push!(giving, "$name gives $(said.licence)")
    end
    return "$metadata gives no licence, so the PDF would be registered with none - add one" *
           (isempty(giving) ? "" : " ($(join(giving, "; ")))")
end

# What `check_paper` says of how the paper's LaTeX and its metadata from
# `source` differ, with what `update_paper` would do, or `nothing` where they
# do not
function _frontmatterreport(compared::NamedTuple, source::AbstractString)
    differences = _frontmatterdifferences(compared, source)
    isempty(differences) && return nothing
    remedy = if source != "CITATION.cff"
        "`update_paper` changes CITATION.cff alone, which `setup_paper` drafts"
    elseif compared.renaming
        "`update_paper` would leave the authors to be changed by hand, since an author both added and removed may be a renaming" *
        (isnothing(compared.title) ? "" : ", and change the title")
    else
        "`update_paper` would bring CITATION.cff into line"
    end
    return "the paper's LaTeX and its metadata differ: $(join(differences, "; ")) - $remedy"
end

# Add to `actions` the files the paper is built from that are not as the
# checked-out commit has them: its metadata files, its own files and those
# from the pipeline that it uses, and its template and config
function _checkuncommitted!(actions::Vector{String}, paper::LaTeXPaper,
                            top::AbstractString,
                            meta::Union{Nothing, RepositoryMetadata},
                            uses::Union{Nothing, NamedTuple})
    paths = String[]
    isnothing(meta) || append!(paths, meta.files)
    isnothing(uses) || append!(paths, uses.own, uses.pipeline)
    for file in (paper.template, paper.config)
        isfile(file) && push!(paths, _gitpath(file, top))
    end
    found = _uncommitted(top, unique(paths))
    isempty(found) && return nothing
    listed = join(("$path ($state)" for (path, state) in found), ", ")
    push!(actions,
          "files the paper is built from are not as the checked-out commit has them: $listed - commit them before `fair run`, or run from uncommitted changes with `fair run --dirty`")
    return nothing
end

# Add to `actions` and `notes` what `identifying` knows of a file the paper
# uses from the pipeline, `file` from the top level `top`: what it is
# registered as, whether a newer version exists, the issues on it and behind
# it, and the inputs behind it superseded since; and where `holding`, the
# local registry, is given, whether that holds it. A file registered as no data
# product is added to `unregistered`, to be said with the others
function _checkpipelinefile!(actions::Vector{String}, notes::Vector{String},
                             unregistered::Vector{String},
                             identifying::RegistryEndpoint,
                             holding::Union{Nothing, RegistryEndpoint},
                             paper::LaTeXPaper, top::AbstractString,
                             file::AbstractString)
    found = _identifyfile(identifying, joinpath(top, file), superseded = true)
    records = [record
               for object in found.objects for record in object.data_products]
    if isempty(records)
        push!(unregistered, file)
        return nothing
    end
    names = unique((record.namespace, record.name) for record in records)
    if length(names) > 1
        push!(actions,
              "$file has the bytes of several data products, $(join((_dataproductname(n...) for n in names), ", ")), so which it is cannot be told")
        return nothing
    end
    record = argmax(record -> record.version, records)
    label = _dataproductname(record.namespace, record.name, record.version)
    if record.version < record.newest
        extension = _productextension(identifying, record.namespace,
                                      record.name, record.newest)
        same = lowercase(splitext(file)[2]) == "." * lowercase(extension)
        push!(actions,
              "$file is $label, and v$(record.newest) is newer - " *
              (same ? "`update_paper(newest = true)` brings it in" :
               "it is a $extension file, so replace this one by hand"))
    else
        push!(notes, "$file is $label, its newest version")
    end
    for object in found.objects, issue in object.issues
        push!(notes, "$file: $(sprint(show, issue))")
    end
    for upstream in found.upstream
        push!(notes,
              "behind $file: $(sprint(show, upstream)), $(_throughline(upstream.through, upstream.making, upstream.input))")
    end
    for outdated in something(found.outdated, OutdatedInput[])
        push!(notes,
              "behind $file: $(sprint(show, outdated)), $(_throughline(outdated.through, outdated.making, true))")
    end
    if !isnothing(holding)
        held = any(_productrecords(holding, joinpath(top, file))) do other
            return (other.namespace, other.name, other.version) ==
                   (record.namespace, record.name, record.version)
        end
        held ||
            push!(actions,
                  "the local registry does not hold $file, $label - `fair pull $(_gitpath(paper.config, top))` pulls it")
    end
    return nothing
end

# Add to `actions` where the paper's config is not what `update_paper` would
# write from its template and the files it uses from the pipeline, `files`,
# as `identifying` identifies them, where that can be told
function _checkconfig!(actions::Vector{String}, identifying::RegistryEndpoint,
                       paper::LaTeXPaper, top::AbstractString,
                       files::AbstractVector{String})
    (isfile(paper.config) && isfile(paper.template)) || return nothing
    found = _pipelineentries(identifying, top, files)
    isempty(found.unregistered) && isempty(found.problems) || return nothing
    expected = try
        _paperconfigtext(paper, _templatetext(paper), found.entries)
    catch err
        err isa ConfigFileException || rethrow()
        push!(actions, err.msg)
        return nothing
    end
    read(paper.config, String) == expected ||
        push!(actions,
              "the config at $(_gitpath(paper.config, top)) is not what `update_paper` would write from the template and the files the paper uses - run `DataPipeline.update_paper`")
    return nothing
end

# Add to `actions` the files that are likely in the wrong place: those the
# paper uses from elsewhere in the repository that `identifying` has
# registered, which the build would take as the paper's own, and those in the
# pipeline folder that it has not, which the paper does not use
function _checkplacement!(actions::Vector{String},
                          identifying::RegistryEndpoint, paper::LaTeXPaper,
                          top::AbstractString, uses::NamedTuple)
    folder = _gitpath(paper.pipeline, top)
    for file in uses.own
        records = _productrecords(identifying, joinpath(top, file))
        isempty(records) && continue
        labels = unique(_dataproductname(r.namespace, r.name, r.version)
                        for r in records)
        push!(actions,
              "$file has the bytes of $(join(labels, ", ")), but is outside the pipeline folder, so the build takes it as the paper's own, with no provenance - move it into $folder")
    end
    used = Set(uses.pipeline)
    unused = [file
              for file in _pipelinefolderfiles(top, paper.pipeline)
              if !(file in used) &&
        isempty(_productrecords(identifying, joinpath(top, file)))]
    isempty(unused) ||
        push!(actions,
              "files in the pipeline folder are registered as no data product and the paper does not use them: $(join(unused, ", ")) - the folder is for files from the pipeline, so move them out, to the drawings folder for any the paper is to use")
    return nothing
end

# The files in a paper's pipeline folder, as paths from the top level `top`,
# but for the environment `setup_paper` creates there and any file git ignores
function _pipelinefolderfiles(top::AbstractString, folder::AbstractString)
    isdir(folder) || return String[]
    files = String[]
    for (dir, _, names) in walkdir(folder), name in names
        dir == folder && name in ("Project.toml", "Manifest.toml") && continue
        push!(files, _gitpath(joinpath(dir, name), top))
    end
    ignored = Set(path
                  for (path, state) in _uncommitted(top, files)
                  if state == "ignored")
    return sort!(filter(!in(ignored), files))
end

# Add to `notes` how the authors of the paper's metadata `meta` differ from
# those of the PDF's version `identifying` registered last, the data product
# named by the template
function _checkpreviousauthors!(notes::Vector{String},
                                identifying::RegistryEndpoint,
                                paper::LaTeXPaper, meta::RepositoryMetadata)
    pdf = _templatepdf(paper)
    isnothing(pdf) && return nothing
    latest = _latestdataproduct(identifying, pdf.namespace, pdf.name)
    isnothing(latest) && return nothing
    object = _getentry(identifying, URIs.URI(latest["object"]))
    names = [_getentry(identifying, URIs.URI(url))["name"]
             for url in object["authors"]]
    keys = _authorkey.(names)
    added = [name for name in meta.authors if !(_authorkey(name) in keys)]
    removed = [name
               for name in names
               if !(_authorkey(name) in _authorkey.(meta.authors))]
    isempty(added) && isempty(removed) && return nothing
    said = String[]
    isempty(added) || push!(said, "$(join(added, ", ")) added")
    isempty(removed) || push!(said, "$(join(removed, ", ")) removed")
    push!(notes,
          "the authors differ from those of $(_dataproductname(pdf.namespace, pdf.name, latest["version"])), the PDF's version registered last: $(join(said, "; "))")
    return nothing
end

# The namespace and name of the PDF's data product as the paper's template
# writes it, in its one `write:` entry of file type pdf, the namespace being
# the CLI's default for outputs where the template names none; `nothing` where
# either cannot be told
function _templatepdf(paper::LaTeXPaper)
    parsed = try
        YAML.load_file(paper.template)
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
    parsed isa AbstractDict || return nothing
    entries = [entry
               for entry in something(get(parsed, "write", nothing), [])
               if entry isa AbstractDict &&
        get(entry, "file_type", nothing) == "pdf"]
    length(entries) == 1 || return nothing
    entry = only(entries)
    use = something(get(entry, "use", nothing), Dict())
    run_metadata = something(get(parsed, "run_metadata", nothing), Dict())
    name = something(get(use, "data_product", nothing),
                     get(entry, "data_product", nothing), Some(nothing))
    namespace = something(get(use, "namespace", nothing),
                          get(run_metadata, "default_output_namespace",
                              nothing),
                          _clioutputnamespace(dirname(paper.tex)),
                          Some(nothing))
    (isnothing(name) || isnothing(namespace)) && return nothing
    return (namespace = String(namespace), name = String(name))
end

# The namespace the CLI writes outputs in by default, from the configuration
# of the project at or above `dir`, else its global one; `nothing` where
# neither names one
function _clioutputnamespace(dir::AbstractString)
    project = _fairroot(dir)
    paths = [joinpath(homedir(), ".fair", "cli", "cli-config.yaml")]
    isnothing(project) ||
        pushfirst!(paths, joinpath(project, ".fair", "cli-config.yaml"))
    for path in paths
        isfile(path) || continue
        config = something(YAML.load_file(path), Dict())
        namespaces = something(get(config, "namespaces", nothing), Dict())
        value = get(namespaces, "output", nothing)
        value isa AbstractString && return String(value)
    end
    return nothing
end
