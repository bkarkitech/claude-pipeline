#!/usr/bin/env bash
# ~/.claude-pipeline/bin/serve-dashboard.sh
# Starts the unified API + dashboard server on port 7778

set -uo pipefail

PIPELINE_DIR="$HOME/.claude-pipeline"
LOCKS_DIR="$PIPELINE_DIR/locks"
LOGS_DIR="$PIPELINE_DIR/logs"
PORT="${1:-7778}"
PID_FILE="$LOCKS_DIR/dashboard.pid"
API_SERVER="$PIPELINE_DIR/bin/api-server.py"

# Check if already running
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Dashboard already running at http://localhost:$PORT (PID $(cat "$PID_FILE"))"
    exit 0
fi

# Start the unified API server
python3 "$API_SERVER" --port "$PORT" >> "$LOGS_DIR/dashboard.log" 2>&1 &
local_pid=$!

# Verify it started
sleep 1
if kill -0 "$local_pid" 2>/dev/null; then
    echo "Dashboard running at http://localhost:$PORT (PID $local_pid)"
else
    echo "Failed to start dashboard server" >&2
    rm -f "$PID_FILE"
    exit 1
fi
