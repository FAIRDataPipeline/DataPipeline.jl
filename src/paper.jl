# SPDX-License-Identifier: LGPL-3.0-or-later

# A LaTeX paper built in a code run: built with `latexmk` in a folder of the
# package's own, the metadata its repository gives it written into the PDF,
# each file it uses from the pipeline folder recorded as an input, and the PDF
# registered as an output with its authors, licence and keywords.

"""
    LaTeXPaper(tex; pipeline = "pipeline", template = "<stem>.template.yaml",
               config = "<stem>.yaml", engine = PdfLaTeXEngine())

A LaTeX paper the pipeline builds: its main `.tex` file, the folder holding
the files it uses that come from the pipeline, the template of the user config
that builds it and the config made from that, and the engine it is built
with. Relative paths are taken from the folder holding `tex`, where `latexmk`
runs, and the template and config are named by `tex`'s stem, so
`paper/article.tex` has `paper/pipeline`, `paper/article.template.yaml` and
`paper/article.yaml`. Every function that takes a paper also takes the path of
its `.tex` file, for a paper with these defaults.

# Fields
- `tex`: the main `.tex` file, as an absolute path
- `pipeline`: the folder of the files from the pipeline, as an absolute path
- `template`: the user config's template, as an absolute path
- `config`: the user config made from the template, as an absolute path
- `engine`: the engine, [`PdfLaTeXEngine`](@ref), [`LuaLaTeXEngine`](@ref) or
  [`XeLaTeXEngine`](@ref)
"""
struct LaTeXPaper{E <: AbstractLaTeXEngine}
    tex::String
    pipeline::String
    template::String
    config::String
    engine::E

    function LaTeXPaper(tex::AbstractString;
                        pipeline::AbstractString = "pipeline",
                        template::Union{Nothing, AbstractString} = nothing,
                        config::Union{Nothing, AbstractString} = nothing,
                        engine::AbstractLaTeXEngine = PdfLaTeXEngine())
        tex = abspath(tex)
        isfile(tex) || throw(ArgumentError("no LaTeX document at $tex"))
        folder = dirname(tex)
        stem = splitext(basename(tex))[1]
        place(path) = normpath(joinpath(folder, path))
        return new{typeof(engine)}(tex, place(pipeline),
                                   place(something(template,
                                                   "$stem.template.yaml")),
                                   place(something(config, "$stem.yaml")),
                                   engine)
    end
end

function Base.show(io::IO, paper::LaTeXPaper)
    return print(io, "LaTeXPaper(", repr(paper.tex), ", ", paper.engine, ")")
end

function Base.show(io::IO, ::MIME"text/plain", paper::LaTeXPaper)
    println(io, "LaTeX paper ", paper.tex)
    println(io, "  files from the pipeline in ", paper.pipeline)
    println(io, "  template ", paper.template)
    println(io, "  config ", paper.config)
    return print(io, "  built with ", paper.engine)
end

# == Functions ==

