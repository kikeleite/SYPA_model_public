# display.jl -- Formatted display of SCED solver results
#
# Provides print_results() for human-readable output of dispatch, flows, prices,
# emissions, and curtailment. Uses PrettyTables.jl for clean aligned tables.
# Called explicitly by the user/scenario runner -- the solver itself is silent.
#
# Also provides print_scenario_header() for scenario banner display,
# print_cross_scenario_summary() for compact cross-scenario comparison tables,
# print_battery_summary() for SOC trajectory display, and
# print_battery_cross_scenario_summary() for battery scenario comparison.

include("solver.jl")

using PrettyTables

# Tolerance for reporting a line as binding. A line is binding if
# abs(flow) >= capacity * (1 - BINDING_TOL). BINDING_TOL is defined in solver.jl.


"""
    print_results(result::NamedTuple, case::CaseData)

Format and display SCED solver results using PrettyTables.

Output layout (5 sections):
1. Header with case identification and solver status
2. Generator dispatch table (sorted by dispatch, descending)
3. Transmission flows table with binding status
4. Zonal prices one-liner
5. Summary: total cost, emissions, curtailment
"""
function print_results(result::NamedTuple, case::CaseData)
    system = case.system

    # =========================================================================
    # Section 1: Header
    # =========================================================================
    println("=" ^ 70)
    println("Case: $(case.season) / $(case.period) / $(case.scenario_id)")
    println("Solver Status: $(result.solver_status)")
    println("=" ^ 70)

    if result.solver_status != "OPTIMAL"
        println("WARNING: Solver did not find optimal solution. Results may be unreliable.")
        println()
        return
    end

    # =========================================================================
    # Section 2: Generator Dispatch Table
    # =========================================================================

    # Collect generator rows: (name, node_str, type, available_mw, dispatch_mw, cost)
    gen_rows = []
    for gen in system.generators
        node_str = case.idx_to_node[gen.node]
        gen_type = case.gen_types[gen.name]
        available = gen.capacity
        dispatched = get(result.dispatch, gen.name, 0.0)
        cost = gen.marginal_cost
        push!(gen_rows, (gen.name, node_str, gen_type, available, dispatched, cost))
    end

    # Add battery rows at the bottom
    for batt in system.batteries
        node_str = case.idx_to_node[batt.node]
        available = batt.power_mw
        dispatched = get(result.dispatch, batt.name, 0.0)
        cost = batt.cost_mwh
        push!(gen_rows, (batt.name, node_str, "battery", available, dispatched, cost))
    end

    # Sort by dispatch amount (descending) for easy reading
    sort!(gen_rows, by=r -> -r[5])

    # Build matrix for PrettyTables
    n_rows = length(gen_rows)
    gen_matrix = Matrix{Any}(undef, n_rows, 6)
    for (i, row) in enumerate(gen_rows)
        gen_matrix[i, 1] = row[1]  # Generator
        gen_matrix[i, 2] = row[2]  # Node
        gen_matrix[i, 3] = row[3]  # Type
        gen_matrix[i, 4] = row[4]  # Available (MW)
        gen_matrix[i, 5] = row[5]  # Dispatch (MW)
        gen_matrix[i, 6] = row[6]  # Cost (R$/MWh)
    end

    gen_labels = ["Generator", "Node", "Type", "Available (MW)", "Dispatch (MW)", "Cost (R\$/MWh)"]

    println()
    pretty_table(gen_matrix;
        column_labels = gen_labels,
        alignment = [:l, :c, :c, :r, :r, :r],
        formatters = [fmt__printf("%.1f", [4, 5, 6])],
        maximum_number_of_rows = -1,
        maximum_number_of_columns = -1,
        fit_table_in_display_horizontally = false,
        fit_table_in_display_vertically = false,
    )

    # =========================================================================
    # Section 3: Transmission Flows Table
    # =========================================================================

    n_lines = length(system.lines)
    flow_matrix = Matrix{Any}(undef, n_lines, 5)

    for (idx, line) in enumerate(system.lines)
        line_id = case.line_ids[idx]
        flow = get(result.flows, line_id, 0.0)
        capacity = line.capacity
        utilization = abs(flow) / capacity * 100.0
        binding = abs(flow) >= capacity * (1 - BINDING_TOL) ? "YES" : "No"

        flow_matrix[idx, 1] = line_id
        flow_matrix[idx, 2] = flow
        flow_matrix[idx, 3] = capacity
        flow_matrix[idx, 4] = utilization
        flow_matrix[idx, 5] = binding
    end

    flow_labels = ["Line", "Flow (MW)", "Capacity (MW)", "Utilization (%)", "Binding?"]

    println()
    pretty_table(flow_matrix;
        column_labels = flow_labels,
        alignment = [:l, :r, :r, :r, :c],
        formatters = [fmt__printf("%.1f", [2, 3, 4])],
        maximum_number_of_rows = -1,
        maximum_number_of_columns = -1,
        fit_table_in_display_horizontally = false,
        fit_table_in_display_vertically = false,
    )

    # =========================================================================
    # Section 4: Zonal Prices (one-liner)
    # =========================================================================

    # Sort nodes by index for consistent ordering (N1=1, NE1=2, SE1=3, S1=4)
    sorted_nodes = sort(collect(keys(case.idx_to_node)))
    price_parts = String[]
    for idx in sorted_nodes
        node_str = case.idx_to_node[idx]
        lmp = get(result.lmps, node_str, NaN)
        push!(price_parts, "$(node_str)=\$$(round(lmp, digits=1))")
    end
    println()
    println("Zonal Prices (R\$/MWh): ", join(price_parts, "  "))

    # =========================================================================
    # Section 5: Summary
    # =========================================================================

    println()
    println("Total Cost: \$$(format_number(result.total_cost))/h")
    println("Emissions: $(round(result.emissions_tco2, digits=1)) tCO2/h")

    # Curtailment (only if non-empty)
    if !isempty(result.curtailment)
        total_curt = sum(values(result.curtailment))
        curt_parts = ["$(k): $(round(v, digits=1)) MW" for (k, v) in sort(collect(result.curtailment), by=p->-p[2])]
        println("Curtailment: $(round(total_curt, digits=1)) MW total ($(join(curt_parts, ", ")))")
    end

    println()
