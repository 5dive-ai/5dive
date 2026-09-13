#!/usr/bin/env bash
# TIER: core
# DIVE-4416 ITEM 3 regression harness — "the usage string teaches bare letters".
#
# Customer report 2026-09-13 (5dive-bug-options-usage-teaches-bare-letters.md):
# `5dive task --help` advertised `[--options=A|B] [--recommend=<A>...]`, and the
# heartbeat /goal nudge embedded the same words, so every filer and every agent
# the heartbeat woke was taught to file gates carrying options "A" and "B". The
# parser never cared (free-form strings, split on '|', trimmed) — the PLACEHOLDER
# was the only thing steering them. Measured cost: a row carrying options A|B and
# recommend A records nothing about what A meant; the mapping survived only in the
# clause order of the free-text ask, and one of their engineers restated it
# backwards while relaying the ruling. A self-describing option survives a forward,
# a quote and a screenshot; a letter survives none.
#
# The row's revision note is the reason arms 1-4 come in PAIRS: `A|B` is an example
# list and `<A>` is a placeholder, and each ALONE still teaches the letter. Fixing
# one and leaving the other beside it leaves the lesson standing, so both spellings
# must be gone from both surfaces.
#
# Arm 5-6 grade the behaviour half: need.sh WARNS (never fails — DIVE-2249's
# fixtures and scripted callers legitimately pass letters) when every --options
# entry is a single character, because that is the old placeholder being copied.
#
# No root, no network, throwaway DB. Run: bash tests/task_need_options_placeholder_unit.sh
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
SRC="${DIVE_TEST_SRC:-$ROOT/src}"
TMP="$(mktemp -d /tmp/task-need-options-placeholder.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---- 1-4. the two surfaces the row names, both spellings each ---------------
# Acceptance from the row: grep for `options=A|B` AND `recommend=<A>` must both
# come back empty, in src/task/dispatch.sh:99 and in the cmd_heartbeat.sh nudge.
for pair in "task usage:$SRC/task/dispatch.sh" "heartbeat /goal nudge:$SRC/cmd_heartbeat.sh"; do
  label="${pair%%:*}"; file="${pair#*:}"
  for pat in 'options=A|B' 'recommend=<A>'; do
    n=$(grep -cF -- "$pat" "$file" 2>/dev/null || true)
    [[ "$n" == "0" ]] \
      && ok_t "$label carries no '$pat'" \
      || bad_t "$label still teaches '$pat'" "$file: $n occurrence(s) — $(grep -nF -- "$pat" "$file" | head -1 | cut -c1-120)"
  done
done

# ---- 5. the same lesson is not left standing in the headless-picker hook ----
# The row said "grep src for any other copy of the A|B example". hooks/ is outside
# src/ and carries one: it is the text an agent reads at the exact moment it was
# about to ask a question, i.e. the moment it files a gate instead.
HOOK="$ROOT/hooks/pretool-headless-question.sh"
if [[ -f "$HOOK" ]]; then
  n=$(grep -cF -- 'options=A|B' "$HOOK" 2>/dev/null || true)
  [[ "$n" == "0" ]] \
    && ok_t "headless-question hook carries no 'options=A|B'" \
    || bad_t "headless-question hook still teaches 'options=A|B'" "$n occurrence(s)"
else
  ok_t "headless-question hook absent (nothing to grade)"
fi

# ---- 6. the rendered help a filer actually reads ---------------------------
# Grading the FILE is not grading the HELP: the usage is a heredoc and a filer
# reads it through `5dive task --help`. Render it the way the CLI does.
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh lib/broker.sh cmd_push.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP/state"
TASKS_DIR="$STATE_DIR/tasks"
# shellcheck disable=SC2034
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
# shellcheck disable=SC2034
FIVE_VERIFY_DEFAULT=0
# shellcheck disable=SC2034
FIVE_FILING_CAP=0
set +e

HELP=$(_task_usage 2>&1)
n=$(printf '%s' "$HELP" | grep -cF -- 'options=A|B')
[[ "$n" == "0" ]] \
  && ok_t "rendered '5dive task --help' carries no 'options=A|B' (row acceptance: count 0)" \
  || bad_t "rendered help still teaches 'options=A|B'" "$n line(s)"
case "$HELP" in
  *'--options="'*) ok_t "rendered help shows a spelled-out --options placeholder" ;;
  *) bad_t "rendered help lost its --options placeholder entirely" "no quoted --options= form found" ;;
esac

# ---- 7-8. the behaviour half: warn on all-single-character options ----------
tasks_db_init
db "INSERT INTO tasks (ident,title,status,priority,created_by,project_key,kind)
    VALUES ('DIVE-9001','placeholder-options row','in_progress','medium','main','dive','standard'),
           ('DIVE-9002','descriptive-options row','in_progress','medium','main','dive','standard');"

run_need() {
  local tag="$1"; shift
  ( cmd_task_need "$@" ) >"$TMP/$tag.out" 2>"$TMP/$tag.err"
  printf '%s' "$?" >"$TMP/$tag.rc"
}

# DIVE-4431: arms 7-8 grade DIVE-4416's "warn, never fail" on the population it
# was written for — a gate an AGENT reads. This harness has no org chart, so the
# chart resolves nobody and (since DIVE-4431) an unrouted tier-1 gate is graded as
# human-facing, where the same letters are REFUSED. Give the filer a lead so these
# arms keep asking their own question; the human-facing escalation is arm 8b.
_gate_route_reviewer() { printf 'main'; }

