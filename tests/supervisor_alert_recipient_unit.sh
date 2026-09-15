#!/usr/bin/env bash
# DIVE-4551 — WHO a supervisor fleet-health alert is addressed to, graded against
# a REAL org chart in a real store.
#
# The defect: `src/cmd_supervisor.sh` named `main` literally on both legs of all
# three alert rails. `main` is a seat that exists on exactly one box in the world
# — ours. On the customer box this was reported from (teal-fox, 0.40.0, three org
# roots, none of them called main) `agent send main` failed with "no agent named
# 'main'" and `_task_agent_channel main` was false, so every alert since 0.38.0
# reached nobody and the only trace was a warn line in a cron log.
#
# Why this harness exists ALONGSIDE supervisor_escalate_delivery_unit.sh: that one
# stubs the resolver, so it grades that the alert HONOURS what it resolves. This
# one runs `_task_resolve_gate_notifier` / `_task_resolve_coordinator` for real
# against three charts, because the RESOLUTION is what the row is about and a
# harness that stubbed it would be testing its own stub.
#
# Run: bash tests/supervisor_alert_recipient_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/sup-alert-recipient-unit.XXXXXX)"
STATE_DIR="$TMP"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh \
         task/routing.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
# The store fence (DIVE-2054) guards a PRODUCTION store; this one is isolated.
_task_human_send_allowed() { return 0; }

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}
chart() { db "DELETE FROM agents_org;"; }

# ── 1. THIS box, as it actually is on 2026-09-15 ─────────────────────────────
# Read off `5dive org ls` before the fix was written, and it is the arm that
# decides which resolver is correct: the row proposed `_task_resolve_coordinator`
# and asserted it returns `main` here. It does NOT — the lone root is olivia (the
# advisory CEO) and `main` is the seat tagged `gate notifier` (DIVE-4365). So the
# literal proposal would have moved every fleet-health alert on this box off the
# CTO who co-owns the D4 runbook these messages cite. The notifier resolver keeps
# it on main AND fixes the customer box below, which is why it is the one used.
chart
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('olivia','AI CEO — conducts the fleet (advisory)',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('main','engineering + infra + the 5dive CLI — gate notifier','olivia');"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('ops','DevOps / SRE','main');"
t "this box: alerts still resolve to main — no behaviour change here" \
  "main" "$(_sup_alert_recipient)"
t "this box: and the coordinator the row proposed is NOT main (the discriminator)" \
  "olivia" "$(_task_resolve_coordinator)"

# ── 2. the customer box the row was filed on ─────────────────────────────────
# One root, nothing tagged: the notifier falls back to the coordinator, which is
# exactly the resolution the row asked for. No seat named `main` anywhere.
chart
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-aleks','founder',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-ivan','engineer','claude-aleks');"
t "lone-root customer chart: resolves the root, with no seat named main present" \
  "claude-aleks" "$(_sup_alert_recipient)"

# ...and the narrow override, which is the whole reason the notifier knob is the
# right one: tagging a seat moves the ALERTS alone, where tagging a coordinator
# would also hand them every unassigned row and every default plan (the six call
# sites named in the DIVE-4365 note in src/task/routing.sh).
db "UPDATE agents_org SET role='engineer — gate notifier' WHERE name='claude-ivan';"
t "lone-root customer chart: an explicit tag overrides the root" \
  "claude-ivan" "$(_sup_alert_recipient)"
t "...and moves ONLY the alerts — the queue coordinator is untouched" \
  "claude-aleks" "$(_task_resolve_coordinator)"

# ── 3. the teal-fox chart as reported: THREE roots, none tagged ──────────────
# Nothing resolves, and that is not a bug in the resolver — it is the state the
# box is in. What must not happen is a silent drop.
chart
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-aleks','founder',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-alena','ops',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-jane','eng',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-ivan','engineer','claude-aleks');"
t "three untagged roots: nothing resolves (ambiguous, never a guess)" \
  "" "$(_sup_alert_recipient)"

# The end-to-end property, through the REAL alert function against the REAL
# store: the tick completes, the audited alert row is still owed by the caller,
# and the lost legs leave rows of their own that `5dive doctor` can read.
MACHINE_FIRED=0
5dive() { MACHINE_FIRED=1; return 0; }
_task_agent_channel() { return 0; }
_task_send_owner() { return 0; }
_SUP_ALERTS_UNDELIVERABLE=0
_sup_capacity_alert claude-ivan no-output "1 open row(s), nothing closed in 32d" true true
rc=$?
unset -f 5dive
t "three untagged roots: the alert path RETURNS — a lost leg never aborts a tick" \
  "0" "$rc"
t "three untagged roots: no send is attempted to a name that cannot resolve" \
  "0" "$MACHINE_FIRED"
t "three untagged roots: both lost legs are counted for the tick summary" \
  "2" "$_SUP_ALERTS_UNDELIVERABLE"
t "three untagged roots: and audited as their own rows, readable after the fact" \
  "2" "$(db "SELECT COUNT(*) FROM supervisor_events WHERE event='alert-undeliverable' AND agent='claude-ivan';")"
