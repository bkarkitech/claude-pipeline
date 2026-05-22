#!/usr/bin/env bash
# ~/.claude-pipeline/bin/telegram-bot.sh
# Telegram bot listener — receives messages and creates pipeline tasks.
# Long-polls the Telegram Bot API for new messages.
# This script can be kept alive by launchd.

set -euo pipefail

PIPELINE_DIR="$HOME/.claude-pipeline"
QUEUE_DIR="$PIPELINE_DIR/queue"
PENDING_DIR="$PIPELINE_DIR/pending"
ACTIVE_DIR="$PIPELINE_DIR/active"
DONE_DIR="$PIPELINE_DIR/done"
FAILED_DIR="$PIPELINE_DIR/failed"
STATE_DIR="$PIPELINE_DIR/state"
LOCKS_DIR="$PIPELINE_DIR/locks"
CONFIG_FILE="$PIPELINE_DIR/config.yml"
LOG_FILE="$PIPELINE_DIR/logs/telegram-bot.log"
PID_FILE="$PIPELINE_DIR/locks/telegram-bot.pid"
OFFSET_FILE="$PIPELINE_DIR/state/.telegram_offset"

# Long-poll timeout in seconds (Telegram supports up to 50s)
POLL_TIMEOUT=30

# Ensure directories exist
mkdir -p "$PIPELINE_DIR/logs" "$PIPELINE_DIR/locks" "$STATE_DIR"

# ─── Logging ─────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [TELEGRAM-BOT] $*" >> "$LOG_FILE"
}

# ─── PID Management ──────────────────────────────────────────────────────────
echo $$ > "$PID_FILE"

cleanup() {
    log "Telegram bot stopping (PID $$)"
    rm -f "$PID_FILE"
}
trap cleanup EXIT

log "Telegram bot starting (PID $$)"

