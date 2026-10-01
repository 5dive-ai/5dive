#!/usr/bin/env bash
# DIVE-4899 — a row may bind SEVERAL pull requests, and it closes only when
# every one has merged.
#
# THE INCIDENT. DIVE-4895 closed done bound to 5dive-api#227 while its companion
# lodar/5dive-frontend#295 — graded as part of the same row, named only in the
# result prose — sat OPEN for 80 minutes. A row bound ONE delivery_ref and every
# close, merge and landing check read that column alone.
#
# WHAT THIS GRADES, executed for real on a throwaway tasks.db over a stubbed
# `_gate_gh` keyed on the pull request each call asks about:
#   D*  `task deliver` binds every --pr (first = primary, rest = companions),
#       dedupes, and (DIVE-5348) a single-PR re-delivery KEEPS the companions.
#   U*  a result naming a pull URL that is not bound is REFUSED with the URL in
#       the message, and nothing is written; --no-pr is the audited exit.
#   H*  the same refusal on a maker's hand-off through `task done`.
#   P*  the forge poller: two bound PRs with one merged -> no landing, the row
#       stays in the merging stage; both merged -> the landing is recorded.
#   L*  `task merge-landed` refuses, naming the open companion.
#   G*  `task done`: one open companion -> refused naming it; both merged ->
#       closes; a result naming an unbound pull URL -> refused.
#   M*  MUTATION: the companion guard removed -> P1 goes red, so the negative
#       control is one something can break (DIVE-4623).
#   DIVE-5348 (the bound set is every PR the row claims, and only an unbind with
#   a reason drops one):
#   S*  shorthand (`fe#295`) for an unbound PR is refused at deliver.
#   F*  the two-PR fixture: API merged + FE open -> done refused naming FE,
#       FE merged -> closes; `task unbind-pr --reason=` -> closes, reason shown;
#       in the merging stage the poller holds, then lands after the unbind.
#   R*  a pull URL in the result, or in the body's "Delivered as", is bound.
#   N*  --no-pr records the reported-on URL as unbound, so it does not hold.
#   M2  MUTATION: bind only delivery_ref -> F1 goes red.
#
# Run: bash tests/task_multi_pr_delivery_unit.sh   (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/multi-pr-unit.XXXXXX)"

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
# `command -v gh` is asked before the gate reads anything; every real read goes
# through the `_gate_gh` function stub below, so this binary must never answer.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh" \
  || { printf 'NOT OK - tests/lib/actor_seam.sh not reachable\n'; exit 1; }

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

task_need_notify() { :; }
audit_log()        { :; }
cmd_send()            { :; }
_task_agent_channel() { return 1; }
_hb_log()             { :; }

API=https://github.com/lodar/5dive-api/pull/227
FE=https://github.com/lodar/5dive-frontend/pull/295
OTHER=https://github.com/5dive-ai/5dive/pull/1111
SHA=8a1b2c3d4e5f60718293a4b5c6d7e8f901234567
AT=2026-09-23T12:44:00Z

# --- the rail: one state per pull request ---------------------------------------
declare -A PRSTATE=()
_gate_gh_token()       { printf 'ghs_stub'; }
_gate_gh_reachable()   { return 0; }
_gate_gh_credentialed(){ return 0; }
_gate_gh() {                      # <tok> <timeout> gh-args...
  shift 2
  local ref="" q="" a prev=""
  for a in "$@"; do
    [[ "$prev" == "view" ]] && ref="$a"
    [[ "$prev" == "-q" ]] && q="$a"
    prev="$a"
  done
  [[ "$1 $2" == "pr view" ]] || return 1
  local st="${PRSTATE[$ref]:-}"
  [[ -n "$st" ]] || return 1
  case "$q" in
    .state)    printf '%s\n' "$st" ;;
    .mergedAt) [[ "$st" == MERGED ]] && printf '%s\n' "$AT" || printf 'null\n' ;;
    *join*)    if [[ "$st" == MERGED ]]; then printf 'MERGED|%s|%s\n' "$SHA" "$AT"; else printf '%s|null|null\n' "$st"; fi ;;
    *headRefOid*) printf '%s|%s\n' "$SHA" "$SHA" ;;
    *)         printf '{"state":"%s"}\n' "$st" ;;
  esac
}

