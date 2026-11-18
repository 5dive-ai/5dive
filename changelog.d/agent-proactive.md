## Unreleased — feat(agent): an agent can message its owner first — `5dive agent proactive <name> off|little|more`

Each agent has a Proactive level, off by default, so every agent behaves as before until its owner turns it on. A little: the agent checks in twice a day and sends at most 1 message a day. More: 4 checks a day, at most 3 messages. A check-in with nothing worth saying sends nothing.

Turning it on makes one loop, "Check in with you", that shows in Tasks > Loops like any other and improves itself. Off pauses that loop and keeps what it learned. The daily limit is kept by 5dive itself, outside the loop's instructions: a check-in run must ask before it sends (`claim`), and once the day's limit is used no further check-in runs start that day. How the owner took the last message (used it, "not now", or no answer) counts toward the loop's score. `5dive agent proactive <name> --json` gives the level, the loop, messages sent today, the limit and the next check.
