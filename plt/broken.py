import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# -----------------------------
# Inline data (conc=8, mem=edge)
# Each item: phase2_ms, setup_ms
# -----------------------------
'''
data = {
    "express-app": {
        "Baseline": {"P50": (462.5, 0.0), "P95": (488.0, 0.0)},
        "SDL":      {"P50": (4.0, 13.0),  "P95": (5.0, 26.0)},
        "NDS":      {"P50": (25.0, 0.0),  "P95": (27.0, 0.0)},
        "SVsafe":   {"P50": (4.0, 44.0),  "P95": (5.0, 61.0)},
    },
    "next-grofers": {
        "Baseline": {"P50": (5305.5, 0.0), "P95": (10799.0, 0.0)},
        "SDL":      {"P50": (4.0, 13.0),   "P95": (5.0, 25.0)},
        "NDS":      {"P50": (321.5, 0.0),  "P95": (374.0, 0.0)},
        "SVsafe":   {"P50": (4.0, 50.0),   "P95": (5.0, 67.0)},
    },
    "ghost": {
        "Baseline": {"P50": (74260.0, 0.0), "P95": (86864.0, 0.0)},
        "NDS":      {"P50": (4626.5, 0.0),  "P95": (6522.0, 0.0)},
        "SVsafe":   {"P50": (4.0, 79.5),    "P95": (5.0, 179.0)},
    }
}
'''

data = {
    "express-app": {
        "Baseline": {"P50": (368.0, 0.0), "P95": (402.0, 0.0)},
        "SDL":      {"P50": (4.0, 23.0),  "P95": (5.0, 24.0)},
        "NDS":      {"P50": (21.0, 0.0),  "P95": (22.0, 0.0)},
        "SVsafe":   {"P50": (3.0, 29.0),  "P95": (4.0, 30.0)},
    },
    "next-grofers": {
        "Baseline": {"P50": (1850.0, 0.0), "P95": (4680.0, 0.0)},
        "SDL":      {"P50": (4.0, 23.0),   "P95": (9.0, 24.0)},
        "NDS":      {"P50": (196.0, 0.0),  "P95": (241.0, 0.0)},
        "SVsafe":   {"P50": (3.0, 32.0),   "P95": (4.0, 32.0)},
    },
    "ghost": {
        "Baseline": {"P50": (24779.0, 0.0), "P95": (29618.0, 0.0)},
        # no SDL in ghost
        "NDS":      {"P50": (3158.5, 0.0),  "P95": (3533.0, 0.0)},
        "SVsafe":   {"P50": (3.0, 64.0),    "P95": (5.0, 68.0)},
    }
}

workloads = ["express-app", "next-grofers", "ghost"]
method_order = ["Baseline", "SDL", "NDS", "SVsafe"]
DROP_MISSING_METHOD_LABELS = True

PHASE2_COLOR = "#1f77b4"
SETUP_COLOR  = "#ff7f0e"
hatch_p95 = "//"

bar_w = 0.16
pair_gap = 0.04
method_gap = 0.16
workload_gap = 0.8

def max_total_ms(d):
    mx = 0.0
    for wl in d:
        for m in d[wl]:
            for st in d[wl][m]:
                p2, setup = d[wl][m][st]
                mx = max(mx, p2 + setup)
    return mx

# --- broken axis limits (tune these) ---
y_bottom_max = 700.0
y_top_min = 3000.0
y_top_max = max_total_ms(data) * 1.05

# -----------------------------
# Create figure with broken y-axis
# -----------------------------
fig, (ax1, ax2) = plt.subplots(
    2, 1, sharex=True, figsize=(14, 5.2),
    gridspec_kw={"height_ratios": [0.9, 1.4], "hspace": 0.05}
)

# -----------------------------
# Build bars (draw on both axes)
# -----------------------------
x = 0.0
xticks, xticklabels = [], []
boundaries = []

