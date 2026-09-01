#!/usr/bin/env bash
# DIVE-1416 (gap#3) isolated unit harness for _sup_classify (cmd_supervisor.sh)
# — the pure classification decision factored out of _sup_agent_record so it's
# directly testable without stubbing systemctl/tmux/pgrep (mirrors how
# tests/supervisor_unit.sh already exercises _sup_act_plan). Focuses on the new
# "stalled"/idle-stranded class: an agent with NO active work but an old todo
# task still sitting assigned to it — the "idle while work is stranded" signal
# the fleet-stall dogfood incident found supervisor didn't model at all.
# Run: bash tests/supervisor_classify_unit.sh (no root, no network).
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
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

_SUP_CLI_LATEST="9.9.9"

PASS=0; FAIL=0
t() {  # <desc> <expected class\x1fcause> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}
tc() {  # <desc> <needle> <haystack> — contains
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected to contain '$2', got '$3'"
  fi
}
# args: desired svc_running active sess tmux_state poller loop_stuck has_work
#       act_age cli_stale goal_drift verify_excerpt stranded
cls() { _sup_classify "$@" | cut -f1,2 -d $'\x1f'; }

# --- the new class itself ----------------------------------------------------
t "idle, no stranded todo -> healthy/(no cause)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 0)"
t "idle + a stranded todo -> stalled/idle-stranded" \
  $'stalled\x1fidle-stranded' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 3)"
t "idle + many stranded -> still just stalled/idle-stranded (no separate tier)" \
  $'stalled\x1fidle-stranded' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 99)"

# --- has_work always wins over stranded (has_work implies the agent isn't
#     idle even if some OTHER old todo happens to be sitting on it) -----------
t "has_work=1 + stranded>0 -> active, not stalled (has_work branch wins)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 5)"

# --- every dead/higher-priority signal still wins over stranded --------------
t "verify-challenge wins over stranded" \
  $'verify-challenge\x1fid-verification' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "ID check pane" 5)"
t "service-dead (has_work) wins over stranded" \
  $'stuck\x1fservice-dead' "$(cls "" 0 active s unknown n/a 0 1 -1 false "" "" 5)"
t "tmux-dead wins over stranded" \
  $'stuck\x1ftmux-dead' "$(cls "" 1 active s dead n/a 0 0 -1 false "" "" 5)"
t "poller-dead wins over stranded" \
  $'stuck\x1fpoller-dead' "$(cls "" 1 active s unknown dead 0 0 -1 false "" "" 5)"
t "loop-stuck wins over stranded" \
  $'stuck\x1floop-stuck' "$(cls "" 1 active s unknown n/a 1 0 -1 false "" "" 5)"
t "cli-stale still wins over stranded (box-level signal, unchanged precedence)" \
  $'update-pending\x1fstale-cli' "$(cls "" 1 active s unknown n/a 0 0 -1 true "" "" 5)"
t "stopped (desired) wins over stranded" \
  $'healthy\x1f' "$(cls "stopped" 0 active s unknown n/a 0 0 -1 false "" "" 5)"

# --- unaffected: existing has_work-branch classes are unchanged by the refactor
t "regression: has_work + no-progress past stuck window -> stuck/no-progress" \
  $'stuck\x1fno-progress' "$(cls "" 1 active s unknown n/a 0 1 $((_SUP_T_STUCK_MIN * 60)) false "" "" 0)"
t "regression: has_work + no-progress past slow (not stuck) window -> slow" \
  $'slow\x1f' "$(cls "" 1 active s unknown n/a 0 1 $((_SUP_T_SLOW_MIN * 60)) false "" "" 0)"
t "regression: goal-drift still fires with no stranded work" \
  $'drift\x1fgoal-drift' "$(cls "" 1 active s unknown n/a 0 0 -1 false "42" "" 0)"
t "regression: plain has_work -> healthy/(no cause)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0)"


# --- DIVE-3272: the OUTPUT classes -------------------------------------------
# args 14/15/16 are open_rows, no_output_days, quota_excerpt. Every `cls` call
# above omits them on purpose: their defaults (0 / -1 / "") must leave every
# pre-existing verdict byte-identical, which is what those regressions assert.
N=$_SUP_T_NO_OUTPUT_DAYS

# The incident shape itself: a seat holding open rows, transcript moving, unit
# and tmux fine — which used to print `healthy / active`.
t "DIVE-3272: open rows + drought past N -> no-output (this is the incident)" \
  $'no-output\x1fno-output' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 20 "$N" "")"
