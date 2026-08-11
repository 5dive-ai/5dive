#!/usr/bin/env bash
# DIVE-3228 — a tier-2 `access` gate's ROUTED lead may clear it; everything else
# still reaches the human.
#
# THE DEFECT. `access` defaults to tier 2 and DIVE-1243 made it lead-clearable BY
# TYPE: routable regardless of tier, bypassing the gate_builder_routing pref, and
# listed beside approval/manual in cmd_task_answer's designated-reviewer exception.
# So filing one tells the filer it routed, and `routed_reviewer` really is set —
# and then the tier-2 floor (`gtier == 2 && ! human`) refuses the routed lead's
# answer, because the DIVE-1437 escalation immediately below it is scoped
# `[[ $nt == approval || $nt == manual ]]` and `access` is not in that list. It does
# not even get the escalation's tap button; it takes the original hard refusal.
# Measured on DIVE-3212 (ops -> main, 2026-08-11): "DIVE-3212 is a tier-2 human gate
# (access) — only a human can clear it; tap the button in Telegram", on a gate that
# was already moot, for a push to our own repo.
#
# WHAT MADE IT SURVIVE: the comment eight lines above that condition asserts the
# opposite ("`access` is DELIBERATELY lead-clearable by DIVE-1243"). Every reader who
# checked the INTENT found it documented and correct. Only the condition disagreed.
#
# THE ARMED CONTROL IS THE POINT OF THIS FILE (E0). Every allow-arm below would also
# pass against a build where the floor never fired at all, so before asserting them
# the harness neuters `_gate_access_lead_clearable` and asserts the SAME answer is
# REFUSED. That is the pre-fix behaviour, reproduced in-suite. Without it "9 arms
# green" is what an unwired instrument prints — this row's own lesson, from the six
# harnesses whose zero audit rows meant nothing until a positive control captured 49.
#
# Run: bash tests/gate_access_lead_clear_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-access-lead-clear.XXXXXX)"
SUMMARY_PRINTED=0
exec 8>&2
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_access_lead_clear_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# This suite does NOT declare its fixture DB as prod (no FIVEDIVE_PROD_TASKS_DB), so
# `_task_store_audit_log` is fenced off and writes nothing to the real fleet log. The
# spy below replaces it anyway — belt-and-braces, and it is how the new row's ARGUMENTS
# get graded rather than merely its absence. `audit_log` (the unfenced one) is stubbed
# outright: it is the call that leaks fixture rows into /var/log/5dive/agent-audit.log.
audit_log() { :; }
SPY="$TMP/spy.log"; : >"$SPY"
_task_store_audit_log() { printf '%s\n' "$*" >>"$SPY"; return 0; }
spy_reset() { : >"$SPY"; }
spy_last()  { grep 'access-lead-clear' "$SPY" 2>/dev/null | tail -n1; }
HUMAN_PINGED=0
_task_need_notify_deliver() { HUMAN_PINGED=1; }
5dive() { return 0; }

# Org chart: main is the lone root/coordinator; ops reports to main (DIVE-3212's shape).
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('ops','main','builder');"

seed() { db "INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('$1',$(sqlq "${2:-a task}"),'todo','ops','ops');"; }
col()  { db "SELECT COALESCE($2,'') FROM tasks WHERE ident='$1';"; }

# --- SELFTEST: the impersonation seam actually moves the actor -------------------
# A seam that silently stops working turns every arm below it green-and-meaningless.
actor_seam_selftest ops && ok_t "SELFTEST the actor seam moves the caller (ops)" \
                        || bad_t "SELFTEST actor seam" "task_actor did not resolve to ops"

