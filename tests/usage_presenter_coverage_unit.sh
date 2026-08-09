#!/usr/bin/env bash
# DIVE-1937 unit: every presenter that renders a usage_collect number must also
# render what that read COVERED.
#
# The bug this guards: DIVE-1929 taught usage_collect to report coverage and
# taught exactly ONE consumer (proof scorecard's tokens row) to respect it. The
# field then rode in the JSON on every collect while `5dive usage`, `5dive cost`,
# `usage budget check` and the digest kept printing the same confident tables —
# a collected-but-unrendered field is not a fix, it is a fix that has not shipped
# (the shape that left DIVE-1908's TODAY_LABEL sitting unused).
#
# WHY THIS SHAPE:
#   * ANY UID. The defect is caller-dependent, but the GUARD must not be: these
#     assertions feed the real presenters synthetic collector output, so root and
#     agent-dev3 run identical assertions. A chmod-based test is inert as root.
#   * THE REAL VERBS, NOT A COPY. src/cmd_usage.sh is sourced and cmd_cost /
#     usage_render_board / cmd_usage_budget_check are driven with usage_collect
#     stubbed — the DIVE-1914 lesson is that a guard written one layer away from
#     where the bug lives passes while the defect is present.
#   * THE SHELL LAYER TOO. The digest's failure was in a bash fallback string
#     that erased the failure before python ever saw it; a python-only test
#     structurally cannot see that, so the fallback is asserted directly.
#
# NEGATIVE CONTROL (how to re-run it):
#   mkdir -p /tmp/prefix && git show origin/main~1:src/cmd_usage.sh  > /tmp/prefix/cmd_usage.sh
#   git show origin/main~1:src/cmd_digest.sh > /tmp/prefix/cmd_digest.sh
#   USAGE_SRC_DIR=/tmp/prefix bash tests/usage_presenter_coverage_unit.sh   # must FAIL
#
#   bash tests/usage_presenter_coverage_unit.sh
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

SRC_DIR="${USAGE_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/usage-presenter.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { grep -qF -- "$2" <<<"$1"; }

# --- harness: the real presenters, with only the SOURCES stubbed -------------
# shellcheck disable=SC1091
source src/lib/error_codes.sh 2>/dev/null || { E_USAGE=2; E_GENERIC=1; E_PERMISSION=77; }
JSON_MODE=0
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
fail() { printf 'error: %s\n' "${2:-}" >&2; exit "${1:-1}"; }
# shellcheck disable=SC1090
source "$SRC_DIR/cmd_usage.sh"
ensure_state()  { :; }
require_root()  { :; }
usage_budget_load() { printf '%s\n' "${BUDGETS:-{\}}"; }
usage_budget_save() { cat >/dev/null; }
usage_resolve_owner_channel() { return 1; }
_task_send_owner() { :; }
usage_collect() { printf '%s\n' "$DATA"; }
USAGE_BUDGET_STATE_FILE="$TMP/budget-state.json"

# collector output: 3 agents expected, `gamma` unreadable, coverage says so.
mk_data() {  # mk_data <complete|partial|nocoverage|partial-row>
  local cov agents
  agents='[{"name":"alpha","account":"a","models":{"m":{"in":10,"out":10,"cc":0,"cr":0,"turns":1}},"total":100,"output":50,"cacheRead":0,"sevenDayPct":10,"fiveHourPct":5},
           {"name":"beta","account":"a","models":{"m":{"in":10,"out":10,"cc":0,"cr":0,"turns":1}},"total":100,"output":50,"cacheRead":0,"sevenDayPct":10,"fiveHourPct":5}]'
  case "$1" in
    complete)  cov='{"agentsExpected":2,"agentsRead":2,"unreadable":[],"complete":true}' ;;
    partial)   cov='{"agentsExpected":3,"agentsRead":2,"unreadable":[{"name":"gamma","reason":"transcript dir not readable by this user (needs root)"}],"complete":false}' ;;
    partial-row)
      # gamma IS in the rows but some of its files were denied: its number is a floor.
      agents="$(jq -c '. + [{"name":"gamma","account":"a","models":{"m":{"in":1,"out":1,"cc":0,"cr":0,"turns":1}},"total":7,"output":3,"cacheRead":0,"sevenDayPct":1,"fiveHourPct":1}]' <<<"$agents")"
      cov='{"agentsExpected":3,"agentsRead":3,"unreadable":[{"name":"gamma","reason":"some transcript files unreadable: Permission denied"}],"complete":false}' ;;
    nocoverage) cov='null' ;;
  esac
  jq -cn --argjson a "$agents" --argjson c "$cov" \
    '{window:{since:0,now:1},agents:$a,tasks:[],untracked:{}} + (if $c==null then {} else {coverage:$c} end)'
}

