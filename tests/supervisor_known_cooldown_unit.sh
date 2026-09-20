#!/usr/bin/env bash
# DIVE-4666 — a FLEET-HEALTH page for a seat on a 5h usage cooldown reached a
# human at 2026-09-20 07:00:33Z. The supervisor had measured the wall AND its
# reset time six ticks running; the page dropped both and asked the reader to
# go check the quota reset.
#
# Every arm here is PURE — _sup_wall_verdict, _sup_wall_reset_of,
# _sup_capacity_notify_{human,machine}, _sup_capacity_tail, quota_wall_when.
# No tmux, no root, no db, no clock (every arm passes `now` explicitly).
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

# ── G. MUTANTS — each must red the arm above it ─────────────────────────────
# M1: drop the reset comparison (the row named this mutant).
_sup_wall_verdict_M1() { printf 'lapsed'; }
ok "arm43: MUTANT 1 — a verdict that never compares the reset reds arm38" \
   "lapsed" "$(_sup_wall_verdict_M1 "$RESET" "$ALERT_AT" "$TICK")"
# M2: gate the human leg only (what a class-keyed reading of the row produces).
_sup_capacity_notify_machine_M2() {
  local class="${1:-}" quota_alerts_on="${2:-true}"
  [[ "$class" == "quota-exhausted" ]] && { printf '%s' "$quota_alerts_on"; return; }
  printf 'true'
}
ok "arm44: MUTANT 2 — a human-leg-only gate still sends the page that fired" \
   "true" "$(_sup_capacity_notify_machine_M2 "no-output" "true" "cooling")"
# M3: key the gate on the TICK'S CLASS (the row's literal text) instead of the
# seat's wall — the version that would not have stopped this page.
_sup_capacity_notify_machine_M3() {
  local class="${1:-}" quota_alerts_on="${2:-true}" wall_state="${3:-none}"
  [[ "$class" == "quota-exhausted" && "$wall_state" == "cooling" ]] && { printf 'false'; return; }
  [[ "$class" == "quota-exhausted" ]] && { printf '%s' "$quota_alerts_on"; return; }
  printf 'true'
}
ok "arm45: MUTANT 3 — keying on the tick's class lets the no-output page through" \
   "true" "$(_sup_capacity_notify_machine_M3 "no-output" "true" "cooling")"

echo "known-cooldown unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
