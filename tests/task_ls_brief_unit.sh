#!/usr/bin/env bash
# DIVE-8209 — `task ls --brief` drops task BODIES and keeps everything else,
# `result` included, so a busy box's whole history fits the box exec service's
# 4 MiB output cap (scripts/inc/shelld.mjs in 5dive-api).
#
# THE DEFECT. chill-gorge's `task ls --all --json` was 4,246,346 B for 1,178
# rows (bodies 3.3 MB, 77%), 52 KB over the cap, so the app's Tasks tab showed
# "Your server didn't answer". `--no-body` already existed but also drops
# `result`, which the Mini App list shows on rows done today.
#
#   A  --brief: no row has a `body` key; a done row keeps its `result`
#   B  --no-body is unchanged: neither key
#   C  both flags, either order: --no-body wins (neither key)
#   D  a board over 4 MiB in full is under 4 MiB with --brief, with every row
#   E  --brief applies to --recurring too (the app reads loops beside the list)
# Run: bash tests/task_ls_brief_unit.sh   (no root, no network)
set -uo pipefail
trap 'rc=$?; [[ -z "${TMP:-}" ]] || rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-ls-brief.XXXXXX)"

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
echo '{"agents":{"alice":{"heartbeat":{"enabled":true}}}}' > "$STATE_DIR/agents.json"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
mk() { cmd_task_add --assignee=alice --body="$2" -- "$1" 2>/dev/null | jq -r '.data.id'; }
t_open=$(mk "open row" "the open row's long body")
t_done=$(mk "done row" "the done row's long body")
db "UPDATE tasks SET status='done', done_at=datetime('now'), result='shipped the thing' WHERE id=$t_done;"
I_DONE=$(db "SELECT ident FROM tasks WHERE id=$t_done;")

keys() { printf '%s' "$1" | jq -r '[.data.tasks[] | (has("body")|tostring) + "/" + (has("result")|tostring)] | unique | join(",")'; }

# --- A ---------------------------------------------------------------------
OUT=$(cmd_task_ls --all --brief 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok_t "A: --brief is accepted (rc=0)" || bad_t "A: --brief rc" "rc=$rc out=${OUT:0:200}"
nb=$(printf '%s' "$OUT" | jq '[.data.tasks[] | select(has("body"))] | length' 2>/dev/null)
[[ "$nb" == "0" ]] && ok_t "A: no row carries a body" || bad_t "A: body present" "rows with body=$nb"
res=$(printf '%s' "$OUT" | jq -r --arg i "$I_DONE" '.data.tasks[] | select(.ident==$i) | .result' 2>/dev/null)
[[ "$res" == "shipped the thing" ]] && ok_t "A: the done row keeps its result" || bad_t "A: result" "got=[$res]"
n=$(printf '%s' "$OUT" | jq '.data.tasks | length' 2>/dev/null)
[[ "$n" == "2" ]] && ok_t "A: every row is listed ($n)" || bad_t "A: row count" "got=$n"

# --- B ---------------------------------------------------------------------
k=$(keys "$(cmd_task_ls --all --no-body 2>/dev/null)")
[[ "$k" == "false/false" ]] && ok_t "B: --no-body still drops body and result" || bad_t "B: --no-body" "keys=$k"

# --- C ---------------------------------------------------------------------
k1=$(keys "$(cmd_task_ls --all --brief --no-body 2>/dev/null)")
k2=$(keys "$(cmd_task_ls --all --no-body --brief 2>/dev/null)")
[[ "$k1" == "false/false" && "$k2" == "false/false" ]] && ok_t "C: --no-body wins in either order" \
  || bad_t "C: both flags" "brief,no-body=$k1 no-body,brief=$k2"

# --- D ---------------------------------------------------------------------
# 1,200 done rows, each with a 3,600-char body and a short result: the shape of
# chill-gorge's history (bodies most of the bytes).
db "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1200)
    INSERT INTO tasks (ident, title, status, priority, assignee, created_by, kind, body, result, done_at)
    SELECT 'BIG-'||i, 'history row '||i, 'done', 'medium', 'alice', 'alice', 'standard',
           hex(randomblob(1800)), 'result '||i, datetime('now','-2 days') FROM n;"
CAP=$((4 * 1024 * 1024))
full=$(cmd_task_ls --all 2>/dev/null | wc -c)
brief_out=$(cmd_task_ls --all --brief 2>/dev/null)
brief=$(printf '%s' "$brief_out" | wc -c)
rows=$(printf '%s' "$brief_out" | jq '.data.tasks | length' 2>/dev/null)
(( full > CAP )) && ok_t "D: the fixture is over 4 MiB in full ($full B)" || bad_t "D: fixture too small" "full=$full"
(( brief < CAP )) && ok_t "D: --brief fits under 4 MiB ($brief B)" || bad_t "D: --brief too big" "brief=$brief"
[[ "$rows" == "1202" ]] && ok_t "D: --brief lists every row ($rows)" || bad_t "D: rows" "got=$rows"

# --- E ---------------------------------------------------------------------
db "INSERT INTO tasks (ident, title, status, priority, assignee, created_by, kind, body, schedule)
         VALUES ('LOOP-1','a loop','todo','medium','alice','alice','recurring','template body','0 9 * * *');"
R=$(cmd_task_ls --recurring --brief 2>/dev/null)
rn=$(printf '%s' "$R" | jq '[.data.tasks[] | select(has("body"))] | length' 2>/dev/null)
rt=$(printf '%s' "$R" | jq '.data.tasks | length' 2>/dev/null)
[[ "$rn" == "0" && "${rt:-0}" -ge 1 ]] && ok_t "E: --recurring --brief lists templates without bodies ($rt)" \
  || bad_t "E: recurring" "with-body=$rn total=$rt"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
