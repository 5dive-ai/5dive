#!/usr/bin/env bash
# DIVE-8398: `5dive config gate-reminders=daily[@HH]` — every non-urgent owner
# reminder in ONE batch a day, at the first heartbeat tick at/after HH:00 UTC.
# Box bug report 950: 20 open questions on per-gate clocks = 15 reminders a day.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-rem-daily.XXXXXX)
HB_FILE="${HB_FILE:-$SRC/cmd_heartbeat.sh}"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/verify_policy.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_box_config.sh; do
  source "$SRC/$f"
done
source "$HB_FILE"
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
db "INSERT INTO agents_org (name,reports_to,role) VALUES ('main',NULL,'coordinator'),('dev','main',NULL);"

SEND_LOG="$TMP/sends"; : >"$SEND_LOG"     # one line per owner message: <tick>|<ids>
NOTICE_LOG="$TMP/notices"; : >"$NOTICE_LOG"
TICK="-"
_task_agent_channel() { TASK_CH_TYPE=claude TASK_CH_TOKEN=x TASK_CH_ACCESS=/dev/null; return 0; }
_task_send_owner() {
  local text="$1" markup="${2:-}" ids="${3:-}"
  TASK_SEND_MESSAGE_IDS="901"; TASK_SEND_DELIVERED=1
  if [[ -z "$ids" ]]; then printf '%s\n' "$text" >>"$NOTICE_LOG"; return 0; fi
  printf '%s|%s\n' "$TICK" "$ids" >>"$SEND_LOG"
  db "UPDATE tasks SET gate_pinged_at=datetime('now') WHERE id IN (${ids});"
}
audit_log() { :; }
_hb_log() { :; }
warn() { printf 'WARN: %s\n' "$*" >>"$TMP/warn"; }
require_root() { :; }
AGENT_SEND_LOG="$TMP/agent_sends"; : >"$AGENT_SEND_LOG"
cmd_send() { printf '%s|%s\n' "$TICK" "$1" >>"$AGENT_SEND_LOG"; return 0; }
_task_gate_delivery_log() { return 0; }

SIM=0
_hb_gate_rem_clock() { printf '%s' "$SIM"; }

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
nsends() { grep -c . "$SEND_LOG"; }
reset() { db "DELETE FROM tasks; DELETE FROM task_prefs WHERE key='gate_reminders_last_slot';"
          : >"$SEND_LOG"; : >"$AGENT_SEND_LOG"; : >"$NOTICE_LOG"; rm -f "$BOX_CONFIG" "$TMP/warn"; }
setmode() { printf '{"gate_reminders":"%s"}\n' "$1" >"$BOX_CONFIG"; }
mk_gate() { # ident tier asked_minutes_ago pinged_minutes_ago urgent
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_options,recommend,need_asked_at,gate_pinged_at,gate_urgent)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked','decision',$2,'choose','A|B','A',
              datetime('now','-$3 minutes'),datetime('now','-$4 minutes'),${5:-0});
      SELECT last_insert_rowid();"
}
seed20() { local i; for i in $(seq 1 20); do mk_gate "DIVE-$((100+i))" 2 $((i*72)) $((i*72-1)) 0 >/dev/null; done; }
# Simulated days start TOMORROW (UTC) so every slot is later than every real
# gate_pinged_at the stub writes; the WHERE's own 'now' stays real.
DAY0=$(( ( $(date -u +%s) / 86400 + 1 ) * 86400 ))
run_day() { # <day offset> <hours...>
  local d="$1" h; shift
  for h in "$@"; do SIM=$(( DAY0 + d*86400 + h*3600 + 120 )); TICK="d${d}h${h}"; _hb_gate_renag_sweep; done
}

