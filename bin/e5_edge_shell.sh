#!/usr/bin/env bash
set -euo pipefail

# 你要的 edge 記憶體上限（GB）
MEM_GB="${1:-4}"                     # 預設 4GB，可以 ./e5_edge_shell.sh 8 改成 8GB
MEM_BYTES=$((MEM_GB * 1024 * 1024 * 1024))

CG=/sys/fs/cgroup/e5_edge

echo "[e5] setup cgroup: $CG (MemoryMax=${MEM_GB}G)"

# 1) 建 cgroup
sudo mkdir -p "$CG"

# 2) 設記憶體上限 & swap（這裡把 swap 關掉，比較乾淨）
echo $MEM_BYTES | sudo tee "$CG/memory.max"        >/dev/null
echo 0          | sudo tee "$CG/memory.swap.max"   >/dev/null || true

# 3) 可選：設一個 soft limit（有些 kernel 用 MemoryHigh）
echo $MEM_BYTES | sudo tee "$CG/memory.high"       >/dev/null || true

# 4) 把現在這個 shell 丟進 cgroup
echo $$ | sudo tee "$CG/cgroup.procs" >/dev/null

# 5) 匯出給 E2/E5 driver 記錄用（寫進 summary.csv）
export CG_MEM_MAX_BYTES="$MEM_BYTES"
export E2_MEM_PROFILE="edge"

echo "[e5] now in cgroup: $CG"
echo "[e5] CG_MEM_MAX_BYTES=$CG_MEM_MAX_BYTES"

# 6) 開一個「受限記憶體」的互動 shell 或直接執行你要的指令
if [[ $# -gt 1 ]]; then
  # 若有多餘參數，當成 command 跑：
  shift
  exec "$@"
else
  # 否則給你一個 shell，之後在裡面跑 E5 driver
  exec bash --login
fi

