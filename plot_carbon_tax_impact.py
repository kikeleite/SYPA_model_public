"""
Carbon Tax Impact Comparison: V2 (Zonal) vs V3 (Nodal)

Generates two figures comparing the effect of carbon pricing across both models:
  1. Emissions vs Carbon Tax level
  2. System Cost vs Carbon Tax level

The key finding: carbon tax reduces emissions in V2 (where dispatchable thermal
is on the margin) but has zero effect in V3 (where only must-run thermal operates
and dispatchable thermal is already priced out of the merit order).
"""

import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np

# =============================================================================
# Data extracted from results/summary.csv (both models)
# =============================================================================

# V2 — Zonal (4 nodes): baseline, carbon_50, carbon_100
v2_tax = [0, 50, 100]
v2_emissions_tco2 = [3.6056978723076925e7, 3.3547603723076925e7, 2.2369478723076925e7]
v2_cost_full = [2.4261696324007694e10, 2.602038026016154e10, 2.7523472946315384e10]

# V3 — Nodal (22 nodes): baseline, carbon_10, carbon_25, carbon_50, carbon_75, carbon_100
v3_tax = [0, 10, 25, 50, 75, 100]
v3_emissions_tco2 = [
    3.2850446241972614e7,
    3.2850446241972614e7,
    3.2850446241972614e7,
    3.285020595783351e7,
    3.285020595783351e7,
    3.285020595783351e7,
]
v3_cost_full = [
    1.6913214257661457e10,
    1.7241718720081184e10,
    1.7734475413710773e10,
    1.8555730803518024e10,
    1.937698595246386e10,
    2.0198241101409702e10,
]

# Convert to convenient units
v2_emissions_mt = [e / 1e6 for e in v2_emissions_tco2]   # MtCO₂
v3_emissions_mt = [e / 1e6 for e in v3_emissions_tco2]
v2_cost_br = [c / 1e9 for c in v2_cost_full]              # Bilhões R$
v3_cost_br = [c / 1e9 for c in v3_cost_full]

# Percentage changes relative to baseline
v2_emissions_pct = [(e - v2_emissions_mt[0]) / v2_emissions_mt[0] * 100 for e in v2_emissions_mt]
v3_emissions_pct = [(e - v3_emissions_mt[0]) / v3_emissions_mt[0] * 100 for e in v3_emissions_mt]
v2_cost_pct = [(c - v2_cost_br[0]) / v2_cost_br[0] * 100 for c in v2_cost_br]
v3_cost_pct = [(c - v3_cost_br[0]) / v3_cost_br[0] * 100 for c in v3_cost_br]

# =============================================================================
# Styling
# =============================================================================

COLOR_V2 = "#2563EB"   # Blue
COLOR_V3 = "#DC2626"   # Red
BG_COLOR = "#FAFAFA"

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.size": 12,
    "axes.titlesize": 14,
    "axes.titleweight": "bold",
    "axes.labelsize": 12,
    "figure.facecolor": "white",
    "axes.facecolor": BG_COLOR,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linestyle": "--",
})

# =============================================================================
# Figure 1 — Emissions vs Carbon Tax
# =============================================================================

fig1, ax1 = plt.subplots(figsize=(9, 5.5))

ax1.plot(v2_tax, v2_emissions_mt, "o-", color=COLOR_V2, linewidth=2.5,
         markersize=8, label="V2 — Zonal (4 nós)", zorder=5)
ax1.plot(v3_tax, v3_emissions_mt, "s-", color=COLOR_V3, linewidth=2.5,
         markersize=8, label="V3 — Nodal (22 nós)", zorder=5)

# Annotate the key difference
ax1.annotate(
    f"−{abs(v2_emissions_pct[-1]):.0f}%",
    xy=(100, v2_emissions_mt[-1]),
    xytext=(75, v2_emissions_mt[-1] - 3.5),
    fontsize=13, fontweight="bold", color=COLOR_V2,
    arrowprops=dict(arrowstyle="->", color=COLOR_V2, lw=1.5),
    ha="center",
)
ax1.annotate(
    "≈ 0% de redução",
    xy=(100, v3_emissions_mt[-1]),
    xytext=(68, v3_emissions_mt[-1] + 3),
    fontsize=13, fontweight="bold", color=COLOR_V3,
    arrowprops=dict(arrowstyle="->", color=COLOR_V3, lw=1.5),
    ha="center",
)

ax1.set_xlabel("Taxa de Carbono (R$/tCO₂)")
ax1.set_ylabel("Emissões Anuais (MtCO₂)")
ax1.set_title("Impacto da Taxa de Carbono nas Emissões")
ax1.set_xlim(-5, 110)
ax1.set_ylim(15, 42)
ax1.legend(loc="upper right", framealpha=0.9, fontsize=11)
ax1.set_xticks([0, 10, 25, 50, 75, 100])

fig1.tight_layout()
fig1.savefig("/Users/henriqueleite/Desktop/stylized-model/results_carbon_tax_emissions.png", dpi=200)
fig1.savefig("/Users/henriqueleite/Desktop/stylized-model/results_carbon_tax_emissions.pdf")
print("Saved: results_carbon_tax_emissions.png / .pdf")

# =============================================================================
# Figure 2 — System Cost vs Carbon Tax
# =============================================================================

fig2, ax2 = plt.subplots(figsize=(9, 5.5))

ax2.plot(v2_tax, v2_cost_br, "o-", color=COLOR_V2, linewidth=2.5,
         markersize=8, label="V2 — Zonal (4 nós)", zorder=5)
ax2.plot(v3_tax, v3_cost_br, "s-", color=COLOR_V3, linewidth=2.5,
         markersize=8, label="V3 — Nodal (22 nós)", zorder=5)

# Annotate cost increase percentages
ax2.annotate(
    f"+{v2_cost_pct[-1]:.1f}% (com redução de emissões)",
    xy=(100, v2_cost_br[-1]),
    xytext=(45, v2_cost_br[-1] - 2.0),
    fontsize=11, fontweight="bold", color=COLOR_V2,
    arrowprops=dict(arrowstyle="->", color=COLOR_V2, lw=1.5),
    ha="center",
)
ax2.annotate(
    f"+{v3_cost_pct[-1]:.1f}% (sem redução de emissões)",
    xy=(100, v3_cost_br[-1]),
    xytext=(50, v3_cost_br[-1] + 1.5),
    fontsize=11, fontweight="bold", color=COLOR_V3,
    arrowprops=dict(arrowstyle="->", color=COLOR_V3, lw=1.5),
    ha="center",
)

ax2.set_xlabel("Taxa de Carbono (R$/tCO₂)")
ax2.set_ylabel("Custo Total do Sistema (Bilhões R$/ano)")
ax2.set_title("Impacto da Taxa de Carbono no Custo do Sistema")
ax2.set_xlim(-5, 110)
ax2.legend(loc="upper left", framealpha=0.9, fontsize=11)
ax2.set_xticks([0, 10, 25, 50, 75, 100])

fig2.tight_layout()
fig2.savefig("/Users/henriqueleite/Desktop/stylized-model/results_carbon_tax_cost.png", dpi=200)
fig2.savefig("/Users/henriqueleite/Desktop/stylized-model/results_carbon_tax_cost.pdf")
print("Saved: results_carbon_tax_cost.png / .pdf")

plt.show()
