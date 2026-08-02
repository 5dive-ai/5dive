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
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
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
[[ "$(_hb_idle_marker devin)"       == 'Ask Devin' ]]      && ok_t "devin marker = Ask Devin (composer placeholder, not a glyph)" || bad_t "devin marker" "got '$(_hb_idle_marker devin)'"
[[ -z "$(_hb_idle_marker grok)" ]]     && ok_t "grok marker empty (byte-stability alone)"     || bad_t "grok marker should be empty" "got '$(_hb_idle_marker grok)'"
[[ -z "$(_hb_idle_marker opencode)" ]] && ok_t "opencode marker empty (byte-stability alone)" || bad_t "opencode marker should be empty" "got '$(_hb_idle_marker opencode)'"
[[ -z "$(_hb_idle_marker "")" ]]       && ok_t "unknown/empty type marker empty"              || bad_t "empty type should be empty" "got '$(_hb_idle_marker "")'"

# --- Real IDLE pane samples (captured live 2026-07-14) must READ idle ----------
CODEX_IDLE=$'─ Worked for 2m 07s ───\n› Improve documentation in @filename\n  gpt-5.6-sol default · /home/claude/projects'
AGY_IDLE=$'────────\n>\n────────\n? for shortcuts                       Gemini 3.1 Pro (High)'
CLAUDE_IDLE=$'> \n❯ \n  ? for shortcuts'
# devin 3000.2.17, captured live 2026-07-27. Note ❭ (U+276D) in BOTH the
# composer and the trust dialog's selection cursor — that pair is why devin's
# marker is prose rather than the glyph (see the note in cmd_agent_runtime.sh).
DEVIN_IDLE=$'\u2800\u2834\u283e\u2836\u2844  Devin CLI\n  v3000.2.17 \u00b7 Pro \u00b7 100% remaining\n\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n\u276d Ask Devin to build features, fix bugs, or work on your code\n\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\nSWE-1.7 Medium'
DEVIN_TRUST=$'Do you trust the authors of this directory?\nFor security, devin should not be run in directories with untrusted content.\n\u276d 1 Yes, trust /home/claude/projects\n\u00b7 2 No, exit'
DEVIN_BUSY=$'\u23fa Ran command\n  \u2502 $ npm test\n\u25e6 Working... (12s \u2022 esc to interrupt)'

assert_idle codex       "$CODEX_IDLE"  "codex idle pane reads idle"
assert_idle antigravity "$AGY_IDLE"    "agy idle pane reads idle"
assert_idle claude      "$CLAUDE_IDLE" "claude idle pane reads idle"
assert_idle devin       "$DEVIN_IDLE"  "devin idle pane reads idle"

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
assert_not_idle devin       "$DEVIN_BUSY"    "devin mid-turn does NOT read idle"
# The one that matters: devin's trust dialog draws ❭ as its selection cursor.
# A glyph-based marker reads that as a composer and the send path types the next
# inter-agent message into a TRUST PROMPT — the gh#214 shape, from the other end.
assert_not_idle devin       "$DEVIN_TRUST"   "devin TRUST DIALOG does NOT read idle (❭ is also a menu cursor)"

# --- ❯ / ❭ are two codepoints apart and near-identical in most fonts. Assert the
# markers cannot cross-match in either direction, whatever the font suggests.
assert_not_idle claude "$DEVIN_IDLE"  "devin pane does NOT satisfy claude's ❯ marker"
assert_not_idle devin  "$CLAUDE_IDLE" "claude pane does NOT satisfy devin's marker"

# --- DIVE-1528: send-path readiness must be a SUPERSET of the idle markers ------
# The send injector uses wait_agent_input_ready -> _agent_pane_input_ready (same
# file). It fell behind _hb_idle_marker: codex "›" was an idle marker but NOT a
# readiness marker, so every send to an idle codex agent timed out 45s and warned
# "input prompt not detected — best-effort (may be lost)". These assert the two
# stay in lockstep: every runtime whose IDLE sample reads idle must ALSO read
# input-ready, or the send path silently regresses for that TUI.
assert_ready() { if _agent_pane_input_ready "$2"; then ok_t "$3"; else bad_t "$3 (send path would time out)"; fi; }
assert_ready codex       "$CODEX_IDLE"  "codex idle pane reads INPUT-READY (DIVE-1528 regression)"
assert_ready antigravity "$AGY_IDLE"    "agy idle pane reads input-ready"
assert_ready claude      "$CLAUDE_IDLE" "claude idle pane reads input-ready"
assert_ready devin       "$DEVIN_IDLE"  "devin idle pane reads INPUT-READY (send path)"
# and the send path must refuse the trust dialog for the same reason as above
if _agent_pane_input_ready "$DEVIN_TRUST"; then
  bad_t "devin trust dialog must NOT read input-ready (would type into a trust prompt)"
else ok_t "devin trust dialog does NOT read input-ready"; fi
# lockstep: any non-empty idle marker must be inside the readiness set.
for _t in claude codex antigravity devin; do
  _m=$(_hb_idle_marker "$_t")
  if [[ -z "$_m" ]] || _agent_pane_input_ready "$_m"; then ok_t "readiness ⊇ idle marker for $_t"
  else bad_t "readiness ⊇ idle marker for $_t" "'$_m' is an idle marker but NOT a readiness marker (drift)"; fi
done
# A bare boot/blank pane (no marker at all) must NOT read ready — that's the boot
# race the probe exists to catch (send-keys before the box renders is lost). A
# still-generating codex ("esc to interrupt", NOT the agy "esc to cancel") also
# doesn't read ready, so the send waits for the composer instead of racing the
# paste into a mid-turn buffer — the reported repro was an IDLE codex, which the
# "›" fix now detects immediately.
if _agent_pane_input_ready $'booting…\n\n'; then bad_t "blank/booting pane must NOT read ready (would drop the send)"; else ok_t "blank/booting pane does NOT read input-ready"; fi
if _agent_pane_input_ready "$CODEX_BUSY"; then bad_t "codex mid-gen (esc to interrupt) should not read ready (avoid racing the composer)"; else ok_t "codex mid-gen does NOT read input-ready (waits for the composer)"; fi

echo "-----"
printf 'idle-marker: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
