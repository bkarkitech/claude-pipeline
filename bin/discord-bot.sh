#!/usr/bin/env bash
# ~/.claude-pipeline/bin/discord-bot.sh
# Discord integration bot for Claude Pipeline.
# Receives commands via Discord and sends task notifications.
#
# Modes:
#   - Webhook-only: Just sends notifications (no incoming commands)
#   - Bot mode: Polls Discord channel for commands (requires bot_token + channel_id)
#
# Commands recognized (in bot mode):
#   !pipeline add <description>
#   !pipeline status
#   !pipeline list [queue|active|done|failed]
#   !pipeline approve <task>
#   !pipeline reject <task>
#
# Usage: discord-bot.sh [start|stop|status]

set -euo pipefail

PIPELINE_DIR="$HOME/.claude-pipeline"
CONFIG_FILE="$PIPELINE_DIR/config.yml"
LOG_FILE="$PIPELINE_DIR/logs/discord-bot.log"
PID_FILE="$PIPELINE_DIR/locks/discord-bot.pid"
PIPELINE_BIN="$PIPELINE_DIR/bin/pipeline"
DISCORD_API="https://discord.com/api/v10"

# ─── Config ───────────────────────────────────────────────────────────────────

BOT_TOKEN=$(awk '/^\s+discord:/,/^\s+[a-z]+:/{print}' "$CONFIG_FILE" 2>/dev/null | grep "bot_token:" | head -1 | sed 's/.*bot_token:\s*//' | tr -d '"' | xargs)
CHANNEL_ID=$(awk '/^\s+discord:/,/^\s+[a-z]+:/{print}' "$CONFIG_FILE" 2>/dev/null | grep "channel_id:" | head -1 | sed 's/.*channel_id:\s*//' | tr -d '"' | xargs)

# ─── Logging ──────────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DISCORD] $*" >> "$LOG_FILE"
}

# ─── Discord API Helpers ──────────────────────────────────────────────────────

discord_post() {
    local channel="$1"
    local content="$2"
    curl -s -X POST "$DISCORD_API/channels/$channel/messages" \
        -H "Authorization: Bot $BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg content "$content" '{content: $content}')" \
        2>/dev/null || true
}

discord_get_messages() {
    local channel="$1"
    local after="$2"
    local url="$DISCORD_API/channels/$channel/messages?limit=10"
    if [[ -n "$after" ]]; then
        url="${url}&after=${after}"
    fi
    curl -s "$url" \
        -H "Authorization: Bot $BOT_TOKEN" \
        2>/dev/null
}

# ─── Command Processing ──────────────────────────────────────────────────────

process_command() {
    local text="$1"
    local user="$2"

    # Strip "!pipeline " prefix
    local cmd
    cmd=$(echo "$text" | sed 's/^!pipeline\s*//')

    case "$cmd" in
        "status")
            local output
            output=$("$PIPELINE_BIN" status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -20)
            discord_post "$CHANNEL_ID" "📊 **Pipeline Status:**\n\`\`\`$output\`\`\`"
            ;;
        "list"*)
            local filter
            filter=$(echo "$cmd" | sed 's/^list\s*//' | xargs)
            filter="${filter:-queue}"
            local output
            output=$("$PIPELINE_BIN" list "$filter" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -30)
            discord_post "$CHANNEL_ID" "📋 **Tasks ($filter):**\n\`\`\`$output\`\`\`"
            ;;
        "add "*)
            local desc
            desc=$(echo "$cmd" | sed 's/^add\s*//')
            if [[ -n "$desc" ]]; then
                "$PIPELINE_BIN" add "$desc" --dumb 2>/dev/null
                discord_post "$CHANNEL_ID" "✅ Task queued: $desc"
                log "Task created from Discord ($user): $desc"
            fi
            ;;
        "approve "*)
            local task
            task=$(echo "$cmd" | sed 's/^approve\s*//' | xargs)
            "$PIPELINE_BIN" approve "$task" 2>/dev/null
            discord_post "$CHANNEL_ID" "✅ Approved: $task"
            log "Approval from Discord ($user): $task"
            ;;
        "reject "*)
            local task
            task=$(echo "$cmd" | sed 's/^reject\s*//' | xargs)
            "$PIPELINE_BIN" reject "$task" 2>/dev/null
            discord_post "$CHANNEL_ID" "❌ Rejected: $task"
            log "Rejection from Discord ($user): $task"
            ;;
        "help")
            discord_post "$CHANNEL_ID" "🤖 **Claude Pipeline Commands:**\n• \`!pipeline add <description>\` — Create a task\n• \`!pipeline status\` — Show pipeline status\n• \`!pipeline list [queue|active|done|failed]\` — List tasks\n• \`!pipeline approve <task>\` — Approve a pending task\n• \`!pipeline reject <task>\` — Reject a pending task"
            ;;
        *)
            ;;
    esac
}

# ─── Bot Main Loop ───────────────────────────────────────────────────────────

run_bot() {
    if [[ -z "$BOT_TOKEN" || -z "$CHANNEL_ID" ]]; then
        echo "Error: Discord bot_token and channel_id required in config.yml"
        echo "Configure under notifications.discord section"
        exit 1
    fi

    echo $$ > "$PID_FILE"
    log "Discord bot starting (PID $$)"

    # Get bot's own user ID
    local bot_id
    bot_id=$(curl -s "$DISCORD_API/users/@me" -H "Authorization: Bot $BOT_TOKEN" 2>/dev/null | jq -r '.id // empty')

    local last_message_id=""

    trap 'log "Discord bot stopping"; rm -f "$PID_FILE"; exit 0' EXIT SIGTERM SIGINT

    while true; do
        sleep 5

        # Poll for new messages
        local response
        response=$(discord_get_messages "$CHANNEL_ID" "$last_message_id")

        if [[ -z "$response" || "$response" == "[]" ]]; then
            continue
        fi

        # Process each message
        echo "$response" | jq -c '.[]?' 2>/dev/null | while IFS= read -r msg; do
            [[ -z "$msg" ]] && continue

            local msg_id msg_author msg_content
            msg_id=$(echo "$msg" | jq -r '.id // empty')
            msg_author=$(echo "$msg" | jq -r '.author.id // empty')
            msg_content=$(echo "$msg" | jq -r '.content // empty')

            # Skip bot's own messages
            [[ "$msg_author" == "$bot_id" ]] && continue

            # Update last seen message ID
            if [[ -n "$msg_id" ]]; then
                last_message_id="$msg_id"
            fi

            # Only process commands starting with !pipeline
            if [[ "$msg_content" == "!pipeline"* ]]; then
                process_command "$msg_content" "$msg_author"
            fi
        done
    done
}

# ─── Management ───────────────────────────────────────────────────────────────

case "${1:-start}" in
    start)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "Discord bot already running (PID $(cat "$PID_FILE"))"
            exit 0
        fi
        echo "Starting Discord bot..."
        run_bot &
        echo "Discord bot started (PID $!)"
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
            echo "Discord bot stopped"
        else
            echo "Discord bot not running"
        fi
        ;;
    status)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "Discord bot running (PID $(cat "$PID_FILE"))"
        else
            echo "Discord bot not running"
        fi
        ;;
    *)
        echo "Usage: discord-bot.sh [start|stop|status]"
        exit 1
        ;;
esac
