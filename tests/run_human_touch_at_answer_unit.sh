#!/usr/bin/env bash
# A run counts a human touch when a HUMAN ANSWERED its gate — not when a gate was filed.
#
# THE DEFECT. `cmd_task_need` set `runs.human_touch=1` at FILING time for every
# tier above 0 (src/task/need.sh). Tier says how big the ask is, not who answers
# it: a TIER-1 GATE IS ROUTED TO THE LEAD SEAT, WHICH IS AN AGENT — queued with
# no a2a send and no wake — and cleared by that agent. So every lead-reviewed row
# reported a person who never saw it. Measured on a live box: one row's only gate
# was filed 05:40:11Z and cleared by a sibling agent 66 seconds later, and one
# `trace` invocation printed the attempts line `[human touch]` and the verdict
# `zero-human — goal to done with 0 human touchpoints` on the same screen —
# `runs[0].human_touch = 1` against `human_touchpoints = 0`.
#
# TWO METRICS FOR ONE QUESTION, DISAGREEING, is the part that makes this worth a
# fix rather than a tuning. "Human touches per shipped task" is the metric the
# zero-human thesis is graded on, and `trace` already had the right predicate:
# gate epochs `WHERE who LIKE 'human:%'` (src/cmd_trace.sh). The flag now follows
# the same rule, at the two moments the answerer is actually known:
#
#   ANSWER   — provenance. `need_answered_by` starts `human:` only on the
#              verified-human path (DIVE-394), so `auto:ttl` / `auto:reject` /
#              `auto:t0` and every agent clear now touch nothing, at any tier.
#   WITHDRAW — delivery. The original filing-time comment defended itself with "a
#              gate that was filed and withdrawn still cost a human", which is
#              true and is exactly this path, because the archive nulls every
#              answer column. Charged on `gate_pinged_at` (the last CONFIRMED Bot
#              API delivery) with no answer — the ask reached a person's chat.
#
# Arm D is the site this fix deliberately does NOT add, with the measurement that
# says why. Run: bash tests/run_human_touch_at_answer_unit.sh (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP="$(mktemp -d /tmp/run-human-touch.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/runs.sh lib/actor.sh cmd_task.sh cmd_org.sh \
         cmd_project.sh cmd_trace.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2

# THE HOST IS NOT AN INPUT. STATE_DIR, the task store and every write this file
# makes live under $TMP; CI has no /var/lib/5dive, no /etc/5dive and no installed
# CLI, and arm E asserts the changed source reads none of them rather than
# assuming it.
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Preconditions, not observables — same seams as tests/trace_human_touchpoint_history_unit.sh.
task_need_notify() { return 0; }
audit_log() { return 0; }
_gate_proof_enforced() { return 0; }
_gate_withdraw_actor() { printf 'human'; }
# The SEAT is seamed, not the metric. `_run_seat` resolves through the caller's
# uid on a real box; pinning it is what lets run_current() find the run this
# harness opened. Which seat it is has no bearing on any arm below — the subject
# is whether the ANSWERER was a person.
SEAT=marcus
_run_seat() { printf '%s' "$SEAT"; }

