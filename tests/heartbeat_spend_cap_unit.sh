#!/usr/bin/env bash
# DIVE-3465 unit harness: a retryable rate limit and a hard spend cap are TWO
# states, and the dispatcher must not collapse them.
#
# The defect this guards: `_hb_pane_is_usage_limit` (DIVE-1666) answers only "is
# this seat parked on a wall dialog" and matches the monthly-spend and 5-hour
# variants alike, so every wall got the RETRY response — press-continue, restart,
# re-nudge. Against a rolling 5h window that is correct. Against a monthly spend
# ceiling it cannot help, and each retry is a whole dispatched session that
# produces nothing: ~20 of 50 analysed sessions accomplished literally nothing,
# and DIVE-3384 was re-attempted across 15+ sessions while still reading `todo`.
#
# What is asserted here:
#   1. _hb_wall_class discriminates the two walls on real dialog text, with the
#      monthly-spend case FIRST-WINS over its own "wait for limit to reset" line
#      (the ordering bug that would make every hard cap read as retryable);
#   2. it has a THIRD outcome — undetermined — and never folds "could not tell"
#      into the retry verdict;
#   3. negative controls: ordinary prompts, and a pane that merely QUOTES a wall
#      (this row's own body does), must not classify as a wall at all;
#   4. the dispatch hold arms, survives an unrelated counter clear, and is
#      released only by a live measurement — with an unreadable probe returning
#      COULD-NOT-DETERMINE rather than headroom.
# Run: bash tests/heartbeat_spend_cap_unit.sh  (no root, no network, no tmux).
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NOTE the absence of 2>/dev/null —
# redirecting the source's stderr also swallows the helper's own stderr line,
# which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMPD:-}"; echo "HARNESS-RC=$rc"' EXIT
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

TMPD=$(mktemp -d /tmp/spend-cap-test.XXXXXX)
REGISTRY="$TMPD/registry.json"
REGISTRY_LOCK="$TMPD/registry.lock"
printf '%s' '{"agents":{
  "dev":  {"authProfile":"acctA","heartbeat":{"enabled":true}},
  "dev2": {"authProfile":"acctA","heartbeat":{"enabled":true}},
  "solo": {"authProfile":"acctB","heartbeat":{"enabled":true}}
}}' > "$REGISTRY"
registry_write() { local tmp; tmp=$(mktemp "${REGISTRY}.XXXXXX"); cat > "$tmp"; mv "$tmp" "$REGISTRY"; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }  # no flock/ensure_state in the harness

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want '$3' got '$2'"; fi; }
cls_t() { local want="$3" got; got=$(_hb_wall_class "$2"); eq_t "$1" "$got" "$want"; }

# --- 1. The two walls, on the text Claude Code actually prints ----------------
# The monthly-spend dialog CONTAINS "wait for limit to reset". If the reset-time
# arm were tested first, every hard cap would read as retryable — which is the
# defect, not a nicety. This is the ordering regression.
MONTHLY=$'You'"'"'ve hit your monthly spend limit\n\n  1. Stop and wait for limit to reset\n  2. Upgrade your plan'
cls_t "monthly spend dialog = spend-cap (despite offering a reset)" "$MONTHLY" "spend-cap"

FIVEHR=$'Usage limit reached\n\nYour limit will reset at 3pm.'
cls_t "5h usage-limit dialog = rate-limit" "$FIVEHR" "rate-limit"

WEEKLY_RATE=$'You'"'"'ve hit your weekly limit\n\nResets at 2026-08-18 09:00.'
cls_t "weekly rolling window = rate-limit" "$WEEKLY_RATE" "rate-limit"

WEEKLY_SPEND=$'You'"'"'ve hit your weekly spend limit\n\n  1. Stop and wait for limit to reset\n  2. Upgrade your plan'
cls_t "weekly SPEND ceiling = spend-cap" "$WEEKLY_SPEND" "spend-cap"

CREDIT=$'Usage limit reached\n\nYour credit balance is too low to run this request. Upgrade your plan or purchase more credits.'
cls_t "credit-balance refusal = spend-cap" "$CREDIT" "spend-cap"

# --- 2. The third outcome, emitted rather than folded -------------------------
# A wall (both signature lines present) that names neither a spend ceiling nor a
# reset time. The honest answer is "I could not tell". Folding it into
# rate-limit would restore the exact retry loop this row exists to stop.
VAGUE=$'You'"'"'ve reached your plan limit\n\nUpgrade your plan to continue.'
cls_t "wall with no discriminator = undetermined (never rate-limit by default)" "$VAGUE" "undetermined"

# --- 3. Negative controls: not a wall at all ----------------------------------
PERM=$'Claude wants to run:\n  rm -rf build/\n\n  1. Yes  2. No, and tell Claude what to do differently'
cls_t "permission dialog is not a wall" "$PERM" "none"
cls_t "marketing copy alone is not a wall" "Upgrade your plan for more features" "none"
# rc contract: `none` must ALSO return non-zero, so `_hb_wall_class ... || x=none`
# is a correct idiom at every call site.
_hb_wall_class "$PERM" >/dev/null && bad_t "none must return non-zero" || ok_t "none returns non-zero (callers may use ||)"
_hb_wall_class "$MONTHLY" >/dev/null && ok_t "a classified wall returns zero" || bad_t "spend-cap must return zero"