# ================================================================================
# P — THE PREDICATE, DIRECTLY. Table-driven so the DENY arms are as legible as the
# one ALLOW arm; the deny set is the whole safety argument.
# ================================================================================
p_case() { # <want:allow|deny> <nt> <tier> <floor_prov> <needs> <label>
  local want="$1"; shift
  local nt="$1" tier="$2" fp="$3" nd="$4" label="$5"
  if _gate_access_lead_clearable "$nt" "$tier" "$fp" "$nd"; then
    [[ "$want" == allow ]] && ok_t "P $label" || bad_t "P $label" "ALLOWED, wanted deny"
  else
    [[ "$want" == deny ]] && ok_t "P $label" || bad_t "P $label" "DENIED, wanted allow"
  fi
}
p_case allow access 2 'axis=type-default' ''              "tier-2 access at the TYPE DEFAULT is lead-clearable"
p_case deny  access 2 'axis=pinned'       ''              "an explicit --tier=2 is a hard-human contract (DIVE-1957)"
p_case deny  access 2 'axis=ask;term=delete' ''           "the T2 category floor fired on the ask"
p_case deny  access 2 'axis=title-fallback;term=spend' '' "a title-fallback floor is still a floor"
p_case deny  access 2 ''                  ''              "an EMPTY provenance is UNKNOWN, not type-default (pre-DIVE-2615 row)"
p_case deny  access 2 'axis=type-default' 'human_tap'     "a declared human capability outranks the provenance"
p_case deny  access 2 'axis=type-default' 'spend_authority' "…and so does spend_authority"
p_case allow access 2 'axis=type-default' 'delegated_push' "an UNRECOGNISED capability changes nothing (as at filing time)"
p_case deny  approval 2 'axis=type-default' ''            "approval is NOT widened by this (scope control)"
p_case deny  manual   2 'axis=type-default' ''            "manual is NOT widened by this (scope control)"
p_case deny  secret   2 'axis=type-default' ''            "secret is NOT widened by this (scope control)"
p_case deny  access 1 'axis=type-default' ''              "tier 1 never reaches the floor, so it is not this predicate's case"

# ================================================================================
# E — END TO END ON A SCRATCH ROW. File as ops, answer as main.
# ================================================================================
answer_as() { # <agent> <ident>  -> prints rc
  local who="$1" ident="$2"
  ( actor_seam_as "$who"; cmd_task_answer "$ident" --value='approved' --from="$who" ) >/dev/null 2>&1
  printf '%s' "$?"
}

# ---- E1 FILE TIME is already correct: it routes, and says so --------------------
seed DIVE-92281 'ship the harness bump'
( actor_seam_as ops; cmd_task_need DIVE-92281 --type=access \
    --ask='push branch dive-3212-openclaw-harness-30s and open the PR' --from=ops ) >/dev/null 2>&1
[[ "$(col DIVE-92281 routed_reviewer)" == "main" ]] \
  && ok_t "E1 an access gate ROUTES to the chart lead at file time" \
  || bad_t "E1 access routes" "routed_reviewer='$(col DIVE-92281 routed_reviewer)'"
[[ "$(col DIVE-92281 tier)" == "2" ]] \
  && ok_t "E1 …at tier 2 (the type default)" \
  || bad_t "E1 tier" "tier='$(col DIVE-92281 tier)'"
[[ "$(col DIVE-92281 floor_provenance)" == "axis=type-default" ]] \
  && ok_t "E1 …with floor_provenance=axis=type-default (nobody CHOSE tier 2)" \
  || bad_t "E1 provenance" "floor_provenance='$(col DIVE-92281 floor_provenance)'"

# ---- E0 THE ARMED CONTROL: the pre-fix build refuses that same answer -----------
# Neuter ONLY the new predicate and re-run E2's exact call. If this passes green the
# arms below are measuring the fix rather than the absence of a floor.
_GATE_ACC_REAL="$(declare -f _gate_access_lead_clearable)"
_gate_access_lead_clearable() { return 1; }
[[ "$(answer_as main DIVE-92281)" != "0" ]] \
  && ok_t "E0 CONTROL with the predicate neutered, main's answer is REFUSED (the pre-fix behaviour, reproduced)" \
  || bad_t "E0 CONTROL" "the answer succeeded with the fix disabled — every E-arm below is vacuous"
eval "$_GATE_ACC_REAL"
[[ -z "$(col DIVE-92281 need_answered_at)" ]] \
  && ok_t "E0 …and the control left the gate UNANSWERED, so E2 grades a real clear" \
  || bad_t "E0 control side-effect" "need_answered_at='$(col DIVE-92281 need_answered_at)'"

# ---- E2 the routed lead clears it ----------------------------------------------
spy_reset; HUMAN_PINGED=0
[[ "$(answer_as main DIVE-92281)" == "0" ]] \
  && ok_t "E2 the ROUTED LEAD clears the tier-2 access gate" \
  || bad_t "E2 lead clears access" "rc=$(answer_as main DIVE-92281)"
