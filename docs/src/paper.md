# Building a paper

A LaTeX paper whose figures and tables come from pipeline runs can be built in
a code run of its own. The PDF is then a data product like any other: its
provenance runs through the files it uses to the runs that made them and the
data behind those; its authors, licence and keywords are those of the paper's
`CITATION.cff`, held by the registry and written into the PDF; and an issue
raised on anything behind it reaches it. This page is the whole cycle: laying
the paper out, setting it up once, and checking, updating and building it each
time it changes.

## Laying the paper out

A paper's files are of two kinds. Those that come from runs - figures, and
tables written to be `\input` - are in its **pipeline folder**, `pipeline/`
beside the `.tex` file by default. Each must have the bytes of a registered
data product, and the run that builds the paper records it as an input.
Everything else the paper uses from its repository is its own, wherever it
is, and recorded with the repository's commit: its `.tex` files and its
bibliography, usually beside it, and whatever else it includes - drawings,
photographs, tables of its own - by convention in `include/`. The pipeline
folder is the only one the build treats otherwise.

```latex
\graphicspath{{pipeline/}{include/}}
...
\includegraphics{rainfall}    % pipeline/rainfall.pdf or include/rainfall.pdf
\input{pipeline/rates}        % \input does not look in \graphicspath
\bibliography{paper}          % paper.bib, beside paper.tex
```

The files from the pipeline are committed with the rest, so that a co-author
can build the paper with `latexmk` alone. Building it needs `latexmk` and
pdfLaTeX, LuaLaTeX or XeLaTeX. Each function below takes the path of the
paper's `.tex` file, or a [`DataPipeline.LaTeXPaper`](@ref) for a paper with
another pipeline folder or engine.

## Setting it up

`DataPipeline.setup_paper("paper.tex")`, run once in Julia, creates each of
these that is missing, leaving any that exists as it is:

- `CITATION.cff`, drafted from the paper's `\title`, `\author` and `\affil`.
  The PDF takes its authors, licence and keywords from it, so add the authors'
  ORCIDs and a `license:` by hand. In a repository holding a package, whose
  citation the top level of the file is, the paper's is drafted as its
  `preferred-citation`.
- `paper.template.yaml`, the template of the user config that builds the
  paper: the PDF's `write:` entry and a Julia script. It is yours to edit; the
  config is written from it.
- `pipeline/Project.toml` and `Manifest.toml`, the script's environment,
  holding DataPipeline. With `project = false` none is created, and the script
  installs DataPipeline into a temporary environment each time it runs.

The template drafted for `paper.tex` at the top level of a repository called
`weed-study`:

```yaml
# The template of the config that builds the paper paper.tex in a run
# of the FAIR Data Pipeline. DataPipeline.update_paper writes
# paper.yaml from it, adding a read: block for the files the paper
# uses from the pipeline. Build the paper from the repository's top
# level with `fair run paper.yaml`.
run_metadata:
  description: "Build the paper Rainfall and the spread of an invented weed"
  shell: julia
  script: |
    import Pkg
    Pkg.activate("pipeline")
    Pkg.instantiate()
    using DataPipeline
    handle = DataPipeline.initialise()
    DataPipeline.build_paper!(handle, "paper.tex")
    DataPipeline.finalise(handle)
write:
- data_product: weed-study/paper
  description: "The paper Rainfall and the spread of an invented weed, built from paper.tex"
  file_type: pdf
```

`setup_paper` then writes the config, `paper.yaml`, as `update_paper` does,
where every file the paper uses from its pipeline folder is registered;
otherwise it says which are not, and the config waits for `update_paper`.

## Each time the paper changes

In Julia:

```julia
DataPipeline.check_paper("paper.tex")
DataPipeline.update_paper("paper.tex", newest = true)
```

then, at the terminal, `fair pull paper.yaml` where the check says that the
local registry lacks a file, a commit of what changed, and `fair run
paper.yaml`.

[`DataPipeline.check_paper`](@ref) changes nothing. It reports what building
the paper lacks, then everything that would stop the build or that is out of
date, and the checks it could not make. For the paper above, after a newer
version of one of its tables was registered:

```
Check of the paper /home/me/weed-study/paper.tex: 1 to do
  set up: nothing is missing
  uses 2 files from the pipeline, 1 of its own and 30 from elsewhere:
    pipeline/rates.tex
    pipeline/sites.tex
    paper.tex
  metadata: the top level of CITATION.cff
  to do:
    - pipeline/rates.tex is testing:weeds/rates@v0.0.1, and v0.0.2 is newer - `update_paper(newest = true)` brings it in
  notes:
    - the top level of CITATION.cff gives no ORCID for Tobias Quennell - add them by hand
    - pipeline/sites.tex is testing:weeds/sites@v0.0.1, its newest version
```

[`DataPipeline.update_paper`](@ref) brings `CITATION.cff`'s title and authors
into line with the LaTeX, and writes the config afresh: the template, then a
`read:` block offering each file the paper uses from the pipeline at the
version it is. With `newest = true` it offers the newest version of each
instead, runs `fair pull`, and copies each newer file over the old one, so
that the repository holds what the config offers. Here it replaced
`pipeline/rates.tex` and wrote:

```yaml
read:
# pipeline/rates.tex
- data_product: "weeds/rates"
  use:
    namespace: "testing"
    version: "0.0.2"
# pipeline/sites.tex
- data_product: "weeds/sites"
  use:
    namespace: "testing"
    version: "0.0.1"
```

The files it changed are then committed, config and all, so that each commit
of the paper says which version of each file it used. Both functions identify
the files in the project's remote registry, `origin`, which co-authors share;
`remote = nothing` uses the local registry alone. `fair pull paper.yaml`
brings the versions the config names into a local registry that lacks them, as
on a new machine.

## The build

`fair run paper.yaml` runs the template's script, in which
[`build_paper!`](@ref) builds the paper with `latexmk` and registers the PDF
under the template's `write:` entry. It refuses, before anything is
registered, a paper whose files are not as the run's commit has them - unless
the run is from uncommitted changes, `fair run --dirty` - whose title and
authors are not those of `CITATION.cff`, or which uses a file from the
pipeline folder that the config does not offer. The PDF is built in a folder
of the package's own, kept between builds, so that an unchanged paper gives
the same bytes and registers nothing new; its title, authors, keywords,
licence and the authors' ORCIDs are written into its document information and,
but for XeLaTeX, read back. [`DataPipeline.rehearse`](@ref) followed by the same calls builds
the paper without recording anything, and warns of what a recorded run would
refuse.

## Without the CLI, or in a fresh clone

Reading the paper and its `CITATION.cff`, and drafting the template, need TeX
alone. Identifying the files needs a registry, found through the CLI's
configuration of the project, which `fair init` writes in each clone and which
is not committed. `check_paper` says what is missing, and each is supplied by
one line, none of which the paper's functions run themselves:

```julia
DataPipeline.install_cli!()            # the package's own copy of fair
DataPipeline.fair"registry install"    # a local registry
DataPipeline.fair"init"                # in the repository: who you are, and your remote
```

## Reference

```@docs
DataPipeline.setup_paper
DataPipeline.check_paper
DataPipeline.update_paper
build_paper!
DataPipeline.PaperCheck
DataPipeline.LaTeXPaper
DataPipeline.PdfLaTeXEngine
DataPipeline.LuaLaTeXEngine
DataPipeline.XeLaTeXEngine
```

## Index
```@index
Pages = ["paper.md"]
```
