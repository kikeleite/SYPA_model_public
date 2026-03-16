# run_scenarios.jl -- Phase 4 scenario runner for non-battery scenarios
#
# Runs all non-battery scenarios (those with battery_node == "none"),
# solves SCED for each (season, period) case, prints per-case dispatch tables,
# writes per-scenario CSVs and a cross-scenario summary CSV, and displays
# a cross-scenario comparison table.
#
# Usage: julia scripts/run_scenarios.jl

include(joinpath(@__DIR__, "..", "src", "display.jl"))

using CSV, DataFrames


# =============================================================================
# Constants
# =============================================================================

const SEASONS = ["wet", "dry"]
const PERIODS = ["night", "day", "peak"]
const MAIN_CARBON = "carbon_50"  # Designated "main" carbon tax for detailed output


# =============================================================================
# Per-scenario CSV builder
# =============================================================================

"""
    build_scenario_df(data, scenario_id, results, cases) -> DataFrame

Build a DataFrame with one row per (season, period) case for a single scenario.
Columns cover dispatch, flows, LMPs, emissions, and curtailment.
"""
function build_scenario_df(data::SystemData, scenario_id::String,
                           results::Dict, cases::Dict)
    # Get structural info from any case (same across all cases for a scenario)
    sample_case = first(values(cases))
    sorted_node_idxs = sort(collect(keys(sample_case.idx_to_node)))
    node_ids = [sample_case.idx_to_node[i] for i in sorted_node_idxs]
    line_ids = sample_case.line_ids
    gen_ids = [g.gen_id for g in data.generators]

    rows = Dict{String, Any}[]

    for season in SEASONS
        for period in PERIODS
            result = results[(season, period)]
            case = cases[(season, period)]
            hours = get_period_hours(data, period)

            row = Dict{String, Any}()
            row["scenario_id"] = scenario_id
            row["season"] = season
            row["period"] = period
            row["hours"] = hours

            # Cost and emissions
            row["total_cost"] = result.total_cost
            row["total_emissions_tco2h"] = result.emissions_tco2

            # Load aggregates
            row["total_load_mw"] = sum(case.system.loads)
            row["total_gen_mw"] = sum(values(result.dispatch))
            row["total_curtailment_mw"] = isempty(result.curtailment) ? 0.0 : sum(values(result.curtailment))

            # LMPs per node
            for nid in node_ids
                row["lmp_$(nid)"] = get(result.lmps, nid, NaN)
            end

            # Flows per line
            for lid in line_ids
                row["flow_$(lid)"] = get(result.flows, lid, 0.0)
            end

            # Binding status per line
            for (idx, line) in enumerate(case.system.lines)
                lid = line_ids[idx]
                flow = abs(get(result.flows, lid, 0.0))
                row["binding_$(lid)"] = flow >= line.capacity * (1 - BINDING_TOL) ? 1 : 0
            end

            # Dispatch per generator (all generators from data, not just case)
            for gid in gen_ids
                row["dispatch_$(gid)"] = get(result.dispatch, gid, 0.0)
            end

            push!(rows, row)
        end
    end

    return DataFrame(rows)
end


# =============================================================================
# Annual metrics aggregation
# =============================================================================

