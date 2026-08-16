#!/usr/bin/env bash
# DIVE-3481: an INERT push-for-review approval gate clears AT FILING — provenance
# `auto:pfr`, a signed closure, a permanent record, and nobody pinged. Grades the
# grant AND, at greater length, every way it must REFUSE to fire, because the whole
# risk of this change is a gate skipping a human it should not have skipped.
#
# Harness mirrors gate_verifier_route_unit.sh: source src/ libs, throwaway STATE_DIR,
# no root, no network. Run: bash tests/gate_pfr_autoclear_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NOTE the absence of `2>/dev/null` —
# the obvious hardening swallows the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-pfr-autoclear-unit.XXXXXX)"
# DIVE-2190/2610: `fail()` exits the whole script, so a refusal inside any cmd_* call
# ends the run with an `ok` as the last line and NO summary — a red that reads as a
# pass that stopped early. fd 8 is a dup of the REAL stderr, taken before any arm runs,
# because a refusal that exits from inside `cmd_x >/dev/null 2>&1` would otherwise print
# the marker into /dev/null.
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_pfr_autoclear_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_push.sh carries _push_branch_from_body, which the auto-clear reads the row's
# binding through. Sourced for the REAL function rather than a local re-implementation:
# the whole point of DIVE-3266's row-state rule is that the gate and `5dive push` derive
# the branch with the same parser, and a harness that reimplemented it would stop
# grading that.
# shellcheck source=/dev/null
source "$SRC/cmd_push.sh"

. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
FIXTURE_ACTOR=fixture-runner
fixture_actor() { FIXTURE_ACTOR="$1"; actor_seam_as "$1"; }

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

HUMAN_PINGED=0
_task_need_notify_deliver() { HUMAN_PINGED=1; }
audit_log() { :; }
_task_store_audit_log() { printf '%s\n' "$*" >>"$TMP/store.log"; return 0; }
: >"$TMP/store.log"
ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { : >"$ROUTE_FILE"; : >"$TMP/store.log"; HUMAN_PINGED=0; }
route_sent()  { local i n; for i in $(seq 1 10); do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; n=$(grep -c . "$ROUTE_FILE" 2>/dev/null); echo "${n:-0}"; }

# ---- the root signing rail, stubbed at the SUDO CALL SITE ------------------------
# The production path is `_gate_closure_payload | sudo -n 5dive gate-proof sign`; the
# HMAC key is 0400 root:root and this suite is not root, so the rail is stubbed here
# exactly where the code reaches for it. The signature it returns is a REAL
# _gate_proof_hmac over the REAL payload against a fixture key, so `_gate_closure_verify`
# — the check the root push executor actually runs — is graded rather than simulated.
# SIGN_OK=0 makes the rail come back empty, which is the cli-scoped-seat case.
export GATE_PROOF_KEY="$TMP/gate-proof.key"
( umask 077; openssl rand -hex 32 > "$GATE_PROOF_KEY" )
SIGN_OK=1
sudo() {
  if [[ "${1:-}" == "-n" && "${2:-}" == "5dive" && "${3:-}" == "gate-proof" && "${4:-}" == "sign" ]]; then
    (( SIGN_OK )) || return 1
    local payload; payload=$(cat)
    _gate_proof_hmac "$payload"
    return 0
  fi
  return 1
}

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev2','main','builder');"

