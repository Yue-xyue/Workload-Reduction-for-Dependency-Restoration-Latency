#!/usr/bin/env bash
set -euo pipefail

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

# === 基本變數與守門（全面參數化，可環境覆寫） ================================
root="${E2_ROOT:-$HOME/experiment/e_ex}"
proj="${1:-${PROJ:-express-app}}"                  # 允許參數或環境變數指定
projdir_base="$root/projects/$proj"
projdir="${PROJECT_DIR:-$projdir_base}"
frontier_dir="${FRONTIER_DIR:-$root/frontier_poc/$proj}"
logd="${LOG_DIR:-$frontier_dir/logs}"
pkgd="${PKG_DIR:-$frontier_dir/pkgs}"
npm_cache="${NPM_CACHE_DIR:-$root/npm-cache}"

# E5 新增：角色與方法
ROLE="${ROLE:-target}"            # target / neighbor
METHOD="${METHOD:-baseline_full}" # fallback 用

export ROLE METHOD

# 若上游（e5_driver）已設定 METHODS，這裡依 ROLE 將它對應回 E5_TARGET_METHODS / E5_NEIGHBOR_METHODS
# 目的：讓新版 e5_driver 傳進來的 METHODS 能與既有 E5_* methods 流程兼容
if [[ -n "${METHODS:-}" ]]; then
  if [[ "$ROLE" = "target" && -z "${E5_TARGET_METHODS:-}" ]]; then
    E5_TARGET_METHODS="$METHODS"
  elif [[ "$ROLE" = "neighbor" && -z "${E5_NEIGHBOR_METHODS:-}" ]]; then
    E5_NEIGHBOR_METHODS="$METHODS"
  fi
fi

# 預設每個專案使用的套件管理工具（可被 PKG_TOOL / E2_PKG_TOOL 覆寫）
case "$proj" in
  ghost)
    PKG_TOOL_DEFAULT="yarn"
    ;;
  *)
    PKG_TOOL_DEFAULT="npm"
    ;;
esac
PKG_TOOL="${PKG_TOOL:-${E2_PKG_TOOL:-$PKG_TOOL_DEFAULT}}"
export PKG_TOOL

# Yarn 專用 cache（預設放在 npm-cache/yarn 底下）
yarn_cache="${YARN_CACHE_DIR:-$root/npm-cache/yarn}"
if [[ "$PKG_TOOL" = "yarn" ]]; then
  export YARN_CACHE_FOLDER="$yarn_cache"
fi

# 導出給下游工具（summarizer 之類可用）
export PROJ="$proj"
export FRONTIER_DIR="$frontier_dir"
export LOG_DIR="$logd"
export PKG_DIR="$pkgd"
export NPM_CONFIG_CACHE="$npm_cache"

mkdir -p "$logd" "$pkgd" "$npm_cache" "$root/bin" "$root/locks"

# E2_SKIP_INSTALL 時，同步關閉「刪 node_modules」與「frontier 建置」
if [[ "${E2_SKIP_INSTALL:-0}" = "1" ]]; then
  export E2_SKIP_RM_NODE_MODULES=1
  export E2_SKIP_BUILD_FRONTIER=1
fi

# E5 worker：預設每次呼叫只跑 E2_ROUNDS 回合；實際總回合數會依 method 數量調整
rounds="${E2_ROUNDS:-1}"

# 控制旗標
RANDOMIZE="${RANDOMIZE:-1}"
ENABLE_TOPK="${ENABLE_TOPK:-0}"
ENABLE_A2="${ENABLE_A2:-0}"
LIMITKB="${LIMITKB:-20480}"

# E8 覆蓋率實驗開關：
# E2_E8_COVERAGE=1 時，run 階段改以 strace 收集 smoke / test 的檔案觸及集合
# E2_E8_EXTRA_CMD 指定額外 workload（例如：npm test / npm run build）
E2_E8_COVERAGE="${E2_E8_COVERAGE:-0}"

