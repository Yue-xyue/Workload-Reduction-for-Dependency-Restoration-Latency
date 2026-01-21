#!/usr/bin/env bash
# shared helpers for e2 scripts (cgroup v2 first; v1 fallback)
#
# Goals of this revision:
# - Keep backward compatibility (existing functions remain).
# - Fix small footguns (parse_bytes whitespace; e2_rand_tag head -c).
# - Add SV-safe / version-key helpers (sha256, flock wrapper, atomic publish).
# - Add mount helpers (ro bind mount / umount with fallbacks).
# - Add robust is_mountpoint/is_ro_mount fallback when findmnt is absent.

# NOTE: This file is sourced by scripts that may use `set -e`.
# Do NOT enable `set -e` here.
shopt -s extglob

# =========================
# 0) Small helpers
# =========================

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# echo to root-protected file (requires sudo)
#   _sudo_write "value" "/path/to/file"
_sudo_write() {
  local val="$1" f="$2"
  if [[ -w "$f" ]]; then
    printf '%s' "$val" > "$f"
  else
    printf '%s' "$val" | sudo tee "$f" >/dev/null
  fi
}

# Robust sha256 helpers (used by version key / lockfile digest)
# Prefer sha256sum; fallback to python3.
e2_sha256_file() {
  local f="$1"
  [[ -r "$f" ]] || { echo ""; return 1; }
  if have_cmd sha256sum; then
    sha256sum "$f" | awk '{print $1}'
    return 0
  fi
  if have_cmd python3; then
    python3 - <<'PY' "$f"
import hashlib, sys
p=sys.argv[1]
h=hashlib.sha256()
with open(p,'rb') as fp:
  for b in iter(lambda: fp.read(1<<20), b''):
    h.update(b)
print(h.hexdigest())
PY
    return 0
  fi
  echo ""
  return 1
}

e2_sha256_str() {
  local s="$1"
  if have_cmd sha256sum; then
    printf '%s' "$s" | sha256sum | awk '{print $1}'
    return 0
  fi
  if have_cmd python3; then
    python3 - <<'PY' "$s"
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest())
PY
    return 0
  fi
  echo ""
  return 1
}

# A short random tag
e2_rand_tag() {
  # fixed: `head -c` (not `head-c`)
  tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6
}

# =========================
# 1) Bytes parsing
# =========================

# parse_bytes:
#   integers (bytes), 10k/10kb, 512m/512mb, 2g/2gb, 1t/1tb, "max"
# return: number or string "max"; unparseable => original string
parse_bytes() {
  local s="${1:-}"
  [[ -z "$s" ]] && { echo ""; return; }

  s="${s,,}"                  # to lowercase
  s="${s//[[:space:]]/}"      # remove ALL whitespace robustly

  if [[ "$s" == "max" ]]; then echo "max"; return; fi
  if [[ "$s" =~ ^[0-9]+$ ]]; then echo "$s"; return; fi

  if [[ "$s" =~ ^([0-9]+)(k|kb|m|mb|g|gb|t|tb)$ ]]; then
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
    case "$u" in
      k|kb)  echo $(( n * 1024 ));;
      m|mb)  echo $(( n * 1024 * 1024 ));;
      g|gb)  echo $(( n * 1024 * 1024 * 1024 ));;
      t|tb)  echo $(( n * 1024 * 1024 * 1024 * 1024 ));;
      *)     echo "$n";;
    esac
    return
  fi

  echo "$s"
}

# =========================
# 2) Memory profile (legacy interface)
# =========================

# choose_mem_flag <project> <mem: ample|edge>
# Legacy docker flags. Newer flows prefer cgroup v2 / systemd scope.
choose_mem_flag() {
  local proj="${1:-}" mem="${2:-ample}"
  case "$mem" in
    ample) echo "" ;;
    edge)  echo "--memory=512m --memory-swap=512m" ;;
    *)     echo "" ;;
  esac
}

# =========================
# 3) Mount & cgroup / PSI / I/O helpers
# =========================

# is_mountpoint: robust fallback if findmnt/mountpoint missing
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

# is_ro_mount: check mount options include ro
is_ro_mount() {
  local p="$1"
  is_mountpoint "$p" || return 1
  if have_cmd findmnt; then
    findmnt -no OPTIONS --target "$p" 2>/dev/null | grep -qw ro
    return $?
  fi
  awk -v m="$p" '$2==m{ if (index($4,"ro")>0) ro=1 } END{ exit ro?0:1 }' /proc/mounts
}

# cgroup v2 unified?
is_cgroup_v2() {
  awk '$2=="/sys/fs/cgroup" && $3=="cgroup2"{found=1} END{exit(found?0:1)}' /proc/self/mounts
}

