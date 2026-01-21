#!/usr/bin/env bash
set -euo pipefail

# e2_matrix_sweep.sh
# - Launches (conc) workers per (mem, conc) cell
# - Each worker joins its own cgroup (memory.max enforced for edge profiles)
# - Uses a shared RUN_TAG per cell so driver-side barrier can synchronize workers
# - Forces driver to run in "single-worker mode" (E2_SPAWN_WORKERS=0) to avoid double-spawn
# - At the end, rebuilds summary.csv and produces matrix_<DAY>_p50_p95.csv
#
# Usage:
#   E2_ROOT=~/experiment/e_ex PROJ=express-app bin/e2_matrix_sweep.sh
#   bin/e2_matrix_sweep.sh express-app
#
# Optional:
#   PROJ=all bin/e2_matrix_sweep.sh            # run express-app, next-grofers, ghost
#   PROJ_SET="express-app next-grofers" bin/e2_matrix_sweep.sh
#
# Compatibility goals:
# - Keep existing env knobs and defaults working
# - Do not require changes to older build_matrices.py (we probe -h to pass new flags only if supported)
# - Avoid background sudo prompts deadlocking the sweep (sudo -n precheck)

root="${E2_ROOT:-$HOME/experiment/e_ex}"
proj="${PROJ:-${1:-express-app}}"

# Optional: run multiple workloads in one sweep
PROJ_SET="${PROJ_SET:-}"
if [[ -z "$PROJ_SET" ]]; then
  if [[ "$proj" == "all" ]]; then
    PROJ_SET="express-app next-grofers ghost"
  else
    PROJ_SET="$proj"
  fi
fi

# Parameters (override by env)
METHODS="${METHODS:-}"                         # if empty -> per-project defaults below
CONC_SET="${CONC_SET:-1 4 8}"
MEM_SET="${MEM_SET:-ample edge}"

# rounds: E2_ROUNDS > ROUNDS_PER_WORKER > default 5
E2_ROUNDS="${E2_ROUNDS:-${ROUNDS_PER_WORKER:-5}}"

# Common knobs (override by env)
NO_NET_DOWNLOAD="${NO_NET_DOWNLOAD:-1}"
NO_UPGRADE="${NO_UPGRADE:-1}"
ISOLATE_PROJECT_PER_WORKER="${ISOLATE_PROJECT_PER_WORKER:-1}"
FRONTIER_CACHE="${FRONTIER_CACHE:-1}"

# Matrix output filter threshold (NET_BYTES_DELTA), default 0 = no filter
NB_THRES="${NB_THRES:-0}"

# Optional cleanup cgroups after each (mem,conc) batch
E2_CGROUP_CLEANUP="${E2_CGROUP_CLEANUP:-0}"  # 1=cleanup worker cgroups

# If a worker fails in a cell:
#   0 = stop sweep immediately (default, safer for debugging)
#   1 = continue to next cells, but exit non-zero at end
E2_CONTINUE_ON_FAIL="${E2_CONTINUE_ON_FAIL:-0}"

# Optional: ask build_matrices.py to include extra dimensions (only passed if supported by build_matrices.py)
MATRIX_INCLUDE_E2E="${MATRIX_INCLUDE_E2E:-0}"
MATRIX_INCLUDE_TAR="${MATRIX_INCLUDE_TAR:-0}"
MATRIX_INCLUDE_A2_MOUNT="${MATRIX_INCLUDE_A2_MOUNT:-0}"

# --- Scheme C: allow network ONLY for baseline_no_cache ----------------------
E2_NOCACHE_ALLOW_NET="${E2_NOCACHE_ALLOW_NET:-0}"        # 1=enable scheme C
E2_NOCACHE_METHOD="${E2_NOCACHE_METHOD:-baseline_no_cache}"
E2_NOCACHE_NET_DOWNLOAD="${E2_NOCACHE_NET_DOWNLOAD:-0}"  # 0 means "allow net" i.e., NO_NET_DOWNLOAD=0

# --- hard guard: do NOT let driver spawn workers -----------------------------
# (Driver must behave as single-worker runner; sweep is the only orchestrator.)
E2_SPAWN_WORKERS="${E2_SPAWN_WORKERS:-0}"