"""
    compute_annual_metrics(data, scenario, results, cases) -> NamedTuple

Aggregate across 6 cases to produce annual metrics for the cross-scenario summary.

Returns a NamedTuple with fields matching print_cross_scenario_summary expectations:
  scenario_id, annual_cost_full, annual_cost_nonpeak, annual_emissions_tco2,
  annual_curtailment_mwh, n_binding_cases, plus per-node avg LMPs.
"""
function compute_annual_metrics(data::SystemData, scenario::ScenarioDef,
                                results::Dict, cases::Dict)
    # Get node IDs for LMP averaging
    sample_case = first(values(cases))
    sorted_node_idxs = sort(collect(keys(sample_case.idx_to_node)))
    node_ids = [sample_case.idx_to_node[i] for i in sorted_node_idxs]

    full_cost = 0.0        # All periods
    nonpeak_cost = 0.0     # Night + Day only
    emissions = 0.0
    curtailment = 0.0
    binding_count = 0
    lmp_weighted = Dict(nid => 0.0 for nid in node_ids)
    total_hours = 0.0

    for season in SEASONS
        for period in PERIODS
            hours = get_period_hours(data, period)
            # Each season is 182.5 days (365/2)
            annual_hours = hours * 182.5
            result = results[(season, period)]
            case = cases[(season, period)]

            # Cost accumulation
            full_cost += result.total_cost * annual_hours
            if period != "peak"
                nonpeak_cost += result.total_cost * annual_hours
            end

            # Emissions (tCO2/h * annual_hours = tCO2/year contribution)
            emissions += result.emissions_tco2 * annual_hours

            # Curtailment (MW * annual_hours = MWh/year contribution)
            if !isempty(result.curtailment)
                curtailment += sum(values(result.curtailment)) * annual_hours
            end

            # Binding line count (count of (case, line) pairs that are binding)
            for (idx, line) in enumerate(case.system.lines)
                lid = case.line_ids[idx]
                flow = abs(get(result.flows, lid, 0.0))
                if flow >= line.capacity * (1 - BINDING_TOL)
                    binding_count += 1
                end
            end

            # LMP hour-weighting
            for nid in node_ids
                lmp = get(result.lmps, nid, 0.0)
                lmp_weighted[nid] += lmp * annual_hours
            end
            total_hours += annual_hours
        end
    end

    # Compute hour-weighted average LMPs
    avg_lmps = Dict(nid => lmp_weighted[nid] / total_hours for nid in node_ids)

    return (
        scenario_id = scenario.scenario_id,
        annual_cost_full = full_cost,
        annual_cost_nonpeak = nonpeak_cost,
        annual_emissions_tco2 = emissions,
        annual_curtailment_mwh = curtailment,
        n_binding_cases = binding_count,
        avg_lmps = avg_lmps,
    )
end


# =============================================================================
# Summary CSV builder
# =============================================================================

"""
    build_summary_df(all_metrics, node_ids) -> DataFrame

Build the cross-scenario summary DataFrame with one row per scenario.
"""
function build_summary_df(all_metrics::Vector, node_ids::Vector{String})
    rows = Dict{String, Any}[]

    for m in all_metrics
        row = Dict{String, Any}()
        row["scenario_id"] = m.scenario_id
        row["carbon_tax"] = 0.0
        row["subsidy"] = 0.0
        row["tx_expansion_mw"] = 0.0
        row["annual_cost_full"] = m.annual_cost_full
        row["annual_cost_nonpeak"] = m.annual_cost_nonpeak
        row["annual_emissions_tco2"] = m.annual_emissions_tco2
        row["annual_curtailment_mwh"] = m.annual_curtailment_mwh
        row["n_binding_cases"] = m.n_binding_cases

        # Per-node average LMPs
        for nid in node_ids
            row["avg_lmp_$(nid)"] = get(m.avg_lmps, nid, NaN)
        end

        push!(rows, row)
    end

    return DataFrame(rows)
end


# =============================================================================
# Main execution
# =============================================================================

