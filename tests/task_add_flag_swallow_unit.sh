#!/usr/bin/env bash
# DIVE-3107 unit harness: `task add` must REFUSE a title that carries a flag
# swallowed past the `--` end-of-flags separator, and refuse an absurdly long
# title, instead of silently storing either. Same isolation contract as the
# other task harnesses: source src/ directly, point STATE_DIR at a throwaway
# temp dir so the live shared tasks.db is NEVER touched.
# Run: bash tests/task_add_flag_swallow_unit.sh   (no root, no network).
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-add-swallow-unit.XXXXXX)"

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
errof() { cat "$TMP"/err; }

tasks_db_init

longtext=$(printf 'x%.0s' $(seq 1 260))

# --- T1: the exact DIVE-3100 shape — --body= written after `--` — is REFUSED
out=$(run add --assignee=alice -- "real title" --body="MEASURED 2026-08-09 the body that got swallowed"); rc=$?
[[ $rc -ne 0 ]] && ok_t "flag after -- exits non-zero" || bad_t "flag after -- exits non-zero" "rc=$rc out=$out"
errof | grep -q -- '--body=' \
  && ok_t "refusal names the leaked flag token" || bad_t "refusal names the leaked flag token" "$(errof)"
errof | grep -qi 'end-of-flags' \
  && ok_t "refusal explains the -- separator" || bad_t "refusal explains the -- separator" "$(errof)"
[[ "$(db "SELECT COUNT(*) FROM tasks;")" == "0" ]] \
  && ok_t "no row was written on refusal" || bad_t "no row was written on refusal" "count=$(db "SELECT COUNT(*) FROM tasks;")"

# --- T2: any leaked flag, not just --body (e.g. --accept=)
run add --assignee=alice -- "title" --accept="all tests green" >/dev/null; rc=$?
[[ $rc -ne 0 ]] && ok_t "leaked --accept= is refused too" || bad_t "leaked --accept= is refused too" "rc=$rc"

# --- T3: an over-long title is refused on the length tell alone
run add --assignee=alice -- "$longtext" >/dev/null; rc=$?
[[ $rc -ne 0 ]] && ok_t "260-char title is refused" || bad_t "260-char title is refused" "rc=$rc"
errof | grep -q '260 chars' \
  && ok_t "length refusal states the measured length" || bad_t "length refusal states the measured length" "$(errof)"

# --- T4: the CORRECT invocation (flags before --) still works, body intact
out=$(run add --assignee=alice --body="the real body" -- "a normal title")
id=$(printf '%s' "$out" | jf '.data.id')
[[ "$id" =~ ^[0-9]+$ ]] \
  && ok_t "correct invocation still creates a row" || bad_t "correct invocation still creates a row" "$out"
[[ "$(db "SELECT body FROM tasks WHERE id=$id;")" == "the real body" ]] \
  && ok_t "correct invocation keeps the body" || bad_t "correct invocation keeps the body" "$(db "SELECT body FROM tasks WHERE id=$id;")"

# --- T5: a title legitimately containing a lone dash or '--' word is NOT refused
out=$(run add --assignee=alice -- "a title with -- a dash and --verbose but no equals")
[[ "$(printf '%s' "$out" | jf '.data.id')" =~ ^[0-9]+$ ]] \
  && ok_t "a '--word' with no '=' is not a false positive" || bad_t "a '--word' with no '=' is not a false positive" "$out"

# --- T6: --materialized (the internal writers) is exempt from both tells
out=$(run add --materialized --assignee=alice -- "$longtext")
[[ "$(printf '%s' "$out" | jf '.data.id')" =~ ^[0-9]+$ ]] \
  && ok_t "--materialized bypasses the length tell" || bad_t "--materialized bypasses the length tell" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
