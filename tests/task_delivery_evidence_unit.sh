#!/usr/bin/env bash
# DIVE-4576 — A DELIVERY CARRIES ITS EVIDENCE, AND A COMMAND-GRADED ROW NEVER
# BOOKS A SESSION.
#
# WHAT IS ASSERTED AND WHY EACH ARM IS THE PERSISTED STATE, NOT THE PRINTED LINE.
# The two claims this row makes are both about what the STORE looks like after a
# verb, not about what scrolled past: (a) a refused delivery left the row
# untouched — no delivery_ref, no result, no handoff clock; (b) a command-graded
# delivery attached NO grader and emitted NO spawn request, which is the whole
# saving. A harness that read the message would pass against a build that printed
# a refusal and wrote the row anyway, which is the exact failure mode DIVE-2476
# records for the already-closed guard.
#
# THE MUTATION ARMS CUT NAMED TERMS OUT OF THE SHIPPING FUNCTIONS (`declare -f`
# + sed + re-eval), never a stub, and each checks the cut LANDED before asserting
# the behaviour changed — a sed that matched nothing would otherwise leave the
# arm green having mutated nothing (the defect tests/task_review_mode_unit.sh
# records). A mutation whose arms stay green is a FAIL of this harness.
#
# Isolation: src/ sourced directly, STATE_DIR on a throwaway dir, BOX_CONFIG
# inside it, so the live box's policy is never read and the shared tasks.db is
# never touched. No root, no network.
# Run: bash tests/task_delivery_evidence_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-delivery-evidence.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
printf '{"verify":"always"}\n' > "$BOX_CONFIG"

PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1

# A distinct grader always exists, so an empty verifier column can only mean the
# code declined to attach one — never "none was available", a third state that
# would make the command-graded arms pass for a wrong reason.
_task_default_verifier() { printf 'grader'; }
_task_require_lane()      { return 0; }
# The delivery reach probe and the spawn request both go outside this box. The
# spawn request is STUBBED TO A COUNTER rather than to a no-op: "no grader
# session was booked" is the claim, so the harness has to be able to see one.
_task_deliver_reach_probe() { return 0; }
SPAWNS="$TMP/spawns"; : > "$SPAWNS"
_grader_spawn_request() { printf '%s\n' "${1:-}" >> "$SPAWNS"; return 0; }
spawn_count() { wc -l < "$SPAWNS" | tr -d ' '; }

PR=https://github.com/5dive-ai/5dive/pull/999
GOOD="CHANGED: src/task/delivery.sh, tests/x.sh
CHECKED: bash tests/x.sh — 14 arms, 14 pass; 3 mutation arms red on the pre-fix tree
GRADED-SHA: deadbeef
CI: green at delivery (lint+unit)
CRITERIA: (1) refusal is non-mutating -> arm 4; (2) no session booked -> arm 9"

add_row() { # <title> [flags...] -> ident
  local t="$1"; shift
  cmd_task_add "$t $RANDOM" --assignee=dev --from=main --priority=high "$@" 2>/dev/null \
    | jq -r '.data.ident // empty' 2>/dev/null
}
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

echo "── PART 1 — the contract: which texts carry evidence ─────────────"
miss() { _delivery_evidence_missing "$1"; }
[[ -z "$(miss "$GOOD")" ]] && ok_t "a filled template is complete" \
  || bad_t "a filled template is complete" "missing='$(miss "$GOOD")'"
[[ "$(miss "${GOOD/CI: green at delivery (lint+unit)/}")" == "CI" ]] \
  && ok_t "a missing field is named, and only it" \
  || bad_t "a missing field is named, and only it" "missing='$(miss "${GOOD/CI: green at delivery (lint+unit)/}")'"
[[ "$(miss "nothing was checked here at all")" == "CHANGED CHECKED GRADED-SHA CI CRITERIA" ]] \
  && ok_t "prose with no labels is missing all five" \
  || bad_t "prose with no labels is missing all five" "missing='$(miss "nothing was checked here at all")'"
