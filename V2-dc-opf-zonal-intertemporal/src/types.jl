# types.jl -- Type definitions for the V2 DC-OPF Brazil model
#
# Two-layer design:
#   Layer 1 (Raw Data): Structs that mirror CSV columns exactly, using string node IDs.
#     These hold everything loaded from the 8 CSV files in data/output/.
#   Layer 2 (Solver-Ready): Structs consumed by the JuMP/DC-OPF solver for a single
#     (season, period, scenario) case, using integer node indices.
#
# The build_case() function (defined in system.jl) converts from Layer 1 to Layer 2
# by selecting seasonal costs/capacities, applying renewable capacity factors,
# mapping string node IDs to integer indices, and applying scenario modifiers.
#
# All structs are immutable. Scenario modifications construct new instances rather
# than mutating existing ones.

# =============================================================================
# LAYER 1: Raw Data Structs (match CSV columns, string node IDs)
# =============================================================================

"""
    NodeData

One row from nodes.csv. Maps subsystems to nodes.
Each subsystem currently contains a single node (e.g., N -> N1).
"""
struct NodeData
    subsystem_id::String
    subsystem_name::String
    node_id::String
    node_name::String
end

"""
    GeneratorData

One row from generators.csv. Contains all seasonal cost and capacity information.
Hydro generators have different wet/dry costs and capacities; non-hydro generators
have identical values across seasons.
"""
struct GeneratorData
    gen_id::String
    node::String            # String node ID (e.g., "N1", "NE1")
    type::String            # "hydro", "thermal", "wind", "solar"
    capacity_mw::Float64    # Nameplate capacity (reference)
    capacity_wet_mw::Float64  # Available capacity in wet season
    capacity_dry_mw::Float64  # Available capacity in dry season
    cost_wet::Float64       # Marginal cost in wet season (R$/MWh)
    cost_dry::Float64       # Marginal cost in dry season (R$/MWh)
    emission_factor::Float64  # tCO2/MWh (0 for renewables/hydro)
    fuel::String            # Fuel type for thermals ("gas", "coal"); "" for others
    must_run_mw::Float64    # Minimum dispatch if committed (0 if fully dispatchable)

    function GeneratorData(gen_id, node, type, capacity_mw, capacity_wet_mw,
                           capacity_dry_mw, cost_wet, cost_dry,
                           emission_factor, fuel, must_run_mw)
        capacity_mw >= 0 || error("Generator $gen_id: capacity_mw must be >= 0, got $capacity_mw")
        capacity_wet_mw >= 0 || error("Generator $gen_id: capacity_wet_mw must be >= 0, got $capacity_wet_mw")
        capacity_dry_mw >= 0 || error("Generator $gen_id: capacity_dry_mw must be >= 0, got $capacity_dry_mw")
        cost_wet >= 0 || error("Generator $gen_id: cost_wet must be >= 0, got $cost_wet")
        cost_dry >= 0 || error("Generator $gen_id: cost_dry must be >= 0, got $cost_dry")
        emission_factor >= 0 || error("Generator $gen_id: emission_factor must be >= 0, got $emission_factor")
        must_run_mw >= 0 || error("Generator $gen_id: must_run_mw must be >= 0, got $must_run_mw")
        must_run_mw <= capacity_mw || error("Generator $gen_id: must_run_mw ($must_run_mw) exceeds capacity_mw ($capacity_mw)")
        type in ("hydro", "thermal", "wind", "solar") || error("Generator $gen_id: unknown type '$type'")
        return new(gen_id, node, type, capacity_mw, capacity_wet_mw,
                   capacity_dry_mw, cost_wet, cost_dry,
                   emission_factor, fuel, must_run_mw)
    end
end

