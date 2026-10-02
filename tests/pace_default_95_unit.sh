#!/usr/bin/env bash
# DIVE-5364 unit: the shipped pacing default is 95/95, and a blind meter holds
# nothing.
#
# THE INCIDENT. 2026-10-01, a 12-seat distribution team on a customer box: every
# recurring slot from 07:00Z to 16:30Z logged "NOT fired — pacing floor soft …
# blind meter, policy=soft". The meter was blind BECAUSE the team was idle (the
# only current reading comes from a seat active in the last 600s), the
# remembered reading was 63%, and `task ls --recurring` showed `last_skipped -`
# all day. lodar, 2026-10-02: "pacing shouldnt be so aggressive … default 95%".
#
# WHAT IS ASSERTED HERE, all on a box with NO pace_week in box.json and NO
# FIVE_PACE_* in the environment — the shipped defaults, nothing else:
#   P1. The incident fixture (blind meter, remembered bound 63%) is band 0 — and a
#       medium recurring slot FIRES through the real materializer + real floor.
#   P2. 94% runs, 96% is urgent-only, and a blind meter whose remembered bound is
#       96% is urgent-only too: the bound is the one thing still able to tighten.
#   P3. `5dive config` prints `pace-week = 95/95 (default)`.
#   P4. The digest agrees: a blind account is NOT rendered as a hold, 96% is.
#   N.  NEGATIVE CONTROL. The same fixtures against a copy of the floor with the
#       three pre-5364 defaults put back (60/90, FIVE_PACE_BLIND default soft):
#       P1 returns 2 and the slot is "NOT fired". If this arm passes against
#       the shipping source, the fixture is not testing the change.
# The 60/90 + soft mechanics are graded, pinned explicitly, in
# tests/pace_the_week_unit.sh.
# Run: bash tests/pace_default_95_unit.sh (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pace-95.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

# The shipped defaults and nothing else: scratch box file with no pace keys, no
# pace env, scratch reading cache (never the live host's).
unset FIVE_PACE_7D_SOFT FIVE_PACE_7D_HARD FIVE_PACE_5H FIVE_PACE_BLIND FIVE_PACE_UNMETERED
export BOX_CONFIG="$TMP/box.json"; printf '{}\n' >"$BOX_CONFIG"
export FIVE_PACE_READING_CACHE_DIR="$TMP/pace-reading"

SRC=src
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/verify_policy.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_heartbeat.sh cmd_box_config.sh; do
  source "$SRC/$f"
done
set +e   # header.sh enabled `set -e`; the arms below deliberately probe non-zero bands
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; tasks_db_init
LOG="$TMP/log"; : >"$LOG"
_hb_log() { printf '%s\n' "$*" >>"$LOG"; }
require_root() { return 0; }

NOW=$(date -u +%s)
FAR=$(( NOW + 5*86400 ))   # 5 days to the reset — no near-reset relaxation anywhere
US=$'\037'
CUR=""; BOUND=""
cur_stub()   { [[ -n "$CUR" ]] && printf '%s%s%s' "$CUR" "$US" "$FAR"; return 0; }
bound_stub() { [[ -n "$BOUND" ]] && printf '%s%s%s' "$BOUND" "$US" "$FAR"; return 0; }
# The seat document for a quiet team: the account's seats carry no reading.
BLIND_DOC='{"agents":[{"name":"s1","account":"mark","sevenDayPct":null,"fiveHourPct":null}]}'

