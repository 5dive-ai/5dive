## Unreleased — perf(team): `5dive team freedom --agent=<name> --json` answers in about a second instead of 2.5 to 6

The app's agent settings sheet waits on this read before it shows the Freedom row. It asked the browser plugin twice, started a whole second `5dive` to read Proactive, opened the task board once per stored value, and read every agent's level one by one with a jq per switch.

Now a status asks the browser once (while the board opens), reads Proactive in the same process, opens the board once and reads every stored level in one query. The answer is unchanged, byte for byte. Measured on a 13-agent box: 5.5 s before, 1.0 s after.
