#!/usr/bin/env bash
# DIVE-1945 — a gate's escalation chain must be walked from the agent that FILED
# it, not from the agent that created the task. The two differ whenever one agent
# files a gate on another's task, and `task gate-escalate` derived the filer as
# COALESCE(created_by, assignee) — so it started the walk on the CREATOR's branch
# of the org chart and attributed the ask to the creator.
#
# The fix persists the filer-of-record at file time (tasks.gate_filed_by) because
# gate-escalate is a SEPARATE privileged process: DIVE-1927's TASK_GATE_FILER env
# pin cannot cross that boundary, so the filer has to come off the row.
#
# Covered:
#   * cmd_task_need stamps gate_filed_by = the filing ACTOR, leaving created_by alone.
#   * cmd_task_gate_escalate walks the FILER's branch and names the FILER.
#   * a legacy gate (gate_filed_by NULL) still falls back to created_by — which is
#     also the non-vacuity control: two rows differing ONLY in that column escalate
#     to two different agents, so assertion 2 cannot be passing by accident.
#   * `task need --withdraw` clears the stamp with the rest of the gate provenance.
#
# Isolated: source src/ libs, throwaway STATE_DIR, the live tasks.db is never
# touched. Run: bash tests/gate_filer_of_record_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-filer-record.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_agent_pairing.sh cmd_agent_runtime.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"; : >"$FIVEDIVE_GATE_NOTIFY_LOG"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---- fleet fixture -----------------------------------------------------------
# TWO branches, on purpose: the creator (main) and the filer (dev3) must resolve
# to DIFFERENT managers, or "started at the wrong branch" is unobservable — both
# readings would deliver to the same agent and the test would grade nothing.
#   dev3 -> qa -> olivia            (the FILER's branch)
#   main -> olivia                  (the CREATOR's branch)
db "INSERT INTO agents_org (name,reports_to,role) VALUES
     ('dev3','qa',NULL),('qa','olivia',NULL),('main','olivia',NULL),
     ('olivia',NULL,'coordinator');"

# READABLE = this uid can read that agent's access.json. gate-escalate runs as
# root, which reads every one of them.
# The stub CLEARS TASK_CH_AGENT on entry and sets it on success, exactly like the
# shipped resolver (DIVE-2073). Without that, a failed resolve leaves the PREVIOUS
# call's agent standing and every "which agent got the alert" assertion grades
# stale state instead of this call.
READABLE=""; PAIRED=""
_task_agent_channel() {
  local n="$1"; TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE="" TASK_CH_AGENT=""
  [[ -n "$n" && " $READABLE " == *" $n "* ]] || return 1
  TASK_CH_TOKEN=tok TASK_CH_ACCESS="$TMP/access.json" TASK_CH_TYPE=claude TASK_CH_AGENT="$n"; return 0
}
_task_agent_paired() { local n="$1"; [[ -n "$n" && " $PAIRED " == *" $n "* ]]; }
# Caller-scoped owner probe. FILER_SELF="" reproduces the real root context (no
# SUDO_USER), where this is a structural no-op — see DIVE-1968.
_task_owner_channel() { _task_agent_channel "${FILER_SELF:-}"; }
task_actor() { local f="${1:-}"; [[ -n "$f" ]] && printf '%s' "$f" || printf '%s' "${FILER_SELF:-root}"; }
audit_log() { :; }
printf '%s\n' '{"allowFrom":["1234567890"]}' >"$TMP/access.json"

SENT=""; SENT_AGENT="x"; SENT_ACCESS="x"
_task_send_owner() {
  SENT="$1"; SENT_ACCESS="$TASK_CH_ACCESS"; SENT_AGENT="$TASK_CH_AGENT"
  TASK_SEND_DELIVERED=1; return 0
}
_task_gate_escalate_via_sudo() { return 1; }   # never needed: this IS the root run
_gate_is_root() { return 0; }                  # the DIVE-1968 root seam
# DIVE-1401's withdraw guard authorizes on the TRUSTED caller id (never --from),
# which in a harness is whoever runs the suite. Pin it so assertion 4 grades the
# column clearing rather than the runner's uid.
_gate_withdraw_actor() { printf 'agent dev3'; }

# NEVER run the verb inside $( ): it sets TASK_CH_*/SENT in the CALLER's shell and
# a command substitution would swallow every one of them — the assertions would
# then read empty strings and "went to the wrong agent" and "did not send at all"
# would be indistinguishable. Redirect to a file and read it back.
run_esc() { : >"$TMP/out"; cmd_task_gate_escalate "$1" >"$TMP/out" 2>&1; local r=$?; esc=$(cat "$TMP/out"); return $r; }

# ---- 1. the stamp: cmd_task_need records the FILER, not the creator ----------
# Filed by dev3 on a task main created. Nobody is paired, so the gate files
# UNNOTIFIED (rc 0, the DIVE-1927 contract) — the stamp must land regardless.
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
    VALUES ('DIVE-9101','creators task','high','main','main','standard','todo');"
