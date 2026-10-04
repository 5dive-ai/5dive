#!/usr/bin/env bash
# DIVE-5503: a new codex agent starts on the current GPT Sol, not whatever the
# Codex CLI defaults to (it was gpt-6-astra on poke-two), and an existing agent's
# model is never rewritten. Three pieces, each graded here against the SHIPPED
# code, extracted rather than copied:
#   1. codex_model_default (src/lib/models.sh): the one pinned id.
#   2. seed_codex_model (src/lib/agent_setup.sh) + cmd_create's codex branch: the
#      model a create chose (--model, else the default) is left as a one-shot seed.
#   3. apply_codex_model_seed (5dive-agent-start): first start writes it as the
#      top-level `model` only when config.toml names none, then drops the seed.
# Plus scripts/codex-model-latest.sh, the daily check that keeps 1. from rotting,
# driven offline through its --catalog seam.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi; }

START=5dive-agent-start
CREATE=src/cmd_agent_create.sh
SETUP=src/lib/agent_setup.sh

# shellcheck source=../src/lib/models.sh
source src/lib/models.sh

# ---------------------------------------------------------------------------
# 1. The constant.
# ---------------------------------------------------------------------------
_def="$(codex_model_default)"
[[ "$_def" =~ ^gpt-[0-9]+(\.[0-9]+)*-sol$ ]] \
  && ok_t "default: '$_def' is a plain GPT Sol id" \
  || bad_t "default: '$_def' is not a gpt-<version>-sol id"
[[ "$_def" != *astra* ]] && ok_t "default: not Astra" || bad_t "default: still Astra"
# ONE place: no other CLI source or launcher spells a Sol/Astra id as a default.
_dupes="$(grep -rnE '"gpt-[0-9.]+-(sol|astra)"' src 5dive-agent-start 2>/dev/null | grep -v '^src/lib/models.sh:' || true)"
eq_t "default: the id is spelled in models.sh only" "" "$_dupes"

# ---------------------------------------------------------------------------
# 2. Create leaves the seed.
# ---------------------------------------------------------------------------
eval "$(awk '/^seed_codex_model\(\) \{$/ { on = 1 } on { print } on && $0 == "}" { exit }' "$SETUP")"
declare -F seed_codex_model >/dev/null || { echo "FATAL - could not extract seed_codex_model"; exit 1; }
chown() { :; }   # the harness is not root; ownership is cmd_create's privilege, not the logic graded here
export AGENT_HOME_ROOT="$TMP/homes"
seed_codex_model newsol "$_def"; _rc=$?
eq_t "seed: rc 0" "0" "$_rc"
eq_t "seed: the chosen model is the file's only line" "$_def" "$(cat "$TMP/homes/agent-newsol/.codex/.5dive-model-seed" 2>/dev/null)"
eq_t "seed: 0600" "600" "$(stat -c '%a' "$TMP/homes/agent-newsol/.codex/.5dive-model-seed" 2>/dev/null)"
seed_codex_model emptyseed ""; _rc=$?
[[ "$_rc" -ne 0 && ! -e "$TMP/homes/agent-emptyseed/.codex/.5dive-model-seed" ]] \
  && ok_t "seed: an empty model writes nothing and says so (rc $_rc)" \
  || bad_t "seed: an empty model left a seed that would pin model = \"\""

# The codex branch of cmd_create seeds --model when given, else the default, and
# validates --model before anything is created.
_branch="$(awk '/preseed_codex_return_channel "\$name"/ { on = 1 } on { print } on && /^  fi$/ { exit }' "$CREATE")"
grep -q '_codex_model="${byo_model:-$(codex_model_default)}"' <<<"$_branch" \
  && ok_t "create: codex seeds --model, else codex_model_default" \
  || bad_t "create: the codex branch does not choose --model-else-default"
grep -q 'seed_codex_model "$name" "$_codex_model"' <<<"$_branch" \
  && ok_t "create: the chosen model is seeded" \
  || bad_t "create: the chosen model is never handed to seed_codex_model"
_vline=$(grep -n 'type" == "codex" && -n "$byo_model"' "$CREATE" | head -1 | cut -d: -f1)
_uline=$(grep -n 'create_agent_user "$name"' "$CREATE" | head -1 | cut -d: -f1)
if [[ -n "$_vline" && -n "$_uline" && "$_vline" -lt "$_uline" ]]; then
  ok_t "create: a codex --model is validated before the agent user exists"