# --- 每 worker 隔離專案（建議 conc>1 一律開啟） -----------------------------
if [[ "${ISOLATE_PROJECT_PER_WORKER:-0}" = "1" && -n "${WORKER_ID:-}" ]]; then
  iso_dir="$projdir_base.w${WORKER_ID}"
  rsync -a --delete --exclude node_modules "$projdir_base/" "$iso_dir/"
  projdir="$iso_dir"
fi

cd "$projdir"

# npm 旗標（僅在使用 npm 時有效；NO_NET_DOWNLOAD=1 則加入 --offline）
npm_flags="--cache=$npm_cache --prefer-offline --no-audit --fund=false --progress=false"
if [[ "${NO_NET_DOWNLOAD:-0}" = "1" ]]; then
  npm_flags="$npm_flags --offline"
fi

smoke_js="smoke_deps.mjs"
[[ -f "$smoke_js" ]] || { echo "[fatal] $smoke_js missing under $projdir" >&2; exit 2; }

# --- helpers: mount / unmount / RW guard / seed 檢查 -------------------------
is_mountpoint() { findmnt -rn "$1" >/dev/null 2>&1; }

a2_status_file="$projdir/.a2_status"
a2_lock_file="$projdir/.a2_mount.lock"

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

ensure_rw_node_modules() {
  local nm="$projdir/node_modules"
  if is_mountpoint "$nm"; then
    echo "[guard] $nm is a mount ($(findmnt -no OPTIONS "$nm")) -> umount -l"
    sudo umount -l "$nm" || true
  fi
  mkdir -p "$nm"
  if ! (touch "$nm/.rw_test" 2>/dev/null); then
    echo "[guard] $nm not writable; abort"; return 1
  fi
  rm -f "$nm/.rw_test"
}

a2_mount_from_seed() {
  local seed="" nm="$projdir/node_modules"
  seed="$(a2_seed_from_status || true)"
  [[ -z "$seed" ]] && seed="$root/a2_ro/$proj/node_modules"
  if [[ ! -d "$seed" ]]; then
    echo "[A2] seed not found -> build once"
    sudo -v || true
    CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    PATH="$CLEAN_PATH" "$root/bin/e2_a2_setup.sh" "$proj" "$npm_flags"
    seed="$(a2_seed_from_status || true)"
    [[ -d "$seed" ]] || { echo "[fatal] A2 seed build failed"; exit 3; }
  fi

  exec {a2fd}>"$a2_lock_file"
  flock -w 30 "$a2fd" || true

  if is_mountpoint "$nm" && findmnt -no OPTIONS "$nm" | grep -q '\bro\b'; then
    echo "[A2] node_modules already ro-mounted -> reuse"
    flock -u "$a2fd" || true
    return 0
  fi

  if is_mountpoint "$nm"; then
    sudo umount -l "$nm" || true
  fi
  mkdir -p "$nm"
  echo "[A2] mount --bind $seed -> $nm (ro)"
  sudo mount --bind "$seed" "$nm"
  sudo mount -o remount,ro,bind "$nm" || {
    echo "[A2][warn] remount ro failed (will continue)"; true;
  }
  if ! findmnt -no OPTIONS "$nm" | grep -q '\bro\b'; then
    echo "[A2][warn] node_modules 未成功唯讀掛載（仍會繼續，但請在結果標註）"
  fi
  flock -u "$a2fd" || true
}

# on-exit：避免殘留唯讀掛載
cleanup() { a2_unmount_if_mounted || true; }
trap cleanup EXIT

# 安全刪除（避免刪到唯讀掛載點）— inline 純命令版本
inline_safe_rm='(findmnt -rn node_modules >/dev/null 2>&1 && echo "[guard rm] skip rm -rf node_modules (mountpoint)" || rm -rf node_modules)'

# --- install 指令預設：依 PKG_TOOL 決定 npm / yarn --------------------------
default_install_cmd() {
  case "${PKG_TOOL:-npm}" in
    yarn)
      # ghost 等 Yarn 專案預設：immutable + ignore-engines；若 NO_NET_DOWNLOAD=1 則加 --offline
      local cmd="YARN_CACHE_FOLDER='$yarn_cache' yarn install --immutable --ignore-engines --non-interactive"
      if [[ "${NO_NET_DOWNLOAD:-0}" = "1" ]]; then
        cmd="$cmd --offline"
      fi
      echo "$cmd"
      ;;
    npm|*)
      # 原本的 npm ci 路徑
      echo "npm ci $npm_flags"
      ;;
  esac
}

