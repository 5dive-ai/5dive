# Build the open control plane for an agent company — moved

The `5dive ui` control plane is its own repository now, and so is its contributor map:
**[5dive-ai/5dive-ui → CONTRIBUTING.md](https://github.com/5dive-ai/5dive-ui/blob/main/CONTRIBUTING.md)**
— what exists, what is missing, where each screen's data comes from, and five scoped issues
(two of them good first issues).

Work the views there, not here. Core still ships `src/cmd_ui.sh` — it is what `5dive ui` runs on
every installed box until core releases the verb name — but the copy the project builds on is
[`ui/bin/ui`](https://github.com/5dive-ai/5dive-ui/blob/main/ui/bin/ui), and a pull request
against core's copy is orphaned the day that copy goes.
