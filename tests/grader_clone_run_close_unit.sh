#!/usr/bin/env bash
# TIER: core — 1.7s measured with a built bundle present (5dive control plane,
# 2026-09-14; three sqlite fixtures, one sweep and one `run metrics` read). It
# grades the METRIC the fleet's own reliability reporting is computed from, and
# both halves of that metric — the writer and the reader — are on the merge path,
# so a diff that moves either pays for it here rather than at the next nightly.
# The bundle build it falls back to when `./5dive` is absent is NOT in that 1.7s;
# in CI the harness runner has already built it.
#
# DIVE-4532 isolated unit harness — THE SWEPT CLONE'S RUN ROW MUST LAND IN A
# BUCKET SOMEBODY COUNTS.
#
# ══ WHAT WENT DARK, AND WHY NO EXISTING ARM SAW IT ══
#
# `_grader_clone_sweep`'s `resolved:` branch is the ONLY place an ephemeral
# grader clone's run row is ever closed, and it closed the row `status='ok'`.
# `src/cmd_run.sh`'s `cmd_run_metrics` is a CLOSED vocabulary —
#
#   settled          status<>'running'
#   completed        status='completed'
#   abandoned        status='abandoned'
#   parked           status='parked'
#   first_attempt_ok status='completed' AND attempt=1
#
# — and `ok` is in none of it. Measured by quinn on the host board, 2,066 rows:
# `completed 1232 / abandoned 621 / running 182 / parked 30 / ok 1`, that one `ok`
# being `gr-20260914T112022Z-3486917-2`, the first real clone grade. Once every
# grade on the board runs as a clone, `completed` and `first_attempt_ok` stop
# counting grades at all: settled-but-uncounted, at exactly the moment grading
# moves to the new lane. The same UPDATE never stamped `ended_at`, so `run show`
# printed an open-ended run for a seat that had already been reaped.
#
# THE VERDICT SELECTS THE CLOSE PATH, and that is why the DIVE-4496 acceptance
# could not have caught this. That acceptance ran on fixture row DIVE-4511 and the
# clone returned a REJECT — `task reject` closes the verifier's own open run
# through `_run_close_for_task ... completed verifier_rejected` (src/task/
# delivery.sh), so the run row was already terminal and the sweep found no open
# run at all (the `orphan:` branch, which writes nothing). Only a PASS leaves the
# run open for the sweep to close. A fixture set that only ever rejects grades
# HALF the lane and looks complete doing it. Both verdicts are posed below.
#
# ══ WHY THIS FILE IS A REAL SQLITE FIXTURE AND NOT A SQL-TEXT ASSERTION ══
#
# tests/grader_process_unit.sh grades the sweep against a db STUB and asserts on
# the SQL string the sweep emits. That arm is kept and updated, but it structurally
# cannot catch this defect: a string assertion can only check the token the author
# already had in mind, and the defect IS the token. So the arms here run the real
# sweep against a real sqlite store and then ask the SHIPPED READER — `5dive run
# metrics`, the bundle, `cmd_run_metrics` itself — what it counted. If the writer
# and the reader ever disagree again, the disagreement is the failure, whichever
# side moved.
#
# Isolation: its own TASKS_DB, its own backup dir (so the DIVE-1986 auto-restore
# can never pull the live board into the fixture), its own clone seams. It never
# reads the live board and it spawns nothing.
# Run: bash tests/grader_clone_run_close_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

# The reader is the BUNDLE, so it has to exist and it has to be this tree's. A
# missing bundle is built rather than skipped: an end-to-end arm that quietly
# turns into a no-op on a runner is the false green this file was written to
# remove.
if [[ ! -x ./5dive || ./src/cmd_run.sh -nt ./5dive ]]; then
  ./build.sh >/dev/null 2>&1 || true
fi
[[ -x ./5dive ]] || { printf 'FAIL harness — no ./5dive bundle and ./build.sh could not make one\n'; echo "HARNESS-RC=1"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/grader-clone-close.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

export TASKS_DIR="$TMP/store"; export TASKS_DB="$TASKS_DIR/tasks.db"
export TASKS_BACKUP_DIR="$TMP/backups"
mkdir -p "$TASKS_DIR" "$TASKS_BACKUP_DIR"

# `tasks` EXISTS IN THE FIXTURE ON PURPOSE. src/lib/tasks_db.sh treats a missing
# board table beside a sentinel or a backup as an incident and AUTO-RESTORES the
# newest snapshot — which, with only TASKS_DB overridden, is production's. A
# fixture that silently gains 3,120 real rows is not a fixture (DIVE-1986).
sqlite3 "$TASKS_DB" <<'SQL'
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ident TEXT, title TEXT, status TEXT,
  assignee TEXT, verifier TEXT, maker_agent TEXT,
  handoff_delivered_at TEXT, handoff_ack_at TEXT, handoff_rejected_at TEXT,
  started_at TEXT, updated_at TEXT);
CREATE TABLE lifecycle_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, kind TEXT NOT NULL,
  ident TEXT, task_id INTEGER, actor TEXT NOT NULL DEFAULT 't',
  authority TEXT NOT NULL DEFAULT 'self', idem_key TEXT NOT NULL DEFAULT '',
  detail TEXT);
