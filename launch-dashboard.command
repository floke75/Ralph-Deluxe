#!/usr/bin/env bash
# Launch Ralph Deluxe dashboard — double-click to open (macOS)

# cd to the script's own directory so relative paths work
cd "$(dirname "$0")" || exit 1

PORT=8080
URL="http://127.0.0.1:${PORT}/.ralph/dashboard.html"

# Kill any existing server on this port
lsof -ti:"$PORT" -c python 2>/dev/null | xargs kill 2>/dev/null || true
sleep 0.3

# Start serve.py in background
python3 .ralph/serve.py --port "$PORT" &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null" INT TERM EXIT

# Wait for server to be ready
for i in $(seq 1 20); do
  (echo >/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break
  sleep 0.25
done

echo "✦ Ralph Deluxe Dashboard"
echo "  $URL"
echo ""
echo "  Close this window or press Ctrl-C to stop the server."
echo ""

open "$URL"

wait $SERVER_PID 2>/dev/null