# seed <ident> <branch-line-or-empty>
seed() {
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,body)
      VALUES('$1','ship the a2a wake change','todo','main','dev2',$(sqlq "${2-}"));"
}
PFR_ASK='approve the delegated push of branch dive-3474-a2a-wake to origin for PR review'
# DIVE-3474 changed what "delivered" MEANS for a routed gate. Before it, delivery
# was an `agent send` at filing time; after it, a routed non-urgent gate is QUEUED
# and the reviewer meets it on its next natural wake. The two arms below assert
# "the gate still reaches someone", and that intent is unchanged — so the predicate
# gains the queue as a third way of being reached, rather than being relaxed. It is
# the REAL queue predicate (`_task_agent_gate_pred`, the one `5dive task queue` and
# the heartbeat nudge both call), not a re-typed WHERE clause, so an arm that queued
# the row somewhere nobody looks still fails here.
queued_for() { # <ident> <agent> -> 1 if `5dive task queue --for=<agent>` would list it
  local n; n=$(db "SELECT COUNT(*) FROM tasks WHERE ident='$1' AND $(_task_agent_gate_pred "$2");" 2>/dev/null)
  [[ "${n:-0}" != "0" ]] && echo 1 || echo 0
}
gby()    { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
gans()   { db "SELECT COALESCE(need_answer,'')      FROM tasks WHERE ident='$1';"; }
gsig()   { db "SELECT COALESCE(need_answer_sig,'')  FROM tasks WHERE ident='$1';"; }
gstat()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
gtier()  { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
gtype()  { db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='$1';"; }
guid()   { db "SELECT COALESCE(CAST(need_answered_uid AS TEXT),'') FROM tasks WHERE ident='$1';"; }
gat()    { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$1';"; }

# ============================ 1. THE GRANT ======================================
route_reset; seed DIVE-901 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-901 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-901)" == "auto:pfr" ]] \
  && ok_t "inert push-for-review approval auto-clears with provenance auto:pfr" \
  || bad_t "inert push-for-review approval auto-clears with provenance auto:pfr" "got=$(gby DIVE-901)"
[[ "$(gans DIVE-901)" == "approve" ]] \
  && ok_t "the filer's recommendation is what was applied" \
  || bad_t "the filer's recommendation is what was applied" "got=$(gans DIVE-901)"
[[ "$(route_sent)" == "0" && "$HUMAN_PINGED" == "0" ]] \
  && ok_t "NOBODY was pinged — no a2a send to the lead and no human notify" \
  || bad_t "NOBODY was pinged" "route_sent=$(route_sent) human=$HUMAN_PINGED"
[[ "$(gstat DIVE-901)" == "todo" ]] \
  && ok_t "the row is unblocked back to todo, so the maker can push immediately" \
  || bad_t "the row is unblocked back to todo" "got=$(gstat DIVE-901)"
[[ "$(gtype DIVE-901)" == "approval" && "$(gtier DIVE-901)" == "1" ]] \
  && ok_t "the permanent gate RECORD survives — type=approval, tier=1, not erased" \
  || bad_t "the permanent gate record survives" "type=$(gtype DIVE-901) tier=$(gtier DIVE-901)"
[[ "$(guid DIVE-901)" == "0" ]] \
  && ok_t "uid 0 — no human is CLAIMED to have answered (same as the TTL sweep)" \
  || bad_t "uid 0 claimed no human" "got=$(guid DIVE-901)"
grep -q 'pfr-auto' "$TMP/store.log" \
  && ok_t "the auto-clear is audited on the task-store rail (countable afterwards)" \
  || bad_t "the auto-clear is audited" "store.log=$(cat "$TMP/store.log")"

# The signature is the load-bearing artifact: grade it with the SAME verifier the root
# push executor runs, not by checking the column is non-empty.
_gate_closure_verify "$(db "SELECT id FROM tasks WHERE ident='DIVE-901';")" approval "$(gans DIVE-901)" \
    "$(gby DIVE-901)" "$(gat DIVE-901)" "$(guid DIVE-901)" "$(gsig DIVE-901)" \
  && ok_t "the stored closure VERIFIES against the root HMAC (_gate_closure_verify)" \
  || bad_t "the stored closure verifies" "sig=$(gsig DIVE-901)"

# ============================ 2. THE BROKER SIDE ================================
# The clear is only worth anything if `5dive push` accepts it, and only on the surface
# it was minted for.
pfr_id=$(db "SELECT id FROM tasks WHERE ident='DIVE-901';")
( broker_gate_check push "$pfr_id" DIVE-901 >/dev/null 2>&1 ) \
  && ok_t "broker_gate_check ACCEPTS auto:pfr on the push surface" \
  || bad_t "broker_gate_check accepts auto:pfr" "rc=$?"
( broker_gate_check push "$pfr_id" DIVE-901 1 >/dev/null 2>&1 ) \
  && ok_t "…and still accepts it under require_sig=1, the ROOT executor's own arm" \
  || bad_t "accepts under require_sig=1" "rc=$?"

# NEGATIVE: the provenance is type-bound. Same row, same signature, need_type flipped —
# a provenance minted for one authority must not be spendable on another.
db "UPDATE tasks SET need_type='manual' WHERE id=${pfr_id};"
( broker_gate_check push "$pfr_id" DIVE-901 >/dev/null 2>&1 ) \
  && bad_t "auto:pfr REFUSED on a non-approval gate" "accepted need_type=manual" \
  || ok_t "auto:pfr REFUSED on a non-approval gate (type-bound, not provenance alone)"
db "UPDATE tasks SET need_type='approval' WHERE id=${pfr_id};"

# NEGATIVE: a raw-DB forge. `auto:pfr` written by hand over a DIFFERENT answer keeps the
# old signature, and the root executor's closure check is what catches it — the string is
# not the boundary (DIVE-1555's argument, re-asserted for this provenance).
db "UPDATE tasks SET need_answer='approve, and also merge it' WHERE id=${pfr_id};"
( broker_gate_check push "$pfr_id" DIVE-901 1 >/dev/null 2>&1 ) \
  && bad_t "a forged auto:pfr closure is REFUSED under require_sig=1" "accepted a tampered answer" \
  || ok_t "a forged auto:pfr closure is REFUSED under require_sig=1 (signature, not string)"

# ============================ 3. IT MUST NOT FIRE ===============================
# Each arm below is a human this change must NOT skip.

# 3a. NOT INERT — the ask also names a merge. Fails closed via the shared predicate.
route_reset; seed DIVE-902 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-902 --type=approval --recommend='approve' \
  --ask='push branch dive-3474-a2a-wake for review and then merge it to main' --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-902)" != "auto:pfr" ]] \
  && ok_t "an ask that also names a merge-to-main does NOT auto-clear" \
  || bad_t "merge-naming ask does not auto-clear" "got=$(gby DIVE-902)"

# 3b. NO BRANCH BINDING on the row. Row state, not prose — and `5dive push` would refuse
# such a row anyway, so a gate on it is not the measured shape.
route_reset; seed DIVE-903 'no binding here'; fixture_actor dev2
( cmd_task_need DIVE-903 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-903)" != "auto:pfr" ]] \
  && ok_t "a row with NO 'Branch:' binding does NOT auto-clear" \
  || bad_t "unbound row does not auto-clear" "got=$(gby DIVE-903)"

# 3c. PROTECTED REF. The binding exists and names main.
route_reset; seed DIVE-904 'Branch: main'; fixture_actor dev2
( cmd_task_need DIVE-904 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-904)" != "auto:pfr" ]] \
  && ok_t "a 'Branch: main' binding does NOT auto-clear (protected ref)" \
  || bad_t "protected ref does not auto-clear" "got=$(gby DIVE-904)"
# …and case does not launder it.
route_reset; seed DIVE-905 'Branch: Production'; fixture_actor dev2
( cmd_task_need DIVE-905 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-905)" != "auto:pfr" ]] \
  && ok_t "'Branch: Production' does NOT auto-clear — the ref test is case-insensitive" \
  || bad_t "cased protected ref does not auto-clear" "got=$(gby DIVE-905)"

# 3d. NO RECOMMENDATION — there is nothing to apply.
route_reset; seed DIVE-906 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-906 --type=approval --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-906)" != "auto:pfr" ]] \
  && ok_t "no --recommend does NOT auto-clear" \
  || bad_t "no recommend does not auto-clear" "got=$(gby DIVE-906)"

# 3e. THE T2 CATEGORY FLOOR STILL WINS (DIVE-1555/1698). A push ask that also names a
# secret is floored to tier 2 above this path and must reach a person.
route_reset; seed DIVE-907 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-907 --type=approval --recommend='approve' \
  --ask='push the branch for review; it rotates the stripe api key in the deploy env' --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-907)" != "auto:pfr" ]] \
  && ok_t "the true-human floor still wins — a secret-naming push ask does NOT auto-clear" \
  || bad_t "T2 floor wins" "got=$(gby DIVE-907) tier=$(gtier DIVE-907)"

