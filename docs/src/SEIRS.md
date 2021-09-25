# SEIRS model example
This is the updated manual for the upcoming `FAIR` interfaced version of the Data Registry package.

```@example
print(pwd())
```

```@example
show(run(`ls`))
```

```@example
cd("/home/runner/work/DataPipeline.jl/DataPipeline.jl")
run(`fair init --ci`)
```

```@example
print(pwd())
```

```@example
run(`fair pull ../../examples/fdp/SEIRSconfig.yaml`)
```

dsf

```@example
run(`fair run ../../examples/fdp/SEIRSconfig.yaml`)
```