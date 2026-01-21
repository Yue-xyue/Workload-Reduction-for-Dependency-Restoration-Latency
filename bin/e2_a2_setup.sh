#!/usr/bin/env bash
# e2_a2_setup.sh <project> [<npm_flags>]
# 功能：建立（若無則建）並掛載唯讀 A2 seed：$E2_ROOT/a2_ro/<project>/node_modules
# 相容性：
# - 支援 PROJECT_DIR 覆寫
# - 加入檔案鎖，避免多進程同時重建 seed
# - 若 seed 已存在且非空 → 直接重用
# - 支援 E2_INSTALL_CMD（例如 yarn install），未設定則用 npm ci
#
# 強化：
# - mountpoint/findmnt/flock 的 fallback
# - 鎖 timeout（預設 300s，可用 E2_A2_LOCK_TIMEOUT 覆寫）
# - 若已正確掛載 ro bind → 直接退出（idempotent）
# - .a2_status 增加更多可 debug 欄位

set -euo pipefail

proj="${1:?Usage: e2_a2_setup.sh <project> [<npm_flags>]}"
npm_flags="${2:-}"

root="${E2_ROOT:-$HOME/experiment/e_ex}"
projdir="${PROJECT_DIR:-$root/projects/$proj}"

seed_dir="$root/a2_ro/$proj"
seed="$seed_dir/node_modules"
lockf="$seed_dir/.a2_seed.lock"

: "${E2_A2_LOCK_TIMEOUT:=300}"   # seconds
: "${E2_SKIP_INSTALL:=0}"        # 1=skip setup entirely
: "${E2_INSTALL_CMD:=}"          # optional
: "${E2_A2_REQUIRE_RO:=1}"       # 1=after mount, require ro; 0=warn only

have_cmd() { command -v "$1" >/dev/null 2>&1; }

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

seed_is_ready() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  find "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

umount_lazy_if_mounted() {
  local p="$1"
  if is_mountpoint "$p"; then
    sudo umount -l "$p" 2>/dev/null || true
  fi
}

# ---- early exit / basic prep ------------------------------------------------
if [[ "${E2_SKIP_INSTALL}" = "1" ]]; then
  echo "[A2] skip setup (E2_SKIP_INSTALL=1)"
  exit 0
fi

mkdir -p "$seed_dir"
mkdir -p "$projdir"

# refresh sudo credential (best-effort)
if have_cmd sudo; then sudo -v || true; fi

nm="$projdir/node_modules"

# ---- idempotent: if already mounted ro and points to seed, do nothing --------
# We treat "mounted ro" as good enough; we don't strictly verify SOURCE because
# bind mounts can show SOURCE ambiguously on some systems.
if is_mountpoint "$nm" && is_ro_mount "$nm"; then
  echo "[A2] already mounted read-only at $nm (skip remount)"
  {
    echo "A2_SEED=$seed"
    echo "PROJECT_DIR=$projdir"
    echo "WHEN=$(date -Is)"
    echo "NOTE=already_mounted_ro"
  } > "$projdir/.a2_status" || true
  exit 0
fi

# If node_modules is mounted (maybe rw/ro), unmount first to avoid EROFS issues.
umount_lazy_if_mounted "$nm"

# ---- build seed if needed (multi-process safe) ------------------------------
if ! seed_is_ready "$seed"; then
  # lock critical section
  if have_cmd flock; then
    exec 9>"$lockf"
    if ! flock -w "${E2_A2_LOCK_TIMEOUT}" 9; then
      echo "[A2] FATAL: cannot acquire lock $lockf within ${E2_A2_LOCK_TIMEOUT}s" >&2
      exit 3
    fi

    # re-check after acquiring lock
    if seed_is_ready "$seed"; then
      echo "[A2] seed already prepared by another process"
    else
      echo "[A2] building seed at $seed (projdir=$projdir)"
      (
        cd "$projdir"
        rm -rf node_modules

        CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        if [[ -n "${E2_INSTALL_CMD}" ]]; then
          echo "[A2] using custom E2_INSTALL_CMD for seed: $E2_INSTALL_CMD"
          PATH="$CLEAN_PATH" bash -lc "$E2_INSTALL_CMD"
        else
          echo "[A2] using npm ci to build seed"
          PATH="$CLEAN_PATH" npm ci $npm_flags
        fi
      )

      rm -rf "$seed"
      mkdir -p "$(dirname "$seed")"
      mv "$projdir/node_modules" "$seed"
    fi

    flock -u 9 || true
  else
    # fallback: no flock -> best-effort single builder (mkdir lock)
    lockdir="${lockf}.d"
    if mkdir "$lockdir" 2>/dev/null; then
      trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT
      if ! seed_is_ready "$seed"; then
        echo "[A2] building seed at $seed (no flock; mkdir-lock fallback)"
        (
          cd "$projdir"
          rm -rf node_modules
          CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          if [[ -n "${E2_INSTALL_CMD}" ]]; then
            PATH="$CLEAN_PATH" bash -lc "$E2_INSTALL_CMD"
          else
            PATH="$CLEAN_PATH" npm ci $npm_flags
          fi
        )
        rm -rf "$seed"
        mkdir -p "$(dirname "$seed")"
        mv "$projdir/node_modules" "$seed"
      fi
      rmdir "$lockdir" 2>/dev/null || true
      trap - EXIT
    else
      echo "[A2] WARN: cannot acquire mkdir-lock; waiting for seed to appear..." >&2
      # wait up to timeout
      t0="$(date +%s)"
      while ! seed_is_ready "$seed"; do
        sleep 1
        now="$(date +%s)"
        if (( now - t0 > E2_A2_LOCK_TIMEOUT )); then
          echo "[A2] FATAL: seed not ready after ${E2_A2_LOCK_TIMEOUT}s (no flock)" >&2
          exit 3
        fi
      done
    fi
  fi
fi

# ---- mount ro bind ----------------------------------------------------------
mkdir -p "$nm"
echo "[A2] mount --bind $seed -> $nm (ro)"
sudo mount --bind "$seed" "$nm"
sudo mount -o remount,ro,bind "$nm"

if [[ "${E2_A2_REQUIRE_RO}" = "1" ]]; then
  if ! is_ro_mount "$nm"; then
    echo "[A2] FATAL: mounted but not read-only: $nm" >&2
    exit 3
  fi
else
  if ! is_ro_mount "$nm"; then
    echo "[A2] WARN: $nm mounted but not ro (results should be annotated)" >&2
  fi
fi

# ---- status file ------------------------------------------------------------
{
  echo "A2_SEED=$seed"
  echo "PROJECT_DIR=$projdir"
  echo "WHEN=$(date -Is)"
  echo "NODE=$(node -v 2>/dev/null || echo unknown)"
  echo "NPM=$(npm -v 2>/dev/null || echo unknown)"
  du -sb "$seed" 2>/dev/null | awk '{print "BYTES="$1}' || true
  if have_cmd findmnt; then
    findmnt -no SOURCE,OPTIONS --target "$nm" 2>/dev/null | awk '{print "MOUNT="$0}' || true
  fi
} > "$projdir/.a2_status"

echo "[A2] mounted read-only node_modules for $proj at $projdir"
