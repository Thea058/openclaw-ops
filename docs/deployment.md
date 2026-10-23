# OpenClaw 云端部署笔记

> 项目：在云服务器上部署 OpenClaw AI Agent，并接入飞书机器人
> 开始日期：2026-10-16 ｜ 最后更新：2026-10-23
> 目标：掌握 Linux 环境配置与故障排查流程，产出可复现的部署文档

---

## 一、项目目标

独立完成 AI Agent 的云端服务器部署，打通「飞书消息 → AI Agent → 飞书回复」全链路，
并形成可复现的运维文档。

**能力覆盖：** Linux 环境配置 · 服务常驻与开机自启 · 端口管理与冲突排查 · SSH 安全加固 · 日志排查 · 备份策略

## 二、技术选型

| 项目 | 选择 | 理由 |
|---|---|---|
| 服务器 | 腾讯云轻量应用服务器 · 东京(ap-tokyo) · 2核2G · 30M | 国际网络直连；东京属 Anthropic 官方支持地区 |
| 操作系统 | Ubuntu Server 24.04.4 LTS | 标准支持至 2029；生态成熟 |
| 运行时 | Node.js 24 | OpenClaw 要求 Node 22+；**Bun 不可用**（缺 `node:sqlite`） |
| AI 模型 | DeepSeek | 官方插件支持，OpenAI 兼容，价格最低 |
| 消息渠道 | 飞书（国内版） | 官方插件 `@openclaw/feishu` |
| 事件传输 | **WebSocket 长连接** | 关键决策，见下 |

### 选型说明

**为什么选东京而不是内地**

初版方案为内地轻量（更便宜、到飞书延迟仅 10–30ms）。实际购买时改选东京：

- **国际网络直连**：GitHub / Docker Hub / npm 官方源无需配置镜像，减少一类网络干扰
- **保留接入 Claude / OpenAI 的可能**：东京在 Anthropic 官方支持地区列表内
- **代价**：价格略高；到飞书延迟约 40–70ms，聊天场景可接受

**为什么不选香港**

Anthropic 官方支持地区包含新加坡、日本、台湾、韩国，**不含香港、澳门、中国大陆**。
且 Anthropic 在加强跨区检测，香港用户使用 VPN 被封号的案例有公开报道。
若将来切海外，只能选新加坡或日本。

**为什么用长连接而不是 Webhook**

| 模式 | 数据方向 | 需要什么 |
|---|---|---|
| Webhook | 飞书主动 POST 到你的公网地址 | 公网 IP + 域名 + HTTPS 证书 + **ICP 备案** |
| **WebSocket 长连接** | 服务器主动连到飞书 | 只需**出站**连接 |

选长连接后：**不需要域名、不需要备案、不需要证书、入站只开 SSH 一个端口**。
这是整个方案能被简化到"一台服务器 + 一条命令"的根本原因。

## 三、架构

```
  飞书 App              云服务器 (Ubuntu 24.04)
 ┌────────┐        ┌────────────────────────────────┐
 │ 用户消息 │        │ systemd: openclaw-gateway      │
 └───┬────┘        │   ┌────────────────────────┐   │
     │             │   │  OpenClaw Gateway      │   │
     │  ① 长连接   │   │  127.0.0.1:18789       │   │
     │  (出站)     │   └───────┬────────────────┘   │
     └─────────────┼───────────┤                    │
                   │           │ ③ 调用模型 API     │
                   │           ▼                    │
                   │     api.deepseek.com           │
                   └────────────────────────────────┘
                               ▲
                               │ ② SSH 隧道
                               │ ssh -L 18789:127.0.0.1:18789
                         ┌─────┴──────┐
                         │ 你的 Windows │
                         │  浏览器面板  │
                         └────────────┘
```

**三个关键设计点：**

1. **Gateway 只绑定回环地址**（`127.0.0.1`，默认行为）。不暴露公网，面板通过 SSH 隧道访问。
2. **默认端口 18789**，可通过 `gateway.port` 修改。
3. **状态目录 `~/.openclaw/`**，含配置 `openclaw.json` 和工作区，需要备份。

## 四、环境信息

### 本地（Windows 11 + Git Bash）

| 项 | 值 |
|---|---|
| OpenSSH | OpenSSH_10.5p1 |
| 专用私钥 | `~/.ssh/id_ed25519_openclaw` |
| 专用公钥 | `~/.ssh/id_ed25519_openclaw.pub` |
| 公钥指纹 | `<KEY_FINGERPRINT>` |
| SSH 别名 | `ssh openclaw`（配置在 `~/.ssh/config`） |

> 采用**专用密钥**而非复用现有密钥：一个密钥一个用途，出问题时可单独吊销，不影响 GitHub 等其他服务。

### 云服务器

| 项 | 值 |
|---|---|
| 云厂商 | 腾讯云 |
| 产品 | 轻量应用服务器（Lighthouse） |
| 地域 | 东京（ap-tokyo） |
| 实例名称 | <INSTANCE_NAME> |
| 实例 ID | <INSTANCE_ID> |
| 公网 IP | <SERVER_IP> |
| 内网 IP | <PRIVATE_IP>/22 |
| 默认用户 | ubuntu |
| 规格 | 2 核 / 2G / 30 Mbps |
| 系统 | Ubuntu 24.04.4 LTS |
| 主机名 | <HOSTNAME> |
| SSH 端口 | 22（暂不改，见阶段 7 可选项） |

> 服务器上 `ip addr` 看不到公网 IP，只有内网 `<PRIVATE_IP>`。
> 因为腾讯云在服务器外部做了 NAT 映射，公网 IP 不在网卡上——**服务器自己不知道自己的公网 IP**，这是正常现象。

## 五、安全基线（三层关卡）

一个数据包要到达服务，必须依次通过三层：

```
你的电脑
   │
   ▼
① 云防火墙（腾讯云控制台）      不在服务器磁盘上
   │
   ▼
② 主机防火墙 ufw                /etc/ufw/
   │
   ▼
③ 服务监听                      /etc/systemd/system/ssh.socket
                                /etc/ssh/sshd_config
```

| 层 | 组件 | 当前位置 | 状态 |
|---|---|---|---|
| ① | 腾讯云轻量防火墙 | 控制台 → 实例 → 防火墙 → 入站规则 | ✅ 仅放行 22（已删 ALL 和 80） |
| ② | ufw | 服务器 `/etc/ufw/` | ✅ active，仅 22/tcp |
| ③ | sshd | `/etc/systemd/system/` + `/etc/ssh/sshd_config` | ✅ 密钥认证，密码登录关闭，`PermitRootLogin no` |

**排查顺序必须由外向内**：先确认云防火墙 → 再确认 ufw → 最后确认服务在监听。

### 端口占用速查

| 端口 | 用途 | 是否对外开放 |
|---|---|---|
| 22 | SSH 远程登录 | ✅ 唯一放行的入站端口 |
| 80 / 443 | HTTP / HTTPS 网站 | ❌ 已删（本项目不提供网站） |
| 18789 | OpenClaw Gateway | ❌ 不开（走 SSH 隧道） |

## 六、进度

- [x] **阶段 0** 本地准备 —— 工具链确认、生成专用 SSH 密钥
- [ ] **阶段 1** 服务器初始化 + 系统加固
  - [x] 购买实例、绑定 SSH 密钥
  - [x] 关闭密码登录（镜像默认已关）
  - [x] 启用 ufw，仅放行 22
  - [x] 云防火墙收敛：删除 ALL 与 80，仅留 22
  - [x] 禁用 root 登录（`sshd_config.d/99-hardening.conf`）
  - [x] 安装 fail2ban（journal 后端；5 次/10 分钟触发，封禁 1 小时）
  - [ ] 改 SSH 端口（**暂缓至阶段 7**，理由见下）
- [x] **阶段 2** 安装 Node + OpenClaw —— Node 24.22.0 / OpenClaw 2026.10.5 / DeepSeek 插件已装
- [x] **阶段 3** 配置模型 —— DeepSeek key 已写入 auth store；默认 `deepseek/deepseek-v4-pro`，备用 `deepseek/deepseek-flash`；实测调用通过
- [x] **阶段 4** 服务化 —— systemd **用户级**服务 `openclaw-gateway.service`，已 `enable` + `enable-linger`，开机自启、断开 SSH 不退出；**2026-10-21 重启后实测生效**
  - [ ] 端口冲突演练（**顺延至阶段 7**，避免在主干路上制造故障）
- [x] **阶段 5** 本地访问面板 —— SSH 隧道 + gateway token 认证，Control UI 已连通
- [x] **阶段 6** 接入飞书 —— 企业自建应用 + WebSocket 长连接 + pairing 配对，**私聊已通**
- [ ] **阶段 7** 备份与排障
  - [x] 备份脚本 + `--verify` 校验 + **恢复演练通过**（135 个条目）
  - [x] cron 每日 04:17 自动备份，保留 30 天
  - [x] 系统健康检查（内存 / swap / 磁盘 / 安全更新）
    - [x] MOTD 三条告警解读：内存 71% / swap 28% / 9 个待更新
    - [x] 定位内存占用：Gateway 主进程 RSS 1.03G（整机 53%），峰值 1.5G
    - [x] **Swap 扩容 2G** + 写入 fstab + `swapoff` / `swapon -a` 实测
    - [x] **`apt upgrade` 179 个包**，内核 `6.8.0-138 → 147`，重启后实测开机自启
  - [x] 日志检查 + `openclaw doctor`
    - [x] 发现 stale lease（持有进程已死），确认数据库准入异常的根因
    - [x] 三条 warning 逐条判定，其中两条**刻意不修**
  - [ ] 端口冲突故障演练
  - [ ] 改 SSH 端口（可选）

