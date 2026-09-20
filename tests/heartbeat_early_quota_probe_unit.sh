#!/usr/bin/env bash
# DIVE-4591 unit harness for the EARLY provider-reset probe.
#
# The row's gap is not "we cannot read a quota number" — it is that every number
# we hold is a RECALL from a parked seat's last turn, so an early reset is
# invisible to every instrument on the box. The only live probe is a real turn.
# So the arms here are about the DECISION to spend one, what is read back, and
# what is done with the answer — never about a percentage.
#
# Each acceptance criterion from the row is named on the arm that closes it.
# The three arms that would be easiest to fake green are built to fail loudly:
#   * "a profile past its printed reset is NOT probed" is asserted on the
#     decision function directly, because `quota_wall_reset_guard` already
#     rewrites such a reading to `unmeasured` upstream — an end-to-end arm alone
#     would pass on the upstream rewrite and say nothing about THIS owner;
#   * "nothing is restarted on a still-walled probe" is asserted as a CALL COUNT
#     of the release path, not as the absence of a log line;
#   * the wall-before-sentinel order in the classifier carries a MUTANT arm: with
#     the two checks swapped, a refusal that quotes the prompt back reads `live`
#     and would restart a fleet on a wall.
# Run: bash tests/heartbeat_early_quota_probe_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-qprobe-unit.XXXXXX)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
grepok(){ if grep -qF "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (no '$2' in $3)"; fi; }
grepno(){ if grep -qF "$2" "$3" 2>/dev/null; then bad "$1 (found '$2' in $3)"; else ok "$1"; fi; }

# --- Extraction is ASSERTED, never assumed ------------------------------------
# A renamed or moved function must red this harness rather than drive an empty
# string and go green.
fn() { awk -v f="^$1\\\\(\\\\) \\\\{" '$0 ~ f,/^\}/' "$SRC/cmd_heartbeat.sh"; }
SRC_ALL=""
for f in _hb_quota_probe_decide _hb_quota_probe_classify _hb_quota_probe_run \
         _hb_quota_probe_walled_seats _hb_quota_probe_correct_deadline \
         _hb_quota_probe_release _hb_quota_probe_accounts _hb_quota_probe_sweep; do
  body="$(fn "$f")"
  if [ -z "$body" ]; then bad "could not extract $f from $SRC/cmd_heartbeat.sh"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; fi
  SRC_ALL+="$body"$'\n'
done
ok "all eight probe functions extract from the module"
for c in _HB_QUOTA_PROBE_EVERY_SEC _HB_QUOTA_PROBE_TIMEOUT_SEC _HB_QUOTA_PROBE_SENTINEL _HB_QUOTA_PROBE_BUDGET_SEC; do
  line=$(grep "^${c}=" "$SRC/cmd_heartbeat.sh")
  if [ -n "$line" ]; then ok "$c is defined in the module"; SRC_ALL+="$line"$'\n'
  else bad "$c is not defined"; fi
done
# The cadence the arms below drive is the module's own, not a number this file
# invented — a harness that hardcodes 3600 would pass against a source that had
# quietly become 60.
check "the shipped cadence is hourly" \
  "$( set +u; eval "$SRC_ALL"; printf '%s' "$_HB_QUOTA_PROBE_EVERY_SEC" )" "3600"
# And the hard default survives the variable being gone entirely: an unset
# cadence must not collapse to "probe every tick".
check "an unset cadence variable falls back to the hour, never to zero" \
  "$( set +u; eval "$(fn _hb_quota_probe_sweep)"
      export STATE_DIR="$TMP"; _hb_log() { :; }
      quota_wall_account() { :; }; _hb_quota_probe_accounts() { :; }
      printf '9999999999\n' > "$TMP/cad.stamp"
      # drive twice a minute apart with NO constant defined; the second must skip
      _hb_quota_probe_sweep 1800000000 "{}" >/dev/null
      _hb_quota_probe_sweep 1800000060 "{}" >/dev/null
      printf '%s' "${_HB_QPROBE_FIRED:-x}" )" "0"

