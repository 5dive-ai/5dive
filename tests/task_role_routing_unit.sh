#!/usr/bin/env bash
# TIER: core — 3.1s measured on the dev VM 2026-08-13 (DIVE-3366). Isolated
# unit harness for role-based routing at FILING time: least-loaded resolution of
# `--assignee=role:<r>` when a role has two or more seats, the audit trail that
# records which counts chose the lane, the lane-skew note on the board, the
# grading/building split that keeps that note from being misread, and the roster
# filter on the WIP-cap redirect's suggestions.
#
# Same isolation contract as the other task harnesses: source src/ directly and
# point STATE_DIR at a throwaway temp dir, so the live shared tasks.db is NEVER
# touched. A REGISTRY FIXTURE IS WRITTEN, deliberately: `_task_roster` reads
# ${STATE_DIR}/agents.json, and with no registry the roster is
# `unestablished:no-registry-file`, under which every roster filter in here is
# SKIPPED BY DESIGN (a roster we could not establish must narrow nothing). A
# harness with no registry would therefore green the two roster arms without
# executing them — the arm proving the filter is what asserts the fixture is live.
# Run: bash tests/task_role_routing_unit.sh   (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-role-routing.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()  { jq -r "$1" 2>/dev/null; }

tasks_db_init

# THE ROSTER IS SEEDED AS A REGISTRY FILE, not through `agent create`: the guards
# under test read agent-ness from the registry (DIVE-3344's "the authority is the
# registry"), and a fixture has no business provisioning a fleet to get a name.
cat >"$STATE_DIR/agents.json" <<'JSON'
{"agents":{"quinn":{},"main2":{},"dev9":{},"bob":{}}}
JSON

# DIVE-2124: seed the chart directly — `org set` is root-only, and these arms are
# about routing, not authz.
org_seed() {  # <name> --role=x
  local n="$1"; shift
  local role=""
  for a in "$@"; do case "$a" in --role=*) role="${a#*=}" ;; esac; done
  db "INSERT OR IGNORE INTO agents_org (name) VALUES ($(sqlq "$n"));"
  [[ -n "$role" ]] && db "UPDATE agents_org SET role=$(sqlq "$role") WHERE name=$(sqlq "$n");"
  return 0
}

# TWO seats on one role — the whole subject of DIVE-3366. `_org_resolve_assignee`
# returns EMPTY here (COUNT != 1), which before this change was a hard refusal at
# `task add`, which is what pushed filers back to typing the name they remember.
org_seed quinn --role=verifier
org_seed main2 --role=verifier
org_seed dev9  --role=builder

# Load quinn up and leave main2 idle: the measured 2026-08-13 shape, scaled down.
seed_row() {  # <assignee> <n> [verifier] [maker]
  local who="$1" n="$2" v="${3:-}" m="${4:-}" i
  for (( i = 0; i < n; i++ )); do
    db "INSERT INTO tasks (title,status,assignee,kind,priority,verifier,maker_agent,created_at)
        VALUES ('seeded ${who} ${i}','todo',$(sqlq "$who"),'standard','medium',
                $([[ -n "$v" ]] && sqlq "$v" || echo NULL),
                $([[ -n "$m" ]] && sqlq "$m" || echo NULL),
                datetime('now'));"
  done
}
seed_row quinn 6

# ---------------------------------------------------------------------------
# A1 (acceptance 1) — role:<r> with TWO holders RESOLVES, to the idler seat.
# ---------------------------------------------------------------------------
JSON_MODE=1
out=$( (cmd_task_add --assignee=role:verifier --no-verify -- "route me by load") 2>"$TMP"/a1.err )
rc=$?
a1_id=$(printf '%s' "$out" | jf '.data.id')
a1_assignee=$(db "SELECT assignee FROM tasks WHERE id=${a1_id:-0};")
[[ $rc -eq 0 && "$a1_assignee" == "main2" ]] \
  && ok_t "A1 --assignee=role:verifier with 2 seats routes to the idler (main2)" \
  || bad_t "A1 role: routes to least-loaded" "rc=$rc assignee='$a1_assignee' out=$out err=$(cat "$TMP"/a1.err)"

# ---------------------------------------------------------------------------
# A2 (acceptance 1, second half) — "its choice is recorded so it can be
# audited". Assert BOTH counts are on the row, not merely that a note exists:
# the note without the numbers is unauditable, because the numbers that chose
# the lane have moved by the time anyone reads it.
# ---------------------------------------------------------------------------
a2_body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${a1_id:-0};")
if [[ "$a2_body" == *"ROUTED BY LOAD"* && "$a2_body" == *"main2 0"* && "$a2_body" == *"quinn 6"* ]]; then
  ok_t "A2 the load-based pick is recorded on the row with BOTH seats' counts"
