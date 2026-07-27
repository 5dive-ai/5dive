#!/usr/bin/env bash
# DIVE-1901: `agent ask` reply capture — the seat answers, the rail must return
# THAT TEXT.
#
# The rail used to read a full-screen TUI pane with `capture-pane -S -2000` and
# slice at the marker. On the claude and codex panes measured for this ticket the
# alternate screen carried NO scrollback, so `-S` came back clamped to a
# screenful with no signal it had been clamped.
#
# CORRECTION (main, 2026-07-25): that is NOT universal, and the original writeup
# overstated it. `-S -200` on a live ANTIGRAVITY pane returned 100 non-blank
# lines, 50 unique, including real history. So scrollback availability is
# per-harness and must not be assumed either way — the rail now asks for `-S`
# (free where it works) AND accumulates frames (needed where it does not).
#
# That produced two failures, anti-correlated by message length, and BOTH exit
# clean:
#
#   A. LONG message -> the `id=<msg_id>` echo scrolls off, the marker is
#      unrecoverable, and the rail either times out with "no idle reply within
#      Ns" WHILE THE SEAT HAS ANSWERED, or exits 0 carrying whatever furniture
#      happened to stabilise (measured live: a 2811-char ask to an antigravity
#      seat returned blank lines and "? for shortcuts" at rc=0).
#   B. SHORT message -> the marker is still on screen and the slice is non-empty
#      but is nothing but STATIC TUI CHROME, unchanged for --idle-secs -> the
#      footer is returned AS THE REPLY, exit 0, before the seat typed anything.
#      NEITHER MODE IS RELIABLY LOUD. Do not reach for the consolation that the
#      long/ballot case at least fails noisily -- it does not, and believing it
#      is what makes a partial fix look sufficient.
#
# So these assert the returned STRING BY EQUALITY, and assert that no chrome
# substring ever rides along. Non-emptiness is exactly what mode B satisfies, so
# an exit-code / non-empty test would pass on the bug.
#
# ITERATION 2: the scraping fallback is now OPT-IN (--allow-unfenced). Every
# fabrication this ticket has caught came from it and none from the fence, so by
# default `ask` returns the fenced reply or NOTHING. The cases below that pass a
# trailing `1` are exercising that opt-in fallback deliberately; the default-path
# cases assert that furniture is never returned as an answer.
#
# The helpers are pure (stdin + temp files), so the whole frame sequence is
# replayed offline — no tmux, no agent, no root, no network.
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

pass=0
ok_() { pass=$((pass+1)); echo "  ok: $1"; }
die() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MID="ab12cd34"
CHROME_NEEDLES=('weekly limit' 'bypass permissions' 'shift+tab' 'esc to interrupt')

# Assert a returned capture carries no TUI furniture, whatever else it says.
assert_no_chrome() {
  local what="$1" got="$2" needle
  for needle in "${CHROME_NEEDLES[@]}"; do
    [[ "$got" != *"$needle"* ]] || die "$what: chrome leaked into the reply — found '$needle' in: $got"
  done
}

# ---------------------------------------------------------------------------
# A claude-shaped pane. `frame <body-lines-file>` renders a body plus the same
# furniture the real TUI draws: a rule, the input box, the hint line and the
# usage/model footer — whose COUNTERS MOVE between the baseline and the reply,
# which is residual 1 (an exact-match chrome compare lets them through).
# ---------------------------------------------------------------------------
frame() {
  local pct="$1" day="$2" model_pct="$3"; shift 3
  printf '%s\n' "$@"
  cat <<EOF
────────────────────────────────────────────────
 >
────────────────────────────────────────────────
  ? for shortcuts                    bypass permissions on (shift+tab to cycle)
  You've used ${pct}% of your weekly limit · resets ${day} 9am
  Sonnet 5 5h: ${model_pct}%
EOF
}

# ===========================================================================
echo "case 1 — SHORT ask: chrome-only frames are NOT a reply (mode B)"
# ===========================================================================
base="$WORK/base1"; acc="$WORK/acc1"; msg="$WORK/msg1"
printf '%s' "ping — reply with the single word PONG" > "$msg"
frame 43 Tue 11 "> previous turn output" "  something the seat said earlier" > "$base"
: > "$acc"

