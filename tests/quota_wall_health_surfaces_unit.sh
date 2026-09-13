#!/usr/bin/env bash
# DIVE-4342 — a seat whose auth account is AT ITS RATE-LIMIT WALL must not be
# reported ready / alive / healthy, and an account's usage row must outlive the
# set of seats bound to it.
#
# The row's own VERIFY clause, arm for arm:
#   * fixture profile at 7d 101% bound to a seat -> all three surfaces name the
#     wall (`agent list` verdict, `liveness` verdict, `supervisor` overlay);
#   * unbind the seat -> `account usage` still prints 101% for that profile.
#
# NEGATIVE CONTROLS ARE THE POINT OF THIS FILE. A join that reports the wall is
# easy; a join that reports the wall AND stays quiet when the snapshot is
# absent, stale, or simply below the wall is the one that can ship. Each
# positive arm below is paired with the negative that a "return exhausted"
# mutant would fail — an equality-only suite cannot tell the join from a stub
# (measured before, on this repo's own harnesses).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh

TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
AUTH_PROFILES_DIR="$STATE_DIR/auth-profiles"; mkdir -p "$AUTH_PROFILES_DIR"
QUOTA_SNAPSHOT_FILE="$STATE_DIR/account-usage.json"

# shellcheck source=/dev/null
source src/lib/quota_wall.sh

PASS=0
FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3"
  fi
}

NOW=$(date +%s)

# snap <ageSec> <fiveHourPct|null> <sevenDayPct|null> — write the published
# snapshot for account `walled`, exactly as `account usage` publishes it.
snap() {
  local age="$1" five="$2" seven="$3"
  jq -cn --argjson at "$(( NOW - age ))" --argjson f "$five" --argjson s "$seven" \
    '{writtenAt:$at, accounts:[
        {name:"walled", agents:["dev9"],
         usage:{fiveHour:(if $f == null then null else {pct:$f, resetsAt:"2026-09-19T00:00:00Z"} end),
                sevenDay:(if $s == null then null else {pct:$s, resetsAt:"2026-09-19T00:00:00Z"} end),
                asOf:$at, source:"dev9", remembered:false}}]}' >"$QUOTA_SNAPSHOT_FILE"
}
field() { local n="$1"; shift; IFS=$'\037' read -r -a f <<<"$*"; printf '%s' "${f[$n]:-}"; }
wstate() { field 0 "$(quota_wall_account "$1")"; }
wwin()   { field 1 "$(quota_wall_account "$1")"; }
wpct()   { field 2 "$(quota_wall_account "$1")"; }

# ---------------------------------------------------------------- the wall ---
snap 10 0 101
t "7d over the wall reads exhausted"              "exhausted" "$(wstate walled)"
t "and names the WINDOW, so a surface can say it" "7d"        "$(wwin walled)"
t "and carries the measured pct, not a label"     "101"       "$(wpct walled)"

snap 10 100 12
t "5h at exactly 100 is the wall too"             "exhausted" "$(wstate walled)"
t "the 5h window is named when it is the hit"     "5h"        "$(wwin walled)"

snap 10 0 101
# When BOTH windows are walled the LONGER one wins: it is the one the operator
# cannot wait out, and naming the 5h reset would understate the outage.
snap 10 100 101
t "both walled -> the 7d window is reported"      "7d"        "$(wwin walled)"

# ------------------------------------------------- negative controls ---------
snap 10 88 99
t "below the wall is clear, NOT exhausted"        "clear"     "$(wstate walled)"

snap "$(( QUOTA_SNAPSHOT_MAX_AGE + 5 ))" 0 101
t "a STALE snapshot at 101% is unmeasured, never a wall" "unmeasured" "$(wstate walled)"
t "a stale snapshot is also not 'clear'" "no" \
  "$( [[ "$(wstate walled)" == "clear" ]] && printf yes || printf no )"

snap 10 null null
t "an account reporting neither window is unmeasured" "unmeasured" "$(wstate walled)"

snap 10 0 101
t "an account with NO row in the snapshot is unmeasured" "unmeasured" "$(wstate other-account)"
t "an unbound seat (no account) is unmeasured, not clear" "unmeasured" "$(wstate "")"

