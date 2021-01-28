# Code snippets

## Getting started - package installation

The package is not currently registered and must be added via the package manager Pkg. From the REPL type `]` to enter Pkg mode and run:

```
pkg> add https://github.com/ScottishCovidResponse/DataRegistryUtils.jl
```

## Usage

It is recommended to use a .yaml data configuration file to specify the data products to be downloaded. An example .yaml is given in the `examples` folder. Refer to https://data.scrc.uk/ for other data products available in the registry.

``` @repl 1
using DataRegistryUtils
?fetch_data_per_yaml
```

NB. a complete working example of this code is also provided in the `examples` folder.

### Example: refesh data

```
julia> TEST_FILE = "examples/data_config.yaml"
julia> DATA_OUT = "out/"
julia> data = DataRegistryUtils.fetch_data_per_yaml(TEST_FILE, DATA_OUT, use_axis_arrays=true, verbose=false)
```

The results referenced by the `data` variable are a `Dict` of data products, indexed by data product name, component name, and so on. They can be accessed thusly:

### Example: access data product by name

```
julia> data_product = data["human/infection/SARS-CoV-2/symptom-delay"]
julia> component = data_product["symptom-delay"]
julia> component_type = component["type"]
julia> distribution_name = component["distribution"]
```

### Example: read individual HDF5 or TOML file

You can also use the package to read in a file that has already been downloaded, as follows:

```
julia> fp = "/path/to/some/file.h5"
julia> dp = DataRegistryUtils.read_data_product_from_file(fp, use_axis_arrays = true, verbose = false)
julia> component = dp["/conversiontable/scotland"]
```

### Example: read data as SQLite connection

Data can be staged using SQLite and returned as an active connection to a file database for querying and aggregation. For example:

```
julia> using SQLite, DataFrames
julia> db = DataRegistryUtils.read_data_product(fp, use_sql = true)
julia> x = DBInterface.execute(db, "SELECT * FROM data_product") |> DataFrame
```
