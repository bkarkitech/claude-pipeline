#!/usr/bin/env python3
"""
Live stream viewer for Claude Pipeline tasks.
Parses stream-output.jsonl and displays a formatted, real-time view of what Claude is doing.

Usage: live-stream.py <stream-file> [--follow]
"""

import sys
import json
import time
import os
import signal

# ANSI colors
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
BLUE = "\033[0;34m"
PURPLE = "\033[0;35m"
CYAN = "\033[0;36m"
WHITE = "\033[1;37m"

# Tool icons
TOOL_ICONS = {
    "Bash": "⚙️ ",
    "Read": "📄",
    "Write": "✏️ ",
    "Edit": "✏️ ",
    "Glob": "🔍",
    "Grep": "🔍",
    "Agent": "🤖",
    "WebSearch": "🌐",
    "WebFetch": "🌐",
    "TaskCreate": "📋",
    "TaskUpdate": "📋",
}


def format_duration(ms):
    """Format milliseconds into human-readable duration."""
    if ms < 1000:
        return f"{ms}ms"
    s = ms / 1000
    if s < 60:
        return f"{s:.1f}s"
    m = int(s // 60)
    s = s % 60
    return f"{m}m{s:.0f}s"


def format_cost(cost):
    """Format cost in USD."""
    if cost < 0.01:
        return f"${cost:.4f}"
    return f"${cost:.2f}"


def truncate(text, max_len=120):
    """Truncate text to max length."""
    text = text.replace("\n", " ").strip()
    if len(text) <= max_len:
        return text
    return text[:max_len - 3] + "..."


def get_cols():
    """Get terminal width safely."""
    try:
        return os.get_terminal_size().columns
    except (OSError, ValueError):
        return 80


def print_separator():
    cols = get_cols()
    print(f"{DIM}{'─' * min(cols, 100)}{RESET}")


def print_header(task_name, model, session_id):
    cols = get_cols()
    print(f"{BOLD}{'═' * min(cols, 100)}{RESET}")
    print(f"{BOLD}⚡ Live: {CYAN}{task_name}{RESET}  {DIM}model={model} session={session_id[:8]}...{RESET}")
    print(f"{BOLD}{'═' * min(cols, 100)}{RESET}")
    print()


def process_event(event, state):
    """Process a single stream-json event and print formatted output."""
    event_type = event.get("type", "")
    subtype = event.get("subtype", "")

    if event_type == "system" and subtype == "init":
        model = event.get("model", "unknown")
        session_id = event.get("session_id", "")
        state["model"] = model
        state["session_id"] = session_id
        state["start_time"] = time.time()
        task_name = state.get("task_name", "unknown")
        print_header(task_name, model, session_id)

    elif event_type == "assistant":
        message = event.get("message", {})
        content = message.get("content", [])
        usage = message.get("usage", {})

        # Track tokens
        if usage:
            state["input_tokens"] = usage.get("input_tokens", state.get("input_tokens", 0))
            state["output_tokens"] = state.get("output_tokens", 0) + usage.get("output_tokens", 0)

        for block in content:
            block_type = block.get("type", "")

            if block_type == "text":
                text = block.get("text", "")
                if text.strip():
                    # Print assistant text in white
                    print(f"{WHITE}🤖 Claude:{RESET}")
                    # Print multi-line text with indent
                    for line in text.strip().split("\n"):
                        print(f"   {line}")
                    print()

            elif block_type == "tool_use":
                tool_name = block.get("name", "unknown")
                tool_input = block.get("input", {})
                icon = TOOL_ICONS.get(tool_name, "🔧")

                # Format tool call based on type
                detail = ""
                if tool_name == "Bash":
                    cmd = tool_input.get("command", "")
                    detail = truncate(cmd, 90)
                elif tool_name in ("Read", "Write", "Edit"):
                    path = tool_input.get("file_path", "")
                    # Shorten home dir
                    path = path.replace(os.path.expanduser("~"), "~")
                    detail = path
                    if tool_name == "Edit":
                        old = tool_input.get("old_string", "")
                        if old:
                            detail += f" {DIM}(editing {len(old.splitlines())} lines){RESET}"
                elif tool_name in ("Glob", "Grep"):
                    pattern = tool_input.get("pattern", tool_input.get("query", ""))
                    detail = truncate(pattern, 60)
                elif tool_name == "Agent":
                    desc = tool_input.get("description", "")
                    detail = desc
                elif tool_name == "WebSearch":
                    query = tool_input.get("query", "")
                    detail = f'"{query}"'
                elif tool_name == "WebFetch":
                    url = tool_input.get("url", "")
                    detail = truncate(url, 70)
                else:
                    # Generic: show first key
                    keys = list(tool_input.keys())
                    if keys:
                        first_val = str(tool_input[keys[0]])
                        detail = truncate(f"{keys[0]}={first_val}", 60)

                print(f"  {icon} {YELLOW}{tool_name}{RESET} {DIM}{detail}{RESET}")

            elif block_type == "thinking":
                thinking = block.get("thinking", "")
                if thinking.strip():
                    summary = truncate(thinking, 100)
                    print(f"  {DIM}💭 {summary}{RESET}")

    elif event_type == "result":
        cost = event.get("total_cost_usd", 0)
        duration = event.get("duration_ms", 0)
        turns = event.get("num_turns", 0)
        stop_reason = event.get("stop_reason", "")
        terminal = event.get("terminal_reason", "")

        print()
        print_separator()

        status_icon = "✅" if terminal in ("completed", "") and stop_reason == "end_turn" else "⚠️ "
        status_color = GREEN if status_icon == "✅" else YELLOW

        print(f"{status_color}{status_icon} Finished{RESET}  "
              f"{DIM}duration={format_duration(duration)} | "
              f"cost={format_cost(cost)} | "
              f"turns={turns} | "
              f"stop={stop_reason}{RESET}")

        if terminal and terminal != "completed":
            print(f"  {YELLOW}⚠️  Terminal reason: {terminal}{RESET}")

        # Print result summary
        result_text = event.get("result", "")
        if result_text:
            print()
            print(f"{BOLD}📋 Result:{RESET}")
            lines = result_text.strip().split("\n")
            for line in lines[:30]:
                print(f"   {line}")
            if len(lines) > 30:
                print(f"   {DIM}... ({len(lines) - 30} more lines){RESET}")
        print()

    elif event_type == "system" and subtype == "task_progress":
        # Sub-agent progress
        pass

    elif event_type == "system" and subtype == "task_notification":
        pass


def main():
    if len(sys.argv) < 2:
        print("Usage: live-stream.py <stream-file> [--follow] [--task-name NAME]", file=sys.stderr)
        sys.exit(1)

    stream_file = sys.argv[1]
    follow = "--follow" in sys.argv or "-f" in sys.argv

    task_name = "unknown"
    for i, arg in enumerate(sys.argv):
        if arg == "--task-name" and i + 1 < len(sys.argv):
            task_name = sys.argv[i + 1]

    if not os.path.exists(stream_file):
        print(f"{RED}Error: Stream file not found: {stream_file}{RESET}", file=sys.stderr)
        sys.exit(1)

    state = {"task_name": task_name}

    # Handle Ctrl+C gracefully
    def sig_handler(sig, frame):
        print(f"\n{DIM}[stopped watching]{RESET}")
        sys.exit(0)
    signal.signal(signal.SIGINT, sig_handler)

    # Read existing content
    has_events = False
    with open(stream_file, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
                process_event(event, state)
                has_events = True
            except json.JSONDecodeError:
                pass

    if not has_events:
        # Check if the task is still active or orphaned
        active_dir = os.path.join(os.path.expanduser("~"), ".claude-pipeline", "active")
        is_active = any(
            f.startswith(task_name.split("-")[0])
            for f in os.listdir(active_dir)
        ) if os.path.isdir(active_dir) else False

        if is_active:
            print(f"{YELLOW}⏳ Task is active but has no output yet.{RESET}")
            print(f"{DIM}   The task may be starting up, or the process may have died.{RESET}")
            print()
        else:
            print(f"{DIM}(no stream data recorded for this task){RESET}")
            if not follow:
                return

    if not follow:
        return

    # Follow mode: tail the file for new events
    print(f"{DIM}[watching for updates... Ctrl+C to stop]{RESET}")
    print()

    with open(stream_file, "r") as f:
        # Seek to end
        f.seek(0, 2)
        while True:
            line = f.readline()
            if line:
                line = line.strip()
                if line:
                    try:
                        event = json.loads(line)
                        process_event(event, state)
                    except json.JSONDecodeError:
                        pass
            else:
                # Check if the task is still running (active dir)
                time.sleep(0.3)


if __name__ == "__main__":
    main()