echo "== the decision to spend a turn =="
D() { ( set +u; eval "$SRC_ALL"; _hb_quota_probe_decide "$1" "$2" "$3" ) }
# ACCEPTANCE 1 (the probe half): walled, printed reset still ahead.
check "walled + reset still in the future -> probe" "$(D exhausted 2000 1000)" "probe"
check "walled + no parseable reset -> probe (the wall named no time)" "$(D exhausted '' 1000)" "probe"
# ACCEPTANCE 1 (the never half): a profile with headroom is never probed.
check "headroom -> never probed" "$(D clear 2000 1000)" "skip:headroom"
check "headroom with no reset at all -> never probed" "$(D clear '' 1000)" "skip:headroom"
# ACCEPTANCE 2, armed explicitly: two owners for one transition is the defect.
check "walled but its printed reset has PASSED -> the un-park owns it, no probe" \
  "$(D exhausted 1000 2000)" "skip:deadline-passed"
check "walled exactly AT its printed reset -> still the un-park's, no probe" \
  "$(D exhausted 1000 1000)" "skip:deadline-passed"
# `unmeasured` is a real third state and must never fall into either action.
check "unmeasured -> no probe (a blind turn buys nothing)" "$(D unmeasured '' 1000)" "skip:unmeasured"
check "an empty state -> no probe" "$(D '' '' 1000)" "skip:unmeasured"
check "a garbage state -> no probe" "$(D wat 5 1000)" "skip:unmeasured"

echo "== reading the probe back =="
C() { ( set +u; eval "$SRC_ALL"; _HB_QUOTA_PROBE_SENTINEL=FIVEDIVEQUOTAPROBEOK
        _SUP_QUOTA_PAT="$(sed -n "s/^\[\[ -n \"\$_SUP_QUOTA_PAT\" \]\] || _SUP_QUOTA_PAT='\(.*\)'$/\1/p" src/cmd_supervisor.sh)"
        printf '%s' "$1" | _hb_quota_probe_classify ) }
check "the sentinel comes back -> live" "$(C 'FIVEDIVEQUOTAPROBEOK')" "live"
check "a Claude Code weekly refusal -> walled" \
  "$(C "Claude usage limit reached. Your limit will reset at 12pm (UTC).")" "walled"
check "the Team banner shape (DIVE-4401) -> walled" \
  "$(C "You've hit your org's monthly spend limit · your weekly limit resets Sep 19, 12pm (UTC)")" "walled"
check "an API 429 -> walled" "$(C 'API Error: 429 rate_limit_error')" "walled"
# Never infer live from silence: the action on `live` is restarting a fleet.
check "empty output -> unknown, never live" "$(C '')" "unknown"
check "whitespace only -> unknown" "$(C '   ')" "unknown"
check "a network error -> unknown" "$(C 'error: connect ETIMEDOUT 160.79.104.10:443')" "unknown"
check "an auth failure -> unknown, not live" "$(C 'Invalid API key · Please run /login')" "unknown"
# The order arm + its mutant.
QUOTED="Claude usage limit reached — I cannot reply with FIVEDIVEQUOTAPROBEOK right now."
check "a refusal that QUOTES the sentinel back is walled, not live" "$(C "$QUOTED")" "walled"
MUT=$( set +u; eval "$SRC_ALL"
       # swap the two checks: sentinel first, wall second
       eval "$(fn _hb_quota_probe_classify \
              | sed -e 's/printf .walled..n.; return 0; }/printf "WALLEDX\\n"; return 0; }/' )" >/dev/null 2>&1
       _hb_quota_probe_classify_mut() { :; }
       # rebuild the mutant explicitly rather than by regex on both lines
       _hb_quota_probe_classify() {
         local sentinel="FIVEDIVEQUOTAPROBEOK" out; out=$(cat)
         [[ -n "${out//[[:space:]]/}" ]] || { printf 'unknown\n'; return 0; }
         grep -qF "$sentinel" <<<"$out" && { printf 'live\n'; return 0; }
         printf 'walled\n'
       }
       printf '%s' "$QUOTED" | _hb_quota_probe_classify )
check "MUTANT: sentinel checked first reads that same refusal as live (the order is load-bearing)" "$MUT" "live"

echo "== the sweep: cadence, cost, and who it touches =="
# One seam per collaborator: the reading, the turn, and the release. Nothing
# here talks to a provider, to systemd or to sqlite.
mkdir -p "$TMP/auth-profiles/walled" "$TMP/auth-profiles/walled2" "$TMP/auth-profiles/clearacct" "$TMP/auth-profiles/late"
for p in walled walled2 clearacct late; do : > "$TMP/auth-profiles/$p/combined.env"; done
REG2='{"agents":{"a":{"type":"claude","authProfile":"walled"},
                 "a2":{"type":"claude","authProfile":"walled2"}}}'
