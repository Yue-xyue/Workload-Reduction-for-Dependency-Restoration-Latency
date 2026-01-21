#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse, csv, os, sys, re
from collections import defaultdict

# -----------------------------------------------------------------------------
# Goals (updated)
# - Read whatever columns exist in summary.csv (no fixed schema assumption)
# - Group by (project, mem, conc, method)
# - Compute P50/P95 for stable core metrics + optionally for extra metrics
# - Robust to missing methods (e.g., ghost has no SDL) and missing/empty method fields
# - Robust to evolving column names (support both legacy lower_snake and newer canonical)
# -----------------------------------------------------------------------------

# Default matrix output header (core; always emitted)
MATRIX_HEADER_DEFAULT = [
    "project", "method", "conc", "mem",
    "PHASE2_BOOTTIME_MS_P50", "PHASE2_BOOTTIME_MS_P95",
    "PGMAJ_DELTA_P50", "PGMAJ_DELTA_P95",
    "PSI_IO_SOME_PCT_P50", "PSI_IO_SOME_PCT_P95",
    "PSI_MEM_SOME_PCT_P50", "PSI_MEM_SOME_PCT_P95",
    "CG_IO_RBYTES_DELTA_P50", "CG_IO_RBYTES_DELTA_P95",
    "NET_BYTES_DELTA_P50", "NET_BYTES_DELTA_P95",
]

# Optional extra matrix columns if requested
MATRIX_HEADER_E2E = [
    "E2_TOTAL_MS_P50", "E2_TOTAL_MS_P95",
    "E2_SETUP_MS_P50", "E2_SETUP_MS_P95",
    "PHASE2_OVER_E2E_RATIO_P50", "PHASE2_OVER_E2E_RATIO_P95",
]

MATRIX_HEADER_TAR = [
    "TAR_EXTRACT_MS_P50", "TAR_EXTRACT_MS_P95",
]

MATRIX_HEADER_A2MOUNT = [
    "A2_MOUNT_MS_P50", "A2_MOUNT_MS_P95",
]

MATRIX_HEADER_SVSAFE = [
    "SVSAFE_MOUNT_MS_P50", "SVSAFE_MOUNT_MS_P95",
    "SVSAFE_PROVISION_MS_P50", "SVSAFE_PROVISION_MS_P95",
    "SVSAFE_LOCK_WAIT_MS_P50", "SVSAFE_LOCK_WAIT_MS_P95",
    "SVSAFE_BUILD_MS_P50", "SVSAFE_BUILD_MS_P95",
    "SVSAFE_INSTALL_MS_P50", "SVSAFE_INSTALL_MS_P95",
]


def parse_args():
    p = argparse.ArgumentParser(description="Build matrices (p50/p95) from summary.csv")
    p.add_argument("--csv", required=True, help="Path to summary.csv (may be multi-project)")
    p.add_argument("--day", default="latest", help='Day in YYYYMMDD (or "latest")')
    p.add_argument("--out-summary", required=True, help="Output filtered summary_${DAY}.csv")
    p.add_argument("--out-matrix", required=True, help="Output matrix_${DAY}_p50_p95.csv")
    p.add_argument("--nb-thres", type=int, default=0,
                   help="Keep rows with NET_BYTES_DELTA >= thres (default: 0 = no filter)")

    # Optional knobs (default off)
    p.add_argument("--include-e2e", action="store_true",
                   help="Include E2E metrics (E2_TOTAL_MS/E2_SETUP_MS/ratio) if present")
    p.add_argument("--include-tar", action="store_true",
                   help="Include TAR_EXTRACT_MS if present")
    p.add_argument("--include-a2-mount", action="store_true",
                   help="Include A2_MOUNT_MS if present")
    p.add_argument("--include-svsafe", action="store_true",
                   help="Include SV-safe metrics if present")

    # Optional: restrict methods
    p.add_argument("--methods", default="",
                   help='Optional filter: comma-separated methods to include (e.g., "baseline_full,a2_shared_ro,svsafe_shared_ro")')
    return p.parse_args()


def safe_str(x):
    return (x or "").strip().strip('"')


def safe_float(x):
    sx = safe_str(x)
    if sx == "" or sx.lower() == "na":
        return None
    try:
        return float(sx)
    except Exception:
        return None