# 3f. A DECLARED CAPABILITY outranks the classification (DIVE-2241).
route_reset; seed DIVE-908 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-908 --type=approval --recommend='approve' --needs=human_tap \
  --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-908)" != "auto:pfr" ]] \
  && ok_t "a declared --needs=human_tap does NOT auto-clear" \
  || bad_t "declared capability does not auto-clear" "got=$(gby DIVE-908)"

# 3g. AN EXPLICIT --tier=2 is the filer's hard-human contract.
route_reset; seed DIVE-909 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-909 --type=approval --tier=2 --recommend='approve' \
  --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-909)" != "auto:pfr" ]] \
  && ok_t "an explicit --tier=2 does NOT auto-clear" \
  || bad_t "explicit tier 2 does not auto-clear" "got=$(gby DIVE-909)"

# 3h. WRONG TYPE. A `decision` gate with the same ask stays on its old path — a decision
# auto-clear could not authorize a push anyway, so widening to it would be surface for
# no gain.
route_reset; seed DIVE-910 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-910 --type=decision --options='approve|hold' --recommend='approve' \
  --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-910)" != "auto:pfr" ]] \
  && ok_t "a --type=decision push ask does NOT auto-clear (approval only)" \
  || bad_t "decision type does not auto-clear" "got=$(gby DIVE-910)"

