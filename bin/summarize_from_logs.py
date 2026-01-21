#!/usr/bin/env python3
import argparse, csv, json, re
from pathlib import Path
from datetime import datetime


def parse_args():
    p = argparse.ArgumentParser(description="Summarize E2 logs -> summary.csv")
    p.add_argument("--project", default="express-app",
                   help="project name under frontier_poc/<project>/logs (default: express-app)")
    p.add_argument("--root", default=str(Path.home() / "experiment" / "e_ex"),
                   help="root directory (default: ~/experiment/e_ex)")
    p.add_argument("--out", default=None,
                   help="optional output csv path (default: <root>/frontier_poc/<project>/logs/summary.csv)")
    # New: keep failed / incomplete samples if you explicitly want them in summary.csv
    p.add_argument("--include-failed", action="store_true",
                   help="include failed samples (EXIT_CODE!=0) and samples missing Phase-2 markers (default: drop)")
    return p.parse_args()


# ----------------------------- parsing helpers -----------------------------
def parse_kv_lines(p: Path):
    d = {}
    if not p.exists():
        return d
    for line in p.read_text(errors="ignore").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def grep_num(p: Path, key: str):
    if not p.exists():
        return ""
    pat = re.compile(rf"\b{re.escape(key)}\s+(\d+)")
    for line in p.read_text(errors="ignore").splitlines():
        m = pat.search(line)
        if m:
            return m.group(1)
    return ""


def grep_float(p: Path, key: str):
    if not p.exists():
        return ""
    pat = re.compile(rf"\b{re.escape(key)}\s+([0-9]+(?:\.[0-9]+)?)")
    for line in p.read_text(errors="ignore").splitlines():
        m = pat.search(line)
        if m:
            return m.group(1)
    return ""


def grep_str(p: Path, key: str):
    if not p.exists():
        return ""
    pat = re.compile(rf"\b{re.escape(key)}\s+(.+)")
    for line in p.read_text(errors="ignore").splitlines():
        m = pat.search(line)
        if m:
            return m.group(1).strip()
    return ""


def read_json(p: Path):
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(errors="ignore"))
    except Exception:
        return {}


def safe_delta(before: str, after: str):
    if not before or not after:
        return ""
    try:
        b = int(before)
        a = int(after)
        d = a - b
        if d < 0:
            d = 0
        return str(d)
    except ValueError:
        return ""


def ts_from_iso(iso: str):
    digits = re.sub(r"\D", "", iso or "")
    if len(digits) >= 14:
        return digits[:14]
    if len(digits) >= 8:
        return digits[:8]
    return ""


def ts_from_dirname_ns(dirname: str):
    m = re.match(r"^(\d+)_w\d+_[a-z0-9_]+$", dirname)
    if not m:
        return ""
    ts_ns = m.group(1)
    try:
        s = int(ts_ns) // 1_000_000_000
        return datetime.fromtimestamp(s).strftime("%Y%m%d%H%M%S")
    except Exception:
        return ""


def parse_timev(p: Path):
    out = {}
    if not p.exists():
        return out
    txt = p.read_text(errors="ignore")

    m = re.search(r"Elapsed \(wall clock\) time.*?:\s*([0-9:.\s]+)", txt)
    if m:
        s = m.group(1).strip()
        parts = s.split(":")
        try:
            if len(parts) == 3:
                h, mn, sc = parts
                val = int(h) * 3600 + int(mn) * 60 + float(sc)
            elif len(parts) == 2:
                mn, sc = parts
                val = int(mn) * 60 + float(sc)
            else:
                val = float(parts[0])
            out["elapsed_s_timev"] = f"{val:.3f}"
        except Exception:
            pass

    for k, pat in [
        ("fs_inputs", r"File system inputs:\s*(\d+)"),
        ("fs_outputs", r"File system outputs:\s*(\d+)"),
        ("timev_user_s", r"User time \(seconds\):\s*([0-9.]+)"),
        ("timev_sys_s", r"System time \(seconds\):\s*([0-9.]+)"),
    ]:
        m2 = re.search(pat, txt)
        if m2:
            out[k] = m2.group(1)
    return out


