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
print(pwd())
show(run(`fair init --ci`))
```

```@example
print(pwd())
read(`fair pull /home/runner/work/DataPipeline.jl/DataPipeline.jl/examples/fdp/SEIRSconfig.yaml`, String)
```

dsf

```@example
show(run(`fair run /home/runner/work/DataPipeline.jl/DataPipeline.jl/examples/fdp/SEIRSconfig.yaml`))
```
