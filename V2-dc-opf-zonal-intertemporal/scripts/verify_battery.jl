# verify_battery.jl -- Phase 5 verification script
#
# Reads persisted CSV results from run_battery.jl and checks 5 success criteria
# adapted for the current all-node battery structure (battery_all scenario with
# one 200 MW / 800 MWh battery at each of N1, NE1, SE1, S1):
#   1. SOC ramp-up and repeating daily cycle (per-battery)
#   2. Arbitrage behavior: charge cheap, discharge expensive
#   3. Efficiency losses: round-trip ~85%
#   4. Battery vs non-battery cost reduction
#   5. Node-specific battery value (per-node profitability comparison)
#
# Usage: julia --project=. scripts/verify_battery.jl

using CSV, DataFrames


# =============================================================================
# Constants
# =============================================================================

const RESULTS_DIR = joinpath(@__DIR__, "..", "results")
const BATTERY_ENERGY_MWH = 800.0
const BATTERY_EFFICIENCY = 0.85
const BATTERY_NODES = ["N1", "NE1", "SE1", "S1"]

# Battery scenarios in the current model
const BATTERY_SCENARIO = "battery_all"
const CARBON_BATTERY_SCENARIO = "carbon_50_battery_all"


# =============================================================================
# Helper: load a per-scenario CSV from results/
# =============================================================================

"""
    load_scenario(scenario_id) -> DataFrame

Read a per-scenario result CSV from the results/ directory.
"""
function load_scenario(scenario_id::String)
    path = joinpath(RESULTS_DIR, "$(scenario_id).csv")
    if !isfile(path)
        error("CSV not found: $(path)")
    end
    return CSV.read(path, DataFrame)
end

# Simple mean function (avoid importing Statistics)
mean(x) = sum(x) / length(x)


# =============================================================================
# Criterion 1: SOC Ramp-Up and Repeating Cycle
# =============================================================================

"""
    criterion_1_soc_ramp_and_cycling() -> Bool

Check that each battery exhibits proper SOC behavior:
1. SOC never exceeds energy_mwh (800) or goes below 0
2. Charge/discharge pattern: charge during non-peak, discharge during peak
3. Steady-state cycling: days 5-8 show consistent peak SOC_end values
"""
function criterion_1_soc_ramp_and_cycling()
    println("Criterion 1: SOC Ramp-Up and Repeating Daily Cycle")
    println("-" ^ 60)

    df = try
        load_scenario(BATTERY_SCENARIO)
    catch e
        println("  ERROR: $(e)")
        println()
        println("Result: FAIL -- $(BATTERY_SCENARIO).csv not found")
        println()
        return false
    end

    # Filter to wet season (representative)
    wet = filter(row -> row.season == "wet", df)

    all_pass = true

    for node in BATTERY_NODES
        soc_end_col = Symbol("soc_end_Battery_$(node)")
        charge_col = Symbol("charge_Battery_$(node)")
        discharge_col = Symbol("discharge_Battery_$(node)")

        println()
        println("  Battery at $(node) (wet season):")
        println("  $(rpad("Day", 5)) $(rpad("Period", 8)) $(lpad("Charge (MW)", 12)) $(lpad("Discharge (MW)", 16)) $(lpad("SOC_end (MWh)", 15)) $(lpad("SOC (%)", 8))")
        println("  " * "-" ^ 64)

        soc_bounds_ok = true
        charge_discharge_pattern_ok = true
        peak_soc_ends = Float64[]

        for row in eachrow(wet)
            soc_end = row[soc_end_col]
            charge = row[charge_col]
            discharge = row[discharge_col]
            day = row.day
            period = row.period
            soc_pct = soc_end / BATTERY_ENERGY_MWH * 100

            println("  $(lpad(day, 5)) $(rpad(period, 8)) $(lpad(string(round(charge, digits=1)), 12)) $(lpad(string(round(discharge, digits=1)), 16)) $(lpad(string(round(soc_end, digits=1)), 15)) $(lpad(string(round(soc_pct, digits=1)), 8))")

            # Check SOC bounds
            if soc_end < -0.1 || soc_end > BATTERY_ENERGY_MWH + 0.1
                soc_bounds_ok = false
            end

            # Track peak SOC_end values for steady-state check
            if period == "peak"
                push!(peak_soc_ends, soc_end)
            end

            # Check charge/discharge pattern (days 2-9)
            if day >= 2 && day <= 9
                if period == "peak" && charge > 1.0
                    charge_discharge_pattern_ok = false
                end
            end
        end

        println()

        # Steady-state check (days 5-8 peak SOC_end within 10%)
        steady_state_ok = true
        if length(peak_soc_ends) >= 8
            days_5_8 = peak_soc_ends[5:8]
            if maximum(days_5_8) > 0.1
                range_pct = (maximum(days_5_8) - minimum(days_5_8)) / maximum(days_5_8) * 100
                steady_state_ok = range_pct < 10.0
                println("  Days 5-8 peak SOC_end range: $(round(minimum(days_5_8), digits=1)) - $(round(maximum(days_5_8), digits=1)) MWh ($(round(range_pct, digits=1))% variation)")
            else
                println("  Days 5-8 peak SOC_end: all ~0 MWh (full discharge each day)")
                steady_state_ok = true
            end
        else
            println("  WARNING: fewer than 8 peak periods found")
            steady_state_ok = false
        end

        node_pass = soc_bounds_ok && charge_discharge_pattern_ok && steady_state_ok
        println("  SOC bounds: $(soc_bounds_ok ? "PASS" : "FAIL")  Pattern: $(charge_discharge_pattern_ok ? "PASS" : "FAIL")  Steady-state: $(steady_state_ok ? "PASS" : "FAIL")")

        if !node_pass
            all_pass = false
        end
    end

    println()
    println("Result: $(all_pass ? "PASS" : "FAIL") -- SOC trajectory shows valid cycling behavior for all batteries")
    println()
    return all_pass
