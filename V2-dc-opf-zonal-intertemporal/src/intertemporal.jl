# intertemporal.jl -- 30-period coupled LP with battery SOC for intertemporal dispatch
#
# Extends the static SCED solver (solver.jl) to a single LP that optimizes battery
# charge/discharge across 10 consecutive days (30 periods = 10 days x 3 periods per
# season). Each period reuses build_case/apply_scenario for generator/load/line data;
# the battery's state-of-charge variable couples adjacent periods.
#
# Separate include chain from solver.jl: intertemporal.jl -> system.jl -> loader.jl -> types.jl
# Does NOT include solver.jl or display.jl.

include("system.jl")

using JuMP, HiGHS

# =============================================================================
# Constants
# =============================================================================

# Period sequence within a representative day (chronological order)
const PERIOD_SEQUENCE = ["night", "day", "peak"]

# Number of identical days per season solve
const N_DAYS = 10

# Total number of time periods per season LP
const N_PERIODS = N_DAYS * length(PERIOD_SEQUENCE)  # 30

# Tolerance for binding flow detection -- same value as solver.jl
const BINDING_TOL = 1e-4


# =============================================================================
# Helper functions
# =============================================================================

"""
    time_to_day_period(t::Int) -> (day::Int, period::String)

Map a time index (1-30) to its (day, period) pair.
Day 1 periods: t=1 -> night, t=2 -> day, t=3 -> peak
Day 2 periods: t=4 -> night, t=5 -> day, t=6 -> peak
...and so on through Day 10.
"""
function time_to_day_period(t::Int)
    day = div(t - 1, 3) + 1
    period_idx = mod(t - 1, 3) + 1
    return (day, PERIOD_SEQUENCE[period_idx])
end


# =============================================================================
# Main solver
# =============================================================================

