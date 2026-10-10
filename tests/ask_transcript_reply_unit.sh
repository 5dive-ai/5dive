#!/usr/bin/env bash
# TIER: nightly — ~21s of real poll/idle sleeps plus a 6s timeout control; the sibling ask_cmd_wiring_unit.sh is nightly for the same reason.
# DIVE-5964 — `agent ask` must return an answer TALLER THAN THE PANE.
#
# A Claude seat runs on tmux's alternate screen (history_size 0, no scrollback)
# and paints a finished answer in one go at the end of its turn. An answer longer
# than the 24-row screen puts its opening marker above the top row in the first
# frame that shows it, so no poll ever sees `<5dive-r:id>` and the rail waits out
# --timeout while the seat has answered. Measured on exact-swallow 2026-10-10: a
# hire's 26-row first-job roast, closer on screen, opener never — the first job
# failed and no task reached Tasks. The fix reads the fence from the seat's own
# session transcript when the pane holds no whole fence.
#
# Offline: tmux, sudo and the registry are stubbed; the pane is a frame fixture
# and the transcript is a fixture jsonl. The python transcript reader is REAL
# (the sudo stub drops `-n -u agent-x` and runs it as the test user).
#
#   L1  direct ask, first-job argv shape (--json, --message-file, --timeout,
#       --from=first-job): a 30-line answer whose opener never reaches the pane
#       comes back WHOLE as .data.reply — the field _first_job_ask reads, and
#       agent_first_job_unit.sh T1 shows that field becoming the done task result.
#   L2  the same long answer on the SCOPED branch (real cmd_capture behind the
#       sudo stub): `_capture` appends the transcript fence, the caller takes it.
#   NC  NEGATIVE CONTROL: with the transcript read reverted (helper → rc 1), L1's
#       exact arm TIMES OUT and names the half-seen fence — the arm sees the bug.
#   S1  a short answer the pane shows whole returns as before (pane text, even
#       with a transcript present — the pane stays the primary read).
#   S2  council-shaped direct ask (plain mode, --from=council) still returns the
#       pane fence; a2a/council callers use this same cmd_ask (see also
#       ask_cmd_wiring_unit.sh, capture_scope_unit.sh, ask_capture_unit.sh).
#   F1  no fabrication: a transcript holding only the ECHOED instruction (adjacent
#       markers) or another ask's completed fence never returns as this reply.
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
export FIVE_ASK_TRANSCRIPT_ROOT="$WORK/projects" FIVE_CAPTURE_ACC_DIR="$WORK/acc" FIVE_CAPTURE_MINT_DIR="$WORK/mint"
TX_DIR="$FIVE_ASK_TRANSCRIPT_ROOT/-home-claude-projects"; TX="$TX_DIR/88ec8b6d.jsonl"
FRAME_F="$WORK/frame_n"
MID="e78392d6"
MODE=long          # long | short

# The answer: 30 rows, taller than the 24-row screen.
ANSWER=$(for i in $(seq 1 30); do printf '%d. roast point %d: the hero copy says nothing\n' "$i" "$i"; done)
ANSWER="${ANSWER%$'\n'}"

rec() { jq -cn --arg t "$1" --arg ty "$2" '{type:$ty, message:{role:$ty, content:[{type:"text", text:$t}]}}'; }
tx_reset() {
  rm -rf "$FIVE_ASK_TRANSCRIPT_ROOT"; mkdir -p "$TX_DIR"
  { rec "[5dive-msg from=first-job id=${MID}] Roast my homepage [reply-format] Put your answer between these two marker lines: <5dive-r:${MID}></5dive-r:${MID}> — the opening marker alone on one line." user
    jq -cn '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", id:"t1", name:"WebFetch", input:{url:"https://example.com"}}]}}'
    rec "Let me look at the homepage first." assistant
  } > "$TX"
}
tx_answer() { rec "<5dive-r:${MID}>"$'\n'"${ANSWER}"$'\n'"</5dive-r:${MID}>" assistant >> "$TX"; }

FOOTER=("────────────────────────────────────────" ">" "────────────────────────────────────────" "  ? for shortcuts                 Opus 5.5")
_frame() {
  local n; n=$(( $(cat "$FRAME_F") + 1 )); echo "$n" > "$FRAME_F"
  if (( n < 3 )); then
    printf '%s\n' "> [5dive-msg from=first-job id=${MID}] Roast my homepage [reply-format] Put" \
                  "  your answer between these two marker lines: <5dive-r:${MID}></5dive-r:${MID}>" \
                  "  — the opening marker alone on one line." "" "✻ Baking… (esc to interrupt)" "${FOOTER[@]}"
    return
  fi
  if [[ "$MODE" == short ]]; then
    printf '%s\n' "> [5dive-msg from=first-job id=${MID}] Roast my homepage" "" \
                  "● <5dive-r:${MID}>" "  PANE-SHORT-OK" "  </5dive-r:${MID}>" "" "${FOOTER[@]}"
    (( n == 3 )) && rec "<5dive-r:${MID}>"$'\n'"TRANSCRIPT-SHORT"$'\n'"</5dive-r:${MID}>" assistant >> "$TX"
    return
  fi
  # LONG: the reply paints at once; the 24-row screen shows rows 13..30 and the
  # closer — the opener and the question marker are already above the top row.
  (( n == 3 )) && tx_answer
  sed -n '13,30p' <<<"$ANSWER" | sed 's/^/  /'
  printf '%s\n' "  </5dive-r:${MID}>" "" "✻ Baked for 26s" "${FOOTER[@]}"
}

