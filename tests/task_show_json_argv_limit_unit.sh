#!/usr/bin/env bash
# TIER: core — ~6s measured bare in a src worktree on the control-plane VM
# (2026-09-13): the arms are ~10 real task_add/show round-trips against a scratch
# TASKS_DB plus two 140KB string builds. No network, no box.
#
# DIVE-4419 — `task show --json` must survive a row bigger than one argv entry,
# and a row body must stop growing without a bound.
#
# THE DEFECT, as it was actually observed: lodar tapped the tier-2 gate on row
# 4542 from Telegram at 07:47Z on 2026-09-13 and got "Couldn't apply that tap …
# 5dive task exited 126 without reporting a reason". The row's body was 116,368
# bytes and its result 24,432. cmd_task_show's JSON branch handed the whole row
# to jq as ONE argv entry (`--argjson t "$task"`), and Linux caps a single argv
# entry at MAX_ARG_STRLEN = 131,072 bytes — not tunable, not the ARG_MAX total.
# execve returns E2BIG, bash reports 126, jq prints "Argument list too long" to
# stderr and NO JSON envelope is emitted, so every machine consumer of the
# surface (the Telegram tap, /inbox, the dashboard row fetch) failed on a row
# whose only sin was that agents had written a lot on it.
#
# WHY THE INSTRUMENT ARMS ARE NOT DECORATION. Both are about vacuity in the same
# direction: a harness that builds a row which happens to render UNDER 131,072
# bytes passes every arm below against the unfixed code. So arm INSTRUMENT-1
# measures the rendered row and fails if it is not over the cap, and INSTRUMENT-2
# runs the PRE-FIX shape on the very same string and fails if it does NOT die.
# Note that the filing's suggested 130,000-byte body is inside the cap once the
# rest of the row JSON is only ~200 bytes — hence 140,000 here, and hence the
# measurement rather than a trusted constant.
#
# MUTANTS (each killed by the arm named; re-check them when editing this file):
#   M1 restore `jq -cn --argjson t "$task" …`           -> A, B
#   M2 swap `.[1]` and `.[2]` in the show filter         -> D (subtasks/blocked_by)
#   M3 drop `del(.body, .result)` from the --no-body arm -> B
#   M4 drop the gate_live/needs_human/gate columns       -> E
#   M5 `_task_body_size_guard` returns 0 unconditionally -> F, I
#   M6 guard checks the PRIOR body instead of the new    -> H (shrink is refused)
#   M7 refuse-branch compares against TASK_BODY_WARN_BYTES  -> G
#   M8 shipped defaults changed                          -> J
#
# Run: bash tests/task_show_json_argv_limit_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC=src
TMP="$(mktemp -d /tmp/task-show-argv-unit.XXXXXX)"

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

tasks_db_init
as() { local who="$1"; shift; ( actor_seam_as "${who}"; "$@" ) 2>"$TMP"/err; }
add() { JSON_MODE=1 cmd_task_add "$@" 2>"$TMP"/err | jq -r '.data.ident // empty'; }
body_bytes() { db "SELECT LENGTH(CAST(COALESCE(body,'') AS BLOB)) FROM tasks WHERE ident=$(sqlq "$1");"; }

# ── the oversized row: built by a direct UPDATE, exactly as row 4542 grew ──────
# (Deliberately NOT through set-body: the guard added by this same change refuses
# that write, and the read defect must be graded on a row that already exists.)
BIG=$(add "oversized row" --assignee=dev)
BIG_BODY=$(printf 'x%.0s' $(seq 1 140000))
# Seeded through sqlite3's STDIN, not through db(): db() passes the SQL as one
# argv entry too, so a 140KB UPDATE hits the very cap this harness is about
# ("/usr/bin/sqlite3: Argument list too long"). That is the same defect on the
# WRITE side and it is what bounds a body to <131072 bytes through the supported
# verbs — the guard below caps well under it, so the supported path never gets
# there. Row 4542 grew to 116,368 bytes inside that window, which is why the
# read surface broke first.
printf 'UPDATE tasks SET body=%s, result=%s WHERE ident=%s;\n' \
  "$(sqlq "$BIG_BODY")" "$(sqlq '')" "$(sqlq "$BIG")" \
  | sqlite3 "$TASKS_DB"

# ── INSTRUMENT-1: the row JSON really is past one argv entry ──────────────────
BIG_ID=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$BIG");")
ROW_JSON=$(dbfmt -json "SELECT * FROM tasks WHERE id=${BIG_ID};")
ROW_LEN=$(printf '%s' "$ROW_JSON" | wc -c | tr -d ' ')
MAX_ARG_STRLEN=131072
(( ROW_LEN > MAX_ARG_STRLEN )) \
  && ok_t "INSTRUMENT-1: fixture row renders ${ROW_LEN} bytes, past MAX_ARG_STRLEN ${MAX_ARG_STRLEN}" \
  || bad_t "INSTRUMENT-1: fixture row is only ${ROW_LEN} bytes" "under the ${MAX_ARG_STRLEN} cap — every arm below is vacuous"

