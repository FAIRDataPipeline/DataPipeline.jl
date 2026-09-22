# FAIR data pipeline manual
This is the manual for the FAIR `DataPipeline` package.

```@contents
Pages = ["fdp_manual.md"]
Depth = 3
```

## Managing code runs

```@docs
initialise
finalise
DataPipeline.DataRegistryHandle
DataPipeline.RegistryEndpoint
```

## Reading data

```@docs
read_array
read_table
read_estimate
read_distribution
link_read!
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
AbstractIssueTarget
WorkingConfig
SubmissionScript
CodeRepository
ConfigDataProduct
ExistingDataProduct
```

## Index
```@index
Pages = ["fdp_manual.md"]
```