end


"""
    format_number(x::Float64) -> String

Format a number with comma thousands separators and one decimal place.
E.g., 1234567.89 -> "1,234,567.9"
"""
function format_number(x::Float64)::String
    if isnan(x) || isinf(x)
        return string(x)
    end
    # Round to 1 decimal
    rounded = round(x, digits=1)
    # Split integer and decimal parts
    int_part = trunc(Int, rounded)
    dec_part = round(abs(rounded - int_part) * 10)

    # Format integer part with commas
    negative = int_part < 0
    int_str = string(abs(int_part))
    groups = String[]
    while length(int_str) > 3
        pushfirst!(groups, int_str[end-2:end])
        int_str = int_str[1:end-3]
    end
    pushfirst!(groups, int_str)
    formatted = join(groups, ",")

    if negative
        formatted = "-" * formatted
    end

    return formatted * "." * string(Int(dec_part))
end


"""
    print_scenario_header(scenario::ScenarioDef)

Print a clear banner between scenarios in the runner loop.
Shows the scenario ID and its policy parameters on a single line.
"""
function print_scenario_header(scenario::ScenarioDef)
    println("\n" * "=" ^ 80)
    println("SCENARIO: $(scenario.scenario_id)")

    # Build policy description parts
    policy_parts = String[]
    if scenario.carbon_tax_per_tco2 > 0
        push!(policy_parts, "carbon_tax=$(scenario.carbon_tax_per_tco2) R\$/tCO2")
    end
    if scenario.subsidy_per_mwh > 0
        push!(policy_parts, "subsidy=$(scenario.subsidy_per_mwh) R\$/MWh")
    end
    if scenario.battery_node != "none"
        push!(policy_parts, "battery=$(scenario.battery_node)")
    end
    if scenario.tx_expansion_line != "none" && scenario.tx_expansion_mw > 0
        push!(policy_parts, "tx_expansion=$(scenario.tx_expansion_line) +$(Int(scenario.tx_expansion_mw)) MW")
    end

    if isempty(policy_parts)
        println("Policy: baseline (no modifications)")
    else
        println("Policy: $(join(policy_parts, ", "))")
    end
    println("=" ^ 80 * "\n")
end


