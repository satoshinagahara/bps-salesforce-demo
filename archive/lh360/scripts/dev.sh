#!/usr/bin/env bash
# lh360 開発サーバー起動スクリプト
# 使い方: ./scripts/dev.sh
#
# FastAPI (port 8000) と Vite dev server (port 5173) を並行起動する。
# Ctrl-C で両方停止。

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

echo "=== Local Headless 360 — Dev Server ==="
echo "API  : http://localhost:8000"
echo "UI   : http://localhost:5173"
echo ""

# バックグラウンドで FastAPI を起動
(cd "$ROOT" && uv run uvicorn app.api.main:app --reload --port 8000 --log-level info) &
API_PID=$!

# バックグラウンドで Vite dev server を起動
(cd "$ROOT/app/web" && npm run dev) &
VITE_PID=$!

# Ctrl-C で両方停止
trap "kill $API_PID $VITE_PID 2>/dev/null; echo ''; echo 'Stopped.'" INT TERM
wait
