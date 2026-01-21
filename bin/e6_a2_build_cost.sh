#!/usr/bin/env bash
set -euo pipefail

# e6_a2_build_cost.sh
# 功能：量測「為某個專案建立 A2 shared-RO seed」的建置時間與資源使用。
#
# 使用方式：
#   PROJ=express-app NO_NET_DOWNLOAD=0 bin/e6_a2_build_cost.sh
#   PROJ=ghost        NO_NET_DOWNLOAD=0 bin/e6_a2_build_cost.sh

root="${E2_ROOT:-$HOME/experiment/e_ex}"
proj="${PROJ:-express-app}"
projdir_base="$root/projects/$proj"
projdir="${PROJECT_DIR:-$projdir_base}"

log_root="$root/frontier_poc/$proj/e6_cost"
mkdir -p "$log_root"

ts="$(date +%Y%m%d%H%M%S)"
out_prefix="$log_root/${ts}_a2_build"

time_log="${out_prefix}.time.txt"
meta_log="${out_prefix}.meta.txt"

echo "[e6][a2] project=$proj"
echo "[e6][a2] projdir=$projdir"

cd "$projdir"

# A2 seed 路徑與 status 檔
a2_status_file="$projdir/.a2_status"
a2_seed_dir="$root/a2_ro/$proj"

# 清掉舊 seed，確保這次是「完整建置」
rm -f "$a2_status_file" 2>/dev/null || true
rm -rf "$a2_seed_dir"   2>/dev/null || true

# npm 旗標（與 driver 保持一致）
npm_cache="${NPM_CACHE_DIR:-$root/npm-cache}"
mkdir -p "$npm_cache"
npm_flags="--cache=$npm_cache --prefer-offline --no-audit --fund=false --progress=false"
if [[ "${NO_NET_DOWNLOAD:-0}" = "1" ]]; then
  npm_flags="$npm_flags --offline"
fi

{
  echo "PROJECT=$proj"
  echo "TIMESTAMP=$ts"
  echo "HOSTNAME=$(hostname)"
  echo "KERNEL=$(uname -r)"
} > "$meta_log"

# 用 /usr/bin/time -v 包 e2_a2_setup.sh，強制英文輸出 (LC_ALL=C)
# 先記錄開始時間（boottime ns）
start_ns="$("$root/bin/boottime_now" 2>/dev/null || echo 0)"

E2_ROOT="$root" \
LC_ALL=C /usr/bin/time -v -o "$time_log" \
  "$root/bin/e2_a2_setup.sh" "$proj" "$npm_flags"

# 結束時間
end_ns="$("$root/bin/boottime_now" 2>/dev/null || echo 0)"

echo "[e6][a2] a2 seed build finished. time log: $time_log"

# 用 boottime 差值算 wall_s（秒）
wall_s=""
if [[ "$start_ns" != "0" && "$end_ns" != "0" ]]; then
  wall_s="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{ printf "%.6f", (e-s)/1e9 }')"
fi


# 從 /usr/bin/time -v 輸出中抓欄位（要對應英文 key）
get_time_field() {
  local key="$1"
  local line=""
  # 注意這裡多了 [[:space:]]*
  line="$(grep -E "^[[:space:]]*${key}" "$time_log" || true)"
  if [[ -z "$line" ]]; then
    echo ""
    return 0
  fi
  echo "$line" | sed -E 's/^[^:]+:[[:space:]]*//'
}


# 解析 wall clock / user / sys / maxrss
user_s="$(get_time_field 'User time \(seconds\)')"
sys_s="$(get_time_field 'System time \(seconds\)')"
maxrss_kb="$(get_time_field 'Maximum resident set size \(kbytes\)')"

# 估 seed 大小（整個 A2 seed 目錄，單位 KB）
seed_bytes_kb=""
if [[ -d "$a2_seed_dir" ]]; then
  seed_bytes_kb="$(du -sk "$a2_seed_dir" | awk '{print $1}')"
fi

csv="$log_root/e6_a2_build_cost.csv"
if [[ ! -f "$csv" ]]; then
  echo "ts,project,method,kind,wall_s,user_s,sys_s,maxrss_kb,seed_kb" > "$csv"
fi
echo "${ts},${proj},a2,build,${wall_s},${user_s},${sys_s},${maxrss_kb},${seed_bytes_kb}" >> "$csv"

echo "[e6][a2] append to CSV: $csv"
