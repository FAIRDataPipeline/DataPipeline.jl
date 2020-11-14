using Simulation
using Unitful
using Unitful.DefaultSymbols
using Simulation.Units
using Simulation.ClimatePref
using StatsBase
using Distributions
using AxisArrays
using DataFrames
using Plots

import DataRegistryUtils
import SQLite
# import JLD

## read in sample data
# function read_sample_data()
#     test_data = "examples/Array_example.jld"
#     sd = JLD.load(test_data, "pop_array")
#     println(typeof(sd))
# end
# read_sample_data()

## produce AxisArray with Unitful km units for the first two dimensions
function get_3d_km_grid_axis_array(cn::SQLite.DB, dims::Array{String,1}, msr::String, tbl::String)
    sel_sql = ""
    dim_ax = []
    for i in eachindex(dims)
        sel_sql = string(sel_sql, dims[i], ",")
        dim_st = SQLite.Stmt(cn, string("SELECT DISTINCT ", dims[i], " AS val FROM ", tbl, " ORDER BY ", dims[i]))
        dim_vals = SQLite.DBInterface.execute(dim_st) |> DataFrames.DataFrame
        av = i < 3 ? [(v)km for v in dim_vals.val] : dim_vals.val   # unit conversion
        push!(dim_ax, AxisArrays.Axis{Symbol(dims[i])}(av))
    end
    sel_sql = string("SELECT ", sel_sql, " SUM(", msr, ") AS val\nFROM ", tbl, "\nGROUP BY ", rstrip(sel_sql, ','))
    stmt = SQLite.Stmt(cn, sel_sql)
    df = SQLite.DBInterface.execute(stmt) |> DataFrames.DataFrame
    ## scottish population AxisArray
    axis_size = Tuple(Int64[length(d) for d in dim_ax])
    data = zeros(typeof(df.val[1]), axis_size)
    output = AxisArrays.AxisArray(data, Tuple(dim_ax))
    for row in eachrow(df)
        output[AxisArrays.atvalue(row[Symbol(dims[1])]km), AxisArrays.atvalue(row[Symbol(dims[2])]km), AxisArrays.atvalue(row[Symbol(dims[3])])] = row.val
    end
    return output
end

