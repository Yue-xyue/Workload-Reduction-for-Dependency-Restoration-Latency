#!/usr/bin/env python3
# extract_process_summary.py
#
# Extract a reduced set of columns from summary.csv into PROCESS_SUMMARY.csv.
# Assumption: each summary.csv is already per-project, so no "project" column.
#
# Usage:
#   python3 extract_process_summary.py --input summary.csv
#   python3 extract_process_summary.py --input /path/to/summary.csv --output PROCESS_SUMMARY.csv

import argparse
import csv
import os
import sys
from typing import Dict, List, Tuple


def PickFirstExisting(row: Dict[str, str], candidates: List[str]) -> str:
    for k in candidates:
        if k in row and row[k] != "":
            return row[k]
    return ""


def BuildFieldSpec() -> List[Tuple[str, List[str]]]:
    # Output field -> candidate input columns (preferred first)
    # Prefer canonical uppercase columns when both exist.
    return [
        ("conc", ["e2_conc", "E2_CONC"]),
        ("mem", ["e2_mem_profile", "E2_MEM_PROFILE"]),
        ("PHASE2_BOOTTIME_MS", ["PHASE2_BOOTTIME_MS", "boottime_ms"]),
        ("E2_SETUP_MS", ["E2_SETUP_MS"]),
        ("E2_TOTAL_MS", ["E2_TOTAL_MS"]),
        ("CG_IO_RBYTES_DELTA", ["CG_IO_RBYTES_DELTA", "cg_io_rbytes_delta"]),
        ("PGMAJ_DELTA", ["PGMAJ_DELTA", "pgmaj_delta"]),
        ("NET_BYTES_DELTA", ["NET_BYTES_DELTA", "net_bytes_delta"]),
        ("EXIT_CODE", ["EXIT_CODE", "exit_code"]),
        # Optional but often useful for grouping/debug in-paper without being noisy:
        ("method", ["method", "METHOD"]),
        ("run_id", ["run_id", "RUN_ID"]),
        ("round", ["round", "ROUND"]),
        ("worker_id", ["worker_id", "WORKER_ID"]),
    ]


def Main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="Path to summary.csv")
    ap.add_argument("--output", default="PROCESS_SUMMARY.csv", help="Output CSV path (default: PROCESS_SUMMARY.csv)")
    args = ap.parse_args()

    in_path = args.input
    out_path = args.output

    if not os.path.isfile(in_path):
        print(f"ERROR: input not found: {in_path}", file=sys.stderr)
        return 2

    field_spec = BuildFieldSpec()
    out_fields = [name for (name, _cands) in field_spec]

    with open(in_path, "r", newline="", encoding="utf-8") as fin:
        reader = csv.DictReader(fin)
        if reader.fieldnames is None:
            print("ERROR: input CSV has no header", file=sys.stderr)
            return 2

        with open(out_path, "w", newline="", encoding="utf-8") as fout:
            writer = csv.DictWriter(fout, fieldnames=out_fields)
            writer.writeheader()

            for row in reader:
                out_row: Dict[str, str] = {}
                for (out_name, candidates) in field_spec:
                    out_row[out_name] = PickFirstExisting(row, candidates)
                writer.writerow(out_row)

    print(f"OK: wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(Main())

