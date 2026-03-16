"""Brazil electricity subsystem map — SYPA style."""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from chart_helpers import *
import geopandas as gpd
import numpy as np
from matplotlib.patches import FancyBboxPatch, Ellipse, Patch
from matplotlib.lines import Line2D

# ── Load states ──────────────────────────────────────────────────────────────
gdf = gpd.read_file('/tmp/brazil_states.geojson')

# ── Subsystem assignments (ONS definition) ───────────────────────────────────
NORTH = ['Acre', 'Amazonas', 'Amapá', 'Pará', 'Rondônia', 'Roraima', 'Tocantins', 'Maranhão']
NORTHEAST = ['Alagoas', 'Bahia', 'Ceará', 'Paraíba', 'Pernambuco',
             'Piauí', 'Rio Grande do Norte', 'Sergipe']
SOUTHEAST_MW = ['Espírito Santo', 'Goiás', 'Minas Gerais', 'Mato Grosso do Sul',
                'Mato Grosso', 'Rio de Janeiro', 'São Paulo', 'Distrito Federal']
SOUTH = ['Paraná', 'Rio Grande do Sul', 'Santa Catarina']

def get_subsystem(name):
    if name in NORTH:        return 'North'
    if name in NORTHEAST:    return 'Northeast'
    if name in SOUTHEAST_MW: return 'Southeast/Midwest'
    if name in SOUTH:        return 'South'
    return 'Other'

gdf['subsystem'] = gdf['name'].apply(get_subsystem)

# ── Subsystem colors (SYPA palette, muted for background) ───────────────────
SUBSYSTEM_COLORS = {
    'North':             '#A8D5BA',  # muted green
    'Northeast':         '#F5CBA7',  # muted orange
    'Southeast/Midwest': '#D5DBDB',  # muted grey
    'South':             '#AEB6BF',  # darker grey
}

# ── Urban centers (approximate lon, lat) ─────────────────────────────────────
CITIES = [
    ('São Paulo',    -46.63, -23.55),
    ('Rio de Janeiro', -43.17, -22.91),
    ('Belo Horizonte', -43.94, -19.92),
    ('Brasília',     -47.88, -15.79),
    ('Salvador',     -38.51, -12.97),
    ('Recife',       -34.87, -8.05),
    ('Fortaleza',    -38.52, -3.72),
    ('Curitiba',     -49.27, -25.43),
    ('Porto Alegre', -51.18, -30.03),
    ('Manaus',       -60.03, -3.12),
    ('Belém',        -48.50, -1.46),
]

# ── Figure ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(10, 10))
ax.set_aspect('equal')
ax.axis('off')

# Plot states by subsystem
for subsystem, color in SUBSYSTEM_COLORS.items():
    subset = gdf[gdf['subsystem'] == subsystem]
    subset.plot(ax=ax, color=color, edgecolor='white', linewidth=0.8)

# ── Overlay circles ──────────────────────────────────────────────────────────

# Amazon basin (large dashed green ellipse over North)
amazon = Ellipse(xy=(-57, -4), width=22, height=16, angle=-5,
                 fill=False, edgecolor='#27AE60', linewidth=2.2,
                 linestyle='--', zorder=3)
ax.add_patch(amazon)

# Wind-rich zone (purple dashed ellipse over NE coast)
wind = Ellipse(xy=(-37.5, -7), width=8, height=15, angle=-10,
               fill=False, edgecolor='#7B3FA0', linewidth=2.2,
               linestyle='--', zorder=3)
ax.add_patch(wind)

# River basins — São Francisco (NE/MG border) and Paraná (SE)
rio_sf = Ellipse(xy=(-42.5, -11.5), width=7, height=5, angle=25,
                 fill=False, edgecolor=BLUE, linewidth=2.0,
                 linestyle='--', zorder=3)
ax.add_patch(rio_sf)

rio_parana = Ellipse(xy=(-50, -23), width=8, height=6, angle=15,
                     fill=False, edgecolor=BLUE, linewidth=2.0,
                     linestyle='--', zorder=3)
ax.add_patch(rio_parana)

# ── Urban centers (red diamonds) ─────────────────────────────────────────────
for name, lon, lat in CITIES:
    ax.plot(lon, lat, marker='D', color='#C0392B', markersize=7,
            markeredgecolor='white', markeredgewidth=0.5, zorder=5)

# ── Legends ──────────────────────────────────────────────────────────────────

# Subsystem legend
subsystem_handles = [
    Patch(facecolor=SUBSYSTEM_COLORS['North'], edgecolor='white', label='North'),
    Patch(facecolor=SUBSYSTEM_COLORS['Northeast'], edgecolor='white', label='Northeast'),
    Patch(facecolor=SUBSYSTEM_COLORS['Southeast/Midwest'], edgecolor='white',
          label='Southeast/Midwest'),
    Patch(facecolor=SUBSYSTEM_COLORS['South'], edgecolor='white', label='South'),
]

# Overlay legend
overlay_handles = [
    Line2D([0], [0], color='#27AE60', linewidth=2.2, linestyle='--', label='Amazon'),
    Line2D([0], [0], color=BLUE, linewidth=2.0, linestyle='--', label='River basins'),
    Line2D([0], [0], color='#7B3FA0', linewidth=2.2, linestyle='--', label='Wind rich'),
    Line2D([0], [0], marker='D', color='w', markerfacecolor='#C0392B',
           markersize=7, markeredgecolor='white', label='Urban centers'),
]

leg1 = ax.legend(handles=subsystem_handles, title='SUBSYSTEMS',
                 title_fontproperties={'weight': 'bold', 'size': 11},
                 fontsize=10, frameon=True, facecolor='white', edgecolor=NEUTRAL_LIGHT,
                 loc='lower left', bbox_to_anchor=(0.0, 0.0))
ax.add_artist(leg1)

ax.legend(handles=overlay_handles,
          fontsize=10, frameon=True, facecolor='white', edgecolor=NEUTRAL_LIGHT,
          loc='lower right', bbox_to_anchor=(1.0, 0.0))

ax.set_title('Brazil Electricity Subsystems',
             fontsize=16, fontweight='bold', color=NEUTRAL_DARK, pad=16)

out = Path('V2-dc-opf-zonal-intertemporal/results/figures/subsystem_map.png')
fig.savefig(out, dpi=300, bbox_inches='tight', facecolor=BG_COLOR)
plt.close(fig)
print(f'Saved -> {out}')
