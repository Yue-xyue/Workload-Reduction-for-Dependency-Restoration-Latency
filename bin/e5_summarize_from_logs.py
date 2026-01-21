#!/usr/bin/env python3
import argparse, csv, json, re
from pathlib import Path

# ------- CLI 參數 -------
parser = argparse.ArgumentParser(description="Summarize E5 logs -> summary.csv")
parser.add_argument(
    "--project",
    default="express-app",
    help="project name under frontier_poc/<project>/logs (default: express-app)",
)
parser.add_argument(
    "--root",
    default=str(Path.home() / "experiment" / "e_ex"),
    help="root directory (default: ~/experiment/e_ex)",
)
parser.add_argument(
    "--out",
    default=None,
    help="optional output csv path (default: <root>/frontier_poc/<project>/logs/summary.csv)",
)
args = parser.parse_args()

# ------- 目錄 -------
root = Path(args.root)
proj = args.project
BASE = root / "frontier_poc" / proj / "logs"
CSV_OUT = Path(args.out) if args.out else (BASE / "summary.csv")

# 欄位順序（對齊既有 header，新增欄位一律加在最後）
HEADER = [
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
    "b2_extract_ok",  # B2 解壓是否成功（1=正常，0=tar 錯誤，其它 method 留空）
    "role",           # E5 新增：ROLE=target / neighbor（從 meta.extras 的 ROLE 取得）
]


# ------- 小工具 -------

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
    """抓 'KEY <int>'，回傳字串或空字串"""
    if not p.exists():
        return ""
    pat = re.compile(rf"\b{re.escape(key)}\s+(\d+)")
    for line in p.read_text(errors="ignore").splitlines():
        m = pat.search(line)
        if m:
            return m.group(1)
    return ""


def grep_float(p: Path, key: str):
    """抓 'KEY <float/int>'，允許小數"""
    if not p.exists():
        return ""
    pat = re.compile(rf"\b{re.escape(key)}\s+([0-9]+(?:\.[0-9]+)?)")
    for line in p.read_text(errors="ignore").splitlines():
        m = pat.search(line)
        if m:
            return m.group(1)
    return ""


def grep_str(p: Path, key: str):
    """抓 'KEY <任意字串>'，整行去掉 KEY 返回"""
    if not p.exists():
        return ""
    pat = re.compile(rf"\b{re.escape(key)}\s+(.+)")
    for line in p.read_text(errors="ignore").splitlines():
        m = pat.search(line)
        if m:
            return m.group(1).strip()
    return ""


def parse_timev(p: Path):
    out = {}
    if not p.exists():
        return out
    txt = p.read_text(errors="ignore")

    # Elapsed (wall clock) time
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
            out["elapsed_s"] = f"{val:.3f}"
        except:  # noqa: E722
            pass

    for k, pat in [
        ("fs_inputs", r"File system inputs:\s*(\d+)"),
        ("fs_outputs", r"File system outputs:\s*(\d+)"),
        ("timev_user_s", r"User time \(seconds\):\s*([0-9.]+)"),
        ("timev_sys_s", r"System time \(seconds\):\s*([0-9.]+)"),
    ]:
        m = re.search(pat, txt)
        if m:
            out[k] = m.group(1)
    return out


def ts_from_iso(iso: str):
    # 轉成只有數字的 YYYYMMDDhhmmss
    digits = re.sub(r"\D", "", iso or "")
    if len(digits) >= 8:
        return digits[:14] if len(digits) >= 14 else digits[:8]
    return ""


def read_json(p: Path):
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(errors="ignore"))
    except:  # noqa: E722
        return {}


def safe_delta(before: str, after: str):
    """把 BEFORE / AFTER 兩個字串轉 int，相減 >=0，失敗回空字串"""
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


# ------- 主流程 -------

rows = []