"""
    print_cross_scenario_summary(summary_data::Vector{<:NamedTuple})

Print a compact PrettyTables comparison of all scenarios' annual metrics.

Each element of `summary_data` must be a NamedTuple with fields:
  - scenario_id::String
  - annual_cost_full::Float64      (R\$/year, all periods)
  - annual_cost_nonpeak::Float64   (R\$/year, Night + Day only)
  - annual_emissions_tco2::Float64 (tCO2/year)
  - annual_curtailment_mwh::Float64 (MWh/year)
  - n_binding_cases::Int           (count of binding line-case pairs)

Costs displayed in M R\$/year, emissions in ktCO2/year, curtailment in GWh/year.
"""
function print_cross_scenario_summary(summary_data::Vector{<:NamedTuple})
    n = length(summary_data)
    n > 0 || return

    println("\n" * "=" ^ 80)
    println("CROSS-SCENARIO COMPARISON SUMMARY")
    println("=" ^ 80)
    println()

    # Build display matrix (n scenarios x 6 columns)
    matrix = Matrix{Any}(undef, n, 6)

    for (i, s) in enumerate(summary_data)
        matrix[i, 1] = s.scenario_id
        matrix[i, 2] = s.annual_cost_full / 1e6          # R$/year -> M R$/year
        matrix[i, 3] = s.annual_cost_nonpeak / 1e6        # R$/year -> M R$/year
        matrix[i, 4] = s.annual_emissions_tco2 / 1e3      # tCO2/year -> ktCO2/year
        matrix[i, 5] = s.annual_curtailment_mwh / 1e3     # MWh/year -> GWh/year
        matrix[i, 6] = s.n_binding_cases
    end

    labels = [
        "Scenario",
        "Cost* (M R\$/yr)",
        "Cost** (M R\$/yr)",
        "Emiss (ktCO2/yr)",
        "Curtail (GWh/yr)",
        "Binding"
    ]

    pretty_table(matrix;
        column_labels = labels,
        alignment = [:l, :r, :r, :r, :r, :r],
        formatters = [fmt__printf("%.0f", [2, 3, 4, 5])],
        maximum_number_of_rows = -1,
        maximum_number_of_columns = -1,
        fit_table_in_display_horizontally = false,
        fit_table_in_display_vertically = false,
    )

    # Footnotes
    println()
    println("*  Full annual cost (all periods)")
    println("** Non-peak annual cost (Night + Day only)")
    println()
end


# =============================================================================
# Battery-specific display functions (Phase 5)
# =============================================================================

