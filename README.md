# DataPipeline.jl
**The [FAIR Data Pipeline][dp_docs] in Julia**

[![dev docs][docs-dev-img]][docs-dev-url]
![Package tests](https://github.com/FAIRDataPipeline/DataPipeline.jl/workflows/Tests/badge.svg)
[![JuliaNightly][nightly-img]][nightly-url]
[![Zenodo][zenodo-badge]][zenodo-url]

## Features
- Conveniently download Data Products from the [SCRC Data Registry](https://data.scrc.uk/).
- File hash-based version checking: new data is downloaded only when necessary.
- A SQLite layer for convenient pre-processing (typically aggregation, and the joining of disparate datasets based on common identifiers.)
- Easily register model code or realisations (i.e. 'runs') with a single line of code.

## Installation

The package is now registered with General and can be added via the package manager Pkg. From the REPL type `]` to enter Pkg mode and run:

```
pkg> add DataPipeline
```

## Usage

See the [package documentation][docs] for instructions and examples.

[docs]: https://fairdatapipeline.github.io/DataPipeline.jl/stable/

[dp_docs]: https://fairdatapipeline.github.io/docs/introduction/

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://fairdatapipeline.github.io/DataPipeline.jl/dev/

[nightly-img]: https://github.com/FAIRDataPipeline/DataPipeline.jl/actions/workflows/nightly.yaml/badge.svg
[nightly-url]: https://github.com/FAIRDataPipeline/DataPipeline.jl/actions/workflows/nightly.yaml

[zenodo-badge]: https://zenodo.org/badge/302237736.svg
[zenodo-url]: https://zenodo.org/badge/latestdoi/302237736
