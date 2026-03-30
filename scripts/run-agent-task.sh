#!/bin/zsh

set -euo pipefail

ROOT_DIR=${0:A:h:h}

if [[ $# -lt 5 ]]; then
    cat <<'EOF'
Usage:
  ./scripts/run-agent-task.sh <codex|claude> <task-id> <title> -- <command...>

Example:
  ./scripts/run-agent-task.sh codex task-42 "Ship overlay" -- codex run
EOF
    exit 1
fi

AGENT=$1
TASK_ID=$2
TITLE=$3
shift 3

if [[ "$1" != "--" ]]; then
    echo "error: use -- before the wrapped command" >&2
    exit 1
fi
shift

if command -v notchagentsctl >/dev/null 2>&1; then
    STATUS_BIN=$(command -v notchagentsctl)
elif [[ -x "$ROOT_DIR/.build/release/notchagentsctl" ]]; then
    STATUS_BIN="$ROOT_DIR/.build/release/notchagentsctl"
elif [[ -x "$ROOT_DIR/.build/debug/notchagentsctl" ]]; then
    STATUS_BIN="$ROOT_DIR/.build/debug/notchagentsctl"
else
    echo "error: notchagentsctl is not installed" >&2
    exit 1
fi

"$STATUS_BIN" start --agent "$AGENT" --id "$TASK_ID" --title "$TITLE"

set +e
"$@"
STATUS=$?
set -e

if [[ $STATUS -eq 0 ]]; then
    "$STATUS_BIN" finish --agent "$AGENT" --id "$TASK_ID" --title "$TITLE"
else
    "$STATUS_BIN" fail \
        --agent "$AGENT" \
        --id "$TASK_ID" \
        --title "$TITLE" \
        --detail "Command exited with status $STATUS"
fi

exit $STATUS
