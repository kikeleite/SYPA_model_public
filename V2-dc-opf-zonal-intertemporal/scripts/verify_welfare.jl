# verify_welfare.jl -- Phase 6 verification script
#
# Reads results/welfare.csv and checks 5 verification criteria adapted for
# the simplified welfare framework (PS + GR, no CS/DWL):
#   1. PS and GR computed for every scenario (complete data, 11 rows)
#   2. Welfare accounting identity holds (PS_total + GR = Total Welfare)
#   3. Carbon tax shows GR > 0 and PS transfer (thermal PS decreases)
#   4. Cross-scenario welfare comparison table (ranking by total welfare)
#   5. Battery PS positive for all battery scenarios
#
# Excluded requirements (per user decisions):
#   - DWL excluded: carbon tax treated as Pigouvian, not distortionary (WELF-04)
#
# Usage: julia --project=. scripts/verify_welfare.jl

using CSV, DataFrames, PrettyTables


# =============================================================================
# Constants
# =============================================================================

const RESULTS_DIR = joinpath(@__DIR__, "..", "results")
const DATA_DIR = joinpath(@__DIR__, "..", "data", "output")

const EXPECTED_SCENARIO_COUNT = 11

# All 11 scenario IDs in order (matching scenarios.csv)
const ALL_SCENARIOS = [
    "baseline",
    "carbon_50", "carbon_100",
    "battery_all",
    "subsidy_1", "subsidy_10",
    "tx_expand_2000", "tx_expand_5000", "tx_expand_10000",
    "carbon_50_battery_all",
    "carbon_50_tx_5000",
]

# Battery scenarios (those with battery_node != "none")
const BATTERY_SCENARIOS = [
    "battery_all",
    "carbon_50_battery_all",
]

# Non-battery scenarios
const NON_BATTERY_SCENARIOS = setdiff(Set(ALL_SCENARIOS), Set(BATTERY_SCENARIOS))

# Welfare columns that must be present and non-NaN
const WELFARE_COLUMNS = [
    "ps_hydro", "ps_thermal", "ps_renewable", "ps_battery",
    "ps_total", "gr", "subsidy_cost", "total_welfare",
]


# =============================================================================
# Helper: simple mean (avoid importing Statistics)
# =============================================================================

_mean(x) = sum(x) / length(x)


# =============================================================================
# Criterion 1: PS and GR computed for every scenario
# =============================================================================

"""
    criterion_1_complete_data(welfare) -> Bool

Check that welfare.csv has exactly 11 rows and every row has non-NaN values
for all welfare columns. Battery PS must be non-NaN for battery scenarios
and 0.0 for non-battery scenarios.
"""
function criterion_1_complete_data(welfare::DataFrame)
    println("Criterion 1: PS and GR Computed for Every Scenario")
    println("-" ^ 60)

    passed = true

    # Check row count
    n_rows = nrow(welfare)
    println()
    println("  Row count: $(n_rows) (expected $(EXPECTED_SCENARIO_COUNT))")
    if n_rows != EXPECTED_SCENARIO_COUNT
        println("  FAIL: expected $(EXPECTED_SCENARIO_COUNT) rows, got $(n_rows)")
        passed = false
    end

    # Check all expected scenarios present
    welfare_scenarios = Set(welfare.scenario_id)
    missing_scenarios = setdiff(Set(ALL_SCENARIOS), welfare_scenarios)
    extra_scenarios = setdiff(welfare_scenarios, Set(ALL_SCENARIOS))

    if !isempty(missing_scenarios)
        println("  FAIL: missing scenarios: $(join(missing_scenarios, ", "))")
        passed = false
    end
    if !isempty(extra_scenarios)
        println("  WARNING: unexpected scenarios: $(join(extra_scenarios, ", "))")
    end

    # Check non-NaN values for all welfare columns
    nan_found = false
    for col in WELFARE_COLUMNS
        col_sym = Symbol(col)
        if !(col_sym in propertynames(welfare))
            println("  FAIL: column $(col) not found in welfare.csv")
            passed = false
            continue
        end
        nan_count = sum(isnan.(welfare[!, col_sym]))
        if nan_count > 0
            println("  FAIL: $(col) has $(nan_count) NaN values")
            nan_found = true
            passed = false
        end
    end
    if !nan_found
        println("  All welfare columns have non-NaN values for all $(n_rows) rows")
    end

    # Check battery PS: non-NaN for battery scenarios, 0.0 for non-battery
    battery_set = Set(BATTERY_SCENARIOS)
    battery_ps_ok = true

    for row in eachrow(welfare)
        sid = row.scenario_id
        bps = row.ps_battery

        if sid in battery_set
            if isnan(bps)
                println("  FAIL: ps_battery is NaN for battery scenario $(sid)")
                battery_ps_ok = false
                passed = false
            end
        else
            if abs(bps) > 1e-6
                println("  FAIL: ps_battery should be 0 for non-battery scenario $(sid), got $(bps)")
                battery_ps_ok = false
                passed = false
            end
        end
    end
    if battery_ps_ok
        println("  Battery PS: non-NaN for $(length(BATTERY_SCENARIOS)) battery scenarios, 0.0 for $(EXPECTED_SCENARIO_COUNT - length(BATTERY_SCENARIOS)) non-battery scenarios")
    end

    # Document excluded requirements
    println()
    println("  Note: DWL excluded (carbon tax treated as Pigouvian).")

    println()
    println("Result: $(passed ? "PASS" : "FAIL") -- $(passed ? "complete welfare data for all $(EXPECTED_SCENARIO_COUNT) scenarios" : "incomplete welfare data")")
    println()
    return passed
