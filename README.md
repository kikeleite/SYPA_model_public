# SYPA: Stylized 4-Node DC-OPF Model of Brazil's Electricity System

A zonal DC optimal power flow model of Brazil's interconnected grid, designed to analyze the impact of carbon taxes, renewable subsidies, battery storage, and transmission expansion on system costs, emissions, and renewable curtailment.

## Model Overview

The model represents Brazil's four electrical subsystems (N, NE, SE/CO, S) as a 4-node network with:

- **30 generators**: hydro (stepped supply curve with wet/dry costs), thermal (must-run, gas, coal), wind, and solar
- **4 transmission corridors**: N-NE, NE-SE, SE-S, N-SE with DC power flow constraints
- **Battery storage**: 200 MW / 4h Li-ion, location as a scenario parameter
- **11 policy scenarios**: carbon tax, renewable subsidy, battery placement, transmission expansion, and combinations

The solver performs security-constrained economic dispatch (SCED) using JuMP/HiGHS across 2 seasons (wet/dry) x 3 daily periods (night/day/peak), annualized to full-year metrics.

## Repository Structure

```
V2-dc-opf-zonal-intertemporal/
  src/
    types.jl          # Type definitions (raw data + solver-ready structs)
    loader.jl         # CSV data loader
    system.jl         # Case builder (season/period/scenario -> PowerSystem)
    solver.jl         # DC-OPF SCED solver (JuMP/HiGHS)
    intertemporal.jl  # Intertemporal solver with battery SOC tracking
    display.jl        # Result formatting and display
  scripts/
    run_scenarios.jl   # Run all 11 policy scenarios
    run_battery.jl     # Battery profitability analysis
    run_sensitivity.jl # NE-SE capacity sensitivity sweep
    run_welfare.jl     # Welfare decomposition analysis
    run_tx_battery_tradeoff.jl  # 2D transmission-battery tradeoff
    plot_figures.jl    # Generate all figures
    plot_helpers.jl    # Shared plotting utilities
    plot_battery_profitability.jl  # Battery profit visualization
    verify_sced.jl     # Solver verification
    verify_scenarios.jl # Scenario verification
    verify_battery.jl  # Battery verification
    verify_welfare.jl  # Welfare verification
  Project.toml         # Julia dependencies

# Root-level plotting scripts (Python/Julia)
plot_*.py / plot_*.jl  # Publication figures
chart_helpers.py       # Shared Python plotting utilities
compute_ons_metrics.py # ONS data metrics computation
```

## Data (Not Included)

The data files are not included in this repository due to size. The model expects the following structure under `V2-dc-opf-zonal-intertemporal/data/`:

### Input Data (`data/output/`)

These CSV files define the model parameters, calibrated from ONS (Operador Nacional do Sistema Eletrico) 2025 data:

| File | Description |
|------|-------------|
| `nodes.csv` | 4 nodes mapping subsystems (N, NE, SE, S) to node IDs |
| `generators.csv` | 30 generators with seasonal costs, capacities, emission factors |
| `demand.csv` | Load by node, season, and period (MW) |
| `renewable_profiles.csv` | Wind/solar capacity factors by season and period |
| `transmission.csv` | 4 inter-regional corridors with capacity and reactance |
| `battery.csv` | Battery technical parameters (200 MW, 4h, 85% efficiency) |
| `temporal.csv` | Period definitions (night/day/peak hours) |
| `scenarios.csv` | 11 policy scenario definitions |

### Raw Data (`data/raw_data/`)

Source data from ONS used for calibration:

- `GERACAO_USINA-2_2025_*.csv` — Monthly generation by plant (Jan-Dec 2025)
- `RESTRICAO_COFF_FOTOVOLTAICA_2025_*.csv` — Solar curtailment orders
- `RESTRICAO_COFF_EOLICA_2025_*.csv` — Wind curtailment orders
- `CMO_SEMIHORARIO_2025.csv` — Marginal cost of operation (semi-hourly)
- `CURVA_CARGA_2025.csv` — Load curve
- `CVU_USINA_TERMICA_2025.csv` — Thermal variable costs
- `LINHA_TRANSMISSAO.csv` — Transmission line inventory

Raw data is publicly available from [ONS](https://dados.ons.org.br/).

## Dependencies

Julia packages (see `Project.toml`):
- **JuMP** + **HiGHS** — optimization modeling and solver
- **CSV** + **DataFrames** — data loading
- **Plots** — visualization
- **PrettyTables** — formatted console output

Python packages (for plotting scripts):
- matplotlib, pandas, numpy

## Usage

```julia
# From the V2-dc-opf-zonal-intertemporal/ directory:
using Pkg
Pkg.activate(".")
Pkg.instantiate()

# Run all scenarios
include("scripts/run_scenarios.jl")

# Run battery analysis
include("scripts/run_battery.jl")

# Run welfare decomposition
include("scripts/run_welfare.jl")
```

## Key Findings

- **NE-SE transmission congestion** is the dominant structural constraint, causing ~10 TWh/yr of renewable curtailment
- **Carbon tax** (R$50/tCO2) reduces emissions by displacing coal/gas but increases system costs
- **Transmission expansion** on the NE-SE corridor is the most cost-effective intervention for reducing curtailment
- **Battery storage** provides arbitrage value but cannot substitute for transmission at scale
- Policy instruments show **complementarity**: carbon tax + transmission expansion outperforms either alone

## License

This project is provided for academic and research purposes.
