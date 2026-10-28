# SPDX-License-Identifier: LGPL-3.0-or-later

# What a LaTeX paper is made from and says of itself: the files a build of it
# uses, as `latexmk` lists them, sorted by where they come from, and its title,
# authors and their affiliations, read from the document as TeX reads it.

# The engine a paper is built with
abstract type AbstractLaTeXEngine end

"""
    PdfLaTeXEngine()

The pdfLaTeX engine, for building a paper with `latexmk -pdf`; the default.
"""
struct PdfLaTeXEngine <: AbstractLaTeXEngine end

"""
    LuaLaTeXEngine()

The LuaLaTeX engine, for building a paper with `latexmk -pdflua`.
"""
struct LuaLaTeXEngine <: AbstractLaTeXEngine end

"""
    XeLaTeXEngine()

The XeLaTeX engine, for building a paper with `latexmk -pdfxe`.
"""
struct XeLaTeXEngine <: AbstractLaTeXEngine end

# == Functions ==

# The flag that has `latexmk` build with an engine
_latexmkflag(::PdfLaTeXEngine) = "-pdf"
_latexmkflag(::LuaLaTeXEngine) = "-pdflua"
_latexmkflag(::XeLaTeXEngine) = "-pdfxe"

# Build the document `tex` with `latexmk` and `engine` into the folder `outdir`,
# running in the folder holding `tex` and naming the PDF by its stem, with
# `options` added to the command and the folder `texinputs`, where there is
# one, searched for TeX's input files before the others. Return the files the
# build used, as absolute paths in the order `latexmk -deps-out` lists them,
# and the PDF's path, as `(files, pdf)`
function _latexmk(tex::AbstractString, outdir::AbstractString,
                  engine::AbstractLaTeXEngine;
                  options::Vector{String} = String[],
                  texinputs::Union{Nothing, AbstractString} = nothing)
    latexmk = Sys.which("latexmk")
    isnothing(latexmk) &&
        throw(ReadWriteException("no `latexmk` on the path: building a paper needs a TeX distribution that has it, such as TeX Live or MiKTeX"))
    tex = abspath(tex)
    isfile(tex) || throw(ReadWriteException("no LaTeX document at $tex"))
    folder = dirname(tex)
    stem = splitext(basename(tex))[1]
    outdir = abspath(outdir)
    mkpath(outdir)
    listing = joinpath(outdir, "$stem.deps")
    log = joinpath(outdir, "$stem.latexmk.log")
    # Run latexmk with `flags` too, and return the files its listing names
    function build(flags::Vector{String})
        command = Cmd(`$latexmk $(_latexmkflag(engine)) $flags -interaction=nonstopmode -halt-on-error -outdir=$outdir -deps-out=$listing -jobname=$stem $options $(basename(tex))`,
                      dir = folder)
        if !isnothing(texinputs)
            # A trailing separator keeps TeX's own search path after the folder
            separator = Sys.iswindows() ? ";" : ":"
            command = addenv(command,
                             "TEXINPUTS" =>
                                 abspath(texinputs) * separator *
                                 get(ENV, "TEXINPUTS", ""))
        end
        built = open(log, "w") do io
            return success(pipeline(command, stdout = io, stderr = io))
        end
        built ||
            throw(ReadWriteException("latexmk could not build $tex - the end of its log, $log:\n$(_logtail(log))"))
        return _dependencies(read(listing, String), folder)
    end
    files = build(String[])
    # latexmk takes a kept build as up to date when a file it used has moved to
    # another folder TeX searches, and lists the file where it was: such a
    # build is forced, once
    all(ispath, files) || (files = build(["-g"]))
    return (files = files, pdf = joinpath(outdir, "$stem.pdf"))
end

# The last lines of a log, to say why a command failed
function _logtail(path::AbstractString; lines::Integer = 20)
    isfile(path) || return ""
    all = readlines(path)
    return join(all[max(1, end - lines + 1):end], "\n")
end

