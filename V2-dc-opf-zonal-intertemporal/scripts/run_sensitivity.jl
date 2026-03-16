# run_sensitivity.jl -- Sensitivity analysis: NE-SE transmission sweep + policy parameter sweeps
#
# Part 1: NE-SE Transmission Capacity Sweep (re-solves required)
#   - 4 existing data points from summary.csv (tx_expansion_mw = 0, 2000, 5000, 10000)
#   - 6 new re-solves for intermediate values (1000, 3000, 4000, 6000, 7000, 8000)
#   - Produces sensitivity_ne_se.csv with 10 rows
#   - Generates 3 NE-SE figures: curtailment, LMP convergence, combined 2-panel
#
# Part 2: Carbon Tax Sensitivity (existing data only)
#   - Reads summary.csv and welfare.csv for 3 carbon scenarios (baseline, carbon_50, carbon_100)
#   - Generates 3-panel carbon tax sensitivity figure
#
# Part 3: Battery Placement Sensitivity (existing data only)
#   - Reads summary.csv and welfare.csv for battery scenarios
#   - Generates battery placement value figure
#
# Usage: julia scripts/run_sensitivity.jl

include(joinpath(@__DIR__, "..", "src", "display.jl"))
include(joinpath(@__DIR__, "plot_helpers.jl"))


# =============================================================================
# Constants
# =============================================================================

const SEASONS = ["wet", "dry"]
const PERIODS = ["night", "day", "peak"]

# NE-SE sweep: existing scenario tx_expansion_mw values and their scenario_id mappings
const EXISTING_TX_POINTS = Dict(
    0     => "baseline",
    2000  => "tx_expand_2000",
    5000  => "tx_expand_5000",
    10000 => "tx_expand_10000",
)

# NE-SE sweep: new intermediate points requiring re-solves (no carbon, no subsidy, no battery)
const NEW_TX_POINTS = [1000, 3000, 4000, 6000, 7000, 8000]

# Baseline NE-SE capacity from transmission.csv
const NE_SE_BASELINE_MW = 10000.0


# =============================================================================
# Part 1: NE-SE Transmission Capacity Sweep
# =============================================================================

"""
    solve_sweep_point(data, tx_additional_mw) -> NamedTuple

Solve SCED for all 6 cases (3 periods x 2 seasons) with NE-SE capacity expanded
by `tx_additional_mw` MW. No carbon tax, no subsidy, no battery.

Returns annual metrics: curtailment, LMP per node, cost.
"""
function solve_sweep_point(data::SystemData, tx_additional_mw::Int)
    scenario = ScenarioDef(
        "sweep_$(tx_additional_mw)",
        0.0,                        # no carbon tax
        0.0,                        # no subsidy
        "none",                     # no battery
        "NE_SE",                    # expand NE-SE line
        Float64(tx_additional_mw),  # additional MW
    )

    # Accumulate annual metrics across 6 cases
    annual_curtailment = 0.0
    annual_cost_full = 0.0
    annual_cost_nonpeak = 0.0
    lmp_weighted = Dict("N1" => 0.0, "NE1" => 0.0, "SE1" => 0.0, "S1" => 0.0)
    total_hours = 0.0
    n_solves = 0

    for season in SEASONS
        for period in PERIODS
            hours = get_period_hours(data, period)
            annual_hours = hours * 182.5  # 182.5 days per season (365/2)

            case = build_case_data(data, season, period, scenario)
            result = solve_sced(case)

            if result.solver_status != "OPTIMAL"
                error("Solver failed for sweep_$(tx_additional_mw) / $(season) / $(period): $(result.solver_status)")
            end
            n_solves += 1

            # Curtailment (MW * annual_hours = MWh/year contribution)
            if !isempty(result.curtailment)
                annual_curtailment += sum(values(result.curtailment)) * annual_hours
            end

            # Cost
            annual_cost_full += result.total_cost * annual_hours
            if period != "peak"
                annual_cost_nonpeak += result.total_cost * annual_hours
            end

            # LMP hour-weighting
            for nid in keys(lmp_weighted)
                lmp_weighted[nid] += get(result.lmps, nid, 0.0) * annual_hours
            end
            total_hours += annual_hours
        end
    end

    # Compute hour-weighted average LMPs
    avg_lmps = Dict(nid => lmp_weighted[nid] / total_hours for nid in keys(lmp_weighted))

    return (
        tx_additional_mw = tx_additional_mw,
        tx_actual_mw = NE_SE_BASELINE_MW + tx_additional_mw,
        annual_curtailment_mwh = annual_curtailment,
        avg_lmp_NE1 = avg_lmps["NE1"],
        avg_lmp_SE1 = avg_lmps["SE1"],
        lmp_spread_NE_SE = avg_lmps["NE1"] - avg_lmps["SE1"],
        annual_cost_nonpeak = annual_cost_nonpeak,
        n_solves = n_solves,
    )