def nearest_rank_quantile(sorted_vals, q):
    """
    gawk-like nearest-rank percentile:
      i = int(q * (n + 1)), clamp [1, n]
    """
    n = len(sorted_vals)
    if n == 0:
        return ""
    i = int(q * (n + 1))
    if i < 1:
        i = 1
    if i > n:
        i = n
    return sorted_vals[i - 1]


def parse_conc_mem_from_run_tag(run_tag):
    """
    From RUN_TAG (fallback), e.g.:
      E2SWEEP_1115_1530.c8.edge.w7 -> conc="8", mem="edge"
    """
    rt = safe_str(run_tag)
    if not rt:
        return "", ""
    parts = rt.split(".")
    conc = ""
    mem = ""
    for j, p in enumerate(parts):
        if p.startswith("c") and p[1:].isdigit():
            conc = p[1:]
            if j + 1 < len(parts):
                mem = parts[j + 1]
            break
    return conc, mem


def infer_project_from_csv_path(csv_path: str) -> str:
    """
    Best-effort: infer <project> from .../frontier_poc/<project>/logs/summary.csv
    Works even if the summary lacks an explicit project column.
    """
    p = csv_path.replace("\\", "/")
    m = re.search(r"/frontier_poc/([^/]+)/logs/", p)
    if m:
        return m.group(1)
    return ""


def pick_day(csv_path, day_arg):
    """
    Return (resolved_day, all_rows, input_fieldnames)
    If day_arg="latest", pick max YYYYMMDD from ts.
    """
    with open(csv_path, newline="") as f:
        rdr = csv.DictReader(f)
        fieldnames = rdr.fieldnames or []
        all_rows = [row for row in rdr]

    if day_arg and day_arg != "latest":
        return day_arg, all_rows, fieldnames

    days = [safe_str(r.get("ts"))[:8] for r in all_rows if safe_str(r.get("ts"))]
    latest = sorted(days)[-1] if days else ""
    return latest, all_rows, fieldnames


def method_is_b2(method: str) -> bool:
    m = safe_str(method)
    return m.startswith("b2_")


def pick_first_nonempty(row: dict, keys):
    """
    Return the first non-empty value for any key in keys (in order).
    """
    for k in keys:
        v = safe_str(row.get(k))
        if v != "":
            return v
    return ""


def pick_float(row: dict, keys):
    """
    Return float for the first parseable value among keys.
    """
    for k in keys:
        v = safe_float(row.get(k))
        if v is not None:
            return v
    return None