# The boundary: a word ENDING in a label must not satisfy that label, and a
# label with nothing after the separator must not either. Both are the shapes
# DIVE-4144's FIX marker had to exclude, one field over.
[[ "$(miss "unCHECKED: nope")" == *CHECKED* ]] && ok_t "'unchecked:' does not satisfy CHECKED" \
  || bad_t "'unchecked:' does not satisfy CHECKED" "missing='$(miss "unCHECKED: nope")'"
[[ "$(miss "CHECKED:")" == *CHECKED* ]] && ok_t "an empty label does not satisfy its field" \
  || bad_t "an empty label does not satisfy its field" "missing='$(miss "CHECKED:")'"
ALIAS="FILES: a.sh
RAN: bash a.sh (3/3)
SHA: c0ffee
CHECKS: red on lint
ACCEPTANCE: (1) -> ran"
[[ -z "$(miss "$ALIAS")" ]] && ok_t "the documented aliases satisfy all five fields" \
  || bad_t "the documented aliases satisfy all five fields" "missing='$(miss "$ALIAS")'"
[[ -z "$(miss "$(tr 'A-Z' 'a-z' <<<"$GOOD")")" ]] && ok_t "labels are case-insensitive" \
  || bad_t "labels are case-insensitive" "missing='$(miss "$(tr 'A-Z' 'a-z' <<<"$GOOD")")'"
# nocasematch is process state a caller may rely on: the helper must restore it.
shopt -u nocasematch; miss "$GOOD" >/dev/null
shopt -q nocasematch && bad_t "nocasematch is restored after the check" "left ON" \
  || ok_t "nocasematch is restored after the check"
[[ "$(_delivery_evidence_template | wc -l)" == "5" ]] && ok_t "the template names five fields" \
  || bad_t "the template names five fields" "$(_delivery_evidence_template | wc -l) lines"
_t=$(_delivery_evidence_template); [[ -z "$(miss "$_t")" ]] \
  && ok_t "the template ITSELF satisfies the check it documents" \
  || bad_t "the template ITSELF satisfies the check it documents" "missing='$(miss "$_t")'"

echo "── PART 2 — the refusal is non-mutating, and scoped to a binding ──"
ID1=$(add_row "unevidenced delivery" --review=temp)
OUT1=$(cmd_task_deliver "$ID1" --pr="$PR" --result="did the thing, it works" 2>&1); RC1=$?
(( RC1 != 0 )) && ok_t "an unevidenced delivery is REFUSED" || bad_t "an unevidenced delivery is REFUSED" "rc=$RC1"
[[ "$(col "$ID1" delivery_ref)" == "" ]] && ok_t "the refused delivery wrote NO delivery_ref" \
  || bad_t "the refused delivery wrote NO delivery_ref" "ref='$(col "$ID1" delivery_ref)'"
[[ "$(col "$ID1" result)" == "" ]] && ok_t "the refused delivery wrote NO result" \
  || bad_t "the refused delivery wrote NO result" "result='$(col "$ID1" result)'"
[[ "$(col "$ID1" handoff_delivered_at)" == "" ]] && ok_t "the refused delivery started NO handoff clock" \
  || bad_t "the refused delivery started NO handoff clock" "stamp='$(col "$ID1" handoff_delivered_at)'"
[[ "$OUT1" == *CHANGED* && "$OUT1" == *GRADED-SHA* ]] && ok_t "the refusal names the missing fields" \
  || bad_t "the refusal names the missing fields" "$OUT1"
OUT2=$(cmd_task_deliver "$ID1" --pr="$PR" --result="$GOOD" 2>&1); RC2=$?
(( RC2 == 0 )) && ok_t "an evidenced delivery is ACCEPTED" || bad_t "an evidenced delivery is ACCEPTED" "rc=$RC2 $OUT2"
[[ "$(col "$ID1" delivery_ref)" == "$PR" ]] && ok_t "the accepted delivery bound the ref" \
  || bad_t "the accepted delivery bound the ref" "ref='$(col "$ID1" delivery_ref)'"

