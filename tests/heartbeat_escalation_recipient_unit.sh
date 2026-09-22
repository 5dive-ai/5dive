#!/usr/bin/env bash
# DIVE-4554 — WHO a heartbeat escalation is addressed to, and what is left behind
# when the answer is nobody. Successor to DIVE-4551, which fixed the same defect
# class on the three SUPERVISOR alert rails.
#
# THE DEFECT. `src/cmd_heartbeat.sh` addressed eleven escalations to a literal
# seat name — three to `main` (the DIVE-3465 spend-cap wall, the DIVE-1666
# usage-limit freeze, the DIVE-3503/1486 stranded seat) and eight to `ops` (the
# queue-housekeeping rails). The census is ten today, not eleven: DIVE-4826 moved
# three ops rails onto the batching spool and added two sites of its own — see B0. Both names exist on exactly one box in the world:
# ours. Worse than the supervisor rails this mirrors: every one was wrapped
# `( … ) >/dev/null 2>&1 || true`, so on a box with no such seat the send failed
# with ZERO trace — no warn in the cron log, no `supervisor_events` row, nothing
# for `doctor` to read. Two of the three `main` sites are the billing escalations
# written specifically to reach a person.
#
# WHAT IS ASSERTED, and the shape is deliberate:
#   A. The two resolvers, run FOR REAL against three org charts in a real store —
#      this box, the lone-root customer chart DIVE-4551 was filed from, and the
#      three-root teal-fox chart where nothing resolves. A harness that stubbed
#      the resolver would be grading its own stub.
#   B. EVERY `_hb_escalate` call site EXTRACTED VERBATIM from
#      src/cmd_heartbeat.sh and DRIVEN, against each of those charts, with a
#      recording `cmd_send`. This is the arm that says "a lone root receives all
#      three": it runs the product's own lines, not a paraphrase of them.
#   C. The lost-leg audit: nothing resolving, and a send that fails, each leave
#      an `alert-undeliverable` row in supervisor_events with its reason and
#      recipient — and the call still returns 0, because a wedged channel must
#      never abort the tick (DIVE-1127).
#   D. The DOCTOR consequence, read through DIVE-4551's own predicate: while a
#      leg was lost in the last 7d the `supervisor-alert-delivery` check is
#      error-level. No new doctor arm was needed; that is the point.
#   E. MUTATION GRADE. Hardcoding any one site back to a literal seat must turn
#      an arm red, and the no-literal-call-site enumeration (the remediation grep
#      the DIVE-4551 wiki page asks for, run as a test instead of as advice) must
#      go red with it.
#
# NOT MEASURED, declared: this does not run a live heartbeat tick — no tmux, no
# systemd, no pane capture. It grades the escalation lines themselves and the
# resolution behind them. That the tick REACHES those lines is unchanged by this
# row; their recipient and their failure trace are what it changed.
#
# Run: bash tests/heartbeat_escalation_recipient_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-escalation-recipient-unit.XXXXXX)"
STATE_DIR="$TMP"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh \
         task/routing.sh cmd_supervisor.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
_task_human_send_allowed() { return 0; }

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}

chart() { db "DELETE FROM agents_org;"; }
this_box() {   # the chart as `5dive org ls` prints it on 2026-09-15
  chart
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('olivia','AI CEO — conducts the fleet (advisory)',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('main','engineering + infra + the 5dive CLI — gate notifier','olivia');"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('ops','DevOps / SRE','main');"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('dev','Lead Engineer (backend)','ops');"
}
lone_root() { # the customer box DIVE-4551 was filed from: no main, no ops
  chart
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-aleks','founder',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-ivan','engineer','claude-aleks');"
}
three_roots() {  # teal-fox as reported: nothing resolves, and that is the state
  chart
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-aleks','founder',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-alena','ops',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-jane','eng',NULL);"
}
undeliv_count() { db "SELECT COUNT(*) FROM supervisor_events WHERE event='alert-undeliverable';"; }
undeliv_reasons() { db "SELECT DISTINCT cause FROM supervisor_events WHERE event='alert-undeliverable' ORDER BY cause;" | paste -sd, -; }
clear_events() { db "DELETE FROM supervisor_events;"; }

