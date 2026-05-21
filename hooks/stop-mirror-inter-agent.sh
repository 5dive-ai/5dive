#!/usr/bin/env bash
# Stop hook: retired (intentional no-op).
#
# This used to mirror THIS agent's transcript text into the operator's group
# at end-of-turn whenever the inbound was a [5dive-msg from=X id=Y] envelope.
# Paired with the receiver-side userprompt-mirror-inter-agent.sh, it covered
# both sides of an inter-agent exchange in the group.
#
# Both halves of that scheme are now superseded by sender-side mirroring in
# the CLI itself (mirror_interagent_outbound in cmd_agent.sh, called from
# cmd_send and cmd_ask). The literal payload of every `5dive agent send|ask`
# is posted under the SENDER's bot via that path, so the group already sees:
#   • A's question to B (posted by A's outbound mirror, under A's bot)
#   • B's reply to A   (posted by B's outbound mirror, under B's bot)
#
# Keeping this hook also wired produced a third, redundant message per turn:
# the same reply payload echoed as transcript narration. Confirmed in local
# test 2026-05-21 — the duplicate cluttered the operator's group.
#
# Kept registered (rather than removed from settings.json) so existing agent
# configs that still reference this path don't error on a missing command.
# New-agent settings.json no longer wires this hook (see agent_setup.sh).
exit 0