end


"""
    extract_existing_point(summary_df, tx_additional_mw, scenario_id) -> NamedTuple

Extract NE-SE sweep metrics for an existing scenario from summary.csv.
"""
function extract_existing_point(summary_df::DataFrame, tx_additional_mw::Int, scenario_id::String)
    row = filter(r -> r.scenario_id == scenario_id, summary_df)
    nrow(row) == 1 || error("Expected 1 row for scenario '$scenario_id', got $(nrow(row))")
    r = row[1, :]

    return (
        tx_additional_mw = tx_additional_mw,
        tx_actual_mw = NE_SE_BASELINE_MW + tx_additional_mw,
        annual_curtailment_mwh = r.annual_curtailment_mwh,
        avg_lmp_NE1 = r.avg_lmp_NE1,
        avg_lmp_SE1 = r.avg_lmp_SE1,
        lmp_spread_NE_SE = r.avg_lmp_NE1 - r.avg_lmp_SE1,
        annual_cost_nonpeak = r.annual_cost_nonpeak,
        n_solves = 0,  # existing data, no re-solve
    )
end


"""
    run_ne_se_sweep(data, summary_df) -> DataFrame

Run the full NE-SE transmission capacity sweep: extract 4 existing points from
summary.csv and solve 6 new intermediate points. Returns a DataFrame with 10 rows
sorted by tx_additional_mw.
"""
function run_ne_se_sweep(data::SystemData, summary_df::DataFrame)
    println("-" ^ 60)
    println("Part 1: NE-SE Transmission Capacity Sweep")
    println("-" ^ 60)

    all_points = NamedTuple[]

    # Extract existing points from summary.csv (no re-solving needed)
    println("\nExtracting existing data points from summary.csv...")
    for (tx_mw, sid) in sort(collect(EXISTING_TX_POINTS), by=first)
        point = extract_existing_point(summary_df, tx_mw, sid)
        push!(all_points, point)
        println("  tx_additional=$(tx_mw) MW ($(sid)): " *
                "curtailment=$(round(point.annual_curtailment_mwh / 1e3, digits=1)) GWh/yr, " *
                "LMP spread=$(round(point.lmp_spread_NE_SE, digits=1)) \$/MWh")
    end

    # Solve new intermediate points
    println("\nSolving new intermediate points...")
    for tx_mw in sort(NEW_TX_POINTS)
        println("  Solving tx_additional=$(tx_mw) MW...")
        point = solve_sweep_point(data, tx_mw)
        push!(all_points, point)
        println("    curtailment=$(round(point.annual_curtailment_mwh / 1e3, digits=1)) GWh/yr, " *
                "LMP spread=$(round(point.lmp_spread_NE_SE, digits=1)) \$/MWh " *
                "($(point.n_solves) solves, all OPTIMAL)")
    end

    # Build DataFrame sorted by tx_additional_mw
    df = DataFrame(all_points)
    sort!(df, :tx_additional_mw)

    return df
end


# =============================================================================
# NE-SE Figures (Part 1)
# =============================================================================