# Poll 1 + 2: the question landed and the seat is still thinking. Everything on
# screen after the marker is furniture — including a footer whose numbers have
# moved since the baseline.
secs=3
for pct in 44 45; do
  secs=$((secs+2))
  got=$(frame "$pct" Wed 12 \
        "> previous turn output" \
        "  something the seat said earlier" \
        "> [5dive-msg from=ask id=${MID}] ping — reply with the single" \
        "  word PONG" \
        "✳ Cogitating… (${secs}s · ↑ 1.2k tokens · esc to interrupt)" \
      | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1)
  assert_no_chrome "case1/poll" "$got"
  [[ -z "$got" ]] || die "case1: chrome-only frame returned a reply: [$got]"
done
ok_ "a pane carrying only furniture + a moved usage counter yields NO reply"

# Poll 3: the seat answered.
got=$(frame 45 Wed 12 \
      "> previous turn output" \
      "  something the seat said earlier" \
      "> [5dive-msg from=ask id=${MID}] ping — reply with the single" \
      "  word PONG" \
      "● PONG" \
    | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1)
assert_no_chrome "case1/answer" "$got"
[[ "$got" == "● PONG" ]] || die "case1: expected '● PONG', got: [$got]"
ok_ "the seat's answer is returned verbatim, by equality"

# ===========================================================================
echo "case 2 — 'reply with exactly this': the echo is eaten, the answer is not"
# ===========================================================================
base="$WORK/base2"; acc="$WORK/acc2"; msg="$WORK/msg2"
printf '%s' "Reply with exactly this and nothing else:
COUNCIL-VOTE: aye - rail works" > "$msg"
frame 43 Tue 11 "  (idle)" > "$base"
: > "$acc"
got=$(frame 43 Tue 11 \
      "  (idle)" \
      "> [5dive-msg from=ask id=${MID}] Reply with exactly this and nothing" \
      "  else:" \
      "  COUNCIL-VOTE: aye - rail works" \
      "● COUNCIL-VOTE: aye - rail works" \
    | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1)
assert_no_chrome "case2" "$got"
[[ "$got" == "● COUNCIL-VOTE: aye - rail works" ]] \
  || die "case2: expected the seat's line once, got: [$got]"
ok_ "the wrapped question echo is consumed in order; the seat's identical line survives"

# ===========================================================================
echo "case 3 — LONG ask: the marker scrolls off and the reply still lands (mode A)"
# ===========================================================================
base="$WORK/base3"; acc="$WORK/acc3"; msg="$WORK/msg3"
long=""
for i in $(seq 1 12); do long+="ballot context line ${i} for the motion under consideration
"; done
long+="Answer with one COUNCIL-VOTE line."
printf '%s' "$long" > "$msg"
frame 43 Tue 11 "  (idle)" > "$base"
: > "$acc"

# Poll 1: the marker + the first half of the echoed ballot are on screen.
echoed=()
for i in $(seq 1 12); do echoed+=("  ballot context line ${i} for the motion under consideration"); done
frame 43 Tue 11 "  (idle)" \
  "> [5dive-msg from=ask id=${MID}] ballot context line 1 for the motion" \
  "  under consideration" \
  "${echoed[@]:1:6}" \
  | _ask_accumulate "$acc" >/dev/null

# Poll 2: the pane has SCROLLED — the marker line is gone from the visible frame,
# which is exactly what killed the real convene. The accumulator must still hold it.
got=$(frame 44 Tue 11 \
      "${echoed[@]:5:7}" \
      "  Answer with one COUNCIL-VOTE line." \
      "● COUNCIL-VOTE: aye - the rail captures long ballots now" \
    | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1)
assert_no_chrome "case3" "$got"
grep -q "id=${MID}" "$acc" || die "case3: the marker was lost from the accumulated transcript"
[[ "$got" == "● COUNCIL-VOTE: aye - the rail captures long ballots now" ]] \
  || die "case3: expected the vote line alone, got: [$got]"
ok_ "the marker survives scroll-off and the long-ask reply is returned alone"

# ===========================================================================
echo "case 4 — in-place redraw does not duplicate the transcript (residual 2)"
# ===========================================================================
acc="$WORK/acc4"; : > "$acc"
printf '%s\n' "line one" "line two" "● Thinking…" | _ask_accumulate "$acc" >/dev/null
out=$(printf '%s\n' "line one" "line two" "● Thinking… (7s)" | _ask_accumulate "$acc")
[[ "$(grep -c '^line one$' <<<"$out")" == "1" ]] \
  || die "case4: a redrawn frame double-counted the transcript:
