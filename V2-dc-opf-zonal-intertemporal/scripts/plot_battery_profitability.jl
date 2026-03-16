# plot_battery_profitability.jl -- Battery profitability comparison figures
#
# Reads battery_all.csv and carbon_50_battery_all.csv to generate figures
# showing per-battery profitability differences across nodes:
#   1. Net profit by node (grouped bar: no carbon vs carbon_50)
#   2. Revenue vs charging cost breakdown (stacked bar per node)
#   3. LMP-driven arbitrage: discharge revenue per MWh vs charging cost per MWh
#
# Usage: julia --project=. scripts/plot_battery_profitability.jl

include(joinpath(@__DIR__, "plot_helpers.jl"))


# =============================================================================
# Constants
# =============================================================================

const BATTERY_NODES = ["N1", "NE1", "SE1", "S1"]
const NODE_LABELS = Dict("N1" => "North", "NE1" => "Northeast",
                         "SE1" => "Southeast", "S1" => "South")
const BATTERY_ENERGY_MWH = 2000.0  # from battery.csv


# =============================================================================
# Data loading
# =============================================================================

"""
    load_battery_profitability(scenario_id) -> Dict{String, NamedTuple}

Read a battery_all CSV file and compute annualized per-battery metrics.
Returns a Dict keyed by node_id (e.g., "N1") with fields:
  charge_gwh, discharge_gwh, revenue_mr, charge_cost_mr, profit_mr, cycles_per_day
"""
function load_battery_profitability(scenario_id::String)
    path = joinpath(@__DIR__, "..", "results", "$(scenario_id).csv")
    isfile(path) || error("CSV not found: $path")

    df = CSV.read(path, DataFrame)

    # Annualization: 60 rows = 30 wet + 30 dry periods over 10 days per season
    # Daily factor: 182.5 / 10 per season, applied to each season's sum
    daily_factor = 182.5 / 10

    metrics = Dict{String, NamedTuple}()

    for nid in BATTERY_NODES
        bn = "Battery_$(nid)"

        # Split by season and annualize
        annual_charge_mwh = 0.0
        annual_discharge_mwh = 0.0
        annual_revenue = 0.0
        annual_charge_cost = 0.0

        for season in ["wet", "dry"]
            sdf = filter(r -> r.season == season, df)

            # Revenue and charge_cost columns are already R$ per period (MW * hours * LMP)
            season_revenue = sum(sdf[!, "revenue_$(bn)"])
            season_chg_cost = sum(sdf[!, "charge_cost_$(bn)"])

            # Convert MW to MWh using hours per period
            season_charge_mwh = sum(sdf[!, "charge_$(bn)"] .* sdf.hours)
            season_discharge_mwh = sum(sdf[!, "discharge_$(bn)"] .* sdf.hours)

            annual_charge_mwh += season_charge_mwh * daily_factor
            annual_discharge_mwh += season_discharge_mwh * daily_factor
            annual_revenue += season_revenue * daily_factor
            annual_charge_cost += season_chg_cost * daily_factor
        end

        cycles_per_day = (annual_discharge_mwh / 365.0) / BATTERY_ENERGY_MWH

        metrics[nid] = (
            charge_gwh = annual_charge_mwh / 1e3,
            discharge_gwh = annual_discharge_mwh / 1e3,
            revenue_mr = annual_revenue / 1e6,
            charge_cost_mr = annual_charge_cost / 1e6,
            profit_mr = (annual_revenue - annual_charge_cost) / 1e6,
            cycles_per_day = cycles_per_day,
        )
    end

    return metrics
end


# =============================================================================
# Figure 1: Net Profit by Node (Grouped Bar: baseline vs carbon_50)
# =============================================================================

function figure_profit_by_node(metrics_base, metrics_carbon)
    println("Figure: battery_profit_by_node")

    n = length(BATTERY_NODES)
    x = 1:n
    labels = [NODE_LABELS[nid] for nid in BATTERY_NODES]

    profits_base = [metrics_base[nid].profit_mr for nid in BATTERY_NODES]
    profits_carbon = [metrics_carbon[nid].profit_mr for nid in BATTERY_NODES]

    bar_width = 0.35
    x_base = collect(x) .- bar_width / 2
    x_carbon = collect(x) .+ bar_width / 2

    p = plot(;
        title  = "Annual Battery Profit by Location",
        ylabel = "Net Profit (M R\$/yr)",
        xlabel = "",
        legend = :outerbottom,
        size   = (900, 680),
        ylims  = (0, maximum([profits_base; profits_carbon]) * 1.15),
    )

    bar!(p, x_base, profits_base;
        bar_width = bar_width,
        color = :steelblue,
        label = "No Carbon Tax",
    )

    bar!(p, x_carbon, profits_carbon;
        bar_width = bar_width,
        color = :orangered,
        label = "Carbon Tax \$50",
    )

    plot!(p; xticks = (collect(x), labels))

    save_figure(p, "battery_profit_by_node")
    return p
end


# =============================================================================
# Figure 2: Revenue vs Charging Cost Breakdown (per node, both scenarios)
# =============================================================================