EV="CHANGED: src/x.sh CHECKED: bash tests/x.sh 3/3 pass DELIVERED-SHA: $SHA CI: green CRITERIA: (1) -> the run above"
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident='$1';"; }
seed() {  # <ident> <assignee> <verifier>
  db "INSERT INTO tasks (ident, title, status, created_by, assignee, verifier)
      VALUES ('$1','two-repo change','in_progress','main','$2',$( [[ -n "$3" ]] && sqlq "$3" || printf 'NULL'));"
}
mk_merging() {  # <ident> — graded PASS, bound to API + FE, merge hold on ops
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status,
                         maker_agent, verifier, graded_by, graded_verdict, graded_at,
                         delivery_ref, delivery_companions, merge_owner, merge_hold_reason)
      VALUES ('$1', 'graded two-repo row', 'high', 'dev', 'main', 'standard', 'in_progress',
              'dev', 'quinn', 'quinn', 'pass', datetime('now','-2 hours'),
              $(sqlq "$API"), $(sqlq "$FE"), 'ops', 'merger:no-push-right');"
}

# ── D: deliver binds every --pr ─────────────────────────────────────────────────
actor_seam_as dev
seed DIVE-901 dev ""
out=$(cmd_task_deliver DIVE-901 --pr="$API" --pr="$FE" --pr="${FE}/files" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok_t "D1 deliver with two --pr succeeds" || bad_t "D1 deliver rc" "rc=$rc out=$out"
[[ "$(col DIVE-901 delivery_ref)" == "$API" ]] \
  && ok_t "D1a the FIRST --pr is the primary delivery_ref (every existing rail reads it unchanged)" \
  || bad_t "D1a primary" "got '$(col DIVE-901 delivery_ref)'"
[[ "$(col DIVE-901 delivery_companions)" == "$FE" ]] \
  && ok_t "D1b the second is bound as a companion, and '${FE}/files' — the same pull request — is bound once" \
  || bad_t "D1b companions" "got '$(col DIVE-901 delivery_companions)'"
out=$(cmd_task_deliver DIVE-901 --pr="$API" --pr="not-a-url" 2>&1); rc=$?
[[ $rc -ne 0 && "$(col DIVE-901 delivery_companions)" == "$FE" ]] \
  && ok_t "D1c a second --pr that is not a pull URL is refused and the binding is unchanged" \
  || bad_t "D1c bad companion" "rc=$rc comp='$(col DIVE-901 delivery_companions)'"
out=$(cmd_task_deliver DIVE-901 --pr="$API" 2>&1); rc=$?
[[ $rc -eq 0 && "$(col DIVE-901 delivery_companions)" == "$FE" && "$out" == *"$FE"*"STAYS BOUND"* && "$out" == *"unbind-pr"* ]] \
  && ok_t "D2 (DIVE-5348) a single-PR re-delivery KEEPS the earlier companion and says so, naming unbind-pr — DIVE-5322's iteration 4 dropped fe#382 this way" \
  || bad_t "D2 re-delivery must not drop a companion" "rc=$rc comp='$(col DIVE-901 delivery_companions)' out=$out"

# ── U: a result naming an unbound pull URL ─────────────────────────────────────
seed DIVE-902 dev ""
out=$(cmd_task_deliver DIVE-902 --pr="$API" --result="$EV — the frontend PR ($FE) adds the model line" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"$FE"* && "$out" == *"NOT BOUND"* ]] \
  && ok_t "U1 deliver whose result names an unbound pull URL is REFUSED, and the refusal names the URL" \
  || bad_t "U1 unbound url refusal" "rc=$rc out=$out"
[[ -z "$(col DIVE-902 delivery_ref)" ]] \
  && ok_t "U1a ...and NOTHING was written — the row is still unbound" \
  || bad_t "U1a refusal mutated the row" "dref='$(col DIVE-902 delivery_ref)'"
out=$(cmd_task_deliver DIVE-902 --pr="$API" --pr="$FE" --result="$EV — the frontend PR ($FE) adds the model line" 2>&1); rc=$?
[[ $rc -eq 0 && "$(col DIVE-902 delivery_companions)" == "$FE" ]] \
  && ok_t "U2 binding it (a second --pr) is the fix the refusal names, and it proceeds" \
  || bad_t "U2 bound url accepted" "rc=$rc out=$out"
