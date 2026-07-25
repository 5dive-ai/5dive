#!/usr/bin/env bash
# DIVE-2007 isolated unit harness for the delivered-loop `task done` guard.
#
# The bug: on a maker→verifier loop the FIRST `task done` delivers (assignee flips
# TO the verifier), and because the routing test is positional (verifier !=
# assignee) a SECOND `task done` by the same MAKER read as "the verifier's own
# close" and closed the task outright — ungraded (DIVE-1988). Guard keys on the
# ACTOR instead.
#
# Same isolation contract as the other task unit harnesses: sources src/ libs
# directly with STATE_DIR on a throwaway temp dir, so it NEVER touches the live
# shared tasks.db. Actor is forced per-case via FIVE_SENDER/USER rather than sudo.
# Run: bash tests/task_done_delivered_guard_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-done-delivered-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# task_actor() falls back to $USER when there's no sudo mapping and no --from, so
# each case sets USER to the agent-<name> form to impersonate that actor.
as() { local who="$1"; shift; ( USER="agent-${who}"; SUDO_UID=""; SUDO_USER=""; "$@" ) 2>"$TMP"/err; }
actor_is() { ( USER="agent-$1"; SUDO_UID=""; SUDO_USER=""; task_actor ); }

[[ "$(actor_is dev)" == "dev" ]] && ok_t "harness can impersonate an actor (task_actor → dev)" \
  || bad_t "actor impersonation" "got '$(actor_is dev)' — every case below would be vacuous"

seed() {  # -> ident of a fresh maker(dev)→verifier(main) loop task
  local out; out=$(JSON_MODE=1 cmd_task_add "$1" --assignee=dev --verifier=main \
                     --accept="must do the thing" 2>"$TMP"/err)
  printf '%s' "$out" | jq -r '.data.ident // empty' 2>/dev/null
}
status_of()   { db "SELECT status FROM tasks WHERE ident=$(sqlq "$1");"; }
assignee_of() { db "SELECT assignee FROM tasks WHERE ident=$(sqlq "$1");"; }
iter_of()     { db "SELECT COALESCE(iteration,0) FROM tasks WHERE ident=$(sqlq "$1");"; }

# --- T1: baseline — the maker's FIRST done delivers, it does not close.
T1=$(seed "T1 deliver once")
[[ -n "$T1" ]] || bad_t "seed T1" "$(cat "$TMP"/err)"
as dev cmd_task_done "$T1" --result="v1" >/dev/null
[[ "$(status_of "$T1")" == "todo" && "$(assignee_of "$T1")" == "main" && "$(iter_of "$T1")" == "1" ]] \
  && ok_t "T1 first done delivers (todo, assignee=main, iteration 1)" \
  || bad_t "T1 delivery" "status=$(status_of "$T1") assignee=$(assignee_of "$T1") iter=$(iter_of "$T1")"

# --- T2: THE BUG — the maker's SECOND done must be REFUSED, not close the task.
out=$(as dev cmd_task_done "$T1" --result="v2 amended"); rc=$?
(( rc != 0 )) && ok_t "T2 maker's second done exits non-zero (rc=$rc)" \
  || bad_t "T2 second done should fail" "rc=$rc out=$out"
[[ "$(status_of "$T1")" == "todo" && "$(assignee_of "$T1")" == "main" ]] \
  && ok_t "T2 task stays DELIVERED (todo, held by main) — not closed" \
  || bad_t "T2 row mutated" "status=$(status_of "$T1") assignee=$(assignee_of "$T1")"
[[ "$(db "SELECT COALESCE(done_at,'') FROM tasks WHERE ident=$(sqlq "$T1");")" == "" ]] \
  && ok_t "T2 done_at not stamped" || bad_t "T2 done_at stamped" "the close went through"
[[ "$(iter_of "$T1")" == "1" ]] && ok_t "T2 refusal does not re-deliver (iteration still 1)" \
  || bad_t "T2 iteration bumped" "iter=$(iter_of "$T1")"
[[ "$(db "SELECT COALESCE(result,'') FROM tasks WHERE ident=$(sqlq "$T1");")" == "v1" ]] \
  && ok_t "T2 delivered result text untouched by the refused amend" \
  || bad_t "T2 result overwritten" "result=$(db "SELECT COALESCE(result,'') FROM tasks WHERE ident=$(sqlq "$T1");")"
grep -qi "DELIVERED to verifier 'main'" "$TMP"/err \
  && ok_t "T2 refusal names the verifier who must close it" || bad_t "T2 message" "$(cat "$TMP"/err)"
grep -qi "agent send main" "$TMP"/err \
  && ok_t "T2 refusal names the amend route (send the correction to the verifier)" \
  || bad_t "T2 no remedy in message" "$(cat "$TMP"/err)"
