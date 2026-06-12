# tmux-ai-bar

> Tmux status bar for multi-agent workflows — see which AI agent is busy, done, or idle at a glance.

![tmux-ai-bar preview](./preview.png)

给同时跑多个 AI agent 的 tmux 用户加状态色，一眼看出哪个 agent 在干活、哪个干完了等你 review：

| 状态 | 含义 |
|---|---|
| 🟡 **黄底** | agent 正在产生输出（干活中） |
| 🔴 **红底** | 已静默 ≥8 秒（完成或卡住，等你 review） |
| ⚪ 默认色 | 空闲 / 已 review / 从未活动 |
| Ⓒ Ⓗ Ⓠ 后缀 | Ⓒ=Claude Code，Ⓗ=Hermes，Ⓠ=Qoder CLI（按进程命令行自动识别） |

## 安装

依赖：tmux ≥ 3.0（`brew install tmux`），支持真彩色的终端（iTerm2 / Warp / Ghostty 等）。

```bash
# 1. clone
git clone https://github.com/lijingcheng3359/tmux-ai-bar ~/dev/tmux-ai-bar

# 2. 备份现有配置
[ -e ~/.tmux.conf ] && mv ~/.tmux.conf ~/.tmux.conf.bak.$(date +%Y%m%d)
mkdir -p ~/.tmux

# 3. 软链
ln -s ~/dev/tmux-ai-bar/tmux.conf ~/.tmux.conf
ln -s ~/dev/tmux-ai-bar/agent-poll.sh ~/.tmux/agent-poll.sh

# 4. 启动
tmux kill-server   # 注意：会断已有 session
tmux new -s ai
```

验证 poller 已启动：

```bash
pgrep -f agent-poll.sh   # 应该有 PID
```

## 用法

每个 tmux window 跑一个 agent，切到任意 window 看状态栏：

```
🍓[0:myproject]  [1:api-serverⒸ ]  [2:ml-pipelineⒽ ]  [3:refactorⓆ ]
     ↑ 你在这         ↑ 黄底=干活中       ↑ 红底=等review       ↑ 黄底=干活中
```

哪个先变红就切过去 review。切到 window 会自动清红标（视为已 review）。

**快捷键**（prefix 默认 `Ctrl+J`）：

| 按键 | 功能 |
|---|---|
| `prefix + r` | 重置当前 window 的状态（清 active/done） |
| `prefix + R` | 重新加载 tmux.conf |

## 自定义 agent

编辑 `agent-poll.sh` 中的 `detect_agent` 函数，在 `case` 语句里添加匹配规则：

```bash
case "$cmd" in
  *claude*|*"@anthropic-ai/claude"*) echo "Ⓒ"; return ;;
  *hermes*) echo "Ⓗ"; return ;;
  *qodercli*) echo "Ⓠ"; return ;;
  *your-agent*) echo "Ⓧ"; return ;;   # ← 加在这里
esac
```

注意：函数里有两层相同的 `case`（子进程和孙进程），两处都要加。改完后重启 poller：

```bash
pkill -f agent-poll.sh
tmux source-file ~/.tmux.conf
```

## 可调参数

`agent-poll.sh` 顶部：

```bash
SLEEP_INTERVAL=2       # 主循环周期（秒）
SILENT_THRESHOLD=4     # 4 轮 × 2s = 8 秒静默 → 变红
GROWTH_THRESHOLD=1     # 1 轮有输出 → 变黄
AGENT_DETECT_EVERY=3   # 每 3 轮 = 6 秒做一次 agent 类型检测
```

`tmux.conf` 里可改状态色：

```bash
bg=#ffcc00   # 黄（active）
bg=#ff3b30   # 红（done）
```

## 工作原理

- 后台 `agent-poll.sh` 每 2 秒扫所有 window，通过 `history_bytes` 增长检测输出活动
- 底部 5 行 hash 变化检测原地刷新（spinner/计时器），需连续 2 次才采信（防止休眠唤醒误判）
- `pgrep` + `ps` 遍历 pane 进程树（3 层），按命令行关键字识别 agent 类型
- 切 window 触发 `session-window-changed` hook 自动清 `@done`
- agent 退出需连续 2 次检测不到才确认（防止 fork/exec 间隙误清）

## 已知限制

- shell 内置循环（`for i; echo`）`pane_current_command` 永远是 zsh，不会被识别为 agent
- 短命令（<1 秒）poller 可能抓不到状态变化
- 某些 agent 的 thinking spinner 持续输出 → 始终黄底，不会触发 done

## 注意

`tmux.conf` 包含个人偏好设置（prefix 改 `Ctrl+J`、base-index 从 0 开始、vim mode 等）。如果只需要 agent 状态功能，建议挑选相关配置复制到你自己的 `tmux.conf`。

## License

[MIT](LICENSE)