addt()     { ( JSON_MODE=1; cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
ident_of() { db "SELECT ident FROM tasks WHERE id=${1};"; }
touch_of() { db "SELECT COALESCE(human_touch,0) FROM runs WHERE task_id=${1} ORDER BY id DESC LIMIT 1;"; }
# The OTHER reader of the same fact — the one that disagreed on the live box.
tp_of()    { ( JSON_MODE=1; cmd_trace "$(ident_of "$1")" --no-audit ) 2>/dev/null | jq -r '.data.human_touchpoints'; }
verdict_of() { ( JSON_MODE=0; cmd_trace "$(ident_of "$1")" --no-audit ) 2>/dev/null | sed -n 's/^verdict: //p'; }

# A row with an OPEN run, which is what the flag lives on.
new_row() {
  local t; t=$(addt --assignee="$SEAT" -- "fixture: $1")
  run_open "$t" "$(ident_of "$t")" "" "" "$SEAT" >/dev/null 2>&1
  printf '%s' "$t"
}
file_gate() { # <id> <tier>
  ( cmd_task_need "$1" --type=decision --options="A|B" \
      --ask-ok="fixture gate: the options ARE the input under test, not prose a person reads (DIVE-4462)" \
      --recommend="A" --ask="fixture gate on $1" --tier="$2" ) >/dev/null 2>&1
}
# Answer by writing the columns the product reads, then invoking the flag rule
# exactly as src/task/answer.sh does. Written this way so the arm does not depend
# on cmd_task_answer's own human-only policy checks (the pattern
# tests/gate_history_unit.sh and its siblings use), while still grading the REAL
# `run_touch_human` and the REAL provenance predicate.
answer_as() { # <id> <need_answered_by>
  local id="$1" who="$2"
  db "UPDATE tasks SET need_answer='B', need_answered_at=datetime('now'),
        need_answered_by=$(sqlq "$who"), need_answered_uid=1000, need_answer_sig='sig-fixture'
      WHERE id=${id};"
  local _lg_prov; _lg_prov=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};" 2>/dev/null)
  if [[ "$_lg_prov" == human:* ]]; then
    run_touch_human "$(run_current "$id")" || true
  fi
}

# --- A. FILING no longer charges anybody ------------------------------------
a1=$(new_row "tier-1 gate, filed"); file_gate "$a1" 1
if [[ "$(touch_of "$a1")" == "0" ]]; then
  ok_t "A1 THE DEFECT'S CELL: filing a TIER-1 gate leaves human_touch=0 — it is routed to the lead SEAT, which is an agent"
else
  bad_t "A1 filing a tier-1 gate still charged a human" "human_touch=$(touch_of "$a1") — every lead-reviewed row reports a person who never saw it"
fi
a2=$(new_row "tier-2 gate, filed"); file_gate "$a2" 2
if [[ "$(touch_of "$a2")" == "0" ]]; then
  ok_t "A2 ...and a TIER-2 filing does not either: tier says how big the ask is, never who answered it"
else
  bad_t "A2 filing a tier-2 gate charged a human before any answer" "human_touch=$(touch_of "$a2")"
fi
a3=$(new_row "tier-0 gate, filed"); file_gate "$a3" 0
if [[ "$(touch_of "$a3")" == "0" ]]; then
  ok_t "A3 tier 0 is unchanged — it was already excluded, on the argument this fix extends to the other two"
else
  bad_t "A3 tier-0 filing charged a human" "human_touch=$(touch_of "$a3")"
fi
# The run TIMELINE event stays: a reader still sees where the gate opened, which
# is a different fact from whether it cost a person.
# run ids are STRINGS (R-<hex>), so the id has to be quoted into the SQL — an
# unquoted one is parsed as a bare token and sqlite refuses the statement.
_a4() { db "SELECT COUNT(*) FROM run_events WHERE run_id=$(sqlq "$(run_current "$a1")") AND kind='gate.opened';"; }
if [[ "$(_a4)" == "1" ]]; then
  ok_t "A4 the gate.opened run event still fires — the timeline keeps the gate, only the CHARGE moved"
else
  bad_t "A4 gate.opened was lost with the flag" "count=$(_a4)"
fi

# --- B. ANSWER charges by PROVENANCE ----------------------------------------
b1=$(new_row "tier-1 gate cleared by a lead AGENT"); file_gate "$b1" 1
answer_as "$b1" 'claude-luca'
if [[ "$(touch_of "$b1")" == "0" ]]; then
  ok_t "B1 a lead AGENT clearing a tier-1 gate is not a human touch — this is the live-box row, reproduced"
else
  bad_t "B1 an agent-cleared gate counted as a human touch" "human_touch=$(touch_of "$b1")"
fi
# The row is still open, so the verdict is trace's in-progress wording rather
# than the `zero-human` it prints at done. What is graded is the COUNT the two
# readers report, which is the thing that disagreed on the live box; pinning the
# done-only string here would grade trace's phrasing instead.
if [[ "$(verdict_of "$b1")" == *"0 human touchpoint"* && "$(tp_of "$b1")" == "0" ]]; then
  ok_t "B1a ...and trace agrees on the same row: 0 human touchpoints, in its count AND its verdict line"
else
  bad_t "B1a trace disagreed with the flag" "verdict='$(verdict_of "$b1")' touchpoints=$(tp_of "$b1")"
fi
b2=$(new_row "gate cleared by a verified HUMAN"); file_gate "$b2" 1
answer_as "$b2" 'human:1234567890'
if [[ "$(touch_of "$b2")" == "1" ]]; then
  ok_t "B2 a verified human clearing the gate IS a human touch — the flag still fires where it should"
else
  bad_t "B2 a human-cleared gate was not counted" "human_touch=$(touch_of "$b2") — the fix would have removed the metric rather than corrected it"
fi
if [[ "$(tp_of "$b2")" == "1" ]]; then
  ok_t "B2a ...and trace counts the same 1 — ONE question, ONE answer, which is the whole point"
else
  bad_t "B2a the two readers disagree again" "flag=$(touch_of "$b2") touchpoints=$(tp_of "$b2")"
fi
# The auto closures, which the filing-time rule also mis-charged at any tier.
for prov in auto:ttl auto:reject auto:t0; do
  bx=$(new_row "gate closed by $prov"); file_gate "$bx" 1
  answer_as "$bx" "$prov"
  if [[ "$(touch_of "$bx")" == "0" ]]; then
    ok_t "B3 '$prov' closes the gate without charging a person"
  else
    bad_t "B3 '$prov' counted as a human touch" "human_touch=$(touch_of "$bx")"
  fi
done

# --- C. WITHDRAW charges by DELIVERY ----------------------------------------
# "Filed and withdrawn still cost a human" is the one true half of the old
# filing-time argument, and it survives here — but on evidence the ask was
# DELIVERED, not on the tier it was filed at.
c1=$(new_row "delivered gate, withdrawn unanswered"); file_gate "$c1" 1
db "UPDATE tasks SET gate_pinged_at=datetime('now') WHERE id=${c1};"
( cmd_task_need "$c1" --withdraw ) >/dev/null 2>&1
if [[ "$(touch_of "$c1")" == "1" ]]; then
  ok_t "C1 a DELIVERED gate withdrawn unanswered still charges the person it reached — no answer row survives to infer it from"
else
  bad_t "C1 a delivered-and-withdrawn gate lost its human touch" "human_touch=$(touch_of "$c1") — this is the property the filing-time flag was defending"
fi
c2=$(new_row "undelivered gate, withdrawn unanswered"); file_gate "$c2" 1
db "UPDATE tasks SET gate_pinged_at=NULL WHERE id=${c2};"
( cmd_task_need "$c2" --withdraw ) >/dev/null 2>&1
if [[ "$(touch_of "$c2")" == "0" ]]; then
  ok_t "C2 a gate withdrawn before it was ever delivered charges nobody — nothing reached a chat"
else
  bad_t "C2 an undelivered gate charged a human" "human_touch=$(touch_of "$c2")"
fi
# THE ORDERING IS LOAD-BEARING, so it is pinned rather than trusted: the withdraw
# transaction nulls gate_pinged_at itself, so an implementation that read the
# column AFTER the clear would see NULL on every row and C1 would silently become
# unreachable — a fix that passes its own test by never firing.
if [[ "$(db "SELECT COALESCE(gate_pinged_at,'') FROM tasks WHERE id=${c1};")" == "" ]]; then
  ok_t "C3 ...and the withdraw clears gate_pinged_at, so C1's read HAS to happen before the transaction"
else
  bad_t "C3 gate_pinged_at survived the withdraw" "the ordering this fix depends on does not hold"
fi

# --- D. PARK: the fourth site, and why it is NOT one -------------------------
# The obvious symmetry is to charge the same delivered-and-unanswered gate at the
# PARK site too. It cannot fire: park REFUSES over a live gate — need_type set,
# need_answered_at NULL, row still open (DIVE-1453) — which is exactly the state
# that would be chargeable. Anything reaching the park UPDATE with a stale
# gate_pinged_at is a ping belonging to an epoch already retired and already
# charged, so touching there would double-count a person who was asked once.
# Measured, not reasoned: the refusal is exercised.
d1=$(new_row "park attempted over a live gate"); file_gate "$d1" 1
db "UPDATE tasks SET gate_pinged_at=datetime('now') WHERE id=${d1};"
( cmd_task_park "$d1" --reason="fixture" --wake="+1d" ) >/dev/null 2>&1
if [[ "$(db "SELECT status FROM tasks WHERE id=${d1};")" != "blocked" ]] \
   || [[ "$(db "SELECT COALESCE(parked_at,'') FROM tasks WHERE id=${d1};")" == "" ]]; then
  ok_t "D1 park is REFUSED over a live gate, so a delivered-and-unanswered gate never reaches the park path — no touch site is added there"
else
  bad_t "D1 park went through over a live gate" "the park site WOULD be chargeable and this fix is incomplete — status=$(db "SELECT status FROM tasks WHERE id=${d1};")"
fi

# --- E. the host-pristine control -------------------------------------------
# CI has no /usr/local/bin/5dive, no /etc/5dive, no /var/lib/5dive and no sudo. A
# predicate short-circuiting on one of those passes at a desk and reds on the
# runner, so it is asserted as a property of the changed hunks.
_changed_hunks="$(sed -n '/DIVE-3932 (this row)/,/^    fi$/p' "$SRC/task/need.sh"; \
                  sed -n '/AND THE HUMAN-TOUCH FLAG, HERE/,/^  fi$/p' "$SRC/task/answer.sh")"
if [[ -n "$_changed_hunks" ]] && ! grep -qE '/usr/local/bin|/etc/5dive|/var/lib/5dive' <<<"$_changed_hunks"; then
  ok_t "E the changed hunks read no absolute host path — nothing here can short-circuit on what CI does not install"
else
  bad_t "E a changed hunk names a host path, or could not be extracted" \
        "$(grep -nE '/usr/local/bin|/etc/5dive|/var/lib/5dive' <<<"$_changed_hunks")"
fi
if [[ "$(cd "$TASKS_DIR" && pwd -P)" == "$(cd "$TMP" && pwd -P)"/* ]]; then
  ok_t "E1 ...and every write this harness made is under its own tempdir"
else
  bad_t "E1 the fixture store escaped the tempdir" "TASKS_DIR=$TASKS_DIR"
fi

# ------------------------------------------------------------- wiring arms ---
# W1 IS WRITTEN AS A PROXIMITY SCAN, NOT A SED RANGE. The first version used
# `sed -n '/gate.filed/,/DIVE-891 tier 0/p'` and reported the filing call GONE on
# an unmodified tree — the range anchors matched earlier in the file, so the arm
# was a false green on exactly the tree it exists to catch. This instead asks the
# question directly: does a `run_touch_human` call sit within three lines of a
# tier test? That is the deleted construct, and nothing else in the file has that
# shape.
_w1_tier_guarded=$(awk '
  /"\$tier" != "0"/ { hot = NR }
  /run_touch_human/  { if (hot && NR - hot <= 3) n++ }
  END { print n + 0 }' "$SRC/task/need.sh")
_w1_calls=$(grep -c 'run_touch_human "\$(run_current' "$SRC/task/need.sh")
if [[ "$_w1_tier_guarded" == "0" && "$_w1_calls" == "1" ]]; then
  ok_t "W1 no tier-guarded run_touch_human survives in need.sh, and its one remaining call is the withdraw path"
else
  bad_t "W1 the filing-time call is still there" \
        "tier-guarded calls=$_w1_tier_guarded, total calls=$_w1_calls — every arm in A grades dead code"
fi
# ...and that one call is the DELIVERY-guarded one, not a tier test wearing a new name.
if awk '/if \(\( _wd_touch \)\); then/ { hot = NR } /run_touch_human/ { if (hot && NR - hot <= 2) n++ } END { exit !(n >= 1) }' "$SRC/task/need.sh"; then
  ok_t "W1a ...and it is guarded by the delivery reading (_wd_touch), taken before the transaction nulls it"
else
  bad_t "W1a the withdraw call is not delivery-guarded" ""
fi
if grep -q 'human_touch=1' "$SRC/lib/runs.sh" && grep -q 'run_touch_human' "$SRC/task/answer.sh"; then
  ok_t "W2 the answer path is the one that calls it, and run_touch_human itself is unchanged"
else
  bad_t "W2 the answer path does not charge the touch" ""
fi
# The predicate must be the SAME one trace uses, spelled the same way.
if grep -q "_lg_prov\" == human:\*" "$SRC/task/answer.sh" && grep -q "who LIKE 'human:%'" "$SRC/cmd_trace.sh"; then
  ok_t "W3 both readers key on the human: provenance prefix — the disagreement cannot come back by drift in one of them"
else
  bad_t "W3 the two readers use different predicates" ""
fi

# ---------------------------------------------------------------- MUTANT arm -
# Re-introduce the deleted filing-time rule, byte for byte, and require the
# lead-answered case to read 1 again. The mutation is applied to a SEPARATE row
# so the arms above keep their verdicts, and it is asserted to have changed
# something before its strike-out is believed.
m1=$(new_row "MUTANT: filing-time charge restored"); file_gate "$m1" 1
_m_before="$(touch_of "$m1")"
# the deleted lines, verbatim:
_m_tier=1
if [[ "$_m_tier" != "0" ]]; then
  run_touch_human "$(run_current "$m1")" || true
fi
_m_after="$(touch_of "$m1")"
if [[ "$_m_before" == "0" && "$_m_after" == "1" ]]; then
  ok_t "M0 MUTANT changes the reading: 0 -> 1 on a filed-but-unanswered gate, so the strike-out below is not vacuous"
else
  bad_t "M0 the mutation is a no-op" "before=$_m_before after=$_m_after"
fi
answer_as "$m1" 'claude-luca'
if [[ "$(touch_of "$m1")" == "1" ]]; then
  ok_t "M1 MUTANT — arm B1 is RED on it: a gate cleared by a lead AGENT reads human_touch=1. The live-box defect, reproduced"
else
  bad_t "M1 mutant must reproduce the defect" "human_touch=$(touch_of "$m1") — arm B1 is vacuous"
fi
if [[ "$(tp_of "$m1")" == "0" ]]; then
  ok_t "M2 ...while trace still reads 0 on that same row — the two-metrics-one-question contradiction, on screen"
else
  bad_t "M2 the contradiction did not reproduce" "touchpoints=$(tp_of "$m1")"
fi

echo
printf 'run_human_touch_at_answer: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
