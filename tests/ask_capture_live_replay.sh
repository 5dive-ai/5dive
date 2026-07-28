#!/usr/bin/env bash
# DIVE-1901 iteration 2 — REGRESSION AGAINST THE REAL PANE.
#
# Iteration 1 shipped and then FAILED live on an antigravity seat: a 2811-char
# ask returned "Gemini 3.6 Flash · high" — the TUI footer — at rc=0, while the
# seat had answered correctly. The fixtures here are not a reconstruction; they
# are three 24-line renders lifted verbatim from `tmux capture-pane -S -200` on
# that seat right after the failing run (main, 2026-07-25):
#
#   frame1-working   the seat is thinking; footer reads "esc to cancel …"
#   frame2-midwrite  the fence is HALF-WRITTEN: "<5dive-r:" then "        ing..."
#   frame3-complete  the fence is closed around AFTER-AGY-LONG-R2K7
#
# frame2 is the whole story and it is why the first hypothesis (the prompt echo
# being mistaken for a reply) was WRONG: the echoed pair always has prose beside
# a marker and was always rejected correctly. The real fault is that the rail
# SETTLED while the seat was still typing, and the scraping fallback handed back
# whatever furniture happened to be holding still. No chrome list fixes that — at
# the instant it looks, static furniture and a finished answer are the same thing.
#
# HONEST LIMIT OF THIS TEST — read before trusting it. It does NOT reproduce the
# live failure. The shipped 0.15.1 extractor passes these same frames, and a
# sweep of ALL 201 twenty-four-line windows of that scrollback produced ZERO
# furniture returns on shipped code. The frame the rail actually settled on was
# already overwritten by the time the pane was dumped (an alt-screen TUI redraws
# in place), so it is not in the capture and cannot be recovered from it.
#
# What this test IS: behaviour PINNED on real frames from the failing seat — the
# mid-write state especially, which no synthetic fixture would have thought to
# include. What makes the fix defensible is not this test but a structural
# argument: every fabrication this ticket has caught came from the scraping
# fallback, and fence-only makes ANY furniture frame unreturnable regardless of
# which one it was. `FIVE_ASK_DEBUG_DIR` exists so the next occurrence pins
# itself rather than needing this reconstruction.
#
# So the assertion is not "the parser got better". It is: while the fence is
# incomplete the rail returns NOTHING (which keeps it polling and, failing that,
# times out loudly), and once the fence closes it returns the token EXACTLY.
set -euo pipefail

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
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh

F=tests/fixtures/dive1901-agy
MID=5d7d77e6
pass=0
ok_() { pass=$((pass+1)); echo "  ok: $1"; }
die() { echo "FAIL: $*" >&2; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
msg="$W/msg"; acc="$W/acc"; : > "$acc"
{ printf 'CONTEXT LINE 1: filler to push this ask past one screen height so any marker scrolls off an alt-screen pane. '
  printf 'Reply with exactly this token and nothing else: AFTER-AGY-LONG-R2K7 '
  printf '[reply-format] Put your answer between these two marker lines: <5dive-r:%s></5dive-r:%s> — the opening marker alone on one line, your answer next, the closing marker alone on the last line.' "$MID" "$MID"
} > "$msg"

poll() { _ask_accumulate "$acc" < "$F/$1" | _ask_reply_window "$F/baseline.txt" "$msg" "$MID" 1 "${2:-0}"; }

got=$(poll frame1-working.txt)
[[ -z "$got" ]] || die "poll 1 (seat still thinking) returned something: [$got]"
ok_ "while the seat is thinking the rail returns NOTHING, not the status footer"

got=$(poll frame2-midwrite.txt)
[[ -z "$got" ]] || die "poll 2 (fence half-written) returned something: [$got]"
ok_ "a HALF-WRITTEN fence is not an answer — this is the exact frame that failed live"

got=$(poll frame3-complete.txt)
[[ "$got" == "AFTER-AGY-LONG-R2K7" ]] || die "poll 3 expected the token, got: [$got]"
ok_ "once the fence closes the rail returns the seat's token exactly"

# The bug that shipped: with scraping allowed, furniture comes back as an answer.
# Kept as a live demonstration of WHY the fallback is opt-in and off by default.
: > "$acc"
leak=$(poll frame1-working.txt 1; poll frame2-midwrite.txt 1)
if [[ "$leak" == *"Gemini 3.6 Flash"* || "$leak" == *"for shortcuts"* ]]; then
  ok_ "with --allow-unfenced the same frames DO leak furniture — which is why it is off by default"
else
  ok_ "opt-in fallback returned no furniture on these frames (still opt-in by policy)"
fi


# ---------------------------------------------------------------------------
# The accumulator DUPLICATES heavily on a real pane — main's forensic transcript
# from the passing iteration-2 run is 1078 lines from 117 unique, ~9x. That is
# the fold appending whole frames when it cannot align, and it is harmless only
# if it cannot corrupt a MULTI-LINE reply, which is what a council rationale is.
# Measured here rather than assumed: stream a multi-line fenced reply, then
# replay earlier frames out of order to force the mis-alignment, and require the
# reply back intact with its relative indentation.
# ---------------------------------------------------------------------------
W2="$(mktemp -d)"; trap 'rm -rf "$W" "$W2"' EXIT
M2=abc12345; acc2="$W2/a"; : > "$acc2"; base2="$W2/b"; msg2="$W2/m"
printf 'vote please\n' > "$msg2"
printf '  idle\n──────\n>\n──────\n? for shortcuts   Model X\n' > "$base2"
_dupframe() {
  printf '%s\n' "  idle" "> [5dive-msg from=dev id=$M2] vote please"
  (( $1 >= 1 )) && printf '%s\n' "◆ <5dive-r:$M2>"
  (( $1 >= 2 )) && printf '%s\n' "  COUNCIL-VOTE: aye"
  (( $1 >= 3 )) && printf '%s\n' "  rationale line one"
  (( $1 >= 4 )) && printf '%s\n' "    indented detail"
  (( $1 >= 5 )) && printf '%s\n' "  </5dive-r:$M2>"
  printf '%s\n' "──────" ">" "──────" "? for shortcuts   Model X"
  return 0
}
for n in 1 2 3 4 5 3 5 2 5; do _dupframe $n | _ask_accumulate "$acc2" >/dev/null; done
got=$(_ask_reply_window "$base2" "$msg2" "$M2" 1 0 < "$acc2")
[[ "$got" == "COUNCIL-VOTE: aye
rationale line one
  indented detail" ]] || die "duplication corrupted a multi-line reply: [$got]"
ok_ "a multi-line reply survives a duplicating, out-of-order accumulator intact"

echo
echo "PASS — ${pass} assertions (DIVE-1901 live pane replay)"
