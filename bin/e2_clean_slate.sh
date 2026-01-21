#!/usr/bin/env bash
set -euo pipefail

# e2_clean_slate.sh
# 目的：清掉「跑分產物（logs/matrix/summary/per-run logs）與必要的暫存」，
#      並可選擇性清除 A2 seed / npm cache / shared_deps / projects/*/node_modules。
#
# 你指定的重點：要刪除 frontier_poc/{express-app,next-grofers,ghost}/logs 底下的資料夾與 csv
# => 本版預設會清掉 frontier_poc/*/logs 與其下所有內容（包含子目錄與 CSV），且不限專案名。

# ===== 可選旗標（環境變數覆寫） ===============================================
: "${CLEAR_A2_SEED:=0}"           # 1=連同 a2_ro/<proj> 也清掉（對所有 proj 或指定 PROJ）
: "${CLEAR_NPM_CACHE:=0}"         # 1=清 npm/yarn cache（root 下的 npm-cache*, yarn-cache*, pkg-cache* 等）
: "${CLEAR_SHARED_DEPS:=0}"       # 1=清 shared_deps/*_node_modules
: "${CLEAR_PROJECT_NODEMOD:=0}"   # 1=清 projects/*/node_modules（非掛載才會刪；預設 0，避免誤刪）
: "${CLEAR_WORKER_CLONES:=1}"     # 1=清 projects/*.w* worker clones（預設 1）
: "${CLEAR_RUN_TMP:=1}"           # 1=清 root/{work,runs,locks}（若存在）
: "${CLEAR_NEIGHBOR:=1}"          # 1=也清 frontier_poc/*.neighbor（預設 1）
: "${DRY_RUN:=0}"                 # 1=只顯示，不執行

# 根目錄可由 E2_ROOT 覆寫
root="${E2_ROOT:-$HOME/experiment/e_ex}"

# 可指定只清特定專案（PROJ 或第一個參數）；若空則清全部專案的 logs
PROJ="${1:-${PROJ:-}}"

