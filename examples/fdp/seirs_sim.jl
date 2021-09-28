### SEIRS model example
using DataPipeline
using DataPipeline.SeirsModel
using CSV
using DataFrames
using Plots

# ENV["FDP_CONFIG_DIR"] = "/var/folders/0f/fj5r_1ws15x4jzgnm27h_y6h0000gr/T/tmpnq2t4wqy/data_store/jobs/2021-09-27_16_53_43_149467"

# Initialise code run
config_file = joinpath(ENV["FDP_CONFIG_DIR"], "config.yaml")
submission_script = joinpath(ENV["FDP_CONFIG_DIR"], "script.sh")
handle = initialise(config_file, submission_script)

# Read model parameters
path = link_read!(handle, "SEIRS_model/parameters")
static_params = CSV.read(path, DataFrames.DataFrame)

alpha = getparameter(static_params, "alpha")
beta = getparameter(static_params, "beta")
inv_gamma = getparameter(static_params, "inv_gamma")
inv_omega = getparameter(static_params, "inv_omega")
inv_mu = getparameter(static_params, "inv_mu")
inv_sigma = getparameter(static_params, "inv_sigma")

# Set initial state
timesteps = 1000
years = 5
initial_state = Dict("S" => 0.999, "E" => 0.001, "I" => 0, "R" => 0)

# Run the model
results = modelseirs(initial_state, timesteps, years, alpha, beta, 
                                  inv_gamma, inv_omega, inv_mu, inv_sigma);

g = plotseirs(results);

# Save outputs to data store
path = link_write!(handle, "model_output")
CSV.write(path, results)

path = link_write!(handle, "figure")
savefig(g, path)

# Register code run in local registry
finalise(handle)