seed DIVE-903 dev ""
out=$(cmd_task_deliver DIVE-903 --pr="$API" --no-pr --result="$EV — same shape as $OTHER" 2>&1); rc=$?
[[ $rc -eq 0 && "$(col DIVE-903 delivery_ref)" == "$API" ]] \
  && ok_t "U3 --no-pr (the result only REPORTS ON it) is the audited exit" \
  || bad_t "U3 --no-pr exit" "rc=$rc out=$out"

# H: the OTHER delivery verb — a maker's `task done --result=` on a verifier row
# hands off through the routing fork, which returns before the close gate.
seed DIVE-904 dev quinn
( actor_seam_as dev; cmd_task_deliver DIVE-904 --pr="$API" >/dev/null 2>&1 )
db "UPDATE tasks SET assignee='dev', status='in_progress' WHERE ident='DIVE-904';"
out=$( actor_seam_as dev; cmd_task_done DIVE-904 --result="$EV — frontend half is $FE" 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"$FE"* && "$out" == *"NOT BOUND"* && "$(col DIVE-904 assignee)" == "dev" ]] \
  && ok_t "H1 a maker's hand-off (task done on a verifier row) whose result names an unbound pull URL is refused and NOT routed" \
  || bad_t "H1 hand-off names unbound url" "rc=$rc assignee='$(col DIVE-904 assignee)' out=$out"

# ── P: the forge poller ─────────────────────────────────────────────────────────
db "DELETE FROM tasks;"
mk_merging DIVE-910
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
_HB_FORGE_MERGE_POLL=on
_hb_forge_merge_sweep
[[ -z "$(col DIVE-910 merge_landed_at)" ]] \
  && ok_t "P1 two bound PRs, ONE merged: no landing is recorded" \
  || bad_t "P1 landing recorded with a companion open" "landed_at='$(col DIVE-910 merge_landed_at)'"
[[ "$(db "SELECT CASE WHEN (${_TASKS_TFV_SQL}) THEN 1 ELSE 0 END FROM tasks WHERE ident='DIVE-910';")" == "1" \
   && "$(col DIVE-910 merge_owner)" == "ops" && "$(col DIVE-910 status)" != "done" ]] \
  && ok_t "P1a ...the row STAYS OPEN in the merging stage, merge hold intact, so the merge owner is still dispatched" \
  || bad_t "P1a row left the merging stage" "owner='$(col DIVE-910 merge_owner)' status='$(col DIVE-910 status)'"
PRSTATE=(["$API"]=MERGED ["$FE"]=MERGED)
_hb_forge_merge_sweep
[[ "$(col DIVE-910 merge_landed_sha)" == "$SHA" && -z "$(col DIVE-910 merge_owner)" ]] \
  && ok_t "P2 BOTH merged: the landing is recorded and the hold retired" \
  || bad_t "P2 landing not recorded" "sha='$(col DIVE-910 merge_landed_sha)' owner='$(col DIVE-910 merge_owner)'"

# ── L: merge-landed ────────────────────────────────────────────────────────────
mk_merging DIVE-911
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
out=$( actor_seam_as ops; cmd_task_merge_landed DIVE-911 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"$FE"* && -z "$(col DIVE-911 merge_landed_at)" ]] \
  && ok_t "L1 merge-landed REFUSES while a companion is open, naming it, and records nothing" \
  || bad_t "L1 merge-landed" "rc=$rc landed='$(col DIVE-911 merge_landed_at)' out=$out"

# ── G: task done ───────────────────────────────────────────────────────────────
# A non-loop row (no verifier) so the close reaches the merge gate directly.
seed DIVE-920 dev ""
( actor_seam_as dev; cmd_task_deliver DIVE-920 --pr="$API" --pr="$FE" >/dev/null 2>&1 )
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
out=$( actor_seam_as dev; cmd_task_done DIVE-920 --result="$EV" 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"$FE"* && "$(col DIVE-920 status)" != "done" ]] \
  && ok_t "G1 task done with the primary merged and a companion OPEN is refused, naming the companion; the row stays open" \
  || bad_t "G1 done over an open companion" "rc=$rc status='$(col DIVE-920 status)' out=$out"
