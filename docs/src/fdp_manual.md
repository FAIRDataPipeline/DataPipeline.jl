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
