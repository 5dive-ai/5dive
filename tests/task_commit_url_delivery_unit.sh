#!/usr/bin/env bash
# DIVE-5758 — a row delivered with a COMMIT URL must be able to leave the merging stage.
#
# MEASURED 2026-10-07 on a customer box: on a repo whose agents push
# straight to main, `task deliver --pr=<…/commit/<sha>>` is the only binding there
# is. The verifier PASSed; `merge-landed` asked `gh pr view` about a commit, got no
# mergedAt and refused; `merge-declined` recorded a false "no landing" and handed
# the row back to its maker, whose re-delivery PASSed again — four times over.
# `unbind-pr` refused the commit URL as "not a GitHub pull URL".
#
# WHAT THIS FILE GRADES, in the order the row's DONE states it:
#   A  a commit URL whose sha IS on the default branch: PASS -> merge-landed
#      closes the stage in one step, credential-free, with the sha recorded
#   B  a commit URL NOT on the default branch is refused WITH A REASON (and an
#      unreadable forge is refused too); nothing is written either way
#   C  unbind-pr drops a commit-URL binding bound beside the primary, and a
#      commit PRIMARY is refused naming merge-landed — not "not a pull URL"
#   P  the probe's own arms (identical/behind/ahead/diverged/base mismatch)
#   M  mutants: the probe's commit arm and the key's commit arm, each reverted,
#      make A and C red.
#
# THE FORGE IS A SEAM: `_gate_gh` is stubbed and answers by the REST path asked.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
export FIVE_GATE_NO_ANON=1
TMP="$(mktemp -d /tmp/task-commit-url.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh \
         cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# The probe falls back to the seat's owner read token (DIVE-5632): isolate it, as
# tests/task_merge_landed_unit.sh does, and refuse to run on a seat that leaks one.
mkdir -p "$TMP/bin" "$TMP/home"; export PATH="$TMP/bin:$PATH" HOME="$TMP/home"
# shellcheck source=tests/lib/isolate_read_tokens.sh
. tests/lib/isolate_read_tokens.sh
isolate_read_tokens "$TMP/bin" || exit 1
[[ "$(read_tokens_stub_control)" == STUBBED && -z "$(read_tokens_isolated_probe)" \
   && -z "$(_gate_read_tokens_file)" ]] \
  || { printf 'read-token isolation FAILED (a real tokens file is reachable: %s) — refusing to run\n' \
         "$(_gate_read_tokens_file)" >&2; exit 1; }
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"
mkdir -p "$TASKS_DIR"; set +e
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init

OWNER=lead; GRADER=verifier; MAKER=dev
SLUG=acme/site
SHA=4f2a9c1e0b7d3a5f6e8c9d0a1b2c3d4e5f607182
OFF=9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a291807
COMMIT="https://github.com/${SLUG}/commit/${SHA}"
COMMIT_OFF="https://github.com/${SLUG}/commit/${OFF}"
PR=https://github.com/acme/site/pull/7
AT=2026-10-07T02:41:09Z

# --- the forge seam ----------------------------------------------------------
# repos/<slug>               -> the default branch
# repos/<slug>/compare/B...S -> status|merge_base|date, per the sha asked about
TOKF="$TMP/tok"; CALLS="$TMP/calls"; : >"$CALLS"
DOWN=0
declare -A CMP=( ["$SHA"]="behind|$SHA|$AT" ["$OFF"]="diverged|1111111111111111111111111111111111111111|2026-10-06T00:00:00Z" )
_gate_gh() { printf '[%s]' "$1" >"$TOKF"; shift 2
  (( DOWN )) && return 1
  [[ "$1" == api ]] || return 1
  printf '%s\n' "$2" >>"$CALLS"
  case "$2" in
    "repos/${SLUG}") printf 'main\n' ;;
    "repos/${SLUG}/compare/main..."*) local s="${2##*...}" k  # the forge resolves a short sha
      for k in "${!CMP[@]}"; do [[ "$k" == "$s"* ]] && { printf '%s\n' "${CMP[$k]}"; return 0; }; done
      return 1 ;;
    *) return 1 ;;
  esac; }
ACT="$OWNER"
task_actor_claim() { ACTOR_BOARD="$ACT"; }
task_actor() { printf '%s\n' "$ACT"; }