ID2=$(add_row "waived delivery" --review=temp)
OUT3=$(cmd_task_deliver "$ID2" --pr="$PR" --result="a revert of a revert" --force-unevidenced="pure revert, no new work" 2>&1); RC3=$?
(( RC3 == 0 )) && ok_t "--force-unevidenced proceeds" || bad_t "--force-unevidenced proceeds" "rc=$RC3 $OUT3"
[[ "$OUT3" == *"pure revert, no new work"* ]] && ok_t "the waiver's reason is printed for the grader" \
  || bad_t "the waiver's reason is printed for the grader" "$OUT3"
OUT4=$(cmd_task_deliver "$ID2" --pr="$PR" --result="still nothing" --force-unevidenced 2>&1); RC4=$?
(( RC4 != 0 )) && ok_t "a bare --force-unevidenced is a usage error" || bad_t "a bare --force-unevidenced is a usage error" "rc=$RC4"

# SCOPE: an UNBOUND row is not in scope — a knowledge/ops row closes as before.
ID3=$(add_row "unbound knowledge row" --review=none)
OUT5=$(cmd_task_done "$ID3" --result="wrote the wiki page and the index line" 2>&1); RC5=$?
(( RC5 == 0 )) && ok_t "an UNBOUND close is untouched by the rail" || bad_t "an UNBOUND close is untouched by the rail" "rc=$RC5 $OUT5"
# And the sharper case, because it is the one the scope term actually decides: a
# row that ROUTES to a grader (so it passes through the guard's funnel) but binds
# NO pull request — a knowledge row that carries a reviewer. It must hand off.
ID3B=$(add_row "unbound but routed" --review=temp)
OUT5B=$(cmd_task_done "$ID3B" --result="compiled the wiki page; no code changed" 2>&1); RC5B=$?
(( RC5B == 0 )) && ok_t "an unbound ROUTED hand-off is untouched by the rail" \
  || bad_t "an unbound ROUTED hand-off is untouched by the rail" "rc=$RC5B $OUT5B"

# A BARE delivery (no --result) is the binding operation, not a claim. Over an
# existing result it is a re-point and passes silently; over an EMPTY one it
# warns rather than refusing — the row body records why that call went this way,
# and the grader's unevidenced-FAIL is where it bites.
IDW=$(add_row "bare delivery, empty result" --review=temp)
OUTW=$( ( cmd_task_deliver "$IDW" --pr="$PR" ) 2>&1 ); RCW=$?
(( RCW == 0 )) && ok_t "a bare delivery over an EMPTY result is not refused" \
  || bad_t "a bare delivery over an EMPTY result is not refused" "rc=$RCW $OUTW"
[[ "$OUTW" == *"NO result at all"* ]] && ok_t "…but it WARNS, naming what the grader is left with" \
  || bad_t "…but it WARNS, naming what the grader is left with" "$OUTW"
IDR=$(add_row "bare re-point over an evidenced result" --review=temp)
cmd_task_deliver "$IDR" --pr="$PR" --result="$GOOD" >/dev/null 2>&1
OUTR=$( ( cmd_task_deliver "$IDR" --pr="${PR}0" ) 2>&1 ); RCR=$?
(( RCR == 0 )) && [[ "$OUTR" != *"NO result at all"* ]] \
  && ok_t "a bare RE-POINT over a standing result is silent" \
  || bad_t "a bare RE-POINT over a standing result is silent" "rc=$RCR $OUTR"

echo "── PART 3 — the other delivery verb meets the same rail ──────────"
# `task done` from a maker on a row that is already BOUND is a delivery: it
# routes through _task_route_to_verifier, and must refuse there too.
ID4=$(add_row "bound row, done fork" --review=temp)
cmd_task_deliver "$ID4" --pr="$PR" --result="$GOOD" >/dev/null 2>&1
db "UPDATE tasks SET assignee='dev', status='in_progress', verifier='grader' WHERE ident=$(sqlq "$ID4");"
OUT6=$(cmd_task_done "$ID4" --result="fixed it, looks right now" 2>&1); RC6=$?
(( RC6 != 0 )) && ok_t "'task done' on a BOUND row refuses an unevidenced result" \
  || bad_t "'task done' on a BOUND row refuses an unevidenced result" "rc=$RC6 $OUT6"

