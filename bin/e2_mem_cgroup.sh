#!/usr/bin/env bash
set -euo pipefail

# mem profile -> memory.max (bytes)
mem_profile_to_bytes() {
  local mem="$1"
  case "$mem" in
    ample)
      # 0 = unlimited (memory.max=max)
      echo 0
      ;;
    edge)
      echo $((512*1024*1024))
      ;;
    edge_1G)
      echo $((1024*1024*1024))
      ;;
    edge_512M)
      echo $((512*1024*1024))
      ;;
    edge_256M)
      echo $((256*1024*1024))
      ;;
    edge_128M)
      echo $((128*1024*1024))
      ;;
    edge_64M)
      echo $((64*1024*1024))
      ;;
    edge_32M)
      echo $((32*1024*1024))
      ;;
    *)
      # 不認得就當 unlimited，但仍建立 cgroup
      echo 0
      ;;
  esac
}

# 建立單一 worker 專屬 cgroup，並設定 memory.max / memory.high / swap.max
# stdout: "<cg_path> <limit_bytes>"
setup_mem_cgroup_for_worker() {
  local proj="$1" mem="$2" conc="$3" worker_id="$4" role="$5"

  local limit_bytes
  limit_bytes="$(mem_profile_to_bytes "$mem")"

  # 你可以視需要把 role 加進名字（方便 trace）
  # 例如 e5_${proj}_${role}_${mem}_c${conc}_w${worker_id}
  local cg="/sys/fs/cgroup/e5_${proj}_${role}_${mem}_c${conc}_w${worker_id}"

  sudo mkdir -p "$cg"

  if [[ "$limit_bytes" -eq 0 ]]; then
    echo "max" | sudo tee "$cg/memory.max"      >/dev/null 2>&1 || true
    echo 0      | sudo tee "$cg/memory.swap.max" >/dev/null 2>&1 || true
    echo "max" | sudo tee "$cg/memory.high"     >/dev/null 2>&1 || true
    echo "[mem] setup cgroup proj=$proj role=$role mem=$mem conc=$conc w=$worker_id cg=$cg limit_bytes=unlimited(max)" >&2
  else
    echo "$limit_bytes" | sudo tee "$cg/memory.max"      >/dev/null
    echo 0              | sudo tee "$cg/memory.swap.max" >/dev/null 2>&1 || true
    echo "$limit_bytes" | sudo tee "$cg/memory.high"     >/dev/null 2>&1 || true
    echo "[mem] setup cgroup proj=$proj role=$role mem=$mem conc=$conc w=$worker_id cg=$cg limit_bytes=$limit_bytes" >&2
  fi

  printf '%s %s\n' "$cg" "$limit_bytes"
}

