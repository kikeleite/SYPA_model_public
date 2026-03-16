# loader.jl -- CSV data loader and validation for the V2 DC-OPF Brazil model
#
# Reads all 8 CSV files from data/output/, validates their contents, and constructs
# a complete SystemData container with typed structs and node ID mappings.
#
# Main entry point: load_system(data_dir) -> SystemData
#
# Loading order matters: nodes first (provides valid_nodes set), then generators
# (provides valid_gen_ids set), then everything else. Cross-file validation runs
# after all files are loaded.

using CSV
using DataFrames

include("types.jl")

# =============================================================================
# Per-file loading functions
# =============================================================================

"""
    load_nodes(path) -> Vector{NodeData}

Read nodes.csv. Validates: no duplicate node_id, no duplicate subsystem_id.
"""
function load_nodes(path::String)::Vector{NodeData}
    df = CSV.read(path, DataFrame)

    expected_cols = Set(["subsystem_id", "subsystem_name", "node_id", "node_name"])
    actual_cols = Set(string.(names(df)))
    missing_cols = setdiff(expected_cols, actual_cols)
    isempty(missing_cols) || error("nodes.csv missing columns: $(join(missing_cols, ", "))")

    nodes = NodeData[]
    seen_node_ids = Set{String}()
    seen_subsystem_ids = Set{String}()

    for row in eachrow(df)
        nid = string(row.node_id)
        sid = string(row.subsystem_id)

        nid in seen_node_ids && error("nodes.csv: duplicate node_id '$nid'")
        sid in seen_subsystem_ids && error("nodes.csv: duplicate subsystem_id '$sid'")

        push!(seen_node_ids, nid)
        push!(seen_subsystem_ids, sid)

        push!(nodes, NodeData(
            sid,
            string(row.subsystem_name),
            nid,
            string(row.node_name)
        ))
    end

    return nodes
end

"""
    load_generators(path, valid_nodes) -> Vector{GeneratorData}

Read generators.csv. Validates: node references exist, no duplicate gen_id.
Handles missing fuel field for non-thermal generators.
"""
function load_generators(path::String, valid_nodes::Set{String})::Vector{GeneratorData}
    df = CSV.read(path, DataFrame; missingstring="")

    expected_cols = Set(["gen_id", "node", "type", "capacity_mw", "capacity_wet_mw",
                         "capacity_dry_mw", "cost_wet", "cost_dry", "emission_factor",
                         "fuel", "must_run_mw"])
    actual_cols = Set(string.(names(df)))
    missing_cols = setdiff(expected_cols, actual_cols)
    isempty(missing_cols) || error("generators.csv missing columns: $(join(missing_cols, ", "))")

    generators = GeneratorData[]
    seen_ids = Set{String}()

    for row in eachrow(df)
        gid = string(row.gen_id)
        node = string(row.node)

        gid in seen_ids && error("generators.csv: duplicate gen_id '$gid'")
        node in valid_nodes || error("generators.csv: generator '$gid' references invalid node '$node'")

        push!(seen_ids, gid)

        # Handle missing fuel field: non-thermals have empty fuel
        fuel_val = ismissing(row.fuel) ? "" : string(row.fuel)

        push!(generators, GeneratorData(
            gid,
            node,
            string(row.type),
            Float64(row.capacity_mw),
            Float64(row.capacity_wet_mw),
            Float64(row.capacity_dry_mw),
            Float64(row.cost_wet),
            Float64(row.cost_dry),
            Float64(row.emission_factor),
            fuel_val,
            Float64(row.must_run_mw)
        ))
    end

    return generators
end

"""
    load_demand(path, valid_nodes) -> Vector{DemandEntry}

Read demand.csv. Validates: node references, season/period values, exactly 24 rows
covering all (node, season, period) combinations.
"""
function load_demand(path::String, valid_nodes::Set{String})::Vector{DemandEntry}
    df = CSV.read(path, DataFrame)

    expected_cols = Set(["node", "season", "period", "load_mw"])
    actual_cols = Set(string.(names(df)))
    missing_cols = setdiff(expected_cols, actual_cols)
    isempty(missing_cols) || error("demand.csv missing columns: $(join(missing_cols, ", "))")

    entries = DemandEntry[]
    seen_combos = Set{Tuple{String,String,String}}()

    for row in eachrow(df)
        node = string(row.node)
        season = string(row.season)
        period = string(row.period)

        node in valid_nodes || error("demand.csv: invalid node '$node'")

        combo = (node, season, period)
        combo in seen_combos && error("demand.csv: duplicate entry for ($node, $season, $period)")
        push!(seen_combos, combo)

        push!(entries, DemandEntry(node, season, period, Float64(row.load_mw)))
    end

    # Verify completeness: every node x season x period must be present
    n_nodes = length(valid_nodes)
    expected_rows = n_nodes * 2 * 3  # 2 seasons x 3 periods
    length(entries) == expected_rows || error(
        "demand.csv: expected $expected_rows rows ($n_nodes nodes x 2 seasons x 3 periods), got $(length(entries))"
    )

    return entries
