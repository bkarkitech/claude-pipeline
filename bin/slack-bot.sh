#!/usr/bin/env bash
# ~/.claude-pipeline/bin/slack-bot.sh
# Slack integration bot for Claude Pipeline.
# Receives commands via Slack and sends task notifications.
#
# Modes:
#   - Webhook-only: Just sends notifications (no incoming commands)
#   - Bot mode: Polls Slack conversations for commands (requires bot_token + channel_id)
#
# Commands recognized (in bot mode):
#   /pipeline add <description>
#   /pipeline status
#   /pipeline list [queue|active|done|failed]
#   /pipeline approve <task>
#   /pipeline reject <task>
#
# Usage: slack-bot.sh [start|stop|status]

set -euo pipefail

PIPELINE_DIR="$HOME/.claude-pipeline"
CONFIG_FILE="$PIPELINE_DIR/config.yml"
LOG_FILE="$PIPELINE_DIR/logs/slack-bot.log"
PID_FILE="$PIPELINE_DIR/locks/slack-bot.pid"
PIPELINE_BIN="$PIPELINE_DIR/bin/pipeline"

# ─── Config ───────────────────────────────────────────────────────────────────

slack_config_get() {
    local key="$1"
    local default="${2:-}"
    awk '/^\s+slack:/,/^\s+[a-z]+:/{print}' "$CONFIG_FILE" 2>/dev/null \
        | grep "${key}:" | head -1 | sed "s/.*${key}:\s*//" | tr -d '"' | xargs
    echo "${default}"
}

BOT_TOKEN=$(awk '/^\s+slack:/,/^\s+[a-z]+:/{print}' "$CONFIG_FILE" 2>/dev/null | grep "bot_token:" | head -1 | sed 's/.*bot_token:\s*//' | tr -d '"' | xargs)
CHANNEL_ID=$(awk '/^\s+slack:/,/^\s+[a-z]+:/{print}' "$CONFIG_FILE" 2>/dev/null | grep "channel_id:" | head -1 | sed 's/.*channel_id:\s*//' | tr -d '"' | xargs)

# ─── Logging ──────────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SLACK] $*" >> "$LOG_FILE"
}

# ─── Slack API Helpers ────────────────────────────────────────────────────────

slack_post() {
    local channel="$1"
    local text="$2"
    curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer $BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg channel "$channel" --arg text "$text" '{channel: $channel, text: $text}')" \
        2>/dev/null || true
}

slack_get_messages() {
    local channel="$1"
    local oldest="$2"
    curl -s "https://slack.com/api/conversations.history?channel=${channel}&oldest=${oldest}&limit=10" \
        -H "Authorization: Bearer $BOT_TOKEN" \
        2>/dev/null
}

# ─── Command Processing ──────────────────────────────────────────────────────

