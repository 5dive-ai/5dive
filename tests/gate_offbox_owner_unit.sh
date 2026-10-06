#!/usr/bin/env bash
# DIVE-5648 — AN OFF-BOX GATE OWNER HOLDS THE PHONE PING.
#
# A team box whose org root is managed from another box (chill-gorge's `head`,
# managed by `marketing` on poke-two) cannot route a gate to that manager — a
# reviewer must be a seat on this box — so every gate the root files rang the
# founder's phone. `5dive task routing offbox <seat>` holds approval/decision
# gates below tier 2 off the phone; the seat reads `task ls --gated` and answers
# through its restricted SSH command, which runs `sudo 5dive task answer` from a
# non-agent login session.
#
# Graded here, all through the real cmd_task_need / cmd_task_answer:
#   1. setting ON, the org root files an approval: the human notifier is called
#      ZERO times, the gate stays open and lists under task ls --gated;
#   2. an answer through the restricted command path closes it and wakes the filer;
#   3. NEGATIVE: the same gate with the setting OFF calls the notifier once;
#   4. a secret gate with the setting ON still calls the notifier once;
#   5. a tier-2 approval with the setting ON still calls it once (an agent answer
#      is refused on tier 2, so holding it would leave it answerable by nobody);
#   6. the heartbeat re-nag selects a held gate only while the setting is OFF.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-offbox-owner.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh cmd_agent_runtime.sh cmd_task.sh \
         cmd_heartbeat.sh; do
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh" \
  || printf 'actor seam: UNRESOLVED (tests/lib/actor_seam.sh not reachable)\n' >&2
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
export FIVEDIVE_NO_HUMAN_SEND=1
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"; : >"$FIVEDIVE_GATE_NOTIFY_LOG"
export _5DIVE_GATE_UNDO_WINDOW_SECS=0   # deliver synchronously, so a count is final when the call returns
# Proof enforcement ON: an answer must carry real evidence, not slip through an
# unenforced box.
touch "$STATE_DIR/gate-proof.enforce"

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# THE HUMAN NOTIFIER, stubbed. A file, not a variable: cmd_task_need runs in the
# gate seam's subshell, so a variable would never come back.
CALLS="$TMP/notifier"; : >"$CALLS"
_task_need_notify_deliver_now() { printf '%s\n' "$1" >>"$CALLS"; TASK_SEND_DELIVERED=1; return 0; }
calls() { grep -cx "$1" "$CALLS" 2>/dev/null || true; }
# The filer wake, stubbed the same way.
WAKES="$TMP/wakes"; : >"$WAKES"
cmd_send() { printf '%s\n' "$1" >>"$WAKES"; return 0; }

# The org: head is the ROOT (no manager), scout reports to head.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('head',NULL,'team lead');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('scout','head','scout');"

mkrow() { # <ident> [assignee]
  db "INSERT INTO tasks (ident,title,status,priority,assignee,created_by)
      VALUES ($(sqlq "$1"),'offbox fixture','in_progress','high',$(sqlq "${2:-head}"),'head');"
}
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

# Every filing below is BY head, the org root: routing decides on the DERIVED
# caller, never on --from, so the seam makes the process head.
actor_seam_as head
actor_seam_selftest head \
  && ok_t "seam: the filing process acts as head" || fail_t "seam: the actor did not move to head"

# ── 1. SETTING ON: the root's approval is held off the phone ────────────────
out=$(cmd_task_routing offbox marketing 2>&1)
[[ "$(_gate_offbox_owner)" == "marketing" ]] \
  && ok_t "task routing offbox marketing sets the box's off-box gate owner" \
  || fail_t "pref not set: $out"
