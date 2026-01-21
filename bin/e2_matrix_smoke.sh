#!/usr/bin/env bash
set -euo pipefail

TAG="E2_MATRIX_$(date +%m%d_%H%M)"
PROJ="${1:-${PROJ:-express-app}}"
ROOT="$HOME/experiment/e_ex"

prepare_frontier() {
  cd "$ROOT/frontier_poc/$PROJ/pkgs"
  rm -f nm.frontier.tar nm.bulk.tar
  cd "$ROOT"
  NO_NET_DOWNLOAD=1 ROUNDS_ONLY_FRONTIER=1 RUN_TAG=E2_PREP_B2 \
  "$ROOT/bin/e2_h1_frontier_driver.sh" "$PROJ" 0
  # sanity：tar 內至少上百個 entries（理想 ~274）
  tar -tf "$ROOT/frontier_poc/$PROJ/pkgs/nm.frontier.tar" | wc -l
}

run_cell() {
  local conc="$1" mem="$2"
  echo "=== RUN cell: conc=$conc mem=$mem ==="
  # 先取得 sudo 時效，避免中途卡密碼
  sudo -n true 2>/dev/null || sudo -v
  # cell 級一次性 drop（所有 worker 共用）
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'

  pids=()
  for wid in $(seq 1 "$conc"); do
    ISOLATE_PROJECT_PER_WORKER=1 \
    NO_DROP_CACHES=1 \
    E2_CONC="$conc" E2_MEM_PROFILE="$mem" WORKER_ID="$wid" \
    NO_NET_DOWNLOAD=1 NO_UPGRADE=1 FRONTIER_CACHE=1 RANDOMIZE=0 \
    METHODS="baseline_full a2_shared_ro b2_frontier_only" \
    RUN_TAG="$TAG.c${conc}.${mem}" \
      "$ROOT/bin/e2_h1_frontier_driver.sh" "$PROJ" 1 & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
}

prepare_frontier
for c in 1 4 8; do
  for m in ample edge; do
    run_cell "$c" "$m"
  done
done

