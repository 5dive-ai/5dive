#!/usr/bin/env bash
# DIVE-3224 — `task inbox --json` is the SINGLE source for "which gates are a
# human's", and it must carry `tier` so no consumer has to rebuild that split.
#
# THE DEFECT THIS GRADES. The telegram plugin's /inbox did not read this view at
# all. It shelled `task ls --json` and kept every row with a `need_type` — "has an
# unanswered gate", not "needs a HUMAN" — because this view withheld `tier`, which
# its ✅ apply-the-recommendation button needs (the plugin's own comment said so).
# Measured 2026-08-11: lodar's /inbox listed 12 gates of which 3 were his; the
# other 9 were routed to agent seats (dev, dev2, dev3, cli, main2, quinn) and each
# still carried a tap-to-apply button on a question addressed to somebody else.
# The fix is one field here plus a DELETION there — so these arms grade both the
# field the plugin now reads AND the filtering it now delegates instead of copying.
#
# THE ARMED CONTROLS ARE THE POINT (T2, R0). A bare "is `tier` in the output?"
# check passes against a build that emits `tier: null` on every row, which is
# exactly the value the consumer's unknown-tier branch treats as 2 — i.e. the whole
# fleet's gates back on the founder's plate, green tests. So T2 asserts the VALUES
# differ per row. And R0 re-runs the routing arm against a hand-neutered predicate
# to show these arms measure a filter that is actually firing.
#
# Run: bash tests/task_inbox_json_tier_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-inbox-json-tier.XXXXXX)"
SUMMARY_PRINTED=0
exec 8>&2
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - task_inbox_json_tier_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

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

# Rows are inserted straight into the table rather than filed through
# `cmd_task_need`: this file grades the SELECT and its WHERE, and filing would
# make the fixture depend on the routing/tier-floor logic that other suites own
# (gate_access_lead_clear_unit, gate_tier2_decision_nonce_unit). Every column the
# predicate reads is therefore set explicitly and visibly.
seed() { # <ident> <tier|NULL> <routed_reviewer> <needs_capability> [need_type] [status]
  local ident="$1" tier="$2" rr="$3" cap="$4" nt="${5:-decision}" st="${6:-blocked}"
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,need_type,ask,recommend,tier,routed_reviewer,needs_capability,need_asked_at)
      VALUES('$ident',$(sqlq "row $ident"),'$st','dev','dev','$nt',$(sqlq "ask for $ident"),'A',$tier,'$rr','$cap',datetime('now'));"
}

inbox_json() { cmd_task_inbox 2>/dev/null; }
idents()     { inbox_json | jq -r '.data.inbox[].ident' 2>/dev/null | sort | tr '\n' ' '; }
field()      { inbox_json | jq -r --arg i "$1" '.data.inbox[] | select(.ident==$i) | .'"$2"'' 2>/dev/null; }
listed()     { [[ " $(idents) " == *" $1 "* ]]; }

# H1 the founder's own gate: nothing routed, so it is his by default.
seed DIVE-90001 0  ''      ''
# H2 a hard gate: routed, but tier 2 escapes back to the human.
seed DIVE-90002 2  'main'  ''
# H3 a declared human capability, routed and tier 1 — still his.
seed DIVE-90003 1  'main'  'human_tap'
# A1 the nine: routed to an agent seat, soft tier, no capability. NOT his.
seed DIVE-90004 1  'main2' ''
seed DIVE-90005 0  'quinn' ''
# X1 answered, X2 closed — the two exclusions the plugin now delegates instead of
# re-deriving, so they are graded here or nowhere.
seed DIVE-90006 0  ''      ''
db "UPDATE tasks SET need_answered_at=datetime('now'), need_answer='approve' WHERE ident='DIVE-90006';"
seed DIVE-90007 0  ''      '' decision done
# U1 an UNKNOWN tier (pre-DIVE-2615 row): stays visible, and must surface as such.
seed DIVE-90008 NULL ''    ''

# ================================================================================
# T — the field itself
# ================================================================================
out="$(inbox_json)"
if printf '%s' "$out" | jq -e '.ok == true and (.data.inbox|type=="array")' >/dev/null 2>&1; then
  ok_t "T0 inbox --json is well-formed {ok, data:{inbox:[…]}}"
else
  bad_t "T0 inbox --json shape" "got: $(printf '%s' "$out" | head -c 200)"
fi

if printf '%s' "$out" | jq -e '[.data.inbox[] | select(.ident!="DIVE-90008") | has("tier")] | all' >/dev/null 2>&1; then
  ok_t "T1 every row with a tier carries a \`tier\` key (the field the plugin's ✅ button reads)"
