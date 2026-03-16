"""Subsidy merit order curve — Okabe-Ito palette, technology shading + hatching, legend below.

Uses Okabe-Ito palette for colorblind safety (deuteranopia, protanopia, tritanopia)
plus diagonal hatching for grayscale print legibility.
"""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *
from matplotlib.patches import Patch
from matplotlib.lines import Line2D
import numpy as np

DATA = 'V2-dc-opf-zonal-intertemporal/data/output'

gens = pd.read_csv(f'{DATA}/generators.csv')
profiles = pd.read_csv(f'{DATA}/renewable_profiles.csv')
demand = pd.read_csv(f'{DATA}/demand.csv')

SEASON, PERIOD = 'dry', 'peak'

# ── Okabe-Ito line colors ────────────────────────────────────────────────────
OI_BLACK     = '#000000'
OI_ORANGE    = '#E69F00'
OI_VERMILLION = '#D55E00'

# ── Okabe-Ito background shading (color, alpha, hatch) ──────────────────────
TECH_SHADING = {
    'wind':             ('#56B4E9', 0.15, '//'),   # sky blue
    'solar':            ('#56B4E9', 0.15, '//'),   # sky blue
    'hydro':            ('#009E73', 0.12, '\\\\'), # bluish green
    'thermal_must_run': ('#D55E00', 0.12, '..'),   # vermillion
    'thermal_dispatch': ('#F0E442', 0.20, 'xx'),   # yellow
}

TECH_LEGEND_ITEMS = [
    ('#56B4E9', 0.15, '//',   'Renewable (wind/solar)'),
    ('#009E73', 0.12, '\\\\', 'Hydro'),
    ('#D55E00', 0.12, '..',   'Must-run thermal'),
    ('#F0E442', 0.20, 'xx',   'Peak thermal'),
]

LINE_WIDTH = 2.0
VLINE_WIDTH = 1.5


def build_supply_curve(gens, profiles, season, period, subsidy=0.0):
    """Build system-wide merit-order supply curve. Returns (x, y, segments)."""
    entries = []

    for _, row in gens.iterrows():
        if row['gen_id'].startswith('Backstop'):
            continue

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

        base_cost = row[f'cost_{season}']
        effective_cost = base_cost
        if row['type'] in ('wind', 'solar'):
            effective_cost -= subsidy

        if row['type'] in ('wind', 'solar'):
            tech = row['type']
        elif row['type'] == 'hydro':
            tech = 'hydro'
        elif row['type'] == 'thermal':
            must_run = row['must_run_mw'] if not pd.isna(row.get('must_run_mw', 0)) else 0
            tech = 'thermal_must_run' if must_run > 0 else 'thermal_dispatch'
        else:
            tech = 'thermal_dispatch'

        type_priority = {'wind': 1, 'solar': 2, 'hydro': 3,
                         'thermal_must_run': 4, 'thermal_dispatch': 5}
        entries.append((effective_cost, type_priority.get(tech, 5),
                        avail_mw / 1e3, tech))

    entries.sort(key=lambda e: (e[0], e[1]))

    segments = []
    cum_gw = 0.0
    for cost, _, cap_gw, tech in entries:
        segments.append((cum_gw, cum_gw + cap_gw, cost, tech))
        cum_gw += cap_gw

    x, y = [], []
    for start, end, cost, _ in segments:
        x.extend([start, end])
        y.extend([cost, cost])

    return np.array(x), np.array(y), segments


# ── Build curves ──────────────────────────────────────────────────────────────
x_base, y_base, seg_base = build_supply_curve(gens, profiles, SEASON, PERIOD,
                                               subsidy=0.0)
x_sub, y_sub, _ = build_supply_curve(gens, profiles, SEASON, PERIOD,
                                      subsidy=10.0)

dem = demand[(demand['season'] == SEASON) & (demand['period'] == PERIOD)]
load_gw = dem['load_mw'].sum() / 1e3

# ── Figure ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(7, 5.5))
ax.grid(False)
ax.yaxis.grid(True, color=GRID_COLOR, linewidth=0.6)
ax.set_axisbelow(True)

# Shade technologies with Okabe-Ito colors + hatching
for start, end, cost, tech in seg_base:
    color, alpha, hatch = TECH_SHADING.get(tech, ('#F0F0F0', 0.15, ''))
    ax.axvspan(start, end, ymin=0, ymax=1,
               alpha=alpha, facecolor=color, hatch=hatch,
               linewidth=0, zorder=0, edgecolor='grey')

# Supply curves
ax.plot(x_base, y_base, color=OI_BLACK, linewidth=LINE_WIDTH, linestyle='-',
        label='Baseline (renewables at R\\$1/MWh)')
ax.plot(x_sub, y_sub, color=OI_ORANGE, linewidth=LINE_WIDTH, linestyle='--',
        label='Subsidy R\\$10/MWh (renewables at -R\\$9/MWh)')

# Demand line
ax.axvline(load_gw, color=OI_VERMILLION, linestyle='--', linewidth=VLINE_WIDTH,
           label=f'Demand ({load_gw:.1f} GW)')

ax.set_xlabel('Cumulative Capacity (GW)', fontsize=11, color=NEUTRAL_DARK, labelpad=8)
ax.set_ylabel('Marginal Cost (R$/MWh)', fontsize=11, color=NEUTRAL_DARK, labelpad=8)
ax.set_title('Subsidy Effect on the Merit Order — Dry Peak',
             fontsize=13, fontweight='bold', color=NEUTRAL_DARK, pad=12)

ax.set_xlim(0, load_gw * 1.25)
ax.set_ylim(-15, 450)
ax.tick_params(colors=NEUTRAL_MID, labelsize=10)

for spine in ('top', 'right'):
    ax.spines[spine].set_visible(False)
for spine in ('left', 'bottom'):
    ax.spines[spine].set_color(NEUTRAL_MID)
    ax.spines[spine].set_linewidth(0.8)

# ── Combined legend below the plot ────────────────────────────────────────────
legend_elements = [
    Line2D([0], [0], color=OI_BLACK, linewidth=LINE_WIDTH, linestyle='-',
           label='Baseline (renewables at R\\$1/MWh)'),
    Line2D([0], [0], color=OI_ORANGE, linewidth=LINE_WIDTH, linestyle='--',
           label='Subsidy R\\$10/MWh (renewables at -R\\$9/MWh)'),
    Line2D([0], [0], color=OI_VERMILLION, linewidth=VLINE_WIDTH, linestyle='--',
           label=f'Demand ({load_gw:.1f} GW)'),
]
for color, alpha, hatch, label in TECH_LEGEND_ITEMS:
    legend_elements.append(Patch(facecolor=color, alpha=alpha,
                                 hatch=hatch, edgecolor='grey',
                                 label=label))

fig.legend(handles=legend_elements, loc='lower center', ncol=4,
           fontsize=9, frameon=False, bbox_to_anchor=(0.5, -0.02))

fig.tight_layout(rect=[0, 0.08, 1, 1])
out = Path('V2-dc-opf-zonal-intertemporal/results/figures/subsidy_merit_order_v2.png')
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved -> {out}')
