#!/usr/bin/env bash
# DIVE-5852 — `task add --tell-me` / `task watch`: the FILING seat is woken once
# when the row it filed closes, whoever closes it.
#
# lodar 2026-10-08, after a third missed "I'll tell you when it's live" in a
# week: the filer had nothing that told it the row had landed, so its promise to
# its owner rested on a guessed timer. And, the hard requirement (05:17Z): "only
# goes when they promised ... its gonna be noisy as hell if they ping every time
# something is shipped". So the NEGATIVE CONTROL carries as much weight as the
# positive arm: an unflagged close produces zero wakes and zero owner messages.
#
# cmd_send and _task_send_owner are stubbed to append to a file, so every arm
# counts deliveries rather than trusting a return code.
# Run: bash tests/task_tell_me_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC=src
TMP="$(mktemp -d /tmp/task-tell-me-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh \
         cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
fixture_box_verify_policy never || exit 1
JSON_MODE=1; mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

SENDS="$TMP/sends"; OWNER="$TMP/owner"; : >"$SENDS"; : >"$OWNER"
SEND_RC=0
# One line per delivery: "<to>|<message, newlines flattened>".
cmd_send() {
  local to="" msg=""
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}" ;; --*) ;; *) to="$a" ;; esac; done
  (( SEND_RC == 0 )) || { echo "tmux session 'agent-${to}' not found" >&2; return 1; }
  printf '%s|%s\n' "$to" "${msg//$'\n'/ }" >>"$SENDS"
}
_task_send_owner() { printf '%s\n' "$1" >>"$OWNER"; }

tasks_db_init
as() { local who="$1"; shift; ( actor_seam_as "${who}"; "$@" ) 2>"$TMP"/err; }
add() { local who="$1"; shift; ( actor_seam_as "$who"; JSON_MODE=1 cmd_task_add "$@" 2>"$TMP"/err | jq -r '.data.ident // empty' ); }
sends()     { wc -l <"$SENDS" | tr -d ' '; }
owner_msgs(){ wc -l <"$OWNER" | tr -d ' '; }
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

[[ "$( ( actor_seam_as filer; task_actor ) )" == "filer" ]] \
  && ok_t "INSTRUMENT: harness impersonates an actor" \
  || bad_t "INSTRUMENT: actor impersonation broken" "arms below would be vacuous"

# ── 1. flagged row, ANOTHER seat closes it: exactly one wake, to the filer ──────
T1=$(add filer "ship the thing" --assignee=maker --no-verify --tell-me)
[[ "$(col "$T1" tell_me_by)" == "filer" ]] \
  && ok_t "--tell-me records the filing seat" \
  || bad_t "--tell-me did not record the filer" "tell_me_by='$(col "$T1" tell_me_by)' err=$(cat "$TMP"/err)"
as maker cmd_task_done "$T1" --result="Merged; live after the nightly release." >/dev/null
if [[ "$(sends)" == 1 ]] && grep -q "^filer|.*${T1} is done.*Merged; live after the nightly release.*LIVE" "$SENDS"; then
  ok_t "done by another seat wakes the filer exactly once, with ident, status, result and the live-check ask"
else
  bad_t "done did not wake the filer exactly once" "sends=$(sends): $(cat "$SENDS") err=$(cat "$TMP"/err)"
fi
[[ "$(owner_msgs)" == 0 ]] && ok_t "the filer is woken, the owner is NOT messaged directly" \
  || bad_t "the owner was messaged directly" "$(cat "$OWNER")"

# ── 2. reopen + second close: zero further wakes ────────────────────────────────
[[ "$(col "$T1" status)" == done ]] || bad_t "precondition: $T1 did not close in arm 1" "status=$(col "$T1" status)"
db "UPDATE tasks SET status='in_progress', done_at=NULL WHERE ident=$(sqlq "$T1");"
as maker cmd_task_done "$T1" --result="again" --force-result >/dev/null
[[ "$(sends)" == 1 ]] && ok_t "a reopen and second close wake nobody (one-shot)" \
  || bad_t "a second close woke the filer again" "sends=$(sends): $(cat "$SENDS")"

