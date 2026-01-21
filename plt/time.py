import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# -----------------------------
# Inline data (conc=8, mem=edge) from your pasted result.csv
# Each item: phase2_ms, setup_ms
# -----------------------------
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
        # no SDL in ghost
        "NDS":      {"P50": (4626.5, 0.0),  "P95": (6522.0, 0.0)},
        "SVsafe":   {"P50": (4.0, 79.5),    "P95": (5.0, 179.0)},
    }
}

workloads = ["express-app", "next-grofers", "ghost"]
method_order = ["Baseline", "SDL", "NDS", "SVsafe"]
DROP_MISSING_METHOD_LABELS = True

# unified colors
PHASE2_COLOR = "#1f77b4"  # blue
SETUP_COLOR  = "#ff7f0e"  # orange

# Layout
bar_w = 0.16
pair_gap = 0.04
method_gap = 0.16
workload_gap = 0.8
hatch_p95 = "//"

fig, ax = plt.subplots(figsize=(14, 4.2))

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

            # bottom: phase-2
            ax.bar(
                xpos, phase2_ms, width=bar_w,
                color=PHASE2_COLOR,
                hatch=hatch, edgecolor=edgecolor
            )
            # top: setup
            ax.bar(
                xpos, setup_ms, width=bar_w, bottom=phase2_ms,
                color=SETUP_COLOR,
                hatch=hatch, edgecolor=edgecolor
            )

        xticks.append(x + (bar_w + pair_gap) / 2.0)
        xticklabels.append(m)

        x += (2 * bar_w + pair_gap + method_gap)

    seg_end = x - method_gap
    ax.text((seg_start + seg_end) / 2.0, 1.02, wl,
            transform=ax.get_xaxis_transform(), ha="center", va="bottom")

    if wi != len(workloads) - 1:
        boundaries.append(x + workload_gap / 2.0)
    x += workload_gap

# workload separators
for bx in boundaries:
    ax.axvline(bx, linestyle="--", linewidth=1.5)

ax.set_xticks(xticks)
ax.set_xticklabels(xticklabels)
ax.set_ylabel("Latency (ms)  [conc=8, mem=edge]")

# no title
ax.set_yscale("log")
ax.grid(axis="y", linestyle="--", linewidth=0.6, alpha=0.5)

# legends
leg1 = ax.legend(handles=[
        Patch(facecolor=PHASE2_COLOR, label="Latency (ms)"),
        Patch(facecolor=SETUP_COLOR,  label="Setup (ms)")
    ],
    loc="upper left", frameon=True
)
ax.add_artist(leg1)

ax.legend(handles=[
        Patch(facecolor="white", edgecolor="black", label="P50"),
        Patch(facecolor="white", edgecolor="black", hatch=hatch_p95, label="P95"),
    ],
    loc="upper right", frameon=True
)

plt.tight_layout()
out = "latency_stacked_conc8_edge_unified.png"
plt.savefig(out, dpi=200)
print(f"Saved: {out}")
plt.show()
