# run_battery.jl -- Phase 5 battery scenario runner
#
# Runs all battery scenarios from scenarios.csv through the intertemporal
# LP solver (30 periods per season), persists per-scenario CSVs with battery
# columns (including per-battery revenue/cost), updates summary.csv with
# battery scenario rows, and prints per-battery profitability tables.
#
# Usage: julia --project=. scripts/run_battery.jl

include(joinpath(@__DIR__, "..", "src", "display.jl"))
include(joinpath(@__DIR__, "..", "src", "intertemporal.jl"))

using CSV, DataFrames


# =============================================================================
# Constants
# =============================================================================

const SEASONS = ["wet", "dry"]


# =============================================================================
# Per-scenario CSV builder (extends Phase 4 schema with battery columns)
# =============================================================================

"""
    build_battery_scenario_df(data, scenario_id, result_wet, result_dry) -> DataFrame

Build a DataFrame with 60 rows (30 wet + 30 dry periods) for a battery scenario.
Extends Phase 4's column schema with battery-specific columns: day, charge_mw,
discharge_mw, soc_start, soc_end, plus per-battery columns for multi-battery scenarios.
"""
function build_battery_scenario_df(data::SystemData, scenario_id::String,
                                    result_wet, result_dry)
    # Get structural info from any period's CaseData
    sample_case = first(values(result_wet.case_data))
    sorted_node_idxs = sort(collect(keys(sample_case.idx_to_node)))
    node_ids = [sample_case.idx_to_node[i] for i in sorted_node_idxs]
    line_ids = sample_case.line_ids
    gen_ids = [g.gen_id for g in data.generators]

    # Detect battery names from first period result
    battery_names = sort(collect(keys(result_wet.periods[1].charge_mw)))

    rows = Dict{String, Any}[]

    for (season, result) in [("wet", result_wet), ("dry", result_dry)]
        for t in 1:N_PERIODS
            pr = result.periods[t]
            case = result.case_data[pr.period]
            hours = pr.hours

            row = Dict{String, Any}()
            row["scenario_id"] = scenario_id
            row["season"] = season
            row["period"] = pr.period
            row["day"] = pr.day
            row["hours"] = hours

            # Cost -- total_cost in result is R$ (hours-weighted), convert to R$/h
            # for consistency with Phase 4's per-case CSV format
            row["total_cost"] = pr.total_cost / hours

            # Emissions (tCO2/h)
            row["total_emissions_tco2h"] = pr.emissions_tco2

            # Load aggregates
            row["total_load_mw"] = sum(case.system.loads)
            row["total_gen_mw"] = sum(v for (k, v) in pr.dispatch
                                      if !startswith(k, "Battery_"))
            row["total_curtailment_mw"] = isempty(pr.curtailment) ? 0.0 : sum(values(pr.curtailment))

            # LMPs per node
            for nid in node_ids
                row["lmp_$(nid)"] = get(pr.lmps, nid, NaN)
            end

            # Flows per line
            for lid in line_ids
                row["flow_$(lid)"] = get(pr.flows, lid, 0.0)
            end

            # Binding status per line
            for (idx, line) in enumerate(case.system.lines)
                lid = line_ids[idx]
                flow = abs(get(pr.flows, lid, 0.0))
                row["binding_$(lid)"] = flow >= line.capacity * (1 - BINDING_TOL) ? 1 : 0
            end

            # Dispatch per generator (all generators from data, not just case)
            for gid in gen_ids
                row["dispatch_$(gid)"] = get(pr.dispatch, gid, 0.0)
            end

            # Battery aggregate columns
            total_charge = sum(max(0.0, get(pr.charge_mw, bn, 0.0)) for bn in battery_names)
            total_discharge = sum(max(0.0, get(pr.discharge_mw, bn, 0.0)) for bn in battery_names)
            total_soc_start = sum(get(pr.soc_start, bn, 0.0) for bn in battery_names)
            total_soc_end = sum(get(pr.soc_end, bn, 0.0) for bn in battery_names)

            row["charge_mw"] = total_charge
            row["discharge_mw"] = total_discharge
            row["soc_start"] = total_soc_start
            row["soc_end"] = total_soc_end

            # Per-battery columns (charge, discharge, SOC, revenue, charging cost)
            for bn in battery_names
                row["charge_$(bn)"] = max(0.0, get(pr.charge_mw, bn, 0.0))
                row["discharge_$(bn)"] = max(0.0, get(pr.discharge_mw, bn, 0.0))
                row["soc_start_$(bn)"] = get(pr.soc_start, bn, 0.0)
                row["soc_end_$(bn)"] = get(pr.soc_end, bn, 0.0)

                # Per-battery revenue and charging cost at nodal LMP (R$ for this period)
                # Requires mapping battery name -> node_id -> LMP
                batt_node_idx = nothing
                for batt in case.system.batteries
                    if batt.name == bn
                        batt_node_idx = batt.node
                        break
                    end
                end
                if batt_node_idx !== nothing
                    batt_nid = case.idx_to_node[batt_node_idx]
                    lmp = get(pr.lmps, batt_nid, 0.0)
                    row["revenue_$(bn)"] = max(0.0, get(pr.discharge_mw, bn, 0.0)) * hours * lmp
                    row["charge_cost_$(bn)"] = max(0.0, get(pr.charge_mw, bn, 0.0)) * hours * lmp
                end
            end

            push!(rows, row)
        end
    end

    return DataFrame(rows)
