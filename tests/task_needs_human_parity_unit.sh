#!/usr/bin/env bash
# DIVE-3267 — `task ls --json`'s `needs_human` is the SAME verdict `task inbox --json`
# renders, evaluated ONCE.
#
# WHY THIS EXISTS. DIVE-3224 fixed the telegram plugin's /inbox, which filtered on
# `need_type` alone — "has an unanswered gate", not "needs a HUMAN" — and showed the
# founder 12 gates of which 3 were his. The same wrong predicate was still live one
# command over in /task's "Needs you" section, in all SIX plugin forks (main, grading
# the merge, 2026-08-11). Both copies existed for one reason: the real predicate was
# reachable only by re-deriving it, so every consumer that needed the answer wrote its
# own. `needs_human` exports the VERDICT so no consumer has to.
#
# THE ARM THAT MATTERS IS P1, AND IT IS WORTHLESS WITHOUT P0. Parity between two views
# is trivially true when the fixture has no row they could disagree about — a board of
# unrouted gates makes "needs a human" and "has a gate" the same set. So the fixture
# seeds rows on BOTH sides of every clause, and P0 replays the pre-fix reading and
# asserts it returns a STRICTLY LARGER set. If P0 cannot make them disagree, P1 is
# measuring a fixture, not a predicate.
#
# S1 IS THE OTHER HALF, AND IT GRADES THE FIX'S OWN FAILURE MODE. The way to "fix" two
# copies of a rule and ship three is to paste the SQL into the ls query. S1 asserts at
# source level that the disjunction appears exactly once in cmd_task.sh, so a future
# copy-paste reds here rather than at the next founder complaint.
#
# Run: bash tests/task_needs_human_parity_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-needs-human.XXXXXX)"
SUMMARY_PRINTED=0
exec 8>&2
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - task_needs_human_parity_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

audit_log() { :; }
_task_store_audit_log() { :; }
5dive() { return 0; }

tasks_db_init

# Rows go straight into the table: this file grades two SELECTs against each other,
# and filing through `cmd_task_need` would make the fixture depend on the routing and
# tier-floor logic other suites own. Every column either predicate reads is explicit.
seed() { # <ident> <tier|NULL> <routed_reviewer> <needs_capability> [need_type] [floor_prov] [status]
  local ident="$1" tier="$2" rr="$3" cap="$4" nt="${5:-decision}" fp="${6:-}" st="${7:-blocked}"
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,need_type,ask,recommend,tier,routed_reviewer,needs_capability,floor_provenance,need_asked_at)
      VALUES('$ident',$(sqlq "row $ident"),'$st','dev','dev','$nt',$(sqlq "ask $ident"),'A',$tier,'$rr','$cap','$fp',datetime('now'));"
}

# --- the fixture straddles every clause, in both directions ---------------------
seed DIVE-91001 0    ''      ''                      # unrouted           -> HIS
seed DIVE-91002 2    'main'  ''                      # routed but tier 2  -> HIS
seed DIVE-91003 1    'main'  'human_tap'             # human capability   -> HIS
seed DIVE-91004 NULL ''      ''                      # unknown tier       -> HIS (reads as 2)
seed DIVE-91005 1    'main2' ''                      # routed, soft       -> NOT his
seed DIVE-91006 0    'quinn' ''                      # routed, soft       -> NOT his
# DIVE-3228's clause, both sides of it: a routed `access` gate at the TYPE DEFAULT is
# the lead's; the same gate with a PINNED floor is still the human's.
seed DIVE-91007 2    'main'  ''      access 'axis=type-default'   # -> NOT his
seed DIVE-91008 2    'main'  ''      access 'axis=pinned'         # -> HIS
# excluded by the OPEN predicate, not the human one
seed DIVE-91009 0    ''      ''                      # answered below
db "UPDATE tasks SET need_answered_at=datetime('now'), need_answer='approve' WHERE ident='DIVE-91009';"
seed DIVE-91010 0    ''      ''      decision ''      done   # closed row, stale gate
# no gate at all — the row `needs_human` must call 0 rather than omit
db "INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('DIVE-91011','no gate here','todo','dev','dev');"

inbox_idents() { cmd_task_inbox 2>/dev/null | jq -r '.data.inbox[].ident' | sort | tr '\n' ' '; }
ls_json()      { ( cmd_task_ls --all 2>/dev/null ); }
nh_idents()    { ls_json | jq -r '.data.tasks[] | select(.needs_human==1) | .ident' | sort | tr '\n' ' '; }

INBOX="$(inbox_idents)"; NH="$(nh_idents)"

# ================================================================================
# P — the two views agree, and the fixture can tell
# ================================================================================
[[ -n "$INBOX" ]] \
  && ok_t "P_pre the fixture produces a non-empty inbox ($(echo "$INBOX" | wc -w) rows)" \
  || bad_t "P_pre" "inbox is EMPTY — every parity arm below would be vacuously true"

[[ "$NH" == "$INBOX" ]] \
  && ok_t "P1 needs_human==1 is EXACTLY the inbox set" \
  || bad_t "P1 parity" "ls needs_human: [$NH]   inbox: [$INBOX]"

