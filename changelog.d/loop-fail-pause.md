## Unreleased — feat(task): a scheduled job that fails 3 times in a row pauses itself and tells you why

A recurring task whose runs fail three times in a row (each run cancelled after it started: the
agent gave up on it) now pauses itself instead of failing quietly every day. Its template is
parked, so nothing fires until it is resumed, and the owner gets ONE message in that agent's chat:
which job, what went wrong last time in plain words (no task numbers, commit ids or paths), and
"say resume, or tap Resume in the app". If no bot of that agent can reach the owner, the agent
gets a row asking it to send that exact message. A run that finishes resets the count; a run
cancelled before it ever started counts neither way. `5dive task loop resume <task>` (or
`task unpark`) brings it back at its next time with the count cleared. `task ls --recurring`
keeps a paused job listed, status blocked, with `failure_pause: {failed, why, paused_at}` in
`--json`, so the app can show it with a Resume button.
