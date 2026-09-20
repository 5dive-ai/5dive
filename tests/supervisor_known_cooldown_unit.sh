#!/usr/bin/env bash
# DIVE-4666 — a FLEET-HEALTH page for a seat on a 5h usage cooldown reached a
# human at 2026-09-20 07:00:33Z. The supervisor had measured the wall AND its
# reset time six ticks running; the page dropped both and asked the reader to
# go check the quota reset.
#
# ITERATION 2 folds in the row's SECOND requirement (the 07:40Z addendum): the
# same alert fired at codex six minutes after it picked a row up, because the
# no-output verdict was measured against the seat's CLOSE history alone. Sections
# H-J cover the queue-movement term that qualifies it.
#
# Sections A-G are PURE — _sup_wall_verdict, _sup_wall_reset_of,
# _sup_capacity_notify_{human,machine}, _sup_capacity_tail, quota_wall_when,
# _sup_output_drought, _sup_ago_phrase, _sup_info_status. No tmux, no root, no
# clock (every arm passes `now` explicitly).
# Section I drives the REAL `_sup_agent_record` with only the store read stubbed
# (the technique tests/supervisor_classify_unit.sh:447 already uses), and
# section J runs `_sup_output_stats`'s REAL SQL against a scratch sqlite file —
# no root, no network, nothing outside $TMPDIR.
#
# THE POPULATION CONTROL is the incident itself: the verbatim
# `supervisor_events` rows for olivia between 04:50Z and 07:10Z that day, on
# disk in the same commit as the fix, replayed at the exact epoch the page
# fired. Composing a specimen would have proved the code runs; replaying the
# rows proves it answers the question that was got wrong.
#
# Run: bash tests/supervisor_known_cooldown_unit.sh (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
FIX=tests/fixtures/dive4666

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh \
         lib/quota_wall.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