t "DIVE-3272: drought past N with NO active work still flags (claiming is not required)" \
  $'no-output\x1fno-output' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 0 20 $((N + 5)) "")"

# --- the two halves are only meaningful together -----------------------------
t "DIVE-3272: drought but ZERO open rows -> healthy (a correctly idle seat)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 0 0 $((N + 90)) "")"
t "DIVE-3272: open rows but closed something today -> healthy (a busy seat)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 20 0 "")"
t "DIVE-3272: one day short of N -> healthy (threshold is >=, not >)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 20 $((N - 1)) "")"
t "DIVE-3272: never closed anything (days=-1) -> healthy, NOT no-output" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 20 -1 "")"

# --- precedence: below the hard dead signals, ABOVE the ones that hid it ------
t "DIVE-3272: service-dead still wins over no-output (more specific)" \
  $'stuck\x1fservice-dead' "$(cls "" 0 active s unknown n/a 0 1 -1 false "" "" 0 20 "$N" "")"
t "DIVE-3272: no-progress still wins over no-output" \
  $'stuck\x1fno-progress' "$(cls "" 1 active s unknown n/a 0 1 $((_SUP_T_STUCK_MIN * 60)) false "" "" 0 20 "$N" "")"
t "DIVE-3272: no-output BEATS stale-cli (a box notice must not mask a dark seat)" \
  $'no-output\x1fno-output' "$(cls "" 1 active s unknown n/a 0 0 -1 true "" "" 0 20 "$N" "")"
t "DIVE-3272: no-output BEATS slow" \
  $'no-output\x1fno-output' "$(cls "" 1 active s unknown n/a 0 1 $((_SUP_T_SLOW_MIN * 60)) false "" "" 0 20 "$N" "")"
t "DIVE-3272: no-output BEATS drift" \
  $'no-output\x1fno-output' "$(cls "" 1 active s unknown n/a 0 0 -1 false "42" "" 0 20 "$N" "")"
t "DIVE-3272: no-output BEATS stalled/idle-stranded" \
  $'no-output\x1fno-output' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 5 20 "$N" "")"

# --- the quota class ---------------------------------------------------------
t "DIVE-3272: quota signature -> quota-exhausted" \
  $'quota-exhausted\x1fquota-exhausted' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 0 -1 "429 quota exhausted")"
t "DIVE-3272: quota-exhausted beats loop-stuck and no-progress (it explains them)" \
  $'quota-exhausted\x1fquota-exhausted' "$(cls "" 1 active s unknown n/a 1 1 $((_SUP_T_STUCK_MIN * 60)) false "" "" 0 20 "$N" "429 quota exhausted")"
t "DIVE-3272: verify-challenge still outranks quota-exhausted" \
  $'verify-challenge\x1fid-verification' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "ID check pane" 0 0 -1 "429 quota exhausted")"
t "DIVE-3272: tmux-dead still outranks quota-exhausted (dead unit is more specific)" \
  $'stuck\x1ftmux-dead' "$(cls "" 1 active s dead n/a 0 1 -1 false "" "" 0 0 -1 "429 quota exhausted")"

# --- the quota REGEX, isolated (no tmux) -------------------------------------
q() { printf '%s\n' "$1" | _sup_quota_match; }
# The verbatim line off dev3's pane on 2026-08-11 — the whole reason this exists.
t "DIVE-3272 regex: dev3's real 429 line matches" "MATCH" \
  "$( [[ -n "$(q '● API Error: Request rejected (429) · Your token-plan 1-week quota has been exhausted.')" ]] && echo MATCH || echo MISS )"
t "DIVE-3272 regex: the spend-limit phrasing matches" "MATCH" \
  "$( [[ -n "$(q "You've hit your monthly spend limit. Opus 5 5h: 0% 1w: 100%")" ]] && echo MATCH || echo MISS )"
t "DIVE-3822 regex: 5h=0 with 7d=100 is weekly-exhausted" "MATCH" \
  "$( [[ -n "$(q 'Opus 5 5h: 0% 7d: 100%')" ]] && echo MATCH || echo MISS )"
t "DIVE-3822 regex: missing 5h with 7d=100 is still weekly-exhausted" "MATCH" \
  "$( [[ -n "$(q 'Opus 5 7d: 100%')" ]] && echo MATCH || echo MISS )"
