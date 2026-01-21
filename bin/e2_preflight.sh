#!/usr/bin/env bash
set -euo pipefail

# ---- Config switches (observe-only by default; enforce only when opted-in) --
: "${E2_ROOT:=${HOME}/experiment/e_ex}"  # fallback only; prefer exporting E2_ROOT explicitly

: "${E2_SET_CPU_GOV:=0}"                 # 1=force governor, 0=report-only
: "${E2_TARGET_CPU_GOV:=performance}"    # target when enforcing
: "${E2_DISABLE_AUTO_UPDATES:=0}"        # 1=mask apt-daily services/timers
: "${E2_ULIMIT_NOFILE:=}"                # e.g. 1048576 (empty=skip)
: "${E2_LOCK_NODE_VERSION:=}"            # e.g. v20.19.5 (empty=skip)
: "${E2_LOCK_NPM_VERSION:=}"             # e.g. 10.8.2 (empty=skip)
: "${E2_LOCK_YARN_VERSION:=}"            # e.g. 4.5.3  (empty=skip；只在需要時檢查)

# IO controller enable behavior:
: "${E2_TRY_ENABLE_IO_CONTROLLER:=1}"    # 1=best-effort enable +io along cgroup chain, 0=skip
: "${E2_REQUIRE_IO_STAT:=0}"             # 1=fail if io.stat not readable, 0=warn only

# Extra checks for SV-safe / mount-heavy methods (observe-only by default)
: "${E2_REQUIRE_FLOCK:=0}"               # 1=fail if flock missing, 0=warn only
: "${E2_REQUIRE_MOUNT_TOOLS:=0}"         # 1=fail if mount/mountpoint missing, 0=warn only
: "${E2_REQUIRE_MEMORY_MAX_WRITABLE:=0}" # 1=fail if memory.max not writable (or sudo-writable)
: "${E2_WARN_ACTIVATION_FIELDS:=1}"      # 1=print hint when activation/breakdown fields enabled

warn() { echo "WARN: $*" >&2; }
info() { echo "INFO: $*" >&2; }

ensure_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || { echo "FATAL: '$c' not found" >&2; exit 1; }
}

ensure_cmd_opt() {
  local c="$1" req="$2"
  if ! command -v "$c" >/dev/null 2>&1; then
    if [[ "$req" == "1" ]]; then
      echo "FATAL: '$c' not found" >&2
      exit 1
    else
      warn "'$c' not found (optional)"
      return 1
    fi
  fi
  return 0
}

realpath_fallback() {
  # resolve symlink if possible; if realpath is missing, fallback to readlink -f (may fail on some systems)
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p" 2>/dev/null || echo "$p"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f -- "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

is_mountpoint() {
  # true if path is a mountpoint (follow symlink best-effort)
  local p="$1" rp=""
  rp="$(realpath_fallback "$p")"
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q -- "$rp" && return 0
  fi
  awk -v m="$rp" '$2==m{found=1} END{exit (found?0:1)}' /proc/mounts
}

is_ro_mount() {
  local p="$1" rp=""
  rp="$(realpath_fallback "$p")"
  awk -v m="$rp" '$2==m{ if (index($4,"ro")>0) ro=1 } END{ exit ro?0:1 }' /proc/mounts
}

mask_auto_updates() {
  # Ubuntu/Debian family best-effort; requires sudo
  local units=(
    apt-daily.timer apt-daily-upgrade.timer
    apt-daily.service apt-daily-upgrade.service
  )
  for u in "${units[@]}"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
      sudo systemctl mask --now "$u" || true
    fi
  done
}

set_cpu_governor_all() {
  local target="$1"
  # best-effort across online CPUs; requires sudo for writes
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -e "$f" ]] || continue
    echo "$target" | sudo tee "$f" >/dev/null || true
  done
}

# ---- cgroup helpers ---------------------------------------------------------
cgroup2_is_mounted() {
  [[ -r /sys/fs/cgroup/cgroup.controllers ]] && mount | grep -q 'type cgroup2'
}

get_self_cgroup_relpath() {
  # return like: /user.slice/user-1000.slice/session-7062.scope
  # From /proc/self/cgroup: "0::/path"
  awk -F: '$1=="0"{print $3; exit}' /proc/self/cgroup 2>/dev/null || true
}

has_controller() {
  local cgdir="$1" ctrl="$2"
  [[ -r "${cgdir}/cgroup.controllers" ]] || return 1
  grep -qw "$ctrl" "${cgdir}/cgroup.controllers"
}

