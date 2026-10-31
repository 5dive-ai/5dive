#!/usr/bin/env bash
# DIVE-7417: an OpenRouter seat on openai/gpt-6-luna answers, and `agent ask`
# times out anyway. The six fixtures are the panes init-smoke dumped on the six
# hermes/codex cells of dispatch run 41210111920 (both OSes), verbatim. Every
# seat had the right sum; every one copied the hint's ADJACENT marker pair as its
# opening line, and three used it (or a doubled closer) to close:
#
#     • <5dive-r:ID></5dive-r:ID>        <5dive-r:ID></5dive-r:ID>
#       808                              817
#       </5dive-r:ID>                    <5dive-r:ID></5dive-r:ID>
#
# The extractor skipped that first line as the question's echo (an adjacent pair
# encloses nothing), so nothing came back and the cell failed at step=reply.
#
# Every "returns nothing" assertion has a liveness twin on the same shape, so an
# extractor that returns nothing for everything cannot pass.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${W:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh

F=tests/fixtures/dive7417-copied-fence
pass=0 fails=0 dirty=0
ok_() { if (( dirty )); then dirty=0; return; fi; pass=$((pass+1)); echo "  ok: $1"; }
bad() { echo "FAIL: $*" >&2; fails=$((fails+1)); dirty=1; }

W="$(mktemp -d)"
base="$W/base"; msg="$W/msg"
: > "$base"
hint() { printf '[reply-format] Put your answer between these two marker lines: <5dive-r:%s></5dive-r:%s> — the opening marker alone on one line, your answer next, the closing marker alone on the last line.' "$1" "$1"; }
window() { _ask_reply_window "$base" "$msg" "$1" 1 0; }

echo "case 1 — the six live panes return the seat's answer"
for pair in 8497ea29:808 bf1a4bb0:820 fc3a041c:1098 8b4db448:817 11211e59:998 5a2737a1:1102; do
  mid=${pair%%:*} want=${pair#*:}
  printf 'What is the sum? Reply with only the number. %s' "$(hint "$mid")" > "$msg"
  got=$(window "$mid" < "$F/pane-$mid.txt")
  [[ "$got" == "$want" ]] || bad "case1 $mid: expected [$want], got: [$got]"
  ok_ "pane $mid returns $want"
done

echo "case 2 — the same panes with the answer cut off return NOTHING"
# Keep everything up to the seat's first pair line, so only the question echo and
# the seat's bare opener remain: a mid-write frame. Anything returned here is the
# echo or chrome coming back as an answer.
for mid in 8497ea29 fc3a041c 8b4db448; do
  printf 'What is the sum? %s' "$(hint "$mid")" > "$msg"
  got=$(awk -v p="<5dive-r:${mid}></5dive-r:${mid}>" 'index($0, p) && $0 !~ /between/ { print; exit } { print }' "$F/pane-$mid.txt" | window "$mid") || got=""
  [[ -z "$got" ]] || bad "case2 $mid: a frame with no answer returned: [$got]"
  ok_ "pane $mid cut at the seat's opener returns nothing"
done

echo "case 3 — a WRAPPED echo that isolates the pair on its own row"
# The composer may break the hint right before and right after the pair, which
# makes the echo's pair look like a seat's pair line. The hint's tail then sits
# inside the block, and that is what refuses it.
MID=ab12cd34
printf 'vote please %s' "$(hint $MID)" > "$msg"
echo_frame=$(printf '%s\n' \
  "▌ [5dive-msg from=ask id=${MID}] vote please [reply-format] Put your" \
  "▌ answer between these two marker lines:" \
  "▌ <5dive-r:${MID}></5dive-r:${MID}> —" \
  "▌ the opening marker alone on one line, your answer next, the closing" \
  "▌ marker alone on the last line.")
got=$(window "$MID" <<<"$echo_frame") || got=""
[[ -z "$got" ]] || bad "case3: the wrapped echo was returned: [$got]"
ok_ "the isolated echo pair alone returns nothing"

got=$(printf '%s\n%s\n' "$echo_frame" "<5dive-r:${MID}></5dive-r:${MID}>" | window "$MID") || got=""
[[ -z "$got" ]] || bad "case3: echo + the seat's bare opener returned: [$got]"
ok_ "the isolated echo pair plus a seat opener with no answer yet returns nothing"

got=$(printf '%s\n%s\n' "$echo_frame" "<5dive-r:${MID}></5dive-r:${MID}>" "nay" "<5dive-r:${MID}></5dive-r:${MID}>" | window "$MID")
[[ "$got" == "nay" ]] || bad "case3-liveness: the reply after the wrapped echo was lost, got: [$got]"
ok_ "and the same frame with the seat's full reply returns it"

echo "case 4 — an EMPTY copied fence returns nothing"
printf 'q %s' "$(hint $MID)" > "$msg"
got=$(printf '%s\n' "<5dive-r:${MID}></5dive-r:${MID}>" "   " "</5dive-r:${MID}>" | window "$MID") || got=""
[[ -z "$got" ]] || bad "case4: an empty block returned: [$got]"
ok_ "a pair line closed around blank rows is not a reply"

got=$(printf '%s\n' "<5dive-r:${MID}></5dive-r:${MID}>" "  line one" "    line two" "</5dive-r:${MID}>" | window "$MID")
[[ "$got" == "line one
  line two" ]] || bad "case4-liveness: multi-line body wrong, got: [$got]"
ok_ "a multi-line reply in a copied fence comes back dedented"

echo
if (( fails )); then
  echo "FAILED — ${fails} assertion(s) red, ${pass} green (DIVE-7417 copied fence)" >&2
  exit 1
fi
echo "PASS — ${pass} assertions (DIVE-7417 copied fence)"
