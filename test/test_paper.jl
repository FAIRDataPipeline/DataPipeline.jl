# SPDX-License-Identifier: LGPL-3.0-or-later

module TestPaper

using DataPipeline
using Dates
using Test

const LibGit2 = DataPipeline.LibGit2
const URIs = DataPipeline.URIs
const ReadWriteException = DataPipeline.ReadWriteException

uid = DataPipeline._randomhash()
datetime = Dates.format(Dates.now(), "yyyymmdd-HHMMSS")
cpath(name) = joinpath("coderun", datetime, "paper-$name", "config.yaml")
config = DataPipeline._createconfig(cpath("launch"))
launch = DataPipeline.initialise(config, config)
registry = launch.registry
namespace = launch.config["run_metadata"]["default_output_namespace"]

# A tiny valid PNG, a white pixel, for a figure
const PNG = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
                  0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
                  0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
                  0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41,
                  0x54, 0x78, 0x9c, 0x63, 0xf8, 0xff, 0xff, 0x3f, 0x00, 0x05,
                  0xfe, 0x02, 0xfe, 0xa7, 0x35, 0x81, 0x84, 0x00, 0x00, 0x00,
                  0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]

# A paper's metadata as `_papermetadata` gives it
function metadata(; authors = ["Morag Fairlie", "Tobias Quennell"],
                  identifiers = Dict("Morag Fairlie" => "https://orcid.org/0000-0002-1825-0097"),
                  licence = "CC-BY-4.0", keywords = ["invented"],
                  title = "A made-up paper")
    return DataPipeline.RepositoryMetadata(authors, identifiers, licence,
                                           keywords, nothing, nothing, title,
                                           ["CITATION.cff"])
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

# Whether latexmk and an engine's program are there to build with
function can_build(program)
    return !isnothing(Sys.which("latexmk")) &&
           !isnothing(Sys.which(program))
end

