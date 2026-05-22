#!/usr/bin/env python3
"""
Claude Pipeline — Unified API + Static Server
Serves dashboard UI and handles API endpoints for task management.
Single port, localhost only, zero external dependencies.

Usage: api-server.py [--port 7778] [--host 127.0.0.1]
"""

import http.server
import json
import os
import signal
import subprocess
import sys
import time
import threading
import re
import urllib.request
import urllib.parse
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from http import HTTPStatus

# ─── Configuration ───────────────────────────────────────────────────────────

PIPELINE_DIR = Path.home() / ".claude-pipeline"
DASHBOARD_DIR = PIPELINE_DIR / "dashboard"
QUEUE_DIR = PIPELINE_DIR / "queue"
PENDING_DIR = PIPELINE_DIR / "pending"
ACTIVE_DIR = PIPELINE_DIR / "active"
DONE_DIR = PIPELINE_DIR / "done"
FAILED_DIR = PIPELINE_DIR / "failed"
STATE_DIR = PIPELINE_DIR / "state"
LOGS_DIR = PIPELINE_DIR / "logs"
LOCKS_DIR = PIPELINE_DIR / "locks"
DOCS_DIR = PIPELINE_DIR / "docs"
BIN_DIR = PIPELINE_DIR / "bin"
CONFIG_FILE = PIPELINE_DIR / "config.yml"

STATUS_DIRS = {
    "queue": QUEUE_DIR,
    "pending": PENDING_DIR,
    "active": ACTIVE_DIR,
    "done": DONE_DIR,
    "failed": FAILED_DIR,
}

DEFAULT_PORT = 7778
DEFAULT_HOST = "127.0.0.1"


# ─── Helpers ─────────────────────────────────────────────────────────────────

