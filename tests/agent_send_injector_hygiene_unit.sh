#!/usr/bin/env bash
# TIER: core
#
# DIVE-4246 — `inject_and_submit` (src/cmd_agent_runtime.sh), the injector behind
# `agent send` / `agent ask` / `_deliver`, owes the composer hygiene DIVE-4242
# gave the heartbeat's `_hb_send_line`:
#
#   1. CLEAR the composer (C-u) before typing. Whatever is already sitting there
#      — a previous injector's unsent remainder, a half-typed human line — is
#      otherwise PREPENDED to the payload and submitted as one line.
#   2. VERIFY the submit against the COMPOSER, not against the paste placeholder.
#      The pre-fix claude path polled `[Pasted text #N]` and returned 0 the moment
#      it cleared. A leftover TAIL clears it too: the pane measured 2026-09-10
#      15:43Z on ops read `❯ [Pasted text #7]irst (verify before relying…` — real,
#      NOT dim, sitting unsent — and that grep calls it submitted.
#
# rc 1 is the point of the whole thing: `send`/`ask`/`_deliver` render sent:false
# on it, so an unreceived message is reported as unreceived instead of receipted.
#
# Every arm grades an ACTION on a scripted pane: which keys the injector sent and
# which rc it returned. Ghost text (CC 2.1.267 promptSuggestion, DIM `ESC[2m`) is
# a fixture too, because reading it as unsent input would make the verify red on
# every idle seat. Two mutation arms prove the failing arms are live.
#
# Reserved-fake values only: seat 'seatx' does not exist; no live pane is touched
# (sudo is a function here). Pane fixtures are the same shapes measured live for
# DIVE-4242 (tests/heartbeat_send_line_verify_unit.sh) — the injector under test
# reads the same panes on the same seats, so the shapes carry over unchanged.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/send-injector-hygiene.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"
KEYS="$TMP/keys"; PANE_I="$TMP/pane_i"
PANES=()
_reset() { : >"$KEYS"; echo 0 >"$PANE_I"; rm -rf "$TMP/agent-seatx"; }
# Fake sudo: `sudo -u agent-x tmux send-keys ...` logs the keystroke; `capture-pane`
# returns the next scripted pane (the last one repeats). Counter lives in a file
# because capture-pane is called inside $(...) subshells.
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  # DIVE-4246 x DIVE-4214: the spool's own verbs run for real against $TMP (see
  # _a2a_queue_dir below), so "the message was queued" is graded on a file that
  # exists, not on a stub that says yes. Everything else keeps returning 0.
  case "${1:-}" in mkdir|tee|mv|rm|find|cat) "$@"; return $?;; esac
  [[ "${1:-}" == tmux ]] || return 0
  shift
  case "${1:-}" in
    send-keys) shift; while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) shift;; --) shift; break;; *) break;; esac; done
               printf '%s\n' "$*" >>"$KEYS"; return 0;;
    capture-pane) local i n; i=$(cat "$PANE_I"); n=${#PANES[@]}; (( i >= n )) && i=$((n-1))
               echo $(( $(cat "$PANE_I") + 1 )) >"$PANE_I"; printf '%b' "${PANES[$i]}"; return 0;;
  esac
  return 0
}
_agent_delivery_inbox()    { return 1; }   # no dispatcher inbox: the tmux path under test
_agent_pane_safe_to_type() { return 0; }
_hb_claude_pid()           { echo 4242; }  # claude path (Enter + composer verify)
# DIVE-4214 landed a busy-seat QUEUE in front of this injector: _a2a_should_queue
# reads _hb_agent_idle and, on rc 1 (busy) ONLY, spools the payload and returns 4
# without typing anything. Every arm below B1..B12 grades what the injector does
# once it has decided to TYPE, so the seat must be a seat that types — IDLE_RC=0.
# Left as the real predicate this harness would read the scripted panes (which
# carry no idle marker) as BUSY and silently grade the queue path instead: that
# is exactly the cross-PR hole quinn measured on the merged tree, where B4/B6/B11
# and the B12 MUTATION arm all went green-to-red without either branch changing.
# B13/B14 at the bottom grade the queue decision itself.
IDLE_RC=0
_hb_agent_idle()           { return "${IDLE_RC:-0}"; }
# B12 MUTATES _hb_verify_submit and must not leak that into the arms after it.
# Snapshot the real one here, while it is still the real one, and restore by eval.
_REAL_VERIFY_SUBMIT="$(declare -f _hb_verify_submit)"
# The spool lives under $TMP, not in a real seat's home.
_a2a_queue_dir()           { printf '%s\n' "$TMP/agent-${1}/.5dive/a2a-queue"; }
spooled()                  { find "$(_a2a_queue_dir "$1")" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
sleep()                    { :; }
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }
enters() { grep -cx 'Enter' "$KEYS"; }
E=$'\e'; NB=$'\xc2\xa0'   # CC renders "❯" + NO-BREAK SPACE (U+00A0), exactly as live panes show it
P_EMPTY="${E}[39m❯${NB} ${E}[39m\n  Opus 5 5h: 3%\n"
P_GHOST="${E}[39m❯${NB} ${E}[2mnext task${E}[0m\n  Opus 5 5h: 3%\n"
P_STUCK="${E}[38;5;246m❯${NB} ${E}[39m[Pasted text #7]irst (verify before relying)\n  Opus 5 5h: 3%\n"
P_LEFTOVER="${E}[39m❯${NB} ${E}[39mhalf a line the operator never sent\n  Opus 5 5h: 3%\n"
MSG='[from ops] pick DIVE-4246 back up'

