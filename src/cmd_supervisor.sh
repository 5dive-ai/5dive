
# -------- 5dive supervisor — fleet health brain (DIVE-724, P1: observe-only) --------
#
# The unifying layer ON TOP of heartbeat/rotation/auto-resume/loops (design:
# docs/fleet-supervisor-design.md). Per agent it runs DETECT -> CLASSIFY and
# surfaces the result on a board; the cron-callable `--tick` additionally
# APPENDS to the supervisor_events audit table. P1 takes ZERO recovery
# actions — no restarts, no nudges, no mutations beyond that audit table —
# so the stuck/slow classifier can be validated against real fleet behavior
# with no risk before P2 turns the recovery ladder on.
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
[[ -n "$_SUP_QUOTA_PAT" ]] || _SUP_QUOTA_PAT='(api[[:space:]]+error|request[[:space:]]+rejected)[^|]{0,60}429|quota[[:space:]]+(has[[:space:]]+been[[:space:]]+)?exhausted|exhausted[[:space:]]+your[[:space:]]+(token|weekly|monthly)|hit[[:space:]]+your[[:space:]]+(monthly|weekly|daily)[[:space:]]+spend[[:space:]]+limit|usage[[:space:]]+limit[[:space:]]+reached|insufficient_quota|credit[[:space:]]+balance[[:space:]]+is[[:space:]]+too[[:space:]]+low'
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
# Ladder pacing (design §5): gap before the NEXT action on an agent is
# base * 2^attempts (20m/40m/80m against the 10m tick); past max attempts the
# supervisor stops acting and escalates once per window.
_SUP_ACT_BASE_MIN="${SUPERVISOR_ACT_BASE_MIN:-20}"
[[ "$_SUP_ACT_BASE_MIN" =~ ^[0-9]+$ ]] || _SUP_ACT_BASE_MIN=20
_SUP_ACT_WINDOW_H=6
_SUP_ACT_MAX_ATTEMPTS=3

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
_SUP_VERIFY_PAT="${SUPERVISOR_VERIFY_PAT:-}"
[[ -n "$_SUP_VERIFY_PAT" ]] || _SUP_VERIFY_PAT='(verify|confirm)[[:space:]]+(your[[:space:]]+)?(identity|age)|please[[:space:]]+verify[[:space:]]+your|(to[[:space:]]+continue|you[[:space:]]+must)[^.]{0,30}verif|government[- ]?issued[[:space:]]+(photo[[:space:]]+)?id|verify[[:space:]]+that[[:space:]]+you[[:space:]]+are[[:space:]]+(over|at[[:space:]]+least)|age[[:space:]-]*restricted'

