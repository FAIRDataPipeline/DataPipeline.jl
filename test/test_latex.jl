# SPDX-License-Identifier: LGPL-3.0-or-later

module TestLaTeX

using DataPipeline
using Test

const LibGit2 = DataPipeline.LibGit2
const ReadWriteException = DataPipeline.ReadWriteException

# A folder holding `files`, a name to its text, its folders made
function folder_of(files::AbstractDict)
    dir = mktempdir()
    for (name, text) in files
        mkpath(dirname(joinpath(dir, name)))
        write(joinpath(dir, name), text)
    end
    return dir
end

# The front matter of a document with this source and these other files
function front(source::AbstractString,
               files::AbstractDict = Dict{String, String}())
    dir = folder_of(merge(Dict("paper.tex" => source), files))
    return DataPipeline._frontmatter(DataPipeline._latexsource(joinpath(dir,
                                                                        "paper.tex")))
end

# The message of the exception of this type that a call throws
function message_of(call::Function, type::Type{<:Exception})
    try
        call()
    catch e
        e isa type || rethrow()
        return e.msg
    end
    return error("nothing was thrown")
end

# A tiny valid PNG, a white pixel, for a figure
const PNG = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
                  0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
                  0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
                  0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41,
                  0x54, 0x78, 0x9c, 0x63, 0xf8, 0xff, 0xff, 0x3f, 0x00, 0x05,
                  0xfe, 0x02, 0xfe, 0xa7, 0x35, 0x81, 0x84, 0x00, 0x00, 0x00,
                  0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]