rm -f "$QUOTA_SNAPSHOT_FILE"
t "no snapshot at all is unmeasured"              "unmeasured" "$(wstate walled)"
t "and the note tells the operator how to make one" "yes" \
  "$(quota_wall_account walled | grep -q 'sudo 5dive account usage' && printf yes || printf no)"

printf 'not-json\n' >"$QUOTA_SNAPSHOT_FILE"
t "an unparseable snapshot is unmeasured, not a wall" "unmeasured" "$(wstate walled)"

# --------------------------------------------- surface 1: agent list ---------
# shellcheck source=/dev/null
source src/cmd_agent.sh 2>/dev/null || true
if declare -f _agent_operational_state >/dev/null; then
  t "agent list: a walled account refuses to say ready" \
    "quota-exhausted" "$(_agent_operational_state active ok ok "" exhausted)"
  t "agent list: a clear account still says ready" \
    "ready"           "$(_agent_operational_state active ok ok "" clear)"
  t "agent list: an UNMEASURED account does not invent a wall" \
    "ready"           "$(_agent_operational_state active ok ok "" unmeasured)"
  t "agent list: a stopped unit still reports the unit, not the quota" \
    "inactive"        "$(_agent_operational_state inactive ok ok "" exhausted)"
  t "agent list: the wall outranks a degraded credential (it is the harder stop)" \
    "quota-exhausted" "$(_agent_operational_state active needs_login ok "" exhausted)"
else
  FAIL=$((FAIL+1)); printf 'FAIL: _agent_operational_state not sourceable\n'
fi

# ----------------------------------------------- surface 2: liveness ---------
# shellcheck source=/dev/null
source src/cmd_liveness.sh 2>/dev/null || true
if declare -f _liv_verdict >/dev/null; then
  t "liveness: the wall outranks a fresh artifact the seat wrote" \
    "quota-exhausted" "$(_liv_verdict 3 0 exhausted)"
  t "liveness: the wall outranks a broken probe set too" \
    "quota-exhausted" "$(_liv_verdict 0 2 exhausted)"
  t "liveness: a clear account leaves alive exactly as it was" \
    "alive"           "$(_liv_verdict 1 0 clear)"
  t "liveness: UNMEASURED must not suppress a real artifact" \
    "alive"           "$(_liv_verdict 1 0 unmeasured)"
  t "liveness: unmeasured leaves not-reached where it was" \
    "not-reached"     "$(_liv_verdict 0 1 unmeasured)"
  t "liveness: unmeasured leaves no-effect where it was" \
    "no-effect"       "$(_liv_verdict 0 0 unmeasured)"
  t "liveness: the default third argument cannot wall a seat" \
    "alive"           "$(_liv_verdict 1 0)"
else
  FAIL=$((FAIL+1)); printf 'FAIL: _liv_verdict not sourceable\n'
fi

# --------------------------------------------- surface 3: supervisor ---------
# shellcheck source=/dev/null
source src/cmd_supervisor.sh 2>/dev/null || true
if declare -f _sup_info_status >/dev/null; then
  WALL='account at 101% of its 7d limit — resets 2026-09-19T00:00:00Z'
  # armed=false, no tick, store readable, no open rows — the EXACT shape the
  # customer box was in when `supervisor` printed `healthy … 0 stalled / 0 stuck`
  # over a seat that could not spend a token.
  DARK=$(_sup_info_status false 0 0 "$NOW" "" "" "" 0 -1 true "$WALL")
  t "supervisor: the wall fires with the tick NOT ARMED" \
    "quota-exhausted" "$(jq -r '.classification' <<<"$DARK")"
  t "supervisor: and says the reading did not come from the tick" \
    "account-usage"   "$(jq -r '.cause' <<<"$DARK")"
  t "supervisor: the escalation verdict is set, so agent info cannot omit it" \
    "quota-exhausted" "$(jq -r '.verdict' <<<"$DARK")"
  t "supervisor: the state line names the wall" "yes" \
    "$(jq -r '.stateNote' <<<"$DARK" | grep -q '101% of its 7d limit' && printf yes || printf no)"
  t "supervisor: the supervisor line says it is not a tick reading" "yes" \
    "$(jq -r '.line' <<<"$DARK" | grep -q 'not from the supervisor tick' && printf yes || printf no)"

  # The DIVE-3880 downgrade must not be able to clear a measured wall: a pane
  # refusal whose deadline has passed says nothing about an account at 101% now.
  LAPSED=$(_sup_info_status true "$NOW" "$NOW" "$NOW" quota-exhausted quota-exhausted \
             "pane refusal, resume at 00:00" 4 0 true "$WALL")
  t "supervisor: a LAPSED pane refusal cannot clear a measured wall" \
    "quota-exhausted" "$(jq -r '.classification' <<<"$LAPSED")"

  NOWALL=$(_sup_info_status false 0 0 "$NOW" "" "" "" 0 -1 true "")
  t "supervisor: with no wall the unarmed box reads exactly as before" \
    "unobserved"      "$(jq -r '.classification' <<<"$NOWALL")"
  t "supervisor: and raises no verdict of its own" \
    "null"            "$(jq -r '.verdict' <<<"$NOWALL")"
  t "supervisor: the pre-existing unarmed line is unchanged" "yes" \
    "$(jq -r '.line' <<<"$NOWALL" | grep -q 'NOT ARMED' && printf yes || printf no)"
