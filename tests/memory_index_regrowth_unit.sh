#!/usr/bin/env bash
# DIVE-4284 unit harness for the MEMORY.md regrowth control:
#   `memory consolidate` re-invokes `memory router` when the always-loaded index
#   is over the LOADER limit, and `memory size` is the read that makes it visible.
#
# WHY THE NEGATIVE CONTROLS ARE THE POINT. "The index got smaller" is satisfied
# by a pass that rewrites the index unconditionally, which would destroy a
# hand-maintained under-limit index on every run. So every arm here is paired:
#   - over-limit regenerates        <-> under-limit is byte-for-byte UNTOUCHED
#   - the reroute fires with 0 atoms <-> proving it is not gated on distilling
#   - keep-marker text survives      <-> and the surrounding bloat does not
#   - --dry-run reports and does not write <-> a real pass afterwards does
#   - the router-can't-win case is LOUD and non-silent (the whole defect class)
# The distiller is a stub script in every arm: no model is ever reached.
# Run: bash tests/memory_index_regrowth_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/mem-regrowth-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_memory.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node absent — the router is node"; echo "PASS=0 FAIL=0"; exit 0; }

export HOME="$TMP/home"
PROJ="$HOME/.claude/projects/proj"
STORE="$PROJ/memory"
mkdir -p "$STORE"

# A small, explicit limit/budget so the fixtures stay legible. These are the
# PRODUCTION seams (src/cmd_memory.sh:_memory_index_limit), not test-only knobs.
export FIVEDIVE_MEMORY_INDEX_LIMIT=4000
export FIVEDIVE_MEMORY_ROUTER_BUDGET=3000

# --- fixtures ----------------------------------------------------------------
mk_atoms() { # <n> — real atoms on disk, so the router has something to index
  local n="$1" i
  for i in $(seq 1 "$n"); do
    cat > "$STORE/reference_atom_$i.md" <<EOF
---
name: atom-$i
description: a durable reference fact number $i about the deploy queue and the loader limit
metadata:
  type: reference
---

Fact body $i. The always-loaded index is truncated past the loader limit.
EOF
  done
}

KEEPLINE='- [PINNED CORRECTION](x.md) — a hand-written line the generator must never eat'
mk_index() { # <filler-lines> [keep]
  local filler="$1" keep="${2:-}"
  rm -f "$STORE"/MEMORY.md.pre-router-*   # earlier arms' backups are not this arm's churn
  { echo "# Memory Index"
    [ -n "$keep" ] && { echo "<!-- router:keep-start -->"; echo "$KEEPLINE"; echo "<!-- router:keep-end -->"; }
    local i
    for i in $(seq 1 "$filler"); do
      echo "- [an enumerated atom line $i](reference_atom_$i.md) — one line per atom is what outgrows the limit"
    done
  } > "$STORE/MEMORY.md"
}

