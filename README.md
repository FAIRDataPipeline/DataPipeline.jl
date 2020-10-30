# DataRegistryUtils.jl
A package for accessing data products listed within the SCRC data registry.

## Installation

The package is not registered and must be added via the package manager Pkg.
From the REPL type `]` to enter the Pkg mode and run:

```
pkg> add https://github.com/mjb3/DataRegistryUtils.jl
```

## Usage

It is recommended to use a .yaml configuration file. An example is given in the `examples` folder.

### Example: refesh data

```
julia> TEST_FILE = "/home/martin/AtomProjects/DataRegistryUtils.jl/examples/data_config.yaml"
julia> DATA_OUT = "/home/martin/AtomProjects/DataRegistryUtils.jl/out/"
julia> data = DataRegistryUtils.fetch_data_per_yaml(TEST_FILE, DATA_OUT, false)
```

### Example: access data product by name

```
julia> data_product = data["human/infection/SARS-CoV-2/symptom-delay"]
julia> component = ["symptom-delay"]
julia> distribution_name = component["distribution"]
```

NB. a complete working example is also given in the `examples` folder.