end

"""
    load_profiles(path, valid_gen_ids) -> Vector{RenewableProfile}

Read renewable_profiles.csv. Validates: gen_id references, season/period values,
capacity_factor in [0,1].
"""
function load_profiles(path::String, valid_gen_ids::Set{String})::Vector{RenewableProfile}
    df = CSV.read(path, DataFrame)

    expected_cols = Set(["gen_id", "season", "period", "capacity_factor"])
    actual_cols = Set(string.(names(df)))
    missing_cols = setdiff(expected_cols, actual_cols)
    isempty(missing_cols) || error("renewable_profiles.csv missing columns: $(join(missing_cols, ", "))")

    profiles = RenewableProfile[]

    for row in eachrow(df)
        gid = string(row.gen_id)

        gid in valid_gen_ids || error("renewable_profiles.csv: gen_id '$gid' not found in generators")

        push!(profiles, RenewableProfile(
            gid,
            string(row.season),
            string(row.period),
            Float64(row.capacity_factor)
        ))
    end

    return profiles
end

"""
    load_transmission(path, valid_nodes) -> Vector{TransmissionLineData}

Read transmission.csv. Validates: node references, no self-loops, no duplicate line_id.
"""
function load_transmission(path::String, valid_nodes::Set{String})::Vector{TransmissionLineData}
    df = CSV.read(path, DataFrame)

    expected_cols = Set(["line_id", "from_node", "to_node", "capacity_mw", "reactance_pu"])
    actual_cols = Set(string.(names(df)))
    missing_cols = setdiff(expected_cols, actual_cols)
    isempty(missing_cols) || error("transmission.csv missing columns: $(join(missing_cols, ", "))")

    lines = TransmissionLineData[]
    seen_ids = Set{String}()

    for row in eachrow(df)
        lid = string(row.line_id)
        from = string(row.from_node)
        to = string(row.to_node)

        lid in seen_ids && error("transmission.csv: duplicate line_id '$lid'")
        from in valid_nodes || error("transmission.csv: line '$lid' references invalid from_node '$from'")
        to in valid_nodes || error("transmission.csv: line '$lid' references invalid to_node '$to'")
        from != to || error("transmission.csv: line '$lid' has from_node == to_node ('$from')")

        push!(seen_ids, lid)

        push!(lines, TransmissionLineData(
            lid, from, to,
            Float64(row.capacity_mw),
            Float64(row.reactance_pu)
        ))
    end

    return lines
end

"""
    load_battery(path) -> BatteryParams

Read battery.csv (key-value format). Validates: all 5 expected parameters present.
"""
function load_battery(path::String)::BatteryParams
    df = CSV.read(path, DataFrame)

    expected_cols = Set(["parameter", "value"])
    actual_cols = Set(string.(names(df)))
    missing_cols = setdiff(expected_cols, actual_cols)
    isempty(missing_cols) || error("battery.csv missing columns: $(join(missing_cols, ", "))")

    # Parse into a dictionary
    params = Dict{String, Float64}()
    for row in eachrow(df)
        params[string(row.parameter)] = Float64(row.value)
    end

    # Validate all expected keys are present
    expected_keys = Set(["power_mw", "energy_mwh", "efficiency", "cost_mwh", "initial_soc"])
    missing_keys = setdiff(expected_keys, Set(keys(params)))
    isempty(missing_keys) || error("battery.csv missing parameters: $(join(missing_keys, ", "))")

    return BatteryParams(
        params["power_mw"],
        params["energy_mwh"],
        params["efficiency"],
        params["cost_mwh"],
        params["initial_soc"]
    )
end