load_floor() {  # <grader_pool file> — (re)source the floor and point it at the stubs
  # shellcheck disable=SC1090
  source "$1"
  _PACE_ACCOUNT_CMD=cur_stub
  _PACE_ACCOUNT_BOUND_CMD=bound_stub
  _PACE_WINDOW_CAPABLE_CMD=true     # a claude account: blind means blind, not unmeterable
}
band7() {  # <cur-pct|""> <bound-pct|""> -> rc of _pace_band_7d on the blind doc
  local rc=0; CUR="$1"; BOUND="$2"
  _pace_band_7d mark "$NOW" <<<"$BLIND_DOC" >/dev/null || rc=$?
  printf '%s' "$rc"
}
# One medium recurring template due now, assigned to a seat on account `mark`,
# driven through the REAL materializer with the REAL floor. -> "fired" | "held"
slot() {  # <cur-pct|""> <bound-pct|""> <title>
  local tid n
  CUR="$1"; BOUND="$2"
  tid=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, schedule, status)
            VALUES ($(sqlq "$3"), '', 'medium', 's1', 'main', 'recurring', '* * * * *', 'todo');
            SELECT last_insert_rowid();")
  rm -f "$(_hb_mz_last_pass_file)"; : >"$LOG"
  ( _HB_PACE_USAGE="$BLIND_DOC"
    registry_read() { printf '{"agents":{"s1":{"authProfile":"mark"}}}'; }
    _hb_materialize_recurring "$NOW" )
  n=$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id=${tid};")
  db "UPDATE tasks SET status='cancelled' WHERE id=${tid} OR from_template_id=${tid};" >/dev/null
  if [[ "$n" == 1 ]]; then printf 'fired'; else printf 'held'; fi
}

# ── P1–P3 on the shipping source ─────────────────────────────────────────────
load_floor src/task/grader_pool.sh

got=$(band7 "" 63)
[[ "$got" == 0 ]] && ok_ "P1: the 10-01 fixture (blind meter, remembered 63%) is band 0 — not held" \
  || bad_ "P1: blind + bound 63" "band $got, want 0"
v=$(CUR=""; BOUND=63; _pace_band_7d mark "$NOW" <<<"$BLIND_DOC")
[[ "$v" == *"blind meter"* && "$v" == *"not held (FIVE_PACE_BLIND=open)"* ]] \
  && ok_ "P1: the verdict still says BLIND (never 0%) and names the open policy" \
  || bad_ "P1: verdict" "$v"
rc=0; _pace_band mark "$NOW" <<<"$BLIND_DOC" >/dev/null || rc=$?
[[ "$rc" == 0 ]] && ok_ "P1: the combined floor (_pace_band, week + 5h) is open too" \
  || bad_ "P1: combiner" "band $rc, want 0"
got=$(slot "" 63 "P1 medium beat")
[[ "$got" == fired ]] && grep -q "fired -> new standard todo" "$LOG" \
  && ok_ "P1: a MEDIUM recurring slot FIRES through the real materializer" \
  || bad_ "P1: slot" "$got — log: $(tr '\n' ' ' <"$LOG")"

for probe in "60 0" "90 0" "94 0" "95 3" "96 3" "100 3"; do
  read -r pct want <<<"$probe"
  got=$(band7 "$pct" "")
  [[ "$got" == "$want" ]] && ok_ "P2: 7d=${pct}% -> band ${want}" || bad_ "P2: 7d=${pct}%" "band $got, want $want"
done
got=$(band7 "" 96)
[[ "$got" == 3 ]] && ok_ "P2: a blind meter with a remembered 96% is urgent-only — the bound still tightens" \
  || bad_ "P2: blind + bound 96" "band $got, want 3"
got=$(band7 "" "")
[[ "$got" == 0 ]] && ok_ "P2: a blind meter with no bound at all is open" || bad_ "P2: blind, no bound" "band $got, want 0"
rc=0; _pace_admits 3 urgent standard || rc=$?; rc2=0; _pace_admits 3 high standard || rc2=$?
[[ "$rc" == 0 && "$rc2" == 1 ]] && ok_ "P2: at 95% urgent work runs and high work waits" \
  || bad_ "P2: admits at hard" "urgent=$rc high=$rc2"
got=$(slot 96 "" "P2 medium beat at 96")
[[ "$got" == held ]] && grep -q "NOT fired — pacing floor hard on mark" "$LOG" \
  && ok_ "P2: at 96% the medium recurring slot is held and says so" \
  || bad_ "P2: slot at 96" "$got — log: $(tr '\n' ' ' <"$LOG")"

out=$(JSON_MODE=0 cmd_box_config 2>&1)
[[ "$out" == *"pace-week = 95/95 (default)"* ]] && ok_ "P3: 5dive config prints pace-week = 95/95 from the default" \
  || bad_ "P3: config show" "$(grep pace <<<"$out")"
[[ "$(_pace_week_effective)" == 95/95 ]] && ok_ "P3: the effective week is 95/95" || bad_ "P3: effective" "$(_pace_week_effective)"