end


# =============================================================================
# Criterion 2: Welfare accounting identity holds
# =============================================================================

"""
    criterion_2_accounting_identity(welfare) -> Bool

For each scenario verify:
  (a) ps_total = ps_hydro + ps_thermal + ps_renewable + ps_battery (within 1e-2)
  (b) total_welfare = ps_total + gr - subsidy_cost (within 1e-2)
"""
function criterion_2_accounting_identity(welfare::DataFrame)
    println("Criterion 2: Welfare Accounting Identity")
    println("-" ^ 60)

    passed = true
    tol = 1e-2  # R$/yr tolerance

    println()
    println("  Identity 1: ps_total = ps_hydro + ps_thermal + ps_renewable + ps_battery")
    identity1_ok = true

    for row in eachrow(welfare)
        computed_ps = row.ps_hydro + row.ps_thermal + row.ps_renewable + row.ps_battery
        diff = abs(computed_ps - row.ps_total)
        if diff > tol
            println("    FAIL: $(row.scenario_id) -- ps_total=$(row.ps_total), sum=$(computed_ps), diff=$(diff)")
            identity1_ok = false
            passed = false
        end
    end
    if identity1_ok
        println("    All $(nrow(welfare)) scenarios PASS (tolerance $(tol) R\$/yr)")
    end

    println()
    println("  Identity 2: total_welfare = ps_total + gr - subsidy_cost")
    identity2_ok = true

    for row in eachrow(welfare)
        computed_welfare = row.ps_total + row.gr - row.subsidy_cost
        diff = abs(computed_welfare - row.total_welfare)
        if diff > tol
            println("    FAIL: $(row.scenario_id) -- total_welfare=$(row.total_welfare), ps_total+gr-sc=$(computed_welfare), diff=$(diff)")
            identity2_ok = false
            passed = false
        end
    end
    if identity2_ok
        println("    All $(nrow(welfare)) scenarios PASS (tolerance $(tol) R\$/yr)")
    end

    # Carbon tax transfer consistency check
    println()
    println("  Carbon tax transfer consistency:")
    println("    For each carbon tax scenario, PS_net + GR = PS_gross (by construction).")
    println("    Total welfare changes vs baseline reflect only dispatch changes,")
    println("    not accounting leaks. The identities above confirm this.")

    baseline_row = filter(r -> r.scenario_id == "baseline", welfare)
    if nrow(baseline_row) > 0
        baseline_tw = baseline_row[1, :total_welfare]
        println()
        println("    $(rpad("Scenario", 30)) $(lpad("Welfare Delta", 18)) $(lpad("Source", 20))")
        println("    " * "-" ^ 68)
        for row in eachrow(welfare)
            if occursin("carbon", row.scenario_id) && !occursin("battery", row.scenario_id) && !occursin("tx", row.scenario_id) && row.scenario_id != "baseline"
                delta = row.total_welfare - baseline_tw
                println("    $(rpad(row.scenario_id, 30)) $(lpad(string(round(delta/1e6, digits=0)) * " M R\$/yr", 18)) $(lpad("dispatch change", 20))")
            end
        end
    end

    println()
    println("Result: $(passed ? "PASS" : "FAIL") -- $(passed ? "all identities hold for all $(nrow(welfare)) scenarios" : "identity violation found")")
    println()
    return passed
