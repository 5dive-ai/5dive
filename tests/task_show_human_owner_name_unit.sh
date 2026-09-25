#!/usr/bin/env bash
# DIVE-4949: `task show --json` exports `human_owner_name`, the display name of
# the human `human_owner` names (DIVE-3342), so the Telegram /task_<id> card can
# print "human owner: <name>" on a multi-human box without joining `human ls`
# itself. NULL, and so absent from the JSON, when there is no owner, the owner
# has no row in `humans`, or the row has no display name.
#
# Mutant: drop the `human_owner_name` column from the show query -> arm A reds.
# Run: bash tests/task_show_human_owner_name_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC=src
TMP="$(mktemp -d /tmp/task-show-owner-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh \
         cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
fixture_box_verify_policy always || exit 1
JSON_MODE=1; mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

tasks_db_init; _tasks_db_migrate
add() { JSON_MODE=1 cmd_task_add "$@" 2>"$TMP"/err | jq -r '.data.ident // empty'; }
show() { JSON_MODE=1 cmd_task_show "$1" 2>"$TMP"/err; }

db "INSERT INTO humans (id, display_name) VALUES ('h-ana','Ana'), ('h-bo','');"
R=$(add "owned row" --assignee=dev)
[[ -n "$R" ]] || { bad_t "fixture row was not created" "$(cat "$TMP"/err)"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

# A — the named owner's display name rides the row.
db "UPDATE tasks SET human_owner='h-ana' WHERE ident=$(sqlq "$R");"
out=$(show "$R")
[[ "$(jq -r '.data.task.human_owner' <<<"$out")" == "h-ana" && "$(jq -r '.data.task.human_owner_name' <<<"$out")" == "Ana" ]] \
  && ok_t "A: human_owner_name is the owner's display name" \
  || bad_t "A: human_owner_name missing or wrong" "$(jq -c '.data.task | {human_owner, human_owner_name}' <<<"$out")"

# B — an owner with an empty display name exports no name (never an empty string).
db "UPDATE tasks SET human_owner='h-bo' WHERE ident=$(sqlq "$R");"
out=$(show "$R")
[[ "$(jq -r '.data.task | has("human_owner_name")' <<<"$out")" == "false" ]] \
  && ok_t "B: an unnamed owner exports no human_owner_name" \
  || bad_t "B: unnamed owner exported a name" "$(jq -c '.data.task.human_owner_name' <<<"$out")"

# C — an owner id with no humans row, and D — no owner at all: no name, and show still succeeds.
db "UPDATE tasks SET human_owner='h-gone' WHERE ident=$(sqlq "$R");"
out=$(show "$R")
[[ "$(jq -r '.ok' <<<"$out")" == "true" && "$(jq -r '.data.task | has("human_owner_name")' <<<"$out")" == "false" ]] \
  && ok_t "C: an owner with no humans row exports no name" \
  || bad_t "C: dangling owner misbehaved" "$out"
db "UPDATE tasks SET human_owner=NULL WHERE ident=$(sqlq "$R");"
out=$(show "$R")
[[ "$(jq -r '.ok' <<<"$out")" == "true" && "$(jq -r '.data.task | has("human_owner_name")' <<<"$out")" == "false" ]] \
  && ok_t "D: no owner, no name, show still ok" \
  || bad_t "D: unowned row misbehaved" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