# DIVE-971: per-type telegram-bridge pgrep pattern (matched against the agent
# user's process argv, -f). claude's forked plugin argv carries the cache path
# …/5dive-plugins/telegram/<ver>; codex/grok/antigravity run the telegram-<x>
# MCP server as `bun <plugin>/server.ts`; opencode launches its relay via
# `bun run --cwd <plugin> … start` — every non-claude plugin dir is
# telegram-<name>, so the dir name is a unique, argv-stable match. A type
# absent here has no probeable bridge -> poller stays "n/a" (never classifies).
declare -A _SUP_POLLER_PAT=(
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
declare -A _SUP_ACTIVITY_PROBE=(
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

# DIVE-1127: pure signature match, no I/O — echoes the first pane line that looks
# like an ID/age-verification challenge (trimmed), empty otherwise. Split out from
# _sup_verify_challenge so the false-positive-critical regex is unit-testable
# without a live tmux (mirrors how _sup_act_plan is the pure, tested core).
_sup_verify_match() {  # <pane-text-on-stdin>
  grep -iE "$_SUP_VERIFY_PAT" 2>/dev/null | head -1 \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160
}

# DIVE-1127: does this agent's live pane show a verification challenge? claude-only
# and root-only (the sudo tmux hop) — any other runtime, no root, or a down service
# returns empty (false-negative bias, like every other signal here). Echoes the
# matched pane excerpt when tripped.
_sup_verify_challenge() {  # <type> <user> <sess> <svc_running>
  local type="$1" user="$2" sess="$3" svc_running="$4"
  [[ "$type" == "claude" ]] || return 0
  (( svc_running )) && [[ $EUID -eq 0 ]] || return 0
  local pane
  pane=$(sudo -n -u "$user" tmux capture-pane -p -t "$sess" -S "-${_SUP_VERIFY_PANE_LINES}" 2>/dev/null) || return 0
  [[ -n "$pane" ]] || return 0
  printf '%s\n' "$pane" | _sup_verify_match
}

# DIVE-3272: pure signature match, no I/O — echoes the first pane line that looks
# like a model-capacity/quota refusal, empty otherwise. Split out from
# _sup_quota_pane for the same reason _sup_verify_match is: the false-positive-
# critical regex has to be unit-testable without a live tmux.
_sup_quota_match() {  # <pane-text-on-stdin>
  grep -iE "$_SUP_QUOTA_PAT" 2>/dev/null | head -1 \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160
}

# DIVE-3272: does this agent's live pane show a capacity refusal? Root-only (the
# sudo tmux hop) and running-service-only; anything else returns empty
# (false-negative bias, like every other probe here). Deliberately NOT
# claude-only — the incident seat was a qwen profile, and a quota wall is the one
# failure every runtime shares.
_sup_quota_pane() {  # <user> <sess> <svc_running>
  local user="$1" sess="$2" svc_running="$3"
  (( svc_running )) && [[ $EUID -eq 0 ]] || return 0
  local pane
  pane=$(sudo -n -u "$user" tmux capture-pane -p -t "$sess" -S "-${_SUP_QUOTA_PANE_LINES}" 2>/dev/null) || return 0
  [[ -n "$pane" ]] || return 0
  printf '%s\n' "$pane" | _sup_quota_match
}

# DIVE-3272: the OUTPUT signal — the one thing no probe above measures, read from
# the store that was holding the answer the whole time, unread. Echoes
# "<open-rows>|<days-since-last-close>"; the second is -1 when this seat has
# never closed anything (unknown age => never classifies on its own, so a
# brand-new seat can't be flagged for having produced nothing yet).
_sup_output_stats() {  # <name>
  local name="$1" open last days=-1
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
  printf '%s|%s\n' "$open" "$days"
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
# args: armed(true/false) tick_epoch row_epoch now
#       rec_class rec_cause rec_detail open_rows days_since_close(-1 = never)
#       store_readable(true/false)
_sup_info_status() {
  local armed="$1" tick="${2:-0}" row="${3:-0}" now="${4:-0}" \
        rc="${5:-}" rcause="${6:-}" rdetail="${7:-}" open="${8:-0}" days="${9:--1}" \
        store="${10:-true}"
  [[ "$store" == "false" ]] || store="true"
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
  else
    output="dry"; transacting="false"
    note="${open} open row(s), nothing closed in ${days}d"
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

  # --- the escalation: what the state line may NOT omit -----------------------
  # Only the "up and reachable but not transacting" classes. A `stuck` seat is
  # already visible in `state:` itself (the unit is down); these three are the
  # ones every liveness signal reads green through.
  local verdict=""
  case "$cls" in quota-exhausted|verify-challenge|no-output) verdict="$cls" ;; esac
  [[ -z "$verdict" && "$output" == "dry" ]] && verdict="no-output"

  local state_note sup_line
  case "$verdict" in
    "") case "$output" in
          ok)         state_note="transacting (last close ${days}d ago)" ;;
          idle)       state_note="idle — no open rows (last close ${days}d ago)" ;;
          unmeasured) state_note="output UNMEASURED — task store unreadable from here" ;;
          *)          state_note="output unknown — ${note}" ;;
        esac ;;
    no-output) state_note="⚠ NOT TRANSACTING (no-output: ${note})" ;;
    *)         state_note="⚠ NOT TRANSACTING (${cls}${detail:+: ${detail}})" ;;
  esac

  local age_s=$(( now > row && row > 0 ? now - row : -1 ))
  local tick_age_s=$(( now > tick && tick > 0 ? now - tick : -1 ))
  if [[ "$store" != "true" ]]; then
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
        store="false"
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
    local ostats; ostats=$(_sup_output_stats "$name" 2>/dev/null || echo "0|-1")
    open="${ostats%%|*}"; days="${ostats##*|}"
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
  _sup_info_status "$armed" "$tick" "$row" "$now" "$rc" "$rcause" "$rdetail" "$open" "$days" "$store"
}