@testset "LaTeX papers" begin
    @testset "plain text from LaTeX" begin
        text = DataPipeline._latextext
        # Accents, braced or not, on a letter or on a dotless i, and letters
        # written as commands, as the characters they stand for, composed
        @test text("M{\\\"u}ller") == "M\u00fcller"
        @test text("M\\\"uller") == "M\u00fcller"
        @test text("Garc\\'{\\i}a L\\'opez") == "Garc\u00eda L\u00f3pez"
        @test text("J{\\o}rgen \\v{S}koda Stra\\ss e") ==
              "J\u00f8rgen \u0160koda Stra\u00dfe"
        @test text("\\c{C}a\\u{g}lar") == "\u00c7a\u011flar"
        # Fonts and sizes dropped, styling kept, escapes, ties and braces
        @test text("\\Huge\\bfseries A \\emph{new} {Model}: 10\\% \\& more~here") ==
              "A new Model: 10% & more here"
        @test text("Long---and--short ``quoted''") ==
              "Long\u2014and\u2013short \"quoted\""
        @test text("\\alpha-diversity in \\LaTeX") ==
              "\u03b1-diversity in LaTeX"
        # Any other command is dropped, or, strictly, the reason
        @test text("A \\unknown B") == "A B"
        @test text("A \\unknown B"; strict = true).reason ==
              "it uses \\unknown, which is not part of a name"
    end

    @testset "comments and inputs" begin
        uncommented = DataPipeline._uncommented
        @test uncommented("a % note\n  b") == "a b"
        @test uncommented("10\\% off % note\nb") == "10\\% off b"
        @test uncommented("line\\\\% note\nnext") == "line\\\\next"

        # The front matter in a file of its own, with a section included,
        # found from the main file's folder; a commented-out author is not
        # one, and an input that cannot be found is left named
        found = front("""
                      \\documentclass{article}
                      \\input{front}
                      % \\author{Not An Author}
                      \\begin{document}
                      \\include{sections/one}
                      \\input missing
                      \\end{document}
                      """,
                      Dict("front.tex" => "\\title{From a file}\n\\author{Ada Person}\n",
                           "sections/one.tex" => "\\author{Bob Second}\n"))
        @test found.title == "From a file"
        @test found.authors == ["Ada Person", "Bob Second"]
        dir = folder_of(Dict("paper.tex" => "\\input{missing}\n\\input{self}\n",
                             "self.tex" => "\\input{self}\n"))
        source = DataPipeline._latexsource(joinpath(dir, "paper.tex"))
        @test occursin("\\input{missing}", source)
    end

    @testset "title, authors and affiliations" begin
        # As the EcoSISTEM paper writes them: authblk, marks, a footnote over
        # two lines in the last author, and a title with fonts set in it
        paper = front("""
                      \\title{\\Huge\\bfseries EcoSISTEM: a model\\thanks{Funded.}}
                      \\author[1,4]{Morag Fairlie}
                      \\author[2]{Ines A. Valcourt}
                      \\author[1]{Tobias Quennell\\footnote[1]{
                      Corresponding author: someone@example.com}}
                      \\affil[1]{Example University, Northhaven}
                      \\affil[2]{Museum of Imaginary Things, Southby}
                      \\affil[4]{Centre for Invented Studies}
                      """)
        @test paper.title == "EcoSISTEM: a model"
        @test paper.authors == ["Morag Fairlie", "Ines A. Valcourt",
            "Tobias Quennell"]
        @test paper.affiliations ==
              [
            ["Example University, Northhaven", "Centre for Invented Studies"],
            ["Museum of Imaginary Things, Southby"],
            ["Example University, Northhaven"]]

        # The last title is the one LaTeX sets
        @test front("\\title{First}\n\\title{Second}\n").title == "Second"
        @test isnothing(front("\\author{Ada Person}\n").title)

        # One \author for several, separated by \and, notes dropped, and each
        # name up to its line break, after which comes an affiliation
        plain = front("\\author{Ada Person\\thanks{Funded.} \\\\ Somewhere \\and Bob O'Second\$^{2}\$ \\AND Ca\\\"el Third}")
        @test plain.authors == ["Ada Person", "Bob O'Second", "Ca\u00ebl Third"]
        @test plain.affiliations == [String[], String[], String[]]

        # authblk without marks: an \affil goes to every author since the
        # \affils before it
        unmarked = front("""
                         \\author{Ada Person}
                         \\affil{First Place}
                         \\author{Bob Second}
                         \\author{Cy Third}
                         \\affil{Second Place}
                         \\affil{Third Place}
                         """)
        @test unmarked.affiliations ==
              [["First Place"], ["Second Place", "Third Place"],
            ["Second Place", "Third Place"]]

        # Names that cannot be read with confidence are refused, all at once
        msg = message_of(ReadWriteException) do
            return front("""
                         \\author{Ada Person, Bob Second and Cy Third}
                         \\author{Morag Fairlie1}
                         \\author{\\myname}
                         \\author{Dee Fourth}
                         """)
        end
        @test occursin("\"Ada Person, Bob Second and Cy Third\": it may be more than one name",
                       msg)
        @test occursin("\"Morag Fairlie1\": it holds a digit", msg)
        @test occursin("\"\\myname\": it uses \\myname", msg)
        @test !occursin("Dee Fourth", msg)
        @test occursin("\\and", msg)
    end

    @testset "the files a build uses" begin
        # A listing as latexmk writes it: the target, then one file to a
        # line, a space in a name as it is, relative to where it ran
        listing = """
                  #===Dependents, and related info, for paper.tex:
                  build/paper.pdf :\\
                      /usr/local/texlive/2026/texmf-dist/tex/latex/base/article.cls\\
                      pipeline/a figure.png\\
                      paper.tex
                  #===End dependents for paper.tex:
                  """
        files = DataPipeline._dependencies(listing, "/work")
        @test files == [
            normpath("/usr/local/texlive/2026/texmf-dist/tex/latex/base/article.cls"),
            normpath("/work/pipeline/a figure.png"), normpath("/work/paper.tex")
        ]

        # Sorted by where they come from: the pipeline folder, the rest of
        # the repository, and outside it, named as git names them
        top = folder_of(Dict("paper/paper.tex" => "",
                             "paper/pipeline/fig.png" => "",
                             "paper/include/d.png" => "", "notes.tex" => ""))
        sorted = DataPipeline._sortdependencies([
                                                    joinpath(top, "paper",
                                                             "paper.tex"),
                                                    joinpath(top, "paper",
                                                             "pipeline",
                                                             "fig.png"),
                                                    joinpath(top, "paper",
                                                             "include",
                                                             "d.png"),
                                                    joinpath(top, "notes.tex"),
                                                    "/usr/share/outside.sty"],
                                                top,
                                                joinpath(top, "paper",
                                                         "pipeline"))
        @test sorted.pipeline == ["paper/pipeline/fig.png"]
        @test sorted.own ==
              ["paper/paper.tex", "paper/include/d.png", "notes.tex"]
        @test sorted.outside == ["/usr/share/outside.sty"]

        # Of the repository's own files, those not as its commit has them
        repo = LibGit2.init(top)
        write(joinpath(top, ".gitignore"), "ignored.tex\n")
        for name in (".gitignore", "paper/paper.tex", "notes.tex")
            LibGit2.add!(repo, name)
        end
        signature = LibGit2.Signature("Test", "test@example.com",
                                      1_000_000_000, 0)
        LibGit2.commit(repo, "paper", author = signature,
                       committer = signature)
        write(joinpath(top, "notes.tex"), "changed")
        write(joinpath(top, "ignored.tex"), "")
        @test DataPipeline._uncommitted(top,
                                        ["paper/paper.tex", "notes.tex",
                                            "paper/include/d.png",
                                            "ignored.tex"]) ==
              ["notes.tex" => "changed since the commit",
            "paper/include/d.png" => "not committed",
            "ignored.tex" => "ignored"]
        close(repo)
    end

    # The engine is the flag latexmk is given
    @test DataPipeline._latexmkflag(DataPipeline.PdfLaTeXEngine()) == "-pdf"
    @test DataPipeline._latexmkflag(DataPipeline.LuaLaTeXEngine()) == "-pdflua"
    @test DataPipeline._latexmkflag(DataPipeline.XeLaTeXEngine()) == "-pdfxe"

    # Building needs latexmk and pdfLaTeX, so is not tried where they are not
    if isnothing(Sys.which("latexmk")) || isnothing(Sys.which("pdflatex"))
        @info "latexmk or pdflatex not found: not building a LaTeX paper"
    else
        @testset "building with latexmk" begin
            dir = folder_of(Dict("paper.tex" => """
                                 \\documentclass{article}
                                 \\usepackage{graphicx}
                                 \\graphicspath{{pipeline/}}
                                 \\input{front}
                                 \\begin{document}
                                 \\maketitle
                                 \\include{sections/methods}
                                 \\end{document}
                                 """,
                                 "front.tex" => "\\title{A test}\n\\author{Ada Person}\n",
                                 "sections/methods.tex" => "Text.\n\\includegraphics[width=1cm]{dot}\n"))
            mkpath(joinpath(dir, "pipeline"))
            write(joinpath(dir, "pipeline", "dot.png"), PNG)
            outdir = mktempdir()
            built = DataPipeline._latexmk(joinpath(dir, "paper.tex"), outdir,
                                          DataPipeline.PdfLaTeXEngine())
            @test built.pdf == joinpath(outdir, "paper.pdf")
            @test isfile(built.pdf)
            # Every file of the paper's own is listed, the figure in an
            # included file too, with TeX's own files
            mine = [relpath(DataPipeline._resolved(file), realpath(dir))
                    for file in built.files
                    if DataPipeline._within(DataPipeline._resolved(file),
                                            realpath(dir))]
            @test Set(mine) ==
                  Set(["paper.tex", "front.tex",
                          joinpath("sections", "methods.tex"),
                          joinpath("pipeline", "dot.png")])
            @test length(built.files) > length(mine)

            # A document that does not build is an error giving the log's end
            write(joinpath(dir, "broken.tex"),
                  "\\documentclass{article}\n\\begin{document}\n\\undefinedcommand\n\\end{document}\n")
            msg = message_of(ReadWriteException) do
                return DataPipeline._latexmk(joinpath(dir, "broken.tex"),
                                             outdir,
                                             DataPipeline.PdfLaTeXEngine())
            end
            @test occursin("could not build", msg)
            @test occursin("broken.latexmk.log", msg)

            # A figure moved to another folder TeX searches leaves a kept
            # build up to date in latexmk's eyes, its listing naming the old
            # place: the build is forced, and lists the new
            moving = folder_of(Dict("moving.tex" => """
                                    \\documentclass{article}
                                    \\usepackage{graphicx}
                                    \\graphicspath{{pipeline/}{include/}}
                                    \\begin{document}
                                    \\includegraphics[width=1cm]{dot}
                                    \\end{document}
                                    """))
            mkpath(joinpath(moving, "pipeline"))
            mkpath(joinpath(moving, "include"))
            write(joinpath(moving, "pipeline", "dot.png"), PNG)
            kept = mktempdir()
            # The folder each listed copy of the figure is in
            placed(built) = [basename(dirname(file))
                             for file in built.files
                             if basename(file) == "dot.png"]
            first = DataPipeline._latexmk(joinpath(moving, "moving.tex"), kept,
                                          DataPipeline.PdfLaTeXEngine())
            @test placed(first) == ["pipeline"]
            mv(joinpath(moving, "pipeline", "dot.png"),
               joinpath(moving, "include", "dot.png"))
            moved = DataPipeline._latexmk(joinpath(moving, "moving.tex"), kept,
                                          DataPipeline.PdfLaTeXEngine())
            @test placed(moved) == ["include"]
            @test all(ispath, moved.files)
        end
    end
end

end