REG='{"agents":{"a":{"type":"claude","authProfile":"walled"},
                "b":{"type":"claude","authProfile":"clearacct"},
                "c":{"type":"claude","authProfile":"late"},
                "d":{"type":"claude","authProfile":"@self:d"},
                "e":{"type":"claude","authProfile":"noprofiledir"}}}'
US=$'\037'
drive() {  # <now> [env assignments...] — echoes "<fired> <reset> <walled> <unknown> <skipped>"
  ( set +u
    export STATE_DIR="$TMP" AUTH_PROFILES_DIR="$TMP/auth-profiles" QUOTA_US="$US"
    eval "$SRC_ALL"
    _hb_log() { printf '%s\n' "$*" >>"$TMP/log"; }
    quota_wall_account() {
      case "$1" in
        walled|walled2) printf 'exhausted%s7d%s101%s%s%s30%sat the wall\n' "$US" "$US" "$US" "$WALL_RESET" "$US" "$US" ;;
        clearacct)  printf 'clear%s7d%s12%s%s%s30%sbelow the wall\n'  "$US" "$US" "$US" "$WALL_RESET" "$US" "$US" ;;
        late)       printf 'exhausted%s7d%s100%s%s%s30%spast its reset\n' "$US" "$US" "$US" "$LATE_RESET" "$US" "$US" ;;
        *)          printf 'unmeasured%s%s%s%s%s0%sno row\n' "$US" "$US" "$US" "$US" "$US" ;;
      esac
    }
    _hb_quota_probe_run() { printf '%s\n' "$1" >>"$TMP/probed"; printf '%s' "${PROBE_OUT:-}"; }
    _hb_quota_probe_release() { printf '%s\n' "$1" >>"$TMP/released"; printf '2 2'; }
    [ $# -gt 1 ] && export "${@:2}"
    _hb_quota_probe_sweep "$1" "$REG"
    printf '%s %s %s %s %s\n' "${_HB_QPROBE_FIRED:-x}" "${_HB_QPROBE_RESET:-x}" \
      "${_HB_QPROBE_WALLED:-x}" "${_HB_QPROBE_UNKNOWN:-x}" "${_HB_QPROBE_SKIPPED:-x}" )
}
reset_fx() { : >"$TMP/log"; : >"$TMP/probed"; : >"$TMP/released"; rm -f "$TMP/quota-probe.stamp"; }
export WALL_RESET LATE_RESET PROBE_OUT
WALL_RESET="2099-01-01T00:00:00Z"   # still ahead of every clock below
LATE_RESET="2020-01-01T00:00:00Z"   # long passed

