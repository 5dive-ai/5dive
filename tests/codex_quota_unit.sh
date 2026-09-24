#!/usr/bin/env bash
# DIVE-3968 — Codex quota is read from the Codex ROLLOUT, not from the pane and
# not from a Claude statusline cache it never writes.
#
# THE ROW, measured 2026-09-14: codex hit `usage_limit_exceeded` at 06:53Z, its
# 5h window reset at 07:00:26Z (`rate_limits.primary.resets_at` in its own
# rollout), and the supervisor kept it `quota-exhausted` until 08:58Z because
# the pane said "try again at 7:00 AM", which the park cannot date — so it took
# the 6h fallback. Same shape 2026-09-11.
#
# Grades, in order: the reader and its one trap (the refused turn's own
# token_count is a `premium` record with both windows null); the five states the
# row names (missing, healthy, near-limit, exhausted, recovered); the account
# row that rotation, `agent list/info` and liveness already read; the join the
# supervisor writes; the PARK that consumes it (the arm that separates the
# trees — a parse arm passed on DIVE-4328's broken tree); and the usage
# collector's reset field.
#
# Pure / fixture-only: no tmux, no root, no network, no live registry.
# Run: bash tests/codex_quota_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/codex-quota.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/quota_wall.sh lib/codex_quota.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_account.sh \
         cmd_supervisor.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
US=$'\037'
field() { local n="$1"; tr "$US" '\n' | sed -n "${n}p"; }

REGISTRY="$TMP/registry.json"
printf '%s' '{"agents":{"cx":{"type":"codex","authProfile":"codex"},"cl":{"type":"claude","authProfile":"mark"}}}' >"$REGISTRY"
registry_read() { cat "$REGISTRY"; }
usage_agent_home() { printf '%s/home/%s\n' "$TMP" "$1"; }

NOW=1789369000                      # 2026-09-14 06:56:40Z — three minutes after the wall
R5H=1789369226                      # the 5h reset the rollout carried (07:00:26Z)
R7D=1789813286                      # the 7d reset
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# ── fixture writers ─────────────────────────────────────────────────────────
tc() {  # <epoch> <p_used> <p_reset> <s_used> <s_reset>  — a codex-limit reading
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus","rate_limit_reached_type":null}}}\n' \
    "$(iso "$1")" "$2" "$3" "$4" "$5"
}
tc_premium() {  # <epoch> — the record a REFUSED turn writes: both windows null
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus","rate_limit_reached_type":null}}}\n' "$(iso "$1")"
}
done_ok() { printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"ok"}}\n' "$(iso "$1")"; }
done_err() {  # <epoch> <codex_error_info>
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"task_complete","error":{"message":"You have hit your usage limit ... try again at 7:00 AM.","codex_error_info":"%s"}}}\n' "$(iso "$1")" "$2"
}
seat() {  # <name> — fresh rollout dir; stdin -> the rollout
  local d="$TMP/home/$1/.codex/sessions/2026/09/14"
  rm -rf "$TMP/home/$1"; mkdir -p "$d"; cat >"$d/rollout-2026-09-14T00-00-00-x.jsonl"
}
state_of() { codex_quota_state "$(codex_quota_read "$TMP/home/$1")" "${2:-$NOW}"; }

# ── 1. missing ──────────────────────────────────────────────────────────────
rm -rf "$TMP/home/none"; mkdir -p "$TMP/home/none"
S=$(state_of none)
[[ "$(field 1 <<<"$S")" == "missing" && -z "$(codex_quota_read "$TMP/home/none")" ]] \
  && ok_t "missing: a seat with no rollout reads missing, and the reader emits nothing" \
  || bad_t "no-rollout state" "$S"
done_ok $((NOW-60)) | seat noreading
S=$(state_of noreading)
[[ "$(field 1 <<<"$S")" == "missing" ]] \
  && ok_t "missing: a rollout with no rate-limit reading (non-ChatGPT provider) is missing, not healthy" \
  || bad_t "no-reading state" "$S"

# ── 2. healthy / near-limit ─────────────────────────────────────────────────
{ tc $((NOW-120)) 4 "$R5H" 50 "$R7D"; done_ok $((NOW-100)); } | seat healthy
S=$(state_of healthy)
[[ "$(field 1 <<<"$S")|$(field 2 <<<"$S")|$(field 3 <<<"$S")|$(field 4 <<<"$S")" == "healthy|7d|50|$R7D" ]] \
  && ok_t "healthy: names the fuller open window (7d 50%) and its reset" \
  || bad_t "healthy state" "$S"
{ tc $((NOW-120)) 95 "$R5H" 50 "$R7D"; done_ok $((NOW-100)); } | seat near
S=$(state_of near)
[[ "$(field 1 <<<"$S")|$(field 2 <<<"$S")|$(field 3 <<<"$S")" == "near-limit|5h|95" ]] \
  && ok_t "near-limit: 5h at 95% (>= CODEX_QUOTA_NEAR_PCT) reads near-limit" \
  || bad_t "near-limit state" "$S"

