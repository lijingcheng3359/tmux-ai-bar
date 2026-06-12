#!/bin/bash
# Background poller for AI-agent status tracking.
# 纯内容（history_bytes）判定 + 检测 pane 内进程类型（@agent_marker）

# 主循环周期 2 秒；阈值按"轮数"计，秒数 = 轮数 × SLEEP_INTERVAL
SLEEP_INTERVAL=2
SILENT_THRESHOLD=4     # 4 轮 × 2s = 8 秒静默 → done
GROWTH_THRESHOLD=1     # 1 轮变化 = 2 秒变化 → active
AGENT_DETECT_EVERY=3   # 每 3 轮 = 6 秒做一次 agent 类型检测（pgrep+ps 较贵）
CAPTURE_EVERY=2        # 每 2 轮 = 4 秒抓一次底部 hash（spinner 检测最贵，占总开销 70%）

# 单实例文件锁：set -C + > 用 O_CREAT|O_EXCL 原子写 pid（一次 syscall，无 mkdir/pid-write race）
LOCKFILE="/tmp/tmux-ai-bar-agent-poll.pid"
if ! (set -C; echo $$ > "$LOCKFILE") 2>/dev/null; then
  old_pid=$(cat "$LOCKFILE" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0   # 已有活实例
  fi
  # stale, 清理后重试一次
  rm -f "$LOCKFILE"
  (set -C; echo $$ > "$LOCKFILE") 2>/dev/null || exit 0
fi
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

# 检测 pane 内是不是某种 agent，返回 marker 字符
# Ⓒ = Claude Code, Ⓗ = Hermes, Ⓠ = Qoder CLI, 其他空
detect_agent() {
  local pane_pid=$1
  # 递归查所有子进程，看 cmdline 里有没有 claude 或 hermes 关键字
  local descendants
  descendants=$(pgrep -P "$pane_pid" 2>/dev/null)
  for pid in $pane_pid $descendants; do
    # macOS ps: -o command 给完整命令行
    local cmd
    cmd=$(ps -p "$pid" -o command= 2>/dev/null)
    case "$cmd" in
      *claude*|*"@anthropic-ai/claude"*) echo "Ⓒ"; return ;;
      *hermes*) echo "Ⓗ"; return ;;
      *qodercli*) echo "Ⓠ"; return ;;
    esac
    # 再下一层
    local subs
    subs=$(pgrep -P "$pid" 2>/dev/null)
    for sub in $subs; do
      cmd=$(ps -p "$sub" -o command= 2>/dev/null)
      case "$cmd" in
        *claude*|*"@anthropic-ai/claude"*) echo "Ⓒ"; return ;;
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

  # 累积所有 window 的 setw 命令，循环结束后一次性 tmux 调用（跨 window 批量）
  all_batch=()

  # 用 process substitution 而非 pipeline，让 while 在主 shell 跑，all_batch 能跨 window 累积
  # 分隔符必须用非空白字符（| 而非 \t）：bash read 对 IFS-whitespace 的连续字符会合并成单个分隔符，
  # 中间字段为空（如 marker 已被清空）时会错位读取，把后面的 miss 读进 marker。
  while IFS='|' read -r wid hb wa ppid lh sc gs was lbh marker miss; do
    [ -z "$wid" ] && continue
    [ -z "$miss" ] && miss=0

    # detect 帧刷新 marker；C/H/Q → "" 走防抖（连续 2 次空才确认 agent 退出，
    # 防止子进程 fork/exec 间隙 ps 暂时看不到 claude/hermes/qodercli 字串而误清状态）
    marker_changed=0
    if [ "$do_agent_detect" = 1 ]; then
      new_marker=$(detect_agent "$ppid")
      if [ "$new_marker" = "$marker" ]; then
        miss=0
      elif [ -z "$new_marker" ] && [ -n "$marker" ]; then
        miss=$((miss + 1))
        if [ "$miss" -ge 2 ]; then
          marker=""
          marker_changed=1
          miss=0
        fi
      else
        # "" → C/H/Q 或 C↔H↔Q：立即认定（无需防抖）
        marker="$new_marker"
        marker_changed=1
        miss=0
      fi
    fi

    per_win=()

    # 纯 shell window：跳过状态机
    # marker 刚被清空时一并清残留（active/done/was 以及 last_*），避免下次重新成 agent 时基于陈旧基线触发误判
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

      # 抓底部 5 行 hash，捕获原地刷新（spinner/计时器）—— 最贵的单项
      # G: hb 增长时已能识别 active，capture 跳过；spinner 检测的真正场景是 hb 停滞期间
      # 的底部刷新（计时器/光标），那时才必须 capture
      if [ "$do_capture" = 1 ] && { [ -z "$lh" ] || [ "$hb" -le "$lh" ]; }; then
        bh=$(tmux capture-pane -p -t "$wid" -S -5 2>/dev/null | cksum | cut -d' ' -f1)
      else
        bh="$lbh"
      fi

      new_active=""; new_done=""; new_was=""

      # history_bytes 增长是强信号，直接算 changed
      # 底部 hash 变化是弱信号（休眠唤醒/reflow 会单次抖动），需连续 2 次才采信
      changed=0
      hb_grew=0
      bhash_changed=0
      [ -n "$lh" ] && [ "$hb" -gt "$lh" ] && { changed=1; hb_grew=1; }
      if [ "$hb_grew" = 0 ] && [ -n "$lbh" ] && [ -n "$bh" ] && [ "$bh" != "$lbh" ]; then
        bhash_changed=1
      fi

      if [ "$changed" = 1 ]; then
        # 强信号：直接递增 streak
        gs=$((gs + 1))
        sc=0
      elif [ "$bhash_changed" = 1 ]; then
        # 弱信号：递增 streak，连续 2 轮 hash 变化才确认 changed
        gs=$((gs + 1))
        sc=0
        [ "$gs" -ge 2 ] && changed=1
      elif [ "$do_capture" = 1 ]; then
        # 本轮做了 capture 但 hash 没变：真正静默，重置 streak
        gs=0
        sc=$((sc + 1))
      else
        # 本轮没做 capture（bh 被设为 lbh）：不可判定，保持 streak 不变
        sc=$((sc + 1))
      fi

      if [ "$changed" = 1 ] && [ "$gs" -ge "$GROWTH_THRESHOLD" ]; then
        new_active=1
        new_done=0
        new_was=1
        was=1
      elif [ "$sc" -ge "$SILENT_THRESHOLD" ]; then
        if [ "$was" = 1 ]; then
          [ "$wa" = 0 ] && new_done=1
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

    # 合并到全局 batch（首条不要前置 ";"）
    if [ ${#per_win[@]} -gt 0 ]; then
      [ ${#all_batch[@]} -gt 0 ] && all_batch+=(";")
      all_batch+=("${per_win[@]}")
    fi
  done < <(tmux list-windows -aF \
    '#{window_id}|#{history_bytes}|#{window_active}|#{pane_pid}|#{E:@last_hbytes}|#{E:@silent_count}|#{E:@growth_streak}|#{E:@was_active}|#{E:@last_bhash}|#{E:@agent_marker}|#{E:@marker_miss}' \
    2>/dev/null)

  # 一次性 tmux 调用：所有 window 的 setw 合到一次 fork（之前是每 window 一次）
  [ ${#all_batch[@]} -gt 0 ] && tmux "${all_batch[@]}" 2>/dev/null

  sleep "$SLEEP_INTERVAL"
done
