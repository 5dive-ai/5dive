#!/usr/bin/env bash
# CNCL-23 schedule E2E — proves `5dive council schedule {add,ls,show,rm,run}` are REACHABLE
# through the real BASH dispatcher (src/cmd_council.sh) on the BUILT binary, and that the
# deterministic RUNNER generalizes the CNCL-21/22 ops scripts correctly:
#   - config CRUD round-trips (add -> ls -> show -> rm) with fail-closed on unknown,
#   - add emits the managed crontab line (tested with --no-cron so the harness NEVER mutates
#     a real user crontab) and does NOT install it,
#   - `run` parses `ACTION:` lines from the sealed verdict and files up to maxActions
#     `--from=council` board tasks (isolated TASKS_DB), citing the sealedDigest,
#   - an INQUORATE / FAILED envelope files NOTHING (CNCL-18 signal) and still exits 0,
#   - --dry prints the task-adds instead of filing.
# The convene itself is stubbed via SCHED_PARSE_TEST=<fixture envelope> (mirrors the ops
# scripts' STANDUP_PARSE_TEST) so the runner is exercised offline with zero network / no seat
# dispatch. Builds a throwaway ./5dive (BUILD_OUT) so it GATES in CI; SKIPs green if it can't
# build or node/jq are missing. Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council schedule e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
# Put the built binary on PATH as `5dive` so the runner's internal `5dive task add` resolves to
# it, and isolate BOTH the state dir and the task board so we never touch anything live.
mkdir -p "$TMP/bin"; ln -sf "$FIVE" "$TMP/bin/5dive"
export PATH="$TMP/bin:$PATH"
export STATE_DIR="$TMP" TASKS_DIR="$TMP" TASKS_DB="$TMP/tasks.db"
# CNCL-23: run artifacts are PER-USER (the runner fires from a non-root cron that cannot write the
# root-owned ${STATE_DIR}/council). Point the override at a temp dir so the harness never writes the
# real $HOME/.5dive, and so we can assert the run OUTPUT is decoupled from the config dir.
export FIVEDIVE_SCHED_RUNS="$TMP/runs"
# schedule add/rm write schedules.json into ${STATE_DIR}/council — in prod that dir is created
# (root-owned) by `sudo council init`; here we pre-create it writable to stand in for that (a non-root
# add against a MISSING/unwritable council dir correctly refuses with a sudo hint, tested elsewhere).
mkdir -p "$STATE_DIR/council"

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }
has(){ case "$2" in *"$3"*) P=$((P+1)) ;; *) F=$((F+1)); echo "FAIL: $1 (missing '$3' in: $2)" ;; esac; }

# --- routing: `schedule` reaches the dispatcher, not "unknown council command" ---
LS0="$(5dive council schedule ls 2>&1 || true)"
case "$LS0" in *"unknown council command"*) chk "schedule is routed" routed unknown ;; *) chk "schedule is routed" routed routed ;; esac

# --- add (--no-cron so we never mutate a real crontab). Assert cronLine + not installed. ---
ADD="$(5dive --json council schedule add standup \
  --question='Daily standup {{date}}. Context:{{context}}' \
  --cron='20 1 * * *' --mode=quick --max-actions=2 --ballot-deadline=1500 \
  --context-cmd='printf FUNNEL42' --no-cron 2>/dev/null)"
chk "add ok" "true" "$(echo "$ADD" | jq -r .ok)"
chk "add cronInstalled=false with --no-cron" "false" "$(echo "$ADD" | jq -r .data.cronInstalled)"
has "add emits the managed cron line" "$(echo "$ADD" | jq -r .data.cronLine)" "council schedule run standup"
has "add cron line carries the marker" "$(echo "$ADD" | jq -r .data.cronLine)" "# 5dive-council-schedule:standup"

# --- ls / show round-trip ---
LS="$(5dive --json council schedule ls 2>/dev/null)"
chk "ls has one schedule" "1" "$(echo "$LS" | jq -r '.data.schedules | length')"
chk "ls bench defaults to council" "council" "$(echo "$LS" | jq -r '.data.schedules[0].bench')"
SHOW="$(5dive --json council schedule show standup 2>/dev/null)"
chk "show maxActions round-trips" "2" "$(echo "$SHOW" | jq -r '.data.maxActions')"
chk "show contextCmd round-trips" "printf FUNNEL42" "$(echo "$SHOW" | jq -r '.data.contextCmd')"

# --- build a QUORATE fixture envelope with 3 ACTION lines (maxActions=2 caps filing at 2) ---
FIX="$TMP/env-quorate.json"
cat > "$FIX" <<'JSON'
{"ok":true,"data":{"sealedDigest":"deadbeefcafe","verdict":{"quorumMet":true,"votesCast":5,"recommendation":"approve"},
"votes":[
 {"seat":"main","vote":"approve","rationale":"looks good. ACTION: Ship the pricing page"},
 {"seat":"olivia","vote":"approve","rationale":"agree. ACTION: Draft the launch tweet"},
 {"seat":"dev","vote":"approve","rationale":"fine. ACTION: Add a healthcheck endpoint"}
]}}
JSON