# The files a `latexmk -deps-out` listing names, as absolute paths, a relative
# one taken from `folder`, where latexmk ran. It writes the target first, then
# one file to a line, a space in a name as it is, each line but the last
# ending in a backslash
function _dependencies(listing::AbstractString, folder::AbstractString)
    files = String[]
    within = false
    target = false
    for line in eachline(IOBuffer(listing))
        if startswith(line, "#===Dependents")
            within = true
            target = true
            continue
        end
        startswith(line, "#===End") && (within = false)
        (within && !startswith(line, "#")) || continue
        entry = lstrip(line)
        endswith(entry, "\\") && (entry = chop(entry))
        if target
            target = false
            continue
        end
        isempty(entry) && continue
        push!(files,
              normpath(isabspath(entry) ? entry : joinpath(folder, entry)))
    end
    return files
end

# The files a build used, sorted into those from the pipeline, in the folder
# `pipeline`; the repository's own, anywhere else in it, `top` being its top
# level; and those outside it, such as TeX's own, as `(pipeline, own,
# outside)`. Those in the repository are paths from its top level with `/`
# between folders, as git names them; those outside are as given
function _sortdependencies(files::AbstractVector{String}, top::AbstractString,
                           pipeline::AbstractString)
    top = _resolved(top)
    folder = _resolved(pipeline)
    sorted = (pipeline = String[], own = String[], outside = String[])
    for file in files
        path = _resolved(file)
        if _within(path, folder)
            push!(sorted.pipeline, _gitpath(path, top))
        elseif _within(path, top)
            push!(sorted.own, _gitpath(path, top))
        else
            push!(sorted.outside, file)
        end
    end
    return sorted
end

# A path with its links resolved where it exists, so that two spellings of one
# place compare equal, as `/tmp` and `/private/tmp` on macOS
_resolved(path::AbstractString) = ispath(path) ? realpath(path) : abspath(path)

# A path in a repository as git names it: from the top level, with `/`
function _gitpath(path::AbstractString, top::AbstractString)
    return replace(relpath(path, top),
                   '\\' => '/')
end

# Of `paths`, from the top level of the repository at `top`, those that are not
# as its checked-out commit has them - untracked, ignored, changed or only
# staged - with what git says of each
function _uncommitted(top::AbstractString, paths::AbstractVector{String})
    found = Pair{String, String}[]
    LibGit2.with(LibGit2.GitRepo(top)) do repo
        for path in paths
            status = LibGit2.status(repo, path)
            flags = isnothing(status) ? LibGit2.Consts.STATUS_WT_NEW : status
            flags == LibGit2.Consts.STATUS_CURRENT && continue
            push!(found, path => _gitstate(flags))
        end
    end
    return found
end

# What git's status flags for a file say of it
function _gitstate(flags::Integer)
    C = LibGit2.Consts
    flags & C.STATUS_IGNORED != 0 && return "ignored"
    flags & (C.STATUS_WT_NEW | C.STATUS_INDEX_NEW) != 0 &&
        return "not committed"
    return "changed since the commit"
end

# The source of a LaTeX document as TeX reads it: the file at `tex` with its
# comments taken out and each `\input` and `\include` replaced by the file it
# names, read in the same way, its path taken from the folder holding `tex` as
# TeX takes it there. A file that cannot be found is left named, for the build
# to report
function _latexsource(tex::AbstractString)
    tex = abspath(tex)
    return _expandinputs(_uncommented(read(tex, String)), dirname(tex), 0)
end

# A document's text with each `\input` and `\include` in it replaced by the
# file it names, to a depth that stops a file that inputs itself
function _expandinputs(text::AbstractString, folder::AbstractString,
                       depth::Integer)
    depth > 32 && return text
    command = r"\\(input|include)(?![A-Za-z@])\s*(?:\{([^{}]*)\}|([^\s{}\\]+))"
    return replace(text,
                   command => function (found)
                       parts = match(command, found)
                       name = strip(something(parts[2], parts[3]))
                       file = _inputfile(folder, name, parts[1] == "include")
                       isnothing(file) && return found
                       content = _uncommented(read(file, String))
                       return _expandinputs(content, folder, depth + 1)
                   end)