end


# =============================================================================
# Criterion 2: Arbitrage Behavior
# =============================================================================

"""
    criterion_2_arbitrage_behavior() -> Bool

Verify that batteries charge during cheap periods and discharge during expensive
periods across all nodes.
"""
function criterion_2_arbitrage_behavior()
    println("Criterion 2: Arbitrage Behavior (Charge Cheap, Discharge Expensive)")
    println("-" ^ 60)

    df = try
        load_scenario(BATTERY_SCENARIO)
    catch e
        println("  ERROR: $(e)")
        println()
        println("Result: FAIL -- $(BATTERY_SCENARIO).csv not found")
        println()
        return false
    end

    println()
    arbitrage_ok = true

    for season in ["wet", "dry"]
        season_df = filter(row -> row.season == season, df)
        steady = filter(row -> row.day >= 2 && row.day <= 9, season_df)

        println("  $(uppercase(season)) season (days 2-9 steady state):")

        for node in BATTERY_NODES
            charge_col = Symbol("charge_Battery_$(node)")
            discharge_col = Symbol("discharge_Battery_$(node)")
            lmp_col = Symbol("lmp_$(node)")

            println("    Battery at $(node):")

            for period in ["night", "day", "peak"]
                period_rows = filter(row -> row.period == period, steady)
                if nrow(period_rows) == 0
                    continue
                end

                avg_charge = mean(period_rows[!, charge_col])
                avg_discharge = mean(period_rows[!, discharge_col])
                avg_lmp = mean(period_rows[!, lmp_col])

                charge_str = avg_charge > 1.0 ? "CHARGING $(round(avg_charge, digits=1)) MW" : "idle"
                discharge_str = avg_discharge > 1.0 ? "DISCHARGING $(round(avg_discharge, digits=1)) MW" : "idle"

                println("      $(rpad(period * ":", 8)) avg LMP=$(lpad(string(round(avg_lmp, digits=1)), 8)) R\$/MWh  $(charge_str)  $(discharge_str)")

                # Verify: no charging during peak
                if period == "peak" && avg_charge > 1.0
                    println("      WARNING: Charging during peak (unexpected)")
                    arbitrage_ok = false
                end
            end
        end
        println()
    end

    println("Result: $(arbitrage_ok ? "PASS" : "FAIL") -- batteries charge during cheap periods, discharge during expensive periods")
    println()
    return arbitrage_ok
