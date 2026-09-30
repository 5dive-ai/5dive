#!/usr/bin/env bash
# Live arms are opt-in: tests/lib/grading_tree.sh's live_arm_ok.
#
# THE DEFECT (measured on 0.64.0): tests/envelope_peer_forgery_unit.sh arm E runs
# the shipped ./5dive twice on any box with a registry — `agent ask
# nonexistent-target-2183 … --from=<a real peer>`, then `--from=comment-watch`.
# A built ./5dive is not a sourced caller, so src/lib/audit.sh's fence does not
# spare it, and src/header.sh hardcodes AUDIT_LOG on purpose. So every run wrote
# two rows into /var/log/5dive/agent-audit.log: the seat running the harness, on
# the fleet record, attempting a peer forgery (code 10, provenance=divergent).
#
# The fix: live_arm_ok, defined once in grading_tree.sh (which every harness
# sources), is true only when the caller sets FIVEDIVE_LIVE_ARMS; each arm that
# runs the shipped binary against the box or writes its live state skips
# otherwise. The name is FIVEDIVE_, not FIVE_, and T3/T4 grade why: env_isolation.sh
# unsets every inherited FIVE_* knob before a harness body runs.
#
#   bash tests/live_arm_opt_in_unit.sh
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.." || exit 1
GT=tests/lib/grading_tree.sh

TMP="$(mktemp -d /tmp/live-arm-opt-in-unit.XXXXXX)"

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'skip - %s\n' "$1"; }

# In a FRESH shell, as a harness sees it: <env assignments…> -- <expression>,
# evaluated after sourcing grading_tree.sh (${GT_UNDER:-$GT}). Prints yes/no.
fresh() {
  local -a envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  env -u FIVEDIVE_LIVE_ARMS -u FIVE_LIVE_ARMS "${envs[@]}" \
    bash -c '. "$1" 2>/dev/null; if eval "$2"; then echo yes; else echo no; fi' _ "${GT_UNDER:-$GT}" "$1"
}

# --- T) the predicate ------------------------------------------------------------
declare -F live_arm_ok >/dev/null \
  && ok_t "T1: grading_tree.sh defines live_arm_ok (every harness that sources it has it)" \
  || bad_t "T1: live_arm_ok is not defined after sourcing $GT" "every gated arm would skip on a missing function, and nothing could opt in"

[[ "$(fresh -- live_arm_ok)" == no ]] \
  && ok_t "T2: FIVEDIVE_LIVE_ARMS unset -> live_arm_ok is false (live arms skip by default)" \
  || bad_t "T2: live_arm_ok must be false with the knob unset" "got $(fresh -- live_arm_ok)"

[[ "$(fresh FIVEDIVE_LIVE_ARMS=1 -- live_arm_ok)" == yes ]] \
  && ok_t "T3: FIVEDIVE_LIVE_ARMS=1 from the caller survives env isolation -> true" \
  || bad_t "T3: the opt-in must reach the harness body" "got $(fresh FIVEDIVE_LIVE_ARMS=1 -- live_arm_ok)"

# Why the knob is not FIVE_LIVE_ARMS: env_isolation.sh clears that namespace.
[[ "$(fresh FIVE_LIVE_ARMS=1 -- '[[ -n "${FIVE_LIVE_ARMS:-}" ]]')" == no ]] \
  && ok_t "T4: a FIVE_* opt-in is cleared by env_isolation.sh before any arm reads it (the reason for FIVEDIVE_)" \
  || bad_t "T4: FIVE_LIVE_ARMS reached the harness body" "env_isolation.sh no longer clears FIVE_*; this arm's reasoning is stale"

# --- G) each gated arm consults it BEFORE its live action -------------------------
# gated <file> <live-action> -> yes when a `live_arm_ok` line precedes the action.
gated() {
  awk -v act="$2" '/live_arm_ok/ && !g { g = NR } index($0, act) { print (g && g < NR) ? "yes" : "no"; exit }' "$1"
}
for pair in 'tests/envelope_peer_forgery_unit.sh|./5dive agent ask' \
            'tests/browser_teardown_unit.sh|agent-browser open'; do
  f="${pair%%|*}"; act="${pair#*|}"
  [[ "$(gated "$f" "$act")" == yes ]] \
    && ok_t "G: $f consults live_arm_ok before '$act'" \
    || bad_t "G: $f runs '$act' without consulting live_arm_ok" "got '$(gated "$f" "$act")'"
done