# ── A: daily@9, 20 gates asked across 24h, 24 hourly ticks → ONE send at 09 ────
reset; seed20; setmode daily@09
run_day 0 $(seq 0 23)
line=$(head -1 "$SEND_LOG"); nids=$(awk -F'|' '{print $2}' <<<"$line" | tr , '\n' | grep -c .)
[[ "$(nsends)" == 1 && "$line" == d0h9\|* && "$nids" == 20 ]] \
  && ok_t "A: 20 gates, 24 ticks -> exactly one batch at 09 with all 20" \
  || bad_t "A: daily batch wrong" "sends=$(nsends) first=${line:0:40} nids=$nids"

# ── B: the next day's 09 tick sends once more, all 20 ──────────────────────────
: >"$SEND_LOG"
run_day 1 $(seq 0 23)
line=$(head -1 "$SEND_LOG"); nids=$(awk -F'|' '{print $2}' <<<"$line" | tr , '\n' | grep -c .)
[[ "$(nsends)" == 1 && "$line" == d1h9\|* && "$nids" == 20 ]] \
  && ok_t "B: second day -> one batch at 09, all 20 again (none waits over a day)" \
  || bad_t "B: second-day batch wrong" "sends=$(nsends) first=${line:0:40} nids=$nids"

# ── C: an urgent gate keeps its own clock in daily mode ────────────────────────
reset; seed20; setmode daily@09
u=$(mk_gate DIVE-200 2 120 119 1)
run_day 0 3
[[ "$(nsends)" == 1 && "$(cat "$SEND_LOG")" == "d0h3|${u}" ]] \
  && ok_t "C: urgent gate reminded at 03 on its own clock, alone" \
  || bad_t "C: urgent gate lane wrong" "$(tr '\n' ' ' <"$SEND_LOG")"

# ── D: missed slot (no tick 09-10) → one send at 11, none later that day ───────
reset; seed20; setmode daily@9
run_day 0 $(seq 0 8) $(seq 11 23)
[[ "$(nsends)" == 1 && "$(head -1 "$SEND_LOG")" == d0h11\|* ]] \
  && ok_t "D: missed 09 slot -> one batch at 11, none after" \
  || bad_t "D: missed slot wrong" "$(cut -c1-12 "$SEND_LOG" | tr '\n' ' ')"

# ── E: FIVEDIVE_GATE_RENAG=0 still silences everything ─────────────────────────
reset; seed20; setmode daily@09
FIVEDIVE_GATE_RENAG=0 run_day 0 $(seq 0 23)
[[ "$(nsends)" == 0 ]] && ok_t "E: FIVEDIVE_GATE_RENAG=0 wins over daily" \
  || bad_t "E: env kill switch lost" "sends=$(nsends)"

# ── F: default (unset) is per-gate: due gates go at the first tick ─────────────
reset
d1=$(mk_gate DIVE-300 2 1600 1500 0); d2=$(mk_gate DIVE-301 2 120 119 0); nd=$(mk_gate DIVE-302 2 600 300 0)
run_day 0 3
[[ "$(nsends)" == 1 && "$(cat "$SEND_LOG")" == "d0h3|${d1},${d2}" ]] \
  && ok_t "F: unset -> per-gate cadence unchanged (due rows at once, not-due row held)" \
  || bad_t "F: default cadence changed" "$(tr '\n' ' ' <"$SEND_LOG")"
reset; setmode per-gate
d1=$(mk_gate DIVE-300 2 1600 1500 0)
run_day 0 3
[[ "$(nsends)" == 1 ]] && ok_t "F2: per-gate set explicitly behaves as unset" || bad_t "F2: per-gate" "sends=$(nsends)"

# ── G: tier-1 lanes: stale (human) waits for the slot; fresh (agent rail) does not
reset; setmode daily@09
st=$(mk_gate DIVE-400 1 1800 1500 0)
fr=$(mk_gate DIVE-401 1 120 119 0)
run_day 0 3
s3=$(nsends); a3=$(grep -c . "$AGENT_SEND_LOG")
run_day 0 9
[[ "$s3" == 0 && "$a3" == 1 && "$(nsends)" == 1 && "$(cat "$SEND_LOG")" == "d0h9|${st}" ]] \
  && ok_t "G: T1 stale waits for 09 slot; T1 fresh still rides the agent rail at 03" \
  || bad_t "G: T1 lanes wrong" "s3=$s3 a3=$a3 sends=$(tr '\n' ' ' <"$SEND_LOG")"

