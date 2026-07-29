#!/usr/bin/env bash
# DIVE-2015 isolated unit harness: a maker may rescue a stalled delivered loop
# with `task verify --cmd`, but the permitted self-close must be visible in the
# task record, the audit log, and stderr. No policy refusal is expected.
#
# Same isolation contract as the other task harnesses: source src/ directly,
# use a throwaway TASKS_DB, stub the task-store audit sink, and touch neither the
# live board nor the fleet audit log.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-verify-self-close-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_CALLS="$TMP/audit-calls"
mkdir -p "$TASKS_DIR"
: >"$AUDIT_CALLS"
set +e

# Exercise the real call site without allowing a fixture store to reach the
# production audit sink. The wrapper's arguments are the receipt under test.
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run()   { local verb="$1"; shift; ( JSON_MODE=1; "cmd_task_$verb" "$@" ) 2>"$TMP/err"; }
run_as() { local who="$1" verb="$2"; shift 2
  ( USER="agent-${who}"; SUDO_UID=""; SUDO_USER=""; JSON_MODE=1; "cmd_task_$verb" "$@" ) 2>"$TMP/err"
}
jf() { jq -r "$1" 2>/dev/null; }
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE id=$1;"; }

JSON_MODE=1
tasks_db_init

make_delivered() { # <title> -> numeric id
  local row id
  row=$(run add --assignee=alice --priority=low --verifier=boss -- "$1")
  id=$(printf '%s' "$row" | jf '.data.id')
  run_as alice start "$id" >/dev/null
  run_as alice done "$id" --result="maker delivery" >/dev/null
  printf '%s' "$id"
}

# Positive arm: maker + live delivered loop + passing auto-close.
M=$(make_delivered "maker rescue visibility")
maker_out=$(run_as alice verify "$M" --cmd=true); maker_rc=$?
maker_err=$(cat "$TMP/err")
maker_result=$(col "$M" result)
maker_ident=$(col "$M" ident)
[[ $maker_rc -eq 0 && "$(col "$M" status)" == "done" ]] \
  && ok_t "maker verify PASS still closes the delivered loop" \
  || bad_t "maker close changed policy" "rc=$maker_rc status=$(col "$M" status) $maker_out"
[[ "$maker_result" == "⚠ self-verified-close: maker=alice; verifier=boss never graded; iteration=1"$'\n'* ]] \
  && ok_t "task result is stamped with maker, ungrading verifier, and iteration" \
  || bad_t "durable task mark missing" "$maker_result"
show_json=$(run show "$M")
[[ "$(printf '%s' "$show_json" | jf '.data.task.result')" == *"self-verified-close: maker=alice; verifier=boss never graded; iteration=1"* ]] \
  && ok_t "task show JSON surfaces the durable self-verified-close mark" \
  || bad_t "task show did not expose mark" "$show_json"
[[ "$maker_err" == *"self-verified-close"* ]] \
  && ok_t "maker self-close warns on stderr" \
  || bad_t "stderr warning missing" "$maker_err"
audit_row=$(tail -n 1 "$AUDIT_CALLS")
[[ "$audit_row" == "task.verify-self-close self-verified-close 0 -- task=${maker_ident} maker=alice verifier=boss iteration=1" ]] \
  && ok_t "distinct audit verb/result attributes the maker close" \
  || bad_t "audit receipt wrong" "$audit_row"

# Control: the assigned verifier's same PASS is an ordinary independent grade.
V=$(make_delivered "verifier grade control")
before=$(wc -l <"$AUDIT_CALLS")
run_as boss verify "$V" --cmd=true >/dev/null
after=$(wc -l <"$AUDIT_CALLS")
[[ "$(col "$V" status)" == "done" && "$(col "$V" result)" != *"self-verified-close"* \
   && "$before" == "$after" && "$(cat "$TMP/err")" != *"self-verified-close"* ]] \
  && ok_t "verifier close carries no maker self-close mark, audit, or warning" \
  || bad_t "independent grade was mislabeled" "result=$(col "$V" result) audit=$before/$after err=$(cat "$TMP/err")"

# Negative arm: a failing maker-selected command records evidence but does not
# close, so it earns none of the three close-only marks.
F=$(make_delivered "maker failing check")
before=$(wc -l <"$AUDIT_CALLS")
run_as alice verify "$F" --cmd=false >/dev/null; fail_rc=$?
after=$(wc -l <"$AUDIT_CALLS")
[[ $fail_rc -ne 0 && "$(col "$F" status)" == "todo" \
   && "$(col "$F" result)" != *"self-verified-close"* && "$before" == "$after" \
   && "$(cat "$TMP/err")" != *"self-verified-close"* ]] \
  && ok_t "failed maker verify does not claim a self-verified close" \
  || bad_t "failed check was mislabeled" "rc=$fail_rc status=$(col "$F" status) audit=$before/$after"

# Negative arm: --no-done explicitly records a check without closing.
N=$(make_delivered "maker no-done check")
before=$(wc -l <"$AUDIT_CALLS")
run_as alice verify "$N" --cmd=true --no-done >/dev/null
after=$(wc -l <"$AUDIT_CALLS")
[[ "$(col "$N" status)" == "todo" && "$(col "$N" result)" != *"self-verified-close"* \
   && "$before" == "$after" && "$(cat "$TMP/err")" != *"self-verified-close"* ]] \
  && ok_t "--no-done maker check is not mislabeled as a close" \
  || bad_t "no-done check was mislabeled" "status=$(col "$N" status) audit=$before/$after"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