# --- 1. `5dive usage` board -------------------------------------------------
DATA="$(mk_data complete)"; OUT="$(usage_render_board "$DATA" 24h '{}' 2>&1)"
{ ! has "$OUT" "PARTIAL READ" && ! has "$OUT" "COVERAGE UNKNOWN"; } \
  && ok_t "board: a COMPLETE read renders no banner (coverage is not noise)" \
  || bad_t "board banner on complete read" "$OUT"

DATA="$(mk_data partial)"; OUT="$(usage_render_board "$DATA" 24h '{}' 2>&1)"
has "$OUT" "PARTIAL READ" \
  && ok_t "board: a PARTIAL read is declared, not silently short" || bad_t "board partial banner" "$OUT"
has "$OUT" "2 of 3" \
  && ok_t "board: the banner carries the coverage COUNT (2 of 3)" || bad_t "board count" "$OUT"
has "$OUT" "gamma" \
  && ok_t "board: the unreadable agent is NAMED in the banner" || bad_t "board names blind spot" "$OUT"
# position matters: a coverage line printed after the table is a footnote.
# Both line numbers must EXIST — an absent banner leaves an empty string, which
# bash reads as 0 in an arithmetic test and would pass this vacuously (the
# DIVE-1914 vacuous-pass trap).
BAN_LN="$(grep -n 'PARTIAL READ' <<<"$OUT" | head -1 | cut -d: -f1)"
TAB_LN="$(grep -n 'TOP AGENTS'   <<<"$OUT" | head -1 | cut -d: -f1)"
{ [[ -n "$BAN_LN" && -n "$TAB_LN" ]] && (( BAN_LN < TAB_LN )); } \
  && ok_t "board: coverage prints BEFORE the numbers it qualifies" || bad_t "banner position" "$OUT"

DATA="$(mk_data nocoverage)"; OUT="$(usage_render_board "$DATA" 24h '{}' 2>&1)"
has "$OUT" "COVERAGE UNKNOWN" \
  && ok_t "board: an UNLABELLED total counts as partial, not as complete" || bad_t "board unknown coverage" "$OUT"

# --- 2. `5dive usage <agent>` — the named-agent lie --------------------------
DATA="$(mk_data partial)"
OUT="$( ( usage_render_agent "$DATA" gamma 24h ) 2>&1 )"; RC=$?
[[ $RC -ne 0 ]] && ! has "$OUT" "no usage for agent" \
  && ok_t "agent view: an unreadable agent is NOT reported as 'no usage'" \
  || bad_t "unreadable agent still reads as idle (rc=$RC)" "$OUT"
has "$OUT" "no visibility" \
  && ok_t "agent view: the error names the real cause (no visibility, needs root)" || bad_t "cause" "$OUT"

DATA="$(mk_data partial-row)"; OUT="$( ( usage_render_agent "$DATA" gamma 24h ) 2>&1 )"
{ has "$OUT" "PARTIAL" && has "$OUT" "FLOOR"; } \
  && ok_t "agent view: a partly-denied agent's own total is marked a FLOOR" || bad_t "floor marker" "$OUT"

# --- 3. `5dive cost` — the row that says 'ok' about an agent it never read ---
DATA="$(mk_data partial)"; JSON_MODE=0
OUT="$(cmd_cost 2>&1)"
has "$OUT" "gamma" \
  && ok_t "cost: an unreadable agent still gets a ROW (it does not vanish)" || bad_t "cost row missing" "$OUT"