"""
    build_paper!(handle, paper; data_product = nothing)

Build the LaTeX paper `paper`, a [`LaTeXPaper`](@ref) or the path of its
`.tex` file, in the code run `handle`: record each file it uses from its
pipeline folder as an input of the run, register the PDF as its output, and
return the PDF's path, as [`link_write!`](@ref) does with a `path`.

The paper must be in the run's repository, checked out at the run's commit,
and every file the build uses from the repository must be as that commit has
it, as must the metadata files read, unless the run is from uncommitted
changes, as `fair run --dirty` records one, when they are taken as they are
and an info message names them. Its title and authors, in order, must be
those its metadata gives - the citation of the paper in `CITATION.cff`, its
`preferred-citation` where it has one, else the first of `.zenodo.json`,
`codemeta.json` and its project file that exists. Each file it uses from the
pipeline folder must have the bytes of a data product the working config's
`read:` block offers. The PDF is written under the working config's one
`write:` entry of file type `pdf`, or under `data_product`, with the authors,
licence and keywords of the paper's metadata, which are written into the
PDF's document information as well and read back from it. Anything wrong is
an error before anything is registered.

The paper is built with `latexmk`, from the folder holding its `.tex` file,
into a folder of the package's own kept between builds, so that an unchanged
paper gives the same bytes and is found unchanged rather than registered
again. A rehearsal builds in a folder of its own, registers nothing, and warns
of what a recorded run would refuse rather than stopping. A change of authors
from the version registered before is said.

In a recorded run, once [`finalise`](@ref) has registered it, the pdf is also
copied to `<stem>.pdf` beside the `.tex` file, where `latexmk` builds one, so
that the file there is the registered one - but not where git tracks that
file, which is then left as it is, with a warning.
"""
function build_paper!(handle::DataRegistryHandle, paper::LaTeXPaper;
                      data_product::Union{Nothing, AbstractString} = nothing)
    mode = handle.mode
    top = _paperrepository(handle, paper)
    entry = _paperwriteentry(handle, data_product)
    front = _frontmatter(_latexsource(paper.tex))
    meta = _papermetadata(top)
    # The metadata is the commit's only where its files are, as the build's are
    dirty = endswith(handle.config["run_metadata"]["latest_commit"], "-dirty")
    _checkcommitted(mode, top, meta.files, dirty)
    _checkfrontmatter(mode, meta, front, top)
    described = _paperdescription(handle, meta)

    folder = _paperfolder(mode, paper)
    _writemetadatatex(folder, meta)
    built = _latexmk(paper.tex, folder, paper.engine;
                     options = ["-usepretex=\\input{$METADATA_TEX}"],
                     texinputs = folder)
    sorted = _sortdependencies(built.files, top, paper.pipeline)
    _checkcommitted(mode, top, vcat(sorted.own, sorted.pipeline), dirty)
    inputs = _pipelineinputs(handle, top, sorted.pipeline)
    _checkdocumentinfo(mode, paper.engine, built.pdf, meta)

    for (file, label) in inputs
        link_read!(handle, label, path = joinpath(top, file))
    end
    previous = _previousauthors(handle, entry)
    path = mktempdir() do scratch
        # The data store holds a copy: a link would be rewritten by the next
        # build, which writes the PDF in place
        copied = joinpath(scratch, basename(built.pdf))
        cp(built.pdf, copied)
        return _linkwrite!(handle, entry, copied, described, false)
    end
    _copybeside!(handle, entry, paper, top)
    _sayauthorchange(handle, previous, described)
    return path
end
function build_paper!(handle::DataRegistryHandle, tex::AbstractString;
                      data_product::Union{Nothing, AbstractString} = nothing)
    return build_paper!(handle, LaTeXPaper(tex); data_product)
end

# What a recorded run refuses, which a rehearsal, registering nothing, says it
# would refuse
function _paperproblem(::RecordedRun, message::AbstractString)
    return throw(ReadWriteException(message))
end
function _paperproblem(::Rehearsal, message::AbstractString)
    @warn "a recorded run would stop here: $message"
    return nothing
end

# The pdf beside a paper's `.tex` file, where `latexmk` builds one by default
function _pdfbeside(paper::LaTeXPaper)
    return joinpath(dirname(paper.tex),
                    splitext(basename(paper.tex))[1] * ".pdf")
end

# Have `finalise` copy the pdf the run writes under `entry` beside the paper's
# `.tex` file once it is registered, in a recorded run, unless git tracks the
# file there, which every run would then change; a rehearsal copies nothing
function _copybeside!(::DataRegistryHandle{Rehearsal}, ::String, ::LaTeXPaper,
                      ::AbstractString)
    return nothing
end
function _copybeside!(handle::DataRegistryHandle{RecordedRun}, entry::String,
                      paper::LaTeXPaper, top::AbstractString)
    beside = _pdfbeside(paper)
    if _githolding(top, _gitpath(beside, top)).tracked
        @warn "git tracks $(_gitpath(beside, top)), so the registered PDF is not copied there: untrack and ignore it to have the copy"
        return nothing
    end
    key = (entry, nothing)
    written = haskey(handle.outputs, key) ? handle.outputs[key] :
              handle.unchanged[key]
    written["copy_to"] = beside
    return nothing
end