end

# The file an `\input` or `\include` of `name` reads, from `folder`: TeX tries
# the name with `.tex` added first, and `\include` only that; `nothing` where
# there is none
function _inputfile(folder::AbstractString, name::AbstractString,
                    include::Bool)
    candidates = include ? ["$name.tex"] : ["$name.tex", name]
    for candidate in candidates
        path = joinpath(folder, candidate)
        isfile(path) && return path
    end
    return nothing
end

# A document's text with its comments taken out: from a `%` that is not
# escaped to the end of its line, with the line break and the next line's
# leading spaces, as TeX takes them out
function _uncommented(text::AbstractString)
    return replace(text, r"(?<!\\)((?:\\\\)*)%[^\n]*(?:\n[ \t]*)?" => s"\1")
end

# What a document's front matter says: its title, its authors and each
# author's affiliations, from the source `_latexsource` gives, as `(title,
# authors, affiliations)`, the title `nothing` where there is none. A name that
# cannot be read with confidence is refused, with all such names at once
function _frontmatter(source::AbstractString)
    titles = _commands(source, "title")
    title = isempty(titles) ? nothing : _titletext(last(titles).argument)
    authors = String[]
    marks = Vector{Vector{String}}()
    positions = Int[]
    refused = String[]
    for found in _commands(source, "author")
        for piece in _authorpieces(found.argument)
            name = _authorname(piece)
            if name isa String
                push!(authors, name)
                push!(marks, _marks(found.option))
                push!(positions, found.position)
            else
                push!(refused, "\"$(_squashed(piece))\": $(name.reason)")
            end
        end
    end
    isempty(refused) ||
        throw(ReadWriteException("cannot read with confidence the author names " *
                                 join(refused, "; ") *
                                 " - give each author an \\author of their own, or separate them with \\and"))
    affiliations = _affiliations(source, marks, positions)
    return (title = title, authors = authors, affiliations = affiliations)
end

# Each use of the command `\name` in a source, in order: its position, its
# optional argument or `nothing`, and its argument, as `(position, option,
# argument)`; a use without a braced argument is passed over
function _commands(source::AbstractString, name::AbstractString)
    found = NamedTuple{(:position, :option, :argument),
                       Tuple{Int, Union{Nothing, String}, String}}[]
    pattern = Regex("\\\\" * name * "(?![A-Za-z@])\\*?")
    for start in findall(pattern, source)
        i = _skipspace(source, nextind(source, last(start)))
        option = nothing
        if i <= ncodeunits(source) && source[i] == '['
            closing = _closing(source, i, '[', ']')
            isnothing(closing) && continue
            option = source[nextind(source, i):prevind(source, closing)]
            i = _skipspace(source, nextind(source, closing))
        end
        (i <= ncodeunits(source) && source[i] == '{') || continue
        closing = _closing(source, i, '{', '}')
        isnothing(closing) && continue
        push!(found,
              (position = first(start), option = option,
               argument = source[nextind(source, i):prevind(source, closing)]))
    end
    return found
end

# The index of the first character from `i` that is not white space
function _skipspace(text::AbstractString, i::Integer)
    while i <= ncodeunits(text) && isspace(text[i])
        i = nextind(text, i)
    end
    return i
end

# The index of the bracket that closes the one at `i`, counting nested pairs
# and passing over escaped brackets, or `nothing` where it is not closed
function _closing(text::AbstractString, i::Integer, open::Char, close::Char)
    depth = 0
    escaped = false
    j = i
    while j <= ncodeunits(text)
        c = text[j]
        if escaped
            escaped = false
        elseif c == '\\'
            escaped = true
        elseif c == open
            depth += 1
        elseif c == close
            depth -= 1
            depth == 0 && return j
        end
        j = nextind(text, j)
    end
    return nothing
