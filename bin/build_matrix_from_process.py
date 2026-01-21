#!/usr/bin/env python3
import argparse
import os
import sys
import pandas as pd
import numpy as np

DEFAULT_METHODS = ["baseline_full", "a2_shared_ro", "b2_frontier_only", "svsafe_shared_ro"]
DEFAULT_CONC = [1, 4, 8]
DEFAULT_MEM = ["ample", "edge"]

DEFAULT_METRICS = [
    "PHASE2_BOOTTIME_MS",
    "E2_SETUP_MS",
    "E2_TOTAL_MS",
    "CG_IO_RBYTES_DELTA",
    "PGMAJ_DELTA",
    "NET_BYTES_DELTA",
    "EXIT_CODE",
]

CG_METRIC_NAME = "CG_IO_RBYTES_DELTA"


def PercentileSeries(s: pd.Series, q: float, method: str, *, exclude_zeros: bool = False) -> float:
    """
    Robust percentile for numeric series:
    - coerces to numeric
    - drops NaN
    - optionally excludes zeros
    """
    a = pd.to_numeric(s, errors="coerce").dropna()
    if exclude_zeros:
        a = a[a != 0]
    arr = a.to_numpy()
    if arr.size == 0:
        return np.nan

    # numpy >= 1.22 uses "method", older uses "interpolation"
    try:
        return float(np.percentile(arr, q, method=method))
    except TypeError:
        return float(np.percentile(arr, q, interpolation=method))


def NonZeroCount(s: pd.Series) -> int:
    a = pd.to_numeric(s, errors="coerce").dropna()
    return int((a != 0).sum())


def BuildMatrix(df: pd.DataFrame,
                metrics: list[str],
                fill_missing: bool,
                methods: list[str],
                conc_set: list[int],
                mem_set: list[str],
                p50_method: str,
                p95_method: str,
                cg_exclude_zeros: bool,
                emit_cg_nzcount: bool) -> pd.DataFrame:

    # Normalize types
    df["conc"] = pd.to_numeric(df["conc"], errors="coerce")
    df["mem"] = df["mem"].astype(str)
    df["method"] = df["method"].astype(str)

    # Keep only target conc/mem if provided
    df = df[df["conc"].isin(conc_set) & df["mem"].isin(mem_set)]
    if df.empty:
        return pd.DataFrame()

    group_cols = ["method", "conc", "mem"]

    # Aggregate count + percentiles
    agg_dict = {"count": ("method", "size")}

    for m in metrics:
        if m not in df.columns:
            # allow missing metric columns; will appear as NaN later if fill_missing
            continue

        if m == CG_METRIC_NAME and cg_exclude_zeros:
            # Optional: expose how many non-zero samples exist per group
            if emit_cg_nzcount:
                agg_dict[f"{m}_NZCOUNT"] = (m, lambda s: NonZeroCount(s))

            agg_dict[f"{m}_P50"] = (m, lambda s: PercentileSeries(s, 50, p50_method, exclude_zeros=True))
            agg_dict[f"{m}_P95"] = (m, lambda s: PercentileSeries(s, 95, p95_method, exclude_zeros=True))
        else:
            agg_dict[f"{m}_P50"] = (m, lambda s: PercentileSeries(s, 50, p50_method, exclude_zeros=False))
            agg_dict[f"{m}_P95"] = (m, lambda s: PercentileSeries(s, 95, p95_method, exclude_zeros=False))

    out = df.groupby(group_cols, dropna=False).agg(**agg_dict).reset_index()

    # Optionally fill missing (method,conc,mem) combinations with NaN rows
    if fill_missing:
        full_index = pd.MultiIndex.from_product(
            [methods, conc_set, mem_set],
            names=["method", "conc", "mem"]
        )
        out = out.set_index(["method", "conc", "mem"]).reindex(full_index).reset_index()
        if "count" not in out.columns:
            out["count"] = 0
        out["count"] = out["count"].fillna(0).astype(int)

    # Sort for readability
    out["conc"] = pd.to_numeric(out["conc"], errors="coerce").astype("Int64")
    out = out.sort_values(["method", "conc", "mem"], kind="stable").reset_index(drop=True)
    return out


