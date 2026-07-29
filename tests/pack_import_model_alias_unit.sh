#!/usr/bin/env bash
# DIVE-2303 — a pack may carry a model ALIAS, and importing it must not lose the pin.
#
# THE BUG THIS GUARDS, because it is invisible from the manifest side:
# cmd_pack.sh reads .config.model out of the manifest and merges it RAW into the
# new agent's settings.json. Per src/lib/models.sh (DIVE-506/536), Claude Code
# >= 2.1.181 runs a startup migration that STRIPS a bare `model:"opus"` from a
# FRESH config dir — and an imported agent's config dir is always fresh. So a
# manifest that correctly says "opus" would produce an agent running the runtime
# default, with the manifest still reading correctly. The fix is to resolve at
# the import path; these assertions are what keep it there.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# No 2>/dev/null — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

cd "$(dirname "$0")/.."
ROOT=$PWD
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got '$2', want '$3')"; }

# shellcheck disable=SC1091
source "$ROOT/src/lib/models.sh"

echo "== 1. BEHAVIOURAL: the value that reaches settings.json is never a bare alias =="
# Replays the import pipeline for real: manifest value -> resolution -> the jq
# merge lifted verbatim from cmd_pack.sh. Asserts on the FILE CONTENT that an
# import would write, which is the thing migration 13 actually reads.
if command -v jq >/dev/null 2>&1; then
  merge_as_import_does() {           # $1 = manifest .config.model
    local model="$1"
    [[ -n "$model" ]] && model=$(resolve_model_alias "$model")   # the DIVE-2303 line
    jq -n --argjson cur '{}' --arg model "$model" --arg effort "" \
      '$cur
       + (if $model  != "" then {model:$model}        else {} end)
       + (if $effort != "" then {effortLevel:$effort} else {} end)'
  }
  for fam in opus sonnet fable haiku; do
    got=$(merge_as_import_does "$fam" | jq -r .model)
    want=$(model_latest "$fam")
    is "manifest '$fam' lands as full id"  "$got"  "$want"
    # The property that matters, stated directly rather than implied by the id:
    [[ "$got" != "$fam" ]] \
      && ok "'$fam' is not written bare (migration 13 would strip it)" \
      || no "'$fam' written bare into settings.json — CC strips this on first boot"
  done
  echo "== 2. a deliberate PIN still passes through untouched =="
  is "pinned id survives"  "$(merge_as_import_does claude-opus-4-8 | jq -r .model)" "claude-opus-4-8"
  is "BYO vendor/model"    "$(merge_as_import_does 'z-ai/glm-4.6'  | jq -r .model)" "z-ai/glm-4.6"
  echo "== 3. no model key at all when the manifest carries none =="
  is "absent stays absent"  "$(merge_as_import_does '' | jq -r 'has("model")')" "false"
else
  echo "  SKIP — jq not installed, so arms 1-3 were NOT REACHED (not a pass)"
  no "jq unavailable: the behavioural arms could not run"
fi

echo "== 4. STRUCTURAL: the import path still resolves BEFORE it writes =="
# Stated as structural on purpose. Arm 1 proves the pipeline is correct when the
# resolve call is present; this is the arm that proves cmd_pack.sh still contains
# it, and in the right order. A future edit that deletes the call would leave
# arm 1 green, because arm 1 replays the logic rather than the file.
src="$ROOT/src/cmd_pack.sh"
rline=$(grep -n 'model=$(resolve_model_alias "$model")' "$src" | head -1 | cut -d: -f1)
wline=$(grep -n 'if \$model  != "" then {model:\$model}' "$src" | head -1 | cut -d: -f1)
if [[ -z "$rline" ]]; then
  no "cmd_pack.sh no longer resolves the manifest model (DIVE-2303 regression)"
elif [[ -z "$wline" ]]; then
  no "could not locate the settings.json model merge — test is stale, fix the test"
elif (( rline < wline )); then
  ok "resolve at :$rline precedes the settings write at :$wline"
else
  no "resolve at :$rline happens AFTER the settings write at :$wline"
fi

echo "== 5. RENDER: the catalog shows the alias AND what it resolves to today =="
# DIVE-2303 (creative's call): index.json stores "opus", never a concrete id, so
# the entry stays true after the alias moves. `market show` resolves at render.
render_model() {                     # mirrors the cmd_pack.sh market-show block
  local _m="$1" _mres _mdisp
  _mres=$(resolve_model_alias "$_m")
  if [[ -z "$_m" ]]; then _mdisp="-"
  elif [[ "$_mres" != "$_m" ]]; then _mdisp="$_m (currently $_mres)"
  else _mdisp="$_m"; fi
  printf '%s' "$_mdisp"
}
is "alias shows both"     "$(render_model opus)"   "opus (currently claude-opus-5)"
is "ward's sonnet"        "$(render_model sonnet)" "sonnet (currently claude-sonnet-5)"
is "a pin shows bare"     "$(render_model claude-opus-4-8)" "claude-opus-4-8"
is "empty renders dash"   "$(render_model '')"     "-"
grep -q 'resolve_model_alias "$_m"' "$ROOT/src/cmd_pack.sh" \
  && ok "market show still resolves at render" \
  || no "market show no longer resolves at render (DIVE-2303 regression)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
