#!/usr/bin/env bash
# e2_svsafe_setup.sh <project>
#
# SV-safe shared volume baseline (safe-ish shared node_modules):
# - versioned by lockfile hash (+ optional key extras)
# - build with lock (flock)
# - build into temp dir, then atomic rename publish
# - runtime mounts published node_modules into PROJECT_DIR/node_modules (read-only bind mount by default)
# - cleans up partial builds
#
# Metrics (ms):
#   SVSAFE_LOCK_WAIT_MS, SVSAFE_BUILD_MS, SVSAFE_INSTALL_MS, SVSAFE_PUBLISH_MS,
#   SVSAFE_MOUNT_MS, SVSAFE_PROVISION_MS, SVSAFE_REUSED
#
# Status file (per project dir):
#   $PROJECT_DIR/.svsafe_status
#
# Published layout:
#   $E2_ROOT/shared_deps/svsafe/<proj>/<key>/node_modules/...
#   $E2_ROOT/shared_deps/svsafe/<proj>/<key>/READY
#   $E2_ROOT/shared_deps/svsafe/<proj>/<key>/META
#
# Compatibility:
# - PROJECT_DIR override (worker clones)
# - E2_INSTALL_CMD override
# - If already mounted RO at node_modules, treat as OK and exit 0 (fast-path), unless disabled.
#
# New (per your requested modifications):
# - E2_SVSAFE_DISABLE_FASTPATH=1: even if already RO mounted, DO NOT exit early; still go through lock/reuse path.
# - Status markers:
#   SVSAFE_FASTPATH=1/0
#   SVSAFE_READY_HIT=1/0

set -euo pipefail

proj="${1:?Usage: e2_svsafe_setup.sh <project>}"

: "${E2_ROOT:=$HOME/experiment/e_ex}"
: "${PROJECT_DIR:=$E2_ROOT/projects/$proj}"

# SV-safe root (shared_deps/)
: "${E2_SVSAFE_ROOT:=$E2_ROOT/shared_deps/svsafe}"

# lock + build behavior
: "${E2_SVSAFE_LOCK_TIMEOUT:=300}"          # seconds
: "${E2_SVSAFE_FORCE_REBUILD:=0}"           # 1=remove existing published dir and rebuild (once per TTL window)
: "${E2_SVSAFE_FORCE_REBUILD_TTL_SEC:=600}" # seconds; avoid repeated rebuild in a concurrent sweep
: "${E2_SVSAFE_CLEAN_PARTIAL:=1}"           # 1=auto cleanup partial/unready dirs
: "${E2_SVSAFE_KEEP_TMP:=0}"                # 1=keep temp dir on failure for debugging
: "${E2_SVSAFE_REQUIRE_RO:=1}"              # 1=after mount require ro; 0=warn only

# key composition options
: "${E2_SVSAFE_KEY_EXTRA:=}"                # extra string appended into key material
: "${E2_SVSAFE_KEY_INCLUDE_RUNTIME:=1}"     # 1=include node/npm + uname into key; 0=only lockfile hash

# install behavior
: "${E2_INSTALL_CMD:=}"                     # optional override
: "${E2_SKIP_INSTALL:=0}"                   # 1=skip everything (for experiments)

# NEW: fast-path control
: "${E2_SVSAFE_DISABLE_FASTPATH:=0}"        # 1=disable "already mounted RO -> exit" fast-path

have_cmd() { command -v "$1" >/dev/null 2>&1; }

info() { echo "[svsafe] $*" >&2; }
warn() { echo "WARN[svsafe]: $*" >&2; }

SVSAFE_EXIT_CODE=0
SVSAFE_FAIL_REASON=""

die()  {
  SVSAFE_EXIT_CODE=3
  SVSAFE_FAIL_REASON="$*"
  echo "FATAL[svsafe]: $*" >&2
  exit 3
}

ensure_cmd() {
  local c="$1"
  have_cmd "$c" || die "required command not found: $c"
}

