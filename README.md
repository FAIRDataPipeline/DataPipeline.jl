# DataRegistryUtils.jl
A package for accessing data products listed within the SCRC data registry.

## Installation

The package is not registered and must be added via the package manager Pkg.
From the REPL type `]` to enter Pkg mode and run:

```
pkg> add https://github.com/ScottishCovidResponse/DataRegistryUtils.jl
```

## Usage

It is recommended to use a .yaml data configuration file to specify the data products to be downloaded. An example .yaml is given in the `examples` folder. Refer to https://data.scrc.uk/ for other data products available in the registry.

```
julia> using DataRegistryUtils
julia> ?fetch_data_per_yaml
```

NB. a complete working example is also given in the `examples` folder.

### Examples

For code snippets and examples, see the docs.
