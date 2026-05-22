# Claude Pipeline — Plugin Development Guide

Plugins extend the pipeline with custom task type handlers that can replace, augment, or wrap Claude's execution.

## Directory Structure

```
plugins/
├── your-plugin/
│   ├── plugin.yml      # Plugin metadata and configuration
│   ├── handler.sh      # Main execution script
│   └── validate.sh     # Optional: validate task before execution
```

## Quick Start

```bash
# Create a plugin skeleton
pipeline plugin create my-plugin

# Edit the handler
$EDITOR ~/.claude-pipeline/plugins/my-plugin/handler.sh

# Create a task using your plugin type
pipeline add "my custom task" --type my-plugin
```

## Plugin Manifest (plugin.yml)

```yaml
name: my-plugin
version: 1.0
description: "What this plugin does"
type: my-plugin            # Task type this handles (matches frontmatter type: field)
mode: replace              # Execution mode (see below)

# Optional: fields required in task frontmatter
required_fields:
  - target_env
  - deploy_branch

# Optional: config key this plugin reads from config.yml
config_key: plugins.my-plugin
```

## Execution Modes

| Mode | Behavior |
|------|----------|
| `replace` | handler.sh runs **INSTEAD** of Claude. Full control. |
| `pre` | handler.sh runs **BEFORE** Claude. stdout is prepended to Claude's prompt. |
| `post` | handler.sh runs **AFTER** Claude completes. Receives Claude's output. |
| `wrap` | handler.sh wraps the **ENTIRE** execution. You invoke Claude yourself if needed. |

## Environment Variables

Your handler.sh receives:

| Variable | Description |
|----------|-------------|
| `TASK_NAME` | Name of the task being executed |
| `TASK_FILE` | Path to the task .md file (in active/) |
| `WORK_DIR` | Working directory for the task |
| `STATE_DIR` | State directory (`state/{task}/`) |
| `TASK_BODY` | The task body text (everything after frontmatter) |
| `PIPELINE_DIR` | Root pipeline directory |
| `CLAUDE_BIN` | Path to Claude CLI (useful in `wrap` mode) |

## Exit Codes

- `0` — Success (task moved to done/)
- Non-zero — Failure (task moved to failed/)

## Example: Deploy Plugin

```bash
#!/usr/bin/env bash
# plugins/deploy/handler.sh
set -euo pipefail

# Read custom frontmatter fields
target_env=$(sed -n '/^---$/,/^---$/p' "$TASK_FILE" | grep "^target_env:" | sed 's/target_env:\s*//')
deploy_branch=$(sed -n '/^---$/,/^---$/p' "$TASK_FILE" | grep "^deploy_branch:" | sed 's/deploy_branch:\s*//')

echo "Deploying '$deploy_branch' to '$target_env'..."
cd "$WORK_DIR"
git checkout "$deploy_branch"
git pull origin "$deploy_branch"

# Your deployment logic here
./scripts/deploy.sh "$target_env"

echo "✓ Deploy complete"
```

## Example: Notification-Only Plugin

```bash
#!/usr/bin/env bash
# plugins/notify-only/handler.sh
# Just sends a notification without invoking Claude
set -euo pipefail

echo "Sending notification: $TASK_BODY"
osascript -e "display notification \"$TASK_BODY\" with title \"Pipeline Notification\""
echo "✓ Notification sent"
```

## Tips

- Plugins must be executable: `chmod +x handler.sh`
- Use `mode: pre` to enrich Claude's context (e.g., fetch data from an API)
- Use `mode: post` for cleanup, deployment, or reporting after Claude finishes
- Use `mode: replace` when you don't need Claude at all
- Use `mode: wrap` when you need full control but still want Claude in the middle
