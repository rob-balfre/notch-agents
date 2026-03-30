> [!WARNING]
> **Experimental** — This project is in early development. APIs, behaviour, and visual design may change without notice.

# NotchAgents

Native macOS overlay that extends the black of a MacBook Pro notch and shows Codex on the left and Claude on the right. Each side renders a live state indicator:

- spinner while work is running
- tick when work has finished recently
- question bubble when input is required
- count badge when more than one task is active for the same agent

The app reads live local state directly from Codex and Claude when it can, and the companion CLI can still inject or override richer task metadata.

## Build the app bundle

```bash
./scripts/install-app.sh
```

That creates:

```text
build/NotchAgents.app
```

It also installs:

```text
~/Applications/NotchAgents.app
~/.local/bin/notchagentsctl
```

To build and launch it immediately:

```bash
./scripts/install-app.sh --open
```

## Live detection

The app now refreshes primarily from filesystem events instead of a hot polling loop.

Codex state is watched from:

- `~/.codex/state_5.sqlite`
- `~/.codex/.codex-global-state.json`
- `~/.codex/sessions/**/rollout-*.jsonl`

Claude state is watched from:

- `~/.claude/tasks`
- `~/.claude/sessions`
- `~/.claude/projects`

Claude Code hooks are also installed into `~/.claude/settings.json` and write directly into the NotchAgents status snapshot through:

- `~/.local/bin/notchagentsctl claude-hook`

If that state is unavailable or ambiguous, the app falls back to root-process detection for `codex`, `claude`, and `claude-code`.

## Publish task state

Start a task:

```bash
notchagentsctl start --agent codex --id feature-123 --title "Build notch overlay"
```

Mark it as needing an answer:

```bash
notchagentsctl ask \
  --agent claude \
  --id review-9 \
  --title "Review overlay polish" \
  --question "Ship the current visual treatment?" \
  --url "https://example.com/thread/review-9"
```

Finish it:

```bash
notchagentsctl finish --agent codex --id feature-123 --title "Build notch overlay"
```

Wrap a real command so the app tracks it automatically:

```bash
./scripts/run-agent-task.sh \
  codex \
  feature-123 \
  "Build notch overlay" \
  -- \
  codex run
```

Remove it entirely:

```bash
notchagentsctl remove --agent codex --id feature-123
```

Inspect the current snapshot:

```bash
notchagentsctl show
```

Inspect only the live inferred state:

```bash
notchagentsctl live
```

Inspect the merged live + manual state:

```bash
notchagentsctl merged
```

Write sample data:

```bash
notchagentsctl sample
```

Clear everything:

```bash
notchagentsctl clear
```

## Status file

Task state is stored at:

```text
~/Library/Application Support/NotchAgents/status.json
```

The overlay merges live agent state with anything you publish to the status file. Explicit status entries and Claude hook updates override inferred live entries when they use the same task id.

## Interaction

- Click an agent pill to open its `actionURL` when one exists.
- Click anywhere else on the notch wings to open the monitor window.
- Right-click either wing for refresh, sample data, reveal status file, and quit.