function figure_revenue_breakdown(metrics_base, metrics_carbon)
    println("Figure: battery_revenue_breakdown")

    n = length(BATTERY_NODES)
    labels = [NODE_LABELS[nid] for nid in BATTERY_NODES]

    # Extract data: 4 series (revenue/cost × no_tax/c50)
    rev_base  = [metrics_base[nid].revenue_mr for nid in BATTERY_NODES]
    cost_base = [metrics_base[nid].charge_cost_mr for nid in BATTERY_NODES]
    rev_c50   = [metrics_carbon[nid].revenue_mr for nid in BATTERY_NODES]
    cost_c50  = [metrics_carbon[nid].charge_cost_mr for nid in BATTERY_NODES]

    # 4 sub-bars per node, arranged symmetrically around the node center
    bar_w = 0.18
    offsets = [-1.5bar_w, -0.5bar_w, 0.5bar_w, 1.5bar_w]
    x = collect(1:n)

    y_max = maximum([rev_base; rev_c50]) * 1.15
    p = plot(;
        title  = "Battery Revenue vs Charging Cost by Location",
        ylabel = "M R\$/yr",
        xlabel = "",
        legend = :outerbottom,
        size   = (900, 700),
        ylims  = (0, y_max),
    )

    bar!(p, x .+ offsets[1], rev_base;
        bar_width = bar_w, color = :steelblue, label = "Revenue (No Tax)")
    bar!(p, x .+ offsets[2], cost_base;
        bar_width = bar_w, color = :lightblue, label = "Chg Cost (No Tax)")
    bar!(p, x .+ offsets[3], rev_c50;
        bar_width = bar_w, color = :orangered, label = "Revenue (C\$50)")
    bar!(p, x .+ offsets[4], cost_c50;
        bar_width = bar_w, color = :lightsalmon, label = "Chg Cost (C\$50)")

    plot!(p; xticks = (x, labels))

    save_figure(p, "battery_revenue_breakdown")
    return p
end


# =============================================================================
# Figures 2b/2c: Revenue Breakdown by Season (Wet / Dry separately)
# =============================================================================

"""
    load_battery_profitability_season(scenario_id, season) -> Dict{String, NamedTuple}

Like load_battery_profitability but for a single season only.
Returns Dict keyed by node_id with fields: revenue_mr, charge_cost_mr, profit_mr.
"""
function load_battery_profitability_season(scenario_id::String, season::String)
    path = joinpath(@__DIR__, "..", "results", "$(scenario_id).csv")
    isfile(path) || error("CSV not found: $path")

    df = CSV.read(path, DataFrame)
    daily_factor = 182.5 / 10  # 10 simulated days → 182.5 calendar days

    metrics = Dict{String, NamedTuple}()

    for nid in BATTERY_NODES
        bn = "Battery_$(nid)"
        sdf = filter(r -> r.season == season, df)

        annual_revenue = sum(sdf[!, "revenue_$(bn)"]) * daily_factor
        annual_charge_cost = sum(sdf[!, "charge_cost_$(bn)"]) * daily_factor

        metrics[nid] = (
            revenue_mr = annual_revenue / 1e6,
            charge_cost_mr = annual_charge_cost / 1e6,
            profit_mr = (annual_revenue - annual_charge_cost) / 1e6,
        )
    end

    return metrics
end


"""
Plot revenue vs charging cost for a single season, both scenarios side by side.
"""
function figure_revenue_breakdown_season(season::String, metrics_base, metrics_carbon)
    season_title = titlecase(season)
    fig_name = "battery_revenue_breakdown_$(season)"
    println("Figure: $(fig_name)")

    n = length(BATTERY_NODES)
    labels = [NODE_LABELS[nid] for nid in BATTERY_NODES]

    rev_base  = [metrics_base[nid].revenue_mr for nid in BATTERY_NODES]
    cost_base = [metrics_base[nid].charge_cost_mr for nid in BATTERY_NODES]
    rev_c50   = [metrics_carbon[nid].revenue_mr for nid in BATTERY_NODES]
    cost_c50  = [metrics_carbon[nid].charge_cost_mr for nid in BATTERY_NODES]

    bar_w = 0.18
    offsets = [-1.5bar_w, -0.5bar_w, 0.5bar_w, 1.5bar_w]
    x = collect(1:n)

    y_max = maximum([rev_base; rev_c50]) * 1.15
    p = plot(;
        title  = "Battery Revenue vs Charging Cost — $(season_title) Season",
        ylabel = "M R\$/yr",
        xlabel = "",
        legend = :outerbottom,
        size   = (900, 700),
        ylims  = (0, max(y_max, 1.0)),  # avoid zero ylim if all values are tiny
    )

    bar!(p, x .+ offsets[1], rev_base;
        bar_width = bar_w, color = :steelblue, label = "Revenue (No Tax)")
    bar!(p, x .+ offsets[2], cost_base;
        bar_width = bar_w, color = :lightblue, label = "Chg Cost (No Tax)")
    bar!(p, x .+ offsets[3], rev_c50;
        bar_width = bar_w, color = :orangered, label = "Revenue (C\$50)")
    bar!(p, x .+ offsets[4], cost_c50;
        bar_width = bar_w, color = :lightsalmon, label = "Chg Cost (C\$50)")

    plot!(p; xticks = (x, labels))

    save_figure(p, fig_name)
    return p
