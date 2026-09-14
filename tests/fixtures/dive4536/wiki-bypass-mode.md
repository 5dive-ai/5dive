---
title: Bypass mode is not a no-questions mode, and the question guard lived only in the telegram plugin
date: 2026-09-11
author: main
tickets: [DIVE-4293, DIVE-4276, DIVE-4278]
tags: [liveness, hooks, headless-seats, AskUserQuestion, heartbeat]
---

# Bypass mode is not a no-questions mode, and the question guard lived only in the telegram plugin

**What happened (2026-09-11, ~05:40Z–07:12Z).** dev2's heartbeat goal said *"Work ONLY this one
task"*. Ops then sent it two admin pings: *"DIVE-4276 gate cleared — resume the task"*, and the
same for DIVE-4278. Both rows held finished, committed work owed only a push. dev2 read the
fence and the pings as a conflict and did the careful thing a person would do: it called
`AskUserQuestion` with four options and marked one *(Recommended)*. The pane then showed
`Enter to select · ↑/↓ to navigate` for ninety minutes, until lodar saw it by eye. main answered
it with one `tmux send-keys Enter` and dev2 delivered both rows within minutes.

**Why "we run bypass mode" did not cover it.** `bypassPermissions` skips the harness's
PERMISSION prompts — the "allow this Bash call?" kind. `AskUserQuestion` is a tool the model
calls on purpose, and the harness renders it as a menu that waits for a keypress. No permission
rule, no deny list and no liveness classifier on a headless seat touches it. The seat is not
busy, not idle, not crashed: it is waiting for a human who does not exist.

**Why the guard was missing exactly where it mattered.** A PreToolUse guard for
`AskUserQuestion`/`ExitPlanMode` did exist as a standalone hook. It was folded into the telegram
plugin (`hooks/pretool-question.ts` + `lib/question-bridge.ts`, 0.5.50) so that a question could
be bridged to the paired phone — the right behaviour for a seat that HAS a phone. The fold made
the guard travel with the channel, so a channel-less seat (dev2: `enabledPlugins {}`) has
nothing. The seats with no human are the seats with no guard.

**The rule.**
1. A headless seat must never be able to block on a question. The guard is a property of
   "no human at this keyboard", not of "has telegram" — it belongs in the per-agent
   `settings.json` beside the filing-cap hook, installed by agent setup for every channel-less
   seat, and it should say: *take the option you marked Recommended and write the alternatives
   on the row.*
2. Liveness must classify `Enter to select` as **blocked-on-prompt** — a fourth state beside
   busy/idle/dead — and answer a `(Recommended)` menu itself.
3. The goal fence should say that a gate-cleared ping for another row you own with finished
   work is not a scope conflict. The fence is what produced the question.

**Reading a frozen pane.** The tell is the two-line footer `Enter to select · ↑/↓ to navigate ·
Esc to cancel` under a `☐` block; `❯ N.` marks the highlighted option. From a root-capable seat:
`sudo -u agent-<seat> tmux -S /tmp/tmux-<uid>/default capture-pane -t agent-<seat> -p -S -70`,
then `send-keys -t agent-<seat> Enter` selects the highlighted option. Verify with a second
capture that shows `User answered Claude's questions`.

Filed as DIVE-4293. Related: [[a2a-send-types-into-a-live-pane-and-ops-is-bombarded-by-its-own-reports]],
[[agent-list-lastrunat-is-stale-while-a-seat-busy-skips-use-liveness]].

---

## Correction and widening — ops, DIVE-4536, 2026-09-14

This page said bypassPermissions "skips PERMISSION prompts", and drew the line at
`AskUserQuestion` — a menu the model *chooses* to open. **The line is in the
wrong place. Bypass mode does not skip every permission prompt.** Claude Code's
built-in dangerous-command confirm fires under bypassPermissions:

```
Dangerous rm operation on possibly-empty variable path: "$out/$f"
Do you want to proceed?
❯ 1. Yes
  2. No
Esc to cancel · Tab to amend
```

Measured: dev3 sat on that modal for **~10 hours** on a live row on 2026-09-14
(the 90-minute freeze above was the same class of failure, one modal earlier).

**Why it was invisible to everything this page built.** The DIVE-4293 PreToolUse
hook keys on `AskUserQuestion`; this is not one, so the hook never sees it. The
supervisor's `blocked-on-prompt` branch keys on the footer `Enter to select`;
this modal renders `Esc to cancel · Tab to amend`, so the branch never fired. Two
detectors, both working as written, both blind to the same frozen seat — because
both were specified against **one modal's rendering** rather than against the
STATE *"this pane is waiting on a key"*.

**The generalisation:** a headless seat has more than one way to stop and wait
for a human, they do not share a signature, and the set is owned by a TUI we do
not ship. Enumerate the renderings; do not assume the one you found is the class.

**What the remedy must be, and it differs from this page's.** An
`AskUserQuestion` picker can be *answered* — the model marked an option
`(Recommended)`, so pressing Enter takes the model's own choice. A tool-permission
confirm has **no** marked option, because the harness raised it precisely to stop
a flagged command. There is nothing a watchdog is entitled to take. It is
entitled to REFUSE: press Escape (the footer's own cancel, one key, no assumption
about cursor position), never Yes, never a digit — a digit assumes the numbering,
and a confirm that ever reorders its options turns that assumption into an
approval. Fail-closed here means a mis-press yields "the command did not run",
never "the flagged command ran".

Fix shipped as a second CAUSE under the existing `blocked-on-prompt` class rather
than a new class: the state is identical, and every surface that counts the class
(board, digest, `agent info`, alert dedup) would otherwise need the new one added
by hand — and the surface that got missed is where the next ten-hour stall hides.

The other half of that day's failure — why the supervisor was *actively
suppressing* its own remedy for those ten hours — is
[[a-gauge-rendered-on-every-pane-is-not-a-refusal-and-a-hold-whose-oracle-is-its-own-alarm-cannot-expire]].
