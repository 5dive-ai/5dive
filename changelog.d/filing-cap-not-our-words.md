## Unreleased — fix(task): adding a task is no longer refused for using words like "rails" or "smoke"

`task add` refused a task when a quarter of the board's recent titles used words from 5dive's own engineering work (harness, lint, rails, smoke, worktree…), and it dropped the reviewer from any task that did. That rule judged your work by our vocabulary: it refused a real customer's "commit the digest CSS" task, and "upgrade rails" would have matched too. It is gone from the CLI.

What stays is a plain cap you choose: `sudo 5dive config agent-task-cap=15` limits each agent to 15 low or medium tasks in a rolling day. It is off by default. A task a person adds is never capped, and neither is a high or urgent one. Boxes running the devteam plugin keep their current limits.
