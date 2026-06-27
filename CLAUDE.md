# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A tmux status bar that color-codes windows by AI-agent activity (yellow = producing output, red = silent 8s+ / needs review, default = idle). Two files do all the work: `tmux.conf` (display + hooks) and `agent-poll.sh` (background poller). No build step, no dependencies beyond tmux >= 3.0 and a true-color terminal.

## Commands

```bash
# Apply config changes after editing tmux.conf
tmux source-file ~/.tmux.conf            # or `prefix + R` (prefix is Ctrl+J)

# Restart the poller after editing agent-poll.sh (source-file does NOT pick up script changes)
pkill -f agent-poll.sh
tmux source-file ~/.tmux.conf            # tmux.conf relaunches the poller via run-shell

# Confirm the poller is alive (exactly one PID expected — see single-instance guard)
pgrep -f agent-poll.sh

# Inspect live per-window state the poller writes (useful for debugging the state machine)
tmux list-windows -aF '#{window_id} active=#{E:@active} done=#{E:@done} marker=#{E:@agent_marker}'

# Watch the poller's effect without tmux: it only writes user options, so tail them
```

There are no tests, linters, or CI. Verification is manual: run agents in tmux windows and watch the bar transition colors.

## Architecture

The poller and tmux communicate **only** through per-window tmux user options (`@active`, `@done`, `@agent_marker`, etc.). The poller computes state and writes these options; `tmux.conf`'s `window-status-format` strings read them to pick colors. There is no other shared state.

**Data flow each poll round (every `SLEEP_INTERVAL`=2s):**
1. One `tmux list-windows -aF` reads all windows' `history_bytes`, pane PID, and prior `@`-state in a single call (fields delimited by `|`, parsed with `IFS='|'`).
2. Per window, the state machine decides new `@active`/`@done`/`@was_active`.
3. All `setw` writes for all windows are accumulated into one `all_batch` array and flushed in a **single** `tmux` invocation — minimizing forks is a core design constraint.

**Activity detection has two signals:**
- *Strong:* `history_bytes` grew → output happened, accept immediately.
- *Weak:* hash of bottom 5 lines (`capture-pane | cksum`) changed → in-place refresh (spinner/timer). Requires **2 consecutive** changes to confirm, to debounce sleep/wake terminal reflow. Bottom-hash capture is the most expensive op (~70% of cost), gated behind `CAPTURE_EVERY` and skipped entirely when `history_bytes` is already growing.

**Heartbeat-prone agents** (`agent_min_growth()` returns >0 — currently Ⓗ hermes, Ⓠ qodercli): some agents redraw a status/clock line into history while idle, bumping `history_bytes` by a small amount and flickering the bottom hash. Both signals would falsely keep them yellow forever (never red). For these agents: (1) strong signal requires growth **>** the per-agent threshold (filters small heartbeat bumps), (2) it must be **sustained 2 rounds** (`gs>=2`), and (3) the **weak signal is disabled entirely** (so capture-pane is skipped for them too — a cost win). Their real output is many KB and clears the threshold easily. To onboard another such agent, add a case to `agent_min_growth()` with a threshold above its largest idle bump.

**Agent type detection** (`detect_agent`): walks the pane process tree via `pgrep -P` two levels deep (child + grandchild), matches command lines against a `case` statement, emits a circled-letter marker (Ⓒ Ⓧ Ⓖ Ⓞ Ⓗ Ⓠ). The `case` block is **duplicated** for child and grandchild loops — edit both when adding an agent. Gated behind `AGENT_DETECT_EVERY` because `pgrep`+`ps` is expensive.

**Debouncing is pervasive and intentional** — don't remove it without understanding why:
- Agent *disappearing* requires `miss >= 3` consecutive detection misses before clearing `@agent_marker` (fork/exec gaps briefly hide the process).
- When the marker clears, all stale `@`-state is reset together so the next agent in that window starts clean.

**Done-state lifecycle:** poller sets `@done=1` on active→silent transition (inactive windows only). Two tmux hooks in `tmux.conf` also touch it: `alert-bell` sets `@done=1` (Claude rings the bell on completion); `session-window-changed` clears `@done` (switching to a window = reviewed).

**Single-instance guard:** `agent-poll.sh` is safe to launch unconditionally (tmux.conf does so via `run-shell -b`). On start it checks a PID lockfile (`/tmp/tmux-ai-bar-agent-poll.pid`), exits fast if a legit poller owns it, otherwise kills orphans and takes over. The EXIT trap only removes the lockfile if it still holds the current PID.

## When editing

- **Touching the state machine in `agent-poll.sh`:** the `while IFS='|' read` loop runs in the main shell via process substitution (`< <(...)`), *not* a pipeline — this is required so `all_batch` survives across iterations. Keep it that way.
- **Adding tunables:** thresholds at the top of `agent-poll.sh` are in *rounds*, not seconds (seconds = rounds × `SLEEP_INTERVAL`). The README's Configuration table documents them — keep it in sync.
- **`tmux.conf` is also the maintainer's personal config** (Ctrl+J prefix, vim mode, mouse, etc.). The README's "Note" section warns users about this. Don't assume every line relates to the agent feature.