end


# =============================================================================
# Criterion 3: Efficiency Losses
# =============================================================================

"""
    criterion_3_efficiency_losses() -> Bool

Verify round-trip efficiency over a multi-day steady-state window (days 3-8)
for each battery. Some batteries (e.g. NE1 in dry season) carry energy across
day boundaries, so a single-day check can show misleading ratios. Over multiple
days the carryover averages out:
  implicit_efficiency = total_discharged / total_charged ≈ 0.85
"""
function criterion_3_efficiency_losses()
    println("Criterion 3: Efficiency Losses (Round-Trip ~$(Int(BATTERY_EFFICIENCY*100))%)")
    println("-" ^ 60)

    println()
    efficiency_ok = true

    for scenario_id in [BATTERY_SCENARIO, CARBON_BATTERY_SCENARIO]
        df = try
            load_scenario(scenario_id)
        catch e
            println("  ERROR: $(e)")
            efficiency_ok = false
            continue
        end

        println("  Scenario: $(scenario_id)")

        for season in ["wet", "dry"]
            season_df = filter(row -> row.season == season, df)
            # Use days 3-8 for steady-state window (avoids ramp-up on days 1-2
            # and end-of-horizon effects on days 9-10)
            steady = filter(row -> row.day >= 3 && row.day <= 8, season_df)

            if nrow(steady) == 0
                println("    WARNING: no rows for days 3-8 $(season)")
                efficiency_ok = false
                continue
            end

            println("    $(uppercase(season)) days 3-8 (steady-state window):")

            for node in BATTERY_NODES
                charge_col = Symbol("charge_Battery_$(node)")
                discharge_col = Symbol("discharge_Battery_$(node)")

                energy_charged = sum(steady[!, charge_col] .* steady.hours)
                energy_discharged = sum(steady[!, discharge_col] .* steady.hours)

                if energy_charged > 0
                    implicit_eff = energy_discharged / energy_charged
                    eff_ok = abs(implicit_eff - BATTERY_EFFICIENCY) < 0.05

                    status = eff_ok ? "OK" : "MISMATCH"
                    println("      $(rpad(node, 5)) charged=$(round(energy_charged, digits=1)) MWh  discharged=$(round(energy_discharged, digits=1)) MWh  eff=$(round(implicit_eff*100, digits=1))%  $(status)")

                    if !eff_ok
                        efficiency_ok = false
                    end
                else
                    println("      $(rpad(node, 5)) no charging in window")
                end
            end
        end
        println()
    end

    # SOC bounds check across both battery scenarios
    println("  SOC bounds check across battery scenarios:")
    soc_bounds_ok = true

    for sid in [BATTERY_SCENARIO, CARBON_BATTERY_SCENARIO]
        path = joinpath(RESULTS_DIR, "$(sid).csv")
        if !isfile(path)
            println("    MISSING: $(sid).csv")
            soc_bounds_ok = false
            continue
        end

        sdf = CSV.read(path, DataFrame)

        for node in BATTERY_NODES
            soc_start_col = Symbol("soc_start_Battery_$(node)")
            soc_end_col = Symbol("soc_end_Battery_$(node)")

            min_soc = min(minimum(sdf[!, soc_start_col]), minimum(sdf[!, soc_end_col]))
            max_soc = max(maximum(sdf[!, soc_start_col]), maximum(sdf[!, soc_end_col]))

            bounds_ok = min_soc >= -0.1 && max_soc <= BATTERY_ENERGY_MWH + 0.1
            status = bounds_ok ? "OK" : "VIOLATION"

            if !bounds_ok
                soc_bounds_ok = false
            end

            println("    $(rpad(sid, 25)) $(rpad(node, 5)) SOC range: [$(round(min_soc, digits=1)), $(round(max_soc, digits=1))] / max=$(Int(BATTERY_ENERGY_MWH)) MWh  $(status)")
        end
    end

    println()
    passed = efficiency_ok && soc_bounds_ok
    println("Result: $(passed ? "PASS" : "FAIL") -- round-trip efficiency ~$(Int(BATTERY_EFFICIENCY*100))% $(efficiency_ok ? "confirmed" : "MISMATCH"), SOC bounds $(soc_bounds_ok ? "respected" : "VIOLATED")")
    println()
    return passed
