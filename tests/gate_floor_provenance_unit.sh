#!/usr/bin/env bash
# DIVE-2615 — A GATE MUST RECORD WHY IT HAS THE TIER IT HAS.
#
# THE INCIDENT, and it is a measurement incident rather than a behaviour one.
# lodar was interrupted three times in ten minutes on 2026-08-03 by gates that were
# not his to answer. Answering the first question anyone asks about that — "how many
# of these did the tier-2 floor over-fire on?" — turned out to be unanswerable from
# the store. `gate_history.floor_provenance` existed on the live box and was NULL on
# all 79 rows, because it had NO writer, NO migration and no reference anywhere in
# src/ or tests/: a column added out-of-band that nothing ever filled.
#
# So the split had to be reconstructed by building a bundle, stripping its `main`
# call, sourcing it, and re-running this file's own predicates over asks re-read
# from the store. Two attempts at that were VOID (one built from a dirty feature
# branch with no DIVE-2629 in it; one ran the bare predicate per field instead of
# `_gate_floor_axis`, which is what the filing path actually calls). Every input to
# the tier decision is computed in `cmd_task_need` and then discarded. This file
# grades that they are kept.
#
# THE DISTINCTION THAT MAKES THE COLUMN WORTH ANYTHING, and arm 6 exists only for
# it: NULL and `axis=none` are DIFFERENT FACTS. NULL means this build never recorded
# it — every row filed before this ships. `axis=none` means the floor RAN and did
# not fire. An empty value that means both "no data" and "no hit" is what made the
# pre-existing column measure nothing, so a writer that emits NULL on a clean gate
# would reproduce the defect while looking like a fix. Arm 6 and arm 11 are a pair:
# 6 asserts the clean gate says `none`, 11 asserts a row the writer never touched
# stays NULL, and only both together pin the distinction.
#
# THE SIX VALUES, and each is a different actor's decision:
#   axis=pinned        the FILER passed --tier=2. The floor was never consulted.
#                      12 of the 48 tier-2 gates that pinged the human in the 7 days
#                      to 2026-08-03 — the largest single population, and invisible
#                      from the row before this, which made the filer's own choice
#                      read as the classifier's doing.
#   axis=type-default  manual/secret/access, where 2 is the type default and nobody
#                      chose anything. Read off `tier_arg`, not `tier` — by that line
#                      the default has been applied and the effective tier cannot
#                      tell the two apart (the distinction DIVE-1182 captured
#                      `tier_arg` for, two lines above).
#   axis=secret-type   type=secret, floored by type without consulting the floor.
#   axis=ask           the floor fired on the ask. THE tier-2 gate.
#   axis=title-fallback the floor fired on the title because the ask states nothing
#                      of its own — floored, deliberately, failing closed.
#   axis=none          the floor ran and did not fire.
# plus `;term=<t>` wherever a term is what fired, so "floored on 'publish'" is a
# stored fact and not something a reader re-derives with a regex.
#
# WHAT THIS FILE DOES NOT CLAIM. It does not grade the floor's verdicts — that is
# tests/gate_floor_branch_name_unit.sh and the classifiers' own harnesses. It grades
# that whatever the floor decided is WRITTEN DOWN, on the same statement that writes
# the tier, and that it survives into gate_history when the gate is retired.
#
# Run: bash tests/gate_floor_provenance_unit.sh   (no root, no network.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
. "$(dirname "${BASH_SOURCE[0]}")/lib/env_isolation.sh" 2>/dev/null || true
declare -F _five_env_isolate >/dev/null && _five_env_isolate
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-floor-prov.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }              # no DM on filing
_task_human_send_allowed() { return 0; }
audit_log() { :; }

