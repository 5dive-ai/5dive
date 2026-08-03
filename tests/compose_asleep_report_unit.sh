#!/usr/bin/env bash
# DIVE-2341 — a created agent that is ASLEEP must be visible in the LAST thing printed.
#
# THE DEFECT is placement, not wording. `agent create` already emits a correct per-agent
# warning ("no heartbeat (agent is ASLEEP — won't self-act on board work)"). But each
# create also prints a full skill-install render, so on a five-role `team import` the user
# gets five warnings buried mid-scroll and then ONE cheerful `errors=0`. Measured on the
# real content-studio template: created=5, all five asleep, summary said errors=0.
# The last thing read says nothing is wrong.
#
# WHY THE ARMS BELOW ARE SOURCE-LEVEL, said plainly rather than hidden: the behaviour is
# emitted by cmd_compose_up, which CREATES AGENTS. A harness cannot exercise it without
# provisioning real users on the host, so these arms pin the invariants that make the
# behaviour possible, and the end-to-end proof was run by hand and is recorded here:
#
#   text mode, 1 created:  OK — applied ...: created=1 started=0 skipped=0 errors=0 asleep=1
#                          ── 1 agent(s) are ASLEEP — created, but they will not self-act...
#                               sudo 5dive heartbeat on hbprobe
#   json, empty:           {"created":0,...,"asleep":[]}
#   json, non-empty:       {"created":1,...,"asleep":["hbprobe2"]}
#
# That is a deliberate coverage limit, NOT a claim that these arms prove the output.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_compose.sh"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[[ -s "$SRC" ]] \
  && ok_t 'T0 cmd_compose.sh is present — the arms below are not reading an empty file' \
  || bad_t 'T0 cmd_compose.sh missing — every arm is vacuous' "src=$SRC"

# --- T1 the summary line carries the count ----------------------------------
# The summary is the line users actually read. A warning that is not in it is a warning
# that competes with a skill-install render for attention, and loses.
grep -q 'errors=\$errors asleep=\${#_asleep\[@\]}' "$SRC" \
  && ok_t 'T1 the text summary line reports asleep=<n> alongside errors' \
  || bad_t 'T1 asleep count is not in the summary line' "$(grep -n 'applied \$file' "$SRC" | head -2)"

# --- T2 the consolidated block is printed AFTER the summary -----------------
# Order is the whole fix. If the block were printed before the summary it would be one
# more thing scrolled past, which is the bug.
_sum_ln=$(grep -n 'OK — applied \$file' "$SRC" | head -1 | cut -d: -f1)
_blk_ln=$(grep -n 'are ASLEEP — created, but they will not self-act' "$SRC" | head -1 | cut -d: -f1)
if [[ -n "$_sum_ln" && -n "$_blk_ln" ]] && (( _blk_ln > _sum_ln )); then
  ok_t "T2 the asleep block is emitted AFTER the summary (summary line $_sum_ln, block line $_blk_ln)"
else
  bad_t 'T2 the asleep block does not follow the summary — it would be scrolled past like the warns it replaces' \
        "summary=$_sum_ln block=$_blk_ln"
fi

# --- T3 the block prints a RUNNABLE command per agent ------------------------
# "an agent is asleep" is a diagnosis; `sudo 5dive heartbeat on <name>` is a remedy. The
# original warn got this right and the consolidated block must not lose it.
grep -q 'sudo 5dive heartbeat on \$_n' "$SRC" \
  && ok_t 'T3 the block prints the exact remedy command per asleep agent' \
  || bad_t 'T3 the block names the problem without the command' ''

# --- T4 state is re-derived from the REGISTRY, not scraped from child output --
# `agent create` output is a clack render; parsing it would break the moment the renderer
# changes, and would silently report zero asleep agents when it did.
if grep -q "heartbeat.enabled // false" "$SRC"; then
  ok_t 'T4 asleep state is read from the registry (the thing that DEFINES it)'
else
  bad_t 'T4 asleep state is not derived from the registry — likely scraped from child output' ''
fi

# --- T5 JSON mode carries it too, and survives an EMPTY list -----------------
# The empty case is the one that breaks: bash set -u plus `jq --argjson` on an unset
# array. Verified by hand ({"asleep":[]}), pinned here so a refactor cannot drop the
# `${arr[@]+...}` guard that makes it safe.
grep -q 'asleep:\$a' "$SRC" \
  && ok_t 'T5 JSON mode emits an asleep array' \
  || bad_t 'T5 JSON mode does not report asleep — machine consumers stay blind' ''
grep -q '_asleep\[@\]+' "$SRC" \
  && ok_t 'T5b the empty-array expansion is guarded (set -u safe)' \
  || bad_t 'T5b unguarded array expansion — an empty asleep list will abort under set -u' ''

# --- T6 ANCHOR: display-only. This must not be able to fail a create ---------
# The fix describes a create; it must never be able to break one. If any of the new code
# can return non-zero into the caller's path, that is worse than the bug it fixes.
if grep -qE '_asleep.*\|\| (fail|return|exit)' "$SRC"; then
  bad_t 'T6 the asleep derivation can fail the run — display code must not gate a create' ''
else
  ok_t 'T6 ANCHOR the asleep derivation cannot fail the run (display-only, as intended)'
fi

echo "-----"
echo "compose_asleep_report_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