"""
    DemandEntry

One row from demand.csv. Load at a specific node for a given season and period.
"""
struct DemandEntry
    node::String        # String node ID
    season::String      # "wet" or "dry"
    period::String      # "night", "day", or "peak"
    load_mw::Float64    # Demand in MW

    function DemandEntry(node, season, period, load_mw)
        load_mw >= 0 || error("Demand at $node/$season/$period: load_mw must be >= 0, got $load_mw")
        season in ("wet", "dry") || error("Demand at $node: invalid season '$season'")
        period in ("night", "day", "peak") || error("Demand at $node: invalid period '$period'")
        return new(node, season, period, load_mw)
    end
end

"""
    RenewableProfile

One row from renewable_profiles.csv. Capacity factor for a wind/solar generator
in a specific season and period.
"""
struct RenewableProfile
    gen_id::String      # Matches gen_id in generators.csv
    season::String      # "wet" or "dry"
    period::String      # "night", "day", or "peak"
    capacity_factor::Float64  # Available fraction of installed capacity (0-1)

    function RenewableProfile(gen_id, season, period, capacity_factor)
        0 <= capacity_factor <= 1 || error("Profile $gen_id/$season/$period: capacity_factor must be in [0,1], got $capacity_factor")
        season in ("wet", "dry") || error("Profile $gen_id: invalid season '$season'")
        period in ("night", "day", "peak") || error("Profile $gen_id: invalid period '$period'")
        return new(gen_id, season, period, capacity_factor)
    end
end

"""
    TransmissionLineData

One row from transmission.csv. Interconnection between two nodes.
"""
struct TransmissionLineData
    line_id::String
    from_node::String   # String node ID
    to_node::String     # String node ID
    capacity_mw::Float64  # Transfer limit (MW, bidirectional)
    reactance_pu::Float64 # Per-unit reactance for DC power flow

    function TransmissionLineData(line_id, from_node, to_node, capacity_mw, reactance_pu)
        capacity_mw > 0 || error("Line $line_id: capacity_mw must be > 0, got $capacity_mw")
        reactance_pu > 0 || error("Line $line_id: reactance_pu must be > 0, got $reactance_pu")
        return new(line_id, from_node, to_node, capacity_mw, reactance_pu)
    end
end

"""
    BatteryParams

Key-value parameters from battery.csv. Defines the battery's technical characteristics.
Location is a scenario parameter, not a battery property.

All fields are loaded even though the static solver (Phase 3) only uses power_mw and
cost_mwh. The intertemporal solver (Phase 5) will use energy_mwh, efficiency, and
initial_soc for charge/discharge and state-of-charge tracking.
"""
struct BatteryParams
    power_mw::Float64       # Charge/discharge rating (MW)
    energy_mwh::Float64     # Total energy capacity (MWh)
    efficiency::Float64     # Round-trip efficiency (0-1)
    cost_mwh::Float64       # Marginal operating cost (R$/MWh discharged)
    initial_soc::Float64    # Starting state of charge (fraction of energy_mwh)

    function BatteryParams(power_mw, energy_mwh, efficiency, cost_mwh, initial_soc)
        power_mw > 0 || error("BatteryParams: power_mw must be > 0, got $power_mw")
        energy_mwh > 0 || error("BatteryParams: energy_mwh must be > 0, got $energy_mwh")
        0 < efficiency <= 1 || error("BatteryParams: efficiency must be in (0,1], got $efficiency")
        cost_mwh >= 0 || error("BatteryParams: cost_mwh must be >= 0, got $cost_mwh")
        0 <= initial_soc <= 1 || error("BatteryParams: initial_soc must be in [0,1], got $initial_soc")
        return new(power_mw, energy_mwh, efficiency, cost_mwh, initial_soc)
    end
end