echo "── PART 4 — a command-graded row never books a grader session ─────"
CMDOK="true"; CMDBAD="false"
ID5=$(add_row "command graded, green" --review=check --verify="$CMDOK")
: > "$SPAWNS"
OUT7=$(cmd_task_deliver "$ID5" --pr="$PR" --result="$GOOD" 2>&1); RC7=$?
(( RC7 == 0 )) && ok_t "a green command-graded delivery succeeds" || bad_t "a green command-graded delivery succeeds" "rc=$RC7 $OUT7"
[[ "$(spawn_count)" == "0" ]] && ok_t "NO grader spawn request was emitted" \
  || bad_t "NO grader spawn request was emitted" "spawns=$(spawn_count)"
[[ "$(col "$ID5" verifier)" == "" ]] && ok_t "NO grader was attached to the row" \
  || bad_t "NO grader was attached to the row" "verifier='$(col "$ID5" verifier)'"
[[ -n "$(col "$ID5" graded_at)" ]] && ok_t "the command's verdict was recorded as the grade" \
  || bad_t "the command's verdict was recorded as the grade" "graded_at empty"
[[ "$(col "$ID5" result)" == *"verify PASS"* ]] && ok_t "the grade receipt is on the row" \
  || bad_t "the grade receipt is on the row" "result='$(col "$ID5" result)'"
[[ "$(col "$ID5" assignee)" == "dev" ]] && ok_t "the row was NOT routed away from the maker" \
  || bad_t "the row was NOT routed away from the maker" "assignee='$(col "$ID5" assignee)'"

ID6=$(add_row "command graded, red" --review=check --verify="$CMDBAD")
: > "$SPAWNS"
OUT8=$(cmd_task_deliver "$ID6" --pr="$PR" --result="$GOOD" 2>&1); RC8=$?
(( RC8 != 0 )) && ok_t "a RED command-graded delivery is refused" || bad_t "a RED command-graded delivery is refused" "rc=$RC8"
[[ "$(spawn_count)" == "0" ]] && ok_t "a red delivery books no session to discover the red" \
  || bad_t "a red delivery books no session to discover the red" "spawns=$(spawn_count)"
[[ "$(col "$ID6" handoff_delivered_at)" == "" ]] && ok_t "a red delivery starts no handoff clock" \
  || bad_t "a red delivery starts no handoff clock" "stamp='$(col "$ID6" handoff_delivered_at)'"

# The maker may ADD the command at delivery.
ID7=$(add_row "command added at delivery")
: > "$SPAWNS"
OUT9=$(cmd_task_deliver "$ID7" --pr="$PR" --result="$GOOD" --verify="$CMDOK" 2>&1); RC9=$?
(( RC9 == 0 )) && ok_t "--verify at delivery grades the row" || bad_t "--verify at delivery grades the row" "rc=$RC9 $OUT9"
[[ "$(col "$ID7" verify_command)" == "$CMDOK" ]] && ok_t "the delivery-time command is PERSISTED" \
  || bad_t "the delivery-time command is PERSISTED" "cmd='$(col "$ID7" verify_command)'"
[[ "$(col "$ID7" review_mode)" == "check" ]] && ok_t "the row's review mode becomes check" \
  || bad_t "the row's review mode becomes check" "mode='$(col "$ID7" review_mode)'"
[[ "$(spawn_count)" == "0" ]] && ok_t "adding the command at delivery books no session" \
  || bad_t "adding the command at delivery books no session" "spawns=$(spawn_count)"

