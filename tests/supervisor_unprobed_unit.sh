#!/usr/bin/env bash
# DIVE-4342 it.2 — A HEALTH SURFACE THAT COULD NOT LOOK MUST NOT PRINT A CLEAN
# WORD. Grades the three pane probes' blindness signal, the `unprobed` verdict
# it produces, and the DEGRADED mark on the board summary.
#
# THE DEFECT THIS GRADES (measured on a customer box, 0.35.0): all three pane
# probes read `(( svc_running )) && [[ $EUID -eq 0 ]] || return 0` and every
# caller tested only `[[ -n "$excerpt" ]]`, so "not allowed to look" and
# "looked, pane is clean" were the same value. An unprivileged `5dive
# supervisor` silently disarmed verify-challenge, blocked-on-prompt and the
# pane-refusal half of quota-exhausted — its three highest-priority branches —
# and still printed `0 stalled / 0 stuck` with no degradation mark.
#
# EVERY POSITIVE ARM IS PAIRED, and the pairing is the point: the mutation arms
# at the end restore the ORIGINAL `return 0` inside `declare -f` of each
# shipping probe, prove the cut landed, and show the blindness signal vanish.
# A suite that only asserted "rc is 3" would pass against a stub that returns 3
# unconditionally; the n/a arms (rc 1) and the clean-pane arms are what make
# the three states distinguishable from each other rather than from nothing.
#
# Runs as a NON-ROOT uid deliberately — that IS the condition under test. Under
# root the blind arms are skipped and say so.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
_SUP_CLI_LATEST="9.9.9"; _SUP_CLI_STALE="false"
# src/header.sh turns on errexit; these arms CAPTURE non-zero return codes as
# their payload, so errexit would kill the harness on its first real assertion.
set +e

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected to contain '$2', got '$3'"; fi; }
tnc(){ if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected NOT to contain '$2', got '$3'"; fi; }

if [[ $EUID -eq 0 ]]; then
  echo "SKIP: this harness grades the NON-ROOT path and is running as root"
  echo "supervisor_unprobed_unit: 0 passed, 0 failed (skipped under root)"
  exit 0
fi

# ── 1. the gate: three states, and the middle one is not blindness ──────────
_sup_pane_gate 1; t "gate: live unit, not root -> BLIND (rc 3)" "3" "$?"
_sup_pane_gate 0; t "gate: unit down -> n/a (rc 1), not blind" "1" "$?"
t "gate: the blind code is the named constant" "3" "$_SUP_PROBE_BLIND"

# ── 2. each shipping probe reports blindness, on the RC, not on stdout ──────
out=$(_sup_verify_challenge claude someuser sess 1); rc=$?
t  "verify probe: not root -> rc 3"            "3"  "$rc"
t  "verify probe: stdout stays EMPTY (the excerpt channel keeps its meaning)" "" "$out"
out=$(_sup_verify_challenge codex someuser sess 1); rc=$?
t  "verify probe: non-claude runtime -> n/a (rc 1), NOT blind" "1" "$rc"
out=$(_sup_verify_challenge claude someuser sess 0); rc=$?
t  "verify probe: unit down -> n/a (rc 1), NOT blind"          "1" "$rc"

out=$(_sup_quota_pane someuser sess 1 "$(date +%s)"); rc=$?
t  "quota probe: not root -> rc 3"             "3"  "$rc"
t  "quota probe: stdout stays EMPTY"           ""   "$out"
out=$(_sup_quota_pane someuser sess 0 "$(date +%s)"); rc=$?
t  "quota probe: unit down -> n/a (rc 1)"      "1"  "$rc"
out=$(_sup_quota_pane_capture someuser sess 1); rc=$?
t  "quota capture: not root -> rc 3"           "3"  "$rc"

out=$(_sup_prompt_pane claude someuser sess 1); rc=$?
t  "prompt probe: not root -> rc 3"            "3"  "$rc"
t  "prompt probe: stdout stays EMPTY"          ""   "$out"
out=$(_sup_prompt_pane grok someuser sess 1); rc=$?
t  "prompt probe: non-claude runtime -> n/a (rc 1)" "1" "$rc"
out=$(_sup_prompt_pane_capture someuser sess 1); rc=$?
t  "prompt capture: not root -> rc 3"          "3"  "$rc"

# ── 3. the fold: ANY blind probe makes the seat unprobed; n/a and clean do not
t "fold: verify blind        -> unprobed" "unprobed" "$(_sup_probe_state 3 0 0)"
t "fold: quota blind         -> unprobed" "unprobed" "$(_sup_probe_state 0 3 0)"
t "fold: prompt blind        -> unprobed" "unprobed" "$(_sup_probe_state 0 0 3)"
t "fold: all three clean     -> ok"       "ok"       "$(_sup_probe_state 0 0 0)"
t "fold: all three n/a       -> ok (nothing to look at is not blindness)" \
                                          "ok"       "$(_sup_probe_state 1 1 1)"
t "fold: clean + n/a mixed   -> ok"       "ok"       "$(_sup_probe_state 0 1 0)"

# ── 4. the classifier: `unprobed` replaces a CLEAN word and nothing else ────
# arg order: desired svc active sess tmux poller loopstuck haswork actage
#            clistale drift verify stranded openrows nooutdays quota deadline
#            prompt promptmark wall paneprobe
cls() { _sup_classify "$@" | cut -f1,2 -d $'\x1f'; }
dt()  { _sup_classify "$@" | cut -f3   -d $'\x1f'; }
IDLE=(running 1 active sess ok n/a 0 0 -1 false "" "" 0 0 -1 "" unknown "" unmarked "")

t "idle seat, probes ran -> healthy (the control this whole row rests on)" \
  "healthy"$'\x1f' "$(cls "${IDLE[@]}" ok)"
t "idle seat, probes BLIND -> unprobed, never healthy" \
  "unprobed"$'\x1f'"pane-unreadable" "$(cls "${IDLE[@]}" unprobed)"
tc "unprobed detail names the three branches that did not run" \
  "verify-challenge / blocked-on-prompt / pane-refusal did NOT run" \
  "$(dt "${IDLE[@]}" unprobed)"
tc "unprobed detail KEEPS what was observed (it is a caveat, not an erasure)" \
  "idle" "$(dt "${IDLE[@]}" unprobed)"
t "default arg: a caller that passes no probe state gets the old behaviour" \
  "healthy"$'\x1f' "$(cls "${IDLE[@]}")"

# blind must NOT overwrite an observed fault — those are facts this DID measure
ACTIVE=(running 1 active sess ok n/a 0 1 60 false "" "" 0 0 -1 "" unknown "" unmarked "")
t "blind + tmux dead -> stuck survives (the observed fault outranks the caveat)" \
  "stuck"$'\x1f'"tmux-dead" \
  "$(cls running 1 active sess dead n/a 0 0 -1 false "" "" 0 0 -1 "" unknown "" unmarked "" unprobed)"
t "blind + account wall -> quota-exhausted survives" \
  "quota-exhausted"$'\x1f'"account-usage" \
  "$(cls running 1 active sess ok n/a 0 0 -1 false "" "" 0 0 -1 "" unknown "" unmarked "7d at 101%" unprobed)"
t "blind + unit stopped by an operator -> stays stopped (no pane to read)" \
  "healthy"$'\x1f' "$(cls stopped 0 inactive sess dead n/a 0 0 -1 false "" "" 0 0 -1 "" unknown "" unmarked "" ok)"
t "PROBES RAN and the pane is clean -> active, unchanged" \
  "healthy"$'\x1f' "$(cls "${ACTIVE[@]}" ok)"

# ── 5. the board summary carries the DEGRADED mark ─────────────────────────
_snap() {  # <paneProbe> <classification>
  jq -cn --arg p "$1" --arg c "$2" \
    '[{name:"a", type:"claude", signals:{service:"active", paneProbe:$p}, classification:$c, cause:null, detail:"-"},
      {name:"b", type:"claude", signals:{service:"active", paneProbe:"ok"}, classification:"healthy", cause:null, detail:"idle"}]'
}
SUM_BLIND=$(_sup_summary_line "$(_snap unprobed unprobed)")
SUM_OK=$(   _sup_summary_line "$(_snap ok healthy)")
tc  "summary: a blind seat marks the board DEGRADED"     "DEGRADED" "$SUM_BLIND"
tc  "summary: it says HOW MANY of how many were unprobed" "1 of 2 seat(s) UNPROBED" "$SUM_BLIND"
tc  "summary: and names the remedy"                       "run as root" "$SUM_BLIND"
tnc "summary CONTROL: a fully probed board carries NO degraded mark" "DEGRADED" "$SUM_OK"
tnc "summary CONTROL: and no UNPROBED count"              "UNPROBED"  "$SUM_OK"
# the mark is driven by the SIGNAL, not the class: a seat that was blind AND
# independently stuck keeps `stuck` and still degrades the board.
tc "summary: blind-but-stuck seat still degrades the board" "DEGRADED" \
  "$(_sup_summary_line "$(_snap unprobed stuck)")"