def main():
    ap = argparse.ArgumentParser(description="Compute P50/P95 by (method, conc, mem) from process.csv")
    ap.add_argument("--input", "-i", default="process.csv", help="Input process.csv path")
    ap.add_argument("--output", "-o", default=None,
                    help="Output matrix CSV path (default: matrix_p50_p95.csv next to input)")
    ap.add_argument("--fill-missing", action="store_true",
                    help="Emit all 24 combos (missing combos as NaN rows). Useful for consistent tables; safe for ghost.")
    ap.add_argument("--methods", nargs="*", default=DEFAULT_METHODS, help="Method list")
    ap.add_argument("--conc", nargs="*", type=int, default=DEFAULT_CONC, help="Conc list")
    ap.add_argument("--mem", nargs="*", default=DEFAULT_MEM, help="Mem list")
    ap.add_argument("--metrics", nargs="*", default=DEFAULT_METRICS,
                    help="Metric columns to compute P50/P95 for")

    # Percentile behavior knobs
    ap.add_argument("--p50-method", default="linear",
                    choices=["linear", "midpoint", "lower", "higher", "nearest"],
                    help="np.percentile method for P50 (default: linear)")
    ap.add_argument("--p95-method", default="higher",
                    choices=["linear", "midpoint", "lower", "higher", "nearest"],
                    help="np.percentile method for P95 (default: higher; returns an observed sample)")

    # NEW: CG non-zero handling
    ap.add_argument("--cg-exclude-zeros", action="store_true", default=True,
                    help=f"Exclude zeros when computing {CG_METRIC_NAME} P50/P95 (default: enabled)")
    ap.add_argument("--no-cg-exclude-zeros", dest="cg_exclude_zeros", action="store_false",
                    help=f"Do NOT exclude zeros for {CG_METRIC_NAME} (restore original behavior)")
    ap.add_argument("--emit-cg-nzcount", action="store_true",
                    help=f"Also emit {CG_METRIC_NAME}_NZCOUNT for debugging/paper explanation")

    args = ap.parse_args()

    in_path = args.input
    if not os.path.exists(in_path):
        print(f"[error] input not found: {in_path}", file=sys.stderr)
        sys.exit(2)

    df = pd.read_csv(in_path)
    needed_cols = {"conc", "mem", "method"}
    miss = needed_cols - set(df.columns)
    if miss:
        print(f"[error] missing required columns: {sorted(miss)}", file=sys.stderr)
        sys.exit(2)

    out = BuildMatrix(
        df=df,
        metrics=args.metrics,
        fill_missing=args.fill_missing,
        methods=args.methods,
        conc_set=args.conc,
        mem_set=args.mem,
        p50_method=args.p50_method,
        p95_method=args.p95_method,
        cg_exclude_zeros=args.cg_exclude_zeros,
        emit_cg_nzcount=args.emit_cg_nzcount,
    )

    if out.empty:
        print("[warn] no rows after filtering (check conc/mem values).", file=sys.stderr)
        sys.exit(1)

    if args.output is None:
        base_dir = os.path.dirname(os.path.abspath(in_path))
        out_path = os.path.join(base_dir, "matrix_p50_p95.csv")
    else:
        out_path = args.output

    out.to_csv(out_path, index=False)
    print(f"[ok] rows={len(out)} -> {out_path}")
    print(f"[note] P50 method={args.p50_method}, P95 method={args.p95_method}")
    print(f"[note] {CG_METRIC_NAME} exclude_zeros={args.cg_exclude_zeros}")

    if args.cg_exclude_zeros and not args.emit_cg_nzcount:
        print("[hint] add --emit-cg-nzcount if you want to see how many non-zero CG samples were used per group.")


if __name__ == "__main__":
    main()
