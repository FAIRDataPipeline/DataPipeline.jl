### SEIRD model simulation example
import DataPipeline
import BayesianWorkflows
import Distributions
import Random

Random.seed!(0)

## so that we have something to read from the DR later
function pre_example()
    ## initialise code run
    wc = "examples/fdp/working_config0.yaml"
    handle = DataPipeline.initialise(wc)
    ## write some data to read in later
    DataPipeline.write_estimate(handle, 0.003, "example/estimate/contact-parameter", "contact-parameter")
    DataPipeline.write_estimate(handle, 5.0, "example/estimate/asymptomatic-period", "asymptomatic-period")
    DataPipeline.write_estimate(handle, 8.0, "example/estimate/recovery-period", "recovery-period")
    DataPipeline.write_estimate(handle, 0.0004, "example/estimate/mortality-rate", "mortality-rate")
    ## finalise code run
    DataPipeline.finalise(handle)
end

## define model
function get_model()
    MODEL_NAME = "SEIRD"
    N_EVENT_TYPES = 4
    # - discrete state space
    SUSCEPTIBLE = 1
    EXPOSED = 2
    INFECTIOUS = 3
    RECOVERED = 4
    DEATH = 5
    OBSERVED_STATES = [INFECTIOUS, DEATH]
    # - observation probabilities
    PROB_DETECTION_I = 0.6
    PROB_DETECTION_D = 0.95
    # - model parameters
    T_ZERO = 0  # I.E. NO INITIAL INFECTION TIME PARAMETER (ASSUME t0=0.0)
    CONTACT = 1
    ASYMPT = 2
    RECOVER = 3
    MORTALITY = 4
    # - rate function
    function seird_rf(output, parameters::Array{Float64, 1}, population::Array{Int64, 1})
        output[1] = parameters[CONTACT] * population[SUSCEPTIBLE] * population[INFECTIOUS]
        output[2] = 1 / parameters[ASYMPT] * population[EXPOSED]
        output[3] = 1 / parameters[RECOVER] * population[INFECTIOUS]
        output[4] = parameters[MORTALITY] * population[INFECTIOUS]
    end
    # - transition matrix and function
    tm = [-1 1 0 0 0; 0 -1 1 0 0; 0 0 -1 1 0; 0 0 -1 0 1]
    fnt = BayesianWorkflows.generate_trans_fn(tm)
    # - initial condition
    fnic() = [1000, 0, 10, 0, 0]
    # - observation function
    function obs_fn!(y::BayesianWorkflows.Observation, population::Array{Int64,1}, parameters::Array{Float64,1})
        di = Distributions.Binomial(population[INFECTIOUS], PROB_DETECTION_I)
        dd = Distributions.Binomial(population[DEATH], PROB_DETECTION_I)
        y.val[OBSERVED_STATES] .= [rand(di), rand(dd)]
    end
    # - observation model
    # obs_model = BayesianWorkflows.partial_gaussian_obs_model(2.0; seq = 3)
    function obs_model(y::BayesianWorkflows.Observation, population::Array{Int64,1}, theta::Array{Float64,1})
        d = Distributions.Binomial.(population[OBSERVED_STATES], [PROB_DETECTION_I, PROB_DETECTION_D])
        return Distributions.logpdf(Distributions.Product(d), y.val[OBSERVED_STATES])
    end
    # - construct model and return
    return BayesianWorkflows.DPOMPModel(MODEL_NAME, N_EVENT_TYPES, seird_rf, fnic, fnt, obs_model, obs_fn!, T_ZERO)
end

## basic model run
function example()
    ## preliminaries
    pre_example()
    ## initialise code run
    wc = "examples/fdp/working_config1.yaml"
    handle = DataPipeline.initialise(wc)
    ## read some data:
    beta = DataPipeline.read_estimate(handle, "example/estimate/contact-parameter", "contact-parameter")
    asymp_prd = DataPipeline.read_estimate(handle, "example/estimate/asymptomatic-period", "asymptomatic-period")
    recov_prd = DataPipeline.read_estimate(handle, "example/estimate/recovery-period", "recovery-period")
    mortality = DataPipeline.read_estimate(handle, "example/estimate/mortality-rate", "mortality-rate")
    ## run simulation:
    parameters = [beta, asymp_prd, recov_prd, mortality]
    model = get_model()
    x = BayesianWorkflows.gillespie_sim(model, parameters)    # run simulation
    println(BayesianWorkflows.plot_trajectory(x))             # plot (optional)
    ## finalise code run
    DataPipeline.finalise(handle)
end

## whats_my_file example
# NB. 23/8/21 THIS IS NOW BROKEN DUE TO CHANGES TO THE DR SCHEMA ***********
function whats_my_example()
    some_filepath = "examples/simple2/data/martinburke/test/array"
    # some_filepath = "examples/simple/data/1e20f69b-c998-4048-a1ff-1543bb7f1a2c"
    ## run for this file only
    DataPipeline.whats_my_file(some_filepath)
    # - same again but display remote file path (can be messy)
    # DataPipeline.whats_my_file(some_filepath, show_path=true)
    # # - run for an entire directory
    # some_dir = "examples/simple/data/"
    # DataPipeline.whats_my_file(some_dir)
end

## run examples:
example()
# whats_my_example()