# Copy each registered file that is to be copied elsewhere too, as a paper's
# PDF is beside its `.tex` file: a copy, since a plain build there writes the
# file in place, which through a link would change the registered file. The
# run is registered by then, so a copy that fails is a warning
function _copyregistered(handle::DataRegistryHandle)
    for written in Iterators.flatten((values(handle.outputs),
                                      values(handle.unchanged)))
        target = get(written, "copy_to", nothing)
        isnothing(target) && continue
        try
            cp(written["path"], target, force = true)
            println("copied to ", target)
        catch err
            err isa Union{Base.IOError, SystemError} || rethrow()
            @warn "the registered file $(written["path"]) could not be copied to $target: $(sprint(showerror, err))"
        end
    end
    return nothing
end

# The top level of the run's repository, which must hold the paper and be
# checked out at the run's commit, since the run records the paper's own files
# as that commit has them
function _paperrepository(handle::DataRegistryHandle, paper::LaTeXPaper)
    top = _gittoplevel(dirname(paper.tex))
    isnothing(top) &&
        throw(ReadWriteException("$(paper.tex) is in no git repository, so no commit can record it"))
    run_metadata = handle.config["run_metadata"]
    _resolved(top) == _resolved(run_metadata["local_repo"]) ||
        throw(ReadWriteException("$(paper.tex) is in the repository at $top, not the run's, $(run_metadata["local_repo"])"))
    commit = replace(run_metadata["latest_commit"], r"-dirty$" => "")
    head = LibGit2.with(LibGit2.GitRepo(top)) do repo
        return string(LibGit2.head_oid(repo))
    end
    head == commit ||
        _paperproblem(handle.mode,
                      "the repository at $top has $head checked out, not the run's commit, $commit")
    return top
end

# The label of the working config's `write:` entry the PDF is written under:
# `data_product`, which must be of file type `pdf`, or else the one entry
# naming no pattern that is
function _paperwriteentry(handle::DataRegistryHandle,
                          data_product::Union{Nothing, AbstractString})
    if !isnothing(data_product)
        wmd, _ = _writemetadata(handle, String(data_product))
        get(wmd, "file_type", nothing) == "pdf" ||
            throw(ConfigFileException("the working config writes '$data_product' as $(repr(get(wmd, "file_type", nothing))), not as a pdf"))
        return String(data_product)
    end
    labels = [String(entry["data_product"])
              for entry in get(handle.config, "write", [])
              if get(entry, "file_type", nothing) == "pdf" &&
        !occursin('*', entry["data_product"])]
    isempty(labels) &&
        throw(ConfigFileException("the working config has no `write:` entry of file type pdf to write the paper under"))
    length(labels) == 1 ||
        throw(ConfigFileException("the working config has several `write:` entries of file type pdf - $(join(labels, ", ")) - so the paper's must be named with `data_product`"))
    return only(labels)
end

# Check that the paper's title and authors, in order, are those its metadata
# gives, `top` being where the metadata files are
function _checkfrontmatter(mode::AbstractRunMode, meta::RepositoryMetadata,
                           front::NamedTuple, top::AbstractString)
    if isempty(meta.files)
        return _paperproblem(mode,
                             "no CITATION.cff or other metadata file in $top gives the paper's authors")
    end
    differences = _frontmatterdifferences(_comparecitation(meta, front),
                                          first(meta.files))
    isempty(differences) && return nothing
    return _paperproblem(mode,
                         "the paper's LaTeX and its metadata differ: $(join(differences, "; ")) - bring $(first(meta.files)) into line with the LaTeX before building")
end

# How the paper's title and authors differ between its LaTeX and the metadata
# file `source`, as `_comparecitation` compared them, each difference said
function _frontmatterdifferences(compared::NamedTuple, source::AbstractString)
    differences = String[]
    isnothing(compared.title) ||
        push!(differences,
              "the title is $(repr(compared.title.latex)) in the LaTeX and $(repr(compared.title.file)) in $source")
    isempty(compared.added) ||
        push!(differences,
              "$(join(compared.added, ", ")) in the LaTeX and not in $source")
    isempty(compared.removed) ||
        push!(differences,
              "$(join(compared.removed, ", ")) in $source and not in the LaTeX")
    compared.reordered &&
        push!(differences, "the authors are in another order")
    return differences
