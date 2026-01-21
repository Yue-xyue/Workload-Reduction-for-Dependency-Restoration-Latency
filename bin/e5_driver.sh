#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# E5_driver.sh
#
# 用途：
#   - 在 host 上一次起多個 e5_worker.sh
#   - 把 worker 分成 ROLE=target / ROLE=neighbor
#   - 讓它們在同一台機器上同時跑，形成「多租戶干擾」情境
#
# 使用方式（例）：
#   # 1 個 target + 3 個 neighbor，記憶體 edge，專案 express-app
#   E5_TARGET_WORKERS=1 \
#   E5_NEIGHBOR_WORKERS=3 \
#   E2_MEM_PROFILE=edge \
#   RUN_TAG_BASE="E5_express_edge_N3" \
#   ~/experiment/e_ex/bin/e5_driver.sh express-app
#
#   # 只跑 1 個 target（無鄰居），當作對照組 N0
#   E5_TARGET_WORKERS=1 \
#   E5_NEIGHBOR_WORKERS=0 \
#   E2_MEM_PROFILE=edge \
#   RUN_TAG_BASE="E5_express_edge_N0" \
#   ~/experiment/e_ex/bin/e5_driver.sh express-app
#
# 環境變數（可調）：
#   - E2_ROOT           ：實驗根目錄（預設 ~/experiment/e_ex）
#   - PROJ / 第1個參數   ：project 名稱（預設 express-app）
#   - E5_TARGET_WORKERS  ：target worker 數量（預設 1）
#   - E5_NEIGHBOR_WORKERS：neighbor worker 數量（預設 0）
#   - E2_MEM_PROFILE     ：ample / edge...（會寫進 meta，也決定 cgroup 記憶體上限）
#   - E5_TARGET_METHODS  ：target 用的 METHODS（預設 "baseline_full b2_frontier_only a2_shared_ro"）
#   - E5_NEIGHBOR_METHODS：neighbor 用的 METHODS（預設 "baseline_full"）
#   - RUN_TAG_BASE       ：整組實驗共用的 run_tag 前綴
#
# 新增行為（對齊 E2）：
#   - 每一個 worker 都會建立自己的 memory cgroup：
#       /sys/fs/cgroup/e5_<proj>_<role>_<mem>_c<conc>_w<id>
#   - 依 E2_MEM_PROFILE 設 memory.max / memory.high / memory.swap.max
#   - 把 worker 的 shell pid 寫進 cgroup.procs
#   - 透過 E2_CG_PATH / CG_MEM_MAX_BYTES 傳給 e5_worker → e2wrap.js
#
# 產出：
#   - 每個 worker 會照 e5_worker.sh 的方式寫 logs
#   - 結束後會呼叫 e5_summarize_from_logs.py 產生 summary.csv
#     並新增欄位 role=target/neighbor（已在 e5_summarize_from_logs.py 實作）
# ============================================================

# ---- 基本路徑與專案 ----
root="${E2_ROOT:-$HOME/experiment/e_ex}"
proj="${1:-${PROJ:-express-app}}"

# ---- 併發與角色設定 ----
E5_TARGET_WORKERS="${E5_TARGET_WORKERS:-1}"      # target worker 數量
E5_NEIGHBOR_WORKERS="${E5_NEIGHBOR_WORKERS:-0}"  # neighbor worker 數量

total_workers=$((E5_TARGET_WORKERS + E5_NEIGHBOR_WORKERS))
if (( total_workers <= 0 )); then
  echo "[E5] ERROR: total_workers = 0（沒有 target 也沒有 neighbor），請設定 E5_TARGET_WORKERS / E5_NEIGHBOR_WORKERS" >&2
  exit 1
fi

# 記憶體 profile（會寫 meta，也會用來轉成 memory.max）
E2_MEM_PROFILE="${E2_MEM_PROFILE:-edge}"

# target / neighbor 使用的方法清單
E5_TARGET_METHODS="${E5_TARGET_METHODS:-baseline_full b2_frontier_only a2_shared_ro}"
E5_NEIGHBOR_METHODS="${E5_NEIGHBOR_METHODS:-baseline_full}"