grep -qE 'gamma.*UNREADABLE' <<<"$OUT" \
  && ok_t "cost: that row reads UNREADABLE, never 'ok'" || bad_t "cost row state" "$OUT"
# positive AND negative: the row must SHOW '?' (a missing row would satisfy the
# negative half on its own, which is how a vacuous guard is born).
{ grep -qE 'gamma +\?' <<<"$OUT" && ! grep -qE 'gamma +0( |$)' <<<"$OUT"; } \
  && ok_t "cost: an unread burn renders '?', not a confident 0" || bad_t "cost zero burn" "$OUT"
JSON_MODE=1; OUTJ="$(cmd_cost 2>&1)"; JSON_MODE=0
[[ "$(jq -r '.data.coverage.complete' <<<"$OUTJ")" == "false" ]] \
  && ok_t "cost --json: coverage travels with the rows" || bad_t "cost json coverage" "$OUTJ"
[[ "$(jq -r '.data.agents[]|select(.name=="gamma")|.readable' <<<"$OUTJ")" == "false" ]] \
  && ok_t "cost --json: the blind row is machine-readable (readable:false)" || bad_t "cost json readable" "$OUTJ"

# --- 4. `usage budget check` — a blind spot must not PASS a budget ----------
BUDGETS='{"gamma":{"soft":1000,"hard":5000,"hardStop":false,"notified":{},"stopped":false}}'
DATA="$(mk_data partial)"; JSON_MODE=0
OUT="$(cmd_usage_budget_check --dry-run 2>&1)"
has "$OUT" "NOT checked" \
  && ok_t "budget check: an unreadable budgeted agent is reported as NOT checked" || bad_t "budget note" "$OUT"
[[ "$(jq -r '.agents.gamma.state' "$USAGE_BUDGET_STATE_FILE")" == "unknown" ]] \
  && ok_t "budget check: its cached state is 'unknown', not 'ok'" \
  || bad_t "budget state" "$(cat "$USAGE_BUDGET_STATE_FILE")"
[[ "$(jq -r '.agents.gamma.burn' "$USAGE_BUDGET_STATE_FILE")" == "null" ]] \
  && ok_t "budget check: its cached burn is null, not 0 (0 is what reads as quiet)" \
  || bad_t "budget burn" "$(cat "$USAGE_BUDGET_STATE_FILE")"
# a FLOOR that already crosses the cap is still a real crossing: it must fire.
BUDGETS='{"gamma":{"soft":5,"hard":10000,"hardStop":false,"notified":{},"stopped":false}}'
DATA="$(mk_data partial-row)"
OUT="$(cmd_usage_budget_check --dry-run 2>&1)"
grep -qE '1 soft' <<<"$OUT" \
  && ok_t "budget check: a partial read that ALREADY crosses the cap still fires" || bad_t "floor crossing" "$OUT"
BUDGETS='{}'

# --- 5. digest: the SHELL fallback that erased the failure ------------------
# `usage` is root-only, so a non-root digest never even reaches the collector.
FB="$(awk '/_digest_usage_unavailable\(\) \{/,/^  \}/' "$SRC_DIR/cmd_digest.sh")"
if [[ -n "$FB" ]]; then
  eval "$FB"
  FBJ="$(_digest_usage_unavailable)"
  [[ "$(jq -r '.data.coverage.complete' <<<"$FBJ")" == "false" ]] \
    && ok_t "digest: the usage-unavailable fallback declares itself INCOMPLETE" || bad_t "fallback coverage" "$FBJ"
else
  bad_t "digest: no usage-unavailable fallback exists" "the fallback still hands python an empty agent list with no marker"
fi
grep -q '_digest_run usage --json .*|| *_digest_usage_unavailable' "$SRC_DIR/cmd_digest.sh" \
  && ok_t "digest: the usage call site USES that fallback (not a bare empty list)" \
  || bad_t "fallback not wired" "$(grep -n '_digest_run usage --json' "$SRC_DIR/cmd_digest.sh")"