say() { echo -e "\033[1;36m[clean]\033[0m $*"; }
doit() { if [[ "$DRY_RUN" = "1" ]]; then echo "DRY: $*"; else eval "$@"; fi; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found" >&2; exit 1; }; }
need_cmd find
need_cmd rm
need_cmd awk

# Optional
have() { command -v "$1" >/dev/null 2>&1; }

# 要用到 sudo 的地方先驗證一次，避免中途卡密碼
if have sudo; then sudo -v || true; fi

# Helper: list project dirs under frontier_poc
list_frontier_projects() {
  # Returns absolute paths like $root/frontier_poc/<proj>
  if [[ -n "${PROJ}" ]]; then
    if [[ -d "$root/frontier_poc/${PROJ}" ]]; then
      echo "$root/frontier_poc/${PROJ}"
    else
      echo "WARN: specified PROJ='${PROJ}' not found under frontier_poc" >&2
    fi
    return 0
  fi

  # all projects under frontier_poc (depth 1)
  find "$root/frontier_poc" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

# Helper: safe umount for node_modules mountpoints
umount_all_project_node_modules() {
  say "find & umount any mounted node_modules under $root/projects ..."
  if ! have findmnt; then
    warn_findmnt=1
  else
    warn_findmnt=0
  fi

  mapfile -t nms < <(find "$root/projects" -maxdepth 2 -type d -name node_modules 2>/dev/null | sort)

  for nm in "${nms[@]:-}"; do
    if (( warn_findmnt )); then
      # fallback via /proc/mounts
      if awk -v m="$nm" '$2==m{found=1} END{exit(found?0:1)}' /proc/mounts; then
        say "umount $nm"
        doit "sudo umount -l '$nm' || true"
      fi
    else
      if findmnt -rn "$nm" >/dev/null 2>&1; then
        say "umount $nm"
        doit "sudo umount -l '$nm' || true"
      fi
    fi
  done
}

# ===== 0) 先卸載可能的掛載（避免 rm 卡住） ====================================
umount_all_project_node_modules

# ===== 1) 清除 worker 複本（*.wN） ==========================================
if [[ "$CLEAR_WORKER_CLONES" = "1" ]]; then
  say "remove worker clones under projects/ (*.w*)"
  doit "find '$root/projects' -maxdepth 1 -type d -name '*.w*' -print -exec rm -rf {} +"
fi

# ===== 2) 清除 root/work root/runs root/locks =================================
if [[ "$CLEAR_RUN_TMP" = "1" ]]; then
  for d in work runs locks; do
    if [[ -e "$root/$d" ]]; then
      say "remove $d/ (tmp artifacts)"
      doit "rm -rf '$root/$d'"
    fi
  done
fi

# ===== 3) 清除 frontier_poc/*/logs（含子目錄與 csv） ==========================
# 這是你指定的核心需求：不只 express-app，也包含 next-grofers、ghost 等所有 project
say "remove ALL contents under frontier_poc/*/logs (folders + csv), scoped=${PROJ:-ALL}"

while IFS= read -r projdir; do
  [[ -n "$projdir" ]] || continue
  logdir="$projdir/logs"
  if [[ -d "$logdir" ]]; then
    say "wipe $logdir/"
    # 保留 logs 目錄本身，刪除其內容（含子目錄）
    doit "find '$logdir' -mindepth 1 -maxdepth 1 -print -exec rm -rf {} +"
  fi

  # 如果你也希望清 pkgs（你前版有做），保留這段；不想清可以改成 CLEAR_PKGS flag
  pkgsdir="$projdir/pkgs"
  if [[ -d "$pkgsdir" ]]; then
    say "wipe $pkgsdir/"
    doit "find '$pkgsdir' -mindepth 1 -maxdepth 1 -print -exec rm -rf {} +"
  fi
done < <(list_frontier_projects)

# ===== 4) 鄰居資料（可選） =====================================================
if [[ "$CLEAR_NEIGHBOR" = "1" ]]; then
  say "remove frontier_poc/*.neighbor (if any), scoped=${PROJ:-ALL}"
  if [[ -n "${PROJ}" ]]; then
    if [[ -d "$root/frontier_poc/${PROJ}.neighbor" ]]; then
      doit "rm -rf '$root/frontier_poc/${PROJ}.neighbor'"
    fi
  else
    doit "find '$root/frontier_poc' -mindepth 1 -maxdepth 1 -type d -name '*.neighbor' -print -exec rm -rf {} +"
  fi
fi

# ===== 5) 舊/legacy 產物（保留相容） ==========================================
if [[ -d "$root/frontier_poc/express" ]]; then
  say "remove frontier_poc/express (legacy PoC)"
  doit "rm -rf '$root/frontier_poc/express'"
fi
if [[ -d "$root/frontier_logs" ]]; then
  say "remove frontier_logs (legacy)"
  doit "rm -rf '$root/frontier_logs'"
fi
if [[ -f "$root/multiwork_summary.csv" ]]; then
  say "remove multiwork_summary.csv (legacy)"
  doit "rm -f '$root/multiwork_summary.csv'"
fi

# ===== 6) 清除專案內的 node_modules（可選，預設關閉） =========================
if [[ "$CLEAR_PROJECT_NODEMOD" = "1" ]]; then
  say "remove projects/*/node_modules (non-mount only)"
  mapfile -t nms < <(find "$root/projects" -maxdepth 2 -type d -name node_modules 2>/dev/null)
  for nm in "${nms[@]:-}"; do
    if have findmnt && findmnt -rn "$nm" >/dev/null 2>&1; then
      say "skip mounted $nm"
      continue
    fi
    # symlink 的 node_modules 也別直接 rm -rf（避免誤刪外部路徑）；只刪 link 本身
    if [[ -L "$nm" ]]; then
      say "remove symlink $nm"
      doit "rm -f '$nm'"
      continue
    fi
    doit "rm -rf '$nm'"
  done
fi

# ===== 7) 清除 shared_deps（可選） ============================================
if [[ "$CLEAR_SHARED_DEPS" = "1" && -d "$root/shared_deps" ]]; then
  say "remove shared_deps/*_node_modules"
  doit "rm -rf '$root/shared_deps'/*_node_modules"
fi

# ===== 8) 清除 A2 seed（可選） ================================================
if [[ "$CLEAR_A2_SEED" = "1" ]]; then
  say "remove A2 seed under a2_ro/, scoped=${PROJ:-ALL}"
  if [[ -n "${PROJ}" ]]; then
    if [[ -d "$root/a2_ro/$PROJ" ]]; then
      doit "rm -rf '$root/a2_ro/$PROJ'"
    else
      say "A2 seed not found: $root/a2_ro/$PROJ (skip)"
    fi
  else
    # all projects under a2_ro
    if [[ -d "$root/a2_ro" ]]; then
      doit "find '$root/a2_ro' -mindepth 1 -maxdepth 1 -type d -print -exec rm -rf {} +"
    fi
  fi
fi

# ===== 9) 清除 npm/yarn cache（可選） =========================================
if [[ "$CLEAR_NPM_CACHE" = "1" ]]; then
  say "remove npm / yarn caches under $root/"

  # 若有 symlink npm-cache -> npm-cache.<ts>，先移除 symlink 再移除實體
  if [[ -L "$root/npm-cache" ]]; then
    say "remove npm-cache symlink"
    doit "rm -f '$root/npm-cache'"
  fi

  # 舊版單一 npm-cache 目錄
  if [[ -d "$root/npm-cache" ]]; then
    say "remove npm-cache dir"
    doit "rm -rf '$root/npm-cache'"
  fi

  # 新版：timestamp / 多版本 cache
  mapfile -t caches < <(
    find "$root" -maxdepth 1 -type d \( \
      -name 'npm-cache.*' -o \
      -name 'yarn-cache.*' -o \
      -name 'pkg-cache.*' \
    \) 2>/dev/null
  )
  for c in "${caches[@]:-}"; do
    say "remove cache dir $c"
    doit "rm -rf '$c'"
  done

  # 也可清 ~/.npm / ~/.cache/yarn（較激進，預設不做）
  # say "NOTE: not touching ~/.npm or ~/.cache/yarn (set CLEAR_HOME_CACHES=1 if needed)"
fi

say "done."