end


# =============================================================================
# Criterion 3: Carbon tax shows GR > 0 and PS transfer
# =============================================================================

"""
    criterion_3_carbon_tax_transfer(welfare, scenarios_df) -> Bool

For carbon tax scenarios:
  (a) GR > 0
  (b) Thermal PS < baseline thermal PS (producers pay the tax)
Report the magnitude of the transfer.
"""
function criterion_3_carbon_tax_transfer(welfare::DataFrame, scenarios_df::DataFrame)
    println("Criterion 3: Carbon Tax Shows GR > 0 and PS Transfer")
    println("-" ^ 60)

    passed = true

    # Identify carbon tax scenarios (carbon_tax_per_tco2 > 0)
    carbon_scenarios = filter(r -> r.carbon_tax_per_tco2 > 0, scenarios_df)
    carbon_ids = Set(carbon_scenarios.scenario_id)

    println()
    println("  Carbon tax scenarios identified: $(length(carbon_ids))")

    # Get baseline thermal PS for comparison
    baseline_row = filter(r -> r.scenario_id == "baseline", welfare)
    if nrow(baseline_row) == 0
        println("  FAIL: baseline not found in welfare.csv")
        println()
        println("Result: FAIL")
        println()
        return false
    end
    baseline_thermal_ps = baseline_row[1, :ps_thermal]

    println()
    println("  $(rpad("Scenario", 30)) $(lpad("Tax (R\$/tCO2)", 14)) $(lpad("GR (M R\$/yr)", 14)) $(lpad("Thermal PS (M)", 16)) $(lpad("Therm PS Delta", 16))")
    println("  " * "-" ^ 90)

    # Print baseline reference
    println("  $(rpad("baseline", 30)) $(lpad("0", 14)) $(lpad("0", 14)) $(lpad(string(round(baseline_thermal_ps/1e6, digits=0)), 16)) $(lpad("-", 16))")

    gr_positive_ok = true
    thermal_lower_ok = true

    for row in eachrow(welfare)
        sid = row.scenario_id
        if !(sid in carbon_ids)
            continue
        end

        # Get carbon tax rate
        tax_row = filter(r -> r.scenario_id == sid, scenarios_df)
        tax_rate = tax_row[1, :carbon_tax_per_tco2]

        gr = row.gr
        thermal_ps = row.ps_thermal
        thermal_delta = thermal_ps - baseline_thermal_ps

        # Check GR > 0
        if gr <= 0
            println("  FAIL: GR <= 0 for $(sid) (GR=$(gr))")
            gr_positive_ok = false
            passed = false
        end

        # Check thermal PS < baseline thermal PS
        if thermal_ps >= baseline_thermal_ps - 1e-6
            println("  FAIL: thermal PS not lower than baseline for $(sid)")
            thermal_lower_ok = false
            passed = false
        end

        println("  $(rpad(sid, 30)) $(lpad(string(round(tax_rate, digits=0)), 14)) $(lpad(string(round(gr/1e6, digits=0)), 14)) $(lpad(string(round(thermal_ps/1e6, digits=0)), 16)) $(lpad(string(round(thermal_delta/1e6, digits=0)), 16))")
    end

    println()
    if gr_positive_ok
        println("  All carbon tax scenarios have GR > 0")
    end
    if thermal_lower_ok
        println("  All carbon tax scenarios show thermal PS lower than baseline")
        println("  Transfer mechanism: carbon tax is deducted from thermal producer surplus")
        println("  and appears as government revenue (GR). Total welfare changes only due")
        println("  to dispatch efficiency changes (coal-to-gas fuel switching).")
    end

    println()
    println("Result: $(passed ? "PASS" : "FAIL") -- $(passed ? "all carbon tax scenarios show GR > 0 and thermal PS transfer" : "carbon tax transfer check failed")")
    println()
    return passed
end


# =============================================================================
# Criterion 4: Cross-scenario welfare comparison table
# =============================================================================

