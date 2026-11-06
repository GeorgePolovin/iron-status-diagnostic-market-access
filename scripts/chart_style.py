"""Shared slide-ready chart style: title / subtitle / footnote layout, PNG + SVG.

Palette (validated for colour-vision deficiency, all-pairs, light surface):
    TEAL   primary series / emphasis
    ORANGE second series
    INDIGO third series
    CONTEXT gray for de-emphasised bars, never a data identity
Text always uses ink tokens, never the series colour.
"""

from pathlib import Path
import textwrap

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

TEAL, ORANGE, INDIGO = "#008C99", "#D9681F", "#3A5BC7"
CONTEXT = "#B8C4CE"
INK, MUTED, GRID, SURFACE = "#172E3D", "#556B7A", "#E0E7EC", "#FFFFFF"
SERIES = [TEAL, ORANGE, INDIGO]

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 13,
    "axes.edgecolor": GRID,
    "axes.labelcolor": MUTED,
    "xtick.color": MUTED,
    "ytick.color": INK,
    "svg.fonttype": "none",
})


def new_figure(rect=(0.30, 0.17, 0.62, 0.62)):
    """16:9 figure with one axes placed inside the title/footnote frame."""
    fig = plt.figure(figsize=(12, 6.75))
    ax = fig.add_axes(rect)
    return fig, ax


def clean(ax, grid_axis="x"):
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.tick_params(length=0, pad=6)
    ax.set_axisbelow(True)
    if grid_axis:
        ax.grid(axis=grid_axis, color=GRID, linewidth=0.8)


def finish(fig, path: Path, title: str, subtitle: str, note: str, number: str = ""):
    """Add the title block and source note, then save PNG (200 dpi) and SVG."""
    label = f"{number}  " if number else ""
    if len(label + title) > 64:
        raise ValueError(f"Title too long for the slide frame: {title!r}")
    note = "\n".join(textwrap.fill(line, 150) for line in note.split("\n"))
    fig.text(0.04, 0.95, label + title, fontsize=21, weight="bold", color=INK, va="top")
    fig.text(0.04, 0.875, subtitle, fontsize=14, color=MUTED, va="top")
    fig.text(0.04, 0.03, note, fontsize=10.5, color=MUTED, va="bottom", linespacing=1.4)
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path.with_suffix(".png"), dpi=200, facecolor=SURFACE)
    fig.savefig(path.with_suffix(".svg"), facecolor=SURFACE)
    plt.close(fig)