run_need letters DIVE-9001 --type=decision \
  --ask="Ship the smaller change now, or hold for the full one?" \
  --options='A|B' --recommend='A'
ERR=$(cat "$TMP/letters.err" 2>/dev/null)
case "$ERR" in
  *'single character'*) ok_t "--options=A|B warns that every option is a single character" ;;
  *) bad_t "no single-character warning on --options=A|B" "stderr: $(printf '%s' "$ERR" | head -3)" ;;
esac
# WARN, not fail: DIVE-2249's fixtures and scripted callers pass letters on purpose.
RC=$(cat "$TMP/letters.rc" 2>/dev/null)
[[ "$RC" == "0" ]] \
  && ok_t "the warning does not fail the filing (warn, never fail)" \
  || bad_t "single-character options were REJECTED, not warned" "rc=$RC err: $(printf '%s' "$ERR" | head -3)"

run_need spelled DIVE-9002 --type=decision \
  --ask="Ship the smaller change now, or hold for the full one?" \
  --options='widen the cap now|fix the 176 rows and split it' \
  --recommend='widen the cap now'
ERR2=$(cat "$TMP/spelled.err" 2>/dev/null)
case "$ERR2" in
  *'single character'*) bad_t "descriptive options wrongly warned" "stderr: $(printf '%s' "$ERR2" | head -3)" ;;
  *) ok_t "descriptive options file silently (no false positive)" ;;
esac
RC=$(cat "$TMP/spelled.rc" 2>/dev/null)
[[ "$RC" == "0" ]] \
  && ok_t "descriptive options file cleanly" \
  || bad_t "descriptive options failed to file" "rc=$RC err: $(printf '%s' "$ERR2" | head -3)"

# ---- 8b. DIVE-4431: the same letters on a HUMAN-facing gate are REFUSED -----
# The warning above is advice to a filer whose reader is an agent. When the reader
# is the paired human the options are the BUTTONS, and `A` / `B` name no outcome —
# so there the same input is a refusal, with the same --ask-ok escape as the rest
# of the human-ask readability rule.
db "INSERT INTO tasks (ident,title,status,priority,created_by,project_key,kind)
    VALUES ('DIVE-9003','human-facing placeholder-options row','in_progress','medium','main','dive','standard');"
run_need humanletters DIVE-9003 --type=decision --tier=2 --needs=human_tap \
  --ask="Ship the smaller change now, or hold for the full one?" \
  --options='A|B' --recommend='A'
RC=$(cat "$TMP/humanletters.rc" 2>/dev/null)
[[ "$RC" != "0" ]] \
  && ok_t "DIVE-4431: bare letters on a gate a PERSON reads are refused, not warned" \
  || bad_t "DIVE-4431: bare letters on a human-facing gate must be refused" "rc=$RC"
case "$(cat "$TMP/humanletters.err" 2>/dev/null)" in
  *'bare labels'*) ok_t "DIVE-4431: ... and the refusal says the buttons name no outcome" ;;
  *) bad_t "DIVE-4431: refusal must name the options" "stderr: $(head -3 "$TMP/humanletters.err" 2>/dev/null)" ;;
esac
[[ "$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='DIVE-9003';")" == "" ]] \
  && ok_t "DIVE-4431: ... and NO gate was written by the refused filing" \
  || bad_t "DIVE-4431: refused filing must not leave a gate" "need_type=$(db "SELECT need_type FROM tasks WHERE ident='DIVE-9003';")"

# ---- 9. a one-character option next to a real one is NOT the placeholder ----
# Only an ALL-single-character list is the copied placeholder. "y|proceed with a
# staged rollout" is someone abbreviating one arm, and warning on it would train
# filers to ignore the warning.
db "INSERT INTO tasks (ident,title,status,priority,created_by,project_key,kind)
    VALUES ('DIVE-9003','mixed-options row','in_progress','medium','main','dive','standard');"
run_need mixed DIVE-9003 --type=decision \
  --ask="Ship the smaller change now, or hold for the full one?" \
  --options='y|hold for the full change' --recommend='y'
ERR3=$(cat "$TMP/mixed.err" 2>/dev/null)
case "$ERR3" in
  *'single character'*) bad_t "mixed-length options wrongly warned" "stderr: $(printf '%s' "$ERR3" | head -3)" ;;
  *) ok_t "a single-character option beside a spelled-out one does not warn" ;;
esac

# ---- 10. the warning arms are not vacuous: the gate actually landed ---------
# `cmd_task_need` returning 0 is not proof it did anything. If the filing had
# silently no-opped, arms 7-9 would grade an empty stderr and pass for the wrong
# reason. Require the two rows to carry a real open gate.
for pair in DIVE-9001:letters DIVE-9002:spelled; do
  _id="${pair%%:*}"; _tag="${pair#*:}"
  _n=$(db "SELECT COUNT(*) FROM tasks WHERE ident='${_id}' AND need_type='decision' AND need_options IS NOT NULL AND need_options<>'';" 2>/dev/null)
  [[ "${_n:-0}" == "1" ]] \
    && ok_t "the $_tag filing actually recorded a decision gate with options on $_id (arms above are not vacuous)" \
    || bad_t "no gate recorded on $_id" "matched=${_n:-<none>} rc=$(cat "$TMP/$_tag.rc" 2>/dev/null) need_type=$(db "SELECT COALESCE(need_type,'<null>') FROM tasks WHERE ident='${_id}';" 2>/dev/null)"
done

echo
printf 'DIVE-4416 ITEM 3 options placeholder: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