end


# =============================================================================
# Annual metrics aggregation (extends Phase 4 pattern with battery metrics)
# =============================================================================

"""
    compute_battery_annual_metrics(data, scenario, result_wet, result_dry) -> NamedTuple

Aggregate 60 periods into annual metrics. Same fields as Phase 4's
compute_annual_metrics plus battery-specific columns.

Annualization: sum across 30 periods / N_DAYS gives daily cost,
then * 182.5 days/season gives seasonal total.
"""
function compute_battery_annual_metrics(data::SystemData, scenario::ScenarioDef,
                                        result_wet, result_dry)
    # Get node IDs for LMP averaging
    sample_case = first(values(result_wet.case_data))
    sorted_node_idxs = sort(collect(keys(sample_case.idx_to_node)))
    node_ids = [sample_case.idx_to_node[i] for i in sorted_node_idxs]
    idx_to_node = sample_case.idx_to_node

    # Detect battery names and build battery -> node_id mapping
    battery_names = sort(collect(keys(result_wet.periods[1].charge_mw)))
    batt_node_id = Dict{String, String}()
    for batt in sample_case.system.batteries
        batt_node_id[batt.name] = idx_to_node[batt.node]
    end

    full_cost = 0.0        # All periods
    nonpeak_cost = 0.0     # Night + Day only
    emissions = 0.0
    curtailment = 0.0
    binding_count = 0
    total_charge_mwh = 0.0
    total_discharge_mwh = 0.0
    lmp_weighted = Dict(nid => 0.0 for nid in node_ids)
    total_hours = 0.0

    # Per-battery accumulators (keyed by battery name)
    per_batt_charge = Dict(bn => 0.0 for bn in battery_names)
    per_batt_discharge = Dict(bn => 0.0 for bn in battery_names)
    per_batt_revenue = Dict(bn => 0.0 for bn in battery_names)
    per_batt_charging_cost = Dict(bn => 0.0 for bn in battery_names)

    for (season, result) in [("wet", result_wet), ("dry", result_dry)]
        # Sum across all 30 periods for this season
        season_cost_total = 0.0       # R$ total across 10 days
        season_cost_nonpeak = 0.0
        season_emissions_energy = 0.0 # tCO2 total across 10 days
        season_curtailment_energy = 0.0  # MWh total across 10 days
        season_charge_energy = 0.0
        season_discharge_energy = 0.0

        # Per-battery season accumulators
        season_per_batt_charge = Dict(bn => 0.0 for bn in battery_names)
        season_per_batt_discharge = Dict(bn => 0.0 for bn in battery_names)
        season_per_batt_revenue = Dict(bn => 0.0 for bn in battery_names)
        season_per_batt_charging_cost = Dict(bn => 0.0 for bn in battery_names)

        for t in 1:N_PERIODS
            pr = result.periods[t]
            hours = pr.hours
            case = result.case_data[pr.period]

            # Cost: total_cost is R$ (hours-weighted for this period)
            # R$/h * hours = R$ for this period
            cost_rate = pr.total_cost / hours  # R$/h
            period_cost = cost_rate * hours     # = pr.total_cost (R$)

            season_cost_total += period_cost
            if pr.period != "peak"
                season_cost_nonpeak += period_cost
            end

            # Emissions: tCO2/h * hours = tCO2 for this period
            season_emissions_energy += pr.emissions_tco2 * hours

            # Curtailment: MW * hours = MWh for this period
            if !isempty(pr.curtailment)
                season_curtailment_energy += sum(values(pr.curtailment)) * hours
            end

            # Battery charge/discharge: MW * hours = MWh for this period
            for (bn, chg) in pr.charge_mw
                energy = max(0.0, chg) * hours
                season_charge_energy += energy
                season_per_batt_charge[bn] += energy
            end
            for (bn, dis) in pr.discharge_mw
                energy = max(0.0, dis) * hours
                season_discharge_energy += energy
                season_per_batt_discharge[bn] += energy
            end

            # Per-battery revenue and charging cost at nodal LMP
            for bn in battery_names
                nid = batt_node_id[bn]
                lmp = get(pr.lmps, nid, 0.0)
                dis_mw = max(0.0, get(pr.discharge_mw, bn, 0.0))
                chg_mw = max(0.0, get(pr.charge_mw, bn, 0.0))
                # Revenue = discharge_MW * hours * LMP (R$ for this period)
                season_per_batt_revenue[bn] += dis_mw * hours * lmp
                # Charging cost = charge_MW * hours * LMP (R$ for this period)
                season_per_batt_charging_cost[bn] += chg_mw * hours * lmp
            end

            # Binding line count
            for (idx, line) in enumerate(case.system.lines)
                lid = case.line_ids[idx]
                flow = abs(get(pr.flows, lid, 0.0))
                if flow >= line.capacity * (1 - BINDING_TOL)
                    binding_count += 1
                end
            end

            # LMP hour-weighting (use annual_hours = hours * 182.5 / N_DAYS)
            annual_hours = hours * 182.5 / N_DAYS
            for nid in node_ids
                lmp = get(pr.lmps, nid, 0.0)
                lmp_weighted[nid] += lmp * annual_hours
            end
            total_hours += annual_hours
        end

        # Annualize: divide by N_DAYS to get daily, multiply by 182.5 for season
        daily_factor = 182.5 / N_DAYS
        full_cost += season_cost_total * daily_factor
        nonpeak_cost += season_cost_nonpeak * daily_factor
        emissions += season_emissions_energy * daily_factor
        curtailment += season_curtailment_energy * daily_factor
        total_charge_mwh += season_charge_energy * daily_factor
        total_discharge_mwh += season_discharge_energy * daily_factor

        # Annualize per-battery accumulators
        for bn in battery_names
            per_batt_charge[bn] += season_per_batt_charge[bn] * daily_factor
            per_batt_discharge[bn] += season_per_batt_discharge[bn] * daily_factor
            per_batt_revenue[bn] += season_per_batt_revenue[bn] * daily_factor
            per_batt_charging_cost[bn] += season_per_batt_charging_cost[bn] * daily_factor
        end
    end

    # Compute hour-weighted average LMPs
    avg_lmps = Dict(nid => lmp_weighted[nid] / total_hours for nid in node_ids)

    # Average cycles per day = (annual_discharge_mwh / 365) / energy_mwh
    avg_cycles = (total_discharge_mwh / 365.0) / data.battery.energy_mwh

    # Build per-battery metrics
    per_battery_metrics = Dict{String, NamedTuple}()
    for bn in battery_names
        nid = batt_node_id[bn]
        batt_cycles = (per_batt_discharge[bn] / 365.0) / data.battery.energy_mwh
        per_battery_metrics[bn] = (
            node_id = nid,
            annual_charge_mwh = per_batt_charge[bn],
            annual_discharge_mwh = per_batt_discharge[bn],
            annual_revenue = per_batt_revenue[bn],
            annual_charging_cost = per_batt_charging_cost[bn],
            annual_profit = per_batt_revenue[bn] - per_batt_charging_cost[bn],
            avg_cycles_per_day = batt_cycles,
        )
    end

    return (
        scenario_id = scenario.scenario_id,
        annual_cost_full = full_cost,
        annual_cost_nonpeak = nonpeak_cost,
        annual_emissions_tco2 = emissions,
        annual_curtailment_mwh = curtailment,
        n_binding_cases = binding_count,
        avg_lmps = avg_lmps,
        annual_charge_mwh = total_charge_mwh,
        annual_discharge_mwh = total_discharge_mwh,
        avg_cycles_per_day = avg_cycles,
        per_battery_metrics = per_battery_metrics,
    )
