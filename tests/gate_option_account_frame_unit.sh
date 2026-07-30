#!/usr/bin/env bash
# DIVE-2212: gate options cross an author/reader boundary. A second-person
# pronoun can naturally point at the answerer when written and at the filer when
# read, so two agents can believe they agreed while selecting the same bytes.
#
# This isolated harness proves both halves of the fix:
#   * filing warns but remains backward-compatible (free-text options still file);
#   * answering a pronoun option renders concrete filer/answerer accounts and a
#     declared frame, without merely echoing the ambiguous option in prose;
#   * word-boundary matching does not warn on innocent substrings.
# Run: bash tests/gate_option_account_frame_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-option-frame.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
JSON_MODE=0

# No fixture may notify the live paired human or a live agent.
task_need_notify() { :; }
cmd_send() { return 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
    VALUES ('DIVE-9212','ambiguous option','medium','dev3','main','standard','todo');"

# The exact incident shape: dev3 writes "you" addressing main. The warning must
# make the risk visible without rejecting an existing free-text gate workflow.
need_out=$(cmd_task_need DIVE-9212 --type=decision --tier=1 \
  --ask="Who should close it?" \
  --options="you-close-it|grant-me-a-token" --recommend="you-close-it" \
  --from=dev3 2>&1); need_rc=$?

[[ "$need_rc" == "0" && "$(db "SELECT status||'|'||need_options||'|'||gate_filed_by FROM tasks WHERE ident='DIVE-9212';")" == "blocked|you-close-it|grant-me-a-token|dev3" ]] \
  && ok_t "pronoun-bearing options warn but still file with dev3 as filer" \
  || bad_t "warning path remains backward-compatible" "rc=$need_rc row=$(db "SELECT status||'|'||COALESCE(need_options,'')||'|'||COALESCE(gate_filed_by,'') FROM tasks WHERE ident='DIVE-9212';") out=$need_out"
[[ "$need_out" == *"second-person"* && "$need_out" == *"Prefer account names"* && "$need_out" == *"filer dev3"* ]] \
  && ok_t "filing warning explains the frame defect and names the filer" \
  || bad_t "filing warning" "$need_out"

# main selects the same bytes. The rendered receipt must resolve the parties by
# account and declare that second-person text in dev3's authored option means
# main. It intentionally must NOT make the raw ambiguous label the receipt.
answer_out=$(cmd_task_answer DIVE-9212 --value="you-close-it" --from=main 2>&1); answer_rc=$?
[[ "$answer_rc" == "0" && "$answer_out" == *"filer=dev3"* && "$answer_out" == *"answerer=main"* && "$answer_out" == *"refer to main"* ]] \
  && ok_t "answer receipt names dev3/main and resolves the authored account frame" \
  || bad_t "account-resolved answer receipt" "rc=$answer_rc out=$answer_out"
[[ "$answer_out" != *"you-close-it"* ]] \
  && ok_t "prose receipt does not merely echo the ambiguous option" \
  || bad_t "ambiguous option leaked back as the prose confirmation" "$answer_out"

# Structured callers keep the raw answer for compatibility, while receiving the
# same explicit account frame as machine-readable fields.
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
    VALUES ('DIVE-9214','json frame','medium','dev3','main','standard','todo');"
cmd_task_need DIVE-9214 --type=decision --tier=1 --ask="Who closes it?" \
  --options="you-close-it|dev3-closes-it" --recommend="you-close-it" \
  --from=dev3 >/dev/null 2>&1
JSON_MODE=1
json_out=$(cmd_task_answer DIVE-9214 --value="you-close-it" --from=main 2>"$TMP/json.err"); json_rc=$?
JSON_MODE=0
[[ "$json_rc" == "0" && "$(jq -r '.data.need_answer' <<<"$json_out")" == "you-close-it" \
   && "$(jq -r '.data.option_account_frame.filer' <<<"$json_out")" == "dev3" \
   && "$(jq -r '.data.option_account_frame.answerer' <<<"$json_out")" == "main" \
   && "$(jq -r '.data.option_account_frame.second_person_refers_to' <<<"$json_out")" == "main" ]] \
  && ok_t "JSON receipt preserves the answer and adds the concrete account frame" \
  || bad_t "JSON account frame" "rc=$json_rc json=$json_out err=$(cat "$TMP/json.err")"

# Non-vacuity control: the boundary matcher must not flag product/action words
# that merely contain the letters "you".
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
    VALUES ('DIVE-9213','clean option','medium','dev3','main','standard','todo');"
clean_out=$(cmd_task_need DIVE-9213 --type=decision --tier=1 \
  --ask="Which path?" --options="youtube-run|young-team-runs" \
  --recommend="youtube-run" --from=dev3 2>&1); clean_rc=$?
[[ "$clean_rc" == "0" && "$clean_out" != *"second-person wording"* ]] \
  && ok_t "word boundaries avoid false-positive warnings" \
  || bad_t "pronoun boundary" "rc=$clean_rc out=$clean_out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