PASS=0; FAIL=0
ok()   { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"; fi; }
has()  { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected to contain '$2', got '$3'"; fi; }
hasnt(){ if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected NOT to contain '$2', got '$3'"; fi; }

# ── the incident's own numbers ──────────────────────────────────────────────
# 1789887633 = 2026-09-20 07:00:33Z, the second the page was sent.
# 1789891800 = 2026-09-20 08:10:00Z, the reset the supervisor had already read.
ALERT_AT=1789887633
RESET=1789891800
TICK=600
# The verbatim audited rows, newest first, as _sup_wall_state reads them.
EVENTS=$(cat "$FIX/olivia-2026-09-20-events.txt")
INCIDENT_DETAIL=$(grep -m1 'resets 1789891800' <<<"$EVENTS" | sed 's/^.* | //')
NO_OUTPUT_DETAIL=$(grep -m1 'nothing closed in 3d' <<<"$EVENTS" | sed 's/^.* | //')

# ── A. _sup_wall_verdict — the three states ─────────────────────────────────
ok "arm01: a reset still ahead is a cooldown" \
   "cooling" "$(_sup_wall_verdict "$RESET" "$ALERT_AT" "$TICK")"
ok "arm02: one second before the reset is still a cooldown" \
   "cooling" "$(_sup_wall_verdict "$RESET" $((RESET - 1)) "$TICK")"
ok "arm03: the ONE-TICK GRACE — a seat resumes on the next dispatch, not on the second" \
   "cooling" "$(_sup_wall_verdict "$RESET" $((RESET + TICK)) "$TICK")"
ok "arm04: past the grace, the wall is dead and the seat is still dark — page" \
   "lapsed" "$(_sup_wall_verdict "$RESET" $((RESET + TICK + 1)) "$TICK")"
ok "arm05: no reset is NO KNOWLEDGE, and no knowledge never quietens" \
   "none" "$(_sup_wall_verdict "" "$ALERT_AT" "$TICK")"
ok "arm06: an unparseable reset never quietens either" \
   "none" "$(_sup_wall_verdict "soon" "$ALERT_AT" "$TICK")"

# ── B. _sup_wall_reset_of — every shape this file produces ──────────────────
ok "arm07: THE INCIDENT STRING, verbatim from supervisor_events" \
   "$RESET" "$(_sup_wall_reset_of "$INCIDENT_DETAIL" "$ALERT_AT")"
ok "arm08: epoch MILLIseconds" \
   "$RESET" "$(_sup_wall_reset_of "... limit — resets ${RESET}000" "$ALERT_AT")"
ok "arm09: the form quota_wall_when renders for a same-day reset" \
   "$RESET" "$(_sup_wall_reset_of "... limit — resets 08:10Z" "$ALERT_AT")"
ok "arm10: ...and the dated form, for a 7d wall that lifts on another day" \
   "$(date -u -d '2026-09-21 08:10 UTC' +%s)" \
   "$(_sup_wall_reset_of "... limit — resets Sep 21 08:10Z" "$ALERT_AT")"
ok "arm11: the VENDOR BANNER's clock, through the one parser that owns it" \
   "$RESET" "$(_sup_wall_reset_of "● Usage limit reached · continuing automatically at 8:10am" "$ALERT_AT")"
ok "arm12: a detail with no reset in it resolves nothing" \
   "" "$(_sup_wall_reset_of "$NO_OUTPUT_DETAIL" "$ALERT_AT")"
ok "arm13: ...and neither does an empty one" \
   "" "$(_sup_wall_reset_of "" "$ALERT_AT")"

# ── C. quota_wall_when / quota_wall_phrase — never an epoch to a person ─────
ok "arm14: a same-day reset is a clock" \
   "08:10Z" "$(quota_wall_when "$RESET" "$ALERT_AT")"
ok "arm15: a reset on another day carries its date" \
   "Sep 21 08:10Z" "$(quota_wall_when "$(date -u -d '2026-09-21 08:10 UTC' +%s)" "$ALERT_AT")"
ok "arm16: a shape this cannot resolve passes through rather than inventing one" \
   "whenever" "$(quota_wall_when "whenever" "$ALERT_AT")"
ok "arm17: an empty reset renders nothing" "" "$(quota_wall_when "" "$ALERT_AT")"
PHRASE=$(quota_wall_phrase "5h" "100" "$RESET" "$ALERT_AT")
hasnt "arm18: the phrase every surface prints carries no epoch" "1789891800" "$PHRASE"
has   "arm19: ...it carries the time instead" "resets 08:10Z" "$PHRASE"

# ── D. THE LEG DECISIONS — the incident, and what must stay loud ────────────
# arm20 IS the incident: `no-output`'s MACHINE leg, the one DIVE-3982 left live
# on purpose, fired at 07:00:33 while the wall the supervisor had measured at
# 06:20 still had 70 minutes to run.
ok "arm20: THE INCIDENT — a no-output page is withheld while the wall is cooling" \
   "false" "$(_sup_capacity_notify_machine "no-output" "true" "cooling")"
ok "arm21: ...and its human leg too" \
   "false" "$(_sup_capacity_notify_human "no-output" "true" "cooling")"
ok "arm22: a cooling wall is quiet on quota-exhausted even in DIVE-4052 debug mode" \
   "false" "$(_sup_capacity_notify_machine "quota-exhausted" "true" "cooling")"
ok "arm23: a LAPSED wall pages again — that is the DIVE-3272 shape, a dead quota" \
   "true" "$(_sup_capacity_notify_machine "no-output" "true" "lapsed")"
ok "arm24: a wall we know nothing about pages, unchanged" \
   "true" "$(_sup_capacity_notify_machine "no-output" "true" "none")"
ok "arm25: DIVE-4052 still governs quota-exhausted when the sentinel is off" \
   "false" "$(_sup_capacity_notify_machine "quota-exhausted" "false" "lapsed")"
ok "arm26: DIVE-3982 still governs no-output's human leg when no wall is known" \
   "false" "$(_sup_capacity_notify_human "no-output" "true" "none")"
# verify-challenge has its OWN sender and never reaches these functions; the arm
# asserts that even if one day it did, a quota wall would not sweep it up.
ok "arm27: an ID-verification challenge is NOT swept up by a cooling wall (human)" \
   "true" "$(_sup_capacity_notify_human "verify-challenge" "true" "cooling")"
ok "arm28: ...nor on the machine leg" \
   "true" "$(_sup_capacity_notify_machine "verify-challenge" "true" "cooling")"
ok "arm29: a seat frozen on a keypress still pages under a cooling wall" \
   "true" "$(_sup_capacity_notify_human "blocked-on-prompt" "true" "cooling")"
# The legacy 2-arg call must be byte-identical to pre-4666 for every class.
for c in healthy no-output quota-exhausted verify-challenge blocked-on-prompt stuck; do
  ok "arm30[$c]: a 2-arg call is the pre-4666 answer (human)" \
     "$(_sup_capacity_notify_human "$c" "true" "none")" "$(_sup_capacity_notify_human "$c" "true")"
  ok "arm30[$c]: a 2-arg call is the pre-4666 answer (machine)" \
     "$(_sup_capacity_notify_machine "$c" "true" "none")" "$(_sup_capacity_notify_machine "$c" "true")"
done

# ── E. WHAT THE PAGE SAYS WHEN IT DOES FIRE ─────────────────────────────────
TAIL_L=$(_sup_capacity_tail olivia lapsed "$RESET" "DIVE-4666, DIVE-4701" $((RESET + 7200)))
has   "arm31: a lapsed page names when the wall ENDED" "ENDED at 08:10Z" "$TAIL_L"
hasnt "arm32: ...and never the provider's epoch" "1789891800" "$TAIL_L"
has   "arm33: ...and names the queue instead of sending the reader to look" \
      "Queued behind it: DIVE-4666, DIVE-4701" "$TAIL_L"
hasnt "arm34: ...and does not fall back to the vague runbook line it can now replace" \
      "Check the seat's model capacity" "$TAIL_L"
TAIL_E=$(_sup_capacity_tail olivia none "" "" "$ALERT_AT")
has   "arm35: an empty queue says so, with the command that proves it" \
      "Nothing is queued behind it right now (5dive task ls --assignee=olivia)" "$TAIL_E"
has   "arm36: ...and with no known wall the old runbook line stands" \
      "Check the seat's model capacity" "$TAIL_E"

# ── F. POPULATION REPLAY — the oscillation, at the second it mattered ───────
# _sup_wall_state's db read is not exercised here (no store); this replays what
# that read RETURNS — the audited quota-exhausted details, newest first — and
# asserts the composed answer at 07:00:33Z.
replay() {  # <now> -> "<verdict>\x1f<reset>"
  local now="$1" d e
  while IFS= read -r d; do
    [[ "$d" == *"quota-exhausted"* ]] || continue
    e=$(_sup_wall_reset_of "${d##* | }" "$now")
    [[ -n "$e" ]] && { printf '%s\x1f%s' "$(_sup_wall_verdict "$e" "$now" "$TICK")" "$e"; return 0; }
  done < <(tac <<<"$EVENTS")
  printf 'none\x1f'
}
R=$(replay "$ALERT_AT")
ok "arm37: at 07:00:33Z the newest audited wall row still resolves a reset" \
   "$RESET" "$(cut -d$'\x1f' -f2 <<<"$R")"
ok "arm38: ...so the tick that classified no-output was on a COOLING seat" \
   "cooling" "$(cut -d$'\x1f' -f1 <<<"$R")"
ok "arm39: THE INCIDENT, END TO END — the machine leg that fired is withheld" \
   "false" "$(_sup_capacity_notify_machine "no-output" "true" "$(cut -d$'\x1f' -f1 <<<"$R")")"
# The seat's OWN healthy ticks must not be read as a wall.
ok "arm40: a healthy row in the same window resolves no wall" \
   "" "$(_sup_wall_reset_of "idle" "$ALERT_AT")"
# Two hours after the reset with the seat still dark, the same replay pages.
R2=$(replay $((RESET + 7200)))
ok "arm41: two hours past the reset, the same rows say LAPSED" \
   "lapsed" "$(cut -d$'\x1f' -f1 <<<"$R2")"
ok "arm42: ...and the page comes back" \
   "true" "$(_sup_capacity_notify_machine "no-output" "true" "$(cut -d$'\x1f' -f1 <<<"$R2")")"

# ── G. MUTANTS — each one is RE-RUN THROUGH THE ARM IT CLAIMS TO COVER ──────
# it.2, on quinn's finding: the first cut of this section defined a shadow
# function and asserted that the shadow gave the wrong answer. That is a
# tautology — it proves the mutant is a mutant, not that the arm above it is
# load-bearing. A mutant is evidence only when the REAL arm's expression,
# evaluated with the mutation substituted, stops producing the real arm's
# expected value. `reds` is that assertion, and it FAILS when the mutation
# changes nothing.
reds() {  # <which arm> <that arm's expected value> <what it computes under the mutation>
  if [[ "$2" != "$3" ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $1 — the mutation changed NOTHING: the arm still computes '$3'"; fi
}

# M1: a verdict that never compares the reset (the mutant the row named).
# Substituted under `replay`, which is exactly what arm37-39 evaluate.
M1=$( _sup_wall_verdict() { printf 'lapsed'; }; replay "$ALERT_AT" )
reds "arm43: MUTANT 1 reds arm38" "cooling" "$(cut -d$'\x1f' -f1 <<<"$M1")"
reds "arm44: MUTANT 1 reds arm39 — the page comes back" \
     "false" "$(_sup_capacity_notify_machine "no-output" "true" "$(cut -d$'\x1f' -f1 <<<"$M1")")"

# M2: gate the HUMAN leg only — what a reading of the row that missed which leg
# actually fired produces. Re-run through arm20's own expression.
M2=$( _sup_capacity_notify_machine() {
        local class="${1:-}" on="${2:-true}"
        [[ "$class" == "quota-exhausted" ]] && { printf '%s' "$on"; return; }
        printf 'true'
      }
      _sup_capacity_notify_machine "no-output" "true" "cooling" )
reds "arm45: MUTANT 2 — a human-leg-only gate reds arm20 (the incident)" "false" "$M2"

# M3: key the gate on the TICK'S CLASS (the row's literal text) rather than the
# seat's wall. Re-run through arm20 and arm39.
M3f() {
  local class="${1:-}" on="${2:-true}" wall_state="${3:-none}"
  [[ "$class" == "quota-exhausted" && "$wall_state" == "cooling" ]] && { printf 'false'; return; }
  [[ "$class" == "quota-exhausted" ]] && { printf '%s' "$on"; return; }
  printf 'true'
}
reds "arm46: MUTANT 3 — keying on the tick's class reds arm20" \
     "false" "$(M3f "no-output" "true" "cooling")"
reds "arm47: ...and reds arm39 with it" \
     "false" "$(M3f "no-output" "true" "$(cut -d$'\x1f' -f1 <<<"$R")")"
# The control for `reds` itself: the UNMUTATED function must NOT red arm20, or
# `reds` would pass on anything at all.
ok "arm48: CONTROL — the real function still answers arm20's expected value" \
   "false" "$(_sup_capacity_notify_machine "no-output" "true" "cooling")"

# ── H. THE SECOND REQUIREMENT — the drought needs BOTH terms ────────────────
# The 07:40Z addendum, as a pure predicate. _SUP_T_NO_OUTPUT_DAYS=3,
# _SUP_T_NO_OUTPUT_IDLE_MIN=1440 (a day) on stock settings.
ok "arm49: THE CODEX PAGE — one open row picked up 5 minutes ago is not a drought" \
   "false" "$(_sup_output_drought 1 3 5)"
ok "arm50: ...and the same seat's row after 2 days with no start since IS one" \
   "true" "$(_sup_output_drought 1 3 2880)"
ok "arm51: an unmeasured queue clock leaves DIVE-3272 exactly as it shipped" \
   "true" "$(_sup_output_drought 1 3 -1)"
ok "arm52: no open rows is never a drought, whatever the clocks say" \
   "false" "$(_sup_output_drought 0 9 9999)"
ok "arm53: a recent close is never a drought, however stale the queue" \
   "false" "$(_sup_output_drought 3 0 9999)"
ok "arm54: a seat that has NEVER closed anything stays unknown, not dry" \
   "false" "$(_sup_output_drought 3 -1 9999)"
ok "arm55: the idle window's own edge — one minute short is still quiet" \
   "false" "$(_sup_output_drought 1 3 1439)"
ok "arm56: ...and exactly at the window it pages" \
   "true" "$(_sup_output_drought 1 3 1440)"
ok "arm57: garbage in the queue clock reads UNKNOWN, never fresh" \
   "true" "$(_sup_output_drought 1 3 "soon")"
# M4: the mutant the row asked for — drop the new comparison. Re-run arm49.
M4f() {  # the pre-4666 conjunction, verbatim
  local open="${1:-0}" days="${2:--1}"
  (( open > 0 )) && (( days >= 0 )) && (( days >= _SUP_T_NO_OUTPUT_DAYS )) \
    && { printf 'true'; return; }
  printf 'false'
}
reds "arm58: MUTANT 4 — dropping the movement comparison reds arm49" \
     "false" "$(M4f 1 3 5)"
ok "arm59: ...and MUTANT 4 agrees with the real predicate everywhere else (arm50)" \
   "true" "$(M4f 1 3 2880)"
# The phrase the page quotes.
ok "arm60: minutes stay minutes" "5m"  "$(_sup_ago_phrase 5)"
ok "arm61: an hour reads as hours"  "2h"  "$(_sup_ago_phrase 120)"
ok "arm62: two days read as days"   "2d"  "$(_sup_ago_phrase 2880)"
ok "arm63: an unmeasured age renders nothing at all" "" "$(_sup_ago_phrase -1)"

# ── I. THE CODEX PAGE, END TO END, THROUGH THE REAL RECORD PATH ─────────────
# Only the store read is stubbed; every other signal is the real function
# answering on a clean pane. NOW is the second the codex page was sent.
CODEX_AT=1789890000   # 2026-09-20 07:40:00Z
rec() {  # <ostats>  -> the agent record JSON
  local stats="$1"
  (
    systemctl() { printf 'ActiveState=active\nSubState=running\nActiveEnterTimestamp=n/a\n'; }
    db() { echo 0; }
    _sup_quota_pane_capture() { printf '%s\n' 'nothing interesting on this pane at all'; }
    _sup_verify_challenge() { :; }
    _sup_prompt_pane() { :; }
    sudo() { return 0; }
    _sup_activity_epoch() { :; }
    _sup_goal_drift() { :; }
    _sup_output_stats() { printf '%s\n' "$stats"; }
    _sup_agent_record codex claude "" agent-codex.service agent-codex codex /home/agent-codex "$CODEX_AT" running
  )
}
C1=$(rec "1|3|5")
ok "arm64: THE 07:40Z PAGE — a seat whose only open row is 5 minutes old does not classify no-output" \
   "healthy" "$(jq -r '.classification' <<<"$C1")"
C2=$(rec "1|3|2880")
ok "arm65: ...and the same row after 2 days with no start/deliver since still does" \
   "no-output" "$(jq -r '.classification' <<<"$C2")"
has "arm66: ...and the page now says WHY, in a duration a person reads" \
    "nothing picked up in 2d" "$(jq -r '.detail' <<<"$C2")"
ok  "arm67: the queue clock is recorded on the audited row, not just consumed" \
    "2880" "$(jq -r '.signals.minsSinceQueueMoved' <<<"$C2")"
# A 2-field stats string is the pre-4666 shape: unknown movement, unchanged verdict.
C3=$(rec "1|3")
ok "arm68: a pre-4666 two-field store read still classifies exactly as it did" \
   "no-output" "$(jq -r '.classification' <<<"$C3")"
ok "arm69: ...with a byte-identical detail line" \
   "1 open row(s), nothing closed in 3d" "$(jq -r '.detail' <<<"$C3")"

# ── I2. SURFACE PARITY — `agent info` must not go on calling it dry ─────────
INFO_FRESH=$(_sup_info_status true "$CODEX_AT" "$CODEX_AT" "$CODEX_AT" healthy "" "" 1 3 true "" 5)
ok  "arm70: the drill-down a person opens after a page agrees with the tick" \
    "true" "$(jq -r '.transacting' <<<"$INFO_FRESH")"
has "arm71: ...and says which fact refutes the drought" \
    "picked up 5m ago" "$(jq -r '.note' <<<"$INFO_FRESH")"
INFO_DRY=$(_sup_info_status true "$CODEX_AT" "$CODEX_AT" "$CODEX_AT" no-output no-output "" 1 3 true "" 2880)
ok  "arm72: a real drought still reads dry there" \
    "false" "$(jq -r '.transacting' <<<"$INFO_DRY")"
INFO_LEGACY=$(_sup_info_status true "$CODEX_AT" "$CODEX_AT" "$CODEX_AT" no-output no-output "" 1 3 true "")
ok  "arm73: an 11-arg call is byte-identical to pre-4666" \
    "$(jq -r '.note' <<<"$INFO_LEGACY")" "1 open row(s), nothing closed in 3d"

# ── J. THE STORE READ ITSELF — the real SQL, on a scratch sqlite file ───────
# quinn's it.1 third finding was that the I/O half of this row had zero arms.
# This is the half THIS iteration adds, so it gets one: the real
# `_sup_output_stats` text, run by sqlite3 against a throwaway store.
# The cleanup is FOLDED INTO the marker trap at the top of this file, not
# registered as a second one: bash keeps only the LAST trap per signal, so a
# bare `trap ... EXIT` here silently removes the HARNESS-RC line the corpus
# contract requires (tests/harness_rc_corpus_contract_unit.sh). rc=$? stays
# first so the cleanup cannot overwrite the exit code.
SCRATCH=$(mktemp -d)
trap 'rc=$?; rm -rf "$SCRATCH"; echo "HARNESS-RC=$rc"' EXIT
STORE="$SCRATCH/tasks.db"
sqlite3 "$STORE" "CREATE TABLE tasks (id INTEGER PRIMARY KEY, assignee TEXT, status TEXT,
  kind TEXT DEFAULT 'standard', created_at TEXT, started_at TEXT, first_started_at TEXT, done_at TEXT);"
stats() {  # <seat>
  ( db() { sqlite3 "$STORE" "$1"; }; _sup_output_stats "$1" )
}
ins() {  # <assignee> <status> <created> <started> <first_started> <done>
  sqlite3 "$STORE" "INSERT INTO tasks(assignee,status,kind,created_at,started_at,first_started_at,done_at)
    VALUES ('$1','$2','standard',datetime('now','$3'),
            $([[ "$4" == "-" ]] && echo NULL || echo "datetime('now','$4')"),
            $([[ "$5" == "-" ]] && echo NULL || echo "datetime('now','$5')"),
            $([[ "$6" == "-" ]] && echo NULL || echo "datetime('now','$6')"));"
}
# codex at 07:40Z: one open row created 9 minutes ago, first started 6 ago; the
# last close was 3 days back.
ins codex in_progress '-9 minutes' '-6 minutes' '-6 minutes' -
ins codex done '-40 days' '-40 days' '-40 days' '-3 days'
CX=$(stats codex)
ok "arm74: THE REAL READ — three fields, not two" "3" "$(awk -F'|' '{print NF}' <<<"$CX")"
ok "arm75: ...one open row"        "1" "$(cut -d'|' -f1 <<<"$CX")"
ok "arm76: ...a 3-day close drought" "3" "$(cut -d'|' -f2 <<<"$CX")"
ok "arm77: ...and a queue that moved 6 minutes ago" "6" "$(cut -d'|' -f3 <<<"$CX")"
ok "arm78: ...so the real store read, fed to the real predicate, withholds the page" \
   "false" "$(_sup_output_drought $(tr '|' ' ' <<<"$CX"))"
# A RE-DISPATCH must not launder a dark seat: started_at is re-stamped by every
# _hb_claim_task out of todo, first_started_at is not. This is why the COALESCE
# reads first_started_at FIRST, and the arm is the proof.
ins dark todo '-4 days' '-2 minutes' '-4 days' -
ins dark done '-40 days' '-40 days' '-40 days' '-5 days'
DK=$(stats dark)
ok "arm79: a row re-claimed 2 minutes ago still reads its FIRST start, 4 days back" \
   "5760" "$(cut -d'|' -f3 <<<"$DK")"
ok "arm80: ...so DIVE-3272's dark seat still pages through a re-dispatch storm" \
   "true" "$(_sup_output_drought $(tr '|' ' ' <<<"$DK"))"
# A row that landed and was never claimed falls back to created_at, not to -1.
ins fresh todo '-5 minutes' - - -
ins fresh done '-40 days' '-40 days' '-40 days' '-3 days'
FR=$(stats fresh)
ok "arm81: an unclaimed row 5 minutes old measures 5 minutes, not 'unknown'" \
   "5" "$(cut -d'|' -f3 <<<"$FR")"
ok "arm82: ...and a row that just landed is not evidence of darkness" \
   "false" "$(_sup_output_drought $(tr '|' ' ' <<<"$FR"))"
# A seat with nothing open: the queue clock is genuinely unknown, and says so.
NB=$(stats nobody)
ok "arm83: a seat with no open rows reports an unknown queue clock, never 0" \
   "0|-1|-1" "$NB"

echo "known-cooldown unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