else
  FAIL=$((FAIL+1)); printf 'FAIL: _sup_info_status not sourceable\n'
fi

# ------------------------------------- 1b: the row outlives the mapping ------
# shellcheck source=/dev/null
source src/cmd_account.sh 2>/dev/null || true
if declare -f account_usage_recall >/dev/null; then
  mkdir -p "$AUTH_PROFILES_DIR/cm"
  # Same trap as the arm below: a bare `r` is a PARSEABLE military time zone,
  # not a nonsense string. Nothing here reads resetsAt, but the literal does not
  # stay in the file (DIVE-4372).
  LIVE=$(jq -cn '{fiveHour:{pct:0,resetsAt:"not-a-reset-time"}, sevenDay:{pct:101,resetsAt:"not-a-reset-time"},
                  asOf:1, source:"alex-dev", remembered:false}')
  account_usage_remember cm "$LIVE"
  t "1b: the account remembers its last reading" \
    "101" "$(account_usage_recall cm | jq -r '.sevenDay.pct')"
  t "1b: a remembered row names no live source (the seat has moved off)" \
    "null" "$(account_usage_recall cm | jq -r '.source')"
  t "1b: and is flagged remembered, so a reader can age it" \
    "true" "$(account_usage_recall cm | jq -r '.remembered')"
  t "1b: an account that never reported anything recalls null, not a zero" \
    "null" "$(account_usage_recall never-seen)"
  # The defect in one line: before this, an emptied profile printed `- - -`.
  t "1b: the remembered reading is still ABOVE the wall after the unbind" \
    "yes" "$( [[ "$(account_usage_recall cm | jq -r '.sevenDay.pct')" -ge 100 ]] && printf yes || printf no )"
  # Storing the measurement and not the classification: nothing in the persisted
  # record is a verdict, so a later reader can ask a different question of it.
  t "1b: the persisted record stores numbers, not a classification" \
    "no" "$(account_usage_recall cm | grep -qE '"(state|verdict|exhausted)"' && printf yes || printf no)"
else
  FAIL=$((FAIL+1)); printf 'FAIL: account_usage_recall not sourceable\n'
fi

# ---- iteration 3: A STALE OR SPENT READING IS NOT A MEASUREMENT OF NOW ------
# quinn's iteration-2 finding. `account usage` republishes a REMEMBERED reading
# stamped writtenAt=now, so the file's age said "fresh" about a number that was
# eleven days old, and the exhausted branch compared pct alone — a window that
# had already reset still printed as a wall, with its own past reset date next
# to it. Two fences close it: the reading is aged by its OWN asOf, and a reading
# whose window has already turned over is unmeasured. Both point at
# `unmeasured` — the direction this file exists to defend — never at `clear`.