end

# What the registry is to record of the PDF: the authors of the paper's
# metadata, found or created as the run's mode allows, its licence and its
# keywords
function _paperdescription(handle::DataRegistryHandle, meta::RepositoryMetadata)
    authors = String[]
    for name in meta.authors
        if !_nameable(name)
            @warn "the registry cannot hold an author named '$name', which the paper's metadata gives: it takes none of $(join(UNNAMEABLE, " ")) in a name, so that author is passed over"
            continue
        end
        identifier = get(meta.identifiers, name, nothing)
        url = isnothing(identifier) ? _namedauthorurl(handle, name) :
              _identifiedauthorurl(handle, name, identifier)
        url in authors || push!(authors, url)
    end
    licence = nothing
    if !isnothing(meta.licence)
        licence = try
            _licence(meta.licence)
        catch err
            err isa ArgumentError || rethrow()
            @warn "the paper's licence '$(meta.licence)' is not recorded: $(err.msg)"
            nothing
        end
    end
    return OutputDescription(authors, licence, meta.keywords)
end

# The URL of the registry's author with this identifier, created where the
# registry has none, or in a rehearsal what stands for one it would create
function _identifiedauthorurl(handle::DataRegistryHandle, name::AbstractString,
                              identifier::AbstractString)
    query = Dict("identifier" => identifier)
    url = _geturl(handle.registry, "author", query)
    isnothing(url) || return url
    _createauthor(handle, name, identifier)
    return something(_geturl(handle.registry, "author", query),
                     _unregisteredauthor(name))
end

# The name of the file of TeX that gives the PDF its metadata, in the build
# folder, which is on TeX's input path for the build
const METADATA_TEX = "datapipeline-metadata.tex"

# The folder a paper is built in, the package's own and kept between builds,
# one for each `.tex` file and a rehearsal's apart, so that a recorded run only
# registers a PDF it built itself
function _paperfolder(mode::AbstractRunMode, paper::LaTeXPaper)
    return _paperfolder(paper) * _foldersuffix(mode)
end
# ... and the path such folders start with, each adding a suffix of its own
function _paperfolder(paper::LaTeXPaper)
    key = first(bytes2hex(SHA.sha1(_resolved(paper.tex))), 16)
    return joinpath(@get_scratch!("papers"), key)
end
_foldersuffix(::RecordedRun) = ""
_foldersuffix(::Rehearsal) = "-rehearsal"

# Write the file of TeX giving the PDF the paper's metadata into the build
# folder, leaving one with the same text untouched, so that unchanged metadata
# does not make the paper be built again
function _writemetadatatex(folder::AbstractString, meta::RepositoryMetadata)
    mkpath(folder)
    path = joinpath(folder, METADATA_TEX)
    text = _metadatatex(_documentinfo(meta))
    (isfile(path) && read(path, String) == text) || write(path, text)
    return path
end

# The document information a PDF is to have from the paper's metadata, as
# PDF keys and their values, in order: its title, authors, keywords, and as
# keys of their own its licence and its authors' identifiers, each only where
# there is one
function _documentinfo(meta::RepositoryMetadata)
    info = Pair{String, String}[]
    isnothing(meta.title) || push!(info, "Title" => meta.title)
    isempty(meta.authors) || push!(info, "Author" => join(meta.authors, "; "))
    isempty(meta.keywords) ||
        push!(info, "Keywords" => join(meta.keywords, "; "))
    isnothing(meta.licence) || push!(info, "License" => meta.licence)
    identified = ["$name: $(meta.identifiers[name])"
                  for name in meta.authors if haskey(meta.identifiers, name)]
    isempty(identified) ||
        push!(info, "AuthorIdentifiers" => join(identified, "; "))
    return info
end

# The keys `hyperref` takes for the standard fields of the document
# information, the others going in its `pdfinfo`
const HYPERREF_KEYS = Dict("Title" => "pdftitle", "Author" => "pdfauthor",
                           "Keywords" => "pdfkeywords")

