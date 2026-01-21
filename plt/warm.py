import matplotlib.pyplot as plt
import numpy as np

def plot_total_cost_analysis(
    workloads,
    main_title="Total Cost Analysis of Warm-up Strategies (P50)",
    figsize=(16, 4.6),
    baseline_color="#4C72B0",   # 藍
    overhead_color="#C44E52",   # 紅
):
    """
    workloads: list[dict], 每個 dict 一個 workload panel，例如：
      {
        "title": "Express (Conc=8, Edge)",
        "labels": ["Baseline", "C1 (Full Scan)", "C2 (Head Scan)"],
        "baseline_effective": [0.54, 0.54, 0.54],   # 藍色段（Effective Phase-2）
        "overhead":           [0.00, 0.08, 0.08],   # 紅色段（Warm-up Cost / Overhead）
        "unit": "s",
      }
    """
    n = len(workloads)
    fig, axes = plt.subplots(1, n, figsize=figsize, constrained_layout=True)
    if n == 1:
        axes = [axes]

    fig.suptitle(main_title, fontsize=14)

    for i, (ax, w) in enumerate(zip(axes, workloads)):
        labels = w["labels"]
        base = np.array(w["baseline_effective"], dtype=float)
        over = np.array(w["overhead"], dtype=float)
        total = base + over
        x = np.arange(len(labels))
        width = 0.55

        # stacked bars
        ax.bar(x, base, width=width, color=baseline_color,
               label="Latency" if i == 0 else None)
        ax.bar(x, over, width=width, bottom=base, color=overhead_color,
               label="Warmup" if i == 0 else None)

        # title / axes
        ax.set_title(w.get("title", ""), fontsize=12)
        ax.set_xticks(x)
        ax.set_xticklabels(labels, fontsize=10)
        ax.set_ylabel("Total Time (s)")
        ax.yaxis.grid(True, linestyle="--", alpha=0.4)

        # y-limit：每個 panel 依最大值自動留白
        ymax = float(np.max(total)) if len(total) else 1.0
        ax.set_ylim(0, ymax * 1.18 if ymax > 0 else 1.0)

        # annotations
        unit = w.get("unit", "s")
        for xi, b, o, t in zip(x, base, over, total):
            # bar top total label (例如 9.7s)
            ax.text(xi, t + ymax * 0.02, f"{t:.1f}{unit}",
                    ha="center", va="bottom", fontsize=9)

            # overhead label inside red segment (例如 +6.6s)，overhead==0 就不標
            if o > 1e-12:
                ax.text(xi, b + o / 2.0, f"+{o:.1f}{unit}",
                        ha="center", va="center", fontsize=9, color="white")

    # legend: only once
    axes[0].legend(loc="upper left", fontsize=9, frameon=True)
    out = "PIC5.6.png"
    plt.savefig(out, dpi=200)
    plt.show()


if __name__ == "__main__":
    # ====== 範例資料（請換成你的 P50 數據）======
    workloads = [
        {
            "title": "Express (Conc=8, Edge)",
            "labels": ["Baseline", "Full Scan", "Head Scan"],
            "baseline_effective": [0.54, 0.54, 0.54],
            "overhead":           [0.00, 0.08, 0.08],
            "unit": "s",
        },
        {
            "title": "Grofers (Conc=8, Edge)",
            "labels": ["Baseline", "Full Scan", "Head Scan"],
            "baseline_effective": [3.1, 3.1, 3.1],
            "overhead":           [0.0, 6.6, 3.3],
            "unit": "s",
        },
        {
            "title": "Ghost (Conc=8, Edge)",
            "labels": ["Baseline", "Full Scan", "Head Scan"],
            "baseline_effective": [59.8, 59.8, 59.8],
            "overhead":           [0.0, 83.9, 4.6],
            "unit": "s",
        },
    ]

    plot_total_cost_analysis(workloads)