# snap3 <asOfAgeSec> <resetsAt> <remembered:true|false> <sevenDayPct> — the
# published shape with the two fields the file's age cannot see.
snap3() {
  jq -cn --argjson at "$NOW" --argjson ao "$(( NOW - $1 ))" --arg r "$2" \
         --argjson rem "$3" --argjson s "$4" \
    '{writtenAt:$at, accounts:[{name:"walled", agents:["dev9"],
      usage:{fiveHour:{pct:1, resetsAt:$r}, sevenDay:{pct:$s, resetsAt:$r},
             asOf:$ao, source:(if $rem then null else "dev9" end),
             remembered:$rem}}]}' >"$QUOTA_SNAPSHOT_FILE"
}
wnote() { field 5 "$(quota_wall_account "$1")"; }

# quinn's fixture 1, verbatim: resetsAt 2020-01-01 at 101%, measured seconds ago.
snap3 5 "2020-01-01" false 101
t "a reading whose window already RESET is unmeasured, not a wall" \
  "unmeasured" "$(wstate walled)"
t "and it is certainly not clear" "no" \
  "$( [[ "$(wstate walled)" == "clear" ]] && printf yes || printf no )"
t "and the note says WHY, naming the reset it predates" "yes" \
  "$(wnote walled | grep -q 'predates its own reset' && printf yes || printf no)"
t "and no past date is handed to a surface to print" "" "$(field 3 "$(quota_wall_account walled)")"

# quinn's fixture 2, verbatim: remembered, measured eleven days ago, 101%.
snap3 "$(( 11 * 86400 ))" "2026-09-19T00:00:00Z" true 101
t "a REMEMBERED reading 11 days old is unmeasured, however fresh the file" \
  "unmeasured" "$(wstate walled)"
t "and not clear either" "no" \
  "$( [[ "$(wstate walled)" == "clear" ]] && printf yes || printf no )"
t "the note ages it by when it was MEASURED, not by when the file was written" "yes" \
  "$(wnote walled | grep -q 'MEASURED' && printf yes || printf no)"
t "and it says the number was recalled, so the operator knows what to refresh" "yes" \
  "$(wnote walled | grep -q 'recalled from the account record' && printf yes || printf no)"

# POSITIVE CONTROLS — the fences must not eat the alarm this row was filed for.
snap3 5 "2026-09-19T00:00:00Z" false 101
t "a FRESH reading with a future reset is still the wall" "exhausted" "$(wstate walled)"
t "and still carries the reset for the surfaces to print" \
  "2026-09-19T00:00:00Z" "$(field 3 "$(quota_wall_account walled)")"
# An "obviously invalid" literal is not a fact about date(1) — it is a guess.
# This arm was written with `r`, and GNU date reads a bare `r` as the RFC-822
# military time zone R (UTC+5): `date -d r` is midnight UTC+5 = 05:00Z TODAY,
# a REAL timestamp that is in the future before 05:00Z and in the past after,
# so this control passed all night and reddened every day from 05:00Z, on main,
# with no diff involved (DIVE-4372). So the fixture now PROVES its own premise
# first: if a future coreutils learns to parse the literal, the arm below fails
# loudly on the premise instead of silently becoming a clock-dependent flake.
UNPARSEABLE_RESET="not-a-reset-time"
t "the unparseable-reset fixture is genuinely unparseable by date(1)" "yes" \
  "$(date -d "$UNPARSEABLE_RESET" +%s >/dev/null 2>&1 && printf no || printf yes)"
snap3 5 "$UNPARSEABLE_RESET" false 101
t "an UNPARSEABLE reset does not discard a fresh measured wall" \
  "exhausted" "$(wstate walled)"
snap3 5 "" false 101
t "a reading with NO reset time at all is still the wall" "exhausted" "$(wstate walled)"

# The reading's age uses the same fence as the file's, and it is a real edge.
snap3 "$(( QUOTA_SNAPSHOT_MAX_AGE - 5 ))" "2026-09-19T00:00:00Z" false 101
t "a reading just INSIDE the freshness fence is measured" "exhausted" "$(wstate walled)"
snap3 "$(( QUOTA_SNAPSHOT_MAX_AGE + 5 ))" "2026-09-19T00:00:00Z" false 101
t "a reading just OUTSIDE it is unmeasured" "unmeasured" "$(wstate walled)"
t "the age reported is the READING's, not the file's" "yes" \
  "$( [[ "$(field 4 "$(quota_wall_account walled)")" -gt "$QUOTA_SNAPSHOT_MAX_AGE" ]] \
      && printf yes || printf no )"

