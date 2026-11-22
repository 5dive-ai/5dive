# Security

## Report a vulnerability

Use GitHub's private reporting: **[Report a vulnerability →](https://github.com/5dive-ai/5dive/security/advisories/new)**

Please don't open a public issue.

In scope: the `5dive` CLI, `install.sh`, the systemd units it ships, and the `5dive-ai/*` workflows. Bugs in the coding CLIs (`claude`, `codex`, ...), apt or Node go to their own maintainers.

## What leaves your server

**No telemetry.** With no 5dive account, your server sends 5dive only what is listed here.

- Your AI keys go straight from your server to your AI provider.
- Updates ask `api.5dive.com` for the newest version number and send nothing.
- `agent import --report-import` sends the pack's name to count imports. It is off unless you add the flag.

## If you link the 5dive app

**5dive can:**

- ✅ See your agents and their settings: names, models, teams. ([code](https://install.5dive.ai/link))
- ✅ Pass your chat to them. Locked end to end if you turn encryption on (it is off by default). ([code](https://github.com/5dive-ai/5dive/blob/e9ed52f5/src/cmd_chat.sh#L14))
- ✅ Apply what you tap: a new model, removing an agent. ([code](https://install.5dive.ai/link))

**5dive can't:**

- ❌ Read your AI keys, passwords or browser cookies on your server. A key you add in the app waits at 5dive only until your server picks it up (30 minutes at most). ([code](https://install.5dive.ai/link))
- ❌ Open your files. Only files sent in the chat travel. ([code](https://github.com/5dive-ai/5dive/blob/e9ed52f5/src/cmd_dashboard_relay.sh#L137-L152))
- ❌ Get in. The link opens no port on your server: it only calls out. ([code](https://install.5dive.ai/link))

Leave any time:

```sh
sudo 5dive-chat-report --unlink
```

Your agents keep running. Only the app link goes.

## Signed releases

**Update files are signed.** Each release publishes an update file (`5dive-offline-<version>.tar`) for servers with no internet. `5dive self-update --from=<file>` checks its signature against 5dive's offline root key, which ships inside 5dive, and refuses a file that is unsigned, changed, signed by an expired key or by a revoked one. On since v0.125.0.

**Online updates are not signed yet.** `5dive self-update` and `install.sh` download over HTTPS from GitHub and check a SHA-256 published in the same place. That catches a broken or swapped download, but not someone who controls our GitHub account. Until online updates are signed too, review [`install.sh`](install.sh) before you run it as root.
