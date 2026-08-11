#!/usr/bin/env bash
# DIVE-2794 arm two: the per-LANE WIP cap.
#
# Tokens cap what one row may SPEND (arm one); this caps how many rows a lane may
# HOLD. The arms that decide whether this is safe rather than merely present:
#
#  - THE CAP IS FROZEN, NOT TRACKING. The first spec had every close lower the
#    cap, which is a LOCK: after each close actionable == cap again, so the next
#    add refuses forever and the lane drains to zero. The arm that proves the fix
#    is "close a row, then successfully add one" — under the broken rule that add
#    is refused, so it cannot pass by accident.
#  - MATERIALIZATION IS EXEMPT. Six internal writers turn ONE approved decision
#    into N rows; a cap firing halfway leaves a half-materialized plan with a
#    loop driver waiting on a short child list. Exempt, but still COUNTED.
#  - HIGH/URGENT IS REDIRECTED, NEVER REFUSED (lodar 2026-08-09). And if every
#    lane is full it LANDS, because at that point refusing a serious finding is
#    the worse failure. Both branches are graded.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-wip-cap.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The cap only governs the SHARED board, so a fixture store disables it. Force it
# on — otherwise every arm below passes vacuously by never running the code.
_task_filing_cap_store_is_prod() { return 0; }
# Keep DIVE-2681 out of the way: it refuses on what a TITLE IS, and every arm here
# is about HOW MANY there are. Left live it would refuse fixture titles for the
# wrong reason and the tally would look identical.
_task_internal_subject_reason() { printf ''; }

# MONOTONIC idents. Restarting the numbering per call collided on UNIQUE, so the
# extra rows silently did not exist and the lane never reached the count the arm
# below asserted on — sqlite's error went to stderr while the tally read as a
# product failure. A fixture that cannot insert must not look like a cap that
# did not fire.
_SEEDN=0
seed() { # <lane> <n> <status>
  local i
  for i in $(seq 1 "$2"); do
    _SEEDN=$((_SEEDN+1))
    db "INSERT INTO tasks (ident,title,status,assignee,kind,priority,created_at,updated_at)
        VALUES ('SEED-$1-$3-${_SEEDN}','seed $1 $3 ${_SEEDN}','$3','$1','standard','medium',
                datetime('now','-$((1000-_SEEDN)) minutes'),datetime('now'));"
  done
}
# Assert the fixture actually landed, so a future collision fails HERE.
seeded_ok() { # <lane> <expected-actionable>
  [[ "$(_task_lane_actionable "$1")" == "$2" ]] \
    && ok_t "fixture: lane $1 holds $2 actionable rows" \
    || bad_t "FIXTURE BROKEN for lane $1" "expected $2, got $(_task_lane_actionable "$1") — arms below would grade the fixture, not the cap"
}
act_of() { _task_lane_actionable "$1"; }
cap_of()  { _task_wip_cap "$1"; }
install_caps() { ( cmd_task_wip_cap_install "$@" >/dev/null 2>&1 ); }
# add-in-a-subshell: policy_refuse ends in fail(), which exits.
try_add() { ( cmd_task_add "$@" >/dev/null 2>&1 ); }
add_err() { ( cmd_task_add "$@" 2>&1 >/dev/null ); }

seed alpha 3 todo
seed beta  1 todo

# ── 0. NO CAP UNTIL INSTALL. A store nobody installed against is uncapped —
#      this is what keeps the cap off every fixture that points
#      FIVEDIVE_PROD_TASKS_DB at itself, and off a fresh board.
if cap_of alpha >/dev/null 2>&1; then
  bad_t "a lane had a cap before install — caps must never be minted by a read" "$(cap_of alpha)"
else
  ok_t "before install, no lane has a cap (a read never mints one)"
fi
if try_add "pre-install row" --assignee=alpha --priority=medium; then
  ok_t "...and an uninstalled store does not enforce (fixtures and fresh boards are untouched)"
else
  bad_t "uninstalled store refused a filing" ""
fi
db "DELETE FROM tasks WHERE title='pre-install row';"

# ── 1. install snapshots the lane's own count, then FREEZES it ───────────────
install_caps
[[ "$(cap_of alpha)" == "3" ]] && ok_t "install snapshots the lane's actionable count (3)" \
  || bad_t "cap init" "$(cap_of alpha)"
seed alpha 2 todo                      # count moves to 5...
seeded_ok alpha 5
[[ "$(cap_of alpha)" == "3" ]] && ok_t "...and does NOT track the count afterwards (still 3)" \
  || bad_t "cap tracked the count" "$(cap_of alpha)"