# --- 6. digest presenter (the real embedded python) -------------------------
awk "/python3 - >\"\\\$tmpd\/out.txt\" <<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" "$SRC_DIR/cmd_digest.sh" > "$TMP/digest.py"
[[ -s "$TMP/digest.py" ]] || { bad_t "could not extract digest python" ""; }
printf '{"data":{"tasks":[]}}\n' > "$TMP/tasks.json"
: > "$TMP/hb.txt"; printf '[]\n' > "$TMP/sup.json"; printf '[]\n' > "$TMP/obj.json"
printf '{"data":{"loops":[]}}\n' > "$TMP/loops.json"
run_digest() {  # run_digest <usage.json> <json?>
  DIGEST_TASKS_F="$TMP/tasks.json" DIGEST_USAGE_F="$1" DIGEST_HB_F="$TMP/hb.txt" \
  DIGEST_LOOPS_F="$TMP/loops.json" DIGEST_SUP_F="$TMP/sup.json" DIGEST_OBJ_F="$TMP/obj.json" \
  DIGEST_WINDOW=86400 DIGEST_JSON="${2:-0}" python3 "$TMP/digest.py" 2>&1
}
# 6a. the non-root case: the source could not be read AT ALL.
printf '%s\n' '{"data":{"agents":[],"tasks":[],"coverage":{"agentsExpected":null,"agentsRead":0,"unreadable":[],"complete":false,"unavailable":true,"reason":"the usage collector could not be run by this caller (5dive usage needs root)"}}}' > "$TMP/u_unavail.json"
OUT="$(run_digest "$TMP/u_unavail.json")"
has "$OUT" "Token burn UNKNOWN" \
  && ok_t "digest: an unread burn source is stated, not rendered as silence" || bad_t "digest unknown line" "$OUT"
! has "$OUT" "no rate-limit pressure" \
  && ok_t "digest: 'no rate-limit pressure' is NOT claimed on a source never read" \
  || bad_t "digest claims health from an unread source" "$OUT"
# 6b. partial read.
printf '%s\n' '{"data":{"agents":[{"name":"alpha","output":50,"fiveHourPct":5,"sevenDayPct":10}],"tasks":[],"coverage":{"agentsExpected":3,"agentsRead":1,"unreadable":[{"name":"gamma","reason":"needs root"}],"complete":false}}}' > "$TMP/u_partial.json"
OUT="$(run_digest "$TMP/u_partial.json")"
{ has "$OUT" "Token burn PARTIAL" && has "$OUT" "1 of 3" && has "$OUT" "gamma"; } \
  && ok_t "digest: a partial burn read is declared with its count and its blind spots" \
  || bad_t "digest partial line" "$OUT"
OUTJ="$(run_digest "$TMP/u_partial.json" 1)"
[[ "$(jq -r '.usageCoverage.complete' <<<"$OUTJ")" == "false" ]] \
  && ok_t "digest --json: usageCoverage rides with the usage list" || bad_t "digest json coverage" "$OUTJ"
[[ "$(jq -r '.health.hotCoverage' <<<"$OUTJ")" == "partial" ]] \
  && ok_t "digest --json: an empty 'hot' list is labelled partial, not 'nobody is hot'" \
  || bad_t "hotCoverage" "$OUTJ"
# 6c. a whole read keeps the old, earned claim.
printf '%s\n' '{"data":{"agents":[{"name":"alpha","output":50,"fiveHourPct":5,"sevenDayPct":10}],"tasks":[],"coverage":{"agentsExpected":1,"agentsRead":1,"unreadable":[],"complete":true}}}' > "$TMP/u_full.json"
OUT="$(run_digest "$TMP/u_full.json")"
{ has "$OUT" "no rate-limit pressure" && ! has "$OUT" "Token burn"; } \
  && ok_t "digest: a COMPLETE read still gets the plain healthy line (no new noise)" \
  || bad_t "digest complete read" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