# P0 THE ARMED CONTROL: the pre-fix reading — "has an unanswered gate" — over the same
# fixture. It must return MORE rows, or P1 is agreement between two things that could
# not have differed.
PRE="$(ls_json | jq -r '.data.tasks[] | select(.gate_live==1) | .ident' | sort | tr '\n' ' ')"
extra=0; for i in $PRE; do [[ " $NH " == *" $i "* ]] || extra=$((extra+1)); done
if (( extra > 0 )); then
  ok_t "P0 CONTROL the pre-fix reading (gate_live alone) returns $extra row(s) MORE — the fixture CAN distinguish them"
else
  bad_t "P0 CONTROL" "gate_live and needs_human returned the same set [$PRE] — P1 proves nothing about this predicate"
fi

# The specific rows the founder should never have been shown, named so a regression
# reports WHICH clause moved rather than a set difference.
for i in DIVE-91005 DIVE-91006 DIVE-91007; do
  [[ " $NH " == *" $i "* ]] \
    && bad_t "P2 $i withheld" "$i is routed to an agent seat and needs_human says 1" \
    || ok_t "P2 $i is routed to an agent seat — needs_human=0"
done
for i in DIVE-91001 DIVE-91002 DIVE-91003 DIVE-91004 DIVE-91008; do
  [[ " $NH " == *" $i "* ]] \
    && ok_t "P3 $i is the human's — needs_human=1" \
    || bad_t "P3 $i shown" "$i should be on the human's plate and needs_human says 0"
done

# ================================================================================
# F — the field's own shape, which is what the consumer's fallback keys on
# ================================================================================
out="$(ls_json)"
if printf '%s' "$out" | jq -e '[.data.tasks[] | has("needs_human")] | all' >/dev/null 2>&1; then
  ok_t "F1 needs_human is present on EVERY row, including the 0s"
else
  bad_t "F1 needs_human present" "some row omits the key: $(printf '%s' "$out" | jq -c '[.data.tasks[]|{ident,needs_human}]' | head -c 300)"
fi
# F1 is load-bearing for the PLUGIN, not for this CLI: a consumer on an older CLI sees
# the key absent everywhere and must fall back to the old filter (showing too much is
# recoverable; hiding a gate is the defect). That fallback can only be safe if a
# present-and-0 never looks like absent — which is exactly what F1 and F2 pin.
[[ "$(printf '%s' "$out" | jq -r '.data.tasks[] | select(.ident=="DIVE-91011") | .needs_human')" == "0" ]] \
  && ok_t "F2 a row with NO gate reads needs_human=0, not absent" \
  || bad_t "F2 ungated row" "got '$(printf '%s' "$out" | jq -r '.data.tasks[]|select(.ident=="DIVE-91011")|.needs_human')'"
[[ "$(printf '%s' "$out" | jq -r '.data.tasks[] | select(.ident=="DIVE-91009") | .needs_human')" == "0" ]] \
  && ok_t "F3 an ANSWERED gate reads 0 (the open predicate, not the human one)" \
  || bad_t "F3 answered row" "needs_human should be 0"
[[ "$(printf '%s' "$out" | jq -r '.data.tasks[] | select(.ident=="DIVE-91010") | .needs_human')" == "0" ]] \
  && ok_t "F4 a CLOSED row's stale gate reads 0" \
  || bad_t "F4 closed row" "needs_human should be 0"

# ================================================================================
# S — one copy of the rule, asserted on the SOURCE
# ================================================================================
# The failure mode this guards is specific: paste human_pred into the ls query rather
# than calling the helper, and every behavioural arm above stays green while the tree
# carries two copies that can drift apart on the next clause. main graded DIVE-3224's
# merge by diffing the predicate byte-for-byte; this is that check, kept.
n_disj=$(cat "$SRC/cmd_task.sh" "$SRC"/task/*.sh | grep -c "^  printf '%s' \"( COALESCE(routed_reviewer,'') = ''")
[[ "$n_disj" == "1" ]] \
  && ok_t "S1 the human-gate disjunction is written EXACTLY once in cmd_task.sh" \
  || bad_t "S1 single copy" "found $n_disj definitions — a second copy is the defect this row closes"
# Exactly two CALL SITES — `cmd_task_inbox` (the view) and the `task ls --json`
# projection — plus one definition. Written as an equality, not a floor: a third
# caller appearing is not automatically wrong, but it is a new consumer of this
# verdict and it should arrive with a reader looking at this line, not silently.
n_call=$(cat "$SRC/cmd_task.sh" "$SRC"/task/*.sh | grep -c '\$(_task_human_gate_pred)')
n_def=$(cat "$SRC/cmd_task.sh" "$SRC"/task/*.sh | grep -c '^_task_human_gate_pred() {')
[[ "$n_call" == "2" && "$n_def" == "1" ]] \
  && ok_t "S2 one definition, exactly two call sites (the inbox view and the ls projection)" \
  || bad_t "S2 call sites" "definitions=$n_def calls=$n_call — expected 1 and 2"
grep -q "CASE WHEN \${_gate_open} AND ( \${_gate_human} ) THEN 1 ELSE 0 END AS needs_human" "$SRC/cmd_task.sh" "$SRC"/task/*.sh \
  && ok_t "S3 the ls projection INTERPOLATES the helpers rather than restating them" \
  || bad_t "S3 interpolation" "the needs_human projection does not read from the helper variables"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == 0 ]]