# ── 3. cancel wakes too ─────────────────────────────────────────────────────────
: >"$SENDS"
T3=$(add filer "maybe the thing" --assignee=maker --no-verify --tell-me)
as maker cmd_task_cancel "$T3" --result="Superseded by another row." >/dev/null
[[ "$(sends)" == 1 ]] && grep -q "^filer|.*${T3} is cancelled" "$SENDS" \
  && ok_t "cancel wakes the filer once" \
  || bad_t "cancel did not wake the filer" "sends=$(sends): $(cat "$SENDS") err=$(cat "$TMP"/err)"

# ── 4. NEGATIVE CONTROL: no flag, no wake, no owner message — ever ──────────────
: >"$SENDS"; : >"$OWNER"
T4=$(add filer "routine thing" --assignee=maker --no-verify)
as maker cmd_task_done "$T4" --result="done" >/dev/null
T4b=$(add filer "routine thing 2" --assignee=maker --no-verify)
as maker cmd_task_cancel "$T4b" --result="not needed" >/dev/null
[[ "$(sends)" == 0 && "$(owner_msgs)" == 0 && -z "$(col "$T4" tell_me_by)" ]] \
  && ok_t "NEGATIVE CONTROL: an unflagged done and cancel produce zero wakes and zero owner messages" \
  || bad_t "an unflagged close produced a message" "sends=$(cat "$SENDS") owner=$(cat "$OWNER")"

# ── 5. task watch on an already-filed row ───────────────────────────────────────
: >"$SENDS"
T5=$(add someone "filed earlier" --assignee=maker --no-verify)
as filer cmd_task_watch "$T5" >/dev/null
as other cmd_task_watch "$T5" >/dev/null; rc=$?
(( rc != 0 )) && ok_t "a second seat cannot overwrite another seat's watch" \
  || bad_t "a second watch silently replaced the first" "tell_me_by=$(col "$T5" tell_me_by)"
as maker cmd_task_done "$T5" --result="landed" >/dev/null
[[ "$(sends)" == 1 ]] && grep -q "^filer|.*${T5} is done" "$SENDS" \
  && ok_t "task watch: the watching seat is woken once on close" \
  || bad_t "task watch did not wake the watcher" "sends=$(sends): $(cat "$SENDS")"
as filer cmd_task_watch "$T5" >/dev/null; rc=$?
(( rc != 0 )) && ok_t "task watch on a closed row is refused" || bad_t "task watch accepted a closed row"

# ── 6. a failed delivery releases the claim and says so ─────────────────────────
: >"$SENDS"
T6=$(add filer "flaky" --assignee=maker --no-verify --tell-me)
SEND_RC=1 as maker cmd_task_done "$T6" --result="x" >/dev/null
if [[ -z "$(col "$T6" told_at)" ]] && grep -q "did not deliver" "$TMP"/err; then
  ok_t "a failed wake leaves told_at empty and warns the closer"
else
  bad_t "a failed wake was swallowed" "told_at=$(col "$T6" told_at) err=$(cat "$TMP"/err)"
fi

# ── 7. the filer closing its own row: no self-wake, a reminder instead ──────────
: >"$SENDS"
T7=$(add filer "my own" --assignee=filer --no-verify --tell-me)
as filer cmd_task_done "$T7" --result="x" >/dev/null
[[ "$(sends)" == 0 ]] && grep -q "you closed it yourself" "$TMP"/err \
  && ok_t "self-close: no wake into your own pane, a reminder on stderr" \
  || bad_t "self-close behaved wrong" "sends=$(cat "$SENDS") err=$(cat "$TMP"/err)"

