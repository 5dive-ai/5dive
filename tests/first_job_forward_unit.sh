#!/usr/bin/env bash
# DIVE-9328 — the owner's first job at hire (DIVE-5874) left core for
# hosted@5dive-plugins (its harness went with it: 5dive-plugins
# tests/hosted_first_job_unit.sh). What core keeps, pinned here:
#
#   R1-R6  `5dive task record-done`: a task BORN DONE from one JSON object on
#          stdin (the plugin's only way onto the board; it never writes core's
#          schema). R1 the row: done, assigned, result verbatim, created_by,
#          started_at from startedAt, done_at stamped, the ident printed (JSON:
#          {ident}); R2 startedAt optional; R3 every bad field refused with
#          nothing written; R4 argv refused (fields go on stdin only); R5 not
#          root -> E_PERMISSION, nothing written; R6 `--help` answers its usage.
#   F1-F4  `agent first-job` / `agent _first_job_run` forward unchanged to the
#          plugin's `first-job` verb, official plugin only: F1 the start's argv,
#          F2 the unit's body as `_run <argv>`, F3 another plugin claiming the
#          verb is never run, F4 no plugin -> E_NOT_INSTALLED with one line.
#   W1-W3  wiring: both agent arms call the forward; the module, its build.sh
#          entry and its harness are gone; the usage keeps the API's spelling.
#   NC1    NEGATIVE CONTROL: a forward without the official-plugin check is
#          CAUGHT by F3.
# Run: bash tests/first_job_forward_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/first-job-forward.XXXXXX")"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e; tasks_db_init >/dev/null 2>&1
REAL_REQUIRE_ROOT=$(declare -f require_root)
require_root() { :; }

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# rd <json> [args…] — `task record-done` in a subshell (fail() exits). Sets OUT, ERR, RC.
rd() { local in="$1"; shift; ( cmd_task record-done "$@" ) <<<"$in" >"$TMP/out" 2>"$TMP/err"; RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err"); }
rows() { sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM tasks;"; }
REPLY_TXT=$'**Your week**\n- Mon: "focus" — it\'s yours'
GOOD=$(jq -cn --arg r "$REPLY_TXT" '{title:"Plan my week", body:"Your first job for ada, picked when you hired it.", assignee:"ada", from:"telegram", result:$r, startedAt:"2026-10-08T10:00:00Z"}')

# ── R1: the row ──────────────────────────────────────────────────────────────
rd "$GOOD"
ID1=$(sqlite3 "$TASKS_DB" "SELECT ident FROM tasks ORDER BY id DESC LIMIT 1;")
row=$(sqlite3 -separator '|' "$TASKS_DB" "SELECT title, assignee, status, created_by, priority, started_at, first_started_at, (done_at IS NOT NULL) FROM tasks WHERE ident='$ID1';")
res=$(sqlite3 "$TASKS_DB" "SELECT result FROM tasks WHERE ident='$ID1';")
{ [[ $RC -eq 0 && "$OUT" == "OK — $ID1" && "$(rows)" == 1 && "$res" == "$REPLY_TXT" ]] \
  && [[ "$row" == "Plan my week|ada|done|telegram|medium|2026-10-08 10:00:00|2026-10-08 10:00:00|1" ]]; } \
  && ok_t "R1 one row born done: assigned, created_by=from, result verbatim, started_at = startedAt, done_at stamped; its ident printed" \
  || bad_t "R1 row" "rc=$RC out=$OUT row=$row err=$ERR"
JSON_MODE=1 rd "$GOOD"
[[ $RC -eq 0 && "$(jq -r '.ok, (.data.ident | test("^[A-Z]+-[0-9]+$"))' <<<"$OUT" | tr '\n' ' ')" == "true true " && "$(rows)" == 2 ]] \
  && ok_t "R1b JSON mode answers {ok:true, data:{ident}}" || bad_t "R1b json" "rc=$RC out=$OUT"

# ── R2: startedAt is optional ────────────────────────────────────────────────
rd "$(jq -c 'del(.startedAt)' <<<"$GOOD")"
[[ $RC -eq 0 && "$(sqlite3 "$TASKS_DB" "SELECT started_at IS NOT NULL AND started_at > '2026-10-09' FROM tasks ORDER BY id DESC LIMIT 1;")" == 1 ]] \
  && ok_t "R2 without startedAt the row is stamped now" || bad_t "R2 no startedAt" "rc=$RC err=$ERR"

# ── R3: bad fields refused, nothing written ──────────────────────────────────
before=$(rows); r3=()
for bad in '.title = "  "' '.result = ""' '.assignee = "Ada;rm"' 'del(.assignee)' '.from = "Tele gram"' \
           '.startedAt = "yesterday"' '.startedAt = "2026-10-08 10:00:00"'; do
  rd "$(jq -c "$bad" <<<"$GOOD")"
  [[ $RC -eq $E_VALIDATION ]] || r3+=("$bad rc=$RC")
done
for raw in 'not json' '["a list"]' ''; do
  rd "$raw"; [[ $RC -eq $E_USAGE ]] || r3+=("'$raw' rc=$RC")
done
[[ ${#r3[@]} -eq 0 && "$(rows)" == "$before" ]] \
  && ok_t "R3 blank title/result, bad assignee/from/startedAt (7) and non-object stdin (3) are refused; nothing written" \
  || bad_t "R3 validation" "${r3[*]} rows $before -> $(rows)"

# ── R4: argv is refused ──────────────────────────────────────────────────────
rd "$GOOD" --title=x
[[ $RC -eq $E_USAGE && "$(rows)" == "$before" && "$ERR" == *"JSON on stdin"* ]] \
  && ok_t "R4 any argument is E_USAGE: the fields go on stdin only" || bad_t "R4 argv" "rc=$RC err=$ERR"

# ── R5: root only ────────────────────────────────────────────────────────────
if (( EUID == 0 )); then
  ok_t "R5 SKIPPED as root: the not-root refusal cannot be observed here (CI runs it unprivileged)"
else
  ( eval "$REAL_REQUIRE_ROOT"; unset FIVE_ARGV; cmd_task record-done ) <<<"$GOOD" >"$TMP/out" 2>"$TMP/err"; RC=$?
  [[ $RC -eq $E_PERMISSION && "$(rows)" == "$before" ]] \
    && ok_t "R5 not root: E_PERMISSION, nothing written" || bad_t "R5 root" "rc=$RC err=$(cat "$TMP/err")"
fi

# ── R6: help ─────────────────────────────────────────────────────────────────
( cmd_task record-done --help ) >"$TMP/out" 2>&1; RC=$?
[[ $RC -eq 0 && "$(head -1 "$TMP/out")" == "usage: 5dive task record-done"* ]] \
  && ok_t "R6 'task record-done --help' answers its own usage, rc 0" || bad_t "R6 help" "rc=$RC $(head -2 "$TMP/out")"

# ── F: the forward ───────────────────────────────────────────────────────────
FWD="$TMP/forward.sh"
sed -n '/^_first_job_forward() {/,/^}/p' src/main.sh >"$FWD"
# f <claims> <argv…> — run the extracted forward against a stubbed plugin table;
# the stub dispatch records its argv and exits (the real one execs).
f() {
  local claims="$1"; shift
  ( _plugin_verb_claims() { [[ "$1" == first-job ]] && printf '%s' "$claims"; }
    _plugin_dispatch_verb() { printf '%s\n' "$@" >"$TMP/dispatch"; exit 0; }
    # shellcheck source=/dev/null
    source "$FWD"; _first_job_forward "$@" ) >"$TMP/out" 2>"$TMP/err"; RC=$?
}
TOK="AbCdEfGhIjKlMnOpQr_s-1"
rm -f "$TMP/dispatch"; f hosted@5dive-plugins ada --token="$TOK" --job-b64=UGxhbg==
[[ $RC -eq 0 && "$(cat "$TMP/dispatch")" == "$(printf '%s\n' first-job ada --token="$TOK" --job-b64=UGxhbg==)" ]] \
  && ok_t "F1 'agent first-job <argv>' -> the plugin's 'first-job <argv>', unchanged" || bad_t "F1 start" "rc=$RC $(cat "$TMP/dispatch" 2>/dev/null)"
rm -f "$TMP/dispatch"; f hosted@5dive-plugins _run ada "$TOK"
[[ $RC -eq 0 && "$(cat "$TMP/dispatch")" == "$(printf '%s\n' first-job _run ada "$TOK")" ]] \
  && ok_t "F2 'agent _first_job_run <argv>' -> 'first-job _run <argv>' (units started before the move resolve)" || bad_t "F2 run" "rc=$RC $(cat "$TMP/dispatch" 2>/dev/null)"
f3_arm() { rm -f "$TMP/dispatch"; f first-job@someone-else ada --token="$TOK" --job-b64=x; [[ ! -e "$TMP/dispatch" && $RC -eq $E_NOT_INSTALLED ]]; }
f3_arm && ok_t "F3 a non-official plugin claiming first-job is never run (it would run as root)" || bad_t "F3 official only" "rc=$RC dispatched=$(cat "$TMP/dispatch" 2>/dev/null)"
rm -f "$TMP/dispatch"; f "" ada --token="$TOK" --job-b64=x
[[ $RC -eq $E_NOT_INSTALLED && ! -e "$TMP/dispatch" && "$(cat "$TMP/err")" == *"comes with a 5dive-built box (plugin hosted@5dive-plugins)"* ]] \
  && ok_t "F4 no plugin: E_NOT_INSTALLED, one line naming the plugin" || bad_t "F4 missing" "rc=$RC err=$(cat "$TMP/err")"

# ── W: wiring ────────────────────────────────────────────────────────────────
arm=$(awk '/^_agent_verb_dispatch\(\) \{/{f=1} f&&/^\}/{exit} f' src/main.sh)
fj_arm=$(grep -A2 -E '^        first-job\)' <<<"$arm"); fjr_arm=$(grep -A2 -E '^        _first_job_run\)' <<<"$arm")
{ grep -q '_first_job_forward "\$@"' <<<"$fj_arm" \
  && grep -q '_first_job_forward _run "\$@"' <<<"$fjr_arm"; } \
  && ok_t "W1 both agent arms forward (first-job, _first_job_run)" || bad_t "W1 arms" ""
{ [[ ! -e src/cmd_agent_first_job.sh && ! -e tests/agent_first_job_unit.sh ]] \
  && ! grep -q cmd_agent_first_job <<<"$(sed -n '/^LAZY_FILES=(/,/^)/p' build.sh)" \
  && ! grep -rqE 'cmd_agent_first_job|_first_job_(ask|watch|task|spawn)' src; } \
  && ok_t "W2 the module, its build.sh entry and its harness are gone, and nothing in src calls into it" || bad_t "W2 gone" ""
grep -q '^  5dive agent first-job <name> --token=' src/main.sh && ok_t "W3 the agent usage keeps the API's spelling" || bad_t "W3 usage" ""

# ── NC1: F3 can go red ───────────────────────────────────────────────────────
sed 's/if \[\[ "$(_plugin_verb_claims first-job 2>\/dev\/null)" == "hosted@5dive-plugins" \]\]; then/if [[ -n "$(_plugin_verb_claims first-job 2>\/dev\/null)" ]]; then/' "$FWD" >"$TMP/fwd.mut"
if cmp -s "$FWD" "$TMP/fwd.mut"; then bad_t "NC1 mutation did not apply" ""
else
  FWD_REAL="$FWD"; FWD="$TMP/fwd.mut"
  f3_arm && bad_t "NC1 a forward without the official check passes F3 — the check cannot go red" "" \
         || ok_t "NC1 a forward without the official-plugin check is CAUGHT by F3"
  FWD="$FWD_REAL"
fi

echo "-----"
echo "TESTS pass=$pass fail=$fail"
(( fail == 0 ))
