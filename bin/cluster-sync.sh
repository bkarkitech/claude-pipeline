#!/usr/bin/env bash
# ~/.claude-pipeline/bin/cluster-sync.sh
# Multi-machine coordination daemon.
# Polls peer nodes for tasks tagged for this machine and pulls them.
# Also pushes tasks tagged for other machines to the appropriate peers.
#
# Usage: cluster-sync.sh [start|stop|status]
#
# Requires cluster configuration in config.yml:
#   cluster:
#     enabled: true
#     node_id: "my-machine"
#     tags: ["macos", "gpu"]
#     peers:
#       - name: "other-machine"
#         url: "http://192.168.1.100:7778"
#         tags: ["linux", "docker"]
#     sync_interval: 30

set -euo pipefail

PIPELINE_DIR="$HOME/.claude-pipeline"
CONFIG_FILE="$PIPELINE_DIR/config.yml"
QUEUE_DIR="$PIPELINE_DIR/queue"
LOG_FILE="$PIPELINE_DIR/logs/cluster-sync.log"
PID_FILE="$PIPELINE_DIR/locks/cluster-sync.pid"

# ─── Helpers ──────────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CLUSTER] $*" >> "$LOG_FILE"
}

config_get() {
    local key="$1"
    local default="${2:-}"
    local value
    value=$(grep -E "^\s*${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | xargs)
    echo "${value:-$default}"
}

# ─── Configuration ────────────────────────────────────────────────────────────

NODE_ID=$(config_get "node_id" "$(hostname)")
SYNC_INTERVAL=$(config_get "sync_interval" "30")

# Parse peer list from config
get_peers() {
    # Extract peer names and URLs from config
    awk '/^\s+peers:/,/^[^ ]/' "$CONFIG_FILE" 2>/dev/null | grep -E "^\s+- name:|url:" | paste - - | while read -r line; do
        local name url
        name=$(echo "$line" | grep -oP 'name:\s*"\K[^"]+' || echo "$line" | grep -oP "name:\s*\K\S+")
        url=$(echo "$line" | grep -oP 'url:\s*"\K[^"]+' || echo "$line" | grep -oP "url:\s*\K\S+")
        if [[ -n "$name" && -n "$url" ]]; then
            echo "$name|$url"
        fi
    done
}

# macOS-compatible peer parsing (no -P flag for grep)
get_peers_macos() {
    local in_peers=false
    local current_name="" current_url=""

    while IFS= read -r line; do
        if echo "$line" | grep -q "peers:"; then
            in_peers=true
            continue
        fi
        if [[ "$in_peers" == "true" ]]; then
            # End of peers section (non-indented line)
            if [[ -n "$line" && ! "$line" =~ ^[[:space:]] && ! "$line" =~ ^$ ]]; then
                break
            fi
            if echo "$line" | grep -q "name:"; then
                current_name=$(echo "$line" | sed 's/.*name:\s*//' | tr -d '"' | xargs)
            fi
            if echo "$line" | grep -q "url:"; then
                current_url=$(echo "$line" | sed 's/.*url:\s*//' | tr -d '"' | xargs)
            fi
            if [[ -n "$current_name" && -n "$current_url" ]]; then
                echo "$current_name|$current_url"
                current_name=""
                current_url=""
            fi
        fi
    done < "$CONFIG_FILE"
}

# ─── Pull Tasks from Peers ───────────────────────────────────────────────────

pull_from_peers() {
    while IFS='|' read -r peer_name peer_url; do
        [[ -z "$peer_name" || -z "$peer_url" ]] && continue

        # Query peer for tasks available for us
        local response
        response=$(curl -s --connect-timeout 5 --max-time 10 "$peer_url/api/cluster/tasks" 2>/dev/null) || continue

        # Check if response is valid JSON array
        if ! echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
            continue
        fi

        # Filter tasks tagged for us (our node_id or our tags)
        local my_tags
        my_tags=$(grep "tags:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*tags:\s*//' | tr -d '[]"' | xargs)

        echo "$response" | jq -c '.[]' 2>/dev/null | while IFS= read -r task; do
            local task_name task_machine task_priority
            task_name=$(echo "$task" | jq -r '.name')
            task_machine=$(echo "$task" | jq -r '.machine')

            # Check if this task is for us
            local should_pull=false
            if [[ "$task_machine" == "$NODE_ID" ]]; then
                should_pull=true
            elif [[ -n "$my_tags" && "$my_tags" == *"$task_machine"* ]]; then
                should_pull=true
            fi

            if [[ "$should_pull" == "true" ]]; then
                # Fetch the full task from the peer
                local task_content
                task_content=$(curl -s --connect-timeout 5 --max-time 10 "$peer_url/api/tasks/$task_name/view" 2>/dev/null)
                local content
                content=$(echo "$task_content" | jq -r '.content // empty' 2>/dev/null)

                if [[ -n "$content" ]]; then
                    local filename="${task_name}.md"
                    if [[ ! -f "$QUEUE_DIR/$filename" ]]; then
                        echo "$content" > "$QUEUE_DIR/$filename"
                        log "Pulled task '$task_name' from peer '$peer_name' (machine: $task_machine)"

                        # Tell peer to delete/mark as transferred
                        curl -s -X POST "$peer_url/api/tasks/$task_name/move" \
                            -H "Content-Type: application/json" \
                            -d "{\"to\": \"done\"}" \
                            --connect-timeout 5 --max-time 10 2>/dev/null || true
                    fi
                fi
            fi
        done

    done < <(get_peers_macos)
}

# ─── Push Tasks to Peers ─────────────────────────────────────────────────────

push_to_peers() {
    # Look for tasks in our queue tagged for other machines
    for f in "$QUEUE_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        local machine_tag
        machine_tag=$(sed -n '/^---$/,/^---$/p' "$f" | grep "^machine:" | head -1 | sed 's/machine:\s*//' | xargs)

        # Skip if no machine tag or tagged for us
        [[ -z "$machine_tag" || "$machine_tag" == "any" || "$machine_tag" == "$NODE_ID" ]] && continue

        # Check our tags — if it matches our tag, don't push
        local my_tags
        my_tags=$(grep "tags:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*tags:\s*//' | tr -d '[]"' | xargs)
        if [[ -n "$my_tags" && "$my_tags" == *"$machine_tag"* ]]; then
            continue
        fi

        # Find a peer that matches this machine tag
        while IFS='|' read -r peer_name peer_url; do
            [[ -z "$peer_name" || -z "$peer_url" ]] && continue

            # Check if this peer matches the machine tag (by name or by checking their status)
            if [[ "$peer_name" == "$machine_tag" ]]; then
                # Push task to this peer
                local content filename
                content=$(cat "$f")
                filename=$(basename "$f")

                local result
                result=$(curl -s -X POST "$peer_url/api/cluster/push" \
                    -H "Content-Type: application/json" \
                    -d "$(jq -n --arg fn "$filename" --arg c "$content" --arg src "$NODE_ID" \
                        '{filename: $fn, content: $c, source_node: $src}')" \
                    --connect-timeout 5 --max-time 10 2>/dev/null)

                if echo "$result" | jq -e '.success' >/dev/null 2>&1; then
                    log "Pushed task '$(basename "$f" .md)' to peer '$peer_name'"
                    # Remove from our queue
                    rm -f "$f"
                fi
                break
            fi
        done < <(get_peers_macos)
    done
}

# ─── Main Loop ────────────────────────────────────────────────────────────────

run_sync() {
    echo $$ > "$PID_FILE"
    log "Cluster sync starting (node: $NODE_ID, interval: ${SYNC_INTERVAL}s)"

    trap 'log "Cluster sync stopping"; rm -f "$PID_FILE"; exit 0' EXIT SIGTERM SIGINT

    while true; do
        # Pull tasks from peers that are tagged for us
        pull_from_peers 2>/dev/null || true

        # Push tasks to peers that are tagged for other machines
        push_to_peers 2>/dev/null || true

        sleep "$SYNC_INTERVAL"
    done
}

# ─── Management ───────────────────────────────────────────────────────────────

case "${1:-start}" in
    start)
        # Check if cluster is enabled
        cluster_enabled=$(config_get "enabled" "false")
        if [[ "$cluster_enabled" != "true" ]]; then
            echo "Cluster not enabled. Set cluster.enabled: true in config.yml"
            exit 1
        fi

        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "Cluster sync already running (PID $(cat "$PID_FILE"))"
            exit 0
        fi
        echo "Starting cluster sync (node: $NODE_ID)..."
        run_sync &
        echo "Cluster sync started (PID $!)"
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
            echo "Cluster sync stopped"
        else
            echo "Cluster sync not running"
        fi
        ;;
    status)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "Cluster sync running (PID $(cat "$PID_FILE"), node: $NODE_ID)"
        else
            echo "Cluster sync not running"
        fi
        ;;
    *)
        echo "Usage: cluster-sync.sh [start|stop|status]"
        exit 1
        ;;
esac
