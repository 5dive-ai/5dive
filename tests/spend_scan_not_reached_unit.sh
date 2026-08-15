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
# DIVE-3417: the same seed, but split across TWO project subdirs — the level the
# middle `*` of projects/*/*.jsonl reads. Both readable must sum 2*EXPECT; one
# unreadable must NOT-REACH, and specifically must never return the well-formed
# HALF that glob.glob() produced by swallowing the failed listing.
mk_home2() {  # mk_home2 <name> -> echoes the home, one in-window turn per subdir
  local n="$1"; local h="$TMP/home-$n"; local ts d
  ts=$(date -u -d "@$((start+10))" +%FT%TZ)
  for d in good locked; do
    mkdir -p "$h/.claude/projects/$d"
    printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":10000,"output_tokens":5000,"cache_creation_input_tokens":15000,"cache_read_input_tokens":999999}}}\n' \
      "$ts" > "$h/.claude/projects/$d/session.jsonl"
  done
  printf '%s' "$h"
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
H_SUB=$(mk_home2 subdiragent)   # DIVE-3417: two project subdirs, one made 000 below
H_LOOP=$(mk_home2 loopdiragent) # DIVE-3417: one subdir swapped for a symlink loop

REGISTRY="$TMP/registry.json"
cat > "$REGISTRY" <<'JSON'
{"agents":{"okagent":{"type":"claude"},"denyagent":{"type":"claude"},
           "fileagent":{"type":"claude"},"idleagent":{"type":"claude"},
           "emptyagent":{"type":"claude"},"goneagent":{"type":"claude"},
           "noaccountagent":{"type":"claude"},"botagent":{"type":"codex"},
           "subdiragent":{"type":"claude"},"loopdiragent":{"type":"claude"}}}
JSON
export REGISTRY LOOP_HOME_OVERRIDE_JSON
# `noaccountagent` is deliberately ABSENT from the override map: it exercises the
# real `home_of()` passwd lookup, which is the half of the fallback a home
# override can never reach.
LOOP_HOME_OVERRIDE_JSON=$(cat <<JSON
{"okagent":"$H_OK","denyagent":"$H_DENY","fileagent":"$H_FILE",
 "idleagent":"$H_IDLE","emptyagent":"$H_EMPTY","goneagent":"$H_GONE","botagent":"$H_BOT",
 "subdiragent":"$H_SUB","loopdiragent":"$H_LOOP"}
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
T_SUB=$(mk_task  SS-11 subdiragent)
T_LOOP=$(mk_task SS-12 loopdiragent)

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

# ====== DIVE-3417: the MIDDLE wildcard — a partial total, not a zero =========
# The level between the two guards above. `probe_readable` covers `projects/`;
# the per-file `except OSError` covers each `*.jsonl`; the `*` BETWEEN them was
# read by glob.glob(), which skips a directory it cannot list WITHOUT raising.
# So this failure never produced a 0 to be caught — it produced HALF of a real
# total, rc 0, which _loop_refresh_spend accepts as a successful read and
# PERSISTS over the accumulated tokens_spent. A smaller lie in the format the
# guard trusts. Every arm here is paired with the same fixture healed, and the
# sick assertion is specifically that the HALF (=$EXPECT) is never returned.
SUB_BOTH=$((EXPECT*2))
# ANCHOR for this fixture: both subdirs readable must sum BOTH, not one.
scan "$T_SUB"
[[ "$RC" == "0" && "$OUT" == "$SUB_BOTH" ]] \
  && ok_t "ANCHOR two readable project subdirs sum BOTH ($OUT) — the middle level is traversed" \
  || bad_t "ANCHOR two-subdir" "rc=$RC out='$OUT' err=$ERR — every middle-level arm below is vacuous while this is red"

# ANY-UID: a self-referential symlink where a project dir belongs. listdir raises
# ELOOP for root too, so this arm grades the middle level on a uid-0 runner —
# the same reason fac4aea put an ENOTDIR arm on the level above (quinn: "a green
# that skipped the point is not a grade"). glob.glob() swallows it identically.
rm -rf "$H_LOOP/.claude/projects/locked"
ln -s locked "$H_LOOP/.claude/projects/locked"
scan "$T_LOOP"
nr_t "ANY-UID: unreadable project SUBDIR (ELOOP, defeats root too)" 'project dir .* unreadable'
[[ "$OUT" != "$EXPECT" ]] \
  && ok_t "ANY-UID: and it is not the well-formed HALF ($EXPECT) that glob produced" \
  || bad_t "PARTIAL" "out='$OUT' — half the truth, rc $RC: the clobber shape DIVE-3345 exists to kill"
# PAIRED HEAL: a real dir with a real transcript back in place -> the full sum.
rm -f "$H_LOOP/.claude/projects/locked"
mkdir -p "$H_LOOP/.claude/projects/locked"
cp "$H_LOOP/.claude/projects/good/session.jsonl" "$H_LOOP/.claude/projects/locked/session.jsonl"
scan "$T_LOOP"
[[ "$RC" == "0" && "$OUT" == "$SUB_BOTH" ]] \
  && ok_t "…and the same subdir healed sums $OUT — the NOT-REACHED was blindness, not emptiness" \
  || bad_t "healed subdir (ELOOP)" "rc=$RC out='$OUT' err=$ERR"

# The PRODUCTION shape, and the row's own fixture: readable projects/ over a 000
# project subdir. EACCES is only expressible unprivileged (root lists a 000 dir
# regardless), so this is SKIPPED rather than faked — the ANY-UID arm above is
# what keeps a root run from being a vacuous green. Reachability here is HIGHER
# on a normalised host, not lower: /etc/cron.d/5dive-agent-home-traversal
# (DIVE-3294) makes the UPPER path traversable every 20m, manufacturing exactly
# this readable-parent-over-unreadable-child state rather than preventing it.
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip - EACCES middle-level arm not runnable as root (a uid that can read everything cannot see this defect)\n'
else
  chmod 000 "$H_SUB/.claude/projects/locked"
  scan "$T_SUB"
  nr_t "unreadable project SUBDIR under a readable projects/ (EACCES)" 'project dir .* unreadable'
  [[ "$OUT" != "$EXPECT" ]] \
    && ok_t "…and never the HALF ($EXPECT): a partial reported as a total is the same fail-open" \
    || bad_t "PARTIAL" "rc=$RC out='$OUT' — exactly the rc=0 out=$EXPECT ops measured on fac4aea"
  chmod 755 "$H_SUB/.claude/projects/locked"
  scan "$T_SUB"
  [[ "$RC" == "0" && "$OUT" == "$SUB_BOTH" ]] \
    && ok_t "…and the same subdir healed sums $OUT — blindness, not emptiness" \
    || bad_t "healed subdir (EACCES)" "rc=$RC out='$OUT' err=$ERR"
fi

# The two skips list_sessions() keeps deliberately, because both mean "nothing
# unread here" rather than "we failed to read it" — and both are what the glob
# did. If either over-fires, a live agent rolling a session over NOT-REACHES.
ln -s /nonexistent-3417 "$H_SUB/.claude/projects/dangling"   # ENOENT
: > "$H_SUB/.claude/projects/stray-file"                     # ENOTDIR, cannot hold */*.jsonl
scan "$T_SUB"
[[ "$RC" == "0" && "$OUT" == "$SUB_BOTH" ]] \
  && ok_t "a dangling symlink and a stray FILE in projects/ are skipped, not NOT-REACHED (still $OUT)" \
  || bad_t "middle-level over-fired" "rc=$RC out='$OUT' err=$ERR — a rolling session must not wedge the scan"
rm -f "$H_SUB/.claude/projects/dangling" "$H_SUB/.claude/projects/stray-file"

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
