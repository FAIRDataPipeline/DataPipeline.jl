# FAIR data pipeline manual
This is the updated manual for the upcoming `FAIR` interfaced version of the Data Registry package.

```@contents
Pages = ["fdp_manual.md"]
Depth = 3
```

Note that data products are processed and downloaded at the point of initialisation, provided that a `data_config` file is specified, and the `offline_mode` option is not used.


## Managing code runs

```@docs
initialise
finalise
```

## Reading data

```@docs
read_array
read_table
read_estimate
read_distribution
link_read
```

## Writing to the Data Registry

The process of registering objects such as data, code, and model runs, in the main Data Registry involves two steps; [local] registration, and then committing registered objects to the main online Registry.

### Registering data

```@docs
write_array
write_table
write_estimate
write_distribution
link_write
```

### Raising issues

```@docs
raise_issue
```

## What's my file?

```@docs
whats_my_file
registry_audit
```

## Index
```@index
Pages = ["fdp_manual.md"]
```
