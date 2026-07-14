#!/usr/bin/env bash
# DIVE-1211 unit harness for per-runtime idle-prompt markers.
#
# Regression guard for the claude-only ❯ bug: _hb_agent_idle's pane-scrape
# fallback used to hardcode `grep -q ❯`, which no non-claude TUI renders, so
# codex/grok/agy/opencode were classified "active" every heartbeat tick and
# never nudged to work their board tasks. _hb_idle_marker now returns a
# per-runtime marker (empty = trust byte-stability alone). This asserts the
# marker table and that each marker matches a real IDLE pane sample while
# rejecting a mid-turn / dialog sample (so a busy agent can't false-read idle).
# Run: bash tests/heartbeat_idle_marker_unit.sh  (no root, no network, no tmux).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# marker-present-in-sample helper mirrors the guard in _hb_agent_idle:
#   [[ -z "$marker" ]] || grep -qE "$marker" <<<"$pane"
idle_reads() {  # <type> <pane-sample> -> rc 0 if the marker guard would pass
  local m; m=$(_hb_idle_marker "$1")
  [[ -z "$m" ]] && return 0
  grep -qF "$m" <<<"$2"
}
assert_idle()     { if idle_reads "$1" "$2"; then ok_t "$3"; else bad_t "$3 (should read idle)"; fi; }
assert_not_idle() { if idle_reads "$1" "$2"; then bad_t "$3 (false-idled a busy pane)"; else ok_t "$3"; fi; }

# --- Marker table --------------------------------------------------------------
[[ "$(_hb_idle_marker claude)"      == '❯' ]]              && ok_t "claude marker = ❯"            || bad_t "claude marker" "got '$(_hb_idle_marker claude)'"
[[ "$(_hb_idle_marker codex)"       == '›' ]]              && ok_t "codex marker = ›"             || bad_t "codex marker" "got '$(_hb_idle_marker codex)'"
[[ "$(_hb_idle_marker antigravity)" == '? for shortcuts' ]] && ok_t "antigravity marker = ? for shortcuts" || bad_t "antigravity marker" "got '$(_hb_idle_marker antigravity)'"
[[ -z "$(_hb_idle_marker grok)" ]]     && ok_t "grok marker empty (byte-stability alone)"     || bad_t "grok marker should be empty" "got '$(_hb_idle_marker grok)'"
[[ -z "$(_hb_idle_marker opencode)" ]] && ok_t "opencode marker empty (byte-stability alone)" || bad_t "opencode marker should be empty" "got '$(_hb_idle_marker opencode)'"
[[ -z "$(_hb_idle_marker "")" ]]       && ok_t "unknown/empty type marker empty"              || bad_t "empty type should be empty" "got '$(_hb_idle_marker "")'"

# --- Real IDLE pane samples (captured live 2026-07-14) must READ idle ----------
CODEX_IDLE=$'─ Worked for 2m 07s ───\n› Improve documentation in @filename\n  gpt-5.6-sol default · /home/claude/projects'
AGY_IDLE=$'────────\n>\n────────\n? for shortcuts                       Gemini 3.1 Pro (High)'
CLAUDE_IDLE=$'> \n❯ \n  ? for shortcuts'
assert_idle codex       "$CODEX_IDLE"  "codex idle pane reads idle"
assert_idle antigravity "$AGY_IDLE"    "agy idle pane reads idle"
assert_idle claude      "$CLAUDE_IDLE" "claude idle pane reads idle"

# grok/opencode have no marker -> the guard passes on any pane (byte-stability
# upstream is the real gate); assert the fix at least stops reading them ACTIVE.
assert_idle grok     "some grok tui at rest" "grok reads idle on stable pane (was never-idle before)"
assert_idle opencode "opencode tui at rest"  "opencode reads idle on stable pane"

# --- Mid-turn / dialog samples must NOT read idle (no false-idle of busy work) --
CODEX_BUSY=$'• Working (12s · esc to interrupt)\n  └ reading files'
AGY_MIDTURN=$'────────\n> analysing the repo\n────────\nesc to cancel                         Gemini 3.1 Pro (High)'
CLAUDE_DIALOG=$'Do you want to proceed?\n  1. Yes\n  2. No\n(the composer prompt is hidden behind the dialog)'
assert_not_idle codex       "$CODEX_BUSY"    "codex mid-turn does NOT read idle"
assert_not_idle antigravity "$AGY_MIDTURN"   "agy mid-turn (esc to cancel) does NOT read idle"
assert_not_idle claude      "$CLAUDE_DIALOG" "claude dialog (no ❯) does NOT read idle"

echo "-----"
printf 'idle-marker: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