# --- install 包裝：預設依 PKG_TOOL，也可由 E2_INSTALL_CMD 覆寫 -------------
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

  # 實際執行安裝指令
  if ! bash -lc "$cmd" >"$logf" 2>&1; then
    # 僅在「PKG_TOOL=npm 且沒客製 E2_INSTALL_CMD」時，啟用 ENOTCACHED → PRIME fallback
    if [[ -z "${E2_INSTALL_CMD:-}" && "${PKG_TOOL:-npm}" = "npm" ]]; then
      if [[ "${NO_NET_DOWNLOAD:-0}" = "1" ]] && grep -q 'ENOTCACHED' "$logf"; then
        echo "[fatal] npm cache missing under offline mode (ENOTCACHED)." >&2
        echo "        建議方案 A：先做一次 PRIME（允許網路）以灌滿快取：" >&2
        echo "        NO_NET_DOWNLOAD=0 NPM_CONFIG_OFFLINE= PROJ=$proj E2_ROUNDS=1 \\ " >&2
        echo "          $0 \"$proj\" && 再切回 NO_NET_DOWNLOAD=1" >&2
        if [[ "${NPM_PRIME_ON_FAIL:-0}" = "1" ]]; then
          echo "[prime] NPM_PRIME_ON_FAIL=1 -> 暫時允許網路以填快取後再重試（一次性）" >&2
          local npm_flags_online="${npm_flags// --offline/}"
          unset NPM_CONFIG_OFFLINE || true
          if npm ci $npm_flags_online >>"$logf" 2>&1; then
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
    # 其他失敗（或非 npm）：把前 200 行 log 帶出以利除錯
    sed -n '1,200p' "$logf" >&2 || true
    return 1
  fi
  return 0
}

# 版本與環境（stage0）
{
  {
    echo "=== VERSION SNAPSHOT ==="
    date -Is
    node -v
    npm -v
    uname -a
    lsb_release -a 2>/dev/null || true
    echo "cpu_governor=$(detect_cpu_governor)"
  } > "$root/VERSION.md"
  CPU_GOV_PRINT="${E2_LAST_CPU_GOV:-$(detect_cpu_governor)}"
  echo "[stage0] node=$(node -v) npm=$(npm -v) cpu_gov=$CPU_GOV_PRINT" 1>&2
  echo "[stage0] 建議先執行 bin/e2_preflight.sh" 1>&2
  echo "[stage0] rounds=$rounds (E2_ROUNDS, default 1 for e5_worker)" 1>&2
} || true

# === 是否需要建 frontier =====================================================
# E5 預設不在 worker 內重建 frontier；如需重建，外部設定 E5_BUILD_FRONTIER=1
need_frontier=0
if [[ "${E5_BUILD_FRONTIER:-0}" = "1" ]]; then
  need_frontier=1
fi

# 如已存在 cache 且 FRONTIER_CACHE=1，則重用，不再重建
if [[ "$need_frontier" -eq 1 && "${FRONTIER_CACHE:-0}" = "1" && -f "$pkgd/nm.frontier.tar" ]]; then
  need_frontier=0
fi

ts_iso="$(date -Is)"
ts_ns="$(date +%s%N)"
tdir="$logd/${ts_ns}_w${WORKER_ID:-0}_trace"
mkdir -p "$tdir" "$pkgd"

only_frontier_then_exit=0
if [[ "${ROUNDS_ONLY_FRONTIER:-0}" = "1" ]]; then
  only_frontier_then_exit=1
fi