def phase2_elapsed_s_from_wrap(wrap_txt: str):
    m1 = re.search(r"\bPHASE2_START_NS\s+(\d+)", wrap_txt)
    m2 = re.search(r"\bPHASE2_END_NS\s+(\d+)", wrap_txt)
    if not (m1 and m2):
        return ""
    try:
        s = int(m1.group(1))
        e = int(m2.group(1))
        if e >= s:
            return f"{(e - s) / 1e9:.3f}"
    except Exception:
        return ""
    return ""


def b2_extract_ok_from_wrap(method: str, wrap_txt: str):
    if not method.startswith("b2_"):
        return ""
    bad_pats = [
        r"tar: .*Cannot open: Not a directory",
        r"tar: .*Cannot open",
        r"tar: Unexpected EOF",
        r"tar: Error is not recoverable",
        r"tar: Exiting with failure status",
    ]
    for pat in bad_pats:
        if re.search(pat, wrap_txt):
            return "0"
    if "frontier" in method:
        return "1"
    return ""


def normalize_01(v, default=""):
    if v is None:
        return default
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return "1" if v != 0 else "0"
    s = str(v).strip()
    if s == "":
        return default
    if s.lower() in ("1", "true", "yes", "y", "on"):
        return "1"
    if s.lower() in ("0", "false", "no", "n", "off"):
        return "0"
    return s


def pick_kv_multi(primary: dict, secondary: dict, keys, default: str = ""):
    for k in keys:
        v = primary.get(k, "")
        if v != "":
            return v
    for k in keys:
        v = secondary.get(k, "")
        if v != "":
            return v
    return default


# ----------------------------- CSV schema -----------------------------
# Keep your existing lower_snake columns for compatibility, AND add the
# required "canonical" columns (uppercase) as aliases so downstream matrix code
# can rely on stable names.
HEADER = [
    # existing core
    "ts",
    "method",
    "boottime_ms",
    "elapsed_s",
    "fs_inputs",
    "fs_outputs",
    "psi_io_some_pct",
    "psi_io_full_pct",
    "psi_cpu_some_pct",
    "psi_mem_some_pct",
    "cg_io_rbytes_delta",
    "pgmaj_delta",
    "net_bytes_delta",
    "frontier_bytes",
    "bulk_bytes",
    "topk_bytes",
    "topk_enabled",
    "topk_limit_kb",
    "run_tag",
    "worker_id",
    "e2_conc",
    "e2_mem_profile",
    "cg_memory_max",
    "cg_memory_max_bytes",
    "cg_memory_current_bytes",
    "cg_swap_current_bytes",
    "cg_path_before",
    "cg_path_after",
    "a2_seed_path",
    "a2_seed_bytes",
    "run_id",
    "seed",
    "round",
    "timev_user_s",
    "timev_sys_s",
    "b2_extract_ok",
    "exit_code",

    # existing "new" fields you already added
    "e2e_wall_ms",
    "e2e_residual_ms",
    "phase2_over_e2e_ratio",
    "a2_mount_ms",
    "a2_mount_ro_ok",
    "a2_seed_path_extras",
    "tar_extract_ms",
    "tar_extract_ok",
    "tar_extract_mode",
    "tar_extract_tar",
    "pkg_tool",

    # svsafe (existing)
    "svsafe_reused",
    "svsafe_lock_wait_ms",
    "svsafe_build_ms",
    "svsafe_install_ms",
    "svsafe_publish_ms",
    "svsafe_mount_ms",
    "svsafe_provision_ms",
    "svsafe_force_rebuild",
    "svsafe_force_rebuild_ttl_sec",
    "svsafe_key",
    "svsafe_base",
    "svsafe_node_modules",
    "svsafe_when",
    "svsafe_mount_line",

    # ---------------- required canonical columns (aliases) ----------------
    # Phase-2 window core
    "PHASE2_BOOTTIME_MS",
    "PGMAJ_DELTA",
    "CG_IO_RBYTES_DELTA",
    "NET_BYTES_DELTA",

    # B2
    "TAR_EXTRACT_MS",
    "TAR_EXTRACT_OK",
    "TAR_EXTRACT_MODE",

    # A2
    "A2_MOUNT_MS",
    "A2_MOUNT_RO_OK",

    # SV-safe
    "SVSAFE_REUSED",
    "SVSAFE_LOCK_WAIT_MS",
    "SVSAFE_BUILD_MS",
    "SVSAFE_INSTALL_MS",
    "SVSAFE_PUBLISH_MS",
    "SVSAFE_MOUNT_MS",
    "SVSAFE_PROVISION_MS",

    # Fair comparison (setup vs total)
    "E2_SETUP_MS",
    "E2_TOTAL_MS",

    # Ensure EXIT_CODE exists in canonical form too
    "EXIT_CODE",
]