if BASE.exists():
    # 掃描 *_wN_method 目錄
    dirs = [
        x
        for x in BASE.iterdir()
        if x.is_dir() and re.match(r"^\d+_w\d+_[a-z0-9_]+$", x.name)
    ]
    for d in sorted(dirs):
        m = re.match(r"^\d+_w(\d+)_([a-z0-9_]+)$", d.name)
        if not m:
            continue
        worker_id, method = m.group(1), m.group(2)

        wrap = d / "wrap_extract.log"
        timev = d / "timev_run.log"
        meta_json = d / "meta.json"
        meta_extras = d / "meta.extras"
        a2_status = d / ".a2_status"  # 可能不存在

        # 先讀整個 wrap_extract.log，供後面 b2_extract_ok 判斷使用
        wrap_txt = wrap.read_text(errors="ignore") if wrap.exists() else ""

        # --- b2_extract_ok：只對 b2_frontier_only 標記，其它 method 留空 ---
        # b2_frontier_only:
        #   - 若看到 tar: ... Cannot open: Not a directory → 視為失敗 (0)
        #   - 否則視為成功 (1)
        # 其它 method → b2_extract_ok = ""
        if method == "b2_frontier_only":
            if "tar:" in wrap_txt and "Cannot open: Not a directory" in wrap_txt:
                b2_extract_ok = "0"
            else:
                b2_extract_ok = "1"
        else:
            b2_extract_ok = ""

        # --- 基本時間與 meta ---
        boottime_ms = grep_num(wrap, "PHASE2_BOOTTIME_MS")
        tv = parse_timev(timev)
        meta = read_json(meta_json)
        kv = parse_kv_lines(meta_extras)
        a2s = parse_kv_lines(a2_status)

        ts = ts_from_iso(meta.get("timestamp_iso", ""))

        run_tag = meta.get("run_tag", "") or kv.get("RUN_TAG", "")
        e2_conc = str(meta.get("e2_conc", "") or kv.get("E2_CONC", ""))
        e2_mem = meta.get("e2_mem_profile", "") or kv.get("E2_MEM_PROFILE", "")

        frontier_bytes = str(meta.get("frontier_bytes", "") or "")
        bulk_bytes = str(meta.get("bulk_bytes", "") or "")
        topk_bytes = str(meta.get("topk_bytes", "") or "")
        topk_enabled = str(meta.get("topk_enabled", "") or "0")
        topk_limit_kb = str(meta.get("topk_limit_kb", "") or "")

        a2_seed_path = a2s.get("A2_SEED", "")
        a2_seed_bytes = a2s.get("A2_SEED_BYTES", "") if "A2_SEED_BYTES" in a2s else ""

        run_id = d.name
        seed = kv.get("SEED", "")
        rnd = kv.get("ROUND", "")
        role = kv.get("ROLE", "")  # E5: target / neighbor（若沒設則為空字串）

        # --- PSI from e2wrap.js ---
        psi_io_some_pct = grep_float(wrap, "PSI_IO_SOME_PCT")
        psi_io_full_pct = grep_float(wrap, "PSI_IO_FULL_PCT")
        psi_cpu_some_pct = grep_float(wrap, "PSI_CPU_SOME_PCT")
        psi_mem_some_pct = grep_float(wrap, "PSI_MEM_SOME_PCT")
        # PSI_MEM_FULL_PCT 有輸出，但目前 header 沒欄位，就先忽略

        # --- cgroup / I/O / net：用 BEFORE/AFTER 算 delta ---
        pg_before = grep_num(wrap, "CG_PGMAJ_BEFORE")
        pg_after = grep_num(wrap, "CG_PGMAJ_AFTER")
        pgmaj_delta = safe_delta(pg_before, pg_after)

        io_before = grep_num(wrap, "CG_IO_RBYTES_BEFORE")
        io_after = grep_num(wrap, "CG_IO_RBYTES_AFTER")
        cg_io_rbytes_delta = safe_delta(io_before, io_after)

        net_before = grep_num(wrap, "NET_BYTES_BEFORE")
        net_after = grep_num(wrap, "NET_BYTES_AFTER")
        net_bytes_delta = safe_delta(net_before, net_after)

        # --- cgroup memory/path ---
        cg_memory_max = grep_str(wrap, "CG_MEMORY_MAX")  # 可能是 "max" 或數字
        cg_memory_max_bytes = grep_num(wrap, "CG_MEMORY_MAX_BYTES")
        cg_memory_current_bytes = grep_num(wrap, "CG_MEMORY_CURRENT_BYTES")
        cg_swap_current_bytes = grep_num(wrap, "CG_SWAP_CURRENT_BYTES")

        cg_path_before = grep_str(wrap, "CG_PATH_BEFORE")
        cg_path_after = grep_str(wrap, "CG_PATH_AFTER")

        row = {
            "ts": ts,
            "method": method,
            "boottime_ms": boottime_ms,
            "elapsed_s": tv.get("elapsed_s", ""),
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
            "role": role,
        }
        rows.append(row)

# 輸出 CSV（覆蓋）
CSV_OUT.parent.mkdir(parents=True, exist_ok=True)
with open(CSV_OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=HEADER)
    w.writeheader()
    for r in rows:
        w.writerow({k: r.get(k, "") for k in HEADER})

print(f"[hotfix] wrote {CSV_OUT} rows={len(rows)}")