for wi, wl in enumerate(workloads):
    methods_here = [m for m in method_order if m in data[wl]] if DROP_MISSING_METHOD_LABELS else method_order
    seg_start = x

    for m in methods_here:
        if m not in data[wl]:
            xticks.append(x + (bar_w + pair_gap) / 2.0)
            xticklabels.append(m)
            x += (2 * bar_w + pair_gap + method_gap)
            continue

        for si, st in enumerate(["P50", "P95"]):
            phase2_ms, setup_ms = data[wl][m][st]
            xpos = x + si * (bar_w + pair_gap)

            is_p95 = (st == "P95")
            hatch = hatch_p95 if is_p95 else None
            edgecolor = "black" if is_p95 else None

            for ax in (ax1, ax2):
                ax.bar(
                    xpos, phase2_ms, width=bar_w,
                    color=PHASE2_COLOR,
                    hatch=hatch, edgecolor=edgecolor
                )
                ax.bar(
                    xpos, setup_ms, width=bar_w, bottom=phase2_ms,
                    color=SETUP_COLOR,
                    hatch=hatch, edgecolor=edgecolor
                )

        xticks.append(x + (bar_w + pair_gap) / 2.0)
        xticklabels.append(m)
        x += (2 * bar_w + pair_gap + method_gap)

    seg_end = x - method_gap
    ax1.text((seg_start + seg_end) / 2.0, 1.02, wl,
             transform=ax1.get_xaxis_transform(), ha="center", va="bottom")

    if wi != len(workloads) - 1:
        boundaries.append(x + workload_gap / 2.0)
    x += workload_gap

# workload separators (lighter looks more "paper")
for bx in boundaries:
    ax1.axvline(bx, linestyle="--", linewidth=1.2, alpha=0.8)
    ax2.axvline(bx, linestyle="--", linewidth=1.2, alpha=0.8)

# x ticks only on bottom axis
ax2.set_xticks(xticks)
ax2.set_xticklabels(xticklabels)

# y limits
ax2.set_ylim(0.0, y_bottom_max)
ax1.set_ylim(y_top_min, y_top_max)

# styling
for ax in (ax1, ax2):
    ax.grid(axis="y", linestyle="--", linewidth=0.6, alpha=0.5)

ax2.set_ylabel("Latency (ms)  [conc=8, mem=edge]")

# hide spines between axes
ax1.spines.bottom.set_visible(False)
ax2.spines.top.set_visible(False)
ax1.tick_params(labeltop=False)
ax1.xaxis.tick_top()
ax2.xaxis.tick_bottom()

# --- draw slanted cut-out marks (your reference style) ---
d = 0.5  # slope of the cut marks
kwargs = dict(
    marker=[(-1, -d), (1, d)],
    markersize=12,
    linestyle="none",
    color="k",
    mec="k",
    mew=1,
    clip_on=False
)
# top axis: marks at bottom (y=0 in axes coords)
ax1.plot([0, 1], [0, 0], transform=ax1.transAxes, **kwargs)
# bottom axis: marks at top (y=1 in axes coords)
ax2.plot([0, 1], [1, 1], transform=ax2.transAxes, **kwargs)

# legends (keep on top axis)
leg1 = ax1.legend(handles=[
        Patch(facecolor=PHASE2_COLOR, label="Latency (ms)"),
        Patch(facecolor=SETUP_COLOR,  label="Setup (ms)")
    ],
    loc="upper left", frameon=True
)
ax1.add_artist(leg1)

ax1.legend(handles=[
        Patch(facecolor="white", edgecolor="black", label="P50"),
        Patch(facecolor="white", edgecolor="black", hatch=hatch_p95, label="P95"),
    ],
    loc="upper right", frameon=True
)

plt.tight_layout()
out = "latency_stacked_conc1_edge_brokenaxis_slash.png"
plt.savefig(out, dpi=200)
print(f"Saved: {out}")
plt.show()