@testset "building a paper" begin
    @testset "a LaTeX paper" begin
        dir = mktempdir()
        mkpath(joinpath(dir, "paper"))
        tex = joinpath(dir, "paper", "article.tex")
        write(tex, "")
        # Named by the .tex file's stem, beside it, the pipeline folder too
        paper = DataPipeline.LaTeXPaper(tex)
        @test paper.pipeline == joinpath(dir, "paper", "pipeline")
        @test paper.template == joinpath(dir, "paper", "article.template.yaml")
        @test paper.config == joinpath(dir, "paper", "article.yaml")
        @test paper.engine == DataPipeline.PdfLaTeXEngine()
        other = DataPipeline.LaTeXPaper(tex, pipeline = "../generated",
                                        engine = DataPipeline.LuaLaTeXEngine())
        @test other.pipeline == joinpath(dir, "generated")
        @test other isa DataPipeline.LaTeXPaper{DataPipeline.LuaLaTeXEngine}
        @test occursin("article.tex", sprint(show, paper))
        @test occursin("files from the pipeline in $(paper.pipeline)",
                       sprint(show, MIME("text/plain"), paper))
        @test_throws ArgumentError DataPipeline.LaTeXPaper(joinpath(dir,
                                                                    "absent.tex"))
    end

    @testset "the PDF's document information" begin
        # What the PDF is to hold: the standard fields, then the licence and
        # the identifiers as fields of their own
        info = DataPipeline._documentinfo(metadata())
        @test info == ["Title" => "A made-up paper",
            "Author" => "Morag Fairlie; Tobias Quennell",
            "Keywords" => "invented", "License" => "CC-BY-4.0",
            "AuthorIdentifiers" => "Morag Fairlie: https://orcid.org/0000-0002-1825-0097"
        ]
        @test DataPipeline._documentinfo(metadata(identifiers = Dict{String,
                                                                     String}(),
                                                  licence = nothing,
                                                  keywords = String[])) ==
              ["Title" => "A made-up paper",
            "Author" => "Morag Fairlie; Tobias Quennell"]

        # The TeX: to hyperref as escaped TeX text, otherwise directly, in
        # UTF-16 hexadecimal
        tex = DataPipeline._metadatatex(["Title" => "50% & {more}",
                                            "License" => "MIT"])
        @test occursin("\\AddToHook{begindocument/end}", tex)
        @test occursin("\\hypersetup{pdftitle={50\\% \\& \\{more\\}},pdfinfo={License={MIT}}}",
                       tex)
        @test occursin("\\pdfinfo{/Title <FEFF003500300025002000260020007B006D006F00720065007D> /License <FEFF004D00490054>}",
                       tex)
        @test DataPipeline._pdfhexstring("\u00eb") == "<FEFF00EB>"

        # Read back from the Info dictionary the trailer names, whichever way
        # its strings are written, a longer object number ending in its own
        # passed over
        pdf = Vector{UInt8}("""%PDF-1.5
                            112 0 obj
                            << /Title (Not this one) >>
                            endobj
                            12 0 obj
                            << /Title (A \\(nested\\) title\\041) /Author (\\376\\377\\000Z\\000o\\000\\353)
                            /Keywords <FEFF006B00650079> /Count 3 /Producer (pdfTeX) >>
                            endobj
                            trailer << /Size 13 /Info 12 0 R >>
                            %%EOF
                            """)
        @test DataPipeline._pdfdocumentinfo(pdf) ==
              Dict("Title" => "A (nested) title!", "Author" => "Zo\u00eb",
                   "Keywords" => "key", "Producer" => "pdfTeX")
        @test isnothing(DataPipeline._pdfdocumentinfo(Vector{UInt8}("%PDF-1.5\n")))
    end

    @testset "every engine, with hyperref and without" begin
        dir = mktempdir()
        write(joinpath(dir, "plain.tex"),
              "\\documentclass{article}\n\\title{T}\\author{A}\n\\begin{document}\\maketitle Text.\\end{document}\n")
        write(joinpath(dir, "hyper.tex"),
              "\\documentclass{article}\n\\usepackage{hyperref}\n\\hypersetup{pdfauthor={Someone Else},pdfkeywords={theirs}}\n\\title{T}\\author{A}\n\\begin{document}\\maketitle Text.\\end{document}\n")
        meta = metadata(authors = ["Zo\u00eb Fairlie", "Bo & Co_Ltd"],
                        identifiers = Dict("Zo\u00eb Fairlie" => "https://orcid.org/0000-0002-1825-0097"),
                        keywords = ["biodiversit\u00e9", "50% {braces}"],
                        title = "A \$5 title #1")
        engines = ((DataPipeline.PdfLaTeXEngine(), "pdflatex"),
                   (DataPipeline.LuaLaTeXEngine(), "lualatex"),
                   (DataPipeline.XeLaTeXEngine(), "xelatex"))
        for (engine, program) in engines, document in ("plain", "hyper")
            if !can_build(program)
                @info "$program not found: not building with it"
                continue
            end
            out = mktempdir()
            DataPipeline._writemetadatatex(out, meta)
            built = DataPipeline._latexmk(joinpath(dir, "$document.tex"), out,
                                          engine,
                                          options = ["-usepretex=\\input{$(DataPipeline.METADATA_TEX)}"],
                                          texinputs = out)
            # Every field as registered, over the paper's own; XeLaTeX
            # compresses them, so they are not read back
            found = DataPipeline._pdfdocumentinfo(read(built.pdf))
            if engine isa DataPipeline.XeLaTeXEngine
                @test isnothing(DataPipeline._checkdocumentinfo(DataPipeline.RecordedRun(),
                                                                engine,
                                                                built.pdf,
                                                                meta))
            else
                @test all(get(found, key, nothing) == value
                          for (key, value) in DataPipeline._documentinfo(meta))
            end
        end
    end

    if !can_build("pdflatex")
        @info "latexmk or pdflatex not found: not building a paper in a run"
    else
        @testset "building in a code run" begin
            # A paper's repository: its LaTeX, a figure and a table from the
            # pipeline, a drawing of its own, and its CITATION.cff
            top = mktempdir()
            files = Dict("paper.tex" => """
                         \\documentclass{article}
                         \\usepackage{graphicx}
                         \\graphicspath{{pipeline/}{drawings/}}
                         \\title{A made-up paper}
                         \\author{Morag Fairlie \\and Tobias Quennell}
                         \\begin{document}
                         \\maketitle
                         \\input{pipeline/table}
                         \\includegraphics[width=1cm]{figure}
                         \\includegraphics[width=1cm]{sketch}
                         \\end{document}
                         """,
                         "pipeline/table.tex" => "A table made in run $uid.\n",
                         "CITATION.cff" => """
                         cff-version: 1.2.0
                         message: "Please cite this paper."
                         title: "A made-up paper"
                         license: CC-BY-4.0
                         keywords:
                           - invented-$uid
                         authors:
                           - family-names: Fairlie
                             given-names: Morag
                             orcid: "https://orcid.org/0000-0002-1825-0097"
                           - family-names: Quennell
                             given-names: Tobias
                         """)
            for (name, text) in files
                mkpath(dirname(joinpath(top, name)))
                write(joinpath(top, name), text)
            end
            mkpath(joinpath(top, "drawings"))
            write(joinpath(top, "pipeline", "figure.png"), PNG)
            write(joinpath(top, "drawings", "sketch.png"), PNG)
            repo = LibGit2.init(top)
            signature = LibGit2.Signature("Test", "test@example.com",
                                          1_000_000_000, 0)
            # Commit everything there is, and return the commit's hash
            function commit!(message)
                LibGit2.add!(repo, ".")
                return string(LibGit2.commit(repo, message,
                                             author = signature,
                                             committer = signature))
            end
            sha = commit!("paper $uid")

            # The table and the figure registered by a run of their own
            inputs = "paper-inputs/$uid"
            config = DataPipeline._createconfig(cpath("inputs"))
            DataPipeline._addwrite(config, "$inputs/table", "a table",
                                   file_type = "tex", use_version = "0.0.1")
            DataPipeline._addwrite(config, "$inputs/figure", "a figure",
                                   file_type = "png", use_version = "0.0.1")
            making = DataPipeline.initialise(config, config)
            link_write!(making, "$inputs/table",
                        path = joinpath(top, "pipeline", "table.tex"))
            link_write!(making, "$inputs/figure",
                        path = joinpath(top, "pipeline", "figure.png"))
            DataPipeline.finalise(making)

            # A run of the paper's repository at a commit, offering the two
            # and writing the paper at a version
            pdf = "papers/$uid"
            function offering(name, commit, version)
                config = DataPipeline._createconfig(cpath(name),
                                                    local_repo = top,
                                                    latest_commit = commit,
                                                    remote_repo = "https://example.org/papers/$uid.git")
                for part in ("table", "figure")
                    DataPipeline._addread(config, part,
                                          use_data_product = "$inputs/$part",
                                          use_version = "0.0.1")
                end
                DataPipeline._addwrite(config, "paper", "the paper",
                                       file_type = "pdf",
                                       use_data_product = pdf,
                                       use_version = version)
                return config
            end
            run_of(handle) = DataPipeline._getentry(registry,
                                                    URIs.URI(handle.code_run_obj))
            versions() = sort([entry["version"]
                               for entry in DataPipeline._getentries(registry,
                                                                     "data_product",
                                                                     Dict("name" =>
                                                                              pdf))])

            # Built: the table and the figure its inputs, not the drawing,
            # and the PDF its output, with the paper's authors, licence and
            # keywords, which the PDF holds too
            config = offering("built", sha, "0.0.1")
            handle = DataPipeline.initialise(config, config)
            path = build_paper!(handle, joinpath(top, "paper.tex"))
            @test isfile(path)
            @test sort(collect(keys(handle.inputs))) ==
                  [("figure", nothing), ("table", nothing)]
            DataPipeline.finalise(handle)
            run = run_of(handle)
            @test length(run["inputs"]) == 2
            @test run["outputs"] ==
                  [handle.outputs[("paper", nothing)]["component_url"]]
            product = DataPipeline._finddataproduct(registry, namespace, pdf,
                                                    "0.0.1")
            object = DataPipeline._getentry(registry,
                                            URIs.URI(product["object"]))
            orcid = DataPipeline._geturl(registry, "author",
                                         Dict("identifier" => "https://orcid.org/0000-0002-1825-0097"))
            names = [DataPipeline._getentry(registry, URIs.URI(url))["name"]
                     for url in object["authors"]]
            @test orcid in object["authors"] && "Tobias Quennell" in names &&
                  length(names) == 2
            @test [DataPipeline._getentry(registry, URIs.URI(url))["identifier"]
                   for url in object["licences"]] ==
                  ["https://spdx.org/licenses/CC-BY-4.0"]
            @test [entry["keyphrase"]
                   for entry in DataPipeline._getentries(registry, "keyword",
                                                         Dict("object" =>
                                                                  DataPipeline._extractid(product["object"])))] ==
                  ["invented-$uid"]
            stored = handle.outputs[("paper", nothing)]["path"]
            info = DataPipeline._pdfdocumentinfo(read(stored))
            @test info["Author"] == "Morag Fairlie; Tobias Quennell"
            @test info["Keywords"] == "invented-$uid"

            # Built again, unchanged: the same bytes, authors and licence, so
            # nothing registered
            config = offering("again", sha, "0.0.2")
            handle = DataPipeline.initialise(config, config)
            build_paper!(handle, joinpath(top, "paper.tex"))
            @test haskey(handle.unchanged, ("paper", nothing))
            DataPipeline.finalise(handle)
            @test versions() == ["0.0.1"]

            # What is refused, before anything is registered
            refused(name, commit, version = "0.0.3") = begin
                config = offering(name, commit, version)
                handle = DataPipeline.initialise(config, config)
                msg = message_of(ReadWriteException) do
                    return build_paper!(handle, joinpath(top, "paper.tex"))
                end
                @test isempty(handle.outputs) && isempty(handle.unchanged)
                @test versions() == ["0.0.1"]
                DataPipeline._resetsession!()
                msg
            end
            # ... a file it uses that is not as the commit has it, and a
            # metadata file either
            write(joinpath(top, "paper.tex"),
                  files["paper.tex"] * "% an edit\n")
            @test occursin("paper.tex (changed since the commit)",
                           refused("edited", sha))
            write(joinpath(top, "paper.tex"), files["paper.tex"])
            write(joinpath(top, "CITATION.cff"),
                  replace(files["CITATION.cff"], "invented-$uid" => "other"))
            @test occursin("CITATION.cff (changed since the commit)",
                           refused("metadata", sha))
            write(joinpath(top, "CITATION.cff"), files["CITATION.cff"])
            # ... authors in the LaTeX in another order from its metadata's
            write(joinpath(top, "paper.tex"),
                  replace(files["paper.tex"],
                          "Morag Fairlie \\and Tobias Quennell" => "Tobias Quennell \\and Morag Fairlie"))
            @test occursin("the authors are in another order",
                           refused("reordered", commit!("reordered")))
            # ... a checkout at another commit than the run's
            @test occursin("not the run's commit", refused("elsewhere", sha))
            # ... a file from the pipeline that no read entry offers
            write(joinpath(top, "pipeline", "extra.tex"),
                  "Not registered $uid.\n")
            write(joinpath(top, "paper.tex"),
                  replace(files["paper.tex"],
                          "\\input{pipeline/table}" => "\\input{pipeline/table}\\input{pipeline/extra}"))
            @test occursin("pipeline/extra.tex",
                           refused("unoffered", commit!("unoffered")))
            # ... document information the paper sets itself later
            write(joinpath(top, "paper.tex"),
                  replace(files["paper.tex"],
                          "\\begin{document}" => "\\AtEndDocument{\\pdfinfo{/Title (Something else)}}\n\\begin{document}"))
            @test occursin("Title is \"Something else\"",
                           refused("overridden", commit!("overridden")))

            # The registered PDF is a copy, which the builds since, writing
            # theirs in place, have left as it was
            @test DataPipeline._getfilehash(stored) ==
                  DataPipeline._getstoragelocation(registry,
                                                   product["object"]).hash

            # A rehearsal says what a recorded run would refuse, and
            # registers nothing
            write(joinpath(top, "paper.tex"), files["paper.tex"])
            clean = commit!("restored")
            write(joinpath(top, "paper.tex"),
                  files["paper.tex"] * "% an edit\n")
            job = dirname(offering("rehearsed", clean, "0.0.3"))
            outputs = mktempdir()
            DataPipeline.rehearse(job, outputs = outputs)
            rehearsal = DataPipeline.initialise()
            @test_logs((:warn,
                        r"^a recorded run would stop here: files the paper uses are not as the run's commit has them: paper\.tex"),
                       match_mode=:any,
                       build_paper!(rehearsal, joinpath(top, "paper.tex")))
            DataPipeline.finalise(rehearsal)
            @test isfile(joinpath(outputs, namespace, pdf, "0.0.3.pdf"))
            @test versions() == ["0.0.1"]
            close(repo)
        end
    end
end

end
