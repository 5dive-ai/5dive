#!/usr/bin/env bash
# TIER: core
# DIVE-3275 — `task set-parent`.
#
# `parent_id` was INSERT-only: `task add --parent=` was the only moment a parent
# edge could ever be written, so a row split out of another and filed without it
# could never be attached. DIVE-3138 was split out of DIVE-2895 in prose, filed
# unparented, and `task show DIVE-2895` therefore rendered no edge — so the maker
# closing DIVE-2895 asserted an item was blocked on work DIVE-3138 had finished
# 2h36m earlier. The fix list said "set parent_id on DIVE-3138" and no verb could.
#
# Run: bash tests/task_set_parent_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-set-parent.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
cmd_send() { return 0; }; audit_log() { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] lacks [$3]"; fi; }
no_t()  { if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] unexpectedly contains [$3]"; fi; }
# The parent edge, read back as the PARENT's ident — the reader's view, which is
# the only view that mattered on DIVE-2895.
parent_of() { db "SELECT COALESCE((SELECT p.ident FROM tasks p WHERE p.id=c.parent_id),'∅')
                  FROM tasks c WHERE c.ident='$1';"; }
rowid()  { db "SELECT id FROM tasks WHERE ident='$1';"; }
# Seed with an explicit row id so the id/ident divergence this verb guards
# against can be reproduced exactly.
seed()   { db "INSERT INTO tasks (id,ident,title,priority,assignee,created_by,kind,status)
                VALUES (${4:-NULL},'$1','${2:-a row}','medium','dev','main','standard','${3:-todo}');"; }

# ── A. the motivating case: attach a row that is ALREADY CLOSED ───────────────
# Deliberately not set-title's refusal. A close freezes what was ASSERTED (body,
# result); parent_id is a navigation edge, and its ABSENCE is the defect — the
# row that needed this verb was closed when its missing edge produced the false
# premise. A blanket closed-row refusal would ship a verb that cannot fix the
# case that motivated it.
seed T-100 "the epic"                  todo
seed T-101 "split out of T-100, closed" done
OUT=$( (cmd_task_set_parent T-101 T-100) 2>&1 ); RC=$?
eq_t "A1: a CLOSED row can be re-parented (rc 0)" "$RC" "0"
eq_t "A1b: ... and the edge really landed" "$(parent_of T-101)" "T-100"
eq_t "A1c: ... without reopening it" "$(db "SELECT status FROM tasks WHERE ident='T-101';")" "done"
# Self-verifying: the writer's exit code is not evidence of a parent edge; the
# reader's view is. That is the wiki lesson this verb is built from.
has_t "A2: the receipt PRINTS the parent's resulting child list" "$OUT" "subtasks of T-100 now:"
has_t "A2b: ... and the child is in it" "$OUT" "T-101"
has_t "A3: the audit row keeps the PRIOR parent" "$(cat "$AUDIT_ROWS")" "prior=none"
has_t "A3b: ... and the new one" "$(cat "$AUDIT_ROWS")" "new=T-100"

: >"$AUDIT_ROWS"
OUT=$( (cmd_task_set_parent T-101 T-100) 2>&1 ); RC=$?
eq_t "A4: re-setting the same parent is a no-op (rc 0)" "$RC" "0"
has_t "A4b: ... and says so" "$OUT" "unchanged"
eq_t "A4c: ... and writes NO audit row" "$(wc -l < "$AUDIT_ROWS")" "0"
has_t "A4d: ... but still shows the reader's view" "$OUT" "subtasks of T-100 now:"

# ── B. detach ────────────────────────────────────────────────────────────────
OUT=$( (cmd_task_set_parent T-101 none) 2>&1 ); RC=$?
eq_t "B1: 'none' detaches (rc 0)" "$RC" "0"
eq_t "B1b: ... and parent_id is NULL" "$(parent_of T-101)" "∅"
# The absence has to be visible where it now matters: the FORMER parent's list.
has_t "B2: detach shows the former parent's list" "$OUT" "subtasks of T-100 now:"
has_t "B2b: ... which is now empty" "$OUT" "(none)"
OUT=$( (cmd_task_set_parent T-101 --parent=none) 2>&1 ); RC=$?
eq_t "B3: --parent=none is accepted too, and is a no-op here" "$RC" "0"
OUT=$( (cmd_task_set_parent T-101 --parent=T-100) 2>&1 ); RC=$?
eq_t "B4: --parent=<ident> is accepted" "$RC" "0"
eq_t "B4b: ... and lands" "$(parent_of T-101)" "T-100"
OUT=$( (cmd_task_set_parent T-101 T-100 --parent=T-100) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "B5: naming the parent twice is a usage error" \
  || bad_t "B5: naming the parent twice is a usage error" "rc=$RC"

# ── C. the cascade-armed refusals ────────────────────────────────────────────
# parent_id REFERENCES tasks(id) ON DELETE CASCADE — a wrong parent does not just
# mis-render, it arms the child's deletion.
OUT=$( (cmd_task_set_parent T-101 T-101) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "C1: self-parenting is refused" || bad_t "C1: self-parenting is refused" "rc=$RC"
eq_t "C1b: ... and the existing edge is untouched" "$(parent_of T-101)" "T-100"

# T-100 -> T-101 would close the loop the other way round.
OUT=$( (cmd_task_set_parent T-100 T-101) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "C2: a 2-row cycle is refused" || bad_t "C2: a 2-row cycle is refused" "rc=$RC"
has_t "C2b: ... naming the chain it walked" "$OUT" "cycle"
eq_t "C2c: ... and T-100 stays unparented" "$(parent_of T-100)" "∅"

# Deeper: T-102 -> T-101 -> T-100. Re-parenting T-100 under T-102 is a 3-hop cycle.
seed T-102 "a grandchild"
OUT=$( (cmd_task_set_parent T-102 T-101) 2>&1 ); RC=$?
eq_t "C3: a 3-level chain builds fine" "$RC" "0"
OUT=$( (cmd_task_set_parent T-100 T-102) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "C4: a 3-hop cycle is refused too" || bad_t "C4: a 3-hop cycle is refused too" "rc=$RC"

# A pre-existing cycle (only reachable by a raw sqlite write, which is exactly
# what this verb exists to displace) must make the walk REFUSE, never hang.
seed T-110 "cyclic a"; seed T-111 "cyclic b"; seed T-112 "an innocent row"
db "UPDATE tasks SET parent_id=(SELECT id FROM tasks WHERE ident='T-111') WHERE ident='T-110';"
db "UPDATE tasks SET parent_id=(SELECT id FROM tasks WHERE ident='T-110') WHERE ident='T-111';"
OUT=$( (cmd_task_set_parent T-112 T-110) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "C5: a PRE-EXISTING cycle is refused, not walked forever" \
  || bad_t "C5: a PRE-EXISTING cycle is refused, not walked forever" "rc=$RC"
eq_t "C5b: ... and the innocent row is untouched" "$(parent_of T-112)" "∅"

OUT=$( (cmd_task_set_parent T-101 NOPE-99) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "C6: a nonexistent parent is refused (it would arm a cascade)" \
  || bad_t "C6: a nonexistent parent is refused" "rc=$RC"
OUT=$( (cmd_task_set_parent T-101) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "C7: a missing parent argument is a usage error" \
  || bad_t "C7: a missing parent argument is a usage error" "rc=$RC"

# ── D. THE BARE-NUMBER GUARD, on set-parent (section G grades it on task add) ─
# resolve_task_id branches on argument SHAPE: ^[0-9]+$ is the GLOBAL ROW ID,
# ^[A-Za-z]+-[0-9]+$ is the ident. The two number spaces have diverged in the
# real store — DIVE-2895 is row id 3082, and row id 2895 is DIVE-2708, a
# cancelled row from another month. That is how DIVE-3273 was filed under the
# wrong parent with no error at all: a valid id naming the wrong row.
seed T-200 "the row a caller means when they type 200" todo 9200
seed T-9200 "the DIFFERENT row that the bare number 9200 actually resolves to" todo 9201
eq_t "D0: the divergence is set up (row id 9200 is NOT ident T-9200)" \
     "$(db "SELECT ident FROM tasks WHERE id=9200;")" "T-200"
OUT=$( (cmd_task_set_parent T-101 9200) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "D1: a bare number resolving to a DIFFERENT ident number is REFUSED" \
  || bad_t "D1: a bare number resolving to a DIFFERENT ident number is REFUSED" "rc=$RC"
has_t "D1b: ... naming the row it actually resolved to" "$OUT" "T-200"
# The instruction, not the verb name: the guard is SHARED with `task add --parent`
# (src/lib/tasks_db.sh), so its message must not name one verb — but it still has
# to hand the caller something to type.
has_t "D1c: ... and telling the caller what to type instead" "$OUT" "by IDENT: T-200"
has_t "D1c2: ... and offering the ident they probably meant" "$OUT" "DIVE-9200"
eq_t "D1d: ... and nothing was written" "$(parent_of T-101)" "T-100"

# The same guard on the CHILD argument: a mis-resolved child re-parents the
# wrong row, which is the identical failure with the identical cascade.
OUT=$( (cmd_task_set_parent 9200 T-100) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "D2: the guard covers the CHILD argument too" \
  || bad_t "D2: the guard covers the CHILD argument too" "rc=$RC"
eq_t "D2b: ... and T-200 was not re-parented" "$(parent_of T-200)" "∅"

# A bare number that DOES agree with its ident still warns — it is a global row
# id that happens to line up today, and `--parent=<id>` in task add's help text
# is what made the bare form look intended.
seed NUM-9300 "ident number equals row id" todo 9300
OUT=$( (cmd_task_set_parent T-101 9300) 2>&1 ); RC=$?
eq_t "D3: an AGREEING bare number is accepted (rc 0)" "$RC" "0"
has_t "D3b: ... but warns loudly, naming the row" "$OUT" "NUM-9300"
has_t "D3c: ... and says to prefer the ident form" "$OUT" "Prefer the ident form"
eq_t "D3d: ... and the edge landed" "$(parent_of T-101)" "NUM-9300"
# The ident form is the quiet path — no warning to train people to ignore.
OUT=$( (cmd_task_set_parent T-101 T-100) 2>&1 ); RC=$?
no_t "D4: the IDENT form warns about nothing" "$OUT" "bare number"

# ── E. a recurring template has no parent by construction ────────────────────
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
    VALUES ('T-300','a recurring template','medium','dev','main','recurring','todo');"
OUT=$( (cmd_task_set_parent T-300 T-100) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "E1: a recurring TEMPLATE is refused (task add refuses --recurring with --parent)" \
  || bad_t "E1: a recurring TEMPLATE is refused" "rc=$RC"

# ── F. the acceptance shape: task show renders the edge ──────────────────────
# The verb's whole point is the READER's view, so grade that and not the UPDATE.
cmd_task_set_parent T-101 T-100 >/dev/null 2>&1
SHOW=$( (cmd_task_show T-100) 2>&1 )
has_t "F1: task show <parent> renders a subtasks block" "$SHOW" "subtasks:"
has_t "F1b: ... containing the re-parented row" "$SHOW" "T-101"

# ── G. the SAME guard on `task add --parent`, the surface that actually misfired ─
# DIVE-3275 folds this in (main's call, 2026-08-12): DIVE-3273 was filed under
# DIVE-2708 by `--parent=2895` with no error, and the remedy shipped at the time
# was a written rule. A rule is not a guard, and this is one function from the
# verb above on the same surface — a separate row would buy a second review of
# the same code.
FIVE_VERIFY_DEFAULT=0; FIVE_FILING_CAP=0
add_out() { ( JSON_MODE=0; cmd_task_add "$@" ) 2>&1; }

OUT=$(add_out --parent=9200 "a child filed under a bare number"); RC=$?
[[ "$RC" != "0" ]] && ok_t "G1: task add --parent=<divergent bare number> is REFUSED" \
  || bad_t "G1: task add --parent=<divergent bare number> is REFUSED" "rc=$RC"
has_t "G1b: ... naming the row it actually resolved to" "$OUT" "T-200"
has_t "G1c: ... and naming the argument that was wrong" "$OUT" "--parent"
# The refusal must land BEFORE the INSERT — a row created under the wrong parent
# is the exact damage, and half-doing it is worse than refusing.
eq_t "G1d: ... and NO row was created" \
     "$(db "SELECT COUNT(*) FROM tasks WHERE title='a child filed under a bare number';")" "0"

OUT=$(add_out --parent=NUM-9300 "a child filed by ident"); RC=$?
eq_t "G2: the ident form still works (rc 0)" "$RC" "0"
eq_t "G2b: ... and the edge is real" \
     "$(db "SELECT (SELECT p.ident FROM tasks p WHERE p.id=c.parent_id) FROM tasks c WHERE c.title='a child filed by ident';")" \
     "NUM-9300"
no_t "G3: ... and it warns about no bare number" "$OUT" "bare number"

OUT=$(add_out --parent=9300 "a child filed under an agreeing bare number"); RC=$?
eq_t "G4: an AGREEING bare number is still accepted (rc 0)" "$RC" "0"
has_t "G4b: ... but warns, so the habit is visible" "$OUT" "bare number"
eq_t "G4c: ... and the edge landed" \
     "$(db "SELECT (SELECT p.ident FROM tasks p WHERE p.id=c.parent_id) FROM tasks c WHERE c.title='a child filed under an agreeing bare number';")" \
     "NUM-9300"

# The help text is what made the bare form look intended (wiki, Delta 2026-08-11).
has_t "G5: the add help line names the IDENT form" "$( (_task_usage) 2>&1 )" "--parent=<DIVE-N>"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