# THE SELF-MATCH CONTROL. A seat that is DISCUSSING a wall — this row's own body
# quotes the dialog verbatim — must not be read as being behind one. The
# supervisor's `quota-exhausted` verdict fails exactly here (it self-matches the
# investigator), which is why this fix reads the parked dialog instead.
QUOTING=$'The dispatcher cannot tell a retryable 429 from a hard spend cap.\nEvery turn returned "You'"'"'ve hit your monthly spend limit" or a 429 quota error.\nNothing between the task engine and the seat distinguishes them.'
cls_t "a pane QUOTING the wall is not a wall" "$QUOTING" "none"

# The DIVE-3465 header widening (weekly/daily) must NOT relax the two-signature
# discipline that keeps ordinary output from reading as a wall.
cls_t "a weekly header with no action line is not a wall" "You've hit your weekly limit" "none"
cls_t "prose about a daily spend limit is not a wall" "we should hit your daily spend limit discussion" "none"

# --- 4. The dispatch hold: arm, persist, release only on a measurement --------
n=$(with_registry_lock _hb_mark_spend_cap dev 1000);  eq_t "1st observation count = 1" "$n" "1"
at=$(_hb_spend_cap_at dev);                            eq_t "hold stamped at first observation" "$at" "1000"
n=$(with_registry_lock _hb_mark_spend_cap dev 5000);  eq_t "2nd observation count = 2" "$n" "2"
at=$(_hb_spend_cap_at dev);                            eq_t "first-observation epoch is NOT overwritten" "$at" "1000"
seen=$(jq -r '.agents.dev.heartbeat.spendCap.lastSeenAt' "$REGISTRY")
eq_t "latest observation is recorded separately" "$seen" "5000"
at=$(_hb_spend_cap_at solo);                           eq_t "un-capped seat reads 0 (no hold)" "$at" "0"

p=$(_hb_spend_cap_probed dev);                         eq_t "no probe yet reads 0" "$p" "0"
with_registry_lock _hb_mark_spend_cap_probe dev 6000
p=$(_hb_spend_cap_probed dev);                         eq_t "probe epoch stored" "$p" "6000"
at=$(_hb_spend_cap_at dev);                            eq_t "probing does not release the hold" "$at" "1000"

# The deliberate NON-fold: _hb_clear_active_defer wipes the defer/heal/press
# counters on any wake bookkeeping. It must NOT wipe a billing hold — that would
# be a release with no measurement behind it.
_hb_clear_active_defer dev
at=$(_hb_spend_cap_at dev)
eq_t "a defer/heal counter clear does NOT release the spend-cap hold" "$at" "1000"

with_registry_lock _hb_clear_spend_cap dev
at=$(_hb_spend_cap_at dev);                            eq_t "explicit clear releases the hold" "$at" "0"

# --- 5. _hb_spend_cap_lifted is three-state, and 'could not look' holds -------
# Stub the two live instruments: peer state and the seat's own pane.
_STATE=""; _hb_agent_native_state() { case "$1" in dev2) printf '%s' "$_STATE";; *) printf '';; esac; }
_PANE=""; _PANE_RC=0; _hb_pane_capture() { printf '%s' "$_PANE"; return "$_PANE_RC"; }
reg=$(cat "$REGISTRY")

lift() { local rc=0; _hb_spend_cap_lifted "$1" "$2" "$reg" || rc=$?; printf '%s' "$rc"; }

_STATE="busy"; _PANE="$MONTHLY"; _PANE_RC=0
eq_t "a transacting peer on the account proves the cap lifted" "$(lift dev acctA)" "0"

_STATE="blocked:dialog open"
eq_t "wall still on the seat's screen = still capped" "$(lift dev acctA)" "1"

_PANE=$'agent-dev $ '                       # ordinary prompt, no wall
eq_t "wall gone from the seat's screen = lifted" "$(lift dev acctA)" "0"

_PANE="$FIVEHR"
eq_t "a DIFFERENT wall is still a wall — hold stands" "$(lift dev acctA)" "1"

_PANE=""; _PANE_RC=0
eq_t "empty pane = COULD-NOT-DETERMINE (2), not headroom" "$(lift dev acctA)" "2"

_PANE=""; _PANE_RC=1
eq_t "failed capture = COULD-NOT-DETERMINE (2), not headroom" "$(lift dev acctA)" "2"

# Solo seat: no peer can ever prove headroom, so the verdict rests entirely on
# the seat's own screen — and an unreadable one must still hold.
_PANE="$MONTHLY"; _PANE_RC=0
eq_t "solo seat behind the wall = still capped" "$(lift solo acctB)" "1"
_PANE=""; _PANE_RC=1
eq_t "solo seat, unreadable pane = COULD-NOT-DETERMINE" "$(lift solo acctB)" "2"

# --- 6. The probe interval is a LOOK cadence, not an expiry -------------------
# Guard the wording as code: nothing in the release path reads a clock. If a
# future edit adds an "expire after N minutes" branch, this assertion is the one
# that should have to be deleted on purpose.
grep -qE '_HB_SPEND_CAP_PROBE_MIN' src/cmd_heartbeat.sh \
  && ok_t "probe interval knob exists" || bad_t "probe interval knob missing"
if declare -f _hb_spend_cap_lifted | grep -qE 'date |_HB_SPEND_CAP_PROBE_MIN|now'; then
  bad_t "the release verdict must not consult a clock — it is a measurement, not a timer"
else
  ok_t "the release verdict consults no clock (measurement, not timer)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