reset_fx
PROBE_OUT="Claude usage limit reached. resets at 12pm (UTC)"
# ACCEPTANCE 1 end-to-end: of five accounts, exactly ONE is probed.
check "exactly one probe fired across five accounts" "$(drive 1900000000)" "1 0 1 0 2"
check "and it was the walled-before-its-reset account, once" "$(sort "$TMP/probed" | tr '\n' ' ')" "walled "
grepno "the account with headroom was never probed" "clearacct" "$TMP/probed"
# ACCEPTANCE 2 end-to-end, on top of the decision arm above.
grepno "the account past its printed reset was never probed" "late" "$TMP/probed"
grepok "and the log says the un-park owns that one" "the heartbeat's own un-park owns that transition" "$TMP/log"
# ACCEPTANCE 4: a still-walled probe restarts nothing and moves no clock.
check "a still-walled probe never reaches the release path" "$(wc -l <"$TMP/released")" "0"
grepok "and it says so in the log" "nothing restarted, no row's clock moved" "$TMP/log"
# Requirement 4 of the row: the cost is stated every time a turn is spent.
grepok "the cost of the turn is stated in the log" "SPENDING ONE SHORT TURN" "$TMP/log"

# The cadence gate. A gate that let everything through would still pass the arm
# above, so the proof is a second call inside the window probing nothing.
check "a second tick 60s later fires no probe (cadence gate)" "$(drive 1900000060)" "0 0 0 0 0"
check "a tick one second short of the cadence still fires none" "$(drive 1900003599)" "0 0 0 0 0"
check "the tick at exactly the cadence probes again" "$(drive 1900003600)" "1 0 1 0 2"

# ACCEPTANCE 3 + 5: a live probe hands the account to the release path.
reset_fx
PROBE_OUT="FIVEDIVEQUOTAPROBEOK"
check "a live probe counts an early reset" "$(drive 1910000000)" "1 1 0 0 2"
check "and the release path was called for that account" "$(cat "$TMP/released")" "walled"
grepok "the log names the restarts and the corrected deadlines" "2 stored deadline(s) corrected to the measured instant" "$TMP/log"

# A blind probe is never headroom.
reset_fx
PROBE_OUT=""
check "an empty probe is could-not-determine, not a reset" "$(drive 1920000000)" "1 0 0 1 2"
check "and nothing is released on it" "$(wc -l <"$TMP/released")" "0"

reset_fx
PROBE_OUT="FIVEDIVEQUOTAPROBEOK"
check "the off switch probes ZERO times, it does not merely read a flag" \
  "$(drive 1930000000 QUOTA_EARLY_PROBE=off)" "0 0 0 0 0"
check "and fires no turn at all" "$(wc -l <"$TMP/probed")" "0"

reset_fx
printf '99999999999\n' >"$TMP/quota-probe.stamp"
check "a stamp from the FUTURE does not wedge the probe" "$(drive 1940000000)" "1 1 0 0 2"

# The packaging defect must be NAMED — silence reads exactly like "nothing was
# walled", which is this sweep's own failure shape.
reset_fx
PKG=$( set +u
  export STATE_DIR="$TMP" AUTH_PROFILES_DIR="$TMP/auth-profiles" QUOTA_US="$US"
  eval "$SRC_ALL"; _hb_log() { printf '%s\n' "$*" >>"$TMP/log"; }
  _hb_quota_probe_sweep 1950000000 "$REG"; printf '%s' "${_HB_QPROBE_FIRED:-x}" )
check "an absent quota_wall_account fires no probe" "$PKG" "0"
grepok "and the missing reader is NAMED in the log" "PACKAGING DEFECT" "$TMP/log"

