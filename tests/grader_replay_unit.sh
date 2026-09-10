#!/usr/bin/env bash
# DIVE-4164 isolated unit harness — `task grader-replay`, the dry-run capacity replay.
#
# Grades the arithmetic against a SEEDED arrival pattern whose answers are known
# by construction, plus the property that makes the verb safe to point at
# production history: it holds no spawn path at all.
#
# Isolation: its own TASKS_DB in a temp dir. It never reads the live board.
# Run: bash tests/grader_replay_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grader-replay.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
BIN="./5dive"; [[ -x "$BIN" ]] || { echo "SKIP: bundle not built (run ./build.sh)"; exit 0; }
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

export TASKS_DIR="$TMP/tasks"; export TASKS_DB="$TASKS_DIR/tasks.db"; mkdir -p "$TASKS_DIR"
sqlite3 "$TASKS_DB" 'CREATE TABLE lifecycle_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, kind TEXT NOT NULL,
  ident TEXT, task_id INTEGER, actor TEXT NOT NULL DEFAULT "t",
  authority TEXT NOT NULL DEFAULT "self", parent_ident TEXT,
  idem_key TEXT NOT NULL DEFAULT "", input_hash TEXT, output_hash TEXT,
  policy_decision TEXT, tokens INTEGER, host TEXT, detail TEXT);'

seed() { # <ident> <delivered-offset-min> <closed-offset-min|-> <kind>
  local id="$1" a="$2" b="$3" k="${4:-task.done}"
  sqlite3 "$TASKS_DB" "INSERT INTO lifecycle_events (ts,kind,ident,idem_key)
    VALUES (datetime('now','-${a} minutes'),'task.delivered','$id','d$id$a');"
  [[ "$b" == "-" ]] || sqlite3 "$TASKS_DB" "INSERT INTO lifecycle_events (ts,kind,ident,idem_key)
    VALUES (datetime('now','-${b} minutes'),'$k','$id','c$id$b');"
}
# Three deliveries fully overlapping (all open 300..100 min ago) => peak 3.
seed A 300 100; seed B 290 110; seed C 280 120
# One resolved long before them => never overlaps.
seed D 900 880
# One still open, delivered INSIDE the A/B/C overlap => must count toward peak.
# First cut seeded this at 60 minutes, which is AFTER A closed at 100, so it
# overlapped nothing and the arm asserted 4 against a true answer of 3 — the test
# was wrong, not the code. Kept as a seeded overlap so the arm actually exercises
# "an un-graded delivery still occupies a grader".
seed E 285 -
J() { $BIN task grader-replay --days=7 "$@" --json 2>/dev/null; }
out=$(J)
if [[ -z "$out" ]]; then bad_ 'replay produced json' 'empty output'; else ok_ 'replay produced json'; fi
g(){ printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }

[[ "$(g deliveries)" == 5 ]] && ok_ 'counts 5 deliveries' || bad_ 'counts 5 deliveries' "got $(g deliveries)"
[[ "$(g resolved)" == 4 ]] && ok_ 'counts 4 resolved spans' || bad_ 'counts 4 resolved' "got $(g resolved)"
[[ "$(g stillOutstanding)" == 1 ]] && ok_ 'counts 1 still outstanding' || bad_ 'still outstanding' "got $(g stillOutstanding)"
# A,B,C overlap plus the open E => 4. D is disjoint and must NOT inflate it.
[[ "$(g peakConcurrentGraders)" == 4 ]] && ok_ 'peak concurrency = 4 (3 overlapping + 1 open)' \
  || bad_ 'peak concurrency = 4' "got $(g peakConcurrentGraders)"

# At cap=1 the three overlapping deliveries must queue; at a generous cap none do.
out=$(J --cap=1); q1=$(g wouldQueueAtCap)
out=$(J --cap=10); q10=$(g wouldQueueAtCap)
[[ "$q1" -gt "$q10" ]] && ok_ "a tight cap queues more than a loose one ($q1 > $q10)" \
  || bad_ 'tight cap queues more' "cap1=$q1 cap10=$q10"
[[ "$q10" == 0 ]] && ok_ 'cap=10 queues nothing' || bad_ 'cap=10 queues nothing' "got $q10"

# --service-cap shortens spans, so it can only REDUCE queueing at a fixed cap.
out=$(J --cap=1); qh=$(g wouldQueueAtCap)
out=$(J --cap=1 --service-cap=0.1); qs=$(g wouldQueueAtCap)
if [[ "$qs" =~ ^[0-9]+$ && "$qh" =~ ^[0-9]+$ ]]; then
  [[ "$qs" -le "$qh" ]] && ok_ "service-cap cannot increase queueing ($qs <= $qh)" \
    || bad_ 'service-cap cannot increase queueing' "capped=$qs uncapped=$qh"
else
  # Guarded because `[[ "" -le "" ]]` is TRUE in bash: the first cut of this arm
  # reported ok while every value was empty, i.e. it passed hardest exactly when
  # the command was broken.
  bad_ 'service-cap cannot increase queueing' "non-numeric: capped=$qs uncapped=$qh"