"""
    plot_ne_se_curtailment(sweep_df)

Figure 1: Curtailment vs NE-SE line capacity.
Line plot with markers; existing scenario points highlighted with larger markers.
"""
function plot_ne_se_curtailment(sweep_df::DataFrame)
    println("Generating: sensitivity_ne_se_curtailment")

    x = sweep_df.tx_actual_mw ./ 1e3  # GW
    y = sweep_df.annual_curtailment_mwh ./ 1e3  # GWh/yr

    # Identify which points are existing vs new
    existing_mask = [row.tx_additional_mw in keys(EXISTING_TX_POINTS) for row in eachrow(sweep_df)]

    p = plot(x, y;
        xlabel     = "NE-SE Line Capacity (GW)",
        ylabel     = "Annual Curtailment (GWh/yr)",
        title      = "Curtailment vs NE-SE Line Capacity",
        linewidth  = 2,
        marker     = :circle,
        markersize = 4,
        color      = FAMILY_COLORS["tx_expand"],
        legend     = false,
        size       = (FIG_WIDTH, FIG_HEIGHT),
    )

    # Highlight existing scenario points with larger markers
    x_existing = x[existing_mask]
    y_existing = y[existing_mask]
    scatter!(x_existing, y_existing;
        markersize = 8,
        markershape = :diamond,
        color = FAMILY_COLORS["tx_expand"],
        markerstrokewidth = 2,
        label = nothing,
    )

    save_figure(p, "sensitivity_ne_se_curtailment")
    return p
end


"""
    plot_ne_se_lmp(sweep_df)

Figure 2: NE-SE LMP spread convergence as line capacity increases.
"""
function plot_ne_se_lmp(sweep_df::DataFrame)
    println("Generating: sensitivity_ne_se_lmp")

    x = sweep_df.tx_actual_mw ./ 1e3  # GW
    y = sweep_df.lmp_spread_NE_SE      # $/MWh (NE1 - SE1)

    existing_mask = [row.tx_additional_mw in keys(EXISTING_TX_POINTS) for row in eachrow(sweep_df)]

    p = plot(x, y;
        xlabel     = "NE-SE Line Capacity (GW)",
        ylabel     = "NE-SE LMP Spread (\$/MWh)",
        title      = "NE-SE Price Convergence",
        linewidth  = 2,
        marker     = :circle,
        markersize = 4,
        color      = FAMILY_COLORS["tx_expand"],
        legend     = false,
        size       = (FIG_WIDTH, FIG_HEIGHT),
    )

    # Highlight existing scenario points
    scatter!(x[existing_mask], y[existing_mask];
        markersize = 8,
        markershape = :diamond,
        color = FAMILY_COLORS["tx_expand"],
        markerstrokewidth = 2,
        label = nothing,
    )

    hline!([0]; color=:black, linestyle=:dash, linewidth=0.5, label=nothing)

    save_figure(p, "sensitivity_ne_se_lmp")
    return p
end


"""
    plot_ne_se_combined(sweep_df)

Figure 3: Combined 2-panel -- curtailment (top) and LMP spread (bottom).
This is the primary NE-SE sensitivity figure for the paper.
"""
function plot_ne_se_combined(sweep_df::DataFrame)
    println("Generating: sensitivity_ne_se_combined")

    x = sweep_df.tx_actual_mw ./ 1e3  # GW
    curtailment = sweep_df.annual_curtailment_mwh ./ 1e3  # GWh/yr
    lmp_spread = sweep_df.lmp_spread_NE_SE

    existing_mask = [row.tx_additional_mw in keys(EXISTING_TX_POINTS) for row in eachrow(sweep_df)]

    # Panel 1: Curtailment
    p1 = plot(x, curtailment;
        ylabel     = "Curtailment (GWh/yr)",
        title      = "Curtailment vs NE-SE Line Capacity",
        linewidth  = 2,
        marker     = :circle,
        markersize = 4,
        color      = FAMILY_COLORS["tx_expand"],
        legend     = false,
        bottom_margin = 2Plots.mm,
    )
    scatter!(p1, x[existing_mask], curtailment[existing_mask];
        markersize = 8, markershape = :diamond,
        color = FAMILY_COLORS["tx_expand"],
        markerstrokewidth = 2, label = nothing,
    )

    # Panel 2: LMP spread
    p2 = plot(x, lmp_spread;
        xlabel     = "NE-SE Line Capacity (GW)",
        ylabel     = "NE-SE LMP Spread (\$/MWh)",
        title      = "NE-SE Price Convergence",
        linewidth  = 2,
        marker     = :circle,
        markersize = 4,
        color      = FAMILY_COLORS["tx_expand"],
        legend     = false,
        top_margin = 2Plots.mm,
    )
    scatter!(p2, x[existing_mask], lmp_spread[existing_mask];
        markersize = 8, markershape = :diamond,
        color = FAMILY_COLORS["tx_expand"],
        markerstrokewidth = 2, label = nothing,
    )
    hline!(p2, [0]; color=:black, linestyle=:dash, linewidth=0.5, label=nothing)

    p = plot(p1, p2; layout=(2, 1), size=(900, 800))

    save_figure(p, "sensitivity_ne_se_combined")
    return p
