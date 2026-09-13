#!/usr/bin/env bash
# DIVE-4406 — how many bytes does ONE heartbeat dispatch carry?
#
# Prints the per-part byte count of a `/goal` wake for a given tree, so the
# before/after of a prose change is a number and not an impression. Point it at
# any checkout (default: this one) — it reads the literals out of
# src/cmd_heartbeat.sh and calls the real clause builders against a throwaway DB,
# so it works on trees from before the dispatch was refactored.
#
# Usage: bash scripts/dispatch-bytes.sh [tree-root]
# No root, no network, no shared state.
set -uo pipefail
TREE="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
TMP="$(mktemp -d /tmp/dispatch-bytes.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

cd "$TREE"
SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e; tasks_db_init >/dev/null 2>&1

task_ident="DIVE-9001"; name="dev"; _gq=2

# The invariant base line, read out of the source and expanded exactly as the
# wake would expand it. `sed` takes the first `local nudge="…"` assignment.
raw_base=$(sed -n 's/^  local nudge="\(.*\)"$/\1/p' "$TREE/src/cmd_heartbeat.sh" | head -1)
base=$(eval "printf '%s' \"$raw_base\"")

raw_know=$(sed -n 's/^ *compile_hint="\(.*\)"$/\1/p' "$TREE/src/cmd_heartbeat.sh" | head -1)
know=$(eval "printf '%s' \"$raw_know\"")

raw_gate=$(sed -n 's/^ *nudge="\${nudge} \(Separately: .*\)"$/\1/p' "$TREE/src/cmd_heartbeat.sh" | head -1)
gate=$(eval "printf '%s' \"$raw_gate\"")

mk() { db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
            VALUES ($(sqlq "$1"), '', 'high', $(sqlq "$2"), 'main', 'standard', 'todo');
            SELECT last_insert_rowid();"; }
b() { printf '%s' "$1" | wc -c; }

db "DELETE FROM tasks;"
M=$(mk "maker row" dev);  db "UPDATE tasks SET verifier='quinn' WHERE id=${M};"
V=$(mk "verifier row" quinn); db "UPDATE tasks SET verifier='quinn', maker_agent='dev' WHERE id=${V};"
R=$(mk "routing row" quinn);  db "UPDATE tasks SET verifier='quinn', created_by='main' WHERE id=${R};"
G=$(mk "graded row" dev);     db "UPDATE tasks SET verifier='quinn', maker_agent='dev', merge_owner='quinn',
        graded_at=datetime('now'), graded_by='quinn', graded_verdict='pass',
        delivery_ref='https://github.com/5dive-ai/5dive/pull/1' WHERE id=${G};"

c_maker=$(_hb_loop_terminal_clause dev "$M" "$task_ident" 2>/dev/null)
c_vfier=$(_hb_loop_terminal_clause quinn "$V" "$task_ident" 2>/dev/null)
c_route=$(_hb_loop_terminal_clause quinn "$R" "$task_ident" 2>/dev/null)
c_owner=$(_hb_loop_terminal_clause quinn "$G" "$task_ident" 2>/dev/null)

printf 'tree: %s (%s)\n' "$TREE" "$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || echo '?')"
printf '%-34s %6s\n' "part" "bytes"
printf '%-34s %6s\n' "base (invariant, EVERY wake)" "$(b "$base")"
printf '%-34s %6s\n' "loop clause: maker"     "$(b "$c_maker")"
printf '%-34s %6s\n' "loop clause: verifier"  "$(b "$c_vfier")"
printf '%-34s %6s\n' "loop clause: routing"   "$(b "$c_route")"
printf '%-34s %6s\n' "loop clause: merge owner" "$(b "$c_owner")"
printf '%-34s %6s\n' "knowledge clause"       "$(b "$know")"
printf '%-34s %6s\n' "gate-queue clause"      "$(b "$gate")"
printf '%-34s %6s\n' "WORST CASE (base+routing+know+gate)" \
  "$(( $(b "$base") + $(b "$c_route") + $(b "$know") + $(b "$gate") ))"
printf '%-34s %6s\n' "TYPICAL (base+maker clause)" "$(( $(b "$base") + $(b "$c_maker") ))"
