# Listing copy (DRAFT: needs lodar's yes before anything is submitted)

Words follow the positioning sheet (2026-10-25): the line is "Hire an AI team
from your phone", and the repo description is quoted as approved.

## Shared

- **App name:** 5dive
- **Version:** the newest 5dive CLI release at build time (the server updates
  itself to the newest one on first boot)
- **Operating system:** Ubuntu 24.04 LTS
- **Suggested plan:** 2 vCPU, 4 GB RAM (DigitalOcean `s-2vcpu-4gb`, Linode
  Shared 4 GB). One small agent runs on 1 GB.
- **Support:** https://github.com/5dive-ai/5dive/issues
- **Website:** https://5dive.ai
- **Source:** https://github.com/5dive-ai/5dive (MIT)

## Short line

Run your own AI team from your phone. Claude Code, Codex and more on your own
server: shared tasks, always-on agents, a small composable bash core. MIT.

## Description (108 words, Linode asks 100-125)

Close your laptop. Your AI team keeps working.

5dive turns this server into a team of AI agents that you own. Each agent has a
name and a job, runs around the clock, and works on the AI plan you already pay
for: Claude Code, Codex, Grok and other agent apps. Agents share one task list,
hand work to each other and check each other's results.

Link the server to the free 5dive app and hire a ready-made team in one tap,
then talk to it from your phone. Or run everything from the command line; no
5dive account is needed.

Own it. Run it from your phone.

## Getting started (DigitalOcean "Getting started" field, Linode docs)

1. Log in to the server over SSH as root (Linode: as the sudo user you chose).
2. The login screen shows one line: open https://5dive.ai/self-host to link
   this server to your 5dive account and hire your team from your phone.
3. Prefer the command line? Run `sudo 5dive init` to set up your first agent.

## Vultr fields

- **One-line description:** the short line above.
- **Readme:** the description above, with two Vultr-only edits (marketing
  review, 2026-11-04): line 2 under the first line is "An open-source
  alternative to Grok Bot and OpenAI Dots." (README pitch), and "Own it. Run
  it from your phone." is cut. Then a last line "Source (MIT):
  https://github.com/5dive-ai/5dive".
- **Categories:** Developer Tool (id 5), Business (id 16). Vultr's list has no
  AI category (`GET /v2/marketplace/apps/categories`, 2026-11-04).
- **Minimum plan:** 1 vCPU / 1 GB (`min_cpu_core` 1, `min_mem_mb` 1024), 2 GB
  recommended: what we told Vultr on 2026-11-03. Cloud Compute only (VPS).
- **Website:** https://5dive.ai/self-host (lodar 2026-11-04: every Vultr link
  field points at the self-host page, not the bare 5dive.ai).
- **Support:** support URL and repo as in Shared; support email
  hello@5dive.ai.
- **App variables:** none.
- **App instructions:**

  > Log in to your server: `ssh root@{{ip}}` (password `{{root_password}}`).
  >
  > The login screen shows one line: open https://5dive.ai/self-host to link
  > this server to your 5dive account and hire your team from your phone.
  >
  > Prefer the command line? Run `sudo 5dive init` to set up your first agent.

- **Icon (light and dark mode):** the app icon, `5dive-frontend`
  `public/icon-512.png` (dark rounded square, white 5; reads on both themes).
- **Gallery (8:5, 800x500 PNG):** the self-host page (phone with a hired
  team), shot at 1280x800 and scaled. Not the home page: it sells the hosted
  trial, not the server.
  Second image: the approved cover "Your AI team. On your own server." /
  "Open source · Free to self-host" (marketing, 2026-11-04).

## Linode assets still owed

Brand colour 1 and 2 (hex), and the 5dive logo as SVG in white and in full
colour.
