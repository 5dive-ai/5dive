# Fleet Supervisor / Self-Healing Recovery Layer — Design (DIVE-724)

**Status:** design draft, pending lodar approval to phase the build
**Target:** 5dive CLI v0.5 flagship (next major bump; currently 0.4.6)
**Owner:** main

## 1. Why this is the flagship

Recovery is 5dive's #1 moat: *the model never dies, the agent does.* Today that moat is
real but **heuristic and fragmented** — we have the pieces, no unifying brain:

- `cmd_heartbeat.sh` — reclaim/idle/spread + carry-over nudges.
- `cmd_watch.sh` — htop-style live view (read-only, human-driven).
- `cmd_loop.sh` — per-loop token ceiling, self-halt + escalate-with-proof.
- `tasks_db.sh` — `stuck` column + `loops --stuck/--escalate-stuck` board (DIVE-478).
- rotation, transient-error auto-resume, `cmd_doctor.sh` health, connectord tunnel.

The honest gap (stated to marketing 2026-06-26): **telling a wedged agent from a slow one
is still more art than science, and recovery actions are scattered with no ladder, no
audit, no single escalation contract.** This task turns that into a product:
`5dive supervisor` — "your agents survive the night and heal themselves."

## 2. Architecture: one brain, four stages

A single supervision loop (cron-driven, like heartbeat — NOT a long blocking foreground
poll, per `feedback_no_blocking_poll_loops`) that runs **detect → classify → act →
escalate** per agent, writing every decision to an audit trail.

```
  cron tick ──► for each live agent ─► [DETECT signals] ─► [CLASSIFY] ─► [ACT up ladder] ─► [ESCALATE if exhausted]
                                              │                                                      │
                                              └──────────────── supervisor_events (audit) ───────────┘
```

Reuse, do not rebuild. The supervisor is the layer ON TOP of heartbeat/rotation/
auto-resume/loops — it *decides and sequences*; the existing primitives *execute*.

## 3. DETECT — health signals (per agent)

| signal | source | meaning |
|---|---|---|
| systemd state | `systemctl is-active 5dive-agent@<n>` | process alive at all |
| tmux session liveness | `tmux has-session` | the persistent CLI pane exists |
| last-token-progress ts | loop_runs / transcript tail | is work actually advancing |
| loop stuck flag | `tasks_db.stuck` | a loop self-flagged at ceiling/no-progress |
| poller alive | telegram plugin pid/heartbeat | agent can still hear its channel |
| goal-drift | active `/goal` vs recent tool calls | busy but off-task (burns money) |
| CLI staleness | `5dive update --check` | running old code after a bad /tmp clobber |
| auth health | doctor 401 / rotation cooldown | model/account usable |

All cheap, read-only, already individually available — the work is **unifying** them into
one per-agent health record per tick.

## 4. CLASSIFY — stuck vs slow vs healthy

The core unsolved bit. Replace the single heuristic with a composite:

- **healthy** — token progress within window OR legitimately idle (no active task/goal).
- **slow** — active task, tokens still advancing but below expected rate; **do nothing**,
  just record. (Avoid the false-positive that kills a working-but-deliberate agent.)
- **stuck** — active task/goal AND no token progress for `T_stuck`, OR systemd/tmux/poller
  dead, OR loop stuck flag set, OR goal-drift over threshold. Sub-type the cause so the
  ladder picks the right rung.

`T_stuck` and the expected-rate model start as conservative constants (tunable per agent
type) — ship simple, instrument, refine. **Bias toward false-negative** (miss a stuck
agent) over false-positive (restart a healthy one), because restart is disruptive.

## 5. ACT — recovery ladder (least → most disruptive)

Pick the lowest rung that addresses the detected cause; escalate up only on repeat within
a backoff window:

1. **nudge** — inject a carry-over/continue prompt (heartbeat mechanism). For mild
   drift / idle-after-handoff.
2. **resume** — trigger transient-error auto-resume. For "died mid-turn on a 429".
3. **rotate** — rotate model/account. For auth 401 / rate-limit cooldown.
4. **restart poller / restart service** — `systemctl restart 5dive-agent@<n>` (delayed
   `systemd-run` so it survives teardown). For dead poller / wedged tmux / stale CLI
   (pair with self-update).
5. **reprovision** — only for a dead box, and **never auto-executed** (see §6).

Every rung: exponential backoff, max attempts, full audit row.

## 6. ESCALATE — and the HARD-GATE boundary

The supervisor **auto-acts only on reversible, in-box recovery (rungs 1–4).** It MUST
escalate-not-act, never auto-execute, for anything irreversible or money-touching:

- reprovision / box teardown / snapshot-destroy
- billing or capacity actions (route to main/human, per `route_billing_tasks_to_main`)
- any action it has already retried to ladder-exhaustion

Escalation = file a `task need` gate (type=manual/decision) to the owning human with a
crisp **"what I tried"** summary (the audit trail), so the human sees the recovery history,
not just "agent down." This respects `match-insurance-to-recoverability` and the
no-destructive-ops-without-itemized-ask rule.

## 7. OBSERVE — surfaces

- `5dive supervisor` — per-agent health board: state, classification, last action, last
  recovery, next-action-eta. `--json` for the dashboard. `--watch[=secs]` repaints.
- `supervisor_events` audit table (append-only): ts, agent, signal snapshot, classification,
  action taken, outcome. This IS the escalation evidence and the demo artifact.

## 8. Phasing (proposed)

- **P0 (this doc)** — design + gate for approval.
- **P1 — observe-only:** detect + classify + board + audit, **zero auto-actions.** Validates
  the stuck/slow classifier against real fleet behavior with no risk. Ship behind a flag.
- **P2 — auto-act rungs 1–3** (nudge/resume/rotate) — fully reversible. Lockstep 0.5.0.
- **P3 — rung 4 (restart)** + escalation gates once P1 data shows the classifier is trusted.
- **Reprovision stays manual indefinitely** (hard gate).

## 9. Open questions for lodar

1. **Scope of v0.5 flagship:** ship P1+P2 as the 0.5.0 flagship (observe + reversible
   self-heal), holding restart/reprovision for a follow-up? (recommended) — or hold the
   whole thing until the full ladder is built?
2. Fold into existing `heartbeat`/`watch` as `5dive supervisor`, or a new top-level command?

## Related

- Backlog: DIVE-725 (native agent workflows), DIVE-726 (queryable team memory).
- Memory: heartbeat reclaim/idle model, rotation mechanics, transient-error auto-resume,
  loop gate human-enforcement, match-insurance-to-recoverability.
