# plot_battery_location.jl -- Battery location analysis: profitability vs system value
#
# Generates 2 figures (V2 zonal model):
#   1. Battery profitability by node — shows SE/S are most profitable
#   2. Battery curtailment effect by node (heatmaps NE vs SE side by side)
#      — shows NE is the only location that reduces curtailment
#
# Key insight: market signals favor SE (higher profits) but the system
# needs batteries at NE (curtailment reduction). This misalignment is
# a key policy finding.
#
# Usage: cd V2-dc-opf-zonal-intertemporal && julia --project=. -e 'include("../plot_battery_location.jl")'

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

const V2_FIG_DIR = joinpath(@__DIR__, "V2-dc-opf-zonal-intertemporal", "results", "figures")
const V2_RESULTS = joinpath(@__DIR__, "V2-dc-opf-zonal-intertemporal", "results")

const BATTERY_NODES  = ["N1", "NE1", "SE1", "S1"]
const NODE_LABELS    = ["Norte", "Nordeste", "Sudeste", "Sul"]
const NODE_LABELS_SHORT = ["N", "NE", "SE", "S"]
const DAYS_PER_SEASON = 182.5
const REPRESENTATIVE_DAYS = 10


# =============================================================================
# Figure 1: Battery profitability by node (grouped bar: no tax vs carbon 50)
# =============================================================================

function figure_battery_profitability()
    println("Figure 1: Rentabilidade da Bateria por Localização")

    # Load battery_all (no carbon tax) and carbon_50_battery_all
    df_base = CSV.read(joinpath(V2_RESULTS, "battery_all.csv"), DataFrame)
    df_c50  = CSV.read(joinpath(V2_RESULTS, "carbon_50_battery_all.csv"), DataFrame)

    n = length(BATTERY_NODES)
    profits_base = zeros(n)
    profits_c50  = zeros(n)

    for (i, node) in enumerate(BATTERY_NODES)
        rev_col  = "revenue_Battery_$(node)"
        cost_col = "charge_cost_Battery_$(node)"

        # Annualize: each season has 10 representative days → scale to 182.5
        for (df, profits) in [(df_base, profits_base), (df_c50, profits_c50)]
            total_profit = 0.0
            for season in ["wet", "dry"]
                df_season = filter(r -> r.season == season, df)
                rev  = sum(df_season[!, rev_col])
                cost = sum(df_season[!, cost_col])
                total_profit += (rev - cost) * (DAYS_PER_SEASON / REPRESENTATIVE_DAYS)
            end
            profits[i] = total_profit
        end
    end

    # Convert to millions R$/yr
    profits_base_m = profits_base ./ 1e6
    profits_c50_m  = profits_c50 ./ 1e6

    x = collect(1:n)
    bar_w = 0.3

    y_max = maximum([profits_base_m; profits_c50_m]) * 1.25

    p = plot(;
        title   = "Rentabilidade Anual da Bateria por Localização",
        ylabel  = "Lucro Líquido (M R\$/ano)",
        xlabel  = "",
        legend  = :outertopright,
        size    = (1000, 650),
        ylims   = (0, y_max),
    )

    bar!(p, x .- 0.17, profits_base_m;
        bar_width = bar_w, label = "Sem carbon tax",
        color = :steelblue)
    bar!(p, x .+ 0.17, profits_c50_m;
        bar_width = bar_w, label = "Carbon tax 50 R/tCO2",
        color = :orangered)

    # Annotate values
    for i in 1:n
        y_base = profits_base_m[i]
        y_c50  = profits_c50_m[i]
        annotate!(p, x[i] - 0.17, y_base + y_max * 0.02,
            text("$(round(y_base, digits=1))", 8, :center, :steelblue))
        annotate!(p, x[i] + 0.17, y_c50 + y_max * 0.02,
            text("$(round(y_c50, digits=1))", 8, :center, :orangered))
    end

    plot!(p; xticks = (x, NODE_LABELS))

    # Highlight the key insight
    annotate!(p, 3.0, y_max * 0.85,
        text("SE e S são mais lucrativos\n(maior spread de arbitragem)", 9, :center, :gray30))
    annotate!(p, 2.0, y_max * 0.72,
        text("NE é o menos lucrativo\n(preços baixos = pouca arbitragem)", 9, :center, :gray30))

    save_figure(p, "battery_profitability_by_location"; dir=V2_FIG_DIR)
    return p
