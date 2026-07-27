#!/usr/bin/env bash
# DIVE-1931: the SCOPED reply read (`agent _capture`) must survive scroll-off.
#
# DIVE-1901 fixed the direct path by ACCUMULATING visible frames, so the
# `id=<msg_id>` marker is remembered after it leaves an alternate-screen pane
# (which usually has no scrollback, so `-S -2000` is a screenful). The scoped
# path could not do that from the caller side: the slice happens on the far side
# of the sudo boundary, so once the marker scrolled off, `_capture` itself
# returned EMPTY and the caller had nothing left to accumulate. A standard /
# admin-isolation OSS agent asking a long question of a TUI seat therefore timed
# out with "no idle reply" WHILE THE SEAT HAD ANSWERED — unless the seat honoured
# the reply fence and the fence happened to still be on screen.
#
# The accumulation now lives INSIDE `_capture`, before the slice. So the two
# things that must both hold, and that this file asserts:
#
#   1. LIVENESS — an un-fenced long reply whose marker has scrolled away comes
#      back as the seat's actual text, BY EQUALITY. Not "non-empty": the failure
#      this replaces returned empty, and its sibling (DIVE-1901 mode B) returned
#      TUI furniture at rc=0, so only an equality assert grades it.
#   2. THE BOUND IS UNCHANGED — accumulation must not become a wider read. The
#      transcript holds frames that contain the seat's pre-existing pane content
#      and a LATER message from a third agent; neither may ever be emitted. The
#      caller still gets exactly "after MY marker, before the next [5dive-msg".
#
# Offline: tmux/sudo/root are stubbed, frames are replayed from fixtures.
set -euo pipefail
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

MID="a1b2c3d4"          # our marker — minted per-ask by gen_msg_id
FOREIGN="99887766"      # a third agent's marker, arriving mid-wait

# --- stubs: no root, no tmux, no agent ------------------------------------
require_root()  { :; }
require_agent() { :; }
FRAME=""
sudo() {
  case " $* " in
    *" has-session "*)  return 0 ;;
    *" capture-pane "*) [[ -n "$FRAME" ]] && cat "$FRAME"; return 0 ;;
  esac
  return 0
}

# Render one visible pane frame. The seat is a full-screen TUI: each frame is a
# WINDOW onto a scrolling stream, and the top of the previous frame is gone.
frame() { local f="$WORK/frame.$1"; shift; printf '%s\n' "$@" > "$f"; echo "$f"; }

SECRET_BEFORE="SECRET-the-seats-own-work-before-we-asked"
SECRET_AFTER="SECRET-the-reply-trinity-got-not-us"

# Frame 1 — our question lands. The seat's earlier work is still on screen ABOVE
# our marker; it is not ours to read, now or after it scrolls.
F1=$(frame 1 \
  "  ${SECRET_BEFORE}" \
  "  api key rotated ok" \
  "[5dive-msg from=neo id=${MID}] summarise the deploy plan, at length" \
  "  Sure. Here is the plan:" \
  "  1. drain the queue")
# Frame 2 — the reply is long, so the marker line has SCROLLED OFF. This is the
# frame the old code choked on: no marker, no anchor, empty return.
F2=$(frame 2 \
  "  Sure. Here is the plan:" \
  "  1. drain the queue" \
  "  2. roll the api" \
  "  3. verify the smoke matrix")
# Frame 3 — scrolled further; a THIRD agent messages the seat mid-wait and gets
# its own reply. Everything from that marker on is outside our window.
F3=$(frame 3 \
  "  3. verify the smoke matrix" \
  "  4. flip the flag" \
  "[5dive-msg from=trinity id=${FOREIGN}] unrelated question" \
  "  ${SECRET_AFTER}")

WANT_WINDOW="  Sure. Here is the plan:
  1. drain the queue
  2. roll the api
  3. verify the smoke matrix
  4. flip the flag"