mk_transcript() { # <path> <user> <assistant>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p, u, a = sys.argv[1], sys.argv[2], sys.argv[3]
with open(p, "w") as fh:
    fh.write(json.dumps({"type":"user","message":{"role":"user","content":u}})+"\n")
    fh.write(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":a}]}})+"\n")
PY
}

stub() { # <name> <stdout payload>
  local f="$TMP/$1.sh"
  { echo '#!/usr/bin/env bash'; echo 'cat >/dev/null'; printf 'cat <<%s\n%s\n%s\n' "'JSONEOF'" "$2" "JSONEOF"; } > "$f"
  chmod +x "$f"; echo "$f"
}
EMPTY=$(stub empty '{"atoms":[]}')

# ALWAYS through a subshell. `_memory_consolidate` takes its single-flight lock
# with `exec 201>`, and a direct call in THIS shell would hold that fd for the
# rest of the harness — every later arm would then get "another pass holds the
# lock" instead of the behaviour it is testing. Same shape as
# tests/memory_consolidate_unit.sh's own `run`.
run() { ( _memory_consolidate "$@" ) ; }

mk_atoms 40
sz() { stat -c %s "$STORE/MEMORY.md" 2>/dev/null || echo 0; }
fresh_transcript() { # <sid>
  rm -f "$PROJ"/*.jsonl "$STORE/.consolidated.tsv"
  mk_transcript "$PROJ/$1.jsonl" "a finished session about the loader limit" "Noted."
  touch -d '3 hours ago' "$PROJ/$1.jsonl"
}

echo "── the two numbers are distinct, and a junk override cannot disable the limit ──"
check "limit honours the override"   "$(_memory_index_limit)"  "4000"
check "budget honours the override"  "$(_memory_router_budget)" "3000"
check "junk limit falls back to the default, never to 'no limit'" \
  "$(FIVEDIVE_MEMORY_INDEX_LIMIT=notanumber _memory_index_limit)" "24400"
check "a zero limit falls back too" \
  "$(FIVEDIVE_MEMORY_INDEX_LIMIT=0 _memory_index_limit)" "24400"

echo "── memory size: bytes / limit / over-or-under, and --strict is the branch ──"
mk_index 200
OVER_BYTES=$(sz)
OUT=$(_memory_size 2>&1); RC=$?
check "a read exits 0 even when over the limit" "$RC" "0"
printf '%s' "$OUT" | grep -q "OVER" && ok "over-limit index is labelled OVER" || bad "over-limit index is labelled OVER (got: $OUT)"
printf '%s' "$OUT" | grep -q "$OVER_BYTES B / 4000 B" && ok "prints bytes AND the limit" || bad "prints bytes AND the limit (got: $OUT)"
printf '%s' "$OUT" | grep -q 'flat index — never routed' && ok "names a never-routed flat index" || bad "names a never-routed flat index"
_memory_size --strict >/dev/null 2>&1
check "--strict exits E_VALIDATION when over" "$?" "3"
JSON_MODE=1
J=$(_memory_size 2>/dev/null); JSON_MODE=0
check "json: over flag"        "$(jq -r '.data.indexes[0].over' <<<"$J")" "true"
check "json: limit"            "$(jq -r '.data.limit' <<<"$J")" "4000"
check "json: over_limit count" "$(jq -r '.data.over_limit' <<<"$J")" "1"
check "json: over_by is bytes past the limit" "$(jq -r '.data.indexes[0].over_by' <<<"$J")" "$((OVER_BYTES - 4000))"
check "json: atoms counted, MEMORY.md excluded" "$(jq -r '.data.indexes[0].atoms' <<<"$J")" "40"

echo "── CONTROL: an UNDER-limit index reports under, and --strict exits 0 ──"
mk_index 5
OUT=$(_memory_size 2>&1)
printf '%s' "$OUT" | grep -q 'under' && ok "under-limit index is labelled under" || bad "under-limit index is labelled under (got: $OUT)"
printf '%s' "$OUT" | grep -q 'OVER' && bad "CONTROL: no OVER label when under" || ok "CONTROL: no OVER label when under"
_memory_size --strict >/dev/null 2>&1
check "CONTROL: --strict exits 0 when under" "$?" "0"

echo "── a store with NO index is not an unreadable one, and rows name the SEAT ──"
# Both measured against a real seat, not invented: this seat has three project
# dirs with no MEMORY.md at all, and every row of the first live run was labelled
# `.claude` because the seat name was read three levels up instead of four.
mk_index 5
EMPTYPROJ="$HOME/.claude/projects/never-used/memory"; mkdir -p "$EMPTYPROJ"
OUT=$(_memory_size 2>&1)
printf '%s' "$OUT" | grep -q 'unreadable' && bad "an index-less store is NOT reported unreadable" || ok "an index-less store is NOT reported unreadable"
printf '%s' "$OUT" | grep -q 'no MEMORY.md yet' && ok "it is reported in its own bucket" || bad "it is reported in its own bucket (got: $OUT)"
_memory_size --strict >/dev/null 2>&1
check "CONTROL: an index-less store does not red --strict" "$?" "0"
JSON_MODE=1; J=$(_memory_size 2>/dev/null); JSON_MODE=0
check "json: no_index counted"       "$(jq -r '.data.no_index' <<<"$J")" "1"
check "json: and not as unreadable"  "$(jq -r '.data.unreadable' <<<"$J")" "0"
SEAT=$(basename "$HOME")
check "the row names the SEAT, not .claude" "$(jq -r '.data.indexes[0].agent' <<<"$J")" "$SEAT"
rmdir "$EMPTYPROJ" "$(dirname "$EMPTYPROJ")"

echo "── an UNREADABLE index is not a clean result (0600 stores, --all as non-root) ──"
# The DIVE-4222 defect was a number nobody printed. A checker that silently skips
# the index it could not open prints "0 over" and is WRONG in exactly the same
# way, so unreadable is its own bucket and it reds --strict.
mk_index 5                       # the readable one is UNDER the limit on purpose
PROJ2="$HOME/.claude/projects/locked"; STORE2="$PROJ2/memory"
mkdir -p "$STORE2"
printf '# locked\n' > "$STORE2/MEMORY.md"; chmod 000 "$STORE2/MEMORY.md"
if [ -r "$STORE2/MEMORY.md" ]; then
  echo "  skip — running as root, 0600 does not bite"
else
  OUT=$(_memory_size 2>&1)
  printf '%s' "$OUT" | grep -q 'unreadable' && ok "an unreadable index is reported, not skipped" || bad "an unreadable index is reported, not skipped (got: $OUT)"
  printf '%s' "$OUT" | grep -q 'NOT a clean result' && ok "and the summary says the result is not clean" || bad "and the summary says the result is not clean"
  _memory_size --strict >/dev/null 2>&1
  check "--strict reds on unreadable even with every readable index under" "$?" "3"
  JSON_MODE=1; J=$(_memory_size 2>/dev/null); JSON_MODE=0
  check "json: unreadable is counted"           "$(jq -r '.data.unreadable' <<<"$J")" "1"
  check "json: an unreadable index is not readable" "$(jq -r '[.data.indexes[]|select(.readable==false)]|length' <<<"$J")" "1"
  check "json: and is NOT counted as over"      "$(jq -r '.data.over_limit' <<<"$J")" "0"
fi
chmod 644 "$STORE2/MEMORY.md"; rm -rf "$PROJ2"

echo "── --all: a home we could not even LOOK inside is unreadable, not empty ──"
# The fail-open this whole read exists to remove: a 0700 home yields nothing from
# the glob, and a silent nothing would be reported as "0 over" by a caller who
# could not open a single store. It must not land in the no-index-yet bucket
# either — "I could not look" is not "there is nothing there".
FAKEHOMES="$TMP/homes"
mkdir -p "$FAKEHOMES/agent-visible/.claude/projects/p/memory" "$FAKEHOMES/agent-blind/.claude/projects/p/memory"
printf '# small\n' > "$FAKEHOMES/agent-visible/.claude/projects/p/memory/MEMORY.md"
printf '# small\n' > "$FAKEHOMES/agent-blind/.claude/projects/p/memory/MEMORY.md"
chmod 000 "$FAKEHOMES/agent-blind/.claude/projects"
if [ -r "$FAKEHOMES/agent-blind/.claude/projects" ]; then
  echo "  skip — running as root, 0000 does not bite"
else
  JSON_MODE=1; J=$(FIVEDIVE_HOMES_ROOT="$FAKEHOMES" _memory_size --all 2>/dev/null); JSON_MODE=0
  check "the blind home is counted UNREADABLE"     "$(jq -r '.data.unreadable' <<<"$J")" "1"
  check "and NOT as a store with no index"         "$(jq -r '.data.no_index' <<<"$J")" "0"
  check "and NOT silently dropped (two rows)"      "$(jq -r '.data.indexes|length' <<<"$J")" "2"
  check "the row names the seat whose home it is"  "$(jq -r '[.data.indexes[]|select(.readable==false)|.agent]|first' <<<"$J")" "blind"
  FIVEDIVE_HOMES_ROOT="$FAKEHOMES" _memory_size --all --strict >/dev/null 2>&1
  check "--strict reds: a fleet answer from a caller who could not look is not clean" "$?" "3"
  # CONTROL: with the same home readable, --all is clean and --strict exits 0.
  chmod 755 "$FAKEHOMES/agent-blind/.claude/projects"
  JSON_MODE=1; J=$(FIVEDIVE_HOMES_ROOT="$FAKEHOMES" _memory_size --all 2>/dev/null); JSON_MODE=0
  check "CONTROL: readable home reports zero unreadable" "$(jq -r '.data.unreadable' <<<"$J")" "0"
  check "CONTROL: and both indexes are read"             "$(jq -r '[.data.indexes[]|select(.readable)]|length' <<<"$J")" "2"
  FIVEDIVE_HOMES_ROOT="$FAKEHOMES" _memory_size --all --strict >/dev/null 2>&1
  check "CONTROL: --strict exits 0 once every home can be read" "$?" "0"
fi
chmod -R 755 "$FAKEHOMES" 2>/dev/null; rm -rf "$FAKEHOMES"

echo "── consolidate REGENERATES an over-limit index (the regrowth control) ──"
mk_index 200
BEFORE=$(sz)
[ "$BEFORE" -gt 4000 ] && ok "fixture starts over the limit ($BEFORE B > 4000 B)" || bad "fixture starts over the limit (got $BEFORE)"
fresh_transcript aaaa-1111
OUT=$(run --distiller="$EMPTY" --max-sessions=1 2>&1); RC=$?
AFTER=$(sz)
check "the pass still exits 0" "$RC" "0"
[ "$AFTER" -le 3000 ] && ok "index regenerated to the BUDGET, not merely to the limit ($BEFORE B → $AFTER B)" \
                       || bad "index regenerated under budget (got $AFTER B, want <= 3000)"
printf '%s' "$OUT" | grep -q 'router re-invoked' && ok "the pass says it re-invoked the router" || bad "the pass says it re-invoked the router (got: $OUT)"
grep -q '<!-- router:generated -->' "$STORE/MEMORY.md" && ok "the new index is a router, not a trimmed flat list" || bad "the new index is a router"
grep -q 'atom-1' "$STORE/MEMORY.md" && bad "not every atom is enumerated any more" || ok "not every atom is enumerated any more"
ls "$STORE"/MEMORY.md.pre-router-* >/dev/null 2>&1 && ok "the previous index is backed up, nothing deleted" || bad "the previous index is backed up"
check "all 40 atoms are still on disk" "$(find "$STORE" -maxdepth 1 -name 'reference_atom_*.md' | wc -l)" "40"

echo "── it is NOT gated on having distilled anything (the growth is from \`add\`) ──"
# 0 atoms written, 0 sessions processed: the index was still brought back under.
mk_index 200
rm -f "$PROJ"/*.jsonl          # nothing at all to distil
OUT=$(run --distiller="$EMPTY" --max-sessions=1 2>&1)
printf '%s' "$OUT" | grep -q '0 session(s) distilled' && ok "CONTROL: the pass really did distil nothing" || bad "CONTROL: the pass really did distil nothing (got: $OUT)"
[ "$(sz)" -le 3000 ] && ok "over-limit index re-routed with zero atoms written" || bad "over-limit index re-routed with zero atoms written (got $(sz) B)"

echo "── hand-written router:keep lines survive the re-invoke ──"
mk_index 200 keep
grep -qF -- "$KEEPLINE" "$STORE/MEMORY.md" || bad "fixture carries the keep line"
OUT=$(run --distiller="$EMPTY" --max-sessions=1 2>&1)
grep -qF -- "$KEEPLINE" "$STORE/MEMORY.md" && ok "the pinned hand-written line is carried over verbatim" || bad "the pinned hand-written line is carried over verbatim"
grep -q 'an enumerated atom line 199' "$STORE/MEMORY.md" && bad "the bloat around it is NOT carried over" || ok "the bloat around it is NOT carried over"
[ "$(sz)" -le 3000 ] && ok "still lands under budget with a keep block" || bad "still lands under budget with a keep block (got $(sz) B)"

echo "── CONTROL: an UNDER-limit index is left byte-for-byte alone ──"
mk_index 5
SUM_BEFORE=$(md5sum < "$STORE/MEMORY.md")
fresh_transcript bbbb-2222
OUT=$(run --distiller="$EMPTY" --max-sessions=1 2>&1)
check "under-limit index untouched (same bytes)" "$(md5sum < "$STORE/MEMORY.md")" "$SUM_BEFORE"
printf '%s' "$OUT" | grep -q 'router re-invoked' && bad "no reroute is reported when under the limit" || ok "no reroute is reported when under the limit"
ls "$STORE"/MEMORY.md.pre-router-* >/dev/null 2>&1 && bad "no backup churn when under the limit" || ok "no backup churn when under the limit"

echo "── --dry-run reports the reroute and writes nothing; a real pass then does ──"
mk_index 200
SUM_BEFORE=$(md5sum < "$STORE/MEMORY.md")
fresh_transcript cccc-3333
OUT=$(run --distiller="$EMPTY" --max-sessions=1 --dry-run 2>&1)
printf '%s' "$OUT" | grep -q 'would re-invoke the router' && ok "dry run names the reroute it would do" || bad "dry run names the reroute it would do (got: $OUT)"
check "dry run left the index untouched" "$(md5sum < "$STORE/MEMORY.md")" "$SUM_BEFORE"
run --distiller="$EMPTY" --max-sessions=1 >/dev/null 2>&1
[ "$(sz)" -le 3000 ] && ok "CONTROL: the real pass after a dry run does re-route" || bad "CONTROL: the real pass after a dry run does re-route"

echo "── the --json envelope carries the numbers the heartbeat counts ──"
mk_index 200
BEFORE=$(sz)
fresh_transcript dddd-4444
JSON_MODE=1
J=$(run --distiller="$EMPTY" --max-sessions=1 2>/dev/null); JSON_MODE=0
check "index_over_limit is the state BEFORE the reroute" "$(jq -r '.data.index_over_limit' <<<"$J")" "true"
check "index_rerouted"                                  "$(jq -r '.data.index_rerouted' <<<"$J")" "true"
check "index_still_over_limit is false once fixed"       "$(jq -r '.data.index_still_over_limit' <<<"$J")" "false"
check "index_bytes_before"                              "$(jq -r '.data.index_bytes_before' <<<"$J")" "$BEFORE"
check "index_limit"                                     "$(jq -r '.data.index_limit' <<<"$J")" "4000"
[ "$(jq -r '.data.index_bytes_after' <<<"$J")" -le 3000 ] && ok "index_bytes_after is the post-reroute size" || bad "index_bytes_after is the post-reroute size"
# CONTROL: an under-limit pass must report over=false / rerouted=false, or the
# heartbeat's fleet counter would climb on healthy seats.
mk_index 5
fresh_transcript eeee-5555
JSON_MODE=1
J=$(run --distiller="$EMPTY" --max-sessions=1 2>/dev/null); JSON_MODE=0
check "CONTROL: index_over_limit false when under"       "$(jq -r '.data.index_over_limit' <<<"$J")" "false"
check "CONTROL: index_rerouted false when under"         "$(jq -r '.data.index_rerouted' <<<"$J")" "false"
check "CONTROL: index_still_over_limit false when under" "$(jq -r '.data.index_still_over_limit' <<<"$J")" "false"

echo "── an index the router CANNOT shrink is LOUD, never silently retried away ──"
# A keep block bigger than the limit is unshrinkable by construction: the router
# carries it verbatim. This is the case the old code had no voice for at all.
mk_index 5 keep
python3 - "$STORE/MEMORY.md" <<'PY'
import sys
p = sys.argv[1]
huge = "\n".join("- a pinned line the generator may not drop, number %d" % i for i in range(1, 200))
s = open(p).read().replace("<!-- router:keep-end -->", huge + "\n<!-- router:keep-end -->")
open(p, "w").write(s)
PY
[ "$(sz)" -gt 4000 ] && ok "fixture is over the limit and unshrinkable" || bad "fixture is over the limit and unshrinkable"
fresh_transcript ffff-6666
ERR=$(run --distiller="$EMPTY" --max-sessions=1 2>&1 >/dev/null); RC=$?
printf '%s' "$ERR" | grep -q 'INDEX OVER LIMIT' && ok "the unfixable case is reported on stderr" || bad "the unfixable case is reported on stderr (got: $ERR)"
printf '%s' "$ERR" | grep -q 'TAIL' && ok "the warning names the consequence (a dropped tail), not just a number" || bad "the warning names the consequence"
check "a truncated index does NOT red the consolidate pass" "$RC" "0"
JSON_MODE=1
J=$(run --distiller="$EMPTY" --max-sessions=1 --force 2>/dev/null); JSON_MODE=0
check "json: index_still_over_limit true when unfixable" "$(jq -r '.data.index_still_over_limit' <<<"$J")" "true"
check "json: index_rerouted false when unfixable"        "$(jq -r '.data.index_rerouted' <<<"$J")" "false"

echo "── the loader-side fail-loud hook warns, and only when over the limit ──"
HOOK=hooks/sessionstart-resume-context.sh
[ -x "$HOOK" ] || [ -r "$HOOK" ] && ok "the SessionStart hook exists" || bad "the SessionStart hook exists"
mk_index 200
OUT=$(printf '{"source":"startup"}' | FIVEDIVE_MEMORY_INDEX_LIMIT=4000 PATH=/usr/bin:/bin HOME="$HOME" bash "$HOOK" 2>/dev/null)
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'MEMORY INDEX OVER THE LOAD LIMIT' \
  && ok "an over-limit index warns at session start" || bad "an over-limit index warns at session start (got: $OUT)"
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'memory router --write' \
  && ok "the warning names the fix" || bad "the warning names the fix"
mk_index 5
OUT=$(printf '{"source":"startup"}' | FIVEDIVE_MEMORY_INDEX_LIMIT=4000 PATH=/usr/bin:/bin HOME="$HOME" bash "$HOOK" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'MEMORY INDEX OVER THE LOAD LIMIT' \
  && bad "CONTROL: no warning when the index is under the limit" || ok "CONTROL: no warning when the index is under the limit"
# CONTROL: the hook must still skip a 'compact' source, warning or not.
mk_index 200
OUT=$(printf '{"source":"compact"}' | FIVEDIVE_MEMORY_INDEX_LIMIT=4000 PATH=/usr/bin:/bin HOME="$HOME" bash "$HOOK" 2>/dev/null)
[ -z "$OUT" ] && ok "CONTROL: source=compact is still skipped" || bad "CONTROL: source=compact is still skipped (got: $OUT)"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