def main():
    args = parse_args()

    root = Path(args.root)
    proj = args.project
    base = root / "frontier_poc" / proj / "logs"
    csv_out = Path(args.out) if args.out else (base / "summary.csv")

    rows = []

    total_dirs = 0
    skipped_failed = 0
    skipped_missing_phase2 = 0

    if base.exists():
        dirs = [
            x for x in base.iterdir()
            if x.is_dir() and re.match(r"^\d+_w\d+_[a-z0-9_]+$", x.name)
        ]

        for d in sorted(dirs):
            total_dirs += 1
            m = re.match(r"^\d+_w(\d+)_([a-z0-9_]+)$", d.name)
            if not m:
                continue
            worker_id, method = m.group(1), m.group(2)

            wrap = d / "wrap_extract.log"
            timev_extract = d / "timev_extract.log"
            timev_run = d / "timev_run.log"
            meta_json = d / "meta.json"
            meta_extras = d / "meta.extras"
            a2_status = d / ".a2_status"
            svsafe_status = d / ".svsafe_status"

            wrap_txt = wrap.read_text(errors="ignore") if wrap.exists() else ""
            meta = read_json(meta_json)
            kv = parse_kv_lines(meta_extras)
            a2s = parse_kv_lines(a2_status)
            svs = parse_kv_lines(svsafe_status)

            ts = ts_from_iso(meta.get("timestamp_iso", "")) or ts_from_dirname_ns(d.name)

            run_tag = meta.get("run_tag", "") or kv.get("RUN_TAG", "")
            e2_conc = str(meta.get("e2_conc", "") or kv.get("E2_CONC", ""))
            e2_mem = meta.get("e2_mem_profile", "") or kv.get("E2_MEM_PROFILE", "")

            frontier_bytes = str(meta.get("frontier_bytes", "") or "")
            bulk_bytes = str(meta.get("bulk_bytes", "") or "")
            topk_bytes = str(meta.get("topk_bytes", "") or "")
            topk_enabled = normalize_01(meta.get("topk_enabled", ""), default="0")
            topk_limit_kb = str(meta.get("topk_limit_kb", "") or "")

            a2_seed_path = a2s.get("A2_SEED", "")
            a2_seed_bytes = a2s.get("A2_SEED_BYTES", "")

            run_id = d.name
            seed = kv.get("SEED", "")
            rnd = kv.get("ROUND", "")

            # EXIT_CODE: always present; default 0 if missing
            exit_code = kv.get("EXIT_CODE", "")
            if exit_code == "":
                exit_code = "0"

            # Phase-2 boottime
            boottime_ms = ""
            m_bt = re.search(r"\bPHASE2_BOOTTIME_MS\s+(\d+)", wrap_txt)
            if m_bt:
                boottime_ms = m_bt.group(1)

            # Default policy: drop failures and drop missing Phase-2 markers
            if not args.include_failed:
                if exit_code != "0":
                    skipped_failed += 1
                    continue
                if boottime_ms == "":
                    skipped_missing_phase2 += 1
                    continue

            elapsed_s = phase2_elapsed_s_from_wrap(wrap_txt)

            tv = parse_timev(timev_extract)
            if not tv:
                tv = parse_timev(timev_run)
            if not elapsed_s:
                elapsed_s = tv.get("elapsed_s_timev", "")

            psi_io_some_pct = grep_float(wrap, "PSI_IO_SOME_PCT")
            psi_io_full_pct = grep_float(wrap, "PSI_IO_FULL_PCT")
            psi_cpu_some_pct = grep_float(wrap, "PSI_CPU_SOME_PCT")
            psi_mem_some_pct = grep_float(wrap, "PSI_MEM_SOME_PCT")

            pgmaj_delta = safe_delta(grep_num(wrap, "CG_PGMAJ_BEFORE"), grep_num(wrap, "CG_PGMAJ_AFTER"))
            cg_io_rbytes_delta = safe_delta(grep_num(wrap, "CG_IO_RBYTES_BEFORE"), grep_num(wrap, "CG_IO_RBYTES_AFTER"))
            net_bytes_delta = safe_delta(grep_num(wrap, "NET_BYTES_BEFORE"), grep_num(wrap, "NET_BYTES_AFTER"))

            cg_memory_max = grep_str(wrap, "CG_MEMORY_MAX")
            cg_memory_max_bytes = grep_num(wrap, "CG_MEMORY_MAX_BYTES")
            cg_memory_current_bytes = grep_num(wrap, "CG_MEMORY_CURRENT_BYTES")
            cg_swap_current_bytes = grep_num(wrap, "CG_SWAP_CURRENT_BYTES")
            cg_path_before = grep_str(wrap, "CG_PATH_BEFORE")
            cg_path_after = grep_str(wrap, "CG_PATH_AFTER")

            # Fairness: prefer new canonical names if you later add them to meta.extras
            # Otherwise, map from existing E2E_* fields.
            e2_total_ms = pick_kv_multi(kv, {}, ["E2_TOTAL_MS", "E2E_WALL_MS"], "")
            e2_setup_ms = pick_kv_multi(kv, {}, ["E2_SETUP_MS", "E2E_RESIDUAL_MS"], "")

            # keep your previous names too
            e2e_wall_ms = pick_kv_multi(kv, {}, ["E2E_WALL_MS", "E2_TOTAL_MS"], "")
            e2e_residual_ms = pick_kv_multi(kv, {}, ["E2E_RESIDUAL_MS", "E2_SETUP_MS"], "")
            phase2_over_e2e_ratio = kv.get("PHASE2_OVER_E2E_RATIO", "")

            # A2 mount (prefer kv; fallback to grep from wrap_extract.log)
            a2_mount_ms = kv.get("A2_MOUNT_MS", "") or grep_num(wrap, "A2_MOUNT_MS")
            a2_mount_ro_ok = kv.get("A2_MOUNT_RO_OK", "") or grep_num(wrap, "A2_MOUNT_RO_OK")
            a2_seed_path_extras = kv.get("A2_SEED_PATH", "")

            # B2 tar extract (prefer kv; fallback to grep)
            tar_extract_ms = kv.get("TAR_EXTRACT_MS", "") or grep_num(wrap, "TAR_EXTRACT_MS")
            tar_extract_ok = kv.get("TAR_EXTRACT_OK", "") or grep_num(wrap, "TAR_EXTRACT_OK")
            tar_extract_mode = kv.get("TAR_EXTRACT_MODE", "") or grep_str(wrap, "TAR_EXTRACT_MODE")
            tar_extract_tar = kv.get("TAR_EXTRACT_TAR", "") or grep_str(wrap, "TAR_EXTRACT_TAR")

            # b2_extract_ok: use TAR_EXTRACT_OK when available; else heuristic
            if method.startswith("b2_") and tar_extract_ok != "":
                b2_extract_ok = tar_extract_ok
            else:
                b2_extract_ok = b2_extract_ok_from_wrap(method, wrap_txt)

            pkg_tool = kv.get("PKG_TOOL", "") or str(meta.get("pkg_tool", "") or "")

            # SVSAFE: prefer .svsafe_status (svs), else meta.extras (kv)
            svsafe_reused = pick_kv_multi(svs, kv, ["SVSAFE_REUSED", "svsafe_reused"], "")
            svsafe_lock_wait_ms = pick_kv_multi(svs, kv, ["SVSAFE_LOCK_WAIT_MS", "svsafe_lock_wait_ms"], "")
            svsafe_build_ms = pick_kv_multi(svs, kv, ["SVSAFE_BUILD_MS", "svsafe_build_ms"], "")
            svsafe_install_ms = pick_kv_multi(svs, kv, ["SVSAFE_INSTALL_MS", "svsafe_install_ms"], "")
            svsafe_publish_ms = pick_kv_multi(svs, kv, ["SVSAFE_PUBLISH_MS", "svsafe_publish_ms"], "")
            svsafe_mount_ms = pick_kv_multi(svs, kv, ["SVSAFE_MOUNT_MS", "svsafe_mount_ms"], "")
            svsafe_provision_ms = pick_kv_multi(svs, kv, ["SVSAFE_PROVISION_MS", "svsafe_provision_ms"], "")
            svsafe_force_rebuild = pick_kv_multi(svs, kv, ["SVSAFE_FORCE_REBUILD", "svsafe_force_rebuild"], "")
            svsafe_force_rebuild_ttl_sec = pick_kv_multi(svs, kv, ["SVSAFE_FORCE_REBUILD_TTL_SEC", "svsafe_force_rebuild_ttl_sec"], "")
            svsafe_key = pick_kv_multi(svs, kv, ["SVSAFE_KEY", "svsafe_key"], "")
            svsafe_base = pick_kv_multi(svs, kv, ["SVSAFE_BASE", "svsafe_base"], "")
            svsafe_node_modules = pick_kv_multi(svs, kv, ["SVSAFE_NODE_MODULES", "svsafe_node_modules"], "")
            svsafe_when = pick_kv_multi(svs, kv, ["SVSAFE_WHEN", "WHEN", "when"], "")
            svsafe_mount_line = pick_kv_multi(svs, kv, ["SVSAFE_MOUNT", "MOUNT", "mount"], "")


            # Build row (lower_snake + canonical aliases)
            row = {
                "ts": ts,
                "method": method,
                "boottime_ms": boottime_ms,
                "elapsed_s": elapsed_s,
                "fs_inputs": tv.get("fs_inputs", ""),
                "fs_outputs": tv.get("fs_outputs", ""),
                "psi_io_some_pct": psi_io_some_pct,
                "psi_io_full_pct": psi_io_full_pct,
                "psi_cpu_some_pct": psi_cpu_some_pct,
                "psi_mem_some_pct": psi_mem_some_pct,
                "cg_io_rbytes_delta": cg_io_rbytes_delta,
                "pgmaj_delta": pgmaj_delta,
                "net_bytes_delta": net_bytes_delta,
                "frontier_bytes": frontier_bytes,
                "bulk_bytes": bulk_bytes,
                "topk_bytes": topk_bytes,
                "topk_enabled": topk_enabled,
                "topk_limit_kb": topk_limit_kb,
                "run_tag": run_tag,
                "worker_id": worker_id,
                "e2_conc": e2_conc,
                "e2_mem_profile": e2_mem,
                "cg_memory_max": cg_memory_max,
                "cg_memory_max_bytes": cg_memory_max_bytes,
                "cg_memory_current_bytes": cg_memory_current_bytes,
                "cg_swap_current_bytes": cg_swap_current_bytes,
                "cg_path_before": cg_path_before,
                "cg_path_after": cg_path_after,
                "a2_seed_path": a2_seed_path,
                "a2_seed_bytes": a2_seed_bytes,
                "run_id": run_id,
                "seed": seed,
                "round": rnd,
                "timev_user_s": tv.get("timev_user_s", ""),
                "timev_sys_s": tv.get("timev_sys_s", ""),
                "b2_extract_ok": b2_extract_ok,
                "exit_code": exit_code,

                "e2e_wall_ms": e2e_wall_ms,
                "e2e_residual_ms": e2e_residual_ms,
                "phase2_over_e2e_ratio": phase2_over_e2e_ratio,
                "a2_mount_ms": a2_mount_ms,
                "a2_mount_ro_ok": a2_mount_ro_ok,
                "a2_seed_path_extras": a2_seed_path_extras,
                "tar_extract_ms": tar_extract_ms,
                "tar_extract_ok": tar_extract_ok,
                "tar_extract_mode": tar_extract_mode,
                "tar_extract_tar": tar_extract_tar,
                "pkg_tool": pkg_tool,

                "svsafe_reused": svsafe_reused,
                "svsafe_lock_wait_ms": svsafe_lock_wait_ms,
                "svsafe_build_ms": svsafe_build_ms,
                "svsafe_install_ms": svsafe_install_ms,
                "svsafe_publish_ms": svsafe_publish_ms,
                "svsafe_mount_ms": svsafe_mount_ms,
                "svsafe_provision_ms": svsafe_provision_ms,
                "svsafe_force_rebuild": svsafe_force_rebuild,
                "svsafe_force_rebuild_ttl_sec": svsafe_force_rebuild_ttl_sec,
                "svsafe_key": svsafe_key,
                "svsafe_base": svsafe_base,
                "svsafe_node_modules": svsafe_node_modules,
                "svsafe_when": svsafe_when,
                "svsafe_mount_line": svsafe_mount_line,

                # canonical aliases
                "PHASE2_BOOTTIME_MS": boottime_ms,
                "PGMAJ_DELTA": pgmaj_delta,
                "CG_IO_RBYTES_DELTA": cg_io_rbytes_delta,
                "NET_BYTES_DELTA": net_bytes_delta,

                "TAR_EXTRACT_MS": tar_extract_ms,
                "TAR_EXTRACT_OK": tar_extract_ok,
                "TAR_EXTRACT_MODE": tar_extract_mode,

                "A2_MOUNT_MS": a2_mount_ms,
                "A2_MOUNT_RO_OK": a2_mount_ro_ok,

                "SVSAFE_REUSED": svsafe_reused,
                "SVSAFE_LOCK_WAIT_MS": svsafe_lock_wait_ms,
                "SVSAFE_BUILD_MS": svsafe_build_ms,
                "SVSAFE_INSTALL_MS": svsafe_install_ms,
                "SVSAFE_PUBLISH_MS": svsafe_publish_ms,
                "SVSAFE_MOUNT_MS": svsafe_mount_ms,
                "SVSAFE_PROVISION_MS": svsafe_provision_ms,

                "E2_SETUP_MS": e2_setup_ms,
                "E2_TOTAL_MS": e2_total_ms,

                "EXIT_CODE": exit_code,
            }

            rows.append(row)

    csv_out.parent.mkdir(parents=True, exist_ok=True)
    with open(csv_out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=HEADER)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in HEADER})

    # Clear operator-facing summary (useful in sweeps)
    msg = f"[ok] wrote {csv_out} rows={len(rows)} scanned_dirs={total_dirs}"
    if not args.include_failed:
        msg += f" skipped_failed={skipped_failed} skipped_missing_phase2={skipped_missing_phase2}"
    print(msg)


if __name__ == "__main__":
    main()