CREATE TABLE runs (
  id TEXT PRIMARY KEY, task_id INTEGER, ident TEXT, agent TEXT, role TEXT,
  attempt INTEGER NOT NULL DEFAULT 1, retry_of TEXT,
  session_id TEXT, journal_unit TEXT, wake_reason TEXT, runtime_type TEXT,
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, ended_at TEXT,
  status TEXT NOT NULL DEFAULT 'running', outcome TEXT,
  human_touch INTEGER NOT NULL DEFAULT 0);
SQL
[[ -n "$(sqlite3 "$TASKS_DB" "SELECT name FROM sqlite_master WHERE name='runs';")" ]] \
  || { printf 'FAIL harness — the fixture store could not be created\n'; exit 1; }

sq(){ sqlite3 -cmd ".timeout 5000" "$TASKS_DB" "$@"; }

# ── the fixture: one PASS-verdict clone, one REJECT-verdict clone, one killed one
#
# Every run row is seeded 10 minutes old so `run metrics`' default 7d window holds
# it and so a stamped `ended_at` produces a non-zero duration.
sq "
INSERT INTO tasks (id,ident,title,status,assignee,verifier,maker_agent,handoff_delivered_at)
  VALUES (1,'DIVE-P','pass row','todo','gr-p-1','quinn','dev',datetime('now','-20 minutes')),
         (2,'DIVE-R','reject row','todo','gr-r-1','quinn','dev',datetime('now','-20 minutes')),
         (3,'DIVE-K','killed row','todo','gr-k-1','quinn','dev',datetime('now','-20 minutes'));

-- P: the clone graded PASS. The row is held open at graded->merge, so NOTHING
-- closed this run — the sweep is the only closer, which is the whole defect.
INSERT INTO runs (id,task_id,ident,agent,role,runtime_type,status,started_at)
  VALUES ('gr-p','1','DIVE-P','gr-p-1','grader','clone','running',datetime('now','-10 minutes'));
INSERT INTO lifecycle_events (ts,kind,ident,idem_key)
  VALUES (datetime('now','-2 minutes'),'task.done','DIVE-P','p1');

-- R: the clone graded REJECT, so src/task/delivery.sh's verifier rail already
-- closed this run through run_close. Seeded exactly as run_close leaves it; the
-- structural arm below pins that seed to the shipped rail.
INSERT INTO runs (id,task_id,ident,agent,role,runtime_type,status,outcome,started_at,ended_at)
  VALUES ('gr-r','2','DIVE-R','gr-r-1','grader','clone','completed','verifier_rejected',
          datetime('now','-10 minutes'), datetime('now','-3 minutes'));
INSERT INTO lifecycle_events (ts,kind,ident,idem_key)
  VALUES (datetime('now','-3 minutes'),'task.rejected','DIVE-R','r1');

-- K: killed mid-grade. No verdict, past the start grace, no CLI alive. The sweep
-- re-queues the delivery and closes the run 'abandoned'.
INSERT INTO runs (id,task_id,ident,agent,role,runtime_type,status,started_at)
  VALUES ('gr-k','3','DIVE-K','gr-k-1','grader','clone','running',datetime('now','-10 minutes'));"

# ── the sweep, run for real against that store ────────────────────────────────
# Only the three FLEET primitives are stubbed (list, remove, liveness): the
# branch logic, both age queries, the verdict query and every UPDATE are the
# shipped code reading and writing the fixture.
RMF="$TMP/removed"; : > "$RMF"
sweep_out=$(
  # shellcheck source=/dev/null
  source src/task/grader_pool.sh
  # shellcheck source=/dev/null
  source src/task/grader_process.sh
  db(){ sq "$*"; }
  sqlq(){ printf "'%s'" "${1//\'/\'\'}"; }
  warn(){ printf 'warn: %s\n' "$*" >&2; }
  ledger_emit(){ return 0; }
  task_actor(){ printf 'harness'; }
  _GRADER_CLONE_LS_CMD='printf "gr-p-1\ngr-r-1\ngr-k-1\n"'
  _GRADER_CLONE_REMOVE_CMD='printf "%s\n" "$clone" >> "$RMF"; return 0'
  _GRADER_CLONE_PRUNE_CMD='return 0'
  # Only the killed clone is dead. Posing the other two as live keeps them off
  # the dead branch for the RIGHT reason.
  _GRADER_CLONE_LIVE_CMD='[[ "$1" != "gr-k-1" ]]'
  _grader_clone_sweep --commit
)

[[ "$sweep_out" == 3 ]] \
  && ok_ 'SWEEP: all three clones are swept in one pass' \
  || bad_ 'SWEEP three clones swept' "swept=$sweep_out removed=$(cat "$RMF")"