frontier_bytes=0; frontier_files=0; bulk_bytes=0; bulk_files=0
if [[ "$need_frontier" -eq 1 ]]; then
  echo "[build] frontier from strace at SRC=$projdir"

  a2_unmount_if_mounted
  ensure_rw_node_modules

  eval "$inline_safe_rm"
  # 以包裝器執行安裝（依 PKG_TOOL 或 E2_INSTALL_CMD）
  run_install_cmd "$tdir/npm_ci.log" || exit 6

  strace -f -tt -qq -s 300 -o "$tdir/strace.log" -e trace=%file -e status=successful node "$smoke_js"

  pwd_abs="$(pwd)/"

  # 1) 從 strace 抽出「候選絕對路徑」，先只看有提到 node_modules/ 的成功檔案操作
  grep -oE '"([^"]+)"' "$tdir/strace.log" \
  | sed -E 's/^"//; s/"$//' \
  | awk -v P="$pwd_abs" '
      {
        p=$0
        if (substr(p,1,1)!="/") p=P p    # 相對路徑 → 絕對路徑
        if (index(p,"/node_modules/") && index(p,"/.cache/")==0) {
          print p
        }
      }
    ' | sort -u > "$tdir/frontier_abs.txt"

  # 2) 透過 realpath / readlink -f 追 symlink，只保留「實際仍在 $projdir/node_modules/ 之下」的檔案
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
        # 還在 $projdir/node_modules/ 底下 → 轉成相對路徑寫回 frontier_files.txt
        rel="${rp#"$pwd_abs"}"
        printf '%s\n' "$rel" >> "$tdir/frontier_files.txt"
        ;;
      *)
        # 透過 symlink 跳出 node_modules/ 的 path（例如 Ghost 的 ../ghost/core）一律跳過
        ;;
    esac
  done < "$tdir/frontier_abs.txt"

  sort -u -o "$tdir/frontier_files.txt" "$tdir/frontier_files.txt"

  # 3) all_files / bulk_files 維持原本語意
  find node_modules -type f | sort > "$tdir/all_files.txt"
  comm -23 "$tdir/all_files.txt" "$tdir/frontier_files.txt" > "$tdir/bulk_files.txt"

  tar --no-recursion -cf "$pkgd/nm.frontier.tar" -T "$tdir/frontier_files.txt"
  tar --no-recursion -cf "$pkgd/nm.bulk.tar"     -T "$tdir/bulk_files.txt"

  frontier_bytes=$(tar -tvf "$pkgd/nm.frontier.tar" | awk '{s+=$3} END{print s+0}')
  frontier_files=$(tar -tvf "$pkgd/nm.frontier.tar" | wc -l | tr -d ' ')
  bulk_bytes=$(tar -tvf "$pkgd/nm.bulk.tar" | awk '{s+=$3} END{print s+0}')
  bulk_files=$(tar -tvf "$pkgd/nm.bulk.tar" | wc -l | tr -d ' ')
  all_bytes=$(( frontier_bytes + bulk_bytes ))
  all_files=$(( frontier_files + bulk_files ))
  pct=$(awk -v a="$frontier_bytes" -v b="$all_bytes" 'BEGIN{print (b>0?100*a/b:0)}')
  printf "[build] frontier=%s files=%s | bulk=%s files=%s | all=%s files=%s | frontier_pct=%.2f%%\n" \
    "$frontier_bytes" "$frontier_files" "$bulk_bytes" "$bulk_files" "$all_bytes" "$all_files" "$pct"
else
  echo "[build] skip frontier (reuse cache; FRONTIER_CACHE=${FRONTIER_CACHE:-0})"
  if [[ ! -f "$pkgd/nm.frontier.tar" || ! -f "$pkgd/nm.bulk.tar" ]]; then
    echo "[build] cache missing -> create empty placeholders (B2 不應使用)"
    mkdir -p "$tdir/_empty"
    tar -C "$tdir/_empty" -cf "$pkgd/nm.frontier.tar" .
    tar -C "$tdir/_empty" -cf "$pkgd/nm.bulk.tar" .
  fi
fi

if [[ "$only_frontier_then_exit" -eq 1 ]]; then
  echo "[build] frontier-only mode -> exit"
  exit 0
fi

# ===== 2) TopK（預設關閉；原樣保留）=========================================
topk_bytes=0
if [[ "$ENABLE_TOPK" -eq 1 && "$need_frontier" -eq 1 ]]; then
  echo "[info] topk target ~= $LIMITKB KB"
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
  echo "[topk] bytes=$topk_bytes"
