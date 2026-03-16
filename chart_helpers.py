import matplotlib
matplotlib.use('Agg')

import matplotlib as mpl
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import seaborn as sns
import pandas as pd
from typing import Optional
from pathlib import Path

# ---------------------------------------------------------------------------
# SYPA Graph Style — EPE logo palette, Harvard Kennedy School academic quality
# ---------------------------------------------------------------------------

# Colors
NAVY = '#0D2B5E'
BLUE = '#1E5FA8'
AMBER = '#F5A623'
GREEN = '#3A9A5C'
RED = '#C0392B'
PURPLE = '#7B3FA0'
NEUTRAL_DARK = '#1A1A1A'
NEUTRAL_MID = '#5C5C5C'
NEUTRAL_LIGHT = '#D9D9D9'
GRID_COLOR = '#EBEBEB'
BG_COLOR = '#FFFFFF'

# Series color order: navy, amber, blue, green, red, purple
SYPA_PALETTE = [NAVY, AMBER, BLUE, GREEN, RED, PURPLE]

# Line styles to pair with colors for accessibility
SYPA_LINE_STYLES = ['-', '--', '-.', ':', (0, (3, 1, 1, 1)), (0, (5, 2))]

# Marker styles to pair with colors for accessibility
SYPA_MARKERS = ['o', 's', '^', 'D', 'v', 'P']

# Figure sizes (inches)
FIGSIZE_SINGLE = (7, 4.5)
FIGSIZE_FULL = (7, 5.5)

mpl.rcParams.update({
    # Figure
    'figure.figsize': FIGSIZE_SINGLE,
    'figure.dpi': 300,
    'figure.facecolor': BG_COLOR,
    'figure.edgecolor': BG_COLOR,
    'savefig.dpi': 300,
    'savefig.facecolor': BG_COLOR,
    'savefig.edgecolor': BG_COLOR,

    # Font — Arial
    'font.family': 'sans-serif',
    'font.sans-serif': ['Arial', 'Helvetica', 'DejaVu Sans'],
    'font.size': 10,

    # Axes
    'axes.titlesize': 13,
    'axes.titleweight': 'bold',
    'axes.labelsize': 11,
    'axes.labelcolor': NEUTRAL_DARK,
    'axes.edgecolor': NEUTRAL_MID,
    'axes.linewidth': 0.8,
    'axes.facecolor': BG_COLOR,
    'axes.grid': True,
    'axes.grid.axis': 'y',
    'axes.spines.top': False,
    'axes.spines.right': False,
    'axes.prop_cycle': mpl.cycler(color=SYPA_PALETTE),
    'axes.labelpad': 8,
    'axes.titlepad': 12,

    # Grid — horizontal only, light
    'grid.color': GRID_COLOR,
    'grid.linewidth': 0.6,
    'grid.alpha': 1.0,

    # Ticks
    'xtick.labelsize': 10,
    'ytick.labelsize': 10,
    'xtick.color': NEUTRAL_MID,
    'ytick.color': NEUTRAL_MID,
    'xtick.major.pad': 5,
    'ytick.major.pad': 5,

    # Legend
    'legend.fontsize': 10,
    'legend.frameon': False,
    'legend.loc': 'upper right',

    # Lines
    'lines.linewidth': 1.8,
    'lines.markersize': 5,

    # Patches (bars, etc.)
    'patch.edgecolor': BG_COLOR,
})

# Set seaborn to use our palette by default
sns.set_palette(SYPA_PALETTE)

CHARTS_DIR = Path('outputs/charts')


def apply_sypa_style(ax: mpl.axes.Axes) -> None:
    """Apply SYPA finishing touches to an axes that rcParams alone cannot set."""
    # Spine colors and widths
    for spine in ('left', 'bottom'):
        ax.spines[spine].set_color(NEUTRAL_MID)
        ax.spines[spine].set_linewidth(0.8)
    for spine in ('top', 'right'):
        ax.spines[spine].set_visible(False)

    # Horizontal grid only
    ax.yaxis.grid(True, color=GRID_COLOR, linewidth=0.6)
    ax.xaxis.grid(False)
    ax.set_axisbelow(True)


def save_chart(fig: mpl.figure.Figure, filename: str) -> Path:
    """Save figure as PNG to outputs/charts/ and close it. Returns the output path."""
    CHARTS_DIR.mkdir(parents=True, exist_ok=True)
    out = CHARTS_DIR / filename
    fig.savefig(out, dpi=300, bbox_inches='tight')
    plt.close(fig)
    return out


