# plot_figures.jl -- 7 focused figures for the SYPA paper
#
# Generates:
#   1. Merit order shift: baseline vs carbon_50 supply curves (dry/peak)
#   2. Battery SOC trajectory: battery NE, wet season
#   3. NE-SE transmission sensitivity: curtailment + LMP spread (2-panel)
#   4. Generation mix: stacked bar for 5 scenarios (dry/peak)
#   5. Merit order shift: baseline vs carbon_50 supply curves (wet/peak)
#   6. Battery profit by season: grouped bar for 4 battery nodes
#   7. SOC profiles: 2×4 panel grid for all batteries, wet + dry
#
# Usage: julia scripts/plot_figures.jl

include(joinpath(@__DIR__, "plot_helpers.jl"))


# =============================================================================
# Data loading (reused from merit order + dispatch heatmap scripts)
# =============================================================================

"""
    load_gen_data() -> (gens, profiles, demand)

Load generators, renewable profiles, and demand CSVs from data/output/.
"""
function load_gen_data()
    data_dir = joinpath(@__DIR__, "..", "data", "output")
    gens     = CSV.read(joinpath(data_dir, "generators.csv"), DataFrame)
    profiles = CSV.read(joinpath(data_dir, "renewable_profiles.csv"), DataFrame)
    demand   = CSV.read(joinpath(data_dir, "demand.csv"), DataFrame)
    return gens, profiles, demand
end

"""
    total_demand_gw(demand_df, season, period) -> Float64

Compute total system demand in GW for a given season/period.
"""
function total_demand_gw(demand_df::DataFrame, season::String, period::String)
    rows = filter(r -> r.season == season && r.period == period, demand_df)
    return sum(rows.load_mw) / 1e3
end

"""
    load_generators_with_tech() -> DataFrame

Load generators.csv and add a `tech_group` column for dispatch aggregation.
"""
function load_generators_with_tech()
    path = joinpath(@__DIR__, "..", "data", "output", "generators.csv")
    gens = CSV.read(path, DataFrame)

    gens.tech_group = map(eachrow(gens)) do row
        if row.type == "thermal"
            row.fuel == "gas"  && return "Thermal Gas"
            row.fuel == "coal" && return "Thermal Coal"
            return "Thermal $(row.fuel)"
        else
            return get(Dict("hydro" => "Hydro", "wind" => "Wind", "solar" => "Solar"),
                       row.type, row.type)
        end
    end

    return gens
end

"""
    load_scenario_csv(scenario_id) -> DataFrame

Read a per-scenario CSV from results/. For battery scenarios (60 rows),
filter to day 5 (steady-state) to get 6 rows.
"""
function load_scenario_csv(scenario_id::String)
    path = joinpath(@__DIR__, "..", "results", "$(scenario_id).csv")
    !isfile(path) && return DataFrame()

    df = CSV.read(path, DataFrame)

    # Battery CSVs have a "day" column and 60 rows; filter to representative day
    if "day" in names(df) && nrow(df) > 6
        df = filter(row -> row.day == 5, df)
    end

    return df
end

"""
    load_battery_csv(scenario_id) -> DataFrame

Read a battery scenario CSV and sort by season, day, period.
"""
function load_battery_csv(scenario_id::String)
    path = joinpath(@__DIR__, "..", "results", "$(scenario_id).csv")
    !isfile(path) && return DataFrame()

    df = CSV.read(path, DataFrame)

    period_rank = Dict("night" => 1, "day" => 2, "peak" => 3)
    season_rank = Dict("wet" => 1, "dry" => 2)
    df.period_rank = [get(period_rank, p, 0) for p in df.period]
    df.season_rank = [get(season_rank, s, 0) for s in df.season]
    sort!(df, [:season_rank, :day, :period_rank])
    select!(df, Not([:period_rank, :season_rank]))

    return df
end


# =============================================================================
# Supply curve builder (from merit order script)
# =============================================================================