# cg_path_of_pid <pid> -> /sys/fs/cgroup/<path> (v2) or v1 memory fallback
cg_path_of_pid() {
  local pid="$1"
  [[ -r "/proc/${pid}/cgroup" ]] || { echo ""; return; }

  local v2
  v2="$(awk -F: '$1=="0"{print $3}' "/proc/${pid}/cgroup" 2>/dev/null)"
  if [[ -z "$v2" ]]; then
    v2="$(awk -F: 'END{print $NF}' "/proc/${pid}/cgroup" 2>/dev/null)"
  fi
  if [[ -n "$v2" && -d "/sys/fs/cgroup${v2}" ]]; then
    echo "/sys/fs/cgroup${v2}"
    return
  fi

  local v1mem
  v1mem="$(awk -F: '$2=="memory"{print $3}' "/proc/${pid}/cgroup" 2>/dev/null)"
  if [[ -n "$v1mem" && -d "/sys/fs/cgroup/memory${v1mem}" ]]; then
    echo "/sys/fs/cgroup/memory${v1mem}"
  else
    echo ""
  fi
}

_sum_io_rbytes() {
  local f="$1"
  [[ -r "$f" ]] || { echo 0; return; }
  awk '{
    for(i=1;i<=NF;i++){
      if($i ~ /^rbytes=/){ split($i,a,"="); s+=a[2] }
    }
  } END{ printf("%s", s ? s : 0) }' "$f" 2>/dev/null
}

# snapshot_cgv2 <cg_abs_path> <out_file>
snapshot_cgv2() {
  local cg="$1" out="$2"
  : > "$out"
  local mem="${cg}/memory.stat"
  local io="${cg}/io.stat"

  if [[ -r "$mem" ]]; then
    awk '$1=="pgmajfault"{print "pgmajfault",$2}' "$mem" >> "$out" 2>/dev/null || true
  fi
  if [[ -r "$io" ]]; then
    echo "io_rbytes $(_sum_io_rbytes "$io")" >> "$out"
  fi
}

_read_field() {
  local file="$1" key="$2"
  [[ -r "$file" ]] || { echo ""; return; }
  awk -v K="$key" '$1==K{print $2; exit}' "$file" 2>/dev/null
}

_nonneg_delta() {
  local before="$1" after="$2"
  if [[ -z "$before" || -z "$after" ]]; then
    echo ""; return
  fi
  local d=$(( after - before ))
  if (( d < 0 )); then
    echo ""; return
  fi
  echo "$d"
}

delta_pgmajfault() {
  local b="$(_read_field "$1" pgmajfault)"
  local a="$(_read_field "$2" pgmajfault)"
  _nonneg_delta "$b" "$a"
}

delta_rbytes() {
  local b="$(_read_field "$1" io_rbytes)"
  local a="$(_read_field "$2" io_rbytes)"
  _nonneg_delta "$b" "$a"
}

snapshot_netns_sum() {
  local pid="$1" out="$2"
  local f="/proc/${pid}/net/dev"
  : > "$out"
  if [[ -r "$f" ]]; then
    awk -F'[: ]+' '
      NR>2 && NF>=17 {
        iface=$1
        if (iface == "lo") next
        rx=$3; tx=$11; sum+=rx+tx
      }
      END { printf("net_bytes %s\n", sum?sum:0) }
    ' "$f" >> "$out"
  fi
}

delta_netbytes() {
  local b="$(_read_field "$1" net_bytes)" a="$(_read_field "$2" net_bytes)"
  if [[ -z "$b" || -z "$a" ]]; then
    echo ""
  else
    echo $(( a - b ))
  fi
}

# =========================
# 4) node_modules write guard (legacy compatible)
# =========================

ensure_rw_node_modules() {
  local d="$1"
  local nm="$d/node_modules"

  if have_cmd mountpoint && mountpoint -q "$nm"; then
    local opts
    opts="$(have_cmd findmnt && findmnt -no OPTIONS "$nm" 2>/dev/null || echo "")"
    echo "[guard] $nm is a mount ($opts) -> try umount -l"
    if ! sudo umount -l "$nm"; then
      echo "[guard] umount failed; trying bind remount rw"
      sudo mount -o bind,remount,rw "$nm" || true
    fi
    if have_cmd mountpoint && mountpoint -q "$nm"; then
      echo "[guard] still a mount; abort to avoid EROFS"
      return 1
    fi
  fi

  mkdir -p "$nm"
  if ! touch "$nm/.rw_test" 2>/dev/null; then
    echo "[guard] $nm not writable; abort"
    return 1
  fi
  rm -f "$nm/.rw_test"
}

# =========================
# 5) Stage-5 cgroup v2 / systemd scope helpers (kept; lightly hardened)
# =========================

