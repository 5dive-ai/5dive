#!/usr/bin/env bash
# DIVE-6015 — a timed-out `agent ask` must not say "the reply fence was OPENED"
# just because the question's own echo is in the pane.
#
# The [reply-format] hint writes both markers ADJACENT
# (`<5dive-r:ID></5dive-r:ID>`) and the pane echoes the question, so the old
# `grep -qF "<5dive-r:ID>" acc_file` was true for every delivered ask. Measured on
# exact-swallow 2026-10-10: amir's first job timed out at 1200s with "the reply
# fence was OPENED but never completed … (try a smaller --poll-secs)" — and a seat
# that never answers at all got the same words. `_ask_timeout_diag` is the clause
# the timeout appends; this harness drives its three branches on pane fixtures.
#
#   D1  delivered, nothing printed (echo on one row) → DELIVERED, not OPENED
#   D2  the echo WRAPPED between the markers, the closer leading the next row
#       behind the TUI's box glyph → DELIVERED
#   D3  the echo wrapped at EVERY break position from right after the opener
#       to right before the closer's last `>` (19 shapes, e.g. `<|/5dive-r:`,
#       `</5dive|-r:`, `…ID|>`), right border glyph on the first row → DELIVERED
#   D4  the echo wrapped so the opener sits ALONE on its row, closer leading the
#       next → DELIVERED (the shape that looks most like a real opener)
#   O1  echo + the seat's own opener on a line of its own, answer half written,
#       no closer → OPENED
#   O2  echo + an inline opener with prose after it, no closer → OPENED
#   O3  echo + a seat-opened fence for ANOTHER ask id → DELIVERED (id-scoped)
#   U1  no question marker at all → DELIVERY failure
#   W1  the timeout path in cmd_ask calls _ask_timeout_diag (wiring)
#   DIVE-6414 — the SCOPED path, where the file holds only `_capture`'s window
#   AFTER the marker, so the marker itself is never in it:
#   S1  scoped, empty window → UNOBSERVABLE: no "DELIVERY failure", no pointer
#       at a warning this path never prints
#   S2  scoped, window holds anything (furniture after the marker) → DELIVERED
#   S3  scoped, the seat opened the fence → OPENED
#   P1  direct, undelivered, warning printed → points at the warning above
#   P2  direct, undelivered, no warning printed → does NOT point at one
#   W2  cmd_ask passes the scoped flag and the warned flag (wiring)
#   NC2 NEGATIVE CONTROL: the pre-6414 two-arg call on S1's fixture → UNDELIVERED
#   NC  NEGATIVE CONTROL: _ask_timeout_diag with the pre-fix check (bare grep for
#       the opener) reports OPENED on D1's fixture — D1 goes red on that tree
#
# Offline: pure functions over fixture files; no tmux, no sudo.
#
#   bash tests/ask_timeout_fence_diag_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh 2>/dev/null || true
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

WORK="$(mktemp -d)"
ID=e78392d6
Q="[5dive-msg from=first-job id=${ID} tier=standard] Roast my landing page and tell me what to fix first."
HINT="[reply-format] Put your answer between these two marker lines: <5dive-r:${ID}></5dive-r:${ID}> — the opening marker alone on one line, your answer next, the closing marker alone on the last line."
FOOTER=$'────────────────────────────────────────\n> \n────────────────────────────────────────\n  ? for shortcuts'

pane() { printf '%s\n' "$2" > "$WORK/$1"; printf '%s' "$WORK/$1"; }
kind() { # <diag> -> OPENED | DELIVERED | UNDELIVERED | ?
  case "$1" in
    *"reply fence was OPENED"*) echo OPENED ;;
    *"question was DELIVERED"*) echo DELIVERED ;;
    *"never seen in the pane"*) echo UNDELIVERED ;;
    *"not observable on the scoped path"*) echo UNOBSERVABLE ;;
    *) echo "?" ;;
  esac
}
expect() { # <arm> <want> <file> <label>
  local got; got=$(kind "$(_ask_timeout_diag "$ID" "$3")")
  [[ "$got" == "$2" ]] && ok_t "$1 $4 → $2" || bad_t "$1 $4" "want $2, got $got"
}

