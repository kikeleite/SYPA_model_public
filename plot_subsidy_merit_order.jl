# plot_subsidy_merit_order.jl -- Merit order curves for subsidy and carbon tax
#
# Generates 4 figures:
#   1. V2 (Zonal): Baseline vs Subsidy R$10/MWh (dry/peak)
#   2. V3 (Nodal): Baseline vs Subsidy R$10/MWh (dry/peak)
#   3. V2 (Zonal): Baseline vs Carbon Tax R$50/tCO2 (dry/peak)
#   4. V3 (Nodal): Baseline vs Carbon Tax R$50/tCO2 (dry/peak)
#
# Key contrast:
#   - Subsidy shifts the LEFT of the curve (renewables, already cheapest)
#     → no change in dispatch or emissions
#   - Carbon tax shifts the RIGHT of the curve (thermals, near the demand crossing)
#     → changes which plants are marginal → reduces emissions
#
# Usage: cd V2-dc-opf-zonal-intertemporal && julia --project=. -e 'include("../plot_subsidy_merit_order.jl")'

using Plots, CSV, DataFrames

# =============================================================================
# Styling
# =============================================================================

function set_plot_defaults()
    default(
        dpi        = 150,
        fontfamily = "Helvetica",
        titlefontsize  = 14,
        guidefontsize  = 11,
        tickfontsize   = 9,
        legendfontsize = 9,
        framestyle = :box,
        grid       = true,
        gridalpha  = 0.2,
        margin     = 8Plots.mm,
    )
end

function save_figure(p, name::String; dir)
    mkpath(dir)
    savefig(p, joinpath(dir, name * ".png"))
    savefig(p, joinpath(dir, name * ".pdf"))
    println("  Saved: $(name).png / $(name).pdf")
end

# =============================================================================
# Generic supply curve builder
# =============================================================================

"""
    build_supply_curve(gens_df, profiles_df, season, period;
                       subsidy=0.0, carbon_tax=0.0)

Build a merit-order supply curve. Returns (cumulative_gw, cost_per_mwh, tech_types).

- `subsidy` (R\$/MWh): subtracted from wind/solar costs
- `carbon_tax` (R\$/tCO2): added to thermal costs as tax × emission_factor
"""
function build_supply_curve(gens_df::DataFrame, profiles_df::DataFrame,
                            season::String, period::String;
                            subsidy::Float64=0.0, carbon_tax::Float64=0.0)

    entries = NamedTuple{(:capacity_gw, :cost, :tech_type),
                          Tuple{Float64, Float64, String}}[]

    for row in eachrow(gens_df)
        # Skip backstop generators (they distort the x-axis range)
        startswith(row.gen_id, "Backstop") && continue

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

        # Apply subsidy to renewables
        if row.type in ("wind", "solar")
            effective_cost -= subsidy
        end

        # Apply carbon tax to thermals
        if row.type == "thermal" && carbon_tax > 0.0
            effective_cost += carbon_tax * row.emission_factor
        end

        tech_type = if row.type == "thermal"
            hasproperty(row, :fuel) && !ismissing(row.fuel) ? "thermal_$(row.fuel)" : "thermal"
        else
            row.type
        end

        push!(entries, (capacity_gw=avail_mw / 1e3,
                        cost=effective_cost, tech_type=tech_type))
    end

    # Sort by cost; ties broken by type priority
    type_priority = Dict("wind" => 1, "solar" => 2, "hydro" => 3,
                         "thermal_gas" => 4, "thermal_coal" => 5, "thermal" => 4)
    sort!(entries, by=e -> (e.cost, get(type_priority, e.tech_type, 6)))

    # Build step arrays
    cumulative_gw = Float64[0.0]
    cost_per_mwh  = Float64[]
    tech_types    = String[]

    running_gw = 0.0
    for e in entries
        push!(cost_per_mwh, e.cost)
        push!(tech_types, e.tech_type)
        running_gw += e.capacity_gw
        push!(cumulative_gw, running_gw)
    end

    return cumulative_gw, cost_per_mwh, tech_types
end

"""
    build_step_arrays(cumulative_gw, costs) -> (x, y)

Convert supply curve data into step-function arrays for plotting.
"""
function build_step_arrays(cumulative_gw::Vector{Float64}, costs::Vector{Float64})
    x, y = Float64[], Float64[]
    for i in 1:length(costs)
        push!(x, cumulative_gw[i]);   push!(y, costs[i])
        push!(x, cumulative_gw[i+1]); push!(y, costs[i])
    end
    return x, y
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
    find_thermal_gw_range(cumulative_gw, costs, tech_types) -> (start_gw, end_gw)

