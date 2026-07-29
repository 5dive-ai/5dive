#!/usr/bin/env bash
# DIVE-2347 — a skill that FAILED to install must not be summarised as `errors=0`.
#
# THE DEFECT: `agent create` deliberately does not fail when a preseeded skill won't
# install — the agent itself is up, and that choice is correct. The consequence is that
# the failure never reaches cmd_compose_up's `errors` counter, so the last line the user
# reads contradicts the red lines they just watched scroll past. Measured on the real
# content-studio template, whose writer and seo roles both request `deep-research`, a
# skill that is not in the 5dive-ai/skills repo the template names:
#
#   error: skill install failed for 'deep-research' on agent 'writer'
#   warn:  skill install failed for 'deep-research' from '5dive-ai/skills' (exit 1) ...
#   OK — applied ...: created=5 started=0 skipped=0 errors=0
#
# A first run that reports success while two things failed is worse than one that fails
# loudly: the customer concludes he broke it.
#
# COVERAGE, stated plainly rather than implied: cmd_compose_up CREATES AGENTS, so no
# harness can run it end-to-end without provisioning real users on this host. T1-T4 below
# therefore EXTRACT THE DERIVATION VERBATIM from the source between its DIVE-2347 markers
# and run it against a stubbed installed-set — they are real behavioural arms over the
# real code, not greps. T5-T8 are source-level arms over the parts (render order, JSON,
# display-only) that only exist inside the un-runnable function.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_compose.sh"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[[ -s "$SRC" ]] \
  && ok_t 'T0 cmd_compose.sh is present — the arms below are not reading an empty file' \
  || bad_t 'T0 cmd_compose.sh missing — every arm is vacuous' "src=$SRC"

# ---------------------------------------------------------------------------
# Extract the derivation verbatim. If the markers ever move or the block is
# emptied, BLOCK is empty and T1 fails loudly rather than passing vacuously.
# ---------------------------------------------------------------------------
BLOCK=$(sed -n '/>>> DIVE-2347 degraded-skill derivation/,/<<< DIVE-2347 degraded-skill derivation/p' "$SRC" \
        | sed '1d;$d')
if [[ -n "$BLOCK" ]] && grep -q '_degraded+=' <<<"$BLOCK"; then
  ok_t "T1 the derivation was extracted from source ($(wc -l <<<"$BLOCK") lines) — T2-T4 run the real code"
else
  bad_t 'T1 could not extract the derivation — T2-T4 below would be vacuous' \
        "markers present? $(grep -c 'DIVE-2347 degraded-skill derivation' "$SRC")"
fi

# Harness: run the extracted block with a stubbed installed-set. `spec`,
# `_brought_up_names` and `_skill_list_json` are exactly what cmd_compose_up
# has in scope at that point.
#   $1 = spec JSON   $2 = agent names (space sep)   $3.. = "agent:skill,skill" installed
run_block() {
  local _spec="$1" _names="$2"; shift 2
  local _installed=("$@")
  bash -uo pipefail -c '
    set +e
    spec="$1"; read -r -a _brought_up_names <<<"$2"; shift 2
    _installed=("$@")
    _skill_list_json() {
      local want="$1" e
      for e in "${_installed[@]+"${_installed[@]}"}"; do
        if [[ "${e%%:*}" == "$want" ]]; then
          tr "," "\n" <<<"${e#*:}" | jq -R "select(length>0) | {name:.}" | jq -sc .
          return
        fi
      done
      echo "[]"
    }
    _n=""
    block() {
      '"$BLOCK"'
      printf "%s\n" "${_degraded[@]+"${_degraded[@]}"}"
    }
    block
  ' _ "$_spec" "$_names" "${_installed[@]+"${_installed[@]}"}"
}

SPEC_TWO='{"agents":{"writer":{"skills":["5dive-cli","deep-research"]},"editor":{"skills":["5dive-cli"]}}}'

# --- T2 a missing skill is DETECTED -----------------------------------------
# The measured case: writer asked for deep-research, only 5dive-cli landed.
out=$(run_block "$SPEC_TWO" "writer editor" "writer:5dive-cli" "editor:5dive-cli")
if [[ "$(grep -c . <<<"$out")" == 1 ]] && grep -qx 'writer deep-research' <<<"$out"; then
  ok_t 'T2 a skill that failed to install is detected (writer/deep-research), and only that one'