## WIP - new function for DR
function run_model_dr(times::Unitful.Time, interval::Unitful.Time, timestep::Unitful.Time; do_plot::Bool=false, do_download::Bool=true, save::Bool=false, savepath::String=pwd())
    ## process yaml, connect to results db
    yaml_config = "examples/data_config_sim.yaml"
    data_dir = "out/"
    view_sql = "examples/simulation_views.sql"
    db = DataRegistryUtils.fetch_data_per_yaml(yaml_config, data_dir, use_sql=true, sql_file=view_sql, verbose=false)

    ## 1) PREV. LINE 17: scottish population
    # - "human/demographics/population/scotland" : "grid1km/age/persons"
    # - nb. view defined by examples/simulation_views.sql
    stmt = SQLite.Stmt(db, "SELECT age_aggr, age_groups as example, SUM(val) as val FROM scottish_population_view GROUP BY age_aggr")
    scottish_pop_by_age_grp = SQLite.DBInterface.execute(stmt) |> DataFrames.DataFrame
    age_categories = DataFrames.nrow(scottish_pop_by_age_grp)
    println("\n1a) aggregate scottish_pop_by_age via custom view: ", age_categories, " distinct age cats, e.g. := ", DataFrames.first(scottish_pop_by_age_grp, 4))
    # - create AxisArray
    scotpop = get_3d_km_grid_axis_array(db, ["grid_x", "grid_y", "age_aggr"], "val", "scottish_population_view")
    print("\n1b) converting to AxisArray := ", typeof(scotpop))
    println(" - of size: ", size(scotpop))
    print("1c) e.g. access scottish_pop_aa[379km, 271km, 30] := ", scotpop[atvalue((379)km), atvalue((271)km), atvalue(30)])
    # - double check data
    chk = SQLite.Stmt(db, "SELECT sum(val) AS val FROM scottish_population_view WHERE grid_x=? AND grid_y=? AND age_aggr=?")
    chk_res = SQLite.DBInterface.execute(chk, (379, 271, 30)) |> DataFrames.DataFrame
    println(" - vs db data check: ", chk_res.val)

    ### Simulation.jl code block A ###
    # Set initial population sizes for all pathogen categories
    abun_v = DataFrame([
        (name="Environment", initial=0),
        (name="Force", initial=fill(0, age_categories)),
    ])
    numvirus = sum(length.(abun_v.initial))
    # Set population to initially have no individuals
    abun_h = DataFrame([
        (name="Susceptible", type=Susceptible, initial=fill(0, age_categories)),
        (name="Exposed", type=OtherDiseaseState, initial=fill(0, age_categories)),
        (name="Asymptomatic", type=Infectious, initial=fill(0, age_categories)),
        (name="Presymptomatic", type=Infectious, initial=fill(0, age_categories)),
        (name="Symptomatic", type=Infectious, initial=fill(0, age_categories)),
        (name="Hospitalised", type=OtherDiseaseState, initial=fill(0, age_categories)),
        (name="Recovered", type=Removed, initial=fill(0, age_categories)),
        (name="Dead", type=Removed, initial=fill(0, age_categories)),
    ])
    numclasses = nrow(abun_h)
    numstates = sum(length.(abun_h.initial))
    # Set up simple gridded environment
    area = (AxisArrays.axes(scotpop, 1)[end] + AxisArrays.axes(scotpop, 1)[2] -
        2 * AxisArrays.axes(scotpop, 1)[1]) *
        (AxisArrays.axes(scotpop, 2)[end] + AxisArrays.axes(scotpop, 2)[2] -
        2 * AxisArrays.axes(scotpop, 2)[1]) * 1.0
    # Sum up age categories and turn into simple matrix
    total_pop = dropdims(sum(Float64.(scotpop), dims=3), dims=3)
    total_pop = AxisArray(total_pop, AxisArrays.axes(scotpop)[1], AxisArrays.axes(scotpop)[2])
    total_pop.data[total_pop .≈ 0.0] .= NaN
    # Shrink to smallest bounding box. The NaNs are inactive.
    total_pop = shrink_to_active(total_pop);

    ## 2) PREV. LINE 57: read_estimate()
    # - specify data_type=Float64
    symptom_pr = DataRegistryUtils.read_estimate(db, "human/infection/SARS-CoV-2/%", "symptom-probability", data_type=Float64)
    println("\n2) read_estimate symptom_pr[1] := ", typeof(symptom_pr[1]), " : ", symptom_pr[1])

    ### Simulation.jl code  block B ###
    # Prob of developing symptoms
    p_s = fill(symptom_pr[1], age_categories)

    ## 3) PREV. LINE 63: read_table()
    # - equivalent to SELECT * FROM [.h5 table]
    param_tab = DataRegistryUtils.read_table(db, "prob_hosp_and_cfr/data_for_scotland", "cfr_byage")
    println("\n3) read_table cfr_byage table, e.g. := ", DataFrames.first(param_tab, 4))

    ### Simulation.jl code block C ###
    # Prob of hospitalisation
    p_h = param_tab.p_h[1:end-1] # remove HCW
    pushfirst!(p_h, p_h[1]) # extend age categories
    append!(p_h, fill(p_h[end], 2)) # extend age categories
    # Case fatality ratio
    cfr_home = param_tab.cfr[1:end-1]
    pushfirst!(cfr_home, cfr_home[1])
    append!(cfr_home, fill(cfr_home[end], 2))
    cfr_hospital = param_tab.p_d[1:end-1]
    pushfirst!(cfr_hospital, cfr_hospital[1])
    append!(cfr_hospital, fill(cfr_hospital[end], 2))
    @assert length(p_s) == length(p_h) == length(cfr_home)

    ## 4) PREV. LINE 79-112: various read_estimate()
    # - i.e. search: human/infection/SARS-CoV-2/*
    sars_cov2_search = "human/infection/SARS-CoV-2/%"
    sars_cov2 = DataRegistryUtils.read_estimate(db, sars_cov2_search)
    println("\n4) search: human/infection/SARS-CoV-2/* := ", DataFrames.first(sars_cov2, 6))

    ### Simulation.jl code block D ###
    # Time exposed
    T_lat = days(DataRegistryUtils.read_estimate(db, sars_cov2_search, "latent-period", data_type=Float64)[1]Unitful.hr)
    # Time asymptomatic
    T_asym = days(DataRegistryUtils.read_estimate(db, sars_cov2_search, "asymptomatic-period", data_type=Float64)[1]Unitful.hr)
    @show T_asym
    # Time pre-symptomatic
    T_presym = 1.5days
    # Time symptomatic
    T_sym = days(DataRegistryUtils.read_estimate(db, sars_cov2_search, "infectious-duration", data_type=Float64)[1]Unitful.hr) - T_presym
    # Time in hospital
    T_hosp = DataRegistryUtils.read_estimate(db, "fixed-parameters/%", "T_hos", data_type=Float64)[1]days
    # Time to recovery if symptomatic
    T_rec = DataRegistryUtils.read_estimate(db, "fixed-parameters/%", "T_rec", data_type=Float64)[1]days

    ## 5) EXTRA:
    # - nb. uses custom view defined in simulation_views.sql
    stmt = SQLite.Stmt(db, "SELECT * FROM pollution_grid_view")
    pollution_grid = SQLite.DBInterface.execute(stmt) |> DataFrames.DataFrame
    println("\n5) extra - pollution grid, e.g. := ", DataFrames.first(pollution_grid, 3))

    ### Final Simulation.jl code block ###
    println("\nrunning simulation:")
    # Exposed -> asymptomatic
    mu_1 = (1 .- p_s) .* 1/T_lat
    # Exposed -> Pre-symptomatic
    mu_2 = p_s .* 1/T_lat
    # Pre-symptomatic -> symptomatic
    mu_3 = fill(1 / T_presym, age_categories)
    # Symptomatic -> hospital
    hospitalisation = p_h .* 1/T_sym
    # Asymptomatic -> recovered
    sigma_1 = (1 .- p_s) .* 1/T_asym
    # Symptomatic -> recovered
    sigma_2 = (1 .- p_h) .* (1 .- cfr_home) .* 1/T_rec
    # Hospital -> recovered
    sigma_hospital = (1 .- cfr_hospital) .* 1/T_hosp
    # Symptomatic -> death
    death_home = cfr_home .* 2/T_hosp
    # Hospital -> death
    death_hospital = cfr_hospital .* 1/T_hosp

    transitions = DataFrame([
        (from="Exposed", to="Asymptomatic", prob=mu_1),
        (from="Exposed", to="Presymptomatic", prob=mu_2),
        (from="Presymptomatic", to="Symptomatic", prob=mu_3),
        (from="Symptomatic", to="Hospitalised", prob=hospitalisation),
        (from="Asymptomatic", to="Recovered", prob=sigma_1),
        (from="Symptomatic", to="Recovered", prob=sigma_2),
        (from="Hospitalised", to="Recovered", prob=sigma_hospital),
        (from="Symptomatic", to="Dead", prob=death_home),
        (from="Hospitalised", to="Dead", prob=death_hospital)
    ])

    # Set simulation parameters
    birth_rates = fill(0.0/day, numclasses, age_categories)
    death_rates = fill(0.0/day, numclasses, age_categories)
    birth_rates[:, 2:4] .= uconvert(day^-1, 1/20years)
    death_rates[1:end-1, :] .= uconvert(day^-1, 1/100years)
    virus_growth_asymp = virus_growth_presymp = virus_growth_symp = fill(0.1/day, age_categories)
    virus_decay = 1.0/day
    beta_force = fill(10.0/day, age_categories)
    beta_env = fill(10.0/day, age_categories)
    age_mixing = fill(1.0, age_categories, age_categories)

    param = (birth = birth_rates, death = death_rates, virus_growth = [virus_growth_asymp virus_growth_presymp virus_growth_symp], virus_decay = virus_decay, beta_force = beta_force, beta_env = beta_env, age_mixing = age_mixing)
    epienv = simplehabitatAE(298.0K, size(total_pop), area, Lockdown(20days))
    movement_balance = (home = fill(0.5, numclasses * age_categories), work = fill(0.5, numclasses * age_categories))

    # Dispersal kernels for virus and disease classes
    dispersal_dists = fill(1.0km, length(total_pop))
    thresholds = fill(1e-3, length(total_pop))
    kernel = GaussianKernel.(dispersal_dists, thresholds)
    home = AlwaysMovement(kernel)

    # Import commuter data (for now, fake table)
    active_cells = findall(.!isnan.(total_pop[1:end]))
    from = active_cells
    to = sample(active_cells, weights(total_pop[active_cells]), length(active_cells))
    count = round.(total_pop[to]/10)
    home_to_work = DataFrame(from=from, to=to, count=count)
    work = Commuting(home_to_work)
    movement = EpiMovement(home, work)

    # Traits for match to environment (turned off currently through param choice, i.e. virus matches environment perfectly)
    traits = GaussTrait(fill(298.0K, numvirus), fill(0.1K, numvirus))
    epilist = EpiList(traits, abun_v, abun_h, movement, transitions, param, age_categories, movement_balance)
    rel = Gauss{eltype(epienv.habitat)}()

    initial_infecteds = 100
    # Create epi system with all information
    @time epi = EpiSystem(epilist, epienv, rel, total_pop, UInt32(1), initial_infected = initial_infecteds)

    # Populate susceptibles according to actual population spread
    cat_idx = reshape(1:(numclasses * age_categories), age_categories, numclasses)
    reshaped_pop =
        reshape(scotpop[1:size(epienv.active, 1), 1:size(epienv.active, 2), :],
                size(epienv.active, 1) * size(epienv.active, 2), size(scotpop, 3))'
    epi.abundances.matrix[cat_idx[:, 1], :] = reshaped_pop
    N_cells = size(epi.abundances.matrix, 2)

    # Turn off work moves for <20s and >70s
    epi.epilist.human.home_balance[cat_idx[1:2, :]] .= 1.0
    epi.epilist.human.home_balance[cat_idx[7:10, :]] .= 1.0
    epi.epilist.human.work_balance[cat_idx[1:2, :]] .= 0.0
    epi.epilist.human.work_balance[cat_idx[7:10, :]] .= 0.0

    # Run simulation
    abuns = zeros(UInt32, size(epi.abundances.matrix, 1), N_cells, floor(Int, times/timestep) + 1)
    @time simulate_record!(abuns, epi, times, interval, timestep, save = save, save_path = savepath)

    # Write to pipeline
    #write_array(api, "simulation-outputs", "final-abundances", DataPipelineArray(abuns))

    if do_plot
        # View summed SIR dynamics for whole area
        category_map = (
            "Susceptible" => cat_idx[:, 1],
            "Exposed" => cat_idx[:, 2],
            "Asymptomatic" => cat_idx[:, 3],
            "Presymptomatic" => cat_idx[:, 4],
            "Symptomatic" => cat_idx[:, 5],
            "Hospital" => cat_idx[:, 6],
            "Recovered" => cat_idx[:, 7],
            "Deaths" => cat_idx[:, 8],
        )
        plot_dir = string(data_dir, "sim_plots/")
        println("showing plot one")
        display(plot_epidynamics(epi, abuns, category_map = category_map))
        isdir(dirname(plot_dir)) || mkpath(dirname(plot_dir))   # check dir
        savefig(string(plot_dir, "one.png"))
        println("showing plot two")
        display(plot_epiheatmaps(epi, abuns, steps = [30]))     # NB. this line fails
        savefig(string(plot_dir, "two.png"))
    end
    println("output abuns := ", typeof(abuns), size(abuns))
    return abuns
end
## run
times = 2months; interval = 1day; timestep = 1day
run_model_dr(times, interval, timestep, do_plot=true)