# --- helpers ----------------------------------------------------------------
die() { echo "FATAL: $*" >&2; exit 1; }

ensure_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || die "command not found: $c"
}

# per-project default methods (only used if METHODS env is empty)
default_methods_for_proj() {
  local p="$1"
  case "$p" in
    ghost)
      # ghost has no SDL in your plan
      echo "baseline_full b2_frontier_only svsafe_shared_ro"
      ;;
    next-grofers|next_grofers|express-app)
      echo "baseline_full a2_shared_ro b2_frontier_only svsafe_shared_ro"
      ;;
    *)
      # safe default: include SV-safe too (won't break older setups; you can override via METHODS)
      echo "baseline_full a2_shared_ro b2_frontier_only svsafe_shared_ro"
      ;;
  esac
}

# --- tool checks -------------------------------------------------------------
ensure_cmd bash
ensure_cmd awk
ensure_cmd sort
ensure_cmd date
ensure_cmd python3
ensure_cmd sudo

[[ -d "$root" ]] || die "E2_ROOT not found: $root"
[[ -x "$root/bin/e2_h1_frontier_driver.sh" ]] || die "driver not executable: $root/bin/e2_h1_frontier_driver.sh"
[[ -f "$root/bin/summarize_from_logs.py" ]] || die "missing: $root/bin/summarize_from_logs.py"
[[ -f "$root/bin/build_matrices.py" ]] || die "missing: $root/bin/build_matrices.py"

# --- sudo non-interactive preflight -----------------------------------------
# Prevent background jobs from blocking on sudo password prompt.
if ! sudo -n true >/dev/null 2>&1; then
  cat >&2 <<'EOF'
FATAL: sudo requires a password (non-interactive sudo not available).
Please run 'sudo -v' once in this terminal to refresh credentials (or configure NOPASSWD),
then re-run this sweep.
EOF
  exit 1
fi

# --- mem profile -> memory.max（bytes） --------------------------------------
# 0 = unlimited (memory.max = "max")
mem_profile_to_bytes() {
  local p="$1"
  local mem="$2"
  case "$mem" in
    ample)
      echo 0
      ;;
    edge)
      case "$p" in
        express-app) echo $((128*1024*1024)) ;;
        next-grofers|next_grofers) echo $((1024*1024*1024)) ;;
        ghost) echo $((1024*1024*1024)) ;;
        *) echo $((512*1024*1024)) ;;
      esac
      ;;
    edge_1G)   echo $((1024*1024*1024)) ;;
    edge_512M) echo $((512*1024*1024)) ;;
    edge_256M) echo $((256*1024*1024)) ;;
    edge_128M) echo $((128*1024*1024)) ;;
    edge_64M)  echo $((64*1024*1024)) ;;
    edge_32M)  echo $((32*1024*1024)) ;;
    *)
      echo 0
      ;;
  esac
}

# 建立「單一 worker」對應的 cgroup
# stdout: "<cg_path> <limit_bytes>"
setup_mem_cgroup_for_worker() {
  local p="$1"
  local mem="$2"
  local conc="$3"
  local worker_id="$4"

  local limit_bytes
  limit_bytes="$(mem_profile_to_bytes "$p" "$mem")"

  # /sys/fs/cgroup/e2_<proj>_<mem>_c<conc>_w<id>
  local cg="/sys/fs/cgroup/e2_${p}_${mem}_c${conc}_w${worker_id}"

  sudo mkdir -p "$cg" >/dev/null 2>&1 || true

  if [[ "$limit_bytes" -eq 0 ]]; then
    echo "max" | sudo tee "$cg/memory.max"       >/dev/null 2>&1 || true
    echo 0     | sudo tee "$cg/memory.swap.max"  >/dev/null 2>&1 || true
    echo "max" | sudo tee "$cg/memory.high"      >/dev/null 2>&1 || true
    echo "[mem] setup cgroup proj=$p mem=$mem conc=$conc w=$worker_id cg=$cg limit=unlimited(max)" >&2
  else
    echo "$limit_bytes" | sudo tee "$cg/memory.max"      >/dev/null
    echo 0              | sudo tee "$cg/memory.swap.max" >/dev/null 2>&1 || true
    echo "$limit_bytes" | sudo tee "$cg/memory.high"     >/dev/null 2>&1 || true
    echo "[mem] setup cgroup proj=$p mem=$mem conc=$conc w=$worker_id cg=$cg limit_bytes=$limit_bytes" >&2
  fi

  printf '%s %s\n' "$cg" "$limit_bytes"
}

