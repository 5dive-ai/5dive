# Changelog

## Unreleased

- feat(heartbeat/supervisor): fleet-stall self-heal, gaps #2 and #3 (DIVE-1416; gap #1 is DIVE-1415's cascade-unblock fix above). DOGFOOD INCIDENT 2026-07-17: the fleet sat ~100% idle ~3h while actionable v0.10 work was stranded, and NOTHING self-corrected or alarmed — supervisor read "15 healthy / 0 stuck" because "idle while work is stranded" wasn't a signal it modeled at all; a human had to notice. **Gap#2 — maker→verifier deliveries never sit invisible:** `_task_route_to_verifier` now stamps a dedicated `handoff_delivered_at` (reset fresh on every re-delivery after a reject/bounce-back — `updated_at` can't do this, any row touch bumps it); the new `_hb_stall_sweep`'s pass (a) flags any delivery still unacknowledged (`handoff_ack_at` NULL) past `HEARTBEAT_VERIFY_STALE_MIN` (default 60m) and pings BOTH the verifier and main, throttled once per delivery via `handoff_stale_pinged_at`. **Gap#3 core — fleet-idle-while-actionable-work-is-open alarm:** pass (b) tracks, in `task_prefs`, how long the fleet has had zero `in_progress` tasks and zero running loops while at least one todo task or fleet-actionable human gate sits open; once that's persisted past `HEARTBEAT_STALL_MIN_MINUTES` (default 30m, the design's "K min") it alarms main — re-alarming on the same cadence while it holds (never silent), clearing the moment the fleet is busy again. A gate only counts as stranded when it's tier<=1 (an agent can clear it) or was never surfaced to the human at all (`need_asked_at` AND `gate_pinged_at` both NULL) — a PINGED tier-2 gate genuinely awaiting the human (e.g. overnight) is parked, not stranded, and must not re-alarm main every cycle (review amendment: the same idle-night alert-fatigue class already killed once). **Gap#3 canary — pinger liveness:** pass (c) is a DELIBERATELY independent re-check of whether the gate-ping TTL reminder batch (DIVE-1434: it silently stopped writing `gate_pinged_at` fleet-wide and nothing noticed for days) is actually still alive — eligible-for-ping gates existing while `MAX(gate_pinged_at)` hasn't advanced fleet-wide in over an hour trips it. **Supervisor "idle+stranded" class:** the per-agent classify chain in `cmd_supervisor.sh` is factored out into a pure `_sup_classify` (mirrors the existing `_sup_act_plan` pattern — directly unit-testable, no systemctl/tmux/pgrep stubbing needed) and gains a new `stalled`/`idle-stranded` class: an agent with NO active work (no in_progress, no running loop) but an old todo task (`SUPERVISOR_T_STRANDED_MIN`, default 45m) still sitting assigned to it, previously indistinguishable from legitimate idle. Observe-only, same posture as slow/drift/update-pending — never feeds the P2 act ladder. Additive schema: `tasks.handoff_delivered_at` + `handoff_stale_pinged_at`. +23 cases in `tests/heartbeat_stall_sweep_unit.sh`, +15 in `tests/supervisor_classify_unit.sh`.
- fix(task-engine): completing a blocker via a NON-`task done` terminal close now cascade-unblocks its dependents too (DIVE-1415). DIVE-1355 wired `_task_cascade_unblock` only into `_task_status_cmd` (the `done`/`cancel` verbs), so a task closed through any OTHER terminal path left its dependents stuck `blocked` behind a satisfied edge — the stall that froze OSS-32/OSS-33 behind OSS-27 for ~3h overnight (OSS-27 closed via `task verify` PASS, so the cascade never ran). Added the cascade to the three missed close paths: `task verify` auto-done (the OSS-27 path), a manual-gate answer that closes the task done, and a loop RUN / loop GATE-step terminal close (cross-DAG dependents the loop-advance never touches). The heartbeat `_hb_blocked_sweep` safety-net still repairs pre-existing rot; this makes the EVENT cascade fire on every terminal close so stranded work never waits for a sweep. Same guardrails inherited (never a parked task, never an unanswered human need-gate). +4 unit cases in `tests/task_cascade_unblock_unit.sh` (T9/T9b/T9c/T10), 16/0 total.
- feat(objective): `5dive objective status <name>` (+ `--json`) renders a read-only v0.10 dashboard over a running self-steering objective loop: target, current, trend, signed gap (per direction), current cycle + outcome, active roles (open originated-task assignees + planner), verified-this-cycle, spend vs ceiling/budget, and next gate or an explicit stop-reason (never a silent blank). Integrity boundary: it never runs the metric-cmd and never originates or mutates, and 'verified this cycle' counts ONLY originated tasks a distinct verifier accepted (status=done), never the planner cycle's self-reported outcome (the anti-Goodhart point, the company cannot fake its own progress). Reuses the existing `_objective_trend` / `dbfmt` / dispatch; `tests/objective_status_unit.sh` 14/0, siblings unchanged (objective_unit 13/0, objective_replan_unit 23/0). MVP item 7 of the v0.10 self-steering line (OSS-31/OSS-32).
- feat(init): `5dive init` for `--type=openclaw` now offers a BYO provider + API-key path, not just the OpenAI /codex/device oauth (DIVE-1390). openclaw defaulted to the device-code sign-in, which dead-ends when the OpenAI account is blocked for inference — with no escape hatch, even though the dashboard already offered BYO. openclaw now gets its own auth branch (split out of the `openclaw|antigravity|grok` oauth-only lump): an `_init_pick` between "Sign in with OpenAI" (unchanged device-code flow) and "Bring your own provider", where BYO picks a provider from the `OPENCLAW_PROVIDER_ID` catalog (openrouter/anthropic/openai/google/deepseek/moonshot/qwen/minimax/huggingface/zai — `nous` omitted, no native id) + key and writes it via the existing `agent auth set openclaw --api-key=- --provider=<id>` → `_apply_byo_openclaw` path (no new capability, init parity only).
- fix(task-engine): a persona/character-pack QUEUE-READINESS approval on our early-stage content surfaces (OpenAgent / character-packs / the daily persona drip) is no longer floored to a hard-human gate on the word 'publish' — it is downgraded to a lead-routed tier-1 and routed to the org lead, the mirror of the DIVE-1359 eng-ship class (DIVE-1381, surfaced by DIVE-1366). The T2 category floor matches 'publish' in the ask/title and forced these curation approvals hard-human (unclearable by the lead, since tier-2 is human-only), even though ship-gating classes OpenAgent/character-packs as early-stage = safe to push, no approval gate to the paired human. New `_gate_content_curation_hit` classifier (persona / character-pack / openagent / promote-queue / drip-queue / curat* / skill-set / gallery-pack) plus a residual-floor re-test: the carve-out fires ONLY when the sole reason the floor tripped was a content-publish-LATER term (`_GATE_CONTENT_PUBLISH_RX` = publish / public post / announce / launch post — the actual publish happens downstream via the drip, not now). The true-human floor still WINS for a genuine publish-NOW / brand / press / customer-comms (newsletter/blast) / money / secret / destructive ask (re-tested with only the publish-later terms stripped), a lead's own curation gate is exempt (no distinct reviewer), and a non-curation 'publish' ask still floors. Routing is intrinsic to the kind, so it bypasses the OFF-by-default `gate_builder_routing` pref. +9 unit cases (`gate_ship_routing_unit` 43/0).
- feat(objective): loop PREFLIGHT + explicit STOP-CONDITIONS (OSS-33, OSS-31 MVP items 4 & 5) — the guards that make a self-steering objective safe to leave running unattended. **Preflight** refuses to `resume`/drive an objective whose planner ROLE cannot do the work, always with a machine reason + a human detail (never a silent no-op start): `role_unassigned` (no planner and no org coordinator), `role_unreachable` (planner not in a populated org chart), `missing_verifier` (the planner is the only agent in the org, so nothing it builds could ever be graded by a distinct verifier), `over_budget` (spent ≥ budget), `role_asleep` (planner unit desiredState=stopped), and `role_unauthenticated` (planner has no auth profile or rotation account) — the last two best-effort from the agent registry, degrading to a pass when it is unreadable. Preflight is deliberately CONSERVATIVE: a bare box with no org chart and no configured planner is "not yet org-wired" (single-operator/manual), so it PASSES with an advisory and never false-fails. `5dive objective resume <name> --force` (and `objective replan --force`) bypass a refusal for a deliberate human. **Stop-conditions** add the two reasons OSS-27 did not cover, so the autonomous loop never spins silently: a still-pending approval gate from a prior cycle (a Tier-2 hard gate awaiting a human, or a Tier-1 checkpoint awaiting a lead/precedent clear) → `gate_pending` (the loop WAITS instead of stacking a fresh proposal on one not yet approved), and metric flat/adverse across the last N cycles → `no_progress` (the objective is PAUSED — a genuine terminal state so the heartbeat stops respinning — with an explicit reason; `--no-progress-limit=N`, default 3, 0=off). All guards run on the AUTONOMOUS path only (a live planner is about to be invoked); a manual `--diff`/`--from-gate` remains an operator override. Each guard appends an `objective_cycles` audit row with its outcome. No schema change. Stacks on OSS-27 (`objective replan`); the `0.10.0` tag stays gated on the full v0.10 line (status surface, `company` sugar, dogfood-green on our own funnel metric).

- fix(agent-create): validate a pi `--model` against pi's live registry so a stale or misspelled slug fails create loudly instead of pinning a dead default (DIVE-1402, pi twin of DIVE-1395). `pi_apply_model_default` merged any `--model` into the agent's `settings.json` `defaultModel` blindly; a slug pi's registry does not carry (e.g. `google/gemini-2.0-flash-lite-001`, which pi lacks — it carries `google/gemini-2.5-flash-lite`) left the fresh agent booting without the intended model. New `pi_validate_model_or_fail` enumerates pi's catalog (`pi --list-models` with the provider key injected, a no-completion metadata read, filtered to the provider column with pi's leading `~` alias marker stripped) and rejects an absent slug with the closest same-provider matches. Fail-OPEN: a missing key, an offline `pi --list-models`, or an empty listing skips the check so create is never blocked on a transient; a `:<thinking>` suffix is compared on the slug alone. New `pi_catalog` + `pi_validate_model_or_fail` helpers (`PI_BIN`-overridable for tests); +7 `pi_auth_provider_unit` cases (26/0), verified end-to-end against the real 270-model openrouter catalog (QA slug rejected with suggestions, `gemini-2.5-flash-lite` accepted).
- fix(agent): a fresh pi agent created against a gateway provider no longer boots to "No models available" (DIVE-1396, re-file of DIVE-1385). `agent create --type=pi --provider=openrouter --api-key=…` writes the provider's key (`OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY`, …) into the single pi connector `/etc/5dive/connectors/pi.env` (`TYPE_API_FILE[pi]=pi.env`), but the systemd template `5dive-agent@.service` loaded the anthropic/openai/gemini connectors and never `pi.env`, so the key never reached the pi process — pi's model registry found no authenticated provider, `getAvailable()` returned 0, and the TUI booted to "No models available" with no runnable model. A regression from DIVE-1200 (the pi connector was introduced but the unit template was not updated); opencode escaped it because `TYPE_API_FILE[opencode]=openai.env`, which the unit already loads. Fix: add `EnvironmentFile=-/etc/5dive/connectors/pi.env` (optional `-` form, so a box with no pi.env still boots cleanly) plus a `pi_auth_provider_unit` assertion that keeps the unit's connector line and `TYPE_API_FILE[pi]` in lockstep (19/0). Proven empirically with pi 0.80.6: no key → the exact "No models available", key present → 270 openrouter models; the invalid-slug path emits a different diagnostic ("No models match pattern"), confirming the reported symptom is env propagation, not the model slug.
- fix(agent-create): validate an opencode `--model` against opencode's live catalog so a stale or misspelled slug fails create loudly instead of silently degrading the agent (DIVE-1395, re-file of DIVE-1384). Root cause: opencode ignores a pinned model it cannot resolve and falls back to an unrelated default (often an image model), which then answers a real tool-using task with "No endpoints found that support tool use." The reported case pinned `openrouter/google/gemini-2.0-flash-lite-001`, a slug absent from opencode's models.dev catalog (it carries `gemini-2.5-flash-lite` etc.), so the fresh agent booted onto "Nano Banana Pro" and could not run tools. `opencode_apply_model_default` now enumerates the authenticated provider's catalog (`opencode models` with the api-key injected, a metadata read that charges no completion) and rejects an absent slug with the closest same-provider matches. It is fail-OPEN: a missing key, an unreachable catalog, or an empty listing skips the check so a models.dev outage or catalog lag never blocks create. New `opencode_catalog` + `opencode_validate_model_or_fail` helpers (`OPENCODE_BIN`-overridable for tests); +5 cases in `opencode_openrouter_unit` (17/0), verified end-to-end against the real catalog (QA slug rejected, `gemini-2.5-flash-lite` accepted).
- fix(agent): fresh `--type=hermes` agents no longer boot unconfigured onto the Nous "hermes setup" wizard after a BYO provider create (DIVE-1394). Two defects compounded: (1) the boot-time seed in `5dive-agent-start` read the shared/profile `config.yaml`+`auth.json` with **sudo-only** `test`/`cmp`/`cat`, but standard-isolation agents have NO passwordless sudo — so for every default (non-admin) hermes agent the seed silently no-op'd and the agent started with no provider (this is the codex/grok DIVE-1188 failure that was never propagated to the hermes seed); and (2) on the no-profile path the shared `/home/claude/.hermes/{config.yaml,auth.json}` stayed mode 0600 owner=claude, unreadable by the group-member agent even once the seed tried a plain read. Fix: `seed_one` now tries a plain group read first and only falls back to `sudo -n` for a not-yet-normalized 0600 file on an admin agent (mirrors codex/grok), and `cmd_create` normalizes the shared no-profile seed source to 0640 g=claude (the profiled path was already normalized by `normalize_profile_seed_perms`). The installer-truthfulness half of the report (upstream Nous `install.sh` mis-reporting build-tool status / npm timeout) is upstream and out of scope for this fix.
- feat(task-engine): maker→verifier handoffs now expose a durable `delivered` → `reviewing` receipt (DIVE-1378). Routing work records `delivered`; only the assigned verifier's own `task start` emits the one ACK and timestamps `handoff_ack_at`, so message delivery or a third-party status change cannot masquerade as review running. `task ls --json`, `task show`, and `task loops` expose the state without adding a second full task FSM.

- feat(task-engine): `task start` runs a fail-loud preflight that surfaces identity/auth/repo gaps UP FRONT, before the agent burns a turn discovering them mid-task (DIVE-1375, Bobby gripe #3). Every check is best-effort and ADVISORY — it prints `warn: preflight:` heads-up lines to stderr and NEVER blocks the start (fail-open). Checks, from the caller's cwd: (1) assignee mismatch (the heartbeat only wakes the assignee, so a start by someone else is flagged as a possible mis-claim); (2) an unanswered human need-gate open on the task, which will make `task done` REFUSE to close it (DIVE-555) — better to learn before doing the work; (3) git dubious-ownership (git refuses the repo), the exact wall Marcus hit on DIVE-1356, handed the one-line `git config --global --add safe.directory` fix; (4) a DIRTY worktree (uncommitted paths a commit could sweep on a shared checkout); (5) unset `git user.email` that would trip the remote author check (Vercel team gate); and (6) an offline push-credential heuristic (SSH remote with no `~/.ssh` key, or HTTPS remote with no `gh auth`). Suppress with `task start --no-preflight`. No schema/DB change; no regression (task_core_unit 30/0).
- fix(task-engine): an eng ship/merge/diff/deploy approval filed by a non-lead builder is forced down from a hard-human (tier-2) gate to a lead-routed tier-1 and routed to the org lead, overriding even an explicit `--tier=2` (DIVE-1359). Builders were escalating eng ship approvals to the paired human (dev DIVE-1349/1314, codex DIVE-907) via a gate class that (a) pinged the human and (b) was unclearable by the lead since tier-2 is human-only by system rule. New `_gate_eng_ship_hit` classifier + downgrade block mirror the DIVE-1243 `access` class: the true-human floor (money/secrets/destructive/brand) is checked FIRST and always wins (a "ship the pricing change" gate stays human), and the routing is intrinsic to the kind so it bypasses the OFF-by-default `gate_builder_routing` pref (the fix is live under the default, not dormant behind a flag). A lead's own eng-ship gate is exempt. +6 unit cases (`gate_ship_routing_unit` 33/0).
- fix(goal/dashboard): make `goal add` async so the dashboard goals page never 502s, even when the planner agent is busy (DIVE-1349, follow-up to the v0.9.26 bounded-wait, which was insufficient — a busy planner still held the request ~155s past the gateway cap). The planner is a live agent turn whose latency we don't control, so decoupling it from the synchronous gateway-fronted request is the real fix. `goal add` now spawns the planner loop WITHOUT blocking and returns a job id immediately; `goal status <job>` polls `queued|running|done|failed` and runs the validate→materialize tail once the plan lands (idempotent, materialize-once via a stale-aware claim); `goal add --from-job=<job>` creates from the previewed plan (the plan JSON is too large for the tunnel's arg cap, so the job id is the handle). `--wait`/`--plan` stay synchronous for scripts. A busy planner no longer blocks the HTTP request: dry-run returned in ~8s vs the old 155s→502. The planner's `project.title/description` are normalized to `name/goal` so real (schema-drifting) planner output is no longer false-rejected. New additive `goal_jobs` table (present in both the fresh-init schema and the gated migration; `CREATE TABLE IF NOT EXISTS`). All guardrails are inherited from the sync path: `--from-job` routes through the same `_goal_finish_with_plan`, so a plan over the checkpoint OR carrying any Tier-2 task still files a human decision gate and materializes NOTHING — the gated build still requires `goal add --from-gate=<id>` after a human `approve` (`--from-job` is not a bypass). The dashboard app-side async wiring ships separately inside the DIVE-1367 goals-page redesign.
- feat(objective): `5dive objective replan <name>` — the outcome-loop re-plan cycle, the v0.10 headline atom (OSS-27, OSS-19 phase A2, DIVE-982 successor). The planner reads the objective's latest metric reading + trend + target gap + its own open originated tasks + last-cycle outcomes (all INJECTED — it never runs the metric) and emits a bounded, schema-validated DIFF `{create, reprioritize, cancel}` that deterministic code validates and applies. The anti-Goodhart spine is inherited WHOLESALE from `5dive goal`: create ops are wrapped into a goal-plan and run through `_goal_validate_plan` (max_new_per_cycle cap = reject-not-truncate, tier-lowering guard via the shared T2 classifier, DAG acyclicity/depth, assignability) then `_goal_materialize`; a T2 create ALWAYS gates at HARD tier 2 (never `--yes`-waived, applied only via `objective replan --from-gate=<id>` on a HUMAN 'approve', re-validated from scratch); every origination batch rides ONE count-checkpoint decision gate (phase-A default checkpoint 0 → any origination gates; `--yes` waives only the count check); and reprioritize/cancel are HARD-restricted to tasks THIS objective originated (`originated_by_objective`), so a planner can never touch a human or other-objective task. Stop-conditions are explicit and audited (never a silent stall): paused / target-reached / budget-exhausted each record a cycle with a clear reason and originate nothing. **Shadow-first run mode (OSS-35):** an objective carries `run_mode` (live|shadow, default live); `shadow` (set via `objective add --shadow` / `objective shadow <name>`, or the ad-hoc `replan --propose-only` flag) forces PROPOSE-ONLY — the ENTIRE diff, including own-task reprioritize/cancel that live mode applies within the objective's autonomy, rides ONE gate a human confirms, nothing auto-applies, and `--yes` cannot waive it. This is the fail-safe lever so the first self-steering dogfood run can go green without auto-executing against the live company. New schema: `tasks.originated_by_objective` + `originated_cycle` provenance columns, `objectives.run_mode`, and an append-only `objective_cycles` audit table (one row per cycle: reading, proposed/applied counts, gate anchor, tokens, outcome). Measurement (OSS-26) was the store; this is the loop. NOTE: this ships as 0.9.32 (incremental) — the `0.10.0` tag stays gated on the full v0.10 line (preflight, status surface, `company` sugar, dogfood-green on our own funnel metric) per the v0.10 vision.

- fix(goal/dashboard): the goals page no longer 502s on "Add goal" (DIVE-1349). `goal add` plans by spawning a loop task for a planner agent and block-polling it behind a single HTTP request; two defects made that request hang past the gateway timeout — the planner agent was never woken on spawn (it sat until its own heartbeat tick), and a bare `loop spawn --wait` defaulted to a 30-minute deadline. Now: (1) `cmd_loop_spawn` best-effort WAKES the assignee the moment a task is spawned (`_loop_wake_agent` → the same `_hb_wake` nudge the heartbeat uses, run directly when root else via `sudo -n 5dive heartbeat wake-task`; skipped for a busy agent or a bare type token, and never fatal); (2) the bare-`--wait` default is bounded to `LOOP_SPAWN_WAIT_DEFAULT` (120s) so a slow plan returns a clean timeout the caller renders, never a socket held to a 502; and (3) the goal planner asks for an explicit in-window `--wait=150` (`GOAL_PLANNER_WAIT_SECS`). Net: a woken planner returns its plan in-window; a genuinely slow plan yields a graceful error instead of a gateway 502.
- fix(task-engine): forbid bare reasonless/dateless blocks — every block must carry a revisit anchor (DIVE-1357, the prevention fast-follow to DIVE-1355). A task can only enter `blocked` via exactly one of three anchors, each with a built-in revisit: a dependency edge (`task block --by`, revisits via the DIVE-1355 cascade), a human need-gate (`task need`, revisits on answer), or a park (`task park`, revisits when the heartbeat passes its `wake_at`). `task park` now REQUIRES both `--reason` and `--wake` (a reasonless/dateless hold was the exact state that filled the block graveyard); a bare `task block <id>` with no `--by` is refused with an error enumerating the three anchored options, and `task block <id> --reason=<why> --wake=<when>` (no `--by`) routes through `task park`. New `_task_has_block_anchor` predicate is the single source of truth the block-producing verbs satisfy, and the `task block`/`task park` help now codifies the attempt-first norm (blocking is the exception you must justify). Net: the DIVE-1355 "blocked with no live reason" surface set is permanently empty because that state is unreachable via the CLI.
- fix(task-engine): completing a blocker now cascade-unblocks its dependents, so the fleet keeps moving without a manual `task unblock` (DIVE-1355 — the root cause of the 2026-07-16 idle night: OSS-26 finished but its dependent OSS-27 stayed `blocked` forever, so dev's heartbeats woke to zero dispatchable work and slept). On any `task done`/`task cancel` (and verify→done), `_task_cascade_unblock` drops the now-satisfied blocking edge and, when a dependent has no blocking edges left, flips it `blocked`→`todo` and pings its assignee — the same unblock-flip `task unblock`, the relay advance, and the park-wake sweep already use. GUARDRAIL: only dependency edges auto-clear — a dependent still holding an unanswered human need-gate or a park is left blocked (the satisfied edge is still dropped, so it releases correctly once the gate is answered / the park wakes). A new heartbeat pass `_hb_blocked_sweep` is belt-and-suspenders: (a) auto-recovers any task still `blocked` whose every blocking edge points to a done/cancelled task (repairs pre-existing rot + any live-cascade miss, pinging main), and (b) SURFACES to main — never auto-unblocks — tasks blocked with no live reason at all (no dependency edge, no human gate, no park: the manually-blocked-and-forgotten majority in tonight's audit), throttled to once/24h.
- feat(init): `5dive init --quiet` (alias `--demo`) hides the noisy install/`agent create`/pairing sub-processes behind a per-step spinner + a clean ✓/✗ line, redirecting their raw output to `/tmp/5dive-init-<ts>.log` and surfacing that path only on failure. The default stays verbose (full streaming) for debugging a broken first run. This suppresses the wizard leakage lodar flagged on the DIVE-1336 demo capture — garbled Claude Code installer progress, marketplace-refresh chatter, `==>` create logs, and the expected-pending self-check warnings — so a raw capture shows only wizard chrome + spinner + success screen. Also fixes the Python `datetime.datetime.utcnow()` DeprecationWarning that leaked from the marketplace pre-register step (now `datetime.now(timezone.utc)`), so it no longer surfaces even in verbose mode (DIVE-1352).
- fix(agent): `agent create --type=hermes|openclaw --provider=openrouter --api-key=… --model=<slug>` now honors the `--model` override instead of silently dropping it. `apply_byo_provider` only forwarded the operator model to the claude path, so `_apply_byo_hermes`/`_apply_byo_openclaw` always pinned their hardcoded catalog default (`openrouter/auto`); the slug was accepted and charset-validated, then thrown away. Both functions now take the override as arg 5 and prefer it over `HERMES_PROVIDER_MODEL`/`OPENCLAW_PROVIDER_MODEL` (applied on hermes' moonshot env-var AND general auth-add paths, and on openclaw). Backward-compatible: the auth re-login 4-arg call still resolves to the catalog default. This is what wires the dashboard's OpenRouter model picker (DIVE-1318) end-to-end for hermes/openclaw.
- feat(task): `5dive task clear-recs --channel-proof=<chat_id> [--only=<id|DIVE-N>]` bulk-applies the recommended answer to a paired human's pending agent-clearable gates in one shot — the "go with recs"/"approve DIVE-N" path. Only tier<2 gates that carry a `--recommend` and are not lead-routed are eligible; each clear reuses the single-gate `cmd_task_answer` path, so provenance, signature, and advance are byte-identical to a per-gate human tap. `--channel-proof` is a chat_id that must verify against the bot's `access.json` paired-human DMs (`_gate_channel_proof_ok`), and `cmd_task_answer` honors it as human evidence ONLY when the gate is tier<2 — a tier-2 hard gate always keeps its per-gate nonce tap and is refused/skipped. Unblocks DIVE-1334 `/inbox` bulk-clear (DIVE-1305, shipped via DIVE-1340).
- fix(agent): human-gate Telegram tap buttons that Telegram rejects are no longer lost silently. When a button-bearing gate ping (`task need` decision/approval/secret/manual) failed for a non-migration reason, `_mirror_post`'s DIVE-117 fallback re-sent the SAME text WITHOUT the keyboard and discarded the error response, so the human got a no-button text ping and we never learned why Telegram rejected the `reply_markup` (lodar's recurring DIVE-1320 no-button — systemic across every gate whose keyboard-send is rejected). The fallback now first logs the actual rejection (`error_code` + `description` + reply_markup byte-length + target chat/thread) to `/var/log/5dive/gate-notify.log` (stderr on CLI-only/OSS boxes) before the no-keyboard retry, so the real cause is finally observable and root-cause-able. Best-effort and non-fatal: it runs after the gate row already committed and never fails the caller (DIVE-1338).
- fix(agent): resolve the codex bin via a `~/.local/bin/codex` one-hop symlink instead of the hardcoded `/home/claude/.nvm/versions/node/v24/bin/codex`. When node upgrades (e.g. to v24.18.0) the `v24` nvm alias can lag and `npm i -g @openai/codex` lands the binary in the real version dir, so the hardcoded path went stale and `agent create --type=codex` reported codex not_installed / auth not_installed even though codex ran fine on PATH. The install recipe now symlinks the freshly-installed codex into `~/.local/bin` (resolved deterministically as `dirname $(nvm which 24)/codex`, same convention as grok/pi/opencode) and `TYPE_BIN[codex]` points there (DIVE-1329).

- fix(agent): `agent send`/`_deliver` now reliably submits to codex (and other non-claude) agents. `inject_and_submit` relied on Claude's `[Pasted text #N]` placeholder to know an Enter still needed re-sending; codex renders the paste inline with no such marker, so a single Enter fired 0.3s after the burst raced the paste-commit and was swallowed, leaving the message unsent and the agent silently deaf. Non-claude TUIs now settle, submit, then confirm the turn started (via `_hb_agent_idle`), re-sending a few times before giving up — mirroring the heartbeat fix (DIVE-1217). Enter and C-m are byte-identical CR to tmux, so the prior manual-C-m workaround was really the settle+confirm (DIVE-1325).
- feat(init): redesign the first-run wizard as a polished four-stage TTY onboarding flow with arrow-key menus, explicit Codex/Claude authentication choices, live-masked API-key and bot-token input, early agent-name validation, deterministic provider pickers, terminal-aware styling, a pre-create review/cancel checkpoint, and clearer completion guidance (DIVE-1326). `TERM=dumb` retains a numbered fallback and `NO_COLOR` disables styling.
- fix(agent-start): fresh `agent create --type=codex` without `--auth-profile` no longer boots silently deaf on a bogus `OPENAI_API_KEY` (401). The codex auth-seed now reads the stable canonical profile file (`/var/lib/5dive/auth-profiles/codex/codex/auth.json`) directly instead of the lazily-created `/home/claude/.codex/auth.json` symlink, so an agent booting before the symlink exists still seeds a valid chatgpt-oauth credential before codex first runs. It also re-seeds when codex has already written a bad `auth_mode=apikey` auth.json while a valid chatgpt source is available — closing the case where the old mtime-only check (and `config set auth-profile=codex` + restart) never corrected a once-deaf agent (DIVE-1322).

## 0.9.14

- fix(agent): `agent import <slug|pack> --type=<codex|pi|opencode|claude|…>` now honors the requested runtime instead of silently taking the pack's baked-in type, making a marketplace/persona hire harness-agnostic (DIVE-1317). Explicit `--type`/`--model`/`--effort` override the manifest for pack imports (they were previously consumed only in `--from-persona` mode), the resolved type is validated up front with a clear error, and `--from-persona` behavior is unchanged (still defaults to claude).

- feat(agent): `agent create --type=opencode --provider=openrouter --api-key=… --model=…` now stores the key as OpenCode's native `OPENROUTER_API_KEY` and pins the new agent's default as `openrouter/<model>` in its merge-safe `opencode.json` (DIVE-1206). This enables OpenRouter-hosted DeepSeek, GLM, Kimi, and Qwen models without an interactive `/connect` or `/models` step; the existing OpenAI provider and `agent auth set opencode` paths remain compatible.

## 0.9.13

- fix(audit): non-root agent-* CLI callers now record their mutating actions (task done/answer, agent send, …) in the tamper-evident audit log via a new hidden, append-only `5dive _audit_append` primitive over NOPASSWD sudo (DIVE-1268). The log is 640 root:claude, so a non-root agent can't write it directly; rather than loosen it to a group-writable 660 (which would let any group-claude agent rewrite/truncate past entries), `_emit_audit_line` routes the non-root append through the privileged primitive, which re-stamps `.user` from `SUDO_USER` (the payload can't spoof the actor), drops non-objects, and appends only — never execs caller input (upholds the write_admin_sudoers invariant). Standard agents get a single scoped `write_standard_sudoers` grant with no trailing wildcard; admin agents are covered by the existing whole-CLI grant. Also fixes a `Permission denied` stderr leak — `_emit_audit_line` gates on writability before the append, so a caller who can't write never triggers the failing-redirect diagnostic (which bash prints before `2>/dev/null` takes effect).