# ── P4: the digest renders what the tick applies ─────────────────────────────
DPROBE="$TMP/dprobe.py"
cat >"$DPROBE" <<'PYEOF'
import json, os, sys, time
src = open(sys.argv[1]).read()
start = src.index('_pace_week = (os.environ.get("DIGEST_PACE_WEEK") or "").strip()')
end = src.index('paced = [p for p in pace_l if p["band"] != "open"]')
block = src[start:end]
def to_epoch(v): return None
now = int(time.time())
out = {}
for p in sys.argv[2].split(","):
    pct = None if p == "null" else int(p)
    ns = {"os": os, "time": time, "to_epoch": to_epoch, "acct_snap": {}, "_unmet": {},
          "agents": [{"name": "s1", "account": "mark", "sevenDayPct": pct,
                      "sevenDayResetsAt": now + 5*86400}]}
    exec(block, ns)
    out[p] = ns["pace_l"][0]["band"]
print(json.dumps(out))
PYEOF
dg=$(DIGEST_PACE_WEEK="$(_pace_week_effective)" python3 "$DPROBE" src/cmd_digest.sh "null,94,96" 2>&1)
[[ "$dg" == '{"null": "open", "94": "open", "96": "hard"}' ]] \
  && ok_ "P4: the digest renders a blind account as open (no 'Pacing floor BLIND' hold), 94% open, 96% hard" \
  || bad_ "P4: digest" "$dg"
dg=$(FIVE_PACE_BLIND=soft DIGEST_PACE_WEEK=95/95 python3 "$DPROBE" src/cmd_digest.sh "null" 2>&1)
[[ "$dg" == '{"null": "blind"}' ]] && ok_ "P4: FIVE_PACE_BLIND=soft still renders the blind hold (opt-in kept)" \
  || bad_ "P4: digest soft opt-in" "$dg"

# ── N: NEGATIVE CONTROL — the pre-5364 defaults put back ─────────────────────
MUT="$TMP/grader_pool.pre5364.sh"
sed -e 's|^_PACE_DEFAULT_7D_SOFT=95$|_PACE_DEFAULT_7D_SOFT=60|' \
    -e 's|^_PACE_DEFAULT_7D_HARD=95$|_PACE_DEFAULT_7D_HARD=90|' \
    -e 's|^_PACE_BLIND="${FIVE_PACE_BLIND:-open}"$|_PACE_BLIND="${FIVE_PACE_BLIND:-soft}"|' \
    src/task/grader_pool.sh >"$MUT"
nchg=$(diff src/task/grader_pool.sh "$MUT" | grep -c '^>')
if [[ "$nchg" != 3 ]]; then
  bad_ "N: the pre-5364 mutant did not apply" "$nchg of 3 lines changed — the defaults moved; re-aim the sed"
else
  # Under 60/90 a remembered 63% is over the soft floor, so main holds it through
  # the BOUND branch ("at LEAST 63%").
  ( load_floor "$MUT"
    got=$(band7 "" 63)
    s=$(slot "" 63 "N medium beat")
    [[ "$got" == 2 && "$s" == held ]] && grep -q "NOT fired — pacing floor soft on mark" "$LOG" ) \
    && ok_ "N: CONTROL — with the pre-5364 defaults the P1 fixture (blind + remembered 63%) is band 2 and the slot is NOT fired" \
    || bad_ "N: CONTROL bound" "the pre-5364 defaults did not hold the P1 fixture — P1 is not testing the change"
  # With no usable bound (the 10-01 box: its remembered reading never reached the
  # floor) main holds through the BLIND branch — the incident's exact log line.
  ( load_floor "$MUT"
    got=$(band7 "" "")
    s=$(slot "" "" "N medium beat, no bound")
    [[ "$got" == 2 && "$s" == held ]] && grep -q "NOT fired — pacing floor soft on mark.*blind meter, policy=soft" "$LOG" ) \
    && ok_ "N: CONTROL — with the pre-5364 defaults a blind meter with no bound is band 2 and logs the 10-01 line (blind meter, policy=soft)" \
    || bad_ "N: CONTROL blind" "the pre-5364 defaults did not reproduce the 10-01 blind hold"
fi

echo "-- ${PASS} passed, ${FAIL} failed --"
[[ $FAIL -eq 0 ]]