# 3i. --mode=confirm-after-send would be a ratification with nobody in it.
route_reset; seed DIVE-911 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-911 --type=approval --mode=confirm-after-send --recommend='approve' \
  --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-911)" != "auto:pfr" ]] \
  && ok_t "--mode=confirm-after-send does NOT auto-clear" \
  || bad_t "confirm-after-send does not auto-clear" "got=$(gby DIVE-911)"

# ============================ 4. UNSIGNABLE SEAT =================================
# THE ARM THIS CHANGE IS MOST AT RISK FROM. A seat that cannot mint a closure must fall
# back to the lead ping, NOT self-clear unsigned — an unsigned clear is a push refused
# later on someone else's round-trip with the lead already skipped, i.e. strictly worse
# than today. Assert BOTH halves: not cleared, AND still routed.
route_reset; SIGN_OK=0; seed DIVE-912 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-912 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
SIGN_OK=1
[[ -z "$(gby DIVE-912)" ]] \
  && ok_t "a seat that cannot SIGN does not clear the gate at all" \
  || bad_t "unsignable seat does not clear" "got=$(gby DIVE-912)"
[[ "$(gstat DIVE-912)" == "blocked" ]] \
  && ok_t "…the row stays BLOCKED, so nothing reads as authorised" \
  || bad_t "unsignable row stays blocked" "got=$(gstat DIVE-912)"
[[ "$(route_sent)" != "0" || "$HUMAN_PINGED" == "1" || "$(queued_for DIVE-912 main)" == "1" ]] \
  && ok_t "…and the gate is still DELIVERED to someone — sent, human-pinged, or QUEUED (DIVE-3474)" \
  || bad_t "unsignable gate still routes" "route_sent=$(route_sent) human=$HUMAN_PINGED queued=$(queued_for DIVE-912 main)"

# ============================ 5. THE KILL SWITCH =================================
_task_pref_set pfr_autoclear off
route_reset; seed DIVE-913 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-913 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ -z "$(gby DIVE-913)" ]] \
  && ok_t "pref pfr_autoclear=off restores the gate (no auto-clear)" \
  || bad_t "pref off restores the gate" "got=$(gby DIVE-913)"
[[ "$(route_sent)" != "0" || "$HUMAN_PINGED" == "1" || "$(queued_for DIVE-913 main)" == "1" ]] \
  && ok_t "…and with the pref off the gate is still delivered — now via the queue (DIVE-3474)" \
  || bad_t "pref off still delivers" "route_sent=$(route_sent) human=$HUMAN_PINGED queued=$(queued_for DIVE-913 main)"
_task_pref_set pfr_autoclear on
route_reset; seed DIVE-914 'Branch: dive-3474-a2a-wake'; fixture_actor dev2
( cmd_task_need DIVE-914 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-914)" == "auto:pfr" ]] \
  && ok_t "pref back ON auto-clears again (the switch moves it both ways)" \
  || bad_t "pref back on auto-clears" "got=$(gby DIVE-914)"

# ============================ 6. THE PROTECTED-REF PREDICATE ====================
# Graded directly as well as through the gate: this predicate decides whether a human
# is skipped, so its own boundary is worth an assertion.
for b in main master HEAD trunk prod production release staging develop dev \
         release/1.2 prod/eu hotfix/urgent; do
  _gate_pfr_protected_ref "$b" || bad_t "protected ref '$b'" "classified as pushable"
done
ok_t "every protected ref name is classified protected (13 forms, incl. release/ prod/ hotfix/ prefixes)"
for b in dive-3474-a2a-wake feature/main-menu mainline devtools release-notes-fix; do
  _gate_pfr_protected_ref "$b" && bad_t "pushable ref '$b'" "classified as protected"
done
ok_t "a feature branch that merely CONTAINS a protected word (mainline, devtools, feature/main-menu) stays pushable"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
