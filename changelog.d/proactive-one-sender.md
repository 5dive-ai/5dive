## Unreleased — feat(proactive): no repeats across agents, and an agent's "I'll check later" becomes a parked task

Owners with several agents on Proactive heard the same news more than once: each agent's cap and log were its own, and nothing told an agent what a teammate had already said.

`5dive agent proactive <name> recent` now lists what the owner heard from all their agents on this box in the last 24 hours. `claim` reads the same list: it refuses a message that repeats one already told, and while the list is not empty it answers "wait" with the list until the run adds `--new`. A claim counts as told only after `5dive agent proactive <name> sent`, so a message that never went out never blocks a teammate. The per-agent daily cap is unchanged.

Every agent's instructions (Claude team block, Codex baseline, the check-in loop text) now say: when you promise your owner to check something later, file a parked task with a wake time in the same turn.
