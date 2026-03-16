"""Render policy recommendations table as a publication-quality figure."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *

# ── Data ──────────────────────────────────────────────────────────────────────
rows = [
    ['Battery revenue stacking',    'Highest', 'Medium-term', 'Medium',    'Model (paradox) + external'],
    ['Dual settlement (DA+RT)',     'High',    'Medium-term', 'High',      'Hogan framework'],
    ['PLD cap/floor relaxation',    'High',    'Medium-term', 'Medium',    'External evidence'],
    ['Carbon tax',                  'High',    'Medium-term', 'Medium',    'Model (merit order)'],
    ['Locational marginal pricing', 'High',    'Long-term',   'Very high', 'Foundational enabler'],
    ['Phase out renewable subsidies','Medium', 'Gradual',     'Medium-high','Model (welfare)'],
]

col_labels = ['Recommendation', 'Priority', 'Timeframe', 'Complexity', 'Evidence basis']

# ── Figure ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(12, 5))
ax.axis('off')

table = ax.table(
    cellText=rows,
    colLabels=col_labels,
    loc='center',
    cellLoc='left',
)

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
        # Bold the recommendation column
        if j == 0:
            cell.set_text_props(color=NEUTRAL_DARK, fontweight='bold', fontsize=10)

# Column widths
col_widths = [0.28, 0.12, 0.15, 0.15, 0.30]
for j, w in enumerate(col_widths):
    for i in range(len(rows) + 1):
        table[i, j].set_width(w)

ax.set_title(
    'Policy Recommendations — Priority and Implementation',
    fontsize=13, fontweight='bold', color=NEUTRAL_DARK, pad=20,
)

out = Path('V2-dc-opf-zonal-intertemporal/results/figures/recommendations_table.png')
out.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved -> {out}')