fi

# ===== 3) 若要跑 A2：**只建 seed，不常駐掛載** ==============================
if [[ "$ENABLE_A2" -eq 1 ]]; then
  if [[ ! -r "$a2_status_file" ]]; then
    echo "[A2] build seed once (status missing)"
    "$root/bin/e2_a2_setup.sh" "$proj" "$npm_flags" || true
    a2_unmount_if_mounted
  fi
fi

# ===== 4) meta =================================================================
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
  "topk_enabled":$ENABLE_TOPK,
  "topk_limit_kb":$LIMITKB,
  "frontier_bytes":$frontier_bytes,
  "frontier_files":$frontier_files,
  "bulk_bytes":$bulk_bytes,
  "bulk_files":$bulk_files,
  "topk_bytes":$topk_bytes
}
EOF

# --- net sandbox helper：必要時把 extract 丟進獨立 net namespace ------------
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

# ===== 5) 多 method / 多輪實驗：抽成函式 ====================================
RUN_RANDOM_SEED="${RUN_RANDOM_SEED:-$RANDOM}"

e5_run_one_round() {
  local m="$1"
  local idx="$2"        # 全域 round index（1..total_rounds）
  local total="$3"      # 全域 total_rounds，用於 log 顯示

  local work out cmd pre_rm do_ci cnt \
        preheat_root preheat_n preheat_cmd preheat_head_n cmd_esc

  work="$root/work/${proj}-$(date +%s%N)-w${WORKER_ID:-0}"
  mkdir -p "$work"

  echo "[E5][round $idx/$total] work=$work method=$m role=$ROLE"

  out="$logd/$(date +%s%N)_w${WORKER_ID:-0}_${m}"
  mkdir -p "$out"
  cp "$meta" "$out/meta.json" 2>/dev/null || true
  if [[ "$m" == "a2_shared_ro" && -f "$a2_status_file" ]]; then
    cp -n "$a2_status_file" "$out/.a2_status" 2>/dev/null || true
  fi
  {
    echo "SEED=$RUN_RANDOM_SEED"
    echo "ROUND=$idx"
    echo "RUN_TAG=${RUN_TAG:-}"
    echo "WORKER_ID=${WORKER_ID:-}"
    echo "E2_CONC=${E2_CONC:-1}"
    echo "E2_MEM_PROFILE=${E2_MEM_PROFILE:-ample}"
    echo "ROLE=${ROLE:-target}"
    echo "CG_MEM_MAX_BYTES=${CG_MEM_MAX_BYTES:-}"
  } > "$out/meta.extras"

  case "$m" in
    baseline_full)
      a2_unmount_if_mounted
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
      cmd="${pre_rm} sync; [[ -z \"\${NO_DROP_CACHES:-}\" ]] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || :; ${do_ci}"
      ;;

    b2_frontier_only)
      a2_unmount_if_mounted
      ensure_rw_node_modules
      if [[ "${E2_SKIP_RM_NODE_MODULES:-0}" != "1" ]]; then
        pre_rm="$inline_safe_rm;"
      else
        pre_rm='echo "[guard rm] skip rm -rf node_modules";'
      fi
      cnt=$(tar -tf "$pkgd/nm.frontier.tar" 2>/dev/null | wc -l | tr -d ' ')
      if [[ "${cnt:-0}" -le 1 ]]; then
        echo "[fatal] nm.frontier.tar is empty (cnt=${cnt:-0}); should have been rebuilt earlier"
        exit 4
      fi
      cmd="${pre_rm} sync; [[ -z \"\${NO_DROP_CACHES:-}\" ]] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || :; mkdir -p node_modules; tar xf \"$pkgd/nm.frontier.tar\""
      ;;

    b2_frontier_plus_full)
      a2_unmount_if_mounted
      ensure_rw_node_modules
      if [[ "${E2_SKIP_RM_NODE_MODULES:-0}" != "1" ]]; then
        pre_rm="$inline_safe_rm;"
      else
        pre_rm='echo "[guard rm] skip rm -rf node_modules";'
      fi
      cnt=$(tar -tf "$pkgd/nm.frontier.tar" 2>/dev/null | wc -l | tr -d ' ')
      if [[ "${cnt:-0}" -le 1 ]]; then
        echo "[fatal] nm.frontier.tar is empty (cnt=${cnt:-0}); should have been rebuilt earlier"
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
      # 先解 frontier，再跑完整 install（語意與 baseline 一致，只是多了預熱）
      cmd="${pre_rm} sync; [[ -z \"\${NO_DROP_CACHES:-}\" ]] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || :; mkdir -p node_modules; tar xf \"$pkgd/nm.frontier.tar\"; ${do_ci}"
      ;;

    a2_shared_ro)
      a2_mount_from_seed
      cmd='sync; [[ -z "${NO_DROP_CACHES:-}" ]] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || :; :'
      ;;

    c1_vmtouch)
      # C1：粗暴預熱（linear touch，大範圍）+ 完整 install
      a2_unmount_if_mounted
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

      preheat_root="${E4_PREHEAT_TARGET:-$npm_cache}"
      preheat_n="${E4_LINEAR_N:-0}"   # >0 則只掃前 N 個檔案，=0 則掃全部

      if [[ -z "$preheat_root" || ! -d "$preheat_root" ]]; then
        # 沒東西可以預熱就直接當 baseline_full 跑
        echo "[c1] WARN: preheat_root='$preheat_root' 不存在，退化為 baseline_full"
        preheat_cmd=':;'
      else
        if [[ "$preheat_n" -gt 0 ]]; then
          preheat_cmd="echo \"[c1] preheat (linear head 4K, limit=$preheat_n) on $preheat_root\"; \
          find \"$preheat_root\" -xdev -type f | head -n $preheat_n | xargs -r -n1 head -c 4096 >/dev/null 2>&1; "
        else
          preheat_cmd="echo \"[c1] preheat (linear head 4K, full tree) on $preheat_root\"; \
          find \"$preheat_root\" -xdev -type f | xargs -r -n1 head -c 4096 >/dev/null 2>&1; "
        fi
      fi

      cmd="${pre_rm} \
      sync; [[ -z \"\${NO_DROP_CACHES:-}\" ]] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || :; \
      $preheat_cmd \
      ${do_ci}"
      ;;

    c2_head4k)
      # C2：粗暴預熱（只掃少量檔案 head 4K）+ 完整 install
      a2_unmount_if_mounted
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

      preheat_root="${E4_PREHEAT_TARGET:-$npm_cache}"
      preheat_head_n="${E4_HEAD_N:-10000}"   # 預設只掃前 10,000 個檔案

      if [[ -z "$preheat_root" || ! -d "$preheat_root" ]]; then
        echo "[c2] WARN: preheat_root='$preheat_root' 不存在，退化為 baseline_full"
        preheat_cmd=':;'
      else
        preheat_cmd="echo \"[c2] preheat (head -n $preheat_head_n, 4K each) on $preheat_root\"; \
        find \"$preheat_root\" -xdev -type f | head -n $preheat_head_n | xargs -r -n1 head -c 4096 >/dev/null 2>&1; "
      fi

      cmd="${pre_rm} \
      sync; [[ -z \"\${NO_DROP_CACHES:-}\" ]] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || :; \
      $preheat_cmd \
      ${do_ci}"
      ;;

    *)
      echo "[fatal] unknown method: $m" >&2; exit 3;;
  esac

  # 依需求，將 cmd 丟入 net sandbox（unshare -n）
  cmd="$(wrap_with_net_sandbox "$cmd")"
  printf -v cmd_esc "%q" "$cmd"

  export RUN_TAG="${RUN_TAG:-}"
  export WORKER_ID="${WORKER_ID:-}"
  export E2_CONC="${E2_CONC:-1}"
  export E2_MEM_PROFILE="${E2_MEM_PROFILE:-ample}"
  export CG_MEM_MAX_BYTES="${CG_MEM_MAX_BYTES:-}"

  /usr/bin/time -v -o "$out/timev_extract.log" \
    bash -lc 'node "'"$root"'/e2_tools/e2wrap.js" -- '"$cmd_esc" \
    > "$out/wrap_extract.log" 2>&1 || true

  if ! grep -q 'PHASE2_BOOTTIME_MS' "$out/wrap_extract.log"; then
    echo "[warn] wrap_extract.log missing PHASE2_BOOTTIME_MS for $m (out=$(basename "$out"))" >&2
  fi

  # --- Phase-2 後的 smoke / test 執行區塊 ---------------------------------
  if [[ "$E2_E8_COVERAGE" = "1" ]]; then
    echo "[e8] coverage mode enabled for method=$m" >&2

    # 1) smoke_deps.mjs：收集 U_smoke
    strace -f -tt -qq -s 300 \
      -o "$out/strace_smoke.log" \
      -e trace=%file -e status=successful \
      node "$smoke_js" \
      >"$out/stdout_run.log" 2>"$out/stderr_run.log" || true

    # 2) 額外工作（例如 npm test / npm run build）：收集 U_extra
    if [[ -n "${E2_E8_EXTRA_CMD:-}" ]]; then
      echo "[e8] extra workload: $E2_E8_EXTRA_CMD" >&2
      strace -f -tt -qq -s 300 \
        -o "$out/strace_extra.log" \
        -e trace=%file -e status=successful \
        bash -lc "$E2_E8_EXTRA_CMD" \
        >"$out/stdout_extra.log" 2>"$out/stderr_extra.log" || true
    fi
  else
    /usr/bin/time -v -o "$out/timev_run.log" \
      bash -lc 'node '"$smoke_js"'' \
      > "$out/stdout_run.log" 2>"$out/stderr_run.log" || true
  fi
}

