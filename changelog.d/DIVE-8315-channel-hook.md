## Unreleased — feat(channels): a plugin can add a chat channel (DIVE-8315)

A plugin can now bring its own way to talk to an agent. Install it, and its channel works like the built-in ones: `sudo 5dive agent create <name> --channels=<its name>`, `agent config`, `local-only allow`, and the Allow/No card for a first message from someone new. `5dive plugin list` shows which channels your plugins add. Telegram, Discord, the dashboard, Buzz and Teams work as before.
