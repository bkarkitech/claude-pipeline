#!/usr/bin/env bash
# ~/.claude-pipeline/bin/watcher.sh
# Sets up filesystem watching on the queue/ directory.
# Uses watchman for instant detection, falls back to polling.
# This script is kept alive by launchd.

set -euo pipefail

PIPELINE_DIR="$HOME/.claude-pipeline"
QUEUE_DIR="$PIPELINE_DIR/queue"
ACTIVE_DIR="$PIPELINE_DIR/active"
FAILED_DIR="$PIPELINE_DIR/failed"
PENDING_DIR="$PIPELINE_DIR/pending"
DONE_DIR="$PIPELINE_DIR/done"
LOCKS_DIR="$PIPELINE_DIR/locks"
STATE_DIR="$PIPELINE_DIR/state"
DISPATCHER="$PIPELINE_DIR/bin/dispatcher.sh"
LOG_FILE="$PIPELINE_DIR/logs/watcher.log"
PID_FILE="$PIPELINE_DIR/locks/watcher.pid"

# Ensure directories exist
mkdir -p "$PIPELINE_DIR/logs" "$PIPELINE_DIR/locks" "$STATE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHER] $*" >> "$LOG_FILE"
}

# Write PID for management
echo $$ > "$PID_FILE"

# Cleanup on exit
cleanup() {
    log "Watcher stopping (PID $$)"
    rm -f "$PID_FILE"
    # Remove watchman trigger if it exists
    watchman trigger-del "$QUEUE_DIR" task-dispatch 2>/dev/null || true
}
trap cleanup EXIT

log "Watcher starting (PID $$)"

# ─── Orphan Detection ────────────────────────────────────────────────────────
# Detect tasks stuck in active/ whose processes have died (e.g., power loss, crash)
detect_orphans() {
    local orphan_count=0
    for f in "$ACTIVE_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        local task_name
        task_name=$(basename "$f" .md)
        local lock_file="$LOCKS_DIR/${task_name}.lock"

        if [[ -f "$lock_file" ]]; then
            local pid
            pid=$(cat "$lock_file" 2>/dev/null || echo "")
            if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
                # Process is dead — task was interrupted mid-execution
                log "Orphaned task detected: $task_name (pid $pid is dead)"
                orphan_count=$((orphan_count + 1))

                # Update state file if it exists
                local state_file="$STATE_DIR/$task_name/current.json"
                if [[ -f "$state_file" ]]; then
                    local session_id
                    session_id=$(jq -r '.session_id // empty' "$state_file" 2>/dev/null || echo "")

                    jq '.status = "interrupted" | .resumable = true | .failure_reason = "orphaned"' \
                        "$state_file" > "${state_file}.tmp" 2>/dev/null \
                        && mv "${state_file}.tmp" "$state_file"

                    # Write resume_session into task frontmatter
                    if [[ -n "$session_id" ]]; then
                        if grep -q "^resume_session:" <(sed -n '/^---$/,/^---$/p' "$f" 2>/dev/null); then
                            sed -i '' "s/^resume_session:.*/resume_session: $session_id/" "$f"
                        else
                            awk -v sid="$session_id" '
                                BEGIN { count=0 }
                                /^---$/ { count++ }
                                count==2 && /^---$/ { print "resume_session: " sid }
                                { print }
                            ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                        fi
                    fi
                fi

                # Move to failed/
                mv "$f" "$FAILED_DIR/"
                rm -f "$lock_file"

                # Notify
                osascript -e "display notification \"$task_name crashed — resumable with 'pipeline resume'\" with title \"Pipeline: Interrupted\" sound name \"Glass\"" 2>/dev/null || true
            fi
        else
            # No lock file but task in active/ — definitely orphaned
            log "Orphaned task (no lock): $task_name"
            mv "$f" "$FAILED_DIR/"
            orphan_count=$((orphan_count + 1))
        fi
    done

    if [[ $orphan_count -gt 0 ]]; then
        log "Recovered $orphan_count orphaned task(s) to failed/"
    fi
}

# Run orphan detection on startup
detect_orphans

# ─── Try Watchman ─────────────────────────────────────────────────────────────
use_watchman() {
    if ! command -v watchman &>/dev/null; then
        return 1
    fi

    log "Setting up watchman trigger on $QUEUE_DIR"

    # Ensure watchman is watching the queue directory
    watchman watch "$QUEUE_DIR" 2>/dev/null || {
        log "Failed to set watchman watch on $QUEUE_DIR"
        return 1
    }

    # Set up trigger: when a .md file is created, run the dispatcher
    watchman -j <<-EOF
["trigger", "$QUEUE_DIR", {
    "name": "task-dispatch",
    "expression": ["allof",
        ["match", "*.md", "wholename"],
        ["type", "f"]
    ],
    "command": ["$DISPATCHER"],
    "append_files": true,
    "stdin": ["name", "exists", "new"],
    "settle": 2000
}]
EOF

    if [[ $? -eq 0 ]]; then
        log "Watchman trigger configured successfully"
        return 0
    else
        log "Failed to configure watchman trigger"
        return 1
    fi
}