# The TeX that gives a PDF this document information at the end of
# `\begin{document}`: to `hyperref` where it is loaded, as TeX text, since
# beside it a field written directly is written twice; otherwise with the
# engine's own command, LuaTeX's, XeTeX's or pdfTeX's, as UTF-16 in
# hexadecimal. Either overrides what the paper sets itself before then
function _metadatatex(info::Vector{Pair{String, String}})
    standard = ["$(HYPERREF_KEYS[key])={$(_texescaped(value))}"
                for (key, value) in info if haskey(HYPERREF_KEYS, key)]
    custom = ["$key={$(_texescaped(value))}"
              for (key, value) in info if !haskey(HYPERREF_KEYS, key)]
    isempty(custom) || push!(standard, "pdfinfo={$(join(custom, ","))}")
    direct = join(("/$key $(_pdfhexstring(value))" for (key, value) in info),
                  " ")
    return """
           % The document information DataPipeline registers with this PDF
           \\AddToHook{begindocument/end}{%
           \\ifdefined\\hypersetup
             \\hypersetup{$(join(standard, ","))}%
           \\else\\ifdefined\\pdfextension
             \\pdfextension info{$direct}%
           \\else\\ifdefined\\XeTeXrevision
             \\special{pdf:docinfo<<$direct>>}%
           \\else
             \\pdfinfo{$direct}%
           \\fi\\fi\\fi}
           """
end

# Text as TeX reads it as itself in `hyperref`'s keys, its special characters
# escaped
function _texescaped(text::AbstractString)
    return replace(text, "\\" => "\\textbackslash{}", "{" => "\\{",
                   "}" => "\\}", "#" => "\\#", "\$" => "\\\$", "%" => "\\%",
                   "&" => "\\&", "_" => "\\_", "^" => "\\textasciicircum{}",
                   "~" => "\\textasciitilde{}")
end

# Text as a PDF string in hexadecimal, UTF-16 with its byte order mark
function _pdfhexstring(text::AbstractString)
    units = transcode(UInt16, String(text))
    return "<FEFF" *
           join(uppercase(string(unit, base = 16, pad = 4)) for unit in units) *
           ">"
end

# Check that files of the repository the paper is made from - its metadata
# files, and after the build those it uses - are as the run's commit has them;
# in a run from uncommitted changes, `dirty`, say which are not
function _checkcommitted(mode::AbstractRunMode, top::AbstractString,
                         paths::AbstractVector{String}, dirty::Bool)
    found = _uncommitted(top, paths)
    isempty(found) && return nothing
    listed = join(("$path ($state)" for (path, state) in found), ", ")
    if dirty
        @info "the run is from uncommitted changes, so these files the paper uses are taken as they are: $listed"
        return nothing
    end
    return _paperproblem(mode,
                         "files the paper uses are not as the run's commit has them: $listed - commit them before building, or run from uncommitted changes with `fair run --dirty`")
end

# Each file the paper uses from the pipeline folder, as a path from the top
# level `top`, with the label of the working config's `read:` entry offering
# the data product it has the bytes of, as pairs in the files' order. A file
# no entry offers, or several do, is refused
function _pipelineinputs(handle::DataRegistryHandle, top::AbstractString,
                         files::AbstractVector{String})
    offered = _offeredhashes(handle)
    inputs = Pair{String, String}[]
    unmatched = String[]
    ambiguous = String[]
    for file in files
        labels = get(offered, _getfilehash(joinpath(top, file)), String[])
        if isempty(labels)
            push!(unmatched, file)
        elseif length(labels) > 1
            push!(ambiguous, "$file ($(join(labels, ", ")))")
        else
            push!(inputs, file => only(labels))
        end
    end
    isempty(unmatched) ||
        _paperproblem(handle.mode,
                      "files the paper uses from its pipeline folder are not the bytes of any data product the working config's read: block offers: $(join(unmatched, ", "))")
    isempty(ambiguous) ||
        _paperproblem(handle.mode,
                      "files the paper uses from its pipeline folder have the bytes of several data products the working config's read: block offers: $(join(ambiguous, "; "))")
    return inputs
end