t "DIVE-3822 regex: 1w spelling at 100 is weekly-exhausted" "MATCH" \
  "$( [[ -n "$(q 'Opus 5 5h: 0% 1w: 100%')" ]] && echo MATCH || echo MISS )"
t "DIVE-3822 regex: a healthy 7d counter does NOT exhaust the seat" "MISS" \
  "$( [[ -n "$(q 'Opus 5 7d: 28%')" ]] && echo MATCH || echo MISS )"
t "DIVE-3822 regex: a healthy 1w counter does NOT exhaust the seat" "MISS" \
  "$( [[ -n "$(q 'Opus 5 5h: 18% 1w: 34%')" ]] && echo MATCH || echo MISS )"
t "DIVE-3272 regex: insufficient_quota matches" "MATCH" \
  "$( [[ -n "$(q 'openai error: insufficient_quota')" ]] && echo MATCH || echo MISS )"
# Negative controls with a NON-ZERO expected value: these are the false
# positives that would page main about a healthy seat.
t "DIVE-3272 regex: an HTTP 429 in ordinary prose does NOT match" "MISS" \
  "$( [[ -n "$(q 'we should retry on 429 responses from the upstream')" ]] && echo MATCH || echo MISS )"
t "DIVE-3272 regex: a bare 4290 does NOT match" "MISS" \
  "$( [[ -n "$(q 'total tokens: 4290')" ]] && echo MATCH || echo MISS )"
t "DIVE-3272 regex: an empty pane does NOT match" "MISS" \
  "$( [[ -n "$(q '')" ]] && echo MATCH || echo MISS )"

# --- DIVE-3880: the DEADLINE inside the refusal, and what the class does with it
#     Measured 2026-09-01 14:17Z: `agent info ops` printed NOT TRANSACTING off a
#     refusal whose own "continuing automatically at 2:10pm" had already passed
#     — the seat was executing the very command that read the flag. quinn, same
#     tick, same predicate, "at 3pm": genuinely frozen. One string, both answers.
#     The three arms below are the three states; the fourth is the abstention,
#     which must leave DIVE-3272's behaviour untouched rather than clear it.
QN=$(date -d '2026-09-01 14:17:00' +%s)
dl() { _sup_quota_deadline "$1" "${2:-$QN}" | cut -f1 -d $'\x1f'; }
t "DIVE-3880: a lapsed 2:10pm deadline read at 14:17 is lapsed" "lapsed" \
  "$(dl '● Usage limit reached · continuing automatically at 2:10pm · esc or type')"
t "DIVE-3880: a 3pm deadline read at 14:17 is live" "live" \
  "$(dl '● Usage limit reached · continuing automatically at 3pm')"
t "DIVE-3880: a 24h form parses too" "lapsed" \
  "$(dl '● Usage limit reached · continuing automatically at 14:10')"
t "DIVE-3880: no deadline in the string is UNKNOWN, never a verdict" "unknown" \
  "$(dl '● API Error: Request rejected (429) · quota has been exhausted')"
t "DIVE-3880: a bare hour with no meridiem is ambiguous -> UNKNOWN, not a guess" "unknown" \
  "$(dl '● Usage limit reached · continuing automatically at 9:30')"
t "DIVE-3880: an impossible clock time is UNKNOWN" "unknown" \
  "$(dl '● Usage limit reached · continuing automatically at 25:99')"
# Day rollover, both directions. A pane line is UNDATED, so anchoring on today
# gets one of these two backwards whichever side you pick.
t "DIVE-3880: 12:30am read at 23:55 is TOMORROW -> live" "live" \
  "$(dl '● Usage limit reached · continuing automatically at 12:30am' "$(date -d '2026-09-01 23:55:00' +%s)")"
t "DIVE-3880: 11pm read at 00:05 is YESTERDAY -> lapsed" "lapsed" \
  "$(dl '● Usage limit reached · continuing automatically at 11pm' "$(date -d '2026-09-01 00:05:00' +%s)")"
t "DIVE-3880: noon is 12pm, not midnight" "live" \
  "$(dl '● Usage limit reached · continuing automatically at 12pm' "$(date -d '2026-09-01 11:00:00' +%s)")"
t "DIVE-3880: at the deadline exactly, the wall is over" "lapsed" \
  "$(dl '● Usage limit reached · continuing automatically at 2:10pm' "$(date -d '2026-09-01 14:10:00' +%s)")"