fi
out=$(J --service-cap=0.5); [[ "$(g serviceCapHours)" == 0.5 ]] \
  && ok_ 'service-cap echoed in json' || bad_ 'service-cap echoed' "got $(g serviceCapHours)"

# A service cap LONGER than every span must be a no-op: it truncates, it never
# extends. Needs a fixture where extending is observable — the first cut only
# seeded spans of 200 minutes and probed with 0.1h, so a min->max mutation moved
# nothing and survived. These three spans are 6 minutes each and overlap, so a
# cap of 1h would visibly stretch them if the direction were wrong.
# WELL-SEPARATED and SHORT (6 minutes each, two hours apart), which is the only
# shape that can observe an extension. Fully-overlapping spans are insensitive to
# span LENGTH — three deliveries that already overlap peak at 3 however long they
# run — so the first cut of this fixture (spans one minute apart) could not
# distinguish truncation from extension and the min->max mutant survived it.
# Disjoint-but-close spans collide only if something stretches them.
seed F 600 594; seed G 480 474; seed H 360 354
out=$(J --cap=1); base_q=$(g wouldQueueAtCap); base_peak=$(g peakConcurrentGraders)
# 10h exceeds EVERY seeded span (the longest is A/B/C at 200 minutes). A cap of
# 1h was the first cut and it truncated those three, so the arm measured
# truncation instead of the no-op it claimed to.
out=$(J --cap=1 --service-cap=10); big_q=$(g wouldQueueAtCap); big_peak=$(g peakConcurrentGraders)
if [[ "$base_q" =~ ^[0-9]+$ && "$big_q" =~ ^[0-9]+$ ]]; then
  [[ "$big_q" == "$base_q" && "$big_peak" == "$base_peak" ]] \
    && ok_ 'a service-cap longer than every span changes nothing (truncates, never extends)' \
    || bad_ 'service-cap must never extend a span' "uncapped q=$base_q peak=$base_peak · capped q=$big_q peak=$big_peak"
else
  bad_ 'service-cap must never extend a span' "non-numeric: $base_q / $big_q"
fi

# Validation.
$BIN task grader-replay --service-cap=abc >/dev/null 2>&1 && bad_ 'rejects a non-numeric service-cap' 'accepted' || ok_ 'rejects a non-numeric service-cap'
$BIN task grader-replay --days=x        >/dev/null 2>&1 && bad_ 'rejects a non-numeric --days' 'accepted'  || ok_ 'rejects a non-numeric --days'

# ── STRUCTURAL: the verb is dry-run BY CONSTRUCTION, not by intention ─────────
# It is pointed at production history, so "it does not spawn" must be a property
# of the code rather than a promise in a comment. Assert the body contains no
# verb that could start or stop anything.
body=$(awk '/^cmd_task_grader_replay\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/task/grader_pool.sh)
danger=$(grep -vE '^[[:space:]]*#' <<<"$body" | grep -nE 'systemctl|agent create|_hb_wake|spawn_request|tmux|sudo ' || true)
[[ -z "$danger" ]] && ok_ 'structural: no spawn/teardown verb in the replay body' \
  || bad_ 'structural: no spawn/teardown verb in the replay body' "$danger"
# And it must not WRITE to the store either.
writes=$(grep -vE '^[[:space:]]*#' <<<"$body" | grep -nE 'INSERT|UPDATE|DELETE|ledger_emit' || true)
[[ -z "$writes" ]] && ok_ 'structural: read-only — no INSERT/UPDATE/DELETE/ledger_emit' \
  || bad_ 'structural: read-only' "$writes"

# ── DIVE-4217 iteration 2: a flag replay does not IMPLEMENT must fail loudly ──
# The rejected first cut carried an --only=<ident> arm here that parsed and was
# never read: `grader-replay --days=7` and `--days=7 --only=DIVE-4208` returned
# BYTE-IDENTICAL whole-queue output, so the operator got positive confirmation
# the flag was understood and 7-day figures presented as scoped to one ident —
# on the one command whose numbers feed a spend argument. The discriminator is
# not "does --only work" (replay has no pairing filter) but "does an unhandled
# flag reach the usage arm". Both halves are asserted: non-zero exit AND that
# the two invocations are not the same bytes.
$BIN task grader-replay --days=7 --only=DIVE-4208 >/dev/null 2>&1 \
  && bad_ 'replay rejects --only rather than silently ignoring it' 'accepted a flag it does not implement' \
  || ok_ 'replay rejects --only rather than silently ignoring it'
plain=$($BIN task grader-replay --days=7 --json 2>/dev/null)
scoped=$($BIN task grader-replay --days=7 --only=DIVE-4208 --json 2>/dev/null)
[[ "$plain" != "$scoped" ]] \
  && ok_ 'replay --only does not return byte-identical whole-queue output' \
  || bad_ 'replay --only does not return byte-identical whole-queue output' 'unscoped figures presented as scoped'
# The tick, whose --only IS wired into the pending filter, keeps it in usage.
grep -q -- '--only=<ident>' <(awk '/^cmd_task_grader_tick\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/task/grader_pool.sh) \
  && ok_ 'the tick still documents --only in its own usage string' \
  || bad_ 'the tick still documents --only in its own usage string' 'usage line lost'

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
