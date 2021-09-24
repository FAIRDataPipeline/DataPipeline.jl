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
run(`cd ../..`)
run(`fair init --ci`)
run(`cd docs/build/`)
run(`fair pull ../../examples/fdp/SEIRSconfig.yaml`)
```

dsf

```@example
print(pwd())
run(`fair run ../../examples/fdp/SEIRSconfig.yaml`)
```