end

# The marks of an `authblk` author or affiliation, `\author[1,4]` giving
# `["1", "4"]`; none for a command without them
_marks(::Nothing) = String[]
function _marks(option::AbstractString)
    return [String(strip(mark))
            for mark in split(option, ',')
            if !isempty(strip(mark))]
end

# The names one `\author` holds: as many as `\and` separates, each up to its
# first line break, after which a plain `\author` gives an affiliation
function _authorpieces(argument::AbstractString)
    pieces = split(argument, r"\\(and|And|AND)(?![A-Za-z@])")
    return [first(split(piece, r"\\\\(\s*\[[^\]]*\])?"))
            for piece in pieces
            if !isempty(strip(piece))]
end

# What is attached to a name rather than part of it: notes, marks, contact
# details, superscripts and mathematics
const _NAME_ATTACHMENTS = r"\\(thanks|footnote|footnotemark|inst|orcidlink|orcid|email|textsuperscript)(?![A-Za-z@])\s*(\[[^\]]*\])?"

# An author's name from a piece of `\author`, as plain text, or why it cannot
# be read with confidence, as `(reason = ...)`: what is attached to the name is
# dropped, and what is left must be letters, spaces, hyphens, apostrophes and
# full stops
function _authorname(piece::AbstractString)
    text = _dropattached(piece)
    name = _latextext(text; strict = true)
    name isa String || return name
    isempty(name) && return (reason = "no name in it",)
    occursin(r"[0-9]", name) &&
        return (reason = "it holds a digit, perhaps a mark not given in \\author's brackets",)
    (occursin(',', name) || occursin(r"(^|\s)(and|&)(\s|$)", name)) &&
        return (reason = "it may be more than one name",)
    occursin(r"[^\p{L}\p{M} .'\-\x{2019}]", name) &&
        return (reason = "it holds characters that are not part of a name",)
    return name
end

# A title as plain text: the last `\title`'s, without the notes attached to it,
# its mathematics kept without its dollar signs
function _titletext(argument::AbstractString)
    text = _dropattached(argument; mathematics = false)
    return _latextext(replace(text, r"(?<!\\)\$" => ""))
end

# A piece of LaTeX with what is attached to a name dropped: each command of
# `_NAME_ATTACHMENTS` with its braced argument, and mathematics unless
# `mathematics` is false
function _dropattached(text::AbstractString; mathematics::Bool = true)
    result = IOBuffer()
    i = 1
    while i <= ncodeunits(text)
        found = findnext(_NAME_ATTACHMENTS, text, i)
        if isnothing(found)
            print(result, text[i:end])
            break
        end
        print(result, text[i:prevind(text, first(found))])
        j = _skipspace(text, nextind(text, last(found)))
        if j <= ncodeunits(text) && text[j] == '{'
            closing = _closing(text, j, '{', '}')
            j = isnothing(closing) ? ncodeunits(text) + 1 :
                nextind(text, closing)
        end
        i = j
    end
    without = String(take!(result))
    mathematics || return without
    without = replace(without, r"\$[^$]*\$" => " ")
    return replace(without, r"\^\{[^{}]*\}|\^\S" => " ")
end