[[ -n "$(col DIVE-92281 need_answered_at)" ]] \
  && ok_t "E2 …the gate is recorded ANSWERED" \
  || bad_t "E2 answered_at" "empty"
[[ "$(col DIVE-92281 routed_reviewer)" == "main" ]] \
  && ok_t "E2 …and it was CLEARED, not escalated (routed_reviewer survives)" \
  || bad_t "E2 not escalated" "routed_reviewer='$(col DIVE-92281 routed_reviewer)' — the DIVE-1437 escalation NULLs it"
[[ "$HUMAN_PINGED" == "0" ]] \
  && ok_t "E2 …the paired human was never pinged" \
  || bad_t "E2 human ping" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(spy_last)" == *"allowed"* && "$(spy_last)" == *"floor_provenance=axis=type-default"* ]] \
  && ok_t "E2 …and the decision is COUNTABLE (audit row names the provenance it allowed on)" \
  || bad_t "E2 audit row" "spy_last='$(spy_last)'"

# ---- E3 a NON-routed agent is still refused -------------------------------------
seed DIVE-92282 'another push'
( actor_seam_as ops; cmd_task_need DIVE-92282 --type=access --ask='push branch dive-b' --from=ops ) >/dev/null 2>&1
[[ "$(answer_as ops DIVE-92282)" != "0" ]] \
  && ok_t "E3 an agent that is NOT the routed reviewer is refused (no self-grant)" \
  || bad_t "E3 non-reviewer refused" "ops cleared a gate routed to main"

# ---- E4 RE-DERIVATION: a routed row whose provenance says otherwise is refused ---
# This is why the exemption reads the ROW and not `_lead_clear` alone. Rewriting the
# column models a row written by an older build, or by any future path that sets
# routed_reviewer — the necessary-but-not-sufficient trap this same ticket already hit.
db "UPDATE tasks SET floor_provenance='axis=pinned' WHERE ident='DIVE-92282';"
[[ "$(answer_as main DIVE-92282)" != "0" ]] \
  && ok_t "E4 a routed access row stamped axis=pinned is REFUSED (re-derived, not inherited)" \
  || bad_t "E4 pinned refused" "main cleared a pinned tier-2 gate"
db "UPDATE tasks SET floor_provenance='axis=ask;term=delete' WHERE ident='DIVE-92282';"
[[ "$(answer_as main DIVE-92282)" != "0" ]] \
  && ok_t "E4 …and one stamped with a category-floor hit is REFUSED" \
  || bad_t "E4 floored refused" "main cleared a category-floored gate"
db "UPDATE tasks SET floor_provenance=NULL WHERE ident='DIVE-92282';"
[[ "$(answer_as main DIVE-92282)" != "0" ]] \
  && ok_t "E4 …and a legacy NULL provenance is REFUSED (unknown fails closed)" \
  || bad_t "E4 legacy refused" "main cleared a row whose tier reason is unknown"
db "UPDATE tasks SET floor_provenance='axis=type-default', needs_capability='human_tap' WHERE ident='DIVE-92282';"
[[ "$(answer_as main DIVE-92282)" != "0" ]] \
  && ok_t "E4 …and a declared --needs=human_tap is REFUSED even at the type default" \
  || bad_t "E4 needs refused" "main cleared a human_tap gate"
[[ "$(spy_last)" == *"denied"* ]] \
  && ok_t "E4 …the DENYING branch is countable too, not just the allowing one" \
  || bad_t "E4 deny audit row" "spy_last='$(spy_last)'"

# ---- E5 SCOPE CONTROL: a tier-2 APPROVAL is unchanged ---------------------------
# It must still take the DIVE-1437 escalation — routed_reviewer NULLed, human pinged.
# If this arm ever flips, the change stopped being about `access`.
seed DIVE-92283 'approve the spend'
db "UPDATE tasks SET need_type='approval', tier=2, routed_reviewer='main',
       floor_provenance='axis=type-default', ask='approve it', status='blocked' WHERE ident='DIVE-92283';"