# and what _sup_classify does with each — arg 17.
t "DIVE-3880: a LAPSED deadline disarms the quota class entirely" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 0 -1 "usage limit reached · continuing automatically at 2:10pm" lapsed)"
t "DIVE-3880: a lapsed quota signature does not mask the signal BELOW it either" \
  $'stuck\x1floop-stuck' "$(cls "" 1 active s unknown n/a 1 1 -1 false "" "" 0 0 -1 "usage limit reached · continuing automatically at 2:10pm" lapsed)"
t "DIVE-3880: a LIVE deadline still classifies (quinn's 3pm case)" \
  $'quota-exhausted\x1fquota-exhausted' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 0 -1 "usage limit reached · continuing automatically at 3pm" live)"
t "DIVE-3880: UNKNOWN abstains — DIVE-3272's classification is unchanged" \
  $'quota-exhausted\x1fquota-exhausted' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 0 -1 "429 quota exhausted" unknown)"
t "DIVE-3880: arg 17 OMITTED behaves as unknown (every pre-3880 caller)" \
  $'quota-exhausted\x1fquota-exhausted' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 0 -1 "429 quota exhausted")"
t "DIVE-3880: a junk deadline state degrades to the abstention, not to a clear" \
  $'quota-exhausted\x1fquota-exhausted' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0 0 -1 "429 quota exhausted" wat)"
# The detail must never again be a bare class: which state it rests on is in it.
dt() { _sup_classify "$@" | cut -f3 -d $'\x1f'; }
tc "DIVE-3880: a live classification SAYS the deadline is still future" "the refusal is live" \
  "$(dt "" 1 active s unknown n/a 0 1 -1 false "" "" 0 0 -1 "usage limit reached · continuing automatically at 3pm" live)"
tc "DIVE-3880: an abstaining classification says UNKNOWN, not confirmed" "UNKNOWN whether it is still in force" \
  "$(dt "" 1 active s unknown n/a 0 1 -1 false "" "" 0 0 -1 "429 quota exhausted" unknown)"

# --- DIVE-3880 it.2: WHICH matching line the window reports ------------------
#     quinn's rejection of it.1: `_sup_quota_match` ended in `head -1`, so the
#     excerpt was the OLDEST match in the 40-line window. Pre-3880 that was
#     cosmetic (any match -> alarm); once `lapsed` DISARMS the alarm it is
#     load-bearing, and a seat that hit the wall, resumed, and hit it again
#     inside one window reported healthy while genuinely frozen — the false
#     negative arriving through the excerpt selection rather than the state
#     machine. Quota-pressured seats are the only population this detector has,
#     so a second refusal in one window is the expected shape, not an exotic
#     one. Before it.2 NO arm fed _sup_quota_match more than one matching line.
qm() { printf '%s\n' "$1" | _sup_quota_match "${2:-$QN}"; }
qs() { _sup_quota_deadline "$(qm "$1" "${2:-$QN}")" "${2:-$QN}" | cut -f1 -d $'\x1f'; }

LAPSED_LINE='● Usage limit reached · continuing automatically at 2:10pm · esc or type'
LIVE_LINE='● Usage limit reached · continuing automatically at 3pm'
UNTIMED_LINE='● API Error: Request rejected (429) · quota has been exhausted'

# quinn's measured pane, verbatim shape: a lapsed line ABOVE a live one.
t "DIVE-3880 it.2: a lapsed line above a LIVE one does not lapse the window" "live" \
  "$(qs "$LAPSED_LINE"$'\n'"$LIVE_LINE")"
t "DIVE-3880 it.2: and the excerpt reported is the live line, not the oldest" "MATCH" \
  "$( [[ "$(qm "$LAPSED_LINE"$'\n'"$LIVE_LINE")" == *"at 3pm"* ]] && echo MATCH || echo MISS )"
# The other order too: a still-future deadline wins wherever it sits, so the
# window can only lapse when EVERY timed match has lapsed.
t "DIVE-3880 it.2: a live line above a lapsed one is still live" "live" \
  "$(qs "$LIVE_LINE"$'\n'"$LAPSED_LINE")"
# Two live walls: the LATEST deadline is the one the seat is actually waiting on.
t "DIVE-3880 it.2: with two live walls the LATEST deadline is reported" "MATCH" \
  "$( [[ "$(qm '● Usage limit reached · continuing automatically at 3pm'$'\n''● Usage limit reached · continuing automatically at 4pm')" == *"at 4pm"* ]] && echo MATCH || echo MISS )"
