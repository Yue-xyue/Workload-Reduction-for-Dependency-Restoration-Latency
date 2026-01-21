#!/usr/bin/env python3
import argparse
import csv
from collections import defaultdict
from math import floor

def parse_args():
    p = argparse.ArgumentParser(
        description="Build E5 matrix (target only, group by neighbor_count × method × mem_profile)."
    )
    p.add_argument("--csv", required=True, help="input summary.csv (from e5_summarize_from_logs.py)")
    p.add_argument("--out", required=True, help="output matrix csv path")
    p.add_argument(
        "--tag-prefix",
        default="E5_",
        help="only keep rows where run_tag startswith this prefix (e.g. E5_express_edge512M_)",
    )
    return p.parse_args()

def percentile(sorted_list, q):
    """
    q in [0,1], simple quantile:
    index = floor(q*(n-1))
    """
    n = len(sorted_list)
    if n == 0:
        return ""
    idx = int(floor(q * (n - 1)))
    return sorted_list[idx]

def to_float(v):
    if v is None:
        return None
    v = v.strip()
    if not v:
        return None
    if v.upper() == "NA":
        return None
    try:
        return float(v)
    except ValueError:
        return None

def to_int(v):
    f = to_float(v)
    if f is None:
        return None
    return int(f)

def extract_neighbor_count(run_tag):
    """
    run_tag 範例: E5_express_edge512M_N3
    簡單從最後一段的 'N3' 擷取出 3
    """
    if not run_tag:
        return None
    # 找 '_N' 之後的整數
    pos = run_tag.rfind("_N")
    if pos == -1:
        return None
    sub = run_tag[pos + 2 :]
    # sub 可能是 '3' 或 '3_xxx'，只吃前面的數字
    num = ""
    for ch in sub:
        if ch.isdigit():
            num += ch
        else:
            break
    if not num:
        return None
    try:
        return int(num)
    except ValueError:
        return None

def main():
    args = parse_args()

    with open(args.csv, newline="") as f:
        reader = csv.reader(f)
        header = next(reader)

        # 欄位位置
        idx = {name: i for i, name in enumerate(header)}

        # 必要欄位檢查
        required_cols = [
            "method",
            "boottime_ms",
            "psi_io_some_pct",
            "psi_mem_some_pct",
            "pgmaj_delta",
            "cg_io_rbytes_delta",
            "run_tag",
            "role",
            "e2_mem_profile",
        ]
        for col in required_cols:
            if col not in idx:
                raise SystemExit(f"[E5-matrix] ERROR: column '{col}' not found in header")

        # 收集資料：key = (neighbor_count, method, mem_profile)
        groups = defaultdict(lambda: {
            "boottime_ms": [],
            "psi_io_some_pct": [],
            "psi_mem_some_pct": [],
            "pgmaj_delta": [],
            "cg_io_rbytes_delta": [],
        })

        for row in reader:
            run_tag = row[idx["run_tag"]].strip()
            if not run_tag.startswith(args.tag_prefix):
                continue

            role = row[idx["role"]].strip()
            if role != "target":
                # E5 只看 target 容器
                continue

            method = row[idx["method"]].strip()
            if not method or method == "trace":
                continue

            mem_profile = row[idx["e2_mem_profile"]].strip()

            neighbor = extract_neighbor_count(run_tag)
            if neighbor is None:
                # 如果 parse 不出來，就歸類到 -1，以免直接丟掉
                neighbor = -1

            key = (neighbor, method, mem_profile)

            # 取需要的 metric
            bt = to_float(row[idx["boottime_ms"]])
            psi_io = to_float(row[idx["psi_io_some_pct"]])
            psi_mem = to_float(row[idx["psi_mem_some_pct"]])
            pgmaj = to_int(row[idx["pgmaj_delta"]])
            cg_io = to_int(row[idx["cg_io_rbytes_delta"]])

            if bt is not None:
                groups[key]["boottime_ms"].append(bt)
            if psi_io is not None:
                groups[key]["psi_io_some_pct"].append(psi_io)
            if psi_mem is not None:
                groups[key]["psi_mem_some_pct"].append(psi_mem)
            if pgmaj is not None:
                groups[key]["pgmaj_delta"].append(pgmaj)
            if cg_io is not None:
                groups[key]["cg_io_rbytes_delta"].append(cg_io)

    # 輸出 matrix
    with open(args.out, "w", newline="") as f_out:
        w = csv.writer(f_out)
        w.writerow([
            "neighbor_count",
            "method",
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

        for (neighbor, method, mem_profile), metrics in sorted(groups.items()):
            # 先排序
            for k in metrics:
                metrics[k].sort()

            cnt = len(metrics["boottime_ms"])  # 用 boottime 的樣本數當作 count

            bt_p50 = percentile(metrics["boottime_ms"], 0.5)
            bt_p95 = percentile(metrics["boottime_ms"], 0.95)

            io_p50 = percentile(metrics["psi_io_some_pct"], 0.5)
            io_p95 = percentile(metrics["psi_io_some_pct"], 0.95)

            mem_p50 = percentile(metrics["psi_mem_some_pct"], 0.5)
            mem_p95 = percentile(metrics["psi_mem_some_pct"], 0.95)

            pg_p50 = percentile(metrics["pgmaj_delta"], 0.5)
            pg_p95 = percentile(metrics["pgmaj_delta"], 0.95)

            cg_p50 = percentile(metrics["cg_io_rbytes_delta"], 0.5)
            cg_p95 = percentile(metrics["cg_io_rbytes_delta"], 0.95)

            w.writerow([
                neighbor,
                method,
                mem_profile,
                cnt,
                bt_p50,
                bt_p95,
                io_p50,
                io_p95,
                mem_p50,
                mem_p95,
                pg_p50,
                pg_p95,
                cg_p50,
                cg_p95,
            ])

if __name__ == "__main__":
    main()