# --- run with the fixture: files exactly maxActions(=2) --from=council tasks citing the digest ---
RUN="$(SCHED_PARSE_TEST="$FIX" 5dive --json council schedule run standup 2>/dev/null)"
chk "run quorate=true" "true" "$(echo "$RUN" | jq -r .data.quorate)"
chk "run caps actionsFiled at maxActions(2)" "2" "$(echo "$RUN" | jq -r .data.actionsFiled)"
BOARD="$(5dive --json task ls 2>/dev/null)"
chk "board has exactly 2 council tasks" "2" "$(echo "$BOARD" | jq -r '[.data.tasks[] | select(.created_by=="council")] | length')"
has "first ACTION became a task" "$(echo "$BOARD" | jq -r '.data.tasks[].title')" "Ship the pricing page"
has "task body cites the sealed receipt digest" "$(echo "$BOARD" | jq -r '.data.tasks[].body' | tr '\n' ' ')" "deadbeefcafe"
# the 3rd ACTION must NOT have been filed (over the cap)
NOPE="$(echo "$BOARD" | jq -r '[.data.tasks[] | select(.title=="Add a healthcheck endpoint")] | length')"
chk "over-cap ACTION not filed" "0" "$NOPE"

# --- run artifacts land in the PER-USER override dir, NOT under the (root-owned in prod) config dir ---
[ -f "$TMP/runs/standup-$(date -u +%F).json" ] && chk "run envelope written to FIVEDIVE_SCHED_RUNS" yes yes || chk "run envelope written to FIVEDIVE_SCHED_RUNS" yes no
[ -f "$TMP/runs/standup.log" ] && chk "run log written to FIVEDIVE_SCHED_RUNS" yes yes || chk "run log written to FIVEDIVE_SCHED_RUNS" yes no
[ ! -e "$TMP/council/schedule-runs" ] && chk "no artifacts under the config dir (decoupled)" yes yes || chk "no artifacts under the config dir (decoupled)" yes no

# --- DECOUPLING PROOF: the runner fires even when the config dir is NON-writable (the prod repro:
#     root-owned COUNCIL_DIR + a non-root cron runner). Config was already written above; make it
#     read-only and confirm run still reads config + parses ACTIONs + writes artifacts to the
#     per-user path. Uses --dry so it does not pollute the board count the later asserts depend on. ---
chmod a-w "$TMP/council" 2>/dev/null
DRY_RO="$(SCHED_PARSE_TEST="$FIX" 5dive council schedule run standup --dry 2>/dev/null)"; RC_RO=$?
chmod u+w "$TMP/council" 2>/dev/null   # restore for trap cleanup
chk "run fires with a NON-writable config dir (exit 0)" "0" "$RC_RO"
has "read-only config dir: still reads config + parses ACTIONs" "$DRY_RO" "DRY: 5dive task add"

# --- inquorate fixture: files NOTHING, still exits 0 (CNCL-18 signal) ---
FIX2="$TMP/env-inq.json"
cat > "$FIX2" <<'JSON'
{"ok":true,"data":{"sealedDigest":"aa11","verdict":{"quorumMet":false,"votesCast":1,"recommendation":null},"votes":[{"seat":"main","vote":"approve","rationale":"ACTION: should not be filed"}]}}
JSON
RUN2="$(SCHED_PARSE_TEST="$FIX2" 5dive --json council schedule run standup 2>/dev/null)"; RC2=$?
chk "inquorate run exits 0" "0" "$RC2"
chk "inquorate run quorate=false" "false" "$(echo "$RUN2" | jq -r .data.quorate)"
AFTER="$(5dive --json task ls 2>/dev/null | jq -r '[.data.tasks[] | select(.created_by=="council")] | length')"
chk "inquorate filed nothing (still 2 total)" "2" "$AFTER"

# --- --dry prints the task-adds instead of filing ---
DRY="$(SCHED_PARSE_TEST="$FIX" 5dive council schedule run standup --dry 2>/dev/null)"
has "dry prints a DRY task-add line" "$DRY" "DRY: 5dive task add"
DRYCOUNT="$(5dive --json task ls 2>/dev/null | jq -r '[.data.tasks[] | select(.created_by=="council")] | length')"
chk "dry filed nothing (still 2 total)" "2" "$DRYCOUNT"

# --- rm removes config + fails closed on unknown ---
chk "rm ok" "0" "$(5dive council schedule rm standup >/dev/null 2>&1; echo $?)"
chk "ls empty after rm" "0" "$(5dive --json council schedule ls 2>/dev/null | jq -r '.data.schedules | length')"
5dive council schedule rm ghost >/dev/null 2>&1; chk "rm unknown fails closed (exit 3)" "3" "$?"

echo "CNCL-23 schedule E2E: $P passed, $F failed"
[ "$F" -eq 0 ]
