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
DataPipeline.RegistryEndpoint
DataPipeline.ReadWriteException
DataPipeline.ConfigFileException
```

## Reading data

```@docs
read_array
read_table
read_estimate
read_distribution
link_read!
link_read_files!
```

## Writing data

```@docs
write_array
write_table
write_estimate
write_distribution
link_write!
```

## Asking what the registry knows about a file or a repository

`DataPipeline.identify` takes a file or the top-level folder of a git
repository, and asks the registry the FAIR CLI is configured to use, or any
other, what it knows about it. No token is needed, so it works outside
`fair run`:

```julia
DataPipeline.identify("results.csv")                     # the local registry
DataPipeline.identify("results.csv", remote = "origin")  # a remote of this project
DataPipeline.identify(".")                               # this checkout's commit and its ancestors
# every run of this repository, including those made with uncommitted changes
DataPipeline.identify(".", commits = DataPipeline.AllCommits(dirty = true))
```

```@docs
DataPipeline.identify
DataPipeline.FileIdentification
DataPipeline.RegisteredObject
DataPipeline.DataProductRecord
DataPipeline.IssueRecord
DataPipeline.RepositoryIdentification
DataPipeline.RegisteredCommit
DataPipeline.CodeRunRecord
DataPipeline.AbstractCommitSelection
DataPipeline.AncestorCommits
DataPipeline.CheckedOutCommit
DataPipeline.AllCommits
```

## Raising issues

```@docs
raise_issue
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
