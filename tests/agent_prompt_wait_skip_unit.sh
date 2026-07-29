#!/usr/bin/env bash
# DIVE-2277 — a harness with no prompt marker must not pay the 45s prompt-wait.
#
# TWO-SIDED BY CONSTRUCTION:
#   BEHAVIOURAL — drive the real wait_agent_input_ready with a stubbed agent_type and a
#     stubbed tmux, and assert on ELAPSED TIME. A skip that still slept would pass any
#     assertion about the return code alone.
#   STRUCTURAL — assert the detectable set and the marker predicate stay in lockstep.
#     They are two lists that must agree; nothing else checks that they do.
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
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# Load just the two functions + the table, without running the CLI.
harness() {
  local want_type="$1"
  cat <<SH
agent_type(){ printf '%s' "$want_type"; }
sudo(){ :; }
$(sed -n '/^_agent_pane_input_ready()/,/^}/p'                      "$SRC/src/cmd_agent_runtime.sh")
$(sed -n '/^declare -A _AGENT_PROMPT_DETECTABLE=(/,/^)/p'          "$SRC/src/cmd_agent_runtime.sh")
$(sed -n '/^wait_agent_input_ready()/,/^}/p'                       "$SRC/src/cmd_agent_runtime.sh")
SH
}

echo "== 1. BEHAVIOURAL: an undetectable harness returns immediately =="
for t in opencode pi hermes openclaw; do
  start=$(date +%s)
  bash -c "$(harness "$t"); wait_agent_input_ready x 6" >/dev/null 2>&1; rc=$?
  el=$(( $(date +%s) - start ))
  (( rc == 0 )) && ok "$t proceeds (rc 0)" || no "$t rc=$rc, expected 0"
  (( el <= 1 ))  && ok "$t costs ${el}s, not the full wait" || no "$t burned ${el}s — still waiting"
done

echo "== 2. BEHAVIOURAL: a detectable harness STILL waits (no blanket skip) =="
for t in claude codex; do
  start=$(date +%s)
  bash -c "$(harness "$t"); wait_agent_input_ready x 3" >/dev/null 2>&1; rc=$?
  el=$(( $(date +%s) - start ))
  (( rc == 1 )) && ok "$t still polls and times out (rc 1)" || no "$t rc=$rc, expected 1"
  (( el >= 2 ))  && ok "$t actually waited (${el}s)" || no "$t returned in ${el}s — skipped a real check"
done

echo "== 3. BEHAVIOURAL: an UNKNOWN type falls through to the poll, never skips =="
start=$(date +%s)
bash -c "$(harness ''); wait_agent_input_ready x 3" >/dev/null 2>&1; rc=$?
el=$(( $(date +%s) - start ))
(( rc == 1 && el >= 2 )) && ok "unknown type still waits (safe default)" || no "unknown type skipped (rc=$rc ${el}s)"

echo "== 4. STRUCTURAL: the set and the marker predicate agree =="
pred=$(sed -n '/^_agent_pane_input_ready()/,/^}/p' "$SRC/src/cmd_agent_runtime.sh")
set_types=$(sed -n '/^declare -A _AGENT_PROMPT_DETECTABLE=(/,/^)/p' "$SRC/src/cmd_agent_runtime.sh" | grep -oE '\[[a-z]+\]' | tr -d '[]')
for t in $set_types; do
  case "$t" in
    claude)      grep -q '❯'              <<<"$pred" && ok "claude marker present"      || no "claude in set, no marker" ;;
    codex)       grep -q '›'              <<<"$pred" && ok "codex marker present"       || no "codex in set, no marker" ;;
    devin)       grep -q 'Devin'          <<<"$pred" && ok "devin marker present"       || no "devin in set, no marker" ;;
    antigravity) grep -q 'for shortcuts'  <<<"$pred" && ok "antigravity marker present" || no "antigravity in set, no marker" ;;
    grok)        grep -q '❯'              <<<"$pred" && ok "grok rides claude's marker" || no "grok in set, no marker" ;;
    *)           no "'$t' is in the detectable set with no asserted marker" ;;
  esac
done
grep -qE '\[opencode\]|\[pi\]|\[hermes\]|\[openclaw\]' <<<"$(sed -n '/^declare -A _AGENT_PROMPT_DETECTABLE=(/,/^)/p' "$SRC/src/cmd_agent_runtime.sh")" \
  && no "a markerless type is listed as detectable" || ok "no markerless type claims detectability"

echo; echo "$pass passed, $fail failed"; (( fail == 0 ))