else
  bad_t "T1 tier present" "at least one row has no tier key: $(printf '%s' "$out" | jq -c '[.data.inbox[]|keys]' 2>/dev/null | head -c 300)"
fi

# T2 THE ARMED CONTROL for T1: a build emitting a constant null would pass T1 and
# then hand the consumer's unknown-tier fail-safe every gate in the fleet.
t1="$(field DIVE-90002 tier)"; t2="$(field DIVE-90001 tier)"
if [[ "$t1" == "2" && "$t2" == "0" ]]; then
  ok_t "T2 CONTROL tier carries the ROW's value, not a constant (2 and 0 read back distinctly)"
else
  bad_t "T2 CONTROL tier values" "DIVE-90002 tier='$t1' (want 2), DIVE-90001 tier='$t2' (want 0)"
fi

# T3 A NULL tier is not exported as `tier: null` — `dbfmt -json` OMITS the key
# entirely, and jq answers `null` for an absent path exactly as it does for a null
# value, so the two are indistinguishable downstream. Both arms are asserted here
# because a consumer that reads `t.tier ?? ''` sees the same thing either way, and
# must map BOTH to 2 (visible / not plugin-clearable). If a future dbfmt starts
# emitting explicit nulls this arm keeps passing, which is correct: the contract
# being fixed is what the CONSUMER can distinguish, and that does not change.
if printf '%s' "$out" | jq -e '[.data.inbox[] | select(.ident=="DIVE-90008") | has("tier")] | any | not' >/dev/null 2>&1 \
   && [[ "$(field DIVE-90008 tier)" == "null" ]]; then
  ok_t "T3 an UNKNOWN tier ships as an ABSENT key, read back as null — the consumer must treat it as 2 (visible), the fail-safe direction"
else
  bad_t "T3 unknown tier" "key present or value not null: $(printf '%s' "$out" | jq -c '.data.inbox[]|select(.ident=="DIVE-90008")' 2>/dev/null | head -c 200)"
fi

if [[ -n "$(field DIVE-90001 recommend)" && "$(field DIVE-90001 recommend)" != "null" ]]; then
  ok_t "T4 \`recommend\` still ships beside it (the button label; regression guard on the SELECT)"
else
  bad_t "T4 recommend" "recommend='$(field DIVE-90001 recommend)'"
fi

# ================================================================================
# R — the routing split the plugin now DELEGATES rather than copies
# ================================================================================
listed DIVE-90001 && ok_t "R1 an unrouted gate is the human's"        || bad_t "R1 unrouted listed" "idents: $(idents)"
listed DIVE-90002 && ok_t "R2 a tier-2 gate escapes back to the human" || bad_t "R2 tier2 listed" "idents: $(idents)"
listed DIVE-90003 && ok_t "R3 a declared human capability is the human's" || bad_t "R3 capability listed" "idents: $(idents)"
listed DIVE-90004 && bad_t "R4 routed soft gate hidden" "DIVE-90004 (routed main2, tier 1) is on the founder's plate — the defect" \
                  || ok_t "R4 a soft gate routed to an agent seat is NOT shown"
listed DIVE-90005 && bad_t "R5 routed soft gate hidden" "DIVE-90005 (routed quinn, tier 0) is on the founder's plate — the defect" \
                  || ok_t "R5 …and neither is the second one"
listed DIVE-90006 && bad_t "R6 answered excluded" "an ANSWERED gate is still listed" \
                  || ok_t "R6 an ANSWERED gate is excluded (the plugin no longer filters this itself)"
listed DIVE-90007 && bad_t "R7 closed excluded" "a DONE task's open gate is still listed" \
                  || ok_t "R7 a CLOSED task's lingering gate is excluded (likewise)"

n="$(printf '%s' "$out" | jq -r '.data.routed_elsewhere' 2>/dev/null)"
[[ "$n" == "2" ]] \
  && ok_t "R8 routed_elsewhere counts the withheld 2 — a quiet inbox stays distinguishable from an empty fleet" \
  || bad_t "R8 routed_elsewhere" "got '$n', want 2"

# R0 THE ARMED CONTROL: reproduce the pre-fix reading — no routing clause at all —
# and show DIVE-90004/5 come back. If this arm cannot make them reappear, R4/R5 are
# passing against a filter that never ran and prove nothing about the founder's plate.
pre="$(db "SELECT ident FROM tasks WHERE need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled') ORDER BY ident;" | tr '\n' ' ')"
if [[ "$pre" == *"DIVE-90004"* && "$pre" == *"DIVE-90005"* ]]; then
  ok_t "R0 CONTROL the pre-fix predicate (need_type alone) DOES return the routed gates — R4/R5 grade a live filter"
else
  bad_t "R0 CONTROL" "the need_type-only read returned '$pre' — it should contain both routed idents"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == 0 ]]
