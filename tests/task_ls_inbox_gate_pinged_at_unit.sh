#!/usr/bin/env bash
# `task ls --json` and `task inbox --json` carry `gate_pinged_at`, the same column
# `task show --json` has always carried.
#
# THE DEFECT. gate_pinged_at is the gate's last CONFIRMED delivery receipt and the
# re-nag throttle (src/cmd_heartbeat.sh reads it; src/task/notify.sh writes it).
# `task show --json` returns it because it does `SELECT *`; `task ls --json` and
# `task inbox --json` are explicit column lists, and neither named it. Both list
# projections drop null-valued keys generally (DIVE-1610), so a consumer reading
# `.gate_pinged_at` off `ls` or `inbox` — the surfaces an agent naturally queries
# for "which gates" — got null on EVERY row and could not tell "omitted by the
# serializer" from "never pinged". One such read produced a board-wide false "no
# gate was ever delivered" finding that two seats acted on. DIVE-2777 was this
# shape on handoff_delivered_at; this is the same shape on the gate receipt.
#
# ASSERTED ON A ROW WHOSE VALUE IS NON-NULL, for DIVE-2777's reason: a fixture
# with a null receipt reads identically before and after the fix. The paired
# never-pinged row is the negative control — its key must be absent on all three
# surfaces alike, so absence keeps meaning NULL and means the same thing
# everywhere. Against a src/ without the fix, arms A1, A2 and A4 go red.
#
# Run: bash tests/task_ls_inbox_gate_pinged_at_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-gate-pinged-at.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# AFTER header.sh, which assigns it unconditionally: this harness audits nothing
# for real, whatever the fence in src/lib/audit.sh does on the tree it grades.
AUDIT_LOG="$TMP/agent-audit.log"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
cmd_send() { return 0; }; audit_log() { return 0; }
_task_store_audit_log() { return 0; }
cat > "$TMP/agents.json" <<'JSON'
{"agents":{"main":{"type":"claude","heartbeat":{"enabled":true}}}}
JSON
_TASK_ROSTER=""; _TASK_ROSTER_STATE=""

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }

# Two LIVE HUMAN gates (need_type set, unanswered, tier 2, no routed reviewer —
# the inbox predicate), one pinged, one never. The receipt is a fixed timestamp,
# not now(): a value the arms can compare byte-for-byte across surfaces.
PINGED='2026-09-15 09:59:21'
seed() { # <id> <ident> <gate_pinged_at SQL literal or NULL>
  db "INSERT INTO tasks (id,ident,title,status,priority,assignee,created_by,need_type,tier,ask,recommend,need_options,need_asked_at,gate_pinged_at,created_at)
      VALUES ($1,'$2','a gate','blocked','high','main','main','decision',2,'ship it?','A','A|B',datetime('now','-1 hour'),$3,datetime('now','-1 hour'));"
}
seed 9001 DIVE-9001 "'$PINGED'"
seed 9002 DIVE-9002 NULL

# Each surface as JSON on stdout. Subshells: the verbs end in ok/fail, which exit.
ls_json()    { ( cmd_task_ls --all ) 2>"$TMP/ls.err"; }
inbox_json() { ( cmd_task_inbox ) 2>"$TMP/inbox.err"; }
show_json()  { ( cmd_task_show "$1" ) 2>"$TMP/show.err"; }
# `has` distinguishes an ABSENT key from a null one; the row projections drop
# nulls, so "absent" is the shape the negative control must show.
ls_field()    { ls_json    | jq -r --arg i "$1" --arg k "$2" '.data.tasks[] | select(.ident==$i) | if has($k) then .[$k] else "<absent>" end'; }
inbox_field() { inbox_json | jq -r --arg i "$1" --arg k "$2" '.data.inbox[] | select(.ident==$i) | if has($k) then .[$k] else "<absent>" end'; }
show_field()  { show_json "$1" | jq -r --arg k "$2" '[.. | objects | select(has("ident") and has("status")) | if has($k) then .[$k] else "<absent>" end] | first // "<no row>"'; }

# ---- REACHABILITY: every surface returns the fixture rows before anything is
# asserted about their fields (an empty projection would read "<absent>" too).
eq_t "R1: task ls --json lists both fixture gates"     "$(ls_json | jq -r '[.data.tasks[].ident] | sort | join(",")')"  "DIVE-9001,DIVE-9002"
eq_t "R2: task inbox --json lists both as human gates" "$(inbox_json | jq -r '[.data.inbox[].ident] | sort | join(",")')" "DIVE-9001,DIVE-9002"
eq_t "R3: task show --json returns the pinged row"     "$(show_field DIVE-9001 ident)" "DIVE-9001"

# ---- ARM A: the PINGED row, on all three surfaces ------------------------------
eq_t "A1: task ls --json carries gate_pinged_at on a pinged gate"    "$(ls_field DIVE-9001 gate_pinged_at)"    "$PINGED"
eq_t "A2: task inbox --json carries gate_pinged_at on a pinged gate" "$(inbox_field DIVE-9001 gate_pinged_at)" "$PINGED"
eq_t "A3: task show --json still carries it (the surface that always did)" "$(show_field DIVE-9001 gate_pinged_at)" "$PINGED"
# A4 is the report's expectation stated as one line: the surfaces agree.
if [[ "$(ls_field DIVE-9001 gate_pinged_at)" == "$(show_field DIVE-9001 gate_pinged_at)" \
   && "$(inbox_field DIVE-9001 gate_pinged_at)" == "$(show_field DIVE-9001 gate_pinged_at)" ]]; then
  ok_t "A4: ls, inbox and show agree on the receipt (one column, one query each, no rebuilt rule)"
