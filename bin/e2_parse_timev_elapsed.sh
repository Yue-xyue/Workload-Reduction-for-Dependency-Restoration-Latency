#!/usr/bin/env bash
# 用法：e2_parse_timev_elapsed.sh /path/to/timev.log
# 解析 /usr/bin/time -v 的 "Elapsed (wall clock) time" 為毫秒
set -euo pipefail
log="${1:?timev.log required}"

# 強制英文，避免本地化把標籤翻譯掉
LC_ALL=C LANG=C awk '
  /^[[:space:]]*Elapsed \(wall clock\) time/ {
    line = $0
    sub(/.*: /, "", line)          # 砍掉最後一個「: 」之前的所有東西
    gsub(/\r/, "", line)           # 去 CR
    n = split(line, a, ":")
    total = 0.0
    if (n == 3)       total = a[1]*3600 + a[2]*60 + a[3]   # h:mm:ss(.xx)
    else if (n == 2)  total = a[1]*60   + a[2]             # m:ss(.xx)
    else              total = a[1]                          # s(.xx)
    printf("%.0f\n", total * 1000)
    found = 1
  }
  END { if (!found) exit 2 }
' "$log"
