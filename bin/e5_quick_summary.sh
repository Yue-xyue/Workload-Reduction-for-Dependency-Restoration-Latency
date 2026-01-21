#!/usr/bin/env bash
set -euo pipefail

CSV="${1:-frontier_poc/express-app/logs/summary.csv}"

p50() {
  awk '{a[NR]=$1} END{
    if(NR==0){print "NA"; exit}
    if(NR%2){print a[(NR+1)/2]}
    else {printf "%.0f\n",(a[NR/2]+a[NR/2+1])/2}
  }'
}

p95() {
  awk '{a[NR]=$1} END{
    if(NR==0){print "NA"; exit}
    pos = int(0.95*(NR+1))
    if(pos<1) pos=1
    if(pos>NR) pos=NR
    print a[pos]
  }'
}

echo "=== E5 baseline_full @ edge + 4G (cg_memory_max_bytes=4294967296) ==="
echo "CSV = $CSV"
echo

for TAG in E5_express_edge_N0 E5_express_edge_N3; do
  for ROLE in target neighbor; do
    # 把該 group 的 boottime_ms 全部收集到一個變數裡
    vals="$(
      awk -F, -v tag="$TAG" -v role="$ROLE" '
        NR>1 &&
        $2=="baseline_full" &&
        $19==tag &&
        $22=="edge" &&
        $24=="4294967296" &&
        $37==role {
          print $3
        }
      ' "$CSV" | sort -n
    )"

    count=$(printf "%s\n" "$vals" | sed '/^$/d' | wc -l)
    if [[ "$count" -eq 0 ]]; then
      printf "%-24s %-8s : count=0 (no rows)\n" "$TAG" "$ROLE"
      continue
    fi

    p50_val=$(printf "%s\n" "$vals" | sed '/^$/d' | p50)
    p95_val=$(printf "%s\n" "$vals" | sed '/^$/d' | p95)

    printf "%-24s %-8s : count=%-3s P50=%-6s P95=%-6s\n" \
      "$TAG" "$ROLE" "$count" "$p50_val" "$p95_val"
  done
done