seed() { # <ident> <delivery_ref> [companions]
  db "DELETE FROM tasks WHERE ident='$1';"
  db "INSERT INTO tasks(ident,title,status,kind,created_by,assignee,maker_agent,verifier,
        graded_at,graded_verdict_at,graded_by,graded_verdict,handoff_delivered_at,
        delivery_ref,delivery_companions,merge_owner,merge_hold_reason,started_at)
      VALUES('$1','direct-to-main delivery','in_progress','standard','$OWNER',
        '$OWNER','$MAKER','$GRADER','2026-10-07 02:50:00',
        '2026-10-07 02:50:00','$GRADER','pass','2026-10-07 02:45:00','$2',$( [[ -n "${3:-}" ]] && printf "'%s'" "$3" || printf NULL ),
        '$OWNER','merger:no-graded-sha-stated','2026-10-07 02:45:00');"
  db "SELECT id FROM tasks WHERE ident='$1';"
}
tfv() { db "SELECT COUNT(*) FROM tasks WHERE ident='$1' AND ${_TASKS_TFV_SQL};"; }
col() { db "SELECT COALESCE($2,'-') FROM tasks WHERE ident='$1';"; }

# ===========================================================================
# F — the fixture is the measured shape (or every arm below is vacuous)
# ===========================================================================
seed DIVE-315 "$COMMIT" >/dev/null
[[ "$(tfv DIVE-315)" == "1" ]] \
  && ok_t "F1 a PASSed row bound to a commit URL IS in the merging stage by the board's own predicate" \
  || bad_t "F1 fixture" "not in TFV"
(
  _merge_landed_probe() { printf 'OPEN\x1fnull\n'; }   # what `gh pr view <commit url>` amounted to
  out=$(cmd_task_merge_landed DIVE-315 2>&1); rc=$?
  (( rc != 0 )) && [[ "$(db "SELECT COALESCE(merge_landed_at,'-') FROM tasks WHERE ident='DIVE-315';")" == "-" ]]
) && ok_t "F2 THE LOOP, LIVE: with a pull-request-only read, merge-landed refuses a commit that is on main" \
  || bad_t "F2 fixture reproduces the refusal" ""

# ===========================================================================
# A — a commit ON the default branch: merge-landed exits the stage in one step
# ===========================================================================
out=$(cmd_task_merge_landed DIVE-315 2>&1); rc=$?
(( rc == 0 )) && ok_t "A1 merge-landed on a row bound to a commit whose sha is on main exits 0" \
  || bad_t "A1 rc" "rc=$rc out=$out"
[[ "$(cat "$TOKF" 2>/dev/null)" == "[]" ]] \
  && ok_t "A1a ...asked with an EMPTY token: recording a landing still resolves no machine account" \
  || bad_t "A1a credential-free" "token seen: '$(cat "$TOKF" 2>/dev/null)'"
grep -qx "repos/${SLUG}/compare/main...${SHA}" "$CALLS" \
  && ok_t "A1b ...by comparing the repository's DEFAULT branch (read from the forge, not assumed) against the sha" \
  || bad_t "A1b compare asked" "$(cat "$CALLS")"
[[ "$(col DIVE-315 merge_landed_sha)" == "$SHA" && "$(col DIVE-315 merge_landed_ref)" == "$COMMIT" && "$(col DIVE-315 merge_landed_by)" == "$OWNER" ]] \
  && ok_t "A2 the landing is RECORDED: the sha, the commit URL it was recorded against, and the seat" \
  || bad_t "A2 record" "sha=$(col DIVE-315 merge_landed_sha) ref=$(col DIVE-315 merge_landed_ref) by=$(col DIVE-315 merge_landed_by)"
[[ "$(tfv DIVE-315)" == "0" && "$(col DIVE-315 merge_owner)" == "-" ]] \
  && ok_t "A3 THE DONE: the row has LEFT the merging stage and the hold is retired — one step, no re-delivery" \
  || bad_t "A3 stage exited" "tfv=$(tfv DIVE-315) owner=$(col DIVE-315 merge_owner)"
[[ "$(col DIVE-315 assignee)" == "$GRADER" && "$(col DIVE-315 merge_declined_at)" == "-" ]] \
  && ok_t "A4 ...handed to the verifier, whose close is ungated — and no false 'no landing' was written" \
  || bad_t "A4 handoff" "assignee=$(col DIVE-315 assignee) declined=$(col DIVE-315 merge_declined_at)"
