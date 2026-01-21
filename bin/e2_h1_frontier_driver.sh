#!/usr/bin/env bash
set -euo pipefail

# e2_h1_frontier_driver.sh (single-worker runner by default)
#
# Design goals (per your plan):
# 1) Sweep (e2_matrix_sweep.sh) is the ONLY orchestrator for conc>1.
#    - Driver should NOT auto-spawn workers unless explicitly enabled.
# 2) For each method, produce:
#    - wrapper metrics (PHASE2_BOOTTIME_MS etc.) in wrap_extract.log
#    - setup metrics (A2_MOUNT_MS / SVSAFE_*_MS) in meta.extras
#    - derived totals: E2_SETUP_MS, E2_TOTAL_MS (Phase-2 + setup)
# 3) For conc>1:
#    - avoid global side effects being executed N times (drop_caches, frontier build, A2 seed build)
#    - provide deterministic stampede for SV-safe (so you can observe lock wait)
#
# NOTE:
# - Default is "single-worker mode": E2_SPAWN_WORKERS=0.
# - Let sweep pass WORKER_ID / RUN_TAG / E2_CONC.

# --- CPU governor detect (host-wide) -----------------------------------------
detect_cpu_governor() {
  local base="" gov="" mismatch=0 p=""
  for cand in \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor \
    /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
  do
    [[ -r "$cand" ]] && { p="$cand"; break; }
  done
  [[ -z "$p" ]] && { echo "unknown"; return; }
  base="$(cat "$p" 2>/dev/null || true)"
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -r "$f" ]] || continue
    gov="$(cat "$f" 2>/dev/null || true)"
    [[ "$gov" == "$base" ]] || { mismatch=1; break; }
  done
  (( mismatch )) && echo "mixed:$base" || echo "$base"
}

# --- boottime helper (prefer CLOCK_BOOTTIME) ---------------------------------
boottime_now_ns() {
  # 1) Prefer a dedicated helper that returns CLOCK_BOOTTIME ns
  if [[ -x "${E2_ROOT:-$HOME/experiment/e_ex}/bin/boottime_now" ]]; then
    "${E2_ROOT:-$HOME/experiment/e_ex}/bin/boottime_now" 2>/dev/null && return 0
  fi
  # 2) Fallback: /proc/uptime (monotonic seconds since boot; ns)
  if [[ -r /proc/uptime ]]; then
    awk '{printf "%.0f\n", $1 * 1000000000.0}' /proc/uptime 2>/dev/null && return 0
  fi
  # 3) Last resort: wall clock (ns)
  date +%s%N
}

# --- kv helpers --------------------------------------------------------------
kv_get() {
  # usage: kv_get FILE KEY
  local f="$1" k="$2"
  [[ -r "$f" ]] || return 1
  awk -F= -v K="$k" '$1==K{print $2; exit 0}' "$f" 2>/dev/null
}

kv_append_if_present() {
  # usage: kv_append_if_present SRC_FILE KEY OUT_META_EXTRAS [OUT_KEY]
  local f="$1" k="$2" out="$3" ok="${4:-$2}"
  local v=""
  v="$(kv_get "$f" "$k" 2>/dev/null || true)"
  [[ -n "$v" ]] && echo "${ok}=${v}" >> "$out"
}

# --- basic vars --------------------------------------------------------------
root="${E2_ROOT:-$HOME/experiment/e_ex}"
proj="${1:-${PROJ:-express-app}}"
projdir_base="$root/projects/$proj"
projdir="${PROJECT_DIR:-$projdir_base}"
frontier_dir="${FRONTIER_DIR:-$root/frontier_poc/$proj}"
logd="${LOG_DIR:-$frontier_dir/logs}"
pkgd="${PKG_DIR:-$frontier_dir/pkgs}"

mkdir -p "$logd" "$pkgd" "$root/bin" "$root/locks" "$root/work"

# --- conc/spawn policy -------------------------------------------------------
E2_CONC="${E2_CONC:-1}"

# Default: DO NOT spawn workers inside driver (sweep orchestrates)
E2_SPAWN_WORKERS="${E2_SPAWN_WORKERS:-0}"

# If conc>1 but RUN_TAG missing, barriers and "once" actions cannot be shared safely
if [[ "${E2_CONC:-1}" -gt 1 && -z "${RUN_TAG:-}" ]]; then
  echo "[warn] E2_CONC>1 but RUN_TAG is empty -> disable shared barriers / once-only actions. (Set RUN_TAG in sweep.)" >&2
  export E2_DROP_CACHES_ONCE=0
  export E2_BUILD_FRONTIER_ONCE=0
  export E2_BUILD_A2_SEED_ONCE=0
  export E2_BARRIER_METHODS=""
fi

# Optional legacy behavior: spawn workers if WORKER_ID missing and enabled
if [[ -z "${WORKER_ID:-}" && "$E2_CONC" -gt 1 && "$E2_SPAWN_WORKERS" = "1" ]]; then
  echo "[driver] (legacy) spawn $E2_CONC workers for proj=$proj run_tag=${RUN_TAG:-}" >&2
  pids=()
  for i in $(seq 0 $((E2_CONC-1))); do
    (
      export WORKER_ID="$i"
      export ISOLATE_PROJECT_PER_WORKER="${ISOLATE_PROJECT_PER_WORKER:-1}"
      export E2_SPAWN_WORKERS="0"
      exec "$0" "$proj"
    ) &
    pids+=("$!")
  done
  rc=0
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=1
  done
  exit "$rc"
fi

# --- global cache root (legacy) ----------------------------------------------
npm_cache="${NPM_CACHE_DIR:-$root/npm-cache}"

# --- package tool ------------------------------------------------------------
case "$proj" in
  ghost) PKG_TOOL_DEFAULT="yarn" ;;
  *)     PKG_TOOL_DEFAULT="npm"  ;;
esac
PKG_TOOL="${PKG_TOOL:-${E2_PKG_TOOL:-$PKG_TOOL_DEFAULT}}"
export PKG_TOOL

yarn_cache="${YARN_CACHE_DIR:-$root/npm-cache/yarn}"
if [[ "$PKG_TOOL" = "yarn" ]]; then
  export YARN_CACHE_FOLDER="$yarn_cache"
fi

# Export for downstream tools
export PROJ="$proj"
export FRONTIER_DIR="$frontier_dir"
export LOG_DIR="$logd"
export PKG_DIR="$pkgd"
export NPM_CONFIG_CACHE="$npm_cache"

