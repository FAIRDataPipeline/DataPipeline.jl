### SEIRD model example
import BayesianWorkflows
import Distributions
import Random

Random.seed!(0)

## define model
function get_model()
    MODEL_NAME = "SEIRDs"
    N_EVENT_TYPES = 4
    # - discrete state space
    SUSCEPTIBLE = 1
    EXPOSED = 2
    INFECTIOUS = 3
    RECOVERED = 4
    DEATH = 5
    ALIVE = 1:4
    OBSERVED_STATES = [INFECTIOUS, DEATH]
    # - observation probabilities
    PROB_DETECTION_I = 0.6
    PROB_DETECTION_D = 0.95
    # - model parameters
    T_ZERO = 0  # I.E. NO INITIAL INFECTION TIME PARAMETER (ASSUME t0=0.0)
    CONTACT = 1
    LATENCY = 2
    RECOVER = 3
    BIRTH_DEATH = 4
    # - rate function
    function seird_rf(output, parameters::Vector{Float64}, population::Vector{Int64})
        output[1] = parameters[CONTACT] * population[SUSCEPTIBLE] * population[INFECTIOUS] / sum(population[ALIVE])
        output[2] = parameters[LATENCY] * population[EXPOSED]
        output[3] = parameters[RECOVER] * population[INFECTIOUS]
        output[4] = 2 * parameters[BIRTH_DEATH] * sum(population[ALIVE])
    end
    # - transition matrix and function
    tm = [-1 1 0 0 0; 0 -1 1 0 0; 0 0 -1 1 0]
    function transition!(population::Vector{Int64}, evt_type::Int64)
        if evt_type == 4        # birth/death:
            if rand(1:2) == 1   # birth
                population[SUSCEPTIBLE] += 1
            else                # death - sample population
                population[Distributions.wsample(population)] -= 1
                population[DEATH] += 1
            end
        else                    # disease model:
            population .+= tm[evt_type, :]
        end
    end
    # - initial condition
    fnic(parameters::Vector{Float64}) = [1000, 0, 10, 0, 0]
    # - observation function
    function obs_fn!(y::BayesianWorkflows.Observation, population::Array{Int64,1}, parameters::Vector{Float64 })
        di = Distributions.Binomial(population[INFECTIOUS], PROB_DETECTION_I)
        dd = Distributions.Binomial(population[DEATH], PROB_DETECTION_D)
        y.val[OBSERVED_STATES] .= [rand(di), rand(dd)]
    end
    # - observation model
    function obs_model(y::BayesianWorkflows.Observation, population::Array{Int64,1}, theta::Array{Float64,1})
        d = Distributions.Binomial.(population[OBSERVED_STATES], [PROB_DETECTION_I, PROB_DETECTION_D])
        return Distributions.logpdf(Distributions.Product(d), y.val[OBSERVED_STATES])
    end
    # - construct model and return
    return BayesianWorkflows.DPOMPModel(MODEL_NAME, N_EVENT_TYPES, seird_rf, fnic, transition!, obs_model, obs_fn!, T_ZERO)
end

## simulate and return some 'observations'
function run_simulation()
    model = get_model()
    parameters = [0.04, 0.04, 0.02, 0.0002]
    x = BayesianWorkflows.gillespie_sim(model, parameters; tmax=1000.0, num_obs=30)
    println(BayesianWorkflows.plot_trajectory(x))
    return x.observations
end
run_simulation()