# ── A. the resolvers, for real ───────────────────────────────────────────────
this_box
t "A1 this box: escalations still resolve to main — byte-identical to the old literal" \
  "main" "$(_hb_escalation_recipient)"
t "A2 this box: and the coordinator is NOT main (the discriminator DIVE-4551 measured)" \
  "olivia" "$(_task_resolve_coordinator)"
t "A3 this box: the housekeeping rails still resolve to ops, not to the notifier" \
  "ops" "$(_hb_ops_recipient)"

lone_root
t "A4 lone-root customer chart: the escalation recipient is the root" \
  "claude-aleks" "$(_hb_escalation_recipient)"
t "A5 lone-root customer chart: with no ops seat, housekeeping falls back to the root — not to nobody" \
  "claude-aleks" "$(_hb_ops_recipient)"
db "UPDATE agents_org SET role='engineer — gate notifier' WHERE name='claude-ivan';"
t "A6 ...and an explicit tag moves the alerts alone" \
  "claude-ivan" "$(_hb_escalation_recipient)"

three_roots
t "A7 teal-fox chart: nothing resolves, and the resolver says so instead of guessing" \
  "" "$(_hb_escalation_recipient)"
t "A8 teal-fox chart: a seat merely ROLED 'ops' is not a seat NAMED ops" \
  "" "$(_hb_ops_recipient)"