end


# =============================================================================
# Figure 2: Heatmaps NE vs SE — curtailment effect (side by side)
# =============================================================================

function figure_battery_curtailment_heatmaps()
    println("Figure 2: Efeito da Bateria no Curtailment (NE vs SE)")

    df = CSV.read(joinpath(V2_RESULTS, "tradeoff_tx_battery.csv"), DataFrame)

    # Filter for NE1 and SE1 battery placements
    df_ne = filter(r -> r.battery_node == "NE1", df)
    df_se = filter(r -> r.battery_node == "SE1", df)

    # Get unique TX expansion and battery sizes
    tx_vals   = sort(unique(df_ne.tx_expansion_mw))
    batt_vals = sort(unique(df_ne.battery_power_mw))

    n_tx   = length(tx_vals)
    n_batt = length(batt_vals)

    # Build matrices
    mat_ne = zeros(n_batt, n_tx)
    mat_se = zeros(n_batt, n_tx)

    for (bi, batt) in enumerate(batt_vals)
        for (ti, tx) in enumerate(tx_vals)
            row_ne = filter(r -> r.tx_expansion_mw == tx && r.battery_power_mw == batt, df_ne)
            row_se = filter(r -> r.tx_expansion_mw == tx && r.battery_power_mw == batt, df_se)
            mat_ne[bi, ti] = nrow(row_ne) > 0 ? row_ne[1, :annual_curtailment_gwh] : NaN
            mat_se[bi, ti] = nrow(row_se) > 0 ? row_se[1, :annual_curtailment_gwh] : NaN
        end
    end

    # X/Y labels
    tx_labels   = ["+$(Int(t))" for t in tx_vals]
    batt_labels = ["$(Int(b))" for b in batt_vals]

    # Common color scale
    clims = (0, maximum(filter(!isnan, [mat_ne[:]; mat_se[:]])))

    # Panel 1: Battery at NE
    p1 = heatmap(mat_ne;
        title  = "Bateria no Nordeste (NE)",
        xlabel = "Expansão TX NE-SE (MW)",
        ylabel = "Capacidade Bateria (MW)",
        color  = :YlOrRd,
        clims  = clims,
        xticks = (1:n_tx, tx_labels),
        yticks = (1:n_batt, batt_labels),
        colorbar = false,
    )

    # Annotate values on NE heatmap
    for bi in 1:n_batt, ti in 1:n_tx
        v = mat_ne[bi, ti]
        isnan(v) && continue
        txt = v < 1 ? "0" : string(Int(round(v)))
        c = v < clims[2] * 0.5 ? :black : :white
        annotate!(p1, ti, bi, text(txt, 8, :bold, :center, c))
    end

    # Panel 2: Battery at SE
    p2 = heatmap(mat_se;
        title  = "Bateria no Sudeste (SE)",
        xlabel = "Expansão TX NE-SE (MW)",
        ylabel = "",
        color  = :YlOrRd,
        clims  = clims,
        xticks = (1:n_tx, tx_labels),
        yticks = (1:n_batt, batt_labels),
        colorbar_title = "Curtailment (GWh/ano)",
    )

    # Annotate values on SE heatmap
    for bi in 1:n_batt, ti in 1:n_tx
        v = mat_se[bi, ti]
        isnan(v) && continue
        txt = v < 1 ? "0" : string(Int(round(v)))
        c = v < clims[2] * 0.5 ? :black : :white
        annotate!(p2, ti, bi, text(txt, 8, :bold, :center, c))
    end

    p = plot(p1, p2;
        layout = (1, 2),
        size   = (1400, 550),
        plot_title = "Curtailment Anual (GWh/ano): Localização da Bateria",
        bottom_margin = 10Plots.mm,
        left_margin = 8Plots.mm,
    )

    save_figure(p, "battery_curtailment_ne_vs_se"; dir=V2_FIG_DIR)
    return p
end


# =============================================================================
# Main
# =============================================================================

function main()
    println("=" ^ 60)
    println("Battery Location Analysis — V2 Zonal Model")
    println("=" ^ 60)
    println()

    set_plot_defaults()

    figure_battery_profitability()
    println()
    figure_battery_curtailment_heatmaps()

    println()
    println("=" ^ 60)
    println("Done. 2 figures saved to V2/.../figures/")
    println("=" ^ 60)
end

main()