F_D1=$(pane d1 "> ${Q} ${HINT}
${FOOTER}")
expect D1 DELIVERED "$F_D1" "delivered, echo on one row, seat printed nothing"

# The pair is adjacent (no space to break at), so a composer's hard wrap lands
# between the markers or inside the closer.
F_D2=$(pane d2 "> ${Q} [reply-format] Put your answer between these two marker lines: <5dive-r:${ID}>
│ </5dive-r:${ID}> — the opening marker alone on one line, your answer next, the closing marker alone on the last line.
${FOOTER}")
expect D2 DELIVERED "$F_D2" "echo wrapped between the markers, box glyph before the closer"

# D3: every place the wrap can land, from right after the opener to right before
# the closer's last `>` — the break can leave `/`, `-`, `:` or `>` leading the
# next row, and those belong to the closer, not to the TUI's padding.
PAIR="<5dive-r:${ID}></5dive-r:${ID}>"
OPENER="<5dive-r:${ID}>"
D3_BAD=""; D3_N=0
for (( k = ${#OPENER}; k < ${#PAIR}; k++ )); do
  F_D3=$(pane "d3_$k" "│ > ${Q} [reply-format] Put your answer between these two marker lines: ${PAIR:0:k}  │
│ ${PAIR:k} — the opening marker alone on one line, your answer next, the closing marker alone on the last line. │
${FOOTER}")
  D3_N=$((D3_N+1))
  got=$(kind "$(_ask_timeout_diag "$ID" "$F_D3")")
  [[ "$got" == DELIVERED ]] || D3_BAD+=" @$k(${PAIR:0:k}|${PAIR:k}→$got)"
done
[[ -z "$D3_BAD" && "$D3_N" -eq $(( ${#PAIR} - ${#OPENER} )) ]] \
  && ok_t "D3 echo wrapped at each of the $D3_N break positions after the opener, right border glyph → DELIVERED" \
  || bad_t "D3 wrapped echo reported as a seat-opened fence" "of $D3_N:$D3_BAD"

F_D4=$(pane d4 "> ${Q} [reply-format] Put your answer between these two marker lines:
  <5dive-r:${ID}>
  </5dive-r:${ID}> — the opening marker alone on one line, your answer next, the closing marker alone on the last line.
${FOOTER}")
expect D4 DELIVERED "$F_D4" "echo wrapped with the opener alone on its row"

F_O1=$(pane o1 "> ${Q} ${HINT}

● <5dive-r:${ID}>
  Your hero says what you do, not why it matters. Fix that first:
  1. The headline
${FOOTER}")
expect O1 OPENED "$F_O1" "seat's own opener on its line, answer half written, no closer"

F_O2=$(pane o2 "> ${Q} ${HINT}

● <5dive-r:${ID}> The hero copy is the first thing to fix, because
${FOOTER}")
expect O2 OPENED "$F_O2" "seat's inline opener with prose after it, no closer"

F_O3=$(pane o3 "> ${Q} ${HINT}

● <5dive-r:aaaa1111>
  an answer to some other ask
${FOOTER}")
expect O3 DELIVERED "$F_O3" "an opener for ANOTHER ask id does not count"

F_U1=$(pane u1 "$FOOTER")
expect U1 UNDELIVERED "$F_U1" "nothing of the question in the pane"

# --- DIVE-6414: the scoped path -------------------------------------------
expect_s() { # <arm> <want> <file> <label>  (scoped=1, warned=0)
  local got; got=$(kind "$(_ask_timeout_diag "$ID" "$3" 1 0)")
  [[ "$got" == "$2" ]] && ok_t "$1 $4 → $2" || bad_t "$1 $4" "want $2, got $got"
}
F_S1=$(pane s1 "")
expect_s S1 UNOBSERVABLE "$F_S1" "scoped, _capture returned nothing"
s1=$(_ask_timeout_diag "$ID" "$F_S1" 1 0)
[[ "$s1" != *"DELIVERY failure"* && "$s1" != *"warning above"* && "$s1" == *"msg_id=${ID}"* ]] \
  && ok_t "S1 scoped clause asserts no delivery failure, names no unprinted warning, names the audit msg_id" \
  || bad_t "S1 scoped clause" "$s1"
F_S2=$(pane s2 "$FOOTER")
expect_s S2 DELIVERED "$F_S2" "scoped, the window opened (furniture after the marker)"
F_S3=$(pane s3 "● <5dive-r:${ID}>
  half an answer
${FOOTER}")
expect_s S3 OPENED "$F_S3" "scoped, the seat opened the fence"
p1=$(_ask_timeout_diag "$ID" "$F_U1" 0 1); p2=$(_ask_timeout_diag "$ID" "$F_U1" 0 0)
[[ "$p1" == *"warning above"* ]] && ok_t "P1 direct, warning printed → the clause points at it" \
  || bad_t "P1 direct warned" "$p1"
[[ "$(kind "$p2")" == UNDELIVERED && "$p2" != *"warning above"* ]] \
  && ok_t "P2 direct, no warning printed → still UNDELIVERED, but no pointer at a warning" \
  || bad_t "P2 direct unwarned" "$p2"
TO_SRC=$(awk '/DIVE-1901 iteration 2: say WHAT was seen/,/fail "\$E_TIMEOUT" "no idle reply/' src/cmd_agent_runtime.sh)
[[ "$TO_SRC" == *'_ask_timeout_diag "$msg_id" "$acc_file" "$use_scoped" "$ready_warned"'* ]] \
  && ok_t "W2 cmd_ask passes the scoped and warned flags" || bad_t "W2 wiring" "$(head -c 400 <<<"$TO_SRC")"
nc2=$(kind "$(_ask_timeout_diag "$ID" "$F_S1")")
[[ "$nc2" == UNDELIVERED ]] \
  && ok_t "NC2 NEGATIVE CONTROL: the pre-6414 call (no scoped flag) calls S1's window a DELIVERY failure — S1 is red there" \
  || bad_t "NC2 the unflagged call must misreport S1" "got $nc2"

# W1: the real timeout branch must use this function, not a local copy of the grep.
TIMEOUT_SRC=$(awk '/DIVE-1901 iteration 2: say WHAT was seen/,/fail "\$E_TIMEOUT" "no idle reply/' src/cmd_agent_runtime.sh)
if [[ "$TIMEOUT_SRC" == *'_ask_timeout_diag "$msg_id" "$acc_file"'* && "$TIMEOUT_SRC" != *'grep -qF "<5dive-r:'* ]]; then
  ok_t "W1 cmd_ask's timeout clause comes from _ask_timeout_diag, with no bare opener grep beside it"
else
  bad_t "W1 timeout wiring" "$(head -c 400 <<<"$TIMEOUT_SRC")"
fi

# NC: the pre-fix check, in place, must turn D1 red (else D1 grades nothing).
DIAG_SRC=$(declare -f _ask_timeout_diag)
eval "$(sed 's/_ask_fence_opened "\$mid" "\$f"/grep -qF "<5dive-r:${mid}>" "$f" 2>\/dev\/null/' <<<"$DIAG_SRC")"
if [[ "$(declare -f _ask_timeout_diag)" == *'grep -qF "<5dive-r:${mid}>"'* ]]; then
  ok_t "NC0 (anchor) the pre-fix grep is in place"
  nc=$(kind "$(_ask_timeout_diag "$ID" "$F_D1")")
  [[ "$nc" == OPENED ]] \
    && ok_t "NC1 NEGATIVE CONTROL: the pre-fix check calls D1's silent seat OPENED — D1 is red there" \
    || bad_t "NC1 the pre-fix check must misreport D1" "got $nc"
else
  bad_t "NC0 anchor" "the sed pattern no longer matches _ask_timeout_diag"
fi
eval "$DIAG_SRC"

echo
echo "PASS=${PASS} FAIL=${FAIL} (DIVE-6015 / DIVE-6414 ask timeout diagnosis)"
(( FAIL == 0 ))
