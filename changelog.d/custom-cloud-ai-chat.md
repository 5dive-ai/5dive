## Unreleased — fix(agent): a Claude agent on a cloud AI added by its own address hears Telegram and dashboard chat again

An agent added with its own AI address (a cloud vendor 5dive does not list, such as Qwen Beijing) showed "Channels are not currently available", and Telegram and the dashboard chat did not reach it. Since 0.124 every such address got the quiet settings meant for a model in the office, and one of them also switches off the Claude Code feature that carries chat. Now only an address on this server or the office network (or a Tailscale one) gets them, as before; a public cloud address gets none, like a listed vendor.

An account saved before this update keeps the old settings until it is saved again: re-run `5dive account add <name> --provider=custom ... --replace` (or `agent auth set` with the same `--base-url`), then restart its agents. A setting the owner changed by hand stays.