else
  bad_t 'T2 the missing skill was not detected — the summary would still read errors=0' \
        "got: $(tr '\n' '|' <<<"$out")"
fi

# --- T3 ANCHOR: the all-present case must be EMPTY ---------------------------
# Without this, T2 would pass just as well if the block flagged EVERY skill. This is the
# arm that makes T2 mean something.
out=$(run_block "$SPEC_TWO" "writer editor" "writer:5dive-cli,deep-research" "editor:5dive-cli")
if [[ "$(grep -c . <<<"$out")" == 0 ]]; then
  ok_t 'T3 ANCHOR a fully-installed roster reports NOTHING degraded (T2 is differential, not blanket)'
else
  bad_t 'T3 ANCHOR a healthy roster was reported degraded — the check flags everything' \
        "got: $(tr '\n' '|' <<<"$out")"
fi

# --- T4 an owner/repo:id spec entry is matched on the BARE id ----------------
# Specs may say `5dive-ai/skills:verify`, but the installed directory is `verify`. Without
# the colon strip every qualified entry would be reported missing forever.
out=$(run_block '{"agents":{"qa":{"skills":["5dive-ai/skills:verify"]}}}' "qa" "qa:verify")
if [[ "$(grep -c . <<<"$out")" == 0 ]]; then
  ok_t 'T4 a fully-qualified `owner/repo:id` entry matches the installed bare id'
else
  bad_t 'T4 qualified spec entries are always reported missing — false degraded on every import' \
        "got: $(tr '\n' '|' <<<"$out")"
fi

# --- T5 the summary line carries the count ----------------------------------
# The summary is the line users actually read; a count that is not in it loses to the
# skill-install render above it.
grep -q 'skills_failed=\${#_degraded\[@\]}' "$SRC" \
  && ok_t 'T5 the text summary reports skills_failed=<n> alongside errors' \
  || bad_t 'T5 the skills_failed count is not in the summary line' "$(grep -n 'applied \$file' "$SRC" | head -2)"

# --- T6 the block is printed AFTER the summary ------------------------------
# Order is the whole fix — the bug is a true statement made before a cheerful one.
_sum_ln=$(grep -n 'OK — applied \$file' "$SRC" | head -1 | cut -d: -f1)
_blk_ln=$(grep -n 'FAILED to install — those agents are up but DEGRADED' "$SRC" | head -1 | cut -d: -f1)
if [[ -n "$_sum_ln" && -n "$_blk_ln" ]] && (( _blk_ln > _sum_ln )); then
  ok_t "T6 the degraded block is emitted AFTER the summary (summary $_sum_ln, block $_blk_ln)"
else
  bad_t 'T6 the degraded block does not follow the summary — it would be scrolled past too' \
        "summary=$_sum_ln block=$_blk_ln"
fi

# --- T7 JSON mode carries it, and survives an EMPTY list ---------------------
# The empty case is the one that breaks: `set -u` plus `jq --argjson` over an unset array.
grep -q 'skills_failed:(\$sf|tonumber)' "$SRC" \
  && ok_t 'T7 JSON mode emits skills_failed' \
  || bad_t 'T7 JSON mode does not report skills_failed — machine consumers stay blind' ''
grep -q '_degraded\[@\]+' "$SRC" \
  && ok_t 'T7b the empty-array expansion is guarded (set -u safe)' \
  || bad_t 'T7b unguarded array expansion — an empty degraded list aborts under set -u' ''

# --- T8 ANCHOR: display-only. This must not be able to fail a create ---------
# The fix describes a create; it must never be able to break one.
if grep -qE '_degraded.*\|\| (fail|return|exit)' "$SRC"; then
  bad_t 'T8 the degraded derivation can fail the run — display code must not gate a create' ''
else
  ok_t 'T8 ANCHOR the degraded derivation cannot fail the run (display-only, as intended)'
fi

echo "-----"
echo "compose_skill_degraded_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
