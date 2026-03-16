# run_welfare.jl -- Phase 6 welfare analysis script
#
# Computes welfare decomposition (PS by technology type + GR - SC) for all scenarios
# from existing CSV results. This is a pure post-processing script -- NO re-solving.
#
# Welfare framework (per user decisions):
#   - DWL excluded: carbon tax treated as Pigouvian (corrective, not distortionary)
#   - Welfare = PS (net of carbon tax) + GR - SC
#   - PS broken down by technology type: Hydro, Thermal, Renewable, Battery
#   - GR = carbon_tax_per_tco2 * total_emissions for carbon tax scenarios
#   - SC = subsidy_per_mwh * total_renewable_dispatch (government expenditure)
#
# Revenue uses the LMP at each generator's node (shadow price from power balance
# constraint), not a uniform system price. PS uses BASE marginal costs from
# generators.csv -- never the carbon-tax-inflated costs from the solver.
#
# Usage: julia scripts/run_welfare.jl

include(joinpath(@__DIR__, "..", "src", "system.jl"))

using CSV, DataFrames, PrettyTables


# =============================================================================
# Constants
# =============================================================================

# Battery operating cost (R$/MWh discharged), from battery.csv / Phase 5 decision
const BATTERY_COST_MWH = 1.0

# Number of intertemporal days per season (Phase 5 structure)
const N_DAYS = 10

# Results and data directories (relative to script location)
const RESULTS_DIR = joinpath(@__DIR__, "..", "results")
const DATA_DIR = joinpath(@__DIR__, "..", "data", "output")


# =============================================================================
# Helper: classify generator type into welfare category
# =============================================================================

"""
    welfare_category(gen_type::String) -> String

Map generator type to welfare reporting category.
Wind and solar both map to "renewable".
"""
function welfare_category(gen_type::String)::String
    if gen_type == "hydro"
        return "hydro"
    elseif gen_type == "thermal"
        return "thermal"
    elseif gen_type in ("wind", "solar")
        return "renewable"
    else
        error("Unknown generator type: $gen_type")
    end
end


# =============================================================================
# Helper: parse battery nodes from scenario definition
# =============================================================================

"""
    parse_battery_nodes(battery_node_str::String) -> Vector{String}

Parse battery_node field from scenarios.csv into a vector of node IDs.
Handles "none", single node ("NE1"), and multi-node ("NE1;SE1").
"""
function parse_battery_nodes(battery_node_str::String)::Vector{String}
    if battery_node_str == "none"
        return String[]
    end
    return [strip(String(s)) for s in split(battery_node_str, ";")]
end


# =============================================================================
# Core welfare computation for a single scenario
# =============================================================================