# Each author's affiliations, in order, as their text: an author with marks
# takes the `\affil`s with those marks; one without takes the unmarked `\affil`s
# that follow it, which `authblk` gives every unmarked author since the
# `\affil`s before. A best guess, for a draft: affiliations are often missing or
# written otherwise. `marks` and `positions` are each author's marks and the
# position of the `\author` naming them
function _affiliations(source::AbstractString,
                       marks::Vector{Vector{String}}, positions::Vector{Int})
    affils = _commands(source, "affil")
    bymark = Dict{String, String}()
    for affil in affils, mark in _marks(affil.option)
        get!(bymark, mark, _latextext(affil.argument))
    end
    result = [[bymark[mark] for mark in own if haskey(bymark, mark)]
              for own in marks]
    # The unmarked authors waiting for their `\affil`s, and whether the last
    # command met was an `\affil`, after which the next author starts afresh
    waiting = Int[]
    after_affil = false
    events = sort(vcat([(position, :author, k)
                        for (k, position) in enumerate(positions)],
                       [(affil.position, :affil, k)
                        for (k, affil) in enumerate(affils)
                        if isnothing(affil.option)]))
    for (_, kind, k) in events
        if kind == :author
            after_affil && (empty!(waiting); after_affil = false)
            isempty(marks[k]) && push!(waiting, k)
        else
            text = _latextext(affils[k].argument)
            foreach(author -> push!(result[author], text), waiting)
            after_affil = true
        end
    end
    return result
end

# Text with its white space single, for a message
_squashed(text::AbstractString) = strip(replace(text, r"\s+" => " "))

# Commands that set a font or a size, which plain text drops
const _FONT_COMMANDS = r"\\(Huge|huge|LARGE|Large|large|normalsize|small|footnotesize|scriptsize|tiny|bfseries|itshape|mdseries|upshape|slshape|scshape|rmfamily|sffamily|ttfamily|normalfont|centering|raggedright|raggedleft|em|bf|it|rm|sf|tt|sc|sl|protect|noindent|par)(?![A-Za-z@])\s*"

# Commands whose argument is kept as it is, without them
const _KEPT_ARGUMENT = r"\\(textbf|textit|emph|textsc|textrm|textsf|texttt|textsl|textup|textmd|textnormal|mbox|text|hbox)(?![A-Za-z@])\s*"

# Accents written with a symbol, `\"o`, and their combining characters
const _SYMBOL_ACCENTS = Dict('"' => "\u0308", '\'' => "\u0301", '`' => "\u0300",
                             '^' => "\u0302", '~' => "\u0303", '=' => "\u0304",
                             '.' => "\u0307")

# Accents written with a letter, `\v{s}`, and their combining characters
const _LETTER_ACCENTS = Dict("u" => "\u0306", "v" => "\u030c", "H" => "\u030b",
                             "c" => "\u0327", "k" => "\u0328", "r" => "\u030a",
                             "d" => "\u0323", "b" => "\u0331", "t" => "\u0361")

# Letters written as a command, `\o`, as themselves, and the logos
const _LETTER_COMMANDS = Dict("o" => "\u00f8", "O" => "\u00d8", "l" => "\u0142",
                              "L" => "\u0141", "ss" => "\u00df",
                              "ae" => "\u00e6", "AE" => "\u00c6",
                              "oe" => "\u0153", "OE" => "\u0152",
                              "aa" => "\u00e5", "AA" => "\u00c5", "i" => "i",
                              "j" => "j", "dh" => "\u00f0", "DH" => "\u00d0",
                              "th" => "\u00fe", "TH" => "\u00de",
                              "ng" => "\u014b", "NG" => "\u014a",
                              "LaTeX" => "LaTeX", "TeX" => "TeX",
                              # Greek letters, for a title's mathematics
                              "alpha" => "\u03b1", "beta" => "\u03b2",
                              "gamma" => "\u03b3", "delta" => "\u03b4",
                              "epsilon" => "\u03f5", "varepsilon" => "\u03b5",
                              "zeta" => "\u03b6", "eta" => "\u03b7",
                              "theta" => "\u03b8", "vartheta" => "\u03d1",
                              "iota" => "\u03b9", "kappa" => "\u03ba",
                              "lambda" => "\u03bb", "mu" => "\u03bc",
                              "nu" => "\u03bd", "xi" => "\u03be",
                              "pi" => "\u03c0", "rho" => "\u03c1",
                              "sigma" => "\u03c3", "tau" => "\u03c4",
                              "upsilon" => "\u03c5", "phi" => "\u03d5",
                              "varphi" => "\u03c6", "chi" => "\u03c7",
                              "psi" => "\u03c8", "omega" => "\u03c9",
                              "Gamma" => "\u0393", "Delta" => "\u0394",
                              "Theta" => "\u0398", "Lambda" => "\u039b",
                              "Xi" => "\u039e", "Pi" => "\u03a0",
                              "Sigma" => "\u03a3", "Upsilon" => "\u03a5",
                              "Phi" => "\u03a6", "Psi" => "\u03a8",
                              "Omega" => "\u03a9")

