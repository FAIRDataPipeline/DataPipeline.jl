# DataPipeline.jl

!!! note

    The [FAIR Data Pipeline documentation](https://www.fairdatapipeline.org/docs/)
    describes the pipeline as a whole, in every language. These pages are for
    the Julia package.

`DataPipeline` is the Julia API of the FAIR Data Pipeline. A model script
calls it to find its inputs, place its outputs and record what it read and
wrote as a code run, so that any output can be traced back through the code
that made it to the data behind it, and a problem found later in any of these
reaches everything made from it.

## The pipeline

The pipeline has three parts. A **registry** holds the record: data products
and the files that hold them, each file known by its SHA-1 hash and where it
is stored; code runs, with their inputs and outputs and the commit of their
code; the sources of data that came from elsewhere; and issues raised on any
of these. The
[schema](https://www.fairdatapipeline.org/docs/data_registry/schema/) has the
detail. A registry runs on the modeller's own machine, so that work can go on
offline, and what it records can be pushed to a remote one, such as
[data.fairdatapipeline.org](https://data.fairdatapipeline.org). The
command-line tool **`fair`** sets up a project, registers and fetches what a
run will read, prepares and launches each run, and moves records between
registries. A small **API in each language**, this package for Julia, is what
the model calls while it runs.

A run starts from a *user config*, a YAML file naming what the run reads and
writes and the command that runs the model. `fair run` turns it into a
*working config*, with every name, namespace and version made explicit, and
runs the command. [`DataPipeline.initialise`](@ref) reads the working config,
and the script asks for each input and output by the name the config gives it.

## What the package does

- **Code runs.** `initialise` opens a run and registers its config, its
  script and the commit of its code; [`link_read!`](@ref) gives the path of
  an input and [`link_write!`](@ref) a path to write an output to, recording
  each, as the component readers and writers do for parts of a TOML or HDF5
  file; and [`DataPipeline.finalise`](@ref) registers the outputs and the
  run. A name to read may be a wildcard, standing for every data product it
  matches.
- **Data from elsewhere**, registered with its source, its authors and its
  licence, and read by a run as any other input:
  [Data that comes from elsewhere](@ref).
- **Issues**, raised on an input, an output, the config, the script or the
  code: [Raising issues](@ref).
- **Rehearsals**: a script run through the pipeline with nothing recorded,
  until it is right: [Rehearsing a run](@ref).
- **Tracing**: what the registry knows of a file or a repository, where a
  file came from, what was made from it, and the RO-Crate that packs a
  paper's files with their provenance: [Tracing provenance](@ref).
- **Papers**: a LaTeX paper built in a run of its own, so that its pdf has
  the provenance of every figure and table in it:
  [Building a paper](@ref).
- **`fair` from Julia**: [`fair"..."`](@ref @fair_str) runs the
  command-line tool, and [`DataPipeline.install_cli!`](@ref) installs a copy
  of it for a Julia with no Python to hand.

## Installation

The package is registered in Julia's General registry. From the REPL type `]`
to enter Pkg mode and run:

```julia
pkg> add DataPipeline
```

It needs Julia 1.11 or later, and `fair-cli` from version 0.11.0: from PyPI,
as the
[CLI's documentation](https://www.fairdatapipeline.org/docs/cli/installation/)
describes, or the package's own copy, which `DataPipeline.install_cli!()`
installs from Julia.

## Getting started

The pipeline is driven by `fair`, from Julia or from a shell. In Julia,
`fair"..."` runs it with its arguments written as on the command line, in the
current directory. Each command starts the local registry where none is
running, and stops it when done; `fair"registry start"` keeps it running until
`fair"registry stop"`.

The first time, install the local registry, then set the project up from the
top level of the git repository holding the model, answering the questions
`fair init` asks:

```julia
using DataPipeline
DataPipeline.install_cli!()  # where there is no `fair` installed
fair"registry install"
cd("path/to/model")
fair"init"
```

Then each time the model runs, register or fetch what it reads, and run it,
adding `--dirty` to `run` while the repository has uncommitted changes:

```julia
using DataPipeline
cd("path/to/model")
fair"pull config.yaml"
fair"run config.yaml"
```

From a shell the same commands are `fair registry install`, `fair init`,
`fair pull config.yaml` and `fair run config.yaml`. Either way, `fair run` runs
the config's script in a shell, so a `julia` that the script calls must be on
the path.

The script that `config.yaml` names brackets the model with the API:

```julia
using DataPipeline

handle = DataPipeline.initialise()
parameters = link_read!(handle, "SEIRS_model/parameters")
# ... run the model on the parameters ...
results = link_write!(handle, "model_output")
# ... and write its results to that path
DataPipeline.finalise(handle)
```

The [SEIRS model example](@ref) is this example whole: its config, its script
and its run.
