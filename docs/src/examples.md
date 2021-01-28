# Simple example

##  Introduction
Here, we use a simplistic example to demonstrate use of the package to interact with the SCRC Data Registry (DR) in a process referred to as the 'pipeline', including:
- How to read data products from the DR,
- utilise them in a simple simulation model,
- register model code releases,
- and register model runs.

The example is also provided as working code (including the accompanying configuration files) in the *examples/simple* directory of the package repository. The steps and the corresponding line of code in that module are:

| Steps                                                     | Code  |
|:---------------------------------------------------------:|:-----:|
| 1. Preliminaries                                          | L22   |
| 2. Config files and scripts                               | L30   |
| 3. Register 'code repo release' [model code] in the DR    | L40   |
| 4. Read data products from the DR                         | L66   |
| 5. Run model simulation                                   | L85   |
| 6. Register model 'code run' in the DR                    | L122  |

```@repl 1
wrkd = "/media/martin/storage/projects/AtomProjects/DataRegistryUtils.jl"; # hide
```

## 1. Preliminaries: import packages

```@repl 1
import DataRegistryUtils    # pipeline stuff
import DPOMPs               # simulation of epidemiological models
import YAML                 # for reading model config file
import Random               # other assorted packages used incidentally
import DataFrames
```

## 2. Specify config files, scripts and data directory
These variables and the corresponding files determine the model configuration; data products to be downloaded; and the local directory where the downloaded files are to be saved.

```@repl 1
model_config = string(wrkd, "/examples/simple/model_config.yaml");
data_config = string(wrkd, "/examples/simple/data_config.yaml");
data_dir = string(wrkd, "/examples/simple/data/");
submission_script = "julia examples/simple/main.jl";
```

## 3. Registering model code ###

### SCRC access token - request via https://data.scrc.uk/docs/
An access token is required if you want to *write* to the DR (e.g. register model code / runs) but not necessary if you only want to *read* from the DR (e.g. download data products.)

The token must not be shared. Common approaches include the use of system variables or [private] configuration files. In this example I have included mine as a separate Julia file with a single line of code. *Note that it is important to also specify the .gitignore so as not to accidentally upload to the internet!*

```
julia> include("access-token.jl")
```


Allowing that the token is the numbers one through six, the access-token.jl file looks like this:

```
const scrc_access_tkn = "token 123456"
```

Back in the main file, we handle model code [release] registration by calling a function that automatically returns the existing *CodeRepoRelease* URI if it is already registered, or a new one if not.

```
julia> code_release_id = DataRegistryUtils.register_github_model(model_config, scrc_access_tkn)
```

Here we have used a .yaml configuration file but for illustration, the code is roughly equivalent to this:

```
model_name = "DRU simple example"
model_repo = "https://github.com/ScottishCovidResponse/DataRegistryUtils.jl"
model_version = "0.0.1"
model_description = " ... " (nb. insert description)
model_docs = "https://mjb3.github.io/DPOMPs.jl/stable/"
code_release_id = DataRegistryUtils.register_github_model(model_name, model_version, model_repo, model_hash, scrc_access_tkn, model_description=model_description, model_website=model_docs)
```

Finally, the resulting URI is in the form:

```
code_release_id := "https://data.scrc.uk/api/code_repo_release/2157/"
```


## 4. Downloading data products
Here we read some epidemiological parameters from the DR, so we can use them to run an **SEIR** simulation in **step (5)**.

First, we process data config file and return a connection to the SQLite database. I.e. we download the data products:
```@repl 1
db = DataRegistryUtils.fetch_data_per_yaml(data_config, data_dir, use_sql=true, verbose=false)
```

Next, we read some parameters and convert them to the required units.

```@repl 1
inf_period_days = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "infectious-duration", data_type=Float64)[1] / 24
lat_period_days = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "latent-period", data_type=Float64)[1] / 24
```

## 5. Model simulation
Now we run a brief **SEIR** simulation using the Gillespie simulation feature of the DPOMPs.jl package. We use the downloaded parameters* as inputs, and finally plot the results as a time series of the population compartments.

First we process the model config .yaml file:

```@repl 1
mc = YAML.load_file(model_config)
p = mc["initial_s"]   # population size
t = mc["max_t"]       # simulation time
beta = mc["beta"]     # nb. contact rate := beta SI / N
Random.seed!(mc["random_seed"])
```

* Note that the population size and contact parameter beta (as well as the random seed) are read from the *model_config.yaml* file instead.

We are then ready the generate a DPOMP model:

```@repl 1
## define a vector of simulation parameters
theta = [beta, inf_period_days^-1, lat_period_days^-1]
## initial system state variable [S E I R]
initial_condition = [p - 1, 0, 1, 0]
## generate DPOMPs model (see https://github.com/mjb3/DPOMPs.jl)
model = DPOMPs.generate_model("SEIR", initial_condition, freq_dep=true)
```

Finally, we run the simulation and plot the results:

```@repl 1
x = DPOMPs.gillespie_sim(model, theta, tmax=t)
println(DPOMPs.plot_trajectory(x))
```

## 6. Registering a 'model run'
Lastly, we register the results of this particular simulation by POSTing to the **CodeRun** endpoint of the DR's RESTful API:

```
julia> model_run_description = "Just another SEIR simulation."
julia> model_run_id = DataRegistryUtils.register_model_run(model_config, submission_script,
    code_release_id, model_run_description, scrc_access_tkn)
```

## Finished!

That concludes the example. Please note however that the registration of Data Products (notably, model 'inputs' and 'outputs') is currently a WIP, along with certain other planned features. See the home page for more information.
