#!/usr/bin/env bash
# TIER: core — the per-filer daily filing budget, ENFORCED (DIVE-3245).
#
# WHY IT EXISTS. lodar's instinct was to forbid verifiers from filing low/medium
# rows. main measured it first and the target was wrong: verifiers filed 10 of
# 1092 low/medium rows in a month, and main filed 577. Of the 1092, 245 were
# cancelled. main already had a filing cap in his own directives and it was not
# binding — "a rule nobody enforces is detection, not control."
#
# THE TWO ARMS THAT MATTER, and they are the two halves of one question, because
# a cap that never fires and a cap that fires on everyone both print no complaints:
#   fires    a filer over budget, at low/medium, is REFUSED with a non-zero rc
#   spares   the same board does NOT refuse urgent/high, and does not refuse a
#            filer at a normal day's volume
#
# NO BYPASS. There is deliberately no flag and no env override — an env-tunable
# cap is the bypass spelled differently, and invisible in the record. So this
# harness trips the REAL threshold by seeding real rows, which is also why it
# cannot be fooled by a cap that was quietly loosened.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# DIVE_TEST_SRC lets tests/filing_volume_cap_mutation.sh run this whole harness
# against a MUTATED copy of src/ — the connection proof. Without it a mutation
# harness can only re-read the file it just edited, which proves nothing about
# whether these arms are wired to the code.
SRC="${DIVE_TEST_SRC:-$ROOT/src}"
TMP=$(mktemp -d /tmp/filing-volume-cap.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
chk() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
# The cap governs the SHARED board, so it only applies to the shared board
# (_task_filing_cap_store_is_prod). Declare this fixture as prod or every arm
# below is vacuous — the cap would decline to enforce and each "refused" arm
# would be measuring the fence, not the rule.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
# Do not write fixture rows into the production fleet audit log (DIVE-3228).
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
tasks_db_init; _tasks_db_migrate >/dev/null 2>&1

CAP="$_TASK_FILING_DAILY_CAP"
# BEHAVIOURAL, not a grep of the source. A source grep would still pass if the
# assignment were `${_TASK_FILING_DAILY_CAP:-15}` — which is exactly the bypass
# this row forbids, spelled so it reads like a default. Export a hostile value
# and re-source: the constant must survive it.
_cap_under_env=$( SRC="$SRC" _TASK_FILING_DAILY_CAP=999 bash -c '
  set +e
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
           lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
           lib/tasks_db.sh lib/actor.sh cmd_task.sh; do . "$SRC/$f" 2>/dev/null; done
  printf "%s" "$_TASK_FILING_DAILY_CAP"' 2>/dev/null )
chk "the cap is a CONSTANT: a hostile env value does NOT raise it" "15" "$_cap_under_env"

seed() { # <filer> <n> <priority> [age-hours]
  local who="$1" n="$2" pri="$3" age="${4:-1}" i
  for (( i=0; i<n; i++ )); do
    db "INSERT INTO tasks (title,body,priority,assignee,created_by,kind,status,created_at)
        VALUES ('seeded row $who $i','','$pri','$who','$who','standard','todo',
                datetime('now','-${age} hours'));" >/dev/null 2>&1
  done
}
add_as() { # <filer> <priority> <title> -> rc, output on stdout
  ( JSON_MODE=0; cmd_task_add "$3" --priority="$2" --from="$1" ) 2>&1
}
rc_of() { ( JSON_MODE=0; cmd_task_add "$3" --priority="$2" --from="$1" ) >/dev/null 2>&1; printf '%s' "$?"; }

# ---- a filer at a NORMAL day's volume is untouched --------------------------
# The median filer's worst rolling-24h on the real board is 4.5, and ten of
# fourteen filers never exceed 6. This arm is the one that proves the cap is not
# simply always-on — without it, every "refused" arm below is satisfied by a
# rule that refuses everything.
seed quiet 6 medium 2
chk "a filer at 6/24h (above the real median) files fine" "0" "$(rc_of quiet medium 'ordinary finding')"

# ---- the cap FIRES ----------------------------------------------------------
seed heavy "$CAP" medium 2
out=$(add_as heavy medium 'one row too many')
chk "at the cap, a medium row is REFUSED" "1" "$(grep -c 'filing cap' <<<"$out")"
chk "and the refusal is non-zero rc, not a warning" "$E_VALIDATION" "$(rc_of heavy medium 'another one')"
chk "low is capped too, not just medium" "1" \
    "$(add_as heavy low 'a low one' | grep -c 'filing cap')"

# ---- what the refusal SAYS is the product ----------------------------------
# A refusal that only names the limit buys silence, not judgement.
chk "it names the ALTERNATIVE, not just the limit (the row body)" "1" \
    "$(grep -c 'BODY of the row you found it on' <<<"$out")"
chk "it points at the wiki for durable knowledge" "1" "$(grep -c 'community/wiki' <<<"$out")"
chk "it states there is NO bypass flag" "1" "$(grep -c 'no bypass flag' <<<"$out")"
chk "it records the refused title rather than losing it" "1" \
    "$(grep -c 'REFUSED TITLE' <<<"$out")"
chk "and the title really is in policy_refusals" "1" \
    "$(db "SELECT COUNT(*) FROM policy_refusals WHERE detail LIKE '%one row too many%';")"

# ---- serious work is NEVER capped ------------------------------------------
# lodar, 2026-08-09: a quota that can block a SERIOUS finding will eventually eat
# one. The priority escape is the designed way out, and it is better than a flag
# because it is a claim about severity, recorded on the row.
chk "urgent is never capped, even far over budget" "0" "$(rc_of heavy urgent 'production is down')"
chk "high is never capped" "0" "$(rc_of heavy high 'a serious finding')"

# ---- the window is ROLLING, and old rows fall out of it ---------------------
# A calendar-day cap lets a burst straddle midnight and clear itself, which is
# the shape that produced the damage (one filer, 65 rows in a day).
seed stale "$CAP" medium 30
chk "rows older than 24h do NOT count toward the cap" "0" \
    "$(rc_of stale medium 'a fresh day')"

# ---- what must not be counted ----------------------------------------------
# A recurring instance is MATERIALIZED by the scheduler, not filed by a person.
# Counting it fires the cap on a cadence nobody chose that day.
seed tmpl "$CAP" medium 2
db "UPDATE tasks SET from_template_id=999 WHERE created_by='tmpl';" >/dev/null 2>&1
chk "template-materialized rows do NOT count toward their creator's cap" "0" \
    "$(rc_of tmpl medium 'a real filing on a template lane')"

# ---- the fence: a fixture store is not the shared board ---------------------
# Liveness in the other direction — the arms above are only meaningful because
# this fixture DECLARED itself prod. Undeclare it and the same over-budget filer
# files freely, which proves those refusals came from the rule, not the fence.
chk "off the shared board the cap declines to enforce" "0" \
    "$( FIVEDIVE_PROD_TASKS_DB="$TMP/not-the-board.db" rc_of heavy medium 'off-board filing' )"

printf -- '-----\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
