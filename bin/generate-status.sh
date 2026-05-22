#!/usr/bin/env bash
# ~/.claude-pipeline/bin/generate-status.sh
# Generates dashboard/status.json from filesystem state
# Called by: dispatcher (post-task), watcher (periodic), pipeline dashboard

set -uo pipefail

PIPELINE_DIR="$HOME/.claude-pipeline"
QUEUE_DIR="$PIPELINE_DIR/queue"
PENDING_DIR="$PIPELINE_DIR/pending"
ACTIVE_DIR="$PIPELINE_DIR/active"
DONE_DIR="$PIPELINE_DIR/done"
FAILED_DIR="$PIPELINE_DIR/failed"
STATE_DIR="$PIPELINE_DIR/state"
LOCKS_DIR="$PIPELINE_DIR/locks"
OUTPUT_FILE="$PIPELINE_DIR/dashboard/status.json"

# ─── Helpers ─────────────────────────────────────────────────────────────────

count_files() {
    find "$1" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | xargs
}

get_title() {
    local file="$1"
    grep -m1 "^#" "$file" 2>/dev/null | sed 's/^[#]* *//' || basename "$file" .md
}

get_frontmatter() {
    local file="$1" key="$2" default="${3:-}"
    local value
    value=$(sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | grep -E "^\s*${key}:" | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | xargs)
    echo "${value:-$default}"
}

# ─── Watcher Status ──────────────────────────────────────────────────────────

watcher_pid=""
watcher_running="false"
if [[ -f "$LOCKS_DIR/watcher.pid" ]]; then
    watcher_pid=$(cat "$LOCKS_DIR/watcher.pid" 2>/dev/null)
    if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
        watcher_running="true"
    fi
fi

# ─── Counts ──────────────────────────────────────────────────────────────────

queue_count=$(count_files "$QUEUE_DIR")
active_count=$(count_files "$ACTIVE_DIR")
pending_count=$(count_files "$PENDING_DIR")
done_count=$(count_files "$DONE_DIR")
failed_count=$(count_files "$FAILED_DIR")

# ─── Active Tasks ────────────────────────────────────────────────────────────

active_tasks="[]"
for f in "$ACTIVE_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    local_name=$(basename "$f" .md)
    local_title=$(get_title "$f")
    local_type=$(get_frontmatter "$f" "type" "general")
    local_repo=$(get_frontmatter "$f" "repo" "")
    local_started=""
    local_elapsed=0

    # Check state file for started_at
    if [[ -f "$STATE_DIR/$local_name/current.json" ]]; then
        local_started=$(jq -r '.started_at // ""' "$STATE_DIR/$local_name/current.json" 2>/dev/null)
        if [[ -n "$local_started" ]]; then
            local start_epoch
            start_epoch=$(date -ujf "%Y-%m-%dT%H:%M:%SZ" "$local_started" "+%s" 2>/dev/null || echo "0")
            if [[ "$start_epoch" != "0" ]]; then
                local_elapsed=$(( $(date +%s) - start_epoch ))
            fi
        fi
    fi

    active_tasks=$(echo "$active_tasks" | jq --arg name "$local_name" --arg title "$local_title" \
        --arg type "$local_type" --arg repo "$local_repo" --arg started "$local_started" \
        --argjson elapsed "$local_elapsed" \
        '. + [{"name": $name, "title": $title, "type": $type, "repo": $repo, "started_at": $started, "elapsed_s": $elapsed}]')
done

# ─── Queued Tasks ────────────────────────────────────────────────────────────

queued_tasks="[]"
for f in "$QUEUE_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    local_name=$(basename "$f" .md)
    local_title=$(get_title "$f")
    local_type=$(get_frontmatter "$f" "type" "general")
    local_repo=$(get_frontmatter "$f" "repo" "")
    local_priority=$(get_frontmatter "$f" "priority" "5")

    queued_tasks=$(echo "$queued_tasks" | jq --arg name "$local_name" --arg title "$local_title" \
        --arg type "$local_type" --arg repo "$local_repo" --arg priority "$local_priority" \
        '. + [{"name": $name, "title": $title, "type": $type, "repo": $repo, "priority": $priority}]')
done

# ─── Recent Done (last 10) ──────────────────────────────────────────────────