# ---- time helpers -----------------------------------------------------------
now_ns() {
  local x=""
  if have_cmd date; then
    x="$(date +%s%N 2>/dev/null || true)"
    if [[ "$x" =~ ^[0-9]{16,}$ ]]; then
      echo "$x"
      return 0
    fi
  fi
  if have_cmd python3; then
    python3 - <<'PY'
import time
print(time.time_ns())
PY
    return 0
  fi
  echo "$(( $(date +%s) * 1000000000 ))"
}

ns_to_ms() {
  local ns="$1"
  if [[ -z "$ns" ]]; then echo 0; return 0; fi
  echo "$(( ns / 1000000 ))"
}

file_mtime_epoch() {
  local f="$1"
  if [[ ! -e "$f" ]]; then
    echo 0
    return 0
  fi
  if have_cmd stat; then
    local t=""
    t="$(stat -c %Y "$f" 2>/dev/null || true)"
    if [[ "$t" =~ ^[0-9]+$ ]]; then
      echo "$t"; return 0
    fi
    t="$(stat -f %m "$f" 2>/dev/null || true)"
    if [[ "$t" =~ ^[0-9]+$ ]]; then
      echo "$t"; return 0
    fi
  fi
  if have_cmd python3; then
    python3 - "$f" <<'PY'
import os, sys
print(int(os.path.getmtime(sys.argv[1])))
PY
    return 0
  fi
  echo 0
}

epoch_now() {
  if have_cmd date; then
    date +%s
  elif have_cmd python3; then
    python3 - <<'PY'
import time
print(int(time.time()))
PY
  else
    echo 0
  fi
}

# ---- privilege helpers ------------------------------------------------------
is_root() { [[ "$(id -u)" -eq 0 ]]; }

sudo_check_noninteractive() {
  if is_root; then
    return 0
  fi
  ensure_cmd sudo
  # non-interactive check; fail fast to avoid hanging sweeps
  if ! sudo -n true 2>/dev/null; then
    die "sudo requires password (non-interactive). Please run 'sudo -v' beforehand or configure NOPASSWD for mount/umount."
  fi
}

run_mount() {
  if is_root; then
    mount "$@"
  else
    sudo -n mount "$@"
  fi
}

run_umount_lazy() {
  local p="$1"
  if is_mountpoint "$p"; then
    if is_root; then
      umount -l "$p" 2>/dev/null || true
    else
      sudo -n umount -l "$p" 2>/dev/null || true
    fi
  fi
}

rmrf_best_effort() {
  local p="$1"
  rm -rf "$p" 2>/dev/null || true
  if [[ -e "$p" ]] && ! is_root && have_cmd sudo; then
    sudo -n rm -rf "$p" 2>/dev/null || true
  fi
}

# ---- mount helpers ----------------------------------------------------------
is_mountpoint() {
  local p="$1"
  if have_cmd findmnt; then
    findmnt -no TARGET --target "$p" >/dev/null 2>&1
    return $?
  fi
  if have_cmd mountpoint; then
    mountpoint -q -- "$p"
    return $?
  fi
  awk -v m="$p" '$2==m{found=1} END{exit(found?0:1)}' /proc/mounts
}

is_ro_mount() {
  local p="$1"
  is_mountpoint "$p" || return 1
  if have_cmd findmnt; then
    findmnt -no OPTIONS --target "$p" 2>/dev/null | grep -qw ro
    return $?
  fi
  awk -v m="$p" '$2==m{ if (index($4,"ro")>0) ro=1 } END{ exit ro?0:1 }' /proc/mounts
}

# ---- lockfile detection + key ----------------------------------------------
detect_lockfile() {
  local d="$1"
  if [[ -f "$d/yarn.lock" ]]; then
    echo "$d/yarn.lock"
  elif [[ -f "$d/package-lock.json" ]]; then
    echo "$d/package-lock.json"
  elif [[ -f "$d/npm-shrinkwrap.json" ]]; then
    echo "$d/npm-shrinkwrap.json"
  else
    echo ""
  fi
}

sha256_file() {
  local f="$1"
  if have_cmd sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif have_cmd shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    die "need sha256sum or shasum"
  fi
}

sha256_text() {
  local s="$1"
  if have_cmd sha256sum; then
    printf '%s' "$s" | sha256sum | awk '{print $1}'
  elif have_cmd shasum; then
    printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
  else
    die "need sha256sum or shasum"
  fi
}

