#!/usr/bin/env bash
# DIVE-4536 — the two defects that held dev3 on a one-keystroke confirm for ~10h.
#
#   1. the pane quota matcher read claude's status-bar USAGE METER
#      ("Opus 5 · 5h: 17%  7d: 100%") as a model-capacity refusal, and
#      DIVE-4097 door 2 then HELD the no-progress ladder behind it;
#   2. no verdict recognised the built-in tool-permission confirm
#      ("Do you want to proceed? / ❯ 1. Yes / 2. No / Esc to cancel").
#
# Every arm here is PURE — the matchers and _sup_classify, no tmux, no root, no
# db. Each defect gets a negative arm (the false positive must stop), a POSITIVE
# CONTROL (the true positive must survive — a matcher that matches nothing
# passes a one-sided test), and, for the regexes, a MUTANT arm proving the arm
# would have failed before the fix.
# Run: bash tests/supervisor_confirm_unit.sh (no root, no network).
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
_SUP_CLI_LATEST="9.9.9"

PASS=0; FAIL=0
ok()   { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"; fi; }
has()  { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected to contain '$2', got '$3'"; fi; }
hasnt(){ if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected NOT to contain '$2', got '$3'"; fi; }

# ── fixtures ────────────────────────────────────────────────────────────────
# The exact line claude renders on EVERY pane, at all times. This one is at the
# weekly cap, which is the state that produced the incident.
METER_PANE=$'  ⏵⏵ bypass permissions on\n  Opus 5 · 5h: 17%  7d: 100%'
# The same meter BELOW the cap — the reading dev3 actually had at 13:49Z, still
# held. Must be as clean as the 100% one.
METER_PANE_71=$'  ⏵⏵ bypass permissions on\n  Opus 5 · 5h: 4%  7d: 71%'
# POSITIVE CONTROL: a real refusal SENTENCE. Nothing about this change may make
# a genuine wall stop classifying.
REFUSAL_PANE=$'Claude usage limit reached · continuing automatically at 8am (UTC)\n  Opus 5 · 5h: 100%  7d: 100%'
# POSITIVE CONTROL for the weekly arm itself: a weekly wall rendered WITHOUT a
# session percentage beside it is not the status bar and must still match.
WEEKLY_ONLY_PANE=$'  weekly limit 7d: 100% — no further requests this window'

# The incident pane, verbatim from main's capture at 2026-09-14 13:49Z.
CONFIRM_PANE=$'Add cmd_read and cmd_links to bin/browser\nDangerous rm operation on possibly-empty variable path: "$out/$f"\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel · Tab to amend'
# FALSE-POSITIVE CONTROLS, DRAWN FROM THE POPULATION, NOT COMPOSED (it.2).
#
# Iteration 1 shipped a two-line paraphrase written by the author against the
# author's own pattern — a specimen of the false positive already known to be
# avoided, which is not a control. The verifier fed the real population instead
# and found TWO hits, both on disk in the same commit as the detector. They are
# checked in VERBATIM here, exactly as they were when they tripped it:
#
#   row-body-task-show.txt — the output of `5dive task show DIVE-4536`, which
#     quotes main's 13:49Z capture in full (all three parts, adjacent) and
#     carries them a SECOND time, all on ONE line, in the delivered `result`.
#   wiki-bypass-mode.md — the page written in THIS delivery to document the
#     defect, fenced block, all three parts. Snapshotted BEFORE its literals
#     were broken, on purpose: a control has to be the thing that failed. The
#     live page no longer carries them either, which is the other half of the
#     fix, not a substitute for this arm.
#
# Do not "tidy" these files. Their value is that nobody wrote them for this test.
FIX_ROW_BODY=tests/fixtures/dive4536/row-body-task-show.txt
FIX_WIKI_PAGE=tests/fixtures/dive4536/wiki-bypass-mode.md

# The incident capture with the chrome a REAL claude pane draws under a modal —
# measured 2026-09-14 from a live pane (`tmux capture-pane -p -S -40`): the box
# rule, the usage/model line, the mode line. The positive control has to carry
# this, or the tail anchor is being graded against a fixture that ends at the
# footer and the constant is never exercised.
CONFIRM_PANE_CHROME=$'Add cmd_read and cmd_links to bin/browser\nDangerous rm operation on possibly-empty variable path: "$out/$f"\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel · Tab to amend\n────────────────────────────────────────\n  Opus 5 5h: 9% 7d: 80%\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent'

# A prose mention that carries ALL THREE parts on ONE line — the shape of this
# row's own `result` field. Killed by the strict ordering, not by the anchor.
ONELINE_MENTION=$'the built-in confirm (Do you want to proceed? / ❯ 1. Yes / Esc to cancel) is\n  invisible to the DIVE-4293 hook, so nothing read it for ten hours.'
# The DIVE-4293 picker, unchanged. Must still read as blocked-on-prompt and must
# NOT be downgraded to a decline (Enter on it is the model'"'"'s own answer).
PICKER_PANE=$'Which approach?\n❯ 1. Rebuild the index (Recommended)\n  2. Patch in place\n↑/↓ to navigate · Enter to select'

# ── defect 1: the meter is a gauge, not a refusal ───────────────────────────
ok "status-bar meter at 7d:100% is NOT a refusal" \
  "" "$(printf '%s\n' "$METER_PANE" | _sup_quota_match 1757851740)"
ok "status-bar meter at 7d:71% is NOT a refusal" \
  "" "$(printf '%s\n' "$METER_PANE_71" | _sup_quota_match 1757851740)"
has "POSITIVE CONTROL: a real refusal sentence still matches" \
  "usage limit reached" "$(printf '%s\n' "$REFUSAL_PANE" | _sup_quota_match 1757851740)"
has "POSITIVE CONTROL: a meter-free weekly wall still matches" \
  "7d: 100%" "$(printf '%s\n' "$WEEKLY_ONLY_PANE" | _sup_quota_match 1757851740)"

# The meter line is no longer a "signature", so the neighbour join may now offer
# it as a CLOCK to an untimed banner. It carries no time of day, so it must lend
# nothing — a "5h" that parsed as a deadline would silently re-arm the hold.
ok "the meter lends no deadline to the join" \
  $'unknown\x1f' "$(_sup_quota_deadline 'Opus 5 · 5h: 17%  7d: 100%' 1757851740)"

# MUTANT: restore the pre-fix predicate. The negative arms above must go red,
# which is what proves they are testing the fix and not the fixture.
_mutant_is_refusal() { grep -qiE "${_SUP_QUOTA_PAT}|${_SUP_WEEKLY_QUOTA_PAT}" <<<"$1" 2>/dev/null; }
_real_is_refusal=$(declare -f _sup_line_is_refusal)
eval "_sup_line_is_refusal() { _mutant_is_refusal \"\$1\"; }"
_mut=$(printf '%s\n' "$METER_PANE" | _sup_quota_match 1757851740)
if [[ -n "$_mut" ]]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "FAIL: MUTANT-KILL — the pre-fix matcher did NOT classify the meter, so the negative arm proves nothing"; fi
eval "$_real_is_refusal"
ok "mutant reverted — the meter is clean again" \
  "" "$(printf '%s\n' "$METER_PANE" | _sup_quota_match 1757851740)"

# ── defect 2: the built-in confirm is a recognised state ─────────────────────
ok "the confirm's question line is matched" \
  "Do you want to proceed?" "$(printf '%s\n' "$CONFIRM_PANE" | _sup_confirm_match)"
ok "POSITIVE CONTROL: the incident capture WITH real pane chrome still matches" \
  "Do you want to proceed?" "$(printf '%s\n' "$CONFIRM_PANE_CHROME" | _sup_confirm_match)"
ok "FALSE-POSITIVE (population): \`task show DIVE-4536\` is NOT a confirm" \
  "" "$(_sup_confirm_match < "$FIX_ROW_BODY")"
ok "FALSE-POSITIVE (population): the bypass-mode wiki page is NOT a confirm" \
  "" "$(_sup_confirm_match < "$FIX_WIKI_PAGE")"
ok "FALSE-POSITIVE: all three parts on ONE line (the result field) is NOT a confirm" \
  "" "$(printf '%s\n' "$ONELINE_MENTION" | _sup_confirm_match)"
# The fixtures must still CONTAIN the signature, or the two arms above pass for
# the wrong reason (a control that no longer carries the thing controls nothing).
if grep -q 'Do you want to proceed' "$FIX_ROW_BODY" && grep -qE '^[[:space:]]*❯?[[:space:]]*1\. Yes' "$FIX_ROW_BODY" \
   && grep -q 'Esc to cancel' "$FIX_ROW_BODY"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "FAIL: row-body fixture no longer carries all three parts — it is not a control"; fi
if grep -q 'Do you want to proceed' "$FIX_WIKI_PAGE" && grep -qE '^[[:space:]]*❯?[[:space:]]*1\. Yes' "$FIX_WIKI_PAGE" \
   && grep -q 'Esc to cancel' "$FIX_WIKI_PAGE"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "FAIL: wiki fixture no longer carries all three parts — it is not a control"; fi

# ANCHORED MUTANT: widen the tail anchor past the footer's real offset in the
# row body (13 non-empty lines from the end) and the population arm MUST go red.
# This is what proves the POSITION is load-bearing rather than some other
# accident of the fixture.
_real_tail=$_SUP_CONFIRM_TAIL_LINES
_SUP_CONFIRM_TAIL_LINES=999
_mut_row=$(_sup_confirm_match < "$FIX_ROW_BODY")
_mut_wiki=$(_sup_confirm_match < "$FIX_WIKI_PAGE")
_SUP_CONFIRM_TAIL_LINES=$_real_tail
if [[ -n "$_mut_row" && -n "$_mut_wiki" ]]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "FAIL: ANCHORED MUTANT — unanchoring did NOT re-admit the population hits (row='$_mut_row' wiki='$_mut_wiki'), so the anchor is not what kills them"; fi
ok "mutant reverted — the row body is clean again" "" "$(_sup_confirm_match < "$FIX_ROW_BODY")"

# The SPAN and ADJ anchors are load-bearing too: push the option away from the
# question by more than ADJ and the real capture must stop matching.
SPACED_PANE=$'Do you want to proceed?\n  (some intervening render)\n  (another line)\n❯ 1. Yes\n  2. No\nEsc to cancel · Tab to amend'
ok "question and option more than ADJ apart -> no match" \
  "" "$(printf '%s\n' "$SPACED_PANE" | _sup_confirm_match)"
ok "the DIVE-4293 picker is not read as a confirm" \
  "" "$(printf '%s\n' "$PICKER_PANE" | _sup_confirm_match)"
ok "the DIVE-4293 picker still matches its own footer" \
  "↑/↓ to navigate · Enter to select" "$(printf '%s\n' "$PICKER_PANE" | _sup_prompt_match)"
ok "the confirm does not match the DIVE-4293 footer (it is why it was invisible)" \
  "" "$(printf '%s\n' "$CONFIRM_PANE" | _sup_prompt_match)"

# Each part of the conjunction is load-bearing: drop one and the match must go.
ok "question + Yes but no Esc footer -> no match" \
  "" "$(printf '%s\n' "$(grep -v 'Esc to cancel' <<<"$CONFIRM_PANE")" | _sup_confirm_match)"
ok "question + footer but no numbered Yes -> no match" \
  "" "$(printf '%s\n' "$(grep -v '1\. Yes' <<<"$CONFIRM_PANE")" | _sup_confirm_match)"
ok "Yes + footer but no question -> no match" \
  "" "$(printf '%s\n' "$(grep -v 'Do you want to proceed' <<<"$CONFIRM_PANE")" | _sup_confirm_match)"

# ── the classifier ──────────────────────────────────────────────────────────
# args: desired svc active sess tmux poller loop_stuck has_work act_age
#       cli_stale goal_drift verify stranded open_rows no_output quota_excerpt
#       quota_deadline prompt_excerpt prompt_mark account_wall pane_probe
cls()  { _sup_classify "$@" | cut -f1,2 -d $'\x1f'; }
det()  { _sup_classify "$@" | cut -f3- -d $'\x1f'; }
Q="Do you want to proceed?"

ok "a dwelt confirm -> blocked-on-prompt/dangerous-confirm" \
  $'blocked-on-prompt\x1fdangerous-confirm' \
  "$(cls "" 1 active s alive n/a 0 1 3600 false "" "" 0 0 -1 "" unknown "$Q" confirm)"
has "and it says it is declinable" "declinable (Esc)" \
  "$(det "" 1 active s alive n/a 0 1 3600 false "" "" 0 0 -1 "" unknown "$Q" confirm)"
ok "a confirm inside its dwell -> same class and cause, not pressable" \
  $'blocked-on-prompt\x1fdangerous-confirm' \
  "$(cls "" 1 active s alive n/a 0 1 60 false "" "" 0 0 -1 "" unknown "$Q" confirm-fresh)"
has "and it says the decline is waiting" "the decline waits" \
  "$(det "" 1 active s alive n/a 0 1 60 false "" "" 0 0 -1 "" unknown "$Q" confirm-fresh)"
hasnt "a confirm is never described as an answerable picker" "Recommended" \
  "$(det "" 1 active s alive n/a 0 1 3600 false "" "" 0 0 -1 "" unknown "$Q" confirm)"

# DIVE-4293 regression: the picker's two marks are untouched.
ok "a (Recommended) picker still classifies as before" \
  $'blocked-on-prompt\x1fblocked-on-prompt' \
  "$(cls "" 1 active s alive n/a 0 1 3600 false "" "" 0 0 -1 "" unknown "Enter to select" recommended)"
ok "an unmarked picker still classifies as before" \
  $'blocked-on-prompt\x1fblocked-on-prompt' \
  "$(cls "" 1 active s alive n/a 0 1 3600 false "" "" 0 0 -1 "" unknown "Enter to select" unmarked)"

# THE INCIDENT, END TO END. The seat that produced 60 HELD lines: active work,
# no transcript progress for 10h, the meter on the pane, no refusal sentence.
# With the meter no longer classifying, quota_excerpt is empty — and the verdict
# is the one that was suppressed for ten hours.
ok "dev3's 10h window with no confirm read -> stuck/no-progress (the nudge fires)" \
  $'stuck\x1fno-progress' \
  "$(cls "" 1 active s alive n/a 0 1 36000 false "" "" 0 0 -1 "" unknown "" unmarked)"
ok "dev3's 10h window WITH the confirm read -> the more specific verdict wins" \
  $'blocked-on-prompt\x1fdangerous-confirm' \
  "$(cls "" 1 active s alive n/a 0 1 36000 false "" "" 0 0 -1 "" unknown "$Q" confirm)"
# POSITIVE CONTROL: a seat behind a REAL wall is still classified and still held.
ok "a real refusal still classifies quota-exhausted" \
  $'quota-exhausted\x1fquota-exhausted' \
  "$(cls "" 1 active s alive n/a 0 1 36000 false "" "" 0 0 -1 "Claude usage limit reached · continuing automatically at 8am (UTC)" unknown "" unmarked)"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