FILER_SELF=""; READABLE=""; PAIRED=""
out=$( (cmd_task_need DIVE-9101 --type=decision --ask="which way?" --options="A|B" --recommend="A" --from=dev3) 2>&1 )
row=$(db "SELECT COALESCE(gate_filed_by,'NULL')||'|'||COALESCE(created_by,'NULL')||'|'||COALESCE(assignee,'NULL')
          FROM tasks WHERE ident='DIVE-9101';")
[[ "$row" == "dev3|main|dev3" ]] \
  && ok_t "task need stamps gate_filed_by=dev3 and leaves created_by=main" \
  || bad_t "gate_filed_by stamped at file time" "got '$row' (want 'dev3|main|dev3') out=${out:0:160}"

# ---- 2. gate-escalate walks the FILER's branch, and says so ------------------
# Everything above dev3 is paired and root-readable, so a correct walk stops at
# dev3's OWN manager (qa). Reading the filer as main would jump the chart to
# olivia — the defect, and the discriminator.
FILER_SELF=""; READABLE="qa olivia main"; PAIRED="qa olivia main"
SENT=""; SENT_AGENT=""; TASK_NOTIFY_ESCALATED_FROM=""
run_esc DIVE-9101; rc=$?
[[ "$rc" == "0" ]] && ok_t "gate-escalate re-sends the alert (rc 0)" || bad_t "gate-escalate rc" "rc=$rc out=${esc:0:200}"
[[ "$SENT_AGENT" == "qa" ]] \
  && ok_t "the chain starts at the FILER's manager (qa), not the creator's (olivia)" \
  || bad_t "escalation branch" "alert went to '$SENT_AGENT' — 'olivia' is the created_by walk this ticket fixes"
[[ "$TASK_NOTIFY_ESCALATED_FROM" == "dev3" ]] \
  && ok_t "the escalation records dev3 as the unpaired filer" \
  || bad_t "escalated-from" "got '$TASK_NOTIFY_ESCALATED_FROM'"
[[ "$SENT" == *"filed by dev3"* && "$SENT" != *"filed by main"* ]] \
  && ok_t "the alert attributes the ask to dev3, not to the task's creator" \
  || bad_t "alert attribution" "sent: ${SENT:0:200}"
[[ "$esc" == *"dev3"* && "$esc" != *"filer main"* ]] \
  && ok_t "the ok line names the filer of record" || bad_t "ok line filer" "${esc:0:200}"

# ---- 3. legacy gate (no stamp) still falls back to created_by ----------------
# Also the NON-VACUITY control for assertion 2: this row differs from DIVE-9101
# only in gate_filed_by, and it must escalate to the OTHER branch. If the SELECT
# ignored the new column both rows would land on the same agent and every
# assertion above would be passing for free.
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at)
    VALUES ('DIVE-9102','legacy gate','high','main','main','standard','blocked','decision',2,'pick one',datetime('now'));"
SENT=""; SENT_AGENT=""; TASK_NOTIFY_ESCALATED_FROM=""
run_esc DIVE-9102; rc=$?
[[ "$rc" == "0" ]] && ok_t "legacy gate still escalates (rc 0)" || bad_t "legacy rc" "rc=$rc out=${esc:0:200}"
[[ "$SENT_AGENT" == "main" ]] \
  && ok_t "a gate with NO stamp falls back to created_by (main's own channel)" \
  || bad_t "legacy fallback" "alert went to '$SENT_AGENT', want 'main'"

# Same shape, one hop up: created_by main with main unpaired must climb main's
# branch to olivia — so the fallback really is walking the CREATOR's chart, and
# assertion 2's 'qa' cannot be an artifact of the fixture ordering.
db "UPDATE tasks SET gate_pinged_at=NULL WHERE ident='DIVE-9102';"
READABLE="qa olivia"; PAIRED="qa olivia"
SENT=""; SENT_AGENT=""; TASK_NOTIFY_ESCALATED_FROM=""
run_esc DIVE-9102; rc=$?
[[ "$SENT_AGENT" == "olivia" && "$TASK_NOTIFY_ESCALATED_FROM" == "main" ]] \
  && ok_t "unstamped + unpaired creator climbs the CREATOR's branch (olivia)" \
  || bad_t "legacy climb" "agent='$SENT_AGENT' from='$TASK_NOTIFY_ESCALATED_FROM' rc=$rc"

# ---- 4. withdraw clears the stamp with the rest of the provenance ------------
FILER_SELF=""; READABLE="qa olivia main"; PAIRED="qa olivia main"
out=$( (cmd_task_need DIVE-9101 --withdraw --from=dev3) 2>&1 ); rc=$?
left=$(db "SELECT COALESCE(gate_filed_by,'NULL')||'|'||COALESCE(need_type,'NULL') FROM tasks WHERE ident='DIVE-9101';")
[[ "$left" == "NULL|NULL" ]] \
  && ok_t "task need --withdraw clears gate_filed_by with the gate" \
  || bad_t "withdraw clears the stamp" "got '$left' rc=$rc out=${out:0:160}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