def read_config():
    """Read pipeline config.yml and return as dict-like accessor."""
    config = {}
    try:
        with open(CONFIG_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if ":" in line and not line.startswith("#"):
                    key, _, val = line.partition(":")
                    val = val.strip().strip('"').strip("'")
                    config[key.strip()] = val
    except FileNotFoundError:
        pass
    return config


def get_repos():
    """Parse repos section from config.yml."""
    repos = {}
    in_repos = False
    try:
        with open(CONFIG_FILE, "r") as f:
            for line in f:
                if line.strip() == "repos:":
                    in_repos = True
                    continue
                if in_repos:
                    if line.strip() and not line.startswith(" ") and not line.startswith("\t"):
                        break
                    if ":" in line:
                        key, _, val = line.strip().partition(":")
                        repos[key.strip()] = val.strip()
    except FileNotFoundError:
        pass
    return repos


def parse_frontmatter(filepath):
    """Parse YAML frontmatter from a markdown file."""
    meta = {}
    try:
        with open(filepath, "r") as f:
            content = f.read()
        if content.startswith("---"):
            parts = content.split("---", 2)
            if len(parts) >= 3:
                for line in parts[1].strip().split("\n"):
                    if ":" in line:
                        key, _, val = line.partition(":")
                        val = val.strip().strip('"').strip("'")
                        meta[key.strip()] = val
                meta["_body"] = parts[2].strip()
            else:
                meta["_body"] = content
        else:
            meta["_body"] = content
    except (FileNotFoundError, IOError):
        pass
    return meta


def get_task_title(filepath):
    """Get the first heading from a task file."""
    try:
        with open(filepath, "r") as f:
            for line in f:
                if line.startswith("#"):
                    return re.sub(r'^#+\s*', '', line.strip())
    except (FileNotFoundError, IOError):
        pass
    return Path(filepath).stem


def find_task_file(name):
    """Find a task file by name (without .md) across all directories."""
    for status, dir_path in STATUS_DIRS.items():
        filepath = dir_path / f"{name}.md"
        if filepath.exists():
            return filepath, status
        # Try partial match
        for f in dir_path.glob("*.md"):
            if f.stem.startswith(name) or name in f.stem:
                return f, status
    return None, None


def get_task_state(name):
    """Read state/current.json for a task."""
    state_file = STATE_DIR / name / "current.json"
    if state_file.exists():
        try:
            with open(state_file, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return {}


def get_task_log(name):
    """Find and read the most recent log file for a task."""
    logs = sorted(LOGS_DIR.glob(f"{name}*.log"), reverse=True)
    if logs:
        try:
            with open(logs[0], "r") as f:
                return f.read()
        except IOError:
            pass
    return ""


def is_pid_alive(pid):
    """Check if a process with given PID is running."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def send_notification(title, message, event_type="complete"):
    """Send Telegram + macOS notification (non-blocking, best-effort)."""
    def _do_notify():
        # ─── Telegram ───
        try:
            # Parse telegram config
            bot_token = ""
            chat_id = ""
            tg_enabled = False
            in_telegram = False
            with open(CONFIG_FILE, "r") as f:
                for line in f:
                    stripped = line.strip()
                    if stripped == "telegram:" or stripped.startswith("telegram:"):
                        in_telegram = True
                        continue
                    if in_telegram:
                        if stripped and not stripped.startswith("#") and not line.startswith(" ") and not line.startswith("\t"):
                            break  # Exited telegram section
                        if "enabled:" in stripped:
                            tg_enabled = "true" in stripped
                        elif "bot_token:" in stripped:
                            bot_token = stripped.split("bot_token:")[-1].strip().strip('"').strip("'")
                        elif "chat_id:" in stripped:
                            chat_id = stripped.split("chat_id:")[-1].strip().strip('"').strip("'")

            if tg_enabled and bot_token and chat_id:
                emoji_map = {"complete": "✅", "failure": "❌", "start": "🚀", "stop": "🛑", "delete": "🗑️", "move": "📦", "retry": "🔄", "resume": "🔄"}
                emoji = emoji_map.get(event_type, "📋")
                timestamp = time.strftime("%Y-%m-%d %H:%M")
                text = f"{emoji} *{title}*\n{message}\n_{timestamp}_"

                data = urllib.parse.urlencode({
                    "chat_id": chat_id,
                    "text": text,
                    "parse_mode": "Markdown"
                }).encode()
                req = urllib.request.Request(
                    f"https://api.telegram.org/bot{bot_token}/sendMessage",
                    data=data
                )
                urllib.request.urlopen(req, timeout=10)
        except Exception:
            pass  # Best-effort, don't crash on notification failure

        # ─── macOS Notification ───
        try:
            subprocess.run(
                ["osascript", "-e", f'display notification "{message}" with title "{title}" sound name "Glass"'],
                capture_output=True, timeout=5
            )
        except Exception:
            pass

    # Run in background thread so we don't block the response
    threading.Thread(target=_do_notify, daemon=True).start()


def get_service_status(name):
    """Check if a service (watcher/telegram) is running."""
    pid_file = LOCKS_DIR / f"{name}.pid"
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            if is_pid_alive(pid):
                return {"running": True, "pid": pid}
        except (ValueError, IOError):
            pass
    return {"running": False, "pid": None}


def generate_task_id():
    """Generate next sequential task ID."""
    max_id = 0
    for dir_path in STATUS_DIRS.values():
        for f in dir_path.glob("*.md"):
            match = re.match(r'^(\d+)', f.stem)
            if match:
                num = int(match.group(1))
                if num > max_id:
                    max_id = num
    return f"{max_id + 1:03d}"


def slugify(text, max_len=30):
    """Convert text to URL-friendly slug."""
    slug = re.sub(r'[^a-z0-9 ]', '', text.lower())
    slug = slug.strip().replace(' ', '-')[:max_len]
    return slug.rstrip('-')


# ─── API Handlers ────────────────────────────────────────────────────────────

def handle_status(handler):
    """GET /api/status — Fresh pipeline status."""
    # Run generate-status.sh for fresh data
    try:
        subprocess.run(
            [str(BIN_DIR / "generate-status.sh")],
            capture_output=True, timeout=10
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    status_file = DASHBOARD_DIR / "status.json"
    if status_file.exists():
        data = json.loads(status_file.read_text())
    else:
        data = {"error": "status.json not found"}

    # Add service statuses
    data["services"] = {
        "watcher": get_service_status("watcher"),
        "telegram_bot": get_service_status("telegram-bot"),
        "dashboard": {"running": True, "pid": os.getpid()},
    }

    return data


def handle_tasks_list(handler):
    """GET /api/tasks — List all tasks with metadata."""
    tasks = []
    for status, dir_path in STATUS_DIRS.items():
        if not dir_path.exists():
            continue
        for f in sorted(dir_path.glob("*.md")):
            name = f.stem
            meta = parse_frontmatter(f)
            state = get_task_state(name)
            title = get_task_title(f)

            task = {
                "name": name,
                "title": title,
                "status": status,
                "type": meta.get("type", "general"),
                "priority": int(meta.get("priority", "5")),
                "repo": meta.get("repo", ""),
                "model": meta.get("model", "sonnet"),
                "source": meta.get("source", "cli"),
                "auto": meta.get("auto", "true") == "true",
            }

            # Add state info
            if state:
                task["session_id"] = state.get("session_id", "")
                task["attempt"] = state.get("attempt", 1)
                task["budget_used"] = state.get("budget_used", 0)
                task["started_at"] = state.get("started_at", "")
                task["resumable"] = state.get("resumable", False)
                task["failure_reason"] = state.get("failure_reason", "")

            # Elapsed time for active tasks
            if status == "active" and state.get("started_at"):
                try:
                    from datetime import datetime
                    started = datetime.fromisoformat(state["started_at"].replace("Z", "+00:00"))
                    elapsed = (datetime.now(started.tzinfo) - started).total_seconds()
                    task["elapsed_s"] = int(elapsed)
                except (ValueError, TypeError):
                    pass

            tasks.append(task)

    # Sort: active first, then by priority desc, then by name
    status_order = {"active": 0, "queue": 1, "pending": 2, "failed": 3, "done": 4}
    tasks.sort(key=lambda t: (status_order.get(t["status"], 5), -t["priority"], t["name"]))

    return {"tasks": tasks}


def handle_task_view(handler, name):
    """GET /api/tasks/<name>/view — Read task file content."""
    filepath, status = find_task_file(name)
    if not filepath:
        return {"error": f"Task '{name}' not found"}, 404

    meta = parse_frontmatter(filepath)
    return {
        "name": filepath.stem,
        "status": status,
        "frontmatter": {k: v for k, v in meta.items() if not k.startswith("_")},
        "body": meta.get("_body", ""),
        "raw": filepath.read_text(),
    }


def handle_task_state(handler, name):
    """GET /api/tasks/<name>/state — Read checkpoint state."""
    state = get_task_state(name)
    if not state:
        return {"error": f"No state for '{name}'"}, 404

    # Include attempts history
    attempts_file = STATE_DIR / name / "attempts.jsonl"
    attempts = []
    if attempts_file.exists():
        for line in attempts_file.read_text().strip().split("\n"):
            if line:
                try:
                    attempts.append(json.loads(line))
                except json.JSONDecodeError:
                    pass

    state["attempts_history"] = attempts
    return state


def handle_task_logs(handler, name):
    """GET /api/tasks/<name>/logs — Read task log."""
    log_content = get_task_log(name)
    if not log_content:
        return {"error": f"No logs for '{name}'"}, 404
    return {"name": name, "log": log_content}


def handle_task_stream_sse(handler, name):
    """GET /api/tasks/<name>/stream — SSE stream of live output."""
    stream_file = STATE_DIR / name / "stream-output.jsonl"
    if not stream_file.exists():
        handler.send_response(404)
        handler.send_header("Content-Type", "application/json")
        handler.end_headers()
        handler.wfile.write(json.dumps({"error": "No stream file"}).encode())
        return None  # Signal already handled

    # Send SSE headers
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Cache-Control", "no-cache")
    handler.send_header("Connection", "keep-alive")
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.end_headers()

    try:
        with open(stream_file, "r") as f:
            # Send existing content as events
            for line in f:
                line = line.strip()
                if line:
                    handler.wfile.write(f"data: {line}\n\n".encode())
                    handler.wfile.flush()

            # Check if task is still active
            task_file, status = find_task_file(name)
            if status != "active":
                handler.wfile.write(b"event: done\ndata: {\"finished\": true}\n\n")
                handler.wfile.flush()
                return None

            # Tail for new events
            while True:
                line = f.readline()
                if line:
                    line = line.strip()
                    if line:
                        handler.wfile.write(f"data: {line}\n\n".encode())
                        handler.wfile.flush()
                else:
                    # Check if task still active
                    task_file, status = find_task_file(name)
                    if status != "active":
                        handler.wfile.write(b"event: done\ndata: {\"finished\": true}\n\n")
                        handler.wfile.flush()
                        break
                    time.sleep(0.3)
    except (BrokenPipeError, ConnectionResetError):
        pass
    return None


def handle_task_create(handler, body):
    """POST /api/tasks/create — Create a new task."""
    description = body.get("description", "").strip()
    if not description:
        return {"error": "Description is required"}, 400

    task_type = body.get("type", "general")
    priority = int(body.get("priority", 5))
    repo = body.get("repo", "")
    auto = body.get("auto", True)
    model = body.get("model", "sonnet")
    timeout = int(body.get("timeout", 600))
    budget = float(body.get("budget", 5.0))

    task_id = generate_task_id()
    slug = slugify(description)
    filename = f"{task_id}-{slug}.md"

    target_dir = QUEUE_DIR if auto else PENDING_DIR
    filepath = target_dir / filename

    # Build task content
    frontmatter = f"""---
type: {task_type}
priority: {priority}
auto: {"true" if auto else "false"}
model: {model}
timeout: {timeout}
budget: {budget:.2f}
source: dashboard
"""
    if repo:
        frontmatter += f"repo: {repo}\n"
    frontmatter += "---\n"

    content = f"""{frontmatter}
# {description}

Task created from web dashboard.

{description}
"""

    filepath.write_text(content)

    send_notification("Pipeline: New Task", f"{filepath.stem} created from dashboard", "start")

    return {
        "success": True,
        "task": {
            "name": filepath.stem,
            "filename": filename,
            "status": "queue" if auto else "pending",
            "path": str(filepath),
        }
    }


def handle_task_action(handler, name, action, body=None):
    """POST /api/tasks/<name>/<action> — Perform action on task."""
    filepath, status = find_task_file(name)
    if not filepath:
        return {"error": f"Task '{name}' not found"}, 404

    actual_name = filepath.stem

    if action == "run":
        # Move pending → queue
        if status != "pending":
            return {"error": f"Can only run pending tasks (currently: {status})"}, 400
        dest = QUEUE_DIR / filepath.name
        filepath.rename(dest)
        # Trigger dispatcher
        subprocess.Popen(
            [str(BIN_DIR / "dispatcher.sh")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        send_notification("Pipeline: Started", f"{actual_name} dispatched from dashboard", "start")
        return {"success": True, "message": f"Task {actual_name} moved to queue and dispatcher triggered"}

    elif action == "retry":
        # Move failed → queue (fresh start)
        if status != "failed":
            return {"error": f"Can only retry failed tasks (currently: {status})"}, 400
        # Remove resume_session from frontmatter
        content = filepath.read_text()
        content = re.sub(r'^resume_session:.*\n', '', content, flags=re.MULTILINE)
        dest = QUEUE_DIR / filepath.name
        dest.write_text(content)
        filepath.unlink()
        # Clear state
        state_file = STATE_DIR / actual_name / "current.json"
        if state_file.exists():
            state = json.loads(state_file.read_text())
            state["resumable"] = False
            state["status"] = "retrying"
            state_file.write_text(json.dumps(state, indent=2))
        subprocess.Popen(
            [str(BIN_DIR / "dispatcher.sh")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        send_notification("Pipeline: Retry", f"{actual_name} queued for fresh retry", "retry")
        return {"success": True, "message": f"Task {actual_name} queued for fresh retry"}

    elif action == "resume":
        # Move failed → queue (keep session)
        if status != "failed":
            return {"error": f"Can only resume failed tasks (currently: {status})"}, 400
        state = get_task_state(actual_name)
        if not state.get("resumable"):
            return {"error": "Task is not resumable"}, 400
        # Add resume_session to frontmatter if not already there
        content = filepath.read_text()
        session_id = state.get("session_id", "")
        if session_id and "resume_session:" not in content:
            content = content.replace("---\n", f"---\nresume_session: {session_id}\n", 1)
        dest = QUEUE_DIR / filepath.name
        dest.write_text(content)
        filepath.unlink()
        subprocess.Popen(
            [str(BIN_DIR / "dispatcher.sh")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        send_notification("Pipeline: Resume", f"{actual_name} resumed with existing session", "resume")
        return {"success": True, "message": f"Task {actual_name} queued for resume"}

    elif action == "stop":
        # Kill running Claude process
        if status != "active":
            return {"error": f"Can only stop active tasks (currently: {status})"}, 400
        lock_file = LOCKS_DIR / f"{actual_name}.lock"
        if lock_file.exists():
            try:
                pid = int(lock_file.read_text().strip())
                os.kill(pid, signal.SIGTERM)
                # Wait a moment, then force kill if needed
                time.sleep(2)
                try:
                    os.kill(pid, signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    pass
                # Move to failed
                dest = FAILED_DIR / filepath.name
                filepath.rename(dest)
                lock_file.unlink(missing_ok=True)
                # Update state
                state_file = STATE_DIR / actual_name / "current.json"
                if state_file.exists():
                    state = json.loads(state_file.read_text())
                    state["status"] = "stopped"
                    state["resumable"] = True
                    state["failure_reason"] = "manual_stop"
                    state_file.write_text(json.dumps(state, indent=2))
                send_notification("Pipeline: Stopped", f"{actual_name} stopped from dashboard", "stop")
                return {"success": True, "message": f"Task {actual_name} stopped"}
            except (ValueError, ProcessLookupError, OSError) as e:
                return {"error": f"Failed to stop: {e}"}, 500
        return {"error": "No lock file found — process may already be dead"}, 400

    elif action == "delete":
        # Remove task file and optionally state
        filepath.unlink()
        # Clean up lock if exists
        lock_file = LOCKS_DIR / f"{actual_name}.lock"
        lock_file.unlink(missing_ok=True)
        # Optionally clean state
        if body and body.get("clean_state"):
            import shutil
            state_dir = STATE_DIR / actual_name
            if state_dir.exists():
                shutil.rmtree(state_dir)
        send_notification("Pipeline: Deleted", f"{actual_name} deleted from dashboard", "delete")
        return {"success": True, "message": f"Task {actual_name} deleted"}

    elif action == "move":
        # Move to specified directory
        target = body.get("to", "") if body else ""
        if target not in STATUS_DIRS:
            return {"error": f"Invalid target: '{target}'. Must be one of: {list(STATUS_DIRS.keys())}"}, 400
        if target == status:
            return {"error": f"Task is already in {status}"}, 400
        dest = STATUS_DIRS[target] / filepath.name
        filepath.rename(dest)
        # Clean lock if moving out of active
        if status == "active":
            lock_file = LOCKS_DIR / f"{actual_name}.lock"
            lock_file.unlink(missing_ok=True)
        # Notify on meaningful transitions
        if target == "done":
            send_notification("Pipeline: Done", f"{actual_name} marked complete from dashboard", "complete")
        elif target == "failed":
            send_notification("Pipeline: Failed", f"{actual_name} moved to failed", "failure")
        return {"success": True, "message": f"Task {actual_name} moved from {status} to {target}"}

    else:
        return {"error": f"Unknown action: {action}"}, 400


def handle_dispatch(handler):
    """POST /api/dispatch — Trigger the dispatcher."""
    subprocess.Popen(
        [str(BIN_DIR / "dispatcher.sh")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    return {"success": True, "message": "Dispatcher triggered"}


def handle_service_action(handler, service, body):
    """POST /api/services/<service> — Start/stop a service."""
    action = body.get("action", "status") if body else "status"

    if service == "watcher":
        script = BIN_DIR / "watcher.sh"
        pid_file = LOCKS_DIR / "watcher.pid"
        log_file = LOGS_DIR / "watcher.log"
    elif service == "telegram":
        script = BIN_DIR / "telegram-bot.sh"
        pid_file = LOCKS_DIR / "telegram-bot.pid"
        log_file = LOGS_DIR / "telegram-bot.log"
    else:
        return {"error": f"Unknown service: {service}"}, 400

    if action == "start":
        # Check if already running
        current = get_service_status(pid_file.stem)
        if current["running"]:
            return {"success": True, "message": f"{service} already running (PID {current['pid']})"}
        # Start in background
        subprocess.Popen(
            ["nohup", str(script)],
            stdout=open(log_file, "a"),
            stderr=subprocess.STDOUT,
            preexec_fn=os.setpgrp
        )
        time.sleep(1)
        new_status = get_service_status(pid_file.stem)
        return {"success": new_status["running"], "pid": new_status.get("pid")}

    elif action == "stop":
        current = get_service_status(pid_file.stem)
        if not current["running"]:
            return {"success": True, "message": f"{service} is not running"}
        os.kill(current["pid"], signal.SIGTERM)
        return {"success": True, "message": f"{service} stopped (PID {current['pid']})"}

    elif action == "status":
        return get_service_status(pid_file.stem)

    return {"error": f"Unknown action: {action}"}, 400


def handle_config(handler):
    """GET /api/config — Return repos and defaults for the UI."""
    repos = get_repos()
    config = read_config()
    return {
        "repos": repos,
        "defaults": {
            "model": config.get("model", "sonnet"),
            "timeout": config.get("timeout", "600"),
            "budget": config.get("budget", "5.00"),
        }
    }


# ─── Request Handler ─────────────────────────────────────────────────────────

class PipelineHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP handler for both static files and API routes."""

    def __init__(self, *args, **kwargs):
        # Set the directory to serve static files from
        super().__init__(*args, directory=str(DASHBOARD_DIR), **kwargs)

    def log_message(self, format, *args):
        """Suppress default logging to stderr."""
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # API routes
        if path.startswith("/api/"):
            self._handle_api_get(path)
            return

        # Serve docs as if they're in dashboard
        if path == "/architecture.html":
            self._serve_file(DOCS_DIR / "architecture.html")
            return

        # Default: serve static files from dashboard/
        super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path.startswith("/api/"):
            self._handle_api_post(path)
            return

        self.send_error(405, "Method not allowed")

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path.startswith("/api/"):
            self._handle_api_post(path)  # Treat same as POST for simplicity
            return

        self.send_error(405, "Method not allowed")

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _read_body(self):
        """Read and parse JSON request body."""
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > 0:
            raw = self.rfile.read(content_length)
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return {}
        return {}

    def _send_json(self, data, status=200):
        """Send JSON response."""
        body = json.dumps(data, indent=2, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_file(self, filepath):
        """Serve a single file."""
        if not filepath.exists():
            self.send_error(404)
            return
        content = filepath.read_bytes()
        self.send_response(200)
        # Guess content type
        if filepath.suffix == ".html":
            ct = "text/html"
        elif filepath.suffix == ".json":
            ct = "application/json"
        elif filepath.suffix == ".js":
            ct = "application/javascript"
        elif filepath.suffix == ".css":
            ct = "text/css"
        else:
            ct = "application/octet-stream"
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _handle_api_get(self, path):
        """Route GET API requests."""
        # /api/status
        if path == "/api/status":
            self._send_json(handle_status(self))
            return

        # /api/tasks
        if path == "/api/tasks":
            self._send_json(handle_tasks_list(self))
            return

        # /api/config
        if path == "/api/config":
            self._send_json(handle_config(self))
            return

        # /api/tasks/<name>/view
        match = re.match(r'^/api/tasks/([^/]+)/view$', path)
        if match:
            result = handle_task_view(self, match.group(1))
            if isinstance(result, tuple):
                self._send_json(result[0], result[1])
            else:
                self._send_json(result)
            return

        # /api/tasks/<name>/state
        match = re.match(r'^/api/tasks/([^/]+)/state$', path)
        if match:
            result = handle_task_state(self, match.group(1))
            if isinstance(result, tuple):
                self._send_json(result[0], result[1])
            else:
                self._send_json(result)
            return

        # /api/tasks/<name>/stream (SSE)
        match = re.match(r'^/api/tasks/([^/]+)/stream$', path)
        if match:
            result = handle_task_stream_sse(self, match.group(1))
            return  # SSE handles its own response

        # /api/tasks/<name>/logs
        match = re.match(r'^/api/tasks/([^/]+)/logs$', path)
        if match:
            result = handle_task_logs(self, match.group(1))
            if isinstance(result, tuple):
                self._send_json(result[0], result[1])
            else:
                self._send_json(result)
            return

        self._send_json({"error": "Not found"}, 404)

    def _handle_api_post(self, path):
        """Route POST API requests."""
        body = self._read_body()

        # /api/tasks/create
        if path == "/api/tasks/create":
            result = handle_task_create(self, body)
            if isinstance(result, tuple):
                self._send_json(result[0], result[1])
            else:
                self._send_json(result)
            return

        # /api/dispatch
        if path == "/api/dispatch":
            self._send_json(handle_dispatch(self))
            return

        # /api/services/<name>
        match = re.match(r'^/api/services/(\w+)$', path)
        if match:
            result = handle_service_action(self, match.group(1), body)
            if isinstance(result, tuple):
                self._send_json(result[0], result[1])
            else:
                self._send_json(result)
            return

        # /api/tasks/<name>/<action>
        match = re.match(r'^/api/tasks/([^/]+)/(\w+)$', path)
        if match:
            name, action = match.group(1), match.group(2)
            result = handle_task_action(self, name, action, body)
            if isinstance(result, tuple):
                self._send_json(result[0], result[1])
            else:
                self._send_json(result)
            return

        self._send_json({"error": "Not found"}, 404)


# ─── Server ──────────────────────────────────────────────────────────────────

class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    """Threaded HTTP server for handling concurrent requests (especially SSE)."""
    allow_reuse_address = True
    daemon_threads = True


def main():
    port = DEFAULT_PORT
    host = DEFAULT_HOST

    # Parse args
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == "--port" and i + 1 < len(args):
            port = int(args[i + 1])
        elif arg == "--host" and i + 1 < len(args):
            host = args[i + 1]

    # Ensure directories exist
    for d in STATUS_DIRS.values():
        d.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    LOCKS_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    server = ThreadedHTTPServer((host, port), PipelineHandler)

    # Write PID file
    pid_file = LOCKS_DIR / "dashboard.pid"
    pid_file.write_text(str(os.getpid()))

    def cleanup(signum, frame):
        pid_file.unlink(missing_ok=True)
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    print(f"Claude Pipeline Dashboard running at http://{host}:{port}/")
    print(f"API available at http://{host}:{port}/api/")
    print(f"PID: {os.getpid()}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        pid_file.unlink(missing_ok=True)
        server.server_close()


if __name__ == "__main__":
    main()
