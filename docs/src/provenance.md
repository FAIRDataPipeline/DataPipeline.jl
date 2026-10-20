# Tracing provenance

What the pipeline records of every run - the code at its commit, what it read
and what it wrote - is there to be asked. This page is what the package asks
of it: what the registry knows about a file, where a file came from, what was
made from it, how one version supersedes another, and the crate that packs the
files of a paper with the provenance of each. None of it needs a token, so it
all works outside `fair run`, against the local registry or a remote one.

## Holding the local registry

Outside a run, each of these functions holds the local registry up through a
session of the FAIR CLI's while it works: a session starts the registry where
nothing holds it, and the last to close stops one a session started. Calls in
a `DataPipeline.registry_session` block share its session, given its endpoint
first; `fair registry start` keeps the registry running until `fair registry
stop`.

```julia
DataPipeline.registry_session() do registry
    DataPipeline.identify(registry, "results.csv")
    DataPipeline.provenance(registry, "results.csv")
end
```

```@docs
DataPipeline.registry_session
```

## Asking what the registry knows about a file or a repository

`DataPipeline.identify` takes a file, or commits of a git repository, and asks
the registry the FAIR CLI is configured to use, or any other, what it knows
about them. A selection of commits holds its repository: the top-level folder
of a clone, or the URL of its remote, by default the repository holding the
current directory. No token is needed, so it works outside `fair run`:

```julia
DataPipeline.identify("results.csv")                        # the local registry
DataPipeline.identify("results.csv", remote = "origin")     # a remote of this project
DataPipeline.identify("results.csv", superseded = true)     # and the inputs behind it since superseded
DataPipeline.identify(DataPipeline.AncestorCommits())       # this checkout's commit and its ancestors
DataPipeline.identify(DataPipeline.NamedCommit("v0.55.0"))  # one commit, by tag, branch, hash or release
# every run of this repository, including those made with uncommitted changes
DataPipeline.identify(DataPipeline.AllCommits(dirty = true))
# a repository with no clone, by the registry's record of it alone
DataPipeline.identify(DataPipeline.AllCommits(repo = "https://github.com/FAIRDataPipeline/DataPipeline.jl"))
```

A file's identification carries the issues raised on it and, behind it, the
issues raised on anything a run on the way read, or on a run's own code,
config or script, each with the run it reaches the file through; with
`superseded = true` it lists the inputs behind the file that a newer version of
has been registered since, as outdated rather than wrong.

```@docs
DataPipeline.identify
DataPipeline.FileIdentification
DataPipeline.RegisteredObject
DataPipeline.DataProductRecord
DataPipeline.UpstreamIssue
DataPipeline.OutdatedInput
DataPipeline.IssueRecord
DataPipeline.RepositoryIdentification
DataPipeline.RegisteredCommit
DataPipeline.CodeRunRecord
DataPipeline.AbstractCommitSelection
DataPipeline.AncestorCommits
DataPipeline.CheckedOutCommit
DataPipeline.AllCommits
DataPipeline.NamedCommit
```

## Where a file came from

`DataPipeline.provenance` traces a data product back: the run that made it,
what that run read, the runs that made those, and so on to the data registered
from elsewhere, each with its source. It takes a file, or a data product named
`namespace:name@version` as the pipeline names one, and prints as a tree,
newest first, each data product once:

```julia
DataPipeline.provenance("figures/summary.pdf")
DataPipeline.provenance("testing:SEIRS_model/report/julia@v0.0.1")
DataPipeline.provenance("testing:SEIRS_model/report/julia", depth = 2)   # two runs back
```

