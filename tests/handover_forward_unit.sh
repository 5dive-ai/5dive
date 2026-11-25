#!/usr/bin/env bash
# DIVE-9329 — the pre-sale handover to the first hire (DIVE-8946, was core's
# src/cmd_helper.sh `_helper_tick`) left core for hosted@5dive-plugins
# (`5dive handover _tick`; its harness went with it: 5dive-plugins
# tests/hosted_handover_unit.sh). What core keeps is the heartbeat's gate,
# `_hb_handover_tick`, pinned here against the real function body:
#
#   G1-G2  a box that handed over, or whose old helper seat already welcomed the
#          owner, never runs the plugin (one stat, no fork).
#   G3     a box without the demo AI account (self-hosted, partner) never runs it.
#   G4     no plugin, or another plugin claiming `handover`, never runs it.
#   G5     a paid box, not done, official plugin: the plugin runs as
#          `handover _tick` with stdin closed, its line lands in the log as
#          [handover], and a silent run logs nothing.
#   G6     a plugin that fails or dies never fails the tick.
#   W1-W4  wiring: the tick calls the gate first; the module, its build.sh
#          entry, its harness and the `helper` verb are gone from core; the
#          usage names `handover`; the old seats stay out of lists and exports.
#   NC1    NEGATIVE CONTROL: a gate without the done check is CAUGHT by G1.
# Run: bash tests/handover_forward_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handover-forward.XXXXXX")"
set +e

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The real gate, cut out of the heartbeat module.
GATE=$(sed -n '/^_hb_handover_tick() {/,/^}/p' src/cmd_heartbeat.sh)
[[ -n "$GATE" ]] || { bad_t "the gate _hb_handover_tick is not in src/cmd_heartbeat.sh" ""; exit 1; }

STATE_DIR="$TMP/state"; AUTH_PROFILES_DIR="$STATE_DIR/auth-profiles"
lazy_need() { :; }
_hb_log() { printf '%s\n' "$*" >>"$TMP/log"; }
CLAIM="hosted@5dive-plugins"
_plugin_verb_claims() { [[ "$1" == handover ]] && [[ -n "$CLAIM" ]] && printf '%s\n' "$CLAIM"; }
PLUGIN_SAYS="gave the handover to the first hire ada"; PLUGIN_RC=0
_plugin_dispatch_verb() {
  local stdin; stdin=$(cat)
  printf '%s|stdin=%s\n' "$*" "${#stdin}" >>"$TMP/calls"
  [[ -n "$PLUGIN_SAYS" ]] && printf '%s\n' "$PLUGIN_SAYS"
  exit "$PLUGIN_RC"       # the real dispatch execs: the gate must hold it in a subshell
}

reset() {
  rm -rf "$STATE_DIR" "$TMP/calls" "$TMP/log"
  mkdir -p "$STATE_DIR/helper" "$AUTH_PROFILES_DIR/demo-ai"
  printf 'K=v\n' >"$AUTH_PROFILES_DIR/demo-ai/combined.env"
  CLAIM="hosted@5dive-plugins"; PLUGIN_SAYS="gave the handover to the first hire ada"; PLUGIN_RC=0
}
calls() { [[ -f "$TMP/calls" ]] && wc -l <"$TMP/calls" | tr -d ' ' || echo 0; }
run_gate() { ( eval "$GATE"; _hb_handover_tick; echo "after rc=$?" ) </dev/null >"$TMP/out" 2>&1; RC=$?; }
eval "$GATE"

# ── G1-G2: done boxes never fork ─────────────────────────────────────────────
g1() { reset; date >"$STATE_DIR/helper/handed-over"; run_gate; [[ "$(calls)" == 0 && $RC -eq 0 ]]; }
g1 && ok_t "G1 handed-over recorded: the plugin is not run" || bad_t "G1 handed-over" "calls=$(calls)"
reset; date >"$STATE_DIR/helper/welcomed"; run_gate
[[ "$(calls)" == 0 ]] && ok_t "G2 the old seat's welcome recorded: the plugin is not run" || bad_t "G2 welcomed" "calls=$(calls)"

# ── G3: not a paid box ───────────────────────────────────────────────────────
reset; rm -f "$AUTH_PROFILES_DIR/demo-ai/combined.env"; run_gate; a=$(calls)
reset; : >"$AUTH_PROFILES_DIR/demo-ai/combined.env"; run_gate; b=$(calls)
[[ "$a" == 0 && "$b" == 0 ]] && ok_t "G3 no demo AI account (missing or empty): the plugin is not run" || bad_t "G3 eligibility" "missing=$a empty=$b"