# All lapsed -> the window lapses (the fix DIVE-3880 shipped, still true with
# more than one line in the window).
t "DIVE-3880 it.2: every match lapsed -> the window lapses" "lapsed" \
  "$(qs '● Usage limit reached · continuing automatically at 1pm'$'\n'"$LAPSED_LINE")"
# An UNTIMED signature is not evidence of a lapse and not evidence of a wall —
# it is the newest line that decides, in both directions.
t "DIVE-3880 it.2: an untimed refusal BELOW a lapsed one keeps the alarm" "unknown" \
  "$(qs "$LAPSED_LINE"$'\n'"$UNTIMED_LINE")"
t "DIVE-3880 it.2: a STALE untimed refusal above a lapsed one does not pin it" "lapsed" \
  "$(qs "$UNTIMED_LINE"$'\n'"$LAPSED_LINE")"
t "DIVE-3880 it.2: an untimed refusal below a LIVE one still keeps the alarm" "live" \
  "$(qs "$LIVE_LINE"$'\n'"$UNTIMED_LINE")"
# Non-matching pane chatter between the two refusals must not change any of it.
t "DIVE-3880 it.2: interleaved non-matching lines do not shift the selection" "live" \
  "$(qs "$LAPSED_LINE"$'\n''● Read(src/cmd_supervisor.sh)'$'\n''  ⎿ 40 lines'$'\n'"$LIVE_LINE")"
# The excerpt is TRIMMED and clamped whichever line wins — the selection rewrite
# must not quietly drop that (it feeds a rendered operator line).
t "DIVE-3880 it.2: the selected line is trimmed, not raw pane padding" "MATCH" \
  "$( [[ "$(qm '   '"$LIVE_LINE"'     ')" == '●'* ]] && echo MATCH || echo MISS )"
# Single-line behaviour is unchanged — the pre-it.2 contract.
t "DIVE-3880 it.2: one lapsed line alone still lapses (ops, the filing case)" "lapsed" \
  "$(qs "$LAPSED_LINE")"
t "DIVE-3880 it.2: one live line alone still classifies (quinn, the filing case)" "live" \
  "$(qs "$LIVE_LINE")"
t "DIVE-3880 it.2: a pane with no signature at all still returns empty" "MISS" \
  "$( [[ -n "$(qm 'nothing here'$'\n''nor here')" ]] && echo MATCH || echo MISS )"

# --- DIVE-3880: THE WIRING, driven through _sup_agent_record ------------------
#     A pure-classifier arm grades the BRANCH and not the READ
#     (community/wiki/a-detectors-tests-can-grade-the-branch-and-not-the-read.md):
#     with the decision correct, arg 17 can still be fed a constant and the
#     detector reads exactly as it did before the fix. Measured: hardcoding
#     "unknown" at the call site survived every arm above. So this drives the
#     real record path with the probes stubbed — the excerpt comes from a
#     stubbed pane, the deadline state is derived inside the function, and only
#     the emitted JSON is asserted.
rec() {  # <pane-line> <now>
  # NOT named `pane`: bash locals are DYNAMICALLY scoped, so the real
  # _sup_quota_pane's own `local pane` shadows this one at the moment the
  # stubbed capture reads it (measured: `pane: unbound variable` under set -u).
  local fixture_pane="$1" rnow="$2"
  (
    systemctl() { printf 'ActiveState=active\nSubState=running\nActiveEnterTimestamp=n/a\n'; }
    db() { echo 0; }
    # DIVE-3880 it.2: stub only the ROOT TMUX HOP, never _sup_quota_pane
    # itself. Replacing the whole function (what it.1 did) also replaced its
    # `now` forwarding, so deleting `"$now"` from the real call site survived
    # every arm in this file — a wiring hole of exactly the kind the section
    # below exists to close. With just the capture stubbed, the real
    # _sup_quota_pane runs and that argument is graded.
    _sup_quota_pane_capture() { printf '%s\n' "$fixture_pane"; }
    _sup_verify_challenge() { :; }
    _sup_activity_epoch() { :; }
    _sup_goal_drift() { :; }
    _sup_output_stats() { echo "0|-1"; }
    _sup_agent_record seatw claude "" agent-seatw.service agent-seatw seatw /home/agent-seatw "$rnow" running
  )
}
LAPSED_REC=$(rec '● Usage limit reached · continuing automatically at 2:10pm · esc or type' "$QN")
t "DIVE-3880 wiring: the record path DERIVES the state, not a constant" "lapsed" \
  "$(jq -r '.signals.quotaDeadline' <<<"$LAPSED_REC")"