"""
    PeriodDef

One row from temporal.csv. Defines a daily period and its duration.
The model uses `hours` to weight costs when computing daily totals.
"""
struct PeriodDef
    period::String      # "night", "day", or "peak"
    hours::Float64      # Duration of period (hours in a representative day)
    start_hour::Float64 # Approximate start hour (for labeling)
    end_hour::Float64   # Approximate end hour (for labeling)

    function PeriodDef(period, hours, start_hour, end_hour)
        hours > 0 || error("PeriodDef '$period': hours must be > 0, got $hours")
        period in ("night", "day", "peak") || error("PeriodDef: unknown period '$period'")
        return new(period, hours, start_hour, end_hour)
    end
end

"""
    ScenarioDef

One row from scenarios.csv. Defines a policy scenario's parameters.
The scenario runner iterates over these, modifying the base system accordingly.
"""
struct ScenarioDef
    scenario_id::String
    carbon_tax_per_tco2::Float64  # Carbon surcharge per tCO2 (R$/tCO2, 0 = no tax)
    subsidy_per_mwh::Float64      # Renewable cost reduction (R$/MWh, 0 = no subsidy)
    battery_node::String          # "none", single node ID, or ";" separated node IDs
    tx_expansion_line::String     # "none" or line_id from transmission.csv
    tx_expansion_mw::Float64      # Additional capacity on expanded line (MW, 0 = none)

    function ScenarioDef(scenario_id, carbon_tax_per_tco2, subsidy_per_mwh,
                         battery_node, tx_expansion_line, tx_expansion_mw)
        carbon_tax_per_tco2 >= 0 || error("Scenario $scenario_id: carbon_tax_per_tco2 must be >= 0, got $carbon_tax_per_tco2")
        subsidy_per_mwh >= 0 || error("Scenario $scenario_id: subsidy_per_mwh must be >= 0, got $subsidy_per_mwh")
        tx_expansion_mw >= 0 || error("Scenario $scenario_id: tx_expansion_mw must be >= 0, got $tx_expansion_mw")
        return new(scenario_id, carbon_tax_per_tco2, subsidy_per_mwh,
                   battery_node, tx_expansion_line, tx_expansion_mw)
    end
end

"""
    SystemData

Container holding all loaded CSV data. Created once at startup by the data loader.
The build_case() function (in system.jl) constructs solver-ready PowerSystem instances
from this container by selecting data for a specific (season, period, scenario) case.

- `demand`: Dict keyed by (node_id, season, period) -> load in MW
- `profiles`: Dict keyed by (gen_id, season, period) -> capacity factor [0,1]
- `node_to_idx`: Maps string node IDs to integer indices for JuMP variables
- `idx_to_node`: Reverse mapping for result display
"""
struct SystemData
    nodes::Vector{NodeData}
    generators::Vector{GeneratorData}
    demand::Dict{Tuple{String,String,String}, Float64}
    profiles::Dict{Tuple{String,String,String}, Float64}
    transmission::Vector{TransmissionLineData}
    battery::BatteryParams
    temporal::Vector{PeriodDef}
    scenarios::Vector{ScenarioDef}
    node_to_idx::Dict{String,Int}
    idx_to_node::Dict{Int,String}
end


# =============================================================================
# LAYER 2: Solver-Ready Structs (integer node indices, single-case values)
# =============================================================================

"""
    Generator

A generator ready for the JuMP solver. Holds data for a single (season, period) case:
capacity is the available MW (after seasonal selection and renewable CF multiplication),
and marginal_cost is the cost for the selected season.
"""
struct Generator
    name::String
    node::Int               # Integer index for JuMP theta[n] variables
    capacity::Float64       # Available capacity for this case (MW)
    marginal_cost::Float64  # Cost for this season (R$/MWh)
    must_run_mw::Float64    # Minimum dispatch (MW, 0 if fully dispatchable)
    emission_factor::Float64  # tCO2/MWh (for carbon tax calculation)

    function Generator(name, node, capacity, marginal_cost, must_run_mw, emission_factor)
        capacity >= 0 || error("Generator $name: capacity must be >= 0, got $capacity")
        # marginal_cost can be negative (e.g. subsidized renewables)
        must_run_mw >= 0 || error("Generator $name: must_run_mw must be >= 0, got $must_run_mw")
        must_run_mw <= capacity || error("Generator $name: must_run_mw ($must_run_mw) exceeds capacity ($capacity)")
        emission_factor >= 0 || error("Generator $name: emission_factor must be >= 0, got $emission_factor")
        return new(name, node, capacity, marginal_cost, must_run_mw, emission_factor)
    end
