#!/bin/bash
# Background poller for AI-agent status tracking.
# Detects activity via history_bytes growth and identifies agent type via process inspection.

# Poll interval in seconds; thresholds are in "rounds" (seconds = rounds x SLEEP_INTERVAL)
SLEEP_INTERVAL=2
SILENT_THRESHOLD=4     # 4 rounds x 2s = 8s silence -> done
GROWTH_THRESHOLD=1     # 1 round of output growth -> active
AGENT_DETECT_EVERY=3   # every 3 rounds = 6s; agent type detection (pgrep+ps is expensive)
CAPTURE_EVERY=2        # every 2 rounds = 4s; bottom-hash capture (most expensive op, ~70% cost)

# Debug logging: record state TRANSITIONS only (not per-round) to pin down which rule
# (silence vs bell) turned a window red. Line-capped retention; flip DEBUG_LOG=0 to disable.
DEBUG_LOG="${DEBUG_LOG:-1}"
LOGFILE="/tmp/tmux-ai-bar-debug.log"
LOG_MAX_LINES=2000     # ~well over an hour of flip events; rotated by tail in the loop

log_event() {
  [ "$DEBUG_LOG" = 1 ] || return 0
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$1" >> "$LOGFILE"
}

# Single instance guard: lockfile holds the PID of the running poller.
# Fast exit if a legitimate poller already owns the lock; otherwise kill orphans and take over.
# Trap only removes the lockfile if it still contains OUR PID (prevents removing a successor's lock).
LOCKFILE="/tmp/tmux-ai-bar-agent-poll.pid"
if [ -f "$LOCKFILE" ]; then
  old_pid=$(cat "$LOCKFILE" 2>/dev/null)
  if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
    case "$(ps -p "$old_pid" -o command= 2>/dev/null)" in
      *agent-poll*) exit 0 ;;
    esac
  fi
fi
for pid in $(pgrep -f 'agent-poll\.sh' 2>/dev/null); do
  [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null
done
sleep 0.2
echo $$ > "$LOCKFILE"
trap '[ "$(cat "$LOCKFILE" 2>/dev/null)" = "$$" ] && rm -f "$LOCKFILE"' EXIT INT TERM

detect_agent() {
  local pane_pid=$1
  local descendants
  descendants=$(pgrep -P "$pane_pid" 2>/dev/null)
  for pid in $pane_pid $descendants; do
    local cmd
    cmd=$(ps -p "$pid" -o command= 2>/dev/null)
    case "$cmd" in
      *claude*|*"@anthropic-ai/claude"*) echo "Ⓒ"; return ;;
      *codex*) echo "Ⓧ"; return ;;
      *gemini*) echo "Ⓖ"; return ;;
      *opencode*) echo "Ⓞ"; return ;;
      *hermes*) echo "Ⓗ"; return ;;
      *qodercli*) echo "Ⓠ"; return ;;
    esac
    # one more level down (grandchild processes)
    local subs
    subs=$(pgrep -P "$pid" 2>/dev/null)
    for sub in $subs; do
      cmd=$(ps -p "$sub" -o command= 2>/dev/null)
      case "$cmd" in
        *claude*|*"@anthropic-ai/claude"*) echo "Ⓒ"; return ;;
        *codex*) echo "Ⓧ"; return ;;
        *gemini*) echo "Ⓖ"; return ;;
        *opencode*) echo "Ⓞ"; return ;;
        *hermes*) echo "Ⓗ"; return ;;
        *qodercli*) echo "Ⓠ"; return ;;
      esac
    done
  done
  echo ""
}

