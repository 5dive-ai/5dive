<!-- README.zh-CN.md — 简体中文 (DIVE-799)。英文原文见 README.md。 -->

<div align="center">

<h1>5dive</h1>

[English](README.md) ｜ **简体中文**

### 在你自己的服务器上，运行一整支 AI 智能体团队

**编排器就是一段 bash。** 没有框架、没有协议、没有中间人——每个智能体都是一个独立的 Linux 用户，以 systemd 服务的形式运行一个官方智能体 CLI（`claude`、`codex` 等），通过它们共同调用的那一条 bash CLI 协作。它们从共享任务队列领活、在你睡觉时互相派活，只有需要人拍板时才通过 Telegram 戳你一下。

[![Latest release](https://img.shields.io/github/v/release/5dive-ai/5dive)](https://github.com/5dive-ai/5dive/releases) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![install-smoke](https://github.com/5dive-ai/5dive/actions/workflows/install-smoke.yml/badge.svg)](https://github.com/5dive-ai/5dive/actions/workflows/install-smoke.yml) [![GitHub stars](https://img.shields.io/github/stars/5dive-ai/5dive?style=flat&logo=github)](https://github.com/5dive-ai/5dive/stargazers) [![Telegram](https://img.shields.io/badge/Telegram-@ai5dive-229ED9?logo=telegram&logoColor=white)](https://t.me/ai5dive)

**[5dive.ai](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh)** · [快速开始](#快速开始) · [为什么适合中国开发者](#为什么适合中国开发者) · [为什么选 5dive](#为什么选-5dive) · [许可协议](#许可协议)

![5dive 演示：安装一个在 Telegram 上回话的 Claude 智能体](docs/quickstart.gif)

</div>

> **我们自己的公司就跑在它上面。** 一支 AI 智能体团队，彼此分派工作、按组织架构汇报、亲手发布这个仓库的版本，只有卡住时才上报给人。你安装的就是那个二进制——开源内核，MIT 协议，没有 open-core 阉割。自己跑，或者用[托管版](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme-zh)省去运维。

---

## 为什么适合中国开发者

用不了、或不想用 Claude？没关系。`claude` 类型可以把官方的智能体编程框架指向任意 Anthropic 兼容的接口，接你自己的 Key 和国产模型：

```sh
sudo 5dive agent create cheap-coder --type=claude --provider=deepseek --api-key=<key>
# 可选 provider：deepseek（DeepSeek）、moonshot（Kimi）、zai（智谱 GLM）
```

也就是说：用你已经在付费的国产大模型（DeepSeek、Kimi、智谱 GLM、通义千问等），在你自己掌控的服务器上，跑一支 7×24 小时不间断的智能体团队。不依赖境外模型的可用性，数据和密钥都不出你的机器。

## 快速开始

```sh
# 1. 安装
curl -fsSL https://install.5dive.ai | sudo bash

# 2. 创建你的第一个智能体——向导会顺带配好 Telegram：
#    粘贴一个 bot token（找 BotFather 要），给 bot 发 /start，
#    它会自动配对。不需要验证码。
sudo 5dive init
```

要写进脚本（CI、自动化开通）？非交互路径多一步——bot 会在你第一次私聊时回一个配对码：

```sh
sudo 5dive agent create my-agent --type=claude --channels=telegram --telegram-token=<token>
sudo 5dive agent pair   my-agent --code=<pairing-code>
```

## 工作原理

每个智能体都是一个独立的 Linux 用户，以 systemd 服务的形式运行一个官方智能体 CLI 会话（`claude`、`codex`、`antigravity`、`grok`…）。多个智能体可以共用同一个 CLI 二进制和订阅。智能体之间通过调用同一个 `5dive` CLI 来互相通信——这条 CLI 本身*就是*总线。Telegram 等通道按智能体单独挂载。

```text
            一台主机
 ┌──────────────────────────────────┐
 │  coder      writer       pm      │
 │ (claude)   (codex)     (claude)  │
 │    │          │           │      │
 │    └────  5dive CLI  ─────┘      │
 │       send · ask · logs          │
 └──────────────────────────────────┘
        ↕ Telegram / Discord
        （按智能体挂载）
```

没有中间件、没有协议、没有编排器（orchestrator）。共享文件系统，共享 CLI。

## 克隆一家现成的公司

不用一个一个地拼团队。一条命令导入整张组织架构：

```sh
sudo 5dive team import solo-founder
# 拉起所有智能体、各自的角色、组织架构图，并预置好初始任务队列
```

用 `5dive team ls` 浏览模板，或在 `5dive.yaml` 里定义你自己的，然后 `5dive up`。模板就是一家可以 fork 的公司：研发小组、研究台、内容工厂、客服班组。克隆它，接上你的 Key 和 bot，搞定。

## 为什么选 5dive

**一家自运转的公司。** 多个智能体跑在一台主机上，按组织架构图向上汇报。

**给它们一个任务队列。** 共享任务队列、支持周期性任务，外加一个心跳机制——只在智能体有排队任务时才把它唤醒。

**它们上报，你拍板。** 决策以「点一下就回」的按钮形式发到你手机上——智能体自主干活，只在需要人来做决定时才打扰你。

**作为服务运行，而不是一次会话。** 关掉终端，智能体依然活着。随时从 Telegram 给它们发消息。

**支持所有主流智能体 CLI。** `claude`、`codex`、`antigravity`、`grok`、`hermes`、`openclaw`、`opencode`，统统纳入一支团队。

**接你自己的国产模型。** 通过 `--provider` 接 DeepSeek、Kimi、智谱 GLM 等 Anthropic 兼容接口，用你自己的 Key，无中间商、无 OAuth 代理。

**默认安全。** 每个智能体都是独立的 Linux 用户，分三档隔离级别。把一个智能体沙箱化后，它读不到你的 home 目录、也 sudo 不了你的机器。

## 智能体类型

| 类型 | 模型家族 | 鉴权 | 通道 |
|------|---------|------|------|
| `claude`      | Anthropic Claude，或任意 Anthropic 兼容接口（含 DeepSeek / Kimi / 智谱 GLM） | OAuth / API key / `--provider` | Telegram、Discord |
| `codex`       | OpenAI Codex           | OAuth / API key | Telegram |
| `antigravity` | Google Antigravity     | Google OAuth | Telegram |
| `grok`        | xAI Grok               | OAuth (xAI) / API key | Telegram |
| `opencode`    | OpenCode               | API key | Telegram |

`claude` 类型可以把官方框架指向第三方 Anthropic 兼容接口，自带 Key 即可（见上方「为什么适合中国开发者」）。

## 常用命令一览

```
5dive agent list / create / start / stop / restart / rm
5dive agent send <name> <text>
5dive agent ask  <name> <text> [--timeout=120]
5dive agent logs <name> [--follow]

5dive task      add / ls / assign / start / done / need / inbox / answer
5dive heartbeat on / off / ls / tick     # 唤醒有排队任务的智能体
5dive org       set / tree               # 谁向谁汇报

5dive team import <slug>                  # 一条命令开通整支团队模板
5dive up / down / ps / export             # 通过 5dive.yaml 声明式管理
5dive self-update                         # 更新 CLI 与插件，并重启智能体
```

完整参数：`5dive --help`（或 `5dive <verb> --help`）。任意命令加 `--json` 输出机器可读结果。

## 不经手任何中间人

5dive 跑在你自己的服务器上。鉴权 token 直接发给模型厂商，绝不经过我们。没有遥测、没有错误上报、没有任何使用数据离开你的机器。每个智能体都是一个带独立登录的 Linux 用户。

## 环境要求

- 带 `systemd` 的 Linux（推荐 Ubuntu 22.04+）
- 安装需 root（安装器会用 apt 装 `jq`、`tmux` 等依赖）

没有 systemd / 没有 root / 不是 Linux？用 [Docker 镜像](#other-paths)。

## 许可协议

MIT。见 [LICENSE](LICENSE)。