"""
    solve_intertemporal(data::SystemData, season::String, scenario::ScenarioDef) -> NamedTuple

Solve a 30-period intertemporal LP with battery SOC coupling for a single season.

The LP replicates the static SCED formulation across 30 time periods (10 days x 3
periods/day), adding battery charge/discharge variables with inter-period SOC coupling.
All non-battery components (generators, loads, lines) repeat identically each day;
only the battery SOC variable links periods together.

Returns a NamedTuple with:
  - status::String -- solver termination status
  - objective::Float64 -- total LP objective value (R\$ over 10 days)
  - periods::Vector{NamedTuple} -- length 30, per-period results
  - case_data::Dict{String, CaseData} -- period_name -> CaseData
"""
function solve_intertemporal(data::SystemData, season::String, scenario::ScenarioDef)

    # =========================================================================
    # Step 1: Build period systems (reuse across identical days)
    # =========================================================================
    period_cases = Dict{String, CaseData}()
    for period in PERIOD_SEQUENCE
        period_cases[period] = build_case_data(data, season, period, scenario)
    end

    # =========================================================================
    # Step 2: Build period sequence and hours mapping
    # =========================================================================
    period_seq = repeat(PERIOD_SEQUENCE, N_DAYS)  # 30 entries
    hours_seq = [get_period_hours(data, period_seq[t]) for t in 1:N_PERIODS]

    # =========================================================================
    # Step 3: Create JuMP model
    # =========================================================================
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    # =========================================================================
    # Step 4: Dimensions
    # =========================================================================
    sample_sys = period_cases[PERIOD_SEQUENCE[1]].system
    ngen = length(sample_sys.generators)
    n = sample_sys.n_nodes
    nlines = length(sample_sys.lines)
    batteries = sample_sys.batteries
    nbat = length(batteries)

    T = 1:N_PERIODS

    # =========================================================================
    # Step 5: Variables
    # =========================================================================
    @variable(model, p_gen[g=1:ngen, t=T] >= 0)
    @variable(model, theta[i=1:n, t=T])

    # Battery variables (bounds from battery params)
    @variable(model, 0 <= p_charge[b=1:nbat, t=T] <= data.battery.power_mw)
    @variable(model, 0 <= p_discharge[b=1:nbat, t=T] <= data.battery.power_mw)
    @variable(model, 0 <= soc[b=1:nbat, t=T] <= data.battery.energy_mwh)

    # =========================================================================
    # Step 6: Per-period constraints
    # =========================================================================
    power_balance = Dict{Tuple{Int,Int}, ConstraintRef}()

    for t in T
        period = period_seq[t]
        sys = period_cases[period].system

        # Generator capacity bounds (vary by period due to renewable CFs)
        for g in 1:ngen
            set_upper_bound(p_gen[g, t], sys.generators[g].capacity)
        end

        # Slack bus: fix angle at node 1 (N1)
        @constraint(model, theta[1, t] == 0)

        # Build adjacency from lines
        neighbors = [Tuple{Int,Float64}[] for _ in 1:n]
        for l in sys.lines
            push!(neighbors[l.from_node], (l.to_node, l.reactance))
            push!(neighbors[l.to_node], (l.from_node, l.reactance))
        end

        # Power balance at each node
        # Battery charge is a load (subtracted), discharge is generation (added)
        for i in 1:n
            gen_at_i = sum(p_gen[g, t] for g in 1:ngen
                           if sys.generators[g].node == i; init=0.0)
            discharge_at_i = sum(p_discharge[b, t] for b in 1:nbat
                                 if batteries[b].node == i; init=0.0)
            charge_at_i = sum(p_charge[b, t] for b in 1:nbat
                              if batteries[b].node == i; init=0.0)
            flow_out = sum((theta[i, t] - theta[k, t]) / x
                           for (k, x) in neighbors[i]; init=0.0)

            power_balance[(i, t)] = @constraint(model,
                gen_at_i + discharge_at_i - charge_at_i
                - sys.loads[i] == flow_out
            )
        end

        # Line flow limits (bidirectional)
        for l in sys.lines
            flow_expr = (theta[l.from_node, t] - theta[l.to_node, t]) / l.reactance
            @constraint(model, flow_expr <=  l.capacity)
            @constraint(model, flow_expr >= -l.capacity)
        end
    end

    # =========================================================================
    # Step 7: SOC coupling constraints
    # =========================================================================
    sqrt_eta = sqrt(data.battery.efficiency)
    initial_soc_mwh = data.battery.initial_soc * data.battery.energy_mwh

    for b in 1:nbat
        # Period 1: from initial SOC
        @constraint(model,
            soc[b, 1] == initial_soc_mwh
                + sqrt_eta * p_charge[b, 1] * hours_seq[1]
                - (1.0 / sqrt_eta) * p_discharge[b, 1] * hours_seq[1]
        )

        # Periods 2-30: from previous period's SOC
        for t in 2:N_PERIODS
            @constraint(model,
                soc[b, t] == soc[b, t-1]
                    + sqrt_eta * p_charge[b, t] * hours_seq[t]
                    - (1.0 / sqrt_eta) * p_discharge[b, t] * hours_seq[t]
            )
        end
    end

    # =========================================================================
    # Step 8: Objective -- minimize total cost weighted by hours
    # =========================================================================
    # Hours weighting ensures the LP values energy correctly across periods of
    # different duration (night=7h, day=11h, peak=6h). Duals are divided by
    # hours_seq[t] post-solve to recover R$/MWh LMPs.
    @objective(model, Min,
        sum(hours_seq[t] * (
            sum(period_cases[period_seq[t]].system.generators[g].marginal_cost * p_gen[g, t]
                for g in 1:ngen)
            + sum(data.battery.cost_mwh * p_discharge[b, t] for b in 1:nbat; init=0.0)
        ) for t in T)
    )

    # =========================================================================
    # Step 9: Solve
    # =========================================================================
    optimize!(model)

    status = string(termination_status(model))

    if termination_status(model) != MOI.OPTIMAL
        return (
            status = status,
            objective = NaN,
            periods = NamedTuple[],
            case_data = period_cases,
        )
    end

    # =========================================================================
    # Step 10: Extract results
    # =========================================================================
    obj_val = objective_value(model)

    # Use metadata from any period's CaseData (same across periods for a given scenario)
    sample_case = period_cases[PERIOD_SEQUENCE[1]]
    idx_to_node = sample_case.idx_to_node
    gen_types = sample_case.gen_types
    line_ids = sample_case.line_ids

    period_results = NamedTuple[]

    for t in T
        day, period = time_to_day_period(t)
        hours_t = hours_seq[t]
        sys = period_cases[period].system

        # --- Dispatch (keyed by gen_id) ---
        dispatch = Dict{String,Float64}()
        for g in 1:ngen
            dispatch[sys.generators[g].name] = value(p_gen[g, t])
        end
        # Add battery discharge as dispatch entries
        for b in 1:nbat
            dispatch[batteries[b].name] = value(p_discharge[b, t])
        end

        # --- Flows (keyed by line_id) ---
        flows = Dict{String,Float64}()
        for (idx, l) in enumerate(sys.lines)
            flow_mw = (value(theta[l.from_node, t]) - value(theta[l.to_node, t])) / l.reactance
            flows[line_ids[idx]] = flow_mw
        end

        # --- Angles (keyed by node_id) ---
        angles = Dict{String,Float64}()
        for i in 1:n
            angles[idx_to_node[i]] = value(theta[i, t])
        end

        # --- LMPs (dual of power balance, divided by hours to recover R$/MWh) ---
        lmps = Dict{String,Float64}()
        for i in 1:n
            lmps[idx_to_node[i]] = dual(power_balance[(i, t)]) / hours_t
        end

        # --- Total cost for this period (R$, hours-weighted) ---
        period_gen_cost = sum(
            sys.generators[g].marginal_cost * value(p_gen[g, t])
            for g in 1:ngen
        )
        period_batt_cost = sum(
            data.battery.cost_mwh * value(p_discharge[b, t])
            for b in 1:nbat; init=0.0
        )
        total_cost = hours_t * (period_gen_cost + period_batt_cost)

        # --- Emissions (tCO2/h for this period) ---
        emissions_tco2 = 0.0
        for g in 1:ngen
            gen = sys.generators[g]
            if gen.emission_factor > 0
                emissions_tco2 += value(p_gen[g, t]) * gen.emission_factor
            end
        end

        # --- Curtailment (MW, per renewable generator) ---
        curtailment = Dict{String,Float64}()
        for g in 1:ngen
            gen = sys.generators[g]
            gtype = gen_types[gen.name]
            if gtype in ("wind", "solar")
                curt = gen.capacity - value(p_gen[g, t])
                if curt > 1e-4
                    curtailment[gen.name] = curt
                end
            end
        end

        # --- Battery-specific results ---
        charge_mw = Dict{String,Float64}()
        discharge_mw = Dict{String,Float64}()
        soc_start = Dict{String,Float64}()
        soc_end = Dict{String,Float64}()

        for b in 1:nbat
            bname = batteries[b].name
            charge_mw[bname] = value(p_charge[b, t])
            discharge_mw[bname] = value(p_discharge[b, t])
            soc_end[bname] = value(soc[b, t])
            # SOC at start of period: initial_soc for t=1, previous period's SOC for t>1
            if t == 1
                soc_start[bname] = initial_soc_mwh
            else
                soc_start[bname] = value(soc[b, t-1])
            end
        end

        push!(period_results, (
            day = day,
            period = period,
            hours = hours_t,
            dispatch = dispatch,
            flows = flows,
            angles = angles,
            total_cost = total_cost,
            lmps = lmps,
            emissions_tco2 = emissions_tco2,
            curtailment = curtailment,
            charge_mw = charge_mw,
            discharge_mw = discharge_mw,
            soc_start = soc_start,
            soc_end = soc_end,
        ))
    end

    return (
        status = status,
        objective = obj_val,
        periods = period_results,
        case_data = period_cases,
    )