# ===== 6) 依 ROLE 與 E5_TARGET/NEIGHBOR_METHODS 安排實際回合數 ==============
# 解析 target / neighbor methods（以空白切）
IFS=' ' read -r -a E5_TARGET_METHODS_ARR <<< "${E5_TARGET_METHODS:-}"
IFS=' ' read -r -a E5_NEIGHBOR_METHODS_ARR <<< "${E5_NEIGHBOR_METHODS:-}"

# 若 target list 為空，就用 METHOD 當成唯一方法（維持原本語意）
if ((${#E5_TARGET_METHODS_ARR[@]} == 0)); then
  E5_TARGET_METHODS_ARR=("$METHOD")
fi

# 若 neighbor list 為空，也用 METHOD（通常會被 e5_driver 設成 baseline_full）
if ((${#E5_NEIGHBOR_METHODS_ARR[@]} == 0)); then
  E5_NEIGHBOR_METHODS_ARR=("$METHOD")
fi

target_method_count=${#E5_TARGET_METHODS_ARR[@]}
if ((target_method_count <= 0)); then
  target_method_count=1
fi

# target 總共要跑的回合數、neighbor 也跟著跑一樣的總回合數（確保干擾期間一致）
total_rounds=$((rounds * target_method_count))

if [[ "$ROLE" == "target" ]]; then
  idx=1
  for m in "${E5_TARGET_METHODS_ARR[@]}"; do
    for ((r=1; r<=rounds; r++)); do
      e5_run_one_round "$m" "$idx" "$total_rounds"
      ((idx++))
    done
  done
else
  # neighbor 一律只用第一個方法（預期為 baseline_full），但回合數 total_rounds
  m="${E5_NEIGHBOR_METHODS_ARR[0]}"
  idx=1
  for ((k=1; k<=total_rounds; k++)); do
    e5_run_one_round "$m" "$idx" "$total_rounds"
    ((idx++))
  done
fi

# ===== 7) 彙整（穩健 Python 版 + fallback） =================================
python3 "$root/bin/summarize_from_logs.py" --project "$proj" || true

summary_csv="$logd/summary.csv"
rows=$(( $(wc -l < "$summary_csv" 2>/dev/null || echo 0) - 1 ))
if [[ "$rows" -le 0 ]]; then
  echo "[summary][fallback] summary.csv currently empty -> rebuilding from wraps"

  HDR='ts,method,boottime_ms,elapsed_s,fs_inputs,fs_outputs,psi_io_some_pct,psi_io_full_pct,psi_cpu_some_pct,psi_mem_some_pct,cg_io_rbytes_delta,pgmaj_delta,net_bytes_delta,frontier_bytes,bulk_bytes,topk_bytes,topk_enabled,topk_limit_kb,run_tag,worker_id,e2_conc,e2_mem_profile,cg_memory_max,cg_memory_max_bytes,cg_memory_current_bytes,cg_swap_current_bytes,cg_path_before,cg_path_after,a2_seed_path,a2_seed_bytes,run_id,seed,round,timev_user_s,timev_sys_s'
  printf '%s\n' "$HDR" > "$summary_csv"

  ns_to_ts() {
    local ns="$1"; local s="${ns%?????????}"
    date -d "@$s" +%Y%m%d%H%M%S 2>/dev/null || echo "00000000000000"
  }
  jget() { grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" | sed -E 's/.*"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'; }
  eget() { grep -oE "^$2=.*" "$1" | head -1 | cut -d= -f2-; }

  mapfile -t WRAPS < <(find "$logd" -type f -name 'wrap_extract.log' | sort)
  for w in "${WRAPS[@]}"; do
    d="$(dirname "$w")"
    base="$(basename "$d")"
    ts_ns_wrap="${base%%_*}"
    method_wrap="${base##*_}"
    ts="$(ns_to_ts "$ts_ns_wrap")"

    bt="$(grep -oE 'PHASE2_BOOTTIME_MS[[:space:]]+[0-9]+' "$w" | awk '{print $2}' | tail -1)"
    [[ -z "${bt:-}" ]] && continue

    s_ns="$(grep -oE 'PHASE2_START_NS[[:space:]]+[0-9]+' "$w" | awk '{print $2}' | tail -1)"
    e_ns="$(grep -oE 'PHASE2_END_NS[[:space:]]+[0-9]+'   "$w" | awk '{print $2}' | tail -1)"
    elapsed_s=""
    [[ -n "${s_ns:-}" && -n "${e_ns:-}" ]] && elapsed_s="$(awk -v s="$s_ns" -v e="$e_ns" 'BEGIN{printf "%.3f",(e-s)/1e9}')"

    meta_wrap="$d/meta.json"; mex="$d/meta.extras"
    run_tag=""; worker_id=""; conc=""; mem=""; topk_en=""; topk_kb=""
    [[ -r "$meta_wrap" ]] && {
      run_tag="$(jget "$meta_wrap" run_tag || true)"
      worker_id="$(jget "$meta_wrap" worker_id || true)"
      conc="$(jget "$meta_wrap" e2_conc || true)"
      mem="$(jget "$meta_wrap" e2_mem_profile || true)"
      topk_en="$(jget "$meta_wrap" topk_enabled || true)"
      topk_kb="$(jget "$meta_wrap" topk_limit_kb || true)"
    }
    [[ ( -z "$conc" || -z "$mem" || -z "$run_tag" || -z "$worker_id" ) && -r "$mex" ]] && {
      [[ -z "$conc"      ]] && conc="$(eget "$mex" E2_CONC || true)"
      [[ -z "$mem"       ]] && mem="$(eget "$mex" E2_MEM_PROFILE || true)"
      [[ -z "$run_tag"   ]] && run_tag="$(eget "$mex" RUN_TAG || true)"
      [[ -z "$worker_id" ]] && worker_id="$(eget "$mex" WORKER_ID || true)"
      # ROLE / CG_MEM_MAX_BYTES 目前只在 meta.extras 中，留給 Python summarizer 使用；fallback 不輸出
    }

    printf '%s\n' \
"${ts},${method_wrap},${bt},${elapsed_s},,,,,,,,,,,,${topk_en},${topk_kb},${run_tag},${worker_id},${conc},${mem},,,,,,,,${base},,,,"
  done >> "$summary_csv"

  rows=$(( $(wc -l < "$summary_csv" 2>/dev/null || echo 0) - 1 ))
  echo "[summary][fallback] rows=$rows -> $summary_csv"
else
  echo "[summary] wrote $summary_csv (rows=$rows)"
fi
