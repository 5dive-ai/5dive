
# -------- 5dive supervisor — fleet health brain (DIVE-724, P1: observe-only) --------
#
# The unifying layer ON TOP of heartbeat/rotation/auto-resume/loops (design:
# docs/fleet-supervisor-design.md). Per agent it runs DETECT -> CLASSIFY and
# surfaces the result on a board; the cron-callable `--tick` additionally
# APPENDS to the supervisor_events audit table. P1 took ZERO recovery
# actions — no restarts, no nudges, no mutations beyond that audit table —
# so the stuck/slow classifier could be validated against real fleet behavior
# with no risk before P2 turned the recovery ladder on. P2's ladder is
# nudge -> resume -> rotate -> restart (rung 4, poller-dead only, rate-limited:
# DIVE-3753; the rate limit counts restarts that did NOT heal the poller, plus a
# separate flap bound on all of them, DIVE-3915), all of it gated on
# $_SUP_ACTIONS_FLAG.
#
# Signals (all read-only; cheap ones implemented, flaky ones stubbed):
#   service   systemctl is-active on 5dive-agent@<name> (claude-session.service
#             for the box's main `claude` user, when that unit is meant to run)
#   tmux      tmux has-session -t agent-<name>, as the agent's own user
#   poller    telegram bridge process alive, per-type (DIVE-971): claude runs
#             the forked plugin as a bun proc carrying …/5dive-plugins/telegram;
#             codex/grok/antigravity run the telegram-<type> MCP server (bun
#             <dir>/server.ts); opencode's telegram-opencode relay IS its main
#             proc. One pgrep pattern per type (_SUP_POLLER_PAT) — telegram
#             channel only; other channels/types stay "n/a".
#   activity  newest session-transcript mtime, per-type (DIVE-971). Every
#             assistant turn appends to the runtime's transcript, so its mtime
#             IS the last-token-progress timestamp — cheaper and wider-coverage
#             than loop_runs.updated_at (loop work only) and far less flaky than
#             pane-scraping. Per-type roots+globs in _sup_activity_epoch:
#             claude ~/.claude/projects/*.jsonl, codex ~/.codex/sessions/
#             rollout-*.jsonl, grok ~/.grok/sessions, opencode
#             ~/.local/share/opencode/storage, antigravity
#             ~/.gemini/antigravity-cli/brain/**/transcript*.jsonl. A missing/
#             empty root => age unknown => never stuck (false-negative bias).
#   goalDrift claude-only (DIVE-971): an active /goal targets a specific DIVE
#             task that is still untouched (status=todo) while the agent is
#             actively progressing on something else. Structural, not semantic
#             — no relevance heuristic. Observe-only: never feeds the act ladder.
#   activeWork in_progress tasks assigned to the agent + its running loops
#   cliStale  one `update --check`-shaped probe per pass (box-level, best-effort)

# Conservative classification knobs (design §4). Bias FALSE-NEGATIVE: missing a
# stuck agent is better than flagging a healthy one, because the P2 ladder's
# restart is disruptive. Env-overridable so the P1 instrumentation phase can
# tune thresholds per box without a release (the _HB_* heartbeat constants are
# the sibling pattern; these add the env escape hatch because tuning IS the
# point of P1). Non-numeric overrides fall back to the defaults.
_SUP_T_STUCK_MIN="${SUPERVISOR_T_STUCK_MIN:-30}"   # active work + no progress this long -> stuck/no-progress
_SUP_T_SLOW_MIN="${SUPERVISOR_T_SLOW_MIN:-10}"     # active work + no progress this long -> slow (record only)
[[ "$_SUP_T_STUCK_MIN" =~ ^[0-9]+$ ]] || _SUP_T_STUCK_MIN=30
[[ "$_SUP_T_SLOW_MIN"  =~ ^[0-9]+$ ]] || _SUP_T_SLOW_MIN=10
# DIVE-1416 (gap#3): an agent with NO active work (no in_progress, no running
# loop) but an old todo task still assigned to it — heartbeat should have woken
# it by now (enrolled or not) — used to read as plain "healthy (idle)". This
# window is how old a todo has to be before that idleness counts as a distinct
# unhealthy signal instead. Same env-override escape hatch as the siblings above.
_SUP_T_STRANDED_MIN="${SUPERVISOR_T_STRANDED_MIN:-45}"
[[ "$_SUP_T_STRANDED_MIN" =~ ^[0-9]+$ ]] || _SUP_T_STRANDED_MIN=45
# DIVE-3272: every signal above measures LIVENESS — is the unit up, is the tmux
# session there, is the poller running, is a transcript still being appended to.
# NONE of them measures OUTPUT. dev3 sat on an expired Qwen 1-week quota for four
# days: the unit was active, tmux was alive, the transcript moved on every wake,
# and the seat KEPT CLAIMING ROWS — so it read `healthy / active` throughout while
# 20 rows, including a whole urgent lane, queued behind it. It was found only
# because a human eyeballed queue depth. A seat that claims work and completes
# none is indistinguishable from a seat that is working; this is the knob that
# tells them apart. Days, not minutes: the longest legitimate drought (one seat
# grinding a single hard multi-day row) must clear it, so the bias stays
# FALSE-NEGATIVE like every other threshold in this file.
_SUP_T_NO_OUTPUT_DAYS="${SUPERVISOR_T_NO_OUTPUT_DAYS:-3}"
[[ "$_SUP_T_NO_OUTPUT_DAYS" =~ ^[0-9]+$ ]] || _SUP_T_NO_OUTPUT_DAYS=3
# DIVE-4666 it.2: the drought's SECOND term. The days-since-close number above
# is measured against the seat's CLOSE history and nothing else, so at 07:40Z on
# 2026-09-20 `codex` — which had been correctly idle with no open rows until
# 07:31Z, was assigned DIVE-4665 at 07:31Z, STARTED it at 07:34Z and had it at a
# gate by 07:40Z — was paged as "not transacting: 1 open row(s), nothing closed
# in 3d". Every word of that was true and the conclusion was wrong: a seat is
# only dark if its OPEN work is also standing still. This window is how long the
# newest touch on the open queue has to be stale before a close drought counts
# as darkness. A day, because the close threshold is three and the two must not
# be the same number — the row's own arms are "picked up 5 minutes ago -> quiet"
# and "sat 2 days with no start since -> page", and anything from ~1h to ~2d
# separates them. Same env escape hatch as its siblings.
_SUP_T_NO_OUTPUT_IDLE_MIN="${SUPERVISOR_T_NO_OUTPUT_IDLE_MIN:-1440}"
[[ "$_SUP_T_NO_OUTPUT_IDLE_MIN" =~ ^[0-9]+$ ]] || _SUP_T_NO_OUTPUT_IDLE_MIN=1440
# DIVE-3272: a model-capacity error in a seat's pane is a FLEET-health event, not
# that seat's private problem — the cost is borne by every row queued behind it.
# Nothing scraped for one before this. Pane-scoped for the same reason the
# DIVE-1127 verify tripwire is: it is a harness-rendered error on the current
# screen, not something the transcript records. Same false-positive exposure too
# — an agent DISCUSSING a 429 (this very task's body quotes one) can trip it — so
# the alert names the matched line and the recipient can dismiss it in one look.
# Env-overridable so a new provider's phrasing is tunable without a release.
_SUP_QUOTA_PANE_LINES="${SUPERVISOR_QUOTA_PANE_LINES:-40}"
[[ "$_SUP_QUOTA_PANE_LINES" =~ ^[0-9]+$ ]] || _SUP_QUOTA_PANE_LINES=40
_SUP_QUOTA_PAT="${SUPERVISOR_QUOTA_PAT:-}"
[[ -n "$_SUP_QUOTA_PAT" ]] || _SUP_QUOTA_PAT='(api[[:space:]]+error|request[[:space:]]+rejected)[^|]{0,60}429|quota[[:space:]]+(has[[:space:]]+been[[:space:]]+)?exhausted|exhausted[[:space:]]+your[[:space:]]+(token|weekly|monthly)|hit[[:space:]]+your[[:space:]]+([^[:space:]]+[[:space:]]+)?((monthly|weekly|daily)[[:space:]]+spend|session|usage|5[[:space:]-]?hour)[[:space:]]+limit|usage[[:space:]]+limit[[:space:]]+reached|insufficient_quota|credit[[:space:]]+balance[[:space:]]+is[[:space:]]+too[[:space:]]+low'
# DIVE-4401 widened the SAME arm again with one optional qualifier word between
# `your` and the window noun. A Claude Team seat prints the possessive form
#   `You've hit your org's monthly spend limit · ... · your session limit resets 9am (UTC)`
# and `org's` sits exactly where the alternation expected `monthly`, so the ONE
# line in the Team banner that carries the reset clock matched no arm at all
# (measured 2026-09-13 04:31Z on main + olivia). The optional group is a single
# non-space token, so it cannot bridge a clause; the arm still requires the
# window noun followed by the literal word `limit`.
#
# DIVE-4206 widened the `hit your ... limit` arm from the spend-only alternation
# to `session|usage|5-hour`. It was written when the walls in evidence all said
# "spend", and the banner both harnesses actually print today matches NONE of the
# old alternatives:
#   Claude Code  `You've hit your session limit · resets 4am (UTC)`
#   codex        `You've hit your usage limit`
# ("usage limit reached" is a different word ORDER and does not match either.) So
# a walled seat classified `healthy`, no quota-exhausted row was written, and
# DIVE-4104's park path -- which reads exactly that classification -- could not
# fire: the reclaimer took the claim off a seat that was frozen, not idle.
# Measured 2026-09-10 02:24-02:45Z: dev, dev3 and ops all on the session-limit
# banner, two claims reclaimed as "idle 44m"/"idle 24m" and one re-nudged into
# the same wall. Two-signature discipline is unaffected -- this is the HEADER
# alternation, and _hb_pane_is_usage_limit still demands an action line too.
_SUP_WEEKLY_QUOTA_PAT="${SUPERVISOR_WEEKLY_QUOTA_PAT:-}"
[[ -n "$_SUP_WEEKLY_QUOTA_PAT" ]] || _SUP_WEEKLY_QUOTA_PAT='(^|[[:space:]])(7d|1w):[[:space:]]*100%([^0-9]|$)'
#
# DIVE-4536: THE WEEKLY ARM MUST NOT MATCH THE STATUS BAR. Claude Code renders a
# two-window usage METER on the bottom line of every pane, at all times:
#
#     Opus 5 · 5h: 17%  7d: 100%
#
# `7d: 100%` sits inside it, so from the moment an account's weekly window
# filled, EVERY tick read that seat's idle pane as "a model-capacity refusal" —
# and DIVE-4097 door 2 then HELD the no-progress ladder behind it. Measured
# 2026-09-14: dev3 sat on a one-keystroke confirm for ~10h producing 60 HELD
# lines and zero nudges, while the meter it was held on had already fallen back
# to `7d: 71%` (the hold reads an UNKNOWN deadline as still-in-force, so nothing
# could expire it either). A hold that cannot expire is a stall with a green
# label.
#
# THE METER IS A GAUGE, NOT A REFUSAL. It is present whether or not the account
# can spend; it says what has been used, never that a request was denied. Only a
# refusal SENTENCE (_SUP_QUOTA_PAT: "usage limit reached", "You've hit your …
# limit", "credit balance is too low", a 429) is evidence that the seat tried and
# was told no.
#
# WHY THE WEEKLY ARM IS NOT SIMPLY DELETED: a weekly wall genuinely can be
# refusal-free in OTHER renderings, and this arm is the only pane reading of one.
# So the arm survives and the METER SHAPE is excluded from it — a line carrying
# BOTH windows (`5h: N%` and `7d: M%`) is the status bar and nothing else.
#
# AND THE COVER THIS GIVES UP IS ALREADY HELD BY A BETTER SIGNAL: DIVE-4342's
# account-usage snapshot reads the provider's own measured percentage and is
# ranked ABOVE this pane branch in _sup_classify. A real weekly wall is measured
# there, from the number, without scraping a gauge off a TUI. What falls through
# here is exactly the row's "at cap, unconfirmed" — no hold, no green word, the
# no-progress path free to do its job.
_SUP_USAGE_METER_PAT="${SUPERVISOR_USAGE_METER_PAT:-}"
[[ -n "$_SUP_USAGE_METER_PAT" ]] || _SUP_USAGE_METER_PAT='(^|[[:space:]])5h:[[:space:]]*[0-9]+%'

# _sup_line_is_usage_meter — rc 0 when this ONE line is Claude Code's two-window
# status meter. Both windows must be on it: the 5h reading is what separates the
# gauge from a weekly-wall sentence, which never carries a session percentage.
_sup_line_is_usage_meter() {  # <line>
  grep -qiE "$_SUP_USAGE_METER_PAT" <<<"$1" 2>/dev/null || return 1
  grep -qiE '(^|[[:space:]])(7d|1w):[[:space:]]*[0-9]+%' <<<"$1" 2>/dev/null
}

# _sup_line_is_refusal — the ONE predicate both the match and its neighbour-skip
# use, so the two can never disagree about what a refusal line is. A refusal
# sentence always counts; the weekly arm counts only when the line is not the
# status meter.
_sup_line_is_refusal() {  # <line>
  grep -qiE "${_SUP_QUOTA_PAT}" <<<"$1" 2>/dev/null && return 0
  _sup_line_is_usage_meter "$1" && return 1
  grep -qiE "${_SUP_WEEKLY_QUOTA_PAT}" <<<"$1" 2>/dev/null
}
# Ignore a missing poller right after a service start — the plugin's bun server
# takes a moment to boot, and a false poller-dead there would flag every
# freshly-restarted agent.
_SUP_POLLER_GRACE_SEC=120
# Ship-behind-a-flag (design §8): `--tick` no-ops with a notice unless this
# sentinel exists. Same file-sentinel pattern as gate-proof.enforce — root
# touches it to enable, removes it to disable; no registry churn.
_SUP_ENABLED_FLAG="${STATE_DIR}/supervisor.enabled"
# P2 (DIVE-857): actions have their OWN sentinel, separate from observe — ticks
# collect audit evidence while the ladder stays dormant. Absent flag => the
# tick records 'planned' rows (what WOULD have fired) instead of acting.
# lodar pre-cleared enabling (gate answered 2026-07-02) conditional on a clean
# zero-false-positive audit week; root touches this file on/after Jul 9.
_SUP_ACTIONS_FLAG="${STATE_DIR}/supervisor.actions.enabled"
# DIVE-4052: quota exhaustion is normal subscription-window behaviour, not a
# fleet incident. lodar, 2026-09-08: "it goes to your active session and burns
# your tokens ... more like an opt-in debug feature. our agents hit usage limits
# all the time - thats how our subscriptions work." So BOTH delivery legs — the
# a2a to main AND lodar's phone — sit behind this ONE sentinel, and the audited
# supervisor_events row is what stays unconditional: it is the record, and it
# costs no turn. Same file-sentinel shape as _SUP_ACTIONS_FLAG: root may touch
# this file to enable; absent is quiet. One flag and not two, because a machine
# ping nobody asked for is the same noise as a phone ping nobody asked for.
_SUP_QUOTA_ALERTS_FLAG="${STATE_DIR}/supervisor.quota-alerts.enabled"
# Ladder pacing (design §5): gap before the NEXT action on an agent is
# base * 2^attempts (20m/40m/80m against the 10m tick); past max attempts the
# supervisor stops acting and escalates once per window.
_SUP_ACT_BASE_MIN="${SUPERVISOR_ACT_BASE_MIN:-20}"
[[ "$_SUP_ACT_BASE_MIN" =~ ^[0-9]+$ ]] || _SUP_ACT_BASE_MIN=20
_SUP_ACT_WINDOW_H=6
_SUP_ACT_MAX_ATTEMPTS=3
# ── DIVE-3753: rung 4 — poller-dead RESTART, rate-limited ────────────────────
# THE WINDOW, WRITTEN DOWN: at most _SUP_RESTART_MAX restarts of one seat per
# _SUP_RESTART_WINDOW_H hours. Default 1 per 6h, keyed per seat, counted off the
# same audit trail as every other rung (no extra state file).
#
# Why 1 and not 3: the remedy is measured at NINE SECONDS
# (community/wiki/no-beacon-has-three-states-and-only-the-process-table-separates-them.md
# — two seats, launcher=0 server=0 before, 1/1 at t+9s). A restart that works is
# visible before the next 10-minute tick, so a SECOND restart inside the window
# is never the cure for the first one having worked; it is the signature of a
# seat that restarting does not fix. That seat needs a human, and the limiter's
# refusal is what routes it to one — the refusing branch ESCALATES (courier
# delivery, DIVE-3727), it does not silently do nothing.
#
# Cost of a wrong restart is one seat's session window; cost of NOT restarting
# was measured on 2026-08-26 as the whole company's human-in-the-loop path dark
# for 2h33m with 9 gates pending, on a correct detection nothing served.
_SUP_RESTART_WINDOW_H="${SUPERVISOR_RESTART_WINDOW_H:-6}"
[[ "$_SUP_RESTART_WINDOW_H" =~ ^[0-9]+$ ]] || _SUP_RESTART_WINDOW_H=6
_SUP_RESTART_MAX="${SUPERVISOR_RESTART_MAX:-1}"
[[ "$_SUP_RESTART_MAX" =~ ^[0-9]+$ ]] || _SUP_RESTART_MAX=1

# ── DIVE-3915: THE CEILING COUNTS RESTARTS THAT DID NOT WORK ─────────────────
# Measured 2026-09-03. `main` and `olivia` both went deaf on telegram inside two
# minutes of each other, both with the same lifecycle signature (a `start` with
# no `boot ok`, the surviving poller SIGHUP'd ~8 min later, silence after). The
# cure on `main` was a plain restart and it took 2.4 SECONDS:
#
#   00:47:25  agent restart      00:47:27.489  launcher      00:47:27.841  boot ok
#
# The supervisor had classified it and could not act:
#
#   ESCALATE main (poller-dead: rung-4-needed)
#   ESCALATE main (poller-dead: restart-rate-limited)
#
# The budget was already spent — by an EARLIER, UNRELATED episode on the same
# seat, hours before, whose restart had WORKED. So the seat sat deaf not because
# the failure was hard but because a successful recovery had consumed the
# allowance for the next one.
#
# WHY THIS IS NOT "JUST ALLOW 2", the thing DIVE-3856 wrote an arm to forbid.
# Read the ceiling's own rationale above: *"a restart that works is visible
# before the next 10-minute tick, so a SECOND restart inside the window is never
# the cure for the first one having worked; it is the signature of a seat that
# restarting does not fix."* That sentence is entirely about a restart that DID
# NOT WORK. It was implemented as a count of restarts ATTEMPTED because, when it
# was written, the two were indistinguishable — `result` was cmd_restart's exit
# code and said `ok` either way. DIVE-3856 removed that excuse: the trail now
# records `ok` / `restart-ran-poller-still-dead` / `restart-ran-poller-unverified`
# from an actual poller probe. So the numerator can finally be what the comment
# always claimed: restarts that ran and left the seat deaf.
#
#   _SUP_RESTART_MAX      unhealed restarts per seat per window   (1 — UNCHANGED)
#   _SUP_RESTART_TOTAL_MAX  restarts of ANY outcome per window    (3 — the flap bound)
#
# `unverified` COUNTS AS UNHEALED, deliberately. It is the "I could not tell"
# outcome, and for a type absent from _SUP_POLLER_VERIFY_PAT (opencode) it is the
# only outcome there is — so on every unprobeable seat this ceiling keeps
# behaving exactly as it did before this change. A widening that rests on a probe
# must not widen where the probe is silent.
#
# THE TOTAL CEILING IS WHAT KEEPS THIS BOUNDED. Without it, a seat whose poller
# dies every ten minutes and is cured every time would restart forever and never
# reach a person: each restart verifies ok, so it never accrues an unhealed row.
# That seat is broken in a way a restart is only papering over, and 3 per 6h is
# the number at which we say so out loud (`escalate restart-flapping`) — a
# distinct reason string from `restart-rate-limited`, because "the remedy keeps
# failing" and "the remedy keeps being needed" send a human to different places.
_SUP_RESTART_TOTAL_MAX="${SUPERVISOR_RESTART_TOTAL_MAX:-3}"
[[ "$_SUP_RESTART_TOTAL_MAX" =~ ^[0-9]+$ ]] || _SUP_RESTART_TOTAL_MAX=3
(( _SUP_RESTART_TOTAL_MAX >= _SUP_RESTART_MAX )) || _SUP_RESTART_TOTAL_MAX="$_SUP_RESTART_MAX"

# ── DIVE-3856: RUNG 4 VERIFIES ITS OWN REMEDY ────────────────────────────────
# THE DEFECT, measured on `main` 2026-08-31 (supervisor_events + the seat's
# channels/telegram/lifecycle.log): at 12:30:15 rung 4 restarted a poller-dead
# seat and recorded {"rung":"restart","result":"ok"} — and `result` was
# cmd_restart's EXIT CODE, not the poller's return. The seat was still deaf. The
# lifecycle log has NO launcher line at all between 12:21:28 and 12:45:23, so
# neither that restart nor a hand-run `agent restart` at 12:33:31 spawned a
# channel launcher. Two restarts, both scored ok, both no-ops. The supervisor
# then discovered at 12:40 what was answerable at 12:30:24, and called the
# interval a success.
#
# WHY THE SUPERVISOR IS THE PLACE THIS CAN BE FIXED, and rotate is not: the
# rotation verb's bounce is a `systemd-run --on-active=1` transient unit that
# fires ~1s AFTER the CLI process exits, deliberately (an immediate restart
# SIGTERMs the caller's own sudo subprocess, and rotation is often invoked from
# inside the rotating seat's own bot). A verb cannot attest to an event
# scheduled after its own death — see
# community/wiki/a-deferred-restart-cannot-be-verified-by-the-verb-that-defers-it.md.
# The supervisor has no such problem: it fires the restart itself and it is
# still running afterwards. It just never looked.
#
# THE WAIT IS A POLL, NOT A SLEEP. A poller appears ~9s after the bounce, so a
# probe taken the instant `cmd_restart` returns reads ZERO on a perfectly
# healthy seat — a FALSE RED whose remedy would be another restart. We poll
# once a second and return the moment the poller is back, so the common case
# costs ~9s of one tick and only a genuinely dead seat pays the ceiling. The
# ceiling is per SEAT and this runs inside a 10-minute tick: even the pathological
# fleet-wide case (every seat poller-dead) is bounded by the rung-4 limiter,
# which allows one restart per seat per 6h.
_SUP_RESTART_VERIFY_SEC="${SUPERVISOR_RESTART_VERIFY_SEC:-30}"
[[ "$_SUP_RESTART_VERIFY_SEC" =~ ^[0-9]+$ ]] || _SUP_RESTART_VERIFY_SEC=30

# WHY A SECOND PREDICATE AND NOT `_SUP_POLLER_PAT`. Measured on this host
# 2026-08-31 (plugin 0.5.49): a claude seat's telegram bridge is TWO processes.
#
#   bun run --cwd ~/.claude/plugins/cache/5dive-plugins/telegram/0.5.49 … start
#       argv contains the plugin dir -> _SUP_POLLER_PAT matches it   THE LAUNCHER
#   /usr/local/bin/bun start.ts
#       argv is two tokens with no path -> _SUP_POLLER_PAT misses it  THE POLLER
#
#   seat        _SUP_POLLER_PAT count      actual `bun start.ts` count
#   don                1                            2   <- orphaned poller, board reads healthy
#   main               1                            1
#
# So the classifier's pattern is stable across the server.ts->start.ts rename
# precisely BECAUSE it never matched the poller. It is correct for state 1
# (launcher and poller both gone — the 08-31 outage) and BLIND to state 2
# (launcher alive, poller dead or duplicated). Inheriting it for the
# post-restart probe would grade the launcher we just started and call a still-
# deaf seat cured, which is this row's defect wearing a different hat.
#
# So this predicate names the POLLER, and names BOTH argv shapes: DIVE-3752 put
# the recording launcher in front of `start.ts`, while an older plugin cache and
# the telegram-<x> MCP variants still run `server.ts` (the variants
# path-qualified, hence the optional segment). A server.ts-only predicate reads
# ZERO on five verifiably healthy seats.
#
# `opencode` is ABSENT ON PURPOSE: its relay is `bun run --cwd <plugin> … start`,
# which carries no `.ts` at all, so any pattern here would read zero on a healthy
# seat. A type absent from this table verifies as `unverified` — which never
# claims ok and never claims dead. Same false-negative bias the classifier uses.
#
# NOT re-walked (measured, DIVE-3854/3855): `pgrep -f` MATCHES YOUR OWN COMMAND
# LINE, so our pid and our parent's are dropped explicitly; `sudo pgrep -u
# agent-<n>` FAILS OPEN on a 5dive-only sudo grant ("a password is required"
# exits like a real zero) so plain pgrep is used — the process table is
# world-readable; `5dive agent info`'s verdict is CACHED and cannot be a check.
declare -gA _SUP_TRUE_POLLER_PAT=(
  [claude]='bun ([^ ]*/)?(start|server)\.ts'
  [codex]='bun ([^ ]*/)?(start|server)\.ts'
  [grok]='bun ([^ ]*/)?(start|server)\.ts'
  [antigravity]='bun ([^ ]*/)?(start|server)\.ts'
)