"""
    build_supply_curve(gens_df, profiles_df, season, period; carbon_tax=0.0)

Build a merit-order supply curve for the given season/period.

Returns: (cumulative_gw, cost_per_mwh, labels, tech_types)
"""
function build_supply_curve(gens_df::DataFrame, profiles_df::DataFrame,
                            season::String, period::String;
                            carbon_tax::Float64=0.0)

    entries = NamedTuple{(:gen_id, :capacity_gw, :cost, :tech_type, :label),
                          Tuple{String, Float64, Float64, String, String}}[]

    for row in eachrow(gens_df)
        # Determine available capacity
        if row.type in ("wind", "solar")
            pf = filter(r -> r.gen_id == row.gen_id &&
                             r.season == season &&
                             r.period == period, profiles_df)
            nrow(pf) == 0 && continue
            avail_mw = row.capacity_mw * pf[1, :capacity_factor]
        elseif row.type == "hydro"
            avail_mw = season == "wet" ? row.capacity_wet_mw : row.capacity_dry_mw
        else
            avail_mw = row.capacity_mw
        end

        avail_mw <= 0.0 && continue

        # Effective cost
        base_cost = season == "wet" ? row.cost_wet : row.cost_dry
        effective_cost = base_cost
        if row.type == "thermal"
            effective_cost += carbon_tax * row.emission_factor
        end

        tech_type = row.type == "thermal" ? "thermal_$(row.fuel)" : row.type
        label = replace(row.gen_id, "_" => " ")

        push!(entries, (gen_id=row.gen_id, capacity_gw=avail_mw / 1e3,
                        cost=effective_cost, tech_type=tech_type, label=label))
    end

    # Sort by cost; ties broken by type priority
    type_priority = Dict("wind" => 1, "solar" => 2, "hydro" => 3,
                         "thermal_gas" => 4, "thermal_coal" => 5)
    sort!(entries, by=e -> (e.cost, get(type_priority, e.tech_type, 6)))

    # Build step arrays
    cumulative_gw = Float64[0.0]
    cost_per_mwh  = Float64[]
    labels_out    = String[]
    tech_types    = String[]

    running_gw = 0.0
    for e in entries
        push!(cost_per_mwh, e.cost)
        push!(labels_out, e.label)
        push!(tech_types, e.tech_type)
        running_gw += e.capacity_gw
        push!(cumulative_gw, running_gw)
    end

    return cumulative_gw, cost_per_mwh, labels_out, tech_types
end


# =============================================================================
# Dispatch helpers (from dispatch heatmap script)
# =============================================================================

# Technology display groups and stacking order
const TECH_ORDER = ["Wind", "Solar", "Hydro", "Thermal Gas", "Thermal Coal"]

const CASE_ORDER = [
    ("wet", "night"), ("wet", "day"), ("wet", "peak"),
    ("dry", "night"), ("dry", "day"), ("dry", "peak"),
]

"""
    extract_dispatch_by_tech(df, gens) -> Dict{String, Vector{Float64}}

Aggregate dispatch columns by technology group.
"""
function extract_dispatch_by_tech(df::DataFrame, gens::DataFrame)
    result = Dict{String, Vector{Float64}}()
    for tg in TECH_ORDER
        result[tg] = zeros(Float64, nrow(df))
    end

    for row in eachrow(gens)
        col = "dispatch_$(row.gen_id)"
        col in names(df) || continue
        tg = row.tech_group
        haskey(result, tg) || (result[tg] = zeros(Float64, nrow(df)))
        result[tg] .+= df[!, col]
    end

    return result
end

"""
    sort_df_by_case_order(df) -> DataFrame

Sort a 6-row DataFrame by standard case ordering (wet/night → dry/peak).
"""
function sort_df_by_case_order(df::DataFrame)
    case_rank = Dict((s, p) => i for (i, (s, p)) in enumerate(CASE_ORDER))
    df.case_rank = [get(case_rank, (row.season, row.period), 99) for row in eachrow(df)]
    sort!(df, :case_rank)
    select!(df, Not(:case_rank))
    return df
end


# =============================================================================
# Figure 1: Merit Order Shift (Carbon Tax)
# =============================================================================