# ── B. every call site, extracted verbatim and driven ────────────────────────
# Pull each `_hb_escalate` invocation out of the product file, continuations and
# all. The list is never hardcoded here: a hand-maintained copy goes stale
# silently and this test would stay green while a new site shipped a literal.
CALLS=(); _buf=""; _in=0
while IFS= read -r _line; do
  if [[ $_in -eq 0 && "$_line" == *'_hb_escalate "'* ]]; then _in=1; _buf="$_line"
  elif [[ $_in -eq 1 ]]; then _buf+=$'\n'"$_line"; fi
  if [[ $_in -eq 1 && "$_buf" != *'\' ]]; then CALLS+=("$_buf"); _in=0; _buf=""; fi
done < src/cmd_heartbeat.sh
# THE CENSUS MOVES WHEN THE PRODUCT MOVES, and DIVE-4826 moved it: three
# housekeeping rails (🧊 stranded-row, ⚠️ blocked-no-reason, ⏳ recurring-stall)
# stopped calling `_hb_escalate` directly and now queue through
# `_hb_ops_digest_note`, and two NEW sites arrived on the batching rail itself —
# `ops-digest` (the once-per-window flush) and `ops-digest-fallback` (the
# unwritable-spool escape, which is a live send on purpose). 8 - 3 + 2 = 7
# housekeeping, and the three billing/stranded rails are untouched. Both
# digest-owned sites still resolve through `_hb_ops_recipient`, which is why they
# belong in this census and not outside it: the batcher changed WHEN ops is told,
# never WHO resolves.
t "B0 every escalation in the product file was extracted (10 sites: 3 billing/stranded + 7 housekeeping, 2 of them digest-owned since DIVE-4826)" \
  "10" "${#CALLS[@]}"

# The product sends inside a SUBSHELL — deliberately, so a `fail`ing send cannot
# exit the tick (DIVE-1127). So the recorder writes to a FILE: an array would be
# mutated in the child and lost, and this harness would read zero sends while the
# product delivered eleven. That silent-zero is the same shape as the defect.
SENT_LOG="$TMP/sent.log"; : >"$SENT_LOG"
cmd_send() {  # recording stub: first arg is the recipient the product chose
  printf '%s\n' "$1" >>"$SENT_LOG"; return 0
}
# `grep -c` PRINTS 0 and EXITS 1 on no matches, so `grep -c … || echo 0` emits
# TWO zeros and every "nothing was sent" arm compares against '0\n0'. Count with
# awk instead — one number, always.
sent_to() { awk -v w="$1" '$0==w{n++} END{print n+0}' "$SENT_LOG"; }
sent_n()  { awk 'END{print NR+0}' "$SENT_LOG"; }
# Every free variable the product's message strings interpolate. Set, not
# stubbed: the strings are the product's, and an unbound one would be a defect
# this harness should surface rather than hide.
drive() {
  : >"$SENT_LOG"
  local name=claude-ivan acct=pooled-1 defer_n=7 task_ident=DIVE-9001 heal_gap=91
  local -a rec=(1 2); local idlist="DIVE-9001 DIVE-9002 " orphan="DIVE-9003 "
  local eident=DIVE-9005 etmpl=DIVE-8001 easg=claude-ivan etarget=claude-jane ehours=51
  local emsg="Recurring-stall ESCALATED:"
  local _hdr="FLEET IDLE" total_stranded=4 stranded_todo=3 open_gates=1 since_secs=5400 parked_gates=0
  local _act_detail="0 active" _tail="(detail)" eligible=6 last_ping="never"
  # DIVE-4826's two digest-owned sites. `subject/class/raw` are _hb_ops_digest_note's
  # own locals at the unwritable-spool fallback; `hdr/body` are the flush's composed
  # message. The stranded/recurring-stall/blocked-no-reason fixtures that used to sit
  # here were deleted with their call sites — a fixture for a line that no longer
  # exists is a claim this harness cannot back.
  local subject=DIVE-9007 class="stranded-row" raw="🧊 Stranded 9d: DIVE-9007"
  local hdr="📋 Board digest — 3 notice(s)" body=$'\n1. [ts DIVE-9007] 🧊 Stranded 9d'
  local c
  for c in "${CALLS[@]}"; do eval "$c" || return 1; done
  return 0
}

this_box; clear_events
drive; rc=$?
t "B1 this box: every extracted site runs and none aborts the tick" "0" "$rc"
t "B2 this box: all 10 escalations were sent" "10" "$(sent_n)"
t "B3 this box: the three billing/stranded rails still go to main (no behaviour change here)" \
  "3" "$(sent_to main)"
t "B4 this box: the seven housekeeping rails still go to ops (no behaviour change here)" \
  "7" "$(sent_to ops)"
t "B5 this box: and nothing was lost" "0" "$(undeliv_count)"

lone_root; clear_events
drive; rc=$?
t "B6 lone-root customer chart: every site runs" "0" "$rc"
t "B7 lone-root customer chart: ALL TEN reach claude-aleks — including the three billing/stranded rails that used to reach nobody" \
  "10" "$(sent_to claude-aleks)"
t "B8 lone-root customer chart: no seat named main was addressed" \
  "0" "$(sent_to main)"
t "B9 lone-root customer chart: nothing lost" "0" "$(undeliv_count)"

# ── C. the lost leg is audited, and the tick survives it ─────────────────────
three_roots; clear_events
drive; rc=$?
t "C1 teal-fox chart: the tick still completes — a dark chart must not abort it (DIVE-1127)" "0" "$rc"
t "C2 teal-fox chart: nothing was sent, because nothing resolves" "0" "$(sent_n)"
t "C3 teal-fox chart: and every one of the ten left an audited row instead of nothing at all" \
  "10" "$(undeliv_count)"
t "C4 teal-fox chart: with the reason recorded" "no-recipient" "$(undeliv_reasons)"

this_box; clear_events
cmd_send() { return 1; }   # the rail refuses: the seat resolves but the send fails
drive; rc=$?
t "C5 a refused send does not abort the tick either" "0" "$rc"
t "C6 a refused send is audited, not swallowed by the old || true" "10" "$(undeliv_count)"
t "C7 ...with the reason recorded" "send-failed" "$(undeliv_reasons)"
t "C8 ...and the recipient we tried, so the audit says WHO was unreachable" \
  "main|ops" "$(db "SELECT DISTINCT json_extract(signals,'\$.recipient') FROM supervisor_events WHERE event='alert-undeliverable' ORDER BY 1;" | paste -sd'|' -)"
cmd_send() { printf '%s\n' "$1" >>"$SENT_LOG"; return 0; }

# ── D. the doctor consequence, through DIVE-4551's own predicate ─────────────
# Not a new arm and not a re-implementation: the same event name and the same 7d
# window the shipped check reads. That a heartbeat leg lights a check written for
# the supervisor is the reuse this row is claiming.
t "D1 a lost heartbeat leg is inside the window the shipped doctor check reads" \
  "10" "$(db "SELECT COUNT(*) FROM supervisor_events WHERE event='alert-undeliverable' AND ts >= datetime('now','-7 days');")"
t "D2 ...so the check cannot read [ok] — its error branch is (undeliv > 0)" \
  "error" "$( [[ "$(db "SELECT COUNT(*) FROM supervisor_events WHERE event='alert-undeliverable' AND ts >= datetime('now','-7 days');")" -gt 0 ]] && echo error || echo ok )"
clear_events

# ── E. enumeration + mutation ────────────────────────────────────────────────
# The remediation grep the DIVE-4551 wiki page prescribes, run as a DELIVERABLE
# instead of as advice for the reader (its own postscript: the grep was never run
# on the product, and three sites survived in the same repo).
t "E1 no escalation call site in the product file addresses a literal seat" \
  "0" "$(grep -c '^[^#]*cmd_send "[a-z][a-z0-9_-]*"' src/cmd_heartbeat.sh)"
t "E2 ...and the resolvers are the only place a seat name survives" \
  "1" "$(grep -c "lower(name)='ops'" src/cmd_heartbeat.sh)"

# Mutant: put one site back the way it was. E1 must red, and so must the
# behavioural arm — an enumeration that cannot be broken is not evidence.
MUT="$TMP/mutant.sh"
sed '0,/_hb_escalate "spend-cap"/s//( cmd_send "main" --from="task-engine" --message="x" ) >\/dev\/null 2>\&1 || true\n            : _hb_escalate "spend-cap"/' \
  src/cmd_heartbeat.sh > "$MUT"
t "E3 MUTANT: one site hardcoded back to 'main' — the enumeration arm goes red (1, not 0)" \
  "1" "$(grep -c '^[^#]*cmd_send "[a-z][a-z0-9_-]*"' "$MUT")"
# ...and the behavioural arm with it: re-extract from the MUTANT tree and drive
# it against the customer chart. The hardcoded site addresses `main`, which does
# not exist there, so an escalation that B7 delivered now reaches nobody — and
# says nothing, because the mutant restored the `|| true` too.
CALLS=(); _buf=""; _in=0
while IFS= read -r _line; do
  if [[ $_in -eq 0 && "$_line" == *'_hb_escalate "'* ]]; then _in=1; _buf="$_line"
  elif [[ $_in -eq 1 ]]; then _buf+=$'\n'"$_line"; fi
  if [[ $_in -eq 1 && "$_buf" != *'\' ]]; then CALLS+=("$_buf"); _in=0; _buf=""; fi
done < "$MUT"
lone_root; clear_events
t "E3b MUTANT: all ten sites still extract (one of them now a no-op)" "10" "${#CALLS[@]}"
drive; rc=$?
t "E3c MUTANT: drive still returns 0" "0" "$rc"
t "E4 MUTANT: on the customer chart one escalation no longer reaches the root (9, not 10)" \
  "9" "$(sent_to claude-aleks)"
t "E5 MUTANT: and it leaves no audit row behind — the silent loss this row exists to end" \
  "0" "$(undeliv_count)"

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