cleanup_cgroup_for_worker() {
  local cg="$1"
  [[ -z "${cg:-}" ]] && return 0
  [[ ! -d "$cg" ]] && return 0
  # best-effort cleanup (may fail if still has procs)
  sudo rmdir "$cg" >/dev/null 2>&1 || true
}

# Create a per-cell shared RUN_TAG (so barrier works across workers)
mk_cell_tag() {
  local p="$1" mem="$2" conc="$3"
  # Include full date+time+ns + pid to minimize collision
  local ts
  ts="$(date +%Y%m%d_%H%M%S.%N)"
  echo "E2SWEEP_${ts}.pid$$.${p}.mem${mem}.c${conc}"
}

# Best-effort cleanup for driver barrier directory to prevent stale ready short-circuit.
cleanup_barrier_dir() {
  local tag="$1"
  local d="$root/locks/barrier_${tag}"
  rm -rf "$d" 2>/dev/null || true
  sudo -n rm -rf "$d" 2>/dev/null || true
}

# --- main -------------------------------------------------------------------
cd "$root"
echo "[sweep] START $(date -Is)"
echo "[sweep] root=$root"
echo "[sweep] PROJ_SET=($PROJ_SET)"
echo "[sweep] CONC_SET=($CONC_SET)"
echo "[sweep] MEM_SET=($MEM_SET)"
echo "[sweep] E2_ROUNDS=$E2_ROUNDS"
echo "[sweep] NO_NET_DOWNLOAD=$NO_NET_DOWNLOAD NO_UPGRADE=$NO_UPGRADE ISOLATE_PROJECT_PER_WORKER=$ISOLATE_PROJECT_PER_WORKER FRONTIER_CACHE=$FRONTIER_CACHE"
echo "[sweep] NB_THRES=$NB_THRES E2_CGROUP_CLEANUP=$E2_CGROUP_CLEANUP E2_CONTINUE_ON_FAIL=$E2_CONTINUE_ON_FAIL"
echo "[sweep] E2_SPAWN_WORKERS=$E2_SPAWN_WORKERS (force driver single-worker mode)"
echo "[sweep] E2_NOCACHE_ALLOW_NET=$E2_NOCACHE_ALLOW_NET E2_NOCACHE_METHOD=$E2_NOCACHE_METHOD E2_NOCACHE_NET_DOWNLOAD=$E2_NOCACHE_NET_DOWNLOAD"
echo

overall_fail=0
overall_fail_msgs=()

