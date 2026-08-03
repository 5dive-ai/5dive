#!/usr/bin/env bash
# DIVE-2301 isolated unit harness for the LEADING WORD BOUNDARY on the tier-2
# category floor (src/cmd_task.sh _gate_tier2_floor_hit / _gate_tier2_floor_term).
#
# THE DEFECT. The floor terms are a bare alternation with no boundary, which makes
# every term a SUBSTRING matcher: 'press' fired on suppression/expression/
# compressed/depression, 'charge' on recharge/supercharge. Both live on the
# NON-APPEALABLE half, so a gate whose ask legitimately said "stop forging a
# suppression" floored to tier 2 with NO appeal path, on a word about neither the
# press nor money. DIVE-2273 escaped only because its hit landed in the TITLE,
# which DIVE-2224 answer A exempts; the same word in an ask has no exemption.
#
# BOTH HALVES ARE ARMS, on purpose. A suite that only asserts the false positives
# are gone can be satisfied by deleting the terms, and a later "fix" that breaks
# the true positives would stay green. T2 is the true-positive half and it must
# include INFLECTIONS (revoked, truncated, charges, pressing) — the boundary is
# LEADING only precisely so those keep matching.
#
# T3 IS THE ARM THAT MATTERS MOST and it is not in the ticket. The prescribed fix
# — write \b onto each term — CANNOT anchor the money terms: \b asserts a
# word/non-word transition and '$' is not a word character, so `\b\$[0-9]` never
# matches and "approve $500 for ads" stops flooring altogether. That converts a
# false positive into a false NEGATIVE on the one class with no escape path. T3
# fails against a per-term-\b implementation and passes against the shipped one.
#
# MUTATION GRADE: drop `(^|[^[:alnum:]_])` from _gate_tier2_floor_hit and T1 must
# go red (7 arms). Re-anchor with per-term \b instead and T3 must go red. If
# either mutation is green the arms are only asserting today's behaviour.
#
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR —
# the live shared tasks.db is NEVER touched. Run:
#   bash tests/gate_floor_word_boundary_unit.sh    (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the obvious hardening also swallows the
# helper's own stderr line, which IS the payload (see gate_tier2_floor_unit.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-floor-boundary-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }

# --- T1: CONTAINMENT INSIDE AN UNRELATED STEM NO LONGER FLOORS. Every one of
#     these matched before the fix, all of them via a NON-APPEALABLE term. ------
for t in \
  'suppression' \
  'expression' \
  'compressed' \
  'impressive' \
  'depression' \
  'recharge' \
  'supercharge'
do
  if _gate_tier2_floor_hit "$t"; then
    bad_t "T1 '$t' does not floor" "still hits, term='$(_gate_tier2_floor_term "$t")'"
  else
    ok_t "T1 '$t' does not floor (was a false 'press'/'charge' hit)"
  fi
done

# The real DIVE-2273 sentence, in an ASK where no title exemption applies.
_ask_2273="stop forging a last_skipped_at suppression that never happened"
_gate_tier2_floor_hit "$_ask_2273" \
  && bad_t "T1 the DIVE-2273 ask does not floor" "hit '$(_gate_tier2_floor_term "$_ask_2273")'" \
  || ok_t "T1 the DIVE-2273 ask does not floor (the reported case, in an ask)"

# --- T2: TRUE POSITIVES SURVIVE, INFLECTIONS INCLUDED. The boundary is LEADING
#     only; anchoring the tail as well would break every one of these. ---------
for t in \
  'press' \
  'pressing' \
  'we need a press release' \
  'charge' \
  'charges' \
  'revoke' \
  'revoked' \
  'truncated' \
  'blasted the list' \
  'move the dns record' \
  'start a domain transfer'
do
  if _gate_tier2_floor_hit "$t"; then
    ok_t "T2 '$t' still floors (term '$(_gate_tier2_floor_term "$t")')"
  else
    bad_t "T2 '$t' still floors" "no longer hits — the boundary was applied to the TAIL too"
  fi
done

# --- T3: THE MONEY CLASS STILL FLOORS. \b cannot sit before '$' or '€', so the
#     ticket's own prescription (per-term \b) silently drops these. This arm is
#     the difference between the two implementations. -------------------------
for t in 'approve $500 for ads' 'wire €900 to the vendor'; do
  if _gate_tier2_floor_hit "$t"; then
    ok_t "T3 '$t' still floors (non-word term, term '$(_gate_tier2_floor_term "$t")')"
  else
    bad_t "T3 '$t' still floors" "FAIL-OPEN on money: a per-term \\b cannot anchor \$/€"
  fi
done

# --- T4: THE REPORTED TERM IS THE TERM, not the term plus its boundary char.
#     The wrapper widens BASH_REMATCH[0] to " press"; the filer reads this string
#     in the warn line and in the refusal, so it must stay clean. --------------
_term=$(_gate_tier2_floor_term "press")
[[ "$_term" == "press" ]] \
  && ok_t "T4 start-of-string branch reports 'press'" \
  || bad_t "T4 start-of-string term reported" "got '${_term}'"
_term=$(_gate_tier2_floor_term "we need a press release")
[[ "$_term" == "press" ]] \
  && ok_t "T4 reported term is 'press', not ' press' (boundary char not leaked)" \
  || bad_t "T4 reported term clean" "got '${_term}'"
_term=$(_gate_tier2_floor_term "approve \$500 for ads")
[[ "$_term" == '$5' ]] \
  && ok_t "T4 reported term for a money hit is '\$5'" \
  || bad_t "T4 money term reported" "got '${_term}'"

