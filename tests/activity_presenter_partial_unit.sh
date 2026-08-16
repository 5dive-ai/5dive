#!/usr/bin/env bash
# DIVE-3421 unit: the PARTIAL banner in `cmd_activity` — the surface DIVE-3419's
# `.partial` contract exists to produce.
#
# WHAT THIS GUARDS, and why the sibling harness does not already guard it.
# DIVE-3419 gave activity_collect a REPORTING contract: it emits the trail and
# names, in `.partial`, every level it could not read; cmd_activity prints that
# above the counts so a short trail can never be mistaken for a quiet one.
# tests/usage_middle_wildcard_unit.sh grades the COLLECTOR seam — it asserts the
# JSON field, in python, from a fixture tree. It cannot see the presenter: the
# banner is bash+jq, and cmd_activity calls require_root, so it was undrivable
# from the seat that wrote it. A `.partial` that is populated correctly and never
# rendered is the same silence DIVE-3419 exists to remove, and a jq typo in the
# banner would be caught by nothing. That is this file.
#
# WHY THIS SHAPE (the DIVE-1937 presenter-seam precedent, applied):
#   * ANY UID. The collector's defect is uid-dependent; the PRESENTER's is not.
#     These arms feed the real cmd_activity synthetic collector output, so root
#     and an unprivileged seat run identical assertions and require_root is
#     stubbed rather than worked around.
#   * THE REAL VERB, NOT A COPY. src/cmd_usage.sh is sourced and cmd_activity is
#     driven with only activity_collect stubbed. A guard written one layer away
#     from where the bug lives passes while the defect is present (DIVE-1914).
#   * ANCHOR FIRST. Arms 1-2 assert a complete render with specific NON-ZERO
#     numbers before anything asserts an ABSENCE. Every "no banner" arm below is
#     vacuous while the anchor is red — a cmd_activity that died on line one also
#     prints no banner.
#   * THE IDLE CASE IS NOT PADDING. An unread level whose trail is EMPTY is the
#     one a reader is most likely to misread as "this agent did nothing", so it
#     gets its own arms.
#
# NEGATIVE CONTROL (how to re-run it):
#   mkdir -p /tmp/prebanner
#   git show origin/main:src/cmd_usage.sh > /tmp/prebanner/cmd_usage.sh
#   USAGE_SRC_DIR=/tmp/prebanner bash tests/activity_presenter_partial_unit.sh  # must FAIL
#
#   The pre-banner cmd_activity is otherwise IDENTICAL to this one, so the
#   control does not merely error out: the anchor and trail arms still pass and
#   only the banner arms red. A control that cannot reach the assertions grades
#   nothing.
#
#   bash tests/activity_presenter_partial_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the obvious hardening also swallows the
# helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

SRC_DIR="${USAGE_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/activity-partial.XXXXXX)"
NOW="$(date +%s)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { grep -qF -- "$2" <<<"$1"; }

# --- harness: the real presenter, with only the SOURCE stubbed ---------------
# shellcheck disable=SC1091
source src/lib/error_codes.sh 2>/dev/null || true
: "${E_USAGE:=2}"; : "${E_GENERIC:=1}"; : "${E_VALIDATION:=3}"; : "${E_NOT_FOUND:=4}"
JSON_MODE=0
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
fail() { printf 'error: %s\n' "${2:-}" >&2; exit "${1:-1}"; }
# shellcheck disable=SC1090
source "$SRC_DIR/cmd_usage.sh"
ensure_state()  { :; }
require_root()  { :; }          # the reason this seam was untested; not the subject
tasks_db_init() { :; }
sqlq()          { printf "'%s'" "${1:-}"; }
db()            { printf '%s||gamma|a task title\n' "$((NOW-3600))"; }
activity_collect() { printf '%s\n' "$DATA"; }

# collector output for agent `gamma`: a real trail (2 edits, 1 command, 3 reads,
# 4 turns) that some number of unread levels may be SHORT of.
LVL1='project dir /home/agent-gamma/.claude/projects/p-two unreadable: Permission denied'
LVL2='transcript /home/agent-gamma/.claude/projects/p-one/s.jsonl unreadable: Permission denied'
LVL3='transcript dir /home/agent-gamma/.claude/projects unreadable: Permission denied'