"""
Overlay baseline vs carbon_50 supply curves for dry/peak.
Shows the coal-to-gas switching mechanism.
"""
function figure_merit_order_carbon_shift(gens::DataFrame, profiles::DataFrame,
                                         demand::DataFrame)
    println("Figure 1: merit_order_carbon_shift")

    cum_base, costs_base, _, _ = build_supply_curve(
        gens, profiles, "dry", "peak"; carbon_tax=0.0)

    cum_c50, costs_c50, _, _ = build_supply_curve(
        gens, profiles, "dry", "peak"; carbon_tax=50.0)

    load_gw = total_demand_gw(demand, "dry", "peak")

    p = plot(;
        xlabel  = "Cumulative Capacity (GW)",
        ylabel  = "Marginal Cost (R\$/MWh)",
        title   = "Merit Order Shift: Carbon Tax \$50 (Dry Peak)",
        legend  = :outerbottom,
        size    = (1000, 680),
        xlims   = (0, 100),
        ylims   = (-5, maximum(costs_c50) * 1.15),
    )

    # Build step lines for baseline
    x_base, y_base = Float64[], Float64[]
    for i in 1:length(costs_base)
        push!(x_base, cum_base[i]);   push!(y_base, costs_base[i])
        push!(x_base, cum_base[i+1]); push!(y_base, costs_base[i])
    end

    # Build step lines for carbon_50
    x_c50, y_c50 = Float64[], Float64[]
    for i in 1:length(costs_c50)
        push!(x_c50, cum_c50[i]);   push!(y_c50, costs_c50[i])
        push!(x_c50, cum_c50[i+1]); push!(y_c50, costs_c50[i])
    end

    plot!(p, x_base, y_base; color=:steelblue, linewidth=2.5, label="Baseline")
    plot!(p, x_c50, y_c50;   color=:orangered, linewidth=2.5, linestyle=:dash,
          label="Carbon \$50")

    vline!([load_gw]; color=:black, linestyle=:dash, linewidth=1.5,
        label="Demand ($(round(load_gw, digits=1)) GW)")

    save_figure(p, "merit_order_carbon_shift")
    return p
end


# =============================================================================
# Figure 2: Battery SOC Trajectory (NE, Wet Season Only)
# =============================================================================

const BATTERY_ENERGY_MWH = 2000.0

"""
Single-panel SOC trajectory for battery NE in wet season.
Highlights steady-state region (days 4-8).
"""
function figure_soc_battery_NE()
    println("Figure 2: soc_battery_NE")

    df = load_battery_csv("battery_NE")
    nrow(df) == 0 && (println("  SKIP: battery_NE.csv not found"); return nothing)

    df_wet = filter(r -> r.season == "wet", df)
    n = nrow(df_wet)

    # Build x-axis labels
    period_abbrev = Dict("night" => "N", "day" => "D", "peak" => "P")
    indices = 1:n

    tick_pos    = Int[]
    tick_labels = String[]
    for i in 1:3:n
        push!(tick_pos, i)
        push!(tick_labels, "Day $(df_wet[i, :day])")
    end

    soc_pct = df_wet.soc_end ./ BATTERY_ENERGY_MWH .* 100

    p = plot(indices, soc_pct;
        xlabel      = "",
        ylabel      = "SOC (%)",
        title       = "Battery SOC: Battery at NE (Wet Season)",
        linewidth   = 2,
        marker      = :circle,
        markersize  = 3,
        color       = TECH_COLORS["battery"],
        legend      = false,
        xticks      = (tick_pos, tick_labels),
        ylims       = (-5, 110),
        xrotation   = 30,
        size        = (1000, 500),
    )

    # Highlight steady-state region (days 4-8 = periods 10-24)
    vspan!([10, 24]; color=:lightblue, alpha=0.15, label=nothing)

    save_figure(p, "soc_battery_NE")
    return p
end


# =============================================================================
# Figure 3: NE-SE Transmission Sensitivity (2-panel)
# =============================================================================