# ══ P — THE PASS VERDICT, THE PATH NOTHING BUT THE SWEEP CLOSES ══
p=$(sq "SELECT status||'|'||COALESCE(outcome,'')||'|'||CASE WHEN ended_at IS NULL THEN 'NULL' ELSE 'set' END
          FROM runs WHERE id='gr-p';")
[[ "$p" == "completed|graded|set" ]] \
  && ok_ 'P1: the sweep closes a PASS-graded clone run completed/graded with ended_at stamped' \
  || bad_ 'P1 pass row closed completed with ended_at' "got '$p' (want 'completed|graded|set')"

# ══ K — THE KILLED CLONE. `abandoned` IS a counted bucket, but a settled run with
# no end time still prints open-ended in `run show` and is skipped by the
# mean-duration metric, so the requeue close owes `ended_at` too.
k=$(sq "SELECT status||'|'||COALESCE(outcome,'')||'|'||CASE WHEN ended_at IS NULL THEN 'NULL' ELSE 'set' END
          FROM runs WHERE id='gr-k';")
[[ "$k" == "abandoned|grader_clone_swept|set" ]] \
  && ok_ 'K1: a clone killed mid-grade is closed abandoned/grader_clone_swept with ended_at stamped' \
  || bad_ 'K1 killed row closed abandoned with ended_at' "got '$k' (want 'abandoned|grader_clone_swept|set')"

# ══ R — THE REJECT VERDICT. Its run was terminal BEFORE the sweep ran; the sweep
# must not rewrite a record it did not close.
r=$(sq "SELECT status||'|'||COALESCE(outcome,'')||'|'||CASE WHEN ended_at IS NULL THEN 'NULL' ELSE 'set' END
          FROM runs WHERE id='gr-r';")
[[ "$r" == "completed|verifier_rejected|set" ]] \
  && ok_ 'R1: a REJECT-graded run, already closed by the verifier rail, is left untouched by the sweep' \
  || bad_ 'R1 reject row untouched' "got '$r' (want 'completed|verifier_rejected|set')"

# R1's seed is a claim about ANOTHER file, so it is pinned to that file rather
# than to this author's memory of it. If the reject rail ever stops closing
# `completed verifier_rejected`, this arm says so instead of R1 passing against a
# fixture that no longer describes the product.
grep -q '_run_close_for_task "\$id" completed verifier_rejected' src/task/delivery.sh \
  && ok_ 'R2: the reject rail this fixture models still closes the run completed/verifier_rejected' \
  || bad_ 'R2 reject rail contract' 'src/task/delivery.sh no longer closes a rejection completed/verifier_rejected'

# ══ THE READER. The arms above assert what was WRITTEN; this is the question the
# row was filed on — does the fleet's own metric COUNT it? ══
j=$(./5dive run metrics --json 2>/dev/null)
g(){ printf '%s' "$j" | python3 -c "import json,sys;print(json.load(sys.stdin)['data'].get('$1'))" 2>/dev/null; }

[[ "$(g total)" == 3 ]] \
  && ok_ 'M0: the reader sees exactly the three fixture runs (no live board leaked in)' \
  || bad_ 'M0 fixture isolation' "total=$(g total) json=$j"
[[ "$(g settled)" == 3 && "$(g completed)" == 2 ]] \
  && ok_ 'M1: BOTH verdicts land in the completed bucket — settled 3, completed 2' \
  || bad_ 'M1 both verdicts counted' "settled=$(g settled) completed=$(g completed)"
[[ "$(g first_attempt_ok)" == 2 ]] \
  && ok_ 'M2: first_attempt_ok counts the clone grades again' \
  || bad_ 'M2 first_attempt_ok' "got $(g first_attempt_ok)"
[[ "$(g abandoned)" == 1 ]] \
  && ok_ 'M3: the killed clone is counted abandoned, not lost' \
  || bad_ 'M3 abandoned' "got $(g abandoned)"

# THE UNCOUNTED-TOKEN PROPERTY ITSELF, stated as a property rather than as a list
# of the four buckets: every settled run must be in one of them. A future writer
# inventing a fifth token fails here even if it never touches the sweep.
uncounted=$(sq "SELECT COUNT(*) FROM runs
                 WHERE status<>'running'
                   AND status NOT IN ('completed','abandoned','parked');")
[[ "$uncounted" == 0 ]] \
  && ok_ 'M4: no settled run carries a status token cmd_run_metrics does not count' \
  || bad_ 'M4 uncounted settled runs' "$uncounted row(s) settled outside completed/abandoned/parked"

# And `ended_at`'s own readers. AVG() SKIPS NULLS, so `mean_duration_s` being a
# number proves only that SOME row had an end time — it went on reading fine with
# the resolved branch stamping nothing. The property is therefore stated over the
# rows: no settled run may be missing its end time, which is also what stops
# `run show` printing an open-ended run for a seat that has been reaped.
openended=$(sq "SELECT COUNT(*) FROM runs WHERE status<>'running' AND ended_at IS NULL;")
[[ "$openended" == 0 && "$(g mean_duration_s)" =~ ^[0-9]+$ ]] \
  && ok_ 'M5: no settled run is left open-ended, so mean_duration_s covers all of them' \
  || bad_ 'M5 ended_at coverage' "settled-with-no-ended_at=$openended mean_duration_s='$(g mean_duration_s)'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