process_command() {
    local text="$1"
    local user="$2"

    # Strip bot mention if present
    text=$(echo "$text" | sed 's/<@[A-Z0-9]*>\s*//' | xargs)

    case "$text" in
        "status"|"/pipeline status")
            local output
            output=$("$PIPELINE_BIN" status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -20)
            slack_post "$CHANNEL_ID" "📊 Pipeline Status:\n\`\`\`$output\`\`\`"
            ;;
        "list"*|"/pipeline list"*)
            local filter
            filter=$(echo "$text" | sed 's/.*list\s*//' | xargs)
            filter="${filter:-queue}"
            local output
            output=$("$PIPELINE_BIN" list "$filter" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -30)
            slack_post "$CHANNEL_ID" "📋 Tasks ($filter):\n\`\`\`$output\`\`\`"
            ;;
        "add "*|"/pipeline add "*)
            local desc
            desc=$(echo "$text" | sed 's/^add\s*//' | sed 's/^\/pipeline add\s*//')
            if [[ -n "$desc" ]]; then
                "$PIPELINE_BIN" add "$desc" --dumb 2>/dev/null
                slack_post "$CHANNEL_ID" "✅ Task queued: $desc"
                log "Task created from Slack ($user): $desc"
            fi
            ;;
        "approve "*|"/pipeline approve "*)
            local task
            task=$(echo "$text" | sed 's/.*approve\s*//' | xargs)
            "$PIPELINE_BIN" approve "$task" 2>/dev/null
            slack_post "$CHANNEL_ID" "✅ Approved: $task"
            log "Approval from Slack ($user): $task"
            ;;
        "reject "*|"/pipeline reject "*)
            local task
            task=$(echo "$text" | sed 's/.*reject\s*//' | xargs)
            "$PIPELINE_BIN" reject "$task" 2>/dev/null
            slack_post "$CHANNEL_ID" "❌ Rejected: $task"
            log "Rejection from Slack ($user): $task"
            ;;
        "help"|"/pipeline help")
            slack_post "$CHANNEL_ID" "🤖 Claude Pipeline Commands:\n• \`add <description>\` — Create a task\n• \`status\` — Show pipeline status\n• \`list [queue|active|done|failed]\` — List tasks\n• \`approve <task>\` — Approve a pending task\n• \`reject <task>\` — Reject a pending task"
            ;;
        *)
            # Ignore non-command messages
            ;;
    esac
}

# ─── Bot Main Loop ───────────────────────────────────────────────────────────

run_bot() {
    if [[ -z "$BOT_TOKEN" || -z "$CHANNEL_ID" ]]; then
        echo "Error: Slack bot_token and channel_id required in config.yml"
        echo "Configure under notifications.slack section"
        exit 1
    fi

    echo $$ > "$PID_FILE"
    log "Slack bot starting (PID $$)"

    # Get bot's own ID to filter out our messages
    local bot_id
    bot_id=$(curl -s "https://slack.com/api/auth.test" -H "Authorization: Bearer $BOT_TOKEN" 2>/dev/null | jq -r '.user_id // empty')

    local last_ts
    last_ts=$(date +%s)

    trap 'log "Slack bot stopping"; rm -f "$PID_FILE"; exit 0' EXIT SIGTERM SIGINT

    while true; do
        sleep 5

        # Poll for new messages
        local response
        response=$(slack_get_messages "$CHANNEL_ID" "$last_ts")

        if [[ -z "$response" ]]; then
            continue
        fi

        # Process messages (newest first, so reverse)
        local messages
        messages=$(echo "$response" | jq -c '.messages[]? | select(.type=="message" and .subtype==null)' 2>/dev/null)

        while IFS= read -r msg; do
            [[ -z "$msg" ]] && continue

            local msg_user msg_text msg_ts
            msg_user=$(echo "$msg" | jq -r '.user // empty')
            msg_text=$(echo "$msg" | jq -r '.text // empty')
            msg_ts=$(echo "$msg" | jq -r '.ts // empty')

            # Skip our own messages
            [[ "$msg_user" == "$bot_id" ]] && continue

            # Update timestamp
            if [[ -n "$msg_ts" ]]; then
                last_ts="$msg_ts"
            fi

            # Process command
            if [[ -n "$msg_text" ]]; then
                process_command "$msg_text" "$msg_user"
            fi
        done <<< "$messages"
    done
}

# ─── Management ───────────────────────────────────────────────────────────────

case "${1:-start}" in
    start)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "Slack bot already running (PID $(cat "$PID_FILE"))"
            exit 0
        fi
        echo "Starting Slack bot..."
        run_bot &
        echo "Slack bot started (PID $!)"
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
            echo "Slack bot stopped"
        else
            echo "Slack bot not running"
        fi
        ;;
    status)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "Slack bot running (PID $(cat "$PID_FILE"))"
        else
            echo "Slack bot not running"
        fi
        ;;
    *)
        echo "Usage: slack-bot.sh [start|stop|status]"
        exit 1
        ;;
esac
