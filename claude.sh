#!/bin/bash

echo "啟動 pxpipe-proxy..."
# 將 proxy 放到背景執行，並把輸出丟掉保持畫面乾淨
npx pxpipe-proxy > /dev/null 2>&1 &
PROXY_PID=$!

# 設定 Trap：當腳本結束或被中斷時，自動殺掉 Proxy 進程
trap "kill $PROXY_PID 2>/dev/null" EXIT INT TERM

# 等 1 秒確保 proxy 順利啟動
sleep 1

echo "啟動 Claude..."
# 執行 Claude
ANTHROPIC_BASE_URL="http://127.0.0.1:47821" claude
