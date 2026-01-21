#!/usr/bin/env bash
set -euo pipefail

# e6_b2_build_cost.sh
# 功能：量測「為某個專案建立 B2 frontier 套件」的建置時間與資源使用。
#
# 使用方式：
#   PROJ=express-app NO_NET_DOWNLOAD=0 bin/e6_b2_build_cost.sh
#   PROJ=ghost        NO_NET_DOWNLOAD=0 bin/e6_b2_build_cost.sh

root="${E2_ROOT:-$HOME/experiment/e_ex}"
proj="${PROJ:-express-app}"

log_root="$root/frontier_poc/$proj/e6_cost"
mkdir -p "$log_root"

ts="$(date +%Y%m%d%H%M%S)"
out_prefix="$log_root/${ts}_b2_build"

time_log="${out_prefix}.time.txt"
meta_log="${out_prefix}.meta.txt"

echo "[e6][b2] project=$proj"
echo "[e6][b2] output prefix=$out_prefix"

# frontier 套件目錄
pkgd="${PKG_DIR:-$root/frontier_poc/$proj/pkgs}"
mkdir -p "$pkgd"
rm -f "$pkgd/nm.frontier.tar" "$pkgd/nm.bulk.tar" "$pkgd/nm.bulk.topk.tar" 2>/dev/null || true

{
  echo "PROJECT=$proj"
  echo "TIMESTAMP=$ts"
  echo "HOSTNAME=$(hostname)"
  echo "KERNEL=$(uname -r)"
} > "$meta_log"

# 用 /usr/bin/time -v 包 e2_h1_frontier_driver.sh
# ROUNDS_ONLY_FRONTIER=1 → 只建 frontier 然後 exit
# FRONTIER_CACHE=0       → 強制重建，不吃 cache
start_ns="$("$root/bin/boottime_now" 2>/dev/null || echo 0)"

ROUNDS_ONLY_FRONTIER=1 \
FRONTIER_CACHE=0 \
E2_ROOT="$root" \
PROJ="$proj" \
LC_ALL=C /usr/bin/time -v -o "$time_log" \
  "$root/bin/e2_h1_frontier_driver.sh" "$proj"

end_ns="$("$root/bin/boottime_now" 2>/dev/null || echo 0)"

echo "[e6][b2] frontier build finished. time log: $time_log"

wall_s=""
if [[ "$start_ns" != "0" && "$end_ns" != "0" ]]; then
  wall_s="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{ printf "%.6f", (e-s)/1e9 }')"
fi


# 抓 time -v 的欄位
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


# 直接從 time -v 抓 Elapsed 那行，允許前面有空白
user_s="$(get_time_field 'User time \(seconds\)')"
sys_s="$(get_time_field 'System time \(seconds\)')"
maxrss_kb="$(get_time_field 'Maximum resident set size \(kbytes\)')"


# 讀取 frontier tar 的大小與檔案數
frontier_tar="$pkgd/nm.frontier.tar"
frontier_bytes=""
frontier_files=""
if [[ -f "$frontier_tar" ]]; then
  frontier_bytes="$(tar -tvf "$frontier_tar" | awk '{s+=$3} END{print s+0}')"
  frontier_files="$(tar -tvf "$frontier_tar" | wc -l | tr -d ' ')"
fi

csv="$log_root/e6_b2_build_cost.csv"
if [[ ! -f "$csv" ]]; then
  echo "ts,project,method,kind,wall_s,user_s,sys_s,maxrss_kb,frontier_bytes,frontier_files" > "$csv"
fi
echo "${ts},${proj},b2,build,${wall_s},${user_s},${sys_s},${maxrss_kb},${frontier_bytes},${frontier_files}" >> "$csv"

echo "[e6][b2] append to CSV: $csv"