CMP["$SHA"]="identical|$SHA|$AT"; seed DIVE-316 "$COMMIT" >/dev/null
out=$(cmd_task_merge_landed DIVE-316 2>&1); rc=$?
(( rc == 0 )) && [[ "$(tfv DIVE-316)" == "0" ]] \
  && ok_t "A5 a sha that IS the tip of main (compare: identical) lands too" || bad_t "A5 identical" "rc=$rc out=$out"
CMP["$SHA"]="behind|$SHA|$AT"

# ===========================================================================
# B — a commit NOT on the default branch is refused, with the reason
# ===========================================================================
seed DIVE-317 "$COMMIT_OFF" >/dev/null
out=$(cmd_task_merge_landed DIVE-317 2>&1); rc=$?
(( rc != 0 )) && [[ "$out" == *"NOT on the repository's default branch"* && "$out" == *"not on main (compare: diverged)"* ]] \
  && ok_t "B1 a commit NOT on main is REFUSED, and the refusal says why: not on main, compare: diverged" \
  || bad_t "B1 off-main refused with reason" "rc=$rc out=$out"
[[ "$(col DIVE-317 merge_landed_at)" == "-" && "$(tfv DIVE-317)" == "1" && "$(col DIVE-317 merge_owner)" == "$OWNER" ]] \
  && ok_t "B1a ...and NOTHING was written: no landing, still at MERGING, the hold still on the row" \
  || bad_t "B1a nothing written" ""
[[ "$out" == *"merge-declined"* ]] \
  && ok_t "B1b ...and it names the honest exit for a commit that will not land" || bad_t "B1b names merge-declined" "$out"
DOWN=1
out=$(cmd_task_merge_landed DIVE-317 2>&1); rc=$?
DOWN=0
(( rc != 0 )) && [[ "$out" == *"could NOT be read"* && "$(col DIVE-317 merge_landed_at)" == "-" ]] \
  && ok_t "B2 a forge that cannot be asked is a refusal too — told apart from 'not on main' — and writes nothing" \
  || bad_t "B2 unreadable refused" "rc=$rc out=$out"

# ===========================================================================
# C — unbind-pr and a commit-URL binding
# ===========================================================================
seed DIVE-318 "$PR" "$COMMIT_OFF" >/dev/null
[[ "$(_task_bound_pr_refs "$(db "SELECT id FROM tasks WHERE ident='DIVE-318';")")" == "$COMMIT_OFF" ]] \
  && ok_t "C0 a commit URL bound beside a pull request is in the row's bound set" || bad_t "C0 bound set" ""
out=$(cmd_task_unbind_pr DIVE-318 "$COMMIT_OFF" --reason="the hotfix commit was reverted; the PR carries the change" 2>&1); rc=$?
(( rc == 0 )) && [[ "$out" == *"NO LONGER BOUND"* && "$(col DIVE-318 delivery_companions)" == "-" ]] \
  && ok_t "C1 THE DONE: unbind-pr DROPS a commit-URL binding, with the reason recorded" \
  || bad_t "C1 unbind commit" "rc=$rc comp=$(col DIVE-318 delivery_companions) out=$out"
[[ -z "$(_task_bound_pr_refs "$(db "SELECT id FROM tasks WHERE ident='DIVE-318';")")" && "$(col DIVE-318 delivery_unbound)" == "$COMMIT_OFF"* ]] \
  && ok_t "C1a ...and it stays dropped: the bound set no longer holds it" || bad_t "C1a stays dropped" "$(col DIVE-318 delivery_unbound)"
seed DIVE-319 "$COMMIT" >/dev/null
out=$(cmd_task_unbind_pr DIVE-319 "$COMMIT" --reason="x" 2>&1); rc=$?
(( rc != 0 )) && [[ "$out" == *"PRIMARY"* && "$out" == *"merge-landed DIVE-319"* && "$out" != *"not a GitHub pull"* ]] \
  && ok_t "C2 a commit PRIMARY is refused as the primary, naming merge-landed — never 'not a GitHub pull URL'" \
  || bad_t "C2 primary commit" "rc=$rc out=$out"
out=$(cmd_task_unbind_pr DIVE-319 "https://example.com/x" --reason="x" 2>&1); rc=$?
(( rc != 0 )) && [[ "$out" == *"not a GitHub pull or commit URL"* ]] \
  && ok_t "C3 a URL that is neither is still refused" || bad_t "C3 garbage refused" "rc=$rc out=$out"