# RUN_TAG：給整組實驗一個共用 tag，方便之後 summary group-by
# 預設格式：E5_<proj>_T<targets>_N<neighbors>_<mem_profile>
default_run_tag_base="E5_${proj}_T${E5_TARGET_WORKERS}_N${E5_NEIGHBOR_WORKERS}_${E2_MEM_PROFILE}"
RUN_TAG_BASE="${RUN_TAG_BASE:-$default_run_tag_base}"

# ---- mem profile -> memory.max（bytes），語意與 E2 一致 ----
mem_profile_to_bytes() {
  local mem="$1"
  case "$mem" in
    ample)
      echo 0
      ;;

    edge)
      # E5 裡的 edge 一樣依專案決定
      case "$proj" in
        express-app)
          echo $((128*1024*1024))
          ;;
        next-grofers|next_grofers)
          echo $((1024*1024*1024))
          ;;
        ghost)
          echo $((1024*1024*1024))
          ;;
        *)
          echo $((512*1024*1024))
          ;;
      esac
      ;;

    edge_1G)
      echo $((1024*1024*1024))
      ;;

    edge_512M)
      echo $((512*1024*1024))
      ;;

    edge_256M)
      echo $((256*1024*1024))
      ;;

    edge_128M)
      echo $((128*1024*1024))
      ;;

    edge_64M)
      echo $((64*1024*1024))
      ;;

    edge_32M)
      echo $((32*1024*1024))
      ;;

    *)
      echo 0
      ;;
  esac
}



# 建立「單一 worker」對應的 cgroup（包含 ample，一律進 e5_* namespace）
# 參數：proj mem conc worker_id role
# 回傳格式（stdout）："<cg_path> <limit_bytes>"
setup_mem_cgroup_for_worker() {
  local proj="$1" mem="$2" conc="$3" worker_id="$4" role="$5"

  local limit_bytes
  limit_bytes="$(mem_profile_to_bytes "$mem")"

  # 每個 worker 專屬一個 cgroup：
  #   /sys/fs/cgroup/e5_<proj>_<role>_<mem>_c<conc>_w<id>
  local cg="/sys/fs/cgroup/e5_${proj}_${role}_${mem}_c${conc}_w${worker_id}"

  sudo mkdir -p "$cg"

  if [[ "$limit_bytes" -eq 0 ]]; then
    # unlimited：寫 "max"，同時關掉 swap
    echo "max" | sudo tee "$cg/memory.max"       >/dev/null 2>&1 || true
    echo 0      | sudo tee "$cg/memory.swap.max" >/dev/null 2>&1 || true
    echo "max" | sudo tee "$cg/memory.high"      >/dev/null 2>&1 || true
    echo "[mem] setup cgroup proj=$proj role=$role mem=$mem conc=$conc w=$worker_id cg=$cg limit_bytes=unlimited(max)" >&2
  else
    echo "$limit_bytes" | sudo tee "$cg/memory.max"       >/dev/null
    echo 0              | sudo tee "$cg/memory.swap.max"  >/dev/null 2>&1 || true
    echo "$limit_bytes" | sudo tee "$cg/memory.high"      >/dev/null 2>&1 || true
    echo "[mem] setup cgroup proj=$proj role=$role mem=$mem conc=$conc w=$worker_id cg=$cg limit_bytes=$limit_bytes" >&2
  fi

  # stdout：cg_path + 數值（0 表 unlimited）
  printf '%s %s\n' "$cg" "$limit_bytes"
}

echo "[E5] root             = $root"
echo "[E5] project          = $proj"
echo "[E5] target_workers   = $E5_TARGET_WORKERS"
echo "[E5] neighbor_workers = $E5_NEIGHBOR_WORKERS"
echo "[E5] total_workers    = $total_workers"
echo "[E5] mem_profile      = $E2_MEM_PROFILE"
echo "[E5] target METHODS   = $E5_TARGET_METHODS"
echo "[E5] neighbor METHODS = $E5_NEIGHBOR_METHODS"
echo "[E5] RUN_TAG_BASE     = $RUN_TAG_BASE"
echo

# 檢查 e5_worker.sh / e5_summarize_from_logs.py 是否存在
if [[ ! -x "$root/bin/e5_worker.sh" ]]; then
  echo "[E5] ERROR: $root/bin/e5_worker.sh 不存在或不可執行" >&2
  exit 2
fi
if [[ ! -f "$root/bin/e5_summarize_from_logs.py" ]]; then
  echo "[E5] WARN: $root/bin/e5_summarize_from_logs.py 不存在，稍後無法自動 summarize" >&2
