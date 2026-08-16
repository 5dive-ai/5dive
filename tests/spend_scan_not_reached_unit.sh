#!/usr/bin/env bash
# DIVE-3345: an agent transcript root the scanner could not READ is NOT-REACHED,
# never 0.
#
# The defect this grades: `_spend_scan_task_ids` resolved each agent's home
# through `home_of()`, which fell back to a GUESSED "/home/agent-<name>". If that
# path was missing, or present but unreadable by the calling uid, `glob.glob()`
# returned [], the per-agent loop contributed nothing, and the function printed
# `0` and exited `0`. Its own header promised "a spend that could not be READ is
# NOT-REACHED, never 0", and both callers are built around that promise — but
# nothing in the scanner could produce the non-zero exit they branch on, so the
# fail-closed path was bypassed by a fail-open one underneath it.
#
# WHY IT SHIPPED, and therefore what this file has to do differently: the old
# code passes any test written by an owner who can read everything. So every sick
# arm here runs as a uid that genuinely cannot read the fixture — `chmod 000`,
# unprivileged — and is PAIRED with the same fixture healed, which must recompute
# a real non-zero total through the same code. Without that pairing a green
# "reports NOT-REACHED" arm is unfalsifiable: a zero from an empty input is
# indistinguishable from a zero from a clean check, and that is the entire bug.
#
# Run: bash tests/spend_scan_not_reached_unit.sh   (no root, no network.)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# chmod back before rm: the arms below leave 000 directories behind, and a trap
# that cannot delete its own tempdir leaks fixtures into /tmp on every run.
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/spend-scan-nr.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_loop.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

now=$(date +%s); start=$((now-300))
# 10000 + 5000 + 15000 = 30000; cache-read excluded, same metric as `5dive usage`.
EXPECT=30000

mk_home() {   # mk_home <name> -> echoes the home, seeded with one in-window turn
  # Split, not `local n=.. h="$TMP/home-$n"`: bash expands every word of a
  # `local` line BEFORE the locals exist, so the second would read an outer `n`.
  local n="$1"; local h="$TMP/home-$n"; local ts
  mkdir -p "$h/.claude/projects/proj"
  ts=$(date -u -d "@$((start+10))" +%FT%TZ)
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":10000,"output_tokens":5000,"cache_creation_input_tokens":15000,"cache_read_input_tokens":999999}}}\n' \
    "$ts" > "$h/.claude/projects/proj/session.jsonl"
  printf '%s' "$h"
}
# DIVE-3468. mk_home_fanout <name> — a home whose session ALSO fanned work out
# to a subagent. Every fixture above writes its turns into <sid>.jsonl and none
# creates the sibling directory, which is exactly why the 26 arms above could
# not see this defect: they model a seat that never delegates.
#
# The real layout, measured on agent-quinn and agent-dev3, is TWO levels:
#
#     projects/<proj>/<sid>.jsonl                     <- the parent transcript
#     projects/<proj>/<sid>/subagents/agent-*.jsonl   <- the sidechain turns
#
# The parent file holds NONE of the sidechain turns (uuid sets disjoint on all
# four dev3 pairs), so this is additional spend, not a re-count of it.
mk_home_fanout() {
  local n="$1"; local h; local ts
  h=$(mk_home "$n")
  ts=$(date -u -d "@$((start+20))" +%FT%TZ)
  mkdir -p "$h/.claude/projects/proj/session/subagents"
  printf '{"type":"assistant","isSidechain":true,"timestamp":"%s","message":{"usage":{"input_tokens":7000,"output_tokens":3000,"cache_creation_input_tokens":11000,"cache_read_input_tokens":42}}}\n' \
    "$ts" > "$h/.claude/projects/proj/session/subagents/agent-deadbeef.jsonl"
  printf '%s' "$h"
}
# mk_decoy <home> — tool-results/ is a sibling of subagents/ in the SAME
# directory: same depth, same .jsonl suffix, and a well-formed billable
# assistant turn inside. It is NOT transcript turns. A `*/*/*.jsonl` sweep — the
# obvious over-broad way to reach the subagents — counts it, and this fixture is
# the only thing in the corpus that says so. Present on all 9 readable seats, so
# that fix would over-charge fleet-wide. Its value is deliberately absurd: if it
# is ever swept in, the total cannot be mistaken for anything else.
mk_decoy() {
  local ts; ts=$(date -u -d "@$((start+25))" +%FT%TZ)
  mkdir -p "$1/.claude/projects/proj/session/tool-results"
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":900000,"output_tokens":900000,"cache_creation_input_tokens":900000}}}\n' \
    "$ts" > "$1/.claude/projects/proj/session/tool-results/blob.jsonl"
}
mk_task() {   # mk_task <ident> <assignee> -> echoes the row id
  db "INSERT INTO tasks (ident,title,status,assignee,kind,started_at,created_at,updated_at)
      VALUES ('$1','spend fixture','in_progress','$2','standard',
              datetime($start,'unixepoch'),datetime($start,'unixepoch'),datetime($start,'unixepoch'));"
  db "SELECT id FROM tasks WHERE ident='$1';"
}
scan() {      # scan <task_id> -> sets RC / OUT / ERR
  OUT=$(_spend_scan_task_ids "[$1]" 0 2>"$TMP/scan.err"); RC=$?; ERR=$(cat "$TMP/scan.err")
}
# Every sick arm asserts all three halves of the contract at once: rc non-zero,
# stdout EMPTY (a 0 here is the defect itself), and a named cause on stderr.
nr_t() {      # nr_t <label> <stderr-regex>
  [[ "$RC" != "0" && -z "$OUT" ]] \
    && ok_t "$1: rc=$RC and stdout EMPTY (never the integer 0)" \
    || bad_t "$1" "rc=$RC out='$OUT' — a 0 here is indistinguishable from an idle agent"
  grep -qE "$2" <<<"$ERR" \
    && ok_t "$1: stderr names the cause (/$2/)" \
    || bad_t "$1 stderr" "got: ${ERR:-<empty>}"
}