[[ "$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy='done-with-unmerged-companion' AND ident='DIVE-920';")" -ge 1 ]] \
  && ok_t "G1a ...recorded under its own policy slug (done-with-unmerged-companion)" \
  || bad_t "G1a refusal slug" ""
PRSTATE=(["$API"]=MERGED ["$FE"]=MERGED)
out=$( actor_seam_as dev; cmd_task_done DIVE-920 --result="$EV" 2>&1 ); rc=$?
[[ "$(col DIVE-920 status)" == "done" ]] \
  && ok_t "G2 both merged: the row closes" \
  || bad_t "G2 close with both merged" "rc=$rc status='$(col DIVE-920 status)' out=$out"
seed DIVE-921 dev ""
( actor_seam_as dev; cmd_task_deliver DIVE-921 --pr="$API" >/dev/null 2>&1 )
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
out=$( actor_seam_as dev; cmd_task_done DIVE-921 --result="$EV — frontend half is $FE" 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"$FE"* && "$out" == *"NOT BOUND"* && "$(col DIVE-921 status)" != "done" ]] \
  && ok_t "G3 task done whose result names an unbound pull URL is refused, with the URL in the message" \
  || bad_t "G3 done names unbound url" "rc=$rc status='$(col DIVE-921 status)' out=$out"
out=$( actor_seam_as dev; cmd_task_done DIVE-921 --no-pr --result="$EV — frontend half is $FE" 2>&1 ); rc=$?
[[ "$(col DIVE-921 status)" == "done" ]] \
  && ok_t "G3a --no-pr is the audited exit for a close that only reports on it" \
  || bad_t "G3a --no-pr on done" "rc=$rc status='$(col DIVE-921 status)' out=$out"

# ── X: the merge primitive does not short-circuit on the primary alone ──────────
# `cmd_task_merge_do` is root-only behind a sudo hop, so its companion loop cannot
# be executed here; the decision it hands `_merge_do_already_landed` can.
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
( _MDO_COMPANIONS_OPEN=1; _merge_do_already_landed "$API" 2>/dev/null ); rc=$?
[[ $rc -eq 1 ]] \
  && ok_t "X1 primary merged + a companion open: the merge primitive still has a merge to perform (it does not return 'already merged')" \
  || bad_t "X1 companion-aware already-landed" "rc=$rc"
( _MDO_COMPANIONS_OPEN=0; _merge_do_already_landed "$API" 2>/dev/null ); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "X1a ...and with no companion open it reads the primary's landing exactly as before" \
  || bad_t "X1a single-PR already-landed unchanged" "rc=$rc"

# ── M: mutation — the guard removed, P1 must go red ───────────────────────────
mk_merging DIVE-930
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
( _task_companions_unlanded() { :; }; _hb_forge_merge_sweep )
[[ -n "$(col DIVE-930 merge_landed_at)" ]] \
  && ok_t "M1 MUTATION: with the companion check stubbed out the poller records the half-landing — P1 is a control that can fail" \
  || bad_t "M1 mutation did not bite" "P1 would pass with the guard removed, so it grades nothing"

# ═══ DIVE-5348 ═════════════════════════════════════════════════════════════════
db "DELETE FROM tasks;"
actor_seam_as dev

# ── S: shorthand ───────────────────────────────────────────────────────────────
seed DIVE-950 dev ""
out=$(cmd_task_deliver DIVE-950 --pr="$API" --result="$EV — delivered as api#227 + fe#295, merge the API first" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"fe#295"* && "$out" != *"api#227, "* && -z "$(col DIVE-950 delivery_ref)" ]] \
  && ok_t "S1 deliver whose result says 'fe#295' while only api#227 is bound is REFUSED naming fe#295, and nothing is written (DIVE-5343's shape)" \
  || bad_t "S1 shorthand refusal" "rc=$rc dref='$(col DIVE-950 delivery_ref)' out=$out"
out=$(cmd_task_deliver DIVE-950 --pr="$API" --pr="$FE" --result="$EV — delivered as api#227 + fe#295, merge the API first" 2>&1); rc=$?
[[ $rc -eq 0 && "$(col DIVE-950 delivery_companions)" == "$FE" ]] \
  && ok_t "S1a binding the frontend PR by URL is the fix, and the same shorthand result proceeds" \
  || bad_t "S1a shorthand bound" "rc=$rc out=$out"
seed DIVE-949 dev ""
out=$(cmd_task_deliver DIVE-949 --pr="$API" --result="$EV — the UI is lodar/5dive-frontend#295" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"lodar/5dive-frontend#295"* ]] \
  && ok_t "S1c the owner/repo#N form is shorthand too, and is refused when its number is not bound" \
  || bad_t "S1c owner/repo shorthand" "rc=$rc out=$out"