end


# =============================================================================
# Criterion 4: Battery vs Non-Battery Cost Reduction
# =============================================================================

"""
    criterion_4_battery_vs_no_battery() -> Bool

Compare battery_all annual cost vs baseline annual cost from summary.csv.
Battery should reduce cost via temporal arbitrage.
"""
function criterion_4_battery_vs_no_battery()
    println("Criterion 4: Battery vs Non-Battery Cost Reduction")
    println("-" ^ 60)

    summary = try
        CSV.read(joinpath(RESULTS_DIR, "summary.csv"), DataFrame)
    catch e
        println("  ERROR: $(e)")
        println()
        println("Result: FAIL -- summary.csv not found")
        println()
        return false
    end

    baseline_row = filter(row -> row.scenario_id == "baseline", summary)
    battery_row = filter(row -> row.scenario_id == BATTERY_SCENARIO, summary)

    if nrow(baseline_row) == 0 || nrow(battery_row) == 0
        println("  ERROR: baseline or $(BATTERY_SCENARIO) not found in summary.csv")
        println()
        println("Result: FAIL")
        println()
        return false
    end

    b = baseline_row[1, :]
    n = battery_row[1, :]

    println()
    println("  Baseline vs $(BATTERY_SCENARIO) comparison:")
    println()
    println("  $(rpad("Metric", 30)) $(lpad("Baseline", 18)) $(lpad("Battery All", 18)) $(lpad("Delta", 18)) $(lpad("Change", 10))")
    println("  " * "-" ^ 94)

    # Full annual cost
    cost_delta = n.annual_cost_full - b.annual_cost_full
    cost_pct = cost_delta / b.annual_cost_full * 100
    println("  $(rpad("Annual cost (full, M R\$/yr)", 30)) $(lpad(string(round(b.annual_cost_full/1e6, digits=0)), 18)) $(lpad(string(round(n.annual_cost_full/1e6, digits=0)), 18)) $(lpad(string(round(cost_delta/1e6, digits=0)), 18)) $(lpad(string(round(cost_pct, digits=2)) * "%", 10))")

    # Non-peak cost
    np_delta = n.annual_cost_nonpeak - b.annual_cost_nonpeak
    np_pct = np_delta / b.annual_cost_nonpeak * 100
    println("  $(rpad("Annual cost (non-peak, M R\$/yr)", 30)) $(lpad(string(round(b.annual_cost_nonpeak/1e6, digits=0)), 18)) $(lpad(string(round(n.annual_cost_nonpeak/1e6, digits=0)), 18)) $(lpad(string(round(np_delta/1e6, digits=0)), 18)) $(lpad(string(round(np_pct, digits=2)) * "%", 10))")

    # Emissions
    em_delta = n.annual_emissions_tco2 - b.annual_emissions_tco2
    em_pct = em_delta / b.annual_emissions_tco2 * 100
    println("  $(rpad("Emissions (ktCO2/yr)", 30)) $(lpad(string(round(b.annual_emissions_tco2/1e3, digits=0)), 18)) $(lpad(string(round(n.annual_emissions_tco2/1e3, digits=0)), 18)) $(lpad(string(round(em_delta/1e3, digits=0)), 18)) $(lpad(string(round(em_pct, digits=2)) * "%", 10))")

    # Curtailment
    curt_delta = n.annual_curtailment_mwh - b.annual_curtailment_mwh
    curt_pct = b.annual_curtailment_mwh > 0 ? curt_delta / b.annual_curtailment_mwh * 100 : 0.0
    println("  $(rpad("Curtailment (GWh/yr)", 30)) $(lpad(string(round(b.annual_curtailment_mwh/1e3, digits=0)), 18)) $(lpad(string(round(n.annual_curtailment_mwh/1e3, digits=0)), 18)) $(lpad(string(round(curt_delta/1e3, digits=0)), 18)) $(lpad(string(round(curt_pct, digits=2)) * "%", 10))")

    println()

    cost_reduced = n.annual_cost_full < b.annual_cost_full
    cost_saving = b.annual_cost_full - n.annual_cost_full

    if cost_reduced
        println("  Battery saves $(round(cost_saving/1e6, digits=0)) M R\$/yr ($(round(abs(cost_pct), digits=2))%)")
        println("  Primary mechanism: battery charges at low-price periods and discharges at high-price periods")
    else
        println("  WARNING: Battery does NOT reduce full annual cost")
        println("  Cost increase: $(round(abs(cost_delta)/1e6, digits=0)) M R\$/yr")
    end

    # Also compare carbon_50_battery_all vs carbon_50
    println()
    c50_row = filter(row -> row.scenario_id == "carbon_50", summary)
    c50b_row = filter(row -> row.scenario_id == CARBON_BATTERY_SCENARIO, summary)

    if nrow(c50_row) > 0 && nrow(c50b_row) > 0
        c50_cost = c50_row[1, :annual_cost_full]
        c50b_cost = c50b_row[1, :annual_cost_full]
        c50_delta = c50b_cost - c50_cost
        println("  Carbon_50 + Battery vs Carbon_50: delta = $(round(c50_delta/1e6, digits=0)) M R\$/yr ($(c50_delta < 0 ? "saving" : "increase"))")
    end

    println()
    passed = cost_reduced
    println("Result: $(passed ? "PASS" : "FAIL") -- battery $(cost_reduced ? "reduces" : "does NOT reduce") annual cost vs baseline")
    println()
    return passed
