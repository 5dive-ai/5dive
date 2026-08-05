#!/usr/bin/env bash
# TIER: nightly — 9.8s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-1920 unit harness for `task set-body`. Same isolation contract as
# task_set_branch_unit.sh: source src/ directly, point STATE_DIR at a
# throwaway temp dir so the live shared tasks.db is NEVER touched.
# Run: bash tests/task_set_body_unit.sh   (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-set-body-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { local verb="$1"; shift; ( "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
jf()  { jq -r "$1" 2>/dev/null; }
bodyof() { db "SELECT COALESCE(body,'') FROM tasks WHERE id=$1;"; }

tasks_db_init

# --- T1: set-body on a bodyless task writes the text
id1=$(run add --assignee=alice -- "bare maker task" | jf '.data.id')
out=$(run set_body "$id1" "here is the missing context")
[[ "$(printf '%s' "$out" | jf '.data.mode')" == "replaced" ]] \
  && ok_t "set-body reports mode=replaced" || bad_t "set-body reports mode=replaced" "$out"
[[ "$(bodyof "$id1")" == "here is the missing context" ]] \
  && ok_t "set-body writes the body" || bad_t "set-body writes the body" "got: $(bodyof "$id1")"

# --- T2: default overwrites, not appends
out2=$(run set_body "$id1" "replacement text")
[[ "$(bodyof "$id1")" == "replacement text" ]] \
  && ok_t "set-body (no --append) overwrites the prior body" || bad_t "set-body overwrites" "got: $(bodyof "$id1")"
[[ "$(printf '%s' "$out2" | jf '.data.prior_lines')" == "1" \
   && "$(printf '%s' "$out2" | jf '.data.new_lines')" == "1" \
   && "$(printf '%s' "$out2" | jf '.data.prior_len')" == "27" \
   && "$(printf '%s' "$out2" | jf '.data.new_len')" == "16" ]] \
  && ok_t "set-body overwrite reports its before/after magnitude" \
  || bad_t "set-body overwrite magnitude" "$out2"
JSON_MODE=0
out2_prose=$(run set_body "$id1" $'replacement line one\nreplacement line two')
JSON_MODE=1
[[ "$out2_prose" == *"1 line -> 2 lines, +1"* ]] \
  && ok_t "set-body prose announces overwrite line delta" \
  || bad_t "set-body prose overwrite magnitude" "$out2_prose"

# --- T3: --append tacks onto the existing body without clobbering it
before3=$(bodyof "$id1")
run set_body "$id1" "an addendum" --append >/dev/null
b3=$(bodyof "$id1")
[[ "$b3" == "${before3}"$'\n\n'"an addendum" ]] \
  && ok_t "set-body --append preserves the prior body and adds the new text" \
  || bad_t "set-body --append preserves + adds" "$b3"

# --- T4: --append on an empty body just writes the text (no leading blank lines)
id2=$(run add --assignee=alice -- "another bare task" | jf '.data.id')
run set_body "$id2" "first finding" --append >/dev/null
[[ "$(bodyof "$id2")" == "first finding" ]] \
  && ok_t "set-body --append on an empty body writes plain text" || bad_t "set-body --append on empty body" "got: $(bodyof "$id2")"

# --- T5: works on recurring templates (the DIVE-176 case)
tid=$(run add --recurring="0 2 * * *" --assignee=alice -- "nightly template" | jf '.data.id')
run set_body "$tid" "template instructions live here" >/dev/null
[[ "$(bodyof "$tid")" == "template instructions live here" ]] \
  && ok_t "set-body works on a recurring template" || bad_t "set-body on recurring template" "got: $(bodyof "$tid")"

# --- T6: refused on a closed (done) task
id4=$(run add --assignee=alice --no-verify -- "closeable task" | jf '.data.id')
run done "$id4" --result="closed in fixture setup (DIVE-2773: a first close must carry a reason)" >/dev/null
e6=$(run set_body "$id4" "too late"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$e6" | grep -q "already done" \
  && ok_t "set-body refuses a closed (done) task" || bad_t "set-body refuses a closed task" "rc=$rc $e6"
[[ "$(bodyof "$id4")" != "too late" ]] \
  && ok_t "rejected set-body left the closed task's body untouched" || bad_t "rejected set-body left body untouched" "$(bodyof "$id4")"

# --- T7: missing text arg -> usage error, not a silent no-op
e7=$(run set_body "$id1"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$e7" | grep -q "usage: 5dive task set-body" \
  && ok_t "set-body with no text errors" || bad_t "set-body with no text errors" "rc=$rc $e7"

# --- T8: boolean --append=<payload> fails safely without echoing the payload
payload="ZZPAYLOADZZ this must not look acknowledged"
before8=$(bodyof "$id1")
e8=$(run set_body "$id1" "--append=$payload"); rc=$?
err8=$(<"$TMP/err")
[[ $rc -eq "$E_USAGE" \
   && "$e8" == *"--append is a boolean flag"* \
   && "$e8" != *"$payload"* \
   && "$err8" != *"$payload"* ]] \
  && ok_t "set-body rejects --append=<payload> without echoing the payload" \
  || bad_t "set-body payload-safe boolean error" "rc=$rc stdout=$e8 stderr=$err8"
[[ "$(bodyof "$id1")" == "$before8" ]] \
  && ok_t "rejected --append=<payload> leaves the body untouched" \
  || bad_t "rejected --append=<payload> changed the body" "got: $(bodyof "$id1")"

# --- T9: another boolean flag cannot replay a pasted paragraph through the
# shared unknown-flag path. This is deliberately `task ls --json=...`, not the
# set-body special case above, so the generic error emitter carries the proof.
other_payload="ZZOTHERBOOLZZ context that ends by claiming FAKE CONFIRMATION"
e9=$(run ls "--json=$other_payload"); rc=$?
err9=$(<"$TMP/err")
[[ $rc -eq "$E_USAGE" \
   && "$e9" == *"unknown flag: --json=ZZOTHERBOOLZZ"* \
   && "$e9" == *"..."* \
   && "$e9" != *"$other_payload"* \
   && "$e9" != *"FAKE CONFIRMATION"* \
   && "$err9" != *"$other_payload"* \
   && "$err9" != *"FAKE CONFIRMATION"* ]] \
  && ok_t "shared unknown-flag errors truncate another boolean payload" \
  || bad_t "shared unknown-flag payload truncation" "rc=$rc stdout=$e9 stderr=$err9"

# --- T10: legacy unknown-flag phrasings use the same safety ceiling.
e10=$( ( fail "$E_USAGE" "unknown flag '$other_payload' (see: 5dive help)" ) 2>"$TMP/err" ); rc=$?
err10=$(<"$TMP/err")
[[ $rc -eq "$E_USAGE" \
   && "$e10" == *"unknown flag 'ZZOTHERBOOLZZ"* \
   && "$e10" == *"..."* \
   && "$e10" != *"$other_payload"* \
   && "$e10" != *"FAKE CONFIRMATION"* \
   && "$err10" != *"$other_payload"* \
   && "$err10" != *"FAKE CONFIRMATION"* ]] \
  && ok_t "legacy unknown-flag errors truncate pasted payloads" \
  || bad_t "legacy unknown-flag payload truncation" "rc=$rc stdout=$e10 stderr=$err10"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