seed DIVE-951 dev ""
out=$(cmd_task_deliver DIVE-951 --pr="$API" --result="$EV — api#227 (lodar/5dive-api#227) only, see DIVE-4899, #1195, src/x.sh#L12 and $API#issuecomment-1" 2>&1); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "S1b shorthand naming the BOUND pull request, a DIVE ident and a bare #N are not refused" \
  || bad_t "S1b shorthand false positive" "rc=$rc out=$out"

# ── F: the two-PR fixture ──────────────────────────────────────────────────────
seed DIVE-952 dev ""
cmd_task_deliver DIVE-952 --pr="$API" --pr="$FE" >/dev/null 2>&1
cmd_task_deliver DIVE-952 --pr="$API" >/dev/null 2>&1      # DIVE-5322's iteration 4
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
out=$(cmd_task_done DIVE-952 --result="$EV" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"$FE"* && "$out" == *"unbind-pr"* && "$(col DIVE-952 status)" != "done" ]] \
  && ok_t "F1 API merged + FE open, after a single-PR re-delivery: done is REFUSED naming the FE PR and the unbind verb" \
  || bad_t "F1 done over an open FE" "rc=$rc status='$(col DIVE-952 status)' out=$out"
PRSTATE=(["$API"]=MERGED ["$FE"]=MERGED)
out=$(cmd_task_done DIVE-952 --result="$EV" 2>&1); rc=$?
[[ "$(col DIVE-952 status)" == "done" ]] \
  && ok_t "F2 merging the FE PR closes it" \
  || bad_t "F2 close after FE merged" "rc=$rc status='$(col DIVE-952 status)' out=$out"

seed DIVE-953 dev ""
cmd_task_deliver DIVE-953 --pr="$API" --pr="$FE" >/dev/null 2>&1
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
out=$(cmd_task_unbind_pr DIVE-953 "$FE" 2>&1); rc=$?
[[ $rc -ne 0 && "$(col DIVE-953 delivery_companions)" == "$FE" ]] \
  && ok_t "F3a unbind-pr with no --reason is refused and nothing changes" \
  || bad_t "F3a unbind without reason" "rc=$rc out=$out"
out=$( actor_seam_as leo; cmd_task_unbind_pr DIVE-953 "$FE" --reason="not mine" 2>&1 ); rc=$?
[[ $rc -ne 0 && "$(col DIVE-953 delivery_companions)" == "$FE" ]] \
  && ok_t "F3b unbind-pr by a seat the row does not name is refused" \
  || bad_t "F3b stranger unbind" "rc=$rc out=$out"
out=$(cmd_task_unbind_pr DIVE-953 "$API" --reason="x" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"PRIMARY"* ]] \
  && ok_t "F3c the primary is not unbindable (that is merge-declined or a re-delivery)" \
  || bad_t "F3c primary unbind" "rc=$rc out=$out"
out=$(cmd_task_unbind_pr DIVE-953 "$FE" --reason="folded into the API PR's server-rendered page" 2>&1); rc=$?
show=$(JSON_MODE=0 cmd_task_show DIVE-953 2>&1)
[[ $rc -eq 0 && -z "$(col DIVE-953 delivery_companions)" && "$show" == *"unbound = $FE — folded into the API PR's server-rendered page (by dev"* ]] \
  && ok_t "F3d unbind-pr with a reason drops it, and the reason appears on the row (task show)" \
  || bad_t "F3d unbind recorded" "rc=$rc comp='$(col DIVE-953 delivery_companions)' show=$(grep -i unbound <<<"$show") out=$out"
cmd_task_deliver DIVE-953 --pr="$API" >/dev/null 2>&1
[[ -z "$(col DIVE-953 delivery_companions)" ]] \
  && ok_t "F3e ...and a later re-delivery does not carry an unbound PR back in" \
  || bad_t "F3e unbound carried back" "comp='$(col DIVE-953 delivery_companions)'"
out=$(cmd_task_done DIVE-953 --result="$EV" 2>&1); rc=$?
[[ "$(col DIVE-953 status)" == "done" ]] \
  && ok_t "F3f with the FE PR still OPEN, the unbind is what lets the row close" \
  || bad_t "F3f close after unbind" "rc=$rc status='$(col DIVE-953 status)' out=$out"

