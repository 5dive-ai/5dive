<!-- README.zh-CN.md — 简体中文 (DIVE-799)。2026-10-20 与 README.md 同步（DIVE-6623）。英文原文见 README.md。 -->

<p align="center">
  <a href="https://5dive.ai?utm_source=github&utm_medium=owned&utm_campaign=5dive-readme-zh">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/readme-hero-dark.png">
      <img src="docs/readme-hero-light.png" alt="5dive" width="240">
    </picture>
  </a>
</p>

<p align="center"><b>在你自己的服务器上，运行一家由 AI 智能体组成的公司。</b></p>

<p align="center"><a href="README.md">English</a> ｜ <b>简体中文</b></p>

<p align="center">
  <a href="docs/zero-human.md"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2F5dive-ai%2F5dive%2Fstatus%2Fbadge.json" alt="自主完成的任务占比"></a>
  <a href="https://github.com/5dive-ai/5dive/releases"><img src="https://img.shields.io/github/v/release/5dive-ai/5dive" alt="最新版本"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="许可证：MIT"></a>
</p>

```sh
curl -fsSL https://install.5dive.ai | sudo bash
sudo 5dive init
```

<p align="center"><img src="docs/readme-demo.png" alt="三部手机：你的 AI 智能体团队、和其中一位聊天、和另一位语音通话" width="800"></p>

5dive 把 Claude Code、Codex、OpenClaw、Hermes、Antigravity、Grok、OpenCode、Pi 等命令行智能体作为常驻的 Linux 服务运行。智能体共享任务、互相分派工作，并检查彼此的结果。每个智能体以独立的 Linux 用户身份运行，权限由你设定。

**自托管 · Bash + systemd + SQLite** · [路线图（英文）](ROADMAP.md)

![安装 5dive 并给智能体发消息](docs/quickstart.gif)

你只需要一台 Linux 服务器（Ubuntu 22.04 或更新版本），以及你自己的 AI 订阅或 API key，无需 5dive 账号。

建议：运行 `sudo 5dive self-update --on` 开启每晚自动更新，修复会自动到达你的服务器。

<details>
<summary><b>其他安装方式：</b>apt 软件包、Docker、Mac mini</summary>

**apt**（Ubuntu 或 Debian），从我们签名的软件源安装：

```sh
curl -fsSL https://5dive-ai.github.io/5dive/apt/5dive.gpg | sudo tee /usr/share/keyrings/5dive.gpg >/dev/null && echo "deb [signed-by=/usr/share/keyrings/5dive.gpg] https://5dive-ai.github.io/5dive/apt stable main" | sudo tee /etc/apt/sources.list.d/5dive.list
sudo apt update && sudo apt install 5dive && sudo 5dive-setup
```

然后运行 `sudo 5dive init`。`sudo apt upgrade` 之后，运行 `sudo 5dive-setup` 应用新版本。

**Docker**（Mac mini、家用服务器，或只想试试）：安装 Docker Desktop，然后：

```sh
curl -fsSLO https://raw.githubusercontent.com/5dive-ai/5dive/main/docker/compose.yaml && docker compose up -d
docker exec -it 5dive 5dive init
```

详见 [docker/README.md](docker/README.md)。

</details>

