import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# -----------------------------
# Inline data (conc=1, mem=edge) from your pasted result.csv
# Metric: CG_IO_RBYTES_DELTA (bytes)
# -----------------------------
data = {
    "express-app": {
        "Baseline": {"P50": 20176896.0, "P95": 20307968.0},
        "SDL":      {"P50":   262144.0, "P95":   262144.0},
        "NDS":      {"P50":  1224704.0, "P95":  1232896.0},
        "SVsafe":   {"P50":   262144.0, "P95":   262144.0},
    },
    "next-grofers": {
        "Baseline": {"P50": 140355584.0, "P95": 140976128.0},
        "SDL":      {"P50":    262144.0, "P95":    262144.0},
        "NDS":      {"P50":  13600768.0, "P95":  13766656.0},
        "SVsafe":   {"P50":    262144.0, "P95":    262144.0},
    },
    "ghost": {
        "Baseline": {"P50": 2791208960.0, "P95": 6255329280.0},
        # no SDL in ghost
        "NDS":      {"P50":  174188544.0, "P95":  177745920.0},
        "SVsafe":   {"P50":     262144.0, "P95":     262144.0},
    }
}

workloads = ["express-app", "next-grofers", "ghost"]
method_order = ["Baseline", "SDL", "NDS", "SVsafe"]
DROP_MISSING_METHOD_LABELS = True  # ghost won't show SDL label/blank

# Two colors only: P50 vs P95
P50_COLOR = "#1f77b4"
P95_COLOR = "#ff7f0e"

# Layout (each method has 2 bars: P50 and P95)
bar_w = 0.18
pair_gap = 0.05
method_gap = 0.22
workload_gap = 0.9

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

        # P50 bar
        ax.bar(x, data[wl][m]["P50"], width=bar_w, color=P50_COLOR)
        # P95 bar
        ax.bar(x + bar_w + pair_gap, data[wl][m]["P95"], width=bar_w, color=P95_COLOR)

        # tick at the center of the pair
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

ax.set_ylabel("Device read bytes (bytes)  [conc=1, mem=edge]")
# no title

# CG_IO spans multiple orders -> log is usually necessary
ax.set_yscale("log")

ax.grid(axis="y", linestyle="--", linewidth=0.6, alpha=0.5)

ax.legend(handles=[
    Patch(facecolor=P50_COLOR, label="P50"),
    Patch(facecolor=P95_COLOR, label="P95"),
], loc="upper left", frameon=True)

plt.tight_layout()
out = "cg_io_rbytes_conc1_edge_p50_p95.png"
plt.savefig(out, dpi=200)
print(f"Saved: {out}")
plt.show()