"""
    load_temporal(path) -> Vector{PeriodDef}

Read temporal.csv. Validates: exactly 3 rows, hours sum to 24, all 3 periods present.
"""
function load_temporal(path::String)::Vector{PeriodDef}
    df = CSV.read(path, DataFrame)

    expected_cols = Set(["period", "hours", "start_hour", "end_hour"])
    actual_cols = Set(string.(names(df)))
    missing_cols = setdiff(expected_cols, actual_cols)
    isempty(missing_cols) || error("temporal.csv missing columns: $(join(missing_cols, ", "))")

    periods = PeriodDef[]
    seen_periods = Set{String}()

    for row in eachrow(df)
        p = string(row.period)
        p in seen_periods && error("temporal.csv: duplicate period '$p'")
        push!(seen_periods, p)

        push!(periods, PeriodDef(
            p,
            Float64(row.hours),
            Float64(row.start_hour),
            Float64(row.end_hour)
        ))
    end

    # Validate exactly 3 periods and hours sum to 24
    length(periods) == 3 || error("temporal.csv: expected 3 periods, got $(length(periods))")

    total_hours = sum(p.hours for p in periods)
    total_hours == 24.0 || error("temporal.csv: hours must sum to 24, got $total_hours")

    expected_periods = Set(["night", "day", "peak"])
    seen_periods == expected_periods || error(
        "temporal.csv: expected periods {night, day, peak}, got {$(join(seen_periods, ", "))}"
    )

    return periods
end

"""
    load_scenarios(path) -> Vector{ScenarioDef}

Read scenarios.csv. Validates: no duplicate scenario_id.
NOTE: Does NOT validate battery_node against valid_nodes -- "none" is valid and
node validation is done in apply_scenario.
"""
function load_scenarios(path::String)::Vector{ScenarioDef}
    df = CSV.read(path, DataFrame; missingstring="")

    expected_cols = Set(["scenario_id", "carbon_tax_per_tco2", "subsidy_per_mwh",
                         "battery_node", "tx_expansion_line", "tx_expansion_mw"])
    actual_cols = Set(string.(names(df)))
    missing_cols = setdiff(expected_cols, actual_cols)
    isempty(missing_cols) || error("scenarios.csv missing columns: $(join(missing_cols, ", "))")

    scenarios = ScenarioDef[]
    seen_ids = Set{String}()

    for row in eachrow(df)
        sid = string(row.scenario_id)
        sid in seen_ids && error("scenarios.csv: duplicate scenario_id '$sid'")
        push!(seen_ids, sid)

        # Handle battery_node and tx_expansion_line as strings
        battery_node = ismissing(row.battery_node) ? "none" : string(row.battery_node)
        tx_line = ismissing(row.tx_expansion_line) ? "none" : string(row.tx_expansion_line)

        push!(scenarios, ScenarioDef(
            sid,
            Float64(row.carbon_tax_per_tco2),
            Float64(row.subsidy_per_mwh),
            battery_node,
            tx_line,
            Float64(row.tx_expansion_mw)
        ))
    end

    return scenarios
end


# =============================================================================
# Cross-file validation
# =============================================================================

"""
    validate_system(data::SystemData)

Cross-file validation after all data is loaded. Throws on any inconsistency.
"""
function validate_system(data::SystemData)
    valid_nodes = Set(n.node_id for n in data.nodes)
    valid_gen_ids = Set(g.gen_id for g in data.generators)

    # Every generator node must exist in nodes
    for g in data.generators
        g.node in valid_nodes || error("Validation: generator '$(g.gen_id)' references unknown node '$(g.node)'")
    end

    # Every demand node must exist in nodes
    for (key, _) in data.demand
        node, _, _ = key
        node in valid_nodes || error("Validation: demand references unknown node '$node'")
    end

    # Every transmission node must exist in nodes
    for line in data.transmission
        line.from_node in valid_nodes || error("Validation: line '$(line.line_id)' references unknown from_node '$(line.from_node)'")
        line.to_node in valid_nodes || error("Validation: line '$(line.line_id)' references unknown to_node '$(line.to_node)'")
    end

    # Every gen_id in profiles must exist in generators
    for (key, _) in data.profiles
        gid, _, _ = key
        gid in valid_gen_ids || error("Validation: profile references unknown gen_id '$gid'")
    end

    # All renewable generators (wind, solar) must have profile entries for all 6 combinations
    renewable_gens = [g for g in data.generators if g.type in ("wind", "solar")]
    seasons = ["wet", "dry"]
    periods = ["night", "day", "peak"]

    for g in renewable_gens
        for s in seasons
            for p in periods
                haskey(data.profiles, (g.gen_id, s, p)) || error(
                    "Validation: renewable generator '$(g.gen_id)' missing profile for ($s, $p)"
                )
            end
        end
    end

    # No hydro or thermal generator should have profile entries
    non_renewable_ids = Set(g.gen_id for g in data.generators if g.type in ("hydro", "thermal"))
    for (key, _) in data.profiles
        gid, _, _ = key
        gid in non_renewable_ids && error(
            "Validation: non-renewable generator '$gid' has profile entries (profiles are for wind/solar only)"
        )
    end

    # Period definitions must match the periods used in demand and profiles
    defined_periods = Set(p.period for p in data.temporal)
    expected_periods = Set(["night", "day", "peak"])
    defined_periods == expected_periods || error(
        "Validation: temporal periods {$(join(defined_periods, ", "))} don't match expected {night, day, peak}"
    )

    # Total demand per season/period must be > 0
    for s in seasons
        for p in periods
            total = sum(get(data.demand, (n.node_id, s, p), 0.0) for n in data.nodes)
            total > 0 || error("Validation: total demand for ($s, $p) is zero or missing")
        end
    end

    println("System validation passed")
