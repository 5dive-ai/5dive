#!/usr/bin/env bash
# TIER: nightly — 10.1s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-1901 iteration 2 — drive cmd_ask ITSELF, both dispatch branches, under set -u.
#
# WHY THIS FILE EXISTS. The other two ask suites test the pure helpers
# (_ask_accumulate / _ask_reply_window) and nothing else, so every line of
# WIRING around them — flag parsing, variable scope, which branch passes what —
# was untested. That gap shipped a crash: `allow_unfenced` was declared in
# cmd_send instead of cmd_ask, so under `set -u` the DIRECT branch died with
# "allow_unfenced: unbound variable" before a single frame was captured. The
# scoped branch reads the same variable one line earlier and would have died
# too; neither was reachable from a helper-level test.
#
# The bug sat exclusively on the branch the failing live case takes — the branch
# this whole iteration exists to fix — and a live seat was spent discovering it.
# So: stub the world, run the real cmd_ask, assert the string it prints.
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
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh 2>/dev/null || true
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh

pass=0
ok_() { pass=$((pass+1)); echo "  ok: $1"; }
die() { echo "FAIL: $*" >&2; exit 1; }

# The frame counter lives in a FILE, not a variable. capture-pane is called from
# a command substitution, i.e. a subshell, so `FRAME_N=$((FRAME_N+1))` there is
# discarded and the stub pane never advances — the harness sits on frame 1
# forever and every run times out. (Found in about ten seconds by pointing the
# new FIVE_ASK_DEBUG_DIR at this very test: the dumped transcript showed the
# mid-write frame and nothing after it. The instrument works.)
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FRAME_F="$WORK/frame_n"; echo 0 > "$FRAME_F"

JSON_MODE=0
MID="feed1234"
echo 0 > "$FRAME_F"

# A pane that answers on the third poll, fenced, with furniture throughout.
_frame() {
  local FRAME_N; FRAME_N=$(( $(cat "$FRAME_F") + 1 )); echo "$FRAME_N" > "$FRAME_F" 
  printf '%s\n' "  antigravity · gemini-3.6-flash" \
                "> [5dive-msg from=dev id=${MID}] ping [reply-format] Put your answer" \
                "  between these two marker lines: <5dive-r:${MID}></5dive-r:${MID}> — the" \
                "  opening marker alone on one line, your answer next, the closing marker" \
                "  alone on the last line."
  if (( FRAME_N >= 3 )); then
    printf '%s\n' "◆ <5dive-r:${MID}>" "  WIRED-OK" "  </5dive-r:${MID}>"
  else
    printf '%s\n' "  <5dive-r:"   # mid-write: must NOT be read as an answer
  fi
  printf '%s\n' "────────────────────────────" ">" "────────────────────────────" \
                "? for shortcuts                    Gemini 3.6 Flash · high"
}

# Everything that leaves the process is stubbed; nothing here touches tmux, sudo,
# the registry or the network.
sudo() {
  case "$*" in
    *"tmux has-session"*)  return 0 ;;
    *"tmux capture-pane"*) _frame ;;
    *"agent _deliver"*)    return 0 ;;
    *"agent _capture"*)    _frame ;;
    *)                     return 0 ;;
  esac
}
require_agent()             { :; }
wait_agent_input_ready()    { return 0; }
inject_and_submit()         { return 0; }
mirror_interagent_outbound(){ :; }
auto_sender_from_sudo()     { echo dev; }
gen_msg_id()                { echo "$MID"; }
step()                      { :; }

# --- the crash that shipped -------------------------------------------------
a2a_needs_scoped() { return 1; }   # DIRECT branch — where it died
echo 0 > "$FRAME_F"
got=$(cmd_ask ada "ping" --from=dev --timeout=30 --idle-secs=1 --poll-secs=1) \
  || die "cmd_ask DIRECT branch failed outright (set -u crash?)"
[[ "$got" == "WIRED-OK" ]] || die "direct branch: expected WIRED-OK, got: [$got]"
ok_ "cmd_ask runs the DIRECT branch under set -u and returns the fenced reply"

a2a_needs_scoped() { return 0; }   # SCOPED branch
echo 0 > "$FRAME_F"
got=$(cmd_ask ada "ping" --from=dev --timeout=30 --idle-secs=1 --poll-secs=1) \
  || die "cmd_ask SCOPED branch failed outright (set -u crash?)"
[[ "$got" == "WIRED-OK" ]] || die "scoped branch: expected WIRED-OK, got: [$got]"
ok_ "cmd_ask runs the SCOPED branch under set -u and returns the fenced reply"

# --- the flag exists and reaches the extractor ------------------------------
a2a_needs_scoped() { return 1; }
echo 0 > "$FRAME_F"
got=$(cmd_ask ada "ping" --from=dev --timeout=30 --idle-secs=1 --poll-secs=1 --allow-unfenced) \
  || die "--allow-unfenced crashed"
[[ -n "$got" ]] || die "--allow-unfenced returned nothing"
ok_ "--allow-unfenced parses and reaches the extractor without unbound reads"


# --- the escape hatch must not be reachable from a ballot -------------------
# "--allow-unfenced becomes the thing everyone sets" is how this fix decays, and
# the governance path is where it would matter. Refused in code, not convention.
# NB the subshell is load-bearing: `fail` exits, and cmd_ask is a function, so
# calling it bare in an `if` would terminate this whole script instead of
# failing the branch -- the remaining assertions would silently never run.
if ( cmd_ask ada "vote" --from=council --allow-unfenced --timeout=5 ) >/dev/null 2>&1; then
  die "a council ask was allowed to opt back into pane scraping"
fi
ok_ "--allow-unfenced is REFUSED when the ask comes from council"

echo
echo "PASS — ${pass} assertions (DIVE-1901 cmd_ask wiring)"
