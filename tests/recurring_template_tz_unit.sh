#!/usr/bin/env bash
# TIER: core
# DIVE-5913 — a recurring template fires in ITS OWN time zone.
#
# DIVE-5909 moved a box's clock to its owner's zone, but the materializer still
# matched every template's cron against `date -u`. On a box set to Asia/Bangkok
# an agent that read `date` (08:00) and filed "0 8 * * *" for "every morning at
# 8" got 15:00 Bangkok, while the box's own crontab said 08:00. Templates now
# carry schedule_tz: NULL (every template filed before this row) stays UTC, a new
# one takes the box's zone. DST follows system (Debian/Vixie) cron: a fixed-time
# slot skipped by a forward jump fires ONCE at the first minute after it; a
# repeated wall-clock minute after a backward jump does not fire it again.
#
# Every arm runs on a FAKED clock: the materializer is handed `now`, and the
# box's zone comes from FIVE_BOX_TZ.
# Run: bash tests/recurring_template_tz_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/recurring-tz-unit.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
cmd_send() { return 0; }; audit_log() { return 0; }
_task_store_audit_log() { return 0; }
LOG="$TMP/log"; : >"$LOG"
_hb_log() { printf '%s\n' "$*" >>"$LOG"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] lacks [$3]"; fi; }

ep() { date -u -d "$1" +%s; }

# A template row, as written either before this row (tz NULL) or after it.
mk_tmpl() {  # mk_tmpl <title> <cron> [tz] -> row id
  local tz_sql="NULL"; [[ -n "${3:-}" ]] && tz_sql=$(sqlq "$3")
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, schedule, schedule_tz, status)
      VALUES ($(sqlq "$1"), '', 'medium', 'main', 'main', 'recurring', $(sqlq "$2"), ${tz_sql}, 'todo');
      SELECT last_insert_rowid();"
}
instances_of() { db "SELECT COUNT(*) FROM tasks WHERE from_template_id=${1};"; }
# One materializer pass at a faked minute, as its own tick. last_fired_at is
# stamped with the REAL clock, which is later than every faked minute, so it is
# cleared after each pass, and open instances are closed so the skip-if-open
# dedup cannot hide a second fire. What is left is the cron decision alone.
pass_at() {  # pass_at <utc 'YYYY-MM-DD HH:MM'>
  _hb_materialize_recurring "$(ep "$1")"
  db "UPDATE tasks SET last_fired_at=NULL WHERE kind='recurring';
      UPDATE tasks SET status='done' WHERE from_template_id IS NOT NULL;"
}
fresh_clock() { rm -f "$(_hb_mz_last_pass_file)"; }

# ── A. the matcher, in a zone ────────────────────────────────────────────────
_cron_matches "0 8 * * *" "$(ep '2026-10-09 01:00')" Asia/Bangkok; eq_t "A1: '0 8 * * *' Asia/Bangkok matches 01:00Z (08:00 local)" "$?" 0
_cron_matches "0 8 * * *" "$(ep '2026-10-09 08:00')" Asia/Bangkok; eq_t "A2: ... and not 08:00Z (15:00 local)" "$?" 1
_cron_matches "0 8 * * *" "$(ep '2026-10-09 08:00')" "";           eq_t "A3: no zone is UTC: '0 8 * * *' matches 08:00Z" "$?" 0
_cron_matches "0 8 * * *" "$(ep '2026-10-09 02:30')" Asia/Kolkata; eq_t "A4: half-hour zone: '0 8 * * *' Asia/Kolkata matches 02:30Z" "$?" 0
_cron_matches "0 8 * * *" "$(ep '2026-10-09 02:00')" Asia/Kolkata; eq_t "A5: ... and not 02:00Z (07:30 local)" "$?" 1
_cron_matches "0 8 * * *" "$(ep '2026-10-09 03:00')" Asia/Kolkata; eq_t "A6: ... and not 03:00Z (08:30 local)" "$?" 1

# ── B. accept 1: a Bangkok template fires at 08:00 Bangkok (01:00Z) ───────────
fresh_clock
t_bkk=$(mk_tmpl "every morning at 8, Bangkok" "0 8 * * *" Asia/Bangkok)
pass_at '2026-10-09 00:59'; eq_t "B1: nothing at 00:59Z (07:59 Bangkok)" "$(instances_of "$t_bkk")" 0
pass_at '2026-10-09 01:00'; eq_t "B2: fires at 01:00Z = 08:00 Asia/Bangkok" "$(instances_of "$t_bkk")" 1
fresh_clock
pass_at '2026-10-09 08:00'; eq_t "B3: does NOT fire at 08:00Z (15:00 Bangkok)" "$(instances_of "$t_bkk")" 1
db "UPDATE tasks SET status='cancelled' WHERE id=${t_bkk};"

