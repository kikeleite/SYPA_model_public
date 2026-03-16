"""Carbon tax merit order curve — SYPA style, English, no annotations."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *
import numpy as np

DATA = 'V2-dc-opf-zonal-intertemporal/data/output'

# ── Load data ─────────────────────────────────────────────────────────────────
gens = pd.read_csv(f'{DATA}/generators.csv')
profiles = pd.read_csv(f'{DATA}/renewable_profiles.csv')
demand = pd.read_csv(f'{DATA}/demand.csv')

SEASON, PERIOD = 'dry', 'peak'


def build_supply_curve(gens, profiles, season, period,
                       subsidy=0.0, carbon_tax=0.0):
    """Build merit-order supply curve. Returns step-function arrays (x, y)."""
    entries = []

    for _, row in gens.iterrows():
        if row['gen_id'].startswith('Backstop'):
            continue

        # Available capacity
        if row['type'] in ('wind', 'solar'):
            pf = profiles[
                (profiles['gen_id'] == row['gen_id']) &
                (profiles['season'] == season) &
                (profiles['period'] == period)
            ]
            if pf.empty:
                continue
            avail_mw = row['capacity_mw'] * pf.iloc[0]['capacity_factor']
        elif row['type'] == 'hydro':
            avail_mw = row[f'capacity_{season}_mw']
        else:
            avail_mw = row['capacity_mw']

        if avail_mw <= 0:
            continue

        # Effective cost
        base_cost = row[f'cost_{season}']
        effective_cost = base_cost

        if row['type'] in ('wind', 'solar'):
            effective_cost -= subsidy

        if row['type'] == 'thermal' and carbon_tax > 0:
            ef = row['emission_factor'] if not pd.isna(row['emission_factor']) else 0
            effective_cost += carbon_tax * ef

        type_priority = {'wind': 1, 'solar': 2, 'hydro': 3, 'thermal': 4}
        entries.append((effective_cost, type_priority.get(row['type'], 5),
                        avail_mw / 1e3, row['type']))

    entries.sort(key=lambda e: (e[0], e[1]))

    cum_gw = [0.0]
    costs = []
    running = 0.0
    for cost, _, cap_gw, _ in entries:
        costs.append(cost)
        running += cap_gw
        cum_gw.append(running)

    x, y = [], []
    for i in range(len(costs)):
        x.extend([cum_gw[i], cum_gw[i + 1]])
        y.extend([costs[i], costs[i]])

    return np.array(x), np.array(y)


# ── Build curves ──────────────────────────────────────────────────────────────
x_base, y_base = build_supply_curve(gens, profiles, SEASON, PERIOD)
x_c50, y_c50 = build_supply_curve(gens, profiles, SEASON, PERIOD, carbon_tax=50.0)
x_c100, y_c100 = build_supply_curve(gens, profiles, SEASON, PERIOD, carbon_tax=100.0)

# Total demand
dem = demand[(demand['season'] == SEASON) & (demand['period'] == PERIOD)]
load_gw = dem['load_mw'].sum() / 1e3

# ── Figure ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(7, 4.5))
ax.grid(False)

# Horizontal grid only
ax.yaxis.grid(True, color=GRID_COLOR, linewidth=0.6)
ax.set_axisbelow(True)

# Supply curves — three series: navy, amber, blue (per SYPA palette order)
ax.plot(x_base, y_base, color=NAVY, linewidth=1.8, linestyle='-',
        label='Baseline')
ax.plot(x_c50, y_c50, color=AMBER, linewidth=1.8, linestyle='--',
        label='Carbon tax R\\$50/tCO2')
ax.plot(x_c100, y_c100, color=BLUE, linewidth=1.8, linestyle='-.',
        label='Carbon tax R\\$100/tCO2')

# Demand line
ax.axvline(load_gw, color=NEUTRAL_MID, linestyle='--', linewidth=1.2,
           label=f'Demand ({load_gw:.1f} GW)')

# Axes
ax.set_xlabel('Cumulative Capacity (GW)', fontsize=11, color=NEUTRAL_DARK, labelpad=8)
ax.set_ylabel('Marginal Cost (R$/MWh)', fontsize=11, color=NEUTRAL_DARK, labelpad=8)
ax.set_title('Carbon Tax Effect on the Merit Order — Dry Peak',
             fontsize=13, fontweight='bold', color=NEUTRAL_DARK, pad=12)

ax.set_xlim(0, load_gw * 1.25)
ax.set_ylim(-15, 550)
ax.tick_params(colors=NEUTRAL_MID, labelsize=10)

# Spines
for spine in ('top', 'right'):
    ax.spines[spine].set_visible(False)
for spine in ('left', 'bottom'):
    ax.spines[spine].set_color(NEUTRAL_MID)
    ax.spines[spine].set_linewidth(0.8)

# Legend outside plot area
ax.legend(fontsize=10, frameon=False, loc='upper left',
          bbox_to_anchor=(0.0, 0.98))

fig.tight_layout()
out = Path('V2-dc-opf-zonal-intertemporal/results/figures/carbon_tax_merit_order_v2.png')
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved → {out}')