"""
    compute_scenario_welfare(scenario_id, data, scenario_lookup, gen_lookup) -> NamedTuple

Compute welfare decomposition for a single scenario by reading its CSV.

Returns: (ps_hydro, ps_thermal, ps_renewable, ps_battery, gr, subsidy_cost, ps_total, total_welfare)
All values are annual R/year.
"""
function compute_scenario_welfare(scenario_id::String, data::SystemData,
                                   scenario_lookup::Dict{String, ScenarioDef},
                                   gen_lookup::Dict{String, GeneratorData})
    # Read per-scenario CSV
    csv_path = joinpath(RESULTS_DIR, "$(scenario_id).csv")
    df = CSV.read(csv_path, DataFrame)

    # Detect CSV type: Phase 5 battery CSVs have a "day" column
    is_battery = "day" in names(df)

    # Get carbon tax rate and subsidy rate for this scenario
    scenario = scenario_lookup[scenario_id]
    carbon_tax = scenario.carbon_tax_per_tco2
    subsidy_rate = scenario.subsidy_per_mwh

    # Initialize accumulators by technology type
    ps_hydro = 0.0
    ps_thermal = 0.0
    ps_renewable = 0.0
    ps_battery = 0.0
    gr_total = 0.0
    sc_total = 0.0  # subsidy cost (government expenditure)

    # Get battery node(s) for this scenario
    battery_nodes = parse_battery_nodes(scenario.battery_node)
    is_multi_battery = length(battery_nodes) > 1

    for row in eachrow(df)
        season = row.season
        hours = row.hours

        # Annualization factor:
        #   Phase 4 (non-battery): hours * 182.5
        #   Phase 5 (battery): hours * 182.5 / N_DAYS
        annual_factor = is_battery ? hours * 182.5 / N_DAYS : hours * 182.5

        # -----------------------------------------------------------------
        # Generator PS (hydro, thermal, renewable)
        # -----------------------------------------------------------------
        for g in data.generators
            dispatch_col = Symbol("dispatch_$(g.gen_id)")
            dispatch = row[dispatch_col]

            if dispatch <= 0.0
                continue
            end

            # Base marginal cost (NOT carbon-tax-inflated)
            base_cost = season == "wet" ? g.cost_wet : g.cost_dry

            # LMP at generator's node
            lmp_col = Symbol("lmp_$(g.node)")
            lmp = row[lmp_col]

            # Gross PS (before carbon tax)
            ps_gross = (lmp - base_cost) * dispatch

            # Carbon tax paid by this generator (only thermals have emission_factor > 0)
            tax_paid = carbon_tax * g.emission_factor * dispatch

            # Net PS (after tax payment)
            ps_net = ps_gross - tax_paid

            # Accumulate into appropriate technology bucket
            cat = welfare_category(g.type)
            annual_ps = ps_net * annual_factor
            if cat == "hydro"
                ps_hydro += annual_ps
            elseif cat == "thermal"
                ps_thermal += annual_ps
            elseif cat == "renewable"
                ps_renewable += annual_ps
                # Subsidy cost: government pays subsidy_per_mwh for each MWh of renewable dispatch
                if subsidy_rate > 0
                    sc_total += subsidy_rate * dispatch * annual_factor
                end
            end
        end

        # -----------------------------------------------------------------
        # Battery PS (only for battery scenarios with charge/discharge columns)
        # -----------------------------------------------------------------
        if is_battery && !isempty(battery_nodes)
            if is_multi_battery
                # Multi-battery scenario: use per-battery columns
                for bnode in battery_nodes
                    bname = "Battery_$(bnode)"
                    charge_col = Symbol("charge_$(bname)")
                    discharge_col = Symbol("discharge_$(bname)")

                    charge = row[charge_col]
                    discharge = row[discharge_col]
                    lmp_node = row[Symbol("lmp_$(bnode)")]

                    # Battery PS = (revenue from discharge) - (cost of charging) - (operating cost)
                    batt_ps = (lmp_node * discharge - lmp_node * charge - BATTERY_COST_MWH * discharge) * annual_factor
                    ps_battery += batt_ps
                end
            else
                # Single-battery scenario: use aggregate charge_mw/discharge_mw
                charge = row.charge_mw
                discharge = row.discharge_mw
                bnode = battery_nodes[1]
                lmp_node = row[Symbol("lmp_$(bnode)")]

                batt_ps = (lmp_node * discharge - lmp_node * charge - BATTERY_COST_MWH * discharge) * annual_factor
                ps_battery += batt_ps
            end
        end

        # -----------------------------------------------------------------
        # Government Revenue
        # -----------------------------------------------------------------
        gr_case = carbon_tax * row.total_emissions_tco2h * annual_factor
        gr_total += gr_case
    end

    # Compute totals
    ps_total = ps_hydro + ps_thermal + ps_renewable + ps_battery
    total_welfare = ps_total + gr_total - sc_total

    return (
        scenario_id = scenario_id,
        ps_hydro = ps_hydro,
        ps_thermal = ps_thermal,
        ps_renewable = ps_renewable,
        ps_battery = ps_battery,
        ps_total = ps_total,
        gr = gr_total,
        subsidy_cost = sc_total,
        total_welfare = total_welfare,
    )
end


# =============================================================================
# Main execution
# =============================================================================

