#!/usr/bin/env bash
# e2_a2_teardown.sh [<project>]
# 功能：卸載 PROJECT_DIR（或標準專案目錄）下的唯讀 bind-mounted node_modules。
#
# 相容性：
# - proj: arg > PROJ > express-app
# - projdir: PROJECT_DIR 覆寫，預設 $E2_ROOT/projects/$proj
# - 使用 .a2_mount.lock + flock 避免並發搶 umount
# - CLEAR_A2_STATUS=1 會刪除 .a2_status（不影響 seed）
#
# 強化：
# - mountpoint/findmnt/flock fallback
# - 鎖 timeout（預設 30s，可用 E2_A2_UMOUNT_LOCK_TIMEOUT 覆寫）
# - umount -l 失敗後回退一般 umount，再檢查狀態

set -euo pipefail

proj="${1:-${PROJ:-express-app}}"
root="${E2_ROOT:-$HOME/experiment/e_ex}"
projdir="${PROJECT_DIR:-$root/projects/$proj}"

nm="$projdir/node_modules"
a2_status_file="$projdir/.a2_status"
a2_lock_file="$projdir/.a2_mount.lock"

: "${CLEAR_A2_STATUS:=0}"
: "${E2_A2_UMOUNT_LOCK_TIMEOUT:=30}"

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

if [[ ! -d "$projdir" ]]; then
  echo "[A2-teardown] projdir=$projdir not found, skip"
  exit 0
fi

# Acquire lock (best-effort)
locked=0
if have_cmd flock; then
  exec {a2fd}>"$a2_lock_file"
  if flock -w "${E2_A2_UMOUNT_LOCK_TIMEOUT}" "$a2fd"; then
    locked=1
  else
    echo "[A2-teardown] WARN: cannot acquire lock $a2_lock_file within ${E2_A2_UMOUNT_LOCK_TIMEOUT}s" >&2
  fi
else
  echo "[A2-teardown] WARN: flock not available; proceed without lock" >&2
fi

if is_mountpoint "$nm"; then
  opts=""
  if have_cmd findmnt; then
    opts="$(findmnt -no SOURCE,OPTIONS --target "$nm" 2>/dev/null || true)"
  fi
  echo "[A2] umount $nm (opts: ${opts:-unknown})"

  if ! sudo umount -l "$nm" 2>/dev/null; then
    echo "[A2] lazy umount failed; retry normal umount"
    sudo umount "$nm" || true
  fi

  if is_mountpoint "$nm"; then
    echo "[A2] WARN: $nm still a mountpoint (umount failed)" >&2
    if (( locked )); then flock -u "$a2fd" || true; fi
    exit 1
  fi

  echo "[A2] umounted $nm"
else
  echo "[A2] $nm not a mountpoint (skip)"
fi

if (( locked )); then flock -u "$a2fd" || true; fi

if [[ "$CLEAR_A2_STATUS" = "1" && -f "$a2_status_file" ]]; then
  echo "[A2] CLEAR_A2_STATUS=1 -> remove $a2_status_file"
  rm -f "$a2_status_file"
fi

echo "[A2-teardown] done for project=$proj (projdir=$projdir)"
