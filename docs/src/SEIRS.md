# SEIRS model example

The package ships a worked example in `examples/fdp/`: an SEIRS epidemic model
whose one input, its parameter table, and two outputs, a results table and a
figure, are tracked by the FAIR Data Pipeline. It is the example the package's
own tests are built on.

## The user config

`examples/fdp/SEIRSconfig.yaml` is the config handed to `fair`. Its
`register:` block names the parameter table as an external object, so
`fair pull` downloads and registers it; its `write:` block declares the two
outputs; and `run_metadata.script` is the command `fair run` executes.

```@example seirs
using DataPipeline
example = joinpath(pkgdir(DataPipeline), "examples", "fdp")
print(read(joinpath(example, "SEIRSconfig.yaml"), String))
```

## The model script

`examples/fdp/seirs_sim.jl` brackets the model with the API: `DataPipeline.initialise`
opens a code run from the working config `fair run` wrote, `link_read!` gives
the path of the parameter table and records it as an input, `link_write!`
gives a path for each output and records it, and `DataPipeline.finalise` names the output
files by their hash, registers them, and attaches everything to the code run.

```@example seirs
print(read(joinpath(example, "seirs_sim.jl"), String))
```

## Running it

With the pipeline installed and a local registry running (see the
[FAIR Data Pipeline documentation](https://www.fairdatapipeline.org/docs/)),
from the root of a clone of this repository:

```sh
fair init
fair pull examples/fdp/SEIRSconfig.yaml
fair run examples/fdp/SEIRSconfig.yaml
```

`fair run` ends by printing the URL of the registered code run. `fair add`
with that run's uuid, then `fair push`, sends it and its data products to a
remote registry.

The two blocks below do exactly that, through `DataPipeline.fair"..."`,
which runs the CLI from Julia with its arguments as on the command line, when
this documentation is built with the
environment variable `FDP_DOCS_RUN_EXAMPLE` set to `true` and a registry
running, as the package's own documentation build does; built without it,
they only say so.

```@example seirs
run_example = get(ENV, "FDP_DOCS_RUN_EXAMPLE", "") == "true"
run_example || println("Not run: FDP_DOCS_RUN_EXAMPLE is not set.")
# fair runs from the root of the repository, where the project is
run_example && cd(pkgdir(DataPipeline)) do
    DataPipeline.fair"pull --local examples/fdp/SEIRSconfig.yaml"
end
nothing # hide
```

```@example seirs
run_example && cd(pkgdir(DataPipeline)) do
    DataPipeline.fair"run --local examples/fdp/SEIRSconfig.yaml"
end
nothing # hide
```

## Rehearsing it

Before a run is recorded, the script can be rehearsed: run through the
pipeline from the same config, reading the registered parameter table and
writing its outputs, with nothing registered. From the root of the clone, in
Julia:

```julia
using DataPipeline
DataPipeline.rehearse("examples/fdp/SEIRSconfig.yaml", local_only = true)
include("examples/fdp/seirs_sim.jl")
```

`rehearse` has `fair` prepare the job as a run would, and the script, unchanged,
opens a rehearsal in its `DataPipeline.initialise` and ends by collecting its
two outputs in a folder, whose path `DataPipeline.finalise` prints and
returns. Run after the recorded run above, it finds the results table
registered already with the same bytes, and says so. The block below does
this under the same condition as the two above.

```@example seirs
run_example && cd(pkgdir(DataPipeline)) do
    DataPipeline.rehearse("examples/fdp/SEIRSconfig.yaml", local_only = true)
    include(joinpath(example, "seirs_sim.jl"))
end
nothing # hide
```
