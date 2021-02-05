# Simple example

##  Introduction
Here, we use a simplistic example to demonstrate use of the package to interact with the SCRC Data Registry (DR) in a process referred to as the 'pipeline', including:
- How to read data products from the DR,
- utilise them in a simple simulation model,
- register the simulation model code with the DR,
- and register the simulation model run with the DR.

The example is also provided as working code (including the accompanying configuration files) in the *examples/simple* directory of the package repository. The steps and the corresponding line of code in that module are:

| Steps                                                     | Code  |
|:---------------------------------------------------------:|:-----:|
| 1. Preliminaries                                          | L22   |
| 2. Config files and scripts                               | L30   |
| 3. Register 'code repo release' [model code] in the DR    | L40   |
| 4. Read data products from the DR                         | L54   |
| 5. Run model simulation                                   | L73   |
| 6. Register model 'code run' in the DR                    | L110  |

## 0. Package installation

The package is not currently registered and must be added via the package manager Pkg. From the REPL type `]` to enter Pkg mode and run:

```
pkg> add https://github.com/ScottishCovidResponse/DataRegistryUtils.jl
```

## 1. Preliminaries: import packages

``` julia
import DataRegistryUtils    # pipeline stuff
import DPOMPs               # simulation of epidemiological models
import YAML                 # for reading model config file
import Random               # other assorted packages used incidentally
import DataFrames
```

## 2. Specify config files, scripts and data directory
These variables and the corresponding files determine the model configuration; data products to be downloaded; and 'submission script' (see 2c.)

``` julia
model_config = "/examples/simple/model_config.yaml"     # (see 2a)
data_config = "/examples/simple/data_config.yaml"       # (see 2b)
submission_script = "julia examples/simple/main.jl"     # (see 2c)
```
### 2a. The *model_config.yaml* file
The **'model config'** file concept is used throughout the SCRC data pipeline, (i.e. not just within this package.) In this example, it is used to store information about both the model code (step 3,) and the individual code run (step 6.) The example below is also given [here]("https://raw.githubusercontent.com/ScottishCovidResponse/DataRegistryUtils.jl/main/examples/simple/data_config.yaml").

``` yaml
# model
model_name: "DRU simple example"
model_repo: "https://github.com/ScottishCovidResponse/DataRegistryUtils.jl"
# NB. ^ because the example is part of this package - replace with your own repo
model_version: "0.0.4"
model_description: "A simple SEIR simulation for demonstrating use of the DataRegistryUtils.jl package."
model_website: "https://mjb3.github.io/DiscretePOMP.jl/stable/"

# simulation parameters
random_seed: 1
initial_s: 1000   # initial population size
max_t: 180.0      # simulation time
beta: 0.7         # contact rate := beta SI / N
```

### 2b. The *data_config.yaml* file
Similar to the model configuration file, **'data config'** files are a standard way to interact with the data pipeline, including in other languages besides `Julia`. This example specifies the Data Products that are downloaded in step 4:

``` yaml
fail_on_hash_mismatch: True     # set 'False' to suppress data mismatch errors
namespace: SCRC                 # default namespace

read:
  - where:
      data_product: human/infection/SARS-CoV-2/symptom-probability
      component: symptom-probability
  - where:
      data_product: prob_hosp_and_cfr/data_for_scotland
      component: cfr_byage
    use:
      namespace: EERA
  - where:
      data_product: human/infection/SARS-CoV-2/asymptomatic-period
      component: asymptomatic-period
  - where:
      data_product: human/infection/SARS-CoV-2/infectious-duration
      component: infectious-duration
  - where:
      data_product: human/infection/SARS-CoV-2/latent-period
      component: latent-period
  - where:
      data_product: fixed-parameters/T_hos
      component: T_hos
    use:
      namespace: EERA
  - where:
      data_product: fixed-parameters/T_rec
      component: T_rec
    use:
      namespace: EERA
```

### 2c. The *submission_script* variable
Finally, the `submission_script` variable is a string that contains the contents of the 'submission script' file; another artefact of the pipeline process that applies outwith the Julia package.

``` julia
submission_script = "julia examples/simple/main.jl"
```

Here it is used to define the 'entry point' of the application; together with the model code and 'config' files, it will allow others to reproduce our results in the future with ease and precision (an important benefit of the overall pipeline process.)

## 3. Registering model code ###

### 3a. SCRC access token - request via https://data.scrc.uk/docs/
An access token is required if you want to *write* to the DR (e.g. register model code / runs) but not necessary if you only want to *read* from the DR (e.g. download data products.)

