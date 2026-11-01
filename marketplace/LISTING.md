# Listing copy (DRAFT: needs lodar's yes before anything is submitted)

Words follow the positioning sheet (2026-10-25): the line is "Hire an AI team
from your phone", and the repo description is quoted as approved.

## Shared

- **App name:** 5dive
- **Version:** the newest 5dive CLI release at build time (the server updates
  itself to the newest one on first boot)
- **Operating system:** Ubuntu 24.04 LTS
- **Suggested plan:** 2 vCPU, 4 GB RAM (DigitalOcean `s-2vcpu-4gb`, Vultr
  `vc2-2c-4gb`, Linode Shared 4 GB). One small agent runs on 1 GB.
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
- **Readme:** the description above.
- **Categories:** Developer Tools, AI.
- **App variables:** none.
- **App instructions:**

  > Log in to your server: `ssh root@{{ip}}` (password `{{root_password}}`).
  >
  > The login screen shows one line: open https://5dive.ai/self-host to link
  > this server to your 5dive account and hire your team from your phone.
  >
  > Prefer the command line? Run `sudo 5dive init` to set up your first agent.

- **Icon:** the 5dive logo, square PNG.
- **Gallery (8:5, 800x500 PNG):** the phone app with a hired team, and the
  self-host page. Made when the listing is submitted.

## Linode assets still owed

Brand colour 1 and 2 (hex), and the 5dive logo as SVG in white and in full
colour.