loop_count=0
while tmux info > /dev/null 2>&1; do
  loop_count=$((loop_count + 1))
  do_agent_detect=0
  do_capture=0
  [ $((loop_count % AGENT_DETECT_EVERY)) -eq 0 ] && do_agent_detect=1
  [ $((loop_count % CAPTURE_EVERY)) -eq 0 ] && do_capture=1

  # Rotate debug log every ~60s: keep only the most recent LOG_MAX_LINES lines
  if [ "$DEBUG_LOG" = 1 ] && [ $((loop_count % 30)) -eq 0 ] && [ -f "$LOGFILE" ]; then
    lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
      tail -n "$LOG_MAX_LINES" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
    fi
  fi

  # Accumulate setw commands across all windows, flush in a single tmux call at the end
  all_batch=()

  # Process substitution (not pipeline) keeps while-loop in the main shell so all_batch accumulates.
  # IFS='|' (not whitespace): bash collapses consecutive whitespace delimiters, which misaligns
  # fields when middle values (e.g. marker) are empty.
  while IFS='|' read -r wid hb wa ppid lh sc gs was lbh marker miss cur_active cur_done; do
    [ -z "$wid" ] && continue
    [ -z "$miss" ] && miss=0

    # Debounced marker detection: agent disappearing requires 2 consecutive misses before
    # confirming exit (prevents false clears during fork/exec gaps where ps briefly can't
    # see the agent process)
    marker_changed=0
    if [ "$do_agent_detect" = 1 ]; then
      new_marker=$(detect_agent "$ppid")
      if [ "$new_marker" = "$marker" ]; then
        miss=0
      elif [ -z "$new_marker" ] && [ -n "$marker" ]; then
        miss=$((miss + 1))
        if [ "$miss" -ge 3 ]; then
          marker=""
          marker_changed=1
          miss=0
        fi
      else
        # new agent appeared or type changed: accept immediately
        marker="$new_marker"
        marker_changed=1
        miss=0
      fi
    fi

    per_win=()

    # Plain shell window: skip state machine.
    # When marker is just cleared, also reset stale state to avoid false triggers on next agent.
    if [ -z "$marker" ]; then
      if [ "$marker_changed" = 1 ]; then
        per_win=(setw -t "$wid" @agent_marker ""
                 ";" setw -t "$wid" @active 0
                 ";" setw -t "$wid" @done 0
                 ";" setw -t "$wid" @was_active 0
                 ";" setw -t "$wid" @last_hbytes 0
                 ";" setw -t "$wid" @last_bhash 0
                 ";" setw -t "$wid" @silent_count 0
                 ";" setw -t "$wid" @growth_streak 0
                 ";" setw -t "$wid" @marker_miss 0)
      fi
    else
      [ -z "$sc" ] && sc=0
      [ -z "$gs" ] && gs=0
      [ -z "$was" ] && was=0

      # Hash bottom 5 lines to detect in-place refreshes (spinners, timers).
      # Skip when history_bytes is already growing (strong signal makes this redundant).
      if [ "$do_capture" = 1 ] && { [ -z "$lh" ] || [ "$hb" -le "$lh" ]; }; then
        bh=$(tmux capture-pane -p -t "$wid" -S -5 2>/dev/null | cksum | cut -d' ' -f1)
      else
        bh="$lbh"
      fi

      new_active=""; new_done=""; new_was=""

      # history_bytes growth = strong signal (direct confirmation of output)
      # bottom-hash change = weak signal (sleep/wake reflow can cause single-round flicker);
      # requires 2 consecutive changes to confirm
      changed=0
      hb_grew=0
      bhash_changed=0
      [ -n "$lh" ] && [ "$hb" -gt "$lh" ] && { changed=1; hb_grew=1; }
      if [ "$hb_grew" = 0 ] && [ -n "$lbh" ] && [ -n "$bh" ] && [ "$bh" != "$lbh" ]; then
        bhash_changed=1
      fi

      if [ "$changed" = 1 ]; then
        # strong signal: increment streak directly
        gs=$((gs + 1))
        sc=0
      elif [ "$bhash_changed" = 1 ]; then
        # weak signal: increment streak, confirm only after 2 consecutive hash changes
        gs=$((gs + 1))
        sc=0
        # ...but ONLY trust the bottom-hash to SUSTAIN an already-active agent (was=1).
        # When idle (was=0), a periodic in-place redraw (spinner/clock that never grows
        # history_bytes) must NOT originate a yellow state, or it loops yellow->red forever.
        [ "$gs" -ge 2 ] && [ "$was" = 1 ] && changed=1
      elif [ "$do_capture" = 1 ]; then
        # captured but hash unchanged: truly silent, reset streak
        gs=0
        sc=$((sc + 1))
      else
        # no capture this round (bh set to lbh): indeterminate, keep streak unchanged
        sc=$((sc + 1))
      fi

      if [ "$changed" = 1 ] && [ "$gs" -ge "$GROWTH_THRESHOLD" ]; then
        new_active=1
        new_done=0
        new_was=1
        was=1
        # Log only the 0->1 transition into active (R1), not every active round
        [ "$cur_active" != 1 ] && log_event "win=$wid ACTIVE hb=$hb lhb=$lh gs=$gs"
      elif [ "$sc" -ge "$SILENT_THRESHOLD" ]; then
        if [ "$was" = 1 ]; then
          if [ "$wa" = 0 ]; then
            new_done=1
            # R2: active -> silence transition turned this window red
            [ "$cur_done" != 1 ] && log_event "win=$wid DONE_BY_SILENCE was=$was sc=$sc hb=$hb"
          fi
          new_was=0
        fi
        new_active=0
      fi

      per_win=(setw -t "$wid" @last_hbytes "$hb"
               ";" setw -t "$wid" @last_bhash "$bh"
               ";" setw -t "$wid" @silent_count "$sc"
               ";" setw -t "$wid" @growth_streak "$gs")
      [ -n "$new_active" ] && per_win+=(";" setw -t "$wid" @active "$new_active")
      [ -n "$new_done" ]   && per_win+=(";" setw -t "$wid" @done "$new_done")
      [ -n "$new_was" ]    && per_win+=(";" setw -t "$wid" @was_active "$new_was")
      [ "$marker_changed" = 1 ] && per_win+=(";" setw -t "$wid" @agent_marker "$marker")
      [ "$do_agent_detect" = 1 ] && per_win+=(";" setw -t "$wid" @marker_miss "$miss")
    fi

    # Merge into global batch (no leading ";" for the first entry)
    if [ ${#per_win[@]} -gt 0 ]; then
      [ ${#all_batch[@]} -gt 0 ] && all_batch+=(";")
      all_batch+=("${per_win[@]}")
    fi
  done < <(tmux list-windows -aF \
    '#{window_id}|#{history_bytes}|#{window_active}|#{pane_pid}|#{E:@last_hbytes}|#{E:@silent_count}|#{E:@growth_streak}|#{E:@was_active}|#{E:@last_bhash}|#{E:@agent_marker}|#{E:@marker_miss}|#{E:@active}|#{E:@done}' \
    2>/dev/null)

  # Single tmux call for all windows (previously one fork per window)
  [ ${#all_batch[@]} -gt 0 ] && tmux "${all_batch[@]}" 2>/dev/null

  sleep "$SLEEP_INTERVAL"
done
