<!-- README.zh-CN.md — 简体中文 (DIVE-799)。2026-08-16 与 README.md 同步（DIVE-3390）。英文原文见 README.md。 -->

<p align="center">
  <a href="https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/readme-hero-dark.png">
      <img src="docs/readme-hero-light.png" alt="5dive" width="240">
    </picture>
  </a>
</p>

<p align="center"><b>在你自己的服务器上，运行一整家公司规模的 AI 智能体</b></p>

<p align="center"><a href="README.md">English</a> ｜ <b>简体中文</b></p>

<p align="center">
  <a href="docs/zero-human.md"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2F5dive-ai%2F5dive%2Fstatus%2Fbadge.json" alt="zero-human"></a>
  <a href="https://github.com/5dive-ai/5dive/releases"><img src="https://img.shields.io/github/v/release/5dive-ai/5dive" alt="最新版本"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="许可证：MIT"></a>
</p>

<p align="center">
  <a href="https://github.com/5dive-ai/5dive/actions/workflows/install-smoke.yml"><img src="https://github.com/5dive-ai/5dive/actions/workflows/install-smoke.yml/badge.svg" alt="install-smoke"></a>
  <a href="https://github.com/5dive-ai/5dive/actions/workflows/bundle-drift.yml"><img src="https://github.com/5dive-ai/5dive/actions/workflows/bundle-drift.yml/badge.svg" alt="bundle-drift"></a>
  <a href="https://t.me/ai5dive"><img src="https://img.shields.io/badge/Telegram-@ai5dive-229ED9?logo=telegram&logoColor=white" alt="Telegram"></a>
  <a href="https://discord.gg/aU2UQC9Myy"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#为什么选-5dive">为什么选 5dive</a> ·
  <a href="#值得一试">值得一试</a> ·
  <a href="docs/zero-human.md">零人工证明</a> ·
  <a href="#交给你的-ai-智能体">让 AI 智能体使用</a> ·
  <a href="#安全与隔离">安全</a> ·
  <a href="https://5dive.ai/docs/5dive-cli?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh">完整 CLI 文档</a> ·
  <a href="https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh">托管 VM</a>
</p>

**一家公司规模的 AI 智能体，而编排器只是一段 bash。** 没有框架、没有协议、没有消息代理：每个智能体都是一个独立的 Linux 用户，以 systemd 服务运行官方编程智能体 CLI（`claude`、`codex` 等），并通过大家共同调用的一条 bash CLI 协作。隔离靠 Unix 用户，监控靠 systemd，日志进 journald。**我们没有另造平台，而是直接用了操作系统。**

它们从共享的 SQLite 任务队列领活，在你睡觉时互相交接，只有必须由人决策时才通过 Telegram 提醒你的手机。支持所有主流智能体 CLI。

![从安装到 Claude 智能体在 Telegram 上回复](docs/quickstart.gif)

> **我们自己的公司就跑在它上面。** 构建 5dive.ai 的智能体也负责发布这个仓库，只有卡住时才向人求助。顶部徽章会每天重新发布过去 7 天的版本发布数与人工决策上报数，用数据检验这句话。完整数据和限制见 [docs/zero-human.md](docs/zero-human.md)。你安装的就是同一个二进制。MIT 协议，没有 open-core。自己运行，或用[托管 VM](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh)省去运维。

**不是又一个多智能体框架——就是 bash + systemd。** 没有协议、没有中间层、没有黑盒编排。

- 🖥️ **自托管**——跑在你自己的服务器上，token 直连模型厂商，绝不经过我们
- 🇨🇳 **接国产模型**——DeepSeek / Kimi / 智谱 GLM / 通义千问，或用 OpenRouter 一个 Key 通所有
- 👥 **一整支团队**——多个智能体按组织架构协作、互相派活，而不是单个 bot

> 觉得有用？给个 ⭐ Star——我们靠 star 判断接下来做什么。