mk_data() {  # mk_data <clean|partial|nofield|idle-partial>
  local partial trail
  case "$1" in
    clean)        partial='[]' ;;
    nofield)      partial='null' ;;   # an older collector's JSON: no field at all
    *)            partial="$(jq -cn --arg a "$LVL1" --arg b "$LVL2" --arg c "$LVL3" '[$a,$b,$c]')" ;;
  esac
  case "$1" in
    idle-partial) trail='{files:[],reads:[],commands:[],skills:[],
                          counts:{bash:0,edit:0,write:0,multiedit:0,notebook:0,read:0,turns:0},
                          tokens:{total:0,output:0}}' ;;
    *)            trail='{files:[{path:"/w/src/cmd_usage.sh",edits:2,last:1755300000}],
                          reads:[{path:"/w/README.md",count:3}],
                          commands:[{ts:1755300000,cmd:"echo one",desc:"the first command"}],
                          skills:[{name:"compile-knowledge",fires:1,cold:0}],
                          counts:{bash:1,edit:2,write:0,multiedit:0,notebook:0,read:3,turns:4},
                          tokens:{total:123456,output:1000}}' ;;
  esac
  jq -cn --argjson p "$partial" "{agent:\"gamma\",window:{since:0,now:1}} + $trail
          + (if \$p==null then {} else {partial:\$p} end)"
}

run_activity() {  # run_activity [args...] -> stdout in OUT, stderr in ERR, rc in RC
  OUT="$(cmd_activity "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}

# --- 1. ANCHOR: a complete read renders the real trail -----------------------
# Asserted with SPECIFIC non-zero numbers, first, so that every absence arm
# below is a statement about the banner and not about a dead renderer.
DATA="$(mk_data clean)"; run_activity gamma
{ [[ $RC -eq 0 ]] && has "$OUT" "files touched: 1 (2 edits)" && has "$OUT" "commands: 1" \
  && has "$OUT" "reads: 3" && has "$OUT" "turns: 4"; } \
  && ok_t "anchor: a complete read renders the counts line with its real numbers (rc=0)" \
  || bad_t "anchor render (rc=$RC)" "$OUT${ERR:+ | stderr: $ERR}"
{ has "$OUT" "2×  /w/src/cmd_usage.sh" && has "$OUT" "the first command" \
  && has "$OUT" "1×  compile-knowledge"; } \
  && ok_t "anchor: the trail itself renders (files, skills, commands)" || bad_t "anchor trail" "$OUT"

# --- 2. a COMPLETE read gets no banner (coverage is not noise) ---------------
! has "$OUT" "PARTIAL" \
  && ok_t "clean: an empty .partial prints no banner" || bad_t "banner on a complete read" "$OUT"
[[ -z "$ERR" ]] \
  && ok_t "clean: nothing on stderr" || bad_t "clean stderr" "$ERR"

# --- 3. the banner itself ----------------------------------------------------
DATA="$(mk_data partial)"; run_activity gamma
has "$OUT" "PARTIAL" \
  && ok_t "partial: the banner is printed at all (the honesty surface exists)" || bad_t "no banner" "$OUT"
# STDOUT, not stderr: a warning on the other stream is gone the moment anyone
# pipes or redirects the trail it qualifies.
{ has "$OUT" "PARTIAL" && ! grep -qF "PARTIAL" <<<"$ERR"; } \
  && ok_t "partial: the banner rides on STDOUT, with the numbers it qualifies" \
  || bad_t "banner stream" "stdout: $OUT | stderr: $ERR"
has "$OUT" "3 level(s) could not be read" \
  && ok_t "partial: the banner carries the COUNT, and it is the array's length (3)" \
  || bad_t "banner count" "$OUT"
has "$OUT" "SHORT of the truth, not low" \
  && ok_t "partial: it says the counts are SHORT of the truth, not merely low" || bad_t "banner wording" "$OUT"
# every named level, verbatim: a banner that prints only the first one is a
# banner that hides two blind spots while looking like a fix.
{ has "$OUT" "$LVL1" && has "$OUT" "$LVL2" && has "$OUT" "$LVL3"; } \
  && ok_t "partial: every unread level is NAMED verbatim, not just the first" || bad_t "named levels" "$OUT"
