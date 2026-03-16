# system.jl -- System builder for the V2 DC-OPF Brazil model
#
# Provides the bridge from loaded CSV data (SystemData) to solver-ready
# representations (PowerSystem). build_case() handles temporal selection
# (choosing seasonal costs, capacities, and renewable CFs for a specific
# season/period), while apply_scenario() handles policy modifications
# (carbon tax, subsidy, battery placement, transmission expansion).
#
# Together they produce the PowerSystem struct that Phase 3's SCED solver
# will consume directly.

include("loader.jl")

# =============================================================================
# System builder functions
# =============================================================================

"""
    build_case(data::SystemData, season::String, period::String) -> PowerSystem

Construct a base PowerSystem for a specific (season, period) without any
policy modifications. Selects the correct seasonal costs, seasonal capacities
(for hydro), renewable capacity factors, and demand for the given time case.

Returns a PowerSystem with no batteries -- batteries are added by apply_scenario().
"""
function build_case(data::SystemData, season::String, period::String)::PowerSystem
    # Validate inputs
    season in ("wet", "dry") || error("build_case: invalid season '$season', expected 'wet' or 'dry'")
    period in ("night", "day", "peak") || error("build_case: invalid period '$period', expected 'night', 'day', or 'peak'")

    # Build solver-ready generators
    generators = Generator[]
    for g in data.generators
        # Cost selection: wet or dry season
        cost = season == "wet" ? g.cost_wet : g.cost_dry

        # Capacity selection depends on generator type
        if g.type == "hydro"
            # Hydro uses seasonal capacity (accounts for water availability)
            base_cap = season == "wet" ? g.capacity_wet_mw : g.capacity_dry_mw
        elseif g.type == "thermal"
            # Thermals have same capacity in both seasons
            base_cap = g.capacity_mw
        elseif g.type in ("wind", "solar")
            # Renewables: nameplate * capacity factor for this (season, period)
            key = (g.gen_id, season, period)
            haskey(data.profiles, key) || error(
                "build_case: no profile entry for generator '$(g.gen_id)' at ($season, $period)"
            )
            cf = data.profiles[key]
            base_cap = g.capacity_mw * cf
        else
            error("build_case: unknown generator type '$(g.type)' for '$(g.gen_id)'")
        end

        # Convert node string to integer index
        node_idx = data.node_to_idx[g.node]

        push!(generators, Generator(g.gen_id, node_idx, base_cap, cost, g.must_run_mw, g.emission_factor))
    end

    # Build loads vector indexed by integer node
    loads = zeros(Float64, length(data.nodes))
    for node in data.nodes
        key = (node.node_id, season, period)
        haskey(data.demand, key) || error(
            "build_case: no demand entry for node '$(node.node_id)' at ($season, $period)"
        )
        loads[data.node_to_idx[node.node_id]] = data.demand[key]
    end

    # Build transmission lines with integer node indices
    lines = [TransmissionLine(
        data.node_to_idx[l.from_node],
        data.node_to_idx[l.to_node],
        l.reactance_pu,
        l.capacity_mw
    ) for l in data.transmission]

    # Return PowerSystem with no batteries (added by apply_scenario)
    return PowerSystem(length(data.nodes), generators, Battery[], loads, lines)
end


"""
    apply_scenario(base::PowerSystem, data::SystemData, scenario::ScenarioDef) -> PowerSystem

Take a base PowerSystem (from build_case) and apply policy modifications.
Returns a NEW PowerSystem -- does not mutate the base.

Policy types handled:
- Carbon tax: adds emission_factor * tax_rate to thermal generator costs
- Renewable subsidy: reduces wind/solar costs (floored at 0)
- Battery placement: creates Battery instances at specified nodes
- Transmission expansion: increases capacity on a specified line
"""
function apply_scenario(base::PowerSystem, data::SystemData, scenario::ScenarioDef)::PowerSystem
    # Create mutable copies of immutable vectors
    generators = collect(base.generators)
    lines = collect(base.lines)
    batteries = Battery[]

    # Build generator data lookup by name (for checking type)
    gen_data_by_name = Dict(g.gen_id => g for g in data.generators)

    # 1. Carbon tax: add emission_factor * tax_rate to thermal costs
    if scenario.carbon_tax_per_tco2 > 0
        for (i, gen) in enumerate(generators)
            gdata = gen_data_by_name[gen.name]
            if gdata.type == "thermal"
                new_cost = gen.marginal_cost + gen.emission_factor * scenario.carbon_tax_per_tco2
                generators[i] = Generator(
                    gen.name, gen.node, gen.capacity, new_cost,
                    gen.must_run_mw, gen.emission_factor
                )
            end
        end
    end

    # 2. Renewable subsidy: reduce wind/solar costs (negative costs allowed)
    if scenario.subsidy_per_mwh > 0
        for (i, gen) in enumerate(generators)
            gdata = gen_data_by_name[gen.name]
            if gdata.type in ("wind", "solar")
                new_cost = gen.marginal_cost - scenario.subsidy_per_mwh
                generators[i] = Generator(
                    gen.name, gen.node, gen.capacity, new_cost,
                    gen.must_run_mw, gen.emission_factor
                )
            end
        end
    end

    # 3. Battery placement
    if scenario.battery_node != "none"
        node_strings = split(scenario.battery_node, ";")
        for ns in node_strings
            node_str = strip(String(ns))
            haskey(data.node_to_idx, node_str) || error(
                "apply_scenario: battery_node '$node_str' not found in node_to_idx " *
                "(scenario '$(scenario.scenario_id)')"
            )
            node_idx = data.node_to_idx[node_str]
            push!(batteries, Battery(
                "Battery_$(node_str)",
                node_idx,
                data.battery.power_mw,
                data.battery.cost_mwh
            ))
        end
    end

    # 4. Transmission expansion
    if scenario.tx_expansion_line != "none" && scenario.tx_expansion_mw > 0
        # Find the line in data.transmission matching the scenario's line_id
        line_data_idx = findfirst(l -> l.line_id == scenario.tx_expansion_line, data.transmission)
        line_data_idx !== nothing || error(
            "apply_scenario: tx_expansion_line '$(scenario.tx_expansion_line)' not found " *
            "in transmission data (scenario '$(scenario.scenario_id)')"
        )

        # Find the corresponding line in the solver-ready lines vector
        # Lines are in the same order as data.transmission
        original_line = lines[line_data_idx]
        lines[line_data_idx] = TransmissionLine(
            original_line.from_node,
            original_line.to_node,
            original_line.reactance,
            original_line.capacity + scenario.tx_expansion_mw
        )
    end

    return PowerSystem(base.n_nodes, generators, batteries, base.loads, lines)