$out"
[[ "$out" == *"● Thinking… (7s)"* && "$out" != *"● Thinking…"$'\n'* ]] \
  || die "case4: the newest render of the changed line did not win:
$out"
ok_ "a frame whose last line changed in place folds instead of appending whole"

# ===========================================================================
echo "case 5 — a message from ANOTHER agent mid-wait is not read as our reply"
# ===========================================================================
base="$WORK/base5"; acc="$WORK/acc5"; msg="$WORK/msg5"
printf '%s' "status?" > "$msg"
frame 43 Tue 11 "  (idle)" > "$base"
: > "$acc"
got=$(frame 43 Tue 11 \
      "  (idle)" \
      "> [5dive-msg from=ask id=${MID}] status?" \
      "● all green" \
      "> [5dive-msg from=olivia id=zz99zz99] unrelated question" \
      "● an answer that belongs to olivia" \
    | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1)
[[ "$got" == "● all green" ]] || die "case5: window was not bounded at the next marker, got: [$got]"
ok_ "the reply window stops at the next [5dive-msg marker"


# ===========================================================================
echo "case 6 — the reply FENCE is harness-agnostic: an opencode-shaped pane"
# ===========================================================================
# Nothing below is claude-shaped: different glyphs, different footer, different
# status line. The extractor is given no per-harness signature and must still
# return exactly what the seat put between the markers.
base="$WORK/base6"; acc="$WORK/acc6"; msg="$WORK/msg6"
FENCE_HINT="[reply-format] Put your answer between these two marker lines: <5dive-r:${MID}></5dive-r:${MID}> — the opening marker alone on one line, your answer next, the closing marker alone on the last line."
printf '%s' "How is the build? ${FENCE_HINT}" > "$msg"
cat > "$base" <<'EOF'
┃ opencode v0.4.2
┃ ~/projects/api
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                                                ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
  anthropic/claude-sonnet-5   ctrl+c to cancel   14% ctx