# ===========================================================================
echo "case 1 — RED control: a single point-in-time read of the scrolled frame"
# ===========================================================================
# Frame 3 on a FRESH transcript is exactly what the old `_capture` did on poll N:
# no marker in the visible pane, so nothing comes back. If this is not empty the
# fixture does not reproduce the bug and every assert below is vacuous.
export FIVE_CAPTURE_ACC_DIR="$WORK/acc-red"
FRAME="$F3"
red=$(cmd_capture morpheus --after-id="$MID")
[[ -z "$red" ]] || die "case1: the scroll-off fixture does not reproduce — frame 3 alone returned: [$red]"
ok_ "the marker is genuinely gone from the scrolled frame (the fixture bites)"

# ===========================================================================
echo "case 2 — LIVENESS: accumulated across polls, the window is the seat's text"
# ===========================================================================
export FIVE_CAPTURE_ACC_DIR="$WORK/acc"
for f in "$F1" "$F2" "$F3"; do
  FRAME="$f"; got=$(cmd_capture morpheus --after-id="$MID")
done
[[ "$got" == "$WANT_WINDOW" ]] \
  || die "case2: window mismatch.
want:
$WANT_WINDOW
got:
$got"
ok_ "an un-fenced reply survives scroll-off and returns BY EQUALITY"

# ===========================================================================
echo "case 3 — THE BOUND: nothing before our marker, nothing past the next one"
# ===========================================================================
# Both secrets sat in frames this transcript folded in, so they are the exact
# thing accumulation could have leaked. Substring, not line, compare.
[[ "$got" != *"$SECRET_BEFORE"* ]] \
  || die "case3: accumulation leaked pane content from BEFORE our marker: [$got]"
[[ "$got" != *"api key rotated"* ]] \
  || die "case3: accumulation leaked pre-marker pane content: [$got]"
ok_ "content preceding the caller's own marker is still unreachable"
[[ "$got" != *"$SECRET_AFTER"* ]] \
  || die "case3: read ran past the next [5dive-msg boundary: [$got]"
[[ "$got" != *"unrelated question"* ]] \
  || die "case3: the next message boundary did not stop the read: [$got]"
ok_ "the read still stops at the next [5dive-msg boundary"

# ===========================================================================
echo "case 4 — an id the caller never minted reads nothing"
# ===========================================================================
never=$(cmd_capture morpheus --after-id="deadbeefcafe")
[[ -z "$never" ]] || die "case4: an unknown marker returned content: [$never]"
ok_ "an unknown marker still yields an empty window"

