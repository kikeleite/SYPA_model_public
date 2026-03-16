"""Render scenario design matrix table as a publication-quality figure."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *

# ── Data ──────────────────────────────────────────────────────────────────────
rows = [
    ['Pricing',  'Carbon Tax\nR$50, R$100/tCO2',
     'Surcharge on thermal CVU\nproportional to emission factor',
     'Does the carbon price cross\nmerit-order thresholds? At what level?'],
    ['Pricing',  'Subsidy\nR$1, R$10/MWh',
     'Cost reduction applied\nto renewable CVU',
     'Same stated objective as carbon\ntax -- does mechanism choice matter?'],
    ['Spatial',  'TX +2, +5, +10 GW',
     'NE-SE corridor capacity',
     'What is the marginal value of congestion\nrelief? Does the bottleneck saturate?'],
    ['Temporal', 'Battery\n200 MW / 800 MWh',
     'SOC-constrained arbitrage\nat each node',
     'Can temporal flexibility substitute\nfor spatial capacity?'],
    ['Combined', 'Carbon + TX;\nCarbon + battery',
     'Two-dimension pairing',
     'Do instruments from different dimensions\ncomplement each other? From the same?'],
]

col_labels = ['Dimension', 'Scenario', 'Key Parameter', 'Design Question']

# ── Figure ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(13, 6.5))
ax.axis('off')

table = ax.table(
    cellText=rows,
    colLabels=col_labels,
    loc='center',
    cellLoc='left',
)

table.auto_set_font_size(False)
table.set_fontsize(10)
table.scale(1.0, 2.4)

# Header row styling
for j in range(len(col_labels)):
    cell = table[0, j]
    cell.set_facecolor(NAVY)
    cell.set_text_props(color='white', fontweight='bold', fontsize=11)
    cell.set_edgecolor('white')
    cell.set_linewidth(1.5)

# Data row styling
for i in range(len(rows)):
    row_color = '#F5F5F5' if i % 2 == 0 else BG_COLOR
    for j in range(len(col_labels)):
        cell = table[i + 1, j]
        cell.set_facecolor(row_color)
        cell.set_edgecolor(NEUTRAL_LIGHT)
        cell.set_linewidth(0.5)
        cell.set_text_props(color=NEUTRAL_DARK, fontsize=10)
        # Bold the dimension column
        if j == 0:
            cell.set_text_props(color=NEUTRAL_DARK, fontweight='bold', fontsize=10)

# Column widths
col_widths = [0.12, 0.20, 0.28, 0.40]
for j, w in enumerate(col_widths):
    for i in range(len(rows) + 1):
        table[i, j].set_width(w)

ax.set_title(
    'Scenario Design Matrix',
    fontsize=13, fontweight='bold', color=NEUTRAL_DARK, pad=20,
)

out = Path('V2-dc-opf-zonal-intertemporal/results/figures/scenario_design_table.png')
out.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved -> {out}')