# An undated reading: we cannot age it, so we do not get to call it anything.
jq -cn --argjson at "$NOW" '{writtenAt:$at, accounts:[{name:"walled",
  usage:{sevenDay:{pct:101, resetsAt:"2026-09-19T00:00:00Z"}}}]}' >"$QUOTA_SNAPSHOT_FILE"
t "a reading with no asOf is unmeasured, in either direction" \
  "unmeasured" "$(wstate walled)"
jq -cn --argjson at "$NOW" '{writtenAt:$at, accounts:[{name:"walled",
  usage:{sevenDay:{pct:12, resetsAt:"2026-09-19T00:00:00Z"}}}]}' >"$QUOTA_SNAPSHOT_FILE"
t "an undated reading BELOW the wall is also unmeasured, never clear" \
  "unmeasured" "$(wstate walled)"

# The reset guard is scoped to the exhausted branch: a below-the-wall reading
# with a stale reset string is still a measurement, and still clear.
snap3 5 "2020-01-01" false 12
t "a past reset on a CLEAR reading changes nothing" "clear" "$(wstate walled)"

# --------------------------------------------------- MUTATION CONTROL --------
# A stub-substituting arm is vacuous. Cut the named term out of the SHIPPING
# function's own text and prove the cut landed, then prove the suite turns red.
if declare -f _liv_verdict >/dev/null; then
  MUT=$(declare -f _liv_verdict | sed 's/"exhausted"/"__never__"/')
  t "mutation: the cut landed in the shipping function text" "yes" \
    "$(grep -q '__never__' <<<"$MUT" && printf yes || printf no)"
  eval "$MUT"
  t "mutation: with the wall term cut, a walled seat falls back to alive" \
    "alive" "$(_liv_verdict 1 0 exhausted)"
  # restore
  # shellcheck source=/dev/null
  source src/cmd_liveness.sh 2>/dev/null || true
  t "mutation: restored — the wall outranks the artifact again" \
    "quota-exhausted" "$(_liv_verdict 1 0 exhausted)"
fi

# Same discipline for the two iteration-3 fences: cut the named term out of the
# SHIPPING function's own text, prove the cut landed, and show the fixture goes
# back to the laundered `exhausted` quinn measured.
snap3 5 "2020-01-01" false 101
MUTR=$(declare -f quota_wall_reset_guard | sed 's/(( rts < now ))/(( rts < 0 ))/')
t "mutation: the reset-guard cut landed in the shipping function text" "yes" \
  "$(grep -q 'rts < 0' <<<"$MUTR" && printf yes || printf no)"
eval "$MUTR"
t "mutation: without the reset guard the past-reset reading is a wall again" \
  "exhausted" "$(wstate walled)"
# shellcheck source=/dev/null
source src/lib/quota_wall.sh
t "mutation: restored — the spent window is unmeasured again" \
  "unmeasured" "$(wstate walled)"

snap3 "$(( 11 * 86400 ))" "2026-09-19T00:00:00Z" true 101
MUTA=$(declare -f quota_wall_account | sed 's/\$readage > \$maxage/$readage > 99999999999/')
t "mutation: the asOf-fence cut landed in the shipping function text" "yes" \
  "$(grep -q '99999999999' <<<"$MUTA" && printf yes || printf no)"
t "mutation: and the original comparison is gone from the mutant" "no" \
  "$(grep -q 'readage > \$maxage' <<<"$MUTA" && printf yes || printf no)"
eval "$MUTA"
t "mutation: without the reading fence an 11-day-old number is a wall again" \
  "exhausted" "$(wstate walled)"
# shellcheck source=/dev/null
source src/lib/quota_wall.sh
t "mutation: restored — the recalled number is unmeasured again" \
  "unmeasured" "$(wstate walled)"