Find the x-range where thermal generators sit in the supply curve.
"""
function find_thermal_gw_range(cumulative_gw, costs, tech_types)
    start_gw = Inf
    end_gw = 0.0
    for i in 1:length(tech_types)
        if startswith(tech_types[i], "thermal")
            start_gw = min(start_gw, cumulative_gw[i])
            end_gw = max(end_gw, cumulative_gw[i+1])
        end
    end
    return start_gw, end_gw
end


# =============================================================================
# Data loaders
# =============================================================================

function load_v2_data()
    data_dir = joinpath(@__DIR__, "V2-dc-opf-zonal-intertemporal", "data", "output")
    gens     = CSV.read(joinpath(data_dir, "generators.csv"), DataFrame)
    profiles = CSV.read(joinpath(data_dir, "renewable_profiles.csv"), DataFrame)
    demand   = CSV.read(joinpath(data_dir, "demand.csv"), DataFrame)
    return gens, profiles, demand
end

function load_v3_data()
    data_dir = joinpath(@__DIR__, "V3-dc-opf-nodal-intertemporal", "state_data", "output")
    gens     = CSV.read(joinpath(data_dir, "generators.csv"), DataFrame)
    profiles = CSV.read(joinpath(data_dir, "renewable_profiles.csv"), DataFrame)
    demand   = CSV.read(joinpath(data_dir, "demand.csv"), DataFrame)
    return gens, profiles, demand
end


# =============================================================================
# Subsidy figures (Figures 1-2)
# =============================================================================

function figure_subsidy(gens, profiles, demand, model_label, model_tag, fig_dir)
    println("  $(model_label): Subsidy Merit Order (Dry Peak)")

    season, period = "dry", "peak"

    cum_base, costs_base, _ = build_supply_curve(gens, profiles, season, period)
    cum_sub, costs_sub, _   = build_supply_curve(gens, profiles, season, period;
                                                  subsidy=10.0)

    load_gw = total_demand_gw(demand, season, period)

    x_base, y_base = build_step_arrays(cum_base, costs_base)
    x_sub, y_sub   = build_step_arrays(cum_sub, costs_sub)

    # Renewable zone boundary
    renewable_gw = 0.0
    for i in 1:length(costs_base)
        costs_base[i] <= 1.0 && (renewable_gw = cum_base[i+1])
    end

    p = plot(;
        xlabel  = "Capacidade Acumulada (GW)",
        ylabel  = "Custo Marginal (R\$/MWh)",
        title   = "$(model_label): Efeito do Subsídio na Curva de Mérito — Ponta Seca",
        legend  = :outertopright,
        size    = (1100, 680),
        xlims   = (0, load_gw * 1.25),
        ylims   = (-15, 450),
    )

    # Shaded renewable zone
    vspan!(p, [0, renewable_gw]; color=:lightgreen, alpha=0.15, label=nothing)
    annotate!(p, renewable_gw / 2, 430,
        text("Renováveis", 10, :bold, :center, :gray40))

    # Supply curves
    plot!(p, x_base, y_base; color=:steelblue, linewidth=2.5,
          label="Baseline (renovável a 1 R/MWh)")
    plot!(p, x_sub, y_sub; color=:forestgreen, linewidth=2.5, linestyle=:dash,
          label="Subsídio 10 R/MWh (renovável a -9 R/MWh)")

    # Demand line
    vline!(p, [load_gw]; color=:black, linestyle=:dash, linewidth=1.5,
        label="Demanda ($(round(load_gw, digits=1)) GW)")

    # Crossing point annotation
    crossing_cost = 0.0
    for i in 1:length(costs_base)
        if cum_base[i+1] >= load_gw
            crossing_cost = costs_base[i]
            break
        end
    end

    annotate!(p, load_gw + 1.5, crossing_cost + 30,
        text("Mesmo ponto\nde cruzamento\n→ despacho idêntico", 9, :left, :gray30))

    # Explanatory text
    annotate!(p, load_gw * 0.55, 380,
        text("Subsídio desloca renováveis\nde 1 para -9 R/MWh,\nmas elas já eram primeiras\nna ordem de mérito.", 9, :center, :gray40))

    save_figure(p, "subsidy_merit_order_$(model_tag)"; dir=fig_dir)
    return p
end


# =============================================================================
# Carbon tax figures (Figures 3-4)
# =============================================================================

function figure_carbon_tax(gens, profiles, demand, model_label, model_tag, fig_dir)
    println("  $(model_label): Carbon Tax Merit Order (Dry Peak)")

    season, period = "dry", "peak"

    cum_base, costs_base, types_base = build_supply_curve(gens, profiles, season, period)
    cum_c50, costs_c50, types_c50    = build_supply_curve(gens, profiles, season, period;
                                                           carbon_tax=50.0)
    cum_c100, costs_c100, _          = build_supply_curve(gens, profiles, season, period;
                                                           carbon_tax=100.0)

    load_gw = total_demand_gw(demand, season, period)

    x_base, y_base = build_step_arrays(cum_base, costs_base)
    x_c50, y_c50   = build_step_arrays(cum_c50, costs_c50)
    x_c100, y_c100 = build_step_arrays(cum_c100, costs_c100)

    # Find thermal zone in baseline
    therm_start, therm_end = find_thermal_gw_range(cum_base, costs_base, types_base)

    p = plot(;
        xlabel  = "Capacidade Acumulada (GW)",
        ylabel  = "Custo Marginal (R\$/MWh)",
        title   = "$(model_label): Efeito do Carbon Tax na Curva de Mérito — Ponta Seca",
        legend  = :outertopright,
        size    = (1100, 680),
        xlims   = (0, load_gw * 1.25),
        ylims   = (-15, 550),
    )

    # Shaded thermal zone (where carbon tax has effect)
    if therm_start < therm_end
        vspan!(p, [therm_start, min(therm_end, load_gw * 1.25)];
               color=:lightsalmon, alpha=0.12, label=nothing)
        annotate!(p, (therm_start + min(therm_end, load_gw * 1.25)) / 2, 520,
            text("Térmicas", 10, :bold, :center, :gray40))
    end

    # Supply curves
    plot!(p, x_base, y_base; color=:steelblue, linewidth=2.5,
          label="Baseline")
    plot!(p, x_c50, y_c50; color=:orangered, linewidth=2.5, linestyle=:dash,
          label="Carbon tax 50 R/tCO2")
    plot!(p, x_c100, y_c100; color=:darkred, linewidth=2.5, linestyle=:dot,
          label="Carbon tax 100 R/tCO2")

    # Demand line
    vline!(p, [load_gw]; color=:black, linestyle=:dash, linewidth=1.5,
        label="Demanda ($(round(load_gw, digits=1)) GW)")

    # Find crossing costs for baseline and carbon_50
    crossing_base = 0.0
    for i in 1:length(costs_base)
        if cum_base[i+1] >= load_gw
            crossing_base = costs_base[i]
            break
        end
    end
    crossing_c50 = 0.0
    for i in 1:length(costs_c50)
        if cum_c50[i+1] >= load_gw
            crossing_c50 = costs_c50[i]
            break
        end
    end
    crossing_c100 = 0.0
    for i in 1:length(costs_c100)
        if cum_c100[i+1] >= load_gw
            crossing_c100 = costs_c100[i]
            break
        end
    end

    # Annotate the shift at the crossing point
    if crossing_c50 > crossing_base
        # Show the price increase at the margin
        delta_50 = round(crossing_c50 - crossing_base, digits=0)
        delta_100 = round(crossing_c100 - crossing_base, digits=0)
        annotate!(p, load_gw + 1.5, crossing_c100 + 20,
            text("Custo marginal sobe:\n+$(Int(delta_50)) R/MWh (tax 50)\n+$(Int(delta_100)) R/MWh (tax 100)",
                 9, :left, :gray30))
    end

    # Explanatory text — mechanism
    annotate!(p, load_gw * 0.42, 480,
        text("Carbon tax encarece térmicas\npróximas à demanda,\nalterando o despacho marginal\n→ reduz emissões.", 9, :center, :gray40))

    # Show arrows indicating thermal cost increase for key plants
    # Gas: +25 R/MWh (50 tax × 0.5 ef), Coal: +50 R/MWh (50 tax × 1.0 ef)
    annotate!(p, therm_start + 1.0, 200,
        text("Gás: +25 R/MWh\nCarvão: +50 R/MWh\n(tax 50)", 8, :left, :salmon))

    save_figure(p, "carbon_tax_merit_order_$(model_tag)"; dir=fig_dir)
    return p
end


# =============================================================================
# Main
# =============================================================================

function main()
    println("=" ^ 60)
    println("Merit Order Comparison — Subsidy vs Carbon Tax")
    println("=" ^ 60)
    println()

    set_plot_defaults()

    v2_gens, v2_profiles, v2_demand = load_v2_data()
    v3_gens, v3_profiles, v3_demand = load_v3_data()

    v2_fig_dir = joinpath(@__DIR__, "V2-dc-opf-zonal-intertemporal", "results", "figures")
    v3_fig_dir = joinpath(@__DIR__, "V3-dc-opf-nodal-intertemporal", "results", "figures")

    # Subsidy figures
    println("Subsidy figures:")
    figure_subsidy(v2_gens, v2_profiles, v2_demand,
                   "Modelo Zonal (V2)", "v2", v2_fig_dir)
    figure_subsidy(v3_gens, v3_profiles, v3_demand,
                   "Modelo Nodal (V3)", "v3", v3_fig_dir)
    println()

    # Carbon tax figures
    println("Carbon tax figures:")
    figure_carbon_tax(v2_gens, v2_profiles, v2_demand,
                      "Modelo Zonal (V2)", "v2", v2_fig_dir)
    figure_carbon_tax(v3_gens, v3_profiles, v3_demand,
                      "Modelo Nodal (V3)", "v3", v3_fig_dir)

    println()
    println("=" ^ 60)
    println("Done. 4 figures saved.")
    println("=" ^ 60)
end

main()