else
  bad_t "A2 pick recorded with counts" "body='$a2_body'"
fi

# ---------------------------------------------------------------------------
# A3 — the pick is DETERMINISTIC on a tie. A router that alternates files the
# two halves of one decomposition into two different lanes.
# ---------------------------------------------------------------------------
_task_role_least_loaded verifier ""; p1="$_TASK_ROLE_PICK"
_task_role_least_loaded verifier ""; p2="$_TASK_ROLE_PICK"
db "DELETE FROM tasks WHERE title LIKE 'tiebreak%';"
seed_row main2 6                 # 6 vs 6 — an exact tie
_task_role_least_loaded verifier ""; t1="$_TASK_ROLE_PICK"
_task_role_least_loaded verifier ""; t2="$_TASK_ROLE_PICK"
[[ "$p1" == "$p2" && -n "$t1" && "$t1" == "$t2" ]] \
  && ok_t "A3 the pick is stable across calls, including on an exact tie ($t1)" \
  || bad_t "A3 deterministic pick" "p1=$p1 p2=$p2 t1=$t1 t2=$t2"
db "DELETE FROM tasks WHERE assignee='main2' AND title LIKE 'seeded main2%';"

# ---------------------------------------------------------------------------
# A4 (acceptance 2, "or resolves the verifier to a different seat") — the
# verifier seat is not a candidate for the build, so a loop row routed by role
# lands on the OTHER holder instead of being refused for self-grading.
# ---------------------------------------------------------------------------
out=$( (cmd_task_add --assignee=role:verifier --verifier=main2 -- "graded by main2, built elsewhere") 2>"$TMP"/a4.err )
rc=$?
a4_id=$(printf '%s' "$out" | jf '.data.id')
a4_a=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${a4_id:-0};")
a4_v=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${a4_id:-0};")
[[ $rc -eq 0 && "$a4_a" == "quinn" && "$a4_v" == "main2" ]] \
  && ok_t "A4 the verifier seat is excluded from the candidates (build->quinn, grade->main2)" \
  || bad_t "A4 verifier excluded from role pick" "rc=$rc assignee='$a4_a' verifier='$a4_v' err=$(cat "$TMP"/a4.err)"

# ---------------------------------------------------------------------------
# A5 (acceptance 2, first half) — PIN, NOT NEW CODE. The filing-time refusal of
# assignee == verifier already exists: DIVE-3097 landed it 2026-08-09 22:51Z,
# four days before DIVE-3366 was filed, and zero rows on the live board were
# filed same-seat after that timestamp. DIVE-3366 asked for a guard that is
# already there, so this arm pins it rather than duplicating it — acceptance 4's
# rule ("do not widen a control that already works") read one control over.
# ---------------------------------------------------------------------------
out=$( (cmd_task_add --assignee=quinn --verifier=quinn -- "grade my own work") 2>"$TMP"/a5.err )
rc=$?
msg="$out$(cat "$TMP"/a5.err)"
[[ $rc -ne 0 && "$msg" == *"own assignee"* ]] \
  && ok_t "A5 filing assignee==verifier is REFUSED at filing time (DIVE-3097, pinned)" \
  || bad_t "A5 same-seat filing refused" "rc=$rc msg=$msg"

# --- A6 NEGATIVE CONTROL for A5: the same row with DISTINCT names files clean.
# Without this, A5 passes just as well if `task add` were broken for every input.
out=$( (cmd_task_add --assignee=dev9 --verifier=quinn -- "distinct names file clean") 2>"$TMP"/a6.err )
rc=$?
a6_id=$(printf '%s' "$out" | jf '.data.id')
[[ $rc -eq 0 && -n "$a6_id" && "$a6_id" != "null" ]] \
  && ok_t "A6 negative control: distinct assignee/verifier files clean" \
  || bad_t "A6 distinct names file clean" "rc=$rc out=$out err=$(cat "$TMP"/a6.err)"

# ---------------------------------------------------------------------------
# A7 — a DELIVERED row is not the same state, and nothing here may treat it as
# one. `assignee == verifier` WITH a non-null maker_agent is the correct shape of
# a delivered row (the handoff reassigns the row to its grader and parks the
# builder in maker_agent) — it is what `task ls --json`'s handoff_state reads,
# and it is what DIVE-3366's own filing evidence misread as nine self-grading
# build rows. A guard that refused the equality unconditionally would refuse
# every delivery on the board.
# ---------------------------------------------------------------------------
seed_row quinn 4 quinn dev9      # delivered: assignee==verifier, maker set
hs=$(db "SELECT COUNT(*) FROM tasks WHERE assignee='quinn' AND assignee=verifier AND maker_agent IS NOT NULL;")
[[ "$hs" == "4" ]] \
  && ok_t "A7 delivered rows (assignee==verifier + maker_agent) survive filing untouched" \
  || bad_t "A7 delivered shape preserved" "count=$hs"