# B1/B2 — clean submit: C-u FIRST, then the payload, then one Enter, rc 0.
_reset; PANES=("$P_EMPTY"); inject_and_submit seatx "$MSG"; rc=$?
grade "B1 clean submit returns 0 with exactly one Enter" "[[ $rc -eq 0 && \$(enters) -eq 1 ]]"
grade "B2 the injector clears the composer (C-u) BEFORE typing the payload" "[[ \$(sed -n 1p '$KEYS') == 'C-u' && \$(sed -n 2p '$KEYS') == '$MSG' ]]"

# B3 — C-u, never Escape. Escape on a seat that is mid-turn ABORTS the turn.
grade "B3 the clear is C-u, never Escape (Escape would abort a running turn)" "! grep -qx 'Escape' '$KEYS'"

# B4 — a leftover line in the composer is cleared, not prepended. The keys are the
# whole record: the payload is typed as its own send-keys after a C-u.
_reset; PANES=("$P_LEFTOVER" "$P_EMPTY"); inject_and_submit seatx "$MSG"; rc=$?
grade "B4 a composer holding an operator's half-typed line is cleared first, and the payload is typed alone" \
      "[[ \$(sed -n 1p '$KEYS') == 'C-u' && \$(sed -n 2p '$KEYS') == '$MSG' ]] && ! grep -q 'half a line' '$KEYS'"

# B5 — dim ghost text is not unsent input: one Enter, rc 0. Without the DIM
# exclusion every idle seat would fail the verify and every send would read false.
_reset; PANES=("$P_GHOST"); inject_and_submit seatx "$MSG"; rc=$?
grade "B5 dim ghost text is not read as unsent input (rc 0, one Enter)" "[[ $rc -eq 0 && \$(enters) -eq 1 ]]"

# B6 — tail sits after the first Enter, clears after the retry: rc 0, two Enters.
_reset; PANES=("$P_STUCK" "$P_EMPTY"); inject_and_submit seatx "$MSG"; rc=$?
grade "B6 a tail left after the first Enter is retried once and then accepted (rc 0, two Enters)" \
      "[[ $rc -eq 0 && \$(enters) -eq 2 ]]"

# B7 — tail survives both Enters: rc 1 (so the caller renders sent:false), and
# exactly two Enters — no five-Enter loop hammering a composer that is not taking.
_reset; PANES=("$P_STUCK" "$P_STUCK"); inject_and_submit seatx "$MSG"; rc=$?
grade "B7 a tail that survives both Enters returns 1 so the caller reports sent:false" "[[ $rc -eq 1 ]]"
grade "B8 ...and stops at two Enters rather than looping stray keystrokes into the pane" "[[ \$(enters) -eq 2 ]]"

# B9 — the shape the placeholder poll is BLIND to. P_STUCK still carries the
# `[Pasted text #N]` marker, so the pre-fix grep would at least keep retrying on
# it. Once the marker itself has scrolled off and only the TAIL is left in the
# composer, that grep matches nothing and the pre-fix path returns 0 on the first
# Enter — a receipt for a message still sitting unsent. B10 runs exactly that.
P_TAIL_NOPLACEHOLDER="${E}[39m❯${NB} ${E}[39mirst (verify before relying)\n  Opus 5 5h: 3%\n"
_reset; PANES=("$P_TAIL_NOPLACEHOLDER" "$P_TAIL_NOPLACEHOLDER"); inject_and_submit seatx "$MSG"; rc=$?
grade "B9 unsent text with NO paste placeholder — invisible to the pre-fix grep — now returns 1" "[[ $rc -eq 1 ]]"