# DIVE-3272: a seat that cannot transact is a FLEET-health event. The entire cost
# of the incident was the 20 rows queued behind a seat nobody knew was dark, so
# the alert leads with that and not with the seat's own symptom. Same delivery
# shape as _sup_verify_alert — both legs best-effort, because one wedged channel
# must never abort the tick for the rest of the fleet — and the caller owns the
# dedup window.
_sup_capacity_alert() {  # <name> <class> <detail>
  local name="$1" class="$2" detail="$3"
  local msg="[FLEET-HEALTH ${class}] agent '${name}' is UP and REACHABLE but NOT TRANSACTING: ${detail}. Every liveness signal (unit / tmux / poller / registry label) reads healthy — that agreement is the DIVE-3272 defect, not evidence against this alert. Check the seat's model capacity (auth-profile, quota reset) and reassign or park whatever is queued behind it."
  # DIVE-3318: a one-way machine notice nobody replies to is not a round — see
  # a2a_round_guard. NOT a sender exemption; never set this by hand.
  _5DIVE_A2A_NOTIFY=1 5dive agent send main "$msg" >/dev/null 2>&1 \
    || warn "capacity-alert: 'agent send main' failed for $name (alert still audited)"
  # lodar is a human — reached through main's paired channel, same route the
  # verify tripwire uses. Best-effort: a miss still leaves the agent-send leg
  # and the audited alert row.
  if _task_agent_channel main; then
    _task_send_owner "$msg" >/dev/null 2>&1 || true
  fi
}