# ── 6. rollup + fleet verdict ──────────────────────────────────────────────
read -r H SL ST DR VC SA NO UP QE UN OT <<<"$(_sup_rollup_counts "$(_snap unprobed unprobed)")"
t "rollup: unprobed is a NAMED bucket, not unclassified" "1" "$UN"
t "rollup: and it did not leak into the unclassified invariant" "0" "$OT"
t "fleet verdict: an unprobed seat degrades the fleet" \
  "degraded" "$(_sup_fleet_class $H $SL $ST $DR $VC $SA $NO $UP $QE $UN $OT)"
read -r H SL ST DR VC SA NO UP QE UN OT <<<"$(_sup_rollup_counts "$(_snap ok healthy)")"
t "rollup CONTROL: fully probed fleet has 0 unprobed" "0" "$UN"
t "fleet verdict CONTROL: fully probed + healthy -> healthy" \
  "healthy" "$(_sup_fleet_class $H $SL $ST $DR $VC $SA $NO $UP $QE $UN $OT)"

# ── 7. MUTATION CONTROLS — restore the original fail-open in each probe ─────
# The mutation cuts a named term out of the SHIPPING function's own text (never
# a stub substituted for it), proves the cut landed, and then shows the arm
# above go quiet. If a future edit removes the blindness signal, these three
# arms are the ones that notice.
mutate() {  # <fn> — re-defines <fn> with the blind return replaced by `return 0`
  local fn="$1" body
  body=$(declare -f "$fn") || return 1
  body=${body//_sup_pane_gate \"\$svc_running\" || return \$?/(( svc_running )) \&\& [[ \$EUID -eq 0 ]] || return 0}
  body=${body//_sup_pane_gate \"\$3\" || return \$?/(( \$3 )) \&\& [[ \$EUID -eq 0 ]] || return 0}
  body=${body//return \"\$_SUP_PROBE_BLIND\"/return 0}
  printf '%s\n' "$body"
}
for fn in _sup_verify_challenge _sup_quota_pane_capture _sup_prompt_pane_capture; do
  before=$(declare -f "$fn"); after=$(mutate "$fn")
  t "mutation[$fn]: the cut LANDED (function text actually changed)" \
    "changed" "$( [[ "$before" != "$after" ]] && echo changed || echo unchanged )"
  tnc "mutation[$fn]: no blind return survives the mutant" "_SUP_PROBE_BLIND" "$after"
  eval "$after"
  case "$fn" in
    _sup_verify_challenge)     out=$("$fn" claude someuser sess 1);   rc=$? ;;
    _sup_quota_pane_capture)   out=$("$fn" someuser sess 1);          rc=$? ;;
    _sup_prompt_pane_capture)  out=$("$fn" someuser sess 1);          rc=$? ;;
  esac
  t "mutation[$fn]: the fail-open is BACK — success-with-empty (this is the red)" \
    "0|" "$rc|$out"
  eval "$before"   # restore before the next arm, so they are independent
  case "$fn" in
    _sup_verify_challenge)     out=$("$fn" claude someuser sess 1);   rc=$? ;;
    _sup_quota_pane_capture)   out=$("$fn" someuser sess 1);          rc=$? ;;
    _sup_prompt_pane_capture)  out=$("$fn" someuser sess 1);          rc=$? ;;
  esac
  t "mutation[$fn]: restored — blindness is reported again" "3" "$rc"
done

# the fold is what carries a mutant all the way to the printed word
t "mutation end-to-end: a probe that fell back to rc 0 folds to ok ..." \
  "ok" "$(_sup_probe_state 0 0 0)"
t "... and ok prints the clean word the row forbids for a blind caller" \
  "healthy"$'\x1f' "$(cls "${IDLE[@]}" ok)"

echo "supervisor_unprobed_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