seed() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ($(sqlq "$1"),$(sqlq "$2"),'todo','main');"; }
prov() { db "SELECT COALESCE(floor_provenance,'<NULL>') FROM tasks WHERE ident=$(sqlq "$1");"; }
tier_of() { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

# --- 0. the column exists at all, on a store this build created -----------------
# The pre-existing live column proves nothing about a fresh box: it was added
# out-of-band. This asserts our OWN schema carries it, on both tables.
for t in tasks gate_history; do
  [[ "$(db "SELECT 1 FROM pragma_table_info('$t') WHERE name='floor_provenance';")" == "1" ]] \
    && ok_t "schema: $t.floor_provenance exists on a freshly-initialised store" \
    || bad_t "$t must carry floor_provenance" "a fresh store built by tasks_db_init has no such column"
done

# --- 1. axis=pinned — the filer chose it ---------------------------------------
seed DIVE-9001 'ordinary title'
( cmd_task_need DIVE-9001 --type=decision --ask="pick a lane" --options="A|B" --recommend=A --tier=2 >/dev/null 2>&1 )
[[ "$(prov DIVE-9001)" == "axis=pinned" && "$(tier_of DIVE-9001)" == "2" ]] \
  && ok_t 'an explicit --tier=2 records axis=pinned (the filer chose the human, not the floor)' \
  || bad_t 'explicit --tier=2 must record axis=pinned' "got [$(prov DIVE-9001)] tier=$(tier_of DIVE-9001)"

# --- 2. axis=type-default — nobody chose anything -------------------------------
# `manual` defaults to tier 2. The effective tier is identical to arm 1's; only
# tier_arg separates them, which is the whole reason this value is distinct.
seed DIVE-9002 'ordinary title'
( cmd_task_need DIVE-9002 --type=manual --ask="do the thing by hand" >/dev/null 2>&1 )
[[ "$(prov DIVE-9002)" == "axis=type-default" && "$(tier_of DIVE-9002)" == "2" ]] \
  && ok_t 'a type-defaulted tier 2 is recorded as type-default, NOT as pinned' \
  || bad_t 'type-default must not be reported as a filer choice' "got [$(prov DIVE-9002)] tier=$(tier_of DIVE-9002)"
[[ "$(prov DIVE-9001)" != "$(prov DIVE-9002)" ]] \
  && ok_t 'differential: two gates at the SAME effective tier 2 record different causes' \
  || bad_t 'pinned and type-default must be distinguishable' 'both read the same — tier_arg is not being consulted'

# --- 3. axis=ask + term — the floor fired on the ask ----------------------------
seed DIVE-9003 'ordinary title'
( cmd_task_need DIVE-9003 --type=decision --ask="approve the spend on a bigger volume" --options="A|B" --recommend=A >/dev/null 2>&1 )
[[ "$(prov DIVE-9003)" == "axis=ask;term=spend" && "$(tier_of DIVE-9003)" == "2" ]] \
  && ok_t 'a floored ask records the axis AND the term that fired' \
  || bad_t 'axis=ask must carry the term' "got [$(prov DIVE-9003)] tier=$(tier_of DIVE-9003)"

# --- 4. axis=title — floored on nothing, routed by kind ------------------------
# DIVE-2224: a category term in the TITLE with a substantive ask does NOT floor.
# The row must still say so — "not floored, and here is the term I saw" is exactly
# the fact a reviewer needs, and it is the bucket 4 of tonight's 48 fell into.
seed DIVE-9004 'delete the old customer records table'
( cmd_task_need DIVE-9004 --type=decision --ask="which of the two rendering libraries should the panel use, A or B" --options="A|B" --recommend=A >/dev/null 2>&1 )
[[ "$(prov DIVE-9004)" == "axis=title;term=delete" ]] \
  && ok_t 'a title-only category term records axis=title with its term' \
  || bad_t 'axis=title must be recorded' "got [$(prov DIVE-9004)]"
[[ "$(tier_of DIVE-9004)" == "1" ]] \
  && ok_t 'liveness pair: that gate is NOT floored — provenance records a term WITHOUT a tier change' \
  || bad_t 'a title-axis term must not floor the gate' "tier=$(tier_of DIVE-9004) — if this is 2, arm 4 is recording the wrong thing"

# --- 5. axis=title-fallback — the ask states nothing of its own -----------------
seed DIVE-9005 'delete the old customer records table'
( cmd_task_need DIVE-9005 --type=decision --ask="?" --options="A|B" --recommend=A >/dev/null 2>&1 )
[[ "$(prov DIVE-9005)" == "axis=title-fallback;term=delete" && "$(tier_of DIVE-9005)" == "2" ]] \
  && ok_t 'an insubstantial ask floors on the title and records title-fallback' \
  || bad_t 'title-fallback must be recorded and must floor' "got [$(prov DIVE-9005)] tier=$(tier_of DIVE-9005)"

# --- 6. axis=none — the floor RAN and did not fire ------------------------------
seed DIVE-9006 'panel rendering library choice'
( cmd_task_need DIVE-9006 --type=decision --ask="which of the two rendering libraries should the panel use, A or B" --options="A|B" --recommend=A >/dev/null 2>&1 )
[[ "$(prov DIVE-9006)" == "axis=none" ]] \
  && ok_t 'a clean gate records axis=none — "ran, no hit", not an empty cell' \
  || bad_t 'a non-floored gate must still record that the floor ran' "got [$(prov DIVE-9006)] — NULL here reproduces the defect this ticket exists to fix"

# --- 7. secret: type-default vs secret-type are DIFFERENT ROUTES to tier 2 ------
# Written to assert `secret-type` on a plain `--type=secret`, which was WRONG and
# this arm caught it. `secret` defaults to tier 2, so the default is applied BEFORE
# the floor block and a plain secret gate never reaches the type-floor at all — it
# is a type-default like any other. `secret-type` is reachable only when the filer
# asks for a LOWER tier and the type forces it back up, which is a different event
# and deserves a different value. Both are graded so neither can quietly become the
# other.
#
# --secret-key and --connector are required TOGETHER. Given wrong, cmd_task_need
# calls fail(), which under a SOURCED harness exits the whole suite here and takes
# arms 8-11 with it — silently, since the tail then prints no total. Every
# cmd_task_need below is run for its EFFECT and asserted from the store, never
# trusted to return.
seed DIVE-9007 'ordinary title'
( cmd_task_need DIVE-9007 --type=secret --ask="the deploy key" --secret-key=DEPLOY_KEY --connector=github >/dev/null 2>&1 )
[[ "$(prov DIVE-9007)" == "axis=type-default" && "$(tier_of DIVE-9007)" == "2" ]] \
  && ok_t 'a plain secret gate is a type-default — the type floor is never consulted' \
  || bad_t 'plain secret must record type-default' "got [$(prov DIVE-9007)] tier=$(tier_of DIVE-9007)"
seed DIVE-9012 'ordinary title'
( cmd_task_need DIVE-9012 --type=secret --tier=1 --ask="the deploy key" --secret-key=DEPLOY_KEY --connector=github >/dev/null 2>&1 )
[[ "$(prov DIVE-9012)" == "axis=secret-type" && "$(tier_of DIVE-9012)" == "2" ]] \
  && ok_t 'a secret filed at tier 1 is forced up BY TYPE and says so (secret-type)' \
  || bad_t 'a down-tiered secret must record secret-type' "got [$(prov DIVE-9012)] tier=$(tier_of DIVE-9012)"

# --- 8. it survives into gate_history when the gate is retired -----------------
# The archive is the only durable record once a row is re-filed or withdrawn, and
# the reconstruction that motivated this ticket read gate_history, not tasks.
seed DIVE-9008 'ordinary title'
( cmd_task_need DIVE-9008 --type=decision --ask="approve the spend on a bigger volume" --options="A|B" --recommend=A >/dev/null 2>&1 )
( cmd_task_need DIVE-9008 --type=decision --ask="which rendering library, A or B" --options="A|B" --recommend=A >/dev/null 2>&1 )
hist=$(db "SELECT COALESCE(floor_provenance,'<NULL>') FROM gate_history WHERE ident='DIVE-9008' ORDER BY id LIMIT 1;")
[[ "$hist" == "axis=ask;term=spend" ]] \
  && ok_t 'the archived gate keeps its provenance in gate_history' \
  || bad_t 'gate_history must carry floor_provenance' "got [$hist]"
[[ "$(prov DIVE-9008)" == "axis=none" ]] \
  && ok_t 'and the re-filed gate on the same row records its OWN, different cause' \
  || bad_t 're-file must overwrite provenance' "got [$(prov DIVE-9008)]"

# --- 9. withdraw clears it -----------------------------------------------------
# A row with no gate must not keep reporting why it had a tier. The value is not
# lost — arm 8 is why: the archive took a copy on the way out.
seed DIVE-9009 'ordinary title'
( cmd_task_need DIVE-9009 --type=decision --ask="approve the spend on a bigger volume" --options="A|B" --recommend=A >/dev/null 2>&1 )
( cmd_task_need DIVE-9009 --withdraw >/dev/null 2>&1 )
[[ "$(prov DIVE-9009)" == "<NULL>" ]] \
  && ok_t 'withdraw clears the provenance off the task row' \
  || bad_t 'a withdrawn gate must not keep its floor provenance' "got [$(prov DIVE-9009)]"
[[ -n "$(db "SELECT floor_provenance FROM gate_history WHERE ident='DIVE-9009';")" ]] \
  && ok_t 'liveness pair: the withdrawn gate kept its provenance in history (cleared, not destroyed)' \
  || bad_t 'withdraw must archive before it clears' 'history row has no provenance — the clear ran ahead of the copy'

# --- 10. the ADDITIVE migration, on a store that predates the column -----------
# The CREATE only runs when gate_history is ABSENT, so on every box that has ever
# filed a gate a new column in the CREATE reaches nothing. This builds that store
# on purpose: table present, column missing.
#
# THE FIXTURE HAS TO CARRY A `tasks` TABLE or it proves nothing: tasks_db_init runs
# the migration ONLY when `tasks` already exists, so a fixture holding gate_history
# alone takes the fresh-store path, the CREATE runs, and the arm passes for the one
# reason it must not — it never exercised the migration. Written that way first;
# it read before=0 after=0 and that is what exposed it. So: build a REAL store,
# then put gate_history back the way a pre-DIVE-2615 box has it.
OLD="$TMP/old"; mkdir -p "$OLD/tasks"
( STATE_DIR="$OLD"; TASKS_DIR="$OLD/tasks"; TASKS_DB="$OLD/tasks/tasks.db"; tasks_db_init >/dev/null 2>&1 )
sqlite3 "$OLD/tasks/tasks.db" "DROP TABLE gate_history; CREATE TABLE gate_history (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id INTEGER NOT NULL, retired_by TEXT NOT NULL);" 2>/dev/null
before=$(sqlite3 "$OLD/tasks/tasks.db" "SELECT COUNT(*) FROM pragma_table_info('gate_history') WHERE name='floor_provenance';")
[[ "$(sqlite3 "$OLD/tasks/tasks.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='tasks';")" == "1" ]] \
  && ok_t 'migration fixture: the store has a tasks table, so init takes the MIGRATE path (not fresh-create)' \
  || bad_t 'the fixture must look like an existing store' 'no tasks table — init would fresh-create and the next arm would be vacuous'
( STATE_DIR="$OLD"; TASKS_DIR="$OLD/tasks"; TASKS_DB="$OLD/tasks/tasks.db"; tasks_db_init >/dev/null 2>&1 )
after=$(sqlite3 "$OLD/tasks/tasks.db" "SELECT COUNT(*) FROM pragma_table_info('gate_history') WHERE name='floor_provenance';")
[[ "$before" == "0" && "$after" == "1" ]] \
  && ok_t "migration: a pre-existing gate_history gains the column (before=$before after=$after)" \
  || bad_t 'the additive migration must reach an existing gate_history' "before=$before after=$after — before must be 0 or this arm proves nothing"

# --- 11. NULL still means "never recorded" -------------------------------------
# The other half of arm 6. A row the writer has not touched must read NULL, so the
# two facts stay separable on a store that spans the release boundary.
seed DIVE-9011 'ordinary title'
[[ "$(prov DIVE-9011)" == "<NULL>" ]] \
  && ok_t 'a row with no gate reads NULL — distinguishable from a gate whose floor found nothing' \
  || bad_t 'an ungated row must be NULL, not axis=none' "got [$(prov DIVE-9011)]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