> **为什么暂缓改 SSH 端口**：该操作需要同时协调云防火墙、ufw、ssh.socket 三处，
> 锁死风险高，而实际安全收益有限（主要是减少扫描器噪音）。
> 按"**一次只改一件事、先让主流程跑通再做加固**"的原则，推迟到收尾阶段。

## 七、操作记录

### 阶段 0 · 本地准备（2026-10-16）

```bash
# 生成专用密钥对（不设密码短语，便于自动化；生产环境建议设置）
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_openclaw -N "" -C "openclaw-vps"
```

已确认本地工具链齐全：`ssh` / `ssh-keygen` / `scp`。

### 阶段 1 · 服务器初始化（2026-10-17）

**1. 绑定 SSH 密钥**

腾讯云控制台 → 密钥对 → 创建密钥对 → 导入已有公钥 → 绑定实例。

**2. 启用主机防火墙**

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp          # 必须先放行，再 enable
sudo ufw --force enable
sudo ufw status verbose
```

**3. 收敛云防火墙**

控制台 → 实例 → 防火墙 → 入站规则：删除 `ALL` 和 `HTTP(80)`，保留 `22`。

**4. 外部验证**

```bash
# 从本机测试（结果：80/443 超时，22 可连）
for p in 80 443 22; do
  timeout 8 bash -c "exec 3<>/dev/tcp/<SERVER_IP>/$p" && echo "port $p open" || echo "port $p blocked"
done
```

**5. 禁用 root 登录**

```bash
printf 'PermitRootLogin no\n' | sudo tee /etc/ssh/sshd_config.d/99-hardening.conf
sudo chmod 600 /etc/ssh/sshd_config.d/99-hardening.conf
sudo mkdir -p /run/sshd          # 手动执行 sshd -t 时需要
sudo sshd -t && echo "语法 OK"    # 必须先通过
sudo systemctl restart ssh
systemctl is-active ssh
sudo sshd -T | grep -i permitrootlogin   # 预期 permitrootlogin no
```

**6. 最终验证**

```
ubuntu 新连接      → ✅ 正常
root 登录          → ✅ Permission denied (publickey)
systemctl is-active ssh → active
ss -tlnp | grep :22 → IPv4 + IPv6 各一个
```

**7. 安装 fail2ban**

```bash
sudo apt install -y fail2ban

sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
banaction = ufw
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 22
EOF

sudo fail2ban-client -t          # 配置语法检查
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

**8. 功能验证（关键）**

服务 active ≠ 功能生效。必须实际触发一次失败登录，看计数器是否增加：

```bash
# 从本机制造 1 次失败登录（未达阈值 5，不会被封）
ssh -o BatchMode=yes -i ~/.ssh/<test-key> thisuserdoesnotexist@<SERVER_IP> 'echo x'

# 验证计数器
sudo fail2ban-client status sshd
# → Currently failed: 1   ✅ 捕获成功
```

### 阶段 2 · 安装运行时与 OpenClaw（2026-10-18 ~ 19）

**1. 安装 Node.js 24（NodeSource 源）**

Ubuntu 自带源只有 Node 18，而 OpenClaw 要求 22+，因此引入第三方源：

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
node -v    # v24.22.0
npm  -v    # 11.19.1
```

> ⚠️ **安全提示**：`curl ... | sudo bash` 等于把网上脚本直接交给 root 执行。
> 严谨做法是先下载 → `less` 审阅 → 再执行。本次使用的是官方可信源。

**2. 安装 OpenClaw（全局）**

```bash
sudo npm install -g openclaw@latest
openclaw --version    # OpenClaw 2026.10.5 (1b58cb9)
which openclaw        # /usr/bin/openclaw
```

`-g` = 全局安装，装到 `/usr/lib/node_modules`，可执行文件链接到 `/usr/bin/`，
因此在任何目录都能直接调用 `openclaw`。

**3. 安装 DeepSeek 提供商插件**

DeepSeek **不是内置插件**（内置的 41 个插件里没有），需单独安装：

```bash
openclaw plugins install @openclaw/deepseek-provider
# → Installed plugin: deepseek
# → 安装位置：/home/ubuntu/.openclaw/extensions/deepseek
```

**4. 安装前的前置检查**

| 项 | 结果 | 说明 |
|---|---|---|
| 内存 | 1.9G，可用 1.5G | 够用 |
| Swap | `/swap.img` 1.9G | 云端镜像已预置，无需手动创建 |
| 磁盘 | 50G，已用 5.3G | 充裕 |
| gcc / make / python3 | 13.3.0 / 4.3 / 3.12.3 | 编译原生模块（如 better-sqlite3）所需 |

### 阶段 3 · 配置 DeepSeek 模型（2026-10-19）

**1. 新建专用 API Key**

在 `platform.deepseek.com` → API Keys → 创建，命名 `openclaw-tokyo`。

选专用 key 的理由是**独立吊销**：这把 key 放在公网可访问的服务器上，万一泄露只需删这一把，不影响其他项目的 key。

> ⚠️ **更正**：DeepSeek 的并发与限流是**账号级**的，与使用哪把 key 无关，官方平台也不提供"给单把 key 设额度"的功能。网上声称可以按 key 设配额的教程不可信（[官方文档](https://api-docs.deepseek.com/quick_start/rate_limit/)）。因此新建 key 的价值在于吊销隔离与来源辨识，**不是**花费隔离。

**2. 写入凭证**

```bash
openclaw models auth paste-api-key --provider deepseek
# → Updated config: ~/.openclaw/openclaw.json
# → Backup: ~/.openclaw/openclaw.json.bak
# → Auth profile: deepseek:manual (deepseek/api_key)
# → ⚠️ Warning: 本地 Gateway 未能刷新，需 openclaw gateway restart
```

key 只粘贴到终端提示符，未写入本文档、未进入聊天记录、未提交 Git。

**3. 模型选择**

```bash
openclaw models list --provider deepseek --refresh
# deepseek/deepseek-v4-pro    text        1000k
# deepseek/deepseek-flash     text+image  1000k

openclaw models set deepseek/deepseek-v4-pro
openclaw models fallbacks add deepseek/deepseek-flash
```

| 项 | 选择 | 理由 |
|---|---|---|
| 默认 | `deepseek-v4-pro` | agent 会连续工具调用，弱模型反复重试反而更贵 |
| 备用 | `deepseek-flash` | 主力模型限流/故障时自动降级，服务不中断 |

> **fallback 的边界**：只覆盖**模型级**故障（429 限流、5xx、超时）。key 无效（401）或余额为零时，两个模型共用同一把 key、同一个账户，fallback 无效——那类故障要靠余额监控。

**4. 验收测试（完整链路）**

```bash
openclaw agent --message "9.11 和 9.9 哪个大？用一句话回答"
# → 9.9 更大（正确）

openclaw agent --model deepseek/deepseek-flash --message "这道题你怎么答"
# → 9.9 更大（正确）
```

链路验证：`CLI → Gateway(127.0.0.1:18789) → DeepSeek API → 模型 → 返回`。

### 阶段 4 · 服务化（2026-10-19）

**1. 安装为 systemd 服务**

```bash
openclaw gateway install
# → Installed systemd service: /home/ubuntu/.config/systemd/user/openclaw-gateway.service
# → No gateway token found. Auto-generated one and saving to config.
```

unit 文件位于 `~/.config/systemd/user/`，属于**用户级**服务：

| 路径 | 级别 | 管理命令 |
|---|---|---|
| `/etc/systemd/system/` | 系统级 | `sudo systemctl ...` |
| `~/.config/systemd/user/` | 用户级 | `systemctl --user ...`（不加 sudo） |

**2. 关键一步：启用 linger**

```bash
sudo loginctl enable-linger ubuntu
loginctl show-user ubuntu | grep Linger    # → Linger=yes
```

> ⚠️ **用户级 systemd 服务默认随最后一个登录会话退出而被杀掉。**
> 不开启 linger，SSH 一断开 Gateway 就死，重启后症状表现为 `ECONNREFUSED`，
> 极易误判为配置错误。这是本阶段最容易踩的坑。

**3. 健康状态确认**

```bash
openclaw gateway status
```

关键行：

```
Service: systemd user (enabled)         ← 开机自启已登记
Runtime: running (pid ..., state active, last exit 0, reason 0)
Connectivity check: ok                  ← 不只是进程在，而是能应答
Listening: 127.0.0.1:18789
```

> `state active` 与 `Connectivity check: ok` 是两回事：进程活着但卡死的情况很常见，必须两者都看。

**4. 凭证文件权限**

```bash
ls -l ~/.openclaw/openclaw.json    # → -rw------- (600)
```

`openclaw.json` 与 `openclaw.sqlite` 中同时存有 DeepSeek API Key 和自动生成的 gateway token，均为敏感文件，**禁止 `cat`、截图、备份外传**。

### 阶段 5 · SSH 隧道访问控制面板（2026-10-19）

**1. 为什么必须用隧道**

Gateway 绑定 `127.0.0.1:18789`（回环地址），只有服务器自己能连。这是刻意的安全默认值：若为访问面板而把 18789 开到公网，会立刻招来大量扫描和暴力尝试。

SSH 隧道让"不开端口也能访问"成为可能。

**2. 建立隧道（在本地新终端）**

```powershell
ssh -N -L 18789:127.0.0.1:18789 openclaw
```

`-L` 的三段：

```
-L  本地端口 : 目标主机 : 目标端口
      18789  : 127.0.0.1 : 18789