# --- E) the defect's own arm: run it with the knob unset ---------------------------
env -u FIVEDIVE_LIVE_ARMS bash tests/envelope_peer_forgery_unit.sh >"$TMP/epf.out" 2>&1; epf_rc=$?
[[ "$epf_rc" == 0 ]] && grep -q 'live arm not opted in' "$TMP/epf.out" \
  && ok_t "E1: envelope_peer_forgery_unit.sh, knob unset: green, and arm E says it was not opted in" \
  || bad_t "E1: envelope_peer_forgery_unit.sh with the knob unset" "rc=$epf_rc; $(grep -iE 'live|FAIL' "$TMP/epf.out" | head -3)"

# The fleet log it used to write. Counted as THIS caller's `agent ask` rows, not
# `wc -l`: every seat on the box appends to the same file while this runs.
# ask_rows <log> -> a count, or "unreadable"
ask_rows() {
  [[ -r "$1" ]] || { echo unreadable; return; }
  awk -v u="\"user\":\"$(id -un)\"" 'index($0, u) && index($0, "\"cmd\":\"agent ask\"") { n++ } END { print n + 0 }' "$1"
}
LIVE_AUDIT_LOG=/var/log/5dive/agent-audit.log
before=$(ask_rows "$LIVE_AUDIT_LOG")
if [[ "$before" == unreadable ]]; then
  skip_t "E2: $LIVE_AUDIT_LOG is unreadable here (CI has none) — the live log arm grades a real box"
else
  env -u FIVEDIVE_LIVE_ARMS bash tests/envelope_peer_forgery_unit.sh >/dev/null 2>&1
  after=$(ask_rows "$LIVE_AUDIT_LOG")
  [[ "$after" == "$before" ]] \
    && ok_t "E2: LIVE: with the knob unset the run adds no '$(id -un)' agent-ask row to $LIVE_AUDIT_LOG ($before -> $after)" \
    || bad_t "E2: LIVE: the run wrote the fleet audit log" "$(id -un) agent-ask rows $before -> $after"
fi
# CONTROL: on a pristine runner (no log) the live arm skips, never fails.
[[ "$(ask_rows "$TMP/absent/agent-audit.log")" == unreadable ]] \
  && ok_t "E3: CONTROL: no audit log -> the live log arm skips" \
  || bad_t "E3: CONTROL: an absent log must read unreadable" "got $(ask_rows "$TMP/absent/agent-audit.log")"
printf '{"user":"%s","cmd":"agent ask"}\n{"user":"someone-else","cmd":"agent ask"}\n' "$(id -un)" >"$TMP/fixture.log"
[[ "$(ask_rows "$TMP/fixture.log")" == 1 ]] \
  && ok_t "E4: CONTROL: the row counter sees this caller's agent-ask row and only that one" \
  || bad_t "E4: CONTROL: ask_rows miscounts" "got $(ask_rows "$TMP/fixture.log") on a 1-row fixture"

# --- M) MUTANTS ---------------------------------------------------------------------
# M1: grading_tree.sh with a predicate that always says yes — the defect, one
# level up. T2's own check, run against that copy, must go red.
mkdir -p "$TMP/mlib"; cp tests/lib/*.sh "$TMP/mlib/"
sed -i 's/^live_arm_ok() { .*}$/live_arm_ok() { return 0; }/' "$TMP/mlib/grading_tree.sh"
if cmp -s "$GT" "$TMP/mlib/grading_tree.sh"; then
  bad_t "M1: MUTANT did not apply" "grading_tree.sh no longer defines live_arm_ok on one line"
else
  [[ "$(GT_UNDER="$TMP/mlib/grading_tree.sh" fresh -- live_arm_ok)" == yes ]] \
    && ok_t "M1: MUTANT always-true live_arm_ok goes red on T2 (yes with the knob unset)" \
    || bad_t "M1: MUTANT stayed green — T2 cannot tell the gate from its absence"
fi
# M2: arm E with its gate stripped, graded by G's instrument (static: never run).
sed 's/if ! live_arm_ok; then/if false; then/' tests/envelope_peer_forgery_unit.sh >"$TMP/epf-mutant.sh"
if cmp -s tests/envelope_peer_forgery_unit.sh "$TMP/epf-mutant.sh"; then
  bad_t "M2: MUTANT did not apply" "arm E no longer reads 'if ! live_arm_ok; then'"
else
  [[ "$(gated "$TMP/epf-mutant.sh" './5dive agent ask')" == no ]] \
    && ok_t "M2: MUTANT arm E without its gate goes red on G" \
    || bad_t "M2: MUTANT stayed green — G cannot tell a gated arm from an ungated one"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
