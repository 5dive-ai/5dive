#!/usr/bin/env bash
# DIVE-2216: a grok seat answers INSIDE a complete fence and the rail harvests
# NOTHING — the seat reads as a silent abstain, which on a council convene is an
# auto-abstain that quietly lowers the effective roster (DIVE-1739).
#
# The two fixtures here are NOT reconstructions. They are `tmux capture-pane -p`
# taken verbatim off the live grok seat 'creative' on the council-demo box
# (a throwaway Hetzner cx23, released 5dive 0.16.32, 2026-07-28), immediately after an
# `agent ask` that exited 11 with "the reply fence was OPENED but never
# completed". The seat had answered. Both captures show the same shape:
#
#     <5dive-r:ID> ALIVE-2216 </5dive-r:ID>               3:08 AM
#
# — both markers on ONE line, the answer between them, and the TUI's own
# timestamp AFTER the closing marker. Two different msg ids, two different
# answers, so this is the harness's layout and not one unlucky render.
#
# WHY 0.16.32 DROPPED IT. The extractor accepted a marker line only if the line
# was the marker and nothing else, so the opening marker (followed by " ALIVE…")
# never matched, no block was ever opened, and the fence-only rule then returned
# silence. The strict rule is CORRECT for what it defends — DIVE-1901 iteration 1
# shipped an adjacency test that a line WRAP defeated, and an echoed instruction
# must never come back as an answer — but it also rejects a real reply from a
# harness that compresses whitespace.
#
# THE DISCRIMINATOR IS CONTENT, NOT LAYOUT, and that is what these assertions
# pin. The echoed instruction always carries the markers ADJACENT
# (`<5dive-r:ID></5dive-r:ID>`, how the hint is written), so the text between its
# markers is empty BY CONSTRUCTION however the composer wraps it; a real reply
# always has something there. So the anti-echo cases below are not decoration:
# they are the reason the strictness is safe to drop, and case 5 replays the
# exact wrap that broke iteration 1 (opening marker isolated on its own line,
# closing marker leading the next).
#
# Every "returns nothing" assertion is paired with a LIVENESS one on the same
# input shape, because an extractor that returned nothing for everything would
# satisfy the negatives alone.
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