end


# =============================================================================
# Part 2: Carbon Tax Sensitivity (existing data only)
# =============================================================================

"""
    plot_carbon_sweep(summary_df, welfare_df)

Figure 4: 3-panel carbon tax sensitivity (emissions, cost, welfare delta).
Uses existing data for 3 carbon scenarios (0, 50, 100 \$/tCO2).
"""
function plot_carbon_sweep(summary_df::DataFrame, welfare_df::DataFrame)
    println("\n" * "-" ^ 60)
    println("Part 2: Carbon Tax Sensitivity")
    println("-" ^ 60)
    println("Generating: sensitivity_carbon_sweep")

    # Carbon tax scenarios (ordered by tax rate)
    carbon_ids = ["baseline", "carbon_50", "carbon_100"]
    tax_rates = [0.0, 50.0, 100.0]

    # Extract data from summary and welfare
    df_s = filter(r -> r.scenario_id in carbon_ids, summary_df)
    df_w = filter(r -> r.scenario_id in carbon_ids, welfare_df)

    # Sort both by tax rate order
    order = Dict(s => i for (i, s) in enumerate(carbon_ids))
    df_s.sort_key = [get(order, s, 0) for s in df_s.scenario_id]
    df_w.sort_key = [get(order, s, 0) for s in df_w.scenario_id]
    sort!(df_s, :sort_key)
    sort!(df_w, :sort_key)

    x = tax_rates

    # Panel 1: Annual emissions (ktCO2/yr)
    p1 = plot(x, df_s.annual_emissions_tco2 ./ 1e3;
        ylabel     = "ktCO2/yr",
        title      = "Annual Emissions",
        linewidth  = 2,
        marker     = :circle,
        markersize = 6,
        color      = FAMILY_COLORS["carbon"],
        legend     = false,
    )

    # Panel 2: Non-peak annual cost (B $/yr)
    p2 = plot(x, df_s.annual_cost_nonpeak ./ 1e9;
        ylabel     = "B \$/yr",
        title      = "Non-Peak Annual Cost",
        linewidth  = 2,
        marker     = :circle,
        markersize = 6,
        color      = FAMILY_COLORS["carbon"],
        legend     = false,
    )

    # Panel 3: Welfare delta (B $/yr)
    p3 = plot(x, df_w.welfare_delta_vs_baseline ./ 1e9;
        xlabel     = "Carbon Tax (\$/tCO2)",
        ylabel     = "B \$/yr",
        title      = "Welfare Delta vs Baseline",
        linewidth  = 2,
        marker     = :circle,
        markersize = 6,
        color      = FAMILY_COLORS["carbon"],
        legend     = false,
    )
    hline!(p3, [0]; color=:black, linestyle=:dash, linewidth=0.5, label=nothing)

    p = plot(p1, p2, p3; layout=(3, 1), size=(800, 900),
             plot_title="Carbon Tax Sensitivity")

    save_figure(p, "sensitivity_carbon_sweep")
    return p
end


# =============================================================================
# Part 3: Battery Placement Sensitivity (per-battery data from battery_all)
# =============================================================================

# Battery node IDs and display labels for per-battery analysis
const BATTERY_NODES = ["N1", "NE1", "SE1", "S1"]
const NODE_LABELS = Dict("N1" => "North", "NE1" => "Northeast",
                         "SE1" => "Southeast", "S1" => "South")