else
  bad_t "A4: the three surfaces agree" "ls=[$(ls_field DIVE-9001 gate_pinged_at)] inbox=[$(inbox_field DIVE-9001 gate_pinged_at)] show=[$(show_field DIVE-9001 gate_pinged_at)]"
fi

# ---- ARM B: the NEVER-PINGED row — absent everywhere, alike ------------------
# The other half of the expectation: where the value is NULL the key is absent on
# every surface (DIVE-1610 drops nulls), so a consumer's `has("gate_pinged_at")`
# means the same thing whichever surface it read.
eq_t "B1: never pinged -> key absent on ls"    "$(ls_field DIVE-9002 gate_pinged_at)"    "<absent>"
eq_t "B2: never pinged -> key absent on inbox" "$(inbox_field DIVE-9002 gate_pinged_at)" "<absent>"
eq_t "B3: never pinged -> key absent on show"  "$(show_field DIVE-9002 gate_pinged_at)"  "<absent>"

# ---- ARM C: siblings untouched -------------------------------------------------
eq_t "C1: gate_live is still 1 on the pinged gate in ls (the verdict the column sits beside)" "$(ls_field DIVE-9001 gate_live)" "1"
eq_t "C2: need_answered_at, never broken, is still absent on an unanswered gate in inbox" "$(inbox_field DIVE-9001 need_answered_at)" "<absent>"

# ---- ARM M: the MUTANT — put the defect back, in this process -----------------
# Everything above is green on the fixed tree, which is also what a file with no
# teeth looks like. This arm rebuilds cmd_task_ls and cmd_task_inbox from the
# WORKING TREE's own definitions with `gate_pinged_at` struck out of the two
# SELECT lists — the pre-fix text — and requires the A arms to go red. In-file,
# because "A1/A2 red against main" is a claim about a checkout nobody re-runs.
ORIG_LS="$(declare -f cmd_task_ls)"
ORIG_INBOX="$(declare -f cmd_task_inbox)"
# M0 is a BEFORE/AFTER pair, not one assertion. "The column is gone after the
# sed" is also true of a sed that matched nothing on a tree that never had the
# column — which is the one tree where a vacuous mutant matters most, because
# there the A arms are red and a reader is already looking for why. So state the
# precondition out loud first, then the strike.
if declare -f cmd_task_ls | grep -q 'gate_pinged_at' \
   && declare -f cmd_task_inbox | grep -q 'gate_pinged_at'; then
  ok_t "M0a: precondition — both projections name gate_pinged_at before the strike (there is something to mutate)"
else
  bad_t "M0a: precondition for the mutant arm" "a projection does not name gate_pinged_at to begin with, so M1/M2 below cannot re-introduce anything: ls=$(declare -f cmd_task_ls | grep -c gate_pinged_at) inbox=$(declare -f cmd_task_inbox | grep -c gate_pinged_at)"
fi
# DIVE-4833: the strikes anchor on the SMALLEST unique token that names the
# column, never on its neighbour. The old anchors quoted the column BEFORE
# gate_pinged_at in each list, so inserting a new column between the two (which
# DIVE-4833 did, twice) made both seds match nothing: the mutant never installed
# and M0b — correctly — refused to let M1/M2 pass vacuously. A projection is an
# ordered list other people edit; the neighbour is not a stable anchor, and the
# column's own name is. `declare -f` strips comments, so each of these matches
# exactly one line in the declared body.
eval "$(sed 's/gate_pinged_at, //' <<<"$ORIG_LS")"
eval "$(sed 's/, gate_pinged_at FROM tasks/ FROM tasks/' <<<"$ORIG_INBOX")"
if ! declare -f cmd_task_ls | grep -q 'gate_pinged_at' \
   && ! declare -f cmd_task_inbox | grep -q 'gate_pinged_at'; then
  ok_t "M0b: ... and the strike landed — neither projection names it now"
else
  bad_t "M0b: the strike landed" "a projection still names gate_pinged_at, so M1/M2 would pass vacuously: ls=$(declare -f cmd_task_ls | grep -c gate_pinged_at) inbox=$(declare -f cmd_task_inbox | grep -c gate_pinged_at)"
fi
eq_t "M1: struck from ls, a pinged gate reads as never pinged (so this file CAN fail)" "$(ls_field DIVE-9001 gate_pinged_at)" "<absent>"
eq_t "M2: ... and the same on inbox — the defect, live"                               "$(inbox_field DIVE-9001 gate_pinged_at)" "<absent>"
# The disagreement is the defect, not the absence: show selects * and is
# unaffected, which is exactly how one surface said 2026-09-15 and another said
# nothing about the same row.
eq_t "M3: ... while show still carries it — the cross-surface disagreement itself" "$(show_field DIVE-9001 gate_pinged_at)" "$PINGED"
# Restore and prove it took: a mutant left installed would poison any arm added
# after this one, and it would look like a fresh regression.
eval "$ORIG_LS"; eval "$ORIG_INBOX"
eq_t "M4: the restored projections carry the receipt again (the mutant is not left installed)" "$(ls_field DIVE-9001 gate_pinged_at)" "$PINGED"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
