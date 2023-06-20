### SEIRS model example
using DataPipeline
using DataPipeline.SeirsModel
using CSV
using DataFrames
using Plots

# Initialise code run
handle = initialise()

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

ENV["GKSwstype"]="100"
g = plotseirs(results);

# Save outputs to data store
path = link_write!(handle, "model_output")
CSV.write(path, results)

path = link_write!(handle, "figure")
savefig(g, path)

# Register code run in local registry
finalise(handle)