end

"""
    Battery

A battery instance placed at a specific node, ready for the JuMP solver.
In the static solver (Phase 3), this is treated as a simple generator.
In the intertemporal solver (Phase 5), charge/discharge variables and SOC
tracking will reference the full BatteryParams from SystemData.
"""
struct Battery
    name::String
    node::Int               # Integer index for JuMP variables
    power_mw::Float64       # Charge/discharge rating (MW)
    cost_mwh::Float64       # Marginal operating cost (R$/MWh)

    function Battery(name, node, power_mw, cost_mwh)
        power_mw > 0 || error("Battery $name: power_mw must be > 0, got $power_mw")
        cost_mwh >= 0 || error("Battery $name: cost_mwh must be >= 0, got $cost_mwh")
        return new(name, node, power_mw, cost_mwh)
    end
end

"""
    TransmissionLine

A transmission line ready for the JuMP solver, with integer node indices.
"""
struct TransmissionLine
    from_node::Int          # Integer index
    to_node::Int            # Integer index
    reactance::Float64      # Per-unit reactance
    capacity::Float64       # Transfer limit (MW, bidirectional)

    function TransmissionLine(from_node, to_node, reactance, capacity)
        reactance > 0 || error("Line $from_node->$to_node: reactance must be > 0, got $reactance")
        capacity > 0 || error("Line $from_node->$to_node: capacity must be > 0, got $capacity")
        return new(from_node, to_node, reactance, capacity)
    end
end

"""
    PowerSystem

The complete system representation for a single JuMP solve. Contains all generators,
batteries, loads, and lines for one (season, period, scenario) case.

- `loads` is a Vector{Float64} indexed by integer node (loads[1] = load at node 1)
- Node 1 (N1) is the slack bus (theta[1] = 0 in the DC-OPF)
"""
struct PowerSystem
    n_nodes::Int
    generators::Vector{Generator}
    batteries::Vector{Battery}
    loads::Vector{Float64}              # Indexed by integer node
    lines::Vector{TransmissionLine}

    function PowerSystem(n_nodes, generators, batteries, loads, lines)
        n_nodes > 0 || error("PowerSystem: n_nodes must be > 0, got $n_nodes")
        length(loads) == n_nodes || error("PowerSystem: loads length ($(length(loads))) != n_nodes ($n_nodes)")
        return new(n_nodes, generators, batteries, loads, lines)
    end
end


"""
    CaseData

Bundles a PowerSystem with metadata needed for result labeling and display.
Constructed by build_case_data() in system.jl -- not intended for direct construction.

Fields:
- `system`: The solver-ready PowerSystem for this (season, period, scenario) case
- `season`: "wet" or "dry" -- for result labeling
- `period`: "night", "day", or "peak" -- for result labeling
- `scenario_id`: Scenario name for display (e.g., "baseline", "carbon_50")
- `idx_to_node`: Integer index -> node ID string (e.g., 1 -> "N1") for readable output
- `gen_types`: gen_id -> type ("hydro", "thermal", "wind", "solar") for post-solve
    curtailment and emissions classification
- `line_ids`: Line ID strings parallel to system.lines (e.g., ["N_NE", "NE_SE", ...])
    for keying flow results
"""
struct CaseData
    system::PowerSystem
    season::String
    period::String
    scenario_id::String
    idx_to_node::Dict{Int,String}
    gen_types::Dict{String,String}
    line_ids::Vector{String}
end
