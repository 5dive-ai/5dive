## Unreleased — fix(usage): count OpenCode seats, and say "unknown" instead of zero for agent types 5dive cannot read

`5dive usage` read only Claude Code and Codex seats. Every other agent type was left out without a word: the report still called itself complete, `5dive usage <seat>` said "no usage", and a daily budget on that seat always passed as "ok".

OpenCode seats are now counted from OpenCode's own message records (input, output with reasoning, cache read and write, per model). Any other type (pi, Hermes, OpenClaw, …) is named on the board as "no visibility — unknown, not zero", `5dive usage <seat>` says so, and its budget check reads "unknown", never "ok".