# ── INSTRUMENT-2: the PRE-FIX shape dies on this exact string ─────────────────
# Positive control for the whole harness: if this passes, the cap is not being
# reached and arm A proves nothing.
jq -cn --argjson t "$ROW_JSON" '{ok:true, data:{task:($t[0])}}' >/dev/null 2>"$TMP"/pre_err
pre_rc=$?
(( pre_rc != 0 )) \
  && ok_t "INSTRUMENT-2: the pre-fix argv shape fails on this row (rc=$pre_rc: $(head -1 "$TMP"/pre_err | tr -d '\n'))" \
  || bad_t "INSTRUMENT-2: the pre-fix argv shape SUCCEEDED (rc=0)" "the defect is not reproduced; arm A cannot fail"

# ── A: the defect — `task show --json` on the oversized row ────────────────────
a_out=$(as dev cmd_task_show "$BIG"); a_rc=$?
a_len=$(printf '%s' "$a_out" | jq -r '.data.task.body // "" | length' 2>/dev/null)
(( a_rc == 0 )) && [[ "$a_len" == "140000" ]] \
  && ok_t "A: show --json on a ${ROW_LEN}-byte row exits 0 and round-trips the full 140000-byte body" \
  || bad_t "A: show --json failed on the oversized row" "rc=$a_rc body_len='$a_len' stderr=$(head -1 "$TMP"/err)"

# ── A2: the body is byte-identical, not merely the right length ───────────────
a_body=$(printf '%s' "$a_out" | jq -r '.data.task.body // empty' 2>/dev/null)
[[ "$a_body" == "$BIG_BODY" ]] \
  && ok_t "A2: the rendered body is byte-identical to the stored body" \
  || bad_t "A2: body differs from what is stored" "stored=${#BIG_BODY} rendered=${#a_body}"

# ── B: --no-body on the same row still strips body AND result ─────────────────
db "UPDATE tasks SET result='a stored result' WHERE ident=$(sqlq "$BIG");"
b_out=$(as dev cmd_task_show "$BIG" --no-body); b_rc=$?
b_keys=$(printf '%s' "$b_out" | jq -r '[.data.task | has("body"), has("result")] | @csv' 2>/dev/null)
b_ident=$(printf '%s' "$b_out" | jq -r '.data.task.ident // empty' 2>/dev/null)
(( b_rc == 0 )) && [[ "$b_keys" == "false,false" && "$b_ident" == "$BIG" ]] \
  && ok_t "B: --no-body exits 0 on the oversized row and drops body+result, ident intact" \
  || bad_t "B: --no-body wrong on the oversized row" "rc=$b_rc keys='$b_keys' ident='$b_ident'"

# ── C: an ORDINARY row is unchanged by the rewrite ────────────────────────────
SMALL=$(add "small row" --assignee=dev --body="short body")
c_out=$(as dev cmd_task_show "$SMALL"); c_rc=$?
c_shape=$(printf '%s' "$c_out" | jq -r '[.ok, (.data|has("subtasks")), (.data|has("blocked_by")), (.data|has("previous_gates")), (.data.task.body=="short body")] | @csv' 2>/dev/null)
(( c_rc == 0 )) && [[ "$c_shape" == "true,true,true,true,true" ]] \
  && ok_t "C: an ordinary row keeps the full envelope shape (ok/subtasks/blocked_by/previous_gates/body)" \
  || bad_t "C: envelope shape changed on an ordinary row" "rc=$c_rc shape='$c_shape'"

# ── D: the stream ORDER is the contract — subtasks and blockers must not swap ──
# The four values now reach jq positionally; nothing but this arm notices if the
# printf order and the filter's indices drift apart.
KID=$(add "child row" --assignee=dev --parent="$SMALL")
BLOCKER=$(add "blocker row" --assignee=dev)
JSON_MODE=1 cmd_task_block "$SMALL" --by="$BLOCKER" >/dev/null 2>&1 \
  || JSON_MODE=1 cmd_task_block "$SMALL" "$BLOCKER" >/dev/null 2>&1
d_out=$(as dev cmd_task_show "$SMALL")
d_sub=$(printf '%s' "$d_out" | jq -r '[.data.subtasks[].ident] | join(",")' 2>/dev/null)
d_dep=$(printf '%s' "$d_out" | jq -r '[.data.blocked_by[].ident] | join(",")' 2>/dev/null)
[[ "$d_sub" == "$KID" && "$d_dep" == "$BLOCKER" ]] \
  && ok_t "D: subtasks=[$d_sub] and blocked_by=[$d_dep] land in their own keys (stream order held)" \
  || bad_t "D: subtasks/blocked_by are swapped or empty" "subtasks='$d_sub' (want $KID) blocked_by='$d_dep' (want $BLOCKER)"