EOF
: > "$acc"
got=$(cat <<EOF | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID"
┃ opencode v0.4.2
┃ ~/projects/api
▌ [5dive-msg from=ask id=${MID}] How is the build? [reply-format] Put your
▌ answer between these two marker lines: <5dive-r:${MID}></5dive-r:${MID}> —
▌ the opening marker alone on one line, your answer next, the closing marker
▌ alone on the last line.
◆ <5dive-r:${MID}>
  build green
    2 warnings in api/db
  </5dive-r:${MID}>
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                                                ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
  anthropic/claude-sonnet-5   ctrl+c to cancel   19% ctx
EOF
)
assert_no_chrome "case6" "$got"
[[ "$got" == "build green
  2 warnings in api/db" ]] || die "case6: fence body wrong, got: [$got]"
ok_ "a fenced multi-line reply is returned verbatim from a non-claude pane, dedented"

# ===========================================================================
echo "case 7 — un-fenced seat on a third TUI: fallback window, still no chrome"
# ===========================================================================
# A seat that ignores the format instruction falls back to the heuristic window.
# Different chrome again (antigravity-shaped) and NO per-harness list anywhere.
base="$WORK/base7"; acc="$WORK/acc7"; msg="$WORK/msg7"
printf '%s' "status? ${FENCE_HINT}" > "$msg"
cat > "$base" <<'EOF'
  antigravity · gemini-3-pro
  ─────────────────────────────
  ▷
  ─────────────────────────────
  tokens 12.4k · press esc to interrupt · 3d 22h left
EOF
: > "$acc"
got=$(cat <<EOF | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1
  antigravity · gemini-3-pro
▷ [5dive-msg from=ask id=${MID}] status? [reply-format] Put your answer
  between these two marker lines: <5dive-r:${MID}></5dive-r:${MID}> — the
  opening marker alone on one line, your answer next, the closing marker
  alone on the last line.
◆ all systems nominal
  ─────────────────────────────
  ▷
  ─────────────────────────────
  tokens 31.9k · press esc to interrupt · 3d 21h left
EOF
)
assert_no_chrome "case7" "$got"
[[ "$got" == "◆ all systems nominal" ]] || die "case7: expected the seat line alone, got: [$got]"
ok_ "an un-fenced reply on a third TUI still comes back clean via the fallback"


# ===========================================================================
echo "case 8 — the SCOPED (_capture) path gets the fence too"
# ===========================================================================
# A scoped-sudo agent reads through the privileged `agent _capture`, which slices
# at the marker on the other side of the sudo boundary — so this side must NOT
# re-slice. The fence is keyed on the msg id, not on the slice, so it must still
# engage: skipping it here was a real gap (the scoped path had no fence at all).
base="$WORK/base8"; msg="$WORK/msg8"; acc="$WORK/acc8"
printf '%s' "vote please ${FENCE_HINT}" > "$msg"
frame 43 Tue 11 "  (idle)" > "$base"
: > "$acc"
got=$(printf '%s\n' \
      "  vote please [reply-format] Put your answer between these two marker" \
      "  lines: <5dive-r:${MID}></5dive-r:${MID}> — the opening marker alone" \
      "● <5dive-r:${MID}>" \
      "  COUNCIL-VOTE: nay - scoped path" \
      "  </5dive-r:${MID}>" \
    | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 0 1)
assert_no_chrome "case8" "$got"
[[ "$got" == "COUNCIL-VOTE: nay - scoped path" ]] \
  || die "case8: fence did not engage on the scoped path, got: [$got]"
ok_ "the fence engages with marker-slicing off, so scoped-sudo callers are covered"


# ===========================================================================
echo "case 9 — a CLOSED fence written on ONE line is a reply, not a miss"
# ===========================================================================
# Weaker seats routinely inline the whole fence: "<5dive-r:id> answer </5dive-r:id>".
# It is fully closed and carries both unique markers, but the line-shape test
# (marker alone on its line) rejected it, so `ask` returned nothing and the
# caller could not tell "the seat said nothing" from "the seat answered and we
# dropped it". Measured on devin 3000.2.17 (SWE-1.7); not devin-specific.
base="$WORK/base9"; msg="$WORK/msg9"; acc="$WORK/acc9"
printf '%s' "reply with pong ${FENCE_HINT}" > "$msg"
frame 43 Tue 11 "  (idle)" > "$base"
: > "$acc"
got=$(printf '%s\n' \
      "  reply with pong [reply-format] Put your answer between these two marker" \
      "  lines: <5dive-r:${MID}></5dive-r:${MID}> — the opening marker alone" \
      "  │ <5dive-r:${MID}> pong from the seat </5dive-r:${MID}>" \
    | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1)
assert_no_chrome "case9" "$got"
[[ "$got" == "pong from the seat" ]] \
  || die "case9: same-line fence not returned, got: [$got]"
ok_ "a same-line fence returns the reply"

# The echoed INSTRUCTION also carries both markers on one line — adjacent, so
# the inner text is empty. It must never be mistaken for an answer; this is the
# case that keeps the tolerance from becoming the scraping path again.
base="$WORK/base9b"; msg="$WORK/msg9b"; acc="$WORK/acc9b"
printf '%s' "reply with pong ${FENCE_HINT}" > "$msg"
frame 43 Tue 11 "  (idle)" > "$base"
: > "$acc"
got=$(printf '%s\n' \
      "  reply with pong [reply-format] Put your answer between these two marker" \
      "  lines: <5dive-r:${MID}></5dive-r:${MID}> — the opening marker alone on" \
      "  one line, your answer next, the closing marker alone on the last line." \
      "✳ Cogitating… (7s · esc to interrupt)" \
    | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1)
assert_no_chrome "case9b" "$got"
[[ -z "$got" ]] || die "case9b: echoed instruction returned as a reply: [$got]"
ok_ "the echoed instruction (markers adjacent, empty inner) is still not a reply"

# An unfinished same-line write has no closing marker, so there is nothing to
# extract — a half-typed answer must not be returned as a whole one.
base="$WORK/base9c"; msg="$WORK/msg9c"; acc="$WORK/acc9c"
printf '%s' "reply with pong ${FENCE_HINT}" > "$msg"
frame 43 Tue 11 "  (idle)" > "$base"
: > "$acc"
got=$(printf '%s\n' \
      "  reply with pong [reply-format] Put your answer between these two marker" \
      "  lines: <5dive-r:${MID}></5dive-r:${MID}> — the opening marker alone" \
      "  │ <5dive-r:${MID}> pong fro" \
    | _ask_accumulate "$acc" | _ask_reply_window "$base" "$msg" "$MID" 1 1)
[[ -z "$got" ]] || die "case9c: mid-write same-line fence returned: [$got]"
ok_ "a mid-write same-line fence (no closing marker) returns nothing"

echo
echo "PASS — ${pass} assertions (DIVE-1901 ask capture)"