end


# =============================================================================
# Main execution
# =============================================================================

function main()
    println("=" ^ 80)
    println("PHASE 5: BATTERY SCENARIO RUNNER (INTERTEMPORAL LP)")
    println("=" ^ 80)
    println()

    # -------------------------------------------------------------------------
    # Step 1: Load data and filter to battery scenarios
    # -------------------------------------------------------------------------
    println("Loading system data...")
    data = load_system("data/output")
    println()

    battery_scenarios = filter(s -> s.battery_node != "none", data.scenarios)
    println("Battery scenarios: $(length(battery_scenarios))")
    for s in battery_scenarios
        println("  - $(s.scenario_id) (battery at $(s.battery_node))")
    end
    println()

    # -------------------------------------------------------------------------
    # Step 2: Solve all battery scenarios
    # -------------------------------------------------------------------------
    all_results = Dict{String, NamedTuple}()

    for scenario in battery_scenarios
        print_scenario_header(scenario)

        results = Dict{String, Any}()
        all_optimal = true

        for season in SEASONS
            println("  Solving $(season) season (30-period intertemporal LP)...")
            result = solve_intertemporal(data, season, scenario)

            if result.status != "OPTIMAL"
                println("  WARNING: $(season) season returned $(result.status) -- skipping scenario")
                all_optimal = false
                break
            end

            println("  $(season): OPTIMAL (objective = $(round(result.objective, digits=1)) R\$)")
            results[season] = result

            # Print battery SOC summary
            print_battery_summary(result, data, scenario.scenario_id, season)
        end

        if !all_optimal
            println("  Skipping scenario $(scenario.scenario_id) due to non-optimal solve.")
            continue
        end

        all_results[scenario.scenario_id] = (
            wet = results["wet"],
            dry = results["dry"],
        )
    end

    println()
    println("Solved $(length(all_results))/$(length(battery_scenarios)) battery scenarios successfully.")
    println()

    # -------------------------------------------------------------------------
    # Step 3: Write per-scenario CSVs
    # -------------------------------------------------------------------------
    results_dir = joinpath(@__DIR__, "..", "results")
    mkpath(results_dir)

    println("-" ^ 80)
    println("Writing per-scenario CSVs to results/")
    println("-" ^ 80)

    for scenario in battery_scenarios
        sid = scenario.scenario_id
        haskey(all_results, sid) || continue

        r = all_results[sid]
        df = build_battery_scenario_df(data, sid, r.wet, r.dry)
        csv_path = joinpath(results_dir, "$(sid).csv")
        CSV.write(csv_path, df)
        println("  Wrote $(csv_path) ($(nrow(df)) rows, $(ncol(df)) columns)")
    end

    # -------------------------------------------------------------------------
    # Step 4: Compute annual aggregates and update summary.csv
    # -------------------------------------------------------------------------
    println()
    println("Computing annual aggregates...")

    all_metrics = NamedTuple[]
    for scenario in battery_scenarios
        sid = scenario.scenario_id
        haskey(all_results, sid) || continue

        r = all_results[sid]
        metrics = compute_battery_annual_metrics(data, scenario, r.wet, r.dry)
        push!(all_metrics, metrics)
    end

    # Get node IDs for summary CSV columns
    sample_case = first(values(first(values(all_results)).wet.case_data))
    sorted_node_idxs = sort(collect(keys(sample_case.idx_to_node)))
    node_ids = [sample_case.idx_to_node[i] for i in sorted_node_idxs]

    # Read existing summary.csv to get column names and Phase 4 rows
    summary_path = joinpath(results_dir, "summary.csv")
    existing_summary = CSV.read(summary_path, DataFrame)
    existing_cols = names(existing_summary)

    println("  Existing summary.csv: $(nrow(existing_summary)) rows, $(ncol(existing_summary)) columns")

    # Build battery summary rows with same columns as existing summary
    battery_rows = Dict{String, Any}[]
    for (i, scenario) in enumerate(battery_scenarios)
        sid = scenario.scenario_id
        haskey(all_results, sid) || continue

        # Find matching metrics
        m = nothing
        for met in all_metrics
            if met.scenario_id == sid
                m = met
                break
            end
        end
        m === nothing && continue

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

        push!(battery_rows, row)
    end

    battery_df = DataFrame(battery_rows)

    # Ensure column ordering matches existing summary exactly
    battery_df = battery_df[:, existing_cols]

    # Combine and write
    combined = vcat(existing_summary, battery_df)
    CSV.write(summary_path, combined)
    println("  Updated $(summary_path): $(nrow(combined)) rows ($(nrow(existing_summary)) Phase 4 + $(nrow(battery_df)) battery)")

    # -------------------------------------------------------------------------
    # Step 5: Print cross-scenario summary tables
    # -------------------------------------------------------------------------
    print_battery_cross_scenario_summary(all_metrics)

    # -------------------------------------------------------------------------
    # Step 5b: Print per-battery profitability tables
    # -------------------------------------------------------------------------
    print_battery_profitability_summary(all_metrics)

    # -------------------------------------------------------------------------
    # Step 6: Completion banner
    # -------------------------------------------------------------------------
    println("=" ^ 80)
    println("PHASE 5 BATTERY SCENARIO RUNNER COMPLETE")
    println("  Battery scenarios solved: $(length(all_results))")
    println("  Seasons per scenario: $(length(SEASONS))")
    println("  Total intertemporal LP solves: $(length(all_results) * length(SEASONS))")
    println("  Per-scenario CSVs: results/*.csv")
    println("  Summary CSV: results/summary.csv ($(nrow(combined)) rows)")
    println("=" ^ 80)
end

# Run
main()