"""
    print_battery_summary(result, data::SystemData, scenario_id::String, season::String)

Print a PrettyTables-formatted SOC trajectory table for a 30-period intertemporal
solve result. Shows charge, discharge, and SOC for each of the 30 periods.

For single-battery scenarios: columns are Day, Period, Hours, Charge (MW),
Discharge (MW), SOC End (MWh), SOC (%).

For multi-battery scenarios (e.g., NE1;SE1): separate columns per battery for
charge, discharge, and SOC.

Parameters:
  - result: NamedTuple returned by solve_intertemporal()
  - data: SystemData (for battery energy_mwh to compute SOC %)
  - scenario_id: scenario name for the header
  - season: "wet" or "dry" for the header
"""
function print_battery_summary(result, data::SystemData, scenario_id::String, season::String)
    # Check for batteries
    if isempty(result.periods) || isempty(result.periods[1].charge_mw)
        println("No batteries in this scenario -- nothing to display.")
        return
    end

    energy_mwh = data.battery.energy_mwh
    n_periods = length(result.periods)

    # Detect battery names from the first period's results
    battery_names = sort(collect(keys(result.periods[1].charge_mw)))
    n_batt = length(battery_names)

    println("\n" * "=" ^ 80)
    println("Battery SOC Trajectory: $(scenario_id) / $(season)")
    println("=" ^ 80)
    println()

    if n_batt == 1
        # --- Single battery: compact table ---
        bname = battery_names[1]

        matrix = Matrix{Any}(undef, n_periods, 7)
        for t in 1:n_periods
            pr = result.periods[t]
            soc_val = pr.soc_end[bname]

            matrix[t, 1] = pr.day
            matrix[t, 2] = pr.period
            matrix[t, 3] = pr.hours
            matrix[t, 4] = max(0.0, pr.charge_mw[bname])      # Clamp -0.0 to 0.0
            matrix[t, 5] = max(0.0, pr.discharge_mw[bname])    # Clamp -0.0 to 0.0
            matrix[t, 6] = soc_val
            matrix[t, 7] = soc_val / energy_mwh * 100.0
        end

        labels = ["Day", "Period", "Hours", "Charge (MW)", "Discharge (MW)",
                  "SOC End (MWh)", "SOC (%)"]

        pretty_table(matrix;
            column_labels = labels,
            alignment = [:r, :l, :r, :r, :r, :r, :r],
            formatters = [fmt__printf("%.1f", [4, 5, 6, 7])],
            maximum_number_of_rows = -1,
            maximum_number_of_columns = -1,
            fit_table_in_display_horizontally = false,
            fit_table_in_display_vertically = false,
        )
    else
        # --- Multi-battery: separate columns per battery ---
        # Columns: Day, Period, Hours, then per battery: Chg, Dis, SOC (MWh)
        n_cols = 3 + n_batt * 3
        matrix = Matrix{Any}(undef, n_periods, n_cols)

        for t in 1:n_periods
            pr = result.periods[t]
            matrix[t, 1] = pr.day
            matrix[t, 2] = pr.period
            matrix[t, 3] = pr.hours

            for (bi, bname) in enumerate(battery_names)
                col_base = 3 + (bi - 1) * 3
                matrix[t, col_base + 1] = max(0.0, pr.charge_mw[bname])
                matrix[t, col_base + 2] = max(0.0, pr.discharge_mw[bname])
                matrix[t, col_base + 3] = pr.soc_end[bname]
            end
        end

        # Build labels: short battery ID from name (e.g., "Battery_NE1" -> "NE1")
        labels = String["Day", "Period", "Hours"]
        fmt_cols = Int[]
        for (bi, bname) in enumerate(battery_names)
            short = replace(bname, "Battery_" => "")
            col_base = 3 + (bi - 1) * 3
            push!(labels, "Chg $short")
            push!(labels, "Dis $short")
            push!(labels, "SOC $short (MWh)")
            push!(fmt_cols, col_base + 1, col_base + 2, col_base + 3)
        end

        alignment = vcat([:r, :l, :r], repeat([:r], n_batt * 3))

        pretty_table(matrix;
            column_labels = labels,
            alignment = alignment,
            formatters = [fmt__printf("%.1f", fmt_cols)],
            maximum_number_of_rows = -1,
            maximum_number_of_columns = -1,
            fit_table_in_display_horizontally = false,
            fit_table_in_display_vertically = false,
        )
    end

    # Footer with battery parameters
    println()
    println("Battery params: $(Int(data.battery.power_mw)) MW / " *
            "$(Int(data.battery.energy_mwh)) MWh / " *
            "efficiency=$(data.battery.efficiency)")
    println()
end


"""
    print_battery_cross_scenario_summary(all_battery_metrics::Vector{<:NamedTuple})

Print a compact cross-scenario comparison table for battery scenarios, extending
the standard print_cross_scenario_summary with battery-specific columns.

Each element of `all_battery_metrics` must be a NamedTuple with fields:
  - scenario_id, annual_cost_full, annual_cost_nonpeak, annual_emissions_tco2,
    annual_curtailment_mwh, n_binding_cases (same as Phase 4)
  - annual_charge_mwh::Float64     (MWh/year total energy charged)
  - annual_discharge_mwh::Float64  (MWh/year total energy discharged)
  - avg_cycles_per_day::Float64    (average daily full-cycle equivalents)

Costs displayed in M R\$/year, emissions in ktCO2/year, energy in GWh/year.
"""
function print_battery_cross_scenario_summary(all_battery_metrics::Vector{<:NamedTuple})
    n = length(all_battery_metrics)
    n > 0 || return

    println("\n" * "=" ^ 80)
    println("BATTERY CROSS-SCENARIO COMPARISON SUMMARY")
    println("=" ^ 80)
    println()

    # Build display matrix (n scenarios x 9 columns)
    matrix = Matrix{Any}(undef, n, 9)

    for (i, s) in enumerate(all_battery_metrics)
        matrix[i, 1] = s.scenario_id
        matrix[i, 2] = s.annual_cost_full / 1e6            # R$/year -> M R$/year
        matrix[i, 3] = s.annual_cost_nonpeak / 1e6          # R$/year -> M R$/year
        matrix[i, 4] = s.annual_emissions_tco2 / 1e3        # tCO2/year -> ktCO2/year
        matrix[i, 5] = s.annual_curtailment_mwh / 1e3       # MWh/year -> GWh/year
        matrix[i, 6] = s.n_binding_cases
        matrix[i, 7] = s.annual_charge_mwh / 1e3            # MWh/year -> GWh/year
        matrix[i, 8] = s.annual_discharge_mwh / 1e3          # MWh/year -> GWh/year
        matrix[i, 9] = s.avg_cycles_per_day
    end

    labels = [
        "Scenario",
        "Cost* (M R\$/yr)",
        "Cost** (M R\$/yr)",
        "Emiss (ktCO2/yr)",
        "Curtail (GWh/yr)",
        "Binding",
        "Charge (GWh/yr)",
        "Discharge (GWh/yr)",
        "Cycles/Day"
    ]

    pretty_table(matrix;
        column_labels = labels,
        alignment = [:l, :r, :r, :r, :r, :r, :r, :r, :r],
        formatters = [fmt__printf("%.0f", [2, 3, 4, 5, 7, 8]),
                      fmt__printf("%.2f", [9])],
        maximum_number_of_rows = -1,
        maximum_number_of_columns = -1,
        fit_table_in_display_horizontally = false,
        fit_table_in_display_vertically = false,
    )

    # Footnotes
    println()
    println("*  Full annual cost (all periods)")
    println("** Non-peak annual cost (Night + Day only)")
    println("Charge/Discharge: annual energy charged/discharged by all batteries")
    println("Cycles/Day: avg daily full-cycle equivalents (discharge_MWh_per_day / energy_mwh)")
    println()
