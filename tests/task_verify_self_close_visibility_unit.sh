#!/usr/bin/env bash
# TIER: nightly — 10.9s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2015 isolated unit harness: a maker may rescue a stalled delivered loop
# with `task verify --cmd`, but the permitted self-close must be visible in the
# task record, the audit log, and stderr. No policy refusal is expected.
#
# DEPENDENCY: the identity arms assume DIVE-2330's resolver contract:
# `_gate_authenticated_actor` obtains its uid from `_gate_caller_uid` and maps it
# only through `_gate_passwd_stream`. Keep this branch atop DIVE-2330 until that
# resolver lands on main; pinning these function seams is what keeps the arms from
# silently grading the harness runner when the production implementation changes.
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
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
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
# Drive the real authenticated-actor resolver through the DIVE-2330 uid/passwd
# seams while varying caller provenance independently. These are function seams,
# not PATH-resolved commands: production defines them after imported functions are
# loaded, while this already-sourced harness can pin them without teaching a caller
# how to override the live resolver.
run_with_identity() { local authenticated="$1" claimed_user="$2" verb="$3"; shift 3
  (
    local pinned_uid=987654
    _gate_caller_uid() { printf '%s' "$pinned_uid"; }
    _gate_passwd_stream() {
      [[ -n "$authenticated" ]] \
        && printf 'agent-%s:x:%s:%s::/nonexistent:/bin/false\n' \
             "$authenticated" "$pinned_uid" "$pinned_uid"
      printf '%s\n' "$(</etc/passwd)"
    }
    USER="$claimed_user"; SUDO_UID=""; SUDO_USER=""; JSON_MODE=1
    "cmd_task_$verb" "$@"
  ) 2>"$TMP/err"
}
run_as() { local who="$1" verb="$2"; shift 2
  run_with_identity "$who" "agent-${who}" "$verb" "$@"
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

# Regression arm: provenance is forgeable, authenticated identity is not. The
# recorded maker still receives all three visibility marks when USER and the old
# resolver's PATH commands both claim a non-maker identity. On the pre-DIVE-2330
# resolver this shim suppresses the mark; the uid/passwd resolver must ignore it.
FORGED_PATH="$TMP/forged-path"
mkdir -p "$FORGED_PATH"
printf '#!/bin/bash\n[[ "${1:-}" == "-u" ]] && printf "1000\\n" || printf "agent-nobody\\n"\n' >"$FORGED_PATH/id"
printf '#!/bin/bash\nprintf "agent-nobody:x:1000:1000::/nonexistent:/bin/false\\n"\n' >"$FORGED_PATH/getent"
chmod +x "$FORGED_PATH/id" "$FORGED_PATH/getent"
P=$(make_delivered "maker forged provenance visibility")
before=$(wc -l <"$AUDIT_CALLS")
forged_out=$(PATH="$FORGED_PATH:$PATH" run_with_identity alice nobody verify "$P" --cmd=true); forged_rc=$?
after=$(wc -l <"$AUDIT_CALLS")
[[ $forged_rc -eq 0 && "$(col "$P" status)" == "done" \
   && "$(col "$P" result)" == *"self-verified-close: maker=alice; verifier=boss never graded; iteration=1"* \
   && "$after" -eq $((before+1)) && "$(cat "$TMP/err")" == *"self-verified-close"* ]] \
  && ok_t "forged USER/PATH cannot suppress an authenticated maker self-close mark" \
  || bad_t "forged USER/PATH bypass remains" "rc=$forged_rc status=$(col "$P" status) audit=$before/$after out=$forged_out err=$(cat "$TMP/err")"

# Fail closed when the kernel identity resolver cannot attribute a caller. The
# passing command remains useful evidence, but an unclassifiable caller cannot
# create the exact silent-close shape this visibility rail exists to prevent.
U=$(make_delivered "unidentified caller control")
before=$(wc -l <"$AUDIT_CALLS")
unknown_out=$(run_with_identity "" nobody verify "$U" --cmd=true); unknown_rc=$?
after=$(wc -l <"$AUDIT_CALLS")
[[ $unknown_rc -ne 0 && "$(col "$U" status)" == "todo" \
   && "$(col "$U" result)" == "✅ verify PASS (exit 0): true"* \
   && "$(col "$U" result)" != *"self-verified-close"* && "$before" == "$after" \
   && "$(cat "$TMP/err")" == *"caller identity could not be authenticated"* ]] \
  && ok_t "unidentified caller records PASS evidence but cannot close a delivered loop" \
  || bad_t "unidentified caller did not fail closed" "rc=$unknown_rc status=$(col "$U" status) result=$(col "$U" result) audit=$before/$after out=$unknown_out err=$(cat "$TMP/err")"

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