The token must not be shared. Common approaches include the use of system variables or [private] configuration files. In this example I have included mine as a separate Julia file with a single line of code. *Note that it is important to also specify the .gitignore so as not to accidentally upload to the internet!*

``` julia
include("access-token.jl")
```

The variable itself looks like: `"token [my token]"`. For example, if the token is the numbers one through six, the access-token.jl file looks like this:

``` julia
const scrc_access_tkn = "token 123456"
```
### 3b. Register model code
Back in the main file, we handle model code [release] registration by calling a function that automatically returns the existing `code_repo_release` URI if it is already registered, or a new one if not.

``` julia
code_release_id = DataRegistryUtils.register_github_model(model_config, scrc_access_tkn)
```

Here we have used a .yaml configuration file but for illustration, the code is roughly equivalent to this:

``` julia
model_name = "DRU simple example"
model_repo = "https://github.com/ScottishCovidResponse/DataRegistryUtils.jl"
model_version = "0.0.1"
model_description = " ... " (nb. insert description)
model_docs = "https://mjb3.github.io/DiscretePOMP.jl/stable/"
code_release_id = DataRegistryUtils.register_github_model(model_name, model_version, model_repo, model_hash, scrc_access_tkn, model_description=model_description, model_website=model_docs)
```

Finally, the resulting URI is in the form:

``` julia
code_release_id := "https://data.scrc.uk/api/code_repo_release/2157/"
```

## 4. Downloading data products
Here we read some epidemiological parameters from the DR, so we can use them to run an **SEIR** simulation in **step (5)**. First we download some data, then read it.

### 4a. Download data
First, we process the `data_config` file, which (in this case) returns a variable representing a connection to a SQLite database. I.e. we download the data products:
``` julia
data_dir = "/examples/simple/data/" # local directory where data is to be stored
db = DataRegistryUtils.fetch_data_per_yaml(data_config, data_dir, use_sql=true)
```

### 4b. Read some data
Next, we read some parameters and convert them to the required units.

``` julia
inf_period_days = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "infectious-duration", key="value", data_type=Float64)[1] / 24
lat_period_days = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "latent-period", key="value", data_type=Float64)[1] / 24
```

See [Code snippets](@ref) and the [Package manual](@ref) for information about reading other types of data product.

## 5. Model simulation
**Step 5 relies on the use of another package: [DiscretePOMP.jl](https://github.com/mjb3/DiscretePOMP.jl), so you may wish to skip this section or replace it with, e.g. your own model or simulation code.**

Next, *for illustration purposes only* we run a simple **SEIR** simulation using the Gillespie simulation feature of the `DiscretePOMP.jl` package. We use the downloaded parameters* as inputs, and finally plot the results as a time series of the population as they migrate between states according to the stochastic dynamics of the model.

First we extract some information about the model run from the `model_config.yaml` file:

``` julia
mc = YAML.load_file(model_config)
p = mc["initial_s"]   # population size
t = mc["max_t"]       # simulation time
beta = mc["beta"]     # nb. contact rate := beta SI / N
Random.seed!(mc["random_seed"])
```

These include the population size and contact parameter beta, as well as the random seed. We are then ready the generate a DiscretePOMP model:

``` julia
## define a vector of simulation parameters
theta = [beta, inf_period_days^-1, lat_period_days^-1]
## initial system state variable [S E I R]
initial_condition = [p - 1, 0, 1, 0]
## generate DPOMPs model (see https://github.com/mjb3/DiscretePOMP.jl)
model = DiscretePOMP.generate_model("SEIR", initial_condition, freq_dep=true)
```

Finally, we run the simulation and plot the results:

``` julia
x = DiscretePOMP.gillespie_sim(model, theta, tmax=t)
println(DiscretePOMP.plot_trajectory(x))
```

## 6. Registering a 'model run'
Lastly, we register the results of this particular simulation by POSTing to the `code_run` endpoint of the DR's RESTful API:

``` julia
model_run_description = "Just another SEIR simulation."
model_run_id = DataRegistryUtils.register_model_run(model_config, submission_script, code_release_id, model_run_description, scrc_access_tkn)
```

## Finished!

That concludes the example. A complete working example of this code can be found [here](https://github.com/ScottishCovidResponse/DataRegistryUtils.jl/tree/main/examples/simple).

Please note that certain features, notably the registration of Data Products (i.e. model 'inputs' and 'outputs') is currently still a work in progress. See the home page for more information.
