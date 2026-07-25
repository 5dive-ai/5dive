#!/usr/bin/env bash
# DIVE-1883 — model catalogue is the single source of truth.
#
# Guards the three things that actually broke before: (1) the alias map resolves
# to the ids we think it does and covers fable, (2) the create path emits a FULL
# resolved id (DIVE-506 — a bare alias is stripped on a fresh config dir), and
# (3) no call site re-inlines a model literal, which is how the CLI and the
# telegram plugin drifted a whole version apart in the first place.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got '$2', want '$3')"; }

# Source just the catalogue — no globals, no side effects.
# shellcheck disable=SC1091
source "$ROOT/src/lib/models.sh"

echo "== 1. alias -> current id =="
is "opus resolves"        "$(resolve_model_alias opus)"    "claude-opus-5"
is "sonnet resolves"      "$(resolve_model_alias sonnet)"  "claude-sonnet-5"
is "fable resolves"       "$(resolve_model_alias fable)"   "claude-fable-5"
is "haiku resolves"       "$(resolve_model_alias haiku)"   "claude-haiku-4-5-20251001"

echo "== 2. pass-through for non-aliases =="
is "full id untouched"    "$(resolve_model_alias claude-opus-4-8)" "claude-opus-4-8"
is "BYO vendor/model"     "$(resolve_model_alias 'z-ai/glm-4.6')"  "z-ai/glm-4.6"
is "empty stays empty"    "$(resolve_model_alias '')"              ""
is "unknown stays"        "$(resolve_model_alias nope)"            "nope"

echo "== 3. every family is mapped, and fable is present =="
missing=""
while read -r fam; do model_latest "$fam" >/dev/null || missing+="$fam "; done < <(model_families)
is "no unmapped family"   "$missing" ""
model_families | grep -qx fable && ok "fable is a selectable family" || no "fable missing from model_families"

echo "== 4. models_json is valid JSON with all four families =="
j=$(models_json)
if command -v jq >/dev/null 2>&1; then
  echo "$j" | jq -e . >/dev/null 2>&1 && ok "models_json parses" || no "models_json is not valid JSON: $j"
  is "json opus"   "$(echo "$j" | jq -r .opus)"   "claude-opus-5"
  is "json fable"  "$(echo "$j" | jq -r .fable)"  "claude-fable-5"
  is "json keys"   "$(echo "$j" | jq -r 'keys_unsorted|join(",")')" "opus,sonnet,fable,haiku"
else
  echo "  skip jq assertions (jq not installed)"
fi

echo "== 5. resolved id is a FULL id, never a bare alias (DIVE-506) =="
# A bare alias in settings.json is stripped by CC's migrationVersion 13 on a
# fresh config dir, so the create path must never emit one.
badpin=""
while read -r fam; do
  id=$(model_latest "$fam")
  [[ "$id" == "$fam" ]] && badpin+="$fam "
  [[ "$id" == claude-* ]] || badpin+="$fam(shape) "
done < <(model_families)
is "no bare/odd pin"      "$badpin" ""

echo "== 6. no call site re-inlines a model literal =="
# src/lib/models.sh is the ONLY file allowed to name a first-party claude-* id
# on the agent-create / compose path. Exempt: comments (they cite DIVE-506
# history) and the third-party BYO provider catalogues in header.sh
# (`[provider]="<slug>"` entries in HERMES_/OPENCLAW_/CLAUDE_PROVIDER_*_MODEL) —
# those are vendor-registry slugs for non-first-party endpoints, deliberately
# pinned and verified per provider, not the Claude Code model id this catalogue
# owns.
stray=$(grep -rn --include='*.sh' -E '"claude-(opus|sonnet|haiku|fable)-[0-9]' src/ \
        | grep -v '^src/lib/models.sh:' | grep -vE ':[0-9]+: *#' \
        | grep -vE ':[0-9]+: *\[[a-z0-9_]+\]=' || true)
if [[ -z "$stray" ]]; then ok "no hardcoded model id outside models.sh"
else no "hardcoded model id(s) outside models.sh:"; printf '%s\n' "$stray"; fi

echo "== 7. 5dive models --json emits the standard {ok,data} envelope =="
if [[ -x "$ROOT/5dive" ]] && command -v jq >/dev/null 2>&1; then
  env_out=$(bash "$ROOT/5dive" models --json 2>/dev/null)
  is "envelope ok"    "$(echo "$env_out" | jq -r .ok)"           "true"
  is "envelope opus"  "$(echo "$env_out" | jq -r .data.opus)"    "claude-opus-5"
  is "envelope fable" "$(echo "$env_out" | jq -r .data.fable)"   "claude-fable-5"
  is "text form"      "$(bash "$ROOT/5dive" models 2>/dev/null | awk '$1=="fable"{print $2}')" "claude-fable-5"
else
  echo "  skip envelope assertions (no built ./5dive or no jq)"
fi

echo "== 8. the built bundle carries the catalogue =="
if [[ -f "$ROOT/5dive" ]]; then
  grep -q 'resolve_model_alias()' "$ROOT/5dive" && ok "bundle has resolve_model_alias" \
    || no "bundle is missing resolve_model_alias — run ./build.sh"
  grep -q 'claude-opus-5' "$ROOT/5dive" && ok "bundle has the current opus id" \
    || no "bundle does not carry claude-opus-5 — run ./build.sh"
else
  echo "  skip bundle assertions (no ./5dive built)"
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
