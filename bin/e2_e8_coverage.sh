#!/usr/bin/env bash
set -euo pipefail

# E8 coverage helper
# 預設：
#   ROOT = ~/experiment/e_ex
#   PROJ = ghost
#   LOG_DIR = $ROOT/frontier_poc/$PROJ/logs
#   PKG_DIR = $ROOT/frontier_poc/$PROJ/pkgs
#
# 用法：
#   PROJ=ghost bin/e2_e8_coverage.sh
#     -> 自動挑最新的 *_b2_frontier_only run 當目標
#
#   PROJ=ghost bin/e2_e8_coverage.sh 1763367398619723283_w0_b2_frontier_only
#   PROJ=ghost bin/e2_e8_coverage.sh /full/path/to/run_dir
#     -> 指定某個 run 目錄

root="${E2_ROOT:-$HOME/experiment/e_ex}"
proj="${PROJ:-ghost}"
projdir_base="$root/projects/$proj"
projdir="${PROJECT_DIR:-$projdir_base}"
logd="${LOG_DIR:-$root/frontier_poc/$proj/logs}"
pkgd="${PKG_DIR:-$root/frontier_poc/$proj/pkgs}"

run_arg="${1:-}"

# ---- 決定 run_dir -----------------------------------------------------------
run_dir=""
if [[ -n "$run_arg" ]]; then
  if [[ -d "$run_arg" ]]; then
    run_dir="$run_arg"
  else
    run_dir="$logd/$run_arg"
  fi
else
  # 沒給參數：挑最新一個 *_b2_frontier_only 目錄
  run_dir="$(ls -td "$logd"/*_b2_frontier_only 2>/dev/null | head -1 || true)"
fi

if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
  echo "[fatal] run_dir not found. 目前 logd=$logd" >&2
  exit 1
fi

frontier_tar="$pkgd/nm.frontier.tar"
if [[ ! -f "$frontier_tar" ]]; then
  echo "[fatal] frontier tar not found: $frontier_tar" >&2
  exit 2
fi

smoke_log="$run_dir/strace_smoke.log"
extra_log="$run_dir/strace_extra.log"

if [[ ! -f "$smoke_log" ]]; then
  echo "[fatal] $smoke_log not found. 確認 E2_E8_COVERAGE=1 有開啟。" >&2
  exit 3
fi

echo "[info] ROOT=$root"
echo "[info] PROJ=$proj"
echo "[info] PROJDIR=$projdir"
echo "[info] LOG_DIR=$logd"
echo "[info] RUN_DIR=$run_dir"
echo "[info] FRONTIER_TAR=$frontier_tar"
echo

# ---- 產生 U_frontier / U_smoke / U_extra ------------------------------------
U_frontier="$run_dir/e8_U_frontier.txt"
U_smoke="$run_dir/e8_U_smoke.txt"
U_extra="$run_dir/e8_U_extra.txt"

echo "[step] 建 U_frontier（來自 nm.frontier.tar）"
tar -tf "$frontier_tar" | sort -u > "$U_frontier"

pwd_abs="$projdir/"

extract_from_strace() {
  local slog="$1"
  local out="$2"

  if [[ ! -f "$slog" ]]; then
    echo "[warn] $slog not found, skip" >&2
    : > "$out"
    return 0
  fi

  # 1) 從 strace 抽出路徑，補成絕對路徑，只保留 node_modules 相關且非 .cache
  grep -oE '"([^"]+)"' "$slog" \
    | sed -E 's/^"//; s/"$//' \
    | awk -v P="$pwd_abs" '
        {
          p=$0
          if (substr(p,1,1)!="/") p=P p    # 相對路徑 → 絕對路徑
          if (index(p,"/node_modules/") && index(p,"/.cache/")==0) {
            print p
          }
        }
      ' \
    | while IFS= read -r abs; do
        if command -v realpath >/dev/null 2>&1; then
          rp="$(realpath -m -- "$abs" 2>/dev/null || true)"
        else
          rp="$(readlink -f -- "$abs" 2>/dev/null || true)"
        fi
        [[ -z "$rp" ]] && continue
        case "$rp" in
          "$pwd_abs"node_modules/*)
            rel="${rp#"$pwd_abs"}"
            printf '%s\n' "$rel"
            ;;
        esac
      done \
    | sort -u > "$out"
}

echo "[step] 建 U_smoke（strace_smoke.log）"
extract_from_strace "$smoke_log" "$U_smoke"

if [[ -f "$extra_log" ]]; then
  echo "[step] 建 U_extra（strace_extra.log）"
  extract_from_strace "$extra_log" "$U_extra"
else
  echo "[info] $extra_log 不存在，略過 U_extra"
  : > "$U_extra"
fi

# ---- coverage 計算 ----------------------------------------------------------
coverage() {
  local A="$1"   # 檔案：集合 A
  local B="$2"   # 檔案：集合 B
  local label="$3"

  local a b inter
  a=$(wc -l < "$A")
  b=$(wc -l < "$B")
  if [[ "$a" -eq 0 || "$b" -eq 0 ]]; then
    echo "$label: |A|=$a |B|=$b |A∩B|=0  cov(A->B)=0.00%  cov(B->A)=0.00%"
    return
  fi

  inter=$(comm -12 <(sort -u "$A") <(sort -u "$B") | wc -l)
  awk -v l="$label" -v a="$a" -v b="$b" -v i="$inter" 'BEGIN{
    pa = (a>0?100*i/a:0);
    pb = (b>0?100*i/b:0);
    printf "%s: |A|=%d |B|=%d |A∩B|=%d  cov(A->B)=%.2f%%  cov(B->A)=%.2f%%\n", l,a,b,i,pa,pb;
  }'
}

echo
echo "== E8 coverage summary =="
echo "(A->B 表示：A 中被 B 覆蓋的比例)"
echo

coverage "$U_smoke" "$U_frontier" "smoke vs frontier   (A=U_smoke   B=U_frontier)"
if [[ -s "$U_extra" ]]; then
  coverage "$U_extra" "$U_frontier" "extra vs frontier   (A=U_extra   B=U_frontier)"
fi
coverage "$U_frontier" "$U_smoke" "frontier vs smoke   (A=U_frontier B=U_smoke)"
if [[ -s "$U_extra" ]]; then
  coverage "$U_frontier" "$U_extra" "frontier vs extra   (A=U_frontier B=U_extra)"
fi

echo
echo "檔案已寫入："
echo "  U_frontier: $U_frontier"
echo "  U_smoke   : $U_smoke"
if [[ -s "$U_extra" ]]; then
  echo "  U_extra   : $U_extra"
else
  echo "  U_extra   : (empty / not collected)"
fi