# ── 9. the VERIFIER's close: a PASS lands through task verify's own raw write ───
# quinn, DIVE-5852 iteration 1: a flagged row closed by `task verify --cmd=true`
# went done with sends=0, and `task watch` then refused the closed row, so the
# promise dropped silently. Every row with a verifier closes this way.
: >"$SENDS"; : >"$OWNER"
T9=$(add filer "graded thing" --assignee=maker --verifier=grader --tell-me)
as grader cmd_task_verify "$T9" --cmd=true >/dev/null
[[ "$(col "$T9" status)" == done ]] || bad_t "precondition: verify did not close $T9" "status=$(col "$T9" status) err=$(cat "$TMP"/err)"
[[ "$(sends)" == 1 ]] && grep -q "^filer|.*${T9} is done (closed by grader)" "$SENDS" \
  && ok_t "a verifier's task verify close wakes the filer exactly once" \
  || bad_t "task verify close did not wake the filer once" "sends=$(sends): $(cat "$SENDS") err=$(cat "$TMP"/err)"
: >"$SENDS"
T9b=$(add filer "graded routine" --assignee=maker --verifier=grader)
as grader cmd_task_verify "$T9b" --cmd=true >/dev/null
[[ "$(col "$T9b" status)" == done && "$(sends)" == 0 && "$(owner_msgs)" == 0 ]] \
  && ok_t "NEGATIVE CONTROL: an unflagged verify close wakes nobody" \
  || bad_t "an unflagged verify close sent something" "status=$(col "$T9b" status) sends=$(cat "$SENDS") owner=$(cat "$OWNER")"

# ── 10. a loop GATE step answered "Approve →" closes by answer.sh's raw write ───
: >"$SENDS"
LR=$(add filer "loop run" --assignee=main --no-verify)
LP=$(add filer "loop work" --assignee=maker --no-verify)
LG=$(add filer "loop gate" --assignee=gatekeeper --no-verify)
db "UPDATE tasks SET body='[[5dive-loop:run]]' WHERE ident=$(sqlq "$LR");
    UPDATE tasks SET parent_id=(SELECT id FROM tasks WHERE ident=$(sqlq "$LR")), body='[[5dive-loop:work]]',
      status='done', done_at=datetime('now') WHERE ident=$(sqlq "$LP");
    UPDATE tasks SET parent_id=(SELECT id FROM tasks WHERE ident=$(sqlq "$LR")), body='[[5dive-loop:gate:decision]]',
      status='blocked', need_type='decision', ask='approve or redo?', tier=1, need_asked_at=datetime('now'),
      tell_me_by='filer' WHERE ident=$(sqlq "$LG");"
as gatekeeper cmd_task_answer "$LG" --value="Approve →" >/dev/null
[[ "$(col "$LG" status)" == done ]] || bad_t "precondition: the gate step did not close" "status=$(col "$LG" status) err=$(cat "$TMP"/err)"
grep -q "^filer|.*${LG} is done" "$SENDS" && [[ "$(grep -c "^filer|.*${LG} is" "$SENDS")" == 1 ]] \
  && ok_t "a loop gate step closed by its answer wakes the filer once" \
  || bad_t "gate-step close did not wake the filer once" "sends=$(cat "$SENDS") err=$(cat "$TMP"/err)"

# ── 8. surface: help line, and the column reaches existing stores ───────────────
_task_usage | grep -q -- "--tell-me" && _task_usage | grep -q "watch <id>" \
  && ok_t "task --help documents --tell-me and watch" || bad_t "help line missing"
printf '%s\n' "${_TASKS_ADDITIVE_COLUMNS[@]}" | grep -qx 'tell_me_by TEXT' \
  && printf '%s\n' "${_TASKS_ADDITIVE_COLUMNS[@]}" | grep -qx 'told_at TEXT' \
  && ok_t "tell_me_by/told_at are additive columns (migrated onto existing boards)" \
  || bad_t "columns missing from _TASKS_ADDITIVE_COLUMNS — existing boards would fail 'no such column'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