mkdir -p "$npm_cache" "$yarn_cache"

# E2_SKIP_INSTALL implies also skip rm node_modules & skip frontier build
if [[ "${E2_SKIP_INSTALL:-0}" = "1" ]]; then
  export E2_SKIP_RM_NODE_MODULES=1
  export E2_SKIP_BUILD_FRONTIER=1
fi

rounds="${E2_ROUNDS:-5}"

RANDOMIZE="${RANDOMIZE:-1}"
ENABLE_TOPK="${ENABLE_TOPK:-0}"
ENABLE_A2="${ENABLE_A2:-0}"
LIMITKB="${LIMITKB:-20480}"

SVSAFE_SETUP="${SVSAFE_SETUP:-$root/bin/e2_svsafe_setup.sh}"
E2_E8_COVERAGE="${E2_E8_COVERAGE:-0}"

# conc>1 default isolate per worker (unless explicitly set)
if [[ -n "${WORKER_ID:-}" && "${E2_CONC:-1}" -gt 1 ]]; then
  if [[ -z "${ISOLATE_PROJECT_PER_WORKER+x}" ]]; then
    ISOLATE_PROJECT_PER_WORKER=1
  fi
fi

# --- per-worker project isolation -------------------------------------------
if [[ "${ISOLATE_PROJECT_PER_WORKER:-0}" = "1" && -n "${WORKER_ID:-}" ]]; then
  iso_dir="$projdir_base.w${WORKER_ID}"
  mkdir -p "$iso_dir"
  rsync -a --delete --exclude node_modules "$projdir_base/" "$iso_dir/"
  projdir="$iso_dir"
fi

export PROJECT_DIR="$projdir"

cd "$projdir"

# npm flags
npm_flags="--cache=$npm_cache --prefer-offline --no-audit --fund=false --progress=false"
if [[ "${NO_NET_DOWNLOAD:-0}" = "1" ]]; then
  npm_flags="$npm_flags --offline"
fi

smoke_js="smoke_deps.mjs"
[[ -f "$smoke_js" ]] || { echo "[fatal] $smoke_js missing under $projdir" >&2; exit 2; }

# --- helpers: mount / unmount / RW guard -------------------------------------
is_mountpoint() { findmnt -rn "$1" >/dev/null 2>&1; }

a2_status_file="$projdir/.a2_status"
a2_lock_file="$projdir/.a2_mount.lock"
svsafe_status_file="$projdir/.svsafe_status"

a2_seed_from_status() {
  [[ -r "$a2_status_file" ]] || return 1
  awk -F= '$1=="A2_SEED"{print $2}' "$a2_status_file"
}

a2_unmount_if_mounted() {
  local nm="$projdir/node_modules"
  exec {a2fd}>"$a2_lock_file"
  flock -w 30 "$a2fd" || true
  if is_mountpoint "$nm"; then
    echo "[A2] umount $nm"
    sudo umount -l "$nm" || true
  fi
  flock -u "$a2fd" || true
}

svsafe_unmount_if_mounted() {
  local nm="$projdir/node_modules"
  if is_mountpoint "$nm"; then
    echo "[SVSAFE] umount $nm"
    sudo umount -l "$nm" || true
  fi
  rm -f "$svsafe_status_file" 2>/dev/null || true
}

ensure_rw_node_modules() {
  local nm="$projdir/node_modules"
  if is_mountpoint "$nm"; then
    echo "[guard] $nm is a mount ($(findmnt -no OPTIONS "$nm" 2>/dev/null || echo unknown)) -> umount -l"
    sudo umount -l "$nm" || true
  fi
  mkdir -p "$nm"
  if ! (touch "$nm/.rw_test" 2>/dev/null); then
    echo "[guard] $nm not writable; abort" >&2
    return 1
  fi
  rm -f "$nm/.rw_test"
}

cleanup() {
  a2_unmount_if_mounted || true
  svsafe_unmount_if_mounted || true
}
trap cleanup EXIT

inline_safe_rm='(findmnt -rn node_modules >/dev/null 2>&1 && echo "[guard rm] skip rm -rf node_modules (mountpoint)" || rm -rf node_modules)'

# --- barrier primitives (file-based) -----------------------------------------
barrier_wait() {
  # usage: barrier_wait TAG EXPECT_N TIMEOUT_SEC
  local tag="$1" expect="${2:-1}" timeout="${3:-120}"
  local wid="${WORKER_ID:-0}"
  local conc="${E2_CONC:-1}"

  [[ "$conc" -le 1 ]] && return 0
  [[ "$expect" -le 1 ]] && return 0

  local bdir="${root}/locks/barrier_${tag}"
  mkdir -p "$bdir"

  : > "$bdir/w${wid}.ready"

  local t0 now cnt
  t0="$(date +%s)"
  while true; do
    cnt="$(find "$bdir" -maxdepth 1 -type f -name 'w*.ready' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${cnt:-0}" -ge "$expect" ]]; then
      break
    fi
    now="$(date +%s)"
    if [[ $((now - t0)) -ge "$timeout" ]]; then
      echo "[barrier][warn] timeout tag=$tag expect=$expect got=${cnt:-0} -> continue" >&2
      break
    fi
    sleep 0.05
  done
}

barrier_touch_once() {
  # usage: barrier_touch_once TAG FILE_BASENAME
  local tag="$1" fn="$2"
  local bdir="${root}/locks/barrier_${tag}"
  mkdir -p "$bdir"
  : > "$bdir/$fn"
}

barrier_wait_file() {
  # usage: barrier_wait_file TAG FILE_BASENAME TIMEOUT_SEC
  local tag="$1" fn="$2" timeout="${3:-120}"
  local bdir="${root}/locks/barrier_${tag}"
  local t0 now
  t0="$(date +%s)"
  while [[ ! -f "$bdir/$fn" ]]; do
    now="$(date +%s)"
    if [[ $((now - t0)) -ge "$timeout" ]]; then
      echo "[barrier][warn] wait_file timeout tag=$tag file=$fn -> continue" >&2
      break
    fi
    sleep 0.05
  done
}