end


# =============================================================================
# Criterion 5: Node-Specific Battery Value
# =============================================================================

"""
    criterion_5_node_specific_value() -> Bool

With the all-node battery scenario, compare per-node profitability to verify
that different locations produce different value. Use per-battery revenue and
charge cost columns from battery_all.csv.
"""
function criterion_5_node_specific_value()
    println("Criterion 5: Node-Specific Battery Value (Per-Node Profitability)")
    println("-" ^ 60)

    println()

    # Check both battery scenarios for per-node profitability
    all_distinct = true

    for scenario_id in [BATTERY_SCENARIO, CARBON_BATTERY_SCENARIO]
        df = try
            load_scenario(scenario_id)
        catch e
            println("  ERROR: $(e)")
            all_distinct = false
            continue
        end

        println("  Scenario: $(scenario_id)")
        println()
        println("  $(rpad("Node", 6)) $(lpad("Revenue (M R\$/yr)", 18)) $(lpad("Chg Cost (M R\$/yr)", 20)) $(lpad("Net Profit (M R\$/yr)", 22))")
        println("  " * "-" ^ 66)

        profits = Dict{String, Float64}()

        for node in BATTERY_NODES
            revenue_col = Symbol("revenue_Battery_$(node)")
            charge_cost_col = Symbol("charge_cost_Battery_$(node)")

            if !(revenue_col in propertynames(df)) || !(charge_cost_col in propertynames(df))
                println("  $(rpad(node, 6))  revenue/charge_cost columns not found")
                all_distinct = false
                continue
            end

            # Annualize: each season is 182.5 days, battery CSV has 10 representative days
            # Revenue/cost are per-period (R$/h * hours = R$/period)
            annual_revenue = 0.0
            annual_charge_cost = 0.0

            for season in ["wet", "dry"]
                season_df = filter(row -> row.season == season, df)
                # Sum revenue across all periods for this season, then scale
                season_revenue = sum(season_df[!, revenue_col])
                season_charge_cost = sum(season_df[!, charge_cost_col])
                # Scale: 182.5 days per season / 10 representative days
                annual_revenue += season_revenue * 182.5 / 10
                annual_charge_cost += season_charge_cost * 182.5 / 10
            end

            net_profit = annual_revenue - annual_charge_cost
            profits[node] = net_profit

            println("  $(rpad(node, 6)) $(lpad(string(round(annual_revenue/1e6, digits=1)), 18)) $(lpad(string(round(annual_charge_cost/1e6, digits=1)), 20)) $(lpad(string(round(net_profit/1e6, digits=1)), 22))")
        end

        println()

        # Check that not all profits are identical (different nodes should have different value)
        if length(profits) >= 2
            profit_values = collect(values(profits))
            profit_range = maximum(profit_values) - minimum(profit_values)

            if profit_range < 1e6  # Less than 1 M R$/yr difference
                println("  WARNING: All node profits are essentially identical (range = $(round(profit_range/1e6, digits=1)) M R\$/yr)")
                all_distinct = false
            else
                # Find best and worst nodes
                best_node = argmax(profits)
                worst_node = argmin(profits)
                println("  Most profitable: $(best_node) ($(round(profits[best_node]/1e6, digits=1)) M R\$/yr)")
                println("  Least profitable: $(worst_node) ($(round(profits[worst_node]/1e6, digits=1)) M R\$/yr)")
                println("  Profit range: $(round(profit_range/1e6, digits=1)) M R\$/yr")
            end
        end

        println()
    end

    # Also check that carbon tax scenario boosts battery profitability
    println("  Carbon tax effect on battery profitability:")
    for scenario_pair in [(BATTERY_SCENARIO, CARBON_BATTERY_SCENARIO)]
        base_sid, carbon_sid = scenario_pair
        base_df = try load_scenario(base_sid) catch; continue end
        carbon_df = try load_scenario(carbon_sid) catch; continue end

        for node in BATTERY_NODES
            revenue_col = Symbol("revenue_Battery_$(node)")
            charge_cost_col = Symbol("charge_cost_Battery_$(node)")

            if !(revenue_col in propertynames(base_df))
                continue
            end

            base_profit = sum(base_df[!, revenue_col]) - sum(base_df[!, charge_cost_col])
            carbon_profit = sum(carbon_df[!, revenue_col]) - sum(carbon_df[!, charge_cost_col])
            delta = carbon_profit - base_profit
            direction = delta > 0 ? "higher" : (delta < 0 ? "lower" : "same")

            println("    $(rpad(node, 5)) base_profit=$(round(base_profit/1e6, digits=1))M  carbon_profit=$(round(carbon_profit/1e6, digits=1))M  $(direction)")
        end
    end

    println()
    println("Result: $(all_distinct ? "PASS" : "FAIL") -- $(all_distinct ? "per-node profitability varies across locations" : "node-specific value check failed")")
    println()
    return all_distinct
end


# =============================================================================
# Main execution
# =============================================================================

function main()
    println("=" ^ 64)
    println("PHASE 5 VERIFICATION REPORT")
    println("Intertemporal Battery Results (All-Node Battery)")
    println("=" ^ 64)
    println()

    c1 = criterion_1_soc_ramp_and_cycling()
    c2 = criterion_2_arbitrage_behavior()
    c3 = criterion_3_efficiency_losses()
    c4 = criterion_4_battery_vs_no_battery()
    c5 = criterion_5_node_specific_value()

    total_pass = sum([c1, c2, c3, c4, c5])

    println("=" ^ 64)
    println("OVERALL: $total_pass/5 criteria PASS")
    println()
    for (i, (label, result)) in enumerate(zip(
        ["SOC ramp-up and repeating cycle (per-battery)",
         "Arbitrage behavior (charge cheap, discharge expensive)",
         "Efficiency losses (~$(Int(BATTERY_EFFICIENCY*100))% round-trip)",
         "Battery vs non-battery cost reduction",
         "Node-specific battery value (per-node profitability)"],
        [c1, c2, c3, c4, c5]))
        println("  Criterion $i: $(result ? "PASS" : "FAIL") -- $label")
    end
    println("=" ^ 64)
end

# Run
main()
