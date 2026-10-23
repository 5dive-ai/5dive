#!/usr/bin/env bash
# DIVE-1883 — model catalogue is the single source of truth.
#
# Guards the three things that actually broke before: (1) the alias map resolves
# to the ids we think it does and covers fable, (2) the create path emits a FULL
# resolved id (DIVE-506 — a bare alias was stripped on a fresh config dir; the
# post-boot move to the alias is tests/model_float_unit.sh), and
# (3) no call site re-inlines a model literal, which is how the CLI and the
# telegram plugin drifted a whole version apart in the first place.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
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
is "opus resolves"        "$(resolve_model_alias opus)"    "claude-opus-5-5"
is "sonnet resolves"      "$(resolve_model_alias sonnet)"  "claude-sonnet-5-5"
is "fable resolves"       "$(resolve_model_alias fable)"   "claude-fable-5-1"
is "haiku resolves"       "$(resolve_model_alias haiku)"   "claude-haiku-5-5"

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
  is "json opus"   "$(echo "$j" | jq -r .opus)"   "claude-opus-5-5"
  is "json fable"  "$(echo "$j" | jq -r .fable)"  "claude-fable-5-1"
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
# src/lib/models.sh is the ONLY file allowed to name a claude-* id, first-party
# or vendor-prefixed (DIVE-6788: the BYO [anthropic] pins in header.sh now come
# from model_latest too). Exempt: comments, which cite history. This is the
# grader's grep for DIVE-6788, run over src/ and install.sh.
stray=$(grep -rnE '(anthropic/)?claude-(opus|sonnet|haiku|fable)-[0-9]' src/ install.sh \
        | grep -v '^src/lib/models.sh:' | grep -vE ':[0-9]+: *#' || true)
if [[ -z "$stray" ]]; then ok "no hardcoded model id outside models.sh"
else no "hardcoded model id(s) outside models.sh:"; printf '%s\n' "$stray"; fi
# Negative control: the same grep must catch the pin this row removed.
probe=$(printf '  [anthropic]="anthropic/claude-sonnet-5"\n' | grep -nE '(anthropic/)?claude-(opus|sonnet|haiku|fable)-[0-9]' | grep -vE ':[0-9]+: *#' || true)
[[ -n "$probe" ]] && ok "the grep catches a vendor-prefixed literal" || no "the grep is blind to anthropic/claude-*"

echo "== 6b. old defaults are recognised; nothing else is (DIVE-6788) =="
is "previous sonnet"      "$(model_default_family claude-sonnet-5)"            "sonnet"
is "previous haiku"       "$(model_default_family claude-haiku-4-5-20251001)"  "haiku"
is "previous opus"        "$(model_default_family claude-opus-4-8)"            "opus"
is "current fable"        "$(model_default_family "$(model_latest fable)")"    "fable"
is "a chosen id is not a default" "$(model_default_family claude-sonnet-4-5)"  ""
is "a bare alias is not a default" "$(model_default_family sonnet)"            ""
is "a vendor slug is not a default" "$(model_default_family anthropic/claude-sonnet-5.5)" ""
both=""
fams=$(model_families)
while read -r fam; do
  ids=$(model_previous "$fam")
  grep -qxF -- "$(model_latest "$fam")" <<<"$ids" && both+="$fam "
done <<<"$fams"
is "no current id is also listed as previous" "$both" ""
declare -A HERMES_PROVIDER_MODEL=() OPENCLAW_PROVIDER_MODEL=()
# shellcheck disable=SC1091
source "$ROOT/src/lib/models.sh"
is "hermes anthropic pin follows the catalogue"   "${HERMES_PROVIDER_MODEL[anthropic]}"   "$(model_latest sonnet)"
is "openclaw anthropic pin follows the catalogue" "${OPENCLAW_PROVIDER_MODEL[anthropic]}" "anthropic/$(model_latest sonnet)"

