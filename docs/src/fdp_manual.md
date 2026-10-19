# FAIR data pipeline manual
This is the manual for the FAIR `DataPipeline` package.

```@contents
Pages = ["fdp_manual.md"]
Depth = 3
```

## Managing code runs

```@docs
DataPipeline.initialise
DataPipeline.finalise
DataPipeline.DataRegistryHandle
DataPipeline.AbstractRunMode
DataPipeline.RecordedRun
DataPipeline.Rehearsal
DataPipeline.RegistryEndpoint
DataPipeline.ReadWriteException
DataPipeline.ConfigFileException
```

## Rehearsing a run

A script can be run through the pipeline without being recorded, to be run
again, unchanged, under `fair run` once it is right. In a session, prepare
the run from the user config, then run the script, or its lines one at a
time:

```julia
using DataPipeline
DataPipeline.fair"pull config.yaml"    # when inputs need registering or syncing
DataPipeline.rehearse("config.yaml")   # fair prepares the job as a run would
include("script.jl")                    # or its lines, one at a time
```

`rehearse` has `fair` write the working config and the script into a job
folder, as `fair run` does before it launches a script, and the session then
holds the rehearsal: that folder, the folder the outputs will be collected
in, and the handle once opened. The script's `initialise()` opens a
rehearsal rather than a code run: it reads what the registry holds, writes to
the data store, holds no registry token, and registers nothing, saying
instead what `link_register!` and `register_authors!` would have registered.
Its `finalise` checks the outputs as a recorded run would, saying which are
registered already, unchanged, moves them to the outputs folder as
`<namespace>/<data product>/<version>.<extension>` with the working config
beside them, prints the issues a recorded run would have raised, deletes the
job folder, and returns the folder. `discard` ends a
rehearsal without collecting anything.

A session has one run, opened once: `initialise()` is an error while a run
is open, and after `finalise` or `discard` has ended it. In a rehearsal the
error says to `rehearse` again, which prepares a fresh one; a script that
failed halfway is run again that way, with `restart = true` while the first
rehearsal is still open. A recorded run cannot be followed by another in the
same session. The outputs folder is a new one under the system's
temporary directory, unless `outputs =` names one, in which case a repeated
rehearsal replaces its files. `local_only = true` passes `--local` to
`fair run`. Nothing of a rehearsal reaches the registry, so a model run can
be rehearsed only once the fetch run it reads from has been recorded.

The `fair` used is the one `DataPipeline.set_cli!(path)` has recorded, a
preference of the active environment that holds across sessions; else the
`fair` on the path, which it is on when Julia was started from a shell with
the CLI's virtual environment active; else the copy the package installed.
`DataPipeline.fair"..."` runs it with any arguments, written as on the
command line: `DataPipeline.fair"pull config.yaml"`, or
`DataPipeline.fair"pull $config"`.

A Julia started by an editor has no virtual environment on its path, so the
package can install a copy of its own, with a Python and a git of its own
that MicroMamba fetches: `DataPipeline.install_cli!()`, once, which records the
copy as the `fair` to use, and again to bring it up to date. The whole
pipeline can then be set up from Julia:

```julia
using DataPipeline
DataPipeline.install_cli!()            # once: fair, with its Python, recorded
DataPipeline.fair"registry install"    # once: the local registry
DataPipeline.fair"init"                # once per project, from its root; asks questions
DataPipeline.fair"registry start"
DataPipeline.fair"pull config.yaml"
DataPipeline.rehearse("config.yaml")
```

```@docs
DataPipeline.rehearse
DataPipeline.discard
DataPipeline.@fair_str
DataPipeline.set_cli!
DataPipeline.install_cli
DataPipeline.install_cli!
```

## Reading data

```@docs
read_array!
read_table!
read_estimate!
read_distribution!
link_read!
link_read_files!
DataPipeline.canread
```

## Writing data

```@docs
write_array!
write_table!
write_estimate!
write_distribution!
link_write!
DataPipeline.canwrite
```

## Several versions of one data product

A script names what it reads and writes by the labels of the working config's
entries, so two versions of one data product are read, or written, under a
label each, the `use:` block of each saying which data product and version it
stands for:

```yaml
read:
- data_product: temperature/older
  use:
    data_product: ECMWF/era5/t2m
    version: 1.0.0
- data_product: temperature/newer
  use:
    data_product: ECMWF/era5/t2m
    version: 2.0.0
```

```julia
older = link_read!(handle, "temperature/older")
newer = link_read!(handle, "temperature/newer")
```

A `write:` entry may name a version that exists, to reproduce it: the file
written must then be that version's - its bytes, with the same source,
authors and licence - and nothing is registered for it. Any other file is an
error at `finalise`, before anything is registered.

## Data that comes from elsewhere

A file fetched from a deposit - a dataset with a DOI, say - is registered with
its source: what it is, who made it, on what terms, and where it was fetched
from. A *fetch run* registers the files it fetches as its outputs, each with its
source, and a *model run* reads them as it reads any other input, so that
anything the model writes traces back through the fetch run to the deposit.