fi

# ---- 啟動 worker ----
pids=()

# target worker：WORKER_ID 從 0 開始
for ((i = 0; i < E5_TARGET_WORKERS; i++)); do
  worker_id="$i"
  echo "[E5] start target worker_id=$worker_id"

  (
    # 每個 worker 在子 shell 中有自己的環境
    export PROJ="$proj"
    export ROLE="target"
    export WORKER_ID="$worker_id"
    export E2_CONC="$total_workers"      # 寫在 meta：代表這一組實驗的「全體併發度」
    export E2_MEM_PROFILE="$E2_MEM_PROFILE"
    export RUN_TAG="$RUN_TAG_BASE"
    export METHODS="$E5_TARGET_METHODS"

    # 建立這個 worker 專屬的 cgroup（包含 ample）
    cg_info="$(setup_mem_cgroup_for_worker "$proj" "$E2_MEM_PROFILE" "$total_workers" "$worker_id" "$ROLE")"
    CG_PATH="${cg_info%% *}"
    CG_LIMIT_BYTES="${cg_info##* }"

    export E2_CG_PATH="$CG_PATH"
    export CG_MEM_MAX_BYTES="$CG_LIMIT_BYTES"

    if [[ -n "$CG_PATH" && -d "$CG_PATH" ]]; then
      echo "[mem][E5] worker role=$ROLE w=$WORKER_ID joining cgroup $CG_PATH"
      # 把目前這個 shell (以及後續子行程) 加進 cgroup
      echo "$$" | sudo tee "$CG_PATH/cgroup.procs" >/dev/null
    else
      echo "[mem][E5] WARN: CG_PATH for target worker w=$WORKER_ID 無效（不會套用 cgroup 限制）" >&2
    fi

    exec "$root/bin/e5_worker.sh" "$proj"
  ) &

  pids+=($!)
done

# neighbor worker：WORKER_ID 接在 target 後面，避免重複
for ((j = 0; j < E5_NEIGHBOR_WORKERS; j++)); do
  worker_id=$((E5_TARGET_WORKERS + j))
  echo "[E5] start neighbor worker_id=$worker_id"

  (
    export PROJ="$proj"
    export ROLE="neighbor"
    export WORKER_ID="$worker_id"
    export E2_CONC="$total_workers"
    export E2_MEM_PROFILE="$E2_MEM_PROFILE"
    export RUN_TAG="$RUN_TAG_BASE"
    export METHODS="$E5_NEIGHBOR_METHODS"

    cg_info="$(setup_mem_cgroup_for_worker "$proj" "$E2_MEM_PROFILE" "$total_workers" "$worker_id" "$ROLE")"
    CG_PATH="${cg_info%% *}"
    CG_LIMIT_BYTES="${cg_info##* }"

    export E2_CG_PATH="$CG_PATH"
    export CG_MEM_MAX_BYTES="$CG_LIMIT_BYTES"

    if [[ -n "$CG_PATH" && -d "$CG_PATH" ]]; then
      echo "[mem][E5] worker role=$ROLE w=$WORKER_ID joining cgroup $CG_PATH"
      echo "$$" | sudo tee "$CG_PATH/cgroup.procs" >/dev/null
    else
      echo "[mem][E5] WARN: CG_PATH for neighbor worker w=$WORKER_ID 無效（不會套用 cgroup 限制）" >&2
    fi

    exec "$root/bin/e5_worker.sh" "$proj"
  ) &

  pids+=($!)
done

# ---- 等待所有 worker 結束 ----
echo "[E5] waiting for ${#pids[@]} workers..."
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    echo "[E5] WARN: worker pid=$pid exit code != 0" >&2
  fi
done
echo "[E5] all workers finished."

# ---- 自動 summarize（若腳本存在）----
if [[ -f "$root/bin/e5_summarize_from_logs.py" ]]; then
  echo "[E5] running e5_summarize_from_logs.py ..."
  python3 "$root/bin/e5_summarize_from_logs.py" --project "$proj" || {
    echo "[E5] WARN: e5_summarize_from_logs.py 執行失敗，請手動檢查。" >&2
  }
else
  echo "[E5] NOTE: 找不到 e5_summarize_from_logs.py，請之後手動跑 summarize。" >&2
fi

echo "[E5] done."
