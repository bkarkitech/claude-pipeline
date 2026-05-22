#!/usr/bin/env bash
# ~/.claude-pipeline/bin/dispatcher.sh
# Core execution engine for the Claude Pipeline.
# Called by the watcher when a new task appears in queue/.
# Can also be called directly: dispatcher.sh <task-file>
#
# v2: Session persistence + checkpointing + resumption support

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
PIPELINE_DIR="$HOME/.claude-pipeline"
QUEUE_DIR="$PIPELINE_DIR/queue"
PENDING_DIR="$PIPELINE_DIR/pending"
ACTIVE_DIR="$PIPELINE_DIR/active"
DONE_DIR="$PIPELINE_DIR/done"
FAILED_DIR="$PIPELINE_DIR/failed"
LOGS_DIR="$PIPELINE_DIR/logs"
LOCKS_DIR="$PIPELINE_DIR/locks"
STATE_DIR="$PIPELINE_DIR/state"
CONFIG_FILE="$PIPELINE_DIR/config.yml"
SYSTEM_PROMPT_FILE="$PIPELINE_DIR/CLAUDE.md"
GLOBAL_LOG="$LOGS_DIR/dispatcher.log"

CLAUDE_BIN="$HOME/.local/bin/claude"
NODE_BIN="$HOME/.nvm/versions/node/v25.6.1/bin/node"

# ─── Logging ──────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$GLOBAL_LOG"
    if [[ "$level" == "ERROR" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
    fi
}

# ─── Config Parsing (simple grep-based YAML reader) ───────────────────────────
config_get() {
    local key="$1"
    local default="${2:-}"
    local value
    value=$(grep -E "^\s*${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | xargs)
    echo "${value:-$default}"
}

# ─── Notification ─────────────────────────────────────────────────────────────
notify() {
    local title="$1"
    local message="$2"
    local event_type="${3:-complete}"  # complete, failure, start, timeout, resume
    local sound
    sound=$(config_get "sound" "Glass")

    # macOS native notification
    if [[ "$(config_get 'enabled' 'true')" == "true" ]]; then
        osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\"" 2>/dev/null || true
    fi

    # Telegram (background, non-blocking)
    _notify_telegram "$title" "$message" "$event_type" &

    # Email (background, non-blocking)
    _notify_email "$title" "$message" "$event_type" &

    # Webhook (background, non-blocking)
    _notify_webhook "$title" "$message" "$event_type" &

    # Regenerate dashboard status
    "$PIPELINE_DIR/bin/generate-status.sh" 2>/dev/null &
}

_notify_telegram() {
    local title="$1" message="$2" event_type="${3:-complete}"
    local enabled token chat_id
    enabled=$(grep -A 5 "telegram:" "$CONFIG_FILE" 2>/dev/null | grep "enabled:" | head -1 | sed 's/.*enabled:\s*//' | tr -d '[:space:]')
    token=$(grep -A 5 "telegram:" "$CONFIG_FILE" 2>/dev/null | grep "bot_token:" | head -1 | sed 's/.*bot_token:\s*//' | tr -d '"' | tr -d '[:space:]')
    chat_id=$(grep -A 5 "telegram:" "$CONFIG_FILE" 2>/dev/null | grep "chat_id:" | head -1 | sed 's/.*chat_id:\s*//' | tr -d '"' | tr -d '[:space:]')

    # Skip if not enabled or not configured
    if [[ "$enabled" != "true" || -z "$token" || -z "$chat_id" ]]; then
        return 0
    fi

    # Format message with emoji based on event type
    local emoji=""
    case "$event_type" in
        complete) emoji="✅" ;;
        failure)  emoji="❌" ;;
        start)    emoji="🚀" ;;
        timeout)  emoji="⏰" ;;
        resume)   emoji="🔄" ;;
        *)        emoji="📋" ;;
    esac

    local text="${emoji} *${title}*
${message}
_$(date '+%Y-%m-%d %H:%M')_"

    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${text}" \
        -d "parse_mode=Markdown" \
        >/dev/null 2>&1 || log "WARN" "Telegram notification failed"
}

