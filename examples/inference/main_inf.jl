####  Introduction  ####
# Here, we demonstrate an inference workflow based on the
# SCRC Data Registry. The first stage of the workflow illustrates:
# - how to read data products from the DR,
# - utilise them in a simple inference model
# - register model code releases,
# - register model runs,
# - and register/upload the corresponding output as 'data products'
#
# The second stage of the workflow demonstrates:
# - how to 'read back' the data products as inputs for a different model
# - repeat the above process, i.e. register the code, runs and output
#
# The third stage involves a hypothetical scenario in which the
# *original* data product is flagged as problematic. That involves:
# - registering an issue with the data in the Registry
# - 'auditing' the [in this case] data product to trace affected objects
#
# Steps:                                                    Code:
# 1. preliminaries                                          L24
# 2. config files and scripts                               L32
# 3. read data products from the DR                         L43
# 4. run model simulation                                   L65
# 4b. automatic data access logging                         L103
# 5. stage 'code repo release' (i.e. model code)            L107
# 6. stage model 'code run'                                 L111
# 7. commit staged objects to the Registry                  L133
#
# Author:   Martin Burke (martin.burke@bioss.ac.uk)
# Date:     24-Jan-2021
# UPDATED:  7-Feb-2021
# NB. THIS CODE AND EXAMPLE IS NOW OBSOLETE DUE TO UNDERLYING PIPELINE CHANGES c. April 2021
# PLEASE SEE: examples/simple/main.jl instead
#### #### #### #### ####


### 1. prelim: import packages ###
import DataPipeline    # pipeline stuff
import DiscretePOMP         # simulation of epidemiological models
import YAML                 # for reading model config file
import Random               # other assorted packages used incidentally
import DataFrames


### 2. specify config files, scripts and data directory ###
# these determine the model configuration;
# data products to be downloaded; and the directory
# where the downloaded files are to be saved.
model_config = "examples/simple/model_config.yaml"
data_config = "examples/simple/data_config.yaml"
data_dir = "examples/simple/data/"
data_log = string(data_dir, "log.yaml")
submission_script = "julia examples/simple/main.jl"


### 3. download data products ###
# here we read some epidemiological parameters from the DR,
# so we can use them to run an SEIR simulation in step 5.

## process data config file and return connection to SQLite db
# i.e. download data products
db = DataPipeline.fetch_data_per_yaml(data_config, data_dir, auto_logging=false, verbose=false)

# NB. this function can now be rerun later in 'offline_mode' to fetch the already downloaded data
db = DataPipeline.fetch_data_per_yaml(data_config, data_dir, auto_logging=true, offline_mode=true)

## display parameter search
# NB. based on *downloaded* data products
sars_cov2_search = "human/infection/SARS-CoV-2/"
sars_cov2 = DataPipeline.read_estimate(db, sars_cov2_search)
println("\n search: human/infection/SARS-CoV-2/* := ", DataFrames.first(sars_cov2, 6),"\n")

## read some parameters and convert from hours => days
inf_period_days = DataPipeline.read_estimate(db, "human/infection/SARS-CoV-2/", "infectious-duration", key="value", data_type=Float64)[1] / 24
lat_period_days = DataPipeline.read_estimate(db, "human/infection/SARS-CoV-2/", "latent-period", key="value", data_type=Float64)[1] / 24


### 4. run model simulation ###
# here we run a simple SEIR simulation based on the
# downloaded parameters* and plot the results
# * however note that the population size and contact
# parameter beta (as well as the random seed) are read
# instead from the model_config file.

## read constants from model config file
mc = YAML.load_file(model_config)
const p = mc["initial_s"]   # population size
const t = mc["max_t"]       # simulation time
const beta = mc["beta"]     # nb. contact rate := beta SI / N
# NB. this is equivalent to:
# const p = 1000
# const t = 180.0
# const beta = 0.7

## set RNG random seed
Random.seed!(mc["random_seed"])
# Random.seed!(1)

## define a vector of simulation parameters
theta = [beta, inf_period_days^-1, lat_period_days^-1]

## initial system state variable [S E I R]
initial_condition = [p - 1, 0, 1, 0]

## generate DiscretePOMP model (see https://github.com/mjb3/DiscretePOMP.jl)
model = DiscretePOMP.generate_model("SEIR", initial_condition, freq_dep=true)

## run simulation and plot results
x = DiscretePOMP.gillespie_sim(model, theta, tmax=t)
println(DiscretePOMP.plot_trajectory(x))
# println(" observations: ", x.observations, "\n")      # uncomment to display
# println(" final system state: ", x.population[end])   # simulated observations
                                                        # and final systen state

### 4b. automatic data access logging
# - NB. *optionally* specify the filepath to print a copy
DataPipeline.finish_data_log(db; filepath=data_log)

### 5. stage model code ###

## SCRC access token - request via https://data.scrc.uk/docs/
# an access token is required if you want to *write* to the
# DR (e.g. register model code / runs) but not necessary if you
# only want to *read* from the DR (e.g. download data products)
include("access-token.jl")
# NB. format: scrc_access_tkn = "token [insert token here (without '[]')]"

## 'stage' model-code-release registration
# NB. returns existing id if code repo is already staged
# code_release_id = DataPipeline.register_github_model(model_config, scrc_access_tkn)
code_release_id = DataPipeline.register_github_model(db, model_config)


### 6. stage model run
# finally we register this particular simulation with
# the 'code_run' endpoint of the DR's RESTful API
# NB. 'inputs' and 'outputs' are currently a WIP
model_run_description = string(mc["model_name"], ": SEIR simulation.")
model_run_id = DataPipeline.register_model_run(db, code_release_id,
    model_config, submission_script, model_run_description)
# model_run_id = DataPipeline.register_model_run(model_config, submission_script,
#     code_release_id, model_run_description, scrc_access_tkn)


### 7. commit staged objects to the Registry
DataPipeline.registry_commit_status(db)
code_release_url = DataPipeline.commit_staged_model(db, code_release_id, scrc_access_tkn)
model_run_url = DataPipeline.commit_staged_run(db, model_run_id, scrc_access_tkn)
DataPipeline.registry_commit_status(db)
println("finished - model run registered as: ", model_run_url)