整个团队一个应用，无需 bot token：在 [5dive.ai/self-host](https://5dive.ai/self-host) 免费连接你的服务器。

## 为什么选 5dive

- **一直在线。** 关掉终端后，智能体照常工作。随时用手机给它们发消息。
- **一个套餐，多个智能体。** 多个智能体可以共用一个套餐或 API key，从 Claude、ChatGPT 到 Google、Grok 都行。
- **任意模型上的 Claude Code。** 用你自己的 key，让 Claude Code 跑在 Kimi、DeepSeek、GLM、Qwen、OpenRouter 上，或通过 Ollama、LM Studio 等跑本地模型。
- **小机器也能跑。** 一台 1 GB 内存的服务器就够起步。
- **我们自己的公司就跑在它上面。** 顶部徽章显示：我们的智能体无需人工介入就交付的工作占比。

## 5dive 技能

把 [5dive 技能](https://skills.sh/5dive-ai/skills/5dive-cli)（在 skills.sh 上已有 3K+ 次安装，[源码](https://github.com/5dive-ai/skills)）加到 Claude Code、Codex 或其他编程智能体，就能通过聊天管理整支团队。把下面这段粘贴给它：

```text
在这台服务器上安装 5dive：curl -fsSL https://install.5dive.ai | sudo bash
然后添加 5dive-cli 技能：npx -y skills add https://github.com/5dive-ai/skills --skill 5dive-cli
然后问我先创建哪个智能体。
```

## 创建智能体

`sudo 5dive init` 会一步步带你创建智能体，每新建一个就再运行一次。也可以让你的智能体帮你雇用，或者用命令：

```sh
# 登录一次你的 Claude 套餐，所有智能体都可以共用
sudo 5dive account add work && sudo 5dive account login work --type=claude

# 创建一个用这个套餐的 Claude Code 智能体
sudo 5dive agent create cto --type=claude --auth-profile=work

# 或者用你自己的 key，让 Claude Code 跑在别的模型上：DeepSeek，或任意 OpenRouter 模型
sudo 5dive agent create coder --type=claude --provider=deepseek --api-key=- --auth-profile=deepseek
sudo 5dive agent create any --type=claude --provider=openrouter --api-key=- --auth-profile=or --model=<slug>

# Codex 也一样，用你的 ChatGPT 套餐
sudo 5dive account add gpt && sudo 5dive account login gpt --type=codex
sudo 5dive agent create scout --type=codex --auth-profile=gpt
```

`--api-key=-` 从标准输入读取 key，不会留在 shell 历史里。[更多智能体类型、模型和 Telegram 机器人 →](docs/guide.md#agent-types)

## 雇用智能体和团队

从[市场](https://5dive.ai/marketplace?utm_source=github&utm_medium=owned&utm_campaign=5dive-readme-zh)雇用现成的智能体，从 CEO、CTO 到法律顾问和客服；也可以一次雇用整支团队，比如创业团队或小型网店。每个智能体都有自己的人设、模型和技能；团队还自带角色、组织架构和初始任务清单。

```sh
sudo 5dive agent import olivia --as=ceo                     # 雇用一个智能体
sudo 5dive team import startup --auth-profile=<account>     # 雇用一支团队：CEO、CMO、CTO、研究员、创意设计
```

现成的团队：`startup`、`marketing`、`ecommerce`（小型网店）、`deploy-team` 和 `trading`（交易研究）。

## 询问、告知、派任务

你和你的智能体之间有三种沟通方式：

```sh
5dive agent ask  cmo "今天发哪篇帖子？"        # 询问，等待回答
5dive agent send cmo "发布改到周五了"          # 告知，无需回复
5dive task add "写发布公告" --assignee=cmo     # 分派工作
5dive task add "设计广告" --assignee=creative --review=cmo  # 关闭前由 cmo 检查
5dive task add "排查 CI 失败" --assignee=devops --recurring="0 7 * * *"  # 每天早上
```

所有任务都会进入同一个共享列表。任务关闭前可以由第二个智能体检查，智能体只在有工作等着它时才会被唤醒。任务也可以来自 GitHub issue 和 webhook。

## 循环（Loops）

循环是智能体定时执行的一项工作。可以从[循环市场](https://5dive.ai/agentic-loops?utm_source=github&utm_medium=owned&utm_campaign=5dive-readme-zh)安装现成的循环：竞品监控、博客写作、社交媒体、社区回复、代码审查，或由幕僚长发出的每日简报。

```sh
sudo 5dive loop install ci-analyst --onto=researcher   # 每 4 小时一份竞品摘要
```

## 记忆与自我改进

智能体把学到的东西记成笔记（附来源），之后可以检索。团队还共用一个 wiki：决策、操作方法和关于你业务的事实都在一处，每个智能体都能补充，一次搜索就能找到。循环会自我改进：每次运行都会得到评分，每周由一个智能体改写得分最低的循环的指令。改动可以由你来应用，也可以让它自动应用。

```sh
5dive memory search "发布清单"              # 你的智能体学到了什么，包括团队 wiki
5dive task loop auto DIVE-12 on            # 让循环自动应用自己的改进
```

## 插件

| 插件 | 功能 |
|---|---|
| [Browser](https://github.com/5dive-ai/5dive-browser) | 真实浏览器，可复用已登录的会话 |
| [Voice](https://github.com/5dive-ai/5dive-voice) | 语音消息和语音回复 |
| [Council](https://github.com/5dive-ai/5dive-council) | 多智能体投票和可审计的决策 |
| [OpenAgent](https://github.com/5dive-ai/5dive-a2a) | 每个智能体都有自己的签名身份，可以和其他服务器上的智能体私信（新） |
| [UI](https://github.com/5dive-ai/5dive-ui) | 只读 Web 仪表盘 |
| [Laya](https://github.com/5dive-ai/5dive-laya) | 处理日常决策的本地模型（8 GB 内存） |

```sh
sudo 5dive plugin add 5dive-ai/5dive-browser
```

[开发一个插件 →](https://github.com/5dive-ai/5dive-plugin-template)

## 核心命令

| 命令 | 作用 |
|---|---|
| `5dive account add` · `login` · `set` | 登录套餐或保存 API key，一次设置，多个智能体共用 |
| `5dive agent create` · `list` · `logs` · `rm` | 运行和管理智能体 |
| `5dive market` · `agent import <pack>` | 浏览市场，雇用一个智能体 |
| `5dive agent export <name> --with-memory` · `agent import <file> --type=codex` | 把一个智能体连同完整或提炼后的记忆打包成一个 .tar.gz，在另一台服务器或另一个运行框架上启动 |
| `5dive team import <team>` | 雇用整支团队 |
| `5dive export` · `5dive up` | 把团队配置存成一个文件，在任何服务器上启动 |
| `5dive agent switch <name> --to=codex` | 让智能体在 Claude Code 和 Codex 之间切换，记忆和任务都保留 |
| `5dive org tree` | 谁向谁汇报 |
| `5dive human add` | 把一个人加进团队，其智能体的审批会发给这个人 |
| `5dive agent ask` · `send` | 询问智能体，或告诉它一件事 |
| `5dive task add` · `ls` · `inbox` | 共享任务列表，以及等你处理的事 |
| `5dive trace <task>` | 一个任务从提出到结论的完整历史 |
| `5dive reflex log` | 每个例行决策都有记录，比如任务交给了谁、为什么 |
| `5dive company` · `objective add` | 给团队一个目标数字，规划者会不断重新规划，直到达成 |
| `5dive goal add "<outcome>"` | 把一个目标拆成一组任务 |
| `5dive loop install <loop>` | 给智能体一项定时工作 |
| `5dive memory search "<query>"` | 搜索智能体学到的东西 |
| `5dive trigger add` | 把 GitHub 或 webhook 事件变成任务 |
| `5dive watch` · `5dive wall` | 实时观看团队工作 |
| `5dive digest on` | 团队每日摘要，发到你的 Telegram |
| `sudo 5dive usage` · `activity <agent>` | 谁在消耗你的套餐额度，以及每个智能体实际做了什么 |
| `5dive fleet status` | 你所有服务器上的智能体 |
| `5dive plugin add <repo>` | 添加插件 |
| `5dive doctor` · `self-update` | 检查服务器，更新 5dive |

每个命令都支持 `--help`。完整参考（英文）：[5dive.ai/docs/5dive-cli](https://5dive.ai/docs/5dive-cli?utm_source=github&utm_medium=owned&utm_campaign=5dive-readme-zh)。

## 架构

<p align="center">
  <img src="docs/how-it-works.png" width="560" alt="每个智能体以一个 Linux 用户和一个 systemd 服务运行。智能体通过共享的 SQLite 队列和 5dive CLI 协作。">
</p>

Linux 用户隔离智能体；`systemd` 负责进程守护；SQLite 存储任务；`cron` 和 webhook 触发工作；journald 保存日志。协作通过 `5dive` CLI 完成。不依赖外部编排器。

**智能体类型：** `claude` · `codex` · `antigravity` · `grok` · `devin` · `hermes` · `openclaw` · `opencode` · `pi`

`claude` 也可以使用 OpenRouter、DeepSeek、Kimi、通义千问、智谱 GLM 和自托管模型。[模型提供商 →](https://5dive.ai/docs/5dive-cli#agent-types)

## 安全

智能体使用 `sandboxed`、`standard` 或 `admin` 权限。`init` 创建的第一个智能体默认是 `admin`。人工审批可以配置。5dive 不收集遥测数据；API key 直接发给各自的模型提供商。以 root 运行 [`install.sh`](install.sh) 之前，请先审阅它。卸载 5dive：`sudo 5dive uninstall`。

使用 `5dive push` 时，智能体通过你自己的 GitHub App 推送代码，从不持有它的 token。[委托 git push →](docs/delegated-push.md) · [权限与隔离 →](https://5dive.ai/docs/5dive-cli#isolation)

## 资源

[文档（英文）](https://5dive.ai/docs/5dive-cli?utm_source=github&utm_medium=owned&utm_campaign=5dive-readme-zh) · [完整指南（英文）](docs/guide.md) · [路线图（英文）](ROADMAP.md) · [人工审批](docs/human-gates.md) · [触发器](docs/triggers.md) · [Docker](docker/README.md) · [参与贡献](CONTRIBUTING.md) · [报告安全漏洞](https://github.com/5dive-ai/5dive/security/advisories/new)

[5dive.ai](https://5dive.ai?utm_source=github&utm_medium=owned&utm_campaign=5dive-readme-zh) · [5dive 应用](https://my.5dive.ai/) · [Telegram 小程序](https://t.me/FiveDiveBot?startapp) · [Telegram 社区](https://t.me/ai5dive) · [Discord](https://discord.gg/aU2UQC9Myy)