# B10 — the pre-fix injector itself, on B9's pane, as the differential. This is
# the ORIGINAL body (placeholder poll, no C-u), not a mutation of the new one.
_prefix_inject() {
  local name="$1" payload="$2" tries=0 pane
  local user="agent-${name}"
  sudo -u "$user" tmux send-keys -t "agent-${name}" -l -- "$payload"
  while (( tries < 5 )); do
    sudo -u "$user" tmux send-keys -t "agent-${name}" Enter
    pane=$(sudo -u "$user" tmux capture-pane -p -t "agent-${name}" 2>/dev/null || true)
    grep -q '\[Pasted text #[0-9]' <<<"$pane" || return 0
    tries=$((tries+1))
  done
  return 1
}
_reset; PANES=("$P_TAIL_NOPLACEHOLDER" "$P_TAIL_NOPLACEHOLDER"); _prefix_inject seatx "$MSG"; rc=$?
grade "B10 differential: the pre-fix body returns 0 on that same stuck pane — the defect is real, not invented here" \
      "[[ $rc -eq 0 ]] && ! grep -qx 'C-u' '$KEYS'"

# B11 — non-claude TUIs keep the idle-state confirmation (no composer glyph to
# read there), and STILL get the C-u clear.
_hb_claude_pid()  { echo ""; }
# Stateful, and that is the honest model rather than a convenience: the injector
# reads idle TWICE on this path and wants a different answer each time. Before
# typing, rc 0 (idle) — a busy seat would have been spooled by DIVE-4214 and this
# code never reached. After the Enter, rc 1 (busy) — which is how the non-claude
# path confirms the submit took, since there is no composer glyph to read.
_B11_N="$TMP/b11n"; echo 0 >"$_B11_N"
_hb_agent_idle()  { local n; n=$(cat "$_B11_N"); echo $((n+1)) >"$_B11_N"; (( n == 0 )) && return 0; return 1; }
_reset; PANES=("$P_EMPTY"); inject_and_submit seatx "$MSG"; rc=$?
grade "B11 non-claude TUIs keep the idle-state confirmation and still get the C-u clear" \
      "[[ $rc -eq 0 && \$(sed -n 1p '$KEYS') == 'C-u' ]]"
_hb_claude_pid()  { echo 4242; }
_hb_agent_idle()  { return "${IDLE_RC:-0}"; }

# B12 — MUTATION: with the verify stubbed to always-pass, B7's stuck fixture
# returns 0 again on one Enter. Proves B7/B9 are graded by the verify, not by the
# fixture happening to be short.
_hb_verify_submit() { return 0; }
_reset; PANES=("$P_STUCK" "$P_STUCK"); inject_and_submit seatx "$MSG"; rc=$?
grade "B12 mutation: dropping the verify turns B7's rc back to 0 — the arm is live" "[[ $rc -eq 0 && \$(enters) -eq 1 ]]"

# --- B13/B14 — the seam with DIVE-4214, graded from THIS side --------------
# The composer hygiene is a thing this injector does to a pane. A BUSY seat has
# no pane it may touch: DIVE-4214 spools the payload and returns 4. So the whole
# hygiene sequence must be ABSENT there — not just the payload, the C-u and the
# Enter too, because a C-u into a running turn edits a composer the operator may
# be using and an Enter submits whatever it holds.
#
# This is the arm neither branch could have had: #866 wrote the hygiene and #862
# wrote the queue, each green alone, and the merged tree was red in both
# directions while `git merge-tree` reported no conflict. Grading the ORDERING
# from both sides is what makes that measurable from one branch.
eval "$_REAL_VERIFY_SUBMIT"   # undo B12's mutation — the real verify is back
IDLE_RC=1
_reset; PANES=("$P_EMPTY"); inject_and_submit seatx "$MSG"; rc=$?
grade "B13 a BUSY seat is spooled at rc 4 and NOTHING is typed — no C-u, no payload, no Enter" \
      "[[ $rc -eq 4 && ! -s '$KEYS' && \$(spooled seatx) -eq 1 ]]"

# B14 — the control for B13. With the queue switched off the SAME busy fixture
# types and submits, so B13 is graded by the queue decision rather than by the
# arm happening to reach no code at all.
_reset; PANES=("$P_EMPTY"); FIVE_A2A_QUEUE=off inject_and_submit seatx "$MSG"; rc=$?
grade "B14 control: with the queue off the same busy seat is typed to, C-u first (so B13 grades the ordering)" \
      "[[ $rc -eq 0 && \$(sed -n 1p '$KEYS') == 'C-u' && \$(sed -n 2p '$KEYS') == '$MSG' && \$(spooled seatx) -eq 0 ]]"
IDLE_RC=0

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