subtree_has_enabled() {
  local cgdir="$1" ctrl="$2"
  [[ -r "${cgdir}/cgroup.subtree_control" ]] || return 1
  grep -Eq "(^|[[:space:]])\\+${ctrl}([[:space:]]|$)" "${cgdir}/cgroup.subtree_control"
}

enable_subtree_controller() {
  local cgdir="$1" ctrl="$2"
  # Need write permission (root)
  if [[ ! -w "${cgdir}/cgroup.subtree_control" ]]; then
    sudo test -w "${cgdir}/cgroup.subtree_control" 2>/dev/null || return 1
  fi
  sudo sh -c "echo +${ctrl} > '${cgdir}/cgroup.subtree_control'" 2>/dev/null
}

enable_io_along_chain() {
  # Enable +io from root down to parent of current leaf, because subtree_control affects children.
  local rel="$1"
  local root="/sys/fs/cgroup"
  local cur="$root"
  local IFS='/'
  local -a parts=()
  local p

  [[ -n "$rel" ]] || return 1
  rel="${rel#/}"
  read -r -a parts <<< "$rel"

  local last_index=$(( ${#parts[@]} - 1 ))
  if (( last_index < 0 )); then
    return 1
  fi

  if has_controller "$root" io; then
    if ! subtree_has_enabled "$root" io; then
      info "[preflight][io] enable +io at $root (root)"
      enable_subtree_controller "$root" io || warn "[io] cannot enable +io at $root (need root or policy)"
    fi
  else
    warn "[io] 'io' not listed in ${root}/cgroup.controllers"
  fi

  for ((i=0; i<last_index; i++)); do
    p="${parts[$i]}"
    cur="${cur}/${p}"
    [[ -d "$cur" ]] || { warn "[io] missing cgroup dir: $cur"; continue; }

    if has_controller "$cur" io; then
      if ! subtree_has_enabled "$cur" io; then
        info "[preflight][io] enable +io at $cur"
        enable_subtree_controller "$cur" io || warn "[io] cannot enable +io at $cur (need root or policy)"
      fi
    else
      warn "[io] 'io' not listed in ${cur}/cgroup.controllers"
    fi
  done
}

check_io_stat_readable() {
  local rel="$1"
  local cgdir="/sys/fs/cgroup${rel}"
  [[ -r "${cgdir}/io.stat" ]]
}

check_memory_max_writable() {
  # Check whether memory.max is writable for current cgroup. For sweep, child cgroups will be created under this node.
  # If not writable directly, allow sudo-writable.
  local rel="$1"
  local cgdir="/sys/fs/cgroup${rel}"
  local f="${cgdir}/memory.max"
  [[ -e "$f" ]] || return 1
  [[ -w "$f" ]] && return 0
  sudo test -w "$f" 2>/dev/null
}

# ---- Pretty summary ---------------------------------------------------------
info "[preflight] options: E2_ROOT=${E2_ROOT}  E2_SET_CPU_GOV=${E2_SET_CPU_GOV} target=${E2_TARGET_CPU_GOV}  E2_DISABLE_AUTO_UPDATES=${E2_DISABLE_AUTO_UPDATES}  E2_ULIMIT_NOFILE=${E2_ULIMIT_NOFILE:-<skip>}  lock Node=${E2_LOCK_NODE_VERSION:-<skip>} NPM=${E2_LOCK_NPM_VERSION:-<skip>} Yarn=${E2_LOCK_YARN_VERSION:-<skip>}  IO: try_enable=${E2_TRY_ENABLE_IO_CONTROLLER} require_io_stat=${E2_REQUIRE_IO_STAT}  SV-safe: require_flock=${E2_REQUIRE_FLOCK} require_mount_tools=${E2_REQUIRE_MOUNT_TOOLS} require_memmax=${E2_REQUIRE_MEMORY_MAX_WRITABLE}"

# ---- Basic tooling ----------------------------------------------------------
for c in bash awk sed grep cut sort tr uniq xargs tar strace node npm python3 /usr/bin/time; do
  ensure_cmd "$c"
done

# Optional tools used by some methods
ensure_cmd_opt mount "${E2_REQUIRE_MOUNT_TOOLS}"
ensure_cmd_opt mountpoint "${E2_REQUIRE_MOUNT_TOOLS}"
ensure_cmd_opt flock "${E2_REQUIRE_FLOCK}"

# ---- Version locks (fail-fast if specified and mismatch) --------------------
install_cmd="${E2_INSTALL_CMD:-}"

node_v="$(node -v 2>/dev/null || echo unknown)"
npm_v="$(npm -v 2>/dev/null || echo unknown)"

need_yarn=0
if [[ "$install_cmd" == *yarn* ]] || [[ -n "${E2_LOCK_YARN_VERSION}" ]]; then
  need_yarn=1
fi

yarn_v=""
if (( need_yarn )); then
  ensure_cmd yarn
  yarn_v="$(yarn -v 2>/dev/null || echo unknown)"
else
  if command -v yarn >/dev/null 2>&1; then
    yarn_v="$(yarn -v 2>/dev/null || echo unknown)"
  else
    yarn_v="(not_used)"
  fi
fi

info "[preflight] Node=${node_v} NPM=${npm_v} Yarn=${yarn_v}"

if [[ -n "${E2_LOCK_NODE_VERSION}" && "$node_v" != "$E2_LOCK_NODE_VERSION" ]]; then
  echo "FATAL: NODE_VERSION mismatch: want ${E2_LOCK_NODE_VERSION}, got ${node_v}" >&2
  exit 3
fi
if [[ -n "${E2_LOCK_NPM_VERSION}" && "$npm_v" != "$E2_LOCK_NPM_VERSION" ]]; then
  echo "FATAL: NPM_VERSION mismatch: want ${E2_LOCK_NPM_VERSION}, got ${npm_v}" >&2
  exit 3
fi
if (( need_yarn )) && [[ -n "${E2_LOCK_YARN_VERSION}" && "$yarn_v" != "$E2_LOCK_YARN_VERSION" ]]; then
  echo "FATAL: YARN_VERSION mismatch: want ${E2_LOCK_YARN_VERSION}, got ${yarn_v}" >&2
  exit 3
fi

# ---- Kernel & mounts --------------------------------------------------------
echo "[preflight] kernel & mount"
grep -m1 'cgroup2' /proc/filesystems >/dev/null || warn "no cgroup2 in filesystems"

if cgroup2_is_mounted; then
  : # cgroup v2 OK
else
  warn "cgroup2 not mounted or /sys/fs/cgroup missing cgroup.controllers"
fi

# ---- PSI availability -------------------------------------------------------
if [[ ! -r /proc/pressure/cpu || ! -r /proc/pressure/io || ! -r /proc/pressure/memory ]]; then
  warn "PSI files missing (/proc/pressure/*) — PSI_* 指標將空白"
fi

# ---- Controllers ------------------------------------------------------------
echo "[preflight] controllers (root)"
ctrl="$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || true)"
echo "controllers: $ctrl"
sc="$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true)"
echo "subtree_control: $sc"

if ! grep -qw 'io' <<<"$ctrl"; then
  warn "io controller not listed at root; io.stat 可能無法使用"
fi

# ---- Resolve current cgroup path and enable +io along chain -----------------
self_rel="$(get_self_cgroup_relpath)"
if [[ -z "$self_rel" ]]; then
  warn "cannot resolve /proc/self/cgroup; skip +io enable checks"
else
  echo "[preflight] self cgroup: ${self_rel}"
  if [[ "${self_rel}" == *"/session-"*.scope* ]]; then
    warn "目前在 session scope 下執行（路徑會隨 session 變動）。正式跑分可考慮 systemd-run --scope 讓 cgroup 路徑穩定。"
  fi

  if (( E2_TRY_ENABLE_IO_CONTROLLER )); then
    if grep -qw 'io' <<<"$ctrl"; then
      enable_io_along_chain "$self_rel"
    fi
  fi

  if check_io_stat_readable "$self_rel"; then
    info "[preflight][io] io.stat is readable at /sys/fs/cgroup${self_rel}/io.stat"
  else
    if (( E2_REQUIRE_IO_STAT )); then
      echo "FATAL: io.stat not readable at /sys/fs/cgroup${self_rel}/io.stat (IO accounting not available)" >&2
      exit 3
    else
      warn "[io] io.stat not readable at /sys/fs/cgroup${self_rel}/io.stat (cg_io_rbytes_delta 可能空白或不可靠)"
    fi
  fi

  # memory.max writability (for sweep/worker cgroups)
  if check_memory_max_writable "$self_rel"; then
    info "[preflight][memcg] memory.max is writable at /sys/fs/cgroup${self_rel}/memory.max (or sudo-writable)"
  else
    if (( E2_REQUIRE_MEMORY_MAX_WRITABLE )); then
      echo "FATAL: memory.max not writable at /sys/fs/cgroup${self_rel}/memory.max (need permission/policy)" >&2
      exit 3
    else
      warn "[memcg] memory.max not writable at /sys/fs/cgroup${self_rel}/memory.max (sweep 建 cgroup 時可能需要 sudo 或 policy 調整)"
    fi
  fi
fi

# ---- boottime_now -----------------------------------------------------------
if ! command -v boottime_now >/dev/null 2>&1 && [[ ! -x "$(dirname "$0")/boottime_now" ]]; then
  warn "boottime_now 不存在或不可執行；請確認 bin/boottime_now 已建立並 chmod +x"
fi

# ---- CPU governor (optional enforcement) -----------------------------------
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
  gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
  echo "[preflight] cpu_governor=$gov"
  if [[ "${E2_SET_CPU_GOV}" == "1" && "$gov" != "$E2_TARGET_CPU_GOV" ]]; then
    info "Setting CPU governor -> ${E2_TARGET_CPU_GOV}"
    set_cpu_governor_all "${E2_TARGET_CPU_GOV}"
    gov2="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
    echo "[preflight] cpu_governor(after)=${gov2}"
  fi
else
  info "無法讀取 CPU governor（非致命）"
fi

# ---- Disable auto updates (optional) ----------------------------------------
if [[ "${E2_DISABLE_AUTO_UPDATES}" == "1" ]]; then
  info "Masking apt-daily timers/services (best-effort)"
  mask_auto_updates
fi

# ---- ulimit (shell scope) ---------------------------------------------------
if [[ -n "${E2_ULIMIT_NOFILE}" ]]; then
  ulimit -n "${E2_ULIMIT_NOFILE}" || warn "failed to set ulimit -n ${E2_ULIMIT_NOFILE}"
fi

echo "[preflight] docker/nerdctl log timing"
echo "OK: driver 會在 release barrier 前就啟動 logs -f。"

# ---- Hints for activation / breakdown fields (optional) ---------------------
if (( E2_WARN_ACTIVATION_FIELDS )); then
  if [[ "${E2_ENABLE_ACTIVATION_METRICS:-0}" == "1" ]]; then
    info "[preflight] activation/breakdown metrics enabled: summary.csv 將包含 JOB_ACTIVATION_MS / A2_MOUNT_MS 等欄位（如 driver/summarizer 支援）"
  fi
fi

# ---- A2 掛載檢查（可選） ---------------------------------------------------
if [[ "${ENABLE_A2:-0}" -eq 1 ]]; then
  proj="${PROJ:-express-app}"
  nm="${E2_ROOT}/projects/${proj}/node_modules"

  if [[ -L "$nm" ]]; then
    echo "[preflight][A2] node_modules 是 symlink（允許的 fallback）"
  elif is_mountpoint "$nm"; then
    if is_ro_mount "$nm"; then
      echo "[preflight][A2] node_modules 為唯讀掛載"
    else
      warn "[A2] $nm 是掛載點但不是唯讀（仍可跑，但請在結果上標註）"
    fi
  else
    echo "FATAL[A2]: 要跑 A2 但 $nm 不是掛載點/符號連結。請先執行: bin/e2_a2_setup.sh $proj" >&2
    exit 3
  fi
fi

# ---- SV-safe 先決條件提示（可選） ------------------------------------------
if [[ "${ENABLE_SVSAFE:-0}" -eq 1 ]]; then
  if ! command -v flock >/dev/null 2>&1; then
    if (( E2_REQUIRE_FLOCK )); then
      echo "FATAL[SVSAFE]: ENABLE_SVSAFE=1 但 flock 不存在" >&2
      exit 3
    else
      warn "[SVSAFE] flock 不存在；svsafe_shared_nm_ro 可能無法正確提供並行安全"
    fi
  fi
  if ! command -v mount >/dev/null 2>&1 || ! command -v mountpoint >/dev/null 2>&1; then
    if (( E2_REQUIRE_MOUNT_TOOLS )); then
      echo "FATAL[SVSAFE]: ENABLE_SVSAFE=1 但 mount/mountpoint 不存在" >&2
      exit 3
    else
      warn "[SVSAFE] mount/mountpoint 不存在；svsafe_shared_nm_ro 可能無法做 ro bind mount 或 mountpoint 檢查"
    fi
  fi
fi

echo "[preflight] done"