def plot_distribution(
    df: pd.DataFrame,
    col: str,
    by_col: Optional[str] = None,
    bins: int = 30,
    kde: bool = True,
    title: Optional[str] = None,
    xlabel: Optional[str] = None,
) -> tuple[mpl.figure.Figure, mpl.axes.Axes]:
    """
    Render a histogram (+ optional KDE) for a numeric column, optionally split by a categorical column.

    Parameters
    ----------
    df : pd.DataFrame
        Source DataFrame.
    col : str
        Numeric column to plot.
    by_col : str or None
        If provided, overlapping histograms are drawn for each unique value of this column.
    bins : int
        Number of histogram bins (default 30). Ignored when by_col is provided (seaborn default).
    kde : bool
        If True (default), overlay a kernel density estimate. Only applied when by_col is None.
    title : str or None
        Chart title. Defaults to f'Distribution of {col}'.
    xlabel : str or None
        X-axis label. Defaults to col.

    Returns
    -------
    tuple[mpl.figure.Figure, mpl.axes.Axes]
        The figure and axes. Caller is responsible for saving via save_chart().
    """
    fig, ax = plt.subplots()

    if by_col is not None:
        for i, val in enumerate(df[by_col].unique()):
            group = df[df[by_col] == val]
            color = SYPA_PALETTE[i % len(SYPA_PALETTE)]
            sns.histplot(data=group, x=col, bins=bins, kde=kde, alpha=0.5,
                         color=color, label=str(val), ax=ax)
        ax.legend(title=by_col, bbox_to_anchor=(1.02, 1), loc='upper left',
                  borderaxespad=0)
    else:
        sns.histplot(data=df, x=col, bins=bins, kde=kde, color=NAVY, ax=ax)

    ax.set_title(title if title is not None else f'Distribution of {col}')
    ax.set_xlabel(xlabel if xlabel is not None else col)
    apply_sypa_style(ax)

    return fig, ax


def plot_correlation_matrix(
    df: pd.DataFrame,
    cols: Optional[list[str]] = None,
    title: Optional[str] = None,
) -> tuple[mpl.figure.Figure, mpl.axes.Axes, pd.DataFrame]:
    """
    Render a heatmap with annotated Pearson r values for selected numeric columns.

    Parameters
    ----------
    df : pd.DataFrame
        Source DataFrame.
    cols : list[str] or None
        Columns to include. Uses all columns if None.
    title : str or None
        Chart title. Defaults to 'Correlation Matrix'.

    Returns
    -------
    tuple[mpl.figure.Figure, mpl.axes.Axes, pd.DataFrame]
        Figure, axes, and the raw correlation DataFrame.
        Caller is responsible for saving via save_chart().
    """
    data = df[cols] if cols is not None else df
    corr = data.corr()
    n = len(corr)

    # Navy-white-amber diverging colormap
    sypa_cmap = mcolors.LinearSegmentedColormap.from_list(
        'sypa_diverging', [NAVY, '#FFFFFF', AMBER])

    fig, ax = plt.subplots(figsize=(max(6, n), max(5, n - 1)))
    sns.heatmap(
        corr,
        annot=True,
        fmt='.2f',
        cmap=sypa_cmap,
        center=0,
        square=True,
        linewidths=0.5,
        linecolor=BG_COLOR,
        cbar_kws={'shrink': 0.8},
        ax=ax,
    )
    ax.set_title(title if title is not None else 'Correlation Matrix')

    return fig, ax, corr


def plot_grouped_comparison(
    df: pd.DataFrame,
    x: str,
    y: str,
    hue: Optional[str] = None,
    kind: str = 'bar',
    title: Optional[str] = None,
    xlabel: Optional[str] = None,
    ylabel: Optional[str] = None,
) -> tuple[mpl.figure.Figure, mpl.axes.Axes]:
    """
    Render bar, box, or violin charts grouped by a categorical column.

    Parameters
    ----------
    df : pd.DataFrame
        Source DataFrame.
    x : str
        Column for the x-axis (categorical grouping variable).
    y : str
        Column for the y-axis (numeric values).
    hue : str or None
        Optional second grouping variable for colour coding.
    kind : str
        Chart type: 'bar' (default), 'box', or 'violin'.
    title : str or None
        Chart title. Defaults to f'{y} by {x}'.
    xlabel : str or None
        X-axis label. Defaults to x column name.
    ylabel : str or None
        Y-axis label. Defaults to y column name.

    Returns
    -------
    tuple[mpl.figure.Figure, mpl.axes.Axes]
        Figure and axes. Caller is responsible for saving via save_chart().
    """
    fig, ax = plt.subplots()

    palette = SYPA_PALETTE
    if kind == 'box':
        sns.boxplot(data=df, x=x, y=y, hue=hue, palette=palette, ax=ax)
    elif kind == 'violin':
        sns.violinplot(data=df, x=x, y=y, hue=hue, inner='quartile',
                       palette=palette, ax=ax)
    else:
        sns.barplot(data=df, x=x, y=y, hue=hue, palette=palette, ax=ax)

    ax.set_title(title if title is not None else f'{y} by {x}')
    if xlabel is not None:
        ax.set_xlabel(xlabel)
    if ylabel is not None:
        ax.set_ylabel(ylabel)

    # Move legend outside plot if hue is used
    if hue is not None:
        ax.legend(bbox_to_anchor=(1.02, 1), loc='upper left', borderaxespad=0)

    apply_sypa_style(ax)

    return fig, ax