# --- T5: THE NON-APPEALABLE HALF, which is where there is no escape path. The
#     appeal works by SUBTRACTION: strip the appealable terms, re-test the FULL
#     floor. Before the fix a residual containing 'suppression' re-fired on
#     'press' and REFUSED the appeal, naming a word the ask never contained. ---
_res=$(_gate_floor_appeal_residual "publish the suppression note")
_gate_tier2_floor_hit "$_res" \
  && bad_t "T5 appeal on 'publish the suppression note' is not refused" \
           "residual '$_res' still hits '$(_gate_tier2_floor_term "$_res")'" \
  || ok_t "T5 appeal survives: residual of an appealable ask naming 'suppression' does not re-fire"
_res=$(_gate_floor_appeal_residual "publish the press release")
_gate_tier2_floor_hit "$_res" \
  && ok_t "T5 appeal still REFUSED when a real non-appealable term is present ('press release')" \
  || bad_t "T5 real non-appealable term still refuses the appeal" "residual '$_res' no longer hits"

# --- T6: the invariant the subtraction depends on — no APPEALABLE term may be a
#     substring of a NON-APPEALABLE one, or stripping the former erases the
#     latter and hands an appeal to a class that has none. Literal terms only
#     (the regex terms \$[0-9], €[0-9], drop[^.]{0,20}table are not substrings
#     of anything). Guards a FUTURE edit to either list, not today's values. --
_viol=""
IFS='|' read -r -a _app <<< "$_GATE_FLOOR_APPEALABLE_RX"
IFS='|' read -r -a _non <<< "$_GATE_FLOOR_NONAPPEALABLE_RX"
for a in "${_app[@]}"; do
  [[ "$a" =~ ^[a-z\ ]+$ ]] || continue
  for n in "${_non[@]}"; do
    [[ "$n" =~ ^[a-z\ ]+$ ]] || continue
    [[ "$n" == *"$a"* ]] && _viol="${_viol} '${a}' inside '${n}';"
  done
done
[[ -z "$_viol" ]] \
  && ok_t "T6 no appealable term is a substring of a non-appealable one (appeal cannot erase a hard class)" \
  || bad_t "T6 appealable/non-appealable substring invariant" "violations:${_viol}"

# --- T7: THE BOUNDARY REACHES A CONSTITUTION-LOADED POLICY. This is why the fix
#     is at the MATCH SITE and not written into _GATE_T2_FLOOR_RX: on a host with
#     a sealed constitution.yaml the shipped default is replaced wholesale, and
#     anchoring the default alone would leave the defect live in exactly the path
#     where the policy is authoritative. An org's own unanchored terms are
#     anchored by the wrapper too. -------------------------------------------
printf 'hard_gates: {}\n' > "$TMP/constitution.yaml"
_council_constitution_path() { printf '%s' "$TMP/constitution.yaml"; }
_council_hard_gate_rx()      { printf 'press|charge|\\$[0-9]'; }
_gate_tier2_floor_hit 'suppression' \
  && bad_t "T7 constitution-loaded terms are boundary-anchored too" \
           "custom rx still matched inside 'suppression'" \
  || ok_t "T7 a constitution-loaded 'press' does NOT match inside 'suppression'"
_gate_tier2_floor_hit 'we need a press release' \
  && ok_t "T7 a constitution-loaded 'press' still matches the real word" \
  || bad_t "T7 constitution-loaded true positive" "custom rx stopped matching 'press release'"
_gate_tier2_floor_hit 'approve $500 for ads' \
  && ok_t "T7 a constitution-loaded money term still floors" \
  || bad_t "T7 constitution-loaded money term" "custom \$[0-9] stopped matching"
unset -f _council_constitution_path _council_hard_gate_rx

# --- T8: END TO END through cmd_task_need — the tier the filer actually gets.
#     T1..T7 grade the helpers; this grades the decision. --------------------
db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('DIVE-901','t','todo','main');"
cmd_task_need DIVE-901 --type=decision --ask="stop forging a suppression that never happened" \
  --options="A|B" --recommend="A" >/dev/null 2>&1
_tier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-901';")
[[ "$_tier" != "2" ]] \
  && ok_t "T8 e2e: a decision gate whose ASK says 'suppression' is NOT floored to tier 2 (tier $_tier)" \
  || bad_t "T8 e2e suppression not floored" "got tier 2 — the floor still reads 'press'"

db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('DIVE-902','t','todo','main');"
cmd_task_need DIVE-902 --type=decision --ask="approve the press release copy" \
  --options="A|B" --recommend="A" >/dev/null 2>&1
_tier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-902';")
[[ "$_tier" == "2" ]] \
  && ok_t "T8 e2e: a decision gate whose ASK says 'press release' IS still floored to tier 2" \
  || bad_t "T8 e2e press release still floored" "got tier '$_tier'"

db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('DIVE-903','t','todo','main');"
cmd_task_need DIVE-903 --type=decision --ask="approve \$500 for ads" \
  --options="A|B" --recommend="A" >/dev/null 2>&1
_tier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-903';")
[[ "$_tier" == "2" ]] \
  && ok_t "T8 e2e: a money ask is STILL floored to tier 2 (the fail-open a per-term \\b would open)" \
  || bad_t "T8 e2e money still floored" "got tier '$_tier' — money stopped flooring"

echo "-----"
printf 'gate_floor_word_boundary_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