F=tests/fixtures/dive2216-grok
pass=0
# An "ok:" line must never print for an assertion that just failed, or a red run
# reads as green at a glance. bad() marks the case dirty; ok_ swallows the tick.
dirty=0
ok_() { if (( dirty )); then dirty=0; return; fi; pass=$((pass+1)); echo "  ok: $1"; }
# KEEP-GOING, deliberately. A fail-fast harness cannot say WHICH cases the old
# extractor drops — it stops at the first one — and "how much of this is the
# bug" is exactly what the red run has to answer. So every assertion is graded
# and the harness exits non-zero at the end if any failed.
fails=0
bad() { echo "FAIL: $*" >&2; fails=$((fails+1)); dirty=1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
base="$W/base"; msg="$W/msg"
# The grok pane's own furniture. Nothing in the extractor may know these strings;
# they exist so a leak is caught by equality AND by name.
CHROME=('Grok 4.5' 'Shift+Tab' 'Ctrl+x' '3:08 AM' '3:12 AM' 'Thought for' 'Worked for' '500K')
printf '%s\n' "  ╭───────────────────╮" "  │ ❯                 │" "  ╰─ Grok 4.5 (high) ─╯" > "$base"

hint() { printf '[reply-format] Put your answer between these two marker lines: <5dive-r:%s></5dive-r:%s> — the opening marker alone on one line, your answer next, the closing marker alone on the last line.' "$1" "$1"; }

# Run the extractor over stdin exactly as the ask rail does (fence path, no
# --allow-unfenced: a scrape must never be what rescues this).
window() { _ask_reply_window "$base" "$msg" "$1" 1 0; }

assert_clean() {
  local what="$1" got="$2" n
  for n in "${CHROME[@]}"; do
    [[ "$got" != *"$n"* ]] || bad "$what: TUI furniture leaked into the reply — '$n' in: [$got]"
  done
}

# ===========================================================================
echo "case 1 — REAL grok pane: both markers inline on one line"
# ===========================================================================
MID=1f18a833
printf 'Reply with exactly: ALIVE-2216 %s' "$(hint $MID)" > "$msg"
got=$(window "$MID" < "$F/reply-oneline.txt")
[[ "$got" == "ALIVE-2216" ]] || bad "case1: expected the seat's answer, got: [$got]"
assert_clean case1 "$got"
ok_ "the answer between an inline marker pair is returned, timestamp excluded"

# ===========================================================================
echo "case 2 — a SECOND real grok pane, different id and answer"
# ===========================================================================
MID2=19f3bb66
printf 'What is your role? %s' "$(hint $MID2)" > "$msg"
got=$(window "$MID2" < "$F/reply-oneline-2.txt")
[[ "$got" == "Creative, the CMO." ]] || bad "case2: expected the seat's answer, got: [$got]"
assert_clean case2 "$got"
ok_ "the same shape harvests on a second live capture, so it is the harness layout"

# ===========================================================================
echo "case 3 — the REAL pane with the reply line DELETED returns NOTHING"
# ===========================================================================
# The strongest anti-echo assertion available: same live capture, same echoed
# instruction (its marker pair is on line 7, adjacent, with prose both sides),
# only the seat's answer removed. Anything non-empty here is the echo coming
# back as an answer — the exact fabrication DIVE-1901 removed the scraper for.
printf 'Reply with exactly: ALIVE-2216 %s' "$(hint $MID)" > "$msg"
got=$(grep -v 'ALIVE-2216 </5dive-r:' "$F/reply-oneline.txt" | window "$MID")
[[ -z "$got" ]] || bad "case3: the echoed instruction was returned as a reply: [$got]"
ok_ "with the answer removed the same pane yields nothing — the echo is not a reply"

# ===========================================================================
echo "case 4 — prose reply, closing marker beside the last content line"
# ===========================================================================
# The second shape recorded on this seat (DIVE-2216 body): the opener sits alone
# but the closer is pushed onto the end of the prose. 0.16.32 rejected the whole
# block on its 'embedded closing marker means echo' branch.
MID3=322be85c
printf 'Grade the evidence. %s' "$(hint $MID3)" > "$msg"
got=$(printf '%s\n' \
  "     ❯ [5dive-msg from=ask id=${MID3}] Grade the evidence. [reply-format]" \
  "       Put your answer between these two marker lines:" \
  "       <5dive-r:${MID3}></5dive-r:${MID3}> — the opening marker alone …" \
  "     ◆ Thought for 1.2s" \
  "     <5dive-r:${MID3}>" \
  "     The repro proves sufficiency, not necessity." \
  "     Two logs, one writer, so one witness." \
  "     VERDICT: insufficient </5dive-r:${MID3}>            3:08 AM" \
  "  ╰─ Grok 4.5 (high) · always-approve ─╯" | window "$MID3")
[[ "$got" == "The repro proves sufficiency, not necessity.
Two logs, one writer, so one witness.
VERDICT: insufficient" ]] || bad "case4: prose body wrong, got: [$got]"
assert_clean case4 "$got"
ok_ "a closer beside the prose keeps the last line and drops the marker"

# ===========================================================================
echo "case 4b — content beside the OPENER, and a closer with only a glyph before it"
# ===========================================================================
# The mirror of case 4 and the third layout this seat can produce: the answer
# starts on the opening marker's line and runs on. The glyph-only closing line
# also grades the content test from the other side — "▌" must not survive as a
# trailing line of the answer, for the same reason it must not open one.
got=$(printf '%s\n' \
  "▌ [5dive-msg from=ask id=${MID3}] Grade the evidence. [reply-format] Put your" \
  "▌ answer between these two marker lines: <5dive-r:${MID3}></5dive-r:${MID3}> —" \
  "▌ <5dive-r:${MID3}> The repro proves sufficiency, not necessity." \
  "▌ Two logs, one writer, so one witness." \
  "▌ </5dive-r:${MID3}>" \
  "  ╰─ Grok 4.5 (high) · always-approve ─╯" | window "$MID3")
[[ "$got" == "The repro proves sufficiency, not necessity.
▌ Two logs, one writer, so one witness." ]] || bad "case4b: opener-inline body wrong, got: [$got]"
assert_clean case4b "$got"
ok_ "an answer beside the opening marker is kept, and a glyph-only closing line is not"

# ===========================================================================
echo "case 5 — the DIVE-1901 WRAPPED ECHO must still return nothing"
# ===========================================================================
# This is the wrap that defeated iteration 1's adjacency defence: the composer
# breaks the line BETWEEN the two adjacent markers, so the opening marker is
# alone on a line and the closer leads the next one. Relaxing the layout rule is
# only safe because the text between them is still empty.
MID4=ab12cd34
printf 'vote please %s' "$(hint $MID4)" > "$msg"
echo_frame=$(printf '%s\n' \
  "▌ [5dive-msg from=ask id=${MID4}] vote please [reply-format] Put your" \
  "▌ answer between these two marker lines:" \
  "▌ <5dive-r:${MID4}>" \
  "▌ </5dive-r:${MID4}> — the opening marker alone on one line, your answer" \
  "▌ next, the closing marker alone on the last line." \
  "  ╰─ Grok 4.5 (high) · always-approve ─╯")
got=$(window "$MID4" <<<"$echo_frame")
[[ -z "$got" ]] || bad "case5: the WRAPPED echo was returned as a reply: [$got]"
ok_ "an echo wrapped between its adjacent markers is still not a reply"

# --- liveness for case 5: the identical frame with a real reply appended must
# come back, or the emptiness above proves nothing about the input shape.
got=$(printf '%s\n%s\n' "$echo_frame" "     <5dive-r:${MID4}> COUNCIL-VOTE: nay </5dive-r:${MID4}>   3:08 AM" | window "$MID4")
[[ "$got" == "COUNCIL-VOTE: nay" ]] || bad "case5-liveness: reply after the wrapped echo lost, got: [$got]"
assert_clean case5 "$got"
ok_ "and a real reply in that same frame IS returned — the negative is not vacuous"

# ===========================================================================
echo "case 6 — a HALF-WRITTEN inline fence returns nothing, so the rail polls on"
# ===========================================================================
# Mid-write is the state DIVE-1901's live capture caught (frame2). An open fence
# must stay unreturnable whatever the layout, or the rail settles on a partial
# answer and calls it the seat's word.
MID5=5d7d77e6
printf 'status? %s' "$(hint $MID5)" > "$msg"
half="     <5dive-r:${MID5}> build gre"
got=$(printf '%s\n%s\n' "     ◆ Thought for 0.4s" "$half" | window "$MID5")
[[ -z "$got" ]] || bad "case6: a half-written fence was returned: [$got]"
ok_ "an unclosed inline fence returns nothing rather than a partial answer"

got=$(printf '%s\n%s\n' "     ◆ Thought for 0.4s" "${half}en </5dive-r:${MID5}>" | window "$MID5")
[[ "$got" == "build green" ]] || bad "case6-liveness: the completed fence was lost, got: [$got]"
ok_ "and the same fence once CLOSED returns the answer — mid-write is not a dead end"

# ===========================================================================
echo "case 7 — the strict, marker-per-line path is untouched"
# ===========================================================================
# The relaxed pass runs only after the strict one finds nothing, so every seat
# that works today must behave identically. Pinned here rather than assumed.
MID6=cc00dd11
printf 'How is the build? %s' "$(hint $MID6)" > "$msg"
got=$(printf '%s\n' \
  "▌ [5dive-msg from=ask id=${MID6}] How is the build? [reply-format] Put your" \
  "▌ answer between these two marker lines: <5dive-r:${MID6}></5dive-r:${MID6}> —" \
  "◆ <5dive-r:${MID6}>" \
  "  build green" \
  "    2 warnings in api/db" \
  "  </5dive-r:${MID6}>" \
  "  anthropic/claude-sonnet-5   ctrl+c to cancel   19% ctx" | window "$MID6")
[[ "$got" == "build green
  2 warnings in api/db" ]] || bad "case7: the strict path changed, got: [$got]"
ok_ "a marker-per-line reply still returns verbatim and dedented"

# ===========================================================================
echo "case 8 — KNOWN LIMIT, pinned: a wrapped reply carries the pane's clock"
# ===========================================================================
# Third verbatim capture off the same live seat, taken from the end-to-end run of
# the FIXED bundle. Grok wrapped its own one-line reply at the pane width, and the
# TUI painted its right-margin timestamp on that first visual row — physically
# BETWEEN the two markers:
#
#     <5dive-r:be8222f3> Creative, CMO VERDICT: marketing lead on     3:21 AM
#     this team </5dive-r:be8222f3>
#
# So "3:21 AM" comes back inside the answer. That is NOT fixed here, deliberately:
# the only way to remove it is to recognise a right-margin clock, which is a
# per-harness chrome signature — the exact thing DIVE-1901 refused to grow, and
# the thing that made the old scraper a fabrication path. The fence's contract is
# "what the seat put between the markers", and on this pane the TUI put that there.
# Pinned rather than left to be discovered: the answer itself is intact and a
# ballot line survives, so the abstain is gone, but a caller doing an EXACT string
# compare against a wrapped grok reply must expect this.
MID7=be8222f3
printf 'your role, then VERDICT: %s' "$(hint $MID7)" > "$msg"
got=$(window "$MID7" < "$F/reply-multiline.txt")
[[ "$got" == "Creative, CMO VERDICT: marketing lead on     3:21 AM
this team" ]] || bad "case8: the known-limit shape moved, got: [$got]"
[[ "$got" == *"VERDICT: marketing lead on"* ]] || bad "case8: the answer itself was lost"
ok_ "a wrapped reply returns whole, with the pane clock riding along — known and pinned"

echo
if (( fails )); then
  echo "FAILED — ${fails} assertion(s) red, ${pass} green (DIVE-2216 inline fence)" >&2
  exit 1
fi
echo "PASS — ${pass} assertions (DIVE-2216 inline fence)"