end


# =============================================================================
# Master loading function
# =============================================================================

"""
    load_system(data_dir) -> SystemData

Load all 8 CSV files from data_dir, validate contents, and construct a complete
SystemData container. This is the main entry point for the data loader.

Loading order:
1. nodes.csv (needed for valid_nodes set)
2. generators.csv (needs valid_nodes; provides valid_gen_ids set)
3. demand.csv, renewable_profiles.csv, transmission.csv (need valid_nodes and/or valid_gen_ids)
4. battery.csv, temporal.csv, scenarios.csv (independent)
5. Build lookup dictionaries
6. Cross-file validation
"""
function load_system(data_dir::String)::SystemData
    # Construct file paths
    nodes_path = joinpath(data_dir, "nodes.csv")
    generators_path = joinpath(data_dir, "generators.csv")
    demand_path = joinpath(data_dir, "demand.csv")
    profiles_path = joinpath(data_dir, "renewable_profiles.csv")
    transmission_path = joinpath(data_dir, "transmission.csv")
    battery_path = joinpath(data_dir, "battery.csv")
    temporal_path = joinpath(data_dir, "temporal.csv")
    scenarios_path = joinpath(data_dir, "scenarios.csv")

    # 1. Load nodes first (needed for valid_nodes set)
    nodes = load_nodes(nodes_path)
    valid_nodes = Set(n.node_id for n in nodes)

    # 2. Load generators (needs valid_nodes)
    generators = load_generators(generators_path, valid_nodes)
    valid_gen_ids = Set(g.gen_id for g in generators)

    # 3. Load remaining files
    demand_entries = load_demand(demand_path, valid_nodes)
    profile_entries = load_profiles(profiles_path, valid_gen_ids)
    transmission = load_transmission(transmission_path, valid_nodes)
    battery = load_battery(battery_path)
    temporal = load_temporal(temporal_path)
    scenarios = load_scenarios(scenarios_path)

    # 4. Build node ID mappings (string <-> integer index)
    node_to_idx = Dict(n.node_id => i for (i, n) in enumerate(nodes))
    idx_to_node = Dict(i => n.node_id for (i, n) in enumerate(nodes))

    # 5. Build demand lookup dict: (node, season, period) -> load_mw
    demand_dict = Dict(
        (d.node, d.season, d.period) => d.load_mw for d in demand_entries
    )

    # 6. Build profiles lookup dict: (gen_id, season, period) -> capacity_factor
    profiles_dict = Dict(
        (p.gen_id, p.season, p.period) => p.capacity_factor for p in profile_entries
    )

    # 7. Construct SystemData
    data = SystemData(
        nodes, generators, demand_dict, profiles_dict,
        transmission, battery, temporal, scenarios,
        node_to_idx, idx_to_node
    )

    # 8. Cross-file validation
    validate_system(data)

    # 9. Print summary
    println("Loaded: $(length(nodes)) nodes, $(length(generators)) generators, " *
            "$(length(demand_entries)) demand entries, $(length(profile_entries)) profiles, " *
            "$(length(transmission)) lines, $(length(scenarios)) scenarios")

    return data
end


# =============================================================================
# Validation self-tests (Task 2)
# =============================================================================