H_OK=$(mk_home okagent)         # readable, one turn
H_DENY=$(mk_home denyagent)     # made 000 below
H_FILE=$(mk_home fileagent)     # dir readable, transcript file made 000 below
H_IDLE="$TMP/home-idleagent";     mkdir -p "$H_IDLE"                        # no .claude at all
H_EMPTY="$TMP/home-emptyagent";   mkdir -p "$H_EMPTY/.claude/projects"      # dir exists, nothing in it
H_GONE="$TMP/home-goneagent"                                               # never created
H_BOT=$(mk_home botagent)       # non-claude type: skipped, and must stay skipped
# DIVE-3468: a seat that DELEGATES. Same one in-window parent turn as H_OK, plus
# a subagent turn one level deeper, plus the tool-results decoy beside it.
H_FAN=$(mk_home_fanout fanoutagent)
mk_decoy "$H_FAN"
# 30000 parent + (7000 + 3000 + 11000) subagent = 51000. The subagent's
# cache_read_input_tokens (42) is excluded by the same metric as the parent's,
# so an exact match here also holds the metric, not just the file set.
EXPECT_FAN=51000

REGISTRY="$TMP/registry.json"
cat > "$REGISTRY" <<'JSON'
{"agents":{"okagent":{"type":"claude"},"denyagent":{"type":"claude"},
           "fileagent":{"type":"claude"},"idleagent":{"type":"claude"},
           "emptyagent":{"type":"claude"},"goneagent":{"type":"claude"},
           "noaccountagent":{"type":"claude"},"botagent":{"type":"codex"},
           "fanoutagent":{"type":"claude"}}}
JSON
export REGISTRY LOOP_HOME_OVERRIDE_JSON
# `noaccountagent` is deliberately ABSENT from the override map: it exercises the
# real `home_of()` passwd lookup, which is the half of the fallback a home
# override can never reach.
LOOP_HOME_OVERRIDE_JSON=$(cat <<JSON
{"okagent":"$H_OK","denyagent":"$H_DENY","fileagent":"$H_FILE",
 "idleagent":"$H_IDLE","emptyagent":"$H_EMPTY","goneagent":"$H_GONE","botagent":"$H_BOT",
 "fanoutagent":"$H_FAN"}
JSON
)