else
  bad_t "create: codex --model validation missing or after the user is created (v=${_vline:-none} u=${_uline:-none})"
fi

# ---------------------------------------------------------------------------
# 3. First start applies it — only where no model was chosen.
# ---------------------------------------------------------------------------
eval "$(awk '/^  apply_codex_model_seed\(\) \{/ { on = 1 } on { print } on && $0 == "  }" { exit }' "$START")"
declare -F apply_codex_model_seed >/dev/null || { echo "FATAL - could not extract apply_codex_model_seed"; exit 1; }
grep -q '^  apply_codex_model_seed "\$AGENT_CODEX_HOME"$' "$START" \
  && ok_t "start: the seed is applied on every codex start" \
  || bad_t "start: apply_codex_model_seed is defined but never called"
_cl=$(grep -n '^  apply_codex_model_seed "\$AGENT_CODEX_HOME"$' "$START" | cut -d: -f1)
_bl=$(grep -n 'if \[\[ ! -f "\$AGENT_CODEX_HOME/config.toml" \]\]; then' "$START" | head -1 | cut -d: -f1)
[[ -n "$_cl" && -n "$_bl" && "$_cl" -gt "$_bl" ]] \
  && ok_t "start: applied AFTER the baseline config.toml is written" \
  || bad_t "start: applied before the baseline exists — a fresh seat would get no model"

baseline() { # the 5dive-agent-start baseline shape, optionally with a model line
  printf '%sapproval_policy = "never"\nsandbox_mode = "danger-full-access"\n\n[projects."/w"]\ntrust_level = "trusted"\n' "${1:-}"
}
mk() { mkdir -p "$TMP/$1"; baseline "${2:-}" > "$TMP/$1/config.toml"; [[ -n "${3:-}" ]] && printf '%s\n' "$3" > "$TMP/$1/.5dive-model-seed"; true; }
top_model() { awk '/^[ \t]*\[/ { exit } /^[ \t]*model[ \t]*=/ { print; exit }' "$1"; }

# a. A fresh seat: the seeded default lands, the rest of the file is untouched.
mk fresh "" "$_def"
apply_codex_model_seed "$TMP/fresh"
eq_t "start: a fresh seat runs the seeded default" "model = \"$_def\"" "$(top_model "$TMP/fresh/config.toml")"
eq_t "start: the baseline below is byte-identical" "$(baseline)" "$(tail -n +2 "$TMP/fresh/config.toml")"
[[ ! -e "$TMP/fresh/.5dive-model-seed" ]] && ok_t "start: the seed is consumed" || bad_t "start: the seed survives and would re-apply"

# b. Negative control: create --model=gpt-6-astra keeps Astra.
mk astra "" "gpt-6-astra"
apply_codex_model_seed "$TMP/astra"
eq_t "start: --model=gpt-6-astra keeps Astra" 'model = "gpt-6-astra"' "$(top_model "$TMP/astra/config.toml")"

# c. A model someone already chose is never rewritten (Leo stays on Astra).
mk chosen 'model = "gpt-6-astra"
' "$_def"
cp "$TMP/chosen/config.toml" "$TMP/chosen.before"
apply_codex_model_seed "$TMP/chosen"
eq_t "start: an existing top-level model is left byte-identical" "$(cat "$TMP/chosen.before")" "$(cat "$TMP/chosen/config.toml")"
[[ ! -e "$TMP/chosen/.5dive-model-seed" ]] && ok_t "start: the seed is dropped even when not applied" || bad_t "start: an unapplied seed lingers"

# d. No seed (every agent created before this change): nothing happens.
mk legacy ""
cp "$TMP/legacy/config.toml" "$TMP/legacy.before"
apply_codex_model_seed "$TMP/legacy"
eq_t "start: no seed, no change" "$(cat "$TMP/legacy.before")" "$(cat "$TMP/legacy/config.toml")"