```
Provenance of testing:SEIRS_model/report/julia@v0.0.1  sha1 c896cfb9
<- run a1b118f0 on 2026-10-15 11:33 UTC, github.com/FAIRDataPipeline/DataPipeline.jl.git at 34d3bdca
   used testing:SEIRS_model/summary/julia@v0.0.1  sha1 b6ae4389
       issue, severity 3: an issue over an input and an output
   <- run 577160a1 on 2026-10-15 11:33 UTC, github.com/FAIRDataPipeline/DataPipeline.jl.git at 34d3bdca
      used PSU:SEIRS_model/parameters@v1.0.0  sha1 6294a595  superseded by v1.0.1  from https://doi.org/10.1038/s41592-020-0856-2 (supplement)
          issue, severity 2: an issue on the parameters
      used testing:SEIRS_model/results/model_output/julia@v0.0.1  sha1 e8912ec2
      <- run c30fbbdd on 2026-10-15 11:33 UTC, github.com/FAIRDataPipeline/DataPipeline.jl.git at 34d3bdca
         used PSU:SEIRS_model/parameters@v1.0.0  (above)
```

The value holds more than the tree prints - every data product, run and
issue reached, keyed by registry URL - for a script to work over.

```@docs
DataPipeline.provenance
DataPipeline.Trace
DataPipeline.TraceProduct
DataPipeline.TraceRun
DataPipeline.TraceIssue
DataPipeline.TraceSource
DataPipeline.TraceRelease
DataPipeline.TraceTarget
```

## What was made from a file

`DataPipeline.downstream` traces the other way: the runs that read a data
product, what they wrote, the runs that read those, and on to the end of every
path. It answers "I have found a problem in this - what must be made again?":
every data product reached that no newer version has superseded. It starts
from a data product, from everything the runs of selected commits wrote, or
from everything an issue is raised on, and prints as the mirror image of
`provenance`:

```julia
DataPipeline.downstream("PSU:SEIRS_model/parameters@v1.0.0")
DataPipeline.downstream(DataPipeline.NamedCommit("v0.55.0"))  # what this release's runs made, and on
DataPipeline.downstream(issue = 12)                           # what an issue affects
```

```@docs
DataPipeline.downstream
```

## Superseding a version

Data is often not wrong but out of date: a dataset is updated, and what was
made from the old version is worth making again, though the old version was
right in its day. `supersede = true` on a write says so. Once the new version
is registered, an issue reading `Superseded by namespace:name@vX.Y.Z` is
raised on the version before it, at severity 0, the lowest, so that `identify`
of anything made from the old version reports it, and `downstream` of the old
version is what to make again:

```julia
link_write!(handle, "era5/t2m/2021", path = "cache/era5_t2m_2021.nc", doi = era5,
            primary = false, supersede = true)
```

Where there is nothing to supersede - the file is registered already,
unchanged, or the name has no version before - nothing is raised and an info
message says so.

## Releases of the code

A run records the commit of the code it ran. `DataPipeline.register_release!`
records that a commit is a release - its version read from the commit's tag,
`v1.2.0` say, its authors and licence from the first of the repository's
`codemeta.json`, `.zenodo.json`, `CITATION.cff` and project file that it has -
as the registry's release
record and as a data product, `<organisation>:<repository>@<version>`, which
the traces and the crate take as they take any data product. A release then
names the code before it, so that a problem fixed in it can be raised on
everything it was found in. Its DOI - `doi = "10.5281/zenodo..."`, or for a
repository with a `.zenodo.json` the Zenodo DOI of its tag's version, found
there - is the data product's source; one that Zenodo has not minted yet is
attached by calling `register_release!` again later:

```julia
release = DataPipeline.register_release!(DataPipeline.NamedCommit("v1.2.0"))
raise_issue!(DataPipeline.AncestorCommits(of = release, including = false),
             "Bug X, fixed in v1.2.0")
```

```@docs
DataPipeline.register_release!
DataPipeline.RegisteredRelease
```

## The crate for a paper

`DataPipeline.crate` fetches the RO-Crate the registry builds for data
products: a package of their files with the provenance of each, in which every
run with its code at its commit, everything it read, and each data product with
its source and its issues travel together. The paper's figures in one folder is
the case in mind:

```julia
DataPipeline.crate("figures")                            # the metadata, parsed
DataPipeline.crate("figures", to = "paper.zip")          # the zip, files packed
DataPipeline.crate("paper", strict = false)              # the sources left out, and said
```

```@docs
DataPipeline.crate
```

## Index
```@index
Pages = ["provenance.md"]
```