const BATTERY_ENERGY_MWH_SENS = 2000.0  # from battery.csv

"""
    load_per_battery_metrics(scenario_id) -> Dict{String, NamedTuple}

Read a battery_all CSV and compute annualized per-battery profit and revenue.
Returns Dict keyed by node_id with fields: profit_mr, revenue_mr, charge_cost_mr.
"""
function load_per_battery_metrics(scenario_id::String)
    path = joinpath(@__DIR__, "..", "results", "$(scenario_id).csv")
    isfile(path) || return nothing

    df = CSV.read(path, DataFrame)
    daily_factor = 182.5 / 10  # 10 days per season, 182.5 days per season

    metrics = Dict{String, NamedTuple}()

    for nid in BATTERY_NODES
        bn = "Battery_$(nid)"

        annual_revenue = 0.0
        annual_charge_cost = 0.0

        for season in ["wet", "dry"]
            sdf = filter(r -> r.season == season, df)
            annual_revenue += sum(sdf[!, "revenue_$(bn)"]) * daily_factor
            annual_charge_cost += sum(sdf[!, "charge_cost_$(bn)"]) * daily_factor
        end

        metrics[nid] = (
            revenue_mr = annual_revenue / 1e6,
            charge_cost_mr = annual_charge_cost / 1e6,
            profit_mr = (annual_revenue - annual_charge_cost) / 1e6,
        )
    end

    return metrics
end

"""
    plot_battery_placement(summary_df, welfare_df)

Figure 5: Battery value by node from the battery_all scenario.
Top panel: per-battery annual profit (no tax vs carbon \$50).
Bottom panel: per-battery revenue vs charging cost.
"""
function plot_battery_placement(summary_df::DataFrame, welfare_df::DataFrame)
    println("\n" * "-" ^ 60)
    println("Part 3: Battery Placement Sensitivity")
    println("-" ^ 60)
    println("Generating: sensitivity_battery_placement")

    metrics_base = load_per_battery_metrics("battery_all")
    metrics_c50 = load_per_battery_metrics("carbon_50_battery_all")

    if metrics_base === nothing || metrics_c50 === nothing
        println("  SKIP: battery_all.csv or carbon_50_battery_all.csv not found")
        return nothing
    end

    n = length(BATTERY_NODES)
    x = 1:n
    labels = [NODE_LABELS[nid] for nid in BATTERY_NODES]

    profits_base = [metrics_base[nid].profit_mr for nid in BATTERY_NODES]
    profits_c50 = [metrics_c50[nid].profit_mr for nid in BATTERY_NODES]

    bar_width = 0.35

    # Panel 1: Per-battery profit (grouped bar: no tax vs carbon $50)
    max_profit = maximum([profits_base; profits_c50])
    p1 = plot(;
        ylabel = "M R\$/yr",
        title  = "Annual Battery Profit by Node",
        legend = :outerbottom,
        ylims  = (0, max_profit * 1.15),
    )

    bar!(p1, collect(x) .- bar_width / 2, profits_base;
        bar_width = bar_width,
        color = :steelblue,
        label = "No Carbon Tax",
    )
    bar!(p1, collect(x) .+ bar_width / 2, profits_c50;
        bar_width = bar_width,
        color = :orangered,
        label = "Carbon Tax \$50",
    )
    plot!(p1; xticks = (collect(x), labels))

    # Panel 2: Revenue vs charging cost breakdown (baseline scenario)
    revenues = [metrics_base[nid].revenue_mr for nid in BATTERY_NODES]
    costs = [metrics_base[nid].charge_cost_mr for nid in BATTERY_NODES]

    max_rev_cost = maximum([revenues; costs])
    p2 = plot(;
        ylabel = "M R\$/yr",
        title  = "Revenue vs Charging Cost (No Carbon Tax)",
        legend = :outerbottom,
        ylims  = (0, max_rev_cost * 1.15),
    )

    bar!(p2, collect(x) .- bar_width / 2, revenues;
        bar_width = bar_width,
        color = FAMILY_COLORS["battery"],
        label = "Discharge Revenue",
    )
    bar!(p2, collect(x) .+ bar_width / 2, costs;
        bar_width = bar_width,
        color = :lightblue,
        label = "Charging Cost",
    )
    plot!(p2; xticks = (collect(x), labels))

    # Panel 3: Revenue vs charging cost breakdown (carbon $50 scenario)
    revenues_c50 = [metrics_c50[nid].revenue_mr for nid in BATTERY_NODES]
    costs_c50 = [metrics_c50[nid].charge_cost_mr for nid in BATTERY_NODES]

    max_rev_cost_c50 = maximum([revenues_c50; costs_c50])
    p3 = plot(;
        ylabel = "M R\$/yr",
        title  = "Revenue vs Charging Cost (Carbon Tax \$50)",
        legend = :outerbottom,
        ylims  = (0, max_rev_cost_c50 * 1.15),
    )

    bar!(p3, collect(x) .- bar_width / 2, revenues_c50;
        bar_width = bar_width,
        color = FAMILY_COLORS["carbon"],
        label = "Discharge Revenue",
    )
    bar!(p3, collect(x) .+ bar_width / 2, costs_c50;
        bar_width = bar_width,
        color = :lightsalmon,
        label = "Charging Cost",
    )
    plot!(p3; xticks = (collect(x), labels))

    p = plot(p1, p2, p3; layout=(3, 1), size=(900, 1100),
             plot_title="Battery Value by Node (battery_all scenario)")

    save_figure(p, "sensitivity_battery_placement")
    return p
