# SEIRS model example
This is the updated manual for the upcoming `FAIR` interfaced version of the Data Registry package.

```@example
print(pwd())
```

```@example
command = `ls`
run(command)
```

```@example
run(`fair init --ci`)
run(`fair pull examples/fdp/SEIRSconfig.yaml`)
```

dsf

```@example
run(`fair run examples/fdp/SEIRSconfig.yaml`)
```