# e. A `model` inside a [table] is not the top-level model: the seed still lands
# at the top, and the table's own key is untouched.
mkdir -p "$TMP/table"
printf 'approval_policy = "never"\n\n[profiles.fast]\nmodel = "gpt-5.6-luna"\n' > "$TMP/table/config.toml"
printf '%s\n' "$_def" > "$TMP/table/.5dive-model-seed"
apply_codex_model_seed "$TMP/table"
eq_t "start: a table-scoped model is not mistaken for a choice" "model = \"$_def\"" "$(top_model "$TMP/table/config.toml")"
grep -q '^model = "gpt-5.6-luna"$' "$TMP/table/config.toml" && ok_t "start: the table's key survives" || bad_t "start: the table's key was lost"

# f. A seed that is not a model id writes nothing (it reaches a TOML string).
mk evil "" 'x" ; danger = "y'
cp "$TMP/evil/config.toml" "$TMP/evil.before"
apply_codex_model_seed "$TMP/evil" 2>/dev/null
eq_t "start: a malformed seed is not written" "$(cat "$TMP/evil.before")" "$(cat "$TMP/evil/config.toml")"
[[ ! -e "$TMP/evil/.5dive-model-seed" ]] && ok_t "start: a malformed seed is still consumed" || bad_t "start: a malformed seed lingers"

eq_t "start: the written file stays 0600" "600" "$(stat -c '%a' "$TMP/fresh/config.toml")"

# ---------------------------------------------------------------------------
# 4. The daily staleness check (offline, through --catalog).
# ---------------------------------------------------------------------------
cat_of() { local f="$TMP/cat-$1.json"; shift; jq -n --args '{data: [$ARGS.positional[] | {id: .}]}' "$@" > "$f"; printf '%s' "$f"; }
_ver="${_def#gpt-}"; _ver="${_ver%-sol}"
latest() { bash scripts/codex-model-latest.sh --catalog="$1" 2>/dev/null; echo "rc=$?"; }

out="$(latest "$(cat_of same "openai/$_def" "openai/gpt-5.6-sol" "openai/gpt-6-astra")")"
eq_t "check: the pin is the newest Sol -> rc 0" "current=$_def latest=$_def
rc=0" "$out"
out="$(latest "$(cat_of newer "openai/$_def" "openai/gpt-99.2-sol" "openai/gpt-99-sol")")"
eq_t "check: a newer Sol -> rc 1 and names it" "current=$_def latest=gpt-99.2-sol
rc=1" "$out"
out="$(latest "$(cat_of variants "openai/$_def" "openai/gpt-99-sol-pro" "openai/gpt-99-sol:batch" "openai/gpt-99-sol-20990101" "openai/gpt-99-astra")")"
eq_t "check: -pro, :batch, dated snapshots and Astra are not a new default" "current=$_def latest=$_def
rc=0" "$out"
out="$(latest "$(cat_of older "openai/gpt-5.6-sol")")"
eq_t "check: a catalog that only has older Sols keeps the pin" "current=$_def latest=$_def
rc=0" "$out"
out="$(latest "$(cat_of none "openai/gpt-6-astra")")"
eq_t "check: no Sol at all is unreadable (rc 2), never 'current'" "rc=2" "$out"
printf 'not json' > "$TMP/garbage.json"
out="$(latest "$TMP/garbage.json")"
eq_t "check: garbage is rc 2" "rc=2" "$out"
# Version order, not string order: 99.10 is newer than 99.9 (a lexical sort
# picks 99.9 and would never flag 99.10).
out="$(latest "$(cat_of order "openai/gpt-99.9-sol" "openai/gpt-99.10-sol" "openai/$_def")")"
eq_t "check: versions compare numerically (99.10 > 99.9)" "current=$_def latest=gpt-99.10-sol
rc=1" "$out"

# The workflow runs the script and treats rc 2 as a failed run, not a pass.
WF=.github/workflows/codex-model-latest.yml
grep -q 'bash scripts/codex-model-latest.sh' "$WF" && ok_t "workflow: runs the shipped script" || bad_t "workflow: does not run the script"
grep -q 'if \[ "$rc" -eq 2 \]; then' "$WF" && grep -q 'schedule:' "$WF" \
  && ok_t "workflow: daily, and an unreadable catalog fails the run" \
  || bad_t "workflow: not scheduled, or an unreadable catalog reads as current"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