# ─── Config Reading ──────────────────────────────────────────────────────────
config_get() {
    local key="$1"
    local default="${2:-}"
    local value
    value=$(grep -E "^\s*${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | xargs)
    echo "${value:-$default}"
}

get_telegram_config() {
    BOT_TOKEN=$(grep -A 5 "telegram:" "$CONFIG_FILE" 2>/dev/null | grep "bot_token:" | head -1 | sed 's/.*bot_token:[[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//')
    CHAT_ID=$(grep -A 5 "telegram:" "$CONFIG_FILE" 2>/dev/null | grep "chat_id:" | head -1 | sed 's/.*chat_id:[[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//')

    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        log "ERROR: Telegram bot_token or chat_id not configured. Exiting."
        echo "Error: Telegram bot_token or chat_id not configured in config.yml" >&2
        exit 1
    fi

    TELEGRAM_API="https://api.telegram.org/bot${BOT_TOKEN}"
    log "Configured for chat_id=$CHAT_ID"
}

# ─── Offset Management ───────────────────────────────────────────────────────
get_offset() {
    if [[ -f "$OFFSET_FILE" ]]; then
        cat "$OFFSET_FILE"
    else
        echo "0"
    fi
}

save_offset() {
    echo "$1" > "$OFFSET_FILE"
}

# ─── Task ID Generation (mirrors pipeline CLI) ──────────────────────────────
generate_task_id() {
    local max_id=0
    for dir in "$QUEUE_DIR" "$PENDING_DIR" "$ACTIVE_DIR" "$DONE_DIR" "$FAILED_DIR"; do
        local files
        files=$(find "$dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null || true)
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            local num
            num=$(basename "$f" .md | grep -oE '^[0-9]+' || echo "0")
            num=$((10#$num))
            if [[ $num -gt $max_id ]]; then
                max_id=$num
            fi
        done <<< "$files"
    done
    printf "%03d" $((max_id + 1))
}

# ─── Telegram API Helpers ────────────────────────────────────────────────────
send_message() {
    local chat_id="$1"
    local text="$2"
    local parse_mode="${3:-Markdown}"

    local response
    response=$(curl -s -X POST "${TELEGRAM_API}/sendMessage" \
        -F "chat_id=${chat_id}" \
        -F "text=${text}" \
        -F "parse_mode=${parse_mode}" 2>/dev/null) || true

    if echo "$response" | grep -q '"ok":false'; then
        log "WARNING: Failed to send Telegram reply: $response"
    fi
}

get_updates() {
    local offset="$1"
    local result
    result=$(curl -s -X GET "${TELEGRAM_API}/getUpdates?offset=${offset}&timeout=${POLL_TIMEOUT}" 2>/dev/null || echo "")
    echo "$result"
}

# ─── Message Processing ──────────────────────────────────────────────────────
slugify() {
    # Convert text to a URL-friendly slug (first few words)
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | tr ' ' '-' | cut -c1-30 | sed 's/-$//'
}

process_message() {
    local message_text="$1"
    local from_chat_id="$2"
    local from_user="${3:-unknown}"

    # Security: only accept messages from configured chat_id
    if [[ "$from_chat_id" != "$CHAT_ID" ]]; then
        log "REJECTED message from unauthorized chat_id=$from_chat_id (user=$from_user)"
        return 0
    fi

    log "Processing message from $from_user: $message_text"

    # Parse commands
    local task_type="general"
    local priority="5"
    local description=""

    case "$message_text" in
        /help*)
            local help_text
            help_text="*Claude Pipeline Bot*

Send me a message and I'll create a task:

/task <description> - General task
/urgent <description> - High priority (9)
/code <description> - Code task
/research <description> - Research task
/status - Show pipeline status

Or just send plain text for a general task."
            send_message "$CHAT_ID" "$help_text"
            return 0
            ;;
        /status*)
            local q_count a_count d_count f_count
            q_count=$(find "$QUEUE_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
            a_count=$(find "$ACTIVE_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
            d_count=$(find "$DONE_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
            f_count=$(find "$FAILED_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d '[:space:]')

            local status_text
            status_text="*Pipeline Status*

📋 Queue: ${q_count}  ⚡ Active: ${a_count}
✅ Done: ${d_count}   ❌ Failed: ${f_count}"

            # Show active task names if any
            if [[ "$a_count" -gt 0 ]]; then
                status_text="${status_text}

*Running:*"
                for af in "$ACTIVE_DIR"/*.md; do
                    [[ -f "$af" ]] || continue
                    local tname
                    tname=$(grep -m1 "^#" "$af" 2>/dev/null | sed 's/^#*[[:space:]]*//' || basename "$af" .md)
                    status_text="${status_text}
• ${tname}"
                done
            fi

            # Show last 3 completed tasks
            if [[ "$d_count" -gt 0 ]]; then
                status_text="${status_text}

*Recently done:*"
                local count=0
                for df in $(ls -t "$DONE_DIR"/*.md 2>/dev/null | head -3); do
                    [[ -f "$df" ]] || continue
                    local dtname
                    dtname=$(grep -m1 "^#" "$df" 2>/dev/null | sed 's/^#*[[:space:]]*//' || basename "$df" .md)
                    status_text="${status_text}
✓ ${dtname}"
                    count=$((count + 1))
                done
            fi

            send_message "$CHAT_ID" "$status_text"
            return 0
            ;;
        /urgent\ *)
            description="${message_text#/urgent }"
            priority="9"
            ;;
        /code\ *)
            description="${message_text#/code }"
            task_type="code"
            ;;
        /research\ *)
            description="${message_text#/research }"
            task_type="research"
            ;;
        /task\ *)
            description="${message_text#/task }"
            ;;
        /*)
            # Unknown command
            send_message "$CHAT_ID" "Unknown command. Send /help for available commands."
            return 0
            ;;
        *)
            # Plain text = general task
            description="$message_text"
            ;;
    esac

    if [[ -z "$description" ]]; then
        send_message "$CHAT_ID" "Please provide a task description."
        return 0
    fi

    # Generate task file
    local task_id slug filename
    task_id=$(generate_task_id)
    slug=$(slugify "$description")
    filename="${task_id}-telegram-${slug}.md"

    local model timeout budget
    model=$(config_get "model" "sonnet")
    timeout=$(config_get "timeout" "600")
    budget=$(config_get "budget" "5.00")

    cat > "$QUEUE_DIR/$filename" <<EOF
---
type: ${task_type}
priority: ${priority}
auto: true
model: ${model}
timeout: ${timeout}
budget: ${budget}
source: telegram
---

# ${description}

Task submitted via Telegram by ${from_user}.

${description}
EOF

    log "Task created: $filename (type=$task_type, priority=$priority)"
    send_message "$CHAT_ID" "$(printf '✅ *Task Queued*\n\n📄 %s\n🏷 Type: %s\n⚡ Priority: %s\n\nYour task is in the queue and will be picked up shortly.' "$filename" "$task_type" "$priority")"
}

# ─── Main Loop ───────────────────────────────────────────────────────────────
get_telegram_config

log "Starting long-poll loop (timeout=${POLL_TIMEOUT}s)"

while true; do
    local_offset=$(get_offset)

    # Long-poll for updates
    response=$(get_updates "$local_offset")

    if [[ -z "$response" ]]; then
        log "WARNING: Empty response from Telegram API, retrying..."
        sleep 5
        continue
    fi

    # Check if response is valid
    ok=$(echo "$response" | jq -r '.ok' 2>/dev/null || echo "false")
    if [[ "$ok" != "true" ]]; then
        log "WARNING: Telegram API error: $response"
        sleep 10
        continue
    fi

    # Process each update
    update_count=$(echo "$response" | jq '.result | length' 2>/dev/null || echo "0")

    if [[ "$update_count" -gt 0 ]]; then
        log "Received $update_count update(s)"

        for ((i=0; i<update_count; i++)); do
            update=$(echo "$response" | jq ".result[$i]")
            update_id=$(echo "$update" | jq -r '.update_id')
            message_text=$(echo "$update" | jq -r '.message.text // empty')
            from_chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
            from_user=$(echo "$update" | jq -r '.message.from.first_name // "unknown"')

            # Save offset (next update_id + 1)
            save_offset $((update_id + 1))

            # Skip if no message text
            if [[ -z "$message_text" ]]; then
                log "Skipping update $update_id (no text message)"
                continue
            fi

            process_message "$message_text" "$from_chat_id" "$from_user"
        done
    fi
done
