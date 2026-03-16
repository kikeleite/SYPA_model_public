# solver.jl -- Security-Constrained Economic Dispatch (SCED) solver
#
# Implements DC optimal power flow for a single (season, period, scenario) case.
# Takes a CaseData struct, returns a named tuple with all results.
# Silent -- never prints. Display is handled by display.jl (Phase 3 Plan 2).

include("system.jl")

using JuMP, HiGHS

# Tolerance for binding flow detection. Used by the display function to determine
# whether a line flow is at capacity (accounts for LP solver numerical precision).
const BINDING_TOL = 1e-4


"""
    solve_sced(case::CaseData) -> NamedTuple

Solve the DC optimal power flow for a single (season, period, scenario) case.

Formulation:
  min  sum(cost_g * p_gen[g]) + sum(cost_b * p_batt[b])
  s.t. Power balance at each node n:
         gen_at_n + batt_at_n - load[n] == net_flow_out[n]
       Slack bus: theta[1] == 0
       Line flow limits: -cap_l <= (theta[from] - theta[to]) / X_l <= cap_l
       Generator bounds: 0 <= p_gen[g] <= available_capacity[g]
       Battery bounds: 0 <= p_batt[b] <= power_mw[b]

Feasibility is guaranteed by backstop thermal generators (one per node, 800 R\$/MWh,
near-unlimited capacity) included in the generator fleet.

Returns a named tuple with fields:
  - dispatch::Dict{String,Float64}     -- gen_id/battery_id -> MW dispatched
  - flows::Dict{String,Float64}        -- line_id -> flow in MW (positive = from->to)
  - angles::Dict{String,Float64}       -- node_id -> voltage angle (radians)
  - total_cost::Float64                -- objective value (R\$/h)
  - solver_status::String              -- JuMP termination status
  - lmps::Dict{String,Float64}        -- node_id -> locational marginal price (R\$/MWh)
  - emissions_tco2::Float64           -- total CO2 emissions (tCO2/h)
  - curtailment::Dict{String,Float64} -- renewable gen_id -> curtailed MW (only non-zero)

Capacity factors are already applied by build_case() -- the solver treats
generator.capacity as the available MW for this case. Do not re-apply CFs.
"""
function solve_sced(case::CaseData)
    system = case.system

    # --- Create JuMP model (silent) ---
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    # --- Dimensions ---
    n = system.n_nodes
    ngen = length(system.generators)
    nbat = length(system.batteries)

    # --- Variables ---
    @variable(model, 0 <= p_gen[g=1:ngen] <= system.generators[g].capacity)
    @variable(model, 0 <= p_batt[b=1:nbat] <= system.batteries[b].power_mw)
    @variable(model, theta[1:n])

    # --- Slack bus: fix angle at node 1 (N1) ---
    @constraint(model, theta[1] == 0)

    # --- Build adjacency from transmission lines ---
    neighbors = [Tuple{Int,Float64}[] for _ in 1:n]
    for l in system.lines
        push!(neighbors[l.from_node], (l.to_node, l.reactance))
        push!(neighbors[l.to_node], (l.from_node, l.reactance))
    end

    # --- Power balance at each node (equality constraints give LMPs via dual) ---
    power_balance = Dict{Int,ConstraintRef}()
    for i in 1:n
        gen_at_i = sum(p_gen[g] for g in 1:ngen
                       if system.generators[g].node == i; init=0.0)
        bat_at_i = sum(p_batt[b] for b in 1:nbat
                       if system.batteries[b].node == i; init=0.0)
        flow_out = sum((theta[i] - theta[k]) / x
                       for (k, x) in neighbors[i]; init=0.0)

        power_balance[i] = @constraint(model,
            gen_at_i + bat_at_i - system.loads[i] == flow_out
        )
    end

    # --- Line flow limits (bidirectional) ---
    for l in system.lines
        flow_expr = (theta[l.from_node] - theta[l.to_node]) / l.reactance
        @constraint(model, flow_expr <=  l.capacity)
        @constraint(model, flow_expr >= -l.capacity)
    end

    # --- Objective: minimize total generation cost ---
    @objective(model, Min,
        sum(system.generators[g].marginal_cost * p_gen[g] for g in 1:ngen) +
        sum(system.batteries[b].cost_mwh * p_batt[b] for b in 1:nbat; init=0.0)
    )

    # --- Solve ---
    optimize!(model)

    # --- Check solver status ---
    status = string(termination_status(model))

    if termination_status(model) != MOI.OPTIMAL
        # Return error result with empty/NaN values
        return (
            dispatch = Dict{String,Float64}(),
            flows = Dict{String,Float64}(),
            angles = Dict{String,Float64}(),
            total_cost = NaN,
            solver_status = status,
            lmps = Dict{String,Float64}(),
            emissions_tco2 = NaN,
            curtailment = Dict{String,Float64}(),
        )
    end

    # --- Extract dispatch (keyed by gen_id string) ---
    dispatch = Dict{String,Float64}()
    for g in 1:ngen
        dispatch[system.generators[g].name] = value(p_gen[g])
    end

    # Add battery dispatch to the same dict
    for b in 1:nbat
        dispatch[system.batteries[b].name] = value(p_batt[b])
    end

    # --- Extract flows (keyed by line_id from case.line_ids) ---
    flows = Dict{String,Float64}()
    for (idx, l) in enumerate(system.lines)
        flow_mw = (value(theta[l.from_node]) - value(theta[l.to_node])) / l.reactance
        flows[case.line_ids[idx]] = flow_mw
    end

    # --- Extract angles (keyed by node_id string) ---
    angles = Dict{String,Float64}()
    for i in 1:n
        angles[case.idx_to_node[i]] = value(theta[i])
    end

    # --- Extract LMPs (dual of power balance equality constraints) ---
    # For equality constraints in a minimization problem, dual() returns the
    # marginal cost of serving one more MW of load at that node.
    lmps = Dict{String,Float64}()
    for i in 1:n
        lmps[case.idx_to_node[i]] = dual(power_balance[i])
    end

    # --- Compute emissions (post-solve, not part of LP) ---
    emissions_tco2 = 0.0
    for g in 1:ngen
        gen = system.generators[g]
        if gen.emission_factor > 0
            emissions_tco2 += value(p_gen[g]) * gen.emission_factor
        end
    end

    # --- Compute curtailment (post-solve, per renewable generator) ---
    # Curtailment = available capacity - dispatch, for wind/solar only.
    # generator.capacity is already CF-adjusted by build_case().
    curtailment = Dict{String,Float64}()
    for g in 1:ngen
        gen = system.generators[g]
        gen_type = case.gen_types[gen.name]
        if gen_type in ("wind", "solar")
            curt = gen.capacity - value(p_gen[g])
            if curt > 1e-4  # Only report meaningful curtailment
                curtailment[gen.name] = curt
            end
        end
    end

    # --- Total cost (objective value) ---
    total_cost = objective_value(model)

    return (
        dispatch = dispatch,
        flows = flows,
        angles = angles,
        total_cost = total_cost,
        solver_status = status,
        lmps = lmps,
        emissions_tco2 = emissions_tco2,
        curtailment = curtailment,
    )
end
