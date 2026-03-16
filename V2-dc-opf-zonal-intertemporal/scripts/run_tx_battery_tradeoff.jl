# run_tx_battery_tradeoff.jl -- TX expansion vs battery capacity 2D sensitivity
#
# Sweeps a 2D grid of (NE-SE transmission expansion, battery capacity) and
# measures annual curtailment using the intertemporal solver. Produces three
# heatmaps (battery at NE1, SE1, N1) showing how the two investment types
# substitute or complement each other.
#
# Grid: 5 TX levels × 5 battery sizes = 25 solves per heatmap, 75 total.
# Each solve runs wet + dry season (30-period intertemporal LP each).
#
# Outputs:
#   results/tradeoff_tx_battery.csv           (75 rows)
#   results/figures/tradeoff_heatmap_NE1.png  (+ .pdf)
#   results/figures/tradeoff_heatmap_SE1.png  (+ .pdf)
#   results/figures/tradeoff_heatmap_N1.png   (+ .pdf)
#
# Usage: julia --project=. scripts/run_tx_battery_tradeoff.jl

include(joinpath(@__DIR__, "..", "src", "display.jl"))
include(joinpath(@__DIR__, "..", "src", "intertemporal.jl"))
include(joinpath(@__DIR__, "plot_helpers.jl"))


# =============================================================================
# Constants
# =============================================================================

const TX_EXPANSION_MW = [0, 1000, 2000, 3000, 4000]          # Additional MW on NE-SE
const BATTERY_POWER_MW = [0, 500, 1000, 2000, 3000]          # Battery power rating (MW)
const BATTERY_LOCATIONS = ["NE1", "SE1", "N1"]                  # Three heatmaps
const SEASONS = ["wet", "dry"]


# =============================================================================
# Helper: create SystemData with modified battery size
# =============================================================================

"""
    with_battery_size(data::SystemData, power_mw::Float64) -> SystemData

Return a copy of `data` with battery power and energy scaled to `power_mw`,
preserving the original energy-to-power ratio (4h duration).
"""
function with_battery_size(data::SystemData, power_mw::Float64)
    ratio = data.battery.energy_mwh / data.battery.power_mw  # preserve E/P ratio
    new_battery = BatteryParams(
        power_mw,
        power_mw * ratio,
        data.battery.efficiency,
        data.battery.cost_mwh,
        data.battery.initial_soc,
    )
    return SystemData(
        data.nodes, data.generators, data.demand, data.profiles,
        data.transmission, new_battery, data.temporal, data.scenarios,
        data.node_to_idx, data.idx_to_node,
    )
end


# =============================================================================
# Solve a single grid point
# =============================================================================

"""
    solve_grid_point(data, tx_mw, battery_mw, battery_node) -> NamedTuple

Solve wet + dry intertemporal LP for a (tx_expansion, battery_capacity, battery_node)
combination and return annual curtailment in MWh.
"""
function solve_grid_point(data::SystemData, tx_mw::Int, battery_mw::Int,
                          battery_node::String)
    # Build modified SystemData if battery > 0
    data_mod = battery_mw > 0 ? with_battery_size(data, Float64(battery_mw)) : data

    # Build ScenarioDef: TX expansion on NE_SE + optional battery
    batt_node_str = battery_mw > 0 ? battery_node : "none"
    tx_line = tx_mw > 0 ? "NE_SE" : "none"

    scenario = ScenarioDef(
        "tradeoff_tx$(tx_mw)_batt$(battery_mw)_$(battery_node)",
        0.0,                     # no carbon tax
        0.0,                     # no subsidy
        batt_node_str,
        tx_line,
        Float64(tx_mw),
    )

    # Solve both seasons
    annual_curtailment_mwh = 0.0

    for season in SEASONS
        result = solve_intertemporal(data_mod, season, scenario)

        if result.status != "OPTIMAL"
            error("Solver failed: tx=$(tx_mw), batt=$(battery_mw)@$(battery_node), " *
                  "season=$(season): $(result.status)")
        end

        # Sum curtailment (MW × hours) across all 30 periods
        season_curtailment_energy = 0.0
        for t in 1:N_PERIODS
            pr = result.periods[t]
            if !isempty(pr.curtailment)
                season_curtailment_energy += sum(values(pr.curtailment)) * pr.hours
            end
        end

        # Annualize: 10 simulated days represent 182.5 calendar days
        annual_curtailment_mwh += season_curtailment_energy * (182.5 / N_DAYS)
    end

    return (
        battery_node = battery_node,
        tx_expansion_mw = tx_mw,
        battery_power_mw = battery_mw,
        annual_curtailment_gwh = annual_curtailment_mwh / 1e3,
    )
end


# =============================================================================
# Run full grid for one battery location
# =============================================================================

"""
    run_tradeoff_grid(data, battery_node) -> DataFrame

Sweep the 5×4 grid of (TX expansion, battery capacity) for a given battery
location. Returns a DataFrame with 20 rows.
"""
function run_tradeoff_grid(data::SystemData, battery_node::String)
    println("-" ^ 60)
    println("Battery location: $(battery_node)")
    println("-" ^ 60)

    rows = NamedTuple[]
    n_total = length(TX_EXPANSION_MW) * length(BATTERY_POWER_MW)
    n_done = 0

    for tx_mw in TX_EXPANSION_MW
        for batt_mw in BATTERY_POWER_MW
            n_done += 1
            println("  [$(n_done)/$(n_total)] TX +$(tx_mw) MW, Battery $(batt_mw) MW...")
            point = solve_grid_point(data, tx_mw, batt_mw, battery_node)
            push!(rows, point)
            println("    curtailment = $(round(point.annual_curtailment_gwh, digits=1)) GWh/yr")
        end
    end

    return DataFrame(rows)