# ── 3. exhausted — the row's own shape, premium trap included ───────────────
# Last real reading at 99% (the measured case: 06:53 wall, 99-100%), then the
# refused turn's premium record, then the refusal.
{ tc $((NOW-240)) 99 "$R5H" 50 "$R7D"; tc_premium $((NOW-200)); done_err $((NOW-200)) usage_limit_exceeded; } | seat walled
M=$(codex_quota_read "$TMP/home/walled")
[[ "$(jq -r '.snapshot.limitId' <<<"$M")" == "codex" && "$(jq -r '.lastTurn.error' <<<"$M")" == "usage_limit_exceeded" ]] \
  && ok_t "reader: skips the refused turn's premium/null record and joins the reading BEFORE it to the refusal" \
  || bad_t "premium trap" "$M"
S=$(state_of walled)
[[ "$(field 1 <<<"$S")|$(field 2 <<<"$S")|$(field 4 <<<"$S")" == "exhausted|5h|$R5H" ]] \
  && ok_t "exhausted: refusal + open 5h window -> exhausted until the rollout's resets_at (07:00:26Z)" \
  || bad_t "exhausted state" "$S"

# Weekly wall: 5h empty, 7d full -> the deadline is days out, not hours.
{ tc $((NOW-240)) 0 "$R5H" 100 "$R7D"; tc_premium $((NOW-200)); done_err $((NOW-200)) usage_limit_exceeded; } | seat weekly
S=$(state_of weekly)
[[ "$(field 1 <<<"$S")|$(field 2 <<<"$S")|$(field 4 <<<"$S")" == "exhausted|7d|$R7D" ]] \
  && ok_t "exhausted: a 7d wall keys to the 7d reset, not the (irrelevant) 5h one" \
  || bad_t "weekly wall" "$S"

# A reading at 100% with the window still open is a wall before any refusal.
{ tc $((NOW-60)) 100 "$R5H" 40 "$R7D"; done_ok $((NOW-50)); } | seat full
S=$(state_of full)
[[ "$(field 1 <<<"$S")" == "exhausted" ]] \
  && ok_t "exhausted: a 100% reading on an open window is exhausted even before a turn is refused" \
  || bad_t "full-reading state" "$S"

# ── 4. recovered ────────────────────────────────────────────────────────────
S=$(state_of walled $((R5H + 30)))
[[ "$(field 1 <<<"$S")|$(field 4 <<<"$S")" == "recovered|$R5H" ]] \
  && ok_t "recovered: same rollout, read after 07:00:26Z -> recovered, without re-reading anything" \
  || bad_t "recovered state" "$S"
# A rolled window is 0%, not its stale number.
{ tc $((NOW-9000)) 100 $((NOW-10)) 30 "$R7D"; done_ok $((NOW-8990)); } | seat rolled
S=$(state_of rolled)
[[ "$(field 1 <<<"$S")|$(field 2 <<<"$S")|$(field 3 <<<"$S")" == "healthy|7d|30" ]] \
  && ok_t "a window whose reset has passed counts as 0% (the 100% 5h reading is history)" \
  || bad_t "rolled window" "$S"

# Legacy Codex 0.4x: resets_in_seconds relative to the reading.
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":20,"window_minutes":300,"resets_in_seconds":600}}}}\n' "$(iso $((NOW-100)))" | seat legacy
S=$(state_of legacy)
[[ "$(field 4 <<<"$S")" == "$((NOW-100+600))" ]] \
  && ok_t "legacy resets_in_seconds is converted against the reading's own time" \
  || bad_t "legacy reset" "$S"

# The NEWEST rollout wins, by mtime.
{ tc $((NOW-60)) 10 "$R5H" 10 "$R7D"; } >"$TMP/home/walled/.codex/sessions/2026/09/14/rollout-older.jsonl"
touch -d "@$((NOW-99999))" "$TMP/home/walled/.codex/sessions/2026/09/14/rollout-older.jsonl"
[[ "$(field 1 <<<"$(state_of walled)")" == "exhausted" ]] \
  && ok_t "the seat's newest rollout (by mtime) is the one read" \
  || bad_t "rollout selection" "$(state_of walled)"