recent_done="[]"
done_files=$(find "$DONE_DIR" -maxdepth 1 -name "*.md" -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -10)
for f in $done_files; do
    [[ -f "$f" ]] || continue
    local_name=$(basename "$f" .md)
    local_title=$(get_title "$f")
    local_cost=0
    local_duration=0
    local_completed=""

    if [[ -f "$STATE_DIR/$local_name/current.json" ]]; then
        local_cost=$(jq -r '.budget_used // 0' "$STATE_DIR/$local_name/current.json" 2>/dev/null)
        local_completed=$(jq -r '.started_at // ""' "$STATE_DIR/$local_name/current.json" 2>/dev/null)
    fi

    # Get duration from attempts.jsonl (last successful attempt)
    if [[ -f "$STATE_DIR/$local_name/attempts.jsonl" ]]; then
        local_duration=$(tail -1 "$STATE_DIR/$local_name/attempts.jsonl" 2>/dev/null | jq -r '.duration // 0' 2>/dev/null || echo "0")
    fi

    recent_done=$(echo "$recent_done" | jq --arg name "$local_name" --arg title "$local_title" \
        --argjson cost "${local_cost:-0}" --argjson duration "${local_duration:-0}" --arg completed "$local_completed" \
        '. + [{"name": $name, "title": $title, "cost_usd": $cost, "duration_s": $duration, "completed_at": $completed}]')
done

# ─── Recent Failed / Resumable ───────────────────────────────────────────────

recent_failed="[]"
for f in "$FAILED_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    local_name=$(basename "$f" .md)
    local_title=$(get_title "$f")
    local_reason="unknown"
    local_resumable="false"
    local_attempts=0

    if [[ -f "$STATE_DIR/$local_name/current.json" ]]; then
        local_reason=$(jq -r '.failure_reason // "unknown"' "$STATE_DIR/$local_name/current.json" 2>/dev/null || echo "unknown")
        local_resumable=$(jq -r '.resumable // false' "$STATE_DIR/$local_name/current.json" 2>/dev/null || echo "false")
        local_attempts=$(jq -r '.attempt // 0' "$STATE_DIR/$local_name/current.json" 2>/dev/null || echo "0")
    fi

    # Ensure booleans/numbers are valid for jq --argjson
    [[ "$local_resumable" == "true" || "$local_resumable" == "false" ]] || local_resumable="false"
    [[ "$local_attempts" =~ ^[0-9]+$ ]] || local_attempts=0

    recent_failed=$(echo "$recent_failed" | jq --arg name "$local_name" --arg title "$local_title" \
        --arg reason "$local_reason" --argjson resumable "$local_resumable" --argjson attempts "${local_attempts}" \
        '. + [{"name": $name, "title": $title, "reason": $reason, "resumable": $resumable, "attempts": $attempts}]')
done

# ─── Cost Aggregation ────────────────────────────────────────────────────────

total_cost=0
today_cost=0
week_cost=0
cost_task_count=0
today=$(date +%Y-%m-%d)
week_ago=$(date -v-7d +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)

for state_file in "$STATE_DIR"/*/current.json; do
    [[ -f "$state_file" ]] || continue
    cost=$(jq -r '.budget_used // 0' "$state_file" 2>/dev/null)
    started_at=$(jq -r '.started_at // ""' "$state_file" 2>/dev/null)

    [[ "$cost" == "0" || "$cost" == "null" || -z "$cost" ]] && continue

    total_cost=$(echo "$total_cost + $cost" | bc 2>/dev/null || echo "$total_cost")
    cost_task_count=$((cost_task_count + 1))

    if [[ "$started_at" == "$today"* ]]; then
        today_cost=$(echo "$today_cost + $cost" | bc 2>/dev/null || echo "$today_cost")
    fi
    if [[ "$started_at" > "$week_ago" ]]; then
        week_cost=$(echo "$week_cost + $cost" | bc 2>/dev/null || echo "$week_cost")
    fi
done

# Ensure costs have leading zero (bc may omit it for values < 1)
today_cost=$(printf '%s' "$today_cost" | sed 's/^\./0./')
week_cost=$(printf '%s' "$week_cost" | sed 's/^\./0./')
total_cost=$(printf '%s' "$total_cost" | sed 's/^\./0./')

# ─── Assemble JSON ───────────────────────────────────────────────────────────

cat > "$OUTPUT_FILE" <<EOF
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "watcher": {
    "running": $watcher_running,
    "pid": ${watcher_pid:-0}
  },
  "counts": {
    "queue": $queue_count,
    "active": $active_count,
    "pending": $pending_count,
    "done": $done_count,
    "failed": $failed_count
  },
  "active_tasks": $active_tasks,
  "queued_tasks": $queued_tasks,
  "recent_done": $recent_done,
  "recent_failed": $recent_failed,
  "costs": {
    "today_usd": $today_cost,
    "week_usd": $week_cost,
    "all_time_usd": $total_cost,
    "task_count": $cost_task_count
  }
}
EOF
