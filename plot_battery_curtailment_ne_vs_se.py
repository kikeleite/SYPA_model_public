"""Recreate battery_curtailment_ne_vs_se heatmap in English with SYPA style."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *
import numpy as np

# ── Load data ─────────────────────────────────────────────────────────────────
df = pd.read_csv(
    'V2-dc-opf-zonal-intertemporal/results/tradeoff_tx_battery.csv'
)

df_ne = df[df['battery_node'] == 'NE1'].copy()
df_se = df[df['battery_node'] == 'SE1'].copy()


def pivot_curtailment(sub):
    return sub.pivot(
        index='battery_power_mw',
        columns='tx_expansion_mw',
        values='annual_curtailment_gwh',
    ).sort_index(ascending=True)


mat_ne = pivot_curtailment(df_ne)
mat_se = pivot_curtailment(df_se)

mat_ne_int = mat_ne.round(0).astype(int)
mat_se_int = mat_se.round(0).astype(int)

# ── Shared color scale ────────────────────────────────────────────────────────
vmin = 0
vmax = max(mat_ne.max().max(), mat_se.max().max())

# SYPA-palette colormap: green (zero) → amber (mid) → red (high curtailment)
sypa_heat_cmap = mcolors.LinearSegmentedColormap.from_list(
    'sypa_heat',
    [GREEN, '#F7F3EB', AMBER, RED],
)

# ── Figure ────────────────────────────────────────────────────────────────────
# Manual positioning: both heatmaps identical, colorbar on its own axes
fig = plt.figure(figsize=(14, 5.5))
plot_w = 0.32
plot_h = 0.72
bot = 0.13
ax1 = fig.add_axes([0.06, bot, plot_w, plot_h])
ax2 = fig.add_axes([0.46, bot, plot_w, plot_h])
cbar_ax = fig.add_axes([0.82, bot, 0.015, plot_h])  # dedicated colorbar axes

x_labels = [f'+{int(c)}' for c in mat_ne.columns]
y_labels = [f'{int(r)}' for r in mat_ne.index]

for ax, mat, mat_int, subtitle in [
    (ax1, mat_ne, mat_ne_int, 'Battery in Northeast (NE)'),
    (ax2, mat_se, mat_se_int, 'Battery in Southeast (SE)'),
]:
    # Disable grid — rcParams turns it on globally, but heatmaps must not have it
    ax.grid(False)

    sns.heatmap(
        mat,
        annot=False,
        cmap=sypa_heat_cmap,
        vmin=vmin,
        vmax=vmax,
        linewidths=0,
        cbar=False,
        xticklabels=x_labels,
        yticklabels=y_labels,
        ax=ax,
    )

    # Adaptive text: white on dark cells, navy on light cells
    threshold = vmax * 0.4
    for i in range(mat_int.shape[0]):
        for j in range(mat_int.shape[1]):
            val = mat.iloc[i, j]
            txt = f'{mat_int.iloc[i, j]:,}'
            color = '#FFFFFF' if val > threshold else NAVY
            ax.text(
                j + 0.5, i + 0.5, txt,
                ha='center', va='center',
                fontsize=9, fontweight='bold', color=color,
            )

    ax.set_title(subtitle, fontsize=13, fontweight='bold', color=NEUTRAL_DARK, pad=12)
    ax.set_xlabel('NE-SE TX Expansion (MW)', fontsize=11, color=NEUTRAL_DARK, labelpad=8)
    ax.set_ylabel('Battery Capacity (MW)', fontsize=11, color=NEUTRAL_DARK, labelpad=8)
    ax.tick_params(colors=NEUTRAL_MID, labelsize=10)
    ax.invert_yaxis()

    # Heatmaps need all four spines visible (they frame the grid)
    for spine in ax.spines.values():
        spine.set_visible(True)
        spine.set_color(NEUTRAL_MID)
        spine.set_linewidth(0.8)

# Shared colorbar on dedicated axes
norm = mpl.colors.Normalize(vmin=vmin, vmax=vmax)
sm = mpl.cm.ScalarMappable(cmap=sypa_heat_cmap, norm=norm)
sm.set_array([])
cbar = fig.colorbar(sm, cax=cbar_ax)
cbar.ax.tick_params(labelsize=10, colors=NEUTRAL_MID)
cbar.set_label('Curtailment (GWh/year)', fontsize=11, color=NEUTRAL_DARK, labelpad=8)
cbar.outline.set_edgecolor(NEUTRAL_MID)
cbar.outline.set_linewidth(0.8)

fig.suptitle(
    'Annual Curtailment (GWh/year): Battery Location',
    fontsize=13, fontweight='bold', color=NEUTRAL_DARK, y=1.02,
)

out = Path('V2-dc-opf-zonal-intertemporal/results/figures/battery_curtailment_ne_vs_se.png')
fig.savefig(out, dpi=300, bbox_inches='tight')
plt.close(fig)
print(f'Saved → {out}')