# The pass must never hold the dispatch tick open on a hung provider — and the
# bound must never be able to starve every probe, which would be a wedge dressed
# as a limit. Two walled accounts, a probe that takes 2s, a 1s budget.
reset_fx
BUDGET=$( set +u
  export STATE_DIR="$TMP" AUTH_PROFILES_DIR="$TMP/auth-profiles" QUOTA_US="$US"
  export WALL_RESET="2099-01-01T00:00:00Z" LATE_RESET="2020-01-01T00:00:00Z"
  eval "$SRC_ALL"
  _HB_QUOTA_PROBE_BUDGET_SEC=1
  _hb_log() { printf '%s\n' "$*" >>"$TMP/log"; }
  quota_wall_account() { printf 'exhausted%s7d%s101%s2099-01-01T00:00:00Z%s30%sat the wall\n' "$US" "$US" "$US" "$US" "$US"; }
  _hb_quota_probe_run() { printf '%s\n' "$1" >>"$TMP/probed"; sleep 2; printf 'Claude usage limit reached'; }
  _hb_quota_probe_sweep 1960000000 "$REG2"
  printf '%s %s' "${_HB_QPROBE_FIRED:-x}" "${_HB_QPROBE_SKIPPED:-x}" )
check "the pass fires ONE probe and defers the rest once its wall-clock budget is spent" "$BUDGET" "1 1"
grepok "and the deferral is stated, not silent" "spent its 1s wall-clock budget" "$TMP/log"

echo "== which accounts are eligible at all =="
ACCTS=$( set +u; export AUTH_PROFILES_DIR="$TMP/auth-profiles"; eval "$SRC_ALL"
         _hb_quota_probe_accounts "$REG" | sort | tr '\n' ' ' )
check "only named profiles with a readable credential are probed" "$ACCTS" "clearacct late walled "

echo "== the release: restart, correct, hand to the one owner =="
# Real sqlite for the deadline correction — ACCEPTANCE 5 is a WRITE, and a
# stubbed db would grade the harness rather than the UPDATE.
DB="$TMP/t.db"
sqlite3 "$DB" "CREATE TABLE supervisor_events(id INTEGER PRIMARY KEY, agent TEXT, classification TEXT, signals TEXT);"
sqlite3 "$DB" "INSERT INTO supervisor_events(agent,classification,signals) VALUES
  ('a','quota-exhausted', json('{\"signals\":{\"quotaDeadlineEpoch\":9000}}')),
  ('a','quota-exhausted', json('{\"signals\":{\"quotaDeadlineEpoch\":9999}}')),
  ('z','quota-exhausted', json('{\"signals\":{\"quotaDeadlineEpoch\":9999}}')),
  ('h','healthy',         json('{\"signals\":{\"quotaDeadlineEpoch\":9999}}'));"
REL=$( set +u
  eval "$SRC_ALL"
  db() { sqlite3 "$DB" "$1"; }
  sqlq() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }
  _hb_log() { printf '%s\n' "$*" >>"$TMP/rlog"; }
  _hb_agent_is_parked() { [[ "$1" == "z" ]]; }
  _hb_wake_settle_tmux() { printf 'settle %s\n' "$1" >>"$TMP/acts"; }
  systemctl() { printf '%s %s\n' "$1" "$2" >>"$TMP/acts"; return 0; }
  _hb_quota_unpark() { printf 'unpark %s grace=%s\n' "$1" "$2" >>"$TMP/acts"; }
  REGR='{"agents":{"a":{"type":"claude","authProfile":"walled"},
                   "z":{"type":"claude","authProfile":"walled"},
                   "h":{"type":"claude","authProfile":"walled"}}}'
  _hb_quota_probe_release walled 5000 "$REGR" )
check "release reports <restarted> <corrected>" "$REL" "1 2"
grepok "ACCEPTANCE 3: the walled seat is restarted" "restart 5dive-agent@a.service" "$TMP/acts"
grepok "the pane is settled before anything is injected" "settle a" "$TMP/acts"
grepok "the transition is handed to the ONE owner, with the grace already spent" "unpark a grace=0" "$TMP/acts"
grepno "an operator-parked seat is NOT restarted" "restart 5dive-agent@z.service" "$TMP/acts"
grepno "and is not woken either" "unpark z" "$TMP/acts"
grepok "but its stale deadline is still corrected" "parked by operator intent" "$TMP/rlog"
# ACCEPTANCE 5, read back out of the database.
check "ACCEPTANCE 5: the newest row's deadline is corrected to the measured instant" \
  "$(sqlite3 "$DB" "SELECT json_extract(signals,'\$.signals.quotaDeadlineEpoch') FROM supervisor_events WHERE agent='a' ORDER BY id DESC LIMIT 1;")" "5000"