# ─── Polling Fallback ─────────────────────────────────────────────────────────
poll_loop() {
    log "Using polling mode (interval: 5s)"

    local last_check=""
    local last_schedule_check=0

    while true; do
        # Check for new .md files in queue/
        local current_files
        current_files=$(find "$QUEUE_DIR" -name "*.md" -type f 2>/dev/null | sort | md5sum)

        if [[ "$current_files" != "$last_check" && -n "$(find "$QUEUE_DIR" -name "*.md" -type f 2>/dev/null)" ]]; then
            log "New task(s) detected in queue/"
            "$DISPATCHER" &
            last_check="$current_files"
        fi

        # Run scheduler every 60 seconds
        local now
        now=$(date +%s)
        if (( now - last_schedule_check >= 60 )); then
            check_scheduled_tasks
            sweep_stale_active_tasks
            last_schedule_check=$now
        fi

        sleep 5
    done
}

# ─── Stale Task Sweep ────────────────────────────────────────────────────────
# Detects tasks stuck in active/ with no running process and moves them to done/failed
sweep_stale_active_tasks() {
    local active_files
    active_files=$(find "$ACTIVE_DIR" -name "*.md" -type f 2>/dev/null)
    [[ -z "$active_files" ]] && return 0

    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        local task_name
        task_name=$(basename "$f" .md)
        local lock_file="$LOCKS_DIR/${task_name}.lock"
        local state_dir="$STATE_DIR/$task_name"
        local stream_file="$state_dir/stream-output.jsonl"

        # Check if lock file exists and has a valid PID
        if [[ -f "$lock_file" ]]; then
            local lock_pid
            lock_pid=$(cat "$lock_file" 2>/dev/null | grep -oE '[0-9]+' | head -1)
            if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                # Process is still alive — task is legitimately running
                continue
            fi
        fi

        # No live process — check how long it's been stuck
        local state_file="$state_dir/current.json"
        local started_at=""
        if [[ -f "$state_file" ]]; then
            started_at=$(jq -r '.started_at // empty' "$state_file" 2>/dev/null)
        fi

        # If started more than 2 minutes ago with no live process, it's orphaned
        local stale_threshold=120
        if [[ -n "$started_at" ]]; then
            local started_epoch now_epoch age
            started_epoch=$(date -ujf "%Y-%m-%dT%H:%M:%SZ" "$started_at" "+%s" 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            age=$((now_epoch - started_epoch))

            if [[ $age -gt 0 && $age -lt $stale_threshold ]]; then
                # Not stale yet — give it time to start
                continue
            fi
        fi

        # Task is orphaned — check if it produced a result
        local has_result="false"
        if [[ -s "$stream_file" ]]; then
            if grep -q '"type":"result"' "$stream_file" 2>/dev/null; then
                has_result="true"
            fi
        fi

        if [[ "$has_result" == "true" ]]; then
            # Had a result — move to done
            log "Sweeping stale task $task_name → done/ (completed but not cleaned up)"
            jq '.status = "completed" | .resumable = false' "$state_file" > "$state_file.tmp" 2>/dev/null \
                && mv "$state_file.tmp" "$state_file" || true
            mv "$f" "$DONE_DIR/"
        else
            # No result — move to failed
            log "Sweeping stale task $task_name → failed/ (orphaned, no output)"
            jq '.status = "orphaned" | .resumable = false | .failure_reason = "process_died"' \
                "$state_file" > "$state_file.tmp" 2>/dev/null \
                && mv "$state_file.tmp" "$state_file" || true
            mv "$f" "$FAILED_DIR/"
        fi

        # Clean up stale lock
        rm -f "$lock_file"
    done <<< "$active_files"
}

# ─── Scheduled Task Support ──────────────────────────────────────────────────
# Minimal cron expression matcher (5-field: min hour dom month dow)
# Supports: numbers, *, */N, ranges (1-5), comma-separated lists
cron_field_matches() {
    local field="$1"    # cron field expression
    local value="$2"    # current value to check

    # Wildcard matches everything
    if [[ "$field" == "*" ]]; then
        return 0
    fi

    # Step syntax: */N
    if [[ "$field" == *"/"* ]]; then
        local base step
        base="${field%%/*}"
        step="${field##*/}"
        [[ "$base" == "*" ]] && base=0
        if (( (value - base) % step == 0 )); then
            return 0
        fi
        return 1
    fi

    # Comma-separated list
    if [[ "$field" == *","* ]]; then
        IFS=',' read -ra parts <<< "$field"
        for part in "${parts[@]}"; do
            if cron_field_matches "$part" "$value"; then
                return 0
            fi
        done
        return 1
    fi

    # Range: N-M
    if [[ "$field" == *"-"* ]]; then
        local low high
        low="${field%%-*}"
        high="${field##*-}"
        if (( value >= low && value <= high )); then
            return 0
        fi
        return 1
    fi

    # Exact match
    if [[ "$field" == "$value" || "$field" == "$(printf '%02d' "$value")" ]]; then
        return 0
    fi

    return 1
}

cron_matches_now() {
    local cron_expr="$1"

    # Parse 5 fields
    local c_min c_hour c_dom c_month c_dow
    read -r c_min c_hour c_dom c_month c_dow <<< "$cron_expr"

    # Get current time components
    local now_min now_hour now_dom now_month now_dow
    now_min=$(date +%-M)
    now_hour=$(date +%-H)
    now_dom=$(date +%-d)
    now_month=$(date +%-m)
    now_dow=$(date +%u)  # 1=Monday, 7=Sunday

    # Convert Sunday: cron uses 0 or 7 for Sunday
    # Our dow format uses 1-7 (Mon-Sun)
    # Standard cron: 0-6 (Sun-Sat) or 0-7 (Sun-Sat with 7=Sun)
    # Convert to standard: if dow_field contains 7, treat same as 0 (Sunday)

    if cron_field_matches "$c_min" "$now_min" &&
       cron_field_matches "$c_hour" "$now_hour" &&
       cron_field_matches "$c_dom" "$now_dom" &&
       cron_field_matches "$c_month" "$now_month"; then
        # Day-of-week check (convert our 1-7 Mon-Sun to cron's 0-6 Sun-Sat)
        local cron_dow_value
        if [[ $now_dow -eq 7 ]]; then
            cron_dow_value=0
        else
            cron_dow_value=$now_dow
        fi
        if cron_field_matches "$c_dow" "$cron_dow_value"; then
            return 0
        fi
    fi
    return 1
}

check_scheduled_tasks() {
    local schedule_state="$STATE_DIR/.schedules"
    mkdir -p "$schedule_state"

    # Look for tasks in pending/ and done/ with a schedule field
    for dir in "$PENDING_DIR" "$DONE_DIR"; do
        for f in "$dir"/*.md; do
            [[ -f "$f" ]] || continue

            local sched
            sched=$(sed -n '/^---$/,/^---$/p' "$f" 2>/dev/null | grep "^schedule:" | sed 's/schedule:\s*//' | tr -d '"' | tr -d "'" | tr -d '[:space:]' || true)
            [[ -z "$sched" ]] && continue

            local task_name
            task_name=$(basename "$f" .md)
            local last_run_file="$schedule_state/${task_name}.last_run"

            # Check if schedule matches current time
            if cron_matches_now "$sched"; then
                # Check if we already ran this minute (prevent double-execution)
                local current_minute
                current_minute=$(date +%Y%m%d%H%M)
                local last_run_minute=""
                [[ -f "$last_run_file" ]] && last_run_minute=$(cat "$last_run_file" 2>/dev/null)

                if [[ "$current_minute" != "$last_run_minute" ]]; then
                    log "Schedule triggered: $task_name (cron: $sched)"
                    echo "$current_minute" > "$last_run_file"

                    # Create a copy of the task in queue/ (original stays for next schedule)
                    local run_id
                    run_id=$(date +%Y%m%d%H%M)
                    local copy_name="${task_name}-run-${run_id}.md"

                    # Copy task to queue, stripping the schedule field (so it runs once)
                    sed '/^schedule:/d' "$f" > "$QUEUE_DIR/$copy_name"

                    log "Scheduled task queued: $copy_name"

                    # Trigger dispatcher
                    "$DISPATCHER" "$QUEUE_DIR/$copy_name" &
                fi
            fi
        done
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────

# Process any tasks already in queue at startup
if find "$QUEUE_DIR" -name "*.md" -type f 2>/dev/null | grep -q .; then
    log "Processing existing queue items on startup"
    "$DISPATCHER" &
fi

# Try watchman first, fall back to polling
if use_watchman; then
    log "Watchman mode active. Watcher will stay alive for trigger callbacks."
    # In watchman mode, we just need to stay alive so the trigger persists.
    # Also periodically re-check for stuck tasks (watchman settle might miss some).
    last_schedule_check_wm=0
    while true; do
        sleep 30
        # Periodic sweep: process any queue items that watchman might have missed
        if find "$QUEUE_DIR" -name "*.md" -type f 2>/dev/null | grep -q .; then
            log "Periodic sweep: found queued tasks"
            "$DISPATCHER" &
        fi
        # Run scheduler every 60 seconds
        now_wm=$(date +%s)
        if (( now_wm - last_schedule_check_wm >= 60 )); then
            check_scheduled_tasks
            last_schedule_check_wm=$now_wm
        fi
    done
else
    log "Watchman not available, falling back to polling"
    poll_loop
fi
