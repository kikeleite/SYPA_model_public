"""Battery location paradox — Private profitability vs curtailment impact, SYPA style."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *
import numpy as np

RESULTS = 'V2-dc-opf-zonal-intertemporal/results'
DAYS_PER_SEASON = 182.5
REP_DAYS = 10

# ── (a) Private Profitability ────────────────────────────────────────────────
df = pd.read_csv(f'{RESULTS}/battery_all.csv')

profits = {}
for node in ['SE1', 'NE1']:
    rev_col = f'revenue_Battery_{node}'
    cost_col = f'charge_cost_Battery_{node}'
    total = 0.0
    for season in ['wet', 'dry']:
        s = df[df['season'] == season]
        total += (s[rev_col].sum() - s[cost_col].sum()) * (DAYS_PER_SEASON / REP_DAYS)
    profits[node] = total / 1e6  # R$ millions

# ── (b) Curtailment Impact ───────────────────────────────────────────────────
tf = pd.read_csv(f'{RESULTS}/tradeoff_tx_battery.csv')

baseline_curt = tf[(tf['tx_expansion_mw'] == 0) &
                    (tf['battery_power_mw'] == 0)].iloc[0]['annual_curtailment_gwh']

curtailment_reduction_per_gw = {}
for node in ['SE1', 'NE1']:
    row = tf[(tf['battery_node'] == node) &
             (tf['tx_expansion_mw'] == 0) &
             (tf['battery_power_mw'] == 500)]
    curt = row.iloc[0]['annual_curtailment_gwh']
    curtailment_reduction_per_gw[node] = (baseline_curt - curt) / 0.5  # GWh per GW

# ── Figure ────────────────────────────────────────────────────────────────────
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 4.5))

nodes = ['SE1', 'NE1']
labels = ['SE\n(Sudeste)', 'NE\n(Nordeste)']
colors = [BLUE, AMBER]

# Panel (a): Private Profitability
vals_a = [profits[n] for n in nodes]
bars_a = ax1.bar(labels, vals_a, color=colors, width=0.5, edgecolor='white', linewidth=0.8)

for bar, val in zip(bars_a, vals_a):
    ax1.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 1.0,
             f'R${val:.1f}M', ha='center', va='bottom',
             fontsize=11, fontweight='bold', color=NEUTRAL_DARK)

ax1.set_ylabel('Annual Arbitrage Profit (R$ million)', fontsize=11,
               color=NEUTRAL_DARK, labelpad=8)
ax1.set_title('(a) Private Profitability', fontsize=13,
              fontweight='bold', color=NEUTRAL_DARK, pad=12)
ax1.set_ylim(0, max(vals_a) * 1.25)
apply_sypa_style(ax1)

# Panel (b): Curtailment Impact
vals_b = [curtailment_reduction_per_gw[n] for n in nodes]
bars_b = ax2.bar(labels, vals_b, color=colors, width=0.5, edgecolor='white', linewidth=0.8)

for bar, val in zip(bars_b, vals_b):
    label_text = 'Zero\nimpact' if val == 0 else f'{val:.0f} GWh/GW'
    y_pos = bar.get_height() + max(vals_b) * 0.03 if val > 0 else max(vals_b) * 0.03
    ax2.text(bar.get_x() + bar.get_width() / 2, y_pos,
             label_text, ha='center', va='bottom',
             fontsize=11, fontweight='bold', color=NEUTRAL_DARK)

ax2.set_ylabel('Curtailment Reduction (GWh per GW installed)', fontsize=11,
               color=NEUTRAL_DARK, labelpad=8)
ax2.set_title('(b) Curtailment Impact', fontsize=13,
              fontweight='bold', color=NEUTRAL_DARK, pad=12)
ax2.set_ylim(0, max(vals_b) * 1.25)
apply_sypa_style(ax2)

fig.suptitle('The Battery Location Paradox',
             fontsize=14, fontweight='bold', color=NEUTRAL_DARK, y=1.02)

# Subtitle annotation
fig.text(0.5, -0.04,
         'The market directs battery investment to SE (highest profit) '
         'while the system\'s need is at NE (curtailment relief)',
         ha='center', fontsize=9, fontstyle='italic', color=NEUTRAL_MID)

fig.tight_layout()
out = Path('V2-dc-opf-zonal-intertemporal/results/figures/battery_location_paradox.png')
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved -> {out}')
