#!/usr/bin/env bash
# DIVE-1930 — `task need --json` emitted ZERO BYTES for the common case.
#
# The envelope carried `precedent_ref:(($pr|select(length>0))|tonumber? // null)`.
# When no precedent matched, $pr was empty, `select` yielded EMPTY, and because the
# `// null` bound to `tonumber?` rather than to the whole expression, the empty
# survived the pipe and propagated OUT of the object constructor — killing the
# ENTIRE envelope, not just that field. Every gate filed without a precedent (the
# overwhelming majority) returned nothing at all to a `--json` caller.
#
# The discriminator is WHERE `// null` BINDS, not whether a pipe follows `select`:
#   (($x|select(length>0)) // null)              safe   -> null
#   (($x|select(length>0)|tonumber?) // null)    safe   -> null   (encloses all)
#   (($x|select(length>0))|tonumber? // null)    BROKEN -> 0 bytes
# `map(select(...))` and `[ ... | select(...) ]` are comprehensions and never at
# risk. That distinction is why this was a ONE-line point fix and not a 19-site
# sweep: enumerating by guard shape rather than by grep hit is what separated the
# single defect from 18 correct lines.
#
# Run: bash tests/gate_json_envelope_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-json-env.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_agent_pairing.sh cmd_agent_runtime.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"
task_need_notify() { :; }   # no channel work here; this is about the envelope
audit_log() { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk() { db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
           VALUES ($(sqlq "$1"),'t','high','dev','dev','standard','todo');"; }

# ---- 1. the live bug: no precedent is the COMMON case, not an edge case -------
mk DIVE-8001
out=$( (JSON_MODE=1 cmd_task_need DIVE-8001 --type=decision --options="A|B" \
          --recommend="A" --ask="pick one" --from=dev) 2>/dev/null )
[[ -n "$out" ]] && ok_t "task need --json emits SOMETHING with no precedent" \
  || bad_t "envelope is non-empty" "got 0 bytes — the whole object was killed by one field"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && ok_t "the envelope parses as JSON" || bad_t "envelope parses" "raw: [${out:0:120}]"
[[ "$(printf '%s' "$out" | jq -r '.data.precedent_ref' 2>/dev/null)" == "null" ]] \
  && ok_t "precedent_ref renders null (absent), not by deleting the envelope" \
  || bad_t "precedent_ref is null" "got: $(printf '%s' "$out" | jq -c '.data.precedent_ref' 2>/dev/null)"
# The sibling fields prove the object was built, not merely non-empty.
[[ "$(printf '%s' "$out" | jq -r '.data.ident' 2>/dev/null)" == "DIVE-8001" \
   && "$(printf '%s' "$out" | jq -r '.data.recommend' 2>/dev/null)" == "A" ]] \
  && ok_t "sibling fields survive intact (ident + recommend)" \
  || bad_t "sibling fields" "$(printf '%s' "$out" | jq -c '.data' 2>/dev/null)"

# ---- 2. a REAL precedent still renders -------------------------------------
# Guard against "fixed" by simply dropping the field: answer a gate on the same
# ask shape, then file the same shape again so the prefill has something to cite.
db "UPDATE tasks SET need_answer='A', need_answered_at=datetime('now'),
       need_answered_by='human:test' WHERE ident='DIVE-8001';"
mk DIVE-8002
out2=$( (JSON_MODE=1 cmd_task_need DIVE-8002 --type=decision --options="A|B" \
           --recommend="A" --ask="pick one" --from=dev) 2>/dev/null )
pref=$(printf '%s' "$out2" | jq -r '.data.precedent_ref' 2>/dev/null)
[[ "$pref" =~ ^[0-9]+$ ]] \
  && ok_t "a real precedent still renders as a number ($pref), so the field is not merely deleted" \
  || bad_t "precedent_ref renders when present" "got '$pref' from: ${out2:0:160}"

# ---- 3. shape guard: the dangerous binding must not come back ----------------
# Matches `select(...))` followed by a pipe, i.e. the closing paren lands BEFORE
# the pipe so any trailing `// null` can only bind to the piped filter. The safe
# forms close after the whole pipeline, or use map()/[ ... ] comprehensions.
bad_sites=$(grep -n 'select(length[^)]*))|' src/*.sh | grep -v 'map(select' || true)
[[ -z "$bad_sites" ]] \
  && ok_t "no select(...)-then-pipe binding where // null cannot enclose the expression" \
  || bad_t "dangerous jq binding reintroduced" "$bad_sites"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