function main()
    println("=" ^ 80)
    println("PHASE 6: WELFARE ANALYSIS")
    println("=" ^ 80)
    println()

    # -------------------------------------------------------------------------
    # Step 1: Load system data for generator metadata and scenario definitions
    # -------------------------------------------------------------------------
    println("Loading system data...")
    data = load_system(DATA_DIR)
    println()

    # Build lookup dictionaries
    gen_lookup = Dict(g.gen_id => g for g in data.generators)
    scenario_lookup = Dict(s.scenario_id => s for s in data.scenarios)

    # All 22 scenario IDs in order from scenarios.csv
    scenario_ids = [s.scenario_id for s in data.scenarios]
    println("Scenarios to process: $(length(scenario_ids))")
    println()

    # -------------------------------------------------------------------------
    # Step 2: Compute welfare for each scenario
    # -------------------------------------------------------------------------
    println("Computing welfare decomposition...")
    println("-" ^ 80)

    welfare_results = NamedTuple[]
    for sid in scenario_ids
        w = compute_scenario_welfare(sid, data, scenario_lookup, gen_lookup)
        push!(welfare_results, w)
        println("  $(rpad(sid, 30)) PS=$(round(w.ps_total/1e6, digits=0)) M  " *
                "GR=$(round(w.gr/1e6, digits=0)) M  " *
                "SC=$(round(w.subsidy_cost/1e6, digits=0)) M  " *
                "Total=$(round(w.total_welfare/1e6, digits=0)) M R\$/yr")
    end
    println("-" ^ 80)
    println()

    # -------------------------------------------------------------------------
    # Step 3: Compute welfare delta vs baseline
    # -------------------------------------------------------------------------
    baseline_welfare = welfare_results[1].total_welfare  # baseline is first scenario

    welfare_deltas = Dict{String, Float64}()
    for w in welfare_results
        welfare_deltas[w.scenario_id] = w.total_welfare - baseline_welfare
    end

    # -------------------------------------------------------------------------
    # Step 4: Read informational metrics from summary.csv
    # -------------------------------------------------------------------------
    println("Reading informational metrics from summary.csv...")
    summary_df = CSV.read(joinpath(RESULTS_DIR, "summary.csv"), DataFrame)

    # Build summary lookup by scenario_id
    summary_lookup = Dict{String, DataFrameRow}()
    for row in eachrow(summary_df)
        summary_lookup[row.scenario_id] = row
    end

    # -------------------------------------------------------------------------
    # Step 5: Build welfare DataFrame and write CSV
    # -------------------------------------------------------------------------
    println("Building welfare.csv...")

    welfare_rows = Dict{String, Any}[]
    for w in welfare_results
        sid = w.scenario_id

        # Get informational metrics from summary.csv if available,
        # otherwise compute from the per-scenario CSV (battery scenarios
        # are not in the Phase 4 summary)
        if haskey(summary_lookup, sid)
            srow = summary_lookup[sid]
            lmp_values = [srow.avg_lmp_N1, srow.avg_lmp_NE1, srow.avg_lmp_SE1, srow.avg_lmp_S1]
            annual_emissions = srow.annual_emissions_tco2
            annual_curtailment = srow.annual_curtailment_mwh
        else
            # Compute from per-scenario CSV
            csv_path = joinpath(RESULTS_DIR, "$(sid).csv")
            sdf = CSV.read(csv_path, DataFrame)
            is_batt = "day" in names(sdf)
            afactor(row) = is_batt ? row.hours * 182.5 / N_DAYS : row.hours * 182.5

            annual_emissions = sum(sdf.total_emissions_tco2h .* [afactor(r) for r in eachrow(sdf)])
            annual_curtailment = sum(sdf.total_curtailment_mw .* [afactor(r) for r in eachrow(sdf)])

            # Average LMPs weighted by hours
            total_hours = sum(sdf.hours)
            avg_n1  = sum(sdf.lmp_N1  .* sdf.hours) / total_hours
            avg_ne1 = sum(sdf.lmp_NE1 .* sdf.hours) / total_hours
            avg_se1 = sum(sdf.lmp_SE1 .* sdf.hours) / total_hours
            avg_s1  = sum(sdf.lmp_S1  .* sdf.hours) / total_hours
            lmp_values = [avg_n1, avg_ne1, avg_se1, avg_s1]
        end

        lmp_spread = maximum(lmp_values) - minimum(lmp_values)
        avg_lmp = sum(lmp_values) / length(lmp_values)

        row = Dict{String, Any}(
            "scenario_id" => sid,
            "ps_hydro" => w.ps_hydro,
            "ps_thermal" => w.ps_thermal,
            "ps_renewable" => w.ps_renewable,
            "ps_battery" => w.ps_battery,
            "ps_total" => w.ps_total,
            "gr" => w.gr,
            "subsidy_cost" => w.subsidy_cost,
            "total_welfare" => w.total_welfare,
            "welfare_delta_vs_baseline" => welfare_deltas[sid],
            "annual_emissions_tco2" => annual_emissions,
            "annual_curtailment_mwh" => annual_curtailment,
            "lmp_spread" => lmp_spread,
            "avg_lmp" => avg_lmp,
        )
        push!(welfare_rows, row)
    end

    welfare_df = DataFrame(welfare_rows)

    # Ensure consistent column ordering
    col_order = ["scenario_id", "ps_hydro", "ps_thermal", "ps_renewable", "ps_battery",
                 "ps_total", "gr", "subsidy_cost", "total_welfare",
                 "welfare_delta_vs_baseline",
                 "annual_emissions_tco2", "annual_curtailment_mwh",
                 "lmp_spread", "avg_lmp"]
    welfare_df = welfare_df[:, col_order]

    welfare_path = joinpath(RESULTS_DIR, "welfare.csv")
    CSV.write(welfare_path, welfare_df)
    println("  Wrote $(welfare_path) ($(nrow(welfare_df)) rows, $(ncol(welfare_df)) columns)")
    println()

    # -------------------------------------------------------------------------
    # Step 6: Print Table 1 -- Welfare Decomposition
    # -------------------------------------------------------------------------
    println("=" ^ 80)
    println("WELFARE DECOMPOSITION: ALL SCENARIOS (M R\$/yr)")
    println("PS is net of carbon tax payments; Total Welfare = PS + GR - SC")
    println("=" ^ 80)

    n = length(welfare_results)
    matrix_w = Matrix{Any}(undef, n, 9)
    for (i, w) in enumerate(welfare_results)
        matrix_w[i, 1] = w.scenario_id
        matrix_w[i, 2] = round(w.ps_hydro / 1e6, digits=0)
        matrix_w[i, 3] = round(w.ps_thermal / 1e6, digits=0)
        matrix_w[i, 4] = round(w.ps_renewable / 1e6, digits=0)
        matrix_w[i, 5] = round(w.ps_battery / 1e6, digits=0)
        matrix_w[i, 6] = round(w.gr / 1e6, digits=0)
        matrix_w[i, 7] = round(w.subsidy_cost / 1e6, digits=0)
        matrix_w[i, 8] = round(w.total_welfare / 1e6, digits=0)
        matrix_w[i, 9] = round(welfare_deltas[w.scenario_id] / 1e6, digits=0)
    end

    pretty_table(matrix_w;
        column_labels = ["Scenario", "Hydro PS", "Thermal PS", "Renew PS",
                         "Battery PS", "Gov Rev", "Subsidy Cost", "Total Welfare", "vs Baseline"],
        alignment = [:l, :r, :r, :r, :r, :r, :r, :r, :r],
        maximum_number_of_rows = -1,
        display_size = (-1, -1),
    )
    println()

    # -------------------------------------------------------------------------
    # Step 7: Print Table 2 -- Informational Metrics
    # -------------------------------------------------------------------------
    println("=" ^ 80)
    println("INFORMATIONAL METRICS")
    println("=" ^ 80)

    matrix_m = Matrix{Any}(undef, n, 5)
    for (i, w) in enumerate(welfare_results)
        sid = w.scenario_id
        wrow = welfare_df[welfare_df.scenario_id .== sid, :][1, :]

        matrix_m[i, 1] = sid
        matrix_m[i, 2] = round(wrow.annual_curtailment_mwh / 1e3, digits=0)  # GWh/yr
        matrix_m[i, 3] = round(wrow.annual_emissions_tco2 / 1e3, digits=0)   # ktCO2/yr
        matrix_m[i, 4] = round(wrow.lmp_spread, digits=1)                     # R$/MWh
        matrix_m[i, 5] = round(wrow.avg_lmp, digits=1)                        # R$/MWh
    end

    pretty_table(matrix_m;
        column_labels = ["Scenario", "Curtailment (GWh/yr)", "Emissions (ktCO2/yr)",
                         "LMP Spread (R\$/MWh)", "Avg LMP (R\$/MWh)"],
        alignment = [:l, :r, :r, :r, :r],
        maximum_number_of_rows = -1,
        display_size = (-1, -1),
    )
    println()

    # -------------------------------------------------------------------------
    # Step 8: Print accounting identity verification
    # -------------------------------------------------------------------------
    println("=" ^ 80)
    println("WELFARE ACCOUNTING VERIFICATION")
    println("=" ^ 80)
    all_pass = true
    for w in welfare_results
        computed_total = w.ps_hydro + w.ps_thermal + w.ps_renewable + w.ps_battery + w.gr - w.subsidy_cost
        diff = abs(computed_total - w.total_welfare)
        pass = diff < 1e-6  # numerical tolerance
        status = pass ? "PASS" : "FAIL"
        if !pass
            all_pass = false
            println("  $(w.scenario_id): $(status) (diff=$(diff))")
        end
    end
    if all_pass
        println("  All $(length(welfare_results)) scenarios PASS accounting identity: PS_total + GR - SC = Total Welfare")
    end
    println()

    # -------------------------------------------------------------------------
    # Step 9: Completion banner
    # -------------------------------------------------------------------------
    println("=" ^ 80)
    println("PHASE 6 WELFARE ANALYSIS COMPLETE")
    println("  Scenarios processed: $(length(welfare_results))")
    println("  Welfare CSV: results/welfare.csv ($(nrow(welfare_df)) rows)")
    println("  Accounting identity: $(all_pass ? "VERIFIED" : "FAILED")")
    println("=" ^ 80)
end

# Run
main()