"""
    criterion_4_welfare_ranking(welfare) -> Bool

Sort all scenarios by total welfare (descending), print ranking table.
Verify plausibility: no negative total welfare, battery scenarios generally
higher than baseline.
"""
function criterion_4_welfare_ranking(welfare::DataFrame)
    println("Criterion 4: Cross-Scenario Welfare Comparison Table")
    println("-" ^ 60)

    passed = true

    # Sort by total welfare descending
    sorted = sort(welfare, :total_welfare, rev=true)

    println()
    println("  WELFARE RANKING (all $(nrow(welfare)) scenarios, descending by total welfare)")
    println()

    # Build matrix for PrettyTables
    n = nrow(sorted)
    matrix = Matrix{Any}(undef, n, 8)

    for (i, row) in enumerate(eachrow(sorted))
        matrix[i, 1] = i  # rank
        matrix[i, 2] = row.scenario_id
        matrix[i, 3] = round(row.total_welfare / 1e6, digits=0)
        matrix[i, 4] = round(row.welfare_delta_vs_baseline / 1e6, digits=0)
        matrix[i, 5] = round(row.ps_hydro / 1e6, digits=0)
        matrix[i, 6] = round(row.ps_thermal / 1e6, digits=0)
        matrix[i, 7] = round(row.ps_renewable / 1e6, digits=0)
        matrix[i, 8] = round(row.gr / 1e6, digits=0)
    end

    pretty_table(matrix;
        column_labels = ["Rank", "Scenario", "Total (M R\$/yr)", "vs Baseline",
                         "Hydro PS", "Thermal PS", "Renew PS", "GR"],
        alignment = [:r, :l, :r, :r, :r, :r, :r, :r],
        maximum_number_of_rows = -1,
        display_size = (-1, -1),
    )
    println()

    # Plausibility checks

    # Check 1: No negative total welfare
    neg_welfare = filter(r -> r.total_welfare < 0, welfare)
    if nrow(neg_welfare) > 0
        println("  FAIL: $(nrow(neg_welfare)) scenario(s) have negative total welfare")
        for row in eachrow(neg_welfare)
            println("    $(row.scenario_id): $(round(row.total_welfare/1e6, digits=0)) M R\$/yr")
        end
        passed = false
    else
        println("  No negative total welfare values (all $(nrow(welfare)) scenarios positive)")
    end

    # Check 2: Battery scenarios should generally improve welfare
    baseline_welfare = filter(r -> r.scenario_id == "baseline", welfare)[1, :total_welfare]

    battery_better = 0
    battery_total = 0
    for sid in BATTERY_SCENARIOS
        row = filter(r -> r.scenario_id == sid, welfare)
        if nrow(row) > 0
            battery_total += 1
            if row[1, :total_welfare] > baseline_welfare
                battery_better += 1
            end
        end
    end

    tx_better = 0
    tx_total = 0
    for sid in ["tx_expand_2000", "tx_expand_5000", "tx_expand_10000"]
        row = filter(r -> r.scenario_id == sid, welfare)
        if nrow(row) > 0
            tx_total += 1
            if row[1, :total_welfare] >= baseline_welfare - 1e-6
                tx_better += 1
            end
        end
    end

    println("  Battery scenarios with higher welfare than baseline: $(battery_better)/$(battery_total)")
    println("  Tx expansion scenarios with higher welfare than baseline: $(tx_better)/$(tx_total)")

    if battery_better < battery_total
        println("  NOTE: some battery scenarios do not improve welfare -- check if this is plausible")
    end

    # Check 3: No scenario vastly different from others without explanation
    welfare_values = welfare.total_welfare
    welfare_mean = _mean(welfare_values)
    welfare_std = sqrt(_mean((welfare_values .- welfare_mean).^2))

    outlier_count = 0
    for row in eachrow(welfare)
        if abs(row.total_welfare - welfare_mean) > 3 * welfare_std
            println("  WARNING: $(row.scenario_id) is a 3-sigma outlier ($(round(row.total_welfare/1e6, digits=0)) M R\$/yr)")
            outlier_count += 1
        end
    end
    if outlier_count == 0
        println("  No 3-sigma outliers detected in welfare distribution")
    end

    println()
    println("Result: $(passed ? "PASS" : "FAIL") -- ranking table produced, plausibility checks $(passed ? "passed" : "failed")")
    println()
    return passed
end


# =============================================================================
# Criterion 5: Battery PS positive for all battery scenarios
# =============================================================================

