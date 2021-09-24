# SEIRS model example
This is the updated manual for the upcoming `FAIR` interfaced version of the Data Registry package.

```@example
print(pwd())
```

```@example
run(`cd /home/runner/work/DataPipeline.jl/DataPipeline.jl`)
run(`fair init --ci`)
run(`cd docs/build/`)
run(`fair pull ../../examples/fdp/SEIRSconfig.yaml`)
```

dsf

```@example
run(`fair run ../../examples/fdp/SEIRSconfig.yaml`)
```