[[ "$(grep -cE '^ +(project dir|transcript)' <<<"$OUT")" -eq 3 ]] \
  && ok_t "partial: the levels are three indented lines under the banner, not one blob" \
  || bad_t "level layout" "$OUT"
# position: a coverage line printed after the table is a footnote. BOTH line
# numbers must EXIST — an absent banner leaves an empty string, which bash reads
# as 0 in an arithmetic test and would pass this vacuously.
BAN_LN="$(grep -n 'PARTIAL'       <<<"$OUT" | head -1 | cut -d: -f1)"
CNT_LN="$(grep -n 'files touched' <<<"$OUT" | head -1 | cut -d: -f1)"
{ [[ -n "$BAN_LN" && -n "$CNT_LN" ]] && (( BAN_LN < CNT_LN )); } \
  && ok_t "partial: the banner prints BEFORE the counts it qualifies" \
  || bad_t "banner position (banner=$BAN_LN counts=$CNT_LN)" "$OUT"

# --- 4. a REPORTING contract, not a fail-closed one --------------------------
# DIVE-3419 decided this reader owes a reporting contract, not the NOT-REACHED
# refusal its spend-scanning sibling owes: refusing to render 40 commands over
# one mode-000 dir destroys the surface. So the trail must survive the banner.
{ [[ $RC -eq 0 ]] && has "$OUT" "files touched: 1 (2 edits)" && has "$OUT" "2×  /w/src/cmd_usage.sh" \
  && has "$OUT" "the first command"; } \
  && ok_t "partial: the trail is still RENDERED (report, do not refuse) and rc=0" \
  || bad_t "partial suppressed the trail (rc=$RC)" "$OUT"

# --- 5. the idle case: 0 is what reads as quiet ------------------------------
DATA="$(mk_data idle-partial)"; run_activity gamma
{ has "$OUT" "PARTIAL" && has "$OUT" "files touched: 0"; } \
  && ok_t "idle: an EMPTY trail with an unread level still warns (0 is not 'did nothing')" \
  || bad_t "idle banner" "$OUT"
has "$OUT" "(none)" \
  && ok_t "idle: the empty sections still render their placeholders" || bad_t "idle placeholders" "$OUT"

# --- 6. over-fire control: a collector that never reported the field ---------
DATA="$(mk_data nofield)"; run_activity gamma
{ [[ $RC -eq 0 ]] && ! has "$OUT" "PARTIAL" && has "$OUT" "files touched: 1 (2 edits)"; } \
  && ok_t "no .partial field at all: no banner, no crash, trail intact (rc=0)" \
  || bad_t "missing-field handling (rc=$RC)" "$OUT${ERR:+ | stderr: $ERR}"

# --- 7. --json: the machine-readable half ------------------------------------
DATA="$(mk_data partial)"; JSON_MODE=1; run_activity gamma; JSON_MODE=0
[[ "$(jq -r '.data.partial|length' <<<"$OUT" 2>/dev/null)" == "3" ]] \
  && ok_t "--json: .partial travels with the counts it shortened" || bad_t "json partial" "$OUT"
[[ "$(jq -r '.data.partial[0]' <<<"$OUT" 2>/dev/null)" == "$LVL1" ]] \
  && ok_t "--json: the named causes survive the presenter unmangled" || bad_t "json cause" "$OUT"
# the banner is a HUMAN surface. Printed into --json it would corrupt the stream
# for every caller that pipes it into jq.
{ ! has "$OUT" "PARTIAL —" && jq -e . <<<"$OUT" >/dev/null 2>&1; } \
  && ok_t "--json: no banner text in the stream (it stays parseable)" || bad_t "json banner leak" "$OUT"

# --- 8. the --task window takes the same banner ------------------------------
# the task branch only swaps the LABEL; a banner that lived inside the rolling
# -window branch would go quiet on exactly the view a reviewer opens.
DATA="$(mk_data partial)"; run_activity gamma --task=DIVE-0000
{ [[ $RC -eq 0 ]] && has "$OUT" "PARTIAL" && has "$OUT" "a task title"; } \
  && ok_t "--task: the banner prints on the task-clipped view too (rc=0)" \
  || bad_t "task-window banner (rc=$RC)" "$OUT${ERR:+ | stderr: $ERR}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
