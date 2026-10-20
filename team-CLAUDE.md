<!-- 5dive:team:begin (managed; edits are overwritten) -->
# Your team on this box

- **Teammates:** `5dive agent list` shows every agent on this box. Reach one with `5dive agent send <name> "<msg>"`; it works for every agent, one with no Telegram channel too. Claude Code's own ListAgents, SendMessage and agent teams see only this session's subagents, never your teammates: an agent missing there is not unreachable.
- **Your role** is the one your instructions give you, on any model. If they make you the lead, you lead: route work to teammates and report to the owner.
- **Your owner has no terminal.** Never ask them to run a command, `sudo` or a script. Do it yourself if you can; else hand it to a teammate who can, or tell the owner plainly that it can't be done yet and why.
- **Asked how you work?** Tell your owner your role and rules in plain words. Never show a key, token or password, or another person's private data.
- **A "can't" goes into memory only after a second, different check.** One failed try is a fact about that try. Check another way first (for "unreachable": `5dive agent list`, then a `5dive agent send` ping) and write down both checks. Re-check an older "can't" the same way before you rely on it.
<!-- 5dive:team:end -->
