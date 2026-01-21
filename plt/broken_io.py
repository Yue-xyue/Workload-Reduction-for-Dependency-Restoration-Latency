import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# -----------------------------
# Inline data (conc=1, mem=edge)
# Metric: CG_IO_RBYTES_DELTA (bytes)
# -----------------------------
'''
data_bytes = {
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
        "NDS":      {"P50":  174188544.0,  "P95":  177745920.0},
        "SVsafe":   {"P50":     262144.0,  "P95":     262144.0},
    }
}
'''

# --- convert to MiB for readability ---
MiB = 1024.0 * 1024.0
data = {}
for wl in data_bytes:
    data[wl] = {}
    for m in data_bytes[wl]:
        data[wl][m] = {k: v / MiB for k, v in data_bytes[wl][m].items()}

workloads = ["express-app", "next-grofers", "ghost"]
method_order = ["Baseline", "SDL", "NDS", "SVsafe"]
DROP_MISSING_METHOD_LABELS = True

P50_COLOR = "#1f77b4"
P95_COLOR = "#ff7f0e"

bar_w = 0.18
pair_gap = 0.05
method_gap = 0.22
workload_gap = 0.9

def max_val(d):
    mx = 0.0
    for wl in d:
        for m in d[wl]:
            mx = max(mx, d[wl][m]["P50"], d[wl][m]["P95"])
    return mx

# -----------------------------
# 3-level broken axis limits (MiB)
#   - bottom: show SDL/SVsafe (~0.25 MiB) + express NDS (~1.2 MiB)
#   - mid: show express baseline (~19 MiB), next NDS (~13 MiB), next baseline (~134 MiB)
#   - top: show ghost baseline (2660~5960 MiB)
# -----------------------------
y_bot_max = 2.0        # 0 ~ 2 MiB
y_mid_min = 8.0        # 8 ~ 300 MiB
 # (leave a gap between bot and mid)
y_mid_max = 300.0
y_top_min = 1500.0     # 1500 ~ max MiB
y_top_max = max_val(data) * 1.05

fig, (ax_top, ax_mid, ax_bot) = plt.subplots(
    3, 1, sharex=True, figsize=(14, 6.2),
    gridspec_kw={"height_ratios": [0.9, 1.0, 1.2], "hspace": 0.05}
)

# -----------------------------
# Build bars (draw on all axes; clipped by ylim)
# -----------------------------
x = 0.0
xticks, xticklabels = [], []
boundaries = []

for wi, wl in enumerate(workloads):
    methods_here = [m for m in method_order if m in data[wl]] if DROP_MISSING_METHOD_LABELS else method_order
    seg_start = x

    for m in methods_here:
        # two bars per method: P50 and P95
        p50 = data[wl][m]["P50"]
        p95 = data[wl][m]["P95"]

        for ax in (ax_top, ax_mid, ax_bot):
            ax.bar(x, p50, width=bar_w, color=P50_COLOR)
            ax.bar(x + bar_w + pair_gap, p95, width=bar_w, color=P95_COLOR)

        xticks.append(x + (bar_w + pair_gap) / 2.0)
        xticklabels.append(m)

        x += (2 * bar_w + pair_gap + method_gap)

    seg_end = x - method_gap
    ax_top.text((seg_start + seg_end) / 2.0, 1.02, wl,
                transform=ax_top.get_xaxis_transform(), ha="center", va="bottom")

    if wi != len(workloads) - 1:
        boundaries.append(x + workload_gap / 2.0)
    x += workload_gap

# workload separators
for bx in boundaries:
    for ax in (ax_top, ax_mid, ax_bot):
        ax.axvline(bx, linestyle="--", linewidth=1.2, alpha=0.8)

# x ticks only on bottom axis
ax_bot.set_xticks(xticks)
ax_bot.set_xticklabels(xticklabels)

# y limits for 3 segments
ax_bot.set_ylim(0.0, y_bot_max)
ax_mid.set_ylim(y_mid_min, y_mid_max)
ax_top.set_ylim(y_top_min, y_top_max)

# grids
for ax in (ax_top, ax_mid, ax_bot):
    ax.grid(axis="y", linestyle="--", linewidth=0.6, alpha=0.5)

ax_mid.set_ylabel("Device read bytes (MiB)  [conc=1, mem=edge]")

# hide spines between axes
ax_top.spines.bottom.set_visible(False)
ax_mid.spines.bottom.set_visible(False)
ax_mid.spines.top.set_visible(False)
ax_bot.spines.top.set_visible(False)

ax_top.tick_params(labeltop=False)
ax_mid.tick_params(labeltop=False)

ax_top.xaxis.tick_top()
ax_mid.xaxis.tick_top()
ax_bot.xaxis.tick_bottom()

# draw cut marks (slashes) between segments
d = 0.5
kwargs = dict(marker=[(-1, -d), (1, d)], markersize=12,
              linestyle="none", color="k", mec="k", mew=1, clip_on=False)

# between top and mid
ax_top.plot([0, 1], [0, 0], transform=ax_top.transAxes, **kwargs)
ax_mid.plot([0, 1], [1, 1], transform=ax_mid.transAxes, **kwargs)

# between mid and bot
ax_mid.plot([0, 1], [0, 0], transform=ax_mid.transAxes, **kwargs)
ax_bot.plot([0, 1], [1, 1], transform=ax_bot.transAxes, **kwargs)

# legend
ax_top.legend(handles=[
    Patch(facecolor=P50_COLOR, label="P50"),
    Patch(facecolor=P95_COLOR, label="P95"),
], loc="upper left", frameon=True)

plt.tight_layout()
out = "cg_io_rbytes_conc1_edge_p50_p95_brokenaxis_3level_mib.png"
plt.savefig(out, dpi=200)
print(f"Saved: {out}")
plt.show()
