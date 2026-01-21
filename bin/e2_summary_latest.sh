#!/usr/bin/env bash
# e2_summary_latest.sh <project>  # 產出 frontier_poc/<proj>/logs/summary_latest.csv
set -euo pipefail
proj="${1:?proj}"
root="${E2_ROOT:-$HOME/experiment/e_ex}"
logd="$root/frontier_poc/$proj/logs"
src="$logd/summary.csv"
out="$logd/summary_latest.csv"
[[ -r "$src" ]] || { echo "[fatal] $src not found"; exit 2; }

DAY="$(date +%Y%m%d)"
awk -F, -v D="$DAY" 'NR==1 || index($1,D)==1 {print $0}' "$src" \
| awk -F, 'BEGIN{
  # 重新挑欄：ts,method,boottime_ms,cg_io_rbytes_delta,e2_conc,e2_mem_profile,run_id,seed,round
  OFS=",";
  print "ts,method,boottime_ms,cg_io_rbytes_delta,e2_conc,e2_mem_profile,run_id,seed,round";
}
NR>1{
  print $1, $2, $3, $11, $21, $22, $32, $(NF-1), $(NF);
}' > "$out"

echo "[latest] wrote $out"