compute_key() {
  local lockfile="$1"
  local lockhash
  lockhash="$(sha256_file "$lockfile")"

  if [[ "${E2_SVSAFE_KEY_INCLUDE_RUNTIME}" = "0" ]]; then
    if [[ -n "${E2_SVSAFE_KEY_EXTRA}" ]]; then
      sha256_text "${lockhash}|${E2_SVSAFE_KEY_EXTRA}"
    else
      echo "$lockhash"
    fi
    return 0
  fi

  local node_v npm_v os_sig
  node_v="$(node -v 2>/dev/null || echo unknown)"
  npm_v="$(npm -v 2>/dev/null || echo unknown)"
  os_sig="$(uname -srm 2>/dev/null || echo unknown)"

  local material="lock=${lockhash}|node=${node_v}|npm=${npm_v}|os=${os_sig}"
  if [[ -n "${E2_SVSAFE_KEY_EXTRA}" ]]; then
    material="${material}|extra=${E2_SVSAFE_KEY_EXTRA}"
  fi
  sha256_text "$material"
}

# ---- install command detection ---------------------------------------------
detect_pm() {
  local d="$1"
  if [[ -f "$d/yarn.lock" ]]; then
    echo "yarn"
  else
    echo "npm"
  fi
}

default_install_cmd() {
  local d="$1"
  if [[ -n "${E2_INSTALL_CMD}" ]]; then
    echo "$E2_INSTALL_CMD"
    return 0
  fi
  case "$(detect_pm "$d")" in
    yarn) echo "yarn install --immutable" ;;
    *)    echo "npm ci" ;;
  esac
}

# ---- sanity prerequisites ---------------------------------------------------
if [[ "${E2_SKIP_INSTALL}" = "1" ]]; then
  projdir="$PROJECT_DIR"
  nm="$projdir/node_modules"
  mkdir -p "$projdir" 2>/dev/null || true
  {
    echo "SVSAFE_REUSED=0"
    echo "SVSAFE_LOCK_WAIT_MS=0"
    echo "SVSAFE_BUILD_MS=0"
    echo "SVSAFE_INSTALL_MS=0"
    echo "SVSAFE_PUBLISH_MS=0"
    echo "SVSAFE_MOUNT_MS=0"
    echo "SVSAFE_PROVISION_MS=0"
    echo "SVSAFE_FORCE_REBUILD=$E2_SVSAFE_FORCE_REBUILD"
    echo "SVSAFE_FORCE_REBUILD_TTL_SEC=$E2_SVSAFE_FORCE_REBUILD_TTL_SEC"
    echo "SVSAFE_DISABLE_FASTPATH=$E2_SVSAFE_DISABLE_FASTPATH"
    echo "SVSAFE_FASTPATH=0"
    echo "SVSAFE_READY_HIT=0"
    echo "SVSAFE_EXIT_CODE=0"
    echo "SVSAFE_FAIL_REASON=skipped(E2_SKIP_INSTALL=1)"
    echo "WHEN=$(date -Is)"
  } > "$projdir/.svsafe_status" 2>/dev/null || true
  info "skip (E2_SKIP_INSTALL=1)"
  exit 0
fi

ensure_cmd bash
ensure_cmd awk
ensure_cmd sed
ensure_cmd node
ensure_cmd npm
ensure_cmd flock

# optional
have_cmd rsync || warn "rsync not found; will fallback to tar copy for temp build"

sudo_check_noninteractive

projdir="$PROJECT_DIR"
[[ -d "$projdir" ]] || die "PROJECT_DIR not found: $projdir"

lockfile="$(detect_lockfile "$projdir")"
[[ -n "$lockfile" ]] || die "no lockfile found under $projdir (need yarn.lock or package-lock.json or npm-shrinkwrap.json)"

key="$(compute_key "$lockfile")"

# published layout
base="$E2_SVSAFE_ROOT/$proj/$key"
published_nm="$base/node_modules"
ready="$base/READY"
meta="$base/META"

# lock layout
lockdir="$E2_SVSAFE_ROOT/$proj/.locks"
lockf="$lockdir/$key.lock"