# ── 2. blocked / parked / recurring do not count ─────────────────────────────
before=$(act_of beta)
seed beta 4 blocked
db "INSERT INTO tasks (ident,title,status,assignee,kind,priority,parked_at,created_at,updated_at)
    VALUES ('SEED-beta-parked','parked','todo','beta','standard','medium',datetime('now'),datetime('now'),datetime('now'));"
db "INSERT INTO tasks (ident,title,status,assignee,kind,priority,created_at,updated_at)
    VALUES ('SEED-beta-tmpl','tmpl','todo','beta','recurring','medium',datetime('now'),datetime('now'));"
[[ "$(act_of beta)" == "$before" ]] \
  && ok_t "blocked, parked and recurring rows are NOT actionable (attention is the resource)" \
  || bad_t "non-actionable counted" "before=$before now=$(act_of beta)"

# ── 3. a full lane refuses low/med, and the refusal is USABLE ────────────────
# alpha: cap 3, actionable 5 -> full
if try_add "a routine alpha row" --assignee=alpha --priority=medium; then
  bad_t "a full lane accepted a medium row" ""
else
  ok_t "a full lane REFUSES a medium row"
fi
err=$(add_err "a routine alpha row" --assignee=alpha --priority=medium)
for want in "alpha" "5/3" "SEED-alpha-todo-" "--task-budget=none" "FIVE_WIP_CAP=0"; do
  [[ "$err" == *"$want"* ]] && ok_t "refusal names [$want]" || bad_t "refusal missing [$want]" "$err"
done

# ── 4. THE ANTI-LOCK ARM. Close a row -> the COUNT drops, the cap does not, so
#      an add now succeeds. Under the original "every close lowers the cap" rule
#      this add is still refused, so this arm cannot pass by accident. ────────
db "UPDATE tasks SET status='done'
    WHERE id IN (SELECT id FROM tasks WHERE assignee='alpha' AND status='todo'
                 ORDER BY created_at ASC LIMIT 3);"
[[ "$(cap_of alpha)" == "3" ]] && ok_t "closing rows does not lower the cap" || bad_t "cap moved on close" "$(cap_of alpha)"
[[ "$(act_of alpha)" == "2" ]] && ok_t "...but it does lower the COUNT (2), which is the headroom" \
  || bad_t "count after closes" "$(act_of alpha)"
if try_add "now there is room" --assignee=alpha --priority=medium; then
  ok_t "close-one-to-file-one works — the lane is not a lock"
else
  bad_t "still refused after closing 3 rows — this is the drain-to-zero bug" "$(add_err "now there is room" --assignee=alpha --priority=medium)"
fi

# ── 5. high/urgent on a full lane is REDIRECTED, never plainly refused ───────
seed gamma 2 todo; install_caps; seed gamma 2 todo   # gamma installed at 2, now holds 4
# beta has headroom by construction (cap 1, actionable 1 -> full); give delta room
seed delta 3 todo; install_caps
db "UPDATE tasks SET status='done'
    WHERE id IN (SELECT id FROM tasks WHERE assignee='delta' AND status='todo' LIMIT 1);"
err=$(add_err "a serious gamma finding" --assignee=gamma --priority=high)
[[ "$err" == *"REDIRECT"* ]] && ok_t "a high row on a full lane is REDIRECTED" || bad_t "no redirect" "$err"
[[ "$err" == *"delta"* ]] && ok_t "...and the redirect NAMES a lane with headroom" || bad_t "no lane named" "$err"
[[ "$err" != *"Close something before adding"* ]] \
  && ok_t "...and does NOT get the low/med close-something refusal" \
  || bad_t "high got the med refusal text" "$err"
# The redirect must actually be actionable: the same row to the named lane works.
if try_add "a serious gamma finding" --assignee=delta --priority=high; then
  ok_t "...and re-filing to the named lane succeeds immediately (nothing is lost)"
else
  bad_t "redirect named a lane that also refuses" ""
fi

# ── 6. every lane full -> an urgent row LANDS anyway, loudly ─────────────────
db "UPDATE task_prefs SET value='1' WHERE key LIKE 'wip_cap:%';"   # every lane holds >=1 => all full
if try_add "saturated fleet urgent row" --assignee=alpha --priority=urgent; then
  ok_t "with NO lane free, an urgent row lands anyway (refusing a serious finding is the worse failure)"
else
  bad_t "urgent row refused with every lane full" "$(add_err "saturated fleet urgent row" --assignee=alpha --priority=urgent)"