sudo() {
  case " $* " in
    *" has-session "*)  return 0 ;;
    *" capture-pane "*) _frame; return 0 ;;
    *" agent _deliver "*) printf '%s\n' '{"ok":true,"data":{"delivered":true}}'; return 0 ;;
    *" agent _capture "*) ( unset SUDO_UID; JSON_MODE=0; cmd_capture ada --after-id="$MID" ) 2>/dev/null; return 0 ;;
    *" python3 -c "*)   shift 3; "$@"; return ;;   # -n -u agent-<x> python3 … → run the real reader
  esac
  return 0
}
require_root()              { :; }
require_agent()             { :; }
wait_agent_input_ready()    { return 0; }
inject_and_submit()         { return 0; }
mirror_interagent_outbound(){ :; }
_buzz_mirror_outbound()     { :; }
_envelope_caller()          { echo first-job; }
envelope_tier()             { echo admin; }
envelope_via()              { :; }
envelope_provenance()       { echo corroborated; }
_agent_refuse_peer_forgery(){ :; }
a2a_round_guard()           { :; }
_wake_sender_vouchable()    { return 1; }
gen_msg_id()                { echo "$MID"; }
step()                      { :; }
a2a_needs_scoped()          { return 1; }

PF="$WORK/prompt"; printf 'Roast my homepage' > "$PF"
first_job_ask() {   # the argv _first_job_ask uses, with a short timeout
  ( JSON_MODE=1; cmd_ask ada --message-file="$PF" --timeout="${1:-40}" --from=first-job --idle-secs=1 --poll-secs=1 ) 2>&1
}
arm() { echo 0 > "$FRAME_F"; rm -rf "$FIVE_CAPTURE_ACC_DIR"; tx_reset; }

# ── L1 ───────────────────────────────────────────────────────────────────────
MODE=long; arm
out=$(first_job_ask 40); rc=$?
got=$(jq -r '.data.reply // empty' <<<"$out" 2>/dev/null)
[[ $rc -eq 0 && "$got" == "$ANSWER" ]] \
  && ok_t "L1 a 30-row answer whose opener never reached the 24-row pane returns WHOLE as .data.reply (first-job argv)" \
  || bad_t "L1 long answer, direct" "rc=$rc out=${out:0:400}"
grep -q '^1\. roast point 1:' <<<"$got" && ! grep -q '<5dive-r' <<<"$got" \
  && ok_t "L1b the reply starts at row 1 (never on screen) and carries no marker" \
  || bad_t "L1b reply head" "${got:0:200}"

# ── L2 ───────────────────────────────────────────────────────────────────────
a2a_needs_scoped() { return 0; }
MODE=long; arm
out=$(first_job_ask 40); rc=$?
got=$(jq -r '.data.reply // empty' <<<"$out" 2>/dev/null)
[[ $rc -eq 0 && "$got" == "$ANSWER" ]] \
  && ok_t "L2 the same long answer returns WHOLE on the SCOPED branch (real cmd_capture appends the transcript fence)" \
  || bad_t "L2 long answer, scoped" "rc=$rc out=${out:0:400}"
a2a_needs_scoped() { return 1; }

# ── NC ───────────────────────────────────────────────────────────────────────
MODE=long; arm
out=$( _ask_transcript_reply() { return 1; }; first_job_ask 6 ); rc=$?
[[ $rc -eq $E_TIMEOUT && "$out" == *"no idle reply"* && "$out" == *"msg_id=${MID}"* ]] \
  && ok_t "NC with the transcript read reverted, L1's arm TIMES OUT (rc $E_TIMEOUT) — the arm sees the bug" \
  || bad_t "NC negative control did not time out" "rc=$rc out=${out:0:400}"

# ── S1 / S2 ──────────────────────────────────────────────────────────────────
MODE=short; arm
out=$(first_job_ask 40); rc=$?
got=$(jq -r '.data.reply // empty' <<<"$out" 2>/dev/null)
[[ $rc -eq 0 && "$got" == "PANE-SHORT-OK" ]] \
  && ok_t "S1 a short answer the pane shows whole returns the pane fence, as before (transcript present but not preferred)" \
  || bad_t "S1 short answer" "rc=$rc out=${out:0:300}"
MODE=short; arm
got=$( ( JSON_MODE=0; cmd_ask ada "vote?" --from=council --timeout=40 --idle-secs=1 --poll-secs=1 ) 2>&1 ); rc=$?
[[ $rc -eq 0 && "$got" == "PANE-SHORT-OK" ]] \
  && ok_t "S2 a council-shaped direct ask still returns the pane fence" \
  || bad_t "S2 council ask" "rc=$rc out=${got:0:300}"

# ── F1 ───────────────────────────────────────────────────────────────────────
tx_reset
rec "You asked: put your answer between <5dive-r:${MID}></5dive-r:${MID}> markers." assistant >> "$TX"
rec "<5dive-r:aaaa1111>"$'\n'"OTHER-ASK"$'\n'"</5dive-r:aaaa1111>" assistant >> "$TX"
got=$(_ask_transcript_reply ada "$MID"); rc=$?
[[ $rc -ne 0 && -z "$got" ]] \
  && ok_t "F1 an echoed adjacent-marker instruction and another id's fence return nothing for this id" \
  || bad_t "F1 fabrication" "rc=$rc got=[$got]"
got=$(_ask_transcript_reply ada aaaa1111)
[[ "$got" == "OTHER-ASK" ]] && ok_t "F1b the other id's own fence is still readable by ITS id" || bad_t "F1b" "[$got]"
got=$(_ask_transcript_reply ada 'x;rm') ; rc=$?
[[ $rc -ne 0 && -z "$got" ]] && ok_t "F1c a non-alnum id is refused before any read" || bad_t "F1c" "rc=$rc"

echo
echo "PASS=${PASS} FAIL=${FAIL} (DIVE-5964 ask transcript reply)"
(( FAIL == 0 ))
