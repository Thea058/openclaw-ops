# OpenClaw 命令速查

> 版本：**OpenClaw 2026.10.5 (1b58cb9)**
> 来源：服务器 `openclaw --help` 实际输出（2026-10-19）
> 原则：**CLI 语法以 `--help` 为准，不以教程或记忆为准。**
> 层级套路：`openclaw --help` → `openclaw <cmd> --help` → `openclaw <cmd> <sub> --help`

---

## 一、本项目的核心命令

| 用途 | 命令 |
|---|---|
| 查看 Gateway 状态 | `openclaw gateway status` |
| 重启 Gateway | `openclaw gateway restart` |
| 查看模型状态 | `openclaw models status` |
| 列出模型 | `openclaw models list --provider deepseek --refresh` |
| 设默认模型 | `openclaw models set deepseek/deepseek-v4-pro` |
| 管理备用模型 | `openclaw models fallbacks add\|list\|remove\|clear <model>` |
| 配置 API Key | `openclaw models auth paste-api-key --provider deepseek` |
| 发一条消息给 agent | `openclaw agent --message "..."`（**不加** `--deliver` 时只在终端显示） |
| 临时换模型跑一次 | `openclaw agent --model deepseek/deepseek-flash --message "..."` |
| 打印面板 URL（不启动浏览器） | `openclaw dashboard --no-open` |
| 显示 gateway token | `openclaw gateway auth-token --show` |
| 建立隧道（本地执行） | `ssh -N -L 18789:127.0.0.1:18789 openclaw` |
| 搜索插件 | `openclaw plugins search <关键词>` |
| 安装插件 | `openclaw plugins install clawhub:<包名>` |
| 添加渠道 | `openclaw channels add --channel feishu` |
| 渠道状态（真实探测） | `openclaw channels status --probe` |
| 渠道日志 | `openclaw channels logs` |
| 批准配对 | `openclaw pairing approve feishu <配对码>` |
| 健康检查 | `openclaw health` |
| 自动诊断修复 | `openclaw doctor` / `openclaw doctor --fix` |
| 查看文件日志 | `openclaw logs` |
| 搜官方文档 | `openclaw docs <关键词>` |
| 生成 shell 补全 | `openclaw completion` |

---

## 二、完整命令列表（按字母序）

```
acp *                Run an ACP bridge backed by the Gateway
agent *              Run an agent turn via the Gateway (use --local for embedded)
agents *             Manage isolated agents (workspaces + auth + routing)
approvals *          Manage approval policy and pending requests
attach               Attach Claude Code to a gateway session with scoped MCP tools
audit                Inspect activity records and exact-run identity context
automations *        Manage automations (alias for cron)
backup *             Create, verify, and restore backup archives and SQLite snapshots
browser *            Manage OpenClaw's dedicated browser (Chrome/Chromium)
capability *         Run provider capability commands (fallback alias: infer)
channels *           Manage connected chat channels and accounts
chat                 Open a local terminal UI (alias for tui --local)
clawbot *            Legacy clawbot command aliases
completion           Generate shell completion script
config *             Non-interactive config helpers (get/set/patch/unset/file/schema/validate)
configure            Interactive configuration for credentials, channels, gateway, agent defaults
connect              Connect this machine to an OpenClaw Gateway as a node
cron *               Manage automations (via Gateway)
daemon *             Manage the Gateway service (launchd/systemd/schtasks)
dashboard            Open the Control UI with your current token
database *           Inspect database schema compatibility and shared-state write ownership
devices *            Device pairing and auth tokens
directory *          Lookup contact and group IDs for supported chat channels
dns *                DNS helpers for wide-area discovery
docs                 Search the live OpenClaw docs
doctor               Health checks + quick fixes for the gateway and channels
exec-approvals *     Manage exec approvals (alias for approvals)
exec-policy *        Show or synchronize requested exec policy with host approvals
file-transfer *      Review file-transfer standing approvals
gateway *            Run, inspect, and query the WebSocket Gateway
health               Fetch health from the running gateway
hooks *              Manage internal agent hooks
infer *              Run provider-backed inference commands through a stable CLI surface
logs                 Tail gateway file logs via RPC
mcp *                Manage OpenClaw mcp.servers config and channel bridge
memory *             Search, inspect, and reindex memory files
message *            Send, read, and manage messages and channel actions
migrate *            Import state from another agent system
models *             Model discovery, scanning, and configuration
node *               Run and manage the headless node host service
nodes *              Manage gateway-owned nodes
onboard *            Guided setup for auth, models, Gateway, workspace, channels, skills
pairing *            Secure DM pairing (approve inbound requests)
plugins *            Manage OpenClaw plugins and extensions
promos *             Discover and claim promotional model offers from ClawHub
proxy *              Run the OpenClaw debug proxy and inspect captured traffic
qr                   Generate a mobile pairing QR code and setup code
reset                Reset local config/state (keeps the CLI installed)
resume               Resume a recent Gateway session in the TUI
sandbox *            Manage sandbox containers
secrets *            Secrets runtime controls
security *           Audit local config and state for common security foot-guns
sessions *           List stored conversation sessions
setup                Chat with OpenClaw; onboard when setup is incomplete
skills *             List and inspect available skills
status               Show channel health and recent session recipients
storage *            List, initialize, and test configured storage locations
system *             System tools (events, heartbeat, presence)
telemetry *          Inspect and manage anonymous usage telemetry
terminal             Open a local terminal UI (alias for tui --local)
transcripts *        Inspect stored transcripts
triage               Collect sanitized diagnostics and open a local coding agent for repair
tui                  Open a terminal UI connected to the Gateway
uninstall            Uninstall the gateway service + local data
update *             Update OpenClaw and inspect update channel status
users *              Manage durable user profiles and email aliases
webhooks *           Webhook helpers and integrations
worker               Run the restricted cloud worker runtime
worktrees *          Create, inspect, restore, and clean up managed worktrees
```

