#!/usr/bin/env python3
import csv
import argparse
from collections import defaultdict

def percentile(sorted_vals, p):
    if not sorted_vals:
        return "NA"
    n = len(sorted_vals)
    if p <= 0:
        return float(sorted_vals[0])
    if p >= 100:
        return float(sorted_vals[-1])
    # 和你之前 awk p95 類似：取 floor(p/100 * n)
    idx = int(p / 100.0 * n)
    if idx < 1:
        idx = 1
    if idx > n:
        idx = n
    return float(sorted_vals[idx - 1])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True, help="input summary.csv")
    ap.add_argument("--out", required=True, help="output matrix csv")
    ap.add_argument("--tag-prefix", required=True,
                    help="only consider rows whose run_tag starts with this prefix, "
                         "and use the suffix as target_strategy (e.g. Tbase/Tb2/Ta2).")
    args = ap.parse_args()

    groups = defaultdict(lambda: {
        "boottime_ms": [],
        "psi_io_some_pct": [],
        "psi_mem_some_pct": [],
        "pgmaj_delta": [],
        "cg_io_rbytes_delta": [],
        "mem_profile": None,
        "neighbor_method": None,
        "count": 0,
    })

    with open(args.csv, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            role = row.get("role", "")
            run_tag = row.get("run_tag", "")
            if role != "neighbor":
                continue
            if not run_tag.startswith(args.tag_prefix):
                continue

            # 例如 prefix = "E5_express_edge_N3_T"，suffix = "base"/"b2"/"a2"
            strategy_suffix = run_tag[len(args.tag_prefix):] or "unknown"
            target_strategy = strategy_suffix  # 可以直接寫成 "base"/"b2"/"a2"

            key = (target_strategy, row.get("method", ""), row.get("e2_mem_profile", ""))

            g = groups[key]
            g["count"] += 1
            g["mem_profile"] = row.get("e2_mem_profile", "")
            g["neighbor_method"] = row.get("method", "")

            def add_float(field, dest):
                val = row.get(field, "")
                if val == "" or val is None:
                    return
                try:
                    g[dest].append(float(val))
                except ValueError:
                    pass

            def add_int(field, dest):
                val = row.get(field, "")
                if val == "" or val is None:
                    return
                try:
                    g[dest].append(int(val))
                except ValueError:
                    pass

            add_int("boottime_ms", "boottime_ms")
            add_float("psi_io_some_pct", "psi_io_some_pct")
            add_float("psi_mem_some_pct", "psi_mem_some_pct")
            add_int("pgmaj_delta", "pgmaj_delta")
            add_int("cg_io_rbytes_delta", "cg_io_rbytes_delta")

    # 輸出矩陣
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "target_strategy",
            "neighbor_method",
            "mem_profile",
            "count",
            "PHASE2_BOOTTIME_MS_P50",
            "PHASE2_BOOTTIME_MS_P95",
            "PSI_IO_SOME_PCT_P50",
            "PSI_IO_SOME_PCT_P95",
            "PSI_MEM_SOME_PCT_P50",
            "PSI_MEM_SOME_PCT_P95",
            "PGMAJ_DELTA_P50",
            "PGMAJ_DELTA_P95",
            "CG_IO_RBYTES_DELTA_P50",
            "CG_IO_RBYTES_DELTA_P95",
        ])

        for (strategy, method, mem_profile), g in sorted(groups.items()):
            bt = sorted(g["boottime_ms"])
            psi_io = sorted(g["psi_io_some_pct"])
            psi_mem = sorted(g["psi_mem_some_pct"])
            pgmaj = sorted(g["pgmaj_delta"])
            cg_rbytes = sorted(g["cg_io_rbytes_delta"])

            w.writerow([
                strategy,
                method,
                mem_profile,
                g["count"],
                percentile(bt, 50),
                percentile(bt, 95),
                percentile(psi_io, 50),
                percentile(psi_io, 95),
                percentile(psi_mem, 50),
                percentile(psi_mem, 95),
                percentile(pgmaj, 50),
                percentile(pgmaj, 95),
                percentile(cg_rbytes, 50),
                percentile(cg_rbytes, 95),
            ])

if __name__ == "__main__":
    main()