function main()
    println("=" ^ 80)
    println("PHASE 4: NON-BATTERY SCENARIO RUNNER")
    println("=" ^ 80)
    println()

    # -------------------------------------------------------------------------
    # Step 1: Load data and filter to non-battery scenarios
    # -------------------------------------------------------------------------
    println("Loading system data...")
    data = load_system("data/output")
    println()

    non_battery = filter(s -> s.battery_node == "none", data.scenarios)
    println("Non-battery scenarios: $(length(non_battery))")
    for s in non_battery
        println("  - $(s.scenario_id)")
    end
    println()

    # -------------------------------------------------------------------------
    # Step 2: Solve all scenarios
    # -------------------------------------------------------------------------
    # Store results and cases for each scenario
    all_results = Dict{String, Dict{Tuple{String,String}, NamedTuple}}()
    all_cases = Dict{String, Dict{Tuple{String,String}, CaseData}}()

    for scenario in non_battery
        print_scenario_header(scenario)

        results = Dict{Tuple{String,String}, NamedTuple}()
        cases = Dict{Tuple{String,String}, CaseData}()

        for season in SEASONS
            for period in PERIODS
                case = build_case_data(data, season, period, scenario)
                result = solve_sced(case)
                results[(season, period)] = result
                cases[(season, period)] = case
                print_results(result, case)
            end
        end

        all_results[scenario.scenario_id] = results
        all_cases[scenario.scenario_id] = cases
    end

    # -------------------------------------------------------------------------
    # Step 3: Write per-scenario CSVs
    # -------------------------------------------------------------------------
    results_dir = joinpath(@__DIR__, "..", "results")
    mkpath(results_dir)

    println("\n" * "-" ^ 80)
    println("Writing per-scenario CSVs to results/")
    println("-" ^ 80)

    for scenario in non_battery
        sid = scenario.scenario_id
        df = build_scenario_df(data, sid, all_results[sid], all_cases[sid])
        csv_path = joinpath(results_dir, "$(sid).csv")
        CSV.write(csv_path, df)
        println("  Wrote $(csv_path) ($(nrow(df)) rows, $(ncol(df)) columns)")
    end

    # -------------------------------------------------------------------------
    # Step 4: Compute annual aggregates and write summary.csv
    # -------------------------------------------------------------------------
    println()
    println("Computing annual aggregates...")

    all_metrics = NamedTuple[]
    for scenario in non_battery
        sid = scenario.scenario_id
        metrics = compute_annual_metrics(data, scenario,
                                         all_results[sid], all_cases[sid])
        push!(all_metrics, metrics)
    end

    # Get node IDs for summary CSV columns
    sample_case = first(values(first(values(all_cases))))
    sorted_node_idxs = sort(collect(keys(sample_case.idx_to_node)))
    node_ids = [sample_case.idx_to_node[i] for i in sorted_node_idxs]

    # Enrich summary with scenario parameters
    summary_rows = Dict{String, Any}[]
    for (i, scenario) in enumerate(non_battery)
        m = all_metrics[i]
        row = Dict{String, Any}()
        row["scenario_id"] = m.scenario_id
        row["carbon_tax"] = scenario.carbon_tax_per_tco2
        row["subsidy"] = scenario.subsidy_per_mwh
        row["tx_expansion_mw"] = scenario.tx_expansion_mw
        row["annual_cost_full"] = m.annual_cost_full
        row["annual_cost_nonpeak"] = m.annual_cost_nonpeak
        row["annual_emissions_tco2"] = m.annual_emissions_tco2
        row["annual_curtailment_mwh"] = m.annual_curtailment_mwh
        row["n_binding_cases"] = m.n_binding_cases
        for nid in node_ids
            row["avg_lmp_$(nid)"] = get(m.avg_lmps, nid, NaN)
        end
        push!(summary_rows, row)
    end

    summary_df = DataFrame(summary_rows)

    # Ensure column ordering is logical
    col_order = ["scenario_id", "carbon_tax", "subsidy", "tx_expansion_mw",
                 "annual_cost_full", "annual_cost_nonpeak",
                 "annual_emissions_tco2", "annual_curtailment_mwh",
                 "n_binding_cases"]
    for nid in node_ids
        push!(col_order, "avg_lmp_$(nid)")
    end
    summary_df = summary_df[:, col_order]

    summary_path = joinpath(results_dir, "summary.csv")
    CSV.write(summary_path, summary_df)
    println("  Wrote $(summary_path) ($(nrow(summary_df)) rows, $(ncol(summary_df)) columns)")

    # -------------------------------------------------------------------------
    # Step 5: Print cross-scenario summary table
    # -------------------------------------------------------------------------
    print_cross_scenario_summary(all_metrics)

    println("=" ^ 80)
    println("PHASE 4 SCENARIO RUNNER COMPLETE")
    println("  Scenarios solved: $(length(non_battery))")
    println("  Cases per scenario: $(length(SEASONS) * length(PERIODS))")
    println("  Total solves: $(length(non_battery) * length(SEASONS) * length(PERIODS))")
    println("  Per-scenario CSVs: results/*.csv")
    println("  Summary CSV: results/summary.csv")
    println("=" ^ 80)
end

# Run
main()