# ── 5. the account row every existing surface reads ─────────────────────────
RL=$(codex_quota_ratelimits "$(codex_quota_read "$TMP/home/walled")" "$NOW")
[[ "$(jq -r '[.fiveHourPct, .fiveResetsAt, .sevenDayPct, .asOf] | @csv' <<<"$RL")" == "100,$R5H,50,$((NOW-200))" ]] \
  && ok_t "account shape: the refused window reads 100% (not the 99 before it), asOf = the refusal" \
  || bad_t "ratelimits shape" "$RL"
[[ -z "$(codex_quota_ratelimits "$(codex_quota_read "$TMP/home/none")" "$NOW")" ]] \
  && ok_t "account shape: a missing reading emits nothing (unmeasured downstream, never clear)" \
  || bad_t "missing -> ratelimits" ""

mkdir -p "$TMP/home/cx"; cp -a "$TMP/home/walled/.codex" "$TMP/home/cx/"
RL=$(usage_read_ratelimits cx)
# Read at the REAL clock, so this fixture's 07:00:26Z wall has long reset: the
# raw 99 comes through (the pure arm above covers the raise to 100).
[[ "$(jq -r '.source' <<<"$RL")" == "codex-rollout" && "$(jq -r '[.fiveHourPct, .fiveResetsAt] | @csv' <<<"$RL")" == "99,$R5H" ]] \
  && ok_t "usage_read_ratelimits: a codex-TYPED seat is read from its rollout (the account row stops being null)" \
  || bad_t "account usage codex branch" "$RL"
mkdir -p "$TMP/home/cl/.claude"; cp -a "$TMP/home/walled/.codex" "$TMP/home/cl/"
printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1},"seven_day":{"used_percentage":34,"resets_at":2}}}' >"$TMP/home/cl/.claude/statusline-last.json"
RL=$(usage_read_ratelimits cl)
[[ "$(jq -r '.fiveHourPct' <<<"$RL")" == "12" && "$(jq -r '.source // "statusline"' <<<"$RL")" == "statusline" ]] \
  && ok_t "usage_read_ratelimits: a claude seat with a stray .codex tree still reads its statusline (type, not directories)" \
  || bad_t "claude branch changed" "$RL"

# ── 6. the supervisor join ──────────────────────────────────────────────────
PANE="You've hit your usage limit. Upgrade to Pro ... or try again at 7:00 AM."
join_of() { _sup_codex_quota_join "$(codex_quota_read "$TMP/home/$1")" "$2" "$3" "$4" "$5" "$6"; }
IFS=$'\x1f' read -r JD JE JW <<<"$(join_of walled "$NOW" "$PANE" unknown "" "")"
[[ "$JD|$JE" == "live|$R5H" && "$JW" == codex\ account\ at\ 100%* ]] \
  && ok_t "join/exhausted: an undatable pane wall becomes live + the rollout's reset epoch, and the wall is named" \
  || bad_t "join exhausted" "$JD|$JE|$JW"
IFS=$'\x1f' read -r JD JE JW <<<"$(join_of walled $((R5H + 30)) "$PANE" unknown "" "")"
[[ "$JD|$JE|$JW" == "lapsed|$R5H|" ]] \
  && ok_t "join/recovered: the same stale pane after the reset is lapsed at that epoch" \
  || bad_t "join recovered" "$JD|$JE|$JW"
IFS=$'\x1f' read -r JD JE JW <<<"$(join_of healthy "$NOW" "$PANE" unknown "" "")"
[[ "$JD|$JE" == "lapsed|$((NOW-100))" ]] \
  && ok_t "join/healthy: a pane refusal older than a SERVED turn is scrollback (lapsed at that turn)" \
  || bad_t "join healthy" "$JD|$JE|$JW"
{ tc $((NOW-120)) 4 "$R5H" 50 "$R7D"; done_err $((NOW-100)) insufficient_credits; } | seat othererr
IFS=$'\x1f' read -r JD JE JW <<<"$(join_of othererr "$NOW" "$PANE" unknown "" "")"
[[ "$JD|$JE|$JW" == "unknown||" ]] \
  && ok_t "join: a turn that failed some OTHER way proves nothing about the pane — left untouched" \
  || bad_t "join other error" "$JD|$JE|$JW"
IFS=$'\x1f' read -r JD JE JW <<<"$(_sup_codex_quota_join "" "$NOW" "$PANE" live 123 "w")"
[[ "$JD|$JE|$JW" == "live|123|w" ]] \
  && ok_t "join/missing: no reading never overrules the pane" \
  || bad_t "join missing" "$JD|$JE|$JW"