# ===========================================================================
echo "case 5 — transcripts are root-only and per (uid, target, marker)"
# ===========================================================================
# Assert the PROPERTY (nothing for group or other), not the exact octal string.
# In production the dir lands under /var/lib/5dive, which is 2750, so the new dir
# inherits the setgid bit and reads 2700 — measured on a live host. An exact
# "700" compare passes here on a plain tmpdir and grades nothing where it counts.
mode_open_to_others() { echo $(( 8#$(stat -c %a "$1") & 8#77 )); }
[[ "$(mode_open_to_others "$FIVE_CAPTURE_ACC_DIR")" == "0" ]] \
  || die "case5: transcript dir is reachable by group/other (got $(stat -c %a "$FIVE_CAPTURE_ACC_DIR"))"
[[ "$(( 8#$(stat -c %a "$FIVE_CAPTURE_ACC_DIR") & 8#700 ))" == "$(( 8#700 ))" ]] \
  || die "case5: transcript dir is not owner-rwx (got $(stat -c %a "$FIVE_CAPTURE_ACC_DIR"))"
for t in "$FIVE_CAPTURE_ACC_DIR"/*; do
  [[ "$(mode_open_to_others "$t")" == "0" ]] \
    || die "case5: $t is readable by group/other (got $(stat -c %a "$t"))"
done
[[ -f "${FIVE_CAPTURE_ACC_DIR}/${SUDO_UID:-0}.morpheus.${MID}" ]] \
  || die "case5: transcript is not keyed by (uid, target, marker)"
ok_ "the transcript store is 0700/0600 and keyed so concurrent asks cannot collide"

# ===========================================================================
echo "case 5b — abandoned transcripts are pruned, live ones are not"
# ===========================================================================
# The store gains a file per ask and nothing else ever removes them, so the prune
# is what keeps this from growing without bound. Asserting it matters because a
# prune that quietly matches NOTHING looks identical to a prune that works — and
# one that matches too much would delete a transcript mid-ask, taking the marker
# with it and reintroducing the exact bug this ticket fixes.
stale="${FIVE_CAPTURE_ACC_DIR}/4242.morpheus.staleaaaa"
: > "$stale"; touch -d '3 hours ago' "$stale"
fresh_before=$(ls "$FIVE_CAPTURE_ACC_DIR" | wc -l)
FRAME="$F1"; cmd_capture morpheus --after-id="$MID" >/dev/null
[[ ! -e "$stale" ]] || die "case5b: an abandoned transcript (3h old) was not pruned"
[[ -f "${FIVE_CAPTURE_ACC_DIR}/${SUDO_UID:-0}.morpheus.${MID}" ]] \
  || die "case5b: the prune ate the LIVE transcript for the ask in flight"
(( fresh_before > 1 )) || die "case5b: fixture did not actually seed a stale file alongside a live one"
ok_ "a stale transcript is pruned while the in-flight one survives"

# ===========================================================================
echo "case 6 — the full SCOPED ask chain returns the seat's answer, not chrome"
# ===========================================================================
# What `cmd_ask` actually does on the scoped path: _capture -> _ask_accumulate ->
# _ask_reply_window with marker-slicing OFF (already sliced privileged-side) and
# the un-fenced fallback opted in. The question ECHO and the pane FURNITURE must
# both be subtracted, or a "reply" that is really our own text rides back.
base="$WORK/base"; msg="$WORK/msg"; cacc="$WORK/cacc"; : > "$cacc"
printf '%s\n' "──────────────────────────────" " > " " ? for shortcuts" "  claude 5 · 43% of weekly limit" > "$base"
printf '%s' "summarise the deploy plan, at length" > "$msg"
export FIVE_CAPTURE_ACC_DIR="$WORK/acc-chain"
E1=$(frame c1 \
  "  ${SECRET_BEFORE}" \
  "[5dive-msg from=neo id=${MID}] summarise the deploy plan, at length" \
  "  Sure. Here is the plan:" \
  "──────────────────────────────" \
  " > " \
  " ? for shortcuts" \
  "  claude 5 · 51% of weekly limit")
E2=$(frame c2 \
  "  Sure. Here is the plan:" \
  "  1. drain the queue" \
  "  2. roll the api" \
  "──────────────────────────────" \
  " > " \
  " ? for shortcuts" \
  "  claude 5 · 52% of weekly limit")
for f in "$E1" "$E2"; do
  FRAME="$f"
  chain=$(cmd_capture morpheus --after-id="$MID")
  chain=$(_ask_accumulate "$cacc" <<<"$chain")
  chain=$(_ask_reply_window "$base" "$msg" "$MID" 0 1 <<<"$chain")
done
# The pane's leading indent rides along: the un-fenced fallback subtracts the
# echo and the chrome, it does NOT dedent (only the fence branch does). That is
# the direct path's behaviour too — ask_capture_unit case 1 asserts "● PONG"
# with its glyph — so asserting the dedented form here would be asserting a
# change DIVE-1931 does not make.
[[ "$chain" == "  Sure. Here is the plan:
  1. drain the queue
  2. roll the api" ]] || die "case6: scoped chain did not return the seat's answer, got: [$chain]"
for needle in 'weekly limit' 'shortcuts' "$SECRET_BEFORE"; do
  [[ "$chain" != *"$needle"* ]] || die "case6: '$needle' leaked into the reply: [$chain]"
done
ok_ "the scoped chain returns the seat's text with chrome and the echo subtracted"

echo
echo "PASS — ${pass} assertions (DIVE-1931 scoped _capture accumulation)"