# ── C. accept 2, NEGATIVE CONTROL: a template from before the upgrade stays UTC
# This is the arm that goes red if the default ever becomes the box's zone.
fresh_clock
t_old=$(mk_tmpl "pre-upgrade template, tz NULL" "0 8 * * *")
FIVE_BOX_TZ=Asia/Bangkok pass_at '2026-10-09 01:00'
eq_t "C1: a tz-NULL template does not fire at 01:00Z on a Bangkok box" "$(instances_of "$t_old")" 0
fresh_clock
FIVE_BOX_TZ=Asia/Bangkok pass_at '2026-10-09 08:00'
eq_t "C2: it still fires at 08:00Z, exactly as before the upgrade" "$(instances_of "$t_old")" 1
db "UPDATE tasks SET status='cancelled' WHERE id=${t_old};"

# ── D. accept 3: a half-hour zone (Asia/Kolkata, +05:30) ─────────────────────
fresh_clock
t_ist=$(mk_tmpl "Kolkata 08:00" "0 8 * * *" Asia/Kolkata)
pass_at '2026-10-09 02:29'; eq_t "D1: nothing at 02:29Z (07:59 IST)" "$(instances_of "$t_ist")" 0
pass_at '2026-10-09 02:30'; eq_t "D2: fires at 02:30Z = 08:00 IST" "$(instances_of "$t_ist")" 1
pass_at '2026-10-09 02:31'; eq_t "D3: once" "$(instances_of "$t_ist")" 1
db "UPDATE tasks SET status='cancelled' WHERE id=${t_ist};"

# ── E. accept 4: DST, Europe/Berlin ──────────────────────────────────────────
# Spring forward 2026-03-29: 02:00 CET -> 03:00 CEST at 01:00Z, so 02:30 local
# never happens. System cron (Debian/Vixie) runs a FIXED-time job whose time was
# skipped once, right after the jump; so does this. Each probe minute is its own
# pass with no catch-up window: 00:30Z and 01:30Z are where a matcher that read
# 02:30 in the wrong offset would fire, 00:59Z/01:01Z bracket the jump.
t_ber=$(mk_tmpl "Berlin 02:30" "30 2 * * *" Europe/Berlin)
t_berw=$(mk_tmpl "Berlin every 30 min in hour 2 (wildcard)" "*/30 2 * * *" Europe/Berlin)
fired_at=""
for hm in 00:29 00:30 00:31 00:59 01:00 01:01 01:29 01:30 01:31 02:30; do
  before=$(instances_of "$t_ber")
  fresh_clock; pass_at "2026-03-29 $hm"
  [[ "$(instances_of "$t_ber")" != "$before" ]] && fired_at+="${hm}Z "
done
eq_t "E1: spring forward: '30 2 * * *' Berlin fires ONCE around the jump" "$(instances_of "$t_ber")" 1
eq_t "E2: ... at 01:00Z, the first minute after the jump (03:00 CEST)" "$fired_at" "01:00Z "
eq_t "E3: a wildcard-minute job in the skipped hour is skipped, as cron does" "$(instances_of "$t_berw")" 0
# Fall back 2026-10-25: 03:00 CEST -> 02:00 CET at 01:00Z, so 02:30 local
# happens at 00:30Z AND at 01:30Z. A fixed-time job runs once; a wildcard one
# runs in both hours, as cron does.
t_berb=$(mk_tmpl "Berlin 02:30 (fall back)" "30 2 * * *" Europe/Berlin)
t_berbw=$(mk_tmpl "Berlin every 30 min (wildcard)" "*/30 * * * *" Europe/Berlin)
for hm in 00:00 00:30 01:00 01:30 02:00; do
  fresh_clock; pass_at "2026-10-25 $hm"
done
eq_t "E4: fall back: '30 2 * * *' Berlin fires once, not twice" "$(instances_of "$t_berb")" 1
eq_t "E5: a wildcard job keeps running through the repeated hour (00:00..02:00Z = 5 slots)" "$(instances_of "$t_berbw")" 5
db "UPDATE tasks SET status='cancelled' WHERE id IN (${t_ber},${t_berw},${t_berb},${t_berbw});"

# ── F. catch-up window in a zone: a missed minute is still found ─────────────
fresh_clock
t_cu=$(mk_tmpl "Bangkok 08:00, catch-up" "0 8 * * *" Asia/Bangkok)
pass_at '2026-10-09 00:58'
pass_at '2026-10-09 01:03'   # no pass ran 00:59..01:02
eq_t "F1: a slot in a minute no pass ran is caught up in the template's zone" "$(instances_of "$t_cu")" 1
db "UPDATE tasks SET status='cancelled' WHERE id=${t_cu};"