t "...carrying the REASON, not just the fact" \
  "no-coordinator" "$(db "SELECT DISTINCT cause FROM supervisor_events WHERE event='alert-undeliverable';")"
t "...and both legs are distinguishable in the row" \
  "human machine" "$(db "SELECT DISTINCT json_extract(signals,'\$.leg') FROM supervisor_events WHERE event='alert-undeliverable' ORDER BY 1;" | paste -sd' ' -)"
# The negative control: the SAME alert on a chart that resolves writes no
# undeliverable row at all. Without it every arm above is satisfied by an
# implementation that files one unconditionally.
chart
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-aleks','founder',NULL);"
db "DELETE FROM supervisor_events;"
5dive() { MACHINE_FIRED=1; return 0; }
_SUP_ALERTS_UNDELIVERABLE=0; MACHINE_FIRED=0
_sup_capacity_alert claude-ivan no-output "d" true true
unset -f 5dive
t "control: a resolvable chart sends, and files NO undeliverable row" \
  "1:0:0" "$MACHINE_FIRED:$_SUP_ALERTS_UNDELIVERABLE:$(db "SELECT COUNT(*) FROM supervisor_events WHERE event='alert-undeliverable';")"

# ── 4. END TO END through the REAL tick, on the customer's chart ────────────
# The row's second acceptance criterion, at the layer it names: the tick still
# COMPLETES, supervisor_events carries the alert row AND an alert-undeliverable
# row, and the summary line a person or a cron log actually reads says so. The
# alert function is deliberately NOT stubbed here — that is the whole point of
# this arm, and it is the one thing the sibling harness's tick arms cannot show,
# because they replace _sup_capacity_alert to observe its arguments.
# The inner script is a FILE, not a `bash -c` string: it needs single quotes of
# its own for the SQL, and a nested single-quoted argument cannot carry them.
cat >"$TMP/tick.sh" <<'TICKEOF'
set -uo pipefail
TMP=$(mktemp -d)
export STATE_DIR="$TMP/state" TASKS_DIR="$TMP/tasks" TASKS_DB="$TMP/tasks/tasks.db"
mkdir -p "$STATE_DIR" "$TASKS_DIR"
JSON_MODE=0
cd "$REPO"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh \
         task/routing.sh cmd_supervisor.sh; do
  . "src/$f"
done
_SUP_ENABLED_FLAG="$TMP/enabled"; : >"$_SUP_ENABLED_FLAG"
_SUP_ACTIONS_FLAG="$TMP/actions"
_SUP_QUOTA_ALERTS_FLAG="$TMP/quota-alerts"
require_root()        { :; }                    # the tick is root-only in prod
_sup_cli_check()      { :; }                    # no network
registry_read()       { printf '{"agents":{}}'; }
_task_agent_channel() { return 1; }             # no telegram anywhere
_task_send_owner()    { return 0; }
_sup_snapshot() {
  printf '%s' '[{"name":"claude-ivan","type":"claude","classification":"no-output","cause":"no-output","detail":"1 open row(s), nothing closed in 32d"}]'
}
( tasks_db_init ) >/dev/null 2>&1 || true
# The teal-fox chart: three roots, none tagged, no seat named main.
for a in claude-aleks claude-alena claude-jane; do
  ( db "INSERT INTO agents_org (name, role, reports_to) VALUES ('$a','root',NULL);" ) >/dev/null 2>&1 || true
done
summary=$(cmd_supervisor_tick 2>/dev/null); rc=$?
printf 'RC=%s|SUMMARY=%s|ALERTS=%s|UNDELIV=%s|HB=%s' \
  "$rc" "$summary" \
  "$(db "SELECT COUNT(*) FROM supervisor_events WHERE event='alert';")" \
  "$(db "SELECT COUNT(*) FROM supervisor_events WHERE event='alert-undeliverable';")" \
  "$(db "SELECT COALESCE(json_extract(signals,'\$.alertsUndeliverable'),'ABSENT')
         FROM supervisor_events WHERE event='heartbeat' LIMIT 1;")"
rm -rf "$TMP"
TICKEOF
tick_out=$(REPO="$PWD" bash "$TMP/tick.sh")
tfld() { local rest="${1#*"$2"=}"; printf '%s' "${rest%%|*}"; }
t "tick e2e: the tick completes — an undeliverable alert never aborts it"   "0" "$(tfld "$tick_out" RC)"
t "tick e2e: the audited alert row is still written (the DIVE-3272 cover)"   "1" "$(tfld "$tick_out" ALERTS)"
t "tick e2e: ...alongside an alert-undeliverable row"   "1" "$(tfld "$tick_out" UNDELIV)"
# no-output mutes the HUMAN leg (DIVE-3982), so exactly one leg was asked for and
# exactly one can be lost. A count of 2 here would mean the muted leg was counted.
t "tick e2e: the heartbeat row carries the count for later analysis"   "1" "$(tfld "$tick_out" HB)"
t "tick e2e: and the summary line SAYS SO instead of leaving it in a warn"   "yes" "$([[ "$(tfld "$tick_out" SUMMARY)" == *"UNDELIVERABLE"* ]] && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