for proj in $PROJ_SET; do
  projdir="$root/projects/$proj"
  [[ -d "$projdir" ]] || die "project dir not found: $projdir"

  BASE="$root/frontier_poc/$proj/logs"
  CSV="$BASE/summary.csv"
  mkdir -p "$BASE"

  # Resolve methods: env METHODS wins; otherwise per-project default
  eff_methods="${METHODS:-$(default_methods_for_proj "$proj")}"

  echo "###############################################################################"
  echo "[sweep] PROJECT=$proj"
  echo "[sweep] METHODS=($eff_methods)"
  echo "###############################################################################"
  echo

  for mem in $MEM_SET; do
    for conc in $CONC_SET; do
      echo "==== proj=$proj mem=$mem conc=$conc ===="

      # Shared RUN_TAG for ALL workers in this cell (so barrier can coordinate)
      RUN_TAG="$(mk_cell_tag "$proj" "$mem" "$conc")"
      echo "  [cell] RUN_TAG=$RUN_TAG (shared across workers for barrier sync)"

      # Best-effort: prevent stale barrier files from short-circuiting
      cleanup_barrier_dir "$RUN_TAG" || true

      # Record cgroups for optional cleanup
      cg_list=()

      # Track background workers for this cell
      pids=()
      labels=()

      for (( w=0; w<conc; w++ )); do
        cg_info="$(setup_mem_cgroup_for_worker "$proj" "$mem" "$conc" "$w")"
        CG_PATH="${cg_info%% *}"
        CG_LIMIT_BYTES="${cg_info##* }"
        cg_list+=("$CG_PATH")

        env \
          E2_ROOT="$root" \
          PROJ="$proj" \
          NO_NET_DOWNLOAD="$NO_NET_DOWNLOAD" \
          NO_UPGRADE="$NO_UPGRADE" \
          ISOLATE_PROJECT_PER_WORKER="$ISOLATE_PROJECT_PER_WORKER" \
          FRONTIER_CACHE="$FRONTIER_CACHE" \
          METHODS="$eff_methods" \
          RUN_TAG="$RUN_TAG" \
          WORKER_ID="$w" \
          E2_CONC="$conc" \
          E2_MEM_PROFILE="$mem" \
          E2_ROUNDS="$E2_ROUNDS" \
          E2_CG_PATH="$CG_PATH" \
          CG_MEM_MAX_BYTES="$CG_LIMIT_BYTES" \
          E2_NOCACHE_ALLOW_NET="$E2_NOCACHE_ALLOW_NET" \
          E2_NOCACHE_METHOD="$E2_NOCACHE_METHOD" \
          E2_NOCACHE_NET_DOWNLOAD="$E2_NOCACHE_NET_DOWNLOAD" \
          E2_SPAWN_WORKERS="$E2_SPAWN_WORKERS" \
          bash -lc '
            set -euo pipefail
            cd "${E2_ROOT}"

            if [[ -n "${E2_CG_PATH:-}" && -d "${E2_CG_PATH:-}" ]]; then
              echo "[mem] worker ${WORKER_ID:-?} joining cgroup ${E2_CG_PATH}"
              echo "$$" | sudo tee "${E2_CG_PATH}/cgroup.procs" >/dev/null
            fi

            # -------------------------------------------------------------------
            # Scheme C: allow network ONLY for baseline_no_cache (or E2_NOCACHE_METHOD)
            # We run the driver twice within the same worker + shared RUN_TAG:
            #   1) nocache method with NO_NET_DOWNLOAD=0
            #   2) remaining methods with NO_NET_DOWNLOAD=<original>
            # -------------------------------------------------------------------
            orig_methods="${METHODS}"
            orig_no_net="${NO_NET_DOWNLOAD}"

            contains_nocache=0
            for x in ${orig_methods}; do
              [[ "$x" == "${E2_NOCACHE_METHOD}" ]] && contains_nocache=1
            done

            if [[ "${E2_NOCACHE_ALLOW_NET:-0}" == "1" && "$contains_nocache" == "1" ]]; then
              rest_methods=""
              for x in ${orig_methods}; do
                [[ "$x" == "${E2_NOCACHE_METHOD}" ]] && continue
                rest_methods="${rest_methods} ${x}"
              done
              rest_methods="$(echo "${rest_methods}" | awk "{\$1=\$1;print}")"

              echo "[sweep][schemeC] worker ${WORKER_ID:-?} RUN_TAG=${RUN_TAG} -> run ${E2_NOCACHE_METHOD} with NO_NET_DOWNLOAD=0, then rest with NO_NET_DOWNLOAD=${orig_no_net}"
              echo "[sweep][schemeC] nocache=${E2_NOCACHE_METHOD} rest_methods=(${rest_methods})"

              # (1) nocache run (force allow-net)
              METHODS="${E2_NOCACHE_METHOD}" \
              NO_NET_DOWNLOAD="${E2_NOCACHE_NET_DOWNLOAD}" \
                bin/e2_h1_frontier_driver.sh "${PROJ}"

              # (2) remaining methods (if any)
              if [[ -n "${rest_methods}" ]]; then
                METHODS="${rest_methods}" \
                NO_NET_DOWNLOAD="${orig_no_net}" \
                  bin/e2_h1_frontier_driver.sh "${PROJ}"
              fi
            else
              bin/e2_h1_frontier_driver.sh "${PROJ}"
            fi
          ' &

        pid=$!
        pids+=("$pid")
        labels+=("proj=$proj mem=$mem conc=$conc w=$w RUN_TAG=$RUN_TAG pid=$pid cg=$CG_PATH")

        echo "  -> worker w=$w RUN_TAG=$RUN_TAG mem=$mem cg=$CG_PATH launched (pid=$pid)"
      done

      # Wait all workers in this cell, collect failures with attribution
      cell_fail=0
      for i in "${!pids[@]}"; do
        pid="${pids[$i]}"
        label="${labels[$i]}"
        if ! wait "$pid"; then
          echo "[sweep][cell FAIL] $label" >&2
          cell_fail=1
        fi
      done

      echo "==== proj=$proj mem=$mem conc=$conc DONE ===="
      echo

      if [[ "$E2_CGROUP_CLEANUP" == "1" ]]; then
        for cg in "${cg_list[@]}"; do
          cleanup_cgroup_for_worker "$cg"
        done
        echo "[mem] cleaned up worker cgroups (best-effort)"
        echo
      fi

      if [[ "$cell_fail" -eq 1 ]]; then
        overall_fail=1
        overall_fail_msgs+=("cell(proj=$proj,mem=$mem,conc=$conc) had worker failures")
        if [[ "$E2_CONTINUE_ON_FAIL" != "1" ]]; then
          die "cell(proj=$proj,mem=$mem,conc=$conc) failed; set E2_CONTINUE_ON_FAIL=1 to continue"
        fi
      fi
    done
  done

  echo "[sweep] project=$proj all launched batches finished."

  # --- rebuild summary.csv once at the end (per project) ----------------------
  echo "[summary] rebuild once at the end (normalize) project=$proj"
  python3 "$root/bin/summarize_from_logs.py" --project "$proj" || true

  [[ -s "$CSV" ]] || die "summary.csv not found or empty: $CSV"

  LASTDAY="$(awk -F, 'NR>1{print substr($1,1,8)}' "$CSV" | sort | tail -1 || true)"
  [[ -n "${LASTDAY:-}" ]] || die "cannot detect LASTDAY from: $CSV"

  echo "[latest day in CSV] $LASTDAY"

  OUT_SUM="$BASE/summary_${LASTDAY}.csv"
  OUT_MAT="$BASE/matrix_${LASTDAY}_p50_p95.csv"

  # --- Optional flags for build_matrices.py (only if supported) ---------------
  BM="$root/bin/build_matrices.py"
  bm_help="$(python3 "$BM" -h 2>&1 || true)"
  bm_extra_args=()

  if [[ "$MATRIX_INCLUDE_E2E" == "1" && "$bm_help" == *"--include-e2e"* ]]; then
    bm_extra_args+=(--include-e2e)
  fi
  if [[ "$MATRIX_INCLUDE_TAR" == "1" && "$bm_help" == *"--include-tar"* ]]; then
    bm_extra_args+=(--include-tar)
  fi
  if [[ "$MATRIX_INCLUDE_A2_MOUNT" == "1" && "$bm_help" == *"--include-a2-mount"* ]]; then
    bm_extra_args+=(--include-a2-mount)
  fi

  python3 "$BM" \
    --csv "$CSV" --day "$LASTDAY" \
    --out-summary "$OUT_SUM" \
    --out-matrix  "$OUT_MAT" \
    --nb-thres "$NB_THRES" \
    "${bm_extra_args[@]}"

  if command -v column >/dev/null 2>&1; then
    column -t -s, "$OUT_MAT" || cat "$OUT_MAT"
  else
    cat "$OUT_MAT"
  fi

  rows=$(( $(wc -l < "$CSV") - 1 ))
  echo "[summary] project=$proj rows=$rows -> $CSV"
  echo "[matrix]  project=$proj $OUT_MAT"
  echo
done

if [[ "$overall_fail" -eq 1 ]]; then
  echo "[sweep] DONE with failures:" >&2
  for m in "${overall_fail_msgs[@]}"; do
    echo "  - $m" >&2
  done
  exit 2
fi

echo "[sweep] DONE (all cells OK)"