mkdir -p "$lockdir" "$E2_SVSAFE_ROOT/$proj"

nm="$projdir/node_modules"
status_file="$projdir/.svsafe_status"

# metrics init
SVSAFE_REUSED=0
SVSAFE_LOCK_WAIT_MS=0
SVSAFE_BUILD_MS=0
SVSAFE_INSTALL_MS=0
SVSAFE_PUBLISH_MS=0
SVSAFE_MOUNT_MS=0
SVSAFE_PROVISION_MS=0

# NEW: path markers
SVSAFE_FASTPATH=0
SVSAFE_READY_HIT=0

t_script_start_ns="$(now_ns)"

# ---- status writer + trap (guarantee .svsafe_status even on failure) --------
write_status() {
  {
    echo "SVSAFE_BASE=$base"
    echo "SVSAFE_NODE_MODULES=$published_nm"
    echo "SVSAFE_KEY=$key"

    echo "SVSAFE_REUSED=$SVSAFE_REUSED"
    echo "SVSAFE_LOCK_WAIT_MS=$SVSAFE_LOCK_WAIT_MS"
    echo "SVSAFE_BUILD_MS=$SVSAFE_BUILD_MS"
    echo "SVSAFE_INSTALL_MS=$SVSAFE_INSTALL_MS"
    echo "SVSAFE_PUBLISH_MS=$SVSAFE_PUBLISH_MS"
    echo "SVSAFE_MOUNT_MS=$SVSAFE_MOUNT_MS"
    echo "SVSAFE_PROVISION_MS=$SVSAFE_PROVISION_MS"

    echo "SVSAFE_FORCE_REBUILD=$E2_SVSAFE_FORCE_REBUILD"
    echo "SVSAFE_FORCE_REBUILD_TTL_SEC=$E2_SVSAFE_FORCE_REBUILD_TTL_SEC"

    # NEW
    echo "SVSAFE_DISABLE_FASTPATH=$E2_SVSAFE_DISABLE_FASTPATH"
    echo "SVSAFE_FASTPATH=$SVSAFE_FASTPATH"
    echo "SVSAFE_READY_HIT=$SVSAFE_READY_HIT"

    echo "SVSAFE_EXIT_CODE=$SVSAFE_EXIT_CODE"
    echo "SVSAFE_FAIL_REASON=$SVSAFE_FAIL_REASON"
    echo "WHEN=$(date -Is)"

    if have_cmd findmnt; then
      findmnt -no SOURCE,OPTIONS --target "$nm" 2>/dev/null | awk '{print "MOUNT="$0}' || true
    else
      awk -v m="$nm" '$2==m{print "MOUNT="$1" "$4}' /proc/mounts 2>/dev/null || true
    fi
  } > "$status_file" 2>/dev/null || true
}

on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$SVSAFE_EXIT_CODE" -eq 0 ]]; then
    SVSAFE_EXIT_CODE=$rc
    [[ -z "$SVSAFE_FAIL_REASON" ]] && SVSAFE_FAIL_REASON="exit_rc=${rc}"
  fi
  local t_end_ns
  t_end_ns="$(now_ns)"
  if [[ -z "${SVSAFE_PROVISION_MS}" || "${SVSAFE_PROVISION_MS}" = "0" ]]; then
    SVSAFE_PROVISION_MS="$(ns_to_ms "$((t_end_ns - t_script_start_ns))")"
  fi
  write_status
}
trap on_exit EXIT

# ---- idempotent fast-path: already mounted ro ------------------------------
if is_mountpoint "$nm" && is_ro_mount "$nm"; then
  if [[ "${E2_SVSAFE_DISABLE_FASTPATH}" != "1" ]]; then
    info "already mounted RO at $nm (fast-path exit)"
    SVSAFE_FASTPATH=1
    SVSAFE_REUSED=1
    # READY_HIT is best-effort: if published already exists, mark it; otherwise keep 0.
    if [[ -f "$ready" && -d "$published_nm" ]]; then
      SVSAFE_READY_HIT=1
    fi
    SVSAFE_EXIT_CODE=0
    SVSAFE_FAIL_REASON=""
    exit 0
  else
    info "already mounted RO at $nm but E2_SVSAFE_DISABLE_FASTPATH=1 -> continue (will still lock/reuse)"
  fi