# A piece of LaTeX as plain text: fonts and sizes dropped, the arguments of
# commands that only style them kept, accents and letters written as commands
# turned into the characters they stand for, braces taken out and white space
# made single. Any other command is dropped, or, where `strict` is true, is
# the reason given, as `(reason = ...)`, that the text cannot be read
function _latextext(text::AbstractString; strict::Bool = false)
    text = replace(text, _FONT_COMMANDS => "")
    text = replace(text, _KEPT_ARGUMENT => "")
    text = replace(text, r"\\[,;:! ]" => " ", "~" => " ", "\\\\" => " ")
    text = replace(text, "---" => "\u2014", "--" => "\u2013", "``" => "\"",
                   "''" => "\"")
    for (escaped, plain) in ("\\&" => "&", "\\%" => "%", "\\\$" => "\$",
        "\\_" => "_", "\\#" => "#")
        text = replace(text, escaped => plain)
    end
    result = IOBuffer()
    unknown = String[]
    i = 1
    while i <= ncodeunits(text)
        c = text[i]
        if c != '\\'
            c in ('{', '}') || print(result, c)
            i = nextind(text, i)
            continue
        end
        j = nextind(text, i)
        j > ncodeunits(text) && break
        d = text[j]
        if haskey(_SYMBOL_ACCENTS, d)
            base, i = _accented(text, nextind(text, j))
            print(result, base, _SYMBOL_ACCENTS[d])
            continue
        end
        if d in ('{', '}')
            print(result, d)
            i = nextind(text, j)
            continue
        end
        name_end = j
        while name_end <= ncodeunits(text) && isletter(text[name_end])
            name_end = nextind(text, name_end)
        end
        name = text[j:prevind(text, name_end)]
        if isempty(name)
            i = nextind(text, j)
        elseif haskey(_LETTER_ACCENTS, name)
            base, i = _accented(text, name_end)
            print(result, base, _LETTER_ACCENTS[name])
        elseif haskey(_LETTER_COMMANDS, name)
            print(result, _LETTER_COMMANDS[name])
            i = name_end
            # A space after a command ends it and is not printed
            i <= ncodeunits(text) && text[i] == ' ' && (i = nextind(text, i))
        else
            push!(unknown, "\\" * name)
            i = name_end
        end
    end
    strict && !isempty(unknown) &&
        return (reason = "it uses $(join(unique(unknown), ", ")), which is not part of a name",)
    plain = strip(replace(String(take!(result)), r"\s+" => " "))
    return Base.Unicode.normalize(String(plain), :NFC)
end

# The letter an accent command sets its accent on, from `i`: a braced letter,
# a letter after spaces, or a letter command such as `\i`; and the index after
# it
function _accented(text::AbstractString, i::Integer)
    i = _skipspace(text, i)
    i > ncodeunits(text) && return ("", i)
    if text[i] == '{'
        closing = _closing(text, i, '{', '}')
        isnothing(closing) && return ("", nextind(text, i))
        inner = text[nextind(text, i):prevind(text, closing)]
        return (_latextext(inner), nextind(text, closing))
    end
    if text[i] == '\\'
        j = nextind(text, i)
        name_end = j
        while name_end <= ncodeunits(text) && isletter(text[name_end])
            name_end = nextind(text, name_end)
        end
        name = text[j:prevind(text, name_end)]
        return (get(_LETTER_COMMANDS, name, ""), name_end)
    end
    return (string(text[i]), nextind(text, i))
end