# ---------------------------------------------------------------------------
# A8 (acceptance 3) — the skew note fires once, NAMES BOTH COUNTS, and splits
# the busy seat into grading vs building. quinn holds 11 open at this point (6
# seeded + A4's build row + the 4 delivered), of which the 4 delivered are
# awaiting its own grade; main2 holds the 1 row A1 routed to it. The counts are
# asserted EXACTLY rather than as "> 0": a split whose two halves do not add up
# to the total is the specific way this note would mislead.
# ---------------------------------------------------------------------------
JSON_MODE=0
note=$( _task_role_skew_note 2>&1 )
lines=$(printf '%s' "$note" | grep -c "LANE SKEW")
if [[ "$lines" == "1" && "$note" == *"quinn holds 11"* && "$note" == *"main2 holds 1"* \
      && "$note" == *"4 awaiting its grade"* && "$note" == *"7 to build"* ]]; then
  ok_t "A8 skew note: one line, both counts, grading/building split"
else
  bad_t "A8 skew note shape" "lines=$lines note=$note"
fi

# --- A9 NEGATIVE CONTROL for A8: a BALANCED role says nothing. Without this the
# note could be unconditional and A8 would not notice.
seed_row main2 10
note2=$( _task_role_skew_note 2>&1 )
[[ -z "$(printf '%s' "$note2" | grep "LANE SKEW")" ]] \
  && ok_t "A9 negative control: a balanced role emits no skew note" \
  || bad_t "A9 balanced role silent" "note2=$note2"
db "DELETE FROM tasks WHERE assignee='main2' AND title LIKE 'seeded main2%';"

# --- A10: the floor keeps the note off a nearly-empty board (2 vs 0 is an
# infinite ratio and must NOT fire).
db "DELETE FROM tasks;"
seed_row quinn 2
note3=$( _task_role_skew_note 2>&1 )
[[ -z "$(printf '%s' "$note3" | grep "LANE SKEW")" ]] \
  && ok_t "A10 the busy-side floor suppresses the note on a 2-vs-0 board" \
  || bad_t "A10 floor suppresses tiny skew" "note3=$note3"

# ---------------------------------------------------------------------------
# A11 (the third instance) — the WIP-cap redirect must not SUGGEST a lane that
# is not a registered agent. Measured while DIVE-3366 was filed: a refused
# --assignee=dev2 offered eleven names that are not agents, each "(1 free)".
# ---------------------------------------------------------------------------
db "DELETE FROM tasks;"
seed_row quinn 1
seed_row main2 1
db "INSERT INTO tasks (title,status,assignee,kind,priority,created_at)
    VALUES ('typo lane row','todo','__nosuchagent_probe__','standard','medium',datetime('now'));"
for lane in quinn main2 __nosuchagent_probe__; do
  db "INSERT INTO task_prefs (key,value) VALUES ($(sqlq "wip_cap:$lane"),'9')
      ON CONFLICT(key) DO UPDATE SET value='9';"
done
free=$(_task_lanes_with_headroom "dev9")
if [[ "$free" == *"quinn"* && "$free" == *"main2"* && "$free" != *"__nosuchagent_probe__"* ]]; then
  ok_t "A11 the headroom suggestion offers only DISPATCHABLE lanes"
else
  bad_t "A11 headroom roster filter" "free='$free'"
fi

# --- A12 NEGATIVE CONTROL for A11, and the arm that proves the fixture roster is
# live: with the roster UNESTABLISHED the filter must narrow NOTHING, so the
# typo'd lane comes back. If this passed while A11 also passed only because the
# registry was missing, both would be vacuous — they cannot both be vacuous.
_TASK_ROSTER=""; _TASK_ROSTER_STATE=""
free_noreg=$(STATE_DIR="$TMP/absent-registry-dir" _task_lanes_with_headroom "dev9")
_TASK_ROSTER=""; _TASK_ROSTER_STATE=""
[[ "$free_noreg" == *"__nosuchagent_probe__"* ]] \
  && ok_t "A12 negative control: an unestablished roster narrows nothing" \
  || bad_t "A12 unestablished roster narrows nothing" "free_noreg='$free_noreg'"

printf '\n%s\n' "----------------------------------------"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