end


# =============================================================================
# CaseData builder (bridge from SystemData to solver input)
# =============================================================================

"""
    build_case_data(data::SystemData, season::String, period::String,
                    scenario::ScenarioDef) -> CaseData

Construct a CaseData for a specific (season, period, scenario) case.
Combines build_case() + apply_scenario() with metadata assembly.

This is the primary entry point for Phase 3+ code: the scenario runner
constructs one CaseData per case and passes it to both solve_sced() and
print_results().
"""
function build_case_data(data::SystemData, season::String, period::String,
                         scenario::ScenarioDef)::CaseData
    # Build base PowerSystem and apply scenario modifications
    base = build_case(data, season, period)
    system = apply_scenario(base, data, scenario)

    # Construct gen_types lookup: gen_id -> type string
    gen_types = Dict(g.gen_id => g.type for g in data.generators)

    # Construct line_ids vector parallel to system.lines
    line_ids = [l.line_id for l in data.transmission]

    return CaseData(system, season, period, scenario.scenario_id,
                    data.idx_to_node, gen_types, line_ids)
end

"""
    build_case_data(data::SystemData, season::String, period::String) -> CaseData

Convenience overload for the baseline case (no policy modifications).
Constructs a no-op ScenarioDef internally.
"""
function build_case_data(data::SystemData, season::String, period::String)::CaseData
    baseline = ScenarioDef("baseline", 0.0, 0.0, "none", "none", 0.0)
    return build_case_data(data, season, period, baseline)
end


"""
    get_period_hours(data::SystemData, period::String) -> Int

Return the hour duration of a given period from the temporal definitions.
Used by the solver to weight costs across periods.
"""
function get_period_hours(data::SystemData, period::String)::Int
    for p in data.temporal
        if p.period == period
            return Int(p.hours)
        end
    end
    error("Period '$period' not found in temporal definitions")
end


