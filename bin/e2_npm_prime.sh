#!/usr/bin/env bash
# 用法：bin/e2_npm_prime.sh <project_dir> [registry]
# 例：  bin/e2_npm_prime.sh ~/experiment/e_ex/projects/express-app.neighbor
#
# 目的：這支腳本是「npm 專用的 cache prime 工具」，用 package-lock.json 裡的
#       resolved URL 把所有 tarball 先丟進一個獨立 npm-cache，再跑一次離線 npm ci。
#
#       ⚠ 對於使用 yarn / yarn.lock / .yarn/cache 的專案（例如 ghost monorepo），
#         這支腳本不會嘗試幫你「轉成 npm」，而是直接告知「不支援」：
#         - 避免把原本建議用 yarn 的專案硬套到 npm 上，產生 methodology 爭議
#         - ghost 的 E2/E6 實驗會透過 E2_INSTALL_CMD 直接用 yarn install，
#           cache 行為交給 yarn / .yarn/cache 自己管理，而不是用這一支。
#
# 若未來真的需要「yarn prime」，建議另外寫一支 e2_yarn_prime.sh，
# 明確記錄 Yarn 版本與指令，例如：
#   E2_INSTALL_CMD='yarn install --immutable' ...
#   （但那會是另一條清楚分開的實驗路徑）

set -euo pipefail

PROJ="${1:-$PWD}"
REG="${2:-https://registry.npmjs.org}"

cd "$PROJ"

# --- 檢查 lockfile 類型 ------------------------------------------------------
if [[ ! -f package-lock.json ]]; then
  if [[ -f yarn.lock ]]; then
    echo "FATAL: e2_npm_prime.sh 是 npm 專用，偵測到 yarn.lock 但沒有 package-lock.json" >&2
    echo "       這通常表示此專案建議使用 yarn（例如 ghost monorepo）。" >&2
    echo "       為避免 methodology 爭議，本腳本不會嘗試用 npm 重新安裝。" >&2
    echo >&2
    echo "       建議做法：" >&2
    echo "         1) 在 E2/E6 實驗中，改用 E2_INSTALL_CMD='yarn install --immutable' 直接跑 yarn；" >&2
    echo "         2) 若真的需要 yarn 的 prime 流程，請另外撰寫 e2_yarn_prime.sh，" >&2
    echo "            並在論文中明寫使用 yarn 及對應版本與參數。" >&2
    exit 1
  fi
  echo "need package-lock.json (npm 專案才可使用本腳本)" >&2
  exit 1
fi

TS="$(date +%s)"
export NODE_OPTIONS=--dns-result-order=ipv4first
export NPM_CONFIG_CACHE="$HOME/experiment/e_ex/npm-cache"
export npm_config_registry="$REG"
export npm_config_fetch_retries=5
export npm_config_fetch_retry_mintimeout=20000
export npm_config_fetch_retry_maxtimeout=300000
export npm_config_audit=false
export npm_config_fund=false
export npm_config_prefer_offline=false
# npm v10 沒有 network-concurrency；用 maxsockets 降並發
export npm_config_maxsockets=1

echo "[prime] project=$PROJ"
echo "[prime] registry=$REG"
echo "[prime] cache=$NPM_CONFIG_CACHE"

echo "[1/3] prefetch tarballs into cache"
# 從 package-lock.json 抓所有 resolved URL
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found" >&2
  exit 2
fi

mapfile -t URLS < <(jq -r '..|.resolved? // empty' package-lock.json | sort -u)
for url in "${URLS[@]}"; do
  echo "  + $url"
  npm cache add "$url" --registry="$REG" >/dev/null
done

echo "[2/3] reset node_modules"
rm -rf node_modules
mkdir -p node_modules && chmod -R u+rwX node_modules

echo "[3/3] npm ci (offline)"
npm ci --offline --no-audit --fund=false --progress=false --timing --loglevel=notice

echo "done. cache=$NPM_CONFIG_CACHE"