end


# =============================================================================
# Heatmap plotting
# =============================================================================

"""
    plot_tradeoff_heatmap(df, battery_node)

Generate a heatmap of annual curtailment (GWh/yr) over the 2D grid of
TX expansion (x-axis) vs battery capacity (y-axis). Cell values are annotated.
"""
function plot_tradeoff_heatmap(df::DataFrame, battery_node::String)
    println("Generating: tradeoff_heatmap_$(battery_node)")

    # Build the curtailment matrix: rows = battery sizes, cols = TX values
    n_tx = length(TX_EXPANSION_MW)
    n_batt = length(BATTERY_POWER_MW)
    z = Matrix{Float64}(undef, n_batt, n_tx)

    for (j, tx_mw) in enumerate(TX_EXPANSION_MW)
        for (i, batt_mw) in enumerate(BATTERY_POWER_MW)
            row = filter(r -> r.tx_expansion_mw == tx_mw &&
                              r.battery_power_mw == batt_mw, df)
            z[i, j] = row[1, :annual_curtailment_gwh]
        end
    end

    # Axis labels
    x_labels = ["+" * string(tx) for tx in TX_EXPANSION_MW]
    y_labels = [string(batt) for batt in BATTERY_POWER_MW]

    node_label = Dict("NE1" => "Northeast", "SE1" => "Southeast", "N1" => "North")[battery_node]

    p = heatmap(x_labels, y_labels, z;
        xlabel  = "NE-SE TX Expansion (MW)",
        ylabel  = "Battery Capacity (MW)",
        title   = "Annual Curtailment (GWh/yr) — Battery at $(node_label)",
        color   = cgrad(:YlOrRd, rev=true),
        clims   = (0, maximum(z) * 1.05),
        size    = (FIG_WIDTH + 120, FIG_HEIGHT),
        aspect_ratio = :auto,
        right_margin = 18Plots.mm,
    )

    # Annotate each cell with its value, centered
    # Skip zero-valued cells (clearly indicated by dark red color)
    z_max = maximum(z)
    for j in eachindex(TX_EXPANSION_MW)
        for i in eachindex(BATTERY_POWER_MW)
            val = round(z[i, j], digits=0)
            val == 0 && continue  # zero curtailment is obvious from the dark red color
            # With rev=true YlOrRd: low values → dark red, high values → light yellow
            # Use white text on dark (low-value) cells, black on light (high-value) cells
            text_color = z[i, j] < z_max * 0.4 ? :white : :black
            annotate!(p, j, i,
                text(string(Int(val)), 10, text_color, :center))
        end
    end

    save_figure(p, "tradeoff_heatmap_$(battery_node)")
    return p
end


# =============================================================================
# Main
# =============================================================================

function main()
    println("=" ^ 60)
    println("TX EXPANSION vs BATTERY CAPACITY TRADEOFF")
    println("=" ^ 60)
    println()

    set_plot_defaults()

    # Load system data
    data_dir = joinpath(@__DIR__, "..", "data", "output")
    data = load_system(data_dir)
    println("Loaded system data ($(length(data.generators)) generators, $(length(data.nodes)) nodes)")
    println("Battery E/P ratio: $(data.battery.energy_mwh / data.battery.power_mw)h")
    println()

    results_dir = joinpath(@__DIR__, "..", "results")
    mkpath(results_dir)

    # Run grids for both battery locations
    all_dfs = DataFrame[]
    for battery_node in BATTERY_LOCATIONS
        println()
        df = run_tradeoff_grid(data, battery_node)
        push!(all_dfs, df)
    end

    # Combine into single CSV
    combined = vcat(all_dfs...)
    csv_path = joinpath(results_dir, "tradeoff_tx_battery.csv")
    CSV.write(csv_path, combined)
    println()
    println("Saved: $(csv_path) ($(nrow(combined)) rows)")

    # Generate heatmaps
    println()
    for battery_node in BATTERY_LOCATIONS
        df_node = filter(r -> r.battery_node == battery_node, combined)
        plot_tradeoff_heatmap(df_node, battery_node)
    end

    # Summary
    println()
    println("=" ^ 60)
    println("TRADEOFF ANALYSIS COMPLETE")
    println("  Grid: $(length(TX_EXPANSION_MW)) TX × $(length(BATTERY_POWER_MW)) battery × $(length(BATTERY_LOCATIONS)) locations")
    println("  Total intertemporal LP solves: $(nrow(combined) * 2) (wet + dry per point)")
    println("  CSV: results/tradeoff_tx_battery.csv ($(nrow(combined)) rows)")
    println("  Figures:")
    for loc in BATTERY_LOCATIONS
        println("    - tradeoff_heatmap_$(loc) (.png/.pdf)")
    end
    println("=" ^ 60)
end

# Run
main()