"""
    test_validation()

Run 5 focused tests to verify the loader rejects malformed input.
Not part of the normal loading path -- call manually to verify validation works.
"""
function test_validation()
    println("Running validation tests...")

    # Test 1: Missing column detection
    print("  Test 1: Missing column detection... ")
    test_dir = mktempdir()
    try
        # Write a generators.csv missing the capacity_mw column
        open(joinpath(test_dir, "generators.csv"), "w") do f
            write(f, "gen_id,node,type,cost_wet,cost_dry,emission_factor,fuel,must_run_mw\n")
            write(f, "Test_Gen,N1,hydro,10,40,0,,0\n")
        end
        load_generators(joinpath(test_dir, "generators.csv"), Set(["N1"]))
        error("TEST FAILED: should have thrown for missing columns")
    catch e
        msg = string(e)
        if occursin("missing columns", msg)
            println("PASSED")
        else
            # Re-throw if it's our "TEST FAILED" error or an unexpected error
            occursin("TEST FAILED", msg) && rethrow(e)
            println("PASSED (threw: $(first(msg, 80)))")
        end
    finally
        rm(test_dir; recursive=true, force=true)
    end

    # Test 2: Invalid node reference
    print("  Test 2: Invalid node reference... ")
    test_dir = mktempdir()
    try
        open(joinpath(test_dir, "generators.csv"), "w") do f
            write(f, "gen_id,node,type,capacity_mw,capacity_wet_mw,capacity_dry_mw,cost_wet,cost_dry,emission_factor,fuel,must_run_mw\n")
            write(f, "Test_Gen,X1,hydro,1000,1000,1000,10,40,0,,0\n")
        end
        load_generators(joinpath(test_dir, "generators.csv"), Set(["N1", "NE1"]))
        error("TEST FAILED: should have thrown for invalid node reference")
    catch e
        msg = string(e)
        if occursin("invalid node", msg)
            println("PASSED")
        else
            occursin("TEST FAILED", msg) && rethrow(e)
            println("PASSED (threw: $(first(msg, 80)))")
        end
    finally
        rm(test_dir; recursive=true, force=true)
    end

    # Test 3: Negative capacity rejection (inner constructor validation)
    print("  Test 3: Negative capacity rejection... ")
    try
        GeneratorData("Bad_Gen", "N1", "hydro", -100.0, -100.0, -100.0, 10.0, 40.0, 0.0, "", 0.0)
        error("TEST FAILED: should have thrown for negative capacity")
    catch e
        msg = string(e)
        if occursin("capacity_mw must be >= 0", msg)
            println("PASSED")
        else
            occursin("TEST FAILED", msg) && rethrow(e)
            println("PASSED (threw: $(first(msg, 80)))")
        end
    end

    # Test 4: Temporal hours validation (hours must sum to 24)
    print("  Test 4: Temporal hours not summing to 24... ")
    test_dir = mktempdir()
    try
        open(joinpath(test_dir, "temporal.csv"), "w") do f
            write(f, "period,hours,start_hour,end_hour\n")
            write(f, "night,5,0,5\n")
            write(f, "day,10,5,15\n")
            write(f, "peak,5,15,20\n")  # Total = 20, not 24
        end
        load_temporal(joinpath(test_dir, "temporal.csv"))
        error("TEST FAILED: should have thrown for hours not summing to 24")
    catch e
        msg = string(e)
        if occursin("hours must sum to 24", msg)
            println("PASSED")
        else
            occursin("TEST FAILED", msg) && rethrow(e)
            println("PASSED (threw: $(first(msg, 80)))")
        end
    finally
        rm(test_dir; recursive=true, force=true)
    end

    # Test 5: Duplicate gen_id detection
    print("  Test 5: Duplicate gen_id detection... ")
    test_dir = mktempdir()
    try
        open(joinpath(test_dir, "generators.csv"), "w") do f
            write(f, "gen_id,node,type,capacity_mw,capacity_wet_mw,capacity_dry_mw,cost_wet,cost_dry,emission_factor,fuel,must_run_mw\n")
            write(f, "Dup_Gen,N1,hydro,1000,1000,1000,10,40,0,,0\n")
            write(f, "Dup_Gen,N1,hydro,2000,2000,2000,20,50,0,,0\n")
        end
        load_generators(joinpath(test_dir, "generators.csv"), Set(["N1"]))
        error("TEST FAILED: should have thrown for duplicate gen_id")
    catch e
        msg = string(e)
        if occursin("duplicate gen_id", msg)
            println("PASSED")
        else
            occursin("TEST FAILED", msg) && rethrow(e)
            println("PASSED (threw: $(first(msg, 80)))")
        end
    finally
        rm(test_dir; recursive=true, force=true)
    end

    println("All validation tests passed!")
end
