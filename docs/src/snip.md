# Code snippets

```@contents
Pages = ["snip.md"]
Depth = 3
```

## Getting started - package installation

The package is not currently registered and must be added via the package manager Pkg. From the REPL type `]` to enter Pkg mode and run:

```
pkg> add https://github.com/ScottishCovidResponse/DataPipeline.jl
```

```  julia
using DataPipeline
?fetch_data_per_yaml
```

## Usage

It is recommended to use a *.yaml* data configuration file to specify the data products to be downloaded. Some example *.yaml* file are included in the `examples` folder. Refer to https://data.scrc.uk/ for information about other data products available in the registry.

### Example: refreshing (i.e. downloading) data

``` julia
TEST_FILE = "examples/data_config.yaml"
DATA_OUT = "out/"
data = DataPipeline.fetch_data_per_yaml(TEST_FILE, DATA_OUT)
```

The results referenced by the `data` variable is a SQLite file databased, containing records of downloaded data products, components, and so on. They can be accessed thusly:

### Example: reading key-value pairs, e.g. point estimates

``` julia
data_product = "human/infection/SARS-CoV-2/infectious-duration"
comp_name = "infectious-duration"
# by data product
est = DataPipeline.read_estimate(data, data_product)
# by component name
est = DataPipeline.read_estimate(data, data_product, comp_name)
```

### Example: reading arrays

``` julia
data_product = "records/SARS-CoV-2/scotland/cases_and_management"
comp_name = "/test_result/date-cumulative"
## read array by dp:
some_arrays = DataPipeline.read_array(data, data_product)
one_array = some_arrays[comp_name]
## read array by component name:
one_array = DataPipeline.read_array(data, data_product, comp_name)
```

### Example: reading tables
``` julia
data_product = "geography/scotland/lookup_table"
comp_name = "/conversiontable/scotland"
tbl = DataPipeline.read_table(data, data_product, comp_name)
```

### Example: reading data products from file

You can also use the package to read in a file that has already been downloaded, as follows:

``` julia
fp = "/path/to/some/file.h5"
dp = DataPipeline.read_data_product_from_file(fp, use_axis_arrays = true, verbose = false)
component = dp["/conversiontable/scotland"]
```

### Example: custom SQL query

Data can also be queried using SQL for convenient joining and aggregation. For example:

``` julia
using SQLite, DataFrames
db = DataPipeline.read_data_product(fp, use_sql = true)
x = DBInterface.execute(data, "SELECT * FROM data_product") |> DataFrame
```

### What's my file?

Sometimes you need to know if a file (or directory of files,) is registered in the Data Registry. This can be accomplished using the `whats_my_file` function. For example:

``` julia
DataPipeline.whats_my_file("path/to/some/file/or/directory")
```