[[ "$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy='done-over-delivered-loop' AND ident=$(sqlq "$T1");")" == "1" ]] \
  && ok_t "T2 refusal audited to policy_refusals" || bad_t "T2 not audited" "no policy_refusals row"

# --- T3: the VERIFIER's own done still closes for real (no regression on the
# happy path — this is the whole point of the loop).
out=$(as main cmd_task_done "$T1" --result="graded PASS"); rc=$?
(( rc == 0 )) && [[ "$(status_of "$T1")" == "done" ]] \
  && ok_t "T3 verifier's done closes the delivered task" \
  || bad_t "T3 verifier close broken" "rc=$rc status=$(status_of "$T1") $(cat "$TMP"/err)"

# --- T4: a third party (neither maker nor verifier) is refused too — the guard is
# "only the verifier closes", not "the maker is special".
T4=$(seed "T4 third party")
as dev cmd_task_done "$T4" --result="v1" >/dev/null
out=$(as olivia cmd_task_done "$T4" --result="drive-by close"); rc=$?
(( rc != 0 )) && [[ "$(status_of "$T4")" == "todo" ]] \
  && ok_t "T4 third-party done on a delivered loop is refused" \
  || bad_t "T4 third party closed it" "rc=$rc status=$(status_of "$T4")"

# --- T5: the verifier's close after an ACK (task start → in_progress) still works.
T5=$(seed "T5 ack then close")
as dev  cmd_task_done  "$T5" --result="v1" >/dev/null
as main cmd_task_start "$T5" --no-preflight >/dev/null
as main cmd_task_done  "$T5" --result="graded after ack" >/dev/null; rc=$?
(( rc == 0 )) && [[ "$(status_of "$T5")" == "done" ]] \
  && ok_t "T5 verifier closes after ACK" || bad_t "T5 post-ack close" "rc=$rc status=$(status_of "$T5") $(cat "$TMP"/err)"

# --- T6: a plain task with NO verifier is untouched — the maker's done closes it.
out=$(JSON_MODE=1 cmd_task_add "T6 plain chore" --assignee=dev --no-verify 2>"$TMP"/err)
T6=$(printf '%s' "$out" | jq -r '.data.ident // empty')
as dev cmd_task_done "$T6" --result="closed" >/dev/null; rc=$?
(( rc == 0 )) && [[ "$(status_of "$T6")" == "done" ]] \
  && ok_t "T6 no-verifier task still closes on the assignee's done" \
  || bad_t "T6 plain close regressed" "rc=$rc status=$(status_of "$T6") $(cat "$TMP"/err)"

# --- T7: a task the verifier holds but that was never DELIVERED (no maker_agent —
# e.g. the verifier is also the assignee from the start) is not caught by the guard.
out=$(JSON_MODE=1 cmd_task_add "T7 verifier is assignee" --assignee=main --no-verify 2>"$TMP"/err)
T7=$(printf '%s' "$out" | jq -r '.data.ident // empty')
db "UPDATE tasks SET verifier='main' WHERE ident=$(sqlq "$T7");"
as main cmd_task_done "$T7" --result="closed" >/dev/null; rc=$?
(( rc == 0 )) && [[ "$(status_of "$T7")" == "done" ]] \
  && ok_t "T7 undelivered (no maker_agent) task closes normally" \
  || bad_t "T7 over-blocked" "rc=$rc status=$(status_of "$T7") $(cat "$TMP"/err)"

# --- T8: cancel is still available to the maker as the abandon path (the refusal
# message points there, so it must actually work).
T8=$(seed "T8 cancel path")
as dev cmd_task_done "$T8" --result="v1" >/dev/null
as dev cmd_task_cancel "$T8" --result="abandoned" >/dev/null; rc=$?
(( rc == 0 )) && [[ "$(status_of "$T8")" == "cancelled" ]] \
  && ok_t "T8 maker can still cancel a delivered task" \
  || bad_t "T8 cancel blocked" "rc=$rc status=$(status_of "$T8") $(cat "$TMP"/err)"

# --- T9: an UNATTRIBUTABLE caller (task_actor → 'cli': non-agent user, root cron,
# CI) is EXEMPT, so this guard cannot shadow a more specific rule downstream.
# Regression lock for what CI caught and every dev box hid: with $USER
# unresolvable the guard fired ahead of the DIVE-1830 merge-gate, refusing an
# unmerged-delivery close while citing DIVE-2007, and refusing a MERGED one
# outright (task_deliver_merge_gate_unit Tb/Tc). Reproduce the CI shape exactly:
# no sudo mapping and a $USER that is not agent-*.
nobody() { ( USER=runner; SUDO_UID=""; SUDO_USER=""; "$@" ) 2>"$TMP"/err; }
[[ "$( ( USER=runner; SUDO_UID=""; SUDO_USER=""; task_actor ) )" == "cli" ]] \
  && ok_t "T9 harness reproduces the unattributable actor (task_actor → cli)" \
  || bad_t "T9 actor precondition" "got '$( ( USER=runner; SUDO_UID=""; SUDO_USER=""; task_actor ) )' — T9/T10 would be vacuous"

T9=$(seed "T9 unattributed close")
as dev cmd_task_done "$T9" --result="v1" >/dev/null
[[ "$(status_of "$T9")" == "todo" && "$(assignee_of "$T9")" == "main" ]] \
  || bad_t "T9 precond delivery" "status=$(status_of "$T9") assignee=$(assignee_of "$T9")"
out=$(nobody cmd_task_done "$T9" --result="closed by automation"); rc=$?
(( rc == 0 )) && [[ "$(status_of "$T9")" == "done" ]] \
  && ok_t "T9 unattributable ('cli') close is NOT refused by the DIVE-2007 guard" \
  || bad_t "T9 cli close refused" "rc=$rc status=$(status_of "$T9") $(cat "$TMP"/err)"
[[ "$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy='done-over-delivered-loop' AND ident=$(sqlq "$T9");")" == "0" ]] \
  && ok_t "T9 no DIVE-2007 refusal row for the exempt actor" \
  || bad_t "T9 spurious refusal row" "the guard fired on an unattributable caller"

# --- T10: the exemption is NARROW — it must not become a bypass for a caller who
# DOES resolve. Same delivered loop, actor resolves to the maker → still refused.
T10=$(seed "T10 exemption is narrow")
as dev cmd_task_done "$T10" --result="v1" >/dev/null
out=$(as dev cmd_task_done "$T10" --result="v2"); rc=$?
(( rc != 0 )) && [[ "$(status_of "$T10")" == "todo" ]] \
  && ok_t "T10 a RESOLVABLE maker is still refused (exemption did not widen)" \
  || bad_t "T10 maker slipped through" "rc=$rc status=$(status_of "$T10")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