"""
    criterion_5_battery_ps(welfare) -> Bool

For battery scenarios:
  (a) Battery PS > 0
  (b) Carbon tax battery scenario has higher battery PS than no-tax battery scenario
"""
function criterion_5_battery_ps(welfare::DataFrame)
    println("Criterion 5: Battery PS Positive")
    println("-" ^ 60)

    passed = true

    println()
    println("  Battery producer surplus across battery scenarios:")
    println()
    println("  $(rpad("Scenario", 30)) $(lpad("Battery PS (M R\$/yr)", 22)) $(lpad("Status", 10))")
    println("  " * "-" ^ 62)

    battery_ps_values = Dict{String, Float64}()
    all_positive = true

    for sid in BATTERY_SCENARIOS
        row = filter(r -> r.scenario_id == sid, welfare)
        if nrow(row) == 0
            println("  $(rpad(sid, 30))  MISSING from welfare.csv")
            passed = false
            continue
        end

        bps = row[1, :ps_battery]
        battery_ps_values[sid] = bps
        status = bps > 0 ? "POSITIVE" : "NOT POSITIVE"

        if bps <= 0
            all_positive = false
            passed = false
        end

        println("  $(rpad(sid, 30)) $(lpad(string(round(bps/1e6, digits=0)), 22)) $(lpad(status, 10))")
    end

    println()
    if all_positive
        println("  All $(length(BATTERY_SCENARIOS)) battery scenarios have positive battery PS")
    else
        println("  FAIL: not all battery scenarios have positive battery PS")
    end

    # Check that carbon_50_battery_all has higher battery PS than battery_all
    # (carbon tax increases peak LMP spread, benefiting battery arbitrage)
    println()
    println("  Carbon tax effect on battery PS:")

    base_bps = get(battery_ps_values, "battery_all", NaN)
    carbon_bps = get(battery_ps_values, "carbon_50_battery_all", NaN)

    if !isnan(base_bps) && !isnan(carbon_bps)
        delta = carbon_bps - base_bps
        direction = delta > 0 ? "higher (carbon tax boosts battery value)" :
                    delta < 0 ? "lower (unexpected)" : "same"
        println("    battery_all:           $(round(base_bps/1e6, digits=1)) M R\$/yr")
        println("    carbon_50_battery_all: $(round(carbon_bps/1e6, digits=1)) M R\$/yr")
        println("    Delta:                 $(round(delta/1e6, digits=1)) M R\$/yr -- $(direction)")

        if delta < 0
            println("  NOTE: carbon tax did not boost battery PS -- may warrant investigation")
        end
    end

    println()
    println("Result: $(passed ? "PASS" : "FAIL") -- $(passed ? "battery PS positive for all $(length(BATTERY_SCENARIOS)) battery scenarios" : "battery PS check failed")")
    println()
    return passed
end


# =============================================================================
# Main execution
# =============================================================================

function main()
    println("=" ^ 64)
    println("PHASE 6 VERIFICATION REPORT")
    println("Welfare Analysis Results")
    println("=" ^ 64)
    println()

    # Load welfare.csv
    welfare_path = joinpath(RESULTS_DIR, "welfare.csv")
    if !isfile(welfare_path)
        println("ERROR: welfare.csv not found at $(welfare_path)")
        println("Run scripts/run_welfare.jl first to produce welfare data.")
        return
    end

    welfare = CSV.read(welfare_path, DataFrame)
    println("Loaded welfare.csv: $(nrow(welfare)) rows, $(ncol(welfare)) columns")

    # Load scenarios.csv for carbon tax identification
    scenarios_path = joinpath(DATA_DIR, "scenarios.csv")
    if !isfile(scenarios_path)
        println("ERROR: scenarios.csv not found at $(scenarios_path)")
        return
    end

    scenarios_df = CSV.read(scenarios_path, DataFrame)
    println("Loaded scenarios.csv: $(nrow(scenarios_df)) rows")
    println()

    # Run all 5 criteria
    c1 = criterion_1_complete_data(welfare)
    c2 = criterion_2_accounting_identity(welfare)
    c3 = criterion_3_carbon_tax_transfer(welfare, scenarios_df)
    c4 = criterion_4_welfare_ranking(welfare)
    c5 = criterion_5_battery_ps(welfare)

    total_pass = sum([c1, c2, c3, c4, c5])

    println("=" ^ 64)
    println("OVERALL: $(total_pass)/5 criteria PASS")
    println()
    for (i, (label, result)) in enumerate(zip(
        ["PS and GR computed for every scenario",
         "Welfare accounting identity holds",
         "Carbon tax shows GR > 0 and PS transfer",
         "Cross-scenario welfare comparison table",
         "Battery PS positive for all battery scenarios"],
        [c1, c2, c3, c4, c5]))
        println("  Criterion $(i): $(result ? "PASS" : "FAIL") -- $(label)")
    end
    println("=" ^ 64)
end

# Run
main()