answer_as main DIVE-92283 >/dev/null
# Two facts, and the SECOND is the one that matters: the lead's answer did not CLEAR
# it. `routed_reviewer` being NULLed is the DIVE-1437 escalation taking the lead out
# of the loop; `need_answered_at` still empty is the gate still waiting on a person.
# (The human DM itself is not asserted here — task_need_notify's delivery rail needs
# a configured owner/channel this suite deliberately does not model, so an arm on it
# would grade the fixture's plumbing rather than this change.)
[[ -z "$(col DIVE-92283 routed_reviewer)" ]] \
  && ok_t "E5 SCOPE a tier-2 APPROVAL still takes the DIVE-1437 escalation (lead removed)" \
  || bad_t "E5 approval escalates" "routed_reviewer='$(col DIVE-92283 routed_reviewer)' — the lead was NOT taken out"
[[ -z "$(col DIVE-92283 need_answered_at)" ]] \
  && ok_t "E5 …and the lead's answer did NOT clear it — it still awaits a human" \
  || bad_t "E5 approval not cleared" "need_answered_at='$(col DIVE-92283 need_answered_at)' — the fix leaked into approval"

# ================================================================================
# I — THE SECOND READER. `task inbox` is "what is waiting on a HUMAN", and its
# `tier >= 2` escape captured a routed access gate a lead can now clear — showing
# lodar a question already addressed to somebody else. Changing the clearer without
# changing this reader is how the row ships half-fixed, which its body asks for by
# name (ENUMERATE THE READERS).
# ================================================================================
inbox_json() { ( JSON_MODE=1; cmd_task_inbox ) 2>/dev/null; }
in_inbox()   { inbox_json | jq -e --arg i "$1" '.data.inbox[]?|select(.ident==$i)' >/dev/null 2>&1; }
routed_n()   { inbox_json | jq -r '.data.routed_elsewhere // 0'; }
open_n()     { db "SELECT COUNT(*) FROM tasks WHERE need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled');"; }

mk_gate() { # <ident> <need_type> <tier> <routed> <floor_prov> <needs>
  seed "$1" "inbox fixture"
  db "UPDATE tasks SET need_type='$2', tier=$3, status='blocked', ask='an ask',
        routed_reviewer=$(sqlq "$4"), floor_provenance=$(sqlq "$5"), needs_capability=$(sqlq "$6")
      WHERE ident='$1';"
}
mk_gate DIVE-92284 access   2 main 'axis=type-default'    ''
mk_gate DIVE-92285 access   2 main 'axis=ask;term=delete' ''
mk_gate DIVE-92286 access   2 ''   'axis=type-default'    ''
mk_gate DIVE-92287 access   2 main 'axis=type-default'    'human_tap'
mk_gate DIVE-92288 approval 2 main 'axis=type-default'    ''

in_inbox DIVE-92284 && bad_t "I1 lead-clearable access must NOT sit in the human inbox" "still listed" \
                    || ok_t "I1 a ROUTED type-default access gate is no longer the human's"
in_inbox DIVE-92285 && ok_t "I2 a CATEGORY-FLOORED access gate is still the human's" \
                    || bad_t "I2 floored access hidden" "a floored gate vanished from the human inbox"
in_inbox DIVE-92286 && ok_t "I3 an UNROUTED access gate is still the human's" \
                    || bad_t "I3 unrouted access hidden" "no agent can clear it and nobody is shown it"
in_inbox DIVE-92287 && ok_t "I4 a declared human_tap access gate is still the human's" \
                    || bad_t "I4 human_tap access hidden" "a declared capability was overridden"
in_inbox DIVE-92288 && ok_t "I5 a tier-2 APPROVAL is still the human's (scope control)" \
                    || bad_t "I5 approval hidden" "the access clause leaked into approval"

# I6 THE COMPLEMENT. `routed_elsewhere` is the count of what the filter WITHHELD, and
# it used to be a hand-written negation of the same predicate — two copies that both
# run and neither errors when they drift. Assert they still partition the open set.
_i_shown=$(inbox_json | jq -r '.data.inbox|length'); _i_routed=$(routed_n); _i_open=$(open_n)
[[ $(( _i_shown + _i_routed )) == "$_i_open" ]] \
  && ok_t "I6 shown + routed_elsewhere == every open gate (the inverse is a true complement)" \
  || bad_t "I6 complement" "shown=$_i_shown routed=$_i_routed open=$_i_open — the withheld count drifted from the view"
(( _i_routed > 0 )) \
  && ok_t "I6 …and the withheld count is NON-ZERO, so the arm above is not vacuous" \
  || bad_t "I6 vacuity" "routed_elsewhere=0 — I6 would pass against a filter that withholds nothing"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]] || exit 1
exit 0