t "DIVE-3880 wiring: and a lapsed refusal does not reach the board as a class" "healthy" \
  "$(jq -r '.classification' <<<"$LAPSED_REC")"
t "DIVE-3880 wiring: the signature we READ is still recorded (both facts kept)" \
  "true" "$(jq -r '(.signals.quotaSignature != null)' <<<"$LAPSED_REC")"
LIVE_REC=$(rec '● Usage limit reached · continuing automatically at 3pm' "$QN")
t "DIVE-3880 wiring: a live refusal still classifies through the same path" \
  "quota-exhausted" "$(jq -r '.classification' <<<"$LIVE_REC")"
t "DIVE-3880 wiring: live state recorded on the row" "live" \
  "$(jq -r '.signals.quotaDeadline' <<<"$LIVE_REC")"
UNK_REC=$(rec '● API Error: Request rejected (429) · quota has been exhausted' "$QN")
t "DIVE-3880 wiring: a deadline-free refusal abstains and still classifies" \
  "quota-exhausted" "$(jq -r '.classification' <<<"$UNK_REC")"
t "DIVE-3880 wiring: abstention is recorded as unknown, never as live" "unknown" \
  "$(jq -r '.signals.quotaDeadline' <<<"$UNK_REC")"
CLEAN_REC=$(rec 'nothing interesting on this pane at all' "$QN")
t "DIVE-3880 wiring: no signature at all leaves the field null, not unknown" "null" \
  "$(jq -r '.signals.quotaDeadline' <<<"$CLEAN_REC")"

TWO_REC=$(rec '● Usage limit reached · continuing automatically at 2:10pm · esc or type
● Usage limit reached · continuing automatically at 3pm' "$QN")
t "DIVE-3880 it.2 wiring: lapsed-above-live reaches the board as a CLASS" \
  "quota-exhausted" "$(jq -r '.classification' <<<"$TWO_REC")"
t "DIVE-3880 it.2 wiring: and the recorded state is live, not lapsed" "live" \
  "$(jq -r '.signals.quotaDeadline' <<<"$TWO_REC")"
t "DIVE-3880 it.2 wiring: the recorded signature is the LIVE line (what info re-derives)" \
  "MATCH" "$( [[ "$(jq -r '.signals.quotaSignature' <<<"$TWO_REC")" == *"at 3pm"* ]] && echo MATCH || echo MISS )"
# The CLOCK HAND-OFF, graded directly. An arm that only compares verdicts
# cannot see `_sup_quota_pane` dropping the `now` it was handed whenever the
# wall clock happens to select the same line as the fixture clock — measured:
# deleting `"$now"` from that call survived every verdict arm in this file at
# 15:17 wall against a 14:17 fixture. So this asserts the DATA FLOW instead:
# stub the far end of the chain and read back which clock reached it.
t "DIVE-3880 it.2 wiring: _sup_quota_pane hands the TICK clock down to the selection" \
  "$QN" "$(
    _sup_quota_pane_capture() { printf '%s\n' "$LIVE_LINE"; }
    _sup_quota_deadline() { printf 'seen=%s\n' "${2:-MISSING}" >&2; printf 'unknown\x1f\n'; }
    _sup_quota_pane u s 1 "$QN" 2>&1 >/dev/null | sed -n 's/^seen=//p' | head -1
  )"
# And the selection order that the wall clock DID mask: live above lapsed.
UPSIDE_REC=$(rec '● Usage limit reached · continuing automatically at 3pm
● Usage limit reached · continuing automatically at 2:10pm · esc or type' "$QN")
t "DIVE-3880 it.2 wiring: a live line ABOVE a lapsed one still reaches the board" \
  "quota-exhausted" "$(jq -r '.classification' <<<"$UPSIDE_REC")"
t "DIVE-3880 it.2 wiring: and it is the live line that was recorded" "MATCH" \
  "$( [[ "$(jq -r '.signals.quotaSignature' <<<"$UPSIDE_REC")" == *"at 3pm"* ]] && echo MATCH || echo MISS )"

TWO_LAPSED_REC=$(rec '● Usage limit reached · continuing automatically at 1pm
● Usage limit reached · continuing automatically at 2:10pm · esc or type' "$QN")
t "DIVE-3880 it.2 wiring: two lapsed refusals still disarm" "healthy" \
  "$(jq -r '.classification' <<<"$TWO_LAPSED_REC")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