fi

# ---- cleanup partial builds (best-effort) -----------------------------------
cleanup_partial() {
  local projroot="$E2_SVSAFE_ROOT/$proj"
  [[ -d "$projroot" ]] || return 0
  if [[ "${E2_SVSAFE_CLEAN_PARTIAL}" = "1" ]]; then
    # clean temp dirs older than today
    find "$projroot" -maxdepth 1 -type d -name ".tmp.${key}.*" -mtime +0 -print0 2>/dev/null \
      | xargs -0 -r rm -rf || true

    if [[ -d "$base" && ! -f "$ready" ]]; then
      warn "published dir exists but missing READY -> remove as partial: $base"
      rmrf_best_effort "$base"
    fi
  fi
}
cleanup_partial

# ---- critical section: build/publish ---------------------------------------
exec 9>"$lockf"

t_lock_wait_start_ns="$(now_ns)"
if ! flock -w "${E2_SVSAFE_LOCK_TIMEOUT}" 9; then
  die "cannot acquire lock within ${E2_SVSAFE_LOCK_TIMEOUT}s: $lockf"
fi
t_lock_acquired_ns="$(now_ns)"
SVSAFE_LOCK_WAIT_MS="$(ns_to_ms "$((t_lock_acquired_ns - t_lock_wait_start_ns))")"

# force rebuild under lock (TTL marker)
force_marker="$lockdir/$key.force_rebuild_marker"
if [[ "${E2_SVSAFE_FORCE_REBUILD}" = "1" ]]; then
  now_epoch="$(epoch_now)"
  mark_epoch="$(file_mtime_epoch "$force_marker")"
  age="$(( now_epoch - mark_epoch ))"
  if [[ "$mark_epoch" -eq 0 || "$age" -ge "${E2_SVSAFE_FORCE_REBUILD_TTL_SEC}" ]]; then
    if [[ -d "$base" ]]; then
      info "FORCE_REBUILD=1 (ttl=${E2_SVSAFE_FORCE_REBUILD_TTL_SEC}s, age=${age}s) -> remove existing published $base"
      rmrf_best_effort "$base"
    else
      info "FORCE_REBUILD=1 (ttl=${E2_SVSAFE_FORCE_REBUILD_TTL_SEC}s, age=${age}s) -> base not exists, proceed"
    fi
    : > "$force_marker" 2>/dev/null || true
  else
    info "FORCE_REBUILD=1 but marker age=${age}s < ttl=${E2_SVSAFE_FORCE_REBUILD_TTL_SEC}s -> skip repeated rebuild"
  fi
fi

t_build_start_ns="$(now_ns)"
if [[ -f "$ready" && -d "$published_nm" ]]; then
  SVSAFE_REUSED=1
  SVSAFE_READY_HIT=1
  info "published exists (READY) -> reuse: $base"
