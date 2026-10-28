## Unreleased — feat(agent): a standard seat can peek at a teammate, give a teammate a skill, and run its own heartbeat (DIVE-7143)

A standard seat has no general sudo, so three everyday team acts were out of its reach:
reading a colleague's pane (`agent logs --tmux` runs `sudo -u`), installing a skill into a
colleague's home (`agent skill add` runs `sudo -u`), and enrolling itself in the heartbeat
(`heartbeat on|off` are root-only). Each now has a narrow root verb with one exact sudoers line:

- `5dive agent peek <name> [--lines=N]` (root half `agent _peek`): a fixed tmux capture of a
  teammate's pane, last 80 lines by default, 500 at most.
- `5dive agent skill <to> give <skill> [--replace]` (root half `agent _skill_give`): copies one
  of the caller's own skills into the teammate's skills dir for its harness. Packed as the giver,
  placed as the recipient; regular files and directories only (a symlink or hard link anywhere is
  refused), 5 MB and 500 files at most, and an existing skill is never overwritten without
  `--replace`.
- `5dive heartbeat self on|off` (root half `heartbeat _self on|off`, one line per op, no other
  arguments): enrols or pauses the CALLER, keeping its cadence and fresh setting.

The caller is always derived from `SUDO_UID`. A teammate is a registered, non-sandboxed agent
(isolation not measured counts as sandboxed) that shares a team with the caller in
`team_members`, manages it or reports to it in the org chart, or sits with it under the lead of a
legacy team. Neither verb reaches UP a tier: a standard member cannot read its admin lead's pane
(a key the lead printed would leak) or put a skill in the lead's own skills dir (the lead would
load it as its own instructions, where a member's message reaches it as untrusted data). Every
call is audited root-side, refusals included. The standard grant still
classifies `cli-scoped`.

`tests/agent_rights_unit.sh` covers the grant, every refusal and the happy paths, with five
negative controls that break a scope check in a copy of the source and require the named arm to
go red.
