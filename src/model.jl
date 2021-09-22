function SEIRS_model(initial_state::Dict, timesteps::Int64, years::Int64,
   alpha::Float64, beta::Float64, inv_gamma::Float64,
   inv_omega::Float64, inv_mu::Float64, inv_sigma::Float64)

   S = initial_state["S"]
   E = initial_state["E"]
   I = initial_state["I"]
   R = initial_state["R"]
   time_unit_years = years / timesteps
   time_unit_days = time_unit_years * 365.25
 
   # Convert parameters to days
   alpha = alpha * time_unit_days
   beta = beta * time_unit_days
   gamma = time_unit_days / inv_gamma
   omega = time_unit_days / (inv_omega * 365.25)
   mu = time_unit_days / (inv_mu * 365.25)
   sigma = 1 / inv_sigma
   N = S + E + I + R
   birth = mu * N

   results = DataFrames.DataFrame(time = 0, S = S, E = E, I = I, R = R)

   for t = 1:timesteps
     infection = (beta * results.I[t] * results.S[t]) / N
     lost_immunity = omega * results.R[t]
     death_S = mu * results.S[t]
     death_E = mu * results.E[t]
     death_I = (mu * alpha) * results.I[t]
     death_R = mu * results.R[t]
     latency = sigma * results.E[t]
     recovery = gamma * results.I[t]
 
     S_rate = birth - infection + lost_immunity - death_S
     E_rate = infection - latency - death_E
     I_rate = latency - recovery - death_I
     R_rate = recovery - lost_immunity - death_R
 
     new_S = results.S[t] + S_rate
     new_E = results.E[t] + E_rate
     new_I = results.I[t] + I_rate
     new_R = results.R[t] + R_rate

     new = DataFrames.DataFrame(time = t * time_unit_days, 
     S = new_S, E = new_E, 
     I = new_I, R = new_R)

     results = vcat(results, new)
   end
 
   return results
end

function plot_SEIRS(results::DataFrames.DataFrame)
   # Left plot
   x = results.time / 365.25
   y1 = Matrix(results[:, 2:5]) .* 100
   p1 = plot(x, y1, label = ["S" "E" "I" "R"], lw = 3)
   xlabel!("Years")
   ylabel!("Relative group size (%)")

   # Right plot
   y2 = y1[:, 2:3]
   p2 = plot(x, y2, label = ["E" "I"], lw = 3)
   xlabel!("Years")
   ylabel!("Relative group size (%)")

   # Join plots together
   Plots.plot(p1, p2, plot_title = "SEIRS model trajectories")
end

function get_parameter(data, parameter)
   output = filter(row -> row.param == parameter, data).value[1]
   return output
end