echo "== 6c. the daily release check (offline, through --catalog; DIVE-6788) =="
TMPC=$(mktemp -d)
cat_of() { jq -n --args '{data: [$ARGS.positional[] | {id: .}]}' "$@" >"$TMPC/c.json"; }
latest() { bash scripts/claude-model-latest.sh --catalog="$TMPC/c.json" >"$TMPC/out" 2>/dev/null; echo "rc=$?"; }
cur=()
while read -r fam; do
  v=$(model_latest "$fam"); v=${v#"claude-$fam-"}; v=$(sed -E 's/-[0-9]{8}$//; s/-/./g' <<<"$v")
  cur+=("anthropic/claude-$fam-$v")
done < <(model_families)
cat_of "${cur[@]}" anthropic/claude-sonnet-5 anthropic/claude-haiku-4.5
is "current table, current catalog: green"        "$(latest)" "rc=0"
cat_of "${cur[@]}" anthropic/claude-sonnet-9.1
is "a newer sonnet: red"                          "$(latest)" "rc=1"
grep -q '^sonnet .*latest=anthropic/claude-sonnet-9.1$' "$TMPC/out" && ok "...and it names the newer slug" || no "the newer slug is not named: $(cat "$TMPC/out")"
cat_of "${cur[@]}" anthropic/claude-sonnet-9.1:batch anthropic/claude-sonnet-9.1-fast
is "only :batch / -fast variants newer: green"    "$(latest)" "rc=0"
cat_of "${cur[@]}" anthropic/claude-tempo-1
is "a family name we do not know: red"            "$(latest)" "rc=1"
cat_of openai/gpt-6.1-sol
is "no Claude in the catalog: could not check"    "$(latest)" "rc=2"
# Negative control: the 2026-10-16 table (sonnet 5, haiku 4.5) against today's
# catalog is what this check exists to catch.
mkdir -p "$TMPC/old/scripts" "$TMPC/old/src/lib"
cp scripts/claude-model-latest.sh "$TMPC/old/scripts/"
sed -e 's/"claude-sonnet-5-5"/"claude-sonnet-5"/' -e 's/"claude-haiku-5-5"/"claude-haiku-4-5-20251001"/' \
  src/lib/models.sh >"$TMPC/old/src/lib/models.sh"
cat_of "${cur[@]}"
bash "$TMPC/old/scripts/claude-model-latest.sh" --catalog="$TMPC/c.json" >"$TMPC/out" 2>/dev/null; rc=$?
is "the old table goes red"                       "rc=$rc" "rc=1"
grep -q '^haiku current=claude-haiku-4-5-20251001 latest=anthropic/claude-haiku-5.5$' "$TMPC/out" \
  && ok "...reading a dated id as its version" || no "dated id misread: $(cat "$TMPC/out")"
rm -rf "$TMPC"
WF=.github/workflows/claude-model-latest.yml
grep -q 'bash scripts/claude-model-latest.sh' "$WF" && grep -q "cron:" "$WF" \
  && ok "workflow: daily, runs the shipped script" || no "workflow: not scheduled or not running the script"

echo "== 7. 5dive models --json emits the standard {ok,data} envelope =="
if [[ -x "$ROOT/5dive" ]] && command -v jq >/dev/null 2>&1; then
  env_out=$(bash "$ROOT/5dive" models --json 2>/dev/null)
  is "envelope ok"    "$(echo "$env_out" | jq -r .ok)"           "true"
  is "envelope opus"  "$(echo "$env_out" | jq -r .data.opus)"    "claude-opus-5-5"
  is "envelope fable" "$(echo "$env_out" | jq -r .data.fable)"   "claude-fable-5-1"
  is "text form"      "$(bash "$ROOT/5dive" models 2>/dev/null | awk '$1=="fable"{print $2}')" "claude-fable-5-1"
else
  echo "  skip envelope assertions (no built ./5dive or no jq)"
fi

echo "== 8. the built bundle carries the catalogue =="
if [[ -f "$ROOT/5dive" ]]; then
  grep -q 'resolve_model_alias()' "$ROOT/5dive" && ok "bundle has resolve_model_alias" \
    || no "bundle is missing resolve_model_alias — run ./build.sh"
  grep -q 'claude-opus-5-5' "$ROOT/5dive" && ok "bundle has the current opus id" \
    || no "bundle does not carry claude-opus-5-5 — run ./build.sh"
else
  echo "  skip bundle assertions (no ./5dive built)"
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