# ── G4: only the official plugin ─────────────────────────────────────────────
reset; CLAIM=""; run_gate; a=$(calls)
reset; CLAIM="handover@someone-else"; run_gate; b=$(calls)
[[ "$a" == 0 && "$b" == 0 ]] && ok_t "G4 no plugin, or another plugin claiming handover: nothing is run" || bad_t "G4 claim" "none=$a other=$b"

# ── G5: the forward ──────────────────────────────────────────────────────────
reset; run_gate
{ [[ "$(calls)" == 1 && "$(cat "$TMP/calls")" == "handover _tick|stdin=0" ]] \
  && grep -qx '\[handover\] gave the handover to the first hire ada;' "$TMP/log" \
  && grep -qx 'after rc=0' "$TMP/out"; } \
  && ok_t "G5 a paid box not yet done: 'handover _tick' runs once, stdin closed, its line logged as [handover]" \
  || bad_t "G5 forward" "calls=$(cat "$TMP/calls" 2>/dev/null) log=$(cat "$TMP/log" 2>/dev/null) out=$(cat "$TMP/out")"
reset; PLUGIN_SAYS=""; run_gate
[[ "$(calls)" == 1 && ! -s "$TMP/log" ]] && ok_t "G5b a silent run logs nothing" || bad_t "G5b silent" "log=$(cat "$TMP/log" 2>/dev/null)"

# ── G6: never fatal ──────────────────────────────────────────────────────────
reset; PLUGIN_RC=7; PLUGIN_SAYS="boom"; run_gate
{ grep -qx 'after rc=0' "$TMP/out" && grep -qx '\[handover\] boom;' "$TMP/log"; } \
  && ok_t "G6 a plugin that fails: the gate returns 0 and the tick goes on" || bad_t "G6 never fatal" "$(cat "$TMP/out")"

# ── W: wiring ────────────────────────────────────────────────────────────────
TICK=$(sed -n '/^cmd_heartbeat_tick() {/,/^}/p' src/cmd_heartbeat.sh)
{ grep -q '^  _hb_handover_tick$' <<<"$TICK" && ! grep -q '_helper_tick' src/cmd_heartbeat.sh \
  && [[ "$(grep -m1 -n '_hb_handover_tick' <<<"$TICK" | cut -d: -f1)" -lt "$(grep -m1 -n 'local checked=0' <<<"$TICK" | cut -d: -f1)" ]]; } \
  && ok_t "W1 the heartbeat tick runs the gate before its wake loop, and nothing calls _helper_tick" || bad_t "W1 tick wiring" ""
BUILTINS=$(sed -n 's/^readonly FIVEDIVE_BUILTIN_VERBS="\(.*\)"$/\1/p' src/cmd_plugin.sh)
{ [[ ! -e src/cmd_helper.sh && ! -e tests/helper_seat_unit.sh ]] && ! grep -q 'cmd_helper' build.sh src/main.sh \
  && [[ -n "$BUILTINS" ]] && ! grep -qw helper <<<"$BUILTINS" && ! grep -qw handover <<<"$BUILTINS" \
  && ! grep -qE '^ +helper\)' src/main.sh; } \
  && ok_t "W2 the module, its build entry, its harness and the 'helper' verb are gone; 'handover' is free for the plugin" \
  || bad_t "W2 removal" ""
grep -qE '^  5dive handover status .*hosted@5dive-plugins' src/main.sh \
  && ok_t "W3 the usage names 'handover' and where it comes from" || bad_t "W3 usage" ""

# The old helper seats (0.138-0.140) stay on their boxes: what keeps them out of
# My team and out of a team copy is core's, and stays pinned (was helper_seat_unit §1).
{ [[ "$(grep -c 'system: (.value.system // null),' src/cmd_agent.sh)" == 1 ]] \
  && [[ "$(grep -c '"system": value.get("system"),' src/cmd_agent.sh)" == 1 ]] \
  && [[ "$(grep -c "select((.value.system // \"\") == \"\") | .key' <<<\"\$reg\"" src/cmd_compose.sh)" == 1 ]]; } \
  && ok_t "W4 both agent-list builders report 'system', and the team export skips system seats" || bad_t "W4 system seats" ""

# ── NC1: G1 can go red ───────────────────────────────────────────────────────
MUT=$(sed '/handed-over" || -e/d' <<<"$GATE")
if [[ "$MUT" == "$GATE" ]]; then bad_t "NC1 mutation did not apply" ""
else
  GATE="$MUT"
  g1 && bad_t "NC1 a gate without the done check passes G1: the check cannot go red" "" \
     || ok_t "NC1 a gate without the done check is CAUGHT by G1 (the plugin ran on a finished box)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