## 0.9.12

- fix(init): `5dive init` pi + openrouter now wires the provider and key through `agent create` instead of an early `auth set`, so the created agent boots with `defaultProvider=openrouter` and the key persisted to *its* connector (DIVE-1269). The wizard previously ran `5dive agent auth set pi --provider=…` before create, then created the agent with only `--model` — so `pi_apply_model_default` ran with an empty provider, leaving `~/.pi/agent/settings.json` `defaultProvider=""` and the key on the *default* connector (never the agent's). pi then errored "No API key found for the selected model". The pi provider+key now defer to create (mirroring the `agent create --provider/--api-key` path and the claude-BYO deferred path), so create runs both `pi_apply_provider_key` (persists the key) and `pi_apply_model_default` (sets provider + model). Key stays on stdin, never argv. `tests/init_pi_unit.sh` updated to assert the deferred-to-create wiring and reject any `auth set pi` regression.

- fix(install): the installer's `5dive.sha256` fetch is now fail-soft under `set -euo pipefail` (DIVE-1271). `refresh_managed_files` assigned `_want="$(curl … 5dive.sha256 | …)"` as a plain assignment; when the checksum is absent (the offline install-smoke bundle omits it) curl exits 37 and `pipefail`+`errexit` aborted the whole install at "Installing CLI binaries" — before the absent-checksum warn branch could treat it as non-fatal. A trailing `|| _want=""` restores the intended "absent checksum only warns" contract (the fetch, not the verify, was the abort). Regression from the DIVE-1261 checksum feature (0.9.7) that had reddened install-smoke on main since. `tests/install_checksum_unit.sh` now reproduces the offline no-sha256 case under the real installer flags (the prior grep-only assertion false-greened).

## 0.9.11

- fix(agent): a freshly-created pi agent now gets the full 5dive default skill set (find-skills, 5dive-cli, compile-knowledge, openagent), not just a stray openagent leaked from the shared project dir (DIVE-1265). pi had no skills-map entry, so its default-skill installs fell through to the claude-code default (`~/.claude/skills`), a directory pi's resource loader never scans (pi reads `~/.pi/agent/skills` and `~/.agents/skills`, plus the `<cwd>/.pi|.agents/skills` project dirs). pi is now a manual-install type like grok: `npx skills add --agent pi` lands skills in `~/.pi/skills` (also unread by pi), so pi is git-clone+cp'd into `.agents/skills` instead. Added `[pi]=pi` + `[pi]=".agents/skills"` and `pi` to `_skill_needs_manual_install`, so the create-path installer, the `5dive-refresh-skills.sh` backfill, `5dive agent skill add`, and `list/rm` all agree on `~/.agents/skills` — a verified pi read dir, matching the notify-user seed already written there.

## 0.9.10

- fix(agent): pre-seed pi's project-trust store at provision time so a freshly-created pi (telegram-relay) agent never blocks on pi's interactive "Trust project folder?" gate on first run (DIVE-1264). The headless systemd relay can't answer the prompt, so it hung before ever polling. `agent_setup` now writes `~/.pi/agent/trust.json` (`{"/home/claude/projects": true}`) during the pi telegram channel setup — pi's trust lookup walks parent dirs, so trusting the projects root covers every per-agent workdir beneath it, exactly mirroring the claude `.claude.json` hasTrustDialogAccepted pre-seed. Merge-safe and idempotent.

## 0.9.9

- fix(runtime): `5dive-agent-start` resolves `bun` via a fallback chain (/usr/local/bin -> ~claude/.bun/bin -> ~claude/.local/bin -> PATH) instead of a single hardcoded `~/.local/bin/bun`, at BOTH the opencode and pi telegram-bridge launch sites (DIVE-1263). install.sh dropped bun at ~/.bun/bin while ensure_bun_for_agent used /usr/local/bin, so on a fresh install.sh box the pi/opencode telegram bridge exit-3'd and systemd crash-looped (a restart counter of 132 in the wild; opencode+telegram was latently broken the same way). install.sh now installs bun to /usr/local/bin (BUN_INSTALL=/usr/local) to match, which also puts bun on PATH for codex/grok/agy hook commands. Smoke: test-vm.sh asserts the bridge unit stays active 6s post-create (the create-path smoke passed before the bridge ever booted).

## 0.9.8

- feat(init): when pi's provider is `openrouter` (a multi-model gateway), `5dive init` now prompts for the model to route to and pins it at create via `--model` (DIVE-1262). openrouter can't route without an explicit model, so the prompt is required (empty rejected); the value flows into the pi agent's `defaultModel` via the existing pi_apply_model_default path. Direct providers (anthropic/openai/etc.) are unaffected — they use pi's provider default.

## 0.9.7

- feat(install): supply-chain integrity check for the curl|bash installer (DIVE-1261). `build.sh` now publishes `5dive.sha256` alongside the bundle, and the installer fetches the bundle to a temp file, verifies it against the published checksum, then does a same-fs atomic swap into place. A checksum MISMATCH is fatal (corrupt download or tampered mirror); an absent/unfetchable checksum only WARNS so a box can't be bricked if the `.sha256` isn't published. Covers both the default install and `--upgrade` (both flow through `refresh_managed_files`). Integrity-check v1 — guards corruption + mirror tamper, not signing-strength (a future out-of-band-key signature would close the absent-checksum downgrade path). New unit `tests/install_checksum_unit.sh`.

## 0.9.6

- fix(install): `curl … | sudo bash -s -- --upgrade` now reports the resolved version — `5dive upgraded: <old> -> <new>` — instead of a bare "5dive upgraded.", read directly from the swapped-in bundle so it reflects what actually landed (DIVE-1260).

## 0.9.5

- feat(init): `5dive init` now prompts for the isolation tier (admin / standard / sandboxed), with a default that mirrors `agent create`'s resolution — pi -> sandboxed (extensions run arbitrary code), the first agent on a fresh box -> admin (bootstrap fleet manager), every other agent -> least-privilege standard — and forwards the choice as `--isolation`. Replaces the hardcoded pi-only sandboxed line. New unit `tests/init_isolation_picker_unit.sh`.

- fix(pi): `install_default_pi_extensions` derives the runtime bin dir from a ONE-hop symlink read instead of `readlink -f` (DIVE-1202/DIVE-1259). `readlink -f` fully dereferenced pi's two-hop symlink chain (`.local/bin/pi` -> `<npm global bin>/pi` -> `../lib/node_modules/<pkg>/cli.js`) into the package dir, which has no node/npm/pi, so `pi install` ran with a broken PATH and failed "pi: command not found" — which the fail-closed guard mislabeled as an npm-integrity mismatch, blocking EVERY pi agent-create (default `FIVE_PI_DEFAULT_EXTENSIONS=1`). One-hop resolution lands in the real `<npm global bin>` dir that holds node/npm/pi; `readlink -f` is kept only for the is-executable guard; a hard node/npm/pi presence assert now fails a future layout drift with an accurate message instead of a misleading integrity error. Uncovered by DIVE-1202's convergence smoke once the DIVE-1258 node24 fix let provisioning advance far enough to hit it.

## 0.9.4

- feat(init): `5dive init` now lists `pi` as agent type option 8 (DIVE-1255). Fixes the wizard's `^[1-7]$` choice regex, adds a provider picker (default `anthropic`) that reuses the multi-provider `PI_PROVIDER_VAR` map, marks pi telegram-capable, and creates the wizard's pi agent with `--isolation=sandboxed` by default (pi extensions run arbitrary code with the agent's permissions, so keep it off the shared claude-group workspace). New unit `tests/init_pi_unit.sh`.

- fix(init): the `opencode` init branch now prompts for a provider instead of hardcoding "paste OpenAI API key" (DIVE-1257). `5dive init -> opencode` lists the supported providers (`openai`/`openrouter`, default `openrouter`) and forwards the choice; `5dive agent auth set opencode --provider=<p>` resolves the key into that provider's native env var via the new `OPENCODE_PROVIDER_VAR` map (no `--provider` keeps the legacy OpenAI default for back-compat). New helper `opencode_provider_var` + unit `tests/opencode_init_provider_unit.sh`.

## 0.9.3

- fix(agent): `pi` install recipe provisions Node 24 with `nvm install 24` instead of `nvm use 24` (completes the DIVE-1254 sweep). On a fresh box `nvm use 24` fails with "version v24 is not yet installed", so `5dive agent create <name> --type=pi` aborted before installing pi — the identical bug fixed for `codex` in 0.9.2, present in the pi recipe added by DIVE-1199. `nvm install 24` provisions the pinned runtime and selects it so the `npm install -g @earendil-works/pi-coding-agent` lands in v24's bin dir. New unit `tests/pi_install_node24_unit.sh`. Audited all 8 install recipes: only `pi` remained (opencode/hermes/openclaw/antigravity/grok use curl installers, no nvm), so this closes out the node24 provisioning class.

## 0.9.2

- fix(init): `codex` install recipe provisions Node 24 with `nvm install 24` before installing Codex (DIVE-1254). `nvm use 24` failed on a fresh box where v24 wasn't yet installed, aborting `--type=codex` provisioning; `nvm install 24` provisions and selects it, forcing the `npm install -g @openai/codex@latest` into v24's bin dir even when the default alias drifted. New unit `tests/codex_install_node24_unit.sh`.

## 0.9.1

- fix(agent): durable Telegram pairing for owner-less fork agents (DIVE-1244). `codex`/`grok`/`antigravity` created with no `allowed_users` previously skipped seeding `access.json` entirely, leaving a block-everything file-absent state that silently dropped the operator's DMs (incl. gate alerts) until a manual file pair. The three installers now ALWAYS seed `access.json` (mirroring `opencode`/`pi`): with ids they allowlist them, without they default `dmPolicy=pairing` so the first DM yields a pairing code instead of a silent drop. Seeds remain append-only and never override an existing `dmPolicy`, so a manual pairing survives config-set re-provisioning. `pending` is now also seeded for schema parity with the bridges.

- feat(agent): audited default pi extensions with fail-closed integrity pinning (DIVE-1246). `install_default_pi_extensions` (agent_setup.sh, tail of pi channel setup) installs the two audited, version-pinned defaults (`pi-web-access@0.13.0`, `pi-mcp-adapter@2.11.0`) via `pi install`, verifies each against its recorded sha512 in the resolved `package-lock.json`, and FAILS CLOSED (`pi remove` + abort) on any mismatch. Never installs latest; keeps each package's safe defaults (browser-cookies / samplingAutoApprove / autoAuth / direct-tools off). Opt out with `FIVE_PI_DEFAULT_EXTENSIONS=0`. Per `community/wiki/pi-extension-default-policy.md`.

- feat(agent): post-create self-health check for new agents (DIVE-1197). Replaces the DIVE-1190 telegram-only pair hint with a generalized self-check at the tail of `cmd_create`: flags a freshly-created agent that looks up-and-running but is actually MUTE (unit inactive), DEAF (empty channel allowlist), BLIND (telegram getMe fails), ASLEEP (no heartbeat) or UNAUTHED (auth deferred), each with the exact one-tap fix command. Prints a single PASS line when clean; all to stderr so `--json` stdout stays a clean envelope.

- feat(agent): reachability/autonomy health in `agent list` (DIVE-1219). `cmd_list` emits `health:{deaf,asleep}` per agent so the dashboard can badge silently-broken agents: deaf = a telegram/discord channel with an empty allowlist (nobody paired), asleep = heartbeat not enabled. Computed CLI-side from the `/exec` passthrough (zero API change); mirrors the DIVE-1197 create-time self-check for the live fleet. Deaf-detection reads the 0600 `access.json` via `sudo -n cat` (the dashboard runs the CLI as `claude` through the exec tunnel, so a plain read EACCESed and false-flagged every paired agent — verifier iter-2); only a positive read of an empty `allowFrom` marks deaf, so unreadable/missing stays unknown and never false-flags a paired agent.

## 0.8.23

- security(agent): freeze grok provisioning behind a code-durable guard (DIVE-1222). Grok Build CLI (xAI) has a disclosed codebase-exfiltration issue with no client-side fix as of its v0.2.98 changelog, and xAI shipped only a revocable server-side mitigation; as a precaution `cmd_create` now refuses `--type=grok` pointing to DIVE-1221, which blocks every provisioning path (create, hire, pack import, clone). Unfreeze requires a VERIFIED xAI client-side patch + pinnable version, never the server-side toggle alone; an off-by-default `FIVE_GROK_UNFREEZE_VERIFIED=1` override exists solely for that moment. New unit `tests/grok_freeze_guard_unit.sh`.

## 0.8.22

- fix(heartbeat): runtime-aware nudge submit — codex/grok/agy/opencode ingest the ~1KB /goal nudge as a paste and swallowed the single Enter, leaving it unsubmitted so the agent never executed; for non-claude runtimes let the paste settle then submit, confirming the turn actually started (agent left idle) before giving up, retrying Enter otherwise; claude path untouched (DIVE-1217).

All notable changes to `5dive` are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/spec/v2.0.0.html).

Unreleased changes accumulate at the top until they're cut into a tagged
release.

## [Unreleased]

### Added
- **`pi` is now the 8th first-class agent type (Pi by earendil-works) — DIVE-1196/1199/1200/1201.**
  Type registration in header.sh; multi-provider API-key auth (no OAuth) via `PI_PROVIDER_VAR` +
  `--provider/--api-key` on create (cmd_auth.sh, DIVE-1200); telegram channel wiring for pi's
  extension-based bridge (agent_setup.sh, 5dive-agent-start, DIVE-1201); install.sh stages
  telegram-pi. New units pi_auth_provider_unit.sh (18) + pi_channel_wiring_unit.sh (13). Bumps to 0.9.0.


### Fixed
- **`agent send`/`ask` a2a now works between scoped-sudo agents on OSS boxes
  (DIVE-1337).** The self-elevation gate keyed on `isolation == standard`, so an
  `admin`-tier sender (the bootstrap first agent on every fresh OSS box, sudo
  scoped to `/usr/local/bin/5dive *` with no `sudo -u`) fell through to the direct
  `sudo -u agent-X tmux` path, was denied, and the failure was mis-reported as
  "session not found". Replaced the tier check with a capability probe
  (`a2a_needs_scoped`): if the caller can't `sudo -u` the target, route through the
  `_deliver`/`_capture` grant. Managed-host agents (NOPASSWD:ALL) keep the direct
  path and its --from/--reply-to plumbing; every scoped OSS agent self-elevates.
  Smoke gains an `a2a-scoped` row (5dive-api test-vm.sh) that sends AS the scoped
  agent user. Bumps to 0.9.18.
- **Heartbeat idle-detection is now runtime-aware, so non-claude agents get
  nudged for board tasks (DIVE-1211).** `_hb_agent_idle`'s pane-scrape fallback
  hardcoded claude's `❯` composer glyph, which codex/grok/agy/opencode never
  render, so every non-claude agent read as "active" on every tick and its nudge
  was deferred forever, never picking up its board tasks. The at-rest check now
  resolves a per-runtime idle marker (`_hb_idle_marker`: claude `❯`, codex `›`,
  antigravity `? for shortcuts`; grok/opencode trust byte-stability alone until
  their idle glyph is verified live) as the guard that a byte-stable pane is
  genuinely parked at the composer and not frozen on a dialog. Verified live:
  idle codex + agy now read IDLE (were stuck "active"). New unit
  `tests/heartbeat_idle_marker_unit.sh` (14 assertions).
- **Builder ship-gates are now org-lead-clearable, closing the DIVE-1145 gap
  (DIVE-1182).** DIVE-1145 routed only `decision` gates to the org lead; a
  builder's actual ship-gate is filed as `approval` (or `manual`), so it stayed
  human-only and pinged lodar instead of Marcus. `task need` now routes
  `approval`/`manual` builder gates to the lead too (pref `gate_builder_routing`
  on), persisting `routed_reviewer` on the row. `task answer` grants exactly the
  designated `agent-<routed_reviewer>` an exception to the approval/manual
  human-only floor for that one routed gate, recorded as `lead:*` provenance (not
  `human:*`). `secret` is never routed (must be human-delivered), tier-2 and
  true-human-category (money/destructive/brand) gates still ping the human, and
  every un-routed approval/manual gate stays hard-human — the DIVE-391/515/516
  self-clear boundary is unchanged. New `routed_reviewer` column (base schema +
  migration backfill). Unit: `tests/gate_ship_routing_unit.sh` (27/27).

## [0.8.17] — 2026-07-14

### Fixed
- **codex `auth login` uses device-code auth on headless/remote (DIVE-1178).**
  `sudo 5dive agent auth login codex` (and `5dive init`) now runs
  `codex login --device-auth` instead of plain `codex login`, which started an
  interactive browser OAuth with a `localhost:1455` callback server. codex
  itself flags this ("On a remote or headless machine? Use codex login
  --device-auth instead."); `--device-auth` prints a URL + one-time code and the
  CLI polls OpenAI, so SSH/headless users can auth with no local browser. Same
  shape grok already uses and the dashboard device-code flow (`auth start`)
  already drove.

## [0.8.16] — 2026-07-12

### Added
- **`proof on --user=<name>` (OSS-30, gh 5dive#30).** The nightly proof-publisher
  cron now runs as `--user` (default `root`, back-compatible). The cron's
  effective user must own the box's git push credentials; on boxes where root
  holds none (creds live with a service user), `--user=<that user>` fixes the
  otherwise-silent 03:00 push failure. Persisted in `proof.json` and sticky
  across re-`on`; unknown users are rejected; `proof status` shows a non-root
  user. Surfaced during OSS-29 live verify.
- **Ship-gating gate routing (DIVE-1145).** Root-cause fix for builders
  over-filing decision gates straight to the human (DIVE-1127/1142). When a
  non-lead agent files a `decision` gate, `task need` now routes it to the org
  lead first (resolved from the org chart — `reports_to`, else the coordinator/
  root, never hardcoded) as an agent handoff, suppressing the human ping until
  the lead resolves or re-escalates (a gate filed by the lead resolves to no
  distinct reviewer, so it goes to the human — free re-escalation). Behind pref
  `gate_builder_routing` (default **off**, ship-safe). True-human categories are
  never routed: tier-2-floored decisions (money/destructive/brand) and every
  non-decision type (approval/manual/secret) keep pinging the human unchanged.
  Approval/manual routing is deferred — it needs the DIVE-1117 provenance floor
  to trust a designated reviewer. Unit-tested in `tests/gate_ship_routing_unit.sh`. Enable/disable/inspect with `5dive task routing on|off|status` (mirrors `task precedent`).

### Fixed
- **Ship-gating routing, verifier iter-2 fixes (DIVE-1145).** (1) The route
  guard now keys on the **effective** tier (`type==decision && tier != 2`)
  instead of `tier_floored==0`, closing a hole where an explicit
  `--type=decision --tier=2` gate that missed the keyword floor kept
  `tier_floored=0` and silently routed to the lead — overriding the hard-human
  `--tier=2` contract and suppressing the human ping. (2) The unit harness now
  stubs `5dive` with a shell function (shadows the real binary, inherited by the
  detached `( … & )` send subshell) recording sends to a file sentinel, so the
  suite has **zero** live side-effects on real hosts/CI (was firing phantom
  `5dive agent send main` pings). Added coverage for explicit-`--tier=2` and a
  no-stray-send assertion; `gate_ship_routing_unit` now 12/12.

## [0.8.15] — 2026-07-12

### Added
- **Gate-shipped sweep — ghost gates flagged when their fix merges (DIVE-1140).**
  Human gates (approval/decision/manual) don't auto-close when the underlying fix
  merges to main, so the overnight recap (DIVE-217/1138) surfaced 'ghost' gates on
  already-shipped work. A new heartbeat sweep (`_hb_gate_shipped_sweep`, wired into
  `cmd_heartbeat_tick` after the TTL sweep) scans each configured repo's
  `origin/main` for a commit referencing an OPEN gate's ident; on a hit it stamps
  `shipped_flag_at` and pings the gate owner "likely shipped — verify and close".
  **Flag-only for ALL tiers** (lodar decision 2026-07-12): a merge is not a human
  sign-off (DIVE-555) and a commit may only partially fix a gate, so it NEVER
  auto-answers or closes — a human still clears it. `shipped_flag_at` throttles to
  one flag per gate. Repo allow-list is configurable via
  `HEARTBEAT_GATE_SHIPPED_REPOS` (default `5dive-cli`); grep is on the local
  `origin/main` tracking ref (no fetch, credential-free). New additive column
  `tasks.shipped_flag_at`.

## [0.8.13] — 2026-07-12

### Added
- **Outcome-loop objectives — `5dive objective` (OSS-19 / OSS-26, phase A1, gh
  5dive#23).** A first-class primitive for a standing goal the company steers a
  single number toward: `objective add "<name>" --metric-cmd="<cmd>" --target=<n>
  [--direction=up|down] [--unit=%] [--review="<cron>"] [--planner=<a>]
  [--project=<key>] [--max-new-per-cycle=N] [--budget=<tok>] [--public]`, plus
  `ls`, `show`, `pause`, `resume`, `rm`, and `tick`. Storage is a new
  `objectives` table + append-only `objective_readings` (both additive, gated
  migrations, byte-identical schema copies per `schema_sync_unit`). The metric is
  a **read-only command contract** (stdout → one number) run ONLY by `objective
  tick` and the digest, **never by a planner** — the anti-Goodhart separation
  baked in from day one. A failed/non-numeric metric records `value=NULL, rc!=0`
  so a broken metric shows as a visible gap, never a silent skip. `5dive digest`
  (text + `--json`) gains an `objectives` block — `{name, current, target,
  direction, unit, trend, gap, inflight, originatedThisCycle}` — deriving `trend`
  from the window baseline the same way `_window_counts` derives ship/ask deltas.
  This build is **measurement only**: NO origination and NO planner cycle (that
  is the blocked successor build); `cmd_proof.sh` is untouched (no-flag-edits
  invariant), so `--public` is stored for a later proof-feed passthrough. Covered
  by a new `objective_unit` (13/13).

## [0.8.12] — 2026-07-12

### Changed
- **Loop token `--ceiling` is now a hard stop, not advisory (OSS-24, gh
  5dive#17).** Driver loops (`loop map`/`until-dry`/`verify`/`grade`) already
  halted on breach — their foreground driver re-checks `spent >= ceiling` before
  each round. The gap was the fire-and-forget `loop spawn`: with no driver, a
  ceiling breach was caught by the heartbeat sweep but only marked `loop_runs`
  escalated + filed an escalate-with-proof gate — the agent kept burning tokens
  on the still-`in_progress` child task. The sweep now also **parks the loop's
  live child task(s)** (`blocked` + `parked_at` + `park_reason`, pending-gate
  fields cleared, same shape as `task park`; never touches
  done/cancelled/already-parked work), so the spend actually stops. This mirrors
  the cost-budget hard stop, scoped to the loop rather than the whole agent.
  Unblocks OSS-18 L2 budget widening (a budget that cannot halt must not be
  widened). Covered by an extended `loop_ceiling_enforce_unit` (now asserts the
  child task is parked on breach).

## [0.8.11] — 2026-07-12

### Changed
- **Supervisor self-heal now covers every runtime (OSS-23, gh 5dive#16).** The
  P2 recovery ladder (nudge → resume → rotate) no longer hard-escalates
  non-`claude` agents: `codex`, `grok`, `opencode`, and `antigravity` get the
  same auto-recovery on a session-alive-but-wedged cause (`no-progress`,
  `loop-stuck`). It always could — every rung is a generic op on the
  `agent-<name>` tmux session + registry (line injection via `_hb_send_line`, a
  modal-clearing Escape, same-type account rotation self-gated on
  `rotation.enabled`), with no claude-specific assumption; the old runtime gate
  was a DIVE-857 caution, not a technical limit. Restart-class causes
  (`service-dead`/`tmux-dead`/`poller-dead`) still escalate for every runtime
  (rung 4 = P3). Prereq for the OSS-18 autonomy ledger, whose self-heal-recovery
  signal would otherwise be claude-biased. Unit matrix in
  `tests/supervisor_unit.sh` extended to codex/grok/opencode/antigravity.
  Live-fleet validation of each runtime's actual resume behavior is main's
  verify-time last-mile.

## [0.8.10] — 2026-07-12

### Added
- **ID/age-verification tripwire in the fleet supervisor (DIVE-1127, ToS-hedge A2).**
  Per the Jul-11 hedge memo (D4 trigger 1), `5dive supervisor --tick` now flags
  any `claude` session whose live tmux pane shows an ID/age-verification
  challenge and alerts `main` + `lodar` SAME-DAY, tagging the account, so the
  response (flip that account to the OpenRouter-Claude profile, A1 runbook) can
  run same-day. Detection is PANE-scoped by design, not the JSONL transcript,
  so an agent merely discussing verification (e.g. this task's own chatter)
  never self-trips; the signature is anchored to a challenge directed at the
  user ("verify your identity/age", "government-issued ID"), env-overridable via
  `SUPERVISOR_VERIFY_PAT`. New classification `verify-challenge` (wins first —
  it explains any concurrent stall and is not a wedge the P2 nudge/resume/rotate
  ladder can clear, so it gets a dedicated alert path). Alerts dedup one per
  account per `SUPERVISOR_ALERT_WINDOW_H` (24h) and are audited as
  `supervisor_events` `event='alert'`. Unit-tested in
  `tests/verify_tripwire_unit.sh` (signature true/false positives incl. the task
  title trap, env override, dedup window). The `lodar` leg DMs the human through
  main's paired Telegram channel (`_task_agent_channel main` +
  `_task_send_owner`), best-effort. Live root `--tick` cron wiring +
  real-signature validation remain main's verify-time last-mile.

## [0.8.9] — 2026-07-12

### Changed
- **zero-human badge message is percent-only.** `proof publish` now renders
  `89.9%` instead of `89.9% (99)` — the shipped-count parenthetical read as
  noise on the badge (lodar call, 2026-07-12). The sample size still ships in
  `zero-human.json` (`week.shipped`) and `docs/zero-human.md` says where to
  look. Zero-ship weeks still render `0 shipped, N asks` (no honest bare `%`
  exists for an empty sample). Unit tests + methodology doc updated.

## [0.8.8] — 2026-07-11

### Added
- **`5dive proof` — publish your own zero-human badge (OSS-17, gh 5dive#21).**
  Generalizes the internal `scripts/publish-zero-human.sh` into a first-class
  verb so any self-hosted box publishes its own proof to its own repo's status
  branch, same methodology (`docs/zero-human.md`). `proof publish [--dry-run]
  [--repo] [--branch]` computes badge.json/zero-human.json/history.jsonl from
  `5dive digest --json` VERBATIM (no flag edits a number, by design), idempotent
  per day (a same-day re-run exits 3). `proof on --repo=<url> [--branch=status]
  [--at=HH]` saves config (`${STATE_DIR}/proof.json`) + installs an idempotent
  root cron (`/etc/cron.d/5dive-proof`); `proof off` removes the cron (config
  kept); `proof status` reports config, last-published date, and staleness.
  First publish prints the copy-paste README badge markdown pointing at the
  user's OWN status branch. `scripts/publish-zero-human.sh` is now a thin
  back-compat shim calling the verb (existing crons keep working; ZH_REPO/
  ZH_BRANCH/ZH_GIT_NAME/ZH_GIT_EMAIL still honored). Push auth is the box's
  ambient git credentials — the verb never stores tokens. Unit-tested in
  `tests/proof_publish_unit.sh`. Our own box's cron migration is held for
  verify-time with main (DIVE-1115 pause).

## [0.8.7] — 2026-07-11

### Fixed
- **Tier-2 gates now refuse a non-human answer regardless of need_type
  (DIVE-1117, companion to DIVE-1115 / defense in depth).** The human-only and
  gate-proof evidence blocks in `task answer` keyed on need_type
  (approval/secret/manual), so a `decision` gate FLOORED to tier 2 by the T2
  category heuristic (e.g. OSS-16/OSS-25, keyword-floored by "secrets") slipped
  past and accepted a bare-agent answer (`need_answered_by=main`) even with
  `gate-proof enforce` ON. Added a tier-2 provenance floor: under enforcement,
  `task answer` on any tier-2 gate refuses a non-human answer (an answer is
  human-sourced only when a trusted path passed `--human`, recorded `human:*`).
  The floor is provenance-only, not evidence-based: a tier-2 `decision` gate
  mints no per-gate nonce and its Telegram tap runs as `SUDO_UID=agent`, so
  demanding evidence would reject a real human decision tap (DIVE-525). Every
  trusted human path (Telegram tap, dashboard/API exec) passes `--human`, so a
  genuine human answer is never blocked. No downgrade path from the answer side:
  an over-fired T2 waits for a human by design. New unit suite
  `tests/gate_tier2_floor_unit.sh` (9 cases). Residual follow-up: the sudo→`--human`
  human:* forge on a tier-2 *decision* (no nonce evidence layer), and the
  phrasing-sensitive T2 heuristic should key on structured category, not ask-text
  keywords.

## [0.8.6] — 2026-07-11

### Added
- **Tier-1 gates auto-clear from proven human precedent (OSS-21).** Behind a new
  fleet pref `5dive task precedent on|off` (default **OFF**). When ON, at gate
  file-time — AFTER tier resolution and the T2 category floor, both unchanged — a
  gate that resolves to **tier 1** clears itself if the ask matches proven human
  precedent: EXACT `ask_shape` + same `need_type`, at least **2 distinct** prior
  gates answered by a **human** (`need_answered_by LIKE 'human:%'`) with the
  **identical** answer within 90d, **zero** contradicting human answers on that
  shape in 90d, precedent tier ≥ 1. The clear uses the same immediate direct-write
  path as tier-0/auto:ttl (never the human-answer path, so **no nonce is minted**),
  stamps provenance `auto:precedent` and `precedent_ref` = the most-recent
  qualifying gate, and surfaces in the digest's Auto-cleared section with its
  citation. Hard exclusions: **secret** gates and **T2** never auto-clear;
  `auto:*`-answered gates never seed a precedent (no compounding); a decision whose
  consensus answer isn't a current option falls through to the human. `5dive
  doctor` gains a `policy` check that flags when the switch is ON. Default OFF
  everywhere pending the OSS-16 policy decision.

## [0.8.5] — 2026-07-11

### Added
- **Fuzzy precedent prefill for repeat human gates (OSS-20).** Hand-written gate
  asks almost never collide EXACTLY, so the exact-shape precedent match prefilled
  ~0 gates in practice. `task need` now falls back to a token-set Jaccard >= 0.8
  match on `ask_shape` when the exact lookup misses — "the same question,
  paraphrased" — and prefills the blank recommend + cites the precedent. Fuzzy
  hits are advisory-ONLY: they never mutate the gate tier and are never eligible
  for auto-clear (that stays exact-match). Each prefill records a `precedent_kind`
  (`exact`|`fuzzy`); the digest's `precedentPrefill` now splits its acceptance
  rate by kind so the two match qualities are comparable (promotion reads exact
  only). Stays strictly inside the DIVE-916 invariant (no tier mutation, clear
  path untouched).
- **`5dive fire` — synonym for removing an agent.** `5dive fire <name>` and
  `5dive agent fire <name>` are aliases for `5dive agent rm <name>` (fire an
  agent from the team). Same guarded teardown path; purely additive.

## [0.8.3] — 2026-07-10

### Added
- **Custom providers in the `5dive init` wizard for Claude.** The claude auth
  step now offers a third option — "Custom provider" — to run Claude Code
  against a BYO Anthropic-compatible endpoint (OpenRouter, z.ai, DeepSeek,
  Moonshot), mirroring the provider picker hermes already had. It prompts for
  the provider + API key and wires `--provider`/`--auth-profile` at create
  time, so a BYO-provider Claude agent no longer needs hand-crafted
  `agent create` flags.

## [0.8.2] — 2026-07-10

### Fixed
- **Listener-only fixes now self-deploy on update (DIVE-1095).** The shared
  team-bot listener runs from a materialized `/opt/5dive/team-bot-listener.ts`
  that was rewritten ONLY by `team-bot shared`, so a listener-only fix (e.g.
  DIVE-1093's `callback_query`/`tna:` tap handling) shipped in the binary but
  stayed dormant on auto-updating boxes until an operator re-ran that command.
  New idempotent `5dive agent team-bot refresh-listener` re-materializes the TS
  from the current bundle and restarts the service (guarded on the unit file →
  no-op where there is no shared team-bot); `self-update` and the nightly
  `5dive-host-updates.sh` both call it after installing the fresh binary.

## [0.8.1] — 2026-07-10

### Added
- **`agent create --model=<slug>` picks the model on BYO claude providers
  (DIVE-1103).** Overrides the primary (opus+sonnet) tiers with any slug the
  provider serves — OpenRouter translates every family (`openai/*`, `google/*`,
  `z-ai/*`, `deepseek/*`, `meta-llama/*`) in Anthropic wire format, and the
  Chinese providers serve their own. The background/fast HAIKU slot stays on the
  catalogue's caching-capable default so background turns stay cheap. Complements
  the already-shipped `agent config set model=<slug>` (switch a running agent,
  persists to `settings.json`) and Claude Code's built-in in-session
  `/model <slug>`; the README documents all three.

## [0.8.0] - 2026-07-10

### Added
- **OpenRouter is now a first-class BYO provider for the CLAUDE (Claude Code) runtime (DIVE-1100).**
  OpenRouter ships a native Anthropic-skin endpoint (`https://openrouter.ai/api`,
  Claude Code appends `/v1/messages`), so the harness talks to it directly with no
  translation proxy. `5dive agent create --type=claude --provider=openrouter
  --api-key=- --auth-profile=<p>` now wires `ANTHROPIC_BASE_URL` +
  `ANTHROPIC_AUTH_TOKEN` (the `sk-or-` key) into the profile's `combined.env` via
  the existing `_apply_byo_claude` path. Because the Anthropic-skin endpoint only
  serves Anthropic first-party models (Claude Code is built around Anthropic
  request semantics, so `openrouter/auto` does NOT work here), the per-tier
  defaults pin concrete `anthropic/*` slugs (`claude-opus-4.8` / `claude-sonnet-5`
  / `claude-haiku-4.5`); operators can override in the model picker. Dashboard
  new-agent wizard now offers OpenRouter for claude-type agents (DIVE-1101).

### Fixed
- **Approval taps now clear gates in shared team-bot mode (DIVE-1093, GH #13 part 3).**
  DIVE-1087 made every per-agent bridge `TELEGRAM_SEND_ONLY` so the single
  `5dive-team-bot-listener` is the sole `getUpdates` consumer — but the listener
  subscribed only to `['message','managed_bot']` and handled only `u.message`, so
  the inline `tna:` approval-button taps were fetched by nobody and human gates
  (`task need --type=approval|secret|manual`) stayed unanswerable from Telegram in
  team-bot mode (the reporter's headline symptom). The listener now subscribes to
  `callback_query` and answers the gate itself: it re-reads the LIVE gate (never
  trusts the tapped payload), resolves the token via the same matrix as
  `plugins/telegram/tna.ts`, then runs `5dive task answer`. As a root daemon its
  `SUDO_UID` is non-agent (satisfies the DIVE-916/950 hard-gate human-evidence
  check) and it also forwards the per-gate `--human-proof` nonce when the tap
  carried one. Fully fail-soft: any stale/deleted task or CLI error just acks the
  tap so Telegram clears the spinner.
- **Shared team-bot members no longer fight the listener over getUpdates (DIVE-1087).**
  With `5dive agent team-bot shared` + poll-fork agents (codex/grok/opencode/agy),
  every per-agent bridge long-polled `getUpdates` in addition to the single
  `5dive-team-bot-listener`. Telegram allows one consumer per token, so N agents +
  the listener 409'd each other and inline approval-button callbacks were silently
  lost (unanswerable `task need --type=approval` gates). `team-bot shared` sets
  `TELEGRAM_SEND_ONLY=1` in the connector env, but codex/grok/opencode/agy spawn
  their MCP bridge with a minimal env and read their own `channels/telegram/.env`,
  which the flag never reached. `5dive-agent-start` now propagates
  `TELEGRAM_SEND_ONLY` into each bridge's `.env` on every boot (and removes it when
  toggled off), and the bridges honor it by structurally skipping the poll loop
  (`acquireSlot`/`bot.start` never run) while keeping the MCP send tools live — so
  the shared listener is the sole poller and approval taps survive.
- **`5dive agent create` (admin isolation) now works on Ubuntu 26.04 (DIVE-1088).**
  sudo-rs (`visudo-rs`, the default sudo on Ubuntu 26.04) rejects wildcards
  *inside* a command argument, so the admin sudoers' `systemctl <verb>
  5dive-agent@*` / `5dive-*.service` lines failed validation and aborted the
  default first-agent (admin) create with no partial install — the error was
  `wildcards are not allowed in command arguments`. `--isolation=standard` was
  unaffected because its grants use a bare trailing `*` (any-args), which
  sudo-rs accepts. Fix: dropped the raw `systemctl` lines (redundant — an admin
  already holds the whole `5dive` CLI as root, which runs `systemctl`
  internally, plus `5dive agent restart|start|stop`) and added a hardened,
  5dive-unit-only `5dive agent _svc <start|stop|restart> <unit>` primitive as
  the scoped replacement for manual service lifecycle. The admin sudoers now
  uses only sudo-rs-valid bare-`*` forms and its privilege scope shrinks.
- **Sandboxed isolation now works for claude agents (DIVE-1033).** Sandboxed
  agents aren't in the `claude` group, so `/home/claude` (0750) — where the
  shared runtime (`claude`, node/nvm) lives — was unreachable, failing both the
  channel-plugin install and `5dive-agent-start` with "Permission denied".
  `create_agent_user` now grants the sandboxed agent a traverse-only ACL
  (`setfacl -m u:agent-<name>:--x /home/claude`): it can exec the binaries by
  known path but cannot list or read claude's home (secrets stay behind their
  own 0600/0700 perms). Cleaned up in `delete_agent_user`. The proper fix
  (relocating the runtime out of `/home/claude`) is tracked as DIVE-1034.
- **Inter-agent delivery no longer silently drops messages (`set -u`
  self-reference).** `inject_and_submit` declared
  `local name="$1" payload="$2" user="agent-${name}" …`, self-referencing `name`
  in the same `local` statement. Under global `set -euo pipefail`, bash aborts the
  function at the declaration before the `tmux send-keys` inject runs, so
  `agent send`/`ask`/`_deliver` never delivered anything — every standard-
  isolation agent on a host was affected. Split the declaration so `name` binds
  first (mirroring `wait_agent_input_ready`). The same latent antipattern was
  fixed in `_team_bot_write_sendonly_env` and `_pack_memory_dir`. Reported by
  agent-triniti.

## [0.7.24] - 2026-07-06

### Added
- **Crash-loop detection in the supervised restart loop (DIVE-1029).** The
  respawn loop that keeps an agent alive now distinguishes a genuine
  usage-limit park (claude ran healthy, then exited) from a crash-loop (claude
  dying within seconds, repeatedly, e.g. the stale plugin-marketplace git
  remote after the org rename that crash-looped 19/21 agents). New
  `hooks/run-loop.sh` helper, wired in by `5dive-agent-start`: on a crash-loop
  it backs off exponentially (2s to 300s) instead of hammering a 2s respawn,
  surfaces the REAL error once (exit code plus the last pane output carrying
  claude's actual stderr) to the paired chats instead of a misleading usage
  banner, and drops a crash-loop flag. `stop-failure-telegram.sh` and
  `resume-after-reset.sh` read that flag to SUPPRESS the false "Usage limit
  reset, agent resumed" banner while the agent is actually just dying. A
  healthy run (>=45s) clears the flag and sends a single "recovered" note.
  Falls back to the original inline loop on boxes that predate the helper.
  Builds on DIVE-902 (DM dedup + single-winner resume-lock).

## [0.7.13] - 2026-07-05

### Changed

- DIVE-1013: **`hire --from-market` now gates before provisioning.** It used to
  resolve the pack, print the DIVE-995 "this pack will run X" disclosure, then
  create a real teammate IMMEDIATELY, so a docs/blog reader or an agent copying
  an example could stand one up unintentionally. Now:
  - `--dry-run` resolves the pack and prints the disclosure but creates NOTHING
    (read-only, runs outside the registry lock — no root, like `agent inspect`).
  - In a TTY it prints the disclosure and requires an interactive `y/N` confirm.
  - Non-interactively it requires an explicit `--yes`, else it aborts after
    showing the disclosure. The resolve/disclosure output is unchanged.

## [0.7.12] - 2026-07-04

### Security

- DIVE-1011: **reject symlink/hardlink members on pack import + inspect**
  (defense-in-depth follow-up to 0.7.11). DIVE-1010's guard refuses `..` and
  absolute member *names*, but a symlink is a distinct escape a name-check
  can't cover: a pack ships a symlink `link -> /etc` (name passes) then a member
  `link/file` (name passes), and on extraction tar follows the on-disk link to
  write outside the mktemp stage. `_pack_safe_extract` now inspects member
  *types* via `tar -tvzf` and refuses any pack shipping a link member — 5dive
  packs never contain links. Modern GNU tar has its own symlink-replacement
  guard, so this is hardening, not an open hole. New symlink-member fixture in
  `pack_disclosure_unit.sh` (30/30).

## [0.7.11] - 2026-07-04

### Security

- DIVE-1010: **harden pack import/inspect against tar path-traversal (zip-slip).**
  A local `.tar.gz` import (`agent import <file>`) bypasses registry signing
  entirely, so a crafted pack with `..` or absolute-path members could have tar
  write files OUTSIDE the mktemp stage. `cmd_import` and `cmd_inspect` now route
  extraction through a shared `_pack_safe_extract` guard that lists members first
  and refuses the pack (with a clear validation error) if any member is absolute
  or contains a `..` path component, extracting nothing. Follow-up to DIVE-995.

## [0.7.10] - 2026-07-04

### Changed

- DIVE-1006: **quiet dangling-link noise for intentional forward-refs.** Follow-up
  to DIVE-991. The memory rules bless a `[[name]]` with no file yet as an
  intentional forward-reference (marks something to write later), but the doctor's
  dangling-link check warned on every one — heavy linkers got a noisy report
  (Marcus: 55/55 warned). `_memory_scan_json` now only warns when the target slug
  is a close edit-distance match to an existing file (a likely typo'd/broken link)
  and names the suspected target ("did you mean [[beta]]?"); links with no near
  match go quiet as intended forward-refs. Actionable typo-suspects stay `warn`;
  intentional stubs no longer pollute the report.

## [0.7.9] - 2026-07-04

### Added

- DIVE-1009: **pack trust layer — close the plugin-hook gap.** Follow-up to
  DIVE-995, from the ship-gate security review. Two holes let a pack still auto-run
  shell on the new agent's tool events despite deny-by-default:
  - Plugin-carried hooks were disclosed by name but never recursed or stripped. A
    bundled plugin registering its OWN shell-on-tool-event slipped `--allow-hooks`
    and installed by default (an incomplete control is worse than none). `agent
    inspect`/`import` disclosure now recurses plugin-carried hooks (`pluginHooks`)
    and `import` scrubs any `.hooks` nested in the plugins block unless
    `--allow-hooks` — same deny-by-default as top-level hooks.
  - Strip now fires on any NON-EMPTY `.hooks` (not just when a `.command` field is
    present), so a future CC hook type that executes without `.command` can't slip
    both the disclosure and the gate. `tests/pack_disclosure_unit.sh` extended
    (23 assertions).

## [0.7.8] - 2026-07-04

### Added

- DIVE-995: **pack trust layer** — the install-time "this pack runs X"
  disclosure and the safety precondition before running any third-party pack.
  New read-only `5dive agent inspect <pack|slug>` unpacks a pack and reports its
  executable surface: hooks (arbitrary shell that auto-runs on the new agent's
  tool events — the agentjacking surface), skills/plugins added, whether it
  re-renders the system prompt, seeds recall memory, or adopts a bundled signing
  key. `agent import` now **prints the same disclosure before recreating** and
  is **deny-by-default on hooks**: a pack's hooks are STRIPPED on import unless
  the importer passes `--allow-hooks`. Import result envelope gains `hooks`
  (`none|stripped(N)|allowed(N)`) and a full `disclosure` object. Covers OSS-6
  item 5's mandatory install disclosure; identity/receipts (item 4) + install
  counts + a PUBLIC marketplace remain split (lodar brand/security decision).

## [0.7.7] - 2026-07-04

### Added

- DIVE-992: the heartbeat tick prompt now injects **memory recall** and a
  **compile nudge** from the shared `_hb_wake` seam. Recall: each `/goal` nudge
  cites the top-k memory/wiki hits most relevant to the task's title+body (BM25
  over the target agent's own store + shared wiki) so the agent starts warm and
  can expand a hit with `5dive memory search`. Compile: if the task looks
  research/knowledge-shaped, the nudge gains a "compile before you close" line
  (karpathy method) — making compile a runtime behavior, not just a convention.
  Both are best-effort and flattened to a single line; a failure never blocks the
  nudge. Covered by tests/heartbeat_recall_compile_unit.sh.

## [0.7.6] - 2026-07-04

### Added

- DIVE-981: `5dive project show` now renders the task_deps dependency
  graph — tasks grouped into topological layers (L0, L1, …) with inline blockers
  and a marked critical path (the longest end-to-end chain). `--json` gains a
  `data.graph` block (nodes with layer/critical/blockers, edge count, layer
  count, and the reconstructed `critical_path`) so a plan can be audited at a
  glance. Covered by tests/project_show_graph_unit.sh.

## [0.7.5] - 2026-07-04

### Added

- DIVE-973: stuck-lane analytics in the daily digest — MTTU
  (mean-time-to-unstick). Sourced from the supervisor_events transition trail
  (which folds in loop_runs.stuck onsets as cause=loop-stuck): each stuck
  episode is a transition into classification=stuck paired with the next
  transition out of it; MTTU is the mean of those durations for episodes that
  recovered in the window. `digest --json` gains a `stuck` block
  (mttuSec/episodes/openStuck/byCause); the text digest adds an "Unstick" line
  plus a still-stuck callout. Same spirit as the zero-human KPI, zero agent
  tokens.

## [0.7.4] - 2026-07-04

### Added

- DIVE-993: `5dive hire <role> --from-market` — one command from the
  open market to an employed teammate. Resolves <role> against the character-pack
  registry (rarity + completeness-tiered pick), provisions from that persona via
  the `agent import` slug path, and slots the new hire into the org chart under
  the pack's role. `--as=<name>` picks the local name (defaults to the slug);
  `--role`/`--title` override the org placement; other flags pass through to
  `agent import`.

## [0.7.3] - 2026-07-04

### Added

- DIVE-991: memory hygiene. New `5dive memory doctor` and a `memory`
  category in `5dive doctor` run a hygiene pass over per-agent memory stores +
  the shared wiki: index drift (MEMORY.md/index.md vs files on disk — missing
  targets are errors, unindexed files warnings), dangling `[[wiki-links]]`,
  stale source refs (a cited `path/file.ts` / `file:line` no longer in the
  codebase — only checked when a code-root is available, so no false alarms on
  customer boxes), and near-duplicate memories (token overlap). `5dive doctor`
  rolls findings up to one row per store; `5dive memory doctor --json` gives the
  itemized list. Pure scanner shared by both, unit-tested in
  tests/memory_doctor_unit.sh.

## [0.7.2] - 2026-07-04

### Added

- DIVE-990: memory-as-onboarding. `agent create --inherit-memory=<scope>`
  seeds a new hire's recall store from shared team knowledge so it boots knowing
  the company instead of cold-starting. Scope is a comma-list of sources — `wiki`
  (the shared team wiki), a sibling `<agent-name>` (its SHAREABLE facts only —
  reference/project, never private user/feedback, same deny-by-default L1 scoping
  as `agent export`), or `all`/`team` (wiki + every sibling). Copies land in the
  agent's own store with a regenerated MEMORY.md index, so `5dive memory search`
  returns team context from the first minute.

## [0.7.1] - 2026-07-04

### Added

- DIVE-989: verifier-by-default now walks a chain of DISTINCT graders
  (project lead, coordinator, maker's manager, org root, technical deputy) and
  takes the first that differs from the maker, so the default no longer silently
  no-ops in the common maker==coordinator case (a lone-root CEO owning all
  unassigned work). Adds _task_resolve_org_root + _task_resolve_deputy.

## [0.7.0] - 2026-07-04

### Added

- Goal decomposition GA: the `5dive goal` line graduates — decompose an
  outcome into a validated task DAG that materializes ONLY on a human-approved
  checkpoint (DIVE-984 planner + DIVE-985 approve->materialize). Version milestone;
  the capability shipped incrementally across 0.6.19-0.6.28.

## [0.6.28] - 2026-07-04

### Added

- DIVE-985: `5dive goal add --from-gate=<id>` completes the approve->materialize
  loop for a gated plan. `--yes` waives ONLY the count checkpoint, so a plan
  carrying a Tier-2 task could be proposed + gated but never built. `--from-gate`
  recovers the plan from the anchor task's body, requires that a HUMAN answered
  the gate `approve` (DIVE-916 human-origin rule: `need_answered_by` must be
  `human:*`, never an agent/TTL clear), re-validates the plan from scratch
  (caps/tier/DAG), then materializes it. It is the only path that materializes a
  Tier-2 plan, is idempotent (refuses to re-build an already-materialized goal),
  and rejects a non-goal or unanswered/non-approve gate. A Tier-2-carrying plan
  now also files its checkpoint gate at HARD tier 2 (was a plain tier-1 decision),
  so it can no longer be 48h-auto-applied or agent-cleared.

## [0.6.27] - 2026-07-04

### Added

- OSS-14: weekly autonomy report. `5dive digest` (esp. `--7d`) gains a one-glance
  "🦾 Autonomy — ran N days without needing you · shipped X · asked you Y×" line
  plus an `autonomy` JSON block (uptimeDays = days since the last human-blocking
  stall, shipped/asked for the window, priorShipped/priorAsked for the trend, and
  currentlyBlocked). Deterministic, rides the existing digest python, zero agent
  tokens — the marketing-flagship framing of the OSS-10 zero-human numbers.

## [0.6.26] - 2026-07-04

### Security

- DIVE-1002: least-privilege agent isolation. New agents now default to
  `standard` isolation (zero sudo) instead of `admin` — a compromised or
  prompt-injected worker can no longer reach root. Bootstrap convenience: the
  FIRST agent on a fresh box (empty registry) is auto-granted `admin`, but the
  resolved tier is recorded EXPLICITLY in the registry (never re-derived from
  create-order); an explicit `--isolation` always wins. The `admin` tier is now
  SCOPED to a `visudo`-validated allowlist — the `5dive` CLI plus non-paging
  `systemctl start|stop|restart` of `5dive-agent@*` / `5dive-*.service` — and no
  longer grants blanket `ALL=(ALL) NOPASSWD: ALL`. The three indirect root
  escapes (`systemd-run *`, `journalctl *`, `systemctl status *` pager `!sh`) are
  excluded; a new `5dive agent restart <name> --defer` runs the deferred
  systemd-run internally (fixed command) so admins never need a raw grant, and
  `5dive crew` now refuses EUID 0 (it execs agent-authored venv Python). Registry
  schema v1->v2 stamps existing field-less agents as explicit `isolation:admin`
  so no live admin is silently downgraded (their sudoers files are untouched; the
  scoped allowlist applies to new admins/fresh boxes). New
  `tests/agent_isolation_unit.sh` (15/15).

## [0.6.24] - 2026-07-04

### Added

- OSS-12: gate SLA escalation — an unanswered T2 gate walks the org chart
  instead of stalling on one recipient. Once a gate ages past
  `_HB_GATE_ESCALATE_DAYS` (env `HEARTBEAT_GATE_ESCALATE_DAYS`, default 5), the
  weekly stale-gate batch in `_hb_gate_ttl_sweep` also CCs the filing agent's
  org-chart parent (`agents_org.reports_to`), so the gate escalates up a level.
  Reuses `gate_pinged_at` + the heartbeat tick as the driver; NEVER auto-answers
  a T2 gate (escalation changes who is pinged, not what clears). New
  `tests/heartbeat_gate_escalate_unit.sh` (5/5).

## [0.6.23] - 2026-07-04

### Added

- DIVE-979: dependency-aware heartbeat scheduling. The per-agent wake now picks
  the next task through `_hb_pick_task`, which (a) SKIPS any todo whose
  `task_deps` still has an open blocker (a `blocked_by` task not yet
  done/cancelled) so no unstartable work is ever handed out, and (b) within a
  priority tier PREFERS the critical path — the todo whose downstream dependent
  chain is longest, via a depth-capped recursive CTE over `task_deps`. Priority
  stays the primary key; critical-path depth is the tiebreaker, then id. The
  urgent/high early-wake probe is likewise gated on being blocker-free. New
  `tests/heartbeat_pick_unit.sh` (7/7) covers the dep graph end to end.

## [0.6.22] - 2026-07-04

### Added

- DIVE-972: enforceable per-loop token ceilings. `task loop start`/`loop spawn`
  now honor a per-loop token budget — a running loop that reaches its ceiling is
  stopped and flagged instead of burning unbounded tokens, and the daily digest
  surfaces each loop's burn against its ceiling so overspend is visible. Closes
  the "runaway loop" gap flagged on the budget-enforcement track.

### Fixed

- Pre-existing shellcheck SC1072/SC1073 in `cmd_supervisor.sh` (a DIVE-971
  artifact) cleaned up to keep the lint gate green.

## [0.6.21] - 2026-07-04

### Added

- DIVE-971: multi-runtime supervisor signals — closes the three supervision
  TODO(P2)s in `cmd_supervisor.sh`. (1) The telegram-poller liveness probe now
  covers codex/grok/antigravity/opencode via a per-type argv pattern
  (`_SUP_POLLER_PAT`), not just claude — each type's bridge dir (`telegram-<x>`)
  is a stable pgrep match. (2) The last-activity/progress age now reads each
  runtime's own transcript root (`_sup_activity_epoch`: codex
  `~/.codex/sessions/rollout-*.jsonl`, grok `~/.grok/sessions`, opencode
  `~/.local/share/opencode/storage`, antigravity
  `~/.gemini/antigravity-cli/brain/**/transcript*.jsonl`), so non-claude agents
  can be classified stuck/no-progress instead of forever-unknown. (3) New
  `drift` classification (cause `goal-drift`): a claude agent with an active
  `/goal` targeting a still-`todo` DIVE task while it progresses elsewhere —
  a STRUCTURAL check (task-id vs status), not a semantic heuristic. All three
  keep the false-negative bias (missing/ambiguous signal => never stuck), and
  `drift` is observe-only — guarded out of the P2 act ladder so no rung, not
  even escalate, can fire on it (no false-stuck regressions on claude agents).

## [0.6.20] - 2026-07-04

### Added

- DIVE-969: verifier-by-default posture (Karpathy autonomy slider). `task add`
  now engages maker->grader verification BY DEFAULT for non-trivial standard
  tasks: it derives acceptance criteria from the title and assigns a grader
  distinct from the maker (project lead, else org coordinator), reusing the
  DIVE-476/477 loop so a plain `task done` hands off to grade instead of closing.
  Trivial chores (bodyless mechanical titles like typo/bump/docs), low-priority
  tasks, recurring templates, and solo orgs with no distinct grader are left
  frictionless. `--no-verify` is the explicit opt-out; `FIVE_VERIFY_DEFAULT=0` is
  a fleet kill-switch. Add output carries `verifyDefaulted` + `verifier`.

## [0.6.19] - 2026-07-04

### Added

- DIVE-984: `5dive goal add "<outcome>"` — goal decomposition v1 (OSS-2). A
  planner agent (via `loop spawn --wait --schema`) turns an outcome into a
  materialized task graph: tasks + `task_deps` edges + assignees under a project.
  Guardrails: hard task/depth cap (reject, never truncate), no tier-lowering
  (reuses the Tier-2 category-floor classifier), a one-gate human checkpoint over
  the count threshold or any Tier-2 task, and `--dry-run` that creates nothing.

## [0.6.18] - 2026-07-04

### Added

- DIVE-976: decision-memory precedent prefill (OSS-11) — when a new gate matches
  a prior ANSWERED gate (same need_type, exact normalized ask-shape, precedent
  tier >= new tier, within 90 days), prefill a BLANK recommendation with the prior
  answer and cite it (Telegram ping + `task show`/inbox). Pure advisory: never
  mutates tier or the clear path, fill-blank-only never overrides a filer rec, and
  a decision precedent must be one of this gate's options — the DIVE-916 invariant
  holds by construction. Adds `ask_shape`/`precedent_ref` columns + an
  acceptance-rate digest line.

## [0.6.15] - 2026-07-04

### Added

- DIVE-968: implement `5dive loop status --handle=<loopId>` — the read-only
  single-loop drilldown that complements the fleet-wide `task loops` board.
  Reports topology/stage/iteration/tokens-vs-ceiling/status plus each backing
  task's live state and a derived `stuck` signal (stored supervisor flag, or a
  running loop at/over ceiling, or with no heartbeat for the stall window).
  Pure read (never spawns/mutates/block-waits), JSON in / JSON out. Retires the
  last `_loop_todo` WIP stub, so no "not yet implemented" verb ships.

## [0.6.11] - 2026-07-04

_Gate-hardening line 0.6.9-0.6.11, merged as `dive-916-931-gate-nonce`._

### Security

- DIVE-916: **close the `sudo`→`--human` gate-forge** with a per-gate HUMAN nonce.
  `task need` now mints a 16-byte nonce for every hard human gate
  (approval/secret/manual), stores only its SHA-256 (`human_nonce_hash`), and
  embeds the RAW nonce solely in the Telegram tap `callback_data` the CLI composes
  as root — the agent's LLM never sees it. `task answer` clears such a gate as
  human iff it presents ONE of two equivalent evidence forms: a matching
  `--human-proof=<nonce>` (the plugin-tap path, whose SUDO_UID is the spawning
  agent) or a non-agent `SUDO_UID` (a claude/root login and the DIVE-931
  secret-drop write, which runs `SUDO_UID=claude`). A bare
  `sudo 5dive task answer --human` from an agent session (SUDO_UID=agent-\*, no
  nonce) is rejected. `manual` joins approval/secret as an enforced human gate.
  Ships **dormant** (audit-only) behind `gate-proof enforce`; flip on once the
  plugin `--human-proof` injection is confirmed live fleet-wide. Scope: this
  closes the realistic/injection-risk forge (an agent one-liner), not the broad
  `sudo su - claude` path (a separate sudo-hardening track). Folds into the
  DIVE-931 secret-drop chain: the drop write clears via the non-agent-SUDO_UID
  form, no nonce-threading needed.

- DIVE-950: **drop the forgeable `--proof` evidence form** (DIVE-916 hardening).
  The DIVE-519 `--proof` token was agent-forgeable — `5dive gate-proof` mint is
  `require_root` only, so any agent could `sudo`-mint a valid token and self-clear
  a gate (the easy one-sudo forge). The `gate-proof <id> <type>` mint subcommand is
  removed (returns a loud, audited error); `task answer` no longer counts `--proof`
  as evidence (the flag is parsed-but-ignored so an in-flight caller mid-deploy
  does not break). Gates clear via the per-gate `--human-proof` nonce or a
  non-agent `SUDO_UID`. Honest scope: this closes the silent one-liner self-clear
  AND the easy sudo-mint forge; it is NOT airtight against a determined agent with
  root `sudo` (instrument-its-own-nonce / `sudo -u claude` / `sudo su - claude`) —
  that is the separate sudo-reduction track. `gate-proof sign`/`verify`/`enforce`
  are unchanged.

### Changed

- DIVE-909: a standalone (non-loop) **manual** human-gate answered `done` now
  closes the task as **done** instead of flipping it back to `todo`. Previously
  completed work parked behind a manual gate had no honest close — the agent
  can't `task done` (blocked by its own pending gate, DIVE-555) and the only
  agent-allowed escape was `task cancel`, which mislabels finished work as
  cancelled (DIVE-524). The already-shipped `✅ Done` Telegram tap
  (`tna:<id>:done` → `task answer --value=done`) now lands on this path and
  closes cleanly across every runtime — no plugin/fork change needed. A
  non-`done` answer still clears the gate → `todo` (the resume path), and loop
  GATE steps are exempt (their manual answer still drives the relay advance).

## [0.6.6] - 2026-07-03

### Changed

- DIVE-906 (create-path token hygiene, part 2 of DIVE-888): `agent create`
  now accepts `--telegram-token=-` and `--discord-token=-`, reading the bot
  token from stdin (same `-` sentinel as `--api-key=-` / `config set
  *.token=-`) so it never lands in argv (and thus never in `ps`). The exec
  tunnel exposes a single stdin channel, so at most one `=-` sentinel is
  allowed per create — a BYO `--api-key=-` combined with a channel
  `--token=-` is rejected up front with a clear usage error rather than
  blocking on a second `cat`. The dashboard new-agent wizard pipes the pasted
  bot token on stdin when no BYO key is present (BYO key keeps stdin when both
  are supplied; the channel token then stays inline as the documented
  residual).

## [0.6.5] - 2026-07-02

### Fixed

- DIVE-901: `agent install antigravity` no longer flakes with "agy still
  missing" when the binary resolves outside `~/.local/bin` (PATH drift /
  image pre-seed): the recipe's gate (`command -v agy`) and the success guard
  (`-x TYPE_BIN`) disagreed, so the recipe no-op'd in 0s and the guard failed
  even though agy works — the same class as grok's opportunistic-symlink gap.
  The recipe now ensures the TYPE_BIN symlink itself, and the install guard
  gives any type's binary a 10s grace for async/late-rename installer drops.

## [0.6.4] - 2026-07-02

### Added

- DIVE-899: every claude agent's per-agent CLAUDE.md now carries the
  self-gated model-tiering default (Fable-as-orchestrator + explicit
  per-subagent model choice: sonnet for mechanical work, opus for
  judgment-heavy work, haiku never). The fragment's first line scopes it to
  Fable sessions, so it is inert on every other model. New
  `model-tiering-CLAUDE.md` shipped to $LIB_DIR by install.sh; appended (not
  copied) after the telegram fragment so both survive. From the DIVE-881
  sniff-test verdict.

## [0.6.3] - 2026-07-02

### Added

- DIVE-897 (DIVE-726 Phase 1b): the memory write/compile path + search scoping.
  `5dive memory add --name --description [--type] [--store=mine|wiki] [--tags]
  [--force]` (body on stdin) writes a frontmatter-stamped memory file with
  provenance (compiled_by/compiled_at), appends the store's index line, and
  refuses token/key-shaped content (tripwire; --force never bypasses it).
  `memory search` gains `--store=all|mine|wiki` + `--agent=<name>` scoping.
  Cross-agent read DECISION: per-agent stores stay per-user 0600 —
  fleet-searchable knowledge is PUBLISHED to the shared wiki via
  `memory add --store=wiki` (deny-by-default, the DIVE-481 distillation-gate
  posture); `--agent` therefore resolves for root only. Cached inverted index
  deferred until stores outgrow a few thousand chunks; embeddings stay Phase 1c.

## [0.6.2] - 2026-07-02

### Fixed

- DIVE-894: gate alerts no longer dead-end on a box with no dashboard. The
  secret/manual CTA lines and any button-less decision/approval alert now carry
  the copy-pasteable on-box fallback (`sudo 5dive task answer <id> ...`, run as
  a human login — claude/root clears approval/secret gates on the human path).
  Companion telegram-plugin 0.5.10 change: a failed gate tap replies with the
  same on-box line instead of "open the dashboard" (lodar hit this live on
  DIVE-790, CLI-only box).

## [0.6.1] - 2026-07-02

### Added

- DIVE-726 Phase 1a: `5dive memory search "<query>"` — queryable team memory
  read-path. BM25-ranked snippets from the agent's markdown memory stores (+ the
  shared wiki when present), section-chunked for provenance and capped at a token
  ceiling. Lexical-first (no embeddings, no new dependency, nothing leaves the
  box); read-only.

## [0.6.0] - 2026-07-02

### Added

- DIVE-891: risk-tiered human gates + TTL (adopted design DIVE-861). `task
  need` takes `--tier=0|1|2`: tier 0 auto-applies the recommendation
  immediately (no ping — the daily digest's new "Auto-cleared gates" section
  is the record); tier 1 pings normally but a new heartbeat sweep applies the
  recommendation after 48h unanswered (provenance `auto:ttl`, closure signed,
  owning agent pinged); tier 2 (the default for approval/secret/manual) never
  auto-applies — stale tier-2 gates instead batch into ONE reminder per
  paired chat after 72h, re-pinged weekly, with manual asks grouped as a
  single "15 minutes" block. Money, public-comms, secret, destructive and
  brand asks are floored to tier 2 in the CLI regardless of the flag; secret
  gates are always tier 2. Loop gate steps and legacy (pre-tier) gates are
  never auto-applied. `task park` gains `--wake=<ts|+Nd|+Nh>` — the same
  sweep auto-unparks the task back to todo when the time passes, so
  "revisit later" stops sitting in the human inbox. New additive tasks.db
  columns: `tier`, `need_asked_at`, `gate_pinged_at`, `wake_at`.

## [0.5.9] - 2026-07-02

### Added

- DIVE-880: bot tokens can now be passed on stdin instead of argv, so they
  never land in `/proc/<pid>/cmdline`, shelld's audit log, or server access
  logs. `agent telegram-getme --token=-` and `agent telegram-discover
  --token=-` read the token from stdin, and `agent config <name> set
  telegram.token=-` / `discord.token=-` do the same — the sentinel `-` form
  `cos set --token=-` and `auth set --api-key=-` already used. The dashboard's
  AddChannelPanel and connect wizard switch to this form via the exec tunnel's
  `stdin` field. Only one `=-` key can be read per invocation (stdin is
  consumed once).

## [0.5.8] - 2026-07-02

### Added

- DIVE-860: `task loop ls` surfaces the latest grade scorecard per builder
  loop run. JSON rows gain `scorecard_json` (raw card string, `''` when
  ungraded — same contract as the `task loops` runs board), joined from
  `loop_runs` by the card's `target` ident; the text board gains a `score`
  column (`84/100` style). Feeds the dashboard Loops tab score chips.

## [0.5.5] - 2026-07-02

### Added

- DIVE-856: claude agents are chat-capable in the web dashboard by default.
  `agent create` folds the token-free `dashboard` channel into every claude
  create on managed boxes (unset `--channels` becomes `dashboard`, explicit
  lists get `,dashboard` appended; `--channels=none` stays the opt-out).
  `agent config <name> set channels=` is now fully comma-list aware and
  dispatches the dashboard plugin install — the backend for the dashboard's
  one-tap "Enable chat" on existing agents.

### Fixed

- Channel lists (DIVE-841) broke several exact-match consumers: a
  `telegram,dashboard` agent lost `AGENT_CHANNEL_MARKETPLACE` (telegram
  plugin resolved against the wrong marketplace → dead channel), was wrongly
  counted as a team-bot relay candidate despite its personal bot, skipped the
  CoS welcome DM / autoPaired flag, and didn't get its plugins preseeded into
  `enabledPlugins`. All channel checks now use the `channel_in_list` helper,
  and the team-bot shared attach preserves a dashboard channel instead of
  clobbering `channels` to bare `telegram`.

## [0.4.10] - 2026-06-28

### Security

- Gate-proof enforcement is now ON by default fleet-wide (DIVE-758, drop 2). The
  install + `--upgrade` paths flip `gate-proof enforce on`, so once a box adopts
  the tamper-evidence build an UNPROVEN agent-path answer to an approval/secret
  gate is rejected. Human taps (`--human`, the Telegram path) always clear and the
  dashboard doesn't answer gates, so live answering is unaffected — this only
  stops an agent self-clearing a human gate. Idempotent + best-effort (never
  blocks install). Toggle off per-box with `5dive gate-proof enforce off`.

## [0.4.9] - 2026-06-28

### Security

- Gate closures are now tamper-evident (DIVE-756). `tasks.db` is group-writable,
  so any claude-group agent could `sqlite3 UPDATE` a human gate answered —
  bypassing the CLI, gate-proof, and all attribution — and the close was logged
  as a spoofable `SUDO_USER`. `task answer` now stamps the real pre-sudo invoker
  (`need_answered_uid` = `$SUDO_UID`) and an HMAC over the closure facts
  (`need_answer_sig`, signed with the root-only gate-proof key). New
  `5dive gate-proof verify <id>` recomputes it and reports `signed`/`valid`: a
  raw-sqlite bypass shows `signed=absent`; tampering with an answer afterward
  shows `valid=false`. Detective half — enforcement (reject on missing/invalid
  sig) is a later flip; this ships additive with no behaviour change.

### Fixed

- Pinned/managed default skills now actually reach **existing** agents
  (DIVE-698). `5dive-refresh-skills.sh` previously skipped any skill already
  present, so a re-pinned skill (e.g. the `openagent` v0.27 pin) only landed on
  brand-new agents while existing boxes kept the stale copy. The refresh now
  **force re-pulls** every skill in `DEFAULT_SKILLS` to its current pinned
  version. Backed by a new `--force` flag on `5dive agent skill <name> add`,
  which drops the existing skill dir before re-installing so the npx path
  upgrades instead of no-op'ing on an already-present directory.

  **Release flow:** to push a re-pinned default skill to the whole fleet, bump
  the pin in `<org>/skills`, then either wait for the daily update cron (which
  runs `5dive-refresh-skills.sh` via `install.sh --upgrade`) or force it now with
  `sudo 5dive-refresh-skills.sh` (all agents) / `sudo 5dive-refresh-skills.sh <name>`.

### Added

- **SessionStart resume-context hook** (DIVE-726 Phase 0, the v0.5 "memory moat"
  floor). After a service restart / crash / rotation a fresh `claude` session
  booted with no idea what the previous one was doing. The new
  `sessionstart-resume-context.sh` hook injects, on every boot, the agent's
  in-flight `in_progress` task(s) — read straight from the durable task queue, so
  the thread is recovered even on an **abrupt** crash, not just a graceful stop —
  plus the head of the latest carryover note. Output is **bounded** (a few
  in-flight task lines + a carryover pointer/head), so per-turn cost stays flat
  regardless of how many tasks/carryovers exist: retrieval, not injection. Wired
  into `agent_setup.sh` for every channel (no plugin defines SessionStart, so no
  double-fire) and shipped to `$LIB_DIR` by `install.sh`'s hook loop. Existing
  agents are backfilled into their `settings.json` by a one-shot pass.

- `5dive agent import --from-persona=<file.persona.yaml>` (DIVE-658 #2, Mark) —
  provision a **live agent from an OpenAgent persona**. The persona carries
  identity (name, role, look, voice, behavior); runtime config comes from flags
  (`--type` default claude, `--isolation`, `--model`, `--effort`, `--channels`,
  …). The CLI synthesizes a v1 character pack from the persona — a generated
  CLAUDE.md identity doc, the portrait fetched from `face.ref` as the avatar, and
  a manifest seeding `find-skills`/`5dive-cli`/`compile-knowledge`/`openagent` —
  then runs the normal import flow. Turns the openagent skill's self-**author**
  into self-**provision**: an agent can mint a persona and stand up a teammate
  from it. Structural gate mirrors the v0.1 schema's required fields.
- Fleet rollout of the `openagent` self-author skill (DIVE-658, Mark). Every
  agent-create path now seeds `openagent` (from `<org>/skills`) alongside
  `find-skills`, `5dive-cli`, and `compile-knowledge`, so new agents can author
  + validate their own OpenAgent persona out of the box. Covers all five types
  (claude, codex, grok, antigravity, opencode). Existing boxes are backfilled by
  `5dive-refresh-skills.sh` on the daily update cron (runs as the agent user,
  post-first-boot, idempotent — skips agents that have never booted to dodge the
  missing-`~/.claude` gotcha).

## [0.4.2] — 2026-06-23

### Changed

- `5dive digest` auto-delivery is now **opt-in, off by default** (DIVE-544, Mark).
  The per-box cron runs hourly but `digest tick` is gated on a per-box pref that
  defaults OFF — nothing is sent until a customer enables it. New
  `5dive digest on [--at=<0-23>] | off | status` writes that pref (stored in the
  state dir; `install.sh` seeds it off and never clobbers it, so the choice +
  custom hour survive CLI updates). `status --json` → `{enabled,hour,lastSent}`.
  Backs the telegram `/digest` command (DIVE-624). Each trial sends at most once
  per day, at the configured hour, box-local.

## [0.4.1] — 2026-06-23

### Added

- `5dive digest` (DIVE-544 Tier 1) — deterministic per-fleet standup digest built
  from data every fleet already has: the task queue (shipped in the last 24h /
  in-progress / open human gates), `usage` (token burn + share-of-limit), and
  heartbeat health. Zero agent reasoning, zero tokens; works on every fleet incl.
  a solo-agent box and never depends on a CEO/coordinator agent. `--json` for
  machines, `--7d` to widen the window. `--send` delivers it to the paired
  Telegram chat (same owner-channel path as the gate alerts). `5dive digest tick`
  is the cron driver, installed by `install.sh` as `/etc/cron.d/5dive-digest`
  (daily 07:00 box-local) so every customer fleet auto-receives its overnight
  recap.

## [0.4.0] — 2026-06-23

Headlined by `5dive loop` — agent-native multi-agent orchestration. Cuts the
accumulated 0.2.x–0.3.x rolling-fleet changes (point versions noted inline)
into a tagged release; the major bump marks loop as the new orchestration line.

### Added

- `5dive loop` — agent-native multi-agent orchestration (0.3.34, LOOP-7). Six
  machine verbs over the existing fleet primitives, all honoring a per-loop
  token `--ceiling` (self-halt + escalate-with-proof, never a surprise bill):
  `spawn` (the atom — backing task + heartbeat), `verify` (maker→verifier
  wrapper, DIVE-474), `panel` (N diverse-lens graders + quorum vote, cost-dial
  default N=3/quorum=2), `map` (index-aligned fan-out, null-on-fail, bounded
  concurrency), `until-dry` (K-empty-round discovery with seen-set dedup),
  `collect` (barrier gather). Plus the human control window: `task loops` now
  shows a live `loop_runs` board with `--runs`/`--watch`/`--kill <loopId>`
  (deferred-safe; read-only otherwise), and `usage loops` rolls up token spend
  per topology / per loop. New additive `loop_runs` table. 59 unit tests across
  tests/loop_*_unit.sh.
- `5dive hire <name> [--type=claude] [--role=… --title=…]` (0.3.33, DIVE-603) —
  ergonomic alias for `agent create` so demos/docs can say "hire a CTO" and have
  the real command match the story. Thin sugar: defaults `--type=claude`,
  forwards every other flag straight to `agent create` (inherits the full create
  surface), and peels off `--role`/`--title` to apply via `org set` once the
  agent exists. `agent create` stays canonical.

### Fixed

- `agent config <name> set telegram.allowed-users=<csv>` now actually writes the
  allowlist when set on its own (0.3.32). The dispatch that seeds `access.json`
  (`install_channel_for_agent` → `seed_telegram_access_allowlist`) was gated
  behind a token rotation or a `channels=telegram` change in the same call, so a
  standalone allowlist update validated, reported success in `applied_keys`, and
  silently no-op'd — leaving the file unchanged (e.g. a second id never landed).
  The guard now also fires when `telegram.allowed-users` is present, falling back
  to the stored connector token. Seeding remains additive (appends ids); use
  `agent telegram-access set` to remove an id or rewrite the list wholesale.

- Loop human-gates are now actually human-enforced (0.3.31, DIVE-560). A loop
  `gate:approval` step fired as `--type=decision` (purely to get the
  Approve/Do-better buttons), but a decision gate is agent-clearable — an agent
  could self-answer it (`need_answered_by=<agent>`), silently undercutting the
  public "you get the final say at the gate" claim. The gate now fires as
  `--type=approval`, which is human-enforced (the DIVE-394/519 agent-uid block +
  gate-proof); the standard Approve/Deny buttons cover it with no plugin change
  (a "denied" tap drives the loop's bounce-back-and-redo). Belt-and-suspenders:
  a loop approval gate only advances on a `need_answered_by=human:*` answer, so
  even an audited `sudo` clear can't progress the relay. Also fixed the
  bounce-match vocabulary — the approval reject value `denied` does not contain
  the substring `deny`, so without this a human's DENY would have wrongly
  advanced the loop.
- Heartbeat nudged the wrong task id (0.3.30). The wake `/goal` and every
  heartbeat log built the `DIVE-N` from a task's raw `id` column, but with the
  projects primitive (DIVE-484) the global row id and the per-project display
  number diverge as soon as a non-default project consumes ids — e.g. the 10
  `POST-*` rows pushed row 570's display ident down to `DIVE-560`. The agent was
  then told to complete a phantom `DIVE-570` it could never find/claim, so the
  nudge re-fired every tick and the starvation WARN fired. New `_hb_ident`
  resolves the true display ident from the row id; the numeric id stays the DB
  and registry key. Nudge text, the stale-task reaper logs, the materializer
  logs, and the tick wake/nudge/starve logs all now name tasks by their real
  ident.

### Added

- `5dive task escalate <id>` (DIVE-449): "flag for attention" — bumps the task's
  priority up one tier (capped at urgent), stamps `escalated_at`/`escalated_by`
  for audit, and best-effort pings both the owning agent and the paired human.
  Backs the new Escalate button on the Telegram `/task_<id>` detail view. Does
  not file a human gate (`task need`) or reassign (`task assign`).

## [0.1.88] — 2026-06-12

### Added

- Org-rename migration for EXISTING agents (follow-up to 0.1.87, gap caught
  by dev): each agent's persisted marketplace state — the source URL in
  `known_marketplaces.json` and the marketplace clone's git origin remote —
  still pointed at `5dive-com`. `5dive-refresh-plugins.sh` now rewrites both
  to the live org (same probe + `GH_ORG` override) at the top of each agent's
  refresh, before `plugin marketplace update` runs. No-op until the rename
  lands; idempotent after.

## [0.1.87] — 2026-06-12

GitHub org rename prep: `5dive-com` → `5dive-ai`.

### Changed

- All GitHub fetch sites (self-update, installer `REPO`, plugin/skill
  tarballs, marketplace registration, doc links) now resolve the org at
  runtime via a new `gh_org()` helper: probe `5dive-ai` once per process,
  fall back to `5dive-com`, `GH_ORG` env overrides. Installs and updates
  work identically on either side of the rename, so the old org can be
  parked immediately after renaming with no redirect window to squat.
- install.sh header now documents the canonical `install.5dive.com` alias
  instead of a raw GitHub URL.

## [0.1.84] — 2026-06-11

Catch-up release covering 0.1.78 → 0.1.84.

### Fixed

- `5dive init` / `agent create` no longer dies on a fresh OSS host with
  "bun not on PATH" (DIVE-265). install.sh deliberately never installs bun,
  and managed boxes get it from provisioning — so the first telegram agent on
  a clean self-hosted box hit a hard fail and pointed at `doctor --repair`.
  All five channel-plugin prechecks (claude/codex/grok/antigravity/opencode)
  now self-heal: when the agent user can't see bun, the CLI installs it
  system-wide (`BUN_INSTALL=/usr/local`, root-owned, visible to every agent
  user with no PATH wiring) and only fails if that install itself fails.
  Caught by lodar testing `5dive init` pre-HN, 2026-06-11.

- `agent config set channels=telegram` (and `channels=discord`) now stages the
  channel plugin synchronously before the deferred restart (DIVE-250). A bare
  `channels=<plugin>` with the token already on disk used to skip the install
  dispatch entirely, so the restarted session could boot with
  `--channels plugin:…` but no staged plugin — no channel tool, and the agent
  improvises (raw Bot-API curl, seen live on the demo box 2026-06-10). The
  dispatch now runs on every channel attach (the install helpers are
  idempotent), and a fail-closed gate refuses the restart with a clear error
  if the claude plugin cache dir is still missing after a short poll.

- `agent list` / `agent info` no longer abort when an agent's per-type runtime
  config is absent. The DIVE-211 model/effort enrichment reads each agent's
  config via `resolve_agent_model`/`resolve_agent_effort`; for `antigravity`
  those `jq` against `~/.gemini/antigravity-cli/settings.json`, which a
  `--defer-auth` agy agent does not have until its first boot writes it. The
  resolvers returned non-zero, and the unguarded `model=$(…)` assignment tripped
  the bundle's `set -e`, killing the command mid-build → empty output. Callers
  (and the smoke harness) read that as "agent not in registry" even though the
  agent was registered fine. The resolvers are now exit-0 on a missing/unreadable
  config (their documented best-effort contract), with `|| true` belt-and-
  suspenders at the call sites (DIVE-230).

### Added

- `agent list --json` now carries each agent's `model` and `effort` (DIVE-211),
  read the same best-effort way `agent info` already resolves them (empty →
  `null`; effort is claude-only). Lets the dashboard render a per-row model
  badge + model/effort picker without an N×`agent info` fan-out.

- Shared team bot quality-of-life across the span: `team-bot discover` finds
  the group id itself (DIVE-247, 0.1.81); new agents auto-attach to the shared
  team bot with their own forum topic, `--no-team-bot` opts out (DIVE-248,
  0.1.82, incl. the never-booted-agent fix); task-board `jq: Argument list too
  long` fix on big boards (DIVE-222, 0.1.79); task gate alerts follow the
  conversation to the last human chat (DIVE-259).

## [0.1.68] — 2026-06-07

### Added

- `task need --recommend="<option>"` (DIVE-148): the filing agent's advised
  choice. The human alert now leads with `✅ Recommended: <X>` before the ask,
  ⭐-marks that option in the numbered list, and sorts/⭐-prefixes its tap button
  first — so the owner sees the advised answer first instead of hunting for it.
  For a `decision` it must match one of `--options`; for `approval` it's free
  text (approved/denied); rejected for secret/manual. Button `callback_data`
  keeps the ORIGINAL option index, so the display reorder never renumbers the
  `tna:` payload. New additive `recommend` column; surfaced in `task show` +
  `task inbox`. The heartbeat nudge + notify-user skill now tell agents to keep
  the ask to one crisp question (detail in the body) and always pass a
  recommendation.

### Changed

- `task done`/`cancel` `--notify` ping shows only the result's FIRST line
  (`${result%%$'\n'*}`); the full result still lives on the record (`task show`).
  Keeps the owner's phone ping to a glanceable one-liner. (DIVE-150 follow-up)

## [0.1.67] — 2026-06-07

### Changed

- Heartbeat idle/blocked detection now uses the native `claude agents --json`
  signal (CC ≥2.1.162) instead of only scraping the tmux pane (DIVE-132).
  `_hb_agent_idle` consults `claude agents --json` first — matching the agent's
  inner-claude PID so dispatched background sub-agents are ignored — and reads
  that session's `status`: `idle` → idle, `busy` → working, `waiting` →
  **blocked** (with the `waitingFor` reason: permission prompt / worker request /
  sandbox request / dialog / input needed). This is more reliable than the
  byte-identical-pane heuristic and, crucially, distinguishes an agent **blocked
  on a prompt** (which should be surfaced/unblocked, not reclaimed) from one
  genuinely working from one idle. The pane-scrape remains as the fallback for
  non-claude CLIs (codex/grok/agy/opencode) and whenever the native signal is
  unavailable (claude not running, binary missing, no matching session). The
  no-clobber gate in the tick now defers on a blocked reading too and logs a WARN
  surfacing the block reason, so a wedged permission prompt is visible in the
  heartbeat log rather than silently deferred. New exit code `3` (blocked) and
  `_HB_IDLE_REASON` carry the distinction; idle-stall reclaim still fires only on
  a confident idle (rc 0), so a blocked agent is never reclaimed.

## [0.1.66] — 2026-06-07

### Added

- Recurring tasks step 2 (DIVE-138): the heartbeat tick now **materializes** due
  recurring templates into standard todos. A new `_cron_matches` evaluator
  (supports `*`, ints, lists, ranges, `*/n`, `a-b/n`, the day-of-month/day-of-week
  OR-rule, and Sunday as both 0 and 7) runs a materializer pass at the top of the
  tick — before the wake loop, and failure-isolated so it can never abort the
  wake — that clones each due template into a `kind='standard'` todo (copying
  title/body/priority/assignee/created_by). New columns `from_template_id`
  (instance → template link, used for the **skip-if-open** dedup so dailies don't
  pile up) and `fresh` (per-template clean-session pref, default on for recurring
  templates via `task add --recurring`, with `--fresh`/`--no-fresh` to override).
  The materialized instance carries `fresh` and the heartbeat `/clear`s before
  working it regardless of the agent-level fresh setting. A `last_fired_at` guard
  prevents a double-fire when two ticks land in the same matching minute.
  - **v1 limitation:** no catch-up for missed ticks — if the host is down over a
    scheduled minute (or the schedule is finer than the ~5m tick interval), that
    occurrence is skipped, not backfilled. Fine for coarse (daily/hourly) jobs.

## [0.1.65] — 2026-06-07

### Fixed

- `5dive agent send` / `agent ask` no longer silently drop large multi-line
  payloads. A big `send-keys -l` is absorbed by the TUI as a bracketed paste
  (`❯ [Pasted text #N]`) and a single trailing Enter raced into / was swallowed
  by the paste, so the turn never started and the message vanished — intermittent
  and size-correlated. New `inject_and_submit()` helper types the body, pauses so
  the paste commits, sends Enter, then confirms the pane left the unsent-paste
  state, retrying Enter up to 5x; if still unsubmitted it warns (`step`) instead
  of falsely reporting success. Both `send` and `ask` route through it.
  Live-proven on a throwaway agent (50-line paste submitted first Enter). (DIVE-147)

## [0.1.64] — 2026-06-07

### Changed

- `rotation set` now stamps `.rotation.lastSet` (`{by, at, fromEnabled,
  toEnabled}`) onto the registry, and `rotation get` surfaces it in both
  `--json` (a `lastSet` field) and human output (`last set: <to> (was <from>)
  by <who> at <ts>`). Writer precedence matches the audit log
  (`FIVEDIVE_AUDIT_USER` → `SUDO_USER` → `USER`). A concurrent-toggle war is now
  diagnosable from live state, not just the audit log. Legacy registries with no
  `lastSet` read back as empty, no error. (DIVE-126)

### Fixed

- `_mirror_send` Telegram posts are now time-bounded (`--connect-timeout 5
  --max-time 10`) so a hung or slow Telegram API can't wedge the foreground
  callers that run it after a DB write has already committed (`task need`
  notify, inter-agent outbound mirror). (DIVE-115)

## [0.1.63] — 2026-06-07

### Changed

- "Needs you" Telegram message drops the footer entirely (was the
  `5dive task answer <id> --value=…` CLI hint, then a dashboard pointer). Both
  were noise in a message the *user* receives: tap buttons cover
  decision/approval, and button-less gates (secret/manual) still surface on the
  dashboard "Needs you" card. The message is now just the header, the ask, and
  (for decisions) the numbered options + buttons.

## [0.1.62] — 2026-06-07

### Fixed

- "Needs you" Telegram message was hard to read and its tap buttons cropped.
  Now: the message separates header / ask / options / footer with blank lines
  (a long `ask` no longer renders as a wall), options are listed one per line
  and numbered to match the buttons, and the tap buttons use an adaptive layout
  — greedily packed up to a ~24-char width budget (max 3 per row) so short
  options share a row while a long label breaks onto its own full-width row
  instead of being truncated. Button index → `tna:` payload is unchanged, so
  the plugin's tap-to-answer handler still resolves correctly.

## [0.1.61] — 2026-06-07

### Added

- Recurring tasks, step 1 (data model + create path). Tasks gain a `kind`
  column (`'standard'` default | `'recurring'`) plus `schedule` (a 5-field cron
  expression) and `last_fired_at`. A `kind='recurring'` row is a **template**,
  not work: it's excluded from `task ls`, the heartbeat TODO count + wake, and
  the human inbox, so it's never picked up directly.
  - `task add --recurring="<cron>"` (alias `--schedule=`) creates a template;
    the cron expression is shape-validated and `--recurring` + `--parent` is
    rejected.
  - `task ls --recurring` lists templates with their schedule + last-fired.
  - Migration is additive (existing rows backfill to `'standard'`), zero risk.
  - Not yet wired: the materializer that clones a template into a todo on
    schedule (step 2) and dashboard CRUD (step 3).

## [0.1.60] — 2026-06-07

### Fixed

- `heartbeat tick` **never woke an agent**. `_hb_reclaim` printed its
  `reclaimed cancelled` counts with no trailing newline, so the caller's
  `read -r ... < <(_hb_reclaim ...)` returned non-zero (EOF before delimiter)
  and, under `set -euo pipefail`, aborted the whole tick right after the first
  enrolled agent's reclaim step — before any wake could happen. Tell-tale: every
  tick logged `checked 0` (the summary only printed when *no* agents were
  enrolled, so the loop body never ran) and a manual `heartbeat tick` exited 1
  with no output. Fixed by emitting the newline and guarding the caller `read`.
- `heartbeat`: `--no-fresh` was silently ignored. Both the `ls` display and the
  tick's wake path read `.heartbeat.fresh // true`, and in jq `false // true`
  evaluates to `true` (the `//` operator treats `false` like `null`), so a
  stored `fresh=false` was coerced back to fresh-on (the agent still got
  `/clear`). Now read with an explicit `has("fresh")` check.

### Added

- `task done` / `task cancel` accept `--notify`: DM the paired human a one-line
  `✅ [DIVE-N] done: <result>` / `⚠️ [DIVE-N] cancelled: <result>` summary,
  reusing the same best-effort Telegram poster as `task need`. The heartbeat
  nudge passes `--notify` so autonomous queue work surfaces a finish line
  without streaming full progress.
- `heartbeat` nudge now routes a task that needs a human decision/approval/
  secret/manual step to `task need` (files a "needs you" gate that pings the
  owner) instead of silently cancelling it; cancel is reserved for genuinely
  irrelevant/impossible tasks. The `/goal` terminal condition accepts a
  blocked-with-gate task as satisfied.

## [0.1.59] — 2026-06-06

### Changed

- `heartbeat tick`: an agent is no longer wedged for hours by a single stuck
  `in_progress` task. The old reaper only force-cancelled after `everyMin × 3`;
  the tick now unwedges via three escalating rules — (a) **orphan-by-restart →
  todo**: if the agent's live claude process started *after* the task did, the
  session that claimed it is gone (rotation/restart/crash/context-reset), so the
  task is reclaimed instantly; (b) **idle-stall → todo**: same process, but the
  task has sat past a 20m grace and the agent is idle now (claimed then walked
  away); (c) **hard cap → cancel**: the existing runaway backstop. (a)/(b)
  reclaim (work still needs doing); only (c) cancels. New `reclaimed` counter.
- `heartbeat tick`: **no-clobber wake gate** — never `/clear`+nudge an agent
  that's mid-turn or in a live conversation (the busy-guard only saw an open
  *task*, not interactive/working state). Uses a dumb, CLI-agnostic idle probe
  (pane byte-identical across a short sample + input prompt present). New
  `active` skipped counter.
- `heartbeat tick`: **wake-on-enqueue** — an `urgent`/`high` task that lands
  since the agent's last wake triggers an early wake on the next tick instead of
  waiting out the full cadence (still gated by busy/spread/idle).

## [0.1.58] — 2026-06-06

### Changed

- `heartbeat tick`: spread agents that share an Anthropic account so they never
  start together. Two same-account agents waking on one tick burst the shared
  account and trip a 429; the tick now requires an even slice of the cadence
  between same-account wakes (`gap = everyMin / agents-on-account`, e.g. 2 agents
  @ 60m → 30m apart, 3 → 20m) and self-heals as agents join. The account's last
  wake is derived from existing `lastRunAt` values plus an in-tick guard (no new
  state); deferred agents stay due and slide later until they clear the gap, so
  phases converge to even spacing on their own. Single-account agents and agents
  with no `authProfile` are never deferred. The tick also now processes
  oldest-waiting agents first so a fresher sibling can't starve an older one of
  the shared slot. Surfaced as `spread` in the tick's skipped counters.

## [0.1.55] — 2026-06-06

### Added

- **Tap-to-answer inline buttons on the `task need` ping** (DIVE-117, Part 1).
  The DIVE-105 Telegram alert now carries Telegram inline buttons for the
  finite-option gates — a decision's `--options` (one button each) and an
  approval (Approve / Deny) — so the human answers with a tap. callback_data is
  `tna:<numericId>:<idx|approved|denied>` (numeric id + option index, under
  Telegram's 64-byte cap; the value is re-resolved from the DB on tap, never
  trusted from the payload). **Gated to `type=claude`** agents — only the claude
  telegram plugin (0.4.59+) has the `tna:` callback handler today; codex / grok
  / antigravity keep the plain text ping until their handlers land (DIVE-118).
  Free-text / secret / manual gates are unchanged (nothing to button).
  `_mirror_send`/`_mirror_post` gain an optional `reply_markup` arg.

## [0.1.54] — 2026-06-06

### Added

- **Instant Telegram ping on `5dive task need`** (DIVE-105, the Human Task
  Inbox notifier). The moment an agent files a human gate, the paired human
  gets one DM — `🙋 [DIVE-N] needs you: <ask>` (with an `Options:` line for a
  decision), leading with the dashboard CTA and a `task answer` tail for
  power-use — so a gate doesn't sit unseen until someone opens the dashboard.
  Fires from the single `task need` chokepoint (no cron) and reuses the
  existing Telegram send path (`_mirror_post`). Targets the human DM allowlist
  (`allowFrom`), falling back to the agent's bound forum topic when no DM is
  paired, so the ask is never silently lost. Fully best-effort and self-gating
  in the shape of `mirror_interagent_outbound`: a missing token / access.json
  or a dead Telegram call returns 0 and never blocks or fails the gate write.
  The daily "still waiting" digest + >48h nudge are deferred to v1.1 (they need
  a per-box cron).

### Added

- **Human Task Inbox — `5dive task need` / `task inbox` / `task answer`**
  (DIVE-103, the CLI data layer behind the dashboard inbox feature DIVE-102).
  `task need <id> --type=decision|secret|approval|manual --ask="…" [--options=A|B]`
  parks a task on a human (status `blocked`; assignee set to the gating agent
  as owner-of-record). `task inbox` lists the still-pending gates,
  priority-ordered. `task answer <id> [--value=…]` records the answer,
  recomputes status (back to `todo` only if no task-blocker edges remain — the
  human gate and `block` edges share the `blocked` status), and best-effort
  pings the owning agent to resume via the existing agent-send path. Five
  additive, NULL-default columns on `tasks` (`need_type`, `ask`, `need_options`,
  `need_answer`, `need_answered_at`), surfaced in the `task ls` / `inbox` /
  `show` `--json` shape for the app to mirror. A `secret` gate never stores its
  value in the group-readable db (records only that it was provided; the agent
  loads the key out-of-band), and the resume ping never embeds the answer
  (avoids the group-chat outbound mirror leak).

## [0.1.52] — 2026-06-05

### Added

- **`5dive agent config <name> set effort=<low|medium|high|xhigh|max>`** —
  closes the parity gap with `set model=`. Reasoning effort is claude-only
  (writes `effortLevel` into the agent's `settings.json`, the same key the
  telegram plugin's `/effort` writes), validated against the five levels, and
  errors clearly for non-claude types. Applied via the existing deferred
  ~1s restart, like the model setter. `xhigh`/`max` are Opus-tier (Sonnet caps
  at `high`) — not gated by model here, matching the plugin picker.
- **`5dive agent info` now surfaces effort** — `effortLevel` is read alongside
  the model (`resolve_agent_effort`); rendered as `model · effort <level>` in
  text and as a new `effort` field (null when unset / non-claude) in `--json`.

## [0.1.51] — 2026-06-04

### Changed

- Agent welcome message: dropped em-dashes, reads the real configured model, and
  no longer prints a raw "default" placeholder.

## [0.1.50] — 2026-06-04

### Fixed

- **Account rotation silently failed to switch accounts** (also hit team
  accounts that repeatedly trip a usage/spend limit). `agent rotation rotate`
  builds the candidate list with `jq` using only `--argjson` args and no input;
  the call was missing `-n`, so when invoked from the StopFailure hook (empty
  stdin) jq processed zero inputs and returned an empty string. That empty
  string then crashed the next jq (`--argjson c ""` → "invalid JSON text"),
  aborting the rotate *after* it had already written the leaving account's
  cooldown. Net effect: the agent cooled the account it was on but never moved
  off it, so it sat parked on the limited account until a human re-logged in.
  Fixed by adding `-n` (`jq -c` → `jq -cn`). Rotation now reaches Tier-1/2/3
  selection as designed.

## [0.1.42] — 2026-06-02

### Fixed
- Rotation auto-resume now reliably **replies** on the new account. The fix in
  0.1.41 made the resume prompt parse, but it was still injected as a startup
  positional — which claude processes ~200ms *before* its telegram MCP server
  finishes connecting. That first turn's tool list therefore lacked the reply
  tool, so the resumed agent reported "MCP disconnected" and went silent
  (verified: prompt queued at T+0.147s, MCP connected at T+0.343s). Fix:
  `5dive-agent-start` no longer passes the prompt as an arg. It launches a bare
  `claude --resume <id>` and a deferred watcher types the prompt into the
  session only after claude's input prompt is ready + a short MCP-settle buffer
  — so the turn has the reply tool. Bare resume (manual `/resume`, no line-2
  prompt) is unchanged. Pairs with telegram plugin 0.4.51, which broadened the
  prompt to `continue and reply to the latest message`.

## [0.1.41] — 2026-06-02

### Fixed
- Account-rotation auto-continue now actually resumes the in-flight turn on the
  new account. `5dive-agent-start` seeded the resume prompt as a bare trailing
  positional (`claude --resume <id> … --channels plugin:telegram@… continue`),
  but `--channels` is a **variadic** flag — it swallowed `continue` as a second
  channel name, claude rejected it (`entries must be tagged`) and exited code 1,
  and the supervisor loop respawned a plain, idle, context-less claude. The new
  account then sat at the prompt until the user re-pinged. Fix: separate the
  prompt from the args with a literal `--` so option parsing ends before the
  positional turn (`claude --resume <id> … --channels … -- continue`). Manual
  `/resume` (no line-2 prompt) was unaffected and stays unchanged.

## [0.1.34] — 2026-06-01

### Added
- `5dive update --check` — read-only version probe (no root, no mutation):
  compares the installed CLI to the published release and reads the last
  managed nightly soft-update result, reporting `{current, latest, behind,
  stale, lastUpdateOk, lastUpdateAt}`. `stale` is true only when the box is
  behind **and** the auto-update isn't closing the gap (failed, never ran on
  record, or overdue past ~36h) — so it doesn't flag a box that's merely a
  release behind with a healthy nightly that'll catch up. Powers the dashboard
  maintenance "your CLI is out of date — update now" banner.

## [0.1.33] — 2026-06-01

### Added
- `5dive self-update` (alias `5dive update`) — on-demand upgrade for
  self-hosted boxes that have no scheduler of their own. Fetches `install.sh`
  and runs `--upgrade` (refreshes the CLI, `5dive-agent-start`, hooks, skills,
  the systemd template, and plugins via `5dive-refresh-plugins.sh`), then
  restarts every running agent so the refreshed plugins/CLIs actually load — a
  live agent keeps its old plugin in memory until it restarts, the usual cause
  of "plugin still shows the old version" after an upgrade. Root-only; `--json`
  reports which agents restarted. Managed boxes keep their nightly scheduler;
  running it there is a harmless, idempotent no-op beyond the restart.

## [0.1.31] — 2026-05-31

### Added
- `5dive agent skill --all list [--json]` — bulk variant that lists installed
  skills for every registry agent in a single invocation, looping serially.
  The dashboard's agents page previously rendered "Installed" pills by firing
  one `agent skill <name> list` exec per agent at once; each spawns a sudo+npx
  process, so on swap-bound boxes the concurrent fan-out saturated shelld, the
  control-plane fetch timed out, and the dashboard 502'd (the account-switch
  modal shares that exec path). The bulk command collapses N concurrent execs
  into one serial loop the box can absorb. `--all` only supports `list`; add/rm
  stay per-agent so a mutation's blast radius is always a single named agent.
  Per-agent extraction refactored into a shared `_skill_list_json` helper so the
  single and bulk paths derive the list identically; best-effort per agent (a
  failure yields an empty list, never aborts the loop).

## [0.1.26] — 2026-05-30

### Added
- `5dive agent config <name> set model=<id>` — uniform model switch that writes
  the selected model into the per-type runtime config the CLI loads, applied on
  the existing deferred restart. The symmetric write side of `agent info`'s
  `model` read, so each fork's `/model` can shell out to one CLI path instead of
  writing its own runtime config. Type-aware: codex/grok edit `config.toml`
  preamble-safely (replace an existing top-level `model =` or prepend above the
  first `[table]`, never binding the key to a section or duplicating it);
  claude/antigravity merge-write the `.model` key in `settings.json` preserving
  all other keys. Atomic (tmp + rename), existing owner/mode preserved, and
  refuses to create a missing config (so it can't drop other settings or
  suppress codex's first-run baseline). Not cached in the registry — `agent
  info` reads the live file, so a model changed via the native CLI stays
  authoritative.

## [0.1.25] — 2026-05-30

### Added
- `5dive agent info <name> [--json]` — single-agent detail that resolves the
  coding-CLI version and the selected model alongside the registry identity +
  live systemd state. The version comes from the type's `TYPE_BIN` binary
  (`--version`), the model from the per-type runtime config the CLI actually
  loads (codex/grok `config.toml`, claude/antigravity `settings.json`). Both are
  best-effort and surface as `null`/`—` when the runtime doesn't persist one
  (e.g. grok/antigravity default to the CLI's built-in pick). JSON fields:
  `cliName`, `cliVersion`, `model`. This lets each fork's `/status` read one
  uniform source instead of shelling every runtime's config itself (the binaries
  aren't on the agent user's PATH, and each type stores its model differently).

## [0.1.24] — 2026-05-30

### Added
- First-class **antigravity** (agy, Google's Gemini CLI) Telegram support
  (`TYPE_CHANNELS[antigravity]=1`). antigravity was already a first-class type
  everywhere else; this flips on the Telegram channel path — provisioning,
  cred-seed into `~/.gemini/channels/telegram/`, global `~/.gemini/config/`
  mcp_config + hooks wiring at boot, connector token + inter-agent mirror, and
  pairing / telegram-access — mirroring the grok path. All four agent types
  (claude, codex, grok, antigravity) now reach Telegram with full MCP tools +
  pairing.

## [0.1.23] — 2026-05-29

### Changed
- Post-pairing welcome DM is now per agent type. Previously every type got the
  Claude welcome — codex/grok bots greeted the user as "Claude agent" and
  advertised a model/effort (read from claude's `settings.local.json`) + voice
  that don't apply to them. Now `send_welcome_message` takes the agent type
  (threaded from `pair`) and branches: claude keeps its model/effort + voice
  line; codex/grok say "Codex agent (OpenAI Codex)" / "Grok agent (xAI Grok)"
  and drop the Claude-specific lines. Copy also refreshed across all three.

## [0.1.22] — 2026-05-29

### Changed
- Telegram access/pairing commands now work for **codex** and **grok** agents,
  not just claude (DIVE-4). All three share the same access.json schema
  (`{dmPolicy, allowFrom, groups}`) and path layout
  (`~/.<type>/channels/telegram/access.json`), so the fix is per-type path
  resolution rather than new logic. Affected commands:
  - `agent telegram-access get`/`set` — resolve the path by agent type via a
    new `_tg_access_state_dir` helper.
  - `agent pair` — code-roundtrip pairing now accepts codex/grok (path resolved
    as `~/.<type>/channels/<channel>/access.json`); openclaw/hermes stay
    token-only.
  - `agent telegram-pending-ignore` and `agent telegram-resolve-handle` — accept
    codex/grok instead of hard-failing "only applies to claude agents".
  - Inter-agent group mirror (`mirror_interagent_outbound`) resolves the sending
    agent's access.json by type, so codex/grok agents mirror to the group too.
  Previously all of these hard-failed for non-claude agents, forcing manual
  access.json edits to manage codex/grok bot allowlists.

## [0.1.21] — 2026-05-29

### Changed
- heartbeat: the wake nudge now issues a Claude Code `/goal` scoped to one
  concrete task id (the agent's highest-priority todo) instead of freeform
  prose. The agent loops turns until that task shows `done`/`cancelled` on the
  board, so it can no longer "do the work but forget to update status" and get
  re-nudged into the same task every tick.

### Added
- heartbeat: deterministic stale-`in_progress` reaper. Every tick (not gated by
  `everyMin`), any task left `in_progress` longer than `everyMin * 3` minutes
  (floored at 45m) is force-closed — `/goal clear` to stop a runaway loop, then
  auto-`cancel` with a result noting the timeout. This is the real hard cap:
  `/goal`'s own "stop after N turns" is model-judged and was observed to
  overrun, so cron enforces termination. No schema change (uses `started_at`).

### Note
- Rolls up the previously-unreleased 0.1.20 work (grok `~/.local/bin/grok`
  symlink fix) and the `agent list` heartbeat-cadence display.

## [0.1.15] — 2026-05-28

### Fixed

- antigravity agents now get the same `find-skills` + `5dive-cli` default
  skill inheritance every other type gets. Previously preseed only ran for
  `claude`, and the channel-installer seed steps (which cover codex/grok)
  don't route antigravity at all, so antigravity agents booted with an
  empty skills dir.
- `SKILLS_INSTALL_DIR[antigravity]` corrected from `.gemini/antigravity-cli/skills`
  (a guess based on agy's state dir layout) to `.agents/skills` (verified by
  grepping the `agy` binary for `{workspace}/.agents/skills/{skill_name}/SKILL.md`).
  The upstream `npx skills add --agent antigravity` fallback path already
  matched this — header comment was the only thing out of sync.

New `preseed_antigravity_agent` in `agent_setup.sh`, dispatched alongside
`preseed_claude_agent` in `cmd_create`.

## [0.1.14] — 2026-05-28

### Fixed

- `install_channel_for_codex_agent` now seeds `notify-user/SKILL.md` into
  `~/.agents/skills/notify-user/` and installs `find-skills` + `5dive-cli`
  via `npx skills add --agent codex`. Mirrors the grok 0.1.13 block — same
  class of bug (telegram-channel agent boots with no comms-loop skill,
  goes silent on first DM). Surfaced when `draft-codex` had an empty
  `.agents/skills/` despite being a codex+telegram agent. Unlike grok,
  codex is in the upstream `npx skills` registry, so the default skills
  go through the normal path rather than the manual-install fallback.

## [0.1.13] — 2026-05-28

### Fixed

- Three `grok` provisioning gaps surfaced by a live smoke test:
  - `5dive-agent-start` now seeds `/home/agent-<name>/.grok/auth.json` from
    `/home/claude/.grok/auth.json` (or `$PROFILE_STATE_DIR/.grok/auth.json`
    under a bound profile) at every boot. Previously the auth-gate in
    `cmd_create` passed because the type-level shared credential satisfied
    it, but the agent's own `~/.grok/auth.json` was never populated — so
    grok couldn't actually talk to xAI on first launch. Mirrors the codex
    seed block; mtime-gated so host-side `5dive auth login grok`
    re-rotations propagate on the next agent restart.
  - `install_channel_for_grok_agent` now copies `notify-user/SKILL.md` into
    `~/.grok/skills/notify-user/` for `--channels=telegram` agents, so the
    comms loop self-starts on the first DM (no manual nudge needed).
    Mirrors the claude-side seed in `preseed_claude_agent`.
  - Default skills `find-skills` + `5dive-cli` now install for grok agents
    too. Upstream `npx skills add` rejects `--agent grok` with "Invalid
    agents: grok", so a new manual-install fallback (`git clone --depth=1`
    + `cp -r`) in `install_default_skill_for_agent` and `cmd_skill_add`
    handles types upstream doesn't recognize. `_skill_needs_manual_install`
    is the single switch — add new types there when upstream rejects them.

## [0.1.12] — 2026-05-28

### Fixed

- `agent create codex` (and `agent install codex`) on hosts where a stray
  `codex` binary lives outside `/home/claude/.nvm/versions/node/v24/bin/`
  (e.g. `/usr/bin/codex` from apt, or under a non-v24 nvm major after
  `nvm install N` drifted the default alias). The previous recipe
  short-circuited on `command -v codex`, so npm install never ran and
  `cmd_install` then reported "install reported success but bin missing".
  Recipe now checks the exact `TYPE_BIN[codex]` path and forces
  `nvm use 24` before `npm install -g @openai/codex` so the bin always
  lands where downstream services expect it.

## [0.1.11] — 2026-05-28

### Added

- `grok --channels=telegram`. New `install_channel_for_grok_agent` writes
  the bot token + access.json into `~/.grok/channels/telegram/`, and
  `5dive-agent-start` now wires the telegram-grok MCP server +
  Stop/PreToolUse/Notification hooks into `~/.grok/config.toml` (absolute
  paths — `${GROK_PLUGIN_ROOT}` isn't documented for MCP command/args in
  grok 0.1.x, so we expand at boot). Mirrors the codex provisioning
  pattern (0.1.8) end-to-end. The launcher's existing `--always-approve`
  flag auto-trusts MCP/hook commands, so no separate trust-bypass step is
  needed.
- `install.sh` stages the telegram-grok plugin into
  `/usr/local/lib/5dive/telegram-grok` for customer VMs (same shape as
  the codex staging shipped in 0.1.9 — `5dive-agent-start`'s plugin
  resolver checks that path first).

## [0.1.10] — 2026-05-28

### Fixed

- `5dive-agent-start` now launches `grok` with `--always-approve` so tool
  executions (web fetch, shell, etc.) auto-approve instead of parking the
  agent on an interactive permission dialog. Without it, a single
  `reuters.com` fetch could stall a grok agent for 30+ minutes, blocking
  all inter-agent traffic until a human toggled yolo mode in the TUI.

## [0.1.9] — 2026-05-27

### Added

- `install.sh` now stages the **telegram-codex plugin** into
  `/usr/local/lib/5dive/telegram-codex` — a whole-subdir tarball from
  `5dive-com/5dive-plugins` plus `bun install --production` of its runtime deps
  (grammy). This is what makes codex `--channels=telegram` (shipped in 0.1.8)
  work on customer VMs and not just hosts with a `5dive-plugins` checkout:
  codex has no plugin marketplace, so its MCP server + lifecycle hooks run from
  this one shared copy, and `5dive-agent-start` already resolves
  `/usr/local/lib/5dive/telegram-codex` ahead of the dev checkout. `server.ts`
  resolves each agent's own state dir from `$HOME`, so a single staged copy
  serves every codex agent. Staging lives in `refresh_managed_files`, so the
  daily `update.sh` → `install.sh --upgrade` cron stages/refreshes it on
  existing VMs too (no separate update.sh change needed). Override the source
  with `CODEX_PLUGIN_TARBALL`; fail-soft (warns, doesn't abort the install) if
  the fetch or `bun install` fails.

## [0.1.8] — 2026-05-27

### Added

- **codex agents now support `--channels=telegram`.** `5dive agent create
  --type=codex --channels=telegram --telegram-token=…
  [--telegram-allowed-users=…]` wires the full telegram-codex bridge the same
  one-flag way claude does: it writes the bot token to
  `~/.codex/channels/telegram/.env`, seeds `access.json` from the allowlist,
  and at first boot appends the `[mcp_servers.telegram]` block plus the
  `Stop` / `PreToolUse` / `Notification` / `PermissionRequest` lifecycle hooks
  to the agent's `config.toml`. codex's first-run "Hooks need review" TUI
  prompt is auto-accepted once on first boot — codex then persists the trust to
  `[hooks.state]` so restarts never re-prompt. (codex's
  `--dangerously-bypass-hook-trust` flag only suppresses the gate for
  non-interactive `codex exec`, not the TUI, so it isn't used.) The plugin is a
  single shared checkout — resolved from `$TELEGRAM_CODEX_PLUGIN_DIR`,
  `/usr/local/lib/5dive/telegram-codex`, or the `5dive-plugins` checkout, in
  that order — and `server.ts` resolves each agent's own state dir from `$HOME`,
  so one copy serves every codex agent. telegram only; no discord build for
  codex yet. Note: customer VMs need the telegram-codex plugin deployed to
  `/usr/local/lib/5dive/telegram-codex` (install.sh staging is a follow-up); on
  the control-plane host the `5dive-plugins` checkout satisfies the resolver.

### Added

- `install.sh` now stages the **5dive-cli skill** under
  `/usr/local/lib/5dive/skills/5dive-cli/` (whole-directory: `SKILL.md` plus
  `references/`). Pulled via tarball from `5dive-com/skills`, mirroring how
  notify-user is staged. Pairs with the 5dive-api update.sh change that
  refreshes every agent's installed copy from this stage on the daily 03:00
  cron — so docs improvements (e.g. the new `task`/`org` reference sections)
  reach existing agents instead of being frozen at agent-create time.

### Fixed

- `5dive-agent-start` now dispatches `grok` and `antigravity`, fixing a
  crash-loop regression (`unknown AGENT_TYPE: grok|antigravity`). Both types
  were already first-class everywhere else in the CLI (`TYPE_BIN`, installer,
  auth, `agent create`), but the systemd launcher's case statement never got
  the matching branches — so `agent create --type=grok` succeeded, then the
  unit exited 2 on every spawn, racking up thousands of restarts. The
  per-type credential scrub also covers them now (same posture as
  hermes/openclaw — OAuth-via-file, no provider env vars).

### Added

- Inter-agent mirror can post into a forum topic: when the group entry in
  `access.json` carries a `message_thread_id`, mirrored `agent send`/`ask`
  traffic lands in that thread (e.g. a dedicated "#5dive" topic) instead of
  the supergroup's General channel.

### Fixed

- Inter-agent mirror now survives a group→supergroup migration. Upgrading a
  paired group to a supergroup (also how it gains forum topics) changes its
  chat id, and Telegram rejects sends to the old id with
  `migrate_to_chat_id`. The mirror now follows that, rewrites the stored group
  id in `access.json` (preserving owner/mode + the thread id), and retries —
  instead of silently posting nothing.

## [0.1.7] — 2026-05-27

### Added

- `5dive task` — a host-shared, sqlite-backed task queue any agent can use
  without sudo (store at `/var/lib/5dive/tasks/tasks.db`, in a group-writable
  `2770` subdir so writes need no root, unlike the root-only registry).
  Subcommands add/ls/show/assign/start/done/cancel/block/unblock/rm, with
  DIVE-N identifiers, subtasks (`--parent`), blocks-edges, a priority-ordered
  board view, and `--json` on every subcommand.
- `5dive org` — agent org chart over the same store: set/tree/show/ls/rm,
  with a `reports_to` subordination edge, reporting-cycle prevention, and a
  recursive-CTE tree view.
- `install.sh` + `5dive doctor` now install / verify `sqlite3`, required by
  the new task + org store.
- `install.sh` now installs the `5dive-hermes-perms.{path,service}` systemd
  units alongside the agent template. Hermes regresses
  `/home/claude/.hermes` to 0700 on every auth.json/config.yaml write,
  blocking `agent-<name>` users (in the `claude` group) from traversing
  to `venv/bin/hermes`. The path-unit watches the dir and the oneshot
  chmods it back to 0775. These units used to live only in the
  5dive-managed-cloud installer; moving them into OSS removes the last
  drift point between the customer-VM provisioner and the OSS source.
- `install.sh` now also pre-creates `/var/lib/5dive/agents.json` at mode
  640 root:claude (was lazy-created on first `5dive agent create`) and
  sets setgid 2750 on the state dirs so any file the root-only CLI
  writes inherits the `claude` group, letting `agent-<name>` users read
  their own per-agent env files.
- `5dive doctor` gained a `channels` category that verifies
  `/etc/claude-code/managed-settings.json` carries `channelsEnabled: true`
  + a `telegram@5dive-plugins` entry, and reads each agent's latest
  telegram-plugin MCP log to confirm whether claude's channel
  subscription is `registered` vs `skipped`. A `skipped` result is
  flagged as a likely Anthropic Teams org override and points the
  operator at the README setup snippet.
- `5dive init` prints a Teams-org heads-up after the Telegram pairing
  step pointing at `sudo 5dive doctor --category=channels` and the
  Anthropic Console setup snippet.

### Fixed

- `5dive-agent-start` no longer rewrites a codex agent's `config.toml` on
  every start. The required keys (approval policy, sandbox mode, project
  trust) are now written only when the file is missing, so `[mcp_servers.*]`
  entries added via `codex mcp add` survive agent restarts.

## [0.1.6] — 2026-05-25

### Changed

- `preseed_claude_agent` no longer wires the standalone StopFailure hook
  (`/usr/local/lib/5dive/stop-failure-telegram.sh`) into new fork
  (`telegram@5dive-plugins`) agents' `settings.json`. Plugin v0.4.4
  bundles the same hook via `hooks.json`, so preseeding the standalone
  copy would double-fire on every rate-limit (two DMs, two
  `resume-after-reset.sh` forks both pressing "1" on claude's
  Stop-and-wait menu). The standalone file stays installed by
  `scripts/install/agent-cli.sh` + `scripts/update.sh` for backward
  compatibility — agents on upstream `telegram@claude-plugins-official`
  still reference it. New upstream agents are unaffected by this
  change (channels=telegram defaults to the fork anyway since v0.1.5).

### Notes

- Companion change in `5dive-api/scripts/update.sh` strips the
  standalone StopFailure entry from existing fork agents' settings.json
  on the next 03:00 UTC customer-VM update cron — same shape as the
  existing `on_upstream_telegram()`-gated backfills, just inverted.

### Changed

- New `telegram` agents now preseed on the `telegram@5dive-plugins` fork
  instead of upstream `claude-plugins-official`. The fork bundles
  PreToolUse / Stop / PostToolUse hooks via `hooks.json` and ships
  richer slash commands (`/model`, `/effort`, `/agents`, `/status`,
  silence-watchdog). `agent_setup.sh` preseeds
  `enabledPlugins → telegram@5dive-plugins`, adds the fork repo to
  `extraKnownMarketplaces` alongside upstream, drops the duplicate
  hook entries (plugin owns them now), and writes
  `AGENT_CHANNEL_MARKETPLACE=5dive-plugins` into the agent env file so
  `5dive-agent-start` builds the right `--channels` arg.
  `install.sh` now also writes `/etc/claude-code/managed-settings.json`
  on first install so the channel-plugin allowlist permits both
  marketplaces (idempotent — preserves an operator-customized file).
  Existing telegram agents are unaffected; they stay on upstream until
  a 5dive-api `update.sh` pass migrates them.

### Fixed

- `stop-failure-telegram` now parses the rate-limit reset time from
  the StopFailure transcript instead of scraping the tmux pane.
  When claude shows the "Stop and wait" menu the pane switches to
  the alt screen and the "resets Xpm (TZ)" line is no longer visible
  to `tmux capture-pane`, so the fallback DM "Usage limit hit —
  waiting for reset." fired without the time-left tail and the
  resume-after-reset helper got no epoch. Transcript parse reads the
  structured rate-limit message claude logs
  (`isApiErrorMessage=true`, text containing "resets Xpm (TZ)") —
  authoritative and immune to tmux screen state. Pane scrape kept as
  last resort. Supersedes the 0.5s pre-capture sleep workaround.
- Plugin install pins the explicit `https://` URL for the marketplace
  `add` step. `claude plugin marketplace add owner/repo` resolves the
  GitHub shorthand to `git@github.com:owner/repo` (SSH) on some
  claude versions, which fails for `agent-<name>` users on customer
  VMs with no SSH key (`ERR_STREAM_PREMATURE_CLOSE` during clone).
  Affects both the new-agent install path and `update.sh` migration.

## [0.1.4] — 2026-05-23

### Fixed

- `antigravity` auth sentinel path. The scaffold's first ship guessed
  `~/.gemini/antigravity-cli/credentials.json` but agy 1.0.1 actually
  writes the token blob at `~/.gemini/antigravity-cli/antigravity-oauth-token`
  (no `.json` extension). The cmd_auth_poll mtime-check never noticed the
  successful OAuth landing and reported `error: antigravity exited without
  writing ...`. Confirmed empirically via the live-VM pair-test. Patches
  TYPE_AUTH + profile_type_auth_path + the comment block in cmd_auth_poll.
- Usage-limit Telegram pings narrowed to the calling chat. When an agent
  is paired with multiple chats (personal DM + team group), hitting the
  Claude usage limit was fanning the "Usage limit hit — resumes in …"
  alert (and its later "agent resumed" follow-up) to every chat in
  `access.json`. `stop-failure-telegram.sh` now scans the StopFailure
  payload's transcript for the most-recent telegram inbound and pings
  only that chat — same idiom `stop-telegram-reply-check.sh` already
  uses. Falls back to the full access.json list when no inbound is
  found (autonomous/cron-triggered sessions) so the alert isn't
  silenced.

### Added

- `grok` agent type. xAI's CLI. Binary lands at `~/.local/bin/grok`
  (symlinked from `~/.grok/bin/grok`); state under `~/.grok/`. OAuth uses
  the xAI device-auth flow (`grok login --device-auth` → URL
  `accounts.x.ai/oauth2/device` + a 4-dash-4 user code like `XJ9P-ZW8T`;
  CLI polls the endpoint itself and writes `~/.grok/auth.json`). Same UX
  shape as codex's device-auth — no callback paste. Also supports BYO API
  key via `XAI_API_KEY`. Run flag: `--permission-mode bypassPermissions`.
  Installer drops a competing `agent` symlink alongside `grok`; the
  TYPE_INSTALL recipe removes it post-install so future tooling isn't
  shadowed.

- `antigravity` agent type. Google's native-Go successor to gemini-cli.
  Installer lands `agy` at `~/.local/bin/agy` (no Node/nvm dependency).
  Run flag: `--dangerously-skip-permissions` (mirrors the claude family
  default). OAuth uses Google's consumer flow with redirect to
  `antigravity.google/oauth-callback` — UX is identical to the deleted
  gemini flow (URL displayed, waits 30s for either an OAuth callback OR
  a pasted authorization code). Wired into the device-code flow alongside
  claude/codex/hermes/openclaw. State dir is `~/.gemini/antigravity-cli/`
  — the binary identifies as `product=antigravity` but reuses Google's
  `~/.gemini` parent directory.

### Removed

- `gemini` agent type. Google's Gemini CLI is being sunsetted by Google in
  favor of Antigravity. Drops the `[gemini]` entries from all `TYPE_*` and
  `SKILLS_*` lookup tables, the `gemini` branch in the init wizard,
  `extract_gemini_url`, the gemini paperclip-seed case, the
  `GEMINI_SANDBOX` / `GEMINI_CLI_TRUST_WORKSPACE` overrides in the
  paperclipai drop-in, and the `gemini.env` connector path. Hermes /
  openclaw routing to Google's Gemini-2.0-flash model via a BYO API key
  is unchanged — that's a model id in Google's provider catalog, not a
  5dive agent type.

## [0.1.3] — 2026-05-22

### Changed

- Inter-agent group mirror moved to the sender side. `5dive agent send`
  (and `agent ask`) now posts `@<receiver>\n<body>` to the **sender's**
  group via the **sender's** bot, so both halves of an exchange show up
  under the correct identity. The previous receiver-side hooks
  (`userprompt-mirror-inter-agent.sh`, `stop-mirror-inter-agent.sh`) are
  retired as no-ops — they posted via the receiver's bot, so
  `marketing → main` showed up under `main`'s identity, and the reply
  hook double-posted (once as the payload, once as transcript
  narration). Files stay on disk so existing agents' `settings.json`
  don't error; new agents wire only the sender-side path.
- `stop-telegram-reply-check.sh` now decides at the **turn level**, not
  per text block. If the agent called `reply` or `edit_message` anywhere
  in the turn, all auto-relay is suppressed — every loose transcript
  block (preamble, progress, end-of-turn summary) is narration, not a
  missed answer. Eliminates the trailing `(auto-relay) ...` duplicates
  that landed in the user's DM right after the real reply.
- StopFailure Telegram alerts include the upstream API error string
  (e.g. "API Error: 529 Overloaded") pulled from the claude pane
  capture, instead of just naming the high-level `server_error` reason.
- Per-agent Telegram guidance moved out of the shared
  `projects-CLAUDE.md`. Telegram-paired claude agents now get a
  dedicated `telegram-agent-CLAUDE.md` dropped at
  `$HOME/.claude/CLAUDE.md` during agent setup, alongside the
  `notify-user` skill. Non-Telegram agents (codex on single-agent hosts,
  for instance) no longer carry the reply mandate or the bot
  references that didn't apply to them. `projects-CLAUDE.md` is trimmed
  to host-wide invariants only.
- Both `projects-CLAUDE.md` and `telegram-agent-CLAUDE.md` tightened —
  smaller token footprint on every agent's session prompt.

### Removed

- `posttool-telegram-relay.sh` retired as a no-op. The mid-turn relay's
  premise (loose mid-turn text = message the user should see) was
  wrong; preambles and progress narration are transcript text too and
  were getting curled to the user as noise. The legitimate "talked to
  the transcript instead of replying" miss is now caught by the
  turn-level Stop hook above.
- `SECURITY.md` removed. Security-reporting instructions inlined into
  the README, with `CONTRIBUTING.md` pointing at GitHub's private
  advisory page directly. Removes the "Security" community pill so the
  README/Contributing/License row stops overflowing on mobile.

### Fixed

- `install-smoke` CI workflow now ships `telegram-agent-CLAUDE.md` in
  the bundle. Without this, `install.sh`'s new curl for that file hit
  a missing source and bailed (curl exit 37).

### Documentation

- README: "How it works" clarifies that agents share CLI binaries and
  subscriptions, with a diagram showing two claude agents alongside one
  codex.
- `hooks/README.md` surfaces the three Telegram-plugin deadlocks in
  the table.
- README prose stripped of em-dashes (kept in the agent-type table
  where they mark n/a entries).

## [0.1.2] — 2026-05-20

### Added

- `5dive init` first-run wizard now includes a Telegram channel picker
  with auto-discovery — the wizard probes the bot's recent updates and
  offers detected chats as one-tap choices instead of asking the user
  to paste a chat id.
- `5dive agent send` / `5dive agent ask` accept `--reply-to-chat` and
  `--reply-to-msg`, so an agent can thread its inter-agent message into
  a specific Telegram conversation rather than picking the first paired
  chat blindly.
- `5dive telegram-pending-ignore` and `5dive telegram-resolve-handle` —
  CLI shortcuts the dashboard and the channel pairing flow lean on.
  `resolve-handle` accepts numeric chat ids and group titles in
  addition to `@usernames`.
- Default-on UI install: the local web dashboard install path is gone
  from OSS (see "Changed" below), but the underlying `--no-ui` flag was
  flipped to default-on for the install bits that remain.
- Ship `projects-CLAUDE.md`: `install.sh` drops a slim project-level
  `CLAUDE.md` at `/home/claude/projects/CLAUDE.md` (only if absent),
  symlinked as `AGENTS.md`. Gives every newly-spawned agent baseline
  guidance for switching its own model/effort, the Telegram reply
  mandate for paired agents, and the inter-agent messaging primitives.
- `hooks/README.md` documents the four (now six, after this release's
  inter-agent mirror split) hook scripts and their failure modes.
- README badges for CI status, latest release, and license.
- README — split the "have your agent install it" section into a
  same-machine prompt and a laptop-agent-installs-onto-remote-VM
  prompt; both end with the agent installing the `5dive-cli` skill
  so the user can keep managing 5dive through the same agent.
- README — `codex → hermes` image-to-animation example.
- README OG social-preview image.

### Changed

- Repo renamed `5dive-com/5dive-cli` → `5dive-com/5dive`. The
  short-url installer (`curl install.5dive.com | sudo bash`) keeps
  working unchanged; only direct `raw.githubusercontent.com` URLs in
  third-party docs need updating.
- Local web dashboard removed from OSS. The managed dashboard at
  5dive.com continues to ship for cloud customers; self-hosted users
  drive 5dive entirely from the CLI. Dropping the bundled Next.js app
  cuts the install footprint and removes a long tail of port-conflict
  / reverse-proxy questions.
- `install.sh --upgrade --no-ui` tolerated as a deprecated no-op (was
  previously rejected after the dashboard removal made the flag
  meaningless).
- README rewrite: tighter Quickstart, "Why 5dive" reframed around the
  three isolation tiers (Docker / systemd-user / dedicated-VM), "How
  it works" promoted above the fold, hero demo served via GitHub
  assets / jsDelivr so the inline `<video>` gets the right mp4 mime.

### Fixed

- `5dive auth login claude` now captures the token from
  `claude setup-token`'s TTY login flow (the upstream CLI started
  printing to its own /dev/tty, bypassing the redirected stdout we
  were grepping). Caught by `pair-test` against a fresh Hetzner box.
- UI new-agent flow: full OAuth state machine + Discord token handling
  + error recovery. The previous version assumed every OAuth attempt
  succeeded on the first poll and got stuck on the loading spinner
  when the upstream URL took two ticks to land.
- `init` ASCII logo spelled out 5DIVE properly; opencode reframed as
  BYO-provider (it ships with free models but the wizard implied you
  had to sign in).
- `src/header.sh` prepends `/usr/sbin` to PATH so `adduser`,
  `usermod`, `userdel` always resolve — first-agent-create was failing
  inside systemd-spawned shells where /usr/sbin wasn't on PATH.
- Hooks reliability pass surfaced by live use:
  - `stop-telegram-reply-check.sh` catches trailing assistant text
    that lands after a successful telegram tool call (the agent
    sometimes appends a sign-off the user never sees).
  - Inter-agent mirror split: the old sender-side `PreToolUse` mirror
    couldn't see heredoc-built command bodies. Replaced with a
    receiver-side `UserPromptSubmit` hook
    (`userprompt-mirror-inter-agent.sh`) plus a `Stop` reply mirror
    (`stop-mirror-inter-agent.sh`).
  - Rate-limit-resume text unified between the immediate ping and the
    detached `resume-after-reset.sh`; the auto-press-1 helper moved
    into the detached helper so it survives session teardown.
  - `pretool-telegram-question.sh` typographic-quote bug fixed (the
    template literal was getting smart-quoted somewhere in the
    pipeline and the deny message rendered with U+201C/U+201D).
  - Three follow-up fixes against the inter-agent mirror after first
    live use against `agent-marketing`.

[Unreleased]: https://github.com/5dive-ai/5dive/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/5dive-ai/5dive/releases/tag/v0.1.2

## [0.1.1] — 2026-05-16

### Fixed

- `install.sh` now installs `unzip`. The bun installer (`curl … | bash`)
  requires it, and on a clean ubuntu:22.04 it isn't preinstalled — the
  one-liner install was failing silently mid-script. Caught by the new
  install-smoke CI job on its first run.

### Added

- README — copy-paste prompt block for users who'd rather have their
  existing AI agent run the install (instead of pasting the curl line
  themselves).

## [0.1.0] — 2026-05-16

First public release.

### CLI

- `5dive agent` — create, list, send to, ask, watch, stop, delete agents.
- `5dive auth` — set / login / status / clear, with profile sharing across
  agents via `5dive account`.
- `5dive skill` — install + remove agent skills (incl. the bundled
  `notify-user` skill).
- `5dive compose` — declare an agent team in a YAML file and stand it up.
- `5dive doctor` — health check across systemd units, agent state, and
  per-type install status.
- `5dive init` — interactive first-run wizard for picking agent types,
  channels, and registering an initial agent.
- `5dive watch` — follow agent activity in the terminal.
- `5dive uninstall` (and `install.sh --uninstall`) — clean removal.
- `5dive --version` / `-v` sourced from a single `FIVE_VERSION` constant.
- Agent-to-agent messaging: every agent can `send` / `ask` any other agent
  on the same host.

### Installer

- One-liner installer (`curl install.5dive.com | sudo bash`).
- Sets up nvm + Node for the agent runtimes that need it.
- Idempotent: re-running won't touch your registry, auth profiles, or
  agents.
- `install.sh --upgrade` — refresh CLI binaries, systemd unit, and hooks
  only (skips apt/nvm).
- Runs `5dive doctor` automatically after install.

### Telegram

- Stop hook auto-relays missed replies for telegram-paired agents.
- `notify-user` skill for sending progress updates from agents.

### Docker

- Demo container under `docker/` for tire-kickers — runs without needing
  systemd or root on the host.

### Docs

- README — quickstart, auth model, agent-to-agent example, securing-your-server,
  telemetry policy, reverse-proxy recipe.
- Offline / air-gapped install recipe.
- Pointer for non-systemd / non-root users at the Docker path.
- SECURITY.md — private vulnerability reporting via GitHub advisories.
- CONTRIBUTING.md — dev setup, scope guardrails, bundle rule, PR expectations.
- Issue + PR templates.

### CI

- `bundle-drift` workflow — fails any push where the committed `5dive`
  bundle disagrees with `./build.sh` output from `src/`.

[0.1.1]: https://github.com/5dive-ai/5dive/releases/tag/v0.1.1
[0.1.0]: https://github.com/5dive-ai/5dive/releases/tag/v0.1.0