# The hash of the file of each data product the working config's `read:`
# block offers by name, with the labels of the entries offering it; a pattern,
# and a data product with no file, offer none
function _offeredhashes(handle::DataRegistryHandle)
    offered = Dict{String, Vector{String}}()
    registry = handle.registry
    for entry in get(handle.config, "read", [])
        label = String(entry["data_product"])
        occursin('*', label) && continue
        rmd = _readmetadata(handle, label)
        product = _finddataproduct(registry, rmd.namespace, rmd.data_product,
                                   rmd.version)
        object = _getentry(registry, URIs.URI(product["object"]))
        isnothing(object["storage_location"]) && continue
        hash = _getentry(registry, URIs.URI(object["storage_location"]))["hash"]
        push!(get!(offered, hash, String[]), label)
    end
    return offered
end

# Check that the PDF's document information holds what is registered with it,
# which a paper or class setting its own after `\begin{document}` would
# change. XeLaTeX compresses it, and it cannot be read without a decompressor,
# so is not checked; a PDF whose information cannot be found is not either
function _checkdocumentinfo(mode::AbstractRunMode, ::AbstractLaTeXEngine,
                            pdf::AbstractString, meta::RepositoryMetadata)
    found = _pdfdocumentinfo(read(pdf))
    if isnothing(found)
        @warn "cannot find the document information in $pdf, so what it holds is not checked"
        return nothing
    end
    wrong = String[]
    for (key, value) in _documentinfo(meta)
        held = get(found, key, nothing)
        held == value ||
            push!(wrong, "$key is $(repr(held)), not $(repr(value))")
    end
    isempty(wrong) && return nothing
    return _paperproblem(mode,
                         "the PDF's document information does not hold what is registered with it: $(join(wrong, "; ")) - the paper or its class may set its own after \\begin{document}")
end
function _checkdocumentinfo(::AbstractRunMode, ::XeLaTeXEngine,
                            ::AbstractString,
                            ::RepositoryMetadata)
    return nothing
end

# The document information of a PDF, its keys and their values, read from its
# `Info` dictionary where that is written out uncompressed; `nothing` where it
# cannot be found. The last `/Info` is the latest, a PDF updated in place
# adding to its end
function _pdfdocumentinfo(bytes::AbstractVector{UInt8})
    found = findlast(codeunits("/Info"), bytes)
    isnothing(found) && return nothing
    reference = _pdfreference(bytes, last(found) + 1)
    isnothing(reference) && return nothing
    label = codeunits("$(reference.number) $(reference.generation) obj")
    start = findlast(label, bytes)
    # A longer number ending in this one is another object
    while !isnothing(start) && first(start) > 1 &&
          isdigit(Char(bytes[first(start) - 1]))
        start = findprev(label, bytes, first(start) - 1)
    end
    isnothing(start) && return nothing
    opening = findnext(codeunits("<<"), bytes, last(start) + 1)
    isnothing(opening) && return nothing
    return _pdfdictionary(bytes, last(opening) + 1)
end

# The object number and generation of the indirect reference `N G R` that
# starts at `i`, or `nothing` where there is none
function _pdfreference(bytes::AbstractVector{UInt8}, i::Integer)
    numbers = Int[]
    n = length(bytes)
    for _ in 1:2
        while i <= n && isspace(Char(bytes[i]))
            i += 1
        end
        j = i
        while j <= n && isdigit(Char(bytes[j]))
            j += 1
        end
        j == i && return nothing
        push!(numbers, parse(Int, String(bytes[i:(j - 1)])))
        i = j
    end
    while i <= n && isspace(Char(bytes[i]))
        i += 1
    end
    (i <= n && bytes[i] == UInt8('R')) || return nothing
    return (number = numbers[1], generation = numbers[2])
end

