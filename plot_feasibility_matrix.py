"""Render policy feasibility matrix with traffic-light color coding."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *

# ── Traffic-light colors (from the cycle diagram) ────────────────────────────
GREEN_BG  = '#27AE60'
YELLOW_BG = '#F5A623'
RED_BG    = '#C0392B'

# ── Data ──────────────────────────────────────────────────────────────────────
#  (recommendation, [(rating, text), ...] for each of the 3 dimensions)
rows = [
    ('Battery revenue\nstacking',
     ('green',  'High\nModel-grounded'),
     ('yellow', 'Medium\nBuilds on ONS/CCEE\ninfrastructure'),
     ('yellow', 'Medium\nNew revenue streams vs.\nestablished interests')),
    ('Dual settlement\n(DA+RT)',
     ('green',  'High\nHogan framework'),
     ('red',    'Low\nRequires DESSEM extension,\nCCEE restructuring'),
     ('red',    'Low\nDisrupts existing\ninstitutional roles')),
    ('PLD cap/floor\nrelaxation',
     ('green',  'High\nSuppression\nwell-documented'),
     ('yellow', 'Medium\nANEEL annual process'),
     ('red',    'Low\nConsumer exposure risk')),
    ('Carbon tax',
     ('green',  'High\nOnly welfare-improving\ninstrument'),
     ('yellow', 'Medium\nEnters CVU,\nno new institution'),
     ('red',    'Low\nVisible tariff increase')),
    ('LMP\n(long-term)',
     ('green',  'High\nFoundational'),
     ('red',    'Very low\nGenerational reform'),
     ('red',    'Very low\nIndustry resistance')),
    ('Phase out\nsubsidies',
     ('green',  'High\nModel + Hogan'),
     ('yellow', 'Medium\nGrandfathering path\nexists'),
     ('red',    'Low\nSolar industry\nopposition')),
]

col_labels = ['Recommendation', 'Technical\nCorrectness',
              'Administrative\nFeasibility', 'Political\nSupportability']

COLOR_MAP = {
    'green':  GREEN_BG,
    'yellow': YELLOW_BG,
    'red':    RED_BG,
}

# Build cell text grid (strip color tags)
cell_text = []
cell_colors = []  # parallel grid of (bg_color, text_color)
for rec, tc, af, ps in rows:
    cell_text.append([rec, tc[1], af[1], ps[1]])
    row_colors = [('#F5F5F5', NEUTRAL_DARK)]  # recommendation column: neutral
    for rating, _ in [tc, af, ps]:
        bg = COLOR_MAP[rating]
        row_colors.append((bg, 'white'))
    cell_colors.append(row_colors)

# ── Figure ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(18, 14))
ax.axis('off')

table = ax.table(
    cellText=cell_text,
    colLabels=col_labels,
    loc='center',
    cellLoc='center',
)

table.auto_set_font_size(False)
table.set_fontsize(15)
table.scale(1.0, 6.0)

# Header row styling
for j in range(len(col_labels)):
    cell = table[0, j]
    cell.set_facecolor(NAVY)
    cell.set_text_props(color='white', fontweight='bold', fontsize=16,
                        ha='center', va='center')
    cell.set_edgecolor('white')
    cell.set_linewidth(1.5)

# Data row styling
for i in range(len(rows)):
    for j in range(len(col_labels)):
        cell = table[i + 1, j]
        bg, fg = cell_colors[i][j]
        cell.set_facecolor(bg)
        cell.set_edgecolor('white')
        cell.set_linewidth(1.5)

        if j == 0:
            # Recommendation column: bold, left-aligned
            cell.set_text_props(color=fg, fontweight='bold', fontsize=15,
                                ha='center', va='center')
        else:
            cell.set_text_props(color=fg, fontsize=15,
                                ha='center', va='center')

# Column widths
col_widths = [0.18, 0.27, 0.27, 0.27]
for j, w in enumerate(col_widths):
    for i in range(len(rows) + 1):
        table[i, j].set_width(w)

ax.set_title(
    'Policy Feasibility Matrix',
    fontsize=18, fontweight='bold', color=NEUTRAL_DARK, pad=24,
)

out = Path('V2-dc-opf-zonal-intertemporal/results/figures/feasibility_matrix.png')
out.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved -> {out}')