fi
# ...and a MEDIUM row in the same saturated state is still refused, so arm 6 is
# about priority and not about the cap having quietly switched off.
if try_add "saturated fleet medium row" --assignee=alpha --priority=medium; then
  bad_t "control: a medium row also landed — the cap switched off rather than deferring to priority" ""
else
  ok_t "control: a medium row in the same saturated state is still refused"
fi

# ── 7. the trip counter records every trip ──────────────────────────────────
trips=$(db "SELECT value FROM task_prefs WHERE key='wip_cap_trips';")
[[ "$trips" =~ ^[0-9]+$ ]] && (( trips > 0 )) \
  && ok_t "wip_cap_trips counts trips (=$trips) so inflow is measured, not argued" \
  || bad_t "trip counter" "$trips"

# ── 8. the exemptions ───────────────────────────────────────────────────────
db "UPDATE task_prefs SET value='1' WHERE key LIKE 'wip_cap:%';"
# DIVE-3245 it.3: the exemption is no longer an argv flag — `--materialized` was an
# unguarded token any caller could assert, so it is gone and the exemption is derived
# from the call stack. This arm drives the SHIPPED door (`task_add_materialized`, what
# the six internal writers call), not a stub of it.
if ( task_add_materialized "materialized child" --assignee=alpha --priority=medium >/dev/null 2>&1 ); then
  ok_t "--materialized is exempt (a half-materialized plan is the worse failure)"
else
  bad_t "materialized row refused" ""
fi
# ...but it still COUNTS, so the next human filing is the one refused.
n_before=$(act_of alpha)
[[ "$n_before" -gt 0 ]] && ok_t "...and the materialized row still counts toward the lane" \
  || bad_t "materialized row not counted" "$n_before"
if try_add "budget-exempt row" --assignee=alpha --priority=medium --task-budget=none; then
  ok_t "--task-budget=none is the ONE carve-out, shared with the token arm"
else
  bad_t "carve-out row refused" ""
fi
if ( FIVE_WIP_CAP=0 cmd_task_add "override row" --assignee=alpha --priority=medium >/dev/null 2>&1 ); then
  ok_t "FIVE_WIP_CAP=0 is the fleet override"
else
  bad_t "override ignored" ""
fi

# ── 9. THE ZERO-LOCK. An EMPTY lane mints cap 0, and 0 >= 0 is a breach, so it
#       could never take its first row — a new agent frozen from birth, and any
#       lane that drained to empty frozen permanently. Same drain-to-zero shape
#       the frozen cap exists to prevent, let back in through INITIALISATION.
#       Found by CI, not by the arms above: every one of them seeds rows first,
#       so none of them could ever see an empty lane.
[[ "$(act_of freshlane)" == "0" ]] && ok_t "fixture: 'freshlane' is genuinely empty" \
  || bad_t "fixture not empty" "$(act_of freshlane)"
db "INSERT INTO tasks (ident,title,status,assignee,kind,priority,created_at,updated_at)
    VALUES ('SEED-fresh-marker','marker','done','freshlane','standard','medium',datetime('now'),datetime('now'));"
install_caps
[[ "$(cap_of freshlane)" == "1" ]] && ok_t "an EMPTY lane's cap floors at 1, never 0" \
  || bad_t "empty lane cap" "$(cap_of freshlane)"
if try_add "first row on a brand new lane" --assignee=freshlane --priority=medium; then
  ok_t "...so a brand-new lane can accept its first row (no zero-lock)"
else
  bad_t "ZERO-LOCK: an empty lane refused its first row" "$(add_err "first row on a brand new lane" --assignee=freshlane --priority=medium)"
fi
# ...and it is a cap of 1, not an exemption: the SECOND row is refused.
if try_add "second row on a brand new lane" --assignee=freshlane --priority=medium; then
  bad_t "control: the floored lane accepted a second row — floor became an exemption" ""
else
  ok_t "control: the second row on that lane IS refused (floor is a cap of 1, not a bypass)"
fi

# ── 10. install is IDEMPOTENT. Re-snapshotting on every run would make the cap
#        track the count again — the exact lock this arm was built to avoid.
before_cap=$(cap_of alpha)
install_caps
[[ "$(cap_of alpha)" == "$before_cap" ]] \
  && ok_t "re-running install does NOT re-snapshot an installed lane (no ratchet)" \
  || bad_t "install re-snapshotted" "was $before_cap now $(cap_of alpha)"

printf -- '-----\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