# ------------- surface 1, PRODUCTION path: the embedded python shaper --------
# `agent list` does NOT run the bash reference path in production — it runs the
# Python shaper embedded between the __5DIVE_AGENT_LIST_PY__ markers (DIVE-4100),
# extracted and executed by the privileged helper. Grading only the bash twin
# would grade a path no box takes, so this arm executes the SHIPPING python text
# with /usr/bin/systemctl stubbed to report the unit active — the only condition
# under which the quota branch can be reached at all.
PYSRC="$TMP/shaper.py"
awk '/^# __5DIVE_AGENT_LIST_PY_BEGIN__$/{e=1;next} /^# __5DIVE_AGENT_LIST_PY_END__$/{exit} e' \
  src/cmd_agent.sh >"$PYSRC"
t "shaper: the marked block was extracted" "yes" \
  "$( [[ -s "$PYSRC" ]] && printf yes || printf no )"

mkdir -p "$TMP/reg"
printf '{"agents":{"dev9":{"type":"claude","authProfile":"walled","workdir":"/tmp"}}}\n' >"$TMP/reg/agents.json"

# shaper_state <sevenDayPct|absent> -> "<operationalState>|<quota.state>"
shaper_state() {
  local pct="$1" aoage="${2:-0}" reset="${3:-r}" rem="${4:-false}"
  if [[ "$pct" == "absent" ]]; then
    rm -f "$QUOTA_SNAPSHOT_FILE"
  else
    jq -cn --argjson at "$NOW" --argjson ao "$(( NOW - aoage ))" --argjson s "$pct" \
           --arg r "$reset" --argjson rem "$rem" \
      '{writtenAt:$at, accounts:[{name:"walled", agents:["dev9"],
        usage:{fiveHour:{pct:1,resetsAt:$r}, sevenDay:{pct:$s,resetsAt:$r},
               asOf:$ao, source:"dev9", remembered:$rem}}]}' >"$QUOTA_SNAPSHOT_FILE"
  fi
  shaper_run
}

# shaper_run — execute the extracted shipping shaper against whatever snapshot
# is on disk, and print "<operationalState>|<quota.state>".
shaper_run() {
  QUOTA_SNAPSHOT_FILE="$QUOTA_SNAPSHOT_FILE" SHAPER="$PYSRC" \
  REGP="$TMP/reg/agents.json" PROFD="$AUTH_PROFILES_DIR" python3 - <<'PYEOF'
import json, os, subprocess, sys, io

real_run = subprocess.run
def fake_run(cmd, *a, **kw):
    # Report every agent unit ACTIVE and ENABLED; everything else is left alone.
    if isinstance(cmd, (list, tuple)) and cmd and str(cmd[0]).endswith("systemctl"):
        units = [c for c in cmd if str(c).endswith(".service")]
        # The shaper runs systemctl with text=True, so stdout is a str here.
        out = "\n\n".join(
            "Id=%s\nActiveState=active\nUnitFileState=enabled" % u for u in units)
        class R:  # the shaper reads .returncode and .stdout only
            returncode = 0
            stdout = out
        return R()
    return real_run(cmd, *a, **kw)
subprocess.run = fake_run

sys.argv = ["shaper", os.environ["REGP"], os.environ["PROFD"],
            os.environ["PROFD"], "/home", "/etc/sudoers.d", "/tmp"]
buf = io.StringIO()
_stdout = sys.stdout
sys.stdout = buf
exec(compile(open(os.environ["SHAPER"]).read(), "shaper", "exec"), {"__name__": "__main__"})
sys.stdout = _stdout
rows = json.loads(buf.getvalue())
r = rows[0]
print("%s|%s" % (r["operationalState"], r["health"]["quota"]["state"]))
PYEOF
}

SH_WALL=$(shaper_state 101)
t "shaper (PRODUCTION path): an ACTIVE unit on a walled account is NOT ready" \
  "quota-exhausted|exhausted" "$SH_WALL"
# The BASELINE for this fixture is `unknown` (no credential file, no startup
# breadcrumb) — which is what makes the arm above load-bearing: the walled run
# and these two runs differ in the snapshot and in nothing else, so
# `quota-exhausted` above can only have come from the join.
SH_CLEAR=$(shaper_state 40)
t "shaper: the same active unit below the wall keeps its baseline verdict" \
  "unknown|clear" "$SH_CLEAR"
