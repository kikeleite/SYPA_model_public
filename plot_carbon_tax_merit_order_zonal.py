"""Carbon tax merit order — separate NE and SE figures, wet/day period, technology shading.

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

SEASON, PERIOD = 'wet', 'day'

# ── Okabe-Ito line colors ────────────────────────────────────────────────────
OI_BLACK     = '#000000'
OI_ORANGE    = '#E69F00'
OI_SKY_BLUE  = '#56B4E9'
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

DISPLACED_COLOR = '#009E73'
DISPLACED_ALPHA = 0.20
DISPLACED_HATCH = '||'

# ── Line series definitions ──────────────────────────────────────────────────
taxes = [
    (0.0,   'Baseline',                OI_BLACK,    '-'),
    (50.0,  'Carbon tax R\\$50/tCO2',  OI_ORANGE,   '--'),
    (100.0, 'Carbon tax R\\$100/tCO2', OI_SKY_BLUE, '-.'),
]

LINE_WIDTH = 2.0   # minimum 1.5pt for print; using 2.0 for clarity
VLINE_WIDTH = 1.5


def build_zonal_supply_curve(gens, profiles, season, period, node, carbon_tax=0.0):
    """Build merit-order supply curve for a single node. Returns (x, y, segments)."""
    entries = []

    for _, row in gens.iterrows():
        if row['gen_id'].startswith('Backstop'):
            continue
        if row['node'] != node:
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

        if row['type'] == 'thermal' and carbon_tax > 0:
            ef = row['emission_factor'] if not pd.isna(row['emission_factor']) else 0
            effective_cost += carbon_tax * ef

        # Classify technology
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

    # Build segments: (start_gw, end_gw, cost, tech)
    segments = []
    cum_gw = 0.0
    for cost, _, cap_gw, tech in entries:
        segments.append((cum_gw, cum_gw + cap_gw, cost, tech))
        cum_gw += cap_gw

    # Build step arrays for the line
    x, y = [], []
    for start, end, cost, _ in segments:
        x.extend([start, end])
        y.extend([cost, cost])

    return np.array(x), np.array(y), segments


def zonal_demand_gw(node):
    dem = demand[(demand['season'] == SEASON) &
                 (demand['period'] == PERIOD) &
                 (demand['node'] == node)]
    return dem['load_mw'].sum() / 1e3


def shade_technologies(ax, segments):
    """Shade background by technology type with Okabe-Ito colors + hatching."""
    for start, end, cost, tech in segments:
        color, alpha, hatch = TECH_SHADING.get(tech, ('#F0F0F0', 0.15, ''))
        ax.axvspan(start, end, ymin=0, ymax=1,
                   alpha=alpha, facecolor=color, hatch=hatch,
                   linewidth=0, zorder=0, edgecolor='grey')


# NE-SE flows from actual results (wet/day period)
flow_baseline = 6.171
flow_c100 = 8.0

nodes_config = [
    ('NE1', 'Northeast (NE) — Exporter', 'carbon_tax_merit_order_NE.png'),
    ('SE1', 'Southeast (SE) — Importer', 'carbon_tax_merit_order_SE.png'),
]

for node, title_label, filename in nodes_config:
    fig, ax = plt.subplots(figsize=(7, 4.5))
    ax.grid(False)
    ax.yaxis.grid(True, color=GRID_COLOR, linewidth=0.6)
    ax.set_axisbelow(True)

    # Shade technologies using baseline segments
    _, _, segments_base = build_zonal_supply_curve(
        gens, profiles, SEASON, PERIOD, node, carbon_tax=0.0)
    shade_technologies(ax, segments_base)

    # Plot supply curves
    for tax, label, color, ls in taxes:
        x, y, _ = build_zonal_supply_curve(gens, profiles, SEASON, PERIOD,
                                           node, carbon_tax=tax)
        ax.plot(x, y, color=color, linewidth=LINE_WIDTH, linestyle=ls, label=label)

    # Local demand line
    load_gw = zonal_demand_gw(node)
    ax.axvline(load_gw, color=OI_VERMILLION, linestyle='--', linewidth=VLINE_WIDTH,
               label=f'Local demand ({load_gw:.1f} GW)')

    # SE: show net demand shift from imports
    if node == 'SE1':
        net_base = load_gw - flow_baseline
        net_c100 = load_gw - flow_c100
        ax.axvline(net_base, color=OI_BLACK, linestyle=':', linewidth=VLINE_WIDTH,
                   alpha=0.7, label=f'Net demand, baseline ({net_base:.1f} GW)')
        ax.axvline(net_c100, color=OI_SKY_BLUE, linestyle=':', linewidth=VLINE_WIDTH,
                   alpha=0.7, label=f'Net demand, tax 100 ({net_c100:.1f} GW)')
        ax.axvspan(net_c100, net_base,
                   alpha=DISPLACED_ALPHA, facecolor=DISPLACED_COLOR,
                   hatch=DISPLACED_HATCH, edgecolor='grey',
                   label='Displaced by NE imports')

    ax.set_title(f'Carbon Tax Effect on the Merit Order — {title_label}\nWet Day',
                 fontsize=13, fontweight='bold', color=NEUTRAL_DARK, pad=12)
    ax.set_xlabel('Cumulative Capacity (GW)', fontsize=11,
                  color=NEUTRAL_DARK, labelpad=8)
    ax.set_ylabel('Marginal Cost (R$/MWh)', fontsize=11,
                  color=NEUTRAL_DARK, labelpad=8)
    ax.tick_params(colors=NEUTRAL_MID, labelsize=10)

    ax.set_ylim(-15, 450)
    ax.set_xlim(0, 50)

    for spine in ('top', 'right'):
        ax.spines[spine].set_visible(False)
    for spine in ('left', 'bottom'):
        ax.spines[spine].set_color(NEUTRAL_MID)
        ax.spines[spine].set_linewidth(0.8)

    # ── Build legend ─────────────────────────────────────────────────────────
    legend_elements = []

    # Line series
    for tax, label, color, ls in taxes:
        legend_elements.append(Line2D([0], [0], color=color, linewidth=LINE_WIDTH,
                                      linestyle=ls, label=label))
    legend_elements.append(Line2D([0], [0], color=OI_VERMILLION, linewidth=VLINE_WIDTH,
                                  linestyle='--', label='Local demand'))

    if node == 'SE1':
        legend_elements.append(Line2D([0], [0], color=OI_BLACK, linewidth=VLINE_WIDTH,
                                      linestyle=':', alpha=0.7,
                                      label='Net demand (baseline)'))
        legend_elements.append(Line2D([0], [0], color=OI_SKY_BLUE, linewidth=VLINE_WIDTH,
                                      linestyle=':', alpha=0.7,
                                      label='Net demand (tax 100)'))

    # Technology shading patches (with hatching to match the plot)
    for color, alpha, hatch, label in TECH_LEGEND_ITEMS:
        legend_elements.append(Patch(facecolor=color, alpha=alpha,
                                     hatch=hatch, edgecolor='grey',
                                     label=label))

    if node == 'SE1':
        legend_elements.append(Patch(facecolor=DISPLACED_COLOR,
                                     alpha=DISPLACED_ALPHA,
                                     hatch=DISPLACED_HATCH, edgecolor='grey',
                                     label='Displaced by NE imports'))

    ncol = 3 if node == 'SE1' else 2
    ax.legend(handles=legend_elements, fontsize=8, frameon=False,
              loc='upper center', bbox_to_anchor=(0.5, -0.18), ncol=ncol)

    fig.subplots_adjust(bottom=0.35)
    out = Path(f'V2-dc-opf-zonal-intertemporal/results/figures/{filename}')
    fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
    plt.close(fig)
    print(f'Saved -> {out}')