```

> **关键理解**：`目标主机` 是从**服务器视角**解释的。
> 浏览器访问本地 `127.0.0.1:18789` → 经 SSH 加密通道 → 到达服务器自己的 `127.0.0.1:18789`。
> Gateway 全程未在公网露面。

`-N` = 不执行远程命令，只做端口转发。

> ⚠️ 这个终端窗口必须保持打开。隧道一断，浏览器立刻白屏，且报错信息含糊，容易误判为配置问题。**排障顺序：先确认隧道，再怀疑配置。**

**3. 验证隧道**

```powershell
curl.exe -I http://127.0.0.1:18789/
# → HTTP/1.1 200 OK
```

> 注意 `curl.exe`，不是 `curl`。PowerShell 里 `curl` 是 `Invoke-WebRequest` 的别名（见案例 9）。

**4. 面板认证**

URL 用两种方式取：

```bash
openclaw dashboard --no-open          # 打印带 token 的面板 URL，不启动浏览器
openclaw gateway auth-token --show    # 单独显示 gateway token
```

浏览器若弹出「此 Gateway 需要令牌」，把 `auth-token --show` 的输出粘贴进 **Gateway 密钥** 字段即可。

**5. 响应头里的安全基线**

| 响应头 | 防什么 |
|---|---|
| `X-Frame-Options: DENY` | 禁止被嵌入 iframe，防点击劫持 |
| `Content-Security-Policy: default-src 'self'` | 只加载同源资源，防 XSS |
| `X-Content-Type-Options: nosniff` | 禁止浏览器猜测 MIME 类型 |
| `Referrer-Policy: no-referrer` | 跳转不带来源地址 |

> **运维技巧**：看响应头可快速判断一个 Web 服务有无基本安全意识。四项齐全 = 作者认真配过。

### 阶段 6 · 接入飞书（2026-10-19）

**背景概念**

| 名词 | 含义 |
|---|---|
| 飞书团队 | 组织单位，人与应用都归属某个团队（免费版够用） |
| 企业自建应用 | 自己开发、只给本团队用，无需上架审核 |
| 开放平台 | `open.feishu.cn`，创建和配置应用的地方 |
| 应用身份 | 应用以**自己**为主体操作，只需 App ID + Secret |
| 用户身份 | 代表**某个用户**操作，需 OAuth 授权（本项目不用） |

> 国内版 `feishu.cn` 与国际版 `larksuite.com` 的开放平台**互不相通**，本项目使用国内版。

**1. 安装渠道插件**

```bash
openclaw plugins search feishu
openclaw plugins install clawhub:@openclaw/feishu
# → Installed plugin: feishu
# → Applied in Gateway generation 3.   ← 热加载，无需重启
```

识别官方包的两个依据：`official` 标记，且版本号与 CLI 一致（均为 2026.10.5）。
搜索结果中另有十余个社区插件（`openclaw-feishu-drip`、`@hotwvpyym/openclaw-lark` 等），均未使用。

**2. 飞书开放平台创建应用**

`open.feishu.cn/app` → 创建企业自建应用 → 填名称与描述 → 在「凭证与基础信息」取得：

```
App ID:     <APP_ID>
App Secret: （仅保存在服务器配置中，不入文档）
```

**3. 应用配置四步**

| 步骤 | 位置 | 内容 |
|---|---|---|
| ① 添加能力 | 添加应用能力 | 启用「机器人」 |
| ② 开权限 | 权限管理 | 见下表 |
| ③ 订事件 | 事件与回调 → 事件配置 | 订阅方式选「**使用长连接接收事件**」，添加 `im.message.receive_v1` |
| ④ 发布 | 版本管理与发布 | 创建版本 → 申请发布 → 管理员审核 |

**权限清单（最小权限）**

| 权限 | 用途 | 数据范围 |
|---|---|---|
| `im:message` | 发送消息 | — |
| `im:message.p2p_msg:readonly` | 接收单聊消息 | — |
| `im:message.group_at_msg:readonly` | 接收群内 @机器人消息 | — |
| `im:resource` | 收发图片、文件 | — |
| `contact:user.base:readonly` | 读取用户基础信息 | **全部成员** |

> **`group_at_msg:readonly` vs `group_at_msg.include_bot:readonly`**：后者额外接收**其他机器人**的 @ 消息。不选，原因有三：最小权限、避免 bot 互 @ 形成消息死循环、减少审核阻力。

> **数据范围选「全部成员」**，不选「与应用的可用范围一致」。后者会与第 ④ 步的发布可用范围产生**间接联动**——可用范围设小会导致用户信息查不到，而页面看起来一切正常，属于最难排查的一类故障。初学阶段少一个变量。

**4. 服务器端接入**

```bash
openclaw channels add --channel feishu
```

交互项与选择：

| 提示 | 选择 | 理由 |
|---|---|---|
| App ID | `<APP_ID>` | — |
| App Secret | 粘贴（终端不回显） | 不落文档、不入聊天 |
| Group chat policy | **Allowlist** | 默认安全（白名单为空 = 群内不响应），后续可逐个批准群 |
| Configure DM access policies | **No** | 保持默认 `pairing`，即陌生人首次私聊需管理员批准 |
| Administration from chat | **Skip for now** | 该功能把飞书账号变成服务器管理钥匙，安全强度低于 SSH 密钥 |

**5. 配对批准**

首次私聊时机器人回复 `access not configured` + 配对码：

```bash
openclaw pairing approve feishu PQGM45LL
# → Approved feishu sender ou_409f...
# → Command owner configured feishu:ou_409f... (commands.ownerAllowFrom was empty)
```

> 注意：即使跳过"administration from chat"，**第一个被批准的用户会被自动登记为 `command owner`**。
> 该身份用于识别聊天中管理命令的来源；不改变聊天访问规则（那由 pairing 决定）。
> 由于飞书账号安全强度低于 SSH 密钥，应对该账号启用双因素认证。

**6. 验收**

```bash
openclaw channels status --probe
# - Feishu default: enabled, configured, running, connected, works
```

飞书私聊机器人，收到模型回复 = 全链路打通。

**总结：为什么不需要备案**

```
飞书服务器  ←── 服务器主动发起的 WebSocket 长连接 ───  Gateway（东京）
```

连接方向是**服务器 → 飞书**（出站），飞书不需要回调你的公网地址。因此：

- 不需要域名
- 不需要 ICP 备案
- 不需要 HTTPS 证书
- **不需要在安全组开放任何新端口**（至今仅 22）

若选 Webhook 模式（"将事件发送至开发者服务器"），则上述四项全部需要——这是两种模式最根本的差别。

### 阶段 7 · 备份（2026-10-20）

**为什么必须自己做**

腾讯云**轻量应用服务器不支持自动快照**（CVM 支持）。磁盘损坏、误删或被加密时没有任何兜底。

不可再生的数据全部位于 `~/.openclaw`：

| 文件 | 丢失后果 |
|---|---|
| `openclaw.json` | 模型配置、gateway token、渠道配置全丢 |
| `state/openclaw.sqlite` | DeepSeek Key、飞书凭证、会话全丢 |
| `agents/` | agent 工作区与记忆 |

**1. 先演练，再执行**

```bash
openclaw backup create --dry-run --json
```

dry-run 显示只备份 `~/.openclaw` 一个资产，其余标记跳过：

- `covered`：workspace、agent 目录已在 `~/.openclaw` 内，不重复打包
- `regenerable`：`extensions/*/node_modules`、`plugin-skills`、`tmp`，可重新生成

**2. 生成并校验**

```bash
mkdir -p ~/backups/openclaw && chmod 700 ~/backups/openclaw

openclaw backup create --output /home/ubuntu/backups/openclaw --verify
# → Archive verification: passed
```

> ⚠️ **`--keep-daily` / `--keep-weekly` / `--namespace` 只能配合 `--to <location>` 使用**，本地 `--output` 不支持：
> `--namespace, --claim-namespace, and retention flags require --to <location>.`
>
> 本地保留策略由脚本中的 `find -mtime +30 -delete` 自行实现。
> 选择按**时间**清理而非"保留 N 份"：备份失败时不会误删唯一可用的旧备份。

**3. 恢复演练（关键）**

```bash
openclaw backup restore ~/backups/openclaw/<归档>.tar.gz --target /tmp/openclaw-restore-test

find /tmp/openclaw-restore-test -name "openclaw.json" -o -name "openclaw.sqlite"
```

结果：**135 个条目恢复成功**，两个关键文件均在。

> ⚠️ `--target` 必须是**不存在或空目录**，非空会被拒绝。
> ⚠️ `ls -R` 默认不显示点文件，`.openclaw` 不会出现在输出里——需用 `ls -la`。
> 这是"文件不见了"类误判的常见来源。

**4. 恢复的边界（Rollback warnings）**

| 警告 | 含义 |
|---|---|
| 恢复即"时间旅行" | 所有状态回滚到归档时刻，之后的数据全部丢失 |
| 审批与投递状态也回滚 | 备份后批准的 pairing 需重新批准 |
| 插件 node_modules 未归档 | 恢复后需 `openclaw plugins install <spec> --force` |
| plugin-skills 链接未归档 | 恢复后需重新生成 |
| 渠道凭证可能失步 | WhatsApp 类受影响；**飞书不受影响** |

> **RPO（Recovery Point Objective）**：备份不是"不丢数据"，而是"最多丢一个备份周期的数据"。
> 每天备份 = RPO 约 24 小时。改动重要配置后可手动补跑一次，把 RPO 缩短到分钟级。

**5. 自动化脚本**

`~/bin/backup-openclaw.sh`（权限 `700`）：

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/home/ubuntu/backups/openclaw"
LOG="$BACKUP_DIR/backup.log"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "[$(date -Iseconds)] backup start" >> "$LOG"
/usr/bin/openclaw backup create --output "$BACKUP_DIR" --verify >> "$LOG" 2>&1
echo "[$(date -Iseconds)] backup done" >> "$LOG"

find "$BACKUP_DIR" -name '*.tar.gz' -mtime +30 -delete
echo "[$(date -Iseconds)] prune done" >> "$LOG"
```

> 写入时使用 `<<'EOF'`（带单引号），阻止 shell 提前展开 `$(date ...)`，使其在**运行时**求值。

**6. cron**

```
17 4 * * * /home/ubuntu/bin/backup-openclaw.sh
```

- 分钟选 17 而非 0，避开整点任务高峰
- **必须用绝对路径**：cron 的环境变量极简，`PATH` 不含 `~/.local/bin` 等
- **先手动执行一次再交给 cron**，否则失败时只能在系统日志里看到 `command not found`

**验证：**

```bash
crontab -l
ls -l ~/bin/backup-openclaw.sh    # -rwx------ 441 bytes
cat ~/backups/openclaw/backup.log # start / done / prune done 三行齐全
```

**备份包的安全等级等于服务器本身**——内含 DeepSeek Key、飞书 App Secret、gateway token。目录 `700`、归档 `600`，禁止上传网盘或提交 Git。

### 阶段 7-1 · 系统健康检查（2026-10-21）

**登录 banner 的三条告警从哪来**

banner 不是系统报错，是 Ubuntu 的 **MOTD**（登录时按序执行 `/etc/update-motd.d/` 下的脚本）：

| 告警 | 来源脚本 |
|---|---|
| `Memory usage: 71%` / `Swap usage: 53%` | `/etc/update-motd.d/50-landscape-sysinfo` |
| `211 updates can be applied immediately` | `/etc/update-motd.d/90-updates-available` |

MOTD 只负责**展示**，不做任何处理。看到告警 ≠ 系统故障，但长期忽略会累积风险。

**1. 判断"内存高"是真问题还是假问题**

关键：**swap 被占用 ≠ 正在换页。**

```bash
free -h
swapon --show
vmstat 1 5
```

实测输出：

```
               total        used        free      shared  buff/cache   available
Mem:           1.9Gi       1.5Gi       373Mi       1.5Mi       240Mi       442Mi
Swap:          1.9Gi       1.0Gi       981Mi
```

```
procs -----------memory---------- ---swap-- -----io---- -system- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 2  0 1030940 380960   8004 238964   10   11    31    88  847    5  1  1 98  0  0  0
 0  0 1030940 380960   8004 239008    4    0     4     0 1054 1131  1  1 98  0  0  0
 0  0 1030940 380960   8004 239012    0    0     0     0  816  842  2  0 98  0  0  0
```

判读要点：

| 指标 | 读数 | 结论 |
|---|---|---|
| `si` / `so`（换入 / 换出） | 首行 10/11（开机以来均值），之后全 0 | **没有活跃换页** |
| `id`（CPU 空闲） | 98 | 没有计算压力 |
| `wa`（IO 等待） | 0 | 磁盘不堵 |
| `buff/cache` | 仅 240Mi | 偏低，说明内存紧张时缓存被回收过 |

> **那 1G swap 是过去换出去、之后一直没被访问的闲置页。**
> 只看 `Swap usage` 的百分比会误判为"内存不够用"，必须结合 `si` / `so` 才能区分"占用"和"正在用"。

**2. 定位谁在吃内存**

```bash
ps -eo pid,comm,%mem,rss --sort=-rss | head -12
systemctl --user status openclaw-gateway --no-pager | head -20
```

结果：

| 进程 | RSS | 占比 |
|---|---|---|
| `node .../openclaw ... gateway`（pid 725234） | 1,078,512 KB ≈ **1.03G** | 53.5% |
| `YDService`（腾讯云 agent） | 59 MB | 2.9% |
| 其余（journald / multipathd / fail2ban / barad_agent） | 均 < 30 MB | — |
| Gateway 的 4 个 node 子进程 | 合计约 80 MB | — |

`systemctl --user status` 同时给出 cgroup 口径：

```
Memory: 1.1G (peak: 1.5G swap: 975.4M swap peak: 1.0G)
```

**结论：内存告警几乎全部来自 Gateway 本身，不是配置错误，是容量问题。**
峰值 1.5G 已占 1.9G 物理内存的 79%，所以约 1G 被挤出到 swap。

**3. 顺带确认堆上限不是配错**

`gateway status` 里有一行：

```
Gateway heap: service argv: --max-old-space-size=1475;
installer recommendation: 1475 MiB old space (1967 MiB physical capacity; ...)
```

**1475 是 OpenClaw 安装器按物理内存自动算出的推荐值，不是人为设错。** 因此不调整堆上限——把它调小只是把「内核 OOM」换成「Node 堆溢出崩溃」，没有解决问题。

**4. 决策：加 swap 作为兜底**

| 方案 | 成本 | 效果 | 结论 |
|---|---|---|---|
| 加 2G swap | 0 元 | 峰值时防止 OOM killer，代价是慢 | ✅ 采用 |
| 降堆上限到 1024 | 0 元 | 更早 GC，延迟可能变差 | ❌ 不采用 |
| 升配到 4G | 花钱 | 根治 | 以后再说 |
| 定时重启 | 0 元 | 掩盖问题 | ❌ 不采用 |

```bash
sudo fallocate -l 2G /swap2.img      # 注意是小写字母 l，不是数字 1
ls -lh /swap2.img
sudo chmod 600 /swap2.img            # 必须在 mkswap 之前
ls -l /swap2.img                     # 期望 -rw-------
sudo mkswap /swap2.img
sudo swapon /swap2.img
free -h                              # Swap 总量应变为 3.9Gi
swapon --show
```

**5. 写入 fstab，并当场验证**

```bash
sudo cp /etc/fstab /etc/fstab.bak    # 改 fstab 前必须备份
echo '/swap2.img none swap sw 0 0' | sudo tee -a /etc/fstab
tail -3 /etc/fstab
```

> 用 `| sudo tee -a`，不要用 `sudo echo ... >>`：重定向由当前用户的 shell 在 `sudo` 之前处理，权限不够会静默失败。

**不等重启才验证**——手动关掉，再让它按 fstab 自动挂回来：

```bash
sudo swapoff /swap2.img
swapon --show                        # 应只剩 /swap.img
sudo swapon -a                       # 按 fstab 启用全部 swap
swapon --show                        # /swap2.img 应回来
```

`swapon -a` 能从 fstab 重新挂上，才证明重启后也能挂上。fstab 写错会导致开机进 emergency mode，所以必须在**还能回滚的时候**验证。

### 阶段 7-2 · 系统更新与重启验证（2026-10-21）

**1. 升级前检查**

```bash
sudo apt update
sudo apt-get -s upgrade | grep -E "^[0-9]+ upgraded|^Remv|will be REMOVED"
apt list --upgradable 2>/dev/null | grep -iE "linux-image|linux-generic"
```

结果：

```
179 upgraded, 0 newly installed, 0 to remove and 5 not upgraded.
linux-generic/noble-updates,noble-security 6.8.0-147.147 [upgradable from: 6.8.0-138.138]
```

- `0 to remove` → 可以安全执行
- `5 not upgraded` → Ubuntu 的**分阶段推送**（phased updates），不是故障
- **有内核更新** → 升级后必须重启

**2. 升级前补一次备份**

```bash
~/bin/backup-openclaw.sh
tail -5 ~/backups/openclaw/backup.log
# → Archive verification: passed
```

**3. 在 tmux 里执行**

```bash
tmux new -s upgrade
sudo NEEDRESTART_MODE=l apt upgrade -y
```

- `tmux`：179 个包要跑十几分钟，SSH 断了会话仍在
- `NEEDRESTART_MODE=l`：让 needrestart **只列清单、不自动重启服务**，避免升级过程中 sshd 被意外重启

升级过程中会遇到两个交互界面，见案例 12 与案例 13。

**4. 确认内核已换、但未生效**

```bash
sudo needrestart -r l
uname -r
ls /boot/vmlinuz-*
```

```
6.8.0-138-generic                 ← 内存里跑的
/boot/vmlinuz-6.8.0-138-generic
/boot/vmlinuz-6.8.0-147-generic   ← 磁盘上新装的
```

**这个不一致就是"必须重启"的直接证据。** 运行中的内核是开机时加载进内存的，替换磁盘文件不会改变它。

**5. 重启，并验证开机自启（关键实证）**

```bash
sudo reboot
```

重连后：

```bash
uname -r
systemctl --user is-enabled openclaw-gateway
loginctl show-user ubuntu | grep Linger
openclaw gateway status
free -h
swapon --show
```

全部通过：

| 检查 | 结果 | 证明了什么 |
|---|---|---|
| `uname -r` | `6.8.0-147-generic` | 新内核已生效 |
| `is-enabled` | `enabled` | 开机自启已登记 |
| `Linger` | `yes` | 不随登录会话退出 |
| `Runtime` | `running (pid 3617, state active, last exit 0)` | **冷启动后自己起来了**（pid 很小，说明是开机时启动的） |
| `Connectivity check` | `ok` | 不只是进程活着，能应答 |
| `swapon --show` | 两个文件都在 | fstab 写对了 |

> 这是本项目**第一次真正验证「开机自启」**。之前只是 `enable` 过，从没经历过冷启动。
> 重启后 Swap used 从 1.0G 降到 418M，进一步印证之前那 1G 是闲置换出页。

**6. 升级后的状态**

- 系统点版本：`24.04.4 → 24.04.5`
- 可升级包：`211 → 9`（新发布的，属正常节奏）
- `unattended-upgrades`：`enabled + active`，但升级前仍堆积 137 个安全更新——**服务 active ≠ 功能生效**，与 fail2ban 那次同源

### 阶段 7-3 · doctor 体检（2026-10-23）

```bash
openclaw gateway status 2>&1 | grep -A1 "Config"
openclaw doctor
```

**doctor 会先暂停 Gateway，结束时恢复原状态**（`Doctor restores its prior service state when finished`），暂停期间只影响渠道机器人，不影响 SSH。

**1. 发现了数据库异常的根因**

```
[state/agent-db] agent database stale lease: owner-pid-dead;
                 previous release not observed
[state/agent-db] integrityGateReason=stale-lease-full
```

**stale lease = 数据库里有一个过期租约，持有它的进程已经死了。**

这一条解释了此前出现的全部症状：

| 现象 | 由 stale lease 解释 |
|---|---|
| `read admission is closed` | 新进程拿不到读取准入，租约被死进程占着 |
| `hostAdmissionWaitMs=1686` | 事务在等准入，不是 SQL 慢 |
| `[sqlite/transaction] slow SQLite transaction hold` | 同上 |
| 进程 PID 反复变化 | 旧进程异常退出，重启产生新进程 |

根因是**进程被强制结束时没释放租约**。doctor 的完整性检查（`integrity gate`）会清理这类残留。

**2. 三条 warning 的处置**

| Warning | 处置 | 理由 |
|---|---|---|
| `channels.feishu.groupPolicy is "allowlist" but groupAllowFrom is empty` | **不修** | 这正是选定的安全策略：群消息默认静默丢弃。要用群聊时再添加具体发送者 ID |
| `core/doctor/node-hosting-preconditions gateway.bind`（只监听回环） | **不修** | 这是刻意设计。doctor 建议的 `bind=lan` / 公网 origin / tailscale 都会让 Gateway 暴露，违背整个方案 |
| `OAuth dir not present` | **不修** | 没有 WhatsApp / pairing 渠道，不需要 |

> **重要判断：不是所有 warning 都要消除。**
> doctor 按"通用最佳实践"给建议，它不知道你的架构选择。`bind` 那条建议对"远程设备接入 Gateway"的场景成立，对"SSH 隧道访问、绝不暴露公网"的方案则是错的——照它改等于拆掉安全边界。
> **读懂警告背后的前提，比会跑 `--fix` 更重要。**

**3. 可选优化（本次不动）**

```
NODE_COMPILE_CACHE 未设置 → 小机器上 CLI 启动慢
OPENCLAW_NO_RESPAWN 未设置 → 重启交由 supervisor 处理
```

属于性能优化，不是故障。要改需动 systemd unit 的环境变量，按"无明确收益的变更不做"暂缓。

### 阶段 7-4 · 日志目录整改（2026-10-23）

**问题**

日志默认写在 `/tmp/openclaw/openclaw-YYYY-MM-DD.log`，存在两个缺陷：

| 缺陷 | 依据 | 后果 |
|---|---|---|
| `/tmp` 每次开机清空 | `/usr/lib/tmpfiles.d/tmp.conf`：`D /tmp 1777 root root 30d` | 重启前的日志全部丢失 |
| OpenClaw 只保留当天 + 前一天 | 目录中只剩最近两天文件，而 `uptime` 显示期间未重启 | 故障发生两天后就无据可查 |

> **`tmpfiles.d` 的首字母决定行为**：`d` 只创建、`q` 按年龄清理、**`D` 每次开机清空**。
> 末尾的 `30d` 是 `q` 的参数，对 `D` 不起保护作用。

**配置项来自 schema，不靠记忆**

```bash
openclaw config schema > /tmp/openclaw-schema.json
sed -n '317,440p' /tmp/openclaw-schema.json
```

`logging` 下只有这些键：

```
level / file / maxFileBytes / consoleLevel / consoleStyle / redactPatterns / audit
```

没有保留天数——`file` 的描述明确写着 **retention/rotation 由运维策略负责**。所以方案是：路径交给 OpenClaw，轮转交给 logrotate。

**1. 建目录**

```bash
sudo mkdir -p /var/log/openclaw
sudo chown ubuntu:ubuntu /var/log/openclaw
sudo chmod 750 /var/log/openclaw
ls -ld /var/log/openclaw          # drwxr-x--- ubuntu ubuntu
```

`750` 而非 `/tmp` 的 `1777`：日志含会话内容，不能让任何用户写入。

**2. 改配置并校验**

```bash
openclaw config set logging.file /var/log/openclaw/openclaw.log
# → Updated logging.file. No gateway restart needed.

openclaw config validate
# → Config valid: ~/.openclaw/openclaw.json
```

> 这里 `config set` 提示**无需重启**——日志配置是热读取的。
> 但不同配置项的生效方式不一样（对比「改配置 ≠ 进程知道」那张表），**必须用 `status` 验证**。

**3. 验证真的在写（关键）**

```bash
openclaw gateway status 2>&1 | grep -E "File logs|Runtime|Connectivity"
# File logs: /var/log/openclaw/openclaw.log

openclaw agent --message "日志路径测试"

ls -lh /var/log/openclaw/ && wc -l /var/log/openclaw/openclaw.log
# -rw------- 29K openclaw.log
# 38 /var/log/openclaw/openclaw.log
```

**文件存在 ≠ 正在写入。** 必须制造一条新日志，看文件大小和行数是否增长。这是本次整改唯一的有效证据。

**4. 轮转（可选）**

```bash
sudo tee /etc/logrotate.d/openclaw > /dev/null <<'EOF'
/var/log/openclaw/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su ubuntu ubuntu
}
EOF

sudo logrotate -d /etc/logrotate.d/openclaw   # debug：只打印计划，不执行
sudo logrotate -f /etc/logrotate.d/openclaw   # 实跑一次，验证可用
```

`copytruncate`：OpenClaw 持有文件句柄，直接重命名会让它继续写旧文件。复制后截断原文件，无需重启进程。

**5. 为什么暂不设 `maxFileBytes`**

它会触发 OpenClaw 自己的按大小轮转，产生 `.1` / `.2` 文件，和 logrotate 的命名规则冲突。日轮转 + 14 天保留已经够用。

## 八、故障排查记录

> 格式：现象 → 排查过程 → 根因 → 解决 → 预防

### 案例 1 · SSH 密钥认证失败

**现象**

```
ubuntu@<SERVER_IP>: Permission denied (publickey,password).
```

**排查过程**

```bash
ssh -v -i ~/.ssh/id_ed25519_openclaw ubuntu@<SERVER_IP>
# 输出关键行：
#   Offering public key: ... SHA256:5fLU5ybw... explicit
#   Authentications that can continue: publickey,password
#   Permission denied
```

- 22 端口可达（TCP 层正常）
- 客户端正确提交了预期指纹的密钥
- 换 `root` 用户同样被拒 → 排除"用户名不对"
- **结论：这把公钥不在服务器的 `authorized_keys` 里**

**根因**

腾讯云轻量创建实例时「登录方式」选密钥对，但**不能直接粘贴公钥**，必须先在「密钥对」页面
**导入**已有公钥，再选择该密钥对。创建时若密钥对列表为空，实际会退化为密码登录。

**解决**

控制台 → 密钥对 → 创建密钥对 → **导入已有公钥** → 粘贴 → 绑定到实例（支持在线绑定，无需关机）。

**预防**

创建云实例前，先在密钥对页面完成导入；创建时确认「已绑定密钥对」而非「密码」。

### 案例 2 · 在 PowerShell 里执行 Linux 命令

**现象**

```
PS C:\Users\Thea Lau> sudo ss -tlnp | grep :22
grep : 无法将"grep"项识别为 cmdlet...
```

**根因**

在**本地 Windows** 执行了 Linux 命令。`sudo` / `grep` / `ss` 只存在于服务器上。

**解决**

先 `ssh openclaw` 登录，看到提示符变为 `ubuntu@<HOSTNAME>:~$` 后再执行。

**预防**

看提示符判断当前位置：`PS C:\...>` 是本地，`ubuntu@VM-...:~$` 是服务器。
**不需要虚拟机**——`ssh` 就是远程登录工具。

### 案例 3 · 云防火墙默认存在 ALL 规则

**现象**

腾讯云轻量防火墙入站规则里除 22 外，还有一条 `ALL`（协议 ALL / 端口 ALL / 来源 0.0.0.0/0）。

**风险**

兜底放行所有端口，等于防火墙失效：
- 未来任何服务（如 OpenClaw 的 18789）若误绑到 `0.0.0.0`，立即对全网暴露
- 使 22 / 80 等具体规则失去意义
- 扫描器识别为全端口开放，标记为高价值目标

**解决**

删除 `ALL` 与 `80`，仅保留 `22/tcp`。外部验证：80/443 超时、22 可连。

### 案例 4 · 配置拼写错误导致 SSH 服务宕机 ⭐

> 本项目最有价值的一次事故，完整复现了"把自己锁在门外"的过程。

**现象**

```bash
$ sudo sshd -t
/etc/ssh/sshd_config.d/99-hardening.conf: line 1: Bad configuration option: PermitRooLogin

$ sudo systemctl restart ssh
Job for ssh.service failed because the control process exited with error code.

# 从外部测试新连接
$ ssh openclaw
ssh: connect to host <SERVER_IP> port 22: Connection refused
```

**排查过程**

1. `Bad configuration option: PermitRooLogin` → 与标准参数 `PermitRootLogin` 对比，发现少了一个 `t`
2. **注意现象是"连接被拒绝"而非"超时"** → 说明防火墙正常，是服务没起来
3. 已建立的 SSH 会话仍然可用 → 因为**已建立的 TCP 连接不受服务重启影响**，只有新连接依赖 sshd

**根因**

手写配置文件时漏写一个字母。sshd 对配置极其严格：**只要有一个无法识别的选项，
整个服务就拒绝启动**。

**解决**

```bash
# 用管道重写文件，避免手打（比 heredoc 更不容易出错）
printf 'PermitRootLogin no\n' | sudo tee /etc/ssh/sshd_config.d/99-hardening.conf
sudo mkdir -p /run/sshd
sudo sshd -t && echo "语法 OK"
sudo systemctl restart ssh
```

**预防**

| 措施 | 说明 |
|---|---|
| 配置一律复制粘贴，不手打 | 一个字母的错误足以让服务宕机 |
| 严格按 改配置 → `sshd -t` → 重启 → `sshd -T` 验证 的顺序 | `sshd -t` 失败时**绝不重启** |
| 永远保留一个已登录会话 | 本次事故中它是有修复能力的唯一通道 |
| 兜底通道：腾讯云控制台 VNC 登录 | 不经过 SSH，即使 SSH 全挂也能进 |

### 案例 5 · Missing privilege separation directory

**现象**

```bash
$ sudo sshd -t
Missing privilege separation directory: /run/sshd
```

**根因**

- `/run` 是 **tmpfs**（内存文件系统），每次开机清空
- `/run/sshd` 由 systemd 通过 `RuntimeDirectory=sshd` 在 `ssh.service` 启动时自动创建
- 案例 4 中服务启动失败 → systemd 清理了该目录
- 手动执行 `sshd -t` 不经过 systemd，没人替它创建目录

**解决**

```bash
sudo mkdir -p /run/sshd
```

**预防**

在容器、救援模式或手动调试 sshd 时，先手动创建该目录。
这也解释了 sshd 的**权限分离**机制：特权父进程（认证）与非特权子进程（处理网络数据）
通过 `/run/sshd` 下的 socket 通信，即使子进程被攻破也拿不到 root 权限。

### 案例 6 · 命令输入错误（空格/拼写）

**现象**

```
$ sudo mkdir -p/run/sshd
mkdir: invalid option -- '/'

$ sudo chmod 600/etc/ssh/sshd_config.d/99-hardening.conf
chmod: missing operand after '600/etc/...'
```

**根因**

参数与路径之间漏了空格，shell 把它们当成了一个参数。

**预防**

- 复制粘贴，不手打
- 命令报 `invalid option` / `missing operand` 时，第一反应检查空格
- 复杂操作拆成单条命令逐条执行，便于定位

### 案例 7 · 中文引号导致命令未执行 ⭐

**现象**

```bash
$ openclaw ask"9.11和9.9哪个大？用一句话回答”
> 回答
>
```

终端出现孤立的 `>`，且命令似乎"卡住"。

**排查过程**

`>` 不是 OpenClaw 的提示符，而是 **bash 的续行提示符 PS2**——shell 认为上一行还没结束，正在等待输入。

**根因（两个错误叠加）**

1. **引号未闭合**：开头用了英文 `"`，结尾却是中文引号 `”`（U+201D）。中文引号在 bash 里只是普通字符，不具备闭合字符串的功能。
2. **缺空格**：`ask"内容"` 会被拼接成单个词 `ask9.11...`，即使引号正确也是错的。

中文输入法会自动把 `"` 转成 `“ ”`，是这类事故的常见来源。

**解决**

`Ctrl+C` 中断当前行，重新输入（**注意 `ask` 后有空格、引号用英文**）：

```bash
openclaw ask "9.11 和 9.9 哪个大？用一句话回答"
```

**预防**

- 敲含引号的命令前，先切到**英文/半角标点**
- 看到孤立的 `>`：立刻 `Ctrl+C`，不要在 `>` 后面继续打字，否则越陷越深
- 中文字符串优先用**单引号** `'...'`（只要内容里没有单引号）

### 案例 8 · 凭记忆猜 CLI 命令

**现象**

```bash
$ openclaw ask "..."
OpenClaw does not know the command "ask".
Try: openclaw --help
```

**根因**

OpenClaw 没有 `ask` 子命令。正确命令是 `openclaw agent --message "..."`。

**解决与预防**

- **不确定的语法，先查 `--help`，不要靠记忆或教程**
- 层级套路：`openclaw --help` → `openclaw <cmd> --help` → `openclaw <cmd> <sub> --help`
- CLI 自带的 `--help` 比在线文档更准，因为它跟的是**你实际安装的版本**；文档站会与版本漂移
- 安装 shell 补全，从根上消灭拼写错误：

```bash
openclaw completion
```

查询结果统一沉淀到同目录下的 [命令速查.md](命令速查.md)，避免重复查、重复猜。

### 案例 9 · PowerShell 的 `curl` 不是 curl

**现象**

```powershell
PS C:\Users\Thea Lau> curl http://127.0.0.1:18789/
安全警告: 脚本执行风险
Invoke-WebRequest 可解析网页内容。解析网页时，可能会运行网页中的脚本代码。
```

**根因**

PowerShell 里 `curl` 和 `wget` 都是 **别名**，指向 `Invoke-WebRequest`，不是原生 curl。

| 敲的命令 | 实际执行 |
|---|---|
| `curl` | PowerShell 的 `Invoke-WebRequest`（解析 HTML，可能执行脚本） |
| `curl.exe` | 真正的 curl 二进制 |

**解决**

```powershell
curl.exe -I http://127.0.0.1:18789/
```

**预防**

- 在 PowerShell 里调用同名外部程序，加 `.exe` 后缀
- 用 `Get-Command curl` 查看某个名字到底指向什么：

```powershell
PS C:\> Get-Command curl
CommandType  Name      Source
Alias        curl      Microsoft.PowerShell.Utility\Invoke-WebRequest
```

`CommandType` 是 `Alias` 就说明被劫持了。

- 与案例 2 同类：**命令在错误的解释器里执行，行为完全不同**。看提示符判断环境（`PS C:\>` vs `ubuntu@...:~$`）

### 案例 10 · 飞书机器人不回复

**现象**

飞书里能给「OpenClaw 助手」发消息，但没有任何回应。

**分层排查（按链路从下往上）**

```bash
openclaw channels status --probe    # ① 连接层
openclaw channels logs              # ② 消息层
openclaw logs                       # ③ 服务层
```

| 检查点 | 正常表现 | 异常含义 |
|---|---|---|
| `channels status --probe` | `enabled, configured, running, connected, works` | 连接未建立 → App ID/Secret 错误，或长连接未生效 |
| `channels logs` 有新 inbound 记录 | 消息已进入 Gateway | 无记录 → 飞书侧事件订阅或版本发布没生效 |
| 有 inbound 但无 outbound | 消息进来了、回复失败了 | 权限缺 `im:message`（发消息） |
| 有 outbound 但用户没收到 | 发送失败 | 机器人能力未启用，或可用范围不含该用户 |

**常见的三种"假故障"**

1. **服务器端从未配置渠道** —— 飞书应用已发布，但 `openclaw channels add` 没做。
   飞书侧只是"应用存在"，OpenClaw 并不知道它的存在。
2. **pairing 未批准** —— 机器人回复 `access not configured` + 配对码。
   这不是故障，是安全机制生效。用 `openclaw pairing approve feishu <code>` 批准。
3. **版本未发布** —— 权限与事件的改动必须发布新版本才生效。配置页全对但机器人不响应，先查这里。

**预防**

排障顺序永远是**先分层定位，再改配置**。不要一上来就重装插件或重启服务——那会同时改变多个变量，把真正的根因掩盖掉。

### 案例 11 · 一个字符引发三条命令连锁失败 ⭐

**现象**

```bash
$ sudo fallocate -1 2G /swap2.img
fallocate: invalid option -- '1'

$ sudo chmod 600 /swap2.img
chmod: cannot access '/swap2.img': No such file or directory

$ sudo mkswap 600 /swap2.img
mkswap: invalid block count argument: '/swap2.img'
```

**根因**

`fallocate` 的长度选项是**小写字母 `l`**，被敲成了**数字 `1`**。shell 把 `-1` 当作选项解析，直接拒绝。

后面两条都是**连锁反应**：

| 命令 | 为什么失败 | 真正的根因 |
|---|---|---|
| `chmod 600 /swap2.img` | 文件根本没被创建 | 第 1 条的 `-1` |
| `mkswap 600 /swap2.img` | 命令名写成了 `mkswap`（应为 `chmod`），于是 `600` 被当成设备、路径被当成块数 | 手误 + 第 1 条 |

**关键判断**：`mkswap: invalid block count` 看起来像"块数写错了"，实际根因在**上一条**。

**解决**

```bash
sudo fallocate -l 2G /swap2.img    # 小写 L
ls -lh /swap2.img                  # 先验证文件存在、大小正确
sudo chmod 600 /swap2.img
ls -l /swap2.img                   # 验证权限 -rw-------
sudo mkswap /swap2.img
sudo swapon /swap2.img
```

**预防**

- **一条命令 → 验证 → 下一条**。合并执行时，报错会指向错误的方向
- 形近字符清单：`l`（ell）/ `1`（one）、`O` / `0`、`-` / `—`
- 好消息：这次失败发生在**改动生效之前**，磁盘没有任何变化。与案例 4（sshd 配置错误导致服务宕机）同源，但后果轻得多

### 案例 12 · apt 升级卡在 debconf 键盘配置界面

**现象**

`apt upgrade` 跑到一半，屏幕被对话框占满：

```
┌─────────┤ Configuring keyboard-configuration ├─────────┐
│ Country of origin for the keyboard:                     │
│    English (Ghana)                                      │
│    English (US)                                         │
│              <Ok>              <Cancel>                 │
└─────────────────────────────────────────────────────────┘
```

之后还有第二个界面：

```
│ Keyboard layout:                                        │
│    English (US)                                         │
│    English (US) - Cherokee                              │
│    English (US) - English (classic Dvorak)              │
│    English (US) - English (Colemak)                     │
```

**这不是卡死，是 apt 在等你回答。** 升级包列表中包含 `keyboard-configuration`，debian 系在重装这类包时会触发交互式配置。

**处理**

| 步骤 | 选择 |
|---|---|
| Country of origin | `English (US)` |
| Keyboard layout | **第一项 `English (US)`**，不带任何 `- 变体` 后缀 |

**为什么这个选择不影响 SSH**

键盘布局只决定**本地控制台（VNC / 物理显示器）**如何解释按键扫描码。SSH 传输的是已经编码好的字符，与服务器认为键盘是什么布局无关。

**绝对不要按 `Ctrl+C`**——会中断 dpkg，让包停在"半配置"状态，之后需要 `sudo dpkg --configure -a` 修复。

**预防**

云服务器升级时交互式提问没有意义（没人会去机房插键盘）。可以跳过：

```bash
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
```

代价是**所有提问自动取默认值**，包括配置文件冲突时可能覆盖本地版本。第一次升级建议人工看着走。

### 案例 13 · sshd_config 冲突：`PermitRootLogin yes` 为什么没生效

**现象**

升级过程中弹出：

```
A new version (/tmp/tmp.NoDuXv7mK9) of configuration file
/etc/ssh/sshd_config is available, but the version installed
currently has been locally modified.

What do you want to do about modified configuration file sshd_config?
   install the package maintainer's version
   keep the local version currently installed
   show the differences between the versions
   ...
```

选「保留本地版本」后，查看实际生效配置：

```bash
sudo grep -vE '^\s*(#|$)' /etc/ssh/sshd_config
```

```
Include /etc/ssh/sshd_config.d/*.conf
AddressFamily any
PermitRootLogin yes          ← 看起来危险
...
PasswordAuthentication no
```

**为什么 `PermitRootLogin yes` 没有生效**

sshd 的规则是「**同一个参数，先被读到的生效**」，而 `Include` 位于文件最顶部：

```
Include 先执行
  └─ sshd_config.d/99-hardening.conf: PermitRootLogin no   ← 先读到，生效
主配置后读到
  └─ PermitRootLogin yes                                    ← 被忽略
```

**验证方式永远不是看文件，而是问 sshd 自己：**

```bash
sudo sshd -T | grep -iE "permitrootlogin|passwordauthentication|port"
# port 22
# permitrootlogin no          ← 最终生效值
# passwordauthentication no
```

**处置**

- 冲突时选 **keep the local version currently installed**。本地版本是当前能正常工作的那一份，而 SSH 是唯一的登录通道
- 选保留后，dpkg 会把新版默认文件另存为 `sshd_config.dpkg-dist`（若选覆盖，则旧版存为 `.dpkg-old`）
- 升级后对比差异，决定是否吸收：

```bash
ls -l /etc/ssh/sshd_config.dpkg-*
sudo diff -u /etc/ssh/sshd_config /etc/ssh/sshd_config.dpkg-dist
```

> **不盲目接受，也不盲目拒绝，先看差异再决定。**

### 案例 14 · stale lease 导致数据库准入关闭 ⭐

**现象**

重启后出现一串日志：

```
[state/db] Shared-state WAL maintenance failed
  error="OpenClaw state database read admission is closed"
[sqlite/transaction] slow SQLite transaction hold
  operation=agent.database.maintenance.lease elapsedMs=1687
  phases={"prepareMs":2,"beginMs":0,"sqlMs":1,"hostAdmissionWaitMs":1686,"commitMs":0}
```

同时 `state/` 目录里出现 `openclaw-quarantine.sqlite`（20K），Gateway 的 PID 反复变化。

**排查过程**

1. `pgrep -af openclaw` → 只有 1 个主进程 + 4 个 worker，**排除多实例抢锁**
2. `systemctl --user show ... -p NRestarts` → `0`，但 `ActiveEnterTimestamp` 是新的 → 说明是手动 / 内部重启，不是 systemd 自动拉起
3. `grep -c "read admission is closed"` → **全天只出现 1 次** → 瞬态，不是持续故障
4. `openclaw doctor` → 找到根因

**根因**

```
[state/agent-db] agent database stale lease: owner-pid-dead;
                 previous release not observed
[state/agent-db] integrityGateReason=stale-lease-full
```

**数据库里有一个过期租约（lease），持有它的进程已经死了。** 进程被强制结束时没来得及释放租约，新进程启动后发现持有者 PID 已死，无法获得读取准入（read admission），于是所有需要写的事务都在等待。

`hostAdmissionWaitMs=1686` 说明耗时全部花在**等准入**，不是 SQL 慢——这是定位关键。

**解决**

`openclaw doctor` 的完整性检查（`integrity gate`）会清理 stale lease，执行后配置告警与数据库准入异常同时消失。

**验证数据没有丢失**

```bash
openclaw models status
# - deepseek effective=profiles:~/.openclaw/state/openclaw.sqlite | profiles=1 (1 api-key)
openclaw channels status --probe
# - Feishu default: enabled, configured, running, connected, works
```

两者都能从 sqlite 读出凭证，说明主库完好。那个 20K 的 `openclaw-quarantine.sqlite` 远小于主库（3.2M），是被隔离的附属文件，**保留不要删**。

**预防**

- 停服务优先用 `systemctl --user stop` / `openclaw gateway restart`，让进程正常释放资源；避免 `kill -9`
- **看日志时区分"耗时花在哪"**：`hostAdmissionWaitMs` 占满 ≠ SQL 慢，排查方向完全不同
- 日志应落在持久目录。本项目日志在 `/tmp/openclaw/`，而 `/tmp` 每次重启清空——重启前的证据全部丢失（见"待整改"）

## 九、知识点速查

### 端口不是文件

端口是 TCP/IP 协议里 **0–65535 的整数**，不是磁盘文件。内核在内存中维护「谁在监听哪个端口」的表。

```bash
sudo ss -tlnp              # 查看监听中的端口与进程
```

字段含义：

```
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=10272,fd=3))
  │    │  │       │          │            │
  │    │  │       │          │            └─ 持有 socket 的进程
  │    │  │       │          └─ 对端地址，* = 任意
  │    │  │       └─ 监听地址，0.0.0.0 = 本机所有 IPv4 网卡
  │    │  └─ 队列上限
  │    └─ 已接收未读取字节数，0 为正常
  └─ socket 状态
```

但"22 从哪来"由文件决定：

| 文件 | 作用 |
|---|---|
| `/etc/systemd/system/ssh.socket` | 决定 SSH 监听哪个端口（Ubuntu 24.04 实际生效处） |
| `/etc/ssh/sshd_config` | 决定认证方式、是否允许 root 登录等 |
| `/etc/ufw/user.rules` | 本机防火墙规则 |

### ssh 与 sshd

| 名称 | 全称 | 角色 | 跑在哪 |
|---|---|---|---|
| **ssh** | Secure **SH**ell client | 客户端，主动发起连接 | 你的 Windows |
| **sshd** | Secure **SH** **D**aemon | 服务端，监听端口、验证身份、开 shell | 服务器 |

`d` = daemon（守护进程）。类比：ssh 是打电话的人，sshd 是接电话的人。
`systemctl restart ssh` 重启的服务单元叫 `ssh.service`，它运行的二进制叫 `sshd`（历史命名差异）。

### ⚠️ Ubuntu 24.04 的 SSH socket 激活坑

`ss -tlnp` 中若看到 `sshd` 和 `systemd(pid=1)` **同时**持有 22 端口的 socket，
说明启用了 systemd socket 激活（`ssh.socket` 为 enabled）。

**后果：改 `/etc/ssh/sshd_config` 里的 `Port` 不生效**，必须改 `ssh.socket`。
这是 Ubuntu 22.10 之后的变化，网上大量老教程仍教改 `sshd_config`。

### sshd 配置的生效顺序

`/etc/ssh/sshd_config` 第 12 行有 `Include /etc/ssh/sshd_config.d/*.conf`，
**在主配置最前面**加载。sshd 对同一参数采取「先读到的生效」。

因此推荐把自定义配置放在 `sshd_config.d/` 下的独立文件（如 `99-hardening.conf`），
而不是直接改主配置——升级软件包时主配置可能被覆盖，drop-in 会保留。

> ⚠️ 但"先定义者生效"只对**已被定义**的参数成立。改完务必用 `sshd -T` 验证实际生效值，
> 不要凭命名顺序臆测。

### 超时 vs 连接被拒绝

| 现象 | 含义 |
|---|---|
| **超时**（无响应） | 被防火墙/安全组拦截，包根本没到服务 |
| **连接被拒绝** | 防火墙放行了，但**没有服务在监听**该端口 |

### swap 占用 ≠ 正在换页

`free -h` 的 `Swap: used` 只表示**有多少页被换到磁盘**，不表示系统正在频繁读写 swap。

| 指标 | 命令 | 含义 |
|---|---|---|
| `si` / `so` | `vmstat 1 5` | 每秒换入 / 换出页数。持续非零才是真在换页 |
| `wa` | `vmstat 1 5` | IO 等待占比。换页严重时会明显升高 |

**闲置的 swap 页不影响性能**——它们被换出去之后一直没被访问，内核也不会主动搬回来。

判断内存是否紧张，看 `available` 而不是 `used`：

```bash
free -h                                       # 看 available 列
systemctl --user status <服务>                # cgroup 口径的 Memory / peak
ps -eo pid,comm,%mem,rss --sort=-rss | head   # 谁在吃内存
```

本项目实测：`Swap used` 1.0G，但 `si` / `so` 全为 0、`wa` 为 0、CPU 空闲 98%——属于闲置页面，不是故障。

### doctor 的 warning 不都要修

配置检查工具按**通用最佳实践**给建议，它不知道你的架构选择。判断标准是：**这条建议的前提，在你的场景里成立吗？**

| Warning | 通用前提 | 本项目前提 | 处置 |
|---|---|---|---|
| `gateway.bind` 只监听回环 | 要让远程设备接入 | 只用 SSH 隧道，绝不暴露 | **不修** |
| 飞书 `groupPolicy` 允许列表为空 | 期望群聊可用 | 群聊默认静默（最小权限） | **不修** |
| needrestart 提示内核未生效 | 新内核已装 | 确实需要重启 | **修**（重启） |

> **跑 `--fix` 之前先问：它要改的东西，是不是我故意这样配的？**

### 改远程网络配置必须留退路

1. **保持一个已登录的会话不关**（案例 4 的活教材）
2. 另开新窗口验证新配置
3. 新窗口进不去 → 回原会话回滚
4. 最后兜底：云控制台 VNC 登录，不经过 SSH

### 先开后关

改端口/放行规则时，先让新通道可用并验证，再关闭旧通道。
不要"关了旧的开新的"，中间的空窗期会让你失去退路。

### 一次只改一件事

配置变更与验证交替进行：改一项 → 检查 → 重启 → 验证 → 再改下一项。
不要在服务已经异常的情况下继续叠加新变更——故障原因会变得无法定位。

### fail2ban 的静默失效陷阱

Ubuntu 的服务单元叫 `ssh.service`，但 fail2ban 默认过滤器的日志匹配写的是：

```
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
```

`+` 在 systemd journal 匹配语法中是**逻辑或**。`_SYSTEMD_UNIT` 对不上，但 `_COMM=sshd`
能对上（进程名确实是 `sshd`），所以仍然生效。

**如果去掉 `_COMM=sshd` 这一项，fail2ban 会完全读不到日志**——`systemctl is-active`
依然显示 `active`，`fail2ban-client status` 也正常返回，但 `Total failed` 永远停在 0。

> **通用教训：服务"运行中"不等于"功能正常"。**
> 验证一个监控类服务，必须制造真实事件并观察它是否响应，不能只看进程状态。
> 这类"静默失效"是线上最难发现的问题之一。

### 自我封禁的恢复

fail2ban 可能封掉你自己的 IP。恢复方式：

```bash
# 通过 VNC 控制台登录后
sudo fail2ban-client unban <你的IP>
sudo fail2ban-client status sshd      # 确认 Banned IP list 已清空
```

---

### Provider 与 Model 是两层

| 层 | 是什么 | 换它要做什么 |
|---|---|---|
| **Provider** | 厂商接入：插件 + API Key + base URL | 三步：装插件 → 配 key → 选模型 |
| **Model** | 具体型号：`deepseek-v4-pro` / `deepseek-flash` | 一步：`openclaw models set <id>` |

同一 Provider 下的模型**共用一把 key、同一个账户、同一个出口**，区别只是请求体里的 `model` 字段。所以换模型是改一个字符串，不是重新配置。

**临时覆盖 vs 永久默认：**

```bash
openclaw models set deepseek/deepseek-flash                      # 改配置文件，永久
openclaw agent --model deepseek/deepseek-flash --message "..."   # 只影响这一次
```

### 改配置 ≠ 进程知道了

常驻进程在启动时把配置读进内存，之后一直用内存里的副本。改磁盘文件后，进程不一定知道。

| 改什么 | 文件 | 生效方式 |
|---|---|---|
| SSH 配置 | `/etc/ssh/sshd_config.d/*.conf` | `sudo systemctl restart ssh` |
| OpenClaw 凭证 | `~/.openclaw/openclaw.json` + `state/openclaw.sqlite` | `openclaw gateway restart` |
| OpenClaw 模型选择 | `~/.openclaw/openclaw.json` | 实测可热读取，无需重启 |

**结论：不同配置项的生效方式可能不同，永远用 `status` 验证，不要假设。**

### 配置与凭证分离存放

| 文件 | 内容 |
|---|---|
| `~/.openclaw/openclaw.json` | 模型选择、gateway token、插件配置 |
| `~/.openclaw/state/openclaw.sqlite` | API Key 等认证凭证（auth store） |

**备份时两个都要**——只备份 JSON 会丢 key，只备份 sqlite 会丢配置。两者均为敏感文件，权限应为 `600`。

### SSH 本地端口转发（-L）

```
ssh -N -L <本地端口>:<目标主机>:<目标端口> <别名>
```

| 参数 | 作用 |
|---|---|
| `-L` | 本地转发：把本地端口的流量送到远端 |
| `-N` | 不执行远程命令，只做转发 |
| `目标主机` | **从服务器视角**解析。写 `127.0.0.1` 表示服务器自己的回环地址 |

**三种常见用途：**

```bash
# 访问只监听回环的 Web 服务（本项目）
ssh -N -L 18789:127.0.0.1:18789 openclaw

# 访问内网数据库
ssh -N -L 5432:127.0.0.1:5432 openclaw
```

**与安全组的关系**：隧道把流量塞进 SSH 的 22 端口，因此**不需要在任何防火墙放开被转发的端口**。这是"安全默认 + 按需访问"的标准做法。

**反向操作**（`-R`）是把本地服务暴露给远端，本项目用不到，但要知道 `-L` 与 `-R` 方向相反。

### 长连接 vs Webhook

| 维度 | WebSocket 长连接 | Webhook |
|---|---|---|
| 连接发起方 | **你的服务器** → 飞书（出站） | 飞书 → 你的服务器（入站） |
| 需要公网地址 | ❌ 不需要 | ✅ 必须 |
| 需要域名 / ICP 备案 | ❌ 不需要 | ✅ 需要 |
| 需要 HTTPS 证书 | ❌ 不需要 | ✅ 需要 |
| 需要开放新端口 | ❌ 不需要 | ✅ 需要 |
| 实时性 | 连接常驻，消息即到 | 每次回调独立请求 |
| 内网环境可用 | ✅ 可以 | ❌ 不行 |

**本项目选长连接的唯一理由**：它让整条链路只需要一个出站方向，从而把"买域名、做备案、配证书、开端口"这四件事全部省掉。这是整个部署方案能简化的根本原因。

### 应用身份 vs 用户身份

| | 应用身份（tenant_access_token） | 用户身份（user_access_token） |
|---|---|---|
| 操作主体 | 应用自己 | 某个具体用户 |
| 获取方式 | App ID + App Secret | OAuth 授权流程 |
| 需要用户同意 | 不需要 | 需要 |
| 适用场景 | 机器人收发消息 | 代表用户读写文档、日历 |

本项目全程使用**应用身份**，因此只需 App ID + App Secret，不涉及任何扫码授权。

### pairing：默认拒绝

OpenClaw 的私聊默认策略是 `pairing`——陌生人首次私聊时必须由管理员批准。

| 策略 | 行为 | 风险 |
|---|---|---|
| open | 任何人可直接对话 | 陌生人可消耗你的模型额度 |
| **pairing** | 每个新用户需人工批准 | 安全，但需手动维护 |
| allowlist | 仅白名单用户可用 | 最严格 |

**默认值选了最安全的那个，保持不动即可。** 这体现的是"默认拒绝（deny by default）"原则——与 ufw 的 `default deny incoming`、云防火墙收敛到单端口，是同一套思路。

## 十、待办与注意事项

### 已完成

- [x] DeepSeek API Key 存放在 `~/.openclaw/state/openclaw.sqlite`（auth store）与 `~/.openclaw/openclaw.json`，**不要写进本文档或提交到 Git**
- [x] 备份脚本覆盖整个 `~/.openclaw`（含 `openclaw.json` 与 `state/openclaw.sqlite`）
- [x] 备份脚本已实现并接入 cron（轻量服务器不支持自动快照，只能自建）
- [x] 系统健康检查、补丁升级、重启验证开机自启
- [x] `openclaw doctor` 体检，清理 stale lease
- [x] 日志目录整改：`/tmp/openclaw/` → `/var/log/openclaw/openclaw.log`（`750`），已实测持续写入

### 待办

- [ ] **日志轮转**：logrotate 配置已给出但未启用，建议在磁盘使用率超过 50% 前补上
- [ ] **端口冲突故障演练**：人为占用 18789，观察 Gateway 启动失败的表现与排查路径
- [ ] **（可选）改 SSH 端口**：需同时协调云防火墙、ufw、`ssh.socket` 三处，锁死风险高
- [ ] **余额监控**：fallback 不覆盖账户级故障（余额耗尽、key 失效），需另做监控

### 风险与边界

- [ ] **不要执行 `do-release-upgrade`**。banner 会提示 `New release '26.04.1 LTS' available`，这是跨大版本升级，与 `apt upgrade` 不是一个量级。24.04 标准支持到 2029 年，没有升级压力
- [ ] 轻量服务器只支持升配不支持降配；不支持弹性公网 IP；整个生命周期仅可更换 1 次公网 IP
- [ ] 2C2G 对当前负载偏紧：Gateway 常驻约 1.1G，峰值 1.5G。已加 2G swap 兜底，长期方案是升配到 4G
- [ ] 升级后仍会周期性出现 `unattended-upgrades` 已启用但更新堆积的情况，需要在收尾时确认 `20auto-upgrades` 的实际配置