else
  SVSAFE_REUSED=0
  SVSAFE_READY_HIT=0

  if [[ -d "$base" && ! -f "$ready" ]]; then
    warn "found partial $base (no READY) -> remove"
    rmrf_best_effort "$base"
  fi

  # temp dir
  rand="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6 || echo rand)"
  tmp="$E2_SVSAFE_ROOT/$proj/.tmp.${key}.$$.$rand"
  mkdir -p "$tmp"

  work="$tmp/work"
  mkdir -p "$work"

  info "building SV-safe node_modules in temp: $tmp"
  if have_cmd rsync; then
    rsync -a --delete \
      --exclude '.git' --exclude 'node_modules' --exclude '.cache' --exclude '.next' \
      "$projdir"/ "$work"/
  else
    rm -rf "$work"
    mkdir -p "$work"
    (cd "$projdir" && tar -cf - --exclude='./.git' --exclude='./node_modules' --exclude='./.cache' --exclude='./.next' .) \
      | (cd "$work" && tar -xf -)
  fi

  # ensure yarn exists if needed
  if [[ -z "${E2_INSTALL_CMD}" && "$(detect_pm "$work")" = "yarn" ]]; then
    ensure_cmd yarn
  fi

  install_cmd="$(default_install_cmd "$work")"
  info "install_cmd: $install_cmd"

  t_install_start_ns="$(now_ns)"
  (
    cd "$work"
    rm -rf node_modules
    CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    PATH="$CLEAN_PATH" bash -lc "$install_cmd"
  )
  t_install_end_ns="$(now_ns)"
  SVSAFE_INSTALL_MS="$(ns_to_ms "$((t_install_end_ns - t_install_start_ns))")"

  [[ -d "$work/node_modules" ]] || die "build finished but node_modules missing in temp workdir"

  rm -rf "$tmp/node_modules"
  mv "$work/node_modules" "$tmp/node_modules"

  {
    echo "PROJ=$proj"
    echo "KEY=$key"
    echo "LOCKFILE=$(basename "$lockfile")"
    echo "LOCKFILE_SHA256=$(sha256_file "$lockfile")"
    echo "NODE=$(node -v 2>/dev/null || echo unknown)"
    echo "NPM=$(npm -v 2>/dev/null || echo unknown)"
    echo "UNAME=$(uname -srm 2>/dev/null || echo unknown)"
    echo "INSTALL_CMD=$install_cmd"
    echo "BUILT_AT=$(date -Is)"
    du -sb "$tmp/node_modules" 2>/dev/null | awk '{print "NODE_MODULES_BYTES="$1}' || true
  } > "$tmp/META"
  echo "OK $(date -Is)" > "$tmp/READY"

  chmod -R a+rX "$tmp/node_modules" 2>/dev/null || true

  t_publish_start_ns="$(now_ns)"
  info "publish: mv $tmp -> $base (atomic rename)"
  if ! mv "$tmp" "$base"; then
    if [[ "${E2_SVSAFE_KEEP_TMP}" != "1" ]]; then
      rmrf_best_effort "$tmp"
    fi
    die "atomic publish failed (mv temp -> base)"
  fi
  t_publish_end_ns="$(now_ns)"
  SVSAFE_PUBLISH_MS="$(ns_to_ms "$((t_publish_end_ns - t_publish_start_ns))")"

  info "published ready: $base"
fi

t_build_end_ns="$(now_ns)"
SVSAFE_BUILD_MS="$(ns_to_ms "$((t_build_end_ns - t_build_start_ns))")"

# release lock
flock -u 9 || true

# ---- runtime mount into project --------------------------------------------
t_mount_start_ns="$(now_ns)"

run_umount_lazy "$nm"
rm -rf "$nm" 2>/dev/null || true
mkdir -p "$nm"

info "mount --bind $published_nm -> $nm (ro)"
run_mount --bind "$published_nm" "$nm"
run_mount -o remount,ro,bind "$nm"

if [[ "${E2_SVSAFE_REQUIRE_RO}" = "1" ]]; then
  if ! is_ro_mount "$nm"; then
    die "mounted but not read-only: $nm"
  fi
else
  if ! is_ro_mount "$nm"; then
    warn "mounted but not read-only: $nm (please annotate results)"
  fi
fi

t_mount_end_ns="$(now_ns)"
SVSAFE_MOUNT_MS="$(ns_to_ms "$((t_mount_end_ns - t_mount_start_ns))")"

t_script_end_ns="$(now_ns)"
SVSAFE_PROVISION_MS="$(ns_to_ms "$((t_script_end_ns - t_script_start_ns))")"

SVSAFE_EXIT_CODE=0
SVSAFE_FAIL_REASON=""

info "METRICS: fastpath=${SVSAFE_FASTPATH} ready_hit=${SVSAFE_READY_HIT} reused=${SVSAFE_REUSED} lock_wait_ms=${SVSAFE_LOCK_WAIT_MS} build_ms=${SVSAFE_BUILD_MS} install_ms=${SVSAFE_INSTALL_MS} publish_ms=${SVSAFE_PUBLISH_MS} mount_ms=${SVSAFE_MOUNT_MS} provision_ms=${SVSAFE_PROVISION_MS}"
info "done: mounted sv-safe node_modules for $proj at $projdir"
exit 0