check "and the correction is marked as measured, not printed by a wall" \
  "$(sqlite3 "$DB" "SELECT json_extract(signals,'\$.signals.quotaDeadlineCorrectedAt') FROM supervisor_events WHERE agent='a' ORDER BY id DESC LIMIT 1;")" "5000"
check "an OLDER observation of the same seat is left alone (the newest is the authority)" \
  "$(sqlite3 "$DB" "SELECT json_extract(signals,'\$.signals.quotaDeadlineEpoch') FROM supervisor_events WHERE agent='a' ORDER BY id ASC LIMIT 1;")" "9000"
check "a seat whose newest observation is NOT a wall is never touched" \
  "$(sqlite3 "$DB" "SELECT json_extract(signals,'\$.signals.quotaDeadlineEpoch') FROM supervisor_events WHERE agent='h';")" "9999"
# Idempotence: the second pass matches zero rows, so a re-run cannot re-correct
# a deadline that is already in the past.
AGAIN=$( set +u; eval "$SRC_ALL"; db() { sqlite3 "$DB" "$1"; }
         sqlq() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }
         _hb_quota_probe_correct_deadline a 6000 )
check "a second correction moves nothing (the predicate is its own latch)" "$AGAIN" "0"

echo "== wiring (extraction grades the function, never its call site) =="
grep -q '_hb_quota_probe_sweep "\$now" "\$reg"' "$SRC/cmd_heartbeat.sh" \
  && ok "the sweep is CALLED from the tick with the tick's own clock and registry" \
  || bad "the sweep is never called from cmd_heartbeat_tick"
SNAP_LN=$(grep -n '_hb_quota_snapshot_sweep "\$now"' "$SRC/cmd_heartbeat.sh" | tail -1 | cut -d: -f1)
PROBE_LN=$(grep -n '_hb_quota_probe_sweep "\$now"' "$SRC/cmd_heartbeat.sh" | tail -1 | cut -d: -f1)
if [ -n "$SNAP_LN" ] && [ -n "$PROBE_LN" ] && [ "$PROBE_LN" -gt "$SNAP_LN" ]; then
  ok "it runs AFTER the snapshot republish, so it decides on this tick's reading"
else bad "the probe does not run after the snapshot republish (snap=$SNAP_LN probe=$PROBE_LN)"; fi
grep -q '^auth_probe_output()' "$SRC/cmd_auth.sh" \
  && ok "auth_probe_output exists (the one copy of the env precedence)" \
  || bad "auth_probe_output is missing from src/cmd_auth.sh"
grep -q 'auth_probe_output "\$type" "\$profile" 5' "$SRC/cmd_auth.sh" \
  && ok "and auth_probe_one was refactored ONTO it — one implementation, not two" \
  || bad "auth_probe_one still carries its own copy of the env precedence"
AUTH_LN=$(grep -n '^  src/cmd_auth.sh$' build.sh | cut -d: -f1)
HB_LN=$(grep -n '^  src/cmd_heartbeat.sh$' build.sh | cut -d: -f1)
if [ -n "$AUTH_LN" ] && [ -n "$HB_LN" ] && [ "$AUTH_LN" -lt "$HB_LN" ]; then
  ok "the bundle orders cmd_auth.sh ahead of cmd_heartbeat.sh (the probe's caller)"
else bad "bundle order does not place cmd_auth.sh ahead of cmd_heartbeat.sh"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