# ── H: config — validation, normalisation, one owner notice per real change ────
reset
_task_resolve_gate_notifier() { printf main; }
out=$(cmd_box_config gate-reminders=off 2>&1); rc=$?
[[ "$rc" != 0 && ! -e "$BOX_CONFIG" ]] && ok_t "H1: 'off' is refused, nothing written" || bad_t "H1: off accepted" "rc=$rc $out"
out=$(cmd_box_config gate-reminders=daily@24 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok_t "H2: hour 24 refused" || bad_t "H2: daily@24 accepted"
SUDO_USER=agent-olivia cmd_box_config gate-reminders=daily@9 >/dev/null 2>&1
stored=$(jq -r .gate_reminders "$BOX_CONFIG")
n1=$(grep -c . "$NOTICE_LOG")
[[ "$stored" == daily@09 && "$n1" == 1 ]] && grep -q "once a day at 09:00 UTC (changed by olivia)" "$NOTICE_LOG" \
  && ok_t "H3: daily@9 stored as daily@09; ONE owner notice naming the seat" \
  || bad_t "H3: set/notice wrong" "stored=$stored notices=$n1 $(cat "$NOTICE_LOG")"
cmd_box_config gate-reminders=daily >/dev/null 2>&1
[[ "$(grep -c . "$NOTICE_LOG")" == 1 ]] && ok_t "H4: identical set (daily = daily@09) sends no second notice" \
  || bad_t "H4: duplicate notice" "$(cat "$NOTICE_LOG")"
cmd_box_config gate-reminders=default >/dev/null 2>&1
[[ "$(grep -c . "$NOTICE_LOG")" == 2 && "$(jq -r '.gate_reminders // "unset"' "$BOX_CONFIG")" == unset ]] \
  && ok_t "H5: clearing it tells the owner once and removes the key" \
  || bad_t "H5: clear wrong" "$(cat "$NOTICE_LOG")"
setmode daily@14
show=$(JSON_MODE=0 cmd_box_config 2>&1)
grep -q "gate-reminders = daily@14 (once a day at 14:00 UTC; box setting)" <<<"$show" \
  && ok_t "H6: '5dive config' shows mode, UTC hour and source" || bad_t "H6: show line" "$(grep gate-rem <<<"$show")"
_task_send_owner() { TASK_SEND_DELIVERED=0; }
rm -f "$BOX_CONFIG" "$TMP/warn"
cmd_box_config gate-reminders=daily@7 >/dev/null 2>&1
grep -q "could NOT be told" "$TMP/warn" 2>/dev/null && ok_t "H7: undelivered notice is said loudly" \
  || bad_t "H7: silent change when no bot confirmed"

# ── NEGATIVE CONTROL: revert the slot check → arm A goes red ───────────────────
if [[ -z "${_GATE_REM_MUTANT:-}" ]]; then
  mut="$TMP/hb_mutant.sh"
  sed -e '/\[\[ "\$last" == "\$day" \]\] && return 1/d' -e '/(( hnow >= 10#\$hh )) || return 1/d' "$SRC/cmd_heartbeat.sh" >"$mut"
  if cmp -s "$mut" "$SRC/cmd_heartbeat.sh"; then
    bad_t "NC: mutant did not change the slot check (sed anchors stale)"
  else
    mo=$(_GATE_REM_MUTANT=1 HB_FILE="$mut" bash "$0" 2>&1)
    grep -q '^FAIL - A:' <<<"$mo" && ok_t "NC: slot check reverted -> arm A red (more than one send)" \
      || bad_t "NC: arm A survived the reverted slot check" "$(grep -m1 'A:' <<<"$mo")"
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
