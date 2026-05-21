#!/usr/bin/env bash
# UserPromptSubmit hook: retired (intentional no-op).
#
# This used to mirror an INBOUND inter-agent message ([5dive-msg from=X id=Y])
# into the shared Telegram group, receiver-side. The problem: it runs on the
# RECEIVER and posts via the RECEIVER's bot, so a message marketing→main showed
# up in the group under main's bot — the wrong sender. With the canonical
# group "call" format (just "@<recipient> <body>"), that misattribution reads
# as the bot addressing itself.
#
# The mirror now lives entirely on the SENDER side, inside `5dive agent send|ask`
# (see mirror_interagent_outbound in the CLI): every outbound call posts
# "@<receiver> <body>" to its own group via its own bot, so each half of an
# exchange shows up under the correct sender's identity. The receiver-side
# Stop hook (stop-mirror-inter-agent.sh) is also retired as a no-op for the
# same reason — it was double-posting the reply payload that the sender's
# outbound mirror already covered.
#
# New-agent settings.json no longer wires this hook. It's kept as a no-op so
# existing agents whose settings.json still reference the path don't error.
exit 0