# ── G. a zone the box cannot read fires nothing and says so ───────────────────
fresh_clock
t_bad=$(mk_tmpl "bad zone" "* * * * *" "Mars/Olympus_Mons")
: >"$LOG"
pass_at '2026-10-09 01:00'
eq_t "G1: an unknown zone is not silently read as UTC" "$(instances_of "$t_bad")" 0
has_t "G2: ... and the pass logs it" "$(cat "$LOG")" "is not a zone this box knows"
db "UPDATE tasks SET status='cancelled' WHERE id=${t_bad};"

# ── H. task add: a new template takes the box's zone ──────────────────────────
OUT=$( (FIVE_BOX_TZ=Asia/Bangkok cmd_task_add "morning digest" --recurring="0 8 * * *" --assignee=main --from=main) 2>&1 ); RC=$?
eq_t "H1: task add --recurring succeeds (rc 0)" "$RC" 0
has_t "H2: the created line names the zone" "$OUT" "0 8 * * * Asia/Bangkok"
eq_t "H3: the box's zone is stamped on the row" "$(db "SELECT schedule_tz FROM tasks WHERE title='morning digest';")" "Asia/Bangkok"
OUT=$( (FIVE_BOX_TZ=Asia/Bangkok cmd_task_add "berlin digest" --recurring="0 8 * * *" --tz=Europe/Berlin --assignee=main --from=main) 2>&1 )
eq_t "H4: --tz overrides the box's zone" "$(db "SELECT schedule_tz FROM tasks WHERE title='berlin digest';")" "Europe/Berlin"
OUT=$( (cmd_task_add "typo zone" --recurring="0 8 * * *" --tz=Asia/Bangkk --assignee=main --from=main) 2>&1 ); RC=$?
[[ "$RC" != 0 ]] && ok_t "H5: an unknown --tz is refused" || bad_t "H5: an unknown --tz is refused" "rc=$RC out=$OUT"
OUT=$( (cmd_task_add "one-off with tz" --tz=Asia/Bangkok --assignee=main --from=main) 2>&1 ); RC=$?
[[ "$RC" != 0 ]] && ok_t "H6: --tz without --recurring is refused" || bad_t "H6: --tz without --recurring is refused" "rc=$RC"
OUT=$( (FIVE_BOX_TZ=Asia/Bangkok cmd_task_add "plain row" --assignee=main --from=main) 2>&1 )
eq_t "H7: a standard row carries no zone" "$(db "SELECT COALESCE(schedule_tz,'NULL') FROM tasks WHERE title='plain row';")" "NULL"

# ── I. the zone is printed next to the schedule ──────────────────────────────
LS=$( (cmd_task_ls --recurring --all) 2>&1 )
has_t "I1: task ls --recurring prints the zone" "$LS" "0 8 * * * (Asia/Bangkok)"
has_t "I2: ... and a pre-upgrade template reads UTC" "$LS" "0 8 * * * (UTC)"
ident_bkk=$(db "SELECT ident FROM tasks WHERE title='morning digest';")
SHOW=$( (cmd_task_show "$ident_bkk") 2>&1 )
has_t "I3: task show prints schedule with its zone" "$SHOW" "schedule = 0 8 * * * (Asia/Bangkok)"
HELP=$(_task_help 2>/dev/null || cmd_task help 2>&1)
has_t "I4: task add --help says a schedule runs in the box's time zone" "$HELP" "a schedule runs in the BOX'S time zone"

# ── J. set-tz moves an existing template ─────────────────────────────────────
ident_old=$(db "SELECT ident FROM tasks WHERE id=${t_old};")
OUT=$( (cmd_task_set_tz "$ident_old" Asia/Bangkok) 2>&1 ); RC=$?
eq_t "J1: set-tz on a template succeeds" "$RC" 0
eq_t "J2: the zone is stored" "$(db "SELECT schedule_tz FROM tasks WHERE id=${t_old};")" "Asia/Bangkok"
OUT=$( (FIVE_BOX_TZ=Europe/Berlin cmd_task_set_tz "$ident_old" box) 2>&1 )
eq_t "J3: 'box' means the box's zone" "$(db "SELECT schedule_tz FROM tasks WHERE id=${t_old};")" "Europe/Berlin"
OUT=$( (cmd_task_set_tz "$ident_old" Nowhere/Land) 2>&1 ); RC=$?
[[ "$RC" != 0 ]] && ok_t "J4: an unknown zone is refused" || bad_t "J4: an unknown zone is refused" "rc=$RC"
ident_std=$(db "SELECT ident FROM tasks WHERE title='plain row';")
OUT=$( (cmd_task_set_tz "$ident_std" UTC) 2>&1 ); RC=$?
[[ "$RC" != 0 ]] && ok_t "J5: a standard row is refused" || bad_t "J5: a standard row is refused" "rc=$RC"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