SH_NONE=$(shaper_state absent)
t "shaper: with no snapshot the quota is UNMEASURED and the verdict is untouched" \
  "unknown|unmeasured" "$SH_NONE"
t "shaper: the ONLY difference between the walled run and its controls is the snapshot" \
  "yes" "$( [[ "$SH_WALL" == "quota-exhausted|exhausted" && "$SH_CLEAR" != quota-exhausted* \
              && "$SH_NONE" != quota-exhausted* ]] && printf yes || printf no )"

# The two iteration-3 fences on the PRODUCTION path too — the shaper carries its
# own copy of the join (it cannot source bash), so a fix landed only in
# src/lib/quota_wall.sh would leave `agent list` laundering on every box.
SH_PAST=$(shaper_state 101 5 "2020-01-01" false)
t "shaper (PRODUCTION path): a reading past its own reset is unmeasured" \
  "unknown|unmeasured" "$SH_PAST"
SH_OLD=$(shaper_state 101 "$(( 11 * 86400 ))" "2026-09-19T00:00:00Z" true)
t "shaper (PRODUCTION path): an 11-day-old remembered reading is unmeasured" \
  "unknown|unmeasured" "$SH_OLD"
SH_FRESH=$(shaper_state 101 5 "2026-09-19T00:00:00Z" false)
t "shaper: and a fresh reading with a future reset is STILL the wall" \
  "quota-exhausted|exhausted" "$SH_FRESH"
t "shaper: neither fenced run says ready and neither says clear" "yes" \
  "$( [[ "$SH_PAST" != *"quota-exhausted"* && "$SH_PAST" != *"|clear"* \
        && "$SH_OLD" != *"quota-exhausted"* && "$SH_OLD" != *"|clear"* ]] \
      && printf yes || printf no )"
SH_NOWIN=$(jq -cn --argjson at "$NOW" '{writtenAt:$at, accounts:[{name:"walled",
  usage:{fiveHour:null, sevenDay:null, asOf:$at, remembered:false}}]}' \
  >"$QUOTA_SNAPSHOT_FILE"; shaper_run)
t "shaper: an account reporting NEITHER window is unmeasured, not clear" \
  "unknown|unmeasured" "$SH_NOWIN"

# MUTATION CONTROL, production path: cut each fence out of the SHIPPING shaper's
# own text and prove the fixture launders again — the arms above are only worth
# their runtime if their absence is red.
PYORIG="$PYSRC"; PYMUT="$TMP/shaper-mut.py"
sed 's/reset_ts is not None and reset_ts < now/reset_ts is not None and reset_ts < 0/' \
  "$PYORIG" >"$PYMUT"
t "shaper mutation: the reset-guard cut landed in the shipping text" "yes" \
  "$(grep -q 'reset_ts < 0' "$PYMUT" && printf yes || printf no)"
t "shaper mutation: and the original comparison is gone from the mutant" "no" \
  "$(grep -q 'reset_ts < now' "$PYMUT" && printf yes || printf no)"
PYSRC="$PYMUT"; SH_MUT1=$(shaper_state 101 5 "2020-01-01" false); PYSRC="$PYORIG"
t "shaper mutation: without the guard the past-reset reading is a wall again" \
  "quota-exhausted|exhausted" "$SH_MUT1"

sed 's/if read_age > QUOTA_MAX_AGE:/if read_age > 99999999999:/' "$PYORIG" >"$PYMUT"
t "shaper mutation: the reading-age cut landed in the shipping text" "yes" \
  "$(grep -q 'read_age > 99999999999' "$PYMUT" && printf yes || printf no)"
PYSRC="$PYMUT"
SH_MUT2=$(shaper_state 101 "$(( 11 * 86400 ))" "2026-09-19T00:00:00Z" true)
PYSRC="$PYORIG"
t "shaper mutation: without it an 11-day-old number is a wall again" \
  "quota-exhausted|exhausted" "$SH_MUT2"
t "shaper: restored — the past-reset fixture is unmeasured again" \
  "unknown|unmeasured" "$(shaper_state 101 5 "2020-01-01" false)"

printf '\nquota_wall_health_surfaces_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