# _sup_true_poller_count <name> <type> -> integer | n/a
# n/a means "not answerable here", never "zero".
_sup_true_poller_count() {
  local name="${1:-}" type="${2:-claude}" pat user pids p n=0
  pat="${_SUP_TRUE_POLLER_PAT[$type]:-}"
  [[ -n "$pat" ]] || { printf 'n/a\n'; return 0; }
  command -v pgrep >/dev/null 2>&1 || { printf 'n/a\n'; return 0; }
  user="agent-${name}"
  getent passwd "$user" >/dev/null 2>&1 || user="$name"
  pids=$(pgrep -u "$user" -f "$pat" 2>/dev/null) || pids=""
  for p in $pids; do
    [[ "$p" == "$$" || "$p" == "${PPID:-}" ]] && continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# _sup_restart_verify <name> <type> [deadline-secs] -> ok | still-dead | unverified
#
# Polls for the seat's POLLER (not its launcher) and returns the moment it is
# back. `unverified` is a THIRD outcome and is never folded into either of the
# other two: a type we cannot probe must not be scored ok (that is the defect)
# and must not be scored still-dead (that would escalate every healthy opencode
# seat). Callers record it verbatim.
_sup_restart_verify() {
  local name="${1:-}" type="${2:-claude}" budget="${3:-$_SUP_RESTART_VERIFY_SEC}" n waited=0
  [[ "$budget" =~ ^[0-9]+$ ]] || budget="$_SUP_RESTART_VERIFY_SEC"
  while :; do
    n="$(_sup_true_poller_count "$name" "$type")"
    [[ "$n" == "n/a" ]] && { printf 'unverified\n'; return 0; }
    [[ "$n" =~ ^[0-9]+$ ]] || { printf 'unverified\n'; return 0; }
    (( n > 0 )) && { printf 'ok\n'; return 0; }
    (( waited >= budget )) && break
    sleep 1
    waited=$((waited + 1))
  done
  printf 'still-dead\n'
}

# DIVE-1127 (ToS-hedge A2): ID/age-verification tripwire. Per the Jul-11 hedge
# memo (anthropic-tos-hedge-decision-jul11, D4 trigger 1), the biometric/ID lever
# in Anthropic's Jul-8 privacy policy is the plausible enforcement path against
# headless BYO. This watcher flags any claude session whose live tmux PANE shows
# an ID/age-verification challenge and alerts main + lodar SAME-DAY, tagging the
# account — the same-day flip to the OpenRouter-Claude profile (A1 runbook) is the
# response. Pane-scoped ON PURPOSE (not the JSONL transcript): the challenge is a
# harness/login interstitial rendered on the current screen, and scanning
# transcripts would self-trigger on any agent merely DISCUSSING verification
# (e.g. this very task's chatter). claude-only — the lever is consumer-auth.
_SUP_VERIFY_PANE_LINES="${SUPERVISOR_VERIFY_PANE_LINES:-40}"
[[ "$_SUP_VERIFY_PANE_LINES" =~ ^[0-9]+$ ]] || _SUP_VERIFY_PANE_LINES=40
# Alerts are deduped one-per-account per this window (same-day intent) so a
# challenge that persists across ticks pings main+lodar once, not every 10m.
_SUP_ALERT_WINDOW_H="${SUPERVISOR_ALERT_WINDOW_H:-24}"
[[ "$_SUP_ALERT_WINDOW_H" =~ ^[0-9]+$ ]] || _SUP_ALERT_WINDOW_H=24
# Anchored, second-person/imperative signature — a bare noun phrase like
# "age-verification" (which appears in THIS task's own title) must NOT match; a
# challenge DIRECTED at the user ("verify your identity", "confirm your age",
# "government-issued ID") must. Env-overridable so a new challenge phrasing can
# be tuned per box without a release (the _SUP_* env-escape-hatch pattern). NB:
# the default is a plain single-quoted assignment, NOT a ${:-} default — the
# `{0,30}` interval's brace would otherwise close the parameter expansion early.
# NB: this default is an UNVERIFIED best-guess — we have never seen a real
# Anthropic ID/age-verification challenge, so the phrasing is inferred. We ship
# alert-only and tune this (or override via SUPERVISOR_VERIFY_PAT) on the first
# real signature (DIVE-1127 verify-time last-mile).
#
# DIVE-4405: the third alternative used to end in the bare STEM `verif`, which
# admits `verified`/`unverified` — so the ordinary idle line
#   "Nothing left to continue - DIVE-4394 is closed and verified"
# ("to continue" + "verif" 30 chars later) paged lodar as an ID challenge on
# 2026-09-13. That clause now requires the imperative directed at the reader
# (`verify your` / `verify you`) — the bare stem appears in no alternative. No
# trailing space is required after it: a TUI wraps, and "…please verify your"
# can legitimately be the last thing on a line.
_SUP_VERIFY_PAT="${SUPERVISOR_VERIFY_PAT:-}"
[[ -n "$_SUP_VERIFY_PAT" ]] || _SUP_VERIFY_PAT='(verify|confirm)[[:space:]]+(your[[:space:]]+)?(identity|age)|please[[:space:]]+verify[[:space:]]+your|(to[[:space:]]+continue|you[[:space:]]+must)[^.]{0,30}verify[[:space:]]+(your|you)|government[- ]?issued[[:space:]]+(photo[[:space:]]+)?id|verify[[:space:]]+that[[:space:]]+you[[:space:]]+are[[:space:]]+(over|at[[:space:]]+least)|age[[:space:]-]*restricted'

# ── DIVE-4405: OUR OWN ALERT, RENDERED INTO A PANE, IS NOT PANE EVIDENCE ─────
#
# The second page on 2026-09-13 (agent-main, 05:51Z) was the FIRST page: main's
# pane was displaying the alert a2a-send, whose text carries the tripped line
# verbatim ("Pane signature: <excerpt>"). Every pane classifier here reads the
# screen, and the screen is where we deliver alerts and messages — so any
# signature we emit is guaranteed to come back as input on the next tick.
#
# Dropped BEFORE the match, for every classifier, not just the one that fired:
# a line carrying `[TRIPWIRE`, `[5dive-msg` or our alert's own `Pane signature:`
# label is machine output of ours, never a harness interstitial. Matched
# ANYWHERE in the line, not anchored: the TUI renders a received message inside
# a box with its own gutter, and an anchor would be defeated by one border glyph.
#
# RESIDUAL, signed and not closed here: tmux returns WRAPPED rows, so a long
# alert can put the excerpt on a continuation row carrying none of these
# markers, and that row is still matchable. `Pane signature:` catches the common
# wrap point (the excerpt starts right after it); the other two controls on that
# path are the tightened pattern above — the line that actually paged no longer
# matches at all — and the 24h per-account alert dedupe.
_SUP_PANE_ECHO_PAT='\[(TRIPWIRE|5dive-msg)|Pane signature:'

# Pure, no I/O: pane text in, the same text minus our own echoed machine lines.
# `|| true` because grep -v exits 1 when it drops everything, and an all-echo
# pane is a legitimately clean pane, not a failure.
_sup_pane_drop_echoes() {  # <pane-text-on-stdin>
  grep -vE "$_SUP_PANE_ECHO_PAT" 2>/dev/null || true
}

# DIVE-971: per-type telegram-bridge pgrep pattern (matched against the agent
# user's process argv, -f). claude's forked plugin argv carries the cache path
# …/5dive-plugins/telegram/<ver>; codex/grok/antigravity run the telegram-<x>
# MCP server as `bun <plugin>/server.ts`; opencode launches its relay via
# `bun run --cwd <plugin> … start` — every non-claude plugin dir is
# telegram-<name>, so the dir name is a unique, argv-stable match. A type
# absent here has no probeable bridge -> poller stays "n/a" (never classifies).
declare -gA _SUP_POLLER_PAT=(
  [claude]='5dive-plugins/telegram'
  [codex]='telegram-codex'
  [grok]='telegram-grok'
  [antigravity]='telegram-agy'
  [opencode]='telegram-opencode'
)

# DIVE-971: per-type "<relroot>|<find-args>" for the last-activity probe. relroot
# is under the agent's $HOME; find-args select the append-on-progress transcript
# files so the newest mtime IS the last-token-progress time (see header). A type
# absent here (or a missing/empty root) => age unknown => never stuck.
declare -gA _SUP_ACTIVITY_PROBE=(
  [claude]=".claude/projects|-name *.jsonl"
  [codex]=".codex/sessions|-name rollout-*.jsonl"
  [grok]=".grok/sessions|( -name *.json -o -name *.sqlite* )"
  [opencode]=".local/share/opencode/storage|-name *.json"
  [antigravity]=".gemini/antigravity-cli/brain|-name transcript*.jsonl"
)

# Newest matching transcript mtime (epoch, or empty) for one agent, per type.
# Read-only; unreadable/absent root => empty (caller treats as unknown age).
_sup_activity_epoch() {  # <type> <home>
  local type="$1" home="$2" probe root fargs
  probe="${_SUP_ACTIVITY_PROBE[$type]:-}"
  [[ -n "$probe" ]] || return 0
  root="${probe%%|*}"; fargs="${probe#*|}"
  [[ -d "$home/$root" ]] || return 0
  # fargs is a deliberate word-split find predicate (multiple -name/-o tokens).
  # shellcheck disable=SC2086
  { find "$home/$root" -type f $fargs -printf '%T@\n' 2>/dev/null || true; } \
    | sort -rn | head -1 | cut -d. -f1
}

# ── DIVE-4342 it.2: A PANE PROBE THAT COULD NOT LOOK SAYS SO ────────────────
#
# All three pane probes below used to read
#     (( svc_running )) && [[ $EUID -eq 0 ]] || return 0
# and every caller tested only `[[ -n "$excerpt" ]]`, so "I was not allowed to
# look" and "I looked and the pane is clean" were the SAME value. An
# unprivileged `5dive supervisor` therefore disarmed its three highest-priority
# branches (verify-challenge, blocked-on-prompt, pane quota) and still printed a
# clean word with no degradation mark. Measured on a customer box, 0.35.0.
#
# The fix is the one this codebase already wrote down for the quota deadline
# (community/wiki/a-fail-open-underneath-a-fail-closed-path-feeds-it-a-lie-in-the-format-it-trusts.md):
# the probe owes a DISTINGUISHABLE signal, the classifier owes the verdict. So
# blindness leaves via the return code — rc 3, never stdout — and the excerpt
# channel keeps its exact old meaning. A caller that ignores rc sees precisely
# what it saw before; a caller that reads it can tell blind from clean.
#
# THREE STATES, and the middle one is not blindness:
#   rc 0  — looked. stdout is the excerpt, empty means a clean pane.
#   rc 1  — N/A: there is nothing to look AT. A non-claude runtime has no
#           claude challenge/picker to render, and a seat whose unit is down has
#           no live pane at all — and that down unit is already the more
#           specific thing the board says about it. Not a degradation.
#   rc 3  — BLIND: a pane exists and we could not read it (not root, the sudo
#           hop failed, or the capture came back empty on a live session).
_SUP_PROBE_BLIND=3

# _sup_pane_gate <svc_running> — may we read this seat's live pane?
# rc 0 look / rc 1 nothing to look at / rc 3 blind. Pure but for $EUID.
_sup_pane_gate() {
  (( ${1:-0} )) || return 1
  [[ $EUID -eq 0 ]] || return "$_SUP_PROBE_BLIND"
  return 0
}

# _sup_probe_state <rc> <rc> ... — fold the three probe return codes into the
# per-seat verdict the classifier is handed. ANY blind probe makes the seat
# unprobed: partial sight is not sight, and the branches that went dark are the
# three highest-ranked ones. `n/a` (rc 1) and clean (rc 0) both read `ok` —
# neither is a failure to observe.
_sup_probe_state() {
  local rc
  for rc in "$@"; do [[ "$rc" == "$_SUP_PROBE_BLIND" ]] && { printf 'unprobed'; return; }; done
  printf 'ok'
}

# DIVE-1127: pure signature match, no I/O — echoes the first pane line that looks
# like an ID/age-verification challenge (trimmed), empty otherwise. Split out from
# _sup_verify_challenge so the false-positive-critical regex is unit-testable
# without a live tmux (mirrors how _sup_act_plan is the pure, tested core).
_sup_verify_match() {  # <pane-text-on-stdin>
  _sup_pane_drop_echoes | grep -iE "$_SUP_VERIFY_PAT" 2>/dev/null | head -1 \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160
}

# DIVE-1127: does this agent's live pane show a verification challenge? claude-only
# and root-only (the sudo tmux hop) — any other runtime, no root, or a down service
# returns empty (false-negative bias, like every other signal here). Echoes the
# matched pane excerpt when tripped.
_sup_verify_challenge() {  # <type> <user> <sess> <svc_running>
  local type="$1" user="$2" sess="$3" svc_running="$4"
  [[ "$type" == "claude" ]] || return 1
  _sup_pane_gate "$svc_running" || return $?
  local pane
  pane=$(sudo -n -u "$user" tmux capture-pane -p -t "$sess" -S "-${_SUP_VERIFY_PANE_LINES}" 2>/dev/null) \
    || return "$_SUP_PROBE_BLIND"
  [[ -n "$pane" ]] || return "$_SUP_PROBE_BLIND"
  printf '%s\n' "$pane" | _sup_verify_match
}

# ── DIVE-4293: BLOCKED-ON-PROMPT — a seat sitting on its own picker ──────────
#
# The class of stall no signal in this file could see. dev2 called
# AskUserQuestion at ~05:40Z on 2026-09-11 and sat at "Enter to select" until
# lodar noticed at 07:12Z. Every probe read it correctly and uselessly: the unit
# was active, tmux alive, the poller n/a, and the transcript's mtime was fresh
# right up to the question — so `no-progress` needs _SUP_T_STUCK_MIN of silence
# to fire, and by the time it does the seat has been frozen for half an hour.
# The pane is the ONLY place this state is written down, which is why it is read
# here (a remediation signal) and not in `5dive liveness` (whose charter refuses
# pane scrapes outright, and correctly — a present pane is not evidence of life).
#
# THE TAIL IS THE FALSE-POSITIVE CONTROL, not a performance choice. This regex
# matches a string that agents routinely WRITE — this very row's body contains
# it — so a 40-line window like the verify/quota probes use would classify any
# seat discussing the picker as sitting on one. A live picker's footer is the
# LAST thing on the pane; a transcript mention scrolls off within a line or two.
_SUP_PROMPT_PANE_LINES="${SUPERVISOR_PROMPT_PANE_LINES:-12}"
[[ "$_SUP_PROMPT_PANE_LINES" =~ ^[0-9]+$ ]] || _SUP_PROMPT_PANE_LINES=12

# The footer claude renders under a choice picker ("↑/↓ to navigate · Enter to
# select") and under the plan-approval dialog. Env-overridable on the same
# escape-hatch pattern as _SUP_VERIFY_PAT, because this string belongs to a TUI
# we do not ship and can change under us in any release.
_SUP_PROMPT_PAT="${SUPERVISOR_PROMPT_PAT:-}"
[[ -n "$_SUP_PROMPT_PAT" ]] || _SUP_PROMPT_PAT='[Ee]nter to (select|confirm|choose)'

# ── DIVE-4536: the OTHER picker — claude's BUILT-IN dangerous-command confirm ──
#
# DIVE-4293 above reads the footer the harness renders under AskUserQuestion and
# ExitPlanMode ("Enter to select"). There is a second modal that freezes a seat
# exactly as hard and renders a DIFFERENT footer. It is claude's own
# tool-permission confirm: a line naming the flagged command, a question asking
# whether to go ahead, a numbered option list whose first entry is the
# affirmative one, and a one-line footer offering the escape key. The three
# parts this reader keys on are the defaults of the three _PAT variables below;
# the modal is NOT transcribed here, for the reason the next paragraph gives.
#
# It fires even under bypassPermissions — bypass is not a no-questions mode —
# and it is not an AskUserQuestion, so DIVE-4293's PreToolUse hook never sees it
# either. Nothing in this fleet could read it. dev3 sat on one for ~10h on a
# live row on 2026-09-14 and every surface said the seat was fine.
#
# THE SIGNATURE IS A POSITION, NOT A CONJUNCTION (DIVE-4536 it.2).
#
# Iteration 1 keyed on the three parts co-occurring in the pane tail and claimed
# that "a quoted mention in prose carries the sentence and neither of the other
# two". THAT CLAIM WAS FALSE, and it was falsified by two artifacts iteration 1
# itself shipped: the task row documenting the incident, and the wiki page
# written to explain it, both quote main's capture VERBATIM — all three parts,
# adjacent. Prose about a pane signature is not a paraphrase of it, it is a
# transcript of it, and faithfulness is the whole point of the document. Any
# claude seat idle >=10m with either artifact in its capture window would have
# been read as sitting on a confirm, taken an Escape into a LIVE pane, and had a
# fabricated decline appended to its row — this row's own defect shape, one
# layer up: the documentation of the stall becomes the trigger that hides the
# next one.
#
# What actually separates an instance from a transcript is WHERE it sits, per
# community/wiki/documenting-machinery-inside-its-own-data-store-manufactures-
# false-positives.md ("anchor on position, not presence"):
#
#   * A LIVE modal is drawn at the BOTTOM of the pane, in place of the input
#     box. Below its footer there is only chrome — the box rule, the usage/model
#     line, the mode line. MEASURED 2026-09-14 on a live claude pane
#     (`tmux capture-pane -p -S -40` on agent-ops' own session): exactly TWO
#     non-empty lines below the input box's bottom rule; tests/ask_capture_unit.sh's
#     independently-written claude frame models THREE. _SUP_CONFIRM_TAIL_LINES
#     is 8 — better than 2x the measured chrome, so an extra hint, queue or
#     border line cannot produce a false negative, and still 5 clear of the
#     nearest REAL quotation measured in the population (the incident row's own
#     `task show` output carries the footer 13 non-empty lines from the end; the
#     wiki page, 24).
#   * A transcript has DOCUMENT after it — the next line of the row body is the
#     sentence explaining what the modal is; the next line of the wiki page is a
#     closing fence.
#
# The conjunction is kept and tightened rather than replaced, because position
# alone would accept a pane whose last lines happen to be a quoted question:
# ordering is now STRICT (question strictly above the affirmative option,
# affirmative option strictly above the footer — the modal's actual geometry, and
# a one-line prose mention carrying all three parts at once therefore fails), and
# the parts must be ADJACENT (_SUP_CONFIRM_SPAN_LINES / _SUP_CONFIRM_ADJ_LINES,
# measured from the capture: question→option 1 line, question→footer 3, so 2 and
# 4 carry a border line of slack).
#
# RESIDUAL, SIGNED: a capture whose BOTTOM-MOST content is a verbatim, correctly
# ordered transcript of the modal is not distinguishable from the modal by any
# rule in this function — the bytes are the same and there is nothing after
# either. That is why fix (3) of this iteration is the other half: the documents
# this change ships have their literals BROKEN, so our own writing cannot be a
# member of the population we scan. The bias of every constant here is
# false-negative: an unmatched confirm degrades to exactly the pre-DIVE-4536
# behaviour, which is the incident, whereas a false positive interrupts a
# working seat.
_SUP_CONFIRM_PAT="${SUPERVISOR_CONFIRM_PAT:-}"
[[ -n "$_SUP_CONFIRM_PAT" ]] || _SUP_CONFIRM_PAT='Do you want to (proceed|continue)'
_SUP_CONFIRM_YES_PAT="${SUPERVISOR_CONFIRM_YES_PAT:-}"
[[ -n "$_SUP_CONFIRM_YES_PAT" ]] || _SUP_CONFIRM_YES_PAT='^[[:space:]]*(❯|>)?[[:space:]]*1\.[[:space:]]*Yes'
_SUP_CONFIRM_FOOTER_PAT="${SUPERVISOR_CONFIRM_FOOTER_PAT:-}"
[[ -n "$_SUP_CONFIRM_FOOTER_PAT" ]] || _SUP_CONFIRM_FOOTER_PAT='Esc to cancel'

# The position anchors. All three count NON-EMPTY lines, because a capture is
# padded to the pane height with blanks and a modal is not the last ROW of the
# pane, it is the last CONTENT of it.
#   TAIL — how far from the end of the capture the footer may sit.
#   SPAN — greatest distance from the question line to the footer line.
#   ADJ  — greatest distance from the question line to the affirmative option.
_SUP_CONFIRM_TAIL_LINES="${SUPERVISOR_CONFIRM_TAIL_LINES:-8}"
[[ "$_SUP_CONFIRM_TAIL_LINES" =~ ^[0-9]+$ ]] || _SUP_CONFIRM_TAIL_LINES=8
_SUP_CONFIRM_SPAN_LINES="${SUPERVISOR_CONFIRM_SPAN_LINES:-4}"
[[ "$_SUP_CONFIRM_SPAN_LINES" =~ ^[0-9]+$ ]] || _SUP_CONFIRM_SPAN_LINES=4
_SUP_CONFIRM_ADJ_LINES="${SUPERVISOR_CONFIRM_ADJ_LINES:-2}"
[[ "$_SUP_CONFIRM_ADJ_LINES" =~ ^[0-9]+$ ]] || _SUP_CONFIRM_ADJ_LINES=2
# HOW LONG a confirm must stand before this watchdog presses a key on the seat's
# behalf. The ALERT is immediate (a frozen seat is a frozen seat); only the
# keystroke waits. Ten minutes is one tick: long enough that we are never racing
# a seat that is about to be answered by a person attached to the pane, short
# enough that the measured failure (10 HOURS) cannot recur.
_SUP_T_CONFIRM_DWELL_MIN="${SUPERVISOR_T_CONFIRM_DWELL_MIN:-10}"
[[ "$_SUP_T_CONFIRM_DWELL_MIN" =~ ^[0-9]+$ ]] || _SUP_T_CONFIRM_DWELL_MIN=10

# _sup_confirm_match — pure, no I/O. Echoes the confirm's question line (trimmed)
# when the pane tail carries the whole signature AT THE BOTTOM, empty otherwise.
# Split from the capture for the same reason every other matcher here is: the
# false-positive-critical rule has to be gradeable without a live tmux. See the
# block above for why this is a position test and not a co-occurrence test.
_sup_confirm_match() {  # <pane-text-on-stdin>
  local tail ln n lo f w q y i
  tail=$(_sup_pane_drop_echoes) || return 0
  [[ -n "$tail" ]] || return 0
  local -a L=()
  while IFS= read -r ln; do
    [[ "$ln" =~ ^[[:space:]]*$ ]] && continue
    L+=("$ln")
  done <<<"$tail"
  n=${#L[@]}
  (( n > 0 )) || return 0
  # Anchor: the footer must sit inside the last _SUP_CONFIRM_TAIL_LINES non-empty
  # lines. Scan from the bottom up so the LOWEST qualifying footer wins — on a
  # pane that carries both a transcript and a live modal, the modal is the lower.
  lo=$(( n - _SUP_CONFIRM_TAIL_LINES )); (( lo < 0 )) && lo=0
  for (( f = n - 1; f >= lo; f-- )); do
    grep -qE "$_SUP_CONFIRM_FOOTER_PAT" <<<"${L[f]}" 2>/dev/null || continue
    w=$(( f - _SUP_CONFIRM_SPAN_LINES )); (( w < 0 )) && w=0
    q=-1; y=-1
    # Strict geometry: question, then the affirmative option, then the footer —
    # each on its OWN line and in that order. A prose mention that carries all
    # three parts on one line (this row's `result` field does exactly that) has
    # no ordering and is rejected here, not by the anchor.
    for (( i = w; i < f; i++ )); do
      if (( q < 0 )) && grep -qE "$_SUP_CONFIRM_PAT" <<<"${L[i]}" 2>/dev/null; then q=$i; continue; fi
      if (( q >= 0 && y < 0 && i > q )) && grep -qE "$_SUP_CONFIRM_YES_PAT" <<<"${L[i]}" 2>/dev/null; then y=$i; fi
    done
    (( q >= 0 && y > q && y < f )) || continue
    (( y - q <= _SUP_CONFIRM_ADJ_LINES )) || continue
    printf '%s\n' "${L[q]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160
    return 0
  done
  return 0
}
# _sup_prompt_match — pure, no I/O. Echoes the footer line (trimmed) when the
# pane tail is sitting on a picker, empty otherwise. Split out from the capture
# for the same reason _sup_verify_match and _sup_quota_match are: the
# false-positive-critical regex has to be gradeable without a live tmux.
_sup_prompt_match() {  # <pane-text-on-stdin>
  _sup_pane_drop_echoes | grep -E "$_SUP_PROMPT_PAT" 2>/dev/null | tail -1 \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160
}

# ── DIVE-4581: the THIRD picker — claude's own USAGE-LIMIT hold ──────────────
#
# Two pickers above; this is the one that PAGED A HUMAN THREE TIMES IN ONE
# EVENING (quinn ~16:05Z, ops ~16:20Z, community ~01:00Z on 2026-09-15/16, all
# on the same exhausted account) for a non-event. When claude is refused by a
# plan/org wall mid-turn it prints the refusal and renders its OWN choice
# picker asking what to do about it: hold and wait for the reset, wait here and
# resume automatically at the printed time, or upgrade the plan. It carries the
# DIVE-4293 footer, so _sup_prompt_match matches it; nothing on it is marked
# "(Recommended)", so _sup_prompt_recommended refuses it; and the pane
# therefore classified `blocked-on-prompt` with "a person must choose".
#
# A PERSON DOES NOT HAVE TO CHOOSE. This is a QUOTA HOLD whose own pane prints
# the time it ends, the class this file already has for exactly that state is
# `quota-exhausted`, and its remedy is a keypress this watchdog is entitled to
# make: take the option that waits here and resumes automatically. main made
# that keypress by hand for two of the three seats; the third had dismissed
# itself before anyone read it. Nothing about the state needed a human.
#
# THE SIGNATURE IS A POSITION, NOT A CONJUNCTION — the DIVE-4536 lesson, and it
# binds harder here because the act is worse. The confirm's mis-press DECLINES
# (fail-closed); this one presses Enter on an option a false positive picked,
# and it also SILENCES the page a real AskUserQuestion owes. So the reading is
# only ever attempted on a pane the DIVE-4293 footer has ALREADY matched, and
# on top of that it demands the wall's own two option lines, each a NUMBERED
# option on its OWN line, in order, immediately above that footer:
#
#   * the HOLD option (wait for the limit to reset) strictly above
#   * the AUTO-RESUME option (continue automatically …) strictly above
#   * the footer, itself inside the last _SUP_LIMIT_TAIL_LINES non-empty lines.
#
# A quotation fails all three anchors at once: prose about this picker carries
# the two option texts on ONE line (this row's own body does exactly that), or
# with document after it. Both failure directions were measured against the
# population, not composed — tests/supervisor_limit_picker_unit.sh feeds in the
# verbatim `task show DIVE-4581` output and the wiki page written for it.
#
# THE KEYSTROKE IS CURSOR-RELATIVE, NOT "Down, Enter". The pane above renders
# the hold option first and the cursor sits on it, so one Down reaches the
# auto-resume option — but a fixed keystroke count is the assumption DIVE-4536
# refused for the same reason ("pressing a DIGIT assumes the numbering"). This
# computes the SIGNED distance from the cursor row to the auto-resume row and
# sends that many Down (or Up) presses. No cursor on a numbered option, or a
# distance beyond _SUP_LIMIT_STEP_MAX, yields `unknown`: the class still flips
# to quota-exhausted (which is true, and which does not page), and NO key is
# pressed. Bias, as everywhere in this file: false-negative.
_SUP_LIMIT_HOLD_PAT="${SUPERVISOR_LIMIT_HOLD_PAT:-}"
[[ -n "$_SUP_LIMIT_HOLD_PAT" ]] \
  || _SUP_LIMIT_HOLD_PAT='^[[:space:]]*(❯|>)?[[:space:]]*[0-9]+\.[[:space:]]+.*wait[[:space:]]+for[[:space:]]+(the[[:space:]]+)?limit[[:space:]]+to[[:space:]]+reset'
_SUP_LIMIT_AUTO_PAT="${SUPERVISOR_LIMIT_AUTO_PAT:-}"
[[ -n "$_SUP_LIMIT_AUTO_PAT" ]] \
  || _SUP_LIMIT_AUTO_PAT='^[[:space:]]*(❯|>)?[[:space:]]*[0-9]+\.[[:space:]]+.*continue[[:space:]]+automatically'
# The cursor row: the POINTER GLYPH ONLY, on a numbered option.
#
# ITERATION 2 (grader gr-quinn-19) — this pattern used to accept a bare '>' as
# an alternative to the pointer, on the argument that "an echoed alert line is
# not a numbered option". A QUOTED option line IS a numbered option behind that
# gutter: a markdown blockquote, a chat forward, or a DIVE-4405 inbound drawn
# with a '>' gutter prefixes EVERY option row with it, so the reading did not
# merely match, it produced the most CONFIDENT possible cursor position and
# emitted a keystroke into a live pane. Measured on three such panes before the
# restriction: all three answered with a step count. This reader is the only
# one in the limit path that ACTS, so it takes the pointer the live capture
# actually renders and nothing else; a terminal that cannot draw it reads
# `unknown`, the class still flips to quota-exhausted, and NO key is pressed.
# _sup_prompt_recommended keeps its wider glyph class deliberately: it emits no
# keystroke of its own and its pre-filter is a different control.
_SUP_LIMIT_CURSOR_PAT="${SUPERVISOR_LIMIT_CURSOR_PAT:-}"
[[ -n "$_SUP_LIMIT_CURSOR_PAT" ]] || _SUP_LIMIT_CURSOR_PAT='^[[:space:]]*❯[[:space:]]*[0-9]+\.[[:space:]]'
# A NUMBERED OPTION ROW of this picker — the unit the distance is counted in.
# Down/Up move by OPTION, not by rendered line, so a release that draws a
# description sub-line under each option makes a line count over-shoot: the
# true distance 1 computes as 2 and walks the cursor onto "upgrade your plan",
# the purchase this design exists to avoid. Same glyph class as the cursor: a
# gutter-quoted "> 2. ..." is not an option row, so a quoted pane cannot supply
# the positions either and falls to `unknown`.
_SUP_LIMIT_OPTION_PAT="${SUPERVISOR_LIMIT_OPTION_PAT:-}"
[[ -n "$_SUP_LIMIT_OPTION_PAT" ]] || _SUP_LIMIT_OPTION_PAT='^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]'
# Anchors, all counting NON-EMPTY lines (a capture is blank-padded to the pane
# height). Measured on the live 2026-09-16 05:5xZ capture kept as
# tests/fixtures/dive4581/limit-picker-pane.txt: the footer is the LAST
# non-empty line of the capture — this picker REPLACES the input box, so unlike
# the DIVE-4536 confirm there is no chrome under it at all — and hold→footer
# spans 3 lines (SPAN 6 carries a fourth option and a border line of slack).
# TAIL 3 is therefore 2 clear of the measurement, which is the slack a future
# release's status line would need, and no more: every additional line of tail
# is a line of QUOTATION the matcher would accept.
#
# RESIDUAL, SIGNED: a capture whose bottom-most content is a verbatim, correctly
# ordered transcript of this picker with fewer than three non-empty lines after
# it is not distinguishable from the picker — the bytes are the same. That is
# DIVE-4536's signed residual inheriting one class down, and it is why the page
# and the row shipped with this change have their literals broken up, and why
# both are graded as fixtures. The exposure is bounded by the footer match this
# reading sits behind: it never sees a pane DIVE-4293 would not already have
# acted on.
_SUP_LIMIT_TAIL_LINES="${SUPERVISOR_LIMIT_TAIL_LINES:-3}"
[[ "$_SUP_LIMIT_TAIL_LINES" =~ ^[0-9]+$ ]] || _SUP_LIMIT_TAIL_LINES=3
_SUP_LIMIT_SPAN_LINES="${SUPERVISOR_LIMIT_SPAN_LINES:-6}"
[[ "$_SUP_LIMIT_SPAN_LINES" =~ ^[0-9]+$ ]] || _SUP_LIMIT_SPAN_LINES=6
_SUP_LIMIT_STEP_MAX="${SUPERVISOR_LIMIT_STEP_MAX:-4}"
[[ "$_SUP_LIMIT_STEP_MAX" =~ ^[0-9]+$ ]] || _SUP_LIMIT_STEP_MAX=4

# _sup_limit_picker_match — pure, no I/O. Echoes
# "<auto-resume-option-line>\x1f<steps|unknown>" when the pane tail is sitting
# on the usage-limit hold picker, empty otherwise. The excerpt is the
# auto-resume line on purpose: it is the one that carries the RESUME TIME, so
# every downstream surface quotes a wall that names when it ends.
_sup_limit_picker_match() {  # <pane-text-on-stdin>
  local tail ln n lo f h a c i w d steps pc pa k
  local -a OPT=()
  tail=$(_sup_pane_drop_echoes) || return 0
  [[ -n "$tail" ]] || return 0
  local -a L=()
  while IFS= read -r ln; do
    [[ "$ln" =~ ^[[:space:]]*$ ]] && continue
    L+=("$ln")
  done <<<"$tail"
  n=${#L[@]}
  (( n > 0 )) || return 0
  lo=$(( n - _SUP_LIMIT_TAIL_LINES )); (( lo < 0 )) && lo=0
  # Bottom-up, so on a pane carrying both a transcript and the live picker the
  # LOWER (live) one wins — same reason _sup_confirm_match scans this way.
  for (( f = n - 1; f >= lo; f-- )); do
    grep -qE "$_SUP_PROMPT_PAT" <<<"${L[f]}" 2>/dev/null || continue
    w=$(( f - _SUP_LIMIT_SPAN_LINES )); (( w < 0 )) && w=0
    h=-1; a=-1; c=-1; OPT=()
    for (( i = w; i < f; i++ )); do
      if (( h < 0 )) && grep -qE "$_SUP_LIMIT_HOLD_PAT" <<<"${L[i]}" 2>/dev/null; then h=$i; fi
      if (( a < 0 && h >= 0 && i > h )) && grep -qE "$_SUP_LIMIT_AUTO_PAT" <<<"${L[i]}" 2>/dev/null; then a=$i; fi
      if grep -qE "$_SUP_LIMIT_OPTION_PAT" <<<"${L[i]}" 2>/dev/null; then OPT+=("$i"); fi
      # FIRST hit only: one pointer is drawn per picker, so a second reading in
      # the same window is not a later cursor, it is another picker's row.
      if (( c < 0 )) && grep -qE "$_SUP_LIMIT_CURSOR_PAT" <<<"${L[i]}" 2>/dev/null; then c=$i; fi
    done
    (( h >= 0 && a > h && a < f )) || continue
    # The distance is counted in OPTION ROWS, and both ends must BE option rows
    # of this window — otherwise the reading is not confident and no key moves.
    steps="unknown"
    if (( c >= w )); then
      pc=-1; pa=-1
      for (( k = 0; k < ${#OPT[@]}; k++ )); do
        (( OPT[k] == c )) && pc=$k
        (( OPT[k] == a )) && pa=$k
      done
      if (( pc >= 0 && pa >= 0 )); then
        d=$(( pa - pc )); (( d < 0 )) && d=$(( -d ))
        (( d <= _SUP_LIMIT_STEP_MAX )) && steps=$(( pa - pc ))
      fi
    fi
    printf '%s\x1f%s\n' \
      "$(printf '%s\n' "${L[a]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160)" \
      "$steps"
    return 0
  done
  return 0
}

# _sup_prompt_recommended — pure, no I/O. rc 0 when the option the cursor is ON
# is marked "(Recommended)", rc 1 otherwise.
#
# WHY THE CURSOR AND NOT THE PANE: Enter takes the HIGHLIGHTED option, so "some
# option somewhere says Recommended" is the wrong question — answering on it
# would press Enter on whatever the model happened to leave the cursor over.
# Claude marks the selected row with ❯ (or a bare '>' on a terminal without it).
# No cursor visible => rc 1 => we do not answer, we page. Fail-closed, because
# the failure mode of guessing is an irreversible choice made by a watchdog.
# DIVE-4405 (iteration 2): the pre-filter runs HERE TOO, and this is the reader
# that most needed it. A TUI renders an inbound a2a/alert inside a box whose
# gutter is a bare '>', so an echoed alert quoting "…(Recommended)" reads as a
# cursor row and authorises Enter on whatever the model was actually sitting on.
# The four other pane-text-on-stdin readers only page; this one ACTS.
_sup_prompt_recommended() {  # <pane-text-on-stdin>
  local line
  line=$(_sup_pane_drop_echoes | grep -E '^[[:space:]]*(❯|>)[[:space:]]' 2>/dev/null | tail -1) || return 1
  [[ -n "$line" ]] || return 1
  [[ "$line" == *"(Recommended)"* ]]
}

# Does this agent's live pane show a choice picker? claude-only and root-only
# (the sudo tmux hop), like every other pane probe here — any other runtime, no
# root, or a down service returns empty (false-negative bias). Echoes
# "<footer-excerpt>\x1f<recommended|unmarked>" when tripped, empty otherwise.
_sup_prompt_pane_capture() {  # <user> <sess> <svc_running>
  _sup_pane_gate "$3" || return $?
  sudo -n -u "$1" tmux capture-pane -p -t "$2" -S "-${_SUP_PROMPT_PANE_LINES}" 2>/dev/null \
    || return "$_SUP_PROBE_BLIND"
}

_sup_prompt_pane() {  # <type> <user> <sess> <svc_running>
  local type="$1" pane excerpt rc lrow
  [[ "$type" == "claude" ]] || return 1
  pane=$(_sup_prompt_pane_capture "$2" "$3" "$4"); rc=$?
  (( rc == 0 )) || return "$rc"
  [[ -n "$pane" ]] || return "$_SUP_PROBE_BLIND"
  excerpt=$(printf '%s\n' "$pane" | _sup_prompt_match)
  if [[ -n "$excerpt" ]]; then
    # DIVE-4581: the usage-limit hold is read FIRST among the footer's readings,
    # and only ever on a pane this footer already matched. It is the narrower
    # claim (a picker whose two options are the wall's own), so a pane that
    # satisfies it is never also an AskUserQuestion; the marks are disjoint and
    # this one carries its own keystroke plan in the mark.
    lrow=$(printf '%s\n' "$pane" | _sup_limit_picker_match)
    if [[ -n "$lrow" ]]; then
      printf '%s\037limit-picker:%s\n' "${lrow%%$'\x1f'*}" "${lrow##*$'\x1f'}"
      return 0
    fi
    if printf '%s\n' "$pane" | _sup_prompt_recommended; then
      printf '%s\037recommended\n' "$excerpt"
    else
      printf '%s\037unmarked\n' "$excerpt"
    fi
    return 0
  fi
  # DIVE-4536: the built-in confirm, checked only after the DIVE-4293 footer has
  # not matched. Ranked second because the two are mutually exclusive in
  # practice and the AskUserQuestion reading is the older, wider-graded one; a
  # pane that somehow carried both is the model's own picker, which is the
  # answerable case and must not be downgraded to a decline.
  excerpt=$(printf '%s\n' "$pane" | _sup_confirm_match)
  [[ -n "$excerpt" ]] || return 0
  printf '%s\037confirm\n' "$excerpt"
}

# DIVE-3272: pure signature match, no I/O — echoes ONE pane line that looks like
# a model-capacity/quota refusal, empty otherwise. Split out from
# _sup_quota_pane for the same reason _sup_verify_match is: the false-positive-
# critical regex has to be unit-testable without a live tmux.
#
# DIVE-3880 it.2: WHICH matching line is returned is now load-bearing, so the
# selection is part of this function rather than a `head -1`. Before 3880 any
# match meant the same thing (alarm) and picking the first was cosmetic; once a
# `lapsed` deadline DISARMS the alarm, choosing the oldest line lets a seat that
# hit the wall, resumed, and hit it AGAIN inside one pane window report healthy
# while genuinely frozen — the excerpt, not the state machine, carrying the
# false negative. Quota-pressured seats are the only population this detector
# has, so two refusals in a 40-line window is the expected shape.
#
# The window is a SEQUENCE, and it is aggregated, not sampled:
#
#   1. Any match whose deadline is still in the FUTURE wins outright (the
#      latest such deadline). A future expiry printed by the harness itself is
#      unarguable proof the wall is still in force, wherever in the window it
#      sits — so the window can only lapse when EVERY timed match has lapsed.
#   2. Otherwise the LAST match wins — the newest refusal, which supersedes the
#      scrollback above it. Its own state (lapsed, or unknown when it carries no
#      parseable deadline) is the window's state.
#
# Why the newest and not "any unknown pins the alarm": an untimed signature
# (a transient `API Error ... 429`, an older `credit balance is too low`) also
# keeps rendering forever, so treating one anywhere in the window as an
# indefinite freeze re-opens the exact stale-scrollback false positive DIVE-3880
# exists to close. A seat that IS indefinitely frozen re-emits — the pane is
# live evidence and the tick re-reads it — so its newest line says so.
#
# `now` is an ARGUMENT (never read internally) so every arm is assertable at a
# fixed clock, same contract as _sup_quota_deadline, which this calls.
# DIVE-4401 — the banner is a SENTENCE and the pane is a fixed width, so the
# signature and the reset clock are routinely on DIFFERENT physical lines. The
# Claude Team wall is the case that forced this:
#
#   You've hit your org's monthly spend limit · ask your admin to raise it at
#   claude.ai/admin-settings/usage · your session limit resets 9am (UTC)
#
# Line 1 carries the signature and no clock; line 2 carries the clock. Reading
# the deadline off the SELECTED line alone therefore returned `unknown` for a
# banner whose reset time was plainly on screen — measured 2026-09-13 04:31Z:
# `agent info main` said quotaDeadline=live and `agent info olivia` said
# `unknown` off byte-equivalent reset text, purely because the two panes wrapped
# the same sentence differently.
#
# So when a selected match carries no parseable deadline of its own, look at its
# IMMEDIATE neighbours (±_SUP_QUOTA_JOIN_LINES) for a line that _sup_quota_deadline
# itself can read, and emit the two joined as one excerpt. Three properties keep
# this from re-opening DIVE-3880's stale-scrollback false positive:
#   • only a match with an UNKNOWN deadline is ever extended — a line that
#     already names its own clock is never overridden by a neighbour's;
#   • the neighbour must satisfy _sup_quota_deadline, which requires either
#     `continuing automatically at <clock>` or `limit … resets <clock>` — a bare
#     `resets 9am` elsewhere on screen cannot join;
#   • adjacency is the wrap relationship. A refusal two screens up cannot lend
#     its clock to a newer one.
# The emitted excerpt is still ONE logical banner, so _sup_quota_deadline's
# one-line invariant and the `info` side that re-parses the stored excerpt both
# hold — and both now read the same state the tick did.
_SUP_QUOTA_JOIN_LINES="${SUPERVISOR_QUOTA_JOIN_LINES:-2}"
[[ "$_SUP_QUOTA_JOIN_LINES" =~ ^[0-9]+$ ]] || _SUP_QUOTA_JOIN_LINES=2

_sup_quota_match() {  # <pane-text-on-stdin> [now_epoch]
  local now="${1:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  # Keep the WHOLE pane, not just the matching lines: the clock we may need to
  # borrow sits on a line that carries no signature of its own.
  #
  # DIVE-4405 dropped our own echoed alert lines immediately before the grep.
  # That filter has to move UPSTREAM of the pane read, not just stay in front
  # of the match: the join below borrows a clock from a NON-signature
  # neighbour, so an echoed alert quoting a reset time is exactly the line this
  # would lend to an untimed banner — DIVE-4405's self-echo defect arriving
  # through the neighbour instead of through the match. Filtering the pane
  # itself closes both doors with one call.
  local pane_text
  pane_text=$(_sup_pane_drop_echoes) || pane_text=""
  [[ -n "$pane_text" ]] || return 0
  local -a pane=() ; local raw
  while IFS= read -r raw; do
    raw="${raw#"${raw%%[![:space:]]*}"}"; raw="${raw%"${raw##*[![:space:]]}"}"
    pane+=("${raw:0:160}")
  done <<<"$pane_text"
  (( ${#pane[@]} )) || return 0

  local i j d st ep jst jep cand last="" live="" live_ep=-1 found=0
  for (( i = 0; i < ${#pane[@]}; i++ )); do
    [[ -n "${pane[i]}" ]] || continue
    _sup_line_is_refusal "${pane[i]}" || continue
    found=1
    cand="${pane[i]}"
    IFS=$'\x1f' read -r st ep <<<"$(_sup_quota_deadline "$cand" "$now")"
    if [[ "$st" == "unknown" ]]; then
      # NEAREST first, and FORWARD before backward at equal distance: a wrapped
      # sentence continues on the line BELOW its signature, so with two banners
      # stacked in one window a backward-first scan hands the newer one the
      # older one's clock. Skip a neighbour that is itself a signature — that is
      # a separate banner, not this one's continuation.
      for (( d = 1; d <= _SUP_QUOTA_JOIN_LINES; d++ )); do
        for j in $(( i + d )) $(( i - d )); do
          (( j >= 0 && j < ${#pane[@]} )) || continue
          [[ -n "${pane[j]}" ]] || continue
          _sup_line_is_refusal "${pane[j]}" && continue
          IFS=$'\x1f' read -r jst jep <<<"$(_sup_quota_deadline "${pane[j]}" "$now")"
          [[ "$jst" == "unknown" ]] && continue
          cand="${pane[i]} · ${pane[j]}"; st="$jst"; ep="$jep"
          break 2
        done
      done
    fi
    last="$cand"
    if [[ "$st" == "live" && "$ep" =~ ^[0-9]+$ ]] && (( ep > live_ep )); then
      live_ep="$ep"; live="$cand"
    fi
  done
  (( found )) || return 0
  printf '%s\n' "${live:-$last}"
}

# DIVE-3880: the pane KEEPS RENDERING a lapsed refusal, so the signature alone
# cannot say whether the seat is still frozen — and the discriminator is already
# inside the string being parsed. The harness prints its own resume deadline
# ("continuing automatically at 2:10pm"); compared against now that is three
# states, not two:
#
#   live     deadline in the FUTURE  -> the refusal is in force, the seat IS frozen
#   lapsed   deadline in the PAST    -> scrollback; the seat has already resumed
#   unknown  no deadline in the text, or one this cannot parse
#
# UNKNOWN abstains — it is NEVER resolved to either of the other two. That is
# DIVE-3778's third-state rule, and it is load-bearing in BOTH directions here:
# most quota phrasings carry no deadline at all (`credit balance is too low`,
# `insufficient_quota`, a weekly `7d: 100%`) and those are real, indefinite
# freezes. So an abstention leaves the pre-3880 classification exactly as it
# was and only refuses to claim a live deadline; it is not a clear.
#
# Pure: `now` is an ARGUMENT, never `date +%s` read internally, so every arm is
# assertable at a fixed clock. Echoes "<state>\x1f<deadline-epoch|>".
#
# INVARIANT (DIVE-3880 it.2): the input is ONE pane line — the single excerpt
# _sup_quota_match selected, or the single one `info` inherited from the trail.
# Aggregating a WINDOW of several refusals is that function's job, deliberately
# not this one's: this parses, it does not choose. So the first-match-wins read
# below is over one refusal, and the "which of several lines" question — the one
# it.1 got wrong — is answered exactly once, upstream.
#
# Which of three candidate days: the NEAREST to `now` (yesterday / today /
# tomorrow at that time-of-day). A pane line is undated, so a bare `12:30am`
# read at 23:55 means tomorrow and a bare `11pm` read at 00:05 means yesterday
# — anchoring on today alone gets one of those backwards whichever way you pick.
# RESIDUAL, stated because it cannot be fixed from this surface: a refusal still
# on screen more than ~12h later reads as the same time-of-day TODAY, so it can
# read `live` when it lapsed a day ago. Bounded by the pane window
# (_SUP_QUOTA_PANE_LINES) at the tick, and by _SUP_INFO_TICK_STALE on the `info`
# side; a dated deadline in the text would remove it and no runtime prints one.
_sup_quota_deadline() {  # <text> [now_epoch]
  local text="$1" now="${2:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  local re='[Cc]ontinuing[[:space:]]+automatically[[:space:]]+at[[:space:]]+([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*([AaPp])?\.?[Mm]?\.?'
  if [[ "$text" =~ $re ]]; then
    _sup_clock_state "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-00}" "${BASH_REMATCH[4]:-}" "$now"
    return 0
  fi
  # DIVE-4206 — the SECOND recognised phrasing, `... limit · resets 4am (UTC)`.
  # DIVE-3970 split _sup_clock_state out of the arm above expressly so this one
  # could reuse the identical meridiem + nearest-day arithmetic instead of a
  # second, subtly different parser, and then never wired a caller: the split's
  # own comment names the phrasing, and until now no regex looked for it. The
  # cost of the gap is not a misread — an unmatched deadline abstains, which is
  # safe — it is that a park on this wall fell back to the blind 6h cap instead
  # of running to the reset time the banner printed.
  #
  # RESIDUAL: the banner stamps its own zone ("(UTC)") and _sup_clock_state
  # resolves a bare clock in the HOST's zone. On this host those are the same
  # (`timedatectl` = UTC), so the two agree today; on a non-UTC host the parsed
  # deadline would be wrong by the offset. Not fixed here, because reading the
  # zone belongs with the clock arithmetic in _sup_clock_state and every caller
  # of it, not in one of two regexes — and `unknown` (the pre-4206 behaviour on
  # this phrasing) is still what an unparseable clock returns.
  local re2='limit[^0-9]{0,20}resets?[[:space:]]+(at[[:space:]]+)?([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*([AaPp])?\.?[Mm]?\.?'
  if [[ "$text" =~ $re2 ]]; then
    _sup_clock_state "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:-00}" "${BASH_REMATCH[5]:-}" "$now"
    return 0
  fi
  printf 'unknown\x1f\n'
}

# DIVE-3970: the meridiem + nearest-day arithmetic of _sup_quota_deadline, split
# out VERBATIM so a second recognised phrasing (`... limit resets 11:30am`) gets
# the identical clock semantics instead of a second, subtly different parser.
# Takes the three captured pieces, not a text: choosing WHICH regex matched is
# the caller's job, exactly as choosing which pane LINE is _sup_quota_match's.
# Echoes "<live|lapsed|unknown>\x1f<epoch|>"; `now` is an ARGUMENT, never read
# internally, so every arm stays assertable at a fixed clock.
_sup_clock_state() {  # <hh> <mm> <a|p|""> <now_epoch>
  local hh="${1:-}" mm="${2:-00}" ap="${3:-}" now="${4:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  [[ "$hh" =~ ^[0-9]{1,2}$ && "$mm" =~ ^[0-9]{1,2}$ ]] || { printf 'unknown\x1f\n'; return 0; }
  hh=$((10#$hh)); mm=$((10#$mm))
  case "${ap,,}" in
    a) (( hh >= 1 && hh <= 12 )) || { printf 'unknown\x1f\n'; return 0; }
       if (( hh == 12 )); then hh=0; fi ;;
    p) (( hh >= 1 && hh <= 12 )) || { printf 'unknown\x1f\n'; return 0; }
       if (( hh != 12 )); then hh=$(( hh + 12 )); fi ;;
    # No meridiem: only an unambiguous 24h hour is parseable. A bare "at 9:30"
    # is 9:30 OR 21:30 and guessing either way invents the answer, so it takes
    # the third state rather than a coin flip.
    *) (( hh >= 13 && hh <= 23 )) || { printf 'unknown\x1f\n'; return 0; } ;;
  esac
  (( mm >= 0 && mm <= 59 )) || { printf 'unknown\x1f\n'; return 0; }
  local day base best="" bestd=-1 d
  day=$(date -d "@${now}" +%Y-%m-%d 2>/dev/null) || { printf 'unknown\x1f\n'; return 0; }
  base=$(date -d "${day} $(printf '%02d:%02d' "$hh" "$mm")" +%s 2>/dev/null)     || { printf 'unknown\x1f\n'; return 0; }
  for d in $(( base - 86400 )) "$base" $(( base + 86400 )); do
    local dist=$(( d > now ? d - now : now - d ))
    if (( bestd < 0 || dist < bestd )); then bestd="$dist"; best="$d"; fi
  done
  if (( best > now )); then printf 'live\x1f%s\n' "$best"
  else printf 'lapsed\x1f%s\n' "$best"; fi
}

# DIVE-3880: "2:10pm" / "14:10" for a reader, from the epoch above.
_sup_quota_deadline_hm() {  # <epoch>
  [[ "${1:-}" =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
  date -d "@$1" +%H:%M 2>/dev/null || printf '?'
}

# ── DIVE-4052 retires the DIVE-3940/3970 quota-mute apparatus ───────────────
# What used to live here: _sup_quota_selfheal (which refusal shapes resolve on
# their own), the persistence horizons, _sup_quota_escalate_after and
# _sup_quota_episode_first — the machinery that decided WHICH quota walls were
# benign enough to keep off lodar's phone, plus part 2's escape, which took the
# phone back once a muted wall outlived the reset it had promised.
#
# All of it answered one question — "is THIS quota wall worth a human's
# attention?" — and lodar's answer as of 2026-09-08 is that none of them are, on
# EITHER leg: a quota wall is what a subscription does, not an incident. A
# per-shape reading cannot beat that answer, so keeping it would be a decision
# procedure with nothing left to decide. _SUP_QUOTA_ALERTS_FLAG is now the whole
# policy for the class: absent, the audited row only; present, both legs,
# unfiltered — a debug mode that hides shapes from you is not a debug mode.
#
# Part 2 in particular was not merely redundant, it was WRONG. Measured
# 2026-09-08 ~16:45Z: main received "STILL WALLED 81h ... this is now a hard
# wall" about a seat whose own quoted pane said "continuing automatically at
# 5pm". mp-team is a shared profile that walls every 5h window, so the episode
# chain never breaks, the horizon expires, and the escalation fires on a wall
# that is self-healing exactly as designed. Retiring it removes a false claim,
# not a safety net. (_sup_quota_deadline SURVIVES — DIVE-3880 classification and
# the quota-lapsed disarm read it, and neither is about notification.)

# DIVE-3272: does this agent's live pane show a capacity refusal? Root-only (the
# sudo tmux hop) and running-service-only; anything else returns empty
# (false-negative bias, like every other probe here). Deliberately NOT
# claude-only — the incident seat was a qwen profile, and a quota wall is the one
# failure every runtime shares.
# The root tmux hop, split out from _sup_quota_pane (DIVE-3880 it.2) so the
# forwarding below is reachable from a unit test. Everything ungradable lives
# here — the EUID gate, the sudo, the capture — and it is the ONE thing a test
# stubs; before the split a stub had to replace _sup_quota_pane whole, which
# took the `now` argument out of the graded path with it (measured: dropping
# `"$now"` from the call below survived every arm).
_sup_quota_pane_capture() {  # <user> <sess> <svc_running>
  local user="$1" sess="$2" svc_running="$3"
  _sup_pane_gate "$svc_running" || return $?
  sudo -n -u "$user" tmux capture-pane -p -t "$sess" -S "-${_SUP_QUOTA_PANE_LINES}" 2>/dev/null \
    || return "$_SUP_PROBE_BLIND"
}

_sup_quota_pane() {  # <user> <sess> <svc_running> [now_epoch]
  local pane="" rc
  pane=$(_sup_quota_pane_capture "$1" "$2" "$3"); rc=$?
  (( rc == 0 )) || return "$rc"
  [[ -n "$pane" ]] || return "$_SUP_PROBE_BLIND"
  # DIVE-3880 it.2: `now` is forwarded because the SELECTION among several
  # matching lines is clock-dependent (a still-future deadline outranks the
  # newest line). Same tick clock the classifier is handed, never a second read.
  printf '%s\n' "$pane" | _sup_quota_match "${4:-}"
}

# DIVE-3272: the OUTPUT signal — the one thing no probe above measures, read from
# the store that was holding the answer the whole time, unread. Echoes
# "<open-rows>|<days-since-last-close>|<minutes-since-the-open-queue-last-moved>".
#
# Field 2 is -1 when this seat has never closed anything (unknown age => never
# classifies on its own, so a brand-new seat can't be flagged for having produced
# nothing yet).
#
# DIVE-4666 it.2 added FIELD 3, and it is the answer to a different question.
# Fields 1+2 say "this seat is holding work and has closed nothing" — which was
# TRUE of codex at 07:40Z on 2026-09-20 and yet paged a human about a seat that
# had picked a row up six minutes earlier and gated it. A close is a LAGGING
# signal by up to the whole length of a row; the queue's own clock is not.
#
# WHAT COUNTS AS MOVEMENT, and why one expression covers all three events the
# row asked for (start, deliver, gate):
#   start   COALESCE(first_started_at, started_at, created_at) — the attempt's
#           own clock. first_started_at FIRST on purpose: `started_at` is
#           re-stamped by every _hb_claim_task re-dispatch out of `todo`
#           (src/cmd_heartbeat.sh), so keying on it would let a seat that is
#           re-woken every 15 minutes and produces nothing look permanently
#           fresh — it would DISARM DIVE-3272 rather than qualify it. created_at
#           is the floor: a row that landed 5 minutes ago and was never claimed
#           is not evidence of darkness either.
#   deliver `_task_route_to_verifier` sets assignee=<verifier>, so a delivered
#           row LEAVES this seat's open set (src/task/delivery.sh).
#   gate    `task need` sets status='blocked', so a gated row leaves it too.
# So both of those are already handled structurally, by the `status IN` +
# `assignee=` filter this function has always carried, and neither needs a term.
#
# MAX, not MIN — the newest touch, not the oldest row. The claim the page makes
# is "this seat is not transacting", and the thing that refutes it is the seat
# having transacted RECENTLY; an ancient row sitting alongside a fresh one is
# already counted by field 2. (MIN would have paged codex exactly as before on
# any seat that also happened to hold one old row.)
#
# -1 on field 3 means UNKNOWN and leaves the drought decision exactly as
# DIVE-3272 shipped it. On this path that pairs only with open=0 — with open>0
# the MAX is over a COALESCE ending in a NOT NULL column, so it always resolves
# — but _sup_classify is also called by harnesses with the old 21-arg signature,
# and those must keep their pre-4666 answers.
_sup_output_stats() {  # <name>
  local name="$1" open last days=-1 moved move=-1
  open=$(db "SELECT COUNT(*) FROM tasks
             WHERE assignee=$(sqlq "$name") AND status IN ('todo','in_progress')
               AND kind='standard';" 2>/dev/null || echo 0)
  [[ "$open" =~ ^[0-9]+$ ]] || open=0
  # done_at stamps BOTH terminal states, and a cancel is output too — a decision
  # recorded is work done. Counting only status='done' would flag a seat that
  # spent the window legitimately triaging its queue to empty.
  last=$(db "SELECT CAST((julianday('now') - julianday(MAX(done_at))) AS INTEGER)
             FROM tasks WHERE assignee=$(sqlq "$name") AND done_at IS NOT NULL;" 2>/dev/null || echo "")
  [[ "$last" =~ ^[0-9]+$ ]] && days="$last"
  moved=$(db "SELECT CAST((julianday('now')
                - julianday(MAX(COALESCE(first_started_at, started_at, created_at)))) * 1440 AS INTEGER)
              FROM tasks WHERE assignee=$(sqlq "$name") AND status IN ('todo','in_progress')
                AND kind='standard';" 2>/dev/null || echo "")
  # A clock skew or a row stamped in the future reads negative; clamp to 0 so a
  # bad stamp cannot masquerade as the -1 that means "unknown".
  [[ "$moved" =~ ^-?[0-9]+$ ]] && { move="$moved"; (( move < 0 )) && move=0; }
  printf '%s|%s|%s\n' "$open" "$days" "$move"
}

# DIVE-4666 it.2: the drought decision itself, lifted OUT of the classifier's
# chain so it is assertable without composing a whole agent record — and so a
# mutant can be pointed at exactly the comparison this row added. Echoes
# true|false, in the same voice as _sup_capacity_notify_{human,machine}.
#
# BOTH terms are required: a close drought AND an open queue that has not moved.
# Either alone is a seat doing its job — a long close drought with fresh starts
# is a seat grinding hard work, and a stale queue with recent closes is a seat
# that just finished something.
_sup_output_drought() {  # <open_rows> <days_since_close> <mins_since_move> -> true|false
  local open="${1:-0}" days="${2:--1}" move="${3:--1}"
  [[ "$open" =~ ^[0-9]+$ ]]   || open=0
  [[ "$days" =~ ^-?[0-9]+$ ]] || days=-1
  [[ "$move" =~ ^-?[0-9]+$ ]] || move=-1
  (( open > 0 )) || { printf 'false'; return; }
  (( days >= 0 && days >= _SUP_T_NO_OUTPUT_DAYS )) || { printf 'false'; return; }
  # move < 0 is UNKNOWN, not fresh: an unmeasured queue clock must not silence a
  # measured three-day drought (that would be the absence-reads-as-health shape
  # this whole file exists to remove). It is unreachable with open>0 on the real
  # store read above; it is reachable from a 21-arg legacy call.
  (( move >= 0 && move < _SUP_T_NO_OUTPUT_IDLE_MIN )) && { printf 'false'; return; }
  printf 'true'
}

# DIVE-4666 it.2: a duration a person reads, for the detail line the page quotes.
_sup_ago_phrase() {  # <minutes>
  local m="${1:--1}"
  [[ "$m" =~ ^[0-9]+$ ]] || { printf ''; return; }
  if   (( m < 60 ));   then printf '%dm' "$m"
  elif (( m < 1440 )); then printf '%dh' $(( m / 60 ))
  else                      printf '%dd' $(( m / 1440 ))
  fi
}

# ── DIVE-3274: the same two facts, on the surface people actually type ────────
#
# DIVE-3272 taught the supervisor BOARD to see a seat that is up and closing
# nothing. `agent info` — the drill-down people actually type — kept printing
# only the systemd/registry LIVENESS label, so the defect survived there intact:
# a dark seat and a working one printed the same `state: active / enabled`. Four
# people trusted that line about dev3 for four days
# (community/wiki/every-signal-measured-liveness-none-measured-output.md).
#
# The two capacity classes are NOT equally measurable from this surface, and the
# overlay says which is which rather than flattening them into one confident
# label:
#
#   no-output        A PURE STORE READ. `info` re-runs _sup_output_stats itself,
#                    so this half is MEASURED at print time — it holds on a box
#                    where the tick has never run, and it cannot go stale.
#   quota-exhausted  Needs a root `tmux capture-pane` hop. `info` is read-only
#                    and runs as any seat (ensure_state_ro), so it must not grow
#                    one; this half is INHERITED from the event trail. It is
#                    therefore printed WITH its age and the tick's arm state and
#                    never as a bare classification — an unmeasured branch has
#                    to say less than the measured one (DIVE-2793), and an
#                    unarmed monitor otherwise prints exactly what a quiet one
#                    prints (DIVE-2306). That is the same defect one level up:
#                    silence from an instrument nobody armed reading as an
#                    all-clear is how this class hides in the first place.
#
# Freshness is decided by COMPARING the agent's newest row against the newest
# fleet heartbeat, not by a wall-clock guess: the tick writes an `observe` row
# EVERY tick for every non-healthy class (see cmd_supervisor_tick), so an agent
# whose newest row predates the newest heartbeat was looked at and found
# healthy. No row at all + no heartbeat at all is `unobserved`, which is a third
# value on purpose — it must not read as either healthy or dry.
# How long before the OBSERVER ITSELF is stale. `healthy` derived from a tick
# that stopped running is the absence-reads-as-health shape this row exists to
# remove (main, at the DIVE-3274 push approval), so past this bound the overlay
# reports `unobserved` and names the age: the recorded reading is not refuted,
# it is simply no longer current, and a surface that cannot tell those apart is
# the defect. 1h is 6x the shipped `*/10` cron. Env-overridable in the house
# style because `info` CANNOT see the cron that drives the tick — a box on a
# slower schedule would otherwise read `unobserved` forever, which is honest but
# useless, and the knob is cheaper than a wrong constant.
_SUP_INFO_TICK_STALE="${SUPERVISOR_INFO_TICK_STALE_SECS:-3600}"
[[ "$_SUP_INFO_TICK_STALE" =~ ^[0-9]+$ ]] || _SUP_INFO_TICK_STALE=3600
_SUP_INFO_TICK_TOL=120   # seconds. Per-agent rows are written BEFORE the fleet
                         # heartbeat that closes the tick, so a row from the SAME
                         # tick carries an EARLIER ts (measured: 1s). Without a
                         # tolerance every current row would read as stale. Kept
                         # well under the shortest sane tick interval so a row
                         # from the PREVIOUS tick can never read as current.

# Pure render of the `agent info` supervisor overlay — NO I/O, so a test can
# assert every branch without a store, a tick or a tmux (same factoring as
# _sup_classify / _sup_act_plan). Echoes one compact JSON object.
# DIVE-3880 reads a clock through _sup_quota_deadline, which takes `now` as an
# ARGUMENT (never `date +%s` internally) — so every deadline arm is still
# assertable at a fixed epoch and the renderer stays deterministic in its args.
# args: armed(true/false) tick_epoch row_epoch now
#       rec_class rec_cause rec_detail open_rows days_since_close(-1 = never)
#       store_readable(true/false) account_wall(empty unless AT the wall now)
#       move_mins(minutes since the open queue last moved; -1 = not measured)
_sup_info_status() {
  local armed="$1" tick="${2:-0}" row="${3:-0}" now="${4:-0}" \
        rc="${5:-}" rcause="${6:-}" rdetail="${7:-}" open="${8:-0}" days="${9:--1}" \
        store="${10:-true}" wall="${11:-}" move="${12:--1}"
  [[ "$store" == "false" ]] || store="true"
  [[ "$move" =~ ^-?[0-9]+$ ]] || move=-1
  [[ "$tick" =~ ^[0-9]+$ ]] || tick=0
  [[ "$row"  =~ ^[0-9]+$ ]] || row=0
  [[ "$now"  =~ ^[0-9]+$ ]] || now=0
  [[ "$open" =~ ^[0-9]+$ ]] || open=0
  [[ "$days" =~ ^-?[0-9]+$ ]] || days=-1
  [[ "$armed" == "true" ]] || armed="false"

  # --- the half this surface MEASURES for itself, at print time ---------------
  # The PAIR is the detector; neither number means anything alone (0 open rows
  # and no closes is a correctly idle seat, 20 open rows and a close this
  # morning is a busy one), which is why each branch below reports both.
  local output transacting note
  if [[ "$store" != "true" ]]; then
    # NOTHING was read. This branch exists because its absence was the same bug
    # one level down: with the store unreadable the counters fall back to
    # 0-open/never-closed, which renders as the perfectly benign "no open rows,
    # nothing ever closed" — a measurement this surface did not take, printed in
    # the voice of one it did. Caught end-to-end on a TASKS_DB pointed at a
    # missing path, not by reading the code.
    output="unmeasured"; transacting="null"
    note="the task store was not readable from here — NOTHING was measured (not a clear)"
  elif (( days < 0 )); then
    # Never closed anything. Must read unknown, not infinitely dry, or every
    # newly created agent is flagged on day one and the alarm is trained out of
    # the fleet inside a week (DIVE-3272).
    output="unknown"; transacting="null"
    if (( open > 0 )); then
      note="${open} open row(s) and has NEVER closed anything — a new seat and a dark one read the same here"
    else
      note="no open rows, nothing ever closed"
    fi
  elif (( days < _SUP_T_NO_OUTPUT_DAYS )); then
    output="ok"; transacting="true"
    note="${open} open row(s), last close ${days}d ago"
  elif (( open == 0 )); then
    output="idle"; transacting="null"
    note="no open rows, last close ${days}d ago — correctly idle, not dry"
  elif [[ "$(_sup_output_drought "$open" "$days" "$move")" != "true" ]]; then
    # DIVE-4666 it.2: SURFACE PARITY. `dry / transacting:false` is the same
    # claim the tick pages on, and this surface is the drill-down a person opens
    # when the page arrives — so it must not go on saying "not transacting"
    # about a seat the tick has just stopped paging for. Reached only when the
    # queue clock was MEASURED and is fresh (an unmeasured one is -1, which
    # _sup_output_drought reads as unknown and lets fall through to `dry`
    # exactly as it did pre-4666, so every 11-arg caller is unchanged).
    output="ok"; transacting="true"
    note="${open} open row(s), last close ${days}d ago — but the newest was picked up $(_sup_ago_phrase "$move") ago, so this seat is moving"
  else
    output="dry"; transacting="false"
    note="${open} open row(s), nothing closed in ${days}d"
    (( move >= 0 )) && note="${note}, nothing picked up in $(_sup_ago_phrase "$move")"
  fi

  # --- the half it INHERITS from the trail ------------------------------------
  local cls="$rc" cause="$rcause" detail="$rdetail" current=false
  (( row > 0 && tick > 0 && row + _SUP_INFO_TICK_TOL >= tick )) && current=true
  if [[ "$store" != "true" ]]; then
    cls="unobserved"; cause=""; detail=""; current=false
  elif [[ "$armed" != "true" ]]; then
    # The flag gates the whole tick. Whatever sits in the trail is not being
    # refreshed, so it cannot be quoted as a current reading at any age.
    cls="unobserved"; cause=""; detail=""
  elif (( tick > 0 && now > tick && now - tick > _SUP_INFO_TICK_STALE )); then
    # The observer itself has stopped. Whatever the trail says — including
    # nothing — is a reading from a dead instrument, so it cannot be forwarded as
    # either a class or a clear.
    cls="unobserved"; cause=""; detail=""; current=false
  elif [[ "$current" != "true" ]]; then
    # The newest tick looked at this agent and wrote no row. The tick writes an
    # `observe` row EVERY tick for EVERY non-healthy class, so that silence is a
    # positive reading and not an absence.
    if (( tick > 0 )); then cls="healthy"; cause=""; detail=""
    else cls="unobserved"; cause=""; detail=""; fi
  fi
  [[ -n "$cls" ]] || cls="unobserved"

  # --- DIVE-3880: the inherited quota class carries its OWN expiry ------------
  # This is the measured defect. The tick reads the pane; `info` reads the tick.
  # Between the two, the refusal's own resume deadline can pass — and a pane
  # goes on rendering a lapsed refusal, so the recorded reading was true when
  # written and is false now. Recency-vs-the-tick cannot catch it (the row IS
  # current: ops was flagged at 14:17 off a 14:10 expiry, mid-command). The
  # discriminator is in the detail string already being carried, and it is
  # re-evaluated HERE, at print time, against this call's `now` — the same
  # reason the output half is recomputed here instead of inherited.
  local qdl_state="" qdl_epoch=""
  if [[ "$cls" == "quota-exhausted" ]]; then
    IFS=$'\x1f' read -r qdl_state qdl_epoch <<<"$(_sup_quota_deadline "$detail" "$now")"
    if [[ "$qdl_state" == "lapsed" ]]; then
      # NOT a clear and NOT the alarm: a third value. The seat resumed at the
      # deadline the refusal itself printed, so this class must stop instructing
      # anyone to reassign a queue — but the reading is still shown, because
      # "we read a refusal" and "it still holds" are different facts.
      cls="quota-lapsed"; cause="deadline-passed"
      detail="the pane refusal this rests on EXPIRED at $(_sup_quota_deadline_hm "$qdl_epoch") — it is scrollback, not a live wall, and the seat has resumed since: ${detail}"
    fi
  fi

  # --- the escalation: what the state line may NOT omit -----------------------
  # Only the "up and reachable but not transacting" classes. A `stuck` seat is
  # already visible in `state:` itself (the unit is down); these three are the
  # ones every liveness signal reads green through.
  local verdict=""
  case "$cls" in quota-exhausted|verify-challenge|no-output) verdict="$cls" ;; esac
  [[ -z "$verdict" && "$output" == "dry" ]] && verdict="no-output"

  # DIVE-4342: the account wall is MEASURED here, like `output`, and owes nothing
  # to the tick. That is the whole point — on the box this was reported from the
  # tick was not armed, every inherited class was therefore `unobserved`, and
  # this surface still printed a seat that could not spend a token as healthy.
  # It overrides the inherited class in BOTH directions: it beats a green one,
  # and it beats a `quota-lapsed` downgrade, because a pane refusal whose
  # deadline has passed says nothing about an account measured at 101% now.
  if [[ -n "$wall" ]]; then
    cls="quota-exhausted"; cause="account-usage"; detail="$wall"; verdict="quota-exhausted"
  fi

  local state_note sup_line
  case "$verdict" in
    "") case "$output" in
          # A historical close is evidence of recent output, not proof of what
          # the seat is doing now. DIVE-4032 observed this line claim
          # "transacting" after 2.2 days with no runtime sessions at all.
          ok)         state_note="output recent (last close ${days}d ago)" ;;
          idle)       state_note="idle — no open rows (last close ${days}d ago)" ;;
          unmeasured) state_note="output UNMEASURED — task store unreadable from here" ;;
          *)          state_note="output unknown — ${note}" ;;
        esac ;;
    no-output) state_note="⚠ NOT TRANSACTING (no-output: ${note})" ;;
    *)         state_note="⚠ NOT TRANSACTING (${cls}${detail:+: ${detail}})" ;;
  esac
  # DIVE-3880: when the alarm was dropped for a lapsed deadline, say so on the
  # SAME line that would otherwise have carried it. A silently-downgraded alarm
  # and a seat that was never flagged must not print identically — that is the
  # same absence-reads-as-health shape this overlay exists to remove.
  [[ "$cls" == "quota-lapsed" ]] \
    && state_note="${state_note} · the pane's quota refusal LAPSED at $(_sup_quota_deadline_hm "$qdl_epoch") (stale scrollback — NOT a not-transacting reading)"

  local age_s=$(( now > row && row > 0 ? now - row : -1 ))
  local tick_age_s=$(( now > tick && tick > 0 ? now - tick : -1 ))
  if [[ -n "$wall" ]]; then
    # Deliberately FIRST: the three branches below all describe how fresh the
    # TICK is, and this reading did not come from the tick.
    sup_line="quota-exhausted / account-usage — ${wall} (measured from the account-usage snapshot, not from the supervisor tick)"
  elif [[ "$store" != "true" ]]; then
    sup_line="unobserved — the task store was not readable from here, so NEITHER the event trail nor the output counters were read (this is not an all-clear)"
  elif [[ "$armed" != "true" ]]; then
    sup_line="unobserved — the tick is NOT ARMED on this box, so nothing refreshes this"
    sup_line="${sup_line} (enable: sudo touch ${_SUP_ENABLED_FLAG})"
  elif (( tick > 0 && now > tick && now - tick > _SUP_INFO_TICK_STALE )); then
    sup_line="unobserved — the last supervisor tick completed $(_sup_info_ago "$tick_age_s") ago and nothing has refreshed this since"
    (( row > 0 )) && sup_line="${sup_line}; newest recorded row for this agent: ${rc:-none} ($(_sup_info_ago "$age_s") ago)"
  elif (( tick > 0 )); then
    sup_line="${cls}${cause:+ / ${cause}}${detail:+ — ${detail}}"
    sup_line="${sup_line} (tick $(_sup_info_ago "$tick_age_s") ago)"
  else
    sup_line="unobserved — armed, but no tick has completed yet on this box"
  fi

  jq -cn \
    --arg cls "$cls" --arg cause "$cause" --arg detail "$detail" \
    --arg output "$output" --arg note "$note" --arg verdict "$verdict" \
    --arg qdl "$qdl_state" \
    --arg stateNote "$state_note" --arg supLine "$sup_line" \
    --argjson armed "$armed" --argjson current "$current" --argjson store "$store" \
    --argjson transacting "$transacting" \
    --argjson open "$open" --argjson days "$days" \
    --argjson thresh "$_SUP_T_NO_OUTPUT_DAYS" \
    --argjson age "$age_s" --argjson tickAge "$tick_age_s" \
    '{
       # MEASURED here, every call, with no dependency on the tick.
       # "unmeasured" is a FOURTH output value and is never folded into one of
       # the other three: an unread store must not print in the voice of a read
       # one.
       storeReadable: $store,
       output: $output,
       transacting: $transacting,          # null == unknown, never false
       openRows: $open,
       daysSinceClose: (if $days < 0 then null else $days end),
       thresholdDays: $thresh,
       # INHERITED from the trail — only as fresh as the tick that wrote it.
       classification: $cls,
       # DIVE-3880: live / lapsed / unknown, re-derived at print time from the
       # deadline the refusal itself printed. null when the inherited class is
       # not a quota reading at all. `unknown` is an ABSTENTION — it is never
       # read as either of the other two.
       quotaDeadline: (if $qdl == "" then null else $qdl end),
       cause: (if $cause == "" then null else $cause end),
       detail: (if $detail == "" then null else $detail end),
       observedAgeSec: (if $age < 0 then null else $age end),
       tickArmed: $armed,
       tickAgeSec: (if $tickAge < 0 then null else $tickAge end),
       fromCurrentTick: $current,
       # The two rendered strings `agent info` prints, so the phrasing is
       # asserted by the unit test and not re-derived in a jq program.
       verdict: (if $verdict == "" then null else $verdict end),
       stateNote: $stateNote,
       line: $supLine,
       note: $note
     }'
}

# "4d" / "3h" / "12m" / "45s" — an age a reader can act on without doing
# arithmetic. -1 (unknown) prints "?".
_sup_info_ago() {
  local s="${1:--1}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
  if   (( s >= 86400 )); then printf '%dd' $(( s / 86400 ))
  elif (( s >= 3600 ));  then printf '%dh' $(( s / 3600 ))
  elif (( s >= 60 ));    then printf '%dm' $(( s / 60 ))
  else                        printf '%ds' "$s"; fi
}

# I/O half: gather this agent's overlay from the store + the arm flag, then hand
# the numbers to the pure renderer. Best-effort by construction — every read is
# guarded and an unreadable store degrades to `unobserved` + `output unknown`,
# never to a confident all-clear and never to a failed `agent info`.
sup_info_for_agent() {  # <name>
  local name="$1" armed="false" tick=0 row=0 now rc="" rcause="" rdetail="" open=0 days=-1 \
        move=-1 store="false"
  now=$(date +%s)
  [[ -f "$_SUP_ENABLED_FLAG" ]] && armed="true"
  # A store this seat cannot read is NOT zero rows and no closes. Probe it with
  # a query that has a known-nonempty answer on any initialised store, so the
  # difference between "read it, nothing there" and "never read it" survives to
  # the renderer instead of collapsing into the benign-looking default.
  [[ -s "$TASKS_DB" ]] \
    && [[ "$(db "SELECT 1 FROM sqlite_master WHERE type='table' AND name='tasks' LIMIT 1;" 2>/dev/null || echo "")" == "1" ]] \
    && store="true"
  if [[ "$store" == "true" ]]; then
    # DIVE-4666 it.2: three fields, read positionally — see _sup_agent_record.
    local ostats; ostats=$(_sup_output_stats "$name" 2>/dev/null || echo "0|-1|-1")
    IFS='|' read -r open days move <<<"$ostats"
    tick=$(db "SELECT COALESCE(strftime('%s', MAX(ts)), 0) FROM supervisor_events
               WHERE agent='(fleet)' AND event='heartbeat';" 2>/dev/null || echo 0)
    local r
    r=$(db "SELECT COALESCE(strftime('%s', ts), 0) || char(31) || classification
                   || char(31) || COALESCE(cause,'') || char(31)
                   || COALESCE(json_extract(signals, '\$.detail'), '')
            FROM supervisor_events WHERE agent=$(sqlq "$name")
            ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    IFS=$'\x1f' read -r row rc rcause rdetail <<<"$r"
  fi
  # DIVE-4342: seat -> auth profile -> account usage, read unprivileged from the
  # published snapshot. Empty unless the account is AT the wall right now.
  local wall="" w_state w_win w_pct w_reset w_age w_note
  if declare -f quota_wall_seat >/dev/null 2>&1; then
    IFS=$'\037' read -r w_state w_win w_pct w_reset w_age w_note <<<"$(quota_wall_seat "$name")"
    [[ "$w_state" == "exhausted" ]] && wall="$(quota_wall_phrase "$w_win" "$w_pct" "$w_reset")"
  fi
  _sup_info_status "$armed" "$tick" "$row" "$now" "$rc" "$rcause" "$rdetail" "$open" "$days" "$store" "$wall" "$move"
}

# ── DIVE-4551: WHO RECEIVES A FLEET-HEALTH ALERT ────────────────────────────
#
# Every alert below used to name `main` literally, on BOTH legs, in all three
# rails. `main` is a seat that exists on exactly one box in the world — ours.
# Reported from a customer box (teal-fox, 5dive 0.40.0, 2026-09-15) whose org
# roots are claude-aleks / claude-alena / claude-jane: `agent send main` failed
# with "no agent named 'main'" and `_task_agent_channel main` was false, so both
# legs dropped and the ONLY trace of a seat sitting on an open row with nothing
# closed in 32 days was a warn line in a cron log nobody reads. That is the
# DIVE-3272 blind spot reproduced one level up: the cover for it existed and was
# addressed to a name that does not resolve.
#
# WHY THE NOTIFIER AND NOT THE COORDINATOR. The row proposed
# `_task_resolve_coordinator` for both legs. Measured on this box before writing
# it: that resolver returns **olivia** (the lone org root, the advisory CEO), not
# main — main is tagged `gate notifier` (DIVE-4365). So the literal proposal
# would have re-routed every fleet-health alert HERE from the CTO who co-owns the
# D4 runbook these messages cite onto a seat that does not run it, which is a
# regression dressed as a fix. `_task_resolve_gate_notifier` is the resolver
# whose JOB is "which seat pages a person about fleet state", and it FALLS BACK
# to `_task_resolve_coordinator`, so on an untagged customer chart with one root
# it resolves exactly what the row asked for (claude-aleks) and on this box it
# resolves `main` — byte-identical here, fixed there. It also gives the customer
# the narrow override the row wanted without inventing a config key: tagging
# a seat `gate notifier` moves the alerts alone, where tagging one `coordinator`
# would also dump every unassigned row and every default plan on them (the six
# call sites named in the DIVE-4365 note above _task_resolve_gate_notifier).
#
# ONE resolver for BOTH legs, deliberately: the a2a and the DM must land on the
# same seat or the reply arrives in a chat that holds none of the context —
# measured on DIVE-4359 and the reason the notifier knob exists at all.
_sup_alert_recipient() {  # -> seat name, or empty when nothing resolves
  declare -F _task_resolve_gate_notifier >/dev/null 2>&1 || return 0
  _task_resolve_gate_notifier 2>/dev/null || true
}

# An undeliverable alert must not be a `warn` that scrolls away — that IS the
# incident. The tick still never aborts (DIVE-1127 design), so the escape is an
# audited row of its own: queryable after the fact, counted in the tick summary,
# and read by `5dive doctor` (supervisor-alert-delivery) so the box says out loud
# that its fleet watcher cannot reach anyone. Deliberately a SECOND row rather
# than a field on the 'alert' row: the alert fired and is real either way, and a
# reader filtering `event='alert'` must keep seeing it.
#
# <reason> is one of: no-coordinator (nothing resolves), send-failed (the a2a
# rail refused), no-channel (the resolved seat has no paired Telegram channel —
# the leg that was a silent `if` with no else before this row).
_SUP_ALERTS_UNDELIVERABLE=0
# DIVE-4666: capacity pages withheld this tick because the seat is on a known,
# self-healing wall. Counted, so "quiet" is a number and not an absence.
_SUP_ALERTS_QUIETED=0
_sup_alert_undeliverable() {  # <name> <class> <leg> <reason> [recipient]
  local name="$1" class="$2" leg="$3" reason="$4" to="${5:-}" sig
  _SUP_ALERTS_UNDELIVERABLE=$(( _SUP_ALERTS_UNDELIVERABLE + 1 ))
  sig=$(jq -nc --arg l "$leg" --arg r "$reason" --arg to "$to" \
          '{leg:$l, reason:$r, recipient:(if $to == "" then null else $to end)}' 2>/dev/null \
        || printf '{"leg":"%s","reason":"%s"}' "$leg" "$reason")
  # The SUBSHELL is load-bearing, not style: `db` fences the store and a fenced
  # or missing store makes it `fail`, which EXITS. An alert-delivery failure
  # taking the whole tick down with it would be the DIVE-1127 rule inverted by
  # the very code written to honour it. The count above is bumped first and in
  # THIS shell, so the summary line still reports a leg the audit row lost.
  ( db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
        VALUES ($(sqlq "$name"), 'alert-undeliverable', $(sqlq "$class"),
                $(sqlq "$reason"), $(sqlq "$sig"));" ) >/dev/null 2>&1 || true
}

# Both legs of every alert rail, in one place. Best-effort by construction: a
# wedged channel, a missing seat or an empty org chart must never abort the tick
# for the rest of the fleet (DIVE-1127) — it must only be IMPOSSIBLE to lose
# silently. A muted leg (DIVE-3982 / DIVE-4052) is not undeliverable and is not
# counted: nobody asked for it to be delivered.
_sup_alert_deliver() {  # <rail> <name> <class> <msg> [notify_human=true] [notify_machine=true]
  local rail="$1" name="$2" class="$3" msg="$4" \
        notify_human="${5:-true}" notify_machine="${6:-true}" to
  to=$(_sup_alert_recipient)
  if [[ -z "$to" ]]; then
    warn "${rail}: UNDELIVERABLE for $name — no alert recipient resolves on this box (alert still audited); fix: give the org chart ONE root (5dive org set <agent> --manager=<mgr>), or tag a seat (5dive org set <agent> --role='<their prose> gate notifier')"
    if [[ "$notify_machine" == "true" ]]; then
      _sup_alert_undeliverable "$name" "$class" machine no-coordinator ""
    fi
    if [[ "$notify_human" == "true" ]]; then
      _sup_alert_undeliverable "$name" "$class" human no-coordinator ""
    fi
    return 0
  fi
  # DIVE-3318: a one-way machine notice nobody replies to is not a round — see
  # a2a_round_guard. NOT a sender exemption; never set this by hand.
  if [[ "$notify_machine" == "true" ]]; then
    if ! _5DIVE_A2A_NOTIFY=1 5dive agent send "$to" "$msg" >/dev/null 2>&1; then
      warn "${rail}: 'agent send ${to}' failed for $name (alert still audited)"
      _sup_alert_undeliverable "$name" "$class" machine send-failed "$to"
    fi
  fi
  # lodar is a human, not an agent — reached through the notifier seat's paired
  # channel. A seat that resolves but carries no channel used to be a silent
  # skip; it is now audited like any other lost leg.
  if [[ "$notify_human" == "true" ]]; then
    if _task_agent_channel "$to"; then
      _task_send_owner "$msg" >/dev/null 2>&1 || true
    else
      warn "${rail}: no paired channel on '${to}' for $name (alert still audited)"
      _sup_alert_undeliverable "$name" "$class" human no-channel "$to"
    fi
  fi
}

# DIVE-3272: a seat that cannot transact is a FLEET-health event. The entire cost
# of the incident was the 20 rows queued behind a seat nobody knew was dark, so
# the alert leads with that and not with the seat's own symptom. Same delivery
# shape as _sup_verify_alert — both legs best-effort, because one wedged channel
# must never abort the tick for the rest of the fleet — and the caller owns the
# dedup window.
_sup_capacity_alert() {  # <name> <class> <detail> [notify_human=true] [notify_machine=true] [wall_state=none] [reset_epoch] [queue]
  local name="$1" class="$2" detail="$3" notify_human="${4:-true}" notify_machine="${5:-true}" \
        wall_state="${6:-none}" reset="${7:-}" queue="${8:-}"
  # DIVE-4666 item 3: the closing sentence is built, not literal — it names the
  # reset in human time (never the provider's epoch) and the rows actually
  # queued behind the seat. Every existing caller that passes neither gets the
  # old sentence back, minus the epoch, which no reader could use anyway.
  local msg="[FLEET-HEALTH ${class}] agent '${name}' is UP and REACHABLE but NOT TRANSACTING: ${detail}. Every liveness signal (unit / tmux / poller / registry label) reads healthy — that agreement is the DIVE-3272 defect, not evidence against this alert. $(_sup_capacity_tail "$name" "$wall_state" "$reset" "$queue")"
  # DIVE-4052: the MACHINE leg is suppressible too, and for quota-exhausted that
  # is the bigger of the two costs. This send lands in main's ACCUMULATING
  # session, where each one is a turn that re-sends the whole window — measured
  # on supervisor_events: 47 quota-exhausted alerts in the 7 days to 2026-09-08.
  # Both parameters default TRUE, so every existing caller and every other class
  # is byte-for-byte unchanged; only the quota path passes false. What is NOT
  # suppressible is the caller's audited supervisor_events row: the DIVE-3272
  # blind-spot cover is a RECORD you can query after the fact, not a ping, and
  # muting a notification must never cost the record.
  #
  # DIVE-3318: a one-way machine notice nobody replies to is not a round — see
  # a2a_round_guard. NOT a sender exemption; never set this by hand.
  # DIVE-4551: both legs go to the RESOLVED recipient, and a leg that cannot be
  # delivered is audited rather than warned into a log nobody reads.
  _sup_alert_deliver capacity-alert "$name" "$class" "$msg" "$notify_human" "$notify_machine"
}

# ── DIVE-4666: A KNOWN COOLDOWN IS NOT AN INCIDENT ──────────────────────────
#
# 2026-09-20 07:00:33Z a FLEET-HEALTH page for `olivia` reached a human. The
# supervisor had measured — four minutes earlier, and on six ticks in the two
# hours before that — that the seat's auth account was AT its 5h wall and WHEN
# it came back. The page dropped both facts and asked the reader to "check the
# seat's model capacity (auth-profile, quota reset)", which is the one thing it
# had just measured. lodar, on his phone: "olivia is just on 5h usage limit
# cooldown - not worth the alert".
#
# WHY IT ESCAPED THE TWO MUTES THAT ALREADY EXIST. DIVE-4052 mutes
# `quota-exhausted` on both legs; DIVE-3982 mutes `no-output`'s human leg. On
# paper this state was covered twice. The alert that fired was class
# `no-output`, whose MACHINE leg is deliberately live (its remedy genuinely is
# main's triage) — and it fired because the CLASSIFICATION oscillates tick to
# tick while one single wall stands. Measured on supervisor_events for olivia,
# 2026-09-20 (ts | classification | cause):
#
#   04:50–06:20  quota-exhausted / account-usage   fresh account reading
#   05:30, 06:30 healthy                           the reading aged past 600s
#   07:00        no-output / no-output  -> ALERT   still no fresh reading, so the
#                                                  3-day drought the wall CAUSED
#                                                  became the most specific branch
#   07:10        quota-exhausted / account-usage   a fresh reading again
#
# The account-usage branch is gated on a reading measured within 600s and the
# snapshot publisher's cadence is longer than that, so the wall signal BLINKS.
# Every mute in this file keys on THIS TICK'S CLASS, so one blink lands the
# fleet on the single class nobody muted. That is cause 5 of
# `a-stalled-signal-is-true-and-names-no-cause`: the detector's window is
# shorter than the lane's cadence.
#
# So the gate below keys on the SEAT'S KNOWN WALL, not on the class of the
# tick. A DELIBERATE DEVIATION from the row's literal text ("a supervisor
# verdict of quota-exhausted with a reset in the FUTURE"), written because the
# literal version keys on the class and would NOT have suppressed the page that
# caused the row.
#
# NOT GATED, on purpose: `verify-challenge` (account state only a person can
# clear) and `blocked-on-prompt` — neither reaches these functions, they have
# their own senders. And the audited supervisor_events row is filed either way:
# muting a notification must never cost the record (DIVE-4052).

# The tick cadence, used only as the one-tick grace below. Not a threshold to
# tune: it answers "could the seat plausibly have resumed yet".
_SUP_TICK_SEC="${SUPERVISOR_TICK_SEC:-600}"
[[ "$_SUP_TICK_SEC" =~ ^[0-9]+$ ]] || _SUP_TICK_SEC=600

# PURE. <reset_epoch> <now_epoch> [tick_sec] -> cooling | lapsed | none
#
# `none` is the NO-KNOWLEDGE answer and restores the pre-4666 policy exactly: an
# empty or unparseable reset can never quieten anything. The false-negative bias
# every threshold in this file carries — an unknown wall pages.
_sup_wall_verdict() {
  local reset="${1:-}" now="${2:-}" tick="${3:-${_SUP_TICK_SEC:-600}}"
  [[ "$reset" =~ ^[0-9]+$ ]] || { printf 'none'; return 0; }
  [[ "$now"   =~ ^[0-9]+$ ]] || now=$(date +%s)
  [[ "$tick"  =~ ^[0-9]+$ ]] || tick=600
  (( now <= reset )) && { printf 'cooling'; return 0; }
  # ONE TICK OF GRACE, which the row asked for by name. A seat does not resume
  # on the second its wall lifts — it resumes on the next dispatch. Paging at
  # reset+1s would page every wall on this box, once, forever.
  (( now - reset <= tick )) && { printf 'cooling'; return 0; }
  printf 'lapsed'
}

# PURE. <text> [now_epoch] -> reset epoch | empty
#
# The reset out of a detail string, in the three shapes this file produces:
#   * `... — resets <epoch>`       the account snapshot's own stamp (s or ms),
#                                   and every audited row written before 4666
#   * `... — resets 08:50Z` /
#     `... — resets Sep 21 08:50Z` what quota_wall_when renders from 4666 on
#   * the vendor banner's clock     parsed by the ONE parser that already
#                                   resolves it (_sup_quota_deadline), never a
#                                   third regex for the same sentence
#
# Our own `HH:MMZ` form is read HERE rather than through _sup_quota_deadline,
# whose regexes correctly refuse a bare meridiem-less clock: on a VENDOR BANNER
# "at 8:50" is 08:50 or 20:50 and guessing invents the answer, but in a string
# this file rendered itself the Z is explicit and there is nothing to guess.
_sup_wall_reset_of() {
  local text="${1:-}" now="${2:-}" st ep hh mm day base best="" bestd=-1 d
  [[ -n "$text" ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  if [[ "$text" =~ resets?[[:space:]]+([0-9]{13})([^0-9]|$) ]]; then
    printf '%s' $(( 10#${BASH_REMATCH[1]} / 1000 )); return 0
  fi
  if [[ "$text" =~ resets?[[:space:]]+([0-9]{9,11})([^0-9]|$) ]]; then
    printf '%s' $(( 10#${BASH_REMATCH[1]} )); return 0
  fi
  # `resets Sep 21 08:50Z` — fully qualified, so resolve it directly. The YEAR
  # is the current one: a wall never resets more than 7 days out, so the only
  # input this is wrong on is one straddling New Year, and it is wrong in the
  # LOUD direction (a stale-looking reset reads `lapsed`, which pages).
  if [[ "$text" =~ resets?[[:space:]]+([A-Z][a-z]{2})[[:space:]]+([0-9]{1,2})[[:space:]]+([0-9]{2}):([0-9]{2})Z ]]; then
    d=$(date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} $(date -u -d "@${now}" +%Y) ${BASH_REMATCH[3]}:${BASH_REMATCH[4]} UTC" +%s 2>/dev/null) || d=""
    [[ "$d" =~ ^[0-9]+$ ]] && { printf '%s' "$d"; return 0; }
    return 0
  fi
  # `resets 08:50Z` — a bare clock, resolved to the NEAREST day, the same
  # yesterday/today/tomorrow arithmetic _sup_clock_state uses on the banner.
  if [[ "$text" =~ resets?[[:space:]]+([0-9]{2}):([0-9]{2})Z ]]; then
    hh="${BASH_REMATCH[1]}"; mm="${BASH_REMATCH[2]}"
    day=$(date -u -d "@${now}" +%Y-%m-%d 2>/dev/null) || return 0
    base=$(date -u -d "${day} ${hh}:${mm} UTC" +%s 2>/dev/null) || return 0
    for d in $(( base - 86400 )) "$base" $(( base + 86400 )); do
      local dist=$(( d > now ? d - now : now - d ))
      if (( bestd < 0 || dist < bestd )); then bestd="$dist"; best="$d"; fi
    done
    printf '%s' "$best"; return 0
  fi
  IFS=$'\x1f' read -r st ep <<<"$(_sup_quota_deadline "$text" "$now")"
  [[ "$st" == "live" || "$st" == "lapsed" ]] && [[ "$ep" =~ ^[0-9]+$ ]] && printf '%s' "$ep"
  return 0
}

# I/O. <name> [now_epoch] -> "<verdict>\x1f<reset epoch or empty>"
#
# The live snapshot first, then the AUDITED ROWS — and the audited rows are the
# whole point: they are what survives the blink. A tick that cannot see a fresh
# reading still sees the six rows the last two hours wrote.
_sup_wall_state() {
  local name="${1:-}" now="${2:-}" w_state w_win w_pct w_reset w_age w_note e rows d
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  [[ -n "$name" ]] || { printf 'none\x1f\n'; return 0; }
  if declare -f quota_wall_seat >/dev/null 2>&1; then
    IFS=$'\037' read -r w_state w_win w_pct w_reset w_age w_note <<<"$(quota_wall_seat "$name" 2>/dev/null)"
    if [[ "$w_state" == "exhausted" && -n "$w_reset" ]]; then
      e=$(_sup_wall_reset_of "resets ${w_reset}" "$now")
      [[ -n "$e" ]] && { printf '%s\x1f%s\n' "$(_sup_wall_verdict "$e" "$now")" "$e"; return 0; }
    fi
  fi
  # The SUBSHELL is load-bearing for the same reason it is in
  # _sup_alert_undeliverable: `db` fences the store and a fenced store makes it
  # `fail`, which EXITS. Deciding whether to quieten an alert must never take
  # the tick down — and an unreadable store answers `none`, which PAGES.
  rows=$( db "SELECT COALESCE(json_extract(signals, '\$.detail'), '')
              FROM supervisor_events
              WHERE agent=$(sqlq "$name")
                AND event IN ('observe','transition','alert')
                AND classification='quota-exhausted'
                AND ts >= datetime('now', '-${_SUP_ALERT_WINDOW_H} hours')
              ORDER BY id DESC LIMIT 24;" 2>/dev/null ) || rows=""
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    e=$(_sup_wall_reset_of "$d" "$now")
    [[ -n "$e" ]] && { printf '%s\x1f%s\n' "$(_sup_wall_verdict "$e" "$now")" "$e"; return 0; }
  done <<<"$rows"
  printf 'none\x1f\n'
}

# I/O. <name> -> "DIVE-1, DIVE-2 (+3 more)" | empty
#
# DIVE-4666 item 3: the page names the queue instead of telling the reader to go
# look it up. The whole cost of the DIVE-3272 incident was the rows stranded
# behind a dark seat, so the alert that exists for it may as well carry them.
_sup_queue_behind() {
  local name="${1:-}" ids n extra
  [[ -n "$name" ]] || return 0
  ids=$( db "SELECT GROUP_CONCAT(ident, ', ') FROM (
               SELECT ident FROM tasks
               WHERE assignee=$(sqlq "$name") AND status IN ('todo','in_progress')
               ORDER BY id LIMIT 5);" 2>/dev/null ) || ids=""
  [[ -n "$ids" ]] || return 0
  n=$( db "SELECT COUNT(*) FROM tasks
           WHERE assignee=$(sqlq "$name") AND status IN ('todo','in_progress');" 2>/dev/null ) || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  extra=""
  (( n > 5 )) && extra=" (+$(( n - 5 )) more)"
  printf '%s%s' "$ids" "$extra"
}

# PURE. <name> <wall_state> <reset_epoch> <queue> [now] -> the closing sentence.
#
# DIVE-4666 item 3. The old tail asked the reader to re-measure two things the
# sender was holding: the quota reset it had just read, and the queue it had
# just counted. An alert that sends you to go look is a slower version of no
# alert.
_sup_capacity_tail() {
  local name="${1:-}" ws="${2:-none}" reset="${3:-}" queue="${4:-}" now="${5:-}" out
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  if [[ "$ws" == "lapsed" && "$reset" =~ ^[0-9]+$ ]] && declare -f quota_wall_when >/dev/null 2>&1; then
    out="Its usage wall ENDED at $(quota_wall_when "$reset" "$now") and the seat is still not transacting, so this is not a cooldown — check the auth profile."
  else
    out="Check the seat's model capacity (auth-profile, quota reset)."
  fi
  if [[ -n "$queue" ]]; then
    out="${out} Queued behind it: ${queue} — reassign or park those."
  else
    out="${out} Nothing is queued behind it right now (5dive task ls --assignee=${name})."
  fi
  printf '%s' "$out"
}

# DIVE-4052: which LEGS does a capacity alert get? Two pure decisions, no I/O,
# so the wiring from classification to each leg is unit-gradeable on its own.
# `quota_alerts_on` is read once per tick from _SUP_QUOTA_ALERTS_FLAG and passed
# in rather than probed here, which is what keeps them pure.
#
# Both default the sentinel to TRUE so that a legacy 1-arg call is exactly the
# pre-4052 loud answer; the production tick always passes the flag explicitly.
_sup_capacity_notify_human() {  # <class> [quota_alerts_on] [wall_state] -> true|false
  local class="${1:-}" quota_alerts_on="${2:-true}" wall_state="${3:-none}"
  # DIVE-4666: a KNOWN cooldown with a measured reset still ahead is not an
  # incident on either leg, whichever of the two capacity classes this tick
  # happened to land on. Ahead of every other rule here because it is a fact
  # about the SEAT and the rules below are facts about the class. Defaults to
  # `none`, so a legacy 2-arg call is byte-for-byte the pre-4666 answer.
  if [[ "$wall_state" == "cooling" ]] \
     && [[ "$class" == "quota-exhausted" || "$class" == "no-output" ]]; then
    printf 'false'; return
  fi
  # DIVE-3982: no-output ("N open row(s), nothing closed in Nd") is never a human
  # ping — the other half of the FLEET-HEALTH family. Its remedy is "reassign or
  # park", which is main/ops triage, NOT lodar's, and it is the byte-identical
  # false positive an idle on-demand seat produces (an empty queue closes
  # nothing; a-stalled-signal-is-true-and-names-no-cause). Its machine leg is
  # untouched by DIVE-4052 — main still triages every one.
  [[ "$class" == "no-output" ]] && { printf 'false'; return; }
  # DIVE-4052: for a quota wall the sentinel IS the policy, on this leg and on
  # the machine leg alike. No per-shape reading survives above it (see the
  # retirement note where _sup_quota_selfheal used to live): the answer to "is
  # this wall worth a ping" is now the same for every shape, and the debug mode
  # that shows them shows all of them.
  [[ "$class" == "quota-exhausted" ]] && { printf '%s' "$quota_alerts_on"; return; }
  printf 'true'
}

# The machine leg (a2a to main). Only quota-exhausted is gated: no-output keeps
# its machine leg — its remedy genuinely IS main's triage, which is why DIVE-3982
# muted the human half and not this one — and verify-challenge never reaches this
# function at all (_sup_verify_alert, loud on both legs by construction: an
# ID-verification challenge is account state only a person can clear, and it is
# not a quota wall).
_sup_capacity_notify_machine() {  # <class> [quota_alerts_on] [wall_state] -> true|false
  local class="${1:-}" quota_alerts_on="${2:-true}" wall_state="${3:-none}"
  # DIVE-4666. THIS is the leg that fired on 2026-09-20 — `no-output`'s machine
  # leg, the one DIVE-3982 deliberately left live — so a gate that covered only
  # the human leg would have changed nothing about the page it was written for.
  if [[ "$wall_state" == "cooling" ]] \
     && [[ "$class" == "quota-exhausted" || "$class" == "no-output" ]]; then
    printf 'false'; return
  fi
  [[ "$class" == "quota-exhausted" ]] && { printf '%s' "$quota_alerts_on"; return; }
  printf 'true'
}

# DIVE-4293: the page for a seat sitting on a picker nobody can answer. Kept
# apart from _sup_capacity_alert because that message ends by telling the reader
# to check model capacity and quota resets, which is the wrong runbook here and
# an alert that sends you to the wrong place is worse than a quieter one. Both
# legs best-effort, like every alert in this file — a wedged channel must never
# abort the tick for the rest of the fleet.
# DIVE-4536: <cause> selects the body. The two causes under this class are
# waiting on the same keypress for opposite reasons, and the old single text
# named AskUserQuestion — which would have told a reader to go pick an option on
# a confirm the watchdog had already refused, on a seat that had already moved on.
_sup_prompt_alert() {  # <name> <detail> [cause]
  local name="$1" detail="$2" cause="${3:-blocked-on-prompt}" msg
  if [[ "$cause" == "dangerous-confirm" ]]; then
    msg="[FLEET-HEALTH blocked-on-prompt] agent '${name}' is UP and REACHABLE and is WAITING ON A KEYPRESS: ${detail}. This is claude's built-in tool-permission confirm (it fires even under bypassPermissions and is not an AskUserQuestion, so no hook sees it). The watchdog answers this one itself by pressing Escape — the safe option — so you are reading this because the keypress could not be sent, automatic actions are off, or the seat has stood on a confirm repeatedly inside one hour, which means the model keeps re-issuing a flagged command and a keypress is not the fix. Read the pane (tmux attach -t agent-${name})."
  else
    msg="[FLEET-HEALTH blocked-on-prompt] agent '${name}' is UP and REACHABLE and is WAITING ON A KEYPRESS: ${detail}. It called AskUserQuestion or ExitPlanMode and the picker is rendering into a tmux pane nobody is reading; the seat will sit there until someone answers it. The highlighted option is NOT marked (Recommended), so this watchdog will not choose for it. Read the pane (tmux attach -t agent-${name}), pick the option, and if the choice genuinely needed a person it belongs on a task gate, not a picker."
  fi
  _sup_alert_deliver prompt-alert "$name" blocked-on-prompt "$msg"
}

# DIVE-1127: fire the same-day alert for a tripped account. Both legs are
# best-effort — a delivery failure must NEVER abort the tick (one wedged account
# can't blind the watcher for the rest of the fleet). main (CTO, D4 runbook
# co-owner) gets the agent-to-agent send; lodar (human owner) gets a pinging
# gate. Dedup is the caller's job (one alert per account per _SUP_ALERT_WINDOW_H).
_sup_verify_alert() {  # <name> <excerpt>
  local name="$1" excerpt="$2"
  local msg="[TRIPWIRE id-verification] claude account 'agent-${name}' looks STALLED on an ID/age-verification challenge (anthropic-tos-hedge D4 trigger 1). Response: flip this account to the OpenRouter-Claude profile same-day (A1 runbook). Pane signature: ${excerpt}"
  _sup_alert_deliver verify-tripwire "$name" verify-challenge "$msg"
}

# Goal-drift (DIVE-971): claude-only, transcript-scoped, STRUCTURAL — no
# semantic relevance heuristic. Echoes the drifting DIVE task id when ALL hold,
# empty otherwise (false-negative bias — any missing/ambiguous signal => empty):
#   * the agent is actively progressing (activity within the slow window) — this
#     is "working the wrong thing", orthogonal to no-progress/idle/stuck;
#   * an active /goal exists (last set-marker not superseded by a later
#     `/goal clear`) and is older than the slow window (so the set->start race
#     right after the heartbeat arms a goal never flags);
#   * the goal condition names a DIVE task whose status is still `todo` —
#     untouched by ANY agent (in_progress-by-anyone or terminal => not drift).
_sup_goal_drift() {  # <type> <home> <name> <now> <act_epoch>
  local type="$1" home="$2" name="$3" now="$4" act_epoch="$5"
  [[ "$type" == "claude" ]] || return 0
  [[ "$act_epoch" =~ ^[0-9]+$ ]] || return 0
  (( now - act_epoch < _SUP_T_SLOW_MIN * 60 )) || return 0
  local tx
  tx=$( { find "$home/.claude/projects" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null || true; } \
        | sort -rn | head -1 | cut -d' ' -f2-)
  [[ -n "$tx" && -r "$tx" ]] || return 0
  # One JSONL record == one physical line, so a line match == a record match.
  local set_ln clr_ln
  set_ln=$(grep -n 'session-scoped Stop hook is now active with condition' "$tx" 2>/dev/null | tail -1 | cut -d: -f1) || set_ln=""
  [[ -n "$set_ln" ]] || return 0
  # A `/goal clear` record carries the short args tag; set records carry the
  # long condition text, so this exact string never matches a set line.
  clr_ln=$(grep -n '<command-args>clear</command-args>' "$tx" 2>/dev/null | tail -1 | cut -d: -f1) || clr_ln=""
  [[ -n "$clr_ln" ]] && (( clr_ln > set_ln )) && return 0
  local setline set_ts set_epoch
  setline=$(sed -n "${set_ln}p" "$tx")
  set_ts=$(grep -oE '"timestamp":"[^"]+"' <<<"$setline" | head -1 | cut -d'"' -f4) || set_ts=""
  [[ -n "$set_ts" ]] && set_epoch=$(date -d "$set_ts" +%s 2>/dev/null) || set_epoch=""
  [[ "$set_epoch" =~ ^[0-9]+$ ]] && (( now - set_epoch < _SUP_T_SLOW_MIN * 60 )) && return 0
  local task
  task=$(grep -oE 'DIVE-[0-9]+' <<<"$setline" | head -1 | grep -oE '[0-9]+') || task=""
  [[ -n "$task" ]] || return 0
  local st
  st=$(db "SELECT status FROM tasks WHERE id=${task};" 2>/dev/null || echo "")
  # Only a still-untouched (todo) target is drift; in_progress (by anyone) or
  # any terminal/blocked state means the goal is being served or is satisfied.
  [[ "$st" == "todo" ]] || return 0
  echo "$task"
}

_sup_usage() {
  cat <<USAGE
5dive supervisor — observe-only fleet health board ( P1)

  5dive supervisor                 # per-agent board: detect + classify, zero actions
  5dive supervisor --watch[=secs]  # live repaint (default 5s; q quits)
  5dive supervisor --tick          # cron-callable observe pass (root): detect +
                                   # classify + append audit rows to the
                                   # supervisor_events table (tasks.db).
                                   # No-ops unless ${_SUP_ENABLED_FLAG} exists.

Classification (conservative — see docs/fleet-supervisor-design.md §4):
  healthy         running + progressing, or legitimately idle/stopped with no active work
  slow            active work but no transcript progress for ${_SUP_T_SLOW_MIN}m+ — recorded, never acted on
  update-pending  box CLI is behind the published release — an update signal, NOT
                  a wedged agent (cause: stale-cli); recorded, NEVER acted on
  stuck           service/tmux/poller dead, a loop self-flagged stuck, or no progress
                  for ${_SUP_T_STUCK_MIN}m+ with active work
                  (cause: service-dead|tmux-dead|poller-dead|loop-stuck|no-progress)
  drift           active /goal targets a still-todo DIVE task while the agent
                  progresses elsewhere (cause: goal-drift) — recorded, NEVER acted on
  no-output       holds open row(s) and has closed NOTHING for ${_SUP_T_NO_OUTPUT_DAYS}d+
                  (cause: no-output) — the seat is claiming work and completing
                  none, which every liveness signal reads as "active"; alerts
  composer-wedged a dispatched payload is sitting UNSENT in the seat's composer
                  (cause: submit-unverified) — the seat is alive, idle and
                  permanently stuck, and its claimed row reads in_progress, which
                  is what makes every later tick skip it as busy. Observe-only:
                  the nudge/resume ladder makes it worse; restart the seat
  blocked-on-prompt
                  pane is sitting on a picker — the seat is waiting on a
                  keypress, not on a model. Two causes:
                  blocked-on-prompt = an AskUserQuestion/ExitPlanMode picker
                  (DIVE-4293), auto-answered with Enter ONLY when the
                  highlighted option is marked (Recommended), paged otherwise;
                  dangerous-confirm = claude's built-in tool-permission confirm
                  (DIVE-4536), which fires even under bypassPermissions and no
                  hook can see — auto-DECLINED with Escape (never Yes) once it
                  has stood ${_SUP_T_CONFIRM_DWELL_MIN}m+ with no transcript
                  progress, noted on the seat's in-progress row, and paged only
                  when the keypress fails or the seat keeps coming back.
  quota-exhausted pane shows a model-capacity/quota refusal (cause:
                  quota-exhausted) — a fleet event, not the seat's own; alerts
  unprobed        this run could not READ the seat's pane (it is not root), so
                  the three top-ranked branches above — verify-challenge,
                  blocked-on-prompt and the pane-refusal half of
                  quota-exhausted — did not run. Not a fault claim: it replaces
                  the word \`healthy\` ONLY, because that word would otherwise be
                  produced by not having looked (DIVE-4342). Run as root, or
                  read the summary's DEGRADED mark as "these three signals are
                  missing from this board".
  stalled         NO active work (no in_progress, no running loop) but a todo
                  task has sat assigned to this agent, untouched, for
                  ${_SUP_T_STRANDED_MIN}m+ (cause: idle-stranded) — gap#3:
                  "idle" alone used to read as healthy even while actionable
                  work was stranded; recorded, NEVER acted on (observe-only,
                  same as slow/drift/update-pending)

Poller + activity signals cover claude/codex/grok/antigravity/opencode.
P1 takes ZERO recovery actions. Add --json to any form for machine output.
USAGE
}

# One box-level CLI-staleness probe per process (the fleet shares one binary,
# so this is NOT per-agent). Mirrors cmd_update_check's read-only logic:
# behind = installed < published; stale = behind AND the nightly soft-update
# isn't closing the gap. Best-effort — no network / no published version means
# staleness stays "unknown" and NEVER classifies anyone stuck (a flaky probe
# must not be a stuck signal).
_SUP_CLI_CHECKED=0
_SUP_CLI_LATEST=""
_SUP_CLI_BEHIND="unknown"
_SUP_CLI_STALE="unknown"
_SUP_CLI_FROZEN="unknown"
_SUP_CLI_FROZEN_DETAIL=""
# DIVE-2306: three-state strings, like BEHIND/STALE above and for the same
# reason — "we did not measure it" is not "false".
_SUP_CLI_AHEAD="unknown"
_SUP_CLI_FROZEN_ARMED="unknown"
_sup_cli_check() {
  (( _SUP_CLI_CHECKED )) && return 0
  _SUP_CLI_CHECKED=1

  # DIVE-2287 — FIRST, and outside every early return below. The staleness
  # probe answers "am I behind LATEST"; this answers "has my version moved AT
  # ALL". They fail in opposite conditions, which is the entire reason both
  # exist: when the release cutter is down the tag stops moving, `behind` is
  # false for every box in the fleet, and the only remaining evidence that
  # nothing has shipped in a week is that no box's version has changed in a
  # week. Ordering matters — every `return 0` in the probe below is a case
  # where the comparison could not be made and the absolute reading is the
  # only one left. This tick runs as root, so unlike `update --check` it can
  # normally write the record.
  local -a fz=()
  mapfile -t fz < <(_cli_freeze_observe "$FIVE_VERSION" "${STATE_DIR}/cli-version-seen.json")
  _SUP_CLI_FROZEN="${fz[0]:-unknown}"
  _SUP_CLI_FROZEN_DETAIL="${fz[2]:-}"
  # DIVE-2306: an `unknown` freeze reading from a box that cannot record the
  # observation is not a monitor waiting for data — it is a monitor that will
  # never have any. The board has to be able to tell those apart.
  case "${fz[3]:-}" in yes) _SUP_CLI_FROZEN_ARMED="true" ;; no) _SUP_CLI_FROZEN_ARMED="false" ;; esac
  # DIVE-2042: the published version is read through _published_cli_probe, which
  # pins both fetches to one immutable sha and verifies the bundle against its
  # own checksum. Anything short of a CONSISTENT read leaves staleness UNKNOWN
  # rather than resolving it — during the propagation window the raw CDN can
  # serve a bundle one release behind, and believing it would mint a confident
  # `behind=false` for a box we did not actually measure. Same doctrine this
  # probe already applies to a missing nightly log: absence of evidence is not
  # evidence of currency.
  local probe
  probe=$(_published_cli_probe) || return 0
  local -a p=()
  mapfile -t p <<<"$probe"
  [[ "${p[0]:-}" == consistent ]] || return 0
  local latest="${p[1]:-}"
  [[ -n "$latest" ]] || return 0
  _SUP_CLI_LATEST="$latest"
  if ! version_lt "$FIVE_VERSION" "$latest"; then
    _SUP_CLI_BEHIND="false"; _SUP_CLI_STALE="false"
    # DIVE-2306: `update --check` has reported `ahead` as its own state since
    # DIVE-2287; the board folded it into this not-behind branch, so the one
    # surface the dashboard reads could not show it. A box above the newest
    # release is the state DIVE-2243's guard refuses every upgrade from — the
    # installer will say so and the board should not disagree by silence.
    if version_lt "$latest" "$FIVE_VERSION"; then _SUP_CLI_AHEAD="true"; else _SUP_CLI_AHEAD="false"; fi
    return 0
  fi
  _SUP_CLI_BEHIND="true"; _SUP_CLI_AHEAD="false"
  # Same nightly-log heuristic as cmd_update_check: a healthy recent nightly
  # means the gap closes on its own (behind-but-fine); a failed/absent/old one
  # means the box is genuinely running old code.
  # No readable nightly log => UNKNOWN, never stale (day-1 audit finding,
  # 2026-07-02): the control host has no soft-updates log, so "behind"
  # minutes after a release cut flagged every claude agent stuck/stale-cli.
  # Absence of evidence is not a stuck signal — same doctrine as the probe
  # itself. A box is only STALE on positive evidence: the last nightly
  # attempt failed, or the last successful one is older than the update
  # window (nightly had its chance and the gap is still open).
  local log="/tmp/claude-soft-updates.log" stale="unknown"
  if [[ -r "$log" ]]; then
    local start_line ok_last=true last_at last_epoch=""
    start_line=$(grep -n "soft updates start" "$log" | tail -1 | cut -d: -f1) || start_line=""
    if [[ -n "$start_line" ]] && grep -q "CLI upgrade via install.5dive.com failed" < <(tail -n "+${start_line}" "$log"); then
      ok_last=false
    fi
    last_at=$(grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ soft updates done" "$log" \
      | tail -1 | grep -oE "^[^ ]+") || last_at=""
    [[ -n "$last_at" ]] && last_epoch=$(date -d "$last_at" +%s 2>/dev/null) || last_epoch=""
    if [[ "$ok_last" == false ]]; then
      stale=true
    elif [[ -n "$last_epoch" ]]; then
      if (( $(date +%s) - last_epoch <= UPDATE_STALE_AFTER_SECS )); then
        stale=false
      else
        stale=true
      fi
    fi
  fi
  _SUP_CLI_STALE="$stale"
}

# DIVE-3968 — the Codex rollout, joined into the three values the classifier and
# the park already consume. Pure: measurement + clock in, no db, no fleet.
#
#   <codex_quota_json> <now> <pane_excerpt> <pane_deadline> <pane_epoch> <account_wall>
#   -> "<deadline>\x1f<epoch>\x1f<account_wall>"
#
# THE PANE IS NOT OVERRULED BY ABSENCE. `missing` (no rollout, or no rate-limit
# reading in it — a codex seat on a non-ChatGPT provider) returns the pane's own
# three values untouched. Otherwise, first-hand beats scrollback:
#   exhausted  → `live` + the window's reset epoch (the park keys to it: this is
#                the 2026-09-14 fix — "7:00 AM" left the park on its 6h cap), and
#                the account wall is named even when the pane has scrolled, so
#                the seat classifies `quota-exhausted` off a record, not a scrape.
#   recovered  → `lapsed` + that same epoch: the reset HAS passed. A past epoch
#                is an answer (DIVE-4328) — the park reads it and ends.
#   healthy / near-limit, newest turn served (no error) → a pane refusal still on
#                screen predates a turn the provider served, so it is scrollback:
#                `lapsed`, epoch = that turn. A turn that FAILED some other way
#                (a provider credit wall, a network error) proves nothing about
#                the pane and leaves it alone.
_sup_codex_quota_join() {
  local m="${1:-}" now="${2:-}" excerpt="${3:-}" dl="${4:-unknown}" ep="${5:-}" wall="${6:-}"
  local st win pct reset asof note terr tat
  if [[ -n "$m" ]] && declare -f codex_quota_state >/dev/null 2>&1; then
    IFS=$'\037' read -r st win pct reset asof note <<<"$(codex_quota_state "$m" "$now")"
    case "$st" in
      exhausted)
        if [[ "$reset" =~ ^[0-9]+$ ]]; then dl="live"; ep="$reset"; else dl="unknown"; ep=""; fi
        [[ -n "$wall" ]] || wall="codex $(quota_wall_phrase "$win" "$pct" "$reset" "$now")"
        ;;
      recovered)
        dl="lapsed"; ep="$reset"; wall=""
        ;;
      healthy|near-limit)
        IFS=$'\t' read -r terr tat <<<"$(jq -r '[(.lastTurn.error // "ok"), (.lastTurn.at // "")] | @tsv' <<<"$m" 2>/dev/null)"
        if [[ -n "$excerpt" && "$terr" == "ok" && "$tat" =~ ^[0-9]+$ ]]; then
          dl="lapsed"; ep="$tat"
        fi
        ;;
    esac
  fi
  printf '%s\x1f%s\x1f%s' "$dl" "$ep" "$wall"
}

# Pure classification decision — NO I/O, directly unit-testable (mirrors the
# _sup_act_plan factoring the P2 ladder already uses). Takes every signal
# _sup_agent_record collects and returns "<class>\x1f<cause>\x1f<detail>" on
# stdout so a test can assert against it without stubbing systemctl/tmux/pgrep.
# args: desired svc_running(0/1) active sess tmux_state poller loop_stuck
#       has_work(0/1) act_age cli_stale(true/false/unknown) goal_drift_task
#       verify_excerpt stranded open_rows no_output_days quota_excerpt
#       quota_deadline(live/lapsed/unknown, DIVE-3880)
#       prompt_excerpt prompt_mark(recommended/unmarked, DIVE-4293;
#                                 confirm/confirm-fresh, DIVE-4536)
_sup_classify() {
  local desired="$1" svc_running="$2" active="$3" sess="$4" tmux_state="$5" poller="$6" \
        loop_stuck="$7" has_work="$8" act_age="$9" cli_stale="${10}" goal_drift_task="${11}" \
        verify_excerpt="${12}" stranded="${13:-0}" \
        open_rows="${14:-0}" no_output_days="${15:--1}" quota_excerpt="${16:-}" \
        quota_deadline="${17:-unknown}" prompt_excerpt="${18:-}" prompt_mark="${19:-unmarked}" \
        account_wall="${20:-}" pane_probe="${21:-ok}" wedged="${22:-}" \
        no_output_move="${23:--1}"
  # DIVE-3880: the policy lives HERE, in the pure decision, not at the pane
  # probe — the probe owes a distinguishable signal, the classifier owes the
  # verdict (community/wiki/a-fail-open-underneath-a-fail-closed-path-feeds-it-a-lie-in-the-format-it-trusts.md).
  # `lapsed` is the only state that disarms the branch; `unknown` must leave it
  # exactly as DIVE-3272 shipped it, or every deadline-free refusal (credit
  # balance, insufficient_quota, weekly 100%) stops being seen at all.
  case "$quota_deadline" in live|lapsed|unknown) ;; *) quota_deadline="unknown" ;; esac
  local class="healthy" cause="" detail=""
  # DIVE-1127: the verification-challenge tripwire wins FIRST — it is the highest
  # priority signal (same-day alert obligation) and, when present, explains any
  # concurrent stall (a challenge freezes the session). Alerting is the tick's job.
  if [[ -n "$verify_excerpt" ]]; then
    class="verify-challenge"; cause="id-verification"
    detail="pane shows an ID/age-verification challenge"
  elif [[ -n "$wedged" ]]; then
    # DIVE-4642 — ranked here, above every inference, for the same reason the two
    # branches around it are: a wedged composer FREEZES the seat, so it explains
    # any concurrent stall and is the more specific reading of one. It must sit
    # above `has_work`/`slow`/`stuck` in particular, because a wedged seat is
    # holding an in_progress row BY DEFINITION — that row is what the injector
    # claimed on the goal it could not deliver — and `active` is exactly the
    # healthy-looking word that hid this for 9.5 hours on quinn.
    #
    # Not `stuck`: the P2 act ladder's remedies are wrong here. A nudge types
    # another line into a composer that already cannot submit (each dispatch only
    # makes the draft longer), and `resume` presses Escape, which aborts the turn.
    # The only measured exit is `sudo 5dive agent restart <seat>`, so this class
    # is observe-and-name, and the remedy is in the detail where an operator reads
    # it rather than in a loop that would make the wedge worse.
    class="composer-wedged"; cause="submit-unverified"
    detail="${wedged} — recover with: sudo 5dive agent restart <seat>"
  elif [[ -n "$prompt_excerpt" ]]; then
    # DIVE-4293: ranked immediately under the verification challenge and above
    # every inference, on the same reasoning — a picker FREEZES the session, so
    # it explains any concurrent stall and is the more specific reading of one.
    # It cannot be reached with the unit down (the probe needs a live pane), so
    # it does not mask a dead-unit branch it is sitting above. Distinct from
    # `stuck` on purpose: the nudge/resume ladder is the wrong remedy — a nudge
    # types a line into a pane that is waiting for a KEY, and `resume` presses
    # Escape, which throws the question away along with whatever the model was
    # about to do with the answer.
    class="blocked-on-prompt"
    case "$prompt_mark" in
      # DIVE-4536: claude's own tool-permission confirm gets its OWN cause, not
      # its own CLASS. The state is identical (a seat frozen on a keypress), and
      # every surface that counts blocked-on-prompt — the board, the digest,
      # `agent info`, the alert dedup — must count this too. A second class for
      # the same state would have had to be added to each of them, and the one
      # that got missed is where the next 10-hour stall hides. What differs is
      # only the REMEDY, and a remedy is what a cause selects.
      confirm|confirm-fresh)
        cause="dangerous-confirm"
        detail="pane is sitting on a tool-permission confirm: ${prompt_excerpt}"
        if [[ "$prompt_mark" == "confirm" ]]; then
          detail="${detail} [standing ${_SUP_T_CONFIRM_DWELL_MIN}m+ with no transcript progress — declinable (Esc)]"
        else
          detail="${detail} [seen this tick — the decline waits ${_SUP_T_CONFIRM_DWELL_MIN}m]"
        fi ;;
      # DIVE-4581: claude's own usage-limit hold. It is the one picker that is
      # NOT a question — it is the capacity wall this classifier already has a
      # class for, wearing a picker's footer, and `blocked-on-prompt` paged a
      # human three times in one evening for it. Reclassified rather than given
      # a cause under blocked-on-prompt (the DIVE-4536 shape), because here the
      # STATE differs and not just the remedy: the seat is walled, the wall
      # prints its own end time, and every surface that counts quota walls —
      # the board, `agent info`, the rotation branch, the DIVE-4052 sentinel —
      # should count this too.
      limit-picker*)
        class="quota-exhausted"; cause="limit-picker"
        detail="pane is sitting on claude's own usage-limit hold picker — a capacity wall that prints its own resume time, not a question for a person: ${prompt_excerpt}"
        if [[ "${prompt_mark#limit-picker:}" == "unknown" ]]; then
          detail="${detail} [no cursor on a numbered option — the auto-resume option will NOT be pressed; the seat waits for its own reset]"
        else
          detail="${detail} [auto-resume option is ${prompt_mark#limit-picker:} step(s) from the cursor — answerable]"
        fi ;;
      recommended)
        cause="blocked-on-prompt"
        detail="pane is sitting on a choice picker: ${prompt_excerpt} [highlighted option is marked (Recommended) — answerable]" ;;
      *)
        cause="blocked-on-prompt"
        detail="pane is sitting on a choice picker: ${prompt_excerpt} [no highlighted (Recommended) option — a person must choose]" ;;
    esac
  # desiredState (P2, DIVE-857 prereq b): an operator's explicit stop/start
  # beats inference. Recorded by `5dive agent stop|start`; absent on legacy
  # agents => the P1 inference path below, unchanged.
  elif [[ "$desired" == "stopped" ]] && (( ! svc_running )) && [[ "$active" != "failed" ]]; then
    detail="stopped (desired)"
  elif (( ! svc_running )); then
    if [[ "$active" == "failed" ]] || (( has_work )) || [[ "$desired" == "running" ]]; then
      class="stuck"; cause="service-dead"; detail="unit ${active:-unknown}${desired:+ (desired: $desired)}"
    else
      detail="stopped (no active work)"
    fi
  elif [[ "$tmux_state" == "dead" ]]; then
    class="stuck"; cause="tmux-dead"; detail="unit active but tmux session '${sess}' gone"
  elif [[ "$poller" == "dead" ]]; then
    class="stuck"; cause="poller-dead"; detail="telegram poller process not running"
  elif [[ -n "$account_wall" ]]; then
    # DIVE-4342: the ACCOUNT's own measured usage, above the pane scrape, because
    # it is better evidence of the same fact and it arrives EARLIER. The pane
    # branch below can only fire after the seat has tried and been refused —
    # it reads a refusal in scrollback. This one reads the number the provider
    # reported: the seat is walled from the first token, not from the first
    # refusal. Measured on a customer box where `account usage` said 101% and
    # this classifier said `healthy` because no pane had been refused yet.
    class="quota-exhausted"; cause="account-usage"
    detail="auth account measured at the wall: ${account_wall}"
  elif [[ -n "$quota_excerpt" && "$quota_deadline" != "lapsed" ]]; then
    # DIVE-3272: placed ABOVE loop-stuck / no-progress on purpose — a capacity
    # wall EXPLAINS both of those, and the response is different in kind (a
    # profile flip or a quota reset, not a nudge/resume). Below the dead-signal
    # branches because a down unit is the more specific reading.
    class="quota-exhausted"; cause="quota-exhausted"
    detail="pane shows a model-capacity refusal: ${quota_excerpt}"
    # DIVE-3880: never a bare class again — the reader is told which of the
    # three deadline states this rests on, so an abstention cannot be read as a
    # confirmed live refusal.
    case "$quota_deadline" in
      live)    detail="${detail} [resume deadline still in the FUTURE — the refusal is live]" ;;
      unknown) detail="${detail} [the refusal names no resume deadline this can parse — UNKNOWN whether it is still in force, NOT confirmed live]" ;;
    esac
  elif (( loop_stuck > 0 )); then
    class="stuck"; cause="loop-stuck"; detail="${loop_stuck} running loop(s) self-flagged stuck"
  elif (( has_work )) && (( act_age >= 0 )) && (( act_age >= _SUP_T_STUCK_MIN * 60 )); then
    class="stuck"; cause="no-progress"; detail="active work, no transcript progress for $((act_age / 60))m"
  elif [[ "$(_sup_output_drought "$open_rows" "$no_output_days" "$no_output_move")" == "true" ]]; then
    # DIVE-3272: the output drought. Ranked BELOW the hard dead signals — those
    # are more specific and already surface — but ABOVE stale-cli / slow / drift
    # / active, because a multi-day drought outranks a ten-minute progress gap
    # and a box-level update notice, and because the branch it has to beat is
    # the one that hid the incident: `has_work -> detail="active"`. A seat that
    # is claiming rows and closing none must not print as active.
    #
    # DIVE-4666 it.2: the predicate, not the inline conjunction, because the
    # test it owes now takes THREE numbers and the third is the one that was
    # missing when this branch paged codex six minutes after it picked a row up.
    # See _sup_output_drought for what movement is and why a delivery and a gate
    # need no term of their own.
    class="no-output"; cause="no-output"
    detail="${open_rows} open row(s), nothing closed in ${no_output_days}d"
    # Only when it was MEASURED. An unknown queue clock adds no clause, so every
    # caller that passes no 23rd argument keeps a byte-identical detail string.
    if (( no_output_move >= 0 )); then
      detail="${detail}, nothing picked up in $(_sup_ago_phrase "$no_output_move")"
    fi
  elif [[ "$cli_stale" == "true" ]]; then
    # Box-level: the shared CLI is behind AND the nightly isn't catching up
    # (the /tmp-clobber class) — every agent is executing old code. Requires a
    # confirmed probe; "unknown" never lands here. This is an UPDATE-PENDING
    # signal, NOT a wedged agent (DIVE-974): the agents are healthy, just one
    # release behind, so it MUST NOT classify as stuck — the P2 act loop only
    # touches class=="stuck", and a stale-cli tick right after every release cut
    # would otherwise nudge/resume/rotate/escalate the entire healthy fleet.
    class="update-pending"; cause="stale-cli"; detail="box CLI ${FIVE_VERSION} stale behind ${_SUP_CLI_LATEST}"
  elif (( has_work )) && (( act_age >= 0 )) && (( act_age >= _SUP_T_SLOW_MIN * 60 )); then
    class="slow"; detail="active work, no transcript progress for $((act_age / 60))m"
  elif [[ -n "$goal_drift_task" ]]; then
    # Disjoint from slow/stuck by construction (drift needs recent activity).
    # Observe-only: the P2 act loop is gated on class=="stuck", so this never
    # nudges/resumes/rotates — surfaced for the audit trail and board only.
    class="drift"; cause="goal-drift"
    detail="active /goal targets DIVE-${goal_drift_task} (still todo); agent progressing elsewhere"
  elif (( has_work )); then
    detail="active"
  elif (( stranded > 0 )); then
    # DIVE-1416 (gap#3): the agent has NO active work at all, yet a todo task
    # has sat assigned to it for _SUP_T_STRANDED_MIN+ — heartbeat should have
    # woken it by now. Plain "idle" used to read as healthy here; this is the
    # distinct unhealthy signal the dogfood incident's board missed. Disjoint
    # from every branch above by construction (all require has_work or a dead
    # signal) — observe-only, same posture as slow/drift/update-pending.
    class="stalled"; cause="idle-stranded"
    detail="${stranded} todo task(s) sitting ${_SUP_T_STRANDED_MIN}m+ untouched, no active work"
  else
    detail="idle"
  fi
  # DIVE-4342 it.2: LAST, and only over a clean verdict. `healthy` is the one
  # word this classifier is not entitled to when the pane probes were blind:
  # verify-challenge, blocked-on-prompt and the pane quota branch sit at the TOP
  # of the chain above, so a blind pass reaches `healthy` by not having looked.
  # Ranked under every named fault on purpose — a dead unit, a stuck loop or an
  # account measured at the wall are all things this DID observe, and replacing
  # them with "unprobed" would trade a true alarm for a caveat.
  if [[ "$pane_probe" == "unprobed" && "$class" == "healthy" ]]; then
    class="unprobed"; cause="pane-unreadable"
    detail="pane unreadable (needs root): verify-challenge / blocked-on-prompt / pane-refusal did NOT run — observed: ${detail}"
  fi
  printf '%s\x1f%s\x1f%s\n' "$class" "$cause" "$detail"
}

# Detect + classify ONE agent -> one compact JSON record on stdout.
# args: name type channels unit user tmux-session home now-epoch
_sup_agent_record() {
  local name="$1" type="$2" channels="$3" unit="$4" user="$5" sess="$6" home="$7" now="$8" desired="${9:-}"

  # --- signal: systemd unit state + uptime (for the poller boot grace) ---
  local props active sub ts_str uptime=0
  props=$(systemctl show "$unit" --property=ActiveState,SubState,ActiveEnterTimestamp --no-page 2>/dev/null || true)
  active=$(awk -F= '/^ActiveState=/{print $2}'         <<<"$props")
  sub=$(awk    -F= '/^SubState=/{print $2}'            <<<"$props")
  ts_str=$(awk -F= '/^ActiveEnterTimestamp=/{print $2}' <<<"$props")
  local svc_running=0
  case "$active" in active|activating|reloading) svc_running=1 ;; esac
  if (( svc_running )) && [[ -n "$ts_str" && "$ts_str" != "n/a" ]]; then
    local since; since=$(date -d "$ts_str" +%s 2>/dev/null || echo "")
    [[ -n "$since" ]] && uptime=$((now - since))
  fi

  # --- signal: tmux session liveness (as the agent's own user) ---
  # Only probeable with root (the sudo hop); without it — or with the service
  # down, where "no session" is implied and uninteresting — report "unknown",
  # which never classifies (false-negative bias).
  local tmux_state="unknown"
  if (( svc_running )) && [[ $EUID -eq 0 ]]; then
    if sudo -n -u "$user" tmux has-session -t "$sess" 2>/dev/null; then
      tmux_state="alive"
    else
      tmux_state="dead"
    fi
  fi

  # --- signal: telegram poller liveness (per-type, DIVE-971) ---
  # Each type's telegram bridge is a bun process whose argv carries its plugin
  # dir (_SUP_POLLER_PAT); a pgrep against the agent user is cheaper than
  # doctor's MCP-log reasoning and answers "alive right now". Grace window right
  # after a service start (bridge boot lag). Types with no probeable bridge, or
  # any non-telegram channel set, stay "n/a" (never classifies).
  local poller="n/a" poller_pat="${_SUP_POLLER_PAT[$type]:-}"
  if [[ -n "$poller_pat" && ",${channels}," == *",telegram,"* ]]; then
    if pgrep -u "$user" -f "$poller_pat" >/dev/null 2>&1; then
      poller="alive"
    elif (( ! svc_running )) || (( uptime > 0 && uptime < _SUP_POLLER_GRACE_SEC )); then
      poller="unknown"
    else
      poller="dead"
    fi
  fi

  # --- signals from the shared store: loop stuck flag + active work ---
  local loop_stuck running_loops inprog
  loop_stuck=$(db "SELECT COUNT(*) FROM loop_runs WHERE spawned_by_agent=$(sqlq "$name") AND status='running' AND stuck=1;" 2>/dev/null || echo 0)
  running_loops=$(db "SELECT COUNT(*) FROM loop_runs WHERE spawned_by_agent=$(sqlq "$name") AND status='running';" 2>/dev/null || echo 0)
  inprog=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='in_progress' AND kind='standard';" 2>/dev/null || echo 0)
  [[ "$loop_stuck"    =~ ^[0-9]+$ ]] || loop_stuck=0
  [[ "$running_loops" =~ ^[0-9]+$ ]] || running_loops=0
  [[ "$inprog"        =~ ^[0-9]+$ ]] || inprog=0
  local has_work=0
  (( inprog > 0 || running_loops > 0 )) && has_work=1

  # --- signal: last-activity / progress timestamp (per-type transcript mtime) ---
  # DIVE-971: per-type roots+globs (_sup_activity_epoch) replace the claude-only
  # probe — codex/grok/antigravity/opencode now get a real progress age. A type
  # with no probe, or an empty/unreadable root, leaves age unknown and can never
  # be classified stuck/no-progress (false-negative bias).
  local act_epoch act_age=-1
  act_epoch=$(_sup_activity_epoch "$type" "$home")
  [[ "$act_epoch" =~ ^[0-9]+$ ]] && act_age=$(( now - act_epoch ))

  # --- signal: goal-drift (per-type; claude-only inside the helper) ---
  # DIVE-971: an active /goal targets a still-untouched DIVE task while the agent
  # progresses elsewhere. Observe-only — never feeds the P2 act ladder.
  local goal_drift_task; goal_drift_task=$(_sup_goal_drift "$type" "$home" "$name" "$now" "$act_epoch")

  # --- signal: ID/age-verification challenge (DIVE-1127) — pane-scoped tripwire ---
  # DIVE-4342 it.2: the RETURN CODE is now load-bearing — rc 3 means the probe
  # was not allowed to look, which is not the same fact as an empty excerpt.
  # Captured on its own line because `local x=$(...)` would swallow it.
  local verify_excerpt verify_rc
  verify_excerpt=$(_sup_verify_challenge "$type" "$user" "$sess" "$svc_running"); verify_rc=$?

  # --- signal: channel BINDING, from the bridge handshake (DIVE-3964) ---
  # Every other signal in this function measures LIVENESS. This one measures
  # whether the channels the registry declares are actually carrying messages,
  # and it is the only signal here the seat asserts about ITSELF: the record is
  # written by the Codex bridge, so a healthy unit, a live tmux session and a
  # running poller are not evidence against it. Empty for a runtime with no
  # bridge and nothing declared — absence is only evidence when the thing was
  # expected (see agent_channel_handshake).
  local chan_health chan_state="" chan_detail="" chan_repair="" chan_evidence=""
  chan_health=$(agent_channel_handshake "$name" "$channels" "$type" \
                  "$([[ "${active:-}" == "active" ]] && echo yes || echo no)" \
                  "$(_sup_channel_repair_history "$name")" 2>/dev/null || true)
  if [[ -n "$chan_health" ]]; then
    chan_state="${chan_health%%|*}"
    chan_detail="${chan_health#*|}"; chan_detail="${chan_detail%%|*}"
    chan_repair="${chan_health%|*}"; chan_repair="${chan_repair##*|}"
    chan_evidence="${chan_health##*|}"
  fi

  # --- signal: model-capacity refusal in the live pane (DIVE-3272) ---
  local quota_excerpt quota_rc
  quota_excerpt=$(_sup_quota_pane "$user" "$sess" "$svc_running" "$now"); quota_rc=$?
  # DIVE-3880: a pane renders a refusal long after it lapses (measured: ops was
  # flagged at 14:17 off a refusal that expired at 14:10, mid-command). The
  # expiry is inside the excerpt itself — read it, and hand the STATE to the
  # classifier rather than deciding here. The excerpt stays in `signals`
  # whatever the state says: "we read this" and "it still holds" are different
  # facts and the operator wants both.
  #
  # DIVE-4328 — THE STATE IS NOT THE DEADLINE, AND THE PARK NEEDS THE DEADLINE.
  # `_sup_quota_deadline` echoes "<state>\x1f<epoch>" and this site took field 1
  # and threw field 2 away, so `signals.quotaDeadline` has only ever held one of
  # `live`/`lapsed`/`unknown`. The reclaimer's park
  # (`_hb_quota_park_until_seat`) then read that column and ran `date -d` on it
  # — which fails on all three words — so EVERY park fell to the blind 6h cap,
  # rebased on each fresh observation of the same stale pane. Measured
  # 2026-09-11: codex held its DIVE-4290 claim 5h past the reset time its own
  # wall printed. The parser was never the gap (DIVE-4206 taught it the
  # `resets 4am` phrasing); the STORAGE was. Both halves are emitted now, and
  # the state half is unchanged for every existing reader.
  local quota_deadline="unknown" quota_deadline_epoch=""
  if [[ -n "$quota_excerpt" ]]; then
    IFS=$'\x1f' read -r quota_deadline quota_deadline_epoch \
      <<<"$(_sup_quota_deadline "$quota_excerpt" "$now")"
    [[ -n "$quota_deadline" ]] || quota_deadline="unknown"
    # An epoch is emitted whenever the wall named a time this could parse —
    # INCLUDING one already in the past. A lapsed deadline is not noise here, it
    # is the only positive evidence that the park must end, and dropping it is
    # what left the un-park to a timer nobody had set.
    [[ "$quota_deadline_epoch" =~ ^[0-9]+$ ]] || quota_deadline_epoch=""
  fi

  # --- signal: OUTPUT (DIVE-3272) — open rows held, and days since this seat
  # last closed anything. The pair is the detector: either number alone is
  # meaningless (0 open rows and no closes is a correctly idle seat; 20 open
  # rows and a close this morning is a busy one).
  # DIVE-4666 it.2: THREE fields now — the third is minutes since the open queue
  # last moved. Read positionally with IFS rather than ${x%%|*}/${x##*|}: the
  # suffix form silently returned field 3 as `no_output_days` the moment the
  # third arrived, which is a wrong number in the voice of a right one.
  local open_rows=0 no_output_days=-1 no_output_move=-1 ostats
  ostats=$(_sup_output_stats "$name")
  IFS='|' read -r open_rows no_output_days no_output_move <<<"$ostats"
  [[ "$open_rows"      =~ ^[0-9]+$ ]]   || open_rows=0
  [[ "$no_output_days" =~ ^-?[0-9]+$ ]] || no_output_days=-1
  [[ "$no_output_move" =~ ^-?[0-9]+$ ]] || no_output_move=-1

  # --- signal: stranded todo (DIVE-1416 gap#3) — a todo task assigned to this
  # agent, sitting untouched (never started) past the stranded window. Only
  # matters when the agent has NO active work at all (_sup_classify only
  # consults it in that branch), so it's cheap to always compute here.
  local stranded; stranded=$(db "SELECT COUNT(*) FROM tasks
               WHERE assignee=$(sqlq "$name") AND status='todo' AND kind='standard'
                 AND created_at <= datetime('now','-${_SUP_T_STRANDED_MIN} minutes');" 2>/dev/null || echo 0)
  [[ "$stranded" =~ ^[0-9]+$ ]] || stranded=0

  # --- signal: BLOCKED-ON-PROMPT (DIVE-4293) — is the pane tail sitting on a
  # choice picker right now? Same root tmux hop as the verify/quota probes, and
  # the same false-negative bias: no root, a down unit or a non-claude runtime
  # yields empty and the branch simply never fires.
  local prompt_excerpt="" prompt_mark="unmarked" prow prompt_rc
  prow=$(_sup_prompt_pane "$type" "$user" "$sess" "$svc_running"); prompt_rc=$?
  if [[ -n "$prow" ]]; then
    prompt_excerpt="${prow%%$'\x1f'*}"; prompt_mark="${prow##*$'\x1f'}"
    case "$prompt_mark" in
      recommended) ;;
      # DIVE-4581: passed through verbatim — the mark carries the cursor-relative
      # keystroke count the act rung needs, and the dwell below is deliberately
      # NOT applied: a quota hold has no person about to answer it, and every
      # tick it stands is a tick the seat is parked for nothing.
      limit-picker:*) ;;
      # DIVE-4536: the DWELL is applied HERE, where the transcript clock lives,
      # and it gates the KEYSTROKE only — the class, the alert and the audited
      # event all fire on the first tick that sees the confirm. act_age is
      # computed a few lines above; -1 means the transcript mtime was
      # unreadable, and an unknown age never presses a key (the same
      # false-negative bias every threshold in this file carries).
      confirm)
        if (( act_age < 0 || act_age < _SUP_T_CONFIRM_DWELL_MIN * 60 )); then
          prompt_mark="confirm-fresh"
        fi ;;
      *) prompt_mark="unmarked" ;;
    esac
  fi

  # --- CLASSIFY (design §4) — see _sup_classify for the decision chain itself.
  local class cause detail crow
  # DIVE-4342: join the seat's auth account usage. Empty unless the account is
  # measured AT the wall right now — `unmeasured` and `clear` both pass through
  # as empty, so a missing snapshot can never invent a class.
  local _sup_wall="" _sw_state _sw_win _sw_pct _sw_reset _sw_age _sw_note
  # declare -f guard: a health read must never die on an unsourced helper, and
  # several harnesses source this file alone.
  if declare -f quota_wall_seat >/dev/null 2>&1; then
    IFS=$'\037' read -r _sw_state _sw_win _sw_pct _sw_reset _sw_age _sw_note <<<"$(quota_wall_seat "$name")"
    [[ "$_sw_state" == "exhausted" ]] && _sup_wall="$(quota_wall_phrase "$_sw_win" "$_sw_pct" "$_sw_reset")"
  fi
  # DIVE-3968: a CODEX seat's quota is read from its own rollout, first-hand, on
  # every tick — and it overrides the pane parse, because the pane's "try again
  # at 7:00 AM" is only a rendering of the `resets_at` the rollout carries.
  local codex_quota="" _cq_join
  if [[ "$type" == "codex" ]] && declare -f codex_quota_read >/dev/null 2>&1; then
    codex_quota=$(codex_quota_read "$home")
    _cq_join=$(_sup_codex_quota_join "$codex_quota" "$now" "$quota_excerpt" \
                 "$quota_deadline" "$quota_deadline_epoch" "$_sup_wall")
    IFS=$'\x1f' read -r quota_deadline quota_deadline_epoch _sup_wall <<<"$_cq_join"
  fi
  # DIVE-4342 it.2: one per-seat verdict out of the three probe return codes.
  # `unprobed` never invents a fault — it only refuses to let a CLEAN word be
  # printed by a caller that was never allowed to observe (see _sup_classify).
  local pane_probe; pane_probe=$(_sup_probe_state "$verify_rc" "$quota_rc" "$prompt_rc")
  # DIVE-4642: the injector already KNOWS when a submit failed — it prints
  # `submit unverified` — and that knowledge went to a log nobody reads while the
  # board said the seat was busy. `_wedge_read` is how it reaches a surface: a
  # seat whose composer is holding an undelivered payload is named UNHEALTHY here
  # within one tick. rc 1 (not wedged) leaves the variable empty, so the branch
  # below is disarmed by absence and no new false red is possible.
  local _sup_wedged=""
  _sup_wedged=$(_wedge_read "$name" 2>/dev/null) || _sup_wedged=""
  crow=$(_sup_classify "$desired" "$svc_running" "$active" "$sess" "$tmux_state" "$poller" \
                        "$loop_stuck" "$has_work" "$act_age" "$_SUP_CLI_STALE" "$goal_drift_task" \
                        "$verify_excerpt" "$stranded" \
                        "$open_rows" "$no_output_days" "$quota_excerpt" "$quota_deadline" \
                        "$prompt_excerpt" "$prompt_mark" "$_sup_wall" "$pane_probe" \
                        "$_sup_wedged" "$no_output_move")
  IFS=$'\x1f' read -r class cause detail <<<"$crow"

  jq -cn \
    --arg name "$name" --arg type "$type" --arg channels "$channels" --arg unit "$unit" \
    --arg service "${active:-unknown}" --arg sub "${sub:-}" \
    --arg tmux "$tmux_state" --arg poller "$poller" \
    --argjson loopStuck "$loop_stuck" --argjson runningLoops "$running_loops" \
    --argjson inProgress "$inprog" --argjson age "$act_age" --argjson uptime "$uptime" \
    --argjson stranded "$stranded" \
    --arg goalDrift "$goal_drift_task" \
    --arg verifyExcerpt "$verify_excerpt" \
    --arg quotaExcerpt "$quota_excerpt" \
    --arg quotaDeadline "$quota_deadline" \
    --arg quotaDeadlineEpoch "$quota_deadline_epoch" \
    --arg codexQuota "$codex_quota" \
    --arg chanState "$chan_state" --arg chanDetail "$chan_detail" \
    --arg chanRepair "$chan_repair" --arg chanEvidence "$chan_evidence" \
    --arg promptExcerpt "$prompt_excerpt" \
    --arg promptMark "$prompt_mark" \
    --arg paneProbe "$pane_probe" \
    --argjson openRows "$open_rows" --argjson noOutputDays "$no_output_days" \
    --argjson noOutputMoveMins "$no_output_move" \
    --arg class "$class" --arg cause "$cause" --arg detail "$detail" \
    '{name:$name, type:$type, channels:$channels, unit:$unit,
      signals:{service:$service, sub:$sub, uptimeSec:$uptime, tmux:$tmux, poller:$poller,
               loopStuck:$loopStuck, runningLoops:$runningLoops, inProgress:$inProgress,
               lastActivityAgeSec:(if $age < 0 then null else $age end),
               strandedTodo:$stranded,
               goalDriftTask:(if $goalDrift == "" then null else ($goalDrift|tonumber) end),
               verifyChallenge:(if $verifyExcerpt == "" then null else $verifyExcerpt end),
               openRows:$openRows,
               daysSinceLastClose:(if $noOutputDays < 0 then null else $noOutputDays end),
               # DIVE-4666 it.2: the SECOND term of the drought — minutes since
               # the newest touch on the open queue of this seat. Recorded, not only
               # consumed: the 07:40Z page was un-auditable after the fact
               # precisely because the number that refuted it was never written
               # down. null == not measured, never 0.
               minsSinceQueueMoved:(if $noOutputMoveMins < 0 then null else $noOutputMoveMins end),
               quotaSignature:(if $quotaExcerpt == "" then null else $quotaExcerpt end),
               # DIVE-3880: live / lapsed / unknown for the signature above.
               # null only when there is no signature to qualify.
               quotaDeadline:(if $quotaExcerpt == "" then null else $quotaDeadline end),
               # DIVE-4328: the RESET TIME THE WALL ITSELF PRINTED, as an
               # epoch. null when the refusal named none this could parse (the
               # unknown state above). This is what a park keys to; the string
               # above says only which of three states the parse landed in.
               quotaDeadlineEpoch:(if $quotaDeadlineEpoch == "" then null else ($quotaDeadlineEpoch|tonumber) end),
               # DIVE-3968: the rate-limit MEASUREMENT from the Codex rollout (null
               # for every other runtime). Stored raw, never as its verdict —
               # `codex_quota_state` classifies it against the clock of whoever reads it.
               codexQuota:(if $codexQuota == "" then null else ($codexQuota|fromjson? // null) end),
               # DIVE-3964. `state` is the bridge handshake verdict
               # (bound|stale|mismatched|unbound|failed|absent|n/a) and `repair`
               # is what a supervisor may SAFELY do about it — never inferred
               # from the state here, because the classifier is the only place
               # that knows whether the restart budget is already spent.
               channelBinding:(if $chanState == "" then null else
                 {state:$chanState, detail:$chanDetail, repair:$chanRepair,
                  evidence:(if $chanEvidence == "" then null else $chanEvidence end)} end),
               # DIVE-4293: the picker footer the pane tail is sitting on, and
               # whether the HIGHLIGHTED option carries (Recommended). The mark
               # is null when there is no picker to qualify.
               blockedOnPrompt:(if $promptExcerpt == "" then null else $promptExcerpt end),
               promptRecommended:(if $promptExcerpt == "" then null else ($promptMark == "recommended") end),
               promptMark:(if $promptExcerpt == "" then null else $promptMark end),
               # DIVE-4342 it.2: "ok" = the pane probes ran (or had nothing to
               # look at); "unprobed" = at least one could not look, so the
               # three branches above it did not run and a clean reading here
               # is an ABSENCE OF OBSERVATION, not an observation of absence.
               paneProbe:$paneProbe},
      classification:$class,
      cause:(if $cause == "" then null else $cause end),
      detail:$detail}'
}

# Full-fleet snapshot -> JSON array. Registered agents plus the box's main
# `claude` user (claude-session.service) when that unit is meant to run —
# enabled or currently active. A disabled+inactive unit means the box's main
# user doesn't operate that way; listing it would be a permanent false alarm.
_sup_snapshot() {
  local reg now
  reg=$(registry_read)
  now=$(date +%s)
  # NB: callers must run _sup_cli_check in THEIR shell first — _sup_snapshot is
  # invoked via $(…), so globals the probe sets in here would die with the
  # subshell and the summary/JSON would report "unknown". This call is then a
  # guarded no-op (already-checked) that only matters if snapshot is called bare.
  _sup_cli_check
  local rows="" name type channels
  for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
    type=$(jq     -r --arg n "$name" '.agents[$n].type // "claude"'     <<<"$reg")
    channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"'   <<<"$reg")
    local desired; desired=$(jq -r --arg n "$name" '.agents[$n].desiredState // ""' <<<"$reg")
    rows+=$(_sup_agent_record "$name" "$type" "$channels" \
      "5dive-agent@${name}.service" "agent-${name}" "agent-${name}" "/home/agent-${name}" "$now" "$desired")
    rows+=$'\n'
  done
  local cs_enabled cs_active
  cs_enabled=$(systemctl is-enabled claude-session.service 2>/dev/null || true)
  cs_active=$(systemctl is-active  claude-session.service 2>/dev/null || true)
  if [[ "$cs_enabled" == "enabled" || "$cs_active" == "active" ]]; then
    # Session name "claude" per the unit's ExecStop; transcripts under /home/claude.
    rows+=$(_sup_agent_record "claude" "claude" "none" \
      "claude-session.service" "claude" "claude" "/home/claude" "$now")
    rows+=$'\n'
  fi
  printf '%s' "$rows" | jq -s -c '.'
}

# Text board: one row per agent. Activity age humanized; "-" = unknown.
_sup_render_board() {
  local snap="$1"
  jq -r '
    def age: if . == null then "-"
             elif . < 3600 then "\(. / 60 | floor)m"
             elif . < 86400 then "\(. / 3600 | floor)h \((. % 3600) / 60 | floor)m"
             else "\(. / 86400 | floor)d \((. % 86400) / 3600 | floor)h" end;
    if length == 0 then "no agents registered (5dive agent create <name> --type=claude)" else
      (["AGENT","TYPE","SERVICE","CLASS","CAUSE","ACTIVITY","DETAIL"] | @tsv),
      (.[] | [ .name, .type, .signals.service, .classification, (.cause // "-"),
               (.signals.lastActivityAgeSec | age), (.detail // "-") ] | @tsv)
    end' <<<"$snap" | column -t -s $'\t'
}

# Post-table summary: counts + the box-level CLI probe result.
_sup_summary_line() {
  local snap="$1"
  jq -r --arg stale "$_SUP_CLI_STALE" --arg cur "$FIVE_VERSION" --arg lat "$_SUP_CLI_LATEST" \
        --arg frozen "$_SUP_CLI_FROZEN" --arg frozendet "$_SUP_CLI_FROZEN_DETAIL" \
        --arg ahead "$_SUP_CLI_AHEAD" --arg armed "$_SUP_CLI_FROZEN_ARMED" '
    "\(length) agents — " +
    "\([.[] | select(.classification == "healthy")]        | length) healthy / " +
    "\([.[] | select(.classification == "slow")]           | length) slow / " +
    "\([.[] | select(.classification == "drift")]          | length) drift / " +
    "\([.[] | select(.classification == "update-pending")] | length) update-pending / " +
    "\([.[] | select(.classification == "stalled")]        | length) stalled / " +
    "\([.[] | select(.classification == "stuck")]          | length) stuck" +
    (if ([.[] | select(.classification == "no-output")] | length) > 0
     then " · ⚠ \([.[] | select(.classification == "no-output")] | length) NO-OUTPUT" else "" end) +
    (if ([.[] | select(.classification == "quota-exhausted")] | length) > 0
     then " · ⚠ \([.[] | select(.classification == "quota-exhausted")] | length) QUOTA-EXHAUSTED" else "" end) +
    (if ([.[] | select(.classification == "verify-challenge")] | length) > 0
     then " · ⚠ \([.[] | select(.classification == "verify-challenge")] | length) VERIFY-CHALLENGE" else "" end) +
    (if ([.[] | select(.classification == "blocked-on-prompt")] | length) > 0
     then " · ⚠ \([.[] | select(.classification == "blocked-on-prompt")] | length) BLOCKED-ON-PROMPT" else "" end) +
    # DIVE-4342 it.2: THE DEGRADATION MARK. Counted off the SIGNAL, not the
    # class, on purpose: a seat that was blind AND independently stuck keeps
    # `stuck` as its class (the more specific, observed fact) — but this board
    # still may not imply the pane branches ran for it. So any unprobed seat
    # degrades the summary, whatever verdict it ended up carrying.
    (if ([.[] | select(.signals.paneProbe == "unprobed")] | length) > 0
     then " · ⚠ DEGRADED: \([.[] | select(.signals.paneProbe == "unprobed")] | length) of \(length) seat(s) UNPROBED — this board could not read their panes (run as root for the verify-challenge / blocked-on-prompt / pane-refusal branches)" else "" end) +
    (if $stale == "true" then " · CLI \($cur) STALE (latest \($lat))"
     elif $stale == "unknown" then " · CLI staleness unknown (probe unavailable)"
     else " · CLI \($cur) ok" end) +
    # DIVE-2306: `ahead` was reachable only from `update --check`. It is the
    # state the installer refuses to move, so a board that renders "CLI ok" for
    # it contradicts the installer without either of them being wrong.
    (if $ahead == "true" then " · ⚠ CLI \($cur) AHEAD of release \($lat) — the installer will refuse (a release cut is owed)"
     else "" end) +
    # DIVE-2287: appended, never substituted. A frozen fleet reads "CLI ok" on
    # the staleness half — that IS the failure — so this line has to be able to
    # say "ok" and "FROZEN" in the same breath.
    (if $frozen == "frozen" then " · ⚠ FLEET FROZEN: \($frozendet) — no release has reached this box; check the release cutter"
     else "" end) +
    # DIVE-2306: and the same argument one level down — a board that cannot
    # record the observation prints the freeze half as silence, which is what
    # "not frozen" looks like.
    (if $armed == "false" then " · ⚠ freeze alarm UNARMED on this box: \($frozendet)"
     else "" end)' <<<"$snap"
}

# --watch[=secs]: repaint inside the alt-screen (cmd_watch's escape constants),
# q / Ctrl-C to quit. Deliberately simpler than cmd_watch — no selection or
# attach; this is a health board, not a control surface (P1 = zero actions).
_sup_watch() {
  local interval="$1"
  [[ -t 1 && -t 0 ]] || fail "$E_USAGE" "supervisor --watch requires a TTY (try running it directly, not piped)"
  _sup_watch_teardown() { printf '%s%s%s' "$WATCH_SHOW" "$WATCH_RESET" "$WATCH_ALT_OFF"; }
  trap '_sup_watch_teardown; exit 130' INT TERM
  # See cmd_watch.sh — chain, never replace (DIVE-2598 it2).
  push_exit_handler _sup_watch_teardown
  printf '%s%s' "$WATCH_ALT_ON" "$WATCH_HIDE"
  _sup_cli_check   # once per watch session, in this shell (see _sup_snapshot)
  while true; do
    local snap board summary out
    snap=$(_sup_snapshot)
    board=$(_sup_render_board "$snap")
    summary=$(_sup_summary_line "$snap")
    out="${WATCH_BOLD}${WATCH_CYAN}5dive supervisor${WATCH_RESET} · observe-only · $(date '+%F %T')"$'\n\n'
    out+="$board"$'\n\n'
    out+="${WATCH_DIM}${summary} · refresh: ${interval}s · q quit${WATCH_RESET}"
    printf '%s%s%s' "$WATCH_HOME" "$out" "$WATCH_CLR_DOWN"
    local key=""
    if IFS= read -rsn1 -t "$interval" key; then
      case "$key" in q|Q) break ;; esac
    fi
  done
}

# --tick: the cron-callable observe pass — detect + classify + AUDIT, nothing
# else. Appends to supervisor_events (see tasks_db.sh): one 'observe' row per
# agent per tick when classification != healthy, plus one 'transition' row
# whenever an agent's classification changed since its last recorded row
# (including recovery back to healthy, so the trail shows both edges). The
# previous classification is derived from the agent's latest event row —
# healthy when it has none — so the tick needs no extra state file.
# ── P2 (DIVE-857): recovery ladder — ACT + ESCALATE (design §5–6) ───────────
# Auto-act was narrow along ONE axis: causes where the session is alive but
# wedged (no-progress, loop-stuck). Everything else stuck ESCALATES: one audit
# row per window, zero mutations. Rungs 1-3, in order: nudge -> resume -> rotate.
#
# DIVE-3753 adds rung 4 for ONE cause: poller-dead -> restart, rate-limited to
# _SUP_RESTART_MAX UNHEALED restarts per seat per _SUP_RESTART_WINDOW_H, and
# _SUP_RESTART_TOTAL_MAX restarts of any outcome in the same window (DIVE-3915 —
# a successful recovery no longer spends the allowance for the next, unrelated
# episode; see the ceiling's block comment). Reprovision stays manual
# and every other rung-4+ cause still escalates. The gap it closes was measured
# on 2026-08-26: `ESCALATE <seat> (poller-dead: rung-4-needed)` fired correctly
# for four seats and NOTHING SERVED IT, so a correct detection produced no
# action for 2h33m while 9 human gates sat pending — including on the
# coordinator seat, i.e. the fleet's human-in-the-loop path was dark and the
# supervisor knew.
#
# OSS-23 (self-heal every runtime): the ladder is RUNTIME-AGNOSTIC — codex, grok,
# opencode, and antigravity get the same nudge/resume/rotate as claude, not just
# claude. It always could be: every rung is a generic op on the agent's tmux
# session + registry, with no claude-specific assumption. nudge/resume inject a
# line (+ a modal-clearing Escape) into the `agent-<name>` tmux pane every runtime
# shares (_hb_send_line); rotate cycles among SAME-TYPE accounts and is already
# gated on per-agent rotation.enabled (a non-claude agent with no rotation pool
# just escalates at rung 2, same as claude). The old claude-only gate was a
# DIVE-857 caution, not a technical limit; without cross-runtime recovery the
# OSS-18 autonomy ledger's self-heal-recovery signal would be claude-biased
# (design: community/wiki/earned-autonomy-design-jul11.md §Sequencing #1).

# attempts + last-action epoch for an agent inside the rolling window, straight
# from the audit trail (no extra state file — same principle as the tick's
# transition detection). Echoes "attempts lastEpoch" (lastEpoch=0 when none).
#
# DIVE-3753: rung-4 restart rows are EXCLUDED. The two ladders are indexed
# differently — nudge/resume/rotate pick their rung by ATTEMPT COUNT, restart
# picks it by CAUSE — so counting a restart as an attempt would silently move
# the next no-progress on that seat from nudge to resume (and, at three, retire
# the ladder to escalate) because of an action taken for an unrelated cause.
# Sharing one counter between a count-indexed ladder and a cause-indexed rung
# makes each one's pacing depend on the other's traffic.
_SUP_ACT_NOT_RESTART="AND (signals IS NULL OR signals NOT LIKE '%\"rung\":\"restart\"%')"
_sup_act_history() {
  local name="$1" n last
  n=$(db "SELECT COUNT(*) FROM supervisor_events
          WHERE agent=$(sqlq "$name") AND event='action'
            ${_SUP_ACT_NOT_RESTART}
            AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
  last=$(db "SELECT COALESCE(strftime('%s', MAX(ts)), 0) FROM supervisor_events
             WHERE agent=$(sqlq "$name") AND event='action'
               ${_SUP_ACT_NOT_RESTART}
               AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
  echo "${n:-0} ${last:-0}"
}

# DIVE-3753: the rung-4 limiter's numerator — restarts of THIS seat inside
# _SUP_RESTART_WINDOW_H. Counts only rows the ladder actually EXECUTED
# (event='action'), never 'planned': a dormant tick must not spend the seat's
# restart budget on a restart it did not perform, or turning actions on would
# find every seat already rate-limited. Echoes a bare integer.
# DIVE-3964: how many CHANNEL repairs this seat has already been given in the
# window, read off the same audit trail as every other limiter — no extra state
# file. The count is fed back INTO the classifier rather than compared here, so
# the ceiling lives in exactly one place (and in the same place for the CLI and
# for the bridge's own TypeScript).
_sup_channel_repair_history() { # <name> -> integer
  local name="$1" n
  n=$(db "SELECT COUNT(*) FROM supervisor_events
          WHERE agent=$(sqlq "$name") AND event='action'
            AND signals LIKE '%\"rung\":\"channel-restart\"%'
            AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

_sup_restart_history() {
  local name="$1" n
  n=$(db "SELECT COUNT(*) FROM supervisor_events
          WHERE agent=$(sqlq "$name") AND event='action'
            AND signals LIKE '%\"rung\":\"restart\"%'
            AND ts >= datetime('now', '-${_SUP_RESTART_WINDOW_H} hours');" 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

# DIVE-3915: the UNHEALED numerator — restarts of this seat inside the window
# that ran and did NOT bring the poller back. Same population as
# _sup_restart_history minus the rows DIVE-3856 verified, i.e. minus
# '"result":"ok"'. Everything else counts: 'failed' (cmd_restart itself
# returned non-zero), 'restart-ran-poller-still-dead' (probed, still deaf) and
# 'restart-ran-poller-unverified' (no probe for this type — see the block
# comment; this is what keeps an unprobeable seat's ceiling exactly where it
# was). Rows written BEFORE DIVE-3856 shipped also carry '"result":"ok"' from
# the old exit-code semantics and are therefore treated as healed; they are at
# most one window old by the time this runs and mis-reading them costs one
# extra restart, never a missed escalation. Echoes a bare integer.
_sup_restart_unhealed_history() {
  local name="$1" n
  n=$(db "SELECT COUNT(*) FROM supervisor_events
          WHERE agent=$(sqlq "$name") AND event='action'
            AND signals LIKE '%\"rung\":\"restart\"%'
            AND signals NOT LIKE '%\"result\":\"ok\"%'
            AND ts >= datetime('now', '-${_SUP_RESTART_WINDOW_H} hours');" 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

# ── DIVE-4097: DOOR 2 — the P2 ladder holds for a seat behind a capacity wall ──
#
# The capacity wall has TWO doors and #798 (DIVE-4052) closed only door 1. Door 1
# is the quota-exhausted ALERT leg: it is now audited-row-only unless
# _SUP_QUOTA_ALERTS_FLAG is set, so no phone rings for a seat the tick actually
# CLASSIFIED as quota-exhausted. Door 2 is this ladder, and it was left wide open,
# because the string that opened this row is not classified quota-exhausted at all:
#
#   "Agent codex is stuck and needs a person — no-progress (rotation-disabled)"
#
# _sup_classify only reaches the quota-exhausted branch when the refusal is inside
# the pane window this tick reads (_SUP_QUOTA_PANE_LINES). On the ticks where the
# seat has scrolled past its own refusal — or has printed nothing at all, which is
# what a walled seat does — the very same wall classifies as stuck/no-progress, the
# ladder runs, and rung 3 escalates `rotation-disabled` to a human. The seat is not
# wedged; it is throttled and self-healing, and it resumes on its own.
#
# Worse than the page: those ticks were also SPENDING the ladder's attempt counter.
# Alternating classifications walked codex from rung 0 to rung 3 without a single
# tick's evidence that a nudge or a resume was ever the right remedy.
#
# THIS IS DELIBERATELY NOT A SELF-HEAL READING. Iterations 1-2 of this row built a
# horizon over _sup_quota_selfheal / _sup_quota_escalate_after / episode-first, and
# #798 deleted all three by lodar's decision: capacity alerting is answered
# per-CLASS, not per-shape. A per-shape decision procedure has nothing left to
# decide, so door 2 asks the one question that survives — *is this seat behind a
# capacity wall right now* — and holds. No horizon, no threshold, no new knob.
#
# TWO INPUTS, and note that neither is a clock read inside this function:
#
#   1. The AUDIT TRAIL. Door 1 files a quota-exhausted supervisor_events row every
#      _SUP_ALERT_WINDOW_H, unconditionally, for as long as the wall is up — #798
#      names that row as the whole of what still covers a walled seat. It is
#      therefore the only durable attestation of the wall, and it is exactly the
#      evidence the pane no longer carries on the tick that pages. Reused as the
#      hold's oracle AND as its expiry: outside that window the wall stopped being
#      re-attested, so the hold lapses on its own. This is the existing constant
#      that governs the re-filing; it is not a second threshold laid on top.
#   2. The PANE, via _sup_quota_deadline (which SURVIVES #798 — DIVE-3880
#      classification is untouched). A `lapsed` reading is a positive statement
#      that the refusal on screen has EXPIRED and the seat has resumed, so it
#      RELEASES the hold on the spot however fresh the audit row is. That is the
#      arm that stops this going quiet forever: a seat still not progressing after
#      its own wall demonstrably came down is genuinely stuck and pages.
#      (`live` and `unknown` never arrive here — _sup_classify routes both to
#      quota-exhausted, so a stuck row carrying a signature carries `lapsed`.)
#
# WHAT IT DOES NOT TOUCH: service-dead, tmux-dead and poller-dead act and escalate
# exactly as before. A walled seat can ALSO be genuinely dead, and a dead unit is
# the more specific reading — holding those would trade a false page for a missed
# outage. Only no-progress and loop-stuck, the two causes a capacity wall actually
# explains, can be held.
#
# THE BOUNDARY FAILURE MODE IS A NUDGE, NOT A PAGE, and that is by construction:
# a `defer` writes no action row (see the dispatch's `case "$verb" in defer`), so a
# held seat spends nothing and stays at attempt 0. If the hold lapses for one tick
# at the window edge, the ladder resumes at rung 0 — a nudge — never at rung 3.
#
# Pure: no db, no clock, no fleet. Echoes "true" or "false".
_sup_ladder_quota_hold() {  # <cause> <quota_deadline> <quota_row_age_sec>
  local cause="$1" deadline="${2:-}" age="${3:-}"
  case "$cause" in
    no-progress|loop-stuck) ;;
    *) printf 'false'; return 0 ;;
  esac
  # The pane says the refusal it is showing has already expired -> released.
  [[ "$deadline" == "lapsed" ]] && { printf 'false'; return 0; }
  # No attestation, or one this cannot read as a number -> never quieter than the
  # code without this function. Absence is not a hold.
  [[ "$age" =~ ^[0-9]+$ ]] || { printf 'false'; return 0; }
  (( age <= _SUP_ALERT_WINDOW_H * 3600 )) || { printf 'false'; return 0; }
  printf 'true'
}

# The db half of the above, split out for the same reason every other pure core in
# this file is: the decision is assertable without a fleet, and this one line is
# the only part that needs a store. Echoes the age in whole seconds of the seat's
# NEWEST quota-exhausted supervisor_events row, or empty when it has never had one
# (MAX(ts) over no rows is NULL and the whole expression prints empty). Any event
# kind counts — an `alert` row and a DIVE-3822 profile-flip `action` row are both
# the tick stating that it found this seat behind a capacity wall.
_sup_ladder_quota_age() {  # <agent>
  local name="$1" age
  age=$(db "SELECT CAST(strftime('%s','now') - strftime('%s', MAX(ts)) AS INTEGER)
            FROM supervisor_events
            WHERE agent=$(sqlq "$name") AND classification='quota-exhausted';" 2>/dev/null) || age=""
  [[ "$age" =~ ^-?[0-9]+$ ]] || age=""
  printf '%s' "$age"
}

# Pure decision, no side effects: echoes "verb [reason]" where verb is one of
# nudge|resume|rotate|restart|escalate|defer. Attempt N picks rung N+1; the gap
# before the next action is base * 2^attempts; ladder exhausted / unreachable
# rung => escalate.
#
# DIVE-3753: `restart` is rung 4 and it is CAUSE-indexed, not attempt-indexed —
# poller-dead does not respond to a nudge (there is no live channel to nudge
# through; that is the whole classification), so walking rungs 1-3 first would
# spend an hour of backoff on three actions that cannot work. It goes straight
# to restart, once, and the rate limit is what bounds it. The 7th parameter is
# the per-seat restart count already spent in _SUP_RESTART_WINDOW_H; it is
# OPTIONAL so every existing 6-arg caller keeps its exact meaning (0 spent).
#
# The 8th parameter is whether the ladder is ARMED ($_SUP_ACTIONS_FLAG). It is
# here rather than at the dispatch because of a regression this rung would
# otherwise ship: while actions are dormant every other rung degrades to a
# harmless 'planned' row, but poller-dead's PREVIOUS behaviour was `escalate
# rung-4-needed`, which is a COURIER-DELIVERED page to a human (DIVE-3727).
# Silently downgrading that to a planned row would take away the only thing
# serving this cause today and give back nothing until the flag is set — the
# opposite of the row. So a dormant ladder still escalates, and the reason
# string says the restart is the action it was holding.
_sup_act_plan() {  # <type> <cause> <attempts> <last_epoch> <now> <rotation_enabled> [unhealed_restarts] [actions_enabled] [total_restarts] [quota_hold]
  # $1 (type) is retained for signature/caller stability but no longer branches:
  # OSS-23 made the ladder runtime-agnostic (see block comment above). rung-4+
  # causes still escalate for every runtime via the case below; rotate
  # self-gates on rot regardless of type. So does restart: a seat is a systemd
  # unit whatever runtime it hosts.
  # shellcheck disable=SC2034
  local type="$1" cause="$2" attempts="$3" last="$4" now="$5" rot="$6" restarts="${7:-0}"
  local acts="${8:-true}"
  # DIVE-3915: $7 is now the UNHEALED restart count — restarts that ran and left
  # the poller dead — which is what _SUP_RESTART_MAX's written rationale was
  # always about. $9 is the TOTAL restart count in the window and is bounded
  # separately by _SUP_RESTART_TOTAL_MAX. It is OPTIONAL and defaults to $7, so
  # an 8-arg caller (and every existing test) keeps its exact previous meaning:
  # with total==unhealed, a seat at the unhealed ceiling is also at or under the
  # total ceiling, and the unhealed refusal is the one that fires.
  local total="${9:-$restarts}"
  # DIVE-4097: the 10th parameter is door 2's capacity hold, from
  # _sup_ladder_quota_hold. OPTIONAL and defaulting to false, so every existing
  # caller and every existing arm keeps its exact previous meaning.
  local qhold="${10:-false}"
  [[ "$restarts" =~ ^[0-9]+$ ]] || restarts=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  (( total >= restarts )) || total="$restarts"
  case "$cause" in
    # DIVE-4097 door 2: a seat behind a live capacity wall is throttled, not
    # wedged. Hold BEFORE the rungs so the attempt counter is not spent — a
    # `defer` writes no action row, which is what keeps a held seat at rung 0
    # instead of walking it to `escalate rotation-disabled`. Scoped to exactly
    # the two causes a capacity wall explains; see the block comment above
    # _sup_ladder_quota_hold for why the dead-signal causes are not held.
    no-progress|loop-stuck)
      [[ "$qhold" == "true" ]] && { echo "defer quota-hold"; return; }
      ;;
    # DIVE-3753 rung 4. The limiter's REFUSING branch escalates rather than
    # deferring: a deferral is silent and this is the seat that cannot report
    # its own unreachability, so "restarting did not fix it" has to leave the
    # ladder and reach a person (escalate carries DIVE-3727 courier delivery).
    poller-dead)
      if [[ "$acts" != "true" ]]; then
        # Dormant: keep the pre-DIVE-3753 human path exactly as it was, and name
        # the rung being held so the audit row still records what WOULD fire.
        echo "escalate rung-4-dormant"
      elif (( restarts >= _SUP_RESTART_MAX )); then
        # The remedy has already been tried inside the window and did not work
        # (or could not be verified). Unchanged reason string — a human reading
        # the trail for the last two months has learned what it means.
        echo "escalate restart-rate-limited"
      elif (( total >= _SUP_RESTART_TOTAL_MAX )); then
        # DIVE-3915: every restart in the window WORKED and the seat keeps
        # coming back for another. That is a different sentence to a human than
        # "restarting does not fix it", so it gets its own reason.
        echo "escalate restart-flapping"
      else
        echo "restart"
      fi
      return ;;
    # DIVE-974: stale-cli is update-pending, not stuck — it never reaches this
    # loop (gated on class=="stuck") but guard here too so no rung, including
    # escalate, can EVER fire on a stale-cli-only classification.
    stale-cli) echo "defer update-pending"; return ;;
    # DIVE-971: goal-drift is class=="drift", not "stuck", so it never reaches
    # this loop (gated on stuck) — guard here too so no rung, not even escalate,
    # can EVER fire on a drift classification.
    goal-drift) echo "defer goal-drift"; return ;;
    *) echo "escalate rung-4-needed"; return ;;
  esac
  (( attempts >= _SUP_ACT_MAX_ATTEMPTS )) && { echo "escalate ladder-exhausted"; return; }
  local gap=$(( _SUP_ACT_BASE_MIN * 60 * (1 << attempts) ))
  if (( last > 0 && now - last < gap )); then echo "defer backoff"; return; fi
  case "$attempts" in
    0) echo "nudge" ;;
    1) echo "resume" ;;
    2) if [[ "$rot" == "true" ]]; then echo "rotate"; else echo "escalate rotation-disabled"; fi ;;
  esac
}

# ── DIVE-3727: escalation DELIVERY — a path that does not traverse the sick seat ──
#
# DIVE-3726 measured the entire defect. The poller-dead classification for `main`
# was CORRECT, it fired, it wrote its audit row and its warn line — and it reached
# nobody, because the only channel that would have carried it to a human was
# `main`'s own dead Telegram. A seat cannot escalate its own unreachability
# through itself. Detection was never the gap; delivery was.
#
# So an escalation picks a COURIER: an enabled agent that is (a) NOT the sick seat
# and (b) not itself classified stuck in this same tick — routing a report about a
# dead seat through a second dead seat reproduces the bug one hop over. The
# candidate order comes from the tick's own snapshot, so no registry re-read and no
# org-chart walk can disagree with what was just classified.
#
# Two rails, tried in order, because they fail INDEPENDENTLY — that independence is
# the finding behind
# community/wiki/a-green-agent-can-still-be-unreachable-probe-the-poller-lock.md:
#
#   1. telegram — `_task_send_owner` under the COURIER's channel. Outbound
#      sendMessage and inbound getUpdates are separate halves of the Bot API, so a
#      courier reaches the paired human directly with no agent in the loop and no
#      dependence on the sick seat's poller. This is the rail that puts it in front
#      of a human within the tick.
#   2. a2a — `agent send` to the courier. Slower (a human sees it when the courier
#      relays) and it needs no channel state at all, which is exactly why it is the
#      fallback: the a2a rail was up throughout the DIVE-3726 outage, and that is
#      how DIVE-3726 was worked at all.
#
# `_task_send_owner`'s own fail-closed chokepoint (`_task_human_send_allowed`)
# still applies and is deliberately not bypassed: a fixture/e2e task DB must not
# reach a paired human just because the sender is the supervisor.
#
# Set SUPERVISOR_ESCALATE_DELIVER=0 to classify and audit exactly as before with
# no send — the knob a dry run or a fixture tick uses. It is NOT a way to silence a
# noisy escalation; the escalate row is already deduped to one per
# _SUP_ACT_WINDOW_H window, so delivery inherits that ceiling.
_SUP_ESC_DELIVER="${SUPERVISOR_ESCALATE_DELIVER:-1}"
[[ "$_SUP_ESC_DELIVER" =~ ^[01]$ ]] || _SUP_ESC_DELIVER=1

# Pure selection, no side effects — the whole point of factoring it out is that the
# "never through the sick seat" property is assertable without a fleet, a channel,
# or a network (same reason _sup_act_plan is pure).
# <sick> <stuck-csv> <all-csv> -> courier names, one per line, in preference order.
_sup_escalate_couriers() {
  local sick="$1" stuck="$2" all="$3" n
  local -a cand=()
  IFS=',' read -r -a cand <<<"$all"
  local -A seen=()
  for n in "${cand[@]}"; do
    [[ -n "$n" ]] || continue
    # The two exclusions this function exists for. Both are unconditional: there is
    # no "no other seat available, send it through the sick one anyway" fallback,
    # because that fallback IS the bug. Zero couriers must surface as zero couriers.
    [[ "$n" == "$sick" ]] && continue
    [[ ",${stuck}," == *",${n},"* ]] && continue
    [[ -n "${seen[$n]:-}" ]] && continue
    seen["$n"]=1
    printf '%s\n' "$n"
  done
}

# Pure: the text a human reads. Written for someone who is not at a terminal and
# does not know what a poller is — it names the seat, what is wrong, WHY the report
# arrived from a different bot than usual (otherwise it reads as a misroute), and
# the one command that re-checks it.
_sup_escalate_text() { # <sick> <cause> <reason> <courier>
  local sick="$1" cause="$2" reason="$3" courier="$4"
  printf '%s' "🚨 Agent '${sick}' is stuck and needs a person — ${cause} (${reason}).

You are getting this from '${courier}''s bot, not ${sick}'s, on purpose: ${sick} cannot be trusted to carry a report about itself being unreachable.

Re-check it:  5dive agent telegram-discover --agent=${sick} --poll-secs=8 --json
(a 409 \"terminated by other getUpdates request\" means it is actually ALIVE — read the message, not the exit code)

Full log: /var/log/5dive/supervisor-tick.log"
}

# One telegram attempt through <courier>. Returns 0 only on a CONFIRMED Bot API
# send (TASK_SEND_DELIVERED), never on "we tried" — an unconfirmed send is the
# silent-failure shape this row exists to remove, so it must fall through to a2a.
_sup_escalate_tg() { # <courier> <text>
  local courier="$1" text="$2"
  # Split-tree guard: tests source cmd_supervisor.sh alone, where the task notify
  # functions do not exist. Absent rail = this rail declines, not an error.
  declare -F _task_agent_channel >/dev/null 2>&1 || return 1
  declare -F _task_send_owner    >/dev/null 2>&1 || return 1
  _task_agent_channel "$courier" || return 1
  TASK_SEND_DELIVERED=0
  _task_send_owner "$text" "" "" || true
  [[ "${TASK_SEND_DELIVERED:-0}" == "1" ]]
}

# One a2a attempt through <courier>.
_sup_escalate_a2a() { # <courier> <text>
  local courier="$1" text="$2"
  declare -F cmd_send >/dev/null 2>&1 || return 1
  ( cmd_send "$courier" --message="$text" ) >/dev/null 2>&1
}

# Deliver one escalation. Echoes the delivery receipt ("telegram:<courier>",
# "a2a:<courier>", "none:<why>") on stdout so the caller can put it in the audit
# row's signals — the receipt is what makes "did this reach anyone?" answerable
# from the board later instead of only from a log line nobody reads.
# Never fails the tick: every rail is best-effort and one bad seat cannot abort.
_sup_escalate_deliver() { # <sick> <cause> <reason> <stuck-csv> <all-csv>
  local sick="$1" cause="$2" reason="$3" stuck="$4" all="$5"
  if [[ "$_SUP_ESC_DELIVER" != "1" ]]; then printf 'none:disabled'; return 0; fi
  local courier tried=0
  while IFS= read -r courier; do
    [[ -n "$courier" ]] || continue
    tried=$((tried + 1))
    local text; text=$(_sup_escalate_text "$sick" "$cause" "$reason" "$courier")
    if _sup_escalate_tg "$courier" "$text"; then printf 'telegram:%s' "$courier"; return 0; fi
    if _sup_escalate_a2a "$courier" "$text"; then printf 'a2a:%s' "$courier"; return 0; fi
  done < <(_sup_escalate_couriers "$sick" "$stuck" "$all")
  # Distinguish the two zero-delivery causes. "no courier" means every other seat
  # was stuck too (a fleet-wide event, and the operator needs to know that is what
  # they are looking at); "all rails failed" means couriers existed and none of
  # them could carry it. Collapsing those into one message is how DIVE-1968 lost 28
  # rows under 840 fixture ones.
  if (( tried == 0 )); then printf 'none:no-courier'; else printf 'none:all-rails-failed'; fi
  return 0
}

# Execute one rung. Returns nonzero, never exits — one bad agent can't abort
# the tick (rotation's fail() is contained in a subshell). Every rung is
# runtime-agnostic (OSS-23): the `agent-<name>` tmux session + registry are the
# same shape for claude/codex/grok/opencode/antigravity, so no per-type branch.
_sup_act_exec() {  # <name> <verb> <cause>
  local name="$1" verb="$2" cause="$3"
  case "$verb" in
    nudge)
      _hb_send_line "$name" "[supervisor] You look stalled (${cause}). Pick your in-progress task back up and continue; if genuinely blocked, say why on the task." ;;
    resume)
      # Clear a wedged modal/prompt first, then ask for plain continuation. Escape
      # is a safe universal dismiss across the runtime TUIs; "continue" is a
      # generic re-prompt every runtime accepts as pane input.
      sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Escape 2>/dev/null || return 1
      sleep 1
      _hb_send_line "$name" "continue" ;;
    answer-prompt)
      # DIVE-4293. NOT a rung on the stalled-seat ladder and never reached from
      # _sup_act_plan — the alert loop calls it directly, and ONLY after
      # _sup_prompt_recommended confirmed the HIGHLIGHTED option carries
      # "(Recommended)". Enter takes whatever the cursor is on, so that check is
      # the whole safety argument: without it this is a watchdog picking an
      # option at random on the agent's behalf.
      #
      # Enter and not Escape: Escape dismisses the picker and discards the
      # question, which is what `resume` does and why that rung is the wrong
      # remedy here (the model has already decided; it wants its own answer).
      sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter 2>/dev/null || return 1 ;;
    decline-prompt)
      # DIVE-4536. The confirm's sibling of answer-prompt, and the difference is
      # the whole safety argument: answer-prompt presses ENTER, which takes the
      # highlighted option, and is therefore only ever reached after
      # _sup_prompt_recommended proved the model marked that option itself.
      # Nothing is marked on a tool-permission confirm — the harness raised it
      # precisely because the command was flagged — so there is no option this
      # watchdog is entitled to TAKE. It is entitled to REFUSE one.
      #
      # ESCAPE AND NOT "2", Enter. Both land on the same outcome (the tool call
      # is denied and the model re-plans, which is what a human did by hand on
      # 2026-09-14 at 13:49Z — the seat resumed within seconds). Escape is the
      # footer's own documented cancel, it is one key, and it does not depend on
      # the cursor sitting where we think it is; pressing a DIGIT assumes the
      # numbering, and a confirm that ever renders its options in another order
      # turns that assumption into an approval. Fail-closed means the failure
      # mode of a mis-press must be "the command did not run", never "the
      # flagged command ran".
      #
      # Never Ctrl-C: that kills the turn, not the modal.
      sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Escape 2>/dev/null || return 1 ;;
    park-on-limit)
      # DIVE-4581. <cause> carries the SIGNED distance from the picker's cursor
      # row to its auto-resume option, computed by _sup_limit_picker_match from
      # the same capture that classified the seat. Cursor-relative and not a
      # fixed "Down, Enter" for the reason decline-prompt refuses to press a
      # digit: a fixed count assumes an option ORDER, and an order that ever
      # changes turns the assumption into "upgrade the plan" — a spend decision
      # made by a watchdog. A non-numeric distance never reaches here (the
      # caller skips on `unknown`); if one did, this refuses rather than guesses.
      local steps="$cause" key=Down i
      [[ "$steps" =~ ^-?[0-9]+$ ]] || return 1
      if (( steps < 0 )); then key=Up; steps=$(( -steps )); fi
      for (( i = 0; i < steps; i++ )); do
        sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" "$key" 2>/dev/null || return 1
      done
      sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter 2>/dev/null || return 1 ;;
    rotate)
      ( with_registry_lock cmd_agent_rotation_rotate "$name" ) >/dev/null 2>&1 ;;
    # DIVE-3753 rung 4. SUBSHELL, for the same reason rotate is one: cmd_restart
    # reaches `fail`/`require_agent`, and `fail` EXITS. Called bare, one seat
    # whose unit no longer exists would abort the whole tick — every later agent
    # in the loop goes unclassified and the fleet heartbeat row is never
    # written. In a subshell that same exit is a nonzero return, which the
    # caller already records as result:"failed".
    restart)
      ( cmd_restart "$name" ) >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# DIVE-3822: a quota-exhausted seat is recoverable when another configured
# profile has live headroom. Keep the machine-readable rotate result so the
# caller can distinguish a completed profile flip from the normal, successful
# "no eligible target" result. The latter must alert a person once rather than
# falling back into the stalled-seat nudge ladder.
_sup_quota_rotate() {  # <name>; 0=rotated, 1=no measured target, 2=failed
  local name="$1" out
  if ! out=$(JSON_MODE=1 with_registry_lock cmd_agent_rotation_rotate "$name" --require-live-headroom 2>/dev/null); then
    return 2
  fi
  if jq -e '.ok == true and .data.rotated == true' <<<"$out" >/dev/null 2>&1; then
    return 0
  fi
  if jq -e '.ok == true and .data.rotated == false' <<<"$out" >/dev/null 2>&1; then
    return 1
  fi
  return 2
}

# DIVE-4055: a wall observed while a seat owns live work is a checkpoint
# boundary, never an account-switch trigger.  Append the only claims automation
# can honestly make (the row/branch artifacts are preserved; the next attempt
# must resume by inspecting them), then requeue the row so the heartbeat's
# dispatch-boundary selector can choose an account before the next first turn.
#
# Returns 0=checkpointed, 1=no live row, 2=state/write unmeasured.  Callers must
# never rotate on 2: an unreadable task state is not proof that the seat is idle.
_SUP_QUOTA_CHECKPOINTED=0
_sup_quota_checkpoint_live_tasks() { # <name>
  local name="$1" n changed stamp note
  _SUP_QUOTA_CHECKPOINTED=0
  n=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='in_progress';" 2>/dev/null) || return 2
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  (( n > 0 )) || return 1
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || stamp="unknown-time"
  note="[${stamp}] quota-boundary checkpoint (DIVE-4055) — done: automatic account rotation was held before changing profiles; the task body and task-bound branch/worktree remain the durable work record. next: resume this row from its body, inspect the bound worktree, and continue only after dispatch-boundary headroom selection."
  changed=$(db "UPDATE tasks
      SET body = COALESCE(body,'')
                 || CASE WHEN COALESCE(body,'') = '' THEN '' ELSE char(10)||char(10) END
                 || $(sqlq "$note"),
          status='todo', started_at=NULL, updated_at=datetime('now')
      WHERE assignee=$(sqlq "$name") AND status='in_progress';
      SELECT changes();" 2>/dev/null) || return 2
  [[ "$changed" =~ ^[0-9]+$ ]] || return 2
  (( changed > 0 )) || return 2
  _SUP_QUOTA_CHECKPOINTED="$changed"
  return 0
}

# ── DIVE-4536: the declined confirm goes ON THE ROW, not only in the log ─────
#
# A supervisor_events row records that the FLEET did something. The seat that
# wakes next needs to know that one of its tool calls was refused by a watchdog
# while it was not looking, or it re-plans blind and the most likely re-plan is
# to run the same flagged command again. `task show` and the digest read the
# body; nothing reads /var/log/5dive/supervisor-tick.log on the way into a turn.
#
# Body-append only: status, assignee and started_at are untouched. Declining a
# tool call does not un-start a row — the seat is still holding it and is about
# to keep working it. (Contrast _sup_quota_checkpoint_live_tasks, which requeues,
# because a walled seat cannot continue at all.)
#
# Best-effort by construction: no live row, or a write that fails, returns
# nonzero and the caller neither retries nor alerts on it. The keystroke has
# already landed; a missing note must not turn a successful decline into a
# failed one.
_sup_confirm_note_row() {  # <name> <excerpt> <result>
  local name="$1" excerpt="$2" result="$3" n stamp note changed
  n=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='in_progress';" 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( n > 0 )) || return 1
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || stamp="unknown-time"
  note="[${stamp}] supervisor DECLINED a tool-permission confirm on this seat (DIVE-4536). The pane had been standing on \"${excerpt}\" with no transcript progress for ${_SUP_T_CONFIRM_DWELL_MIN}m+, so the watchdog pressed Escape (result: ${result}) — the SAFE option, never Yes. The flagged command did NOT run. If that command was genuinely needed, re-plan it in a form that does not trip the guard (name the path, avoid an unset variable in an rm), or put the decision on a task gate; do not simply re-issue it and wait for someone to press Yes."
  changed=$(db "UPDATE tasks
      SET body = COALESCE(body,'')
                 || CASE WHEN COALESCE(body,'') = '' THEN '' ELSE char(10)||char(10) END
                 || $(sqlq "$note"),
          updated_at=datetime('now')
      WHERE assignee=$(sqlq "$name") AND status='in_progress';
      SELECT changes();" 2>/dev/null) || return 1
  [[ "$changed" =~ ^[0-9]+$ ]] && (( changed > 0 ))
}

# ── DIVE-3667: fleet rollup — count EVERY class, not a hand-picked five ──────
#
# The tick's rollup used to enumerate healthy/slow/stuck/drift/verify-challenge
# by hand. `stalled` was in none of them, so the one class that means ACTIONABLE
# WORK IS STRANDED ON A SEAT THAT IS NOT WORKING IT had zero unattended surface:
# not counted, not printed, not in the heartbeat row's signals, and — unlike
# no-output and quota-exhausted — not on the alert path either. The board
# (_sup_render_board / _sup_summary_line) printed it correctly the whole time;
# only the cron form, the one that runs with nobody watching, dropped it.
#
# Measured 2026-08-22 (DIVE-3665): supervisor_events held six consecutive
# observe/stalled/idle-stranded rows for one seat holding a delivered, unstarted
# high-priority row, while supervisor-tick.log printed
#   "17 agents — 16 healthy / 0 slow / 0 drift / 0 stuck"
# every 10 minutes. The ONLY symptom was a total that did not add up, which
# reads as a rounding artifact rather than as stranded work.
#
# These three helpers are deliberately pure and separately callable: the
# counting is a `group_by` over whatever classes the classifier actually
# emitted, and `unclassified` is what keeps a class added AFTER this commit from
# disappearing the same way. Adding a class no longer requires editing the
# rollup — it requires nothing.

# _sup_rollup_counts <snap-json>
# Emits ten tab-separated counts, in this fixed order:
#   healthy slow stuck drift verify-challenge stalled no-output update-pending
#   quota-exhausted unprobed unclassified
# `unclassified` is total minus the ten named — it is the invariant that makes
# the printed buckets sum to the agent count, and the alarm for a new class.
#
# DIVE-4342 it.2: `unprobed` is NAMED here rather than left to fall into
# `unclassified`. It would have degraded the fleet either way (see
# _sup_fleet_class), but a heartbeat row that says "1 unclassified" reads as an
# unknown class needing investigation, and this one is a known state with a
# known remedy — run the tick as root.
_sup_rollup_counts() {
  local snap="${1:-[]}"
  jq -r '
    (length) as $total
    | ([.[].classification] | group_by(.) | map({key:.[0],value:length}) | from_entries) as $c
    | [ ($c.healthy // 0), ($c.slow // 0), ($c.stuck // 0), ($c.drift // 0),
        ($c["verify-challenge"] // 0), ($c.stalled // 0), ($c["no-output"] // 0),
        ($c["update-pending"] // 0), ($c["quota-exhausted"] // 0),
        ($c.unprobed // 0) ]
    | . + [ ($total - add) ] | @tsv' <<<"$snap"
}

# _sup_fleet_class <the eleven counts, in _sup_rollup_counts order>
# The `(fleet)` heartbeat row's verdict. It takes ALL eleven deliberately, so the
# classes it does NOT count are an explicit, testable choice rather than an
# argument someone forgot to pass:
#   healthy        — the baseline
#   drift          — a /goal pointing at the wrong row; "recorded, NEVER acted on"
#   update-pending — "an update signal, NOT a wedged agent"; a fleet-wide publish
#                    would otherwise paint every box degraded for a night
# Everything else means WORK IS NOT MOVING, and that is what degraded means here.
_sup_fleet_class() {  # <healthy> <slow> <stuck> <drift> <vchal> <stalled> <nooutput> <updpend> <quota> <unprobed> <other>
  local slow="${2:-0}" stuck="${3:-0}" vchal="${5:-0}" stalled="${6:-0}"
  local nooutput="${7:-0}" quota="${9:-0}" unprobed="${10:-0}" other="${11:-0}"
  # DIVE-4342 it.2: `unprobed` degrades. It is NOT a claim that work stopped —
  # it is the fleet verdict declining to certify a fleet it could not observe,
  # which is the same reason `other` is in this sum.
  (( slow + stuck + vchal + stalled + nooutput + quota + unprobed + other > 0 )) \
    && { printf 'degraded'; return; }
  printf 'healthy'
}

# _sup_rollup_extra <stalled> <nooutput> <updpend> <quota> <other>
# Suffix appended to the tick's log line. The four original buckets keep their
# exact position ahead of this so anything already parsing the line still
# parses; these appear only when non-zero, so a clean fleet's line does not grow.
_sup_rollup_extra() {
  local out=""
  (( ${1:-0} > 0 )) && out+=" / ${1} stalled"
  (( ${2:-0} > 0 )) && out+=" / ${2} no-output"
  (( ${3:-0} > 0 )) && out+=" / ${3} update-pending"
  (( ${4:-0} > 0 )) && out+=" / ${4} quota-exhausted"
  (( ${5:-0} > 0 )) && out+=" / ⚠ ${5} unclassified"
  printf '%s' "$out"
}

cmd_supervisor_tick() {
  require_root "supervisor --tick"
  if [[ ! -f "$_SUP_ENABLED_FLAG" ]]; then
    # DIVE-2306: name what the no-op costs, rather than only what it skips. This
    # tick is the only caller guaranteed to run as root and therefore guaranteed
    # able to WRITE the DIVE-2287 version record; `update --check` runs as an
    # operator and degrades to `unknown` on a STATE_DIR it cannot write. So on a
    # box where the tick is off, the freeze alarm may have no writer at all —
    # and an alarm with no writer reports `unknown` forever, which reads exactly
    # like a monitor that has simply not fired yet. Stated here, and again in
    # `update --check` / the board / the digest as `frozenArmed:false`, because
    # a notice on a disabled cron path is seen by nobody by construction.
    ok "supervisor tick: disabled — observe pass skipped (enable: sudo touch ${_SUP_ENABLED_FLAG}) · the DIVE-2287 version-freeze record is not being refreshed by this tick; if no other caller can write it, the freeze alarm is unarmed on this box" \
       '{enabled:false, skipped:true, freezeRecordRefreshed:false}'
    return 0
  fi
  tasks_db_init
  _sup_cli_check   # in this shell, not the $(…) subshell — see _sup_snapshot
  local snap; snap=$(_sup_snapshot)
  local events=0 row name class cause last
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    name=$(jq -r '.name' <<<"$row")
    class=$(jq -r '.classification' <<<"$row")
    cause=$(jq -r '.cause // ""' <<<"$row")
    last=$(db "SELECT classification FROM supervisor_events WHERE agent=$(sqlq "$name") ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    [[ -n "$last" ]] || last="healthy"
    if [[ "$class" != "$last" ]]; then
      db "INSERT INTO supervisor_events (agent, event, classification, cause, prev_classification, signals)
          VALUES ($(sqlq "$name"), 'transition', $(sqlq "$class"), $(sqlq_or_null "$cause"), $(sqlq "$last"), $(sqlq "$row"));" \
        2>/dev/null && events=$((events + 1)) || warn "supervisor: transition insert failed for $name"
    fi
    if [[ "$class" != "healthy" ]]; then
      db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
          VALUES ($(sqlq "$name"), 'observe', $(sqlq "$class"), $(sqlq_or_null "$cause"), $(sqlq "$row"));" \
        2>/dev/null && events=$((events + 1)) || warn "supervisor: observe insert failed for $name"
    fi
  done < <(jq -c '.[]' <<<"$snap")

  local actions_on="false" quota_alerts_on="false" acted=0 planned=0 escalated=0 now_s
  [[ -f "$_SUP_ACTIONS_FLAG" ]] && actions_on="true"
  [[ -f "$_SUP_QUOTA_ALERTS_FLAG" ]] && quota_alerts_on="true"
  now_s=$(date +%s)
  local reg_now; reg_now=$(registry_read)

  # ── DIVE-1127: ID/age-verification tripwire — SAME-DAY alert (not the P2 ladder).
  # A verification challenge is not "wedged compute" you nudge/resume/rotate out of;
  # it is an account-state event whose only response is a human/runbook flip. So it
  # gets its own alert path, always live when the tick is enabled (no actions flag),
  # deduped one alert per account per _SUP_ALERT_WINDOW_H, and audited as event='alert'.
  local alerted=0
  # DIVE-4551: per-tick, because the alert helpers below bump it as a global
  # (the loop runs in this shell — process substitution, not a pipe — so the
  # count survives to the summary line and the heartbeat row).
  _SUP_ALERTS_UNDELIVERABLE=0
  # DIVE-4666: same per-tick reset, same reason.
  _SUP_ALERTS_QUIETED=0
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    # DIVE-3272: the same always-live, deduped alert path carries the capacity
    # classes. DIVE-3822 adds one narrow recovery before quota-exhausted reaches
    # that alert: rotation to a destination with measured live headroom. It
    # never enters the stalled-seat nudge/resume ladder.
    local cls; cls=$(jq -r '.classification' <<<"$row")
    case "$cls" in verify-challenge|no-output|quota-exhausted|blocked-on-prompt) ;; *) continue ;; esac
    name=$(jq -r '.name' <<<"$row")
    local excerpt cause_s
    case "$cls" in
      verify-challenge)  excerpt=$(jq -r '.signals.verifyChallenge // ""' <<<"$row"); cause_s="id-verification" ;;
      quota-exhausted)   excerpt=$(jq -r '.detail // ""' <<<"$row");                  cause_s="quota-exhausted" ;;
      blocked-on-prompt) excerpt=$(jq -r '.detail // ""' <<<"$row");                  cause_s="blocked-on-prompt" ;;
      *)                 excerpt=$(jq -r '.detail // ""' <<<"$row");                  cause_s="no-output" ;;
    esac

    # DIVE-4293: a blocked picker has one automatic remedy and it is bounded —
    # press Enter, but ONLY when the highlighted option is the model's own
    # "(Recommended)" one. Placed here rather than on the nudge/resume ladder
    # because that ladder is gated on class=="stuck" and both of its early rungs
    # are actively wrong for a pane waiting on a key (see _sup_act_exec).
    #
    # NOT deduped against the alert window: it is an ACT, and an act that worked
    # removes its own trigger (the picker is gone next tick). A seat that comes
    # back blocked is blocked on a NEW question and owes another answer.
    # Unmarked pickers are never answered — they fall straight through to the
    # page below, which is the whole point of the row: a person chooses.
    if [[ "$cls" == "blocked-on-prompt" ]]; then
      local prompt_mark_s; prompt_mark_s=$(jq -r '.signals.promptMark // ""' <<<"$row")
      # DIVE-4536: the declinable confirm, handled before the answerable picker
      # because the two marks are disjoint and this one must never reach a
      # branch whose remedy is Enter. Not deduped, for the same reason
      # answer-prompt is not: an act that worked removes its own trigger, and a
      # seat that comes back on a confirm is standing at a NEW one.
      if [[ "$prompt_mark_s" == "confirm" && "$actions_on" == "true" ]]; then
        local dec_result="ok"
        _sup_act_exec "$name" decline-prompt "dangerous-confirm" || dec_result="failed"
        db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
            VALUES ($(sqlq "$name"), 'action', 'blocked-on-prompt', 'dangerous-confirm',
                    $(sqlq "{\"rung\":\"decline-prompt\",\"result\":\"${dec_result}\",\"key\":\"Escape\"}"));" 2>/dev/null \
          && { acted=$((acted + 1)); events=$((events + 1)); } \
          || warn "supervisor: decline-prompt audit insert failed for $name"
        # The row the seat was frozen ON is where this belongs — the digest and
        # `task show` are read by whoever picks the row up next, and a declined
        # tool call the model has to re-plan around is a fact about the WORK.
        _sup_confirm_note_row "$name" "$excerpt" "$dec_result"
        if [[ "$dec_result" == "ok" ]]; then
          warn "supervisor: DECLINED $name — tool-permission confirm, pressed Escape (the safe option)"
          # RECURRENCE IS THE ESCALATION, and it is the reason this act is safe
          # to leave unattended. One decline is a watchdog unsticking a seat. A
          # seat that stands on a confirm again within the hour is a seat whose
          # model keeps re-issuing a flagged command, and pressing Escape at it
          # forever is the same silent loop this row exists to end — so the
          # THIRD one inside the window stops being quiet and falls through to
          # the page below. The audited row for THIS decline is already
          # inserted, so the count includes it.
          local recent_dec
          recent_dec=$(db "SELECT COUNT(*) FROM supervisor_events
                           WHERE agent=$(sqlq "$name") AND event='action'
                             AND cause='dangerous-confirm'
                             AND ts >= datetime('now', '-1 hours');" 2>/dev/null || echo 0)
          [[ "$recent_dec" =~ ^[0-9]+$ ]] || recent_dec=0
          if (( recent_dec < 3 )); then continue; fi
          excerpt="${excerpt}; DECLINED ${recent_dec}x in the last hour — this seat keeps re-issuing a flagged command and a keypress is not the fix"
        else
          excerpt="${excerpt}; auto-decline failed to reach the pane"
        fi
      elif [[ "$prompt_mark_s" == "confirm" ]]; then
        excerpt="${excerpt}; automatic actions are disabled"
      fi
      local prompt_rec; prompt_rec=$(jq -r '.signals.promptRecommended // false' <<<"$row")
      if [[ "$prompt_rec" == "true" && "$actions_on" == "true" ]]; then
        local ans_result="ok"
        _sup_act_exec "$name" answer-prompt "blocked-on-prompt" || ans_result="failed"
        db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
            VALUES ($(sqlq "$name"), 'action', 'blocked-on-prompt', 'blocked-on-prompt',
                    $(sqlq "{\"rung\":\"answer-prompt\",\"result\":\"${ans_result}\",\"recommended\":true}"));" 2>/dev/null \
          && { acted=$((acted + 1)); events=$((events + 1)); } \
          || warn "supervisor: answer-prompt audit insert failed for $name"
        if [[ "$ans_result" == "ok" ]]; then
          warn "supervisor: ANSWERED $name — blocked-on-prompt, took the highlighted (Recommended) option"
          continue
        fi
        excerpt="${excerpt}; auto-answer failed to reach the pane"
      elif [[ "$prompt_rec" == "true" ]]; then
        excerpt="${excerpt}; automatic actions are disabled"
      fi
    fi

    # DIVE-4581: the usage-limit HOLD PICKER, handled before the rotation branch
    # and ending the row here — no page, whatever happens. Three FLEET-HEALTH
    # pages reached a phone in one evening for this state; the wall prints when
    # it ends, so the only thing owed is the keypress that parks the seat on it.
    # Ahead of rotation on purpose: flipping the profile under an OPEN picker
    # leaves the picker open and the seat still frozen, so the keypress is the
    # more specific remedy and it removes its own trigger.
    if [[ "$cls" == "quota-exhausted" ]]; then
      local lp_mark; lp_mark=$(jq -r '.signals.promptMark // ""' <<<"$row")
      if [[ "$lp_mark" == limit-picker:* ]]; then
        local lp_steps="${lp_mark#limit-picker:}" lp_result="ok" recent_lp
        if [[ "$actions_on" != "true" ]]; then
          lp_result="skipped-actions-off"
        elif [[ "$lp_steps" == "unknown" ]]; then
          lp_result="skipped-no-cursor"
        else
          _sup_act_exec "$name" park-on-limit "$lp_steps" || lp_result="failed"
        fi
        # The KEYSTROKE is attempted every tick the picker still stands (an act
        # that worked removes its own trigger), but the audited row is filed at
        # most once per alert window per seat — that row is what the digest and
        # `agent info` read, and a parked seat must not write a line every ten
        # minutes for the hours a weekly wall lasts.
        recent_lp=$(db "SELECT COUNT(*) FROM supervisor_events
                        WHERE agent=$(sqlq "$name") AND event='action' AND cause='limit-picker'
                          AND ts >= datetime('now', '-${_SUP_ALERT_WINDOW_H} hours');" 2>/dev/null || echo 0)
        [[ "$recent_lp" =~ ^[0-9]+$ ]] || recent_lp=0
        if (( recent_lp == 0 )); then
          db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
              VALUES ($(sqlq "$name"), 'action', 'quota-exhausted', 'limit-picker',
                      $(sqlq "{\"rung\":\"park-on-limit\",\"result\":\"${lp_result}\",\"steps\":\"${lp_steps}\"}"));" 2>/dev/null \
            && { acted=$((acted + 1)); events=$((events + 1)); } \
            || warn "supervisor: park-on-limit audit insert failed for $name"
        fi
        if [[ "$lp_result" == "ok" ]]; then
          warn "supervisor: PARKED $name — usage-limit hold, took the wait-and-resume option (no page: the wall names its own reset)"
        else
          warn "supervisor: usage-limit hold on $name — ${lp_result}; the seat waits for its own reset (no page)"
        fi
        continue
      fi
    fi

    # DIVE-3822: quota exhaustion is the one capacity class with an automatic
    # remedy. It bypasses the stalled-seat nudge ladder and asks the existing
    # rotation selector for a destination whose live pane shows headroom. A
    # successful flip is quiet; no measured destination (or a failed rotate)
    # falls through to the same 24h-deduped human alert as before.
    if [[ "$cls" == "quota-exhausted" && "$actions_on" == "true" ]]; then
      local quota_rot qrc=0 checkpoint_rc=0
      quota_rot=$(jq -r --arg n "$name" '.agents[$n].rotation.enabled // false' <<<"$reg_now")
      if [[ "$quota_rot" == "true" ]]; then
        # The live-row check is immediately adjacent to the old destructive
        # call.  A read/write failure refuses the flip and falls through to the
        # existing capacity alert; only a measured zero reaches rotation.
        _sup_quota_checkpoint_live_tasks "$name" || checkpoint_rc=$?
        if (( checkpoint_rc == 0 )); then
          if db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
                 VALUES ($(sqlq "$name"), 'action', 'quota-exhausted', 'quota-exhausted',
                         $(sqlq "{\"rung\":\"checkpoint\",\"result\":\"requeued\",\"liveTasks\":${_SUP_QUOTA_CHECKPOINTED}}"));" 2>/dev/null; then
            acted=$((acted + 1)); events=$((events + 1))
          else
            warn "supervisor: quota checkpoint audit insert failed for $name"
          fi
          continue
        elif (( checkpoint_rc == 2 )); then
          excerpt="${excerpt}; live-task state/checkpoint unmeasured — account rotation refused"
        elif _sup_quota_rotate "$name"; then
          if db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
                 VALUES ($(sqlq "$name"), 'action', 'quota-exhausted', 'quota-exhausted',
                         $(sqlq "{\"rung\":\"rotate\",\"result\":\"ok\",\"measuredTarget\":true}"));" 2>/dev/null; then
            acted=$((acted + 1)); events=$((events + 1))
          else
            warn "supervisor: quota rotation insert failed for $name"
          fi
          continue
        else
          qrc=$?
          if (( qrc == 1 )); then
            excerpt="${excerpt}; no measured-eligible rotation target"
          else
            excerpt="${excerpt}; measured-target rotation failed"
          fi
        fi
      else
        excerpt="${excerpt}; rotation is disabled"
      fi
    elif [[ "$cls" == "quota-exhausted" ]]; then
      excerpt="${excerpt}; automatic actions are disabled"
    fi
    local prev_alert
    # Dedup is scoped BY CLASS (DIVE-3272): a seat can be both quota-walled and
    # output-dry, and an unscoped window would let whichever fired first
    # suppress the other for a day.
    prev_alert=$(db "SELECT COUNT(*) FROM supervisor_events
                     WHERE agent=$(sqlq "$name") AND event='alert'
                       AND classification=$(sqlq "$cls")
                       AND ts >= datetime('now', '-${_SUP_ALERT_WINDOW_H} hours');" 2>/dev/null || echo 0)
    [[ "$prev_alert" =~ ^[0-9]+$ ]] || prev_alert=0
    # DIVE-4052 retires DIVE-3970 part 2 (the episode-expiry escalation) with the
    # mute it existed to escape. Part 2 let exactly one extra alert through a
    # dedup window when a muted wall outlived the reset it had promised, so that
    # a wall which never resets could not go permanently silent. There is now no
    # human leg left for it to restore — the sentinel is the whole policy for
    # this class — and leaving it wired would have been half a change. It also
    # had a defect worth naming, since a reader will otherwise assume this cost
    # us cover: on a SHARED profile (mp-team) that walls every 5h window, the
    # episode chain never breaks, so the horizon expires while the wall is still
    # self-healing and the escalation announces a hard wall that the very pane
    # it quotes says is resuming at 5pm (observed 2026-09-08 ~16:45Z).
    #
    # What still covers a genuinely stuck seat: the audited supervisor_events
    # row, filed every window, unconditionally, for as long as the wall is up.
    # That is the DIVE-3272 cover and it is QUERYABLE — `5dive agent info` and
    # the digest both read it. What changed is only that nobody is PINGED.
    if (( prev_alert > 0 )); then continue; fi
    local notify_human notify_machine
    # DIVE-4666: the seat's KNOWN wall, resolved once per alerting seat. Read
    # even for the classes it cannot quieten, because the `lapsed` reading is
    # what lets the page say when the wall ended instead of asking the reader.
    local wall_state wall_reset queue_behind
    IFS=$'\x1f' read -r wall_state wall_reset <<<"$(_sup_wall_state "$name")"
    notify_human=$(_sup_capacity_notify_human "$cls" "$quota_alerts_on" "$wall_state")
    notify_machine=$(_sup_capacity_notify_machine "$cls" "$quota_alerts_on" "$wall_state")
    queue_behind=$(_sup_queue_behind "$name")
    if [[ "$cls" == "verify-challenge" ]]; then
      _sup_verify_alert "$name" "$excerpt"
    elif [[ "$cls" == "blocked-on-prompt" ]]; then
      _sup_prompt_alert "$name" "$excerpt" "$(jq -r '.cause // "blocked-on-prompt"' <<<"$row")"
    else
      # A GUARD THAT SUPPRESSES AN ACTION LOGS THE ACTION'S NAME (the wiki page
      # of that title). One line per quietened seat per window — the row's
      # "at most one digest line" — and it names the class it withheld, the
      # wall, and when the seat is due back, so a reader of supervisor-tick.log
      # can tell "quiet because known" from "quiet because broken". The
      # audited supervisor_events row below is filed either way.
      if [[ "$notify_human" != "true" && "$notify_machine" != "true" && "$wall_state" == "cooling" ]]; then
        _SUP_ALERTS_QUIETED=$(( _SUP_ALERTS_QUIETED + 1 ))
        warn "supervisor: QUIET ${name} — withheld the ${cls} page: known usage wall, back at $(if declare -f quota_wall_when >/dev/null 2>&1; then quota_wall_when "$wall_reset"; else printf '%s' "$wall_reset"; fi)$(if [[ -n "$queue_behind" ]]; then printf ' (queued behind it: %s)' "$queue_behind"; fi)"
      fi
      _sup_capacity_alert "$name" "$cls" "$excerpt" "$notify_human" "$notify_machine" \
                          "$wall_state" "$wall_reset" "$queue_behind"
    fi
    db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
        VALUES ($(sqlq "$name"), 'alert', $(sqlq "$cls"), $(sqlq "$cause_s"), $(sqlq "$row"));" 2>/dev/null \
      && { alerted=$((alerted + 1)); events=$((events + 1)); } \
      || warn "supervisor: $cls alert insert failed for $name"
    warn "supervisor: ALERT $name — $cls: $excerpt"
  done < <(jq -c '.[]' <<<"$snap")

  # ── DIVE-3964: CHANNEL BINDING — repair what a restart can fix, report the rest.
  #
  # This is its own loop and not a rung on the P2 ladder for the same reason the
  # DIVE-1127 tripwire is: the ladder is a response to WEDGED COMPUTE, escalating
  # nudge -> resume -> rotate -> restart against a seat that is not progressing.
  # A seat whose channels are deaf is progressing perfectly — it simply cannot be
  # reached — so it never classifies `stuck` and the ladder never looks at it.
  # That was the DIVE-4036 shape exactly: every liveness signal green, the seat
  # working, nobody able to talk to it for 2.2 days.
  #
  # The verdict decides, not this loop: `repair` is `restart` only for a cause a
  # restart can plausibly fix, and the classifier withdraws it once the attempts
  # in the window are spent (fed in above as the attempt count). So a dead token,
  # a refused account or a record this build cannot parse is REPORTED and never
  # retried, and no condition can be restart-looped.
  local chan_repaired=0 chan_reported=0
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    local cb_state cb_detail cb_repair cb_name cb_prior
    cb_state=$(jq -r '.signals.channelBinding.state  // ""' <<<"$row" 2>/dev/null) || continue
    [[ -n "$cb_state" && "$cb_state" != "bound" && "$cb_state" != "n/a" ]] || continue
    cb_name=$(jq -r '.name' <<<"$row")
    cb_detail=$(jq -r '.signals.channelBinding.detail // ""' <<<"$row")
    cb_repair=$(jq -r '.signals.channelBinding.repair // "report"' <<<"$row")
    if [[ "$cb_repair" == "restart" && "$actions_on" == "true" ]]; then
      local cb_rc=0 cb_res="ok"
      _sup_act_exec "$cb_name" "restart" "channel-$cb_state" || { cb_rc=$?; cb_res="failed"; }
      db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
          VALUES ($(sqlq "$cb_name"), 'action', 'channels', $(sqlq "channel-$cb_state"),
                  $(sqlq "{\"rung\":\"channel-restart\",\"result\":\"${cb_res}\",\"detail\":$(jq -Rc . <<<"$cb_detail")}"));" 2>/dev/null \
        && { chan_repaired=$((chan_repaired + 1)); acted=$((acted + 1)); events=$((events + 1)); } \
        || warn "supervisor: channel action insert failed for $cb_name"
      warn "supervisor: CHANNEL REPAIR $cb_name — $cb_state: $cb_detail — restarted ($cb_res)"
      continue
    fi
    # REPORT. Deduped per agent per window like the other always-live alerts, so
    # a condition a restart cannot fix pages once and then stays on the board.
    cb_prior=$(db "SELECT COUNT(*) FROM supervisor_events
                   WHERE agent=$(sqlq "$cb_name") AND event='alert' AND classification='channels'
                     AND ts >= datetime('now', '-${_SUP_ALERT_WINDOW_H} hours');" 2>/dev/null || echo 0)
    [[ "$cb_prior" =~ ^[0-9]+$ ]] || cb_prior=0
    (( cb_prior > 0 )) && continue
    db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
        VALUES ($(sqlq "$cb_name"), 'alert', 'channels', $(sqlq "channel-$cb_state"), $(sqlq "$row"));" 2>/dev/null \
      && { chan_reported=$((chan_reported + 1)); alerted=$((alerted + 1)); events=$((events + 1)); } \
      || warn "supervisor: channel alert insert failed for $cb_name"
    warn "supervisor: CHANNEL ALERT $cb_name — $cb_state: $cb_detail$(if [[ "$actions_on" != "true" && "$cb_repair" == "restart" ]]; then printf ' (a restart would be attempted, but actions are dormant)'; fi)"
  done < <(jq -c '.[]' <<<"$snap")

  # ── P2 (DIVE-857): ACT + ESCALATE — pre-cleared by lodar 2026-07-02, gated on
  # $_SUP_ACTIONS_FLAG until the audit week (started 2026-07-02) is clean.
  # Dormant mode writes 'planned' rows: the Jul 9 review reads exactly what the
  # ladder WOULD have done all week. reprovision stays manual; restart is rung 4
  # since DIVE-3753 and rides this same dormancy flag.
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    class=$(jq -r '.classification' <<<"$row")
    [[ "$class" == "stuck" ]] || continue
    name=$(jq -r '.name' <<<"$row"); cause=$(jq -r '.cause // ""' <<<"$row")
    local atype rot attempts last plan verb reason
    atype=$(jq -r '.type' <<<"$row")
    rot=$(jq -r --arg n "$name" '.agents[$n].rotation.enabled // false' <<<"$reg_now")
    read -r attempts last <<<"$(_sup_act_history "$name")"
    # DIVE-3753: the rung-4 limiter reads its own counter (restart rows only),
    # so it is not perturbed by, and does not perturb, the 1-3 attempt count.
    # DIVE-3915: TWO numerators, because a restart that worked and a restart that
    # did not are different evidence. `unhealed` is the ceiling that means "the
    # remedy is not working, get a person"; `restarts` (all outcomes) is the flap
    # bound that means "the remedy keeps being needed, get a person". Both are
    # read off the same audit trail, still with no extra state file.
    local restarts unhealed
    restarts=$(_sup_restart_history "$name")
    unhealed=$(_sup_restart_unhealed_history "$name")
    # DIVE-4097 door 2: is this seat behind a capacity wall right now? The pane
    # signal comes off THIS tick's snapshot row (so it is the same judgement the
    # alert loop made ten lines up), the audit signal off the trail door 1 keeps.
    local qdl qage qhold
    qdl=$(jq -r '.signals.quotaDeadline // ""' <<<"$row" 2>/dev/null) || qdl=""
    qage=$(_sup_ladder_quota_age "$name")
    qhold=$(_sup_ladder_quota_hold "$cause" "$qdl" "$qage")
    plan=$(_sup_act_plan "$atype" "$cause" "$attempts" "$last" "$now_s" "$rot" "$unhealed" "$actions_on" "$restarts" "$qhold")
    # A hold that swallows a page must SAY what it swallowed. A silent suppression
    # is the DIVE-3208 failure shape one layer over: nothing reads unit state, so
    # a mute nobody can see is indistinguishable from a detector that stopped
    # working. Only warn when the hold actually changed the outcome.
    if [[ "$qhold" == "true" ]]; then
      local unheld
      unheld=$(_sup_act_plan "$atype" "$cause" "$attempts" "$last" "$now_s" "$rot" "$unhealed" "$actions_on" "$restarts")
      case "$unheld" in
        defer*|"") : ;;
        *) warn "supervisor: HELD $name — behind a capacity wall (${cause}); would have: ${unheld}" ;;
      esac
    fi
    read -r verb reason <<<"$plan"
    case "$verb" in
      defer|"") continue ;;
      escalate)
        local esc
        esc=$(db "SELECT COUNT(*) FROM supervisor_events
                  WHERE agent=$(sqlq "$name") AND event='escalate'
                    AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
        (( esc > 0 )) && continue
        # DIVE-3727: DELIVER before recording, so the audit row carries the receipt
        # rather than only the intent. Ordering matters: a row written first and a
        # send that then fails is indistinguishable on the board from a send that
        # worked, which is the exact ambiguity DIVE-3726 was diagnosed through.
        # Candidates come from THIS tick's snapshot, so "who else is stuck" is the
        # same judgement that produced this escalation.
        local esc_stuck esc_all esc_via
        esc_stuck=$(jq -r '[.[] | select(.classification == "stuck") | .name] | join(",")' <<<"$snap" 2>/dev/null) || esc_stuck=""
        esc_all=$(jq -r '[.[] | .name] | join(",")' <<<"$snap" 2>/dev/null) || esc_all=""
        esc_via=$(_sup_escalate_deliver "$name" "$cause" "$reason" "$esc_stuck" "$esc_all")
        db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
            VALUES ($(sqlq "$name"), 'escalate', 'stuck', $(sqlq_or_null "$cause"),
                    $(sqlq "{\"reason\":\"${reason}\",\"attempts\":${attempts},\"delivered\":\"${esc_via}\"}"));" 2>/dev/null \
          && { escalated=$((escalated + 1)); events=$((events + 1)); } \
          || warn "supervisor: escalate insert failed for $name"
        # The log line now states WHERE it went. "needs a human" with no delivery
        # receipt is what three days of dead backups looked like.
        if [[ "$esc_via" == none:* ]]; then
          warn "supervisor: ESCALATE $name ($cause: $reason) — needs rung-4+/human — NOT DELIVERED (${esc_via#none:})"
        else
          warn "supervisor: ESCALATE $name ($cause: $reason) — needs rung-4+/human — delivered via ${esc_via}"
        fi
        ;;
      nudge|resume|rotate|restart)
        # DIVE-3753: restart joins this branch deliberately — it is audited as
        # an ACT (event='action', rung='restart'), exactly like the rungs below
        # it, and it obeys the same _SUP_ACTIONS_FLAG dormancy. It does NOT
        # also write an escalate row: an action that was TAKEN and a condition
        # that needs a human are two different rows, and emitting both would
        # make every successful auto-recovery ping a person — which is the
        # noise that gets an escalation channel muted. The human path for
        # poller-dead is the limiter's refusal (escalate restart-rate-limited),
        # not the restart itself.
        if [[ "$actions_on" == "true" ]]; then
          local rc=0 res="ok"
          _sup_act_exec "$name" "$verb" "$cause" || { rc=$?; res="failed"; }
          # DIVE-3856: rung 4 VERIFIES ITS OWN REMEDY. `res` above is
          # cmd_restart's exit code and nothing more; on 2026-08-31 that scored
          # `ok` for a restart that spawned no channel launcher at all and left
          # the seat deaf for another fifteen minutes. Only the poller-dead
          # restart is verified, because it is the only rung whose success is a
          # PROCESS we can count: a nudge or a resume succeeds by being
          # delivered, and re-probing them would be re-litigating the agent's
          # reply, not the action.
          local verified=""
          if [[ "$verb" == "restart" && "$cause" == "poller-dead" && "$res" == "ok" ]]; then
            verified="$(_sup_restart_verify "$name" "$atype")"
            case "$verified" in
              ok)          res="ok" ;;
              still-dead)  res="restart-ran-poller-still-dead" ;;
              *)           res="restart-ran-poller-unverified" ;;
            esac
          fi
          db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
              VALUES ($(sqlq "$name"), 'action', 'stuck', $(sqlq_or_null "$cause"),
                      $(sqlq "{\"rung\":\"${verb}\",\"attempt\":$((attempts + 1)),\"result\":\"${res}\"}"));" 2>/dev/null \
            && { acted=$((acted + 1)); events=$((events + 1)); } \
            || warn "supervisor: action insert failed for $name"
          # ESCALATE ON THIS TICK, not the next one. The old path discovered a
          # failed restart ten minutes later, at which point the rung-4 limiter
          # refuses a second restart and escalates `restart-rate-limited` — a
          # true statement that names the LIMITER as the reason a human is
          # needed, when the reason is that the remedy did not work. We now know
          # that at t+~9s, so we say it at t+~9s and we say what it was. The
          # limiter itself is untouched: a restart that works is visible in
          # seconds, so a second one inside the window is still the signature of
          # a seat restart does not fix.
          #
          # `unverified` deliberately does NOT escalate. It is the "I could not
          # tell" outcome, and paging a person on it would make every healthy
          # seat of an unprobeable type an alert — which is how an escalation
          # channel gets muted.
          if [[ "$res" == "restart-ran-poller-still-dead" ]]; then
            local vesc
            vesc=$(db "SELECT COUNT(*) FROM supervisor_events
                       WHERE agent=$(sqlq "$name") AND event='escalate'
                         AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
            [[ "$vesc" =~ ^[0-9]+$ ]] || vesc=0
            if (( vesc == 0 )); then
              local v_stuck v_all v_via v_reason="restart-ran-poller-still-dead"
              v_stuck=$(jq -r '[.[] | select(.classification == "stuck") | .name] | join(",")' <<<"$snap" 2>/dev/null) || v_stuck=""
              v_all=$(jq -r '[.[] | .name] | join(",")' <<<"$snap" 2>/dev/null) || v_all=""
              v_via=$(_sup_escalate_deliver "$name" "$cause" "$v_reason" "$v_stuck" "$v_all")
              db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
                  VALUES ($(sqlq "$name"), 'escalate', 'stuck', $(sqlq_or_null "$cause"),
                          $(sqlq "{\"reason\":\"${v_reason}\",\"attempts\":${attempts},\"delivered\":\"${v_via}\"}"));" 2>/dev/null \
                && { escalated=$((escalated + 1)); events=$((events + 1)); } \
                || warn "supervisor: escalate insert failed for $name"
              if [[ "$v_via" == none:* ]]; then
                warn "supervisor: ESCALATE $name ($cause: $v_reason) — the rung-4 restart ran and the poller did NOT come back — NOT DELIVERED (${v_via#none:})"
              else
                warn "supervisor: ESCALATE $name ($cause: $v_reason) — the rung-4 restart ran and the poller did NOT come back — delivered via ${v_via}"
              fi
            fi
          fi
        else
          # One planned row per agent per window — evidence, not spam.
          local pln
          pln=$(db "SELECT COUNT(*) FROM supervisor_events
                    WHERE agent=$(sqlq "$name") AND event='planned'
                      AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
          (( pln > 0 )) && continue
          db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
              VALUES ($(sqlq "$name"), 'planned', 'stuck', $(sqlq_or_null "$cause"),
                      $(sqlq "{\"rung\":\"${verb}\",\"attempt\":$((attempts + 1)),\"dormant\":true}"));" 2>/dev/null \
            && { planned=$((planned + 1)); events=$((events + 1)); } \
            || warn "supervisor: planned insert failed for $name"
        fi
        ;;
    esac
  done < <(jq -c '.[]' <<<"$snap")

  # DIVE-3667: the rollup counts EVERY class the classifier emitted, via
  # _sup_rollup_counts. See the comment on that helper for what the hand-picked
  # five cost. `other` (unclassified) is the invariant that keeps this true for
  # a class added after this commit.
  local total healthy slow stuck drift vchal stalled nooutput updpend quota unprobed other
  total=$(jq 'length' <<<"$snap")
  read -r healthy slow stuck drift vchal stalled nooutput updpend quota unprobed other \
    <<<"$(_sup_rollup_counts "$snap")"

  # DIVE-975: one 'heartbeat' row per tick — the observation DENOMINATOR. The
  # transition/observe rows above are sporadic by nature (a clean fleet writes
  # none), so an all-healthy week left supervisor_events empty and DIVE-970 had
  # no window to measure a false-positive RATE against. This additive summary
  # row makes the table grow on every cron tick and records the fleet snapshot;
  # reviewers filter it out by event='heartbeat'. agent='(fleet)' is a sentinel.
  #
  # DIVE-3667: every bucket goes in `signals`, including the ones that do not
  # move fleet_class. This row is the denominator, so a reader must be able to
  # recompute ANY definition of degraded from it — the previous JSON omitted
  # verifyChallenge, which DROVE fleet_class, so the row could not explain its
  # own verdict.
  local fleet_class sig
  fleet_class=$(_sup_fleet_class "$healthy" "$slow" "$stuck" "$drift" "$vchal" \
                                 "$stalled" "$nooutput" "$updpend" "$quota" \
                                 "$unprobed" "$other")
  sig=$(jq -nc \
          --argjson t "$total" --argjson h "$healthy" --argjson sl "$slow" \
          --argjson dr "$drift" --argjson st "$stuck" --argjson sa "$stalled" \
          --argjson vc "$vchal" --argjson no "$nooutput" --argjson up "$updpend" \
          --argjson qe "$quota" --argjson un "$unprobed" \
          --argjson ot "$other" --argjson ev "$events" \
          --argjson ua "${_SUP_ALERTS_UNDELIVERABLE:-0}" \
          --argjson qw "${_SUP_ALERTS_QUIETED:-0}" \
          '{total:$t, healthy:$h, slow:$sl, drift:$dr, stuck:$st, stalled:$sa,
            verifyChallenge:$vc, noOutput:$no, updatePending:$up,
            quotaExhausted:$qe, unprobed:$un, unclassified:$ot, anomalyRows:$ev,
            alertsUndeliverable:$ua, capacityPagesWithheld:$qw}')
  db "INSERT INTO supervisor_events (agent, event, classification, signals)
      VALUES ('(fleet)', 'heartbeat', $(sqlq "$fleet_class"), $(sqlq "$sig"));" \
    2>/dev/null && events=$((events + 1)) || warn "supervisor: heartbeat insert failed"

  local act_note=""
  if [[ "$actions_on" == "true" ]]; then act_note=" · actions ON: ${acted} acted / ${escalated} escalated"
  elif (( planned + escalated > 0 )); then act_note=" · dormant: ${planned} planned / ${escalated} escalated"
  fi
  local vchal_note=""
  (( vchal > 0 )) && vchal_note=" · ⚠ ${vchal} verify-challenge (${alerted} alerted)"
  # DIVE-4551: an alert that reached nobody is the loudest thing this line can
  # carry — it says the watcher itself is dark. Appears only when non-zero, like
  # every other conditional note here.
  local undeliv_note=""
  (( ${_SUP_ALERTS_UNDELIVERABLE:-0} > 0 )) \
    && undeliv_note=" · ⚠ ${_SUP_ALERTS_UNDELIVERABLE} alert leg(s) UNDELIVERABLE (no recipient resolves — see 5dive doctor)"
  # DIVE-4666: quiet is a NUMBER, not an absence. Without this, "the supervisor
  # stopped paging about walls" and "the supervisor stopped noticing walls" read
  # identically on the one line anybody watches. Not a ⚠ — withholding a page
  # for a wall that names its own reset is the correct outcome, not a fault.
  local quiet_note=""
  (( ${_SUP_ALERTS_QUIETED:-0} > 0 )) \
    && quiet_note=" · ${_SUP_ALERTS_QUIETED} capacity page(s) withheld (seat on a known wall, reset still ahead)"
  # DIVE-3667: the four original buckets keep their exact position so anything
  # already parsing this line still parses; the rest appear only when non-zero,
  # so a clean fleet's line does not grow.
  local extra
  extra=$(_sup_rollup_extra "$stalled" "$nooutput" "$updpend" "$quota" "$other")
  ok "supervisor tick: ${total} agents — ${healthy} healthy / ${slow} slow / ${drift} drift / ${stuck} stuck${extra} · ${events} audit row(s)${act_note}${vchal_note}${undeliv_note}${quiet_note}" \
     '{enabled:true, agents:($t|tonumber), healthy:($h|tonumber), slow:($sl|tonumber), drift:($dr|tonumber), stuck:($st|tonumber), stalled:($sa|tonumber), noOutput:($no|tonumber), updatePending:($up|tonumber), quotaExhausted:($qe|tonumber), unclassified:($ot|tonumber), verifyChallenge:($vc|tonumber), alerted:($al|tonumber), auditRows:($e|tonumber), actionsEnabled:($ae == "true"), acted:($ac|tonumber), planned:($pl|tonumber), escalated:($es|tonumber), alertsUndeliverable:($ua|tonumber), capacityPagesWithheld:($qw|tonumber)}' \
     --arg t "$total" --arg h "$healthy" --arg sl "$slow" --arg dr "$drift" --arg st "$stuck" --arg e "$events" \
     --arg sa "$stalled" --arg no "$nooutput" --arg up "$updpend" --arg qe "$quota" --arg ot "$other" \
     --arg vc "$vchal" --arg al "$alerted" \
     --arg ae "$actions_on" --arg ac "$acted" --arg pl "$planned" --arg es "$escalated" \
     --arg ua "${_SUP_ALERTS_UNDELIVERABLE:-0}" --arg qw "${_SUP_ALERTS_QUIETED:-0}"
}

cmd_supervisor() {
  local mode="board" interval=5
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tick)         mode="tick" ;;
      --watch)        mode="watch" ;;
      --watch=*)      mode="watch"; interval="${1#--watch=}" ;;
      -h|--help|help) _sup_usage; return 0 ;;
      *) fail "$E_USAGE" "unknown supervisor flag: $1 (try: 5dive supervisor --help)" ;;
    esac
    shift
  done
  case "$mode" in
    tick) cmd_supervisor_tick ;;
    watch)
      [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 && interval <= 300 )) \
        || fail "$E_VALIDATION" "--watch seconds must be 1-300"
      _sup_watch "$interval" ;;
    board)
      _sup_cli_check   # in this shell, not the $(…) subshell — see _sup_snapshot
      local snap; snap=$(_sup_snapshot)
      if (( JSON_MODE )); then
        # stdin, not --argjson (DIVE-222) — the snapshot can be large.
        printf '%s' "$snap" | jq -c \
          --arg cur "$FIVE_VERSION" --arg lat "$_SUP_CLI_LATEST" \
          --arg beh "$_SUP_CLI_BEHIND" --arg stl "$_SUP_CLI_STALE" \
          --arg frz "$_SUP_CLI_FROZEN" --arg frzd "$_SUP_CLI_FROZEN_DETAIL" \
          --arg ahd "$_SUP_CLI_AHEAD" --arg frzarm "$_SUP_CLI_FROZEN_ARMED" \
          --argjson tstuck "$_SUP_T_STUCK_MIN" --argjson tslow "$_SUP_T_SLOW_MIN" \
          '{ok:true, data:{agents:.,
             cli:{current:$cur, latest:(if $lat == "" then null else $lat end), behind:$beh, stale:$stl,
                  ahead:$ahd,
                  frozen:$frz, frozenDetail:(if $frzd == "" then null else $frzd end),
                  frozenArmed:$frzarm},
             tStuckMin:$tstuck, tSlowMin:$tslow}}'
      else
        _sup_render_board "$snap"
        echo ""
        _sup_summary_line "$snap"
      fi ;;
  esac
}