end


"""
    print_battery_profitability_summary(all_battery_metrics::Vector{<:NamedTuple})

Print a per-battery profitability comparison table for each scenario that has
per-battery metrics. Shows charge/discharge volumes, cycling, revenue, charging
cost, and net profit for each battery across all scenarios.

Each element of `all_battery_metrics` must have a `per_battery_metrics` field:
  Dict{String, NamedTuple} keyed by battery name with fields:
    node_id, annual_charge_mwh, annual_discharge_mwh,
    annual_revenue, annual_charging_cost, annual_profit, avg_cycles_per_day
"""
function print_battery_profitability_summary(all_battery_metrics::Vector{<:NamedTuple})
    isempty(all_battery_metrics) && return

    for metrics in all_battery_metrics
        pbm = metrics.per_battery_metrics
        isempty(pbm) && continue

        println("\n" * "=" ^ 80)
        println("PER-BATTERY PROFITABILITY: $(metrics.scenario_id)")
        println("=" ^ 80)
        println()

        # Sort batteries by name for consistent ordering
        sorted_names = sort(collect(keys(pbm)))
        n = length(sorted_names)

        matrix = Matrix{Any}(undef, n, 8)

        for (i, bn) in enumerate(sorted_names)
            bm = pbm[bn]
            matrix[i, 1] = replace(bn, "Battery_" => "Batt ")
            matrix[i, 2] = bm.node_id
            matrix[i, 3] = bm.annual_charge_mwh / 1e3       # MWh -> GWh
            matrix[i, 4] = bm.annual_discharge_mwh / 1e3     # MWh -> GWh
            matrix[i, 5] = bm.avg_cycles_per_day
            matrix[i, 6] = bm.annual_revenue / 1e6           # R$ -> M R$
            matrix[i, 7] = bm.annual_charging_cost / 1e6     # R$ -> M R$
            matrix[i, 8] = bm.annual_profit / 1e6            # R$ -> M R$
        end

        labels = [
            "Battery", "Node",
            "Charge (GWh/yr)", "Discharge (GWh/yr)", "Cycles/Day",
            "Revenue (M R\$/yr)", "Chg Cost (M R\$/yr)", "Net Profit (M R\$/yr)"
        ]

        pretty_table(matrix;
            column_labels = labels,
            alignment = [:l, :c, :r, :r, :r, :r, :r, :r],
            formatters = [fmt__printf("%.1f", [3, 4, 6, 7, 8]),
                          fmt__printf("%.2f", [5])],
            maximum_number_of_rows = -1,
            maximum_number_of_columns = -1,
            fit_table_in_display_horizontally = false,
            fit_table_in_display_vertically = false,
        )

        println()
        println("Revenue = discharge_MWh * LMP at battery node (summed over all periods, annualized)")
        println("Chg Cost = charge_MWh * LMP at battery node (summed over all periods, annualized)")
        println("Net Profit = Revenue - Chg Cost (excludes battery CapEx and O&M)")
        println()
    end
end