mk_merging DIVE-954
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
_hb_forge_merge_sweep
held=$([[ -z "$(col DIVE-954 merge_landed_at)" && "$(col DIVE-954 merge_owner)" == "ops" ]] && echo 1)
out=$( actor_seam_as ops; cmd_task_unbind_pr DIVE-954 "$FE" --reason="superseded by DIVE-955" 2>&1 ); rc=$?
_hb_forge_merge_sweep
[[ "$held" == 1 && $rc -eq 0 && "$(col DIVE-954 merge_landed_sha)" == "$SHA" ]] \
  && ok_t "F4 merging stage: the poller HOLDS with FE open, the merge owner unbinds with a reason, and the next tick lands the row" \
  || bad_t "F4 merging-stage unbind" "held=$held rc=$rc landed='$(col DIVE-954 merge_landed_sha)' out=$out"

# ── R: the derived set ─────────────────────────────────────────────────────────
seed DIVE-956 dev ""
cmd_task_deliver DIVE-956 --pr="$API" >/dev/null 2>&1
db "UPDATE tasks SET result=$(sqlq "$EV — frontend half: $FE") WHERE ident='DIVE-956';"   # an --append-result after delivery
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
out=$(cmd_task_done DIVE-956 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"$FE"* && "$(col DIVE-956 status)" != "done" ]] \
  && ok_t "R1 a pull URL in the stored RESULT is bound: done is refused while it is open" \
  || bad_t "R1 result-named PR" "rc=$rc status='$(col DIVE-956 status)' out=$out"
seed DIVE-957 dev ""
db "UPDATE tasks SET body=$(sqlq $'Build the thing.\n\nDelivered as:\n- '"$API"$'\n- '"$FE"$'\n\nNotes: '"$OTHER") WHERE ident='DIVE-957';"
cmd_task_deliver DIVE-957 --pr="$API" >/dev/null 2>&1
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN ["$OTHER"]=OPEN)
out=$(cmd_task_done DIVE-957 --result="$EV" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"$FE"* && "$out" != *"$OTHER"* ]] \
  && ok_t "R2 a pull URL under the body's 'Delivered as' is bound (and one outside that paragraph is not)" \
  || bad_t "R2 body Delivered-as" "rc=$rc out=$out"

# ── N: --no-pr records a drop ──────────────────────────────────────────────────
seed DIVE-958 dev ""
cmd_task_deliver DIVE-958 --pr="$API" --no-pr --result="$EV — same shape as $OTHER" >/dev/null 2>&1
PRSTATE=(["$API"]=MERGED ["$OTHER"]=OPEN)
out=$(cmd_task_done DIVE-958 --result="$EV" 2>&1); rc=$?
[[ "$(col DIVE-958 status)" == "done" && "$(col DIVE-958 delivery_unbound)" == "$OTHER"* ]] \
  && ok_t "N1 a URL the delivery declared --no-pr is recorded as unbound and does not hold the close" \
  || bad_t "N1 --no-pr recorded" "rc=$rc status='$(col DIVE-958 status)' unb='$(col DIVE-958 delivery_unbound)' out=$out"

# ── M2: mutation — bind only delivery_ref, F1 must go red ─────────────────────
seed DIVE-959 dev ""
cmd_task_deliver DIVE-959 --pr="$API" --pr="$FE" >/dev/null 2>&1
PRSTATE=(["$API"]=MERGED ["$FE"]=OPEN)
( _task_bound_pr_refs() { :; }; cmd_task_done DIVE-959 --result="$EV" >/dev/null 2>&1 )
[[ "$(col DIVE-959 status)" == "done" ]] \
  && ok_t "M2 MUTATION: with the bound set reduced to delivery_ref the row closes with FE open — F1 is a control that can fail" \
  || bad_t "M2 mutation did not bite" "F1 would pass with only delivery_ref bound, so it grades nothing"
seed DIVE-960 dev ""
( _task_unbound_pr_shorthand() { :; }; cmd_task_deliver DIVE-960 --pr="$API" --result="$EV — api#227 + fe#295" >/dev/null 2>&1 )
[[ -n "$(col DIVE-960 delivery_ref)" ]] \
  && ok_t "M3 MUTATION: with the shorthand check stubbed the S1 delivery goes through — S1 is a control that can fail" \
  || bad_t "M3 mutation did not bite" "S1 would pass with the shorthand check removed"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