_notify_email() {
    local title="$1" message="$2" event_type="${3:-complete}"
    local enabled to from prefix
    enabled=$(grep -A 5 "email:" "$CONFIG_FILE" 2>/dev/null | grep "enabled:" | head -1 | sed 's/.*enabled:\s*//' | xargs)
    to=$(grep -A 5 "email:" "$CONFIG_FILE" 2>/dev/null | grep "to:" | head -1 | sed 's/.*to:\s*//' | sed 's/^"//' | sed 's/"$//' | xargs)
    from=$(grep -A 5 "email:" "$CONFIG_FILE" 2>/dev/null | grep "from:" | head -1 | sed 's/.*from:\s*//' | sed 's/^"//' | sed 's/"$//' | xargs)
    prefix=$(grep -A 5 "email:" "$CONFIG_FILE" 2>/dev/null | grep "subject_prefix:" | head -1 | sed 's/.*subject_prefix:\s*//' | sed 's/^"//' | sed 's/"$//' | xargs)

    from="${from:-claude-pipeline@localhost}"
    prefix="${prefix:-[Pipeline]}"

    # Skip if not enabled or not configured
    if [[ "$enabled" != "true" || -z "$to" ]]; then
        return 0
    fi

    {
        echo "From: $from"
        echo "To: $to"
        echo "Subject: $prefix $title"
        echo "Content-Type: text/plain; charset=utf-8"
        echo "X-Pipeline-Event: $event_type"
        echo ""
        echo "$title"
        echo ""
        echo "$message"
        echo ""
        echo "---"
        echo "Event: $event_type"
        echo "Claude Pipeline | $(date)"
    } | /usr/sbin/sendmail "$to" 2>/dev/null || log "WARN" "Email notification failed"
}

_notify_webhook() {
    local title="$1" message="$2" event_type="${3:-complete}"
    local enabled url auth_header events_filter
    enabled=$(grep -A 6 "webhook:" "$CONFIG_FILE" 2>/dev/null | grep "enabled:" | head -1 | sed 's/.*enabled:\s*//' | xargs)
    url=$(grep -A 6 "webhook:" "$CONFIG_FILE" 2>/dev/null | grep "url:" | head -1 | sed 's/.*url:\s*//' | sed 's/^"//' | sed 's/"$//' | xargs)
    auth_header=$(grep -A 6 "webhook:" "$CONFIG_FILE" 2>/dev/null | grep "auth_header:" | head -1 | sed 's/.*auth_header:\s*//' | sed 's/^"//' | sed 's/"$//' | xargs)
    events_filter=$(grep -A 6 "webhook:" "$CONFIG_FILE" 2>/dev/null | grep "events:" | head -1 | sed 's/.*events:\s*//' | sed 's/^"//' | sed 's/"$//' | xargs)

    # Skip if not enabled or not configured
    if [[ "$enabled" != "true" || -z "$url" ]]; then
        return 0
    fi

    # Check if this event type is in the filter
    if [[ -n "$events_filter" && "$events_filter" != *"$event_type"* ]]; then
        return 0
    fi

    # Build JSON payload
    local payload
    payload=$(jq -n \
        --arg event "$event_type" \
        --arg title "$title" \
        --arg message "$message" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg hostname "$(hostname)" \
        '{event: $event, title: $title, message: $message, timestamp: $timestamp, hostname: $hostname, source: "claude-pipeline"}')

    # Send webhook
    local curl_args=(-s -X POST "$url" -H "Content-Type: application/json" -d "$payload" --max-time 10)
    if [[ -n "$auth_header" ]]; then
        curl_args+=(-H "Authorization: $auth_header")
    fi

    curl "${curl_args[@]}" >/dev/null 2>&1 || log "WARN" "Webhook notification failed: $url"
}

# ─── Frontmatter Parsing ─────────────────────────────────────────────────────
# Extracts YAML frontmatter value from a task file
frontmatter_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"

    # Extract between --- markers
    local value
    value=$(sed -n '/^---$/,/^---$/p' "$file" | grep -E "^\s*${key}:" | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | xargs)
    echo "${value:-$default}"
}

