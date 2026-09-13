#!/usr/bin/env bash
# DIVE-4401 — the Claude Team / org-monthly-spend usage wall, read off the pane.
#
# Two defects, both measured live 2026-09-13 04:31Z on two Telegram-enabled
# Claude Code 2.1.270 seats sharing one Team auth profile (main, olivia):
#
#   1. `_SUP_QUOTA_PAT`'s `hit your <window> limit` arm required the window noun
#      IMMEDIATELY after `your`. The Team banner says `hit your org's monthly
#      spend limit`, so the one line that also carries `session limit resets 9am
#      (UTC)` matched no arm at all.
#   2. The deadline was read off the SELECTED line only. The banner is a
#      sentence and the pane is a fixed width, so the signature and the clock
#      land on different physical lines whenever it wraps — which is why
#      `agent info main` reported quotaDeadline=live and `agent info olivia`
#      reported `unknown` off byte-equivalent reset text.
#
# Pure: no tmux, no root, no network. `now` is injected so every arm is
# assertable at a fixed clock.
# Run: bash tests/supervisor_team_wall_unit.sh
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

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}
tc() {  # <desc> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected to contain '$2', got '$3'"
  fi
}

# 2026-09-13 04:31:00 UTC — the measured wall. The banner's reset clock is
# 9am (UTC) the same day, i.e. 4h29m in the future at this instant.
NOW=$(TZ=UTC date -d '2026-09-13 04:31:00 UTC' +%s)
WANT=$(TZ=UTC date -d '2026-09-13 09:00:00 UTC' +%s)

qm()  { printf '%s\n' "$1" | _sup_quota_match "$NOW"; }
qd()  { _sup_quota_deadline "$1" "$NOW"; }
qst() { qd "$1" | cut -d$'\x1f' -f1; }
qep() { qd "$1" | cut -d$'\x1f' -f2; }

# --- the two measured panes, wrapped as the terminals actually wrapped them ---
# olivia: the org-spend sentence first (wrapped across two physical lines), the
# short "Usage limit reached" line after it.
OLIVIA="assorted scrollback above the wall
You've hit your org's monthly spend limit · ask your admin to raise it at
claude.ai/admin-settings/usage · your session limit resets 9am (UTC)
Usage limit reached ·
continuing automatically at 9am"

# main: the "reached again after you continued" variant first, then the same
# org-spend sentence.
MAIN="Usage limit reached again after you continued · continuing automatically at 9am
the automatic-continue setting no longer ends this wait
You've hit your org's monthly spend limit · ask your admin to raise it at
claude.ai/admin-settings/usage · your session limit resets 9am (UTC)"

# --- 1. the org-spend HEADER line is now a signature at all (defect 1) -------
O_EXC=$(qm "$OLIVIA")
tc "olivia: the Team org-spend banner is recognised" "monthly spend limit" "$O_EXC"

# --- 2. the wrapped clock is joined, so the deadline is live (defect 2) ------
t "olivia: deadline state is live, not unknown" "live" "$(qst "$O_EXC")"
t "olivia: deadline epoch is the banner's 9am (UTC)" "$WANT" "$(qep "$O_EXC")"

# --- 3. deliverable 4: the two panes AGREE on byte-equivalent reset text -----
M_EXC=$(qm "$MAIN")
t "main: deadline state is live" "live" "$(qst "$M_EXC")"
t "main: deadline epoch is the banner's 9am (UTC)" "$WANT" "$(qep "$M_EXC")"
t "main and olivia agree on the deadline epoch" "$(qep "$M_EXC")" "$(qep "$O_EXC")"

# --- 4. the unwrapped one-liner is unchanged (no regression, no join) --------
ONE="You've hit your session limit · resets 9am (UTC)"
t "unwrapped one-liner still reads live"   "live"  "$(qst "$(qm "$ONE")")"
t "unwrapped one-liner keeps its own epoch" "$WANT" "$(qep "$(qm "$ONE")")"
t "unwrapped one-liner is not extended by a neighbour" "$ONE" "$(qm "$ONE")"

# --- 5. negative control: prose that merely mentions an org spend limit ------
PROSE="we should raise the org spend limit before Friday
the monthly spend limit conversation is on the agenda"
t "prose about a spend limit is not a wall" "" "$(qm "$PROSE")"

# --- 6. negative control: a bare clock line cannot lend its time -------------
# `resets 9am (UTC)` with no `limit` / `continuing automatically` lead-in is not
# something _sup_quota_deadline will read, so an untimed signature beside it
# must still abstain (DIVE-3880: unknown is never resolved).
BARE="credit balance is too low
resets 9am (UTC)"
t "a bare clock line does not join an untimed signature" "unknown" "$(qst "$(qm "$BARE")")"
t "the untimed signature is emitted unextended" "credit balance is too low" "$(qm "$BARE")"

# --- 7. DIVE-3880 aggregation still holds across joined candidates -----------
# A lapsed wrapped banner ABOVE a live wrapped banner: the live one wins.
TWO="You've hit your org's monthly spend limit · ask your admin to raise it at
claude.ai/admin-settings/usage · your session limit resets 3am (UTC)
You've hit your org's monthly spend limit · ask your admin to raise it at
claude.ai/admin-settings/usage · your session limit resets 9am (UTC)"
t "a still-future joined deadline outranks a lapsed one" "$WANT" "$(qep "$(qm "$TWO")")"

# A wholly lapsed window stays lapsed (the alarm really does disarm).
LAPSED="You've hit your org's monthly spend limit · ask your admin to raise it at
claude.ai/admin-settings/usage · your session limit resets 3am (UTC)"
t "an all-lapsed joined window reads lapsed" "lapsed" "$(qst "$(qm "$LAPSED")")"

# --- 8. DIVE-3778 regression: a clean pane must not kill an errexit caller ---
CLEAN="agent-olivia is idle
nothing to report"
t "a clean pane yields no excerpt" "" "$(qm "$CLEAN")"
( set -e; printf '%s\n' "$CLEAN" | _sup_quota_match "$NOW" >/dev/null; echo ALIVE ) | grep -q ALIVE \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: clean pane killed an errexit caller"; }

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