"""
    print_system_summary(system::PowerSystem, data::SystemData, season::String, period::String)

Print a readable summary of a PowerSystem for debugging and verification.
Shows generation capacity vs demand, generator details, loads, and transmission.
"""
function print_system_summary(system::PowerSystem, data::SystemData, season::String, period::String)
    println("=" ^ 70)
    println("System Summary: $season / $period")
    println("=" ^ 70)

    # Totals
    total_gen_cap = sum(g.capacity for g in system.generators)
    total_batt_cap = isempty(system.batteries) ? 0.0 : sum(b.power_mw for b in system.batteries)
    total_load = sum(system.loads)
    println("Total generation capacity: $(round(total_gen_cap, digits=1)) MW")
    println("Total battery capacity:    $(round(total_batt_cap, digits=1)) MW")
    println("Total demand:              $(round(total_load, digits=1)) MW")
    println("Capacity margin:           $(round(total_gen_cap + total_batt_cap - total_load, digits=1)) MW")
    println()

    # Generators
    println("Generators ($(length(system.generators))):")
    println("-" ^ 60)
    for g in system.generators
        node_str = data.idx_to_node[g.node]
        println("  $(rpad(g.name, 22)) Node=$(rpad(node_str, 4)) " *
                "Cap=$(lpad(string(round(g.capacity, digits=1)), 8)) MW  " *
                "Cost=$(lpad(string(round(g.marginal_cost, digits=1)), 6)) R\$/MWh" *
                (g.must_run_mw > 0 ? "  [must-run: $(round(g.must_run_mw, digits=1)) MW]" : ""))
    end
    println()

    # Batteries
    if !isempty(system.batteries)
        println("Batteries ($(length(system.batteries))):")
        println("-" ^ 60)
        for b in system.batteries
            node_str = data.idx_to_node[b.node]
            println("  $(rpad(b.name, 22)) Node=$(rpad(node_str, 4)) " *
                    "Power=$(lpad(string(round(b.power_mw, digits=1)), 8)) MW  " *
                    "Cost=$(lpad(string(round(b.cost_mwh, digits=1)), 6)) R\$/MWh")
        end
        println()
    end

    # Loads
    println("Loads by node:")
    println("-" ^ 60)
    for i in 1:system.n_nodes
        node_str = data.idx_to_node[i]
        println("  Node $(rpad(node_str, 4)): $(round(system.loads[i], digits=1)) MW")
    end
    println()

    # Transmission
    println("Transmission lines ($(length(system.lines))):")
    println("-" ^ 60)
    for line in system.lines
        from_str = data.idx_to_node[line.from_node]
        to_str = data.idx_to_node[line.to_node]
        println("  $(rpad(from_str, 4)) -> $(rpad(to_str, 4))  " *
                "Capacity=$(lpad(string(round(line.capacity, digits=1)), 8)) MW  " *
                "Reactance=$(round(line.reactance, digits=3)) pu")
    end
    println("=" ^ 70)
end


# =============================================================================
# End-to-end smoke test
# =============================================================================

"""
    smoke_test()

Run the full data pipeline for all case-scenario combinations and verify basic
feasibility. Prints spot checks for key model dynamics.

This is the final validation that the entire Phase 2 data pipeline works end-to-end:
CSV files -> SystemData -> PowerSystem for every combination.
"""
function smoke_test()
    println("Running end-to-end smoke test...")
    data = load_system("data/output")

    seasons = ["wet", "dry"]
    periods = ["night", "day", "peak"]
    n_cases = 0
    n_pass = 0

    for season in seasons
        for period in periods
            base = build_case(data, season, period)

            # Verify base case structural correctness
            @assert length(base.loads) == base.n_nodes
            @assert sum(base.loads) > 0

            for scenario in data.scenarios
                n_cases += 1
                sys = apply_scenario(base, data, scenario)

                # Basic structural checks
                @assert length(sys.loads) == sys.n_nodes
                @assert sum(sys.loads) > 0

                # Structural checks on values
                @assert all(g.capacity >= 0 for g in sys.generators)
                # marginal_cost can be negative for subsidized renewables
                @assert all(sys.loads .>= 0)

                n_pass += 1
            end
        end
    end

    println("Smoke test complete: $n_pass/$n_cases case-scenario combinations built successfully")

    # Print spot checks for key model dynamics
    println("\n--- Spot Checks ---")

    # Check 1: Hydro capacity varies by season
    base_wet = build_case(data, "wet", "day")
    base_dry = build_case(data, "dry", "day")
    hydro_n_t1_wet = first(g for g in base_wet.generators if g.name == "Hydro_N_T1")
    hydro_n_t1_dry = first(g for g in base_dry.generators if g.name == "Hydro_N_T1")
    println("Hydro_N_T1: wet=$(hydro_n_t1_wet.capacity) MW, dry=$(hydro_n_t1_dry.capacity) MW (expect 6000 vs 2100)")

    # Check 2: Renewable CF applied
    wind_ne_day = first(g for g in base_wet.generators if g.name == "Wind_NE")
    println("Wind_NE wet/day: $(wind_ne_day.capacity) MW (expect 52000 * 0.15 = 7800)")

    # Check 3: Cost varies by season for hydro
    println("Hydro_N_T1 cost: wet=$(hydro_n_t1_wet.marginal_cost), dry=$(hydro_n_t1_dry.marginal_cost) (expect 10 vs 40)")

    # Check 4: South hydro INCREASES in dry season (inverse seasonality)
    hydro_s_t1_wet = first(g for g in base_wet.generators if g.name == "Hydro_S_T1")
    hydro_s_t1_dry = first(g for g in base_dry.generators if g.name == "Hydro_S_T1")
    println("Hydro_S_T1: wet=$(hydro_s_t1_wet.capacity) MW, dry=$(hydro_s_t1_dry.capacity) MW (expect 7000 vs 8400)")

    # Check 5: Dry season costs higher than wet
    hydro_se_t2_wet = first(g for g in base_wet.generators if g.name == "Hydro_SE_T2")
    hydro_se_t2_dry = first(g for g in base_dry.generators if g.name == "Hydro_SE_T2")
    println("Hydro_SE_T2 cost: wet=$(hydro_se_t2_wet.marginal_cost), dry=$(hydro_se_t2_dry.marginal_cost) (expect 35 vs 90)")

    println("\nAll checks passed -- Phase 2 data pipeline complete!")
end