"""
Read sensitivity_ne_se.csv and plot curtailment + LMP spread vs NE-SE capacity.
"""
function figure_sensitivity_ne_se()
    println("Figure 3: sensitivity_ne_se")

    csv_path = joinpath(@__DIR__, "..", "results", "sensitivity_ne_se.csv")
    if !isfile(csv_path)
        println("  SKIP: sensitivity_ne_se.csv not found")
        return nothing
    end

    sweep_df = CSV.read(csv_path, DataFrame)
    sort!(sweep_df, :tx_actual_mw)

    x = sweep_df.tx_actual_mw ./ 1e3  # GW
    curtailment = sweep_df.annual_curtailment_mwh ./ 1e3  # GWh/yr
    lmp_spread  = sweep_df.lmp_spread_NE_SE

    # Identify existing scenario points (0, 2000, 5000, 10000 additional MW)
    existing_tx = Set([0, 2000, 5000, 10000])
    existing_mask = [row.tx_additional_mw in existing_tx for row in eachrow(sweep_df)]

    # Panel 1: Curtailment
    p1 = plot(x, curtailment;
        ylabel     = "Curtailment (GWh/yr)",
        title      = "Curtailment vs NE-SE Line Capacity",
        linewidth  = 2,
        marker     = :circle,
        markersize = 4,
        color      = FAMILY_COLORS["tx_expand"],
        label      = "Sensitivity sweep",
        legend     = :topright,
        bottom_margin = 2Plots.mm,
    )
    scatter!(p1, x[existing_mask], curtailment[existing_mask];
        markersize = 8, markershape = :diamond,
        color = FAMILY_COLORS["tx_expand"],
        markerstrokewidth = 2, label = "Modeled scenarios",
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

    save_figure(p, "sensitivity_ne_se")
    return p
end


# =============================================================================
# Figure 4: Generation Mix Comparison (Stacked Bar, Dry/Peak)
# =============================================================================

"""
Stacked bar of dispatch (GW) for 5 key scenarios in dry/peak.
"""
function figure_dispatch_mix(gens::DataFrame, demand::DataFrame)
    println("Figure 4: dispatch_mix_dry_peak")

    target_season = "dry"
    target_period = "peak"

    scenarios = ["baseline", "carbon_50", "battery_all",
                 "carbon_50_battery_all", "tx_expand_5000"]

    # Total system load for this case
    case_demand = filter(r -> r.season == target_season && r.period == target_period, demand)
    total_load = sum(case_demand.load_mw)

    n_scenarios = length(scenarios)
    x_positions = 1:n_scenarios
    x_labels = [human_label(s) for s in scenarios]

    # Collect dispatch by tech for each scenario
    tech_values = Dict{String, Vector{Float64}}()
    for tg in TECH_ORDER
        tech_values[tg] = zeros(Float64, n_scenarios)
    end

    has_battery = false

    for (si, sid) in enumerate(scenarios)
        df = load_scenario_csv(sid)
        nrow(df) == 0 && continue
        df = sort_df_by_case_order(df)

        case_rows = filter(r -> r.season == target_season && r.period == target_period, df)
        nrow(case_rows) == 0 && continue

        td = extract_dispatch_by_tech(case_rows, gens)
        for tg in TECH_ORDER
            tech_values[tg][si] = td[tg][1] / 1e3  # GW
        end

        # Check for battery discharge
        if "discharge_mw" in names(case_rows) && case_rows[1, :discharge_mw] > 0
            has_battery = true
            if !haskey(tech_values, "Battery")
                tech_values["Battery"] = zeros(Float64, n_scenarios)
            end
            tech_values["Battery"][si] = case_rows[1, :discharge_mw] / 1e3
        end
    end

    # Build ordered tech list for stacking
    plot_techs = copy(TECH_ORDER)
    has_battery && push!(plot_techs, "Battery")

    tech_colors_map = Dict(
        "Wind"         => TECH_COLORS["wind"],
        "Solar"        => TECH_COLORS["solar"],
        "Hydro"        => TECH_COLORS["hydro"],
        "Thermal Gas"  => TECH_COLORS["thermal_gas"],
        "Thermal Coal" => TECH_COLORS["thermal_coal"],
        "Battery"      => TECH_COLORS["battery"],
    )

    cumulative = zeros(Float64, n_scenarios)

    p = plot(; size=(900, 680), legend=:outerbottom,
        title  = "Generation Mix: Dry Peak",
        ylabel = "GW",
        xlabel = "",
    )

    for tg in plot_techs
        vals = get(tech_values, tg, zeros(n_scenarios))
        bar!(x_positions, cumulative .+ vals;
            bar_width = 0.6,
            fillrange = copy(cumulative),
            label     = tg,
            color     = get(tech_colors_map, tg, :gray),
        )
        cumulative .+= vals
    end

    # Set ylims based on actual stacked bar height with headroom
    max_bar = max(maximum(cumulative), total_load / 1e3)
    plot!(p; ylims = (0, max_bar * 1.15))

    hline!([total_load / 1e3]; color=:black, linestyle=:dash, linewidth=1.5,
        label="Load ($(round(total_load/1e3, digits=1)) GW)")

    plot!(xticks=(x_positions, x_labels), xrotation=30,
          bottom_margin=12Plots.mm)

    save_figure(p, "dispatch_mix_dry_peak")
    return p
end


# =============================================================================
# Figure 5: Merit Order Shift (Carbon Tax) — Wet Peak
# =============================================================================

"""
Overlay baseline vs carbon_50 supply curves for wet/peak.
Wet-season complement to Figure 1 (dry/peak).
"""
function figure_merit_order_carbon_shift_wet(gens::DataFrame, profiles::DataFrame,
                                              demand::DataFrame)
    println("Figure 5: merit_order_carbon_shift_wet")

    cum_base, costs_base, _, _ = build_supply_curve(
        gens, profiles, "wet", "peak"; carbon_tax=0.0)

    cum_c50, costs_c50, _, _ = build_supply_curve(
        gens, profiles, "wet", "peak"; carbon_tax=50.0)

    load_gw = total_demand_gw(demand, "wet", "peak")

    p = plot(;
        xlabel  = "Cumulative Capacity (GW)",
        ylabel  = "Marginal Cost (R\$/MWh)",
        title   = "Merit Order Shift: Carbon Tax \$50 (Wet Peak)",
        legend  = :outerbottom,
        size    = (1000, 680),
        xlims   = (0, 100),
        ylims   = (-5, maximum(costs_c50) * 1.15),
    )

    # Build step lines for baseline
    x_base, y_base = Float64[], Float64[]
    for i in 1:length(costs_base)
        push!(x_base, cum_base[i]);   push!(y_base, costs_base[i])
        push!(x_base, cum_base[i+1]); push!(y_base, costs_base[i])
    end

    # Build step lines for carbon_50
    x_c50, y_c50 = Float64[], Float64[]
    for i in 1:length(costs_c50)
        push!(x_c50, cum_c50[i]);   push!(y_c50, costs_c50[i])
        push!(x_c50, cum_c50[i+1]); push!(y_c50, costs_c50[i])
    end

    plot!(p, x_base, y_base; color=:steelblue, linewidth=2.5, label="Baseline")
    plot!(p, x_c50, y_c50;   color=:orangered, linewidth=2.5, linestyle=:dash,
          label="Carbon \$50")

    vline!([load_gw]; color=:black, linestyle=:dash, linewidth=1.5,
        label="Demand ($(round(load_gw, digits=1)) GW)")

    save_figure(p, "merit_order_carbon_shift_wet")
    return p
end


# =============================================================================
# Figure 6: Battery Profit by Season (Grouped Bar Chart)
# =============================================================================

const BATTERY_NODES  = ["N1", "NE1", "SE1", "S1"]
const BATTERY_LABELS = ["N", "NE", "SE", "S"]
const BATTERY_NODE_CAPACITY_MWH = 800.0
const DAYS_PER_SEASON = 182.5
const REPRESENTATIVE_DAYS = 10

"""
Grouped bar chart of annual battery profit by season for each node.
Profit = sum(revenue) - sum(charge_cost), annualized × (182.5 / 10).
"""
function figure_battery_profit_by_season()
    println("Figure 6: battery_profit_by_season")

    df = load_battery_csv("battery_all")
    nrow(df) == 0 && (println("  SKIP: battery_all.csv not found"); return nothing)

    n_batteries = length(BATTERY_NODES)
    wet_profits = zeros(n_batteries)
    dry_profits = zeros(n_batteries)

    for (i, node) in enumerate(BATTERY_NODES)
        rev_col  = "revenue_Battery_$(node)"
        cost_col = "charge_cost_Battery_$(node)"

        for season in ["wet", "dry"]
            df_season = filter(r -> r.season == season, df)
            profit = sum(df_season[!, rev_col]) - sum(df_season[!, cost_col])
            annual_profit = profit * (DAYS_PER_SEASON / REPRESENTATIVE_DAYS)

            if season == "wet"
                wet_profits[i] = annual_profit
            else
                dry_profits[i] = annual_profit
            end
        end
    end

    x = collect(1:n_batteries)
    bar_w = 0.3

    # Convert to millions for readability
    wet_mr = wet_profits ./ 1e6
    dry_mr = dry_profits ./ 1e6
    all_mr = [wet_mr; dry_mr]
    y_max = maximum(all_mr) * 1.20  # 20% headroom for annotations

    p = plot(;
        title   = "Annual Battery Profit by Season",
        ylabel  = "Annual Profit (M R\$/yr)",
        xlabel  = "",
        legend  = :outerbottom,
        size    = (900, 650),
        ylims   = (0, y_max),
    )

    bar!(x .- 0.17, wet_mr;
        bar_width = bar_w, label = "Wet Season", color = :deepskyblue)
    bar!(x .+ 0.17, dry_mr;
        bar_width = bar_w, label = "Dry Season", color = :sandybrown)

    # Annotate total annual profit above each pair
    for i in 1:n_batteries
        total = wet_mr[i] + dry_mr[i]
        y_top = max(wet_mr[i], dry_mr[i], 0.0)
        annotate!(x[i], y_top + y_max * 0.04,
            text("Total $(round(total, digits=1))M", 8, :center))
    end

    plot!(xticks = (x, BATTERY_LABELS))
    hline!([0]; color=:black, linewidth=0.5, label=nothing)

    save_figure(p, "battery_profit_by_season")
    return p
end


# =============================================================================
# Figure 7: SOC Profiles by Subsystem (2×4 Panel Grid)
# =============================================================================

"""
2×4 panel grid of SOC trajectories: rows = wet/dry, columns = N/NE/SE/S.
Each subplot shows soc_end (% of 800 MWh) across 30 periods (10 days × 3).
"""
function figure_soc_profiles()
    println("Figure 7: soc_profiles")

    df = load_battery_csv("battery_all")
    nrow(df) == 0 && (println("  SKIP: battery_all.csv not found"); return nothing)

    node_colors = Dict("N1" => :royalblue, "NE1" => :forestgreen,
                        "SE1" => :orangered, "S1" => :purple)

    subplots = []

    for (ri, season) in enumerate(["wet", "dry"])
        df_season = filter(r -> r.season == season, df)
        n = nrow(df_season)
        indices = 1:n

        # Tick marks at day boundaries (every 3 periods = 1 day)
        tick_pos    = Int[]
        tick_labels = String[]
        for i in 1:3:n
            push!(tick_pos, i)
            push!(tick_labels, "D$(df_season[i, :day])")
        end

        for (ci, (node, label)) in enumerate(zip(BATTERY_NODES, BATTERY_LABELS))
            soc_col = "soc_end_Battery_$(node)"
            soc_pct = df_season[!, soc_col] ./ BATTERY_NODE_CAPACITY_MWH .* 100

            sp = plot(indices, soc_pct;
                title      = "$(label) ($(titlecase(season)))",
                linewidth  = 1.5,
                marker     = :circle,
                markersize = 2,
                color      = node_colors[node],
                legend     = false,
                xticks     = (tick_pos, tick_labels),
                ylims      = (-5, 110),
                xrotation  = 30,
            )

            # y-label only for leftmost column
            ci == 1 && plot!(sp; ylabel = "SOC (%)")
            # x-label only for bottom row
            ri == 2 && plot!(sp; xlabel = "Period")

            push!(subplots, sp)
        end
    end

    p = plot(subplots...; layout = (2, 4), size = (1600, 700),
             plot_title = "Battery SOC Profiles")

    save_figure(p, "soc_profiles")
    return p
end


# =============================================================================
# Main
# =============================================================================

function main()
    println("=" ^ 60)
    println("Phase 7 — 7 Focused Figures")
    println("=" ^ 60)

    set_plot_defaults()

    gens, profiles, demand = load_gen_data()
    gens_tech = load_generators_with_tech()
    println("Loaded: $(nrow(gens)) generators, $(nrow(profiles)) profiles, $(nrow(demand)) demand rows")
    println()

    # Figure 1: Merit order shift (baseline vs carbon_50, dry/peak)
    figure_merit_order_carbon_shift(gens, profiles, demand)

    # Figure 2: Battery SOC trajectory (NE, wet)
    figure_soc_battery_NE()

    # Figure 3: NE-SE transmission sensitivity (2-panel)
    figure_sensitivity_ne_se()

    # Figure 4: Generation mix stacked bar (dry/peak)
    figure_dispatch_mix(gens_tech, demand)

    # Figure 5: Merit order shift (baseline vs carbon_50, wet/peak)
    figure_merit_order_carbon_shift_wet(gens, profiles, demand)

    # Figure 6: Battery profit by season (grouped bar)
    figure_battery_profit_by_season()

    # Figure 7: SOC profiles by subsystem (2×4 panel)
    figure_soc_profiles()

    println()
    println("=" ^ 60)
    println("All 7 figures saved to results/figures/")
    println("=" ^ 60)
end

main()