end


# =============================================================================
# Smoke test
# =============================================================================

"""
    test_intertemporal()

Basic validation: load data, find battery_NE scenario, solve wet season,
print solver status, objective, and SOC trajectory.
"""
function test_intertemporal()
    println("=" ^ 70)
    println("INTERTEMPORAL SOLVER SMOKE TEST")
    println("=" ^ 70)
    println()

    # Load data (path relative to project root)
    data = load_system("data/output")
    println()

    # Find battery_NE scenario
    scenario = nothing
    for s in data.scenarios
        if s.scenario_id == "battery_NE"
            scenario = s
            break
        end
    end

    if scenario === nothing
        println("ERROR: 'battery_NE' scenario not found in scenarios.csv")
        return
    end

    println("Scenario: $(scenario.scenario_id)")
    println("Battery node: $(scenario.battery_node)")
    println("Season: wet")
    println()

    # Solve
    println("Solving 30-period intertemporal LP...")
    result = solve_intertemporal(data, "wet", scenario)

    println()
    println("Solver status: $(result.status)")
    println("Objective value: $(round(result.objective, digits=1)) R\$ (over 10 days)")
    println()

    if result.status != "OPTIMAL"
        println("ERROR: Solver did not find optimal solution")
        return
    end

    # Print SOC trajectory
    println("SOC Trajectory:")
    println("-" ^ 70)
    println("  Day  Period   Charge(MW)  Discharge(MW)  SOC_end(MWh)  SOC(%)")
    println("-" ^ 70)

    energy_mwh = data.battery.energy_mwh

    for t in 1:N_PERIODS
        pr = result.periods[t]

        # Get the first (and likely only) battery name
        bname = first(keys(pr.soc_end))

        charge = pr.charge_mw[bname]
        discharge = pr.discharge_mw[bname]
        soc_val = pr.soc_end[bname]
        soc_pct = soc_val / energy_mwh * 100

        println("  $(lpad(pr.day, 3))  $(rpad(pr.period, 7))  " *
                "$(lpad(string(round(charge, digits=1)), 10))  " *
                "$(lpad(string(round(discharge, digits=1)), 13))  " *
                "$(lpad(string(round(soc_val, digits=1)), 12))  " *
                "$(lpad(string(round(soc_pct, digits=1)), 5))%")
    end

    println("-" ^ 70)
    println()
    println("Smoke test complete.")
end


# Run smoke test when executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    test_intertemporal()
end