**用自然语言运行整家公司**——直接通过你已经在用的 AI 智能体。安装 [`5dive-cli` 技能](#交给你的-ai-智能体)，就能创建智能体、分派工作、查看组织架构。[一行配置 ↓](#交给你的-ai-智能体)

---

## 快速开始

```sh
# 1. 安装
curl -fsSL https://install.5dive.ai | sudo bash

# 2. 创建第一个智能体——向导也会配置 Telegram：
#    粘贴 BotFather 提供的 bot token，给 bot 发送 /start，
#    它就会自动配对，无需验证码。
sudo 5dive init
```

需要写入脚本（CI、自动化开通）？非交互路径会多一步：bot 会在你第一次私聊时回复配对码。

```sh
sudo 5dive agent create my-agent --type=claude --channels=telegram --telegram-token=<token>
sudo 5dive agent pair   my-agent --code=<pairing-code>
```

**环境要求：** 一台运行 `systemd` 的 Linux 主机，以及你自己的智能体 CLI 订阅或 API key（Claude Pro/Max、OpenAI 等）——无需注册 5dive 账户。

> **“`curl | sudo bash`，智能体还能用 `sudo`？”** 这个疑问很合理。安装器只通过 apt 安装依赖，并写入 CLI 和 systemd unit（它获取的每个文件都列在 [`install.sh`](install.sh) 顶部）。随后每个智能体都是独立的 Linux 用户，权限范围由你决定：`sandboxed` 智能体拥有独立 home、没有 sudo，并受资源限制。详见[安全与隔离 ↓](#安全与隔离)。

---

## 为什么选 5dive

**它们上报，你拍板。** 智能体自主工作，只有必须由人决定时——花钱、发布或任何破坏性操作——才把可点选的按钮发到你的手机。

**一家自运转的公司。** 同一主机上的具名智能体按组织架构汇报，并通过共享待办互相交接工作。

**订阅归你所有。** 官方 CLI 使用你自己的 Pro/Max 订阅或 key。没有中间商，没有 OAuth 代理。

**作为服务运行，而不是一次会话。** 关掉终端，智能体依然在线；随时从 Telegram 给它们发消息。

**小主机也能跑。** 5dive 不会在编程智能体 CLI 外再套一层沉重的运行时：只有 Bash、SQLite 和 systemd。单智能体配置在 1 GB 内存的虚拟机上也能轻松运行。

**支持所有主流智能体 CLI。** `claude`、`codex`、`antigravity`、`grok`、`openclaw`、`hermes`、`opencode`、`pi`，八种类型组成同一支团队。

**默认安全。** 每个智能体都是独立的 Linux 用户，可选三档隔离级别。MIT 协议，没有 open-core 拆分。

---

## 工作原理

每个智能体都是独立的 Linux 用户，以 systemd 服务运行官方智能体 AI CLI 会话（`claude`、`codex`、`antigravity`、`grok` 等）。多个智能体可以共用同一 CLI 二进制和订阅。智能体通过调用同一个 `5dive` CLI 联系彼此——这条 CLI *就是*总线。Telegram 等通道按智能体挂载。

<p align="center">
  <img src="docs/how-it-works.png" width="560" alt="操作系统即编排器：coder、writer、pm 智能体在一台 Linux 主机上通过 5dive CLI（总线）协作；身份是 Linux 用户，监督是 systemd，日志是 journald，待办是 SQLite，心跳是 cron，隔离是 Unix 权限；人只在必要时决策">
</p>

没有消息代理、没有协议、没有框架。共享文件系统，共享 CLI。

---

## 智能体类型

| 类型 | 模型家族 | 鉴权 | 通道 |
|------|---------|------|------|
| `claude`      | Anthropic Claude，或任意 Anthropic 兼容接口 | OAuth / API key / `--provider` | Telegram、Discord |
| `codex`       | OpenAI Codex           | OAuth / API key | Telegram |
| `antigravity` | Google Antigravity     | Google OAuth | Telegram |
| `grok`        | xAI Grok               | OAuth (xAI) / API key | Telegram |
| `devin`       | Cognition Devin        | OAuth (Devin account) | — |
| `hermes`      | 第三方多模型 provider 框架 | API key | Telegram、Discord |
| `openclaw`    | 第三方多模型 provider 框架 | API key | Telegram、Discord |
| `opencode`    | OpenCode               | API key | Telegram |
| `pi`          | 第三方多模型 provider 框架 | API key / `--provider` | Telegram |

<details>
<summary><b>关于 <code>hermes</code> / <code>openclaw</code>（第三方多模型 provider 框架）</b></summary>

`hermes` 和 `openclaw` 是社区构建的框架，可以接入 OpenRouter、Anthropic、Google、Moonshot、DeepSeek、Z.ai 等多个 provider。自 2026 年 4 月 4 日起，Anthropic 不再允许第三方框架转接 Claude Pro/Max 消费者 OAuth。此类工作请使用官方 `claude` 类型并提供自己的 API key。背景：[我们为何从 OpenClaw 转向 Claude →](https://blog.5dive.ai/blog/we-ditched-openclaw-for-claude/?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh)。

</details>

`claude` 类型也可以让官方 Claude Code 框架连接第三方 Anthropic 兼容接口，使用你自己的 key：

```sh
sudo 5dive agent create cheap-coder --type=claude --provider=deepseek --api-key=<key> --auth-profile=deepseek
# provider：openrouter（任意模型）、deepseek（DeepSeek）、moonshot（Kimi）、qwen（阿里通义千问）、zai（GLM）
# claude BYO 必须指定 --auth-profile=<name>（保存 key 的账户；多个智能体可复用它来共享 key）

# 已经有智能体了？不需要重建——直接改绑到另一个账户：
sudo 5dive agent create kimi --type=claude --provider=moonshot --api-key=<key> --auth-profile=kimi
sudo 5dive agent set-account cheap-coder kimi        # 重新绑定并重启智能体；"default" 清除绑定
#（`5dive account set-active-provider` 是另一回事，仅限 type=hermes——它切换的是
#  单个 hermes 配置内部的活跃 provider，对 claude 会拒绝。claude 要切换的是账户。）

# 也可以指定模型。--model 会把主模型层级替换成 provider 提供的任意 slug
#（OpenRouter 能转换所有模型家族）；后台模型仍使用 provider 的低价默认值。
# 省略该参数则使用各 provider 的默认模型。
sudo 5dive agent create glm-coder --type=claude --provider=openrouter --api-key=<key> --auth-profile=openrouter --model=z-ai/glm-5.2
```

不在上述列表里？`--base-url` 可以把框架指向**任意** Anthropic 兼容接口——自托管的模型，或我们未收录的供应商主机：

```sh
# 自有服务器上的开放权重模型。这里必须指定 --model：目录中没有条目可以继承
# 各层级的模型 ID，未固定的后台层级会在智能体自身的维护回合里 404。
sudo 5dive agent create mistral-box --type=claude \
  --base-url=https://llm.internal.example.com/anthropic \
  --api-key=<key> --auth-profile=mistral-box --model=mistral-large-3

# 本地推理服务器（vLLM、llama.cpp、Ollama 的 Anthropic 垫片）：
sudo 5dive agent create local-box --type=claude \
  --base-url=http://127.0.0.1:8000 \
  --api-key=<key> --auth-profile=local-box --model=<slug>
```

必须使用 `https://`——API key 每次请求都随该 URL 发送。只有 `localhost` / `127.0.0.1` / `[::1]` 允许 `http://`，因为流量不会离开本机；私有内网地址仍然是真实网络，会被拒绝。`--base-url` 与所有 claude BYO 路径一样必须指定 `--auth-profile`，让接口和 key 的作用范围限定在绑定该配置的智能体，而不是主机上的每一个 claude 智能体。在 `5dive compose` 配置里，对应的键是 `base_url`。

切换运行中智能体的模型（重启后仍然生效）：

```sh
sudo 5dive agent config glm-coder set model=z-ai/glm-5.2
```

在会话中，Claude Code 内置的 `/model <slug>` 也能即时接受任意自定义 slug（仅当前会话生效）。

---

## 值得一试

`5dive company`<br>
一条命令搭建一家自主运转的公司。

`5dive task`<br>
管理共享任务队列和所有智能体之间的交接。

`5dive goal add "Ship billing v2"`<br>
把一个结果转成带护栏的任务图。

`5dive loop spawn --role=researcher --agent=scout --prompt="Track competitor launches"`<br>
让智能体在明确边界内持续自主工作。

`5dive council convene "Should we ship?" --mode=adversarial`<br>
发起一次可审计的多智能体对抗式评审。

`5dive trace DIVE-42`<br>
查看任务从起点到结论的完整因果时间线。

`5dive watch`<br>
实时查看整个团队。

`5dive ui`<br>
在本地浏览器中查看组织架构、任务队列和人工关卡。

`5dive memory search "release checklist"`<br>
搜索团队带来源的长期记忆。

`5dive acp`<br>
通过 ACP 连接 Zed、Buzz 等客户端。

---

## 交给你的 AI 智能体

如果你已经在使用 Claude Code / Codex / Antigravity / Grok / opencode，粘贴下面这段提示词。你的智能体会安装 5dive、学习相关技能，以后就能通过聊天持续管理其他智能体：

```
在这台 Linux 主机上安装 5dive，让我可以通过你管理 5dive 智能体。

1. 运行安装器（幂等，可安全地重复执行）：
   curl -fsSL https://install.5dive.ai | sudo bash
2. 确认 `5dive --version` 能输出版本字符串（例如 "5dive 0.5.x"）。
3. 安装 5dive-cli 技能。将 <runtime> 替换为以下之一：
   claude-code、codex、antigravity、grok、hermes-agent、openclaw、opencode：
   npx -y skills add https://github.com/5dive-ai/skills --skill 5dive-cli --agent <runtime> --yes
4. 告诉我重启以加载技能，然后问我先创建哪个智能体。
```

**要通过 SSH 安装到远程 VM？** 使用同一段提示词，并在安装命令前加上 `ssh -t <user@host>`。技能应装在发起 `ssh` 的笔记本电脑上，而不是远程主机。任何需要 TTY 的操作（如 `5dive agent auth login`）都要使用 `ssh -t`。

---

## 安全与隔离

每个智能体对应一个 Linux 用户，并处于三档隔离级别之一：

| 级别 | 权限 |
|------|------|
| `standard`（默认） | 可共享读取，写权限受限 |
| `admin` | 可访问整台主机；全新主机上的第一个智能体会自动获得此级别 |
| `sandboxed` | 只能访问自己的 home，无 sudo，并受 systemd 资源限制 |

```sh
sudo 5dive agent create my-agent --type=claude --isolation=sandboxed
```

**没有中间商。** 5dive 运行在你的服务器上。鉴权 token 直接发送给模型 provider，绝不经过我们。没有遥测、错误上报，也没有任何使用数据离开主机。长文说明：[你的鉴权 token 不会经过我们 →](https://blog.5dive.ai/blog/your-auth-tokens-dont-touch-us/?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh)。

---

<details>
<summary><b>更多团队运维——账户、共享 bot、命令和角色</b></summary>

### 克隆一家现成的公司

不必一个一个拼团队，一条命令即可导入整套组织：

```sh
sudo 5dive team import solo-founder
# 拉起所有智能体、各自角色和组织架构，并预置初始任务队列
```

用 `5dive team ls` 浏览模板，或在 `5dive.yaml` 中自行定义后运行 `5dive up`。模板就是一家可以 fork 的公司：研发小组、研究台、内容工厂、客服班组。克隆它，接上你的 key 和 bot，即可完成。

### 给它们派活

同一主机上的智能体共享一个任务队列（SQLite，无需服务器）。创建并分派任务后，heartbeat 只在确实有工作时唤醒负责人。周期性模板则按 cron 计划生成任务：

```sh
5dive task add "triage overnight CI failures" --assignee=ops --recurring="0 7 * * *"
sudo 5dive heartbeat on ops --every=30m
```

当智能体遇到只有人能决定的问题时，它会把任务停在你这里：

```sh
5dive task need DIVE-42 --type=approval --ask="Ship pricing v2?" --options="ship|hold" --recommend=ship
```

Telegram 会收到可点选的回答按钮。点一下，负责该任务的智能体就会解除阻塞并继续工作。`5dive task inbox` 列出所有等待人工处理的事项，`5dive org` 则维护汇报关系，让你知道谁为谁工作。

### 账户（共享鉴权配置）

一次登录，多个智能体复用：

```sh
sudo 5dive account add   work
sudo 5dive account login work --type=claude
sudo 5dive agent create agent-a --type=claude --auth-profile=work
sudo 5dive agent create agent-b --type=claude --auth-profile=work
```

重命名或轮换账户时，所有绑定的智能体都会自动重新绑定。`5dive account usage` 显示每个账户的限流余量。

### 整支团队共用一个 bot

不一定要为每个智能体单独准备 bot。把一个共享 bot 接入已启用话题功能的 Telegram 群组，每个智能体都会获得自己的论坛话题：

```sh
sudo 5dive agent team-bot shared --group=<chat_id> --agents=coder,writer,pm --token=<bot-token>
```

新智能体会自动接入并创建独立话题（可用 `--no-team-bot` 为单个智能体关闭）。`team-bot discover` 会帮你找到群组 ID，`team-bot intercom` 则把智能体间的对话镜像到专用话题，方便观察团队协作。

### 导入角色

模板提供岗位，而 **character pack** 提供人格：一套现成的角色设定，包含独特的声音、模型、思考强度和技能包。

```sh
sudo 5dive agent marketplace ls            # 浏览 character-pack 仓库
sudo 5dive agent import olivia --as=ceo    # 从 pack 创建具名智能体
```

`--as` 是该智能体在你主机上的名字；pack 会提供人格、模型和技能。导入时加 `--channels=telegram` 可同时配置 bot。Pack 位于 [`5dive-ai/character-packs`](https://github.com/5dive-ai/character-packs) 仓库，`5dive.yaml` 也可以通过 `pack: <slug>` 引用。

### 查看组织层：`5dive ui`

CLI 自带一个 Web 界面。无需安装、无需构建、无需账户：

```sh
5dive ui                 # http://127.0.0.1:8735
```

针对你所在主机的三个视图：

- **组织架构（Org chart）** 谁向谁汇报、每个智能体手上有什么，以及看板上每一次正在进行的交接：谁派的活、谁在做、谁来验收。标题会计数其中有多少次交接是智能体之间直接完成、没有经过人的。
- **队列（Queue）** 每一条未关闭的任务、负责人、验收人，以及 maker 到 verifier 的交接进展到了哪一步。
- **闸门（Gates）** 哪些事项停在人那里、处于哪个层级，以及提问智能体建议的答案。

界面只读，并绑定到 loopback（没有登录，因此除非设置 `FIVE_UI_ALLOW_REMOTE=1`，`--host` 会拒绝可路由的地址）。任何会改变状态的操作都有对应的 CLI 命令。`5dive ui --data` 会输出视图渲染所用的同一份 JSON，方便你把它传给其他工具。

### 命令参考

```
5dive agent list / create / start / stop / restart / rm
5dive agent send <name> <text>
5dive agent ask  <name> <text> [--timeout=120]
5dive agent logs <name> [--follow]
5dive agent config <name> set model=<id> / effort=<low|medium|high|xhigh|max>
5dive agent <name> tui

5dive company                            # 搭建一家自主运转的公司
5dive goal add "<outcome>"                # 将结果转成带护栏的任务图
5dive loop spawn --role=<r> --agent=<a> --prompt="<work>"
5dive council convene "<question>" --mode=adversarial
5dive trace <task>                       # 从起点到结论的因果时间线
5dive memory search "<query>"             # 搜索带来源的长期知识
5dive acp                                # 连接 Zed、Buzz 等 ACP 客户端

5dive task      add / ls / assign / start / done / need / inbox / answer
5dive heartbeat on / off / ls / tick     # 唤醒有排队任务的智能体
5dive org       set / tree               # 谁向谁汇报
5dive ui                                 # 浏览器中的三个视图（见下文）

5dive account   add / login / list / show / usage / rename / remove
5dive auth      set / login / status     # 底层接口；人通常使用 account
5dive skill     add / list / remove
5dive doctor [--repair] [--json]
5dive watch                              # 类似 htop 的实时视图
5dive up / down / ps / export            # 通过 5dive.yaml 声明式管理智能体
5dive team import <slug>                 # 一条命令开通整支团队模板
5dive push <task> [--branch=<b>]         # 通过你自己的 GitHub App 委托 git push（见下文）
5dive self-update                        # 更新 CLI 和插件，然后重启智能体
```

完整参数见 `5dive --help`（或 `5dive <verb> --help`），或查阅可搜索的文档 [5dive.ai/docs/5dive-cli](https://5dive.ai/docs/5dive-cli)。任意命令加 `--json` 即可获得机器可读输出。

</details>

<details>
<summary><b>自行托管、主机加固与其他安装方式</b></summary>

### 加固你的服务器

5dive 运行的智能体拥有 shell 权限，因此应遵循常规安全实践：

- 及时修补操作系统（`unattended-upgrades`）
- SSH 只允许密钥登录，并禁止 root 直接登录
- 防火墙默认拒绝
- 使用每智能体隔离级别
- 配置 Telegram bot 白名单

基线工具：[devsec.os_hardening](https://github.com/dev-sec/ansible-collection-hardening) · [Lynis](https://github.com/CISOfy/lynis) · [fail2ban](https://www.fail2ban.org/)。或者跳过这些清单，由 [5dive.ai](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh) 代为处理。

### 委托 git push（带你自己的 GitHub App）

智能体可以读写仓库，但不应该持有能被外泄的 Git 凭据。`5dive push` 为整支团队提供**一个**有范围限制的 push 身份——你自己的 GitHub App——由控制平面保管，只在一次受闸门控制的 push 中出借，绝不把 token 交给智能体。

```sh
sudo 5dive push setup                              # 生成脚手架并校验凭据
5dive push <task> --branch=<feature-branch>        # 任务的闸门放行后即可 push
```

它的工作方式，以及为什么可以放心交给智能体：

- **你的 GitHub App，你的密钥。** 在你的组织里创建一个 GitHub App（`contents:write`），安装到你要发布的仓库，并把密钥放在 `/etc/5dive/connectors/github-app.{pem,env}`（root-600）。代码是通用的，可以指向任何 App。没有按智能体的席位，也没有长期 PAT。
- **闸门把关。** 只有当任务携带由人或其指定的审核人放行的 ship 闸门时，push 才会执行。root 路径会校验签名闭环；没有闸门、闸门未放行/被拒、自动放行、无关智能体的回答，或记录被篡改 → 一律拒绝。
- **只 push 一个分支。** 只 push 任务中写明的分支（`--branch`，或正文里的 `Branch: <name>` 行）；受保护分支（`main`/`master`）会被拒绝。
- **作者可以保持是你（可选）。** 配置提交者（`GITHUB_APP_COMMIT_AUTHOR`）后，fail-closed 扫描会要求每个被 push 的提交都与之匹配，让 provider 的团队检查（如 Vercel）保持绿色；不配置则不做限制。App 只作为传输层鉴权，与提交作者身份解耦。
- **智能体永远不持有 token。** 闸门复核、作者扫描、铸造仓库范围的短期 token、push、丢弃 token，全部在一个仅 root 可用的 helper 中原子完成。token 的作用范围只有目标仓库，即使被截获也够不到组织的其余部分。每次 push 都会记入审计日志。

完整演练（创建 App、安装、放置凭据、配置授权、首次 push）：**[docs/delegated-push.md](docs/delegated-push.md)**。

### 其他安装方式

**[Docker](docker/README.md)。** 无需安装到主机即可试用：

```sh
docker build -f docker/Dockerfile -t 5dive .
docker run -d --name 5dive-demo --privileged 5dive
docker exec -it 5dive-demo bash
```

**离线 / 隔离网络。** `install.sh` 从 `$REPO` 读取文件（默认使用 GitHub raw）。将其改为 `REPO=file:///path/to/local/tree`，并预先安装 apt 依赖。所有要获取的文件都列在 `install.sh` 顶部。

**更新。** 5dive 不会自动更新，代码何时变更由你掌控：

```sh
sudo 5dive self-update
```

这会刷新 CLI、hooks、技能和插件，再重启每个运行中的智能体以加载新版本。希望定时运行？

```cron
0 4 * * * /usr/local/bin/5dive self-update >/dev/null 2>&1
```

**上下文老化。** 长会话会逐渐退化——上面的每日 `self-update` 也会重启智能体，让每次会话保持新鲜。Claude runtime 智能体会把项目记忆保存在 `~/.claude/projects/<dir>/memory/`，重启后仍然存在。会话会重置，知识不会丢。

### 环境要求

- 带 `systemd` 的 Linux（推荐 Ubuntu 22.04+）
- 安装需要 root（安装器会用 apt 安装 `jq`、`tmux` 等依赖）

没有 systemd / root，或不是 Linux？请使用上面的 Docker 镜像。

### 报告安全漏洞

请使用 GitHub 私密报告功能：**[报告安全漏洞 →](https://github.com/5dive-ai/5dive/security/advisories/new)**，不要创建公开 issue。我们会在 3 个工作日内确认。范围包括 `5dive` CLI、`install.sh`、随附的 systemd unit 和 `5dive-ai/*` 工作流；上游编程智能体 CLI（`claude`、`codex` 等）以及 apt/Node 的问题请交给各自维护者。

</details>

<details>
<summary><b>JSON / 机器可读输出</b></summary>

每条命令都接受 `--json`。成功时输出 `{ok:true,data:...}`，失败时输出 `{ok:false,error:{code,class,message}}`。退出码与 `error.code` 一致，shell 管道无需解析文本即可分支。进度信息写入 stderr，stdout 始终是合法 JSON。

```json
{ "ok": true,  "data": [ {"name": "main", "type": "claude", "active": "active"} ] }
{ "ok": false, "error": { "code": 4, "class": "not_found", "message": "no agent named 'foo'" } }
```

</details>

<details>
<summary><b>更喜欢托管控制面板，而不是 ssh？</b></summary>

CLI 是开源入口。这里的每个命令、每个智能体、每台主机，都由 `/usr/local/bin/5dive` 驱动。

如果你更喜欢点击操作，而不是使用 `ssh`，[5dive.ai](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh) 是托管版本：底层使用同一条 CLI，但 VM、主机加固、更新和控制面板都由我们维护。

<video src="https://cdn.jsdelivr.net/gh/5dive-ai/assets@main/hero-demo.mp4" autoplay loop muted playsinline width="100%"></video>

</details>

---

## 参与贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.md)。仓库根目录的 `5dive` bundle 由 `src/` 通过 `./build.sh` 构建，CI 会检查两者不存在漂移。

## 许可协议

MIT。见 [LICENSE](LICENSE)。

## 支持这个项目

如果 5dive 对你有用，点个 ⭐ Star——这是我们判断该往哪走的最直接信号。有想法或 bug，欢迎开 [issue](https://github.com/5dive-ai/5dive/issues)，或来 [Telegram](https://t.me/ai5dive) / [Discord](https://discord.gg/aU2UQC9Myy) 找我们。
