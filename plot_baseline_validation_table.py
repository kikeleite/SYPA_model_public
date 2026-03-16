"""Render baseline validation comparison table as a publication-quality figure."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *

# ── Data ──────────────────────────────────────────────────────────────────────
rows = [
    ['NE clearing price',           'R$54/MWh',          'R$151/MWh (CMO mean)'],
    ['SE clearing price',           'R$116/MWh',         'R$216/MWh (CMO mean)'],
    ['NE–SE price spread',          'R$62/MWh',          'R$65/MWh'],
    ['Annual renewable curtailment','~9.7 TWh',          '~9.5 TWh (TX constraints only, of 43.6 total)'],

    ['NE–SE corridor capacity',     '8,000 MW',          '~10,250 MW (NE→SE, ONS)'],
    ['Thermal cost range',          'R$150–400/MWh',     'R$101–518/MWh (gas/coal CVU)'],
    ['Hydro cost range (wet/dry)',  'R$40–95/MWh',       'CMO median: R$11 / R$270 (NE)'],
    ['SE–S price relationship',     'Non-binding (equal)','Coupled 69% of half-hours'],
]

col_labels = ['Metric', 'Model Baseline', 'Brazil 2025 (ONS)']

# ── Figure ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(10, 5))
ax.axis('off')

table = ax.table(
    cellText=rows,
    colLabels=col_labels,
    loc='center',
    cellLoc='left',
)

# Style the table
table.auto_set_font_size(False)
table.set_fontsize(10)
table.scale(1.0, 1.8)

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
        # Bold the metric column
        if j == 0:
            cell.set_text_props(color=NEUTRAL_DARK, fontweight='bold', fontsize=10)

# Column widths
col_widths = [0.30, 0.25, 0.45]
for j, w in enumerate(col_widths):
    for i in range(len(rows) + 1):
        table[i, j].set_width(w)

ax.set_title(
    'Model Baseline vs. Brazil 2025 Real System Data',
    fontsize=13, fontweight='bold', color=NEUTRAL_DARK, pad=20,
)

out = Path('V2-dc-opf-zonal-intertemporal/results/figures/baseline_validation_table.png')
out.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved → {out}')