标注 `*` 的命令有子命令，需再跑 `<cmd> --help`。

---

## 三、官方示例（来自 `openclaw --help`）

```bash
openclaw onboard                 # 引导式配置：Gateway / workspace / auth / channels
openclaw setup --baseline        # 创建基线配置、workspace、session 目录
openclaw configure               # 交互式修改模型 / Gateway / channels / plugins 等
openclaw status                  # Gateway、channel、模型、最近会话状态
openclaw doctor --fix            # 修复常见配置 / 服务 / 插件 / 渠道问题
openclaw channels add            # 添加或更新渠道账号
openclaw channels status         # 查看已连接的消息账号与登录状态
openclaw --dev gateway           # 开发用 Gateway，隔离状态，端口 19001
openclaw gateway run --force     # 启动 Gateway 并抢占端口
openclaw models status           # 运行 agent 前检查模型 / 凭证健康
openclaw plugins list            # 查看已启用 / 禁用 / 已安装插件
openclaw agent --to +15555550123 --message "Run summary" --deliver
openclaw message send --channel telegram --target @mychat --message "Hi"
```

---

## 三之二、`openclaw agent` 参数详解

```
openclaw agent [options] [command]

  --agent <id>               Agent id（覆盖路由绑定）
  --channel <channel>        投递渠道，省略则用主会话渠道
  --deliver                  把回复发回所选渠道（默认 false）
  --local                    用配置的凭证在本地嵌入式运行，绕过 Gateway
  -m, --message <text>       消息正文
  --message-file <path>      从 UTF-8 文件读消息（最大 4 MiB）
  --model <id>               本次运行临时覆盖模型（provider/model）
  --reply-account/-channel/-to   投递目标覆盖
  --session-id / --session-key   指定会话
  -t, --to <number>          E.164 号码，用于派生会话 key
  --thinking <level>         off|minimal|low|medium|high|xhigh|adaptive|max|ultra
  --timeout <seconds>        超时（默认 600 或配置值）
  --verbose <on|off>         会话级详细日志
  --json                     JSON 输出
```

**本项目常用两种：**

```bash
# 只在本机看回复（不发任何渠道）—— 验收测试用这个
openclaw agent --message "你的问题"

# 临时用 flash 跑一次，不改默认
openclaw agent --model deepseek/deepseek-flash --message "你的问题"
```

**别乱加的：**
- `--deliver` —— 会把回复发到渠道，没配好渠道时会失败
- `--local` —— 绕过 Gateway，测不到完整链路

---

## 四、全局选项

| 选项 | 作用 |
|---|---|
| `--profile <name>` | 使用命名 profile，隔离状态目录 |
| `--dev` | 开发模式，状态放 `~/.openclaw-dev`，端口 19001 |
| `--log-level <level>` | silent / fatal / error / warn / info / debug / trace |
| `--no-color` | 关闭 ANSI 颜色（日志重定向时有用） |
| `--container <name>` | 在 Docker/Podman 容器内运行 CLI |
| `-V, --version` | 版本号 |

---

## 五、怎么自己查（别猜）

```bash
openclaw --help                    # 顶层命令
openclaw models --help             # 子命令
openclaw models fallbacks --help   # 孙命令
openclaw docs <关键词>              # 搜在线文档
openclaw completion                # 生成 bash 补全，之后按 Tab 不会拼错
```

`openclaw completion` 值得装——装完按 Tab 自动补全子命令和参数，从根上消灭 `modles` 这类拼写事故。
