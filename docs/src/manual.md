# Package manual
```@contents
Pages = ["manual.md"]
Depth = 3
```

## Reading / downloading data

### Downloading data products

Note that data products are processed and downloaded at the point of initialisation, provided that a `data_config` file is specified, and the `offline_mode` option is not used.

```@docs
initialise_local_registry
```

### Reading data

```@docs
read_estimate
read_array
read_table
read_data_product_from_file
```

## Writing to the Data Registry

The process of registering objects such as data, code, and model runs in the main Data Registry

### Registering objects locally

```@docs
register_data_product
register_text_file
register_github_model
register_model_run
```

### Committing to the main Registry

Note that 'staged' objects (i.e. registered locally) can be committed all at once, or one at a time using the identifiers yielded by the above function calls, e.g. `register_data_product`.

```@docs
registry_commit_status
commit_all
```

```@docs
commit_staged_data_product
commit_staged_model
commit_staged_run
```

## Other

```@docs
whats_my_file
registry_audit
```

## Index
```@index
```