# Write/update a frontmatter field in a task file
frontmatter_set() {
    local file="$1"
    local key="$2"
    local value="$3"

    # Check if key already exists in frontmatter
    if sed -n '/^---$/,/^---$/p' "$file" | grep -q "^${key}:"; then
        # Update existing field
        sed -i '' "s/^${key}:.*/${key}: ${value}/" "$file"
    else
        # Insert new field before the closing ---
        # Use awk: insert before the second --- line
        awk -v key="$key" -v val="$value" '
            BEGIN { count=0 }
            /^---$/ { count++ }
            count==2 && /^---$/ { print key ": " val }
            { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

# Remove a frontmatter field from a task file
frontmatter_remove() {
    local file="$1"
    local key="$2"

    sed -i '' "/^${key}:/d" "$file"
}

# Extract task body (everything after second ---)
task_body() {
    local file="$1"
    sed -n '/^---$/,/^---$/!p' "$file" | sed '/^$/N;/^\n$/d'  # Remove leading blank lines
}

# ─── Concurrency Control ─────────────────────────────────────────────────────
active_count() {
    find "$ACTIVE_DIR" -name "*.md" -type f 2>/dev/null | wc -l | xargs
}

acquire_lock() {
    local task_name="$1"
    local lock_file="$LOCKS_DIR/${task_name}.lock"

    # Atomic lock acquisition
    if (set -o noclobber; echo "$$" > "$lock_file") 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

release_lock() {
    local task_name="$1"
    rm -f "$LOCKS_DIR/${task_name}.lock"
}

clean_stale_locks() {
    local timeout
    timeout=$(config_get "lock_timeout_seconds" "3600")

    find "$LOCKS_DIR" -name "*.lock" -type f -mmin "+$((timeout / 60))" | while read -r lock_file; do
        local pid
        pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            log "WARN" "Cleaning stale lock: $lock_file (pid $pid is dead)"
            rm -f "$lock_file"
        fi
    done
}

# ─── Repo Resolution ─────────────────────────────────────────────────────────
resolve_repo() {
    local repo_spec="$1"

    # If it's an absolute path, use directly
    if [[ "$repo_spec" == /* ]]; then
        echo "$repo_spec"
        return
    fi

    # If it starts with ~, expand
    if [[ "$repo_spec" == ~* ]]; then
        eval echo "$repo_spec"
        return
    fi

    # Look up in config repos section
    local repo_path
    repo_path=$(grep -A 20 "^repos:" "$CONFIG_FILE" | grep -E "^\s+${repo_spec}:" | head -1 | sed 's/^[^:]*:\s*//' | xargs)

    if [[ -n "$repo_path" && -d "$repo_path" ]]; then
        echo "$repo_path"
    else
        # Try common locations
        for base in "$HOME/Projects" "$HOME/projects" "$HOME/repos" "$HOME/code"; do
            if [[ -d "$base/$repo_spec" ]]; then
                echo "$base/$repo_spec"
                return
            fi
        done
        # Fallback: pipeline dir
        echo "$PIPELINE_DIR"
    fi
}

# ─── Session Validation ──────────────────────────────────────────────────────
# Check if a Claude session is valid and resumable
validate_session() {
    local session_id="$1"
    local work_dir="$2"

    # Encode path the way Claude Code does it (replace / with -)
    local encoded_path
    encoded_path=$(echo "$work_dir" | sed 's|^/||' | tr '/' '-')
    local session_file="$HOME/.claude/projects/-${encoded_path}/${session_id}.jsonl"

    # Check file exists and is non-empty
    if [[ -f "$session_file" && -s "$session_file" ]]; then
        # Check age (sessions older than max_age may have stale context)
        local max_age_days
        max_age_days=$(config_get "session_max_age_days" "7")
        local file_mod_epoch
        file_mod_epoch=$(stat -f %m "$session_file" 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local file_age_days=$(( (now_epoch - file_mod_epoch) / 86400 ))

        if [[ $file_age_days -le $max_age_days ]]; then
            log "INFO" "Session $session_id validated (age: ${file_age_days}d)"
            return 0
        else
            log "WARN" "Session $session_id too old (${file_age_days}d > ${max_age_days}d max)"
        fi
    else
        log "WARN" "Session file not found or empty: $session_file"
    fi
    return 1
}

# ─── Git State Capture ────────────────────────────────────────────────────────
# Capture git state for context reconstruction fallback
capture_git_state() {
    local work_dir="$1"
    local state_dir="$2"

    if [[ -d "$work_dir/.git" ]]; then
        {
            echo "=== Snapshot taken: $(date '+%Y-%m-%d %H:%M:%S') ==="
            echo ""
            echo "=== Branch ==="
            git -C "$work_dir" branch --show-current 2>/dev/null || echo "(detached)"
            echo ""
            echo "=== Recent Commits (last 5) ==="
            git -C "$work_dir" log --oneline -5 2>/dev/null || echo "(no commits)"
            echo ""
            echo "=== Uncommitted Changes ==="
            git -C "$work_dir" status --short 2>/dev/null || echo "(clean)"
            echo ""
            echo "=== Diff Summary ==="
            git -C "$work_dir" diff --stat 2>/dev/null || echo "(no diff)"
        } > "$state_dir/git-snapshot.txt"
    fi
}

# ─── State File Management ────────────────────────────────────────────────────
# Write the state tracking JSON file
write_state() {
    local file="$1"
    local session_id="$2"
    local attempt="$3"
    local status="$4"
    local work_dir="$5"
    local budget_total="${6:-0}"

    cat > "$file" <<STATEEOF
{
    "session_id": "$session_id",
    "attempt": $attempt,
    "status": "$status",
    "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "last_activity": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "budget_used": $budget_total,
    "work_dir": "$work_dir",
    "resumable": true
}
STATEEOF
}

# Append to attempts log
log_attempt() {
    local state_dir="$1"
    local session_id="$2"
    local attempt="$3"
    local mode="$4"
    local exit_code="$5"
    local duration="$6"

    echo "{\"attempt\":$attempt,\"session_id\":\"$session_id\",\"mode\":\"$mode\",\"exit_code\":$exit_code,\"duration\":$duration,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$state_dir/attempts.jsonl"
}

# ─── Context Reconstruction ──────────────────────────────────────────────────
# Build a smart prompt when session can't be resumed (fallback mode)
reconstruct_context() {
    local task_name="$1"
    local state_dir="$PIPELINE_DIR/state/$task_name"
    local original_body="$2"

    local context=""

    # Add original task
    context="# Original Task\n\n${original_body}\n\n"

    # Add git state if available
    if [[ -f "$state_dir/git-snapshot.txt" ]]; then
        context+="# Previous Progress (from git state)\n\n"
        context+="The previous execution made the following progress before being interrupted:\n\n"
        context+="\`\`\`\n$(cat "$state_dir/git-snapshot.txt")\n\`\`\`\n\n"
    fi

    # Add last few lines of log output
    local last_log
    last_log=$(find "$LOGS_DIR" -name "${task_name}*" -type f 2>/dev/null | sort | tail -1)
    if [[ -n "$last_log" && -f "$last_log" ]]; then
        context+="# Last Known Output (tail of previous execution)\n\n"
        context+="\`\`\`\n$(tail -50 "$last_log")\n\`\`\`\n\n"
    fi

    context+="# Instructions\n\n"
    context+="Continue this task. The previous execution was interrupted. "
    context+="Review what was already done (check git log, modified files) and continue from where it stopped. "
    context+="Do NOT redo completed work.\n"

    echo -e "$context"
}

# ─── Stream Processing ────────────────────────────────────────────────────────
# Process stream-json output to extract human-readable text + cost tracking
process_stream() {
    local state_dir="$1"
    local task_log="$2"

    while IFS= read -r line; do
        # Save raw stream output
        echo "$line" >> "$state_dir/stream-output.jsonl"

        # Extract useful information based on message type
        local msg_type
        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)

        case "$msg_type" in
            "assistant")
                # Extract text content for human-readable log
                local text
                text=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null || true)
                if [[ -n "$text" ]]; then
                    echo "$text" >> "$task_log"
                fi
                ;;
            "result")
                # Capture final cost from result event
                local cost
                cost=$(echo "$line" | jq -r '.total_cost_usd // .cost_usd // 0' 2>/dev/null || echo "0")
                if [[ "$cost" != "0" && "$cost" != "null" && -n "$cost" ]]; then
                    # Update budget_used in state file
                    local prev_used
                    prev_used=$(jq -r '.budget_used // 0' "$state_dir/current.json" 2>/dev/null || echo "0")
                    local total_used
                    total_used=$(echo "$prev_used + $cost" | bc 2>/dev/null || echo "$cost")
                    jq --argjson cost "$total_used" '.budget_used = $cost | .status = "completed"' \
                        "$state_dir/current.json" > "$state_dir/current.json.tmp" 2>/dev/null \
                        && mv "$state_dir/current.json.tmp" "$state_dir/current.json"
                fi
                # Also write result text to log
                local result_text
                result_text=$(echo "$line" | jq -r '.result // empty' 2>/dev/null || true)
                if [[ -n "$result_text" ]]; then
                    echo "$result_text" >> "$task_log"
                fi
                ;;
        esac
    done
}

# ─── Dependency Resolution ────────────────────────────────────────────────────
# After a task completes, check pending/ for tasks that depend on it and re-queue them
_requeue_unblocked_tasks() {
    local completed_name="$1"

    for f in "$PENDING_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        local deps
        deps=$(frontmatter_get "$f" "depends_on" "")
        [[ -z "$deps" ]] && continue

        # Check if this task depends on the completed one
        if [[ "$deps" == *"$completed_name"* ]]; then
            # Verify ALL dependencies are now met
            local all_met=true
            IFS=',' read -ra dep_list <<< "$deps"
            for dep in "${dep_list[@]}"; do
                dep=$(echo "$dep" | xargs)
                [[ -z "$dep" ]] && continue
                if [[ ! -f "$DONE_DIR/${dep}.md" ]]; then
                    if ! find "$DONE_DIR" -name "*${dep}*" -type f 2>/dev/null | grep -q .; then
                        all_met=false
                        break
                    fi
                fi
            done

            if [[ "$all_met" == "true" ]]; then
                local unblocked_name
                unblocked_name=$(basename "$f" .md)
                log "INFO" "Dependencies met for $unblocked_name — re-queuing"
                mv "$f" "$QUEUE_DIR/"
            fi
        fi
    done
}

# ─── Main: Process a Single Task ─────────────────────────────────────────────
process_task() {
    local task_file="$1"
    local task_name
    task_name=$(basename "$task_file" .md)

    log "INFO" "Processing task: $task_name"

    # ── Parse frontmatter ──
    local task_type repo priority auto_flag model effort timeout budget add_dirs branch resume_session depends_on
    task_type=$(frontmatter_get "$task_file" "type" "general")
    repo=$(frontmatter_get "$task_file" "repo" "")
    priority=$(frontmatter_get "$task_file" "priority" "5")
    auto_flag=$(frontmatter_get "$task_file" "auto" "true")
    model=$(frontmatter_get "$task_file" "model" "$(config_get 'model' 'opus')")
    effort=$(frontmatter_get "$task_file" "effort" "$(config_get 'effort' 'max')")
    timeout=$(frontmatter_get "$task_file" "timeout" "$(config_get 'timeout' '600')")
    budget=$(frontmatter_get "$task_file" "budget" "$(config_get 'budget' '5.00')")
    add_dirs=$(frontmatter_get "$task_file" "add-dirs" "")
    branch=$(frontmatter_get "$task_file" "branch" "")
    resume_session=$(frontmatter_get "$task_file" "resume_session" "")
    depends_on=$(frontmatter_get "$task_file" "depends_on" "")

    # ── Check dependencies ──
    if [[ -n "$depends_on" ]]; then
        local deps_met=true
        IFS=',' read -ra dep_list <<< "$depends_on"
        for dep in "${dep_list[@]}"; do
            dep=$(echo "$dep" | xargs)  # trim whitespace
            [[ -z "$dep" ]] && continue
            # Check if dependency is in done/
            local dep_found=false
            if [[ -f "$DONE_DIR/${dep}.md" ]]; then
                dep_found=true
            else
                # Partial match
                if find "$DONE_DIR" -name "*${dep}*" -type f 2>/dev/null | grep -q .; then
                    dep_found=true
                fi
            fi
            if [[ "$dep_found" == "false" ]]; then
                deps_met=false
                log "INFO" "Task $task_name blocked: dependency '$dep' not completed"
                break
            fi
        done

        if [[ "$deps_met" == "false" ]]; then
            # Move back to pending (or keep in queue) — dependencies not met
            log "INFO" "Task $task_name: dependencies not met, moving to pending/"
            mv "$task_file" "$PENDING_DIR/"
            return 0
        fi
    fi

    # ── Handle auto:false (move to pending/) ──
    if [[ "$auto_flag" == "false" ]]; then
        mv "$task_file" "$PENDING_DIR/"
        log "INFO" "Task $task_name moved to pending/ (auto:false)"
        return 0
    fi

    # ── Concurrency check ──
    local max_concurrent
    max_concurrent=$(config_get "max_concurrent" "2")

    if [[ $(active_count) -ge $max_concurrent ]]; then
        log "WARN" "Concurrency limit reached ($max_concurrent). Task $task_name stays in queue."
        return 0
    fi

    # ── Acquire lock ──
    if ! acquire_lock "$task_name"; then
        log "WARN" "Could not acquire lock for $task_name (already processing?)"
        return 0
    fi

    # ── Move to active ──
    mv "$task_file" "$ACTIVE_DIR/"
    local active_file="$ACTIVE_DIR/$(basename "$task_file")"

    # ── Resolve working directory ──
    local work_dir="$HOME"
    if [[ -n "$repo" ]]; then
        work_dir=$(resolve_repo "$repo")
    fi

    # ── Prepare log file ──
    local task_log="$LOGS_DIR/${task_name}-$(date '+%Y%m%d-%H%M%S').log"

    # ── Extract task body ──
    local body
    body=$(task_body "$active_file")

    # Prepend branch instruction if specified
    if [[ -n "$branch" ]]; then
        body="IMPORTANT: Work on git branch named '$branch'. Create it if it doesn't exist.

$body"
    fi

    # ── Initialize state tracking ──
    local state_dir="$STATE_DIR/$task_name"
    mkdir -p "$state_dir"

    # Clear previous stream output for this attempt
    > "$state_dir/stream-output.jsonl"

    # ── Determine execution mode: FRESH vs RESUME vs RECONSTRUCT ──
    local exec_mode="fresh"
    local session_id=""
    local attempt=1
    local remaining_budget="$budget"
    local prompt=""

    if [[ -n "$resume_session" ]]; then
        # Task has a resume_session field — try to resume
        if validate_session "$resume_session" "$work_dir"; then
            exec_mode="resume"
            session_id="$resume_session"

            # Read attempt count from state
            if [[ -f "$state_dir/current.json" ]]; then
                attempt=$(jq -r '.attempt // 1' "$state_dir/current.json" 2>/dev/null || echo "1")
                attempt=$((attempt + 1))

                # Calculate remaining budget
                local used
                used=$(jq -r '.budget_used // 0' "$state_dir/current.json" 2>/dev/null || echo "0")
                remaining_budget=$(echo "$budget - $used" | bc 2>/dev/null || echo "$budget")

                # Check if we have enough budget to resume
                local min_budget
                min_budget=$(config_get "min_budget_for_resume" "0.50")
                if (( $(echo "$remaining_budget < $min_budget" | bc -l 2>/dev/null || echo "0") )); then
                    log "WARN" "Insufficient budget to resume ($remaining_budget < $min_budget). Marking non-resumable."
                    jq '.resumable = false | .status = "budget_exhausted"' \
                        "$state_dir/current.json" > "$state_dir/current.json.tmp" 2>/dev/null \
                        && mv "$state_dir/current.json.tmp" "$state_dir/current.json"
                    mv "$active_file" "$FAILED_DIR/"
                    release_lock "$task_name"
                    notify "Pipeline: Budget Exhausted" "$task_name — no budget remaining for resume" "failure"
                    return 0
                fi
            fi

            # Check max attempts
            local max_attempts
            max_attempts=$(config_get "max_attempts" "5")
            if [[ $attempt -gt $max_attempts ]]; then
                log "WARN" "Max resume attempts reached ($max_attempts) for $task_name"
                jq '.resumable = false | .status = "max_attempts_reached"' \
                    "$state_dir/current.json" > "$state_dir/current.json.tmp" 2>/dev/null \
                    && mv "$state_dir/current.json.tmp" "$state_dir/current.json"
                mv "$active_file" "$FAILED_DIR/"
                release_lock "$task_name"
                notify "Pipeline: Max Attempts" "$task_name — exceeded $max_attempts resume attempts" "failure"
                return 0
            fi

            prompt="Continue the task from where you left off. The previous session was interrupted. Pick up exactly where you stopped."
            log "INFO" "RESUME MODE: session=$session_id attempt=$attempt budget_remaining=$remaining_budget"
        else
            # Session invalid — fall back to context reconstruction
            exec_mode="reconstruct"
            session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

            if [[ -f "$state_dir/current.json" ]]; then
                attempt=$(jq -r '.attempt // 1' "$state_dir/current.json" 2>/dev/null || echo "1")
                attempt=$((attempt + 1))
            fi

            prompt=$(reconstruct_context "$task_name" "$body")
            log "INFO" "RECONSTRUCT MODE: old session invalid, using context recovery. New session=$session_id"
        fi
    else
        # No resume_session — fresh execution
        exec_mode="fresh"
        session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
        prompt="$body"
        log "INFO" "FRESH MODE: session=$session_id"
    fi

    # ── Capture pre-execution git state ──
    capture_git_state "$work_dir" "$state_dir"

    # ── Write state file ──
    local prev_budget_used="0"
    if [[ -f "$state_dir/current.json" ]]; then
        prev_budget_used=$(jq -r '.budget_used // 0' "$state_dir/current.json" 2>/dev/null || echo "0")
    fi
    write_state "$state_dir/current.json" "$session_id" "$attempt" "running" "$work_dir" "$prev_budget_used"

    log "INFO" "Executing task: $task_name | mode=$exec_mode | type=$task_type | repo=$work_dir | model=$model | timeout=${timeout}s | attempt=$attempt"

    # Notify on task start if configured
    if [[ "$(config_get 'on_start' 'false')" == "true" ]]; then
        notify "Pipeline: Started" "$task_name — mode=$exec_mode, model=$model" "start"
    fi

    # ── Build Claude command based on execution mode ──
    local claude_args=()

    if [[ "$exec_mode" == "resume" ]]; then
        claude_args=(
            "--resume" "$session_id"
            "-p"
            "--verbose"
            "--dangerously-skip-permissions"
            "--model" "$model"
            "--effort" "$effort"
            "--max-budget-usd" "$remaining_budget"
            "--output-format" "stream-json"
        )
    else
        # Fresh or Reconstruct mode
        claude_args=(
            "-p"
            "--verbose"
            "--dangerously-skip-permissions"
            "--session-id" "$session_id"
            "--model" "$model"
            "--effort" "$effort"
            "--max-budget-usd" "$remaining_budget"
            "--append-system-prompt-file" "$SYSTEM_PROMPT_FILE"
            "--output-format" "stream-json"
        )
    fi

    # Add extra directories if specified
    if [[ -n "$add_dirs" ]]; then
        IFS=',' read -ra dirs <<< "$add_dirs"
        for dir in "${dirs[@]}"; do
            dir=$(echo "$dir" | xargs)  # trim whitespace
            claude_args+=("--add-dir" "$dir")
        done
    fi

    # ── Execute ──
    local start_time exit_code
    start_time=$(date +%s)

    # Write task header to log
    {
        echo "======================================================================="
        echo "Task: $task_name"
        echo "Mode: $exec_mode (attempt $attempt)"
        echo "Session: $session_id"
        echo "Type: $task_type"
        echo "Repo: $work_dir"
        echo "Model: $model | Effort: $effort | Timeout: ${timeout}s | Budget: \$${remaining_budget}"
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "======================================================================="
        echo ""
    } > "$task_log"

    # Run Claude with timeout
    # Strategy: capture raw stream-json to file, then post-process for log + state
    local raw_output="$state_dir/stream-output.jsonl"
    > "$raw_output"

    set +e

    # macOS-compatible timeout using background process + kill
    (
        cd "$work_dir" && "$CLAUDE_BIN" "${claude_args[@]}" "$prompt" > "$raw_output" 2>> "$task_log"
    ) &
    local claude_pid=$!

    # Watchdog: kill after timeout
    (
        sleep "$timeout"
        kill -TERM "$claude_pid" 2>/dev/null
        sleep 5
        kill -KILL "$claude_pid" 2>/dev/null
    ) &
    local watchdog_pid=$!

    # Wait for Claude to finish
    wait "$claude_pid" 2>/dev/null
    exit_code=$?

    # Kill the watchdog if Claude finished before timeout
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null || true

    # Detect if killed by timeout (137=SIGKILL, 143=SIGTERM)
    if [[ $exit_code -eq 143 || $exit_code -eq 137 ]]; then
        exit_code=124  # Conventional timeout exit code
    fi

    # ── Post-process stream output ──
    # Extract text output for human-readable log and cost tracking
    if [[ -s "$raw_output" ]]; then
        # Extract assistant text messages into log
        jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' \
            "$raw_output" >> "$task_log" 2>/dev/null || true

        # Extract result text
        jq -r 'select(.type=="result") | .result // empty' \
            "$raw_output" >> "$task_log" 2>/dev/null || true

        # Extract cost and update state
        local total_cost
        total_cost=$(jq -r 'select(.type=="result") | .total_cost_usd // 0' "$raw_output" 2>/dev/null | tail -1)
        if [[ -n "$total_cost" && "$total_cost" != "0" && "$total_cost" != "null" ]]; then
            local prev_budget_total
            prev_budget_total=$(jq -r '.budget_used // 0' "$state_dir/current.json" 2>/dev/null || echo "0")
            local new_total
            new_total=$(echo "$prev_budget_total + $total_cost" | bc 2>/dev/null || echo "$total_cost")
            jq --argjson cost "$new_total" '.budget_used = $cost' \
                "$state_dir/current.json" > "$state_dir/current.json.tmp" 2>/dev/null \
                && mv "$state_dir/current.json.tmp" "$state_dir/current.json" || true
        fi
    fi

    # Re-enable strict mode for the rest
    set -e

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Write footer to log
    {
        echo ""
        echo "======================================================================="
        echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Duration: ${duration}s"
        echo "Exit code: $exit_code"
        echo "Mode: $exec_mode | Attempt: $attempt | Session: $session_id"
        echo "======================================================================="
    } >> "$task_log"

    # ── Log this attempt ──
    log_attempt "$state_dir" "$session_id" "$attempt" "$exec_mode" "$exit_code" "$duration"

    # ── Handle result ──
    if [[ $exit_code -eq 0 ]]; then
        # Success — update state and move to done
        jq '.status = "completed" | .resumable = false' \
            "$state_dir/current.json" > "$state_dir/current.json.tmp" 2>/dev/null \
            && mv "$state_dir/current.json.tmp" "$state_dir/current.json"

        # Capture final git state
        capture_git_state "$work_dir" "$state_dir"

        mv "$active_file" "$DONE_DIR/"
        log "INFO" "Task $task_name completed successfully (${duration}s, attempt $attempt, mode $exec_mode)"
        notify "Pipeline: Done" "$task_name completed (${duration}s)" "complete"

        # Check if any pending tasks had this as a dependency — re-queue them
        _requeue_unblocked_tasks "$task_name"

    elif [[ $exit_code -eq 124 ]]; then
        # Timeout — mark as resumable
        jq '.status = "timeout" | .resumable = true | .failure_reason = "timeout"' \
            "$state_dir/current.json" > "$state_dir/current.json.tmp" 2>/dev/null \
            && mv "$state_dir/current.json.tmp" "$state_dir/current.json"

        # Capture post-execution git state (what did Claude accomplish before timeout?)
        capture_git_state "$work_dir" "$state_dir"

        # Write resume_session into frontmatter
        frontmatter_set "$active_file" "resume_session" "$session_id"

        mv "$active_file" "$FAILED_DIR/"
        echo "FAILURE: Timed out after ${timeout}s (resumable)" >> "$task_log"
        log "ERROR" "Task $task_name timed out after ${timeout}s (resumable, session=$session_id)"
        notify "Pipeline: Timeout (resumable)" "$task_name timed out — 'pipeline resume $task_name'" "timeout"

        # Auto-resume on timeout if configured
        if [[ "$(config_get 'auto_resume_on_timeout' 'false')" == "true" ]]; then
            log "INFO" "Auto-resuming timed-out task: $task_name"
            local failed_file="$FAILED_DIR/$(basename "$active_file")"
            mv "$failed_file" "$QUEUE_DIR/" 2>/dev/null || true
        fi

    else
        # Other failure — mark as resumable
        jq --arg reason "exit_$exit_code" '.status = "failed" | .resumable = true | .failure_reason = $reason' \
            "$state_dir/current.json" > "$state_dir/current.json.tmp" 2>/dev/null \
            && mv "$state_dir/current.json.tmp" "$state_dir/current.json"

        # Capture post-execution git state
        capture_git_state "$work_dir" "$state_dir"

        # Write resume_session into frontmatter
        frontmatter_set "$active_file" "resume_session" "$session_id"

        mv "$active_file" "$FAILED_DIR/"
        echo "FAILURE: Exit code $exit_code (resumable)" >> "$task_log"
        log "ERROR" "Task $task_name failed with exit code $exit_code (${duration}s, resumable, session=$session_id)"
        notify "Pipeline: Failed (resumable)" "$task_name failed — 'pipeline resume $task_name'" "failure"
    fi

    # ── Release lock ──
    release_lock "$task_name"

    return 0
}

# ─── Main Entry Point ─────────────────────────────────────────────────────────
main() {
    # Ensure directories exist
    mkdir -p "$QUEUE_DIR" "$PENDING_DIR" "$ACTIVE_DIR" "$DONE_DIR" "$FAILED_DIR" "$LOGS_DIR" "$LOCKS_DIR" "$STATE_DIR"

    # Global dispatcher scan lock — prevents two dispatcher instances from
    # scanning the queue simultaneously (e.g. watchman trigger + periodic sweep).
    # Use flock with a 0-second timeout: if we can't get the lock instantly, a
    # dispatcher is already running; exit gracefully.
    local scan_lock="$LOCKS_DIR/dispatcher-scan.lock"
    exec 9>"$scan_lock"
    if ! flock -n 9; then
        log "INFO" "Dispatcher already running (scan lock held) — skipping this invocation"
        exit 0
    fi
    # Lock is held for the lifetime of this process (released on exit automatically)

    # Clean stale locks
    clean_stale_locks

    # If called with a specific file argument
    if [[ $# -gt 0 ]]; then
        local target="$1"
        # If it's just a filename, prepend queue dir
        if [[ "$target" != /* ]]; then
            target="$QUEUE_DIR/$target"
        fi
        if [[ -f "$target" ]]; then
            process_task "$target"
        else
            log "INFO" "Task file not found (likely already picked up): $target"
        fi
        return
    fi

    # Otherwise, process all tasks in queue/ (sorted by priority in filename)
    local tasks=()
    while IFS= read -r -d '' task_file; do
        tasks+=("$task_file")
    done < <(find "$QUEUE_DIR" -name "*.md" -type f -print0 | sort -z)

    if [[ ${#tasks[@]} -eq 0 ]]; then
        log "INFO" "No tasks in queue."
        return 0
    fi

    log "INFO" "Found ${#tasks[@]} task(s) in queue."

    for task_file in "${tasks[@]}"; do
        # Re-check concurrency before each task
        local max_concurrent
        max_concurrent=$(config_get "max_concurrent" "2")
        if [[ $(active_count) -ge $max_concurrent ]]; then
            log "WARN" "Concurrency limit reached. Remaining tasks stay queued."
            break
        fi
        process_task "$task_file"
    done
}

main "$@"