# A row that PINNED a grading seat is not silently downgraded to a command.
ID8=$(add_row "pinned seat, command offered" --review=grader)
OUTA=$(cmd_task_deliver "$ID8" --pr="$PR" --result="$GOOD" --verify="$CMDOK" 2>&1)
[[ "$OUTA" == *"as its grader"* ]] && ok_t "a row pinning a NAMED grader is not downgraded" \
  || bad_t "a row pinning a NAMED grader is not downgraded" "$OUTA"
[[ "$(col "$ID8" verify_command)" == "$CMDOK" ]] && ok_t "the offered command is still stored for that grader" \
  || bad_t "the offered command is still stored for that grader" "cmd='$(col "$ID8" verify_command)'"

echo "── PART 5 — mutation arms: each named term is LIVE ───────────────"
# (a) the BINDING scope term. Cut it and an unbound close must start refusing —
# if it does not, the term was not what kept knowledge rows out of the rail.
ORIG_GUARD=$(declare -f _task_guard_delivery_evidence)
MUT=$(printf '%s\n' "$ORIG_GUARD" | sed '0,/\[\[ -n "\$_ev_ref" \]\] || return 0/s//:/')
if [[ "$MUT" == "$ORIG_GUARD" ]]; then
  bad_t "mutation (a) landed" "sed matched nothing — the arm below would be vacuous"
else
  eval "$MUT"
  # The same shape as the positive control above — routed, unbound — so the arm
  # measures the scope term and not the difference between two row kinds.
  ID9=$(add_row "unbound routed, guard mutated" --review=temp)
  # In a SUBSHELL: a refusal is a `fail`, i.e. an exit, and an exit in the main
  # shell would take the harness with it — silently, mid-part, which reads as a
  # hang rather than as the arm's own result.
  ( cmd_task_done "$ID9" --result="compiled the wiki page; no code changed" ) >/dev/null 2>&1
  RCM=$?
  (( RCM != 0 )) && ok_t "cutting the binding scope makes an unbound close refuse (term is live)" \
    || bad_t "cutting the binding scope makes an unbound close refuse (term is live)" "rc=$RCM — the scope term is NOT what exempts unbound rows"
  eval "$ORIG_GUARD"
fi
# (b) the FIELD LIST. Drop CI from it and a text missing only CI must pass.
ORIG_FIELDS="$_DELIVERY_EVIDENCE_FIELDS"
_DELIVERY_EVIDENCE_FIELDS='CHANGED CHECKED GRADED-SHA CRITERIA'
[[ -z "$(miss "${GOOD/CI: green at delivery (lint+unit)/}")" ]] \
  && ok_t "dropping CI from the field list changes the answer (the list is read)" \
  || bad_t "dropping CI from the field list changes the answer (the list is read)" "still missing '$(miss "${GOOD/CI: green at delivery (lint+unit)/}")'"
_DELIVERY_EVIDENCE_FIELDS="$ORIG_FIELDS"
# (c) the COMMAND-GRADE early return. Cut it and a green check row must fall
# through to the grader attach — i.e. book the session this row exists to save.
ORIG_DELIV=$(declare -f cmd_task_deliver)
MUT2=$(printf '%s\n' "$ORIG_DELIV" | sed '0,/if _task_deliver_command_grade "\$id" "\$ident" "\$deliver_cmd" "\$result" "\$want_result"; then/s//if false; then/')
if [[ "$MUT2" == "$ORIG_DELIV" ]]; then
  bad_t "mutation (c) landed" "sed matched nothing — the arm below would be vacuous"
else
  eval "$MUT2"
  IDA=$(add_row "check row, grade path cut" --review=check --verify="$CMDOK")
  : > "$SPAWNS"
  ( cmd_task_deliver "$IDA" --pr="$PR" --result="$GOOD" ) >/dev/null 2>&1
  [[ "$(col "$IDA" verifier)" != "" || "$(spawn_count)" != "0" ]] \
    && ok_t "cutting the command-grade path books a grader again (the path is what saves it)" \
    || bad_t "cutting the command-grade path books a grader again" "no grader attached even with the path cut — the saving is not attributable to it"
  eval "$ORIG_DELIV"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAILN"
(( FAILN == 0 ))