# ── 7. the classifier and the PARK — what the consumer reads ────────────────
classify() {  # <quota_excerpt> <deadline> <wall>
  _sup_classify active 1 active 1 alive ok 0 0 60 0 "" "" 0 0 0 "$1" "$2" "" unmarked "$3" ok "" -1 \
    | cut -d$'\x1f' -f1
}
IFS=$'\x1f' read -r JD JE JW <<<"$(join_of walled "$NOW" "" unknown "" "")"
[[ "$(classify "" "$JD" "$JW")" == "quota-exhausted" ]] \
  && ok_t "classify: a walled codex seat whose pane has SCROLLED still reads quota-exhausted (off the record)" \
  || bad_t "scrolled wall" "$(classify "" "$JD" "$JW")"
IFS=$'\x1f' read -r JD JE JW <<<"$(join_of walled $((R5H + 30)) "$PANE" unknown "" "")"
[[ "$(classify "$PANE" "$JD" "$JW")" != "quota-exhausted" ]] \
  && ok_t "classify: after the reset the stale pane no longer holds the seat quota-exhausted" \
  || bad_t "recovered still walled" "$(classify "$PANE" "$JD" "$JW")"
[[ "$(classify "$PANE" unknown "")" == "quota-exhausted" ]] \
  && ok_t "control: the pane-only reading (the old tree) DOES hold it — the arm above discriminates" \
  || bad_t "control did not hold" ""

park_for() {  # <deadline> <epoch> — one observation 3m old, then ask the park
  db "DELETE FROM supervisor_events;"
  local ep_json="null"; [[ "$2" =~ ^[0-9]+$ ]] && ep_json="$2"
  db "INSERT INTO supervisor_events (ts, agent, event, classification, cause, signals)
      VALUES (datetime('now','-3 minutes'), 'cx', 'observe', 'quota-exhausted', 'quota-exhausted',
              '{\"signals\":{\"quotaDeadline\":\"$1\",\"quotaDeadlineEpoch\":${ep_json}}}');"
  _hb_quota_park_until_seat cx 15
}
IFS=$'\x1f' read -r JD JE JW <<<"$(join_of walled "$NOW" "$PANE" unknown "" "")"
U=$(park_for "$JD" "$JE")
[[ "$U" == "$((R5H + 15*60))" ]] \
  && ok_t "PARK: runs to the rollout's reset + one tick ($(date -u -d "@$U" +%H:%MZ)), not the 6h cap" \
  || bad_t "park did not key to the reset" "until=$U want=$((R5H + 900))"
U0=$(park_for unknown "")
OBS=$(date -u -d "$(db "SELECT ts FROM supervisor_events LIMIT 1;") UTC" +%s)
[[ "$U0" == "$((OBS + _HB_QUOTA_PARK_FALLBACK_SEC))" ]] \
  && ok_t "control: the pane-only values (the 2026-09-14 tree) fall to the 6h cap — the PARK arm discriminates" \
  || bad_t "control park" "until=$U0"

# ── 8. the usage collector's reset field ────────────────────────────────────
awk "/python3 - <<'PY'/{f=1;next} f&&/^PY$/{exit} f" "$SRC/cmd_usage.sh" >"$TMP/collect.py"
UN=$(date +%s)
mkdir -p "$TMP/uh/agent-cx/.codex/sessions/2026/09/14"
printf '{"agents":{"cx":{"type":"codex"}}}' >"$TMP/ureg.json"
{ tc $((UN-300)) 99 $((UN+3000)) 50 $((UN+90000)); tc_premium $((UN-200)); done_err $((UN-200)) usage_limit_exceeded; } \
  >"$TMP/uh/agent-cx/.codex/sessions/2026/09/14/rollout-u.jsonl"
UO=$(REGISTRY="$TMP/ureg.json" TASK_DB="$TMP/none.db" USAGE_SINCE="$((UN-3600))" USAGE_HOME_ROOT="$TMP/uh" \
     python3 "$TMP/collect.py" 2>/dev/null)
UR=$(jq -c '.agents[] | select(.name=="cx")' <<<"$UO")
[[ "$(jq -r '[.fiveHourPct, .sevenDayPct] | @csv' <<<"$UR")" == "99,50" ]] \
  && ok_t "usage: the refused turn's null record no longer blanks the 5h/7d gauge" \
  || bad_t "usage gauge blanked" "$UR"
grep -q '"resets_at"' "$SRC/cmd_usage.sh" && grep -q 'last_rl_ts' "$SRC/cmd_usage.sh" \
  && ok_t "usage: current Codex's resets_at epoch is read (it was resets_in_seconds only)" \
  || bad_t "usage reset field" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