# The keys and values of a PDF dictionary whose entries start at `i`, each
# value a string, its others left out
function _pdfdictionary(bytes::AbstractVector{UInt8}, i::Integer)
    info = Dict{String, String}()
    key = nothing
    n = length(bytes)
    while i <= n
        c = Char(bytes[i])
        if isspace(c)
            i += 1
        elseif c == '>' && i < n && Char(bytes[i + 1]) == '>'
            break
        elseif c == '/'
            j = i + 1
            while j <= n && !(Char(bytes[j]) in " \t\r\n/<>()[]{}%")
                j += 1
            end
            name = String(bytes[(i + 1):(j - 1)])
            isnothing(key) ? (key = name) : (key = nothing)
            i = j
        elseif c == '('
            value, i = _pdfliteral(bytes, i)
            isnothing(key) || (info[key] = value)
            key = nothing
        elseif c == '<'
            j = something(findnext(==(UInt8('>')), bytes, i), n)
            value = _pdfhex(String(bytes[(i + 1):(j - 1)]))
            isnothing(key) || (info[key] = value)
            key = nothing
            i = j + 1
        else
            # Any other value: a number, a reference or a name's value
            while i <= n && !(Char(bytes[i]) in " \t\r\n/<>()")
                i += 1
            end
            key = nothing
        end
    end
    return info
end

# A PDF literal string starting at `i`, its escapes read and its parentheses
# balanced, as text, and the index after it
function _pdfliteral(bytes::AbstractVector{UInt8}, i::Integer)
    out = UInt8[]
    depth = 0
    n = length(bytes)
    while i <= n
        b = bytes[i]
        if b == UInt8('\\') && i < n
            e = bytes[i + 1]
            if UInt8('0') <= e <= UInt8('7')
                j = i + 1
                while j <= min(i + 3, n) && UInt8('0') <= bytes[j] <= UInt8('7')
                    j += 1
                end
                push!(out,
                      parse(UInt8, String(bytes[(i + 1):(j - 1)]), base = 8))
                i = j
                continue
            end
            escapes = Dict(UInt8('n') => 0x0a, UInt8('r') => 0x0d,
                           UInt8('t') => 0x09, UInt8('b') => 0x08,
                           UInt8('f') => 0x0c)
            push!(out, get(escapes, e, e))
            i += 2
            continue
        end
        if b == UInt8('(')
            depth += 1
            depth > 1 && push!(out, b)
        elseif b == UInt8(')')
            depth -= 1
            depth == 0 && return (_pdftext(out), i + 1)
            push!(out, b)
        else
            push!(out, b)
        end
        i += 1
    end
    return (_pdftext(out), i)
end

# A PDF hexadecimal string's text
function _pdfhex(hex::AbstractString)
    digits = filter(isxdigit, hex)
    isodd(length(digits)) && (digits *= "0")
    return _pdftext(hex2bytes(digits))
end

# The text of a PDF string's bytes: UTF-16 after its byte order mark, else
# PDFDocEncoding, which is Latin-1 for the characters that matter here
function _pdftext(bytes::AbstractVector{UInt8})
    if length(bytes) >= 2 && bytes[1] == 0xfe && bytes[2] == 0xff
        units = [UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])
                 for k in 3:2:(length(bytes) - 1)]
        return Base.Unicode.normalize(transcode(String, units), :NFC)
    end
    return String(map(Char, bytes))
end

# The registry URLs of the authors of the version of the paper's data product
# registered before this run, or `nothing` where there is none
function _previousauthors(handle::DataRegistryHandle, label::AbstractString)
    wmd, name = _writemetadata(handle, String(label))
    namespace = _writenamespace(handle, wmd)
    latest = _latestdataproduct(handle.registry, namespace, name)
    isnothing(latest) && return nothing
    object = _getentry(handle.registry, URIs.URI(latest["object"]))
    return (version = String(latest["version"]),
            authors = String.(object["authors"]))
end

# Say how the PDF's authors differ from those of the version before, by name
function _sayauthorchange(handle::DataRegistryHandle,
                          previous::Union{Nothing, NamedTuple},
                          described::OutputDescription)
    isnothing(previous) && return nothing
    added = setdiff(described.authors, previous.authors)
    removed = setdiff(previous.authors, described.authors)
    isempty(added) && isempty(removed) && return nothing
    name(url) = startswith(url, "unregistered author: ") ?
                chopprefix(url, "unregistered author: ") :
                _getentry(handle.registry, URIs.URI(url))["name"]
    said = String[]
    isempty(added) || push!(said, "added $(join(name.(added), ", "))")
    isempty(removed) || push!(said, "removed $(join(name.(removed), ", "))")
    @info "the paper's authors differ from those of version $(previous.version): $(join(said, "; "))"
    return nothing
end