# DIVE-1127: fire the same-day alert for a tripped account. Both legs are
# best-effort — a delivery failure must NEVER abort the tick (one wedged account
# can't blind the watcher for the rest of the fleet). main (CTO, D4 runbook
# co-owner) gets the agent-to-agent send; lodar (human owner) gets a pinging
# gate. Dedup is the caller's job (one alert per account per _SUP_ALERT_WINDOW_H).
_sup_verify_alert() {  # <name> <excerpt>
  local name="$1" excerpt="$2"
  local msg="[TRIPWIRE id-verification] claude account 'agent-${name}' looks STALLED on an ID/age-verification challenge (anthropic-tos-hedge D4 trigger 1). Response: flip this account to the OpenRouter-Claude profile same-day (A1 runbook). Pane signature: ${excerpt}"
  # DIVE-3318: a one-way machine notice nobody replies to is not a round — see
  # a2a_round_guard. NOT a sender exemption; never set this by hand.
  _5DIVE_A2A_NOTIFY=1 5dive agent send main "$msg" >/dev/null 2>&1 \
    || warn "verify-tripwire: 'agent send main' failed for $name (alert still audited)"
  # lodar is a human, not an agent — reach them through main's paired Telegram
  # channel (main is the human-facing bot). Resolve main's channel, then DM the
  # owner on it. Best-effort: a miss is fine — main's agent-send leg above and
  # the audited alert row still carry the signal. (DIVE-1127 last-mile, routing
  # decided by main.)
  if _task_agent_channel main; then
    _task_send_owner "$msg" >/dev/null 2>&1 || true
  fi
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
  quota-exhausted pane shows a model-capacity/quota refusal (cause:
                  quota-exhausted) — a fleet event, not the seat's own; alerts
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
    if [[ -n "$start_line" ]] && tail -n "+${start_line}" "$log" | grep -q "CLI upgrade via install.5dive.com failed"; then
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

# Pure classification decision — NO I/O, directly unit-testable (mirrors the
# _sup_act_plan factoring the P2 ladder already uses). Takes every signal
# _sup_agent_record collects and returns "<class>\x1f<cause>\x1f<detail>" on
# stdout so a test can assert against it without stubbing systemctl/tmux/pgrep.
# args: desired svc_running(0/1) active sess tmux_state poller loop_stuck
#       has_work(0/1) act_age cli_stale(true/false/unknown) goal_drift_task
#       verify_excerpt stranded open_rows no_output_days quota_excerpt
_sup_classify() {
  local desired="$1" svc_running="$2" active="$3" sess="$4" tmux_state="$5" poller="$6" \
        loop_stuck="$7" has_work="$8" act_age="$9" cli_stale="${10}" goal_drift_task="${11}" \
        verify_excerpt="${12}" stranded="${13:-0}" \
        open_rows="${14:-0}" no_output_days="${15:--1}" quota_excerpt="${16:-}"
  local class="healthy" cause="" detail=""
  # DIVE-1127: the verification-challenge tripwire wins FIRST — it is the highest
  # priority signal (same-day alert obligation) and, when present, explains any
  # concurrent stall (a challenge freezes the session). Alerting is the tick's job.
  if [[ -n "$verify_excerpt" ]]; then
    class="verify-challenge"; cause="id-verification"
    detail="pane shows an ID/age-verification challenge"
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
  elif [[ -n "$quota_excerpt" ]]; then
    # DIVE-3272: placed ABOVE loop-stuck / no-progress on purpose — a capacity
    # wall EXPLAINS both of those, and the response is different in kind (a
    # profile flip or a quota reset, not a nudge/resume). Below the dead-signal
    # branches because a down unit is the more specific reading.
    class="quota-exhausted"; cause="quota-exhausted"
    detail="pane shows a model-capacity refusal: ${quota_excerpt}"
  elif (( loop_stuck > 0 )); then
    class="stuck"; cause="loop-stuck"; detail="${loop_stuck} running loop(s) self-flagged stuck"
  elif (( has_work )) && (( act_age >= 0 )) && (( act_age >= _SUP_T_STUCK_MIN * 60 )); then
    class="stuck"; cause="no-progress"; detail="active work, no transcript progress for $((act_age / 60))m"
  elif (( no_output_days >= 0 )) && (( no_output_days >= _SUP_T_NO_OUTPUT_DAYS )) && (( open_rows > 0 )); then
    # DIVE-3272: the output drought. Ranked BELOW the hard dead signals — those
    # are more specific and already surface — but ABOVE stale-cli / slow / drift
    # / active, because a multi-day drought outranks a ten-minute progress gap
    # and a box-level update notice, and because the branch it has to beat is
    # the one that hid the incident: `has_work -> detail="active"`. A seat that
    # is claiming rows and closing none must not print as active.
    class="no-output"; cause="no-output"
    detail="${open_rows} open row(s), nothing closed in ${no_output_days}d"
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
  local verify_excerpt; verify_excerpt=$(_sup_verify_challenge "$type" "$user" "$sess" "$svc_running")

  # --- signal: model-capacity refusal in the live pane (DIVE-3272) ---
  local quota_excerpt; quota_excerpt=$(_sup_quota_pane "$user" "$sess" "$svc_running")

  # --- signal: OUTPUT (DIVE-3272) — open rows held, and days since this seat
  # last closed anything. The pair is the detector: either number alone is
  # meaningless (0 open rows and no closes is a correctly idle seat; 20 open
  # rows and a close this morning is a busy one).
  local open_rows=0 no_output_days=-1 ostats
  ostats=$(_sup_output_stats "$name")
  open_rows="${ostats%%|*}"; no_output_days="${ostats##*|}"
  [[ "$open_rows"      =~ ^[0-9]+$ ]]  || open_rows=0
  [[ "$no_output_days" =~ ^-?[0-9]+$ ]] || no_output_days=-1

  # --- signal: stranded todo (DIVE-1416 gap#3) — a todo task assigned to this
  # agent, sitting untouched (never started) past the stranded window. Only
  # matters when the agent has NO active work at all (_sup_classify only
  # consults it in that branch), so it's cheap to always compute here.
  local stranded; stranded=$(db "SELECT COUNT(*) FROM tasks
               WHERE assignee=$(sqlq "$name") AND status='todo' AND kind='standard'
                 AND created_at <= datetime('now','-${_SUP_T_STRANDED_MIN} minutes');" 2>/dev/null || echo 0)
  [[ "$stranded" =~ ^[0-9]+$ ]] || stranded=0

  # --- CLASSIFY (design §4) — see _sup_classify for the decision chain itself.
  local class cause detail crow
  crow=$(_sup_classify "$desired" "$svc_running" "$active" "$sess" "$tmux_state" "$poller" \
                        "$loop_stuck" "$has_work" "$act_age" "$_SUP_CLI_STALE" "$goal_drift_task" \
                        "$verify_excerpt" "$stranded" \
                        "$open_rows" "$no_output_days" "$quota_excerpt")
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
    --argjson openRows "$open_rows" --argjson noOutputDays "$no_output_days" \
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
               quotaSignature:(if $quotaExcerpt == "" then null else $quotaExcerpt end)},
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
# Auto-act is narrow along ONE axis: causes where the session is alive but wedged
# (no-progress, loop-stuck). Everything else stuck needs rung 4+ (restart/
# reprovision = P3/manual), so it ESCALATES: one audit row per window, zero
# mutations. Rungs, in order: nudge -> resume -> rotate.
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
_sup_act_history() {
  local name="$1" n last
  n=$(db "SELECT COUNT(*) FROM supervisor_events
          WHERE agent=$(sqlq "$name") AND event='action'
            AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
  last=$(db "SELECT COALESCE(strftime('%s', MAX(ts)), 0) FROM supervisor_events
             WHERE agent=$(sqlq "$name") AND event='action'
               AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
  echo "${n:-0} ${last:-0}"
}

# Pure decision, no side effects: echoes "verb [reason]" where verb is one of
# nudge|resume|rotate|escalate|defer. Attempt N picks rung N+1; the gap before
# the next action is base * 2^attempts; ladder exhausted / unreachable rung
# => escalate.
_sup_act_plan() {  # <type> <cause> <attempts> <last_epoch> <now> <rotation_enabled>
  # $1 (type) is retained for signature/caller stability but no longer branches:
  # OSS-23 made the ladder runtime-agnostic (see block comment above). rung-4+
  # causes still escalate for every runtime via the case below (restart is P3);
  # rotate self-gates on rot regardless of type.
  # shellcheck disable=SC2034
  local type="$1" cause="$2" attempts="$3" last="$4" now="$5" rot="$6"
  case "$cause" in
    no-progress|loop-stuck) : ;;
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
    rotate)
      ( with_registry_lock cmd_agent_rotation_rotate "$name" ) >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
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

  # ── DIVE-1127: ID/age-verification tripwire — SAME-DAY alert (not the P2 ladder).
  # A verification challenge is not "wedged compute" you nudge/resume/rotate out of;
  # it is an account-state event whose only response is a human/runbook flip. So it
  # gets its own alert path, always live when the tick is enabled (no actions flag),
  # deduped one alert per account per _SUP_ALERT_WINDOW_H, and audited as event='alert'.
  local alerted=0
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    # DIVE-3272: the same always-live, deduped alert path now carries the two
    # capacity classes. They belong here and NOT on the P2 ladder for the same
    # reason the verify challenge does: a nudge/resume/rotate cannot fix a seat
    # that has no model capacity, and rotating work onto it is what queued 20
    # rows behind dev3 in the first place.
    local cls; cls=$(jq -r '.classification' <<<"$row")
    case "$cls" in verify-challenge|no-output|quota-exhausted) ;; *) continue ;; esac
    name=$(jq -r '.name' <<<"$row")
    local excerpt cause_s
    case "$cls" in
      verify-challenge) excerpt=$(jq -r '.signals.verifyChallenge // ""' <<<"$row"); cause_s="id-verification" ;;
      quota-exhausted)  excerpt=$(jq -r '.detail // ""' <<<"$row");                  cause_s="quota-exhausted" ;;
      *)                excerpt=$(jq -r '.detail // ""' <<<"$row");                  cause_s="no-output" ;;
    esac
    local prev_alert
    # Dedup is scoped BY CLASS (DIVE-3272): a seat can be both quota-walled and
    # output-dry, and an unscoped window would let whichever fired first
    # suppress the other for a day.
    prev_alert=$(db "SELECT COUNT(*) FROM supervisor_events
                     WHERE agent=$(sqlq "$name") AND event='alert'
                       AND classification=$(sqlq "$cls")
                       AND ts >= datetime('now', '-${_SUP_ALERT_WINDOW_H} hours');" 2>/dev/null || echo 0)
    [[ "$prev_alert" =~ ^[0-9]+$ ]] || prev_alert=0
    (( prev_alert > 0 )) && continue
    if [[ "$cls" == "verify-challenge" ]]; then
      _sup_verify_alert "$name" "$excerpt"
    else
      _sup_capacity_alert "$name" "$cls" "$excerpt"
    fi
    db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
        VALUES ($(sqlq "$name"), 'alert', $(sqlq "$cls"), $(sqlq "$cause_s"), $(sqlq "$row"));" 2>/dev/null \
      && { alerted=$((alerted + 1)); events=$((events + 1)); } \
      || warn "supervisor: $cls alert insert failed for $name"
    warn "supervisor: ALERT $name — $cls: $excerpt"
  done < <(jq -c '.[]' <<<"$snap")

  # ── P2 (DIVE-857): ACT + ESCALATE — pre-cleared by lodar 2026-07-02, gated on
  # $_SUP_ACTIONS_FLAG until the audit week (started 2026-07-02) is clean.
  # Dormant mode writes 'planned' rows: the Jul 9 review reads exactly what the
  # ladder WOULD have done all week. restart stays P3; reprovision manual.
  local actions_on="false" acted=0 planned=0 escalated=0 now_s
  [[ -f "$_SUP_ACTIONS_FLAG" ]] && actions_on="true"
  now_s=$(date +%s)
  local reg_now; reg_now=$(registry_read)
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    class=$(jq -r '.classification' <<<"$row")
    [[ "$class" == "stuck" ]] || continue
    name=$(jq -r '.name' <<<"$row"); cause=$(jq -r '.cause // ""' <<<"$row")
    local atype rot attempts last plan verb reason
    atype=$(jq -r '.type' <<<"$row")
    rot=$(jq -r --arg n "$name" '.agents[$n].rotation.enabled // false' <<<"$reg_now")
    read -r attempts last <<<"$(_sup_act_history "$name")"
    plan=$(_sup_act_plan "$atype" "$cause" "$attempts" "$last" "$now_s" "$rot")
    read -r verb reason <<<"$plan"
    case "$verb" in
      defer|"") continue ;;
      escalate)
        local esc
        esc=$(db "SELECT COUNT(*) FROM supervisor_events
                  WHERE agent=$(sqlq "$name") AND event='escalate'
                    AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
        (( esc > 0 )) && continue
        db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
            VALUES ($(sqlq "$name"), 'escalate', 'stuck', $(sqlq_or_null "$cause"),
                    $(sqlq "{\"reason\":\"${reason}\",\"attempts\":${attempts}}"));" 2>/dev/null \
          && { escalated=$((escalated + 1)); events=$((events + 1)); } \
          || warn "supervisor: escalate insert failed for $name"
        warn "supervisor: ESCALATE $name ($cause: $reason) — needs rung-4+/human"
        ;;
      nudge|resume|rotate)
        if [[ "$actions_on" == "true" ]]; then
          local rc=0 res="ok"
          _sup_act_exec "$name" "$verb" "$cause" || { rc=$?; res="failed"; }
          db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
              VALUES ($(sqlq "$name"), 'action', 'stuck', $(sqlq_or_null "$cause"),
                      $(sqlq "{\"rung\":\"${verb}\",\"attempt\":$((attempts + 1)),\"result\":\"${res}\"}"));" 2>/dev/null \
            && { acted=$((acted + 1)); events=$((events + 1)); } \
            || warn "supervisor: action insert failed for $name"
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

  local total healthy slow stuck drift vchal
  total=$(jq 'length' <<<"$snap")
  healthy=$(jq '[.[] | select(.classification == "healthy")] | length' <<<"$snap")
  slow=$(jq  '[.[] | select(.classification == "slow")]    | length' <<<"$snap")
  stuck=$(jq '[.[] | select(.classification == "stuck")]   | length' <<<"$snap")
  drift=$(jq '[.[] | select(.classification == "drift")]   | length' <<<"$snap")
  vchal=$(jq '[.[] | select(.classification == "verify-challenge")] | length' <<<"$snap")

  # DIVE-975: one 'heartbeat' row per tick — the observation DENOMINATOR. The
  # transition/observe rows above are sporadic by nature (a clean fleet writes
  # none), so an all-healthy week left supervisor_events empty and DIVE-970 had
  # no window to measure a false-positive RATE against. This additive summary
  # row makes the table grow on every cron tick and records the fleet snapshot;
  # reviewers filter it out by event='heartbeat'. agent='(fleet)' is a sentinel.
  local fleet_class="healthy"
  (( slow + stuck + vchal > 0 )) && fleet_class="degraded"
  db "INSERT INTO supervisor_events (agent, event, classification, signals)
      VALUES ('(fleet)', 'heartbeat', $(sqlq "$fleet_class"),
              $(sqlq "{\"total\":${total},\"healthy\":${healthy},\"slow\":${slow},\"drift\":${drift},\"stuck\":${stuck},\"anomalyRows\":${events}}"));" \
    2>/dev/null && events=$((events + 1)) || warn "supervisor: heartbeat insert failed"

  local act_note=""
  if [[ "$actions_on" == "true" ]]; then act_note=" · actions ON: ${acted} acted / ${escalated} escalated"
  elif (( planned + escalated > 0 )); then act_note=" · dormant: ${planned} planned / ${escalated} escalated"
  fi
  local vchal_note=""
  (( vchal > 0 )) && vchal_note=" · ⚠ ${vchal} verify-challenge (${alerted} alerted)"
  ok "supervisor tick: ${total} agents — ${healthy} healthy / ${slow} slow / ${drift} drift / ${stuck} stuck · ${events} audit row(s)${act_note}${vchal_note}" \
     '{enabled:true, agents:($t|tonumber), healthy:($h|tonumber), slow:($sl|tonumber), drift:($dr|tonumber), stuck:($st|tonumber), verifyChallenge:($vc|tonumber), alerted:($al|tonumber), auditRows:($e|tonumber), actionsEnabled:($ae == "true"), acted:($ac|tonumber), planned:($pl|tonumber), escalated:($es|tonumber)}' \
     --arg t "$total" --arg h "$healthy" --arg sl "$slow" --arg dr "$drift" --arg st "$stuck" --arg e "$events" \
     --arg vc "$vchal" --arg al "$alerted" \
     --arg ae "$actions_on" --arg ac "$acted" --arg pl "$planned" --arg es "$escalated"
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