# ===========================================================================
# P — the key and the probe, arm by arm
# ===========================================================================
[[ "$(_task_pr_url_key "https://github.com/Acme/Site/commit/${SHA^^}")" == "acme/site@${SHA}" \
   && "$(_task_pr_url_key "$PR/files")" == "acme/site#7" && -z "$(_task_pr_url_key "https://github.com/acme/site/tree/main")" ]] \
  && ok_t "P1 the key: a commit is owner/repo@sha (lowercased), a pull request unchanged, anything else nothing" \
  || bad_t "P1 key" ""
probe() { _merge_landed_probe "$1" "" | tr '\037' '|'; }
[[ "$(probe "$COMMIT")" == "MERGED|$SHA|$AT" ]] && ok_t "P2 behind -> MERGED with the full sha and the commit's date" || bad_t "P2" "$(probe "$COMMIT")"
CMP["$SHA"]="ahead|1111111111111111111111111111111111111111|$AT"
[[ "$(probe "$COMMIT")" == "OPEN|not on main (compare: ahead)" ]] && ok_t "P3 ahead -> OPEN (a commit main does not contain)" || bad_t "P3" "$(probe "$COMMIT")"
CMP["$SHA"]="behind|2222222222222222222222222222222222222222|$AT"
[[ "$(probe "$COMMIT")" == "UNKNOWN|" ]] && ok_t "P4 'behind' whose merge base is NOT the sha is not an answer: UNKNOWN, which writes nothing" || bad_t "P4" "$(probe "$COMMIT")"
CMP["$SHA"]="behind|$SHA|$AT"
[[ "$(probe "https://github.com/${SLUG}/commit/${SHA:0:12}")" == "MERGED|$SHA|$AT" ]] \
  && ok_t "P5 a short sha in the URL lands as the full sha the forge reports" || bad_t "P5" "$(probe "https://github.com/${SLUG}/commit/${SHA:0:12}")"
[[ "$(_gate_owner_from_args api "repos/${SLUG}/compare/main...x" -q .x)" == "acme" && -z "$(_gate_owner_from_args pr view 7 -q 'repos/x/y')" ]] \
  && ok_t "P6 the owner-scoped read token is picked from a REST path's owner (private direct-to-main repos)" \
  || bad_t "P6 owner from REST path" ""

# ===========================================================================
# M — mutants
# ===========================================================================
MUT="$TMP/mut"; mkdir -p "$MUT"
cp src/task/delivery.sh "$MUT/delivery.sh"
sed -i 's@^  if _task_is_commit_url "\$ref"; then _merge_landed_commit_probe "\$ref"; return 0; fi$@  : # MUTANT@' "$MUT/delivery.sh"
m_hits=$(grep -c '^  : # MUTANT$' "$MUT/delivery.sh")
( set +e
  [[ "$m_hits" == "1" ]] || exit 2
  source "$MUT/delivery.sh" >/dev/null 2>&1
  # what the pull-request read would say about a commit: no mergedAt
  _gate_gh() { shift 2; [[ "$1" == pr ]] && printf 'null|null|null\n'; return 0; }
  seed DIVE-320 "$COMMIT" >/dev/null
  out=$(cmd_task_merge_landed DIVE-320 2>&1); rc=$?
  (( rc != 0 )) && [[ "$(tfv DIVE-320)" == "1" ]] && exit 0 || exit 1 ) \
  && ok_t "M1 MUTANT (the probe's commit arm removed, $m_hits hit): merge-landed refuses again and the row stays at MERGING — A1/A3 are red on it" \
  || bad_t "M1 mutant must bring the loop back" "hits=$m_hits"
cp src/task/gate_evidence.sh "$MUT/gate_evidence.sh"
python3 - "$MUT/gate_evidence.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old='  elif [[ "$u" =~ $cre ]]; then\n'
assert s.count(old)==1
open(p,'w').write(s.replace(old,'  elif false; then # MUTANT\n'))
PY
( set +e
  source "$MUT/gate_evidence.sh" >/dev/null 2>&1
  seed DIVE-321 "$PR" "$COMMIT_OFF" >/dev/null
  out=$(cmd_task_unbind_pr DIVE-321 "$COMMIT_OFF" --reason="x" 2>&1); rc=$?
  (( rc != 0 )) && [[ "$out" == *"not a GitHub pull or commit URL"* ]] && exit 0 || exit 1 ) \
  && ok_t "M2 MUTANT (the key's commit arm removed): unbind-pr refuses the commit URL again — C1 is red on it" \
  || bad_t "M2 mutant must bring the unbind refusal back" ""

printf -- '-----\n'
printf 'task_commit_url_delivery: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
