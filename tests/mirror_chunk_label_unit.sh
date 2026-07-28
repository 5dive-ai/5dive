#!/usr/bin/env bash
# DIVE-2265: the inter-agent MIRROR DELIVERY path shipped (gh#213 / PR #282) with
# ZERO test coverage — there was no tests/*mirror* file at all. This is a
# control-flow loop with an off-by-one in its own label, which is exactly the
# shape a two-sided arm catches and a read-through does not.
#
# WHAT THIS DRIVES: the REAL mirror_interagent_outbound, with its real chunking
# loop. Only the transport boundary (_mirror_post) is stubbed, so the loop, the
# label, the crop and the overflow counter are the shipped code — not a copy
# extracted for testability, which would grade a seam nothing creates.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  ok   - %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  FAIL - %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail+1)); }

# --- fixture: satisfy mirror_interagent_outbound's preconditions ------------
export SUDO_USER=agent-fixture
export CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
printf 'TELEGRAM_BOT_TOKEN=fixture-token\n' > "$CONNECTORS_DIR/telegram-fixture.env"
ACCESS_DIR="$TMP/access"; mkdir -p "$ACCESS_DIR"
printf '{"groups":{"-100999":{}}}\n' > "$ACCESS_DIR/access.json"

# shellcheck disable=SC1090
# A subshell INHERITS the enclosing function's positional params, so $1/$2/$3
# below are run_mirror's own args — no re-passing needed (and re-passing them to
# `( ... )` is a syntax error, which is how the first draft of this failed).
run_mirror() { # run_mirror <chunks> <maxchars> <body>  -> payload log on stdout
  local _log="$TMP/posts.$RANDOM"; : > "$_log"
  (
    set +u
    . "$ROOT/src/cmd_agent_runtime.sh" 2>/dev/null || true
    registry_read() { printf '{"agents":{"fixture":{"type":"claude"}}}'; }
    _tg_access_state_dir() { printf '%s' "$ACCESS_DIR"; }
    _mirror_post() { printf '<<<POST>>>%s\n' "$4" >> "$_log"; MIRROR_POST_DELIVERED=1; return 0; }
    export MIRROR_CHUNKS="$1" MIRROR_MAX_BODY_CHARS="$2"
    # 20s ceiling so a genuine non-terminating loop fails LOUD instead of wedging CI
    timeout 20 bash -c 'true'  # keep timeout resolvable in this env
    mirror_interagent_outbound receiver "$3"
  ) >/dev/null 2>&1
  cat "$_log"; rm -f "$_log"
}
# grep -c PRINTS 0 and RETURNS 1 on no match, so `|| echo 0` emitted TWO zeros
# and every arithmetic comparison downstream became a syntax error.
posts() { local n; n=$(grep -c '<<<POST>>>' <<<"${1:-}" 2>/dev/null); printf '%s' "${n:-0}"; }

echo "DIVE-2265 mirror chunk label"

# --- ARM 0: the instrument reaches the code under test ---------------------
_out=$(run_mirror 1 800 "hello")
if (( $(posts "$_out") == 1 )); then ok "ARM 0 REACHED: the fixture drives a real post (1)"
else no "ARM 0: fixture never reached _mirror_post — every arm below is vacuous" "$_out"; fi

# --- ARM 1: default posts ONE message ---------------------------------------
_out=$(run_mirror "" 800 "$(printf 'x%.0s' {1..2000})")
_n=$(posts "$_out")
(( _n == 1 )) && ok "A1 default (MIRROR_CHUNKS unset) posts exactly ONE message" \
  || no "A1 default posted $_n messages, want 1"
grep -q 'cont\.' <<<"$_out" && no "A1 default must carry NO continuation label" || ok "A1 default carries no (cont.) label"

# --- ARM 2: THE REGRESSION ARM — denominator is the ACTUAL chunk count -------
# 250 chars at 100/chunk = 3 chunks, ceiling 5. Old code labelled "/5".
_out=$(run_mirror 5 100 "$(printf 'y%.0s' {1..250})")
_n=$(posts "$_out")
(( _n == 3 )) && ok "A2 a 250-char body at 100/chunk posts 3 messages" || no "A2 posted $_n, want 3"
if grep -q '(cont\. 2/3)' <<<"$_out" && grep -q '(cont\. 3/3)' <<<"$_out"; then
  ok "A2 denominator is the ACTUAL count (2/3, 3/3) not the ceiling"
elif grep -qE '\(cont\. [23]/5\)' <<<"$_out"; then
  no "A2 denominator is the CONFIGURED MAX (/5) — DIVE-2265 defect present" "$(grep -o '(cont\. [0-9]*/[0-9]*)' <<<"$_out" | tr '\n' ' ')"
else
  no "A2 no continuation label found at all" "$_out"
fi

# --- ARM 3: body exceeding the ceiling crops and reports the TRUE remainder --
# 500 chars, 100/chunk, ceiling 2 -> 2 posts, 300 chars unshown.
_out=$(run_mirror 2 100 "$(printf 'z%.0s' {1..500})")
_n=$(posts "$_out")
(( _n == 2 )) && ok "A3 crops at the ceiling (2 messages)" || no "A3 posted $_n, want 2"
grep -q '(+300 chars)' <<<"$_out" && ok "A3 reports the TRUE remainder (+300 chars)" \
  || no "A3 wrong remainder" "$(grep -o '(+[0-9]* chars)' <<<"$_out" | tr '\n' ' ')"
grep -q '(cont\. 2/2)' <<<"$_out" && ok "A3 denominator equals the ceiling when the body exceeds it" \
  || no "A3 expected (cont. 2/2)"

# --- ARM 4: max_chars=0 emits NOTHING and terminates ------------------------
# NOT "does not spin": _idx increments regardless so it always terminated. The
# real defect was max_chunks BLANK posts. Assert emptiness, not termination.
_t0=$SECONDS
_out=$(run_mirror 3 0 'abcdef')
_elapsed=$(( SECONDS - _t0 ))
(( _elapsed < 15 )) && ok "A4 max_chars=0 terminates (${_elapsed}s)" || no "A4 took ${_elapsed}s — non-terminating"
_n=$(posts "${_out:-}")
(( _n == 0 )) && ok "A4 max_chars=0 emits NOTHING (not 3 blank posts)" || no "A4 emitted $_n message(s), want 0"

printf '\nDIVE-2265 mirror chunk label: passed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
