# SPDX-License-Identifier: LGPL-3.0-or-later

module TestPaper

using DataPipeline
using Dates
using Test

const LibGit2 = DataPipeline.LibGit2
const URIs = DataPipeline.URIs
const YAML = DataPipeline.YAML
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
                  0xfe, 0x02, 0xfe, 0x0d, 0xef, 0x46, 0xb8, 0x00, 0x00, 0x00,
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

    @testset "a paper's template and config" begin
        top = mktempdir()
        mkpath(joinpath(top, "paper"))
        tex = joinpath(top, "paper", "article.tex")
        write(tex, "\\documentclass{article}\n")
        repo = LibGit2.init(top)
        close(LibGit2.GitRemote(repo, "origin",
                                "git@github.com:example/My-Study.git"))
        paper = DataPipeline.LaTeXPaper(tex)
        front = (title = "An invented study", authors = ["Ines A. Valcourt"],
                 affiliations = [String[]])

        # The PDF named by the repository and the paper, and the paper by its
        # path unless it is built otherwise than by default
        @test DataPipeline._paperdataproduct(paper, top) == "My-Study/article"
        @test DataPipeline._paperargument(paper, top) == "\"paper/article.tex\""
        other = DataPipeline.LaTeXPaper(tex, pipeline = "figures",
                                        engine = DataPipeline.LuaLaTeXEngine())
        @test DataPipeline._paperargument(other, top) ==
              "DataPipeline.LaTeXPaper(\"paper/article.tex\", pipeline = \"figures\", engine = DataPipeline.LuaLaTeXEngine())"

        # The template: a Julia script building the paper in the pipeline
        # folder's environment, or else a temporary one, and the PDF's entry
        template = DataPipeline._drafttemplate(paper, top, front, true)
        drafted = YAML.load(template)
        @test drafted["run_metadata"]["shell"] == "julia"
        script = drafted["run_metadata"]["script"]
        @test startswith(script,
                         "import Pkg\nPkg.activate(\"paper/pipeline\")\nPkg.instantiate()\n")
        @test occursin("DataPipeline.build_paper!(handle, \"paper/article.tex\")\n",
                       script)
        @test drafted["write"] ==
              [Dict("data_product" => "My-Study/article",
                    "description" => "The paper An invented study, built from paper/article.tex",
                    "file_type" => "pdf")]
        temporary = YAML.load(DataPipeline._drafttemplate(paper, top, front,
                                                          false))
        @test startswith(temporary["run_metadata"]["script"],
                         "import Pkg\nPkg.activate(temp = true)\nPkg.add(\"DataPipeline\")\n")

        # The config: the template as it is, then a read: block pinning each
        # data product, labelled by its namespace too where two share a name
        entries = [
            (namespace = "alpha", name = "maps/rain", version = v"1.0.0",
             files = ["paper/pipeline/rain.pdf"], current = true),
            (namespace = "beta", name = "maps/rain", version = v"0.2.0",
             files = ["paper/pipeline/rain-b.pdf"], current = true),
            (namespace = "beta", name = "tables/one", version = v"0.0.1",
             files = ["paper/pipeline/one.tex", "paper/pipeline/same.tex"],
             current = true)]
        text = DataPipeline._paperconfigtext(paper, template, entries)
        @test startswith(text,
                         "# Written by DataPipeline.update_paper from article.template.yaml")
        @test occursin(template, text)
        @test occursin("# paper/pipeline/one.tex\n# paper/pipeline/same.tex\n- data_product: \"tables/one\"",
                       text)
        @test YAML.load(text)["read"] ==
              [
            Dict("data_product" => "alpha/maps/rain",
                 "use" => Dict("data_product" => "maps/rain",
                      "namespace" => "alpha",
                      "version" => "1.0.0")),
            Dict("data_product" => "beta/maps/rain",
                 "use" => Dict("data_product" => "maps/rain",
                      "namespace" => "beta", "version" => "0.2.0")),
            Dict("data_product" => "tables/one",
                 "use" => Dict("namespace" => "beta", "version" => "0.0.1"))]
        @test YAML.load(DataPipeline._paperconfigtext(paper, template, []))["read"] ==
              []
        # A template with a read: block of its own is refused
        write(paper.template, template * "read: []\n")
        @test occursin("has a read: block",
                       message_of(() -> DataPipeline._templatetext(paper),
                                  DataPipeline.ConfigFileException))

        # The pipeline folder's files, but for the environment there and what
        # git ignores
        for name in ("Project.toml", "Manifest.toml", "a.tex", "b.log",
            "sub/c.tex", "sub/Project.toml")
            mkpath(dirname(joinpath(paper.pipeline, name)))
            write(joinpath(paper.pipeline, name), "$name\n")
        end
        write(joinpath(top, ".gitignore"), "*.log\n")
        @test DataPipeline._pipelinefolderfiles(top, paper.pipeline) ==
              ["paper/pipeline/a.tex", "paper/pipeline/sub/Project.toml",
            "paper/pipeline/sub/c.tex"]
        close(repo)
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
                         \\graphicspath{{pipeline/}{include/}}
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
            mkpath(joinpath(top, "include"))
            write(joinpath(top, "pipeline", "figure.png"), PNG)
            write(joinpath(top, "include", "sketch.png"), PNG)
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

            # A run from uncommitted changes, as `fair run --dirty` records
            # one, takes the paper's files as they are, and names them
            config = offering("dirty", clean * "-dirty", "0.0.3")
            handle = DataPipeline.initialise(config, config)
            @test_logs((:info,
                        r"^the run is from uncommitted changes, so these files the paper uses are taken as they are: paper\.tex \(changed since the commit\)"),
                       match_mode=:any,
                       build_paper!(handle, joinpath(top, "paper.tex")))
            DataPipeline.finalise(handle)
            @test versions() == ["0.0.1", "0.0.3"]
            close(repo)
        end

        @testset "setting a paper up, checking it and updating it" begin
            # A paper in a folder of its repository, using two tables from the
            # pipeline and notes of its own
            top = mktempdir()
            folder = joinpath(top, "paper")
            article = """
                      \\documentclass{article}
                      \\title{An invented study of setups}
                      \\author{Ines A. Valcourt \\and Oskar Lindqvist}
                      \\begin{document}
                      \\maketitle
                      \\input{pipeline/table}
                      \\input{pipeline/results}
                      \\input{include/notes}
                      \\end{document}
                      """
            texts = Dict("paper/article.tex" => article,
                         "paper/pipeline/table.tex" => "A table for the paper setup, run $uid.\n",
                         "paper/pipeline/results.tex" => "Results for the paper setup, run $uid.\n",
                         "paper/include/notes.tex" => "Notes of the paper's own, run $uid.\n")
            for (name, text) in texts
                mkpath(dirname(joinpath(top, name)))
                write(joinpath(top, name), text)
            end
            repo = LibGit2.init(top)
            signature = LibGit2.Signature("Test", "test@example.com",
                                          1_000_000_000, 0)
            # Commit everything there is
            function commit!(message)
                LibGit2.add!(repo, ".")
                return LibGit2.commit(repo, message, author = signature,
                                      committer = signature)
            end
            commit!("paper setup $uid")
            paper = DataPipeline.LaTeXPaper(joinpath(folder, "article.tex"))
            citation = joinpath(top, "CITATION.cff")

            # A version of a table registered by a run of its own, from a copy
            # of its text, so that the paper's file is not linked to the data
            # store's
            inputs = "paper-setup/$uid"
            function register!(part, text, version; file_type = "tex")
                config = DataPipeline._createconfig(cpath("setup-$part-$version"))
                DataPipeline._addwrite(config, "$inputs/$part", "a $part",
                                       file_type = file_type,
                                       use_version = version)
                handle = DataPipeline.initialise(config, config)
                copy = joinpath(mktempdir(), "$part.$file_type")
                write(copy, text)
                link_write!(handle, "$inputs/$part", path = copy)
                return DataPipeline.finalise(handle)
            end
            label(part, version) = "$namespace:$inputs/$part@v$version"
            pinned() = Dict(entry["data_product"] => entry["use"]["version"]
                            for entry in YAML.load_file(paper.config)["read"])

            # Set up before the tables are registered: CITATION.cff and the
            # template drafted, and the config left for later
            early = DataPipeline.setup_paper(registry, paper, project = false,
                                             remote = nothing)
            @test early.created == [citation, paper.template]
            @test isempty(early.kept)
            @test isnothing(early.config) && !isfile(paper.config)
            @test sort(early.unregistered) ==
                  ["paper/pipeline/results.tex", "paper/pipeline/table.tex"]
            @test occursin("  - family-names: \"Valcourt\"\n    given-names: \"Ines A.\"\n",
                           read(citation, String))

            # Set up again once they are: what is there kept as it is, and the
            # config written, pinned to the versions the files are
            register!("table", texts["paper/pipeline/table.tex"], "0.0.1")
            register!("results", texts["paper/pipeline/results.tex"], "0.0.1")
            for file in (citation, paper.template)
                write(file, "# Kept by setup_paper\n" * read(file, String))
            end
            set = DataPipeline.setup_paper(registry, paper, project = false,
                                           remote = nothing)
            @test isempty(set.created)
            @test set.kept == [citation, paper.template]
            @test all(startswith(read(file, String), "# Kept by setup_paper\n")
                      for file in (citation, paper.template))
            @test set.config == paper.config && isempty(set.unregistered)
            @test pinned() ==
                  Dict("$inputs/results" => "0.0.1", "$inputs/table" => "0.0.1")

            # Checked: every file registered and current, the repository not
            # initialised for the pipeline, no licence and no ORCIDs
            commit!("set up")
            check = DataPipeline.check_paper(registry, paper, remote = nothing)
            @test any(contains("not initialised for the pipeline"), check.setup)
            @test sort(check.uses.pipeline) ==
                  ["paper/pipeline/results.tex", "paper/pipeline/table.tex"]
            @test sort(check.uses.own) ==
                  ["paper/article.tex", "paper/include/notes.tex"]
            @test check.metadata == "the top level of CITATION.cff"
            @test "paper/pipeline/table.tex is $(label("table", "0.0.1")), its newest version" in
                  check.notes
            @test length(check.actions) == 1
            @test contains(only(check.actions),
                           "the top level of CITATION.cff gives no licence")
            @test any(contains("no ORCID for Ines A. Valcourt, Oskar Lindqvist"),
                      check.notes)
            @test occursin("\n  to do:\n    - the top level of CITATION.cff gives no licence",
                           sprint(show, MIME"text/plain"(), check))
            @test sprint(show, check) ==
                  "PaperCheck(\"article.tex\": $(length(check.setup)) missing from the setup, 1 to do)"

            # A newer table, files in the wrong places, the environment in the
            # pipeline folder, and the authors reordered
            register!("table", "A newer table for the paper setup, run $uid.\n",
                      "0.0.2")
            write(joinpath(folder, "pipeline", "unused.txt"),
                  "Not from the pipeline, run $uid.\n")
            write(joinpath(folder, "pipeline", "Project.toml"), "[deps]\n")
            write(joinpath(folder, "include", "notes.tex"),
                  texts["paper/pipeline/results.tex"])
            reordered = replace(article,
                                "Ines A. Valcourt \\and Oskar Lindqvist" => "Oskar Lindqvist \\and Ines A. Valcourt")
            write(paper.tex, reordered)
            check = DataPipeline.check_paper(registry, paper, remote = nothing)
            @test any(contains("paper/pipeline/table.tex is $(label("table", "0.0.1")), and v0.0.2 is newer - `update_paper(newest = true)` brings it in"),
                      check.actions)
            @test any(contains("paper/include/notes.tex has the bytes of $(label("results", "0.0.1")), but is outside the pipeline folder"),
                      check.actions)
            @test any(contains("files in the pipeline folder are registered as no data product and the paper does not use them: paper/pipeline/unused.txt -"),
                      check.actions)
            @test !any(contains("Project.toml"), check.actions)
            @test any(contains("the authors are in another order - `update_paper` would bring CITATION.cff into line"),
                      check.actions)
            @test any(contains("paper/article.tex (changed since the commit)"),
                      check.actions)

            # Updated to the newest versions: the newer table copied in, the
            # config pinning it, and CITATION.cff in the LaTeX's order
            write(joinpath(folder, "include", "notes.tex"),
                  texts["paper/include/notes.tex"])
            rm(joinpath(folder, "pipeline", "unused.txt"))
            updated = DataPipeline.update_paper(registry, paper, newest = true,
                                                remote = nothing)
            @test updated.config == paper.config
            @test updated.files ==
                  ["paper/pipeline/table.tex" => label("table", "0.0.2")]
            @test read(joinpath(folder, "pipeline", "table.tex"), String) ==
                  "A newer table for the paper setup, run $uid.\n"
            @test pinned()["$inputs/table"] == "0.0.2"
            @test updated.citation == ["authors put in the LaTeX's order"]
            @test DataPipeline._papermetadata(top).authors ==
                  ["Oskar Lindqvist", "Ines A. Valcourt"]
            commit!("updated")
            check = DataPipeline.check_paper(registry, paper, remote = nothing)
            @test "paper/pipeline/table.tex is $(label("table", "0.0.2")), its newest version" in
                  check.notes
            @test length(check.actions) == 1
            @test contains(only(check.actions), "gives no licence")

            # The authors compared with those of the PDF's version registered
            # last, the template naming its namespace
            template = read(paper.template, String)
            pdf = "$(basename(top))/article"
            write(paper.template,
                  template * "  use:\n    namespace: $namespace\n")
            config = DataPipeline._createconfig(cpath("setup-pdf"))
            DataPipeline._addwrite(config, pdf, "a made-up PDF",
                                   file_type = "pdf", use_version = "0.0.1")
            handle = DataPipeline.initialise(config, config)
            made = joinpath(mktempdir(), "article.pdf")
            write(made, "%PDF-1.4 made up for the paper setup, run $uid\n")
            link_write!(handle, pdf, path = made)
            DataPipeline.finalise(handle)
            check = DataPipeline.check_paper(registry, paper, remote = nothing)
            @test any(contains("the authors differ from those of $namespace:$pdf@v0.0.1, the PDF's version registered last: Oskar Lindqvist, Ines A. Valcourt added"),
                      check.notes)
            # ... and the config not what the changed template gives
            @test any(contains("the config at paper/article.yaml is not what `update_paper` would write"),
                      check.actions)
            write(paper.template, template)

            if Sys.iswindows()
                @info "the stand-in for fair is a shell script: not pulling through the project's remote on Windows"
            else
                # Through the project's remote, `origin` - here the suite's own
                # registry - `fair pull` is run in the repository with the
                # config, and the newest table then copied in
                mkpath(joinpath(top, ".fair"))
                token = joinpath(top, ".fair", "token")
                write(token, ENV["FDP_LOCAL_TOKEN"] * "\n")
                # The same registry by another name, to tell the paper's
                # project's configuration from any other
                origin = replace(registry.url, "127.0.0.1" => "localhost")
                write(joinpath(top, ".fair", "cli-config.yaml"),
                      "registries:\n  origin:\n    uri: $origin\n    token: $token\n")
                @test DataPipeline._paperremote("origin", top).url == origin
                bin = mktempdir()
                calls = joinpath(bin, "calls")
                standin = joinpath(bin, "fair")
                write(standin,
                      "#!/bin/sh\necho \"\$(pwd -P) \$*\" >> $calls\necho \"fair, version 9.9.9\"\n")
                chmod(standin, 0o755)
                register!("table",
                          "The newest table for the paper setup, run $uid.\n",
                          "0.0.3")
                DataPipeline.set_cli!(standin)
                try
                    updated = DataPipeline.update_paper(registry, paper,
                                                        newest = true)
                    @test "$(realpath(top)) pull $(paper.config)" in
                          readlines(calls)
                    @test updated.files ==
                          ["paper/pipeline/table.tex" =>
                        label("table", "0.0.3")]
                    check = DataPipeline.check_paper(registry, paper)
                    @test isempty(check.setup)
                    @test !any(contains("does not hold"), check.actions)
                    rm(token)
                    check = DataPipeline.check_paper(registry, paper)
                    @test any(contains("there is no token for the remote registry 'origin' in $token"),
                              check.setup)
                    write(token, ENV["FDP_LOCAL_TOKEN"] * "\n")

                    # A pull that fails leaves the config and the files as
                    # they were. The newer table is registered with no
                    # stand-in recorded, since a run given no session by
                    # `fair run` asks the recorded fair to open one
                    DataPipeline.set_cli!(nothing)
                    register!("table",
                              "A table newer still for the paper setup, run $uid.\n",
                              "0.0.4")
                    failing = joinpath(bin, "failing")
                    write(failing,
                          "#!/bin/sh\n[ \"\$1\" = pull ] && exit 1\necho \"fair, version 9.9.9\"\n")
                    chmod(failing, 0o755)
                    DataPipeline.set_cli!(failing)
                    kept = read(paper.config, String)
                    @test contains(message_of(() -> DataPipeline.update_paper(registry,
                                                                              paper,
                                                                              newest = true),
                                              ReadWriteException),
                                   "`fair pull")
                    @test read(paper.config, String) == kept
                    @test read(joinpath(folder, "pipeline", "table.tex"),
                               String) ==
                          "The newest table for the paper setup, run $uid.\n"
                finally
                    DataPipeline.set_cli!(nothing)
                end
            end

            # Refused, the config left as it was: the newest from a remote not
            # `origin`, no template, a template with a read: block, a file not
            # registered, and a newest version of another file type
            before = read(paper.config, String)
            @test_throws ArgumentError DataPipeline.update_paper(registry,
                                                                 paper,
                                                                 newest = true,
                                                                 remote = "elsewhere")
            mv(paper.template, paper.template * ".away")
            @test contains(message_of(() -> DataPipeline.update_paper(registry,
                                                                      paper,
                                                                      remote = nothing),
                                      DataPipeline.ConfigFileException),
                           "run `DataPipeline.setup_paper` to draft one")
            mv(paper.template * ".away", paper.template)
            write(paper.template, template * "read: []\n")
            @test contains(message_of(() -> DataPipeline.update_paper(registry,
                                                                      paper,
                                                                      remote = nothing),
                                      DataPipeline.ConfigFileException),
                           "has a read: block")
            write(paper.template, template)
            write(joinpath(folder, "pipeline", "results.tex"),
                  "Results not registered, run $uid.\n")
            @test contains(message_of(() -> DataPipeline.update_paper(registry,
                                                                      paper,
                                                                      remote = nothing),
                                      ReadWriteException),
                           "registered as no data product, so the build would refuse them: paper/pipeline/results.tex -")
            @test any(contains("registered as no data product, so the build would refuse them: paper/pipeline/results.tex -"),
                      DataPipeline.check_paper(registry, paper,
                                               remote = nothing).actions)
            write(joinpath(folder, "pipeline", "results.tex"),
                  texts["paper/pipeline/results.tex"])
            register!("results", "Results as a table, run $uid.\n", "0.0.2",
                      file_type = "csv")
            @test contains(message_of(() -> DataPipeline.update_paper(registry,
                                                                      paper,
                                                                      newest = true,
                                                                      remote = nothing),
                                      ReadWriteException),
                           "is a csv file")
            @test read(paper.config, String) == before
            check = DataPipeline.check_paper(registry, paper, remote = nothing)
            @test any(contains("and v0.0.2 is newer - it is a csv file, so replace this one by hand"),
                      check.actions)

            # What a file trusted less than CITATION.cff says otherwise is
            # noted
            write(joinpath(top, ".zenodo.json"),
                  "{\"creators\": [{\"name\": \"Else, Somebody\"}]}\n")
            check = DataPipeline.check_paper(registry, paper, remote = nothing)
            @test any(contains(".zenodo.json gives the authors Somebody Else"),
                      check.notes)

            # A registry that answers, and an address where none does
            @test DataPipeline._answers(registry)
            @test !DataPipeline._answers(DataPipeline.RegistryEndpoint("http://127.0.0.1:1/api/"))
            close(repo)
        end

        @testset "a paper beside a package" begin
            # A repository holding a package and a paper using nothing from
            # the pipeline
            top = mktempdir()
            write(joinpath(top, "Project.toml"),
                  """
                  name = "InventedPackage"
                  uuid = "8f5a1c2e-3b4d-4e6f-9a7b-1c2d3e4f5a6b"
                  authors = ["Tobias Quennell <tq@example.org>"]
                  """)
            write(joinpath(top, "paper.tex"),
                  """
                  \\documentclass{article}
                  \\title{A paper beside a package}
                  \\author{Morag Fairlie \\and Tobias Quennell}
                  \\begin{document}
                  \\maketitle
                  Nothing from the pipeline, run $uid.
                  \\end{document}
                  """)
            close(LibGit2.init(top))
            paper = DataPipeline.LaTeXPaper(joinpath(top, "paper.tex"))
            citation = joinpath(top, "CITATION.cff")

            # Set up with the build's environment: the package at the top
            # level of CITATION.cff and the paper its preferred-citation
            set = DataPipeline.setup_paper(registry, paper, remote = nothing)
            environment = joinpath(top, "pipeline", "Project.toml")
            @test set.created ==
                  [citation, paper.template, environment,
                joinpath(top, "pipeline", "Manifest.toml")]
            @test haskey(DataPipeline.TOML.parsefile(environment)["deps"],
                         "DataPipeline")
            @test startswith(YAML.load_file(paper.template)["run_metadata"]["script"],
                             "import Pkg\nPkg.activate(\"pipeline\")\nPkg.instantiate()\n")
            @test set.config == paper.config
            @test YAML.load_file(paper.config)["read"] == []
            cff = YAML.load_file(citation)
            @test cff["title"] == "InventedPackage"
            @test length(cff["authors"]) == 1
            @test cff["preferred-citation"]["title"] ==
                  "A paper beside a package"
            @test DataPipeline.check_paper(registry, paper,
                                           remote = nothing).metadata ==
                  "the preferred-citation of CITATION.cff"

            # A CITATION.cff of the package's alone is not updated, but has
            # the paper's citation added by setup_paper
            write(citation,
                  "cff-version: 1.2.0\nmessage: \"Cite the package.\"\ntitle: \"InventedPackage\"\nauthors:\n  - family-names: Quennell\n    given-names: Tobias\n")
            @test contains(message_of(() -> DataPipeline.update_paper(registry,
                                                                      paper,
                                                                      remote = nothing),
                                      DataPipeline.ConfigFileException),
                           "has no preferred-citation for the paper")
            again = DataPipeline.setup_paper(registry, paper, remote = nothing)
            @test citation in again.created && environment in again.kept
            cff = YAML.load_file(citation)
            @test length(cff["authors"]) == 1
            @test length(cff["preferred-citation"]["authors"]) == 2
        end
    end
end

end