end


# =============================================================================
# Main
# =============================================================================

function main()
    println("=" ^ 60)
    println("SENSITIVITY ANALYSIS")
    println("=" ^ 60)
    println()

    set_plot_defaults()

    # Load existing results
    results_dir = joinpath(@__DIR__, "..", "results")
    summary_df = CSV.read(joinpath(results_dir, "summary.csv"), DataFrame)
    welfare_df = CSV.read(joinpath(results_dir, "welfare.csv"), DataFrame)
    println("Loaded summary.csv ($(nrow(summary_df)) rows) and welfare.csv ($(nrow(welfare_df)) rows)")

    # Load system data for re-solves
    data_dir = joinpath(@__DIR__, "..", "data", "output")
    data = load_system(data_dir)
    println("Loaded system data ($(length(data.generators)) generators, $(length(data.nodes)) nodes)")
    println()

    # -------------------------------------------------------------------------
    # Part 1: NE-SE Transmission Sweep
    # -------------------------------------------------------------------------
    sweep_df = run_ne_se_sweep(data, summary_df)

    # Save sweep results to CSV
    sweep_csv_path = joinpath(results_dir, "sensitivity_ne_se.csv")
    CSV.write(sweep_csv_path, sweep_df[:, Not(:n_solves)])  # exclude internal field
    println("\nSaved: $(sweep_csv_path) ($(nrow(sweep_df)) rows)")

    # Generate NE-SE figures
    println()
    plot_ne_se_curtailment(sweep_df)
    plot_ne_se_lmp(sweep_df)
    plot_ne_se_combined(sweep_df)

    # -------------------------------------------------------------------------
    # Part 2: Carbon Tax Sensitivity
    # -------------------------------------------------------------------------
    plot_carbon_sweep(summary_df, welfare_df)

    # -------------------------------------------------------------------------
    # Part 3: Battery Placement Sensitivity
    # -------------------------------------------------------------------------
    plot_battery_placement(summary_df, welfare_df)

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    println()
    println("=" ^ 60)
    println("SENSITIVITY ANALYSIS COMPLETE")
    println("  NE-SE sweep: $(nrow(sweep_df)) data points (4 existing + 6 new re-solves)")
    println("  CSV output: results/sensitivity_ne_se.csv")
    println("  Figures: 5 saved to results/figures/")
    println("    - sensitivity_ne_se_curtailment (.png/.pdf)")
    println("    - sensitivity_ne_se_lmp (.png/.pdf)")
    println("    - sensitivity_ne_se_combined (.png/.pdf)")
    println("    - sensitivity_carbon_sweep (.png/.pdf)")
    println("    - sensitivity_battery_placement (.png/.pdf)")
    println("=" ^ 60)
end

# Run
main()