```julia
using DataPipeline
handle = DataPipeline.initialise()
register_authors!(handle, "authors.toml")  # ORCIDs and ROR ids of authors cited by name
era5 = "10.24381/cds.f17050d7"
# The deposit, a data product with no file, which this run reads
link_register!(handle, "deposits/era5-monthly", doi = era5, primary = true,
               licence = "CC-BY-4.0")
# An extract requested from it, which this run writes
link_write!(handle, "era5/t2m/2020", path = "cache/era5_t2m_2020.nc",
            doi = era5, primary = false, title = "ERA5 2m temperature, 2020",
            description = "the request that made it", licence = "CC-BY-4.0",
            release_version = "1.0.0")
DataPipeline.finalise(handle)
```

with a `write:` entry in the working config that covers the file -
`data_product: era5/t2m/*`, with a `file_type` of `nc` - and nothing for the
deposit, which `link_register!` registers itself. A DOI's own metadata gives
what it has of the title, description, licence, release date and version, and
the identifiers of its authors; the keywords fill in what it lacks, and take
the place of what it says. A citation given as BibTeX by
[`register_citations!`](@ref) is named by `bibtex =` instead, and serves a run
with no network. Run again, a fetch run registers nothing new for a file that
has not changed.

Registering a source needs `data-registry` v1.4.0 or later. Wildcard entries in
the working config need `fair-cli` 0.10.0 or later, a pattern read of a family
written more than once 0.10.1, and reading a data product pulled from a remote
registry, or pushing or pulling a deposit with no file, 0.10.2.

```@docs
register_citations!
register_authors!
link_register!
```

## Building a paper

A LaTeX paper whose figures and tables come from pipeline runs can be built in
a code run of its own, so that the PDF is a data product whose provenance runs
through what it uses to the data behind it. The files the paper uses from its
pipeline folder must be registered outputs of other runs, which the working
config's `read:` block offers; its own files, such as the `.tex`, the
bibliography and any drawings, are recorded with the repository's commit. The
PDF is registered with the authors, licence and keywords of the paper's
metadata, `CITATION.cff` first, and holds them in its document information
too. The run's script is an ordinary one:

```julia
import Pkg
Pkg.activate("pipeline")
Pkg.instantiate()
using DataPipeline
handle = DataPipeline.initialise()
build_paper!(handle, "paper.tex")
DataPipeline.finalise(handle)
```

Outside any run, [`DataPipeline.setup_paper`](@ref) prepares a paper once,
drafting its `CITATION.cff` from the LaTeX, the template of the config that
builds it, holding that script, and the script's environment in the pipeline
folder. Before each build, [`DataPipeline.check_paper`](@ref) reports what is
missing or out of date, and [`DataPipeline.update_paper`](@ref) brings
`CITATION.cff` and the config up to date, with `newest = true` bringing in the
newest version of each file from the pipeline too:

```julia
DataPipeline.setup_paper("paper.tex")
DataPipeline.check_paper("paper.tex")
DataPipeline.update_paper("paper.tex", newest = true)
```

The files changed are then committed, after `fair pull paper.yaml` where the
local registry lacks a version the config names, and the paper is built with
`fair run paper.yaml`.

```@docs
build_paper!
DataPipeline.setup_paper
DataPipeline.check_paper
DataPipeline.update_paper
DataPipeline.PaperCheck
DataPipeline.LaTeXPaper
DataPipeline.PdfLaTeXEngine
DataPipeline.LuaLaTeXEngine
DataPipeline.XeLaTeXEngine
```

## Raising issues

An issue records a problem found in something registered, so that
[`DataPipeline.identify`](@ref) of anything made from it reports it and
[`DataPipeline.downstream`](@ref) of it says what to make again. In a run,
`raise_issue!(handle, target, description)` queues it, and `finalise`
registers it, so that an output can be named before it is written:

```julia
raise_issue!(handle, "SEIRS_model/parameters", "Rates are per day, not per week",
             severity = 4)
raise_issue!(handle, DataPipeline.CodeRepository(), "Fixed in the next commit")
```

Outside a run, an issue on something registered already - a data product, or
commits of a code repository - is registered at once. A selection of commits
stands for the code at each of them, so a problem fixed in a release is raised
on everything before it in one call (see [Releases of the
code](@ref)):

```julia
raise_issue!("PSU:SEIRS_model/parameters@v1.0.0", "Rates are per day, not per week")
raise_issue!(DataPipeline.AncestorCommits(of = "v1.2.0", including = false),
             "Bug X, fixed in v1.2.0")
```

```@docs
raise_issue!
DataPipeline.AbstractIssueTarget
DataPipeline.WorkingConfig
DataPipeline.SubmissionScript
DataPipeline.CodeRepository
DataPipeline.ConfigDataProduct
DataPipeline.ExistingDataProduct
```

## Index
```@index
Pages = ["fdp_manual.md"]
```