end


# =============================================================================
# Figure 3: Arbitrage Spread -- Revenue and Cost per MWh discharged
# =============================================================================

function figure_arbitrage_spread(metrics_base, metrics_carbon)
    println("Figure: battery_arbitrage_spread")

    n = length(BATTERY_NODES)
    labels = [NODE_LABELS[nid] for nid in BATTERY_NODES]

    # Compute R$/MWh metrics (revenue per MWh discharged, cost per MWh charged)
    rev_per_mwh_base = [metrics_base[nid].revenue_mr * 1e6 /
                         (metrics_base[nid].discharge_gwh * 1e3) for nid in BATTERY_NODES]
    cost_per_mwh_base = [metrics_base[nid].charge_cost_mr * 1e6 /
                          (metrics_base[nid].charge_gwh * 1e3) for nid in BATTERY_NODES]

    rev_per_mwh_c50 = [metrics_carbon[nid].revenue_mr * 1e6 /
                        (metrics_carbon[nid].discharge_gwh * 1e3) for nid in BATTERY_NODES]
    cost_per_mwh_c50 = [metrics_carbon[nid].charge_cost_mr * 1e6 /
                         (metrics_carbon[nid].charge_gwh * 1e3) for nid in BATTERY_NODES]

    x = 1:n

    all_values = [rev_per_mwh_base; cost_per_mwh_base; rev_per_mwh_c50; cost_per_mwh_c50]
    p = plot(;
        title  = "Battery Arbitrage Spread by Location",
        ylabel = "R\$/MWh",
        xlabel = "",
        legend = :outerbottom,
        size   = (900, 700),
        ylims  = (0, maximum(all_values) * 1.15),
    )

    # Discharge revenue per MWh (markers)
    scatter!(p, collect(x) .- 0.15, rev_per_mwh_base;
        markersize = 8, markershape = :utriangle, color = :steelblue,
        label = "Discharge Price (No Tax)")
    scatter!(p, collect(x) .+ 0.15, rev_per_mwh_c50;
        markersize = 8, markershape = :utriangle, color = :orangered,
        label = "Discharge Price (C\$50)")

    # Charging cost per MWh (markers)
    scatter!(p, collect(x) .- 0.15, cost_per_mwh_base;
        markersize = 8, markershape = :dtriangle, color = :steelblue,
        markerstrokewidth = 2, label = "Charge Price (No Tax)")
    scatter!(p, collect(x) .+ 0.15, cost_per_mwh_c50;
        markersize = 8, markershape = :dtriangle, color = :orangered,
        markerstrokewidth = 2, label = "Charge Price (C\$50)")

    # Connect with vertical lines showing spread
    for (i, _) in enumerate(BATTERY_NODES)
        plot!(p, [i - 0.15, i - 0.15], [cost_per_mwh_base[i], rev_per_mwh_base[i]];
            color = :steelblue, linewidth = 2, linestyle = :dash, label = nothing)
        plot!(p, [i + 0.15, i + 0.15], [cost_per_mwh_c50[i], rev_per_mwh_c50[i]];
            color = :orangered, linewidth = 2, linestyle = :dash, label = nothing)
    end

    plot!(p; xticks = (collect(x), labels))

    save_figure(p, "battery_arbitrage_spread")
    return p
end


# =============================================================================
# Main
# =============================================================================

function main()
    println("=" ^ 60)
    println("Battery Profitability Figures")
    println("=" ^ 60)
    println()

    set_plot_defaults()

    # Load per-battery metrics from CSVs
    println("Loading battery_all scenario data...")
    metrics_base = load_battery_profitability("battery_all")
    metrics_carbon = load_battery_profitability("carbon_50_battery_all")

    # Print summary for verification
    println()
    println("Per-battery annual profit (M R\$/yr):")
    for nid in BATTERY_NODES
        b = metrics_base[nid]
        c = metrics_carbon[nid]
        println("  $(rpad(NODE_LABELS[nid], 12))  No tax: $(round(b.profit_mr, digits=1))  " *
                "Carbon \$50: $(round(c.profit_mr, digits=1))")
    end
    println()

    # Generate figures
    figure_profit_by_node(metrics_base, metrics_carbon)
    figure_revenue_breakdown(metrics_base, metrics_carbon)
    figure_arbitrage_spread(metrics_base, metrics_carbon)

    # Seasonal revenue breakdown figures (wet and dry separately)
    for season in ["wet", "dry"]
        println("\nLoading $(season)-season per-battery metrics...")
        season_base = load_battery_profitability_season("battery_all", season)
        season_carbon = load_battery_profitability_season("carbon_50_battery_all", season)
        figure_revenue_breakdown_season(season, season_base, season_carbon)
    end

    println()
    println("=" ^ 60)
    println("All battery profitability figures saved to results/figures/")
    println("=" ^ 60)
end

main()