mkrow DIVE-9501
out=$(cmd_task_need DIVE-9501 --type=approval --ask="Run the launch post on the forum today?" --from=head 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok_t "1: the gate files clean (rc 0)" || fail_t "1: filing rc=$rc: $out"
[[ "$(col DIVE-9501 tier)" == "1" && "$(col DIVE-9501 routed_reviewer)" == "" ]] \
  && ok_t "1 precondition: a tier-1 approval from the org root with no routed reviewer (the human path)" \
  || fail_t "1 drifted: tier=$(col DIVE-9501 tier) routed=$(col DIVE-9501 routed_reviewer)"
[[ "$(calls DIVE-9501)" == "0" ]] \
  && ok_t "1: the human notifier was called ZERO times" \
  || fail_t "1: notifier called $(calls DIVE-9501) time(s) with the setting on"
[[ -n "$(col DIVE-9501 need_type)" && -z "$(col DIVE-9501 need_answered_at)" ]] \
  && ok_t "1: the gate stays open" || fail_t "1: the gate is not open"
ls_out=$(JSON_MODE=1 cmd_task_ls --gated 2>&1)
jq -e '.data.tasks[] | select(.ident=="DIVE-9501")' <<<"$ls_out" >/dev/null 2>&1 \
  && ok_t "1: it lists under task ls --gated (where the off-box owner reads it)" \
  || fail_t "1: not in task ls --gated: ${ls_out:0:400}"
[[ "$(col DIVE-9501 route_provenance)" == "offbox:marketing" ]] \
  && ok_t "1: route_provenance says offbox:marketing (held, not pinged)" \
  || fail_t "1: route_provenance=$(col DIVE-9501 route_provenance)"
grep -q 'hold:offbox:marketing' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "1: the hold is recorded as a delivery row" \
  || fail_t "1: no hold row: $(tail -3 "$FIVEDIVE_GATE_NOTIFY_LOG")"
grep -q 'off-box gate owner' <<<"$out" && ! grep -q 'sits on the PAIRED HUMAN' <<<"$out" \
  && ok_t "1: the filer is told the ping is held for marketing, not that it sits on the human" \
  || fail_t "1: filer line: $out"

# ── 2. ANSWER THROUGH THE RESTRICTED COMMAND PATH ───────────────────────────
# marketing's SSH command runs `sudo 5dive task answer` as the box's non-agent
# login user, inside an SSH session scope. Seams: root EUID, a non-agent
# SUDO_UID (0 resolves to root, which is not agent-*), the session cgroup.
: >"$WAKES"
# In a command substitution, so the root seams die with it and the filing arms
# below still run as head.
out=$( _gate_is_root() { return 0; }
       _gate_caller_uid() { printf '0'; }
       _gate_caller_cgroup() { printf '/user.slice/user-1000.slice/session-7.scope'; }
       _gate_passwd_stream() { printf 'root:x:0:0:::\n'; }
       SUDO_UID=0 cmd_task_answer DIVE-9501 --value=approve --from=marketing 2>&1 ); rc=$?
[[ $rc -eq 0 && -n "$(col DIVE-9501 need_answered_at)" ]] \
  && ok_t "2: an answer through the restricted command path closes the held gate" \
  || fail_t "2: answer rc=$rc: $out"
grep -qx head "$WAKES" \
  && ok_t "2: the filer (head) is woken" || fail_t "2: no wake for head: $(cat "$WAKES")"

# ── 3. NEGATIVE CONTROL: the same gate with the setting OFF ─────────────────
cmd_task_routing offbox off >/dev/null 2>&1
[[ -z "$(_gate_offbox_owner)" ]] && ok_t "task routing offbox off clears the setting" || fail_t "setting still on"
mkrow DIVE-9502
cmd_task_need DIVE-9502 --type=approval --ask="Run the launch post on the forum today?" --from=head >/dev/null 2>&1
[[ "$(calls DIVE-9502)" == "1" ]] \
  && ok_t "3: with the setting OFF the notifier is called exactly once (today's behaviour)" \
  || fail_t "3: notifier called $(calls DIVE-9502) time(s), expected 1"
[[ "$(col DIVE-9502 route_provenance)" == human:* ]] \
  && ok_t "3: provenance stays human:* when nothing is held" || fail_t "3: provenance=$(col DIVE-9502 route_provenance)"

# ── 4. A SECRET GATE WITH THE SETTING ON still reaches the human ────────────
cmd_task_routing offbox marketing >/dev/null 2>&1
mkrow DIVE-9503
out=$(cmd_task_need DIVE-9503 --type=secret --secret-key=FORUM_TOKEN --connector=forum --ask="Paste the forum API token" --from=head 2>&1)
[[ -n "$(col DIVE-9503 need_type)" ]] || fail_t "4 precondition: the secret gate did not file: ${out:0:400}"
[[ "$(calls DIVE-9503)" == "1" ]] \
  && ok_t "4: a secret gate with the setting ON still calls the notifier once" \
  || fail_t "4: notifier called $(calls DIVE-9503) time(s), expected 1"

# ── 5. A TIER-2 APPROVAL WITH THE SETTING ON still reaches the human ────────
mkrow DIVE-9504
cmd_task_need DIVE-9504 --type=approval --tier=2 --ask="Run the launch post on the forum today?" --from=head >/dev/null 2>&1
[[ "$(col DIVE-9504 tier)" == "2" ]] || fail_t "5 precondition: tier=$(col DIVE-9504 tier)"
[[ "$(calls DIVE-9504)" == "1" ]] \
  && ok_t "5: a tier-2 approval is NOT held (an agent cannot answer tier 2, so holding it would strand it)" \
  || fail_t "5: notifier called $(calls DIVE-9504) time(s), expected 1"

# ── 6. THE RE-NAG reads the same predicate, live ────────────────────────────
mkrow DIVE-9505
cmd_task_need DIVE-9505 --type=decision --ask="Post in the morning or the evening?" --from=head >/dev/null 2>&1
[[ "$(calls DIVE-9505)" == "0" ]] && ok_t "6: a decision gate is held too" || fail_t "6: decision notifier calls=$(calls DIVE-9505)"
db "UPDATE tasks SET need_asked_at=datetime('now','-2 hours'), gate_pinged_at=NULL WHERE ident='DIVE-9505';"
n_on=$(db "SELECT COUNT(*) FROM tasks WHERE ident='DIVE-9505' AND ${_HB_GATE_RENAG_WHERE};")
cmd_task_routing offbox off >/dev/null 2>&1
n_off=$(db "SELECT COUNT(*) FROM tasks WHERE ident='DIVE-9505' AND ${_HB_GATE_RENAG_WHERE};")
[[ "$n_on" == "0" ]] && ok_t "6: the re-nag skips a held gate while the setting is on" || fail_t "6: re-nag selected the held gate (n=$n_on)"
[[ "$n_off" == "1" ]] && ok_t "6: turning the setting off re-arms it for the re-nag" || fail_t "6: re-nag did not pick it up when off (n=$n_off)"

# STRUCTURAL: the 72h stale reminder and its pinger canary live inside sweep
# functions with no seam; both must carry the same predicate as the re-nag, or a
# held gate is reminded to the human at 72h (and the canary reads the silence as
# a dead pinger). Three uses: re-nag WHERE, 72h reminder, canary.
n_use=$(grep -c 'AND NOT \${_GATE_OFFBOX_HELD_SQL:-0}' "$SRC/cmd_heartbeat.sh")
[[ "$n_use" == "3" ]] \
  && ok_t "structural: re-nag, 72h reminder and pinger canary all exclude held gates (3 uses)" \
  || fail_t "structural: expected 3 uses of the held predicate in cmd_heartbeat.sh, found $n_use"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
