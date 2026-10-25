# FAIR data pipeline manual
This is the manual for the FAIR `DataPipeline` package, which works with the
pipeline's command-line tool, `fair-cli`, from version 0.11.0.

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
fair"pull config.yaml"                 # when inputs need registering or syncing
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
job folder `fair` prepared for it, and returns the folder. `discard` ends a
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

A script can also rehearse the run it belongs to, as a check before that run
starts. In a script that `fair run` launched, `DataPipeline.rehearse() do
handle ... end` rehearses the job `fair run` prepared, passes the block the
rehearsal's handle, and discards the rehearsal as the block ends, so that the
script's `initialise()` then opens the recorded run as usual. A fetch run that
finds nothing left to fetch can stop there, before a code run is registered:

```julia
using DataPipeline
nothing_to_fetch = DataPipeline.rehearse() do handle
    return all_fetched(handle)    # the script's own check
end
nothing_to_fetch && exit()
handle = DataPipeline.initialise()
```

Under `fair run` a script rehearses in a block only: `rehearse` given a path is
refused there, since the script's `initialise()` would open that rehearsal in
place of the run, and record nothing. Elsewhere a block takes a path, as
`rehearse` does.

The `fair` used is the one `DataPipeline.set_cli!(path)` has recorded, a
preference of the environment DataPipeline is loaded from that holds across
sessions; else the
`fair` on the path, which it is on when Julia was started from a shell with
the CLI's virtual environment active; else the copy the package installed.
`fair"..."` runs it with any arguments, written as on the command line:
`fair"pull config.yaml"`, or `fair"pull $config"`.

A Julia started by an editor has no virtual environment on its path, so the
package can install a copy of its own, with a Python and a git of its own
that MicroMamba fetches: `DataPipeline.install_cli!()`, once, which records the
copy as the `fair` to use, and again to bring it up to date. The whole
pipeline can then be set up from Julia:

```julia
using DataPipeline
DataPipeline.install_cli!()            # once: fair, with its Python, recorded
fair"registry install"                 # once: the local registry
fair"init"                             # once per project, from its root; asks questions
fair"pull config.yaml"
DataPipeline.rehearse("config.yaml")
```

```@docs
DataPipeline.rehearse
DataPipeline.discard
@fair_str
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

A fetch run can ask before it fetches. `DataPipeline.isregistered(handle, name)`
says whether anything is registered under a name, and given the source keywords
the link call would be given, but no file, whether registering the file would
register nothing new - the same source, authors and licence. In a rehearsal in
a block (see [Rehearsing a run](@ref)), a fetch run with nothing to fetch can
then stop before a code run is registered:

```julia
using DataPipeline
nothing_to_fetch = DataPipeline.rehearse() do handle
    return DataPipeline.isregistered(handle, "my_namespace:era5/t2m/2020",
                                     doi = "10.24381/cds.f17050d7",
                                     primary = false,
                                     title = "ERA5 2m temperature, 2020",
                                     licence = "CC-BY-4.0",
                                     release_version = "1.0.0")
end
nothing_to_fetch && exit()
handle = DataPipeline.initialise()
```

A name is spelled as `link_register!` spells it, its namespace by default the
run's default input namespace, so a file that a `write:` entry puts in another
namespace is named with it.

A deposit may instead be registered by `fair pull` from a `register:` entry with
`no_file: true`, or by `link_register!` in an earlier run. Either way a later
run is offered it by a `read:` entry, and `link_read!` records it as an input
and returns `nothing`, since it has no file.

Registering a source needs `data-registry` v1.4.0 or later.

```@docs
register_citations!
register_authors!
link_register!
DataPipeline.isregistered
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