# ── E: the computed verdict columns survive the rewrite (DIVE-3340/3785) ──────
e_out=$(as dev cmd_task_show "$SMALL")
e_fields=$(printf '%s' "$e_out" | jq -r '[.data.task | has("gate_live"), has("gate")] | @csv' 2>/dev/null)
[[ "$e_fields" == "true,true" ]] \
  && ok_t "E: gate_live and gate are still exported on the JSON surface" \
  || bad_t "E: the computed gate fields are gone" "got '$e_fields' — DIVE-3340/3785 consumers rebuild the rule from raw inputs"

# ── J: the SHIPPED thresholds, before the harness lowers them ─────────────────
# Every guard arm below runs at 200/500 so the arms stay cheap, which means none
# of them notices if the defaults ship at, say, 8 bytes or 8MB. This arm is the
# only place the numbers the fleet actually gets are graded.
[[ "$TASK_BODY_WARN_BYTES" == "49152" && "$TASK_BODY_MAX_BYTES" == "98304" ]] \
  && ok_t "J: shipped thresholds are 48KB warn / 96KB refuse" \
  || bad_t "J: shipped thresholds changed" "warn=$TASK_BODY_WARN_BYTES max=$TASK_BODY_MAX_BYTES (want 49152/98304)"

# ── the growth guard ──────────────────────────────────────────────────────────
# Thresholds are lowered rather than writing 96KB of prose per arm; the guard
# reads the globals at call time, so this grades the real predicate.
TASK_BODY_WARN_BYTES=200
TASK_BODY_MAX_BYTES=500

# ── F: an append past the cap is REFUSED and the row is untouched ─────────────
G1=$(add "guard row" --assignee=dev --body="seed")
before=$(body_bytes "$G1")
LONG=$(printf 'y%.0s' $(seq 1 600))
f_out=$(as dev cmd_task_set_body "$G1" --append "$LONG"); f_rc=$?
f_err=$(cat "$TMP"/err)
after=$(body_bytes "$G1")
(( f_rc != 0 )) && [[ "$before" == "$after" ]] \
  && ok_t "F: append past the cap refused (rc=$f_rc) and the stored body is unchanged (${after} bytes)" \
  || bad_t "F: oversized append was accepted" "rc=$f_rc before=$before after=$after"

# ── F2: the refusal carries the ARCHIVE RECIPE, not just a number ─────────────
# A refusal that does not say what to do instead is a wall, and the caller is an
# agent that will otherwise retry the same write.
[[ "$f_err$f_out" == *"evidence/"* && "$f_err$f_out" == *"--append"* ]] \
  && ok_t "F2: the refusal names the archive-to-a-file recipe" \
  || bad_t "F2: the refusal is a bare size complaint" "$(printf '%s' "$f_err$f_out" | head -c 200)"

# ── G: the WARN band still LANDS (a warning is not a refusal) ─────────────────
G2=$(add "warn row" --assignee=dev --body="seed")
MID=$(printf 'z%.0s' $(seq 1 300))
g_out=$(as dev cmd_task_set_body "$G2" --append "$MID"); g_rc=$?
g_err=$(cat "$TMP"/err)
g_after=$(body_bytes "$G2")
(( g_rc == 0 )) && (( g_after > 300 )) && [[ "$g_err" == *"warn"* ]] \
  && ok_t "G: a body in the warn band lands (${g_after} bytes) and warns on stderr" \
  || bad_t "G: the warn band did not behave as a warning" "rc=$g_rc after=$g_after err=$(head -1 <<<"$g_err")"

# ── H: SHRINKING an already-oversized row is allowed ──────────────────────────
# The way out of an oversized row is a replace with a pointer; a guard that read
# the PRIOR size instead of the new one would trap exactly the rows it exists to
# prevent, permanently.
G3=$(add "oversized already" --assignee=dev)
db "UPDATE tasks SET body=$(sqlq "$LONG") WHERE ident=$(sqlq "$G3");"
h_out=$(as dev cmd_task_set_body "$G3" "full text: evidence/${G3}-archive.md"); h_rc=$?
h_after=$(body_bytes "$G3")
(( h_rc == 0 )) && (( h_after < 100 )) \
  && ok_t "H: a shrinking replace over a ${#LONG}-byte body is accepted (now ${h_after} bytes)" \
  || bad_t "H: the way OUT of an oversized row is blocked" "rc=$h_rc after=$h_after err=$(head -1 "$TMP"/err)"

# ── I: a row cannot be BORN oversized either (--body-file / --body) ───────────
printf '%s' "$LONG" > "$TMP"/big-body.md
i_out=$(as dev cmd_task_add "born oversized" --assignee=dev --body-file="$TMP"/big-body.md); i_rc=$?
i_rows=$(db "SELECT COUNT(*) FROM tasks WHERE title='born oversized';")
(( i_rc != 0 )) && [[ "$i_rows" == "0" ]] \
  && ok_t "I: task add --body-file past the cap is refused (rc=$i_rc) and no row is created" \
  || bad_t "I: a row was born past the cap" "rc=$i_rc rows=$i_rows"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