def main():
    args = parse_args()

    inferred_project = infer_project_from_csv_path(args.csv)
    day_resolved, all_rows, in_header = pick_day(args.csv, args.day)

    if not day_resolved:
        print("[audit] no day resolved (empty CSV?)", file=sys.stderr)
        os.makedirs(os.path.dirname(args.out_summary), exist_ok=True)
        with open(args.out_summary, "w", newline="") as fo:
            cw = csv.writer(fo)
            cw.writerow(in_header if in_header else [])
        os.makedirs(os.path.dirname(args.out_matrix), exist_ok=True)
        with open(args.out_matrix, "w", newline="") as fo:
            cw = csv.writer(fo)
            cw.writerow(MATRIX_HEADER_DEFAULT)
        return

    # Determine header to write in filtered summary:
    out_summary_header = in_header if in_header else []

    # Optional method filter
    allow_methods = None
    if args.methods.strip():
        allow_methods = set([m.strip() for m in args.methods.split(",") if m.strip()])

    # 1) Filter rows by day + optional methods
    kept = []
    for r in all_rows:
        ts = safe_str(r.get("ts"))
        if ts[:8] != day_resolved:
            continue
        method = safe_str(r.get("method"))
        if allow_methods is not None:
            if method not in allow_methods:
                continue
        kept.append(r)

    # 2) net bytes threshold filter (use canonical first, then legacy)
    kept_after_nb = []
    for r in kept:
        nb = pick_float(r, ["NET_BYTES_DELTA", "net_bytes_delta"])
        if nb is None:
            nb = 0.0
        if nb >= float(args.nb_thres):
            kept_after_nb.append(r)

    print(f"[audit] day={day_resolved} "
          f"kept_rows_total={len(kept)} "
          f"kept_after_nb_thres={len(kept_after_nb)}")

    # method distribution (pre exit/b2 gating)
    counts = defaultdict(int)
    for r in kept:
        counts[safe_str(r.get("method"))] += 1
    for m, c in sorted(counts.items()):
        print(f"[audit] count method={m}: {c}")

    # 3) Write filtered summary_${DAY}.csv using input header (keeps new columns)
    os.makedirs(os.path.dirname(args.out_summary), exist_ok=True)
    with open(args.out_summary, "w", newline="") as fo:
        cw = csv.writer(fo)
        if out_summary_header:
            cw.writerow(out_summary_header)
            for r in kept:
                cw.writerow([safe_str(r.get(k)) for k in out_summary_header])
        else:
            # If input had no header (unlikely), still write something minimal
            cw.writerow(["ts", "method"])
            for r in kept:
                cw.writerow([safe_str(r.get("ts")), safe_str(r.get("method"))])

    # 4) Buckets aggregation (key = project, method, conc, mem)
    buckets = defaultdict(lambda: {
        # core metrics
        "bt": [],
        "pg": [],
        "psi_io_some": [],
        "psi_mem_some": [],
        "rb": [],
        "nb": [],
        # optional metrics
        "e2_total_ms": [],
        "e2_setup_ms": [],
        "phase2_over_e2e_ratio": [],
        "tar_extract_ms": [],
        "a2_mount_ms": [],
        # svsafe optional metrics
        "svsafe_mount_ms": [],
        "svsafe_provision_ms": [],
        "svsafe_lock_wait_ms": [],
        "svsafe_build_ms": [],
        "svsafe_install_ms": [],
    })

    dropped_b2_bad = 0
    dropped_exit = 0
    dropped_exit_by_method = defaultdict(int)
    dropped_missing_key = 0

    for r in kept_after_nb:
        # method must exist (requirement: "method 缺值也不崩")
        method = safe_str(r.get("method"))
        if not method:
            dropped_missing_key += 1
            continue

        # exit_code gate: support both canonical and legacy
        exit_code = pick_first_nonempty(r, ["EXIT_CODE", "exit_code"])
        if exit_code not in ("", "0"):
            dropped_exit += 1
            dropped_exit_by_method[method] += 1
            continue

        # B2 extraction sanity:
        # - prefer TAR_EXTRACT_OK if present
        # - else fallback to b2_extract_ok
        if method_is_b2(method):
            b2ok = pick_first_nonempty(r, ["TAR_EXTRACT_OK", "tar_extract_ok", "b2_extract_ok"])
            if b2ok == "0":
                dropped_b2_bad += 1
                continue

        # project grouping (prefer explicit columns; else infer from csv path)
        project = pick_first_nonempty(r, ["project", "proj", "PROJECT"])
        if project == "":
            project = inferred_project

        # conc/mem
        conc = pick_first_nonempty(r, ["e2_conc", "conc", "E2_CONC"])
        mem = pick_first_nonempty(r, ["e2_mem_profile", "mem", "E2_MEM_PROFILE"])
        if not conc or not mem:
            conc2, mem2 = parse_conc_mem_from_run_tag(r.get("run_tag"))
            conc = conc or conc2 or ""
            mem = mem or mem2 or ""

        # If still missing conc/mem, skip to avoid corrupt buckets
        if conc == "" or mem == "":
            dropped_missing_key += 1
            continue

        key = (project, method, conc, mem)

        # ----- core metrics (prefer canonical, fallback legacy) -----
        bt = pick_float(r, ["PHASE2_BOOTTIME_MS", "boottime_ms"])
        pg = pick_float(r, ["PGMAJ_DELTA", "pgmaj_delta"])
        psi_io_some = pick_float(r, ["PSI_IO_SOME_PCT", "psi_io_some_pct"])
        psi_mem_some = pick_float(r, ["PSI_MEM_SOME_PCT", "psi_mem_some_pct"])
        rb = pick_float(r, ["CG_IO_RBYTES_DELTA", "cg_io_rbytes_delta"])
        nb = pick_float(r, ["NET_BYTES_DELTA", "net_bytes_delta"])

        if bt is not None:
            buckets[key]["bt"].append(bt)
        if pg is not None:
            buckets[key]["pg"].append(pg)
        if psi_io_some is not None:
            buckets[key]["psi_io_some"].append(psi_io_some)
        if psi_mem_some is not None:
            buckets[key]["psi_mem_some"].append(psi_mem_some)
        if rb is not None:
            buckets[key]["rb"].append(rb)
        if nb is not None:
            buckets[key]["nb"].append(nb)

        # ----- optional metrics -----
        if args.include_e2e:
            # Prefer canonical names produced by summarize_from_logs.py
            e2_total = pick_float(r, ["E2_TOTAL_MS", "e2_total_ms"])
            e2_setup = pick_float(r, ["E2_SETUP_MS", "e2_setup_ms"])
            ratio = pick_float(r, ["PHASE2_OVER_E2E_RATIO", "phase2_over_e2e_ratio"])

            # Backward-compat: if canonical empty, fall back to older names
            if e2_total is None:
                e2_total = pick_float(r, ["E2E_WALL_MS", "e2e_wall_ms"])
            if e2_setup is None:
                e2_setup = pick_float(r, ["E2E_RESIDUAL_MS", "e2e_residual_ms"])

            if e2_total is not None:
                buckets[key]["e2_total_ms"].append(e2_total)
            if e2_setup is not None:
                buckets[key]["e2_setup_ms"].append(e2_setup)
            if ratio is not None:
                buckets[key]["phase2_over_e2e_ratio"].append(ratio)

        
        # ----- optional metrics (with method gating to avoid cross-contamination) -----
        if args.include_tar:
            # Only meaningful for b2_*
            if method_is_b2(method):
                tar_ms = pick_float(r, ["TAR_EXTRACT_MS", "tar_extract_ms"])
                if tar_ms is not None:
                    buckets[key]["tar_extract_ms"].append(tar_ms)

        if args.include_a2_mount:
            # Only meaningful for a2_*
            if method.startswith("a2_"):
                a2m = pick_float(r, ["A2_MOUNT_MS", "a2_mount_ms"])
                if a2m is not None:
                    buckets[key]["a2_mount_ms"].append(a2m)

        if args.include_svsafe:
            # Only meaningful for svsafe_*
            if method.startswith("svsafe_"):
                s_mount = pick_float(r, ["SVSAFE_MOUNT_MS", "svsafe_mount_ms"])
                s_prov  = pick_float(r, ["SVSAFE_PROVISION_MS", "svsafe_provision_ms"])
                s_lock  = pick_float(r, ["SVSAFE_LOCK_WAIT_MS", "svsafe_lock_wait_ms"])
                s_build = pick_float(r, ["SVSAFE_BUILD_MS", "svsafe_build_ms"])
                s_inst  = pick_float(r, ["SVSAFE_INSTALL_MS", "svsafe_install_ms"])
                if s_mount is not None:
                    buckets[key]["svsafe_mount_ms"].append(s_mount)
                if s_prov is not None:
                    buckets[key]["svsafe_provision_ms"].append(s_prov)
                if s_lock is not None:
                    buckets[key]["svsafe_lock_wait_ms"].append(s_lock)
                if s_build is not None:
                    buckets[key]["svsafe_build_ms"].append(s_build)
                if s_inst is not None:
                    buckets[key]["svsafe_install_ms"].append(s_inst)


    if dropped_exit > 0:
        print(f"[audit] dropped rows with exit_code != 0: {dropped_exit}")
        for m, c in sorted(dropped_exit_by_method.items()):
            print(f"[audit]   method={m} exit_code!=0 rows={c}")

    if dropped_b2_bad > 0:
        print(f"[audit] dropped b2_* rows with extract_ok=0: {dropped_b2_bad}")

    if dropped_missing_key > 0:
        print(f"[audit] dropped rows with missing method/conc/mem: {dropped_missing_key}")

    # 5) Build matrix header depending on flags
    matrix_header = list(MATRIX_HEADER_DEFAULT)
    if args.include_e2e:
        matrix_header += MATRIX_HEADER_E2E
    if args.include_tar:
        matrix_header += MATRIX_HEADER_TAR
    if args.include_a2_mount:
        matrix_header += MATRIX_HEADER_A2MOUNT
    if args.include_svsafe:
        matrix_header += MATRIX_HEADER_SVSAFE

    # 6) Emit matrix
    os.makedirs(os.path.dirname(args.out_matrix), exist_ok=True)
    with open(args.out_matrix, "w", newline="") as fo:
        cw = csv.writer(fo)
        cw.writerow(matrix_header)

        # Sort by project then method then conc then mem (stable)
        for (project, method, conc, mem) in sorted(buckets.keys()):
            b = buckets[(project, method, conc, mem)]

            bt_vals = sorted(b["bt"])
            pg_vals = sorted(b["pg"])
            psi_io_vals = sorted(b["psi_io_some"])
            psi_mem_vals = sorted(b["psi_mem_some"])
            rb_vals = sorted(b["rb"])
            nb_vals = sorted(b["nb"])

            p50bt = nearest_rank_quantile(bt_vals, 0.50)
            p95bt = nearest_rank_quantile(bt_vals, 0.95)

            p50pg = nearest_rank_quantile(pg_vals, 0.50) if pg_vals else ""
            p95pg = nearest_rank_quantile(pg_vals, 0.95) if pg_vals else ""

            p50_psi_io = nearest_rank_quantile(psi_io_vals, 0.50) if psi_io_vals else ""
            p95_psi_io = nearest_rank_quantile(psi_io_vals, 0.95) if psi_io_vals else ""

            p50_psi_mem = nearest_rank_quantile(psi_mem_vals, 0.50) if psi_mem_vals else ""
            p95_psi_mem = nearest_rank_quantile(psi_mem_vals, 0.95) if psi_mem_vals else ""

            p50rb = nearest_rank_quantile(rb_vals, 0.50) if rb_vals else ""
            p95rb = nearest_rank_quantile(rb_vals, 0.95) if rb_vals else ""

            p50nb = nearest_rank_quantile(nb_vals, 0.50) if nb_vals else ""
            p95nb = nearest_rank_quantile(nb_vals, 0.95) if nb_vals else ""

            row = [
                project, method, conc, mem,
                p50bt, p95bt,
                p50pg, p95pg,
                p50_psi_io, p95_psi_io,
                p50_psi_mem, p95_psi_mem,
                p50rb, p95rb,
                p50nb, p95nb,
            ]

            if args.include_e2e:
                e2_total_vals = sorted(b["e2_total_ms"])
                e2_setup_vals = sorted(b["e2_setup_ms"])
                ratio_vals = sorted(b["phase2_over_e2e_ratio"])
                row += [
                    nearest_rank_quantile(e2_total_vals, 0.50) if e2_total_vals else "",
                    nearest_rank_quantile(e2_total_vals, 0.95) if e2_total_vals else "",
                    nearest_rank_quantile(e2_setup_vals, 0.50) if e2_setup_vals else "",
                    nearest_rank_quantile(e2_setup_vals, 0.95) if e2_setup_vals else "",
                    nearest_rank_quantile(ratio_vals, 0.50) if ratio_vals else "",
                    nearest_rank_quantile(ratio_vals, 0.95) if ratio_vals else "",
                ]

            if args.include_tar:
                tar_vals = sorted(b["tar_extract_ms"])
                row += [
                    nearest_rank_quantile(tar_vals, 0.50) if tar_vals else "",
                    nearest_rank_quantile(tar_vals, 0.95) if tar_vals else "",
                ]

            if args.include_a2_mount:
                a2m_vals = sorted(b["a2_mount_ms"])
                row += [
                    nearest_rank_quantile(a2m_vals, 0.50) if a2m_vals else "",
                    nearest_rank_quantile(a2m_vals, 0.95) if a2m_vals else "",
                ]

            if args.include_svsafe:
                s_mount_vals = sorted(b["svsafe_mount_ms"])
                s_prov_vals = sorted(b["svsafe_provision_ms"])
                s_lock_vals = sorted(b["svsafe_lock_wait_ms"])
                s_build_vals = sorted(b["svsafe_build_ms"])
                s_inst_vals = sorted(b["svsafe_install_ms"])

                row += [
                    nearest_rank_quantile(s_mount_vals, 0.50) if s_mount_vals else "",
                    nearest_rank_quantile(s_mount_vals, 0.95) if s_mount_vals else "",
                    nearest_rank_quantile(s_prov_vals, 0.50) if s_prov_vals else "",
                    nearest_rank_quantile(s_prov_vals, 0.95) if s_prov_vals else "",
                    nearest_rank_quantile(s_lock_vals, 0.50) if s_lock_vals else "",
                    nearest_rank_quantile(s_lock_vals, 0.95) if s_lock_vals else "",
                    nearest_rank_quantile(s_build_vals, 0.50) if s_build_vals else "",
                    nearest_rank_quantile(s_build_vals, 0.95) if s_build_vals else "",
                    nearest_rank_quantile(s_inst_vals, 0.50) if s_inst_vals else "",
                    nearest_rank_quantile(s_inst_vals, 0.95) if s_inst_vals else "",
                ]

            cw.writerow(row)

    print(f"[ok] wrote {args.out_matrix} groups={len(buckets)}")


if __name__ == "__main__":
    main()