# Which methods should stampede-sync (to observe waiting)?
should_barrier_method() {
  local m="$1"
  local list="${E2_BARRIER_METHODS:-svsafe_shared_ro svsafe_shared_ro_no_cache}"
  case " $list " in
    *" $m "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# --- global side-effects controls (conc>1) -----------------------------------
E2_DROP_CACHES_ONCE="${E2_DROP_CACHES_ONCE:-1}"          # default ON for conc>1
E2_BUILD_FRONTIER_ONCE="${E2_BUILD_FRONTIER_ONCE:-1}"    # default ON for conc>1
E2_BUILD_A2_SEED_ONCE="${E2_BUILD_A2_SEED_ONCE:-1}"      # default ON for conc>1

maybe_drop_caches() {
  # usage: maybe_drop_caches TAG
  local tag="$1"
  [[ -n "${NO_DROP_CACHES:-}" ]] && return 0

  local conc="${E2_CONC:-1}" wid="${WORKER_ID:-0}"
  if [[ "$conc" -gt 1 && "${E2_DROP_CACHES_ONCE}" = "1" ]]; then
    barrier_wait "$tag.drop.pre" "$conc" "${E2_BARRIER_TIMEOUT_SEC:-120}"
    if [[ "$wid" = "0" ]]; then
      echo "[drop_caches] (once) tag=$tag by worker0" >&2
      sync
      echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || true
      barrier_touch_once "$tag.drop" "drop.done"
    fi
    barrier_wait "$tag.drop.post" "$conc" "${E2_BARRIER_TIMEOUT_SEC:-120}"
    barrier_wait_file "$tag.drop" "drop.done" "${E2_BARRIER_TIMEOUT_SEC:-120}"
  else
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || true
  fi
}

# --- SV-safe cold purge (only worker0) ---------------------------------------
svsafe_cold_purge_once() {
  local proj="$1" root="$2"
  local wid="${WORKER_ID:-0}"
  local cold="${E2_SVSAFE_COLD:-0}"
  [[ "$cold" != "1" ]] && return 0
  [[ "$wid" != "0" ]] && return 0
  echo "[svsafe][cold] purge shared store: $root/shared_deps/svsafe/$proj/*" >&2
  rm -rf "$root/shared_deps/svsafe/$proj"/* 2>/dev/null || true
}

# --- install commands --------------------------------------------------------
default_install_cmd_with_cache() {
  local cache_dir="$1"
  case "${PKG_TOOL:-npm}" in
    yarn)
      local ycache="${cache_dir:-$yarn_cache}"
      local cmd="YARN_CACHE_FOLDER='$ycache' yarn install --immutable --ignore-engines --non-interactive"
      if [[ "${NO_NET_DOWNLOAD:-0}" = "1" ]]; then
        cmd="$cmd --offline"
      fi
      echo "$cmd"
      ;;
    npm|*)
      local ncache="${cache_dir:-$npm_cache}"
      local flags="--cache=$ncache --prefer-offline --no-audit --fund=false --progress=false"
      if [[ "${NO_NET_DOWNLOAD:-0}" = "1" ]]; then
        flags="$flags --offline"
      fi
      echo "npm ci $flags"
      ;;
  esac
}

default_install_cmd() { default_install_cmd_with_cache ""; }

run_install_cmd() {
  local logf="$1"
  local cmd=""

  if [[ -n "${E2_INSTALL_CMD:-}" ]]; then
    echo "[install] using custom E2_INSTALL_CMD: $E2_INSTALL_CMD" >&2
    cmd="$E2_INSTALL_CMD"
  else
    cmd="$(default_install_cmd)"
    echo "[install] using default ${PKG_TOOL:-npm} install: $cmd" >&2
  fi

  if ! bash -lc "$cmd" >"$logf" 2>&1; then
    if [[ -z "${E2_INSTALL_CMD:-}" && "${PKG_TOOL:-npm}" = "npm" ]]; then
      if [[ "${NO_NET_DOWNLOAD:-0}" = "1" ]] && grep -q 'ENOTCACHED' "$logf"; then
        echo "[fatal] npm cache missing under offline mode (ENOTCACHED)." >&2
        echo "        建議先 PRIME 一次以灌滿快取，或暫時 NO_NET_DOWNLOAD=0。" >&2
        if [[ "${NPM_PRIME_ON_FAIL:-0}" = "1" ]]; then
          echo "[prime] NPM_PRIME_ON_FAIL=1 -> 暫時允許網路以填快取後再重試（一次性）" >&2
          local flags_online="--cache=$npm_cache --prefer-offline --no-audit --fund=false --progress=false"
          if npm ci $flags_online >>"$logf" 2>&1; then
            echo "[prime] cache primed, retry offline npm ci" >&2
            npm ci $npm_flags >>"$logf" 2>&1
            return 0
          else
            echo "[fatal] online prime failed，請檢查網路或 registry 設定。" >&2
            return 1
          fi
        fi
        return 1
      fi
    fi
    sed -n '1,200p' "$logf" >&2 || true
    return 1
  fi
  return 0
}

# --- A2 mount metrics --------------------------------------------------------
A2_MOUNT_MS_LAST=""
A2_MOUNT_RO_OK_LAST=""
A2_SEED_PATH_LAST=""

a2_mount_from_seed() {
  local seed="" nm="$projdir/node_modules"
  A2_MOUNT_MS_LAST=""
  A2_MOUNT_RO_OK_LAST=""
  A2_SEED_PATH_LAST=""

  seed="$(a2_seed_from_status || true)"
  [[ -z "$seed" ]] && seed="$root/a2_ro/$proj/node_modules"

  # Build seed once (conc>1 safe): lock + optional once-only
  if [[ ! -d "$seed" ]]; then
    local conc="${E2_CONC:-1}" wid="${WORKER_ID:-0}"
    local lck="$root/locks/a2_seed_${proj}.lock"
    exec {lkfd}>"$lck"

    if [[ "$conc" -gt 1 && "${E2_BUILD_A2_SEED_ONCE}" = "1" ]]; then
      barrier_wait "a2seed_${RUN_TAG:-none}_${proj}.pre" "$conc" "${E2_BARRIER_TIMEOUT_SEC:-120}"
    fi

    flock -w 300 "$lkfd" || true
    # Re-check after lock
    seed="$(a2_seed_from_status || true)"
    [[ -z "$seed" ]] && seed="$root/a2_ro/$proj/node_modules"

    if [[ ! -d "$seed" ]]; then
      if [[ "$wid" = "0" || "$conc" -le 1 || "${E2_BUILD_A2_SEED_ONCE}" != "1" ]]; then
        echo "[A2] seed not found -> build once" >&2
        sudo -v || true
        CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        PATH="$CLEAN_PATH" "$root/bin/e2_a2_setup.sh" "$proj" "$npm_flags"
      fi
    fi
    flock -u "$lkfd" || true

    if [[ "$conc" -gt 1 && "${E2_BUILD_A2_SEED_ONCE}" = "1" ]]; then
      # let others proceed after worker0 has a chance to build
      barrier_wait "a2seed_${RUN_TAG:-none}_${proj}.post" "$conc" "${E2_BARRIER_TIMEOUT_SEC:-120}"
    fi
  fi

  seed="$(a2_seed_from_status || true)"
  [[ -z "$seed" ]] && seed="$root/a2_ro/$proj/node_modules"
  [[ -d "$seed" ]] || { echo "[fatal] A2 seed missing after build attempt: $seed" >&2; exit 3; }

  A2_SEED_PATH_LAST="$seed"

  exec {a2fd}>"$a2_lock_file"
  flock -w 30 "$a2fd" || true

  if is_mountpoint "$nm" && findmnt -no OPTIONS "$nm" | grep -q '\bro\b'; then
    echo "[A2] node_modules already ro-mounted -> reuse"
    A2_MOUNT_MS_LAST="0"
    A2_MOUNT_RO_OK_LAST="1"
    flock -u "$a2fd" || true
    return 0
  fi

  local t0 t1
  t0="$(boottime_now_ns)"
  if is_mountpoint "$nm"; then
    sudo umount -l "$nm" || true
  fi
  mkdir -p "$nm"
  echo "[A2] mount --bind $seed -> $nm (ro)"
  sudo mount --bind "$seed" "$nm"
  sudo mount -o remount,ro,bind "$nm" || {
    echo "[A2][warn] remount ro failed (will continue)" >&2
    true
  }
  t1="$(boottime_now_ns)"

  # FIX: write A2 mount time (ms)
  if is_mountpoint "$nm"; then
    if [[ -n "$t0" && -n "$t1" && "$t1" -ge "$t0" ]]; then
      A2_MOUNT_MS_LAST="$(( (t1 - t0) / 1000000 ))"
      A2_MOUNT_RO_OK_LAST="1"
    else
      A2_MOUNT_MS_LAST="0"
      A2_MOUNT_RO_OK_LAST="0"
    fi
  else
    A2_MOUNT_MS_LAST=""
    A2_MOUNT_RO_OK_LAST="0"
    echo "[A2][warn] mountpoint not active after mount; record empty A2_MOUNT_MS" >&2
  fi

  flock -u "$a2fd" || true
}

# --- SVSAFE metrics ----------------------------------------------------------
SVSAFE_MOUNT_MS_LAST=""
SVSAFE_REUSED_LAST=""

svsafe_mount_shared_ro() {
  [[ -x "$SVSAFE_SETUP" ]] || { echo "[fatal] SVSAFE_SETUP missing or not executable: $SVSAFE_SETUP" >&2; exit 3; }
  SVSAFE_MOUNT_MS_LAST=""
  SVSAFE_REUSED_LAST=""

  a2_unmount_if_mounted || true

  local t0 t1
  t0="$(boottime_now_ns)"
  PROJECT_DIR="$projdir" E2_ROOT="$root" SVSAFE_STATUS_FILE="$svsafe_status_file" "$SVSAFE_SETUP" "$proj"
  t1="$(boottime_now_ns)"
  SVSAFE_MOUNT_MS_LAST="$(( (t1 - t0) / 1000000 ))"

  if [[ -r "$svsafe_status_file" ]]; then
    local rv=""
    rv="$(kv_get "$svsafe_status_file" "SVSAFE_REUSED" 2>/dev/null || true)"
    [[ -z "$rv" ]] && rv="$(kv_get "$svsafe_status_file" "svsafe_reused" 2>/dev/null || true)"
    [[ -n "$rv" ]] && SVSAFE_REUSED_LAST="$rv"
  fi
}

# --- version snapshot (stage0) ----------------------------------------------
{
  {
    echo "=== VERSION SNAPSHOT ==="
    date -Is
    node -v
    npm -v
    uname -a
    lsb_release -a 2>/dev/null || true
    echo "cpu_governor=$(detect_cpu_governor)"
    echo "pkg_tool=$PKG_TOOL"
  } > "$root/VERSION.md"
  CPU_GOV_PRINT="${E2_LAST_CPU_GOV:-$(detect_cpu_governor)}"
  echo "[stage0] node=$(node -v) npm=$(npm -v) cpu_gov=$CPU_GOV_PRINT pkg_tool=$PKG_TOOL" >&2
  echo "[stage0] rounds=$rounds (E2_ROUNDS, default 5)" >&2
} || true

# --- determine methods -------------------------------------------------------
if [[ -n "${METHODS:-}" ]]; then
  # shellcheck disable=SC2206
  methods=(${METHODS})
else
  methods=(baseline_full b2_frontier_only)
  [[ "$ENABLE_A2" -eq 1 ]] && methods+=(a2_shared_ro)
fi

b2_requested=0
case " ${methods[*]} " in
  *" b2_frontier_only "*|*" b2_frontier_plus_full "*) b2_requested=1 ;;
esac

# --- frontier need logic -----------------------------------------------------
need_frontier=0
if [[ "${ROUNDS_ONLY_FRONTIER:-0}" = "1" ]]; then
  need_frontier=1
fi
if [[ "$b2_requested" -eq 1 || "$ENABLE_TOPK" -eq 1 ]]; then
  need_frontier=1
fi
if [[ "${FORCE_BUILD_FRONTIER:-0}" = "1" ]]; then
  need_frontier=1
fi
if [[ "${E2_SKIP_BUILD_FRONTIER:-0}" = "1" ]]; then
  need_frontier=0
fi
if [[ "$need_frontier" -eq 1 && "${FRONTIER_CACHE:-0}" = "1" && -f "$pkgd/nm.frontier.tar" && -f "$pkgd/nm.bulk.tar" ]]; then
  need_frontier=0
fi
if [[ "$need_frontier" -eq 0 && "$b2_requested" -eq 1 && -f "$pkgd/nm.frontier.tar" ]]; then
  cnt=$(tar -tf "$pkgd/nm.frontier.tar" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  if [[ "${cnt:-0}" -le 1 ]]; then
    echo "[build] WARN: cached frontier looks empty (cnt=${cnt:-0}); forcing rebuild" >&2
    need_frontier=1
  fi
fi

# --- build frontier (once-safe) ----------------------------------------------
ts_iso="$(date -Is)"
ts_ns="$(date +%s%N)"
tdir="$logd/${ts_ns}_w${WORKER_ID:-0}_trace"
mkdir -p "$tdir" "$pkgd"

only_frontier_then_exit=0
if [[ "${ROUNDS_ONLY_FRONTIER:-0}" = "1" ]]; then
  only_frontier_then_exit=1
fi

frontier_bytes=0; frontier_files=0; bulk_bytes=0; bulk_files=0; topk_bytes=0

build_frontier_impl() {
  echo "[build] frontier from strace at SRC=$projdir" >&2

  a2_unmount_if_mounted || true
  svsafe_unmount_if_mounted || true
  ensure_rw_node_modules

  eval "$inline_safe_rm"
  run_install_cmd "$tdir/npm_ci.log" || exit 6

  strace -f -tt -qq -s 300 -o "$tdir/strace.log" -e trace=%file -e status=successful node "$smoke_js"

  pwd_abs="$(pwd)/"

  grep -oE '"([^"]+)"' "$tdir/strace.log" \
    | sed -E 's/^"//; s/"$//' \
    | awk -v P="$pwd_abs" '
        {
          p=$0
          if (substr(p,1,1)!="/") p=P p
          if (index(p,"/node_modules/") && index(p,"/.cache/")==0) {
            print p
          }
        }
      ' | sort -u > "$tdir/frontier_abs.txt"

  : > "$tdir/frontier_files.txt"
  while IFS= read -r abs; do
    if command -v realpath >/dev/null 2>&1; then
      rp="$(realpath -m -- "$abs" 2>/dev/null || echo "")"
    else
      rp="$(readlink -f -- "$abs" 2>/dev/null || echo "")"
    fi
    [[ -z "$rp" ]] && continue

    case "$rp" in
      "$pwd_abs"node_modules/*)
        rel="${rp#"$pwd_abs"}"
        printf '%s\n' "$rel" >> "$tdir/frontier_files.txt"
        ;;
      *) ;;
    esac
  done < "$tdir/frontier_abs.txt"

  sort -u -o "$tdir/frontier_files.txt" "$tdir/frontier_files.txt"

  find node_modules -type f | sort > "$tdir/all_files.txt"
  comm -23 "$tdir/all_files.txt" "$tdir/frontier_files.txt" > "$tdir/bulk_files.txt"

  # Write tar atomically (tmp then mv) to avoid torn reads in conc>1
  tmp_front="$pkgd/.nm.frontier.tar.tmp.$$"
  tmp_bulk="$pkgd/.nm.bulk.tar.tmp.$$"
  tar --no-recursion -cf "$tmp_front" -T "$tdir/frontier_files.txt"
  tar --no-recursion -cf "$tmp_bulk"  -T "$tdir/bulk_files.txt"
  mv -f "$tmp_front" "$pkgd/nm.frontier.tar"
  mv -f "$tmp_bulk"  "$pkgd/nm.bulk.tar"

  frontier_bytes=$(tar -tvf "$pkgd/nm.frontier.tar" | awk '{s+=$3} END{print s+0}')
  frontier_files=$(tar -tvf "$pkgd/nm.frontier.tar" | wc -l | tr -d ' ')
  bulk_bytes=$(tar -tvf "$pkgd/nm.bulk.tar" | awk '{s+=$3} END{print s+0}')
  bulk_files=$(tar -tvf "$pkgd/nm.bulk.tar" | wc -l | tr -d ' ')
  all_bytes=$(( frontier_bytes + bulk_bytes ))
  all_files=$(( frontier_files + bulk_files ))
  pct=$(awk -v a="$frontier_bytes" -v b="$all_bytes" 'BEGIN{print (b>0?100*a/b:0)}')
  printf "[build] frontier=%s files=%s | bulk=%s files=%s | all=%s files=%s | frontier_pct=%.2f%%\n" \
    "$frontier_bytes" "$frontier_files" "$bulk_bytes" "$bulk_files" "$all_bytes" "$all_files" "$pct" >&2
}

if [[ "$need_frontier" -eq 1 ]]; then
  if [[ "${E2_CONC:-1}" -gt 1 && "${E2_BUILD_FRONTIER_ONCE}" = "1" ]]; then
    barrier_wait "frontier_${RUN_TAG:-none}_${proj}.pre" "${E2_CONC}" "${E2_BARRIER_TIMEOUT_SEC:-180}"

    # lock to ensure only one builder even if barrier is imperfect
    lck="$root/locks/frontier_${proj}.lock"
    exec {ff}>"$lck"
    flock -w 600 "$ff" || true

    # re-check after lock
    if [[ "${FRONTIER_CACHE:-0}" = "1" && -f "$pkgd/nm.frontier.tar" && -f "$pkgd/nm.bulk.tar" ]]; then
      need_frontier=0
      echo "[build] frontier already exists (after lock) -> reuse" >&2
    else
      if [[ "${WORKER_ID:-0}" = "0" ]]; then
        build_frontier_impl
      fi
    fi

    flock -u "$ff" || true
    barrier_wait "frontier_${RUN_TAG:-none}_${proj}.post" "${E2_CONC}" "${E2_BARRIER_TIMEOUT_SEC:-180}"
  else
    build_frontier_impl
  fi
else
  echo "[build] skip frontier (need_frontier=0, reuse cache if exists)" >&2
  if [[ "$b2_requested" -eq 1 ]]; then
    if [[ ! -f "$pkgd/nm.frontier.tar" || ! -f "$pkgd/nm.bulk.tar" ]]; then
      echo "[build] cache missing -> create empty placeholders (B2 不應使用)" >&2
      mkdir -p "$tdir/_empty"
      tar -C "$tdir/_empty" -cf "$pkgd/nm.frontier.tar" .
      tar -C "$tdir/_empty" -cf "$pkgd/nm.bulk.tar" .
    fi
  fi
fi

if [[ "$only_frontier_then_exit" -eq 1 ]]; then
  echo "[build] frontier-only mode -> exit" >&2
  exit 0
fi

# --- TopK (unchanged; only meaningful if we built frontier this round) --------
if [[ "$ENABLE_TOPK" -eq 1 && "$need_frontier" -eq 1 ]]; then
  echo "[info] topk target ~= $LIMITKB KB" >&2
  FILTER_PAT='\.map$|(^|/)README(\.|$)|(^|/)CHANGE(S|LOG)?(\.|$)|(^|/)LICENSE(\.|$)|(^|/)NOTICE(\.|$)|(^|/)docs?(/|$)|(^|/)doc(/|$)|(^|/)test(s)?(/|$)|(^|/)__tests__(/|$)|(^|/)examples?(/|$)|(^|/)bench(mark)?(/|$)|(^|/)\.github(/|$)|(^|/)\.eslintrc|(^|/)yarn\.lock$|(^|/)package-lock\.json$|\.d\.ts$|\.flow$'
  tar -tvf "$pkgd/nm.bulk.tar" \
   | awk '{size=$3; name=$NF; print size "\t" name}' \
   | sort -nr -k1,1 > "$tdir/bulk_list_all.tsv"
  grep -Ev "$FILTER_PAT" "$tdir/bulk_list_all.tsv" > "$tdir/bulk_list_filtered.tsv" || true
  awk -v limitKB="$LIMITKB" -F'\t' '
    BEGIN{sum=0}
    { szKB=int($1/1024); name=$2; if (sum<limitKB && name!="" ){ print name; sum+=szKB } }
  ' "$tdir/bulk_list_filtered.tsv" > "$tdir/topk_bulk.txt" || true

  stage="$tdir/topk_stage"
  rm -rf "$stage"; mkdir -p "$stage"
  tar -xf "$pkgd/nm.bulk.tar" -C "$stage" -T "$tdir/topk_bulk.txt" || true
  tar -C "$stage" -cf "$pkgd/nm.bulk.topk.tar" .
  topk_bytes=$(tar -tvf "$pkgd/nm.bulk.topk.tar" | awk '{s+=$3} END{print s+0}')
  echo "[topk] bytes=$topk_bytes" >&2
fi

# --- meta --------------------------------------------------------------------
meta="$tdir/meta.json"
cat > "$meta" <<EOF
{
  "project":"$proj",
  "timestamp_iso":"$ts_iso",
  "ts_ns":"$ts_ns",
  "worker_id":"${WORKER_ID:-}",
  "run_tag":"${RUN_TAG:-}",
  "e2_conc":"${E2_CONC:-1}",
  "e2_mem_profile":"${E2_MEM_PROFILE:-ample}",
  "pkg_tool":"$PKG_TOOL",
  "topk_enabled":$ENABLE_TOPK,
  "topk_limit_kb":$LIMITKB,
  "frontier_bytes":$frontier_bytes,
  "frontier_files":$frontier_files,
  "bulk_bytes":$bulk_bytes,
  "bulk_files":$bulk_files,
  "topk_bytes":$topk_bytes
}
EOF

wrap_with_net_sandbox() {
  local inner="$1"
  if [[ "${E2_NET_SANDBOX:-0}" != "1" ]]; then
    echo "$inner"
    return 0
  fi
  echo "[net] E2_NET_SANDBOX=1 -> wrap extract with 'sudo unshare -n'" >&2
  local wrapped=""
  printf -v wrapped 'sudo unshare -n -- bash -lc %q' "$inner"
  echo "$wrapped"
}

# --- workload loop -----------------------------------------------------------
RUN_RANDOM_SEED="${RUN_RANDOM_SEED:-$RANDOM}"

for ((r=1; r<=rounds; r++)); do
  work="$root/work/${proj}-$(date +%s%N)-w${WORKER_ID:-0}"
  mkdir -p "$work"

  if [[ "$RANDOMIZE" -eq 1 ]]; then
    mapfile -t order < <(printf "%s\n" "${methods[@]}" | shuf)
  else
    order=("${methods[@]}")
  fi
  echo "[round $r/$rounds] work=$work order=${order[*]}" >&2

  for m in "${order[@]}"; do
    out="$logd/$(date +%s%N)_w${WORKER_ID:-0}_${m}"
    mkdir -p "$out"
    cp "$meta" "$out/meta.json" 2>/dev/null || true

    {
      echo "SEED=$RUN_RANDOM_SEED"
      echo "ROUND=$r"
      echo "RUN_TAG=${RUN_TAG:-}"
      echo "WORKER_ID=${WORKER_ID:-}"
      echo "E2_CONC=${E2_CONC:-1}"
      echo "E2_MEM_PROFILE=${E2_MEM_PROFILE:-ample}"
      echo "PKG_TOOL=$PKG_TOOL"
      [[ -n "${CG_MEM_MAX_BYTES:-}" ]] && echo "CG_MEM_MAX_BYTES=${CG_MEM_MAX_BYTES}"
    } > "$out/meta.extras"

    e2e_start_ns="$(boottime_now_ns)"
    echo "E2E_START_NS=$e2e_start_ns" >> "$out/meta.extras"

    per_cache_dir="$out/pkg-cache"
    per_yarn_cache_dir="$out/yarn-cache"

    TAR_EXTRACT_MODE=""
    TAR_EXTRACT_TAR=""

    # Deterministic stampede / synchronization points
    if should_barrier_method "$m"; then
      btag="run_${RUN_TAG:-none}_${proj}_r${r}_${m}"
      barrier_wait "$btag.pre" "${E2_CONC:-1}" "${E2_BARRIER_TIMEOUT_SEC:-120}"
    else
      btag="run_${RUN_TAG:-none}_${proj}_r${r}_${m}"
    fi

    # Drop caches in a conc-safe way (optional once-per-method)
    maybe_drop_caches "$btag" || true

    cmd=""
    case "$m" in
      baseline_full)
        a2_unmount_if_mounted || true
        svsafe_unmount_if_mounted || true
        ensure_rw_node_modules

        if [[ "${E2_SKIP_RM_NODE_MODULES:-0}" != "1" ]]; then
          pre_rm="$inline_safe_rm;"
        else
          pre_rm='echo "[guard rm] skip rm -rf node_modules";'
        fi

        if [[ "${E2_SKIP_INSTALL:-0}" != "1" ]]; then
          if [[ -n "${E2_INSTALL_CMD:-}" ]]; then
            do_ci="$E2_INSTALL_CMD;"
          else
            do_ci="$(default_install_cmd);"
          fi
        else
          do_ci='echo "[guard install] skip install (E2_SKIP_INSTALL=1)";'
        fi

        cmd="${pre_rm} ${do_ci}"
        ;;

      baseline_no_cache)
        a2_unmount_if_mounted || true
        svsafe_unmount_if_mounted || true
        ensure_rw_node_modules

        if [[ "${E2_SKIP_RM_NODE_MODULES:-0}" != "1" ]]; then
          pre_rm="$inline_safe_rm;"
        else
          pre_rm='echo "[guard rm] skip rm -rf node_modules";'
        fi

        if [[ "${E2_SKIP_INSTALL:-0}" != "1" ]]; then
          if [[ -n "${E2_INSTALL_CMD:-}" ]]; then
            do_ci="$E2_INSTALL_CMD;"
          else
            mkdir -p "$per_cache_dir" "$per_yarn_cache_dir"
            do_ci="$(default_install_cmd_with_cache "$per_cache_dir");"
          fi
        else
          do_ci='echo "[guard install] skip install (E2_SKIP_INSTALL=1)";'
        fi

        cmd="${pre_rm} ${do_ci}"
        ;;

      b2_frontier_only)
        a2_unmount_if_mounted || true
        svsafe_unmount_if_mounted || true
        ensure_rw_node_modules

        if [[ "${E2_SKIP_RM_NODE_MODULES:-0}" != "1" ]]; then
          pre_rm="$inline_safe_rm;"
        else
          pre_rm='echo "[guard rm] skip rm -rf node_modules";'
        fi

        cnt=$(tar -tf "$pkgd/nm.frontier.tar" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${cnt:-0}" -le 1 ]]; then
          echo "[fatal] nm.frontier.tar is empty (cnt=${cnt:-0}); should have been rebuilt earlier" >&2
          exit 4
        fi

        TAR_EXTRACT_MODE="b2_frontier_only"
        TAR_EXTRACT_TAR="$pkgd/nm.frontier.tar"

        cmd="${pre_rm} \
mkdir -p node_modules; \
echo TAR_TS_DISABLED=1 >> \"$out/meta.extras\"; \
tar xf \"$pkgd/nm.frontier.tar\"; rc_tar=\$?; \
exit \$rc_tar"

        ;;

      b2_frontier_plus_full)
        a2_unmount_if_mounted || true
        svsafe_unmount_if_mounted || true
        ensure_rw_node_modules

        if [[ "${E2_SKIP_RM_NODE_MODULES:-0}" != "1" ]]; then
          pre_rm="$inline_safe_rm;"
        else
          pre_rm='echo "[guard rm] skip rm -rf node_modules";'
        fi

        cnt=$(tar -tf "$pkgd/nm.frontier.tar" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${cnt:-0}" -le 1 ]]; then
          echo "[fatal] nm.frontier.tar is empty (cnt=${cnt:-0}); should have been rebuilt earlier" >&2
          exit 4
        fi

        if [[ "${E2_SKIP_INSTALL:-0}" != "1" ]]; then
          if [[ -n "${E2_INSTALL_CMD:-}" ]]; then
            do_ci="$E2_INSTALL_CMD;"
          else
            do_ci="$(default_install_cmd);"
          fi
        else
          do_ci='echo "[guard install] skip install (E2_SKIP_INSTALL=1)";'
        fi

        TAR_EXTRACT_MODE="b2_frontier_plus_full"
        TAR_EXTRACT_TAR="$pkgd/nm.frontier.tar"

        cmd="${pre_rm} \
mkdir -p node_modules; \
ts_tar_s=\$(date +%s%N); tar xf \"$pkgd/nm.frontier.tar\"; rc_tar=\$?; ts_tar_e=\$(date +%s%N); \
echo TAR_EXTRACT_MS=\$(( ( (ts_tar_e-ts_tar_s) + 999999 ) / 1000000 )) >> \"$out/meta.extras\"; \
echo TAR_EXTRACT_US=\$(( (ts_tar_e-ts_tar_s) / 1000 )) >> \"$out/meta.extras\"; \
echo TAR_EXTRACT_OK=\$(( rc_tar==0 ? 1 : 0 )) >> \"$out/meta.extras\"; \
[[ \$rc_tar -ne 0 ]] && exit \$rc_tar; \
${do_ci}"
        ;;

      a2_shared_ro)
        svsafe_unmount_if_mounted || true
        a2_mount_from_seed
        echo "A2_MOUNT_MS=${A2_MOUNT_MS_LAST}" >> "$out/meta.extras"
        echo "A2_MOUNT_RO_OK=${A2_MOUNT_RO_OK_LAST}" >> "$out/meta.extras"
        [[ -n "${A2_SEED_PATH_LAST:-}" ]] && echo "A2_SEED_PATH=${A2_SEED_PATH_LAST}" >> "$out/meta.extras"
        [[ -f "$a2_status_file" ]] && cp -n "$a2_status_file" "$out/.a2_status" 2>/dev/null || true
        cmd=':'
        ;;

      svsafe_shared_ro|svsafe_shared_ro_no_cache)
        a2_unmount_if_mounted || true

        if should_barrier_method "$m"; then
          # cold purge by worker0 (optional), then stampede-sync to observe wait
          svsafe_cold_purge_once "$proj" "$root"
          barrier_wait "$btag.cold" "${E2_CONC:-1}" "${E2_BARRIER_TIMEOUT_SEC:-120}"
        fi

        svsafe_mount_shared_ro
        [[ -n "${SVSAFE_SETUP_WALL_MS_LAST:-}" ]] && echo "SVSAFE_SETUP_WALL_MS=${SVSAFE_SETUP_WALL_MS_LAST}" >> "$out/meta.extras"

        if [[ -r "$svsafe_status_file" ]]; then
          cp -n "$svsafe_status_file" "$out/.svsafe_status" 2>/dev/null || true
          kv_append_if_present "$svsafe_status_file" "SVSAFE_LOCK_WAIT_MS" "$out/meta.extras" "SVSAFE_LOCK_WAIT_MS"
          kv_append_if_present "$svsafe_status_file" "SVSAFE_BUILD_MS"     "$out/meta.extras" "SVSAFE_BUILD_MS"
          kv_append_if_present "$svsafe_status_file" "SVSAFE_INSTALL_MS"   "$out/meta.extras" "SVSAFE_INSTALL_MS"
          kv_append_if_present "$svsafe_status_file" "SVSAFE_PUBLISH_MS"   "$out/meta.extras" "SVSAFE_PUBLISH_MS"
          kv_append_if_present "$svsafe_status_file" "SVSAFE_PROVISION_MS" "$out/meta.extras" "SVSAFE_PROVISION_MS"
          kv_append_if_present "$svsafe_status_file" "SVSAFE_REUSED"       "$out/meta.extras" "SVSAFE_REUSED"
          kv_append_if_present "$svsafe_status_file" "SVSAFE_KEY"          "$out/meta.extras" "SVSAFE_KEY"
        fi

        cmd=':'
        ;;

      *)
        echo "[fatal] unknown method: $m" >&2
        exit 3
        ;;
    esac

    [[ -n "${TAR_EXTRACT_MODE:-}" ]] && echo "TAR_EXTRACT_MODE=${TAR_EXTRACT_MODE}" >> "$out/meta.extras"
    [[ -n "${TAR_EXTRACT_TAR:-}"  ]] && echo "TAR_EXTRACT_TAR=${TAR_EXTRACT_TAR}" >> "$out/meta.extras"

    cmd="$(wrap_with_net_sandbox "$cmd")"
    printf -v cmd_esc "%q" "$cmd"

    export RUN_TAG="${RUN_TAG:-}"
    export WORKER_ID="${WORKER_ID:-}"
    export E2_CONC="${E2_CONC:-1}"
    export E2_MEM_PROFILE="${E2_MEM_PROFILE:-ample}"
    export CG_MEM_MAX_BYTES="${CG_MEM_MAX_BYTES:-}"

    set +e
    /usr/bin/time -v -o "$out/timev_extract.log" \
      bash -lc 'node "'"$root"'/e2_tools/e2wrap.js" -- '"$cmd_esc" \
      > "$out/wrap_extract.log" 2>&1
    rc_extract=$?
    set -e

    if ! grep -q 'PHASE2_BOOTTIME_MS' "$out/wrap_extract.log"; then
      echo "[warn] wrap_extract.log missing PHASE2_BOOTTIME_MS for $m (out=$(basename "$out"))" >&2
    fi

    rc_smoke=0
    rc_extra=0

    if [[ "$E2_E8_COVERAGE" = "1" ]]; then
      echo "[e8] coverage mode enabled for method=$m" >&2
      set +e
      strace -f -tt -qq -s 300 \
        -o "$out/strace_smoke.log" \
        -e trace=%file -e status=successful \
        node "$smoke_js" \
        >"$out/stdout_run.log" 2>"$out/stderr_run.log"
      rc_smoke=$?
      set -e

      if [[ -n "${E2_E8_EXTRA_CMD:-}" ]]; then
        echo "[e8] extra workload: $E2_E8_EXTRA_CMD" >&2
        set +e
        strace -f -tt -qq -s 300 \
          -o "$out/strace_extra.log" \
          -e trace=%file -e status=successful \
          bash -lc "$E2_E8_EXTRA_CMD" \
          >"$out/stdout_extra.log" 2>"$out/stderr_extra.log"
        rc_extra=$?
        set -e
      fi
    else
      set +e
      /usr/bin/time -v -o "$out/timev_run.log" \
        bash -lc 'node '"$smoke_js"'' \
        > "$out/stdout_run.log" 2>"$out/stderr_run.log"
      rc_smoke=$?
      set -e
    fi

    method_exit_code=0
    for rc in "$rc_extract" "$rc_smoke" "$rc_extra"; do
      if [[ "$rc" -ne 0 && "$method_exit_code" -eq 0 ]]; then
        method_exit_code="$rc"
      fi
    done

    e2e_end_ns="$(boottime_now_ns)"
    e2e_wall_ms=$(( (e2e_end_ns - e2e_start_ns) / 1000000 ))
    echo "E2E_END_NS=$e2e_end_ns" >> "$out/meta.extras"
    echo "E2E_WALL_MS=$e2e_wall_ms" >> "$out/meta.extras"

    phase2_bt_ms="$(grep -oE 'PHASE2_BOOTTIME_MS[[:space:]]+[0-9]+' "$out/wrap_extract.log" | awk '{print $2}' | tail -1 || true)"
    if [[ -n "${phase2_bt_ms:-}" && "$phase2_bt_ms" =~ ^[0-9]+$ ]]; then
      e2e_residual_ms=$(( e2e_wall_ms - phase2_bt_ms ))
      echo "E2E_RESIDUAL_MS=$e2e_residual_ms" >> "$out/meta.extras"
      ratio_bp="$(awk -v p="$phase2_bt_ms" -v e="$e2e_wall_ms" 'BEGIN{if(e>0) printf "%.4f", p/e; else printf ""}')"
      [[ -n "${ratio_bp:-}" ]] && echo "PHASE2_OVER_E2E_RATIO=$ratio_bp" >> "$out/meta.extras"

      # setup_ms + total_ms (for A2/SV-safe fairness)
      setup_ms="0"
      case "$m" in
        a2_shared_ro)
          setup_ms="$(kv_get "$out/meta.extras" "A2_MOUNT_MS" 2>/dev/null || true)"
          ;;
        svsafe_shared_ro|svsafe_shared_ro_no_cache)
          setup_ms="$(kv_get "$out/meta.extras" "SVSAFE_PROVISION_MS" 2>/dev/null || true)"
          if [[ -z "${setup_ms:-}" ]]; then
            setup_ms="$(kv_get "$out/meta.extras" "SVSAFE_MOUNT_MS" 2>/dev/null || true)"
          fi
          ;;
        *)
          setup_ms="0"
          ;;
      esac
      [[ -z "${setup_ms:-}" ]] && setup_ms="0"
      [[ ! "$setup_ms" =~ ^[0-9]+$ ]] && setup_ms="0"

      total_ms=$(( phase2_bt_ms + setup_ms ))
      echo "E2_SETUP_MS=$setup_ms" >> "$out/meta.extras"
      echo "E2_TOTAL_MS=$total_ms" >> "$out/meta.extras"
    fi

    echo "EXIT_CODE=$method_exit_code" >> "$out/meta.extras"
  done
done

# --- summarization policy ----------------------------------------------------
# Default: skip per-worker summarize to avoid races (sweep rebuilds once per project).
E2_DRIVER_SUMMARIZE="${E2_DRIVER_SUMMARIZE:-0}"
if [[ "$E2_DRIVER_SUMMARIZE" = "1" ]]; then
  # If conc>1, only worker0 should summarize
  if [[ "${E2_CONC:-1}" -le 1 || "${WORKER_ID:-0}" = "0" ]]; then
    python3 "$root/bin/summarize_from_logs.py" --project "$proj" || true
  fi
fi
