"""Render carbon tax vs renewable subsidy comparison table as a publication-quality figure."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *

# ── Data ──────────────────────────────────────────────────────────────────────
rows = [
    ['Mechanism',          'Surcharge on thermal CVU\nthrough dispatch',   'Cost reduction for\ninframarginal renewables'],
    ['Emission reduction', 'Significant; nonlinear\nwith tax level',      'Negligible; invariant\nto subsidy level'],
    ['Curtailment impact', 'None (does not\nalter network)',               'None (does not\nalter network)'],
    ['Welfare effect',     'Positive\n(efficiency gain)',                  'Negative (pure transfer,\nno efficiency gain)'],
    ['Fiscal impact',      'Revenue generating',                          'Treasury cost'],
    ['Merit order effect', 'Reshuffles thermal\ndispatch',                'No change at margin'],
]

col_labels = ['Dimension', 'Carbon tax', 'Renewable subsidy']

# ── Figure ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(10, 5.5))
ax.axis('off')

table = ax.table(
    cellText=rows,
    colLabels=col_labels,
    loc='center',
    cellLoc='left',
)

table.auto_set_font_size(False)
table.set_fontsize(10)
table.scale(1.0, 2.2)

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
col_widths = [0.22, 0.39, 0.39]
for j, w in enumerate(col_widths):
    for i in range(len(rows) + 1):
        table[i, j].set_width(w)

ax.set_title(
    'Carbon Tax vs. Renewable Subsidy — Policy Comparison',
    fontsize=13, fontweight='bold', color=NEUTRAL_DARK, pad=20,
)

out = Path('V2-dc-opf-zonal-intertemporal/results/figures/policy_comparison_table.png')
out.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved -> {out}')
