# Changelog

All notable changes to `5dive` are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/spec/v2.0.0.html).

Unreleased changes accumulate at the top until they're cut into a tagged
release.

## [Unreleased]

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

[Unreleased]: https://github.com/5dive-com/5dive/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/5dive-com/5dive/releases/tag/v0.1.2

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

[0.1.1]: https://github.com/5dive-com/5dive/releases/tag/v0.1.1
[0.1.0]: https://github.com/5dive-com/5dive/releases/tag/v0.1.0
