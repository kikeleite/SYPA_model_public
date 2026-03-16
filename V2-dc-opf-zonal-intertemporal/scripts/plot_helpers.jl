# plot_helpers.jl -- Shared plotting utilities for Phase 7 visualization
#
# Defines consistent scenario labels, color palettes, technology colors,
# scenario family groupings, and utility functions used by all plotting scripts.

using Plots, CSV, DataFrames

# ---------------------------------------------------------------------------
# Figure sizing constants
# ---------------------------------------------------------------------------

const FIG_WIDTH = 1000
const FIG_HEIGHT = 650
const FIG_WIDE = (1200, 650)   # Wide figures (many scenarios on x-axis)
const FIG_TALL = (900, 800)    # Tall figures (horizontal bar charts)

# ---------------------------------------------------------------------------
# Human-readable scenario labels (all 22 scenarios)
# ---------------------------------------------------------------------------

const SCENARIO_LABELS = Dict(
    "baseline"                      => "Baseline",
    "carbon_10"                     => "Carbon Tax \$10",
    "carbon_25"                     => "Carbon Tax \$25",
    "carbon_50"                     => "Carbon Tax \$50",
    "carbon_75"                     => "Carbon Tax \$75",
    "carbon_100"                    => "Carbon Tax \$100",
    "battery_N"                     => "Battery at N",
    "battery_NE"                    => "Battery at NE",
    "battery_SE"                    => "Battery at SE",
    "battery_S"                     => "Battery at S",
    "battery_NE_SE"                 => "Battery NE+SE",
    "subsidy_1"                     => "Subsidy \$1",
    "subsidy_10"                    => "Subsidy \$10",
    "tx_expand_2000"                => "TX +2000 MW",
    "tx_expand_5000"                => "TX +5000 MW",
    "tx_expand_10000"               => "TX +10000 MW",
    "carbon_50_battery_NE"          => "C50 + Batt NE",
    "carbon_50_battery_SE"          => "C50 + Batt SE",
    "carbon_50_battery_NE_SE"       => "C50 + Batt NE+SE",
    "carbon_50_tx_5000"             => "C50 + TX 5000",
    "carbon_50_battery_NE_tx_5000"  => "C50 + Batt NE + TX",
    "battery_all"                   => "Battery All Nodes",
    "carbon_50_battery_all"         => "C50 + Batt All",
)

# ---------------------------------------------------------------------------
# Scenario family groupings
# ---------------------------------------------------------------------------

const SCENARIO_FAMILIES = Dict(
    "Carbon Tax"        => ["baseline", "carbon_10", "carbon_25", "carbon_50",
                            "carbon_75", "carbon_100"],
    "Battery Placement" => ["baseline", "battery_N", "battery_NE", "battery_SE",
                            "battery_S", "battery_NE_SE"],
    "TX Expansion"      => ["baseline", "tx_expand_2000", "tx_expand_5000",
                            "tx_expand_10000"],
    "Subsidy"           => ["baseline", "subsidy_1", "subsidy_10"],
    "Combinations"      => ["baseline", "carbon_50", "carbon_50_battery_NE",
                            "carbon_50_battery_SE", "carbon_50_battery_NE_SE",
                            "carbon_50_tx_5000", "carbon_50_battery_NE_tx_5000"],
)

# ---------------------------------------------------------------------------
# Color palettes
# ---------------------------------------------------------------------------

# Colors by scenario family
const FAMILY_COLORS = Dict(
    "baseline"    => :gray,
    "carbon"      => :orangered,
    "battery"     => :royalblue,
    "subsidy"     => :forestgreen,
    "tx_expand"   => :purple,
    "combination" => :goldenrod,
)

# Colors by generation technology
const TECH_COLORS = Dict(
    "hydro"       => :deepskyblue,
    "thermal_gas" => :salmon,
    "thermal_coal"=> :brown,
    "wind"        => :mediumseagreen,
    "solar"       => :gold,
    "battery"     => :slateblue,
)

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

"""
    human_label(scenario_id) -> String

Return human-readable label for a scenario_id. Falls back to the raw ID if
not found in the mapping.
"""
function human_label(scenario_id::AbstractString)
    return get(SCENARIO_LABELS, scenario_id, scenario_id)
end

"""
    scenario_family(scenario_id) -> String

Return the family key for a given scenario_id, used for color mapping.
"""
function scenario_family(scenario_id::AbstractString)
    scenario_id == "baseline" && return "baseline"
    startswith(scenario_id, "carbon_50_battery") && return "combination"
    startswith(scenario_id, "carbon_50_tx")      && return "combination"
    startswith(scenario_id, "carbon")             && return "carbon"
    startswith(scenario_id, "battery")            && return "battery"
    startswith(scenario_id, "subsidy")            && return "subsidy"
    startswith(scenario_id, "tx_expand")          && return "tx_expand"
    return "baseline"  # fallback
end

"""
    family_color(scenario_id) -> Symbol

Return the color associated with the scenario's family.
"""
function family_color(scenario_id::AbstractString)
    return FAMILY_COLORS[scenario_family(scenario_id)]
end

"""
    save_figure(p, name)

Save figure `p` as both PNG and PDF in `results/figures/`. Creates the
output directory if it does not exist.
"""
function save_figure(p, name::String)
    figdir = joinpath(@__DIR__, "..", "results", "figures")
    mkpath(figdir)
    savefig(p, joinpath(figdir, name * ".png"))
    savefig(p, joinpath(figdir, name * ".pdf"))
    println("  Saved: $(name).png / $(name).pdf")
end

"""
    set_plot_defaults()

Configure Plots.jl defaults for consistent styling across all figures:
Helvetica font, box frame, subtle grid, appropriate font sizes and margins.
"""
function set_plot_defaults()
    default(
        size       = (FIG_WIDTH, FIG_HEIGHT),
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