T_OK=$(mk_task   SS-1 okagent)
T_DENY=$(mk_task SS-2 denyagent)
T_FILE=$(mk_task SS-3 fileagent)
T_IDLE=$(mk_task SS-4 idleagent)
T_EMPT=$(mk_task SS-5 emptyagent)
T_GONE=$(mk_task SS-6 goneagent)
T_UNRG=$(mk_task SS-7 notinregistry)
T_NOAC=$(mk_task SS-8 noaccountagent)
T_BOT=$(mk_task  SS-9 botagent)
T_FAN=$(mk_task SS-11 fanoutagent)

# ===================== ANCHOR: the scanner can reach a number =================
# Runs FIRST and on the same code path as every arm below. If this is red, every
# NOT-REACHED green underneath it is vacuous — the scanner would simply be broken.
scan "$T_OK"
[[ "$RC" == "0" && "$OUT" == "$EXPECT" ]] \
  && ok_t "ANCHOR readable home still sums the real spend (rc 0, =$OUT)" \
  || bad_t "ANCHOR" "rc=$RC out='$OUT' err=$ERR — every arm below is vacuous while this is red"

# =========================== STATE 1: root MISSING ===========================
scan "$T_GONE"
nr_t "missing transcript root" 'does not exist'

# ============ STATE 2a: root present, unreadable — AT ANY UID ================
# quinn, clearing this row's push gate: "if CI executes as uid 0, every EACCES
# arm skips and the harness reports green having never touched the defect this
# row exists to fix — a green that skipped the point is not a grade."
#
# So the defect CLASS is graded first by a condition permission bits cannot
# express: the transcript dir is a regular FILE, which raises ENOTDIR for root
# too (usage_coverage_unit.sh's trick, DIVE-2069). Root can read everything and
# still cannot listdir a file. The EACCES arms below remain the unprivileged
# extra — they are the shape production actually takes — but this one means the
# harness can never be green WITHOUT having exercised an unreadable root.
printf 'runner uid=%s (%s) — arms marked ANY-UID grade the defect regardless\n' "$(id -u)" "$(id -un)"
H_NOTDIR="$TMP/home-notdiragent"; mkdir -p "$H_NOTDIR/.claude"
: > "$H_NOTDIR/.claude/projects"          # a FILE where the transcript dir belongs
LOOP_HOME_OVERRIDE_JSON=$(python3 -c '
import json,os,sys
m = json.loads(sys.argv[1]); m["notdiragent"] = sys.argv[2]; print(json.dumps(m))' \
  "$LOOP_HOME_OVERRIDE_JSON" "$H_NOTDIR")
python3 - "$REGISTRY" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["agents"]["notdiragent"] = {"type": "claude"}
json.dump(d, open(p, "w"))
PY
T_NOTDIR=$(mk_task SS-10 notdiragent)
scan "$T_NOTDIR"
nr_t "ANY-UID: transcript root unreadable (ENOTDIR, defeats root too)" 'unreadable'

# ======================= STATE 2b: root present, UNREADABLE ==================
# The production condition, and the reporter's: /home/agent-* is mode 700 on a
# shared host, so any peer's spend read as 0. EACCES is only expressible
# unprivileged — root reads a 000 dir regardless — so this is SKIPPED rather
# than faked, and 2a above is what keeps a root run from being a vacuous green.
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip - EACCES arms not runnable as root (the whole defect is invisible to a uid that can read everything)\n'
else
  chmod 000 "$H_DENY"
  scan "$T_DENY"
  nr_t "unreadable transcript root (EACCES)" 'not readable by this uid'
  # PAIRED HEAL: same fixture, same task, permission restored. Proves the arm
  # above reported a BLINDNESS and not an empty home.
  chmod 755 "$H_DENY"
  scan "$T_DENY"
  [[ "$RC" == "0" && "$OUT" == "$EXPECT" ]] \
    && ok_t "…and the same home healed sums $OUT — the NOT-REACHED was blindness, not emptiness" \
    || bad_t "healed home" "rc=$RC out='$OUT' err=$ERR"

  # File granularity: dir listable, one transcript denied. A PARTIAL sum reported
  # as a total is the same fail-open, one level down.
  chmod 000 "$H_FILE/.claude/projects/proj/session.jsonl"
  scan "$T_FILE"
  nr_t "unreadable transcript FILE (partial sum refused)" 'unreadable'
  chmod 644 "$H_FILE/.claude/projects/proj/session.jsonl"
  scan "$T_FILE"
  [[ "$RC" == "0" && "$OUT" == "$EXPECT" ]] \
    && ok_t "…and the same file healed sums $OUT" \
    || bad_t "healed file" "rc=$RC out='$OUT' err=$ERR"
fi

# ================== STATE 3: readable and genuinely empty -> 0 ===============
# The ONLY legitimate zero. If these go red the fix has over-fired and every idle
# agent now reports NOT-REACHED, which disables the guards just as thoroughly.
scan "$T_IDLE"
[[ "$RC" == "0" && "$OUT" == "0" ]] \
  && ok_t "readable home, never ran (no .claude) -> a legitimate 0" \
  || bad_t "idle home over-fired" "rc=$RC out='$OUT' err=$ERR"
scan "$T_EMPT"
[[ "$RC" == "0" && "$OUT" == "0" ]] \
  && ok_t "readable home, transcript dir present but empty -> a legitimate 0" \
  || bad_t "empty dir over-fired" "rc=$RC out='$OUT' err=$ERR"
scan "$T_BOT"
[[ "$RC" == "0" && "$OUT" == "0" ]] \
  && ok_t "non-claude agent still SKIPPED, not NOT-REACHED (it has no claude transcripts)" \
  || bad_t "non-claude over-fired" "rc=$RC out='$OUT' err=$ERR"
OUT=$(_spend_scan_task_ids '[]' 0 2>/dev/null); RC=$?
[[ "$RC" == "0" && "$OUT" == "0" ]] \
  && ok_t "no child tasks at all -> still a plain 0 (unchanged)" \
  || bad_t "empty kids" "rc=$RC out='$OUT'"

# ================= DIVE-3468: the seat that DELEGATES =========================
# The defect these arms exist for: subagent turns are written to a sibling
# DIRECTORY, projects/<proj>/<sid>/subagents/*.jsonl, and a one-level glob stops
# short of them. Every arm above models a seat that never delegates, which is
# exactly why 26 green arms could not see it.
#
# It fails in the worst available direction. There is no rc, no NOT-REACHED, no
# named cause — just a smaller correct-looking integer, under-charging precisely
# the rows that fan work out, i.e. the expensive ones. Nothing inside the numbers
# falsifies it, which is why it needs an arm that knows the true total.
#
# Independently replicated on a THIRD seat before this was written (agent-dev,
# not the agent-quinn/agent-dev3 pair in the row): 116 turns, all
# isSidechain:true, every one carrying the PARENT's sessionId, and the parent
# .jsonl holding ZERO of their uuids — so the second glob ADDS turns rather than
# re-counting them. 3,174,912 tokens, 3.1% of that seat's true total, were being
# silently dropped.
scan "$T_FAN"
[[ "$RC" == "0" && "$OUT" == "$EXPECT_FAN" ]] \
  && ok_t "subagent turns are INCLUDED: parent+sidechain summed (=$OUT)" \
  || bad_t "subagent turns excluded" "rc=$RC out='$OUT' want=$EXPECT_FAN err=$ERR"

# The pre-fix figure, asserted as a NON-match. Without this the arm above only
# says "the number is 51000"; with it, the number is also demonstrably not the
# one the old reader produced, so a future change that silently reverts the glob
# cannot pass by coincidence.
[[ "$OUT" != "$EXPECT" ]] \
  && ok_t "the fanout total is NOT the parent-only total the one-level glob returned ($EXPECT)" \
  || bad_t "still parent-only" "out='$OUT' — the second glob is not reaching subagents/"

# The over-broad fix must stay refused. tool-results/ sits at the SAME depth as
# subagents/, with the same .jsonl suffix and a well-formed billable turn inside,
# and it is present on all 9 readable seats — so a `*/*/*.jsonl` sweep would
# over-charge fleet-wide. The decoy's value is 2,700,000: if it is ever swept in,
# the total cannot be mistaken for anything else.
(( OUT < 2700000 )) \
  && ok_t "tool-results/ decoy NOT swept in (a */*/*.jsonl fix would have added 2,700,000)" \
  || bad_t "decoy counted" "out='$OUT' — the glob is too broad, not too narrow"

# The unreadable-level contract must hold at the NEW depth too, or the fix trades
# a silent undercount for a silent undercount one level deeper. Same pairing
# discipline as every arm above: break it, assert NOT-REACHED, heal it, assert the
# real total recomputes through the same code.
if [[ $EUID -ne 0 ]]; then
  chmod 000 "$H_FAN/.claude/projects/proj/session/subagents"
  scan "$T_FAN"
  nr_t "unreadable subagents/ dir is NOT-REACHED, not a quiet short total" \
       'unreadable|not read|NOT-REACHED|Permission denied'
  chmod 755 "$H_FAN/.claude/projects/proj/session/subagents"
  scan "$T_FAN"
  [[ "$RC" == "0" && "$OUT" == "$EXPECT_FAN" ]] \
    && ok_t "healed subagents/ dir recomputes the full total through the same code (=$OUT)" \
    || bad_t "heal did not recompute" "rc=$RC out='$OUT' want=$EXPECT_FAN err=$ERR"
else
  ok_t "SKIP unreadable-subagents arms (running as root: chmod 000 does not deny)"
fi

# ============ acceptance 4: the GUESSED home, and the unknown assignee ========
scan "$T_NOAC"
nr_t "registry agent with no account on this host" 'no agent-noaccountagent account|unresolvable'
scan "$T_UNRG"
nr_t "assignee absent from the registry (DIVE-3344's 'cli' rows)" 'not in the agent registry'

# ========================= the task db is an input too ========================
( TASKS_DB="$TMP/nope/missing.db"; scan "$T_OK"
  [[ "$RC" != "0" && -z "$OUT" ]] \
    && printf 'ok   - unreadable task db -> NOT-REACHED, not 0\n' \
    || printf 'FAIL - unreadable task db\n   rc=%s out=%s\n' "$RC" "$OUT" ) | tee "$TMP/db.out"
grep -q '^ok' "$TMP/db.out" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ===================== CONSUMER: the contract the callers branch on ==========
# _loop_refresh_spend already HAD an rc-2 NOT-REACHED path; the producer just
# could never trigger it for this cause. End to end, including the persist —
# a failed read must not clobber the last good total (DIVE-2304).
if [[ "$(id -u)" -ne 0 ]]; then
  db "INSERT INTO loop_runs (loop_id,topology,status,tokens_spent,ceiling,child_task_ids,spawned_by_task,started_at,updated_at)
      VALUES ('L-3345','spawn','running',60000,50000,'[$T_DENY]',$T_DENY,$start,$start);"
  chmod 000 "$H_DENY"
  c_out=$(_loop_refresh_spend "L-3345" 2>"$TMP/c.err"); c_rc=$?
  [[ "$c_rc" == "2" && -z "$c_out" ]] \
    && ok_t "consumer: _loop_refresh_spend surfaces the unreadable home as rc 2, no value" \
    || bad_t "consumer rc" "rc=$c_rc out='$c_out' err=$(cat "$TMP/c.err")"
  grep -q 'NOT-REACHED' "$TMP/c.err" \
    && ok_t "consumer: the cause reaches stderr, so the ceiling is not silently unverified" \
    || bad_t "consumer stderr" "$(cat "$TMP/c.err")"
  [[ "$(db "SELECT tokens_spent FROM loop_runs WHERE loop_id='L-3345';")" == "60000" ]] \
    && ok_t "consumer: the persisted total is NOT clobbered by the failed read" \
    || bad_t "CLOBBERED" "tokens_spent -> $(db "SELECT tokens_spent FROM loop_runs WHERE loop_id='L-3345';")"
  chmod 755 "$H_DENY"
  c_out=$(_loop_refresh_spend "L-3345" 2>/dev/null); c_rc=$?
  [[ "$c_rc" == "0" && "$c_out" == "$EXPECT" ]] \
    && ok_t "consumer: healed home recomputes and persists ($c_out) — the ceiling still works" \
    || bad_t "consumer healed" "rc=$c_rc out='$c_out'"
fi

printf -- '-----\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
