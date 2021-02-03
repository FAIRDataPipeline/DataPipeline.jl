####  Introduction  ####
# Here, we use an example to show how to interact with the SCRC
# Data Registry (DR) including:
# - how to read data products from the DR,
# - utilise them in a simple simulation model
# - register model code releases
# - and register model runs.
#
# Steps:                                                    Code:
# 1. preliminaries                                          L22
# 2. config files and scripts                               L30
# 3. register 'code repo release' [model code] in the DR    L40
# 4. read data products from the DR                         L54
# 5. run model simulation                                   L73
# 6. register model 'code run' in the DR                    L110
#
# Author: Martin Burke (martin.burke@bioss.ac.uk)
# Date: 24-Jan-2021
#### #### #### #### ####


### 1. prelim: import packages ###
import DataRegistryUtils    # pipeline stuff
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
submission_script = "julia examples/simple/main.jl"


### 3. register model code ###

## SCRC access token - request via https://data.scrc.uk/docs/
# an access token is required if you want to *write* to the
# DR (e.g. register model code / runs) but not necessary if you
# only want to *read* from the DR (e.g. download data products)
include("access-token.jl")
# NB. format: scrc_access_tkn = "token [insert token here (without '[]')]"

## register model code release
# NB. returns existing URI if code repo is already registered
code_release_id = DataRegistryUtils.register_github_model(model_config, scrc_access_tkn)


### 4. download data products ###
# here we read some epidemiological parameters from the DR,
# so we can use them to run an SEIR simulation in step 5.

## process data config file and return connection to SQLite db
# i.e. download data products
db = DataRegistryUtils.fetch_data_per_yaml(data_config, data_dir, use_sql=true, verbose=false)

## display parameter search
# NB. based on *downloaded* data products
sars_cov2_search = "human/infection/SARS-CoV-2/%"
sars_cov2 = DataRegistryUtils.read_estimate(db, sars_cov2_search)
println("\n search: human/infection/SARS-CoV-2/* := ", DataFrames.first(sars_cov2, 6),"\n")

## read some parameters and convert from hours => days
inf_period_days = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "infectious-duration", data_type=Float64)[1] / 24
lat_period_days = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "latent-period", data_type=Float64)[1] / 24


### 5. run model simulation ###
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

### 6. register model run
# finally we register this particular simulation with
# the 'code_run' endpoint of the DR's RESTful API
# NB. 'inputs' and 'outputs' are currently a WIP
model_run_description = string(mc["model_name"], ": SEIR simulation.")
model_run_id = DataRegistryUtils.register_model_run(model_config, submission_script,
    code_release_id, model_run_description, scrc_access_tkn)

println("finished - model run registered as: ", model_run_id)