cg2_make_group() {
  local p="$1"
  [[ -z "$p" ]] && { echo ""; return 1; }
  if [[ "$p" != /sys/fs/cgroup/* ]]; then
    p="/sys/fs/cgroup/${p#/}"
  fi
  sudo mkdir -p "$p"

  local parent
  parent="$(dirname "$p")"
  if [[ -w "$parent/cgroup.subtree_control" ]] || (have_cmd sudo && sudo test -w "$parent/cgroup.subtree_control" 2>/dev/null); then
    {
      grep -qw memory "$parent/cgroup.controllers" 2>/dev/null && _sudo_write "+memory" "$parent/cgroup.subtree_control"
      grep -qw io     "$parent/cgroup.controllers" 2>/dev/null && _sudo_write "+io"     "$parent/cgroup.subtree_control"
    } >/dev/null 2>&1 || true
  fi
  echo "$p"
}

cg2_set_memory_limits() {
  local cg="$1" m="$2" s="${3:-max}"
  [[ -z "$cg" || ! -d "$cg" ]] && { echo "[cg2] bad cgroup path: $cg" >&2; return 1; }
  local mb ss
  mb="$(parse_bytes "$m")"; [[ -z "$mb" ]] && mb="max"
  ss="$(parse_bytes "$s")"; [[ -z "$ss" ]] && ss="max"
  [[ -f "$cg/memory.max"      ]] && _sudo_write "$mb" "$cg/memory.max"
  [[ -f "$cg/memory.swap.max" ]] && _sudo_write "$ss" "$cg/memory.swap.max"
}

cg2_add_pid() {
  local cg="$1" pid="$2"
  [[ -z "$cg" || -z "$pid" ]] && return 1
  [[ -f "$cg/cgroup.procs" ]] || return 1
  _sudo_write "$pid" "$cg/cgroup.procs"
}

run_in_cg2() {
  local cg="$1"; shift
  local cmd="$*"
  [[ -z "$cg" || -z "$cmd" ]] && { echo "[cg2] usage: run_in_cg2 <cg> <cmd...>" >&2; return 2; }
  bash -lc "echo \$\$ | sudo tee '$cg/cgroup.procs' >/dev/null; exec $cmd"
}

run_with_systemd_scope() {
  local name="$1" mem="$2" swap="${3:-max}"; shift 3 || true
  if [[ "${1:-}" != "--" ]]; then
    echo "[scope] usage: run_with_systemd_scope <name> <mem> [<swap>] -- <cmd...>" >&2
    return 2
  fi
  shift
  local cmd=( "$@" )

  local mval sval
  mval="$(parse_bytes "$mem")"; [[ -z "$mval" ]] && mval="max"
  sval="$(parse_bytes "$swap")"; [[ -z "$sval" ]] && sval="max"

  if have_cmd systemd-run && [[ -S /run/systemd/private ]]; then
    # Try user scope first (no sudo)
    if systemd-run --user --scope -p "MemoryMax=$mval" bash -lc 'true' >/dev/null 2>&1; then
      systemd-run --user --scope -p "MemoryMax=$mval" bash -lc "$(printf '%q ' "${cmd[@]}")"
      return $?
    fi
    # Fallback to system scope (needs sudo)
    sudo systemd-run --scope -p "MemoryMax=$mval" bash -lc "$(printf '%q ' "${cmd[@]}")"
    return $?
  fi

  # Pure cgroup v2 fallback
  local cg="/e2.matrix/${name}"
  cg="$(cg2_make_group "$cg")" || return 1
  cg2_set_memory_limits "$cg" "$mem" "$swap"
  run_in_cg2 "$cg" "$(printf '%q ' "${cmd[@]}")"
}

# Optional: emit a prologue into wrap log before calling e2wrap.js
e2_emit_prologue() {
  local run_tag="${1:-}" worker_id="${2:-}" conc="${3:-}" memp="${4:-}" cg="${5:-}"
  [[ -n "$run_tag"   ]] && echo "RUN_TAG $run_tag"
  [[ -n "$worker_id" ]] && echo "WORKER_ID $worker_id"
  [[ -n "$conc"      ]] && echo "E2_CONC $conc"
  [[ -n "$memp"      ]] && echo "E2_MEM_PROFILE $memp"
  if [[ -n "$cg" && -d "$cg" ]]; then
    echo "CG_PATH_BEFORE $cg"
    if [[ -r "$cg/memory.max" ]]; then
      local v; v="$(cat "$cg/memory.max" 2>/dev/null || true)"
      [[ -n "$v" ]] && echo "CG_MEMORY_MAX $v"
      if [[ "$v" != "max" ]]; then
        echo "CG_MEMORY_MAX_BYTES $(parse_bytes "$v")"
      fi
    fi
    [[ -r "$cg/memory.current"      ]] && echo "CG_MEMORY_CURRENT_BYTES $(cat "$cg/memory.current" 2>/dev/null || echo 0)"
    [[ -r "$cg/memory.swap.current" ]] && echo "CG_SWAP_CURRENT_BYTES $(cat "$cg/memory.swap.current" 2>/dev/null || echo 0)"
  fi
}

# =========================
# 6) Package manager helpers (kept)
# =========================

e2_detect_pm() {
  local d="$1"
  if [[ -f "$d/yarn.lock" ]]; then
    echo "yarn"
  elif [[ -f "$d/package-lock.json" || -f "$d/npm-shrinkwrap.json" ]]; then
    echo "npm"
  else
    echo "unknown"
  fi
}

e2_default_install_cmd() {
  local d="${1:-.}"
  if [[ -n "${E2_INSTALL_CMD:-}" ]]; then
    printf '%s\n' "$E2_INSTALL_CMD"
    return 0
  fi
  case "$(e2_detect_pm "$d")" in
    yarn) echo "yarn install --immutable" ;;
    npm)  echo "npm ci" ;;
    *)    echo "npm install" ;;
  esac
}

pkg_install_cmd() {
  case "${PKG_TOOL:-npm}" in
    yarn)
      echo "YARN_CACHE_FOLDER='$E2_ROOT/npm-cache/yarn' yarn install --immutable --ignore-engines"
      ;;
    npm|*)
      echo "npm ci --cache '$E2_ROOT/npm-cache' --prefer-offline"
      ;;
  esac
}

# =========================
# 7) New helpers for SV-safe & version keys
# =========================

# e2_find_lockfile <project_root> -> path or empty
e2_find_lockfile() {
  local d="$1"
  if [[ -f "$d/package-lock.json" ]]; then echo "$d/package-lock.json"; return 0; fi
  if [[ -f "$d/npm-shrinkwrap.json" ]]; then echo "$d/npm-shrinkwrap.json"; return 0; fi
  if [[ -f "$d/yarn.lock" ]]; then echo "$d/yarn.lock"; return 0; fi
  echo ""
  return 1
}

# e2_seed_key <project_root>
# Default seed key material: lockfile sha + node + npm + os + arch
# (你若要更嚴格，可在 driver 那邊額外加上 PKG_TOOL / distro / libc 等)
e2_seed_key() {
  local d="$1"
  local lf; lf="$(e2_find_lockfile "$d")"
  [[ -n "$lf" ]] || { echo ""; return 1; }

  local lfh; lfh="$(e2_sha256_file "$lf")"
  local nodev npmv os arch
  nodev="$(node -v 2>/dev/null || echo unknown)"
  npmv="$(npm -v 2>/dev/null || echo unknown)"
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"

  # Keep readable prefix + stable hash
  local material="lock=$lfh node=$nodev npm=$npmv os=$os arch=$arch"
  e2_sha256_str "$material"
}

# e2_with_flock <lockfile> <cmd...>
# If flock not available, runs command without locking (caller decides if that is acceptable).
e2_with_flock() {
  local lock="$1"; shift
  if have_cmd flock; then
    flock -x "$lock" bash -lc "$(printf '%q ' "$@")"
    return $?
  fi
  # fallback: no lock
  bash -lc "$(printf '%q ' "$@")"
}

# e2_atomic_publish_dir <src_tmp_dir> <dst_dir>
# Publish by rename into place; tries to be as atomic as possible.
e2_atomic_publish_dir() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || { echo "[atomic] src missing: $src" >&2; return 1; }
  local parent; parent="$(dirname "$dst")"
  mkdir -p "$parent"

  # If dst already exists, keep it (idempotent publish)
  if [[ -e "$dst" ]]; then
    return 0
  fi

  mv "$src" "$dst"
}

# e2_bind_mount_ro <src> <dst>
# Read-only bind mount helper with "already mounted" early return.
e2_bind_mount_ro() {
  local src="$1" dst="$2"
  mkdir -p "$dst"

  if is_mountpoint "$dst"; then
    # if already ro, reuse; otherwise try remount ro
    if is_ro_mount "$dst"; then
      return 0
    fi
    sudo mount -o bind,remount,ro "$dst" 2>/dev/null || true
    is_ro_mount "$dst" && return 0
  fi

  sudo mount --bind "$src" "$dst"
  sudo mount -o bind,remount,ro "$dst"
}

# e2_umount_lazy <path>
e2_umount_lazy() {
  local p="$1"
  is_mountpoint "$p" || return 0
  sudo umount -l "$p" || true
}

# =========================
# End of common.sh
# =========================
