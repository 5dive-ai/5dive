#!/usr/bin/env bash
# DIVE-5264 — a team template's `model: opus|sonnet` resolves against the
# ACCOUNT the seat is bound to, the way pack import does since DIVE-5163.
#
# THE BUG: every curated team template pins opus/sonnet per role, and
# _compose_wire_role resolved them with resolve_model_alias -> claude-opus-5-5 /
# claude-sonnet-5 whatever the account. Claude Code applies an account's
# ANTHROPIC_DEFAULT_* map to ALIASES only, so on the seeded OpenRouter account (or
# a my.5dive box's demo-ai key) a full claude-* id went out as-is and OpenRouter
# billed a 5-seat team as real Claude Opus and Sonnet.
#
# Arms drive the REAL `team import` -> `up` -> _compose_wire_role on the startup
# template. Only the provisioning CLI is faked: a recorder that registers the seat
# with the --auth-profile it was created with, and mirrors `agent config set
# model=` forgetting the family on a full id (cmd_agent_config.sh, DIVE-5163) —
# so the recorded-family arm is graded against the real ordering hazard.
#
#   T1-T3  OpenRouter-style account: each role lands on its OWN tier's mapped id,
#          no seat is set to a claude-* id, and each remembers its family.
#   T4     NEGATIVE CONTROL: an Anthropic account resolves exactly as before.
#   T5     no account (defer_auth template): unchanged, family still recorded so
#          `agent set-account` can move it later.
#   T6     a failed model set records no family and warns.
#   M1/M2  mutants: reverting to resolve_model_alias, or dropping the family
#          write, turn T1/T3 red.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/models.sh src/lib/state.sh src/lib/audit.sh src/lib/registry.sh \
         src/lib/tasks_db.sh src/lib/actor.sh src/lib/marketplace.sh src/task/routing.sh \
         src/cmd_compose.sh src/cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
# The sourced CLI turns errexit ON; several helpers legitimately end on a false
# [[ ]] — same reason every sibling team harness does this.
set +e

TMP="$(mktemp -d /tmp/team-import-model.XXXXXX)"
JSON_MODE=0
PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

FIX="$ROOT/tests/fixtures/team-templates"
unset TEAM_TG_TOKEN

# ---- accounts ----------------------------------------------------------------
# Distinct per-tier ids so a role landing on the WRONG tier is visible too.
OPUS_T="vendor/opus-tier"; SONNET_T="vendor/sonnet-tier"; HAIKU_T="vendor/haiku-tier"
AUTH_PROFILES_DIR="$TMP/profiles"
mkdir -p "$AUTH_PROFILES_DIR/demo-ai" "$AUTH_PROFILES_DIR/client-claude"
printf 'ANTHROPIC_BASE_URL=https://openrouter.ai/api\nANTHROPIC_AUTH_TOKEN=sk-test\nANTHROPIC_DEFAULT_OPUS_MODEL=%s\nANTHROPIC_DEFAULT_SONNET_MODEL=%s\nANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' \
  "$OPUS_T" "$SONNET_T" "$HAIKU_T" >"$AUTH_PROFILES_DIR/demo-ai/combined.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=oat-test\n' >"$AUTH_PROFILES_DIR/client-claude/combined.env"

# ---- the ONE network call is replaced; the resolver above it is real --------
mkdir -p "$TMP/reg/teams"
cp "$FIX/index.json" "$TMP/reg/teams/index.json"
cp "$FIX/startup.5dive.yaml" "$FIX/distribution.5dive.yaml" "$TMP/reg/teams/"
REG_BASE="$(_teams_registry_base)"
_teams_get() {
  local rel="${1#"$REG_BASE"/}"
  [[ -f "$TMP/reg/$rel" ]] || return 1
  cp "$TMP/reg/$rel" "$2"
}

# ---- provisioning seams ------------------------------------------------------
export REGF="$TMP/registry.json" MODELS="$TMP/models.log"
cat >"$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
# agent create <name> ... [--auth-profile=P]  -> register the seat, bound to P
# agent config <name> set model=<m>           -> record; a full id forgets the family
if [[ "$1 $2" == "agent create" ]]; then
  n="$3" p=""
  for a in "$@"; do [[ "$a" == --auth-profile=* ]] && p="${a#--auth-profile=}"; done
  jq --arg n "$n" --arg p "$p" '.agents[$n] = ({type:"claude"} + (if $p == "" then {} else {authProfile:$p} end))' \
    "$REGF" >"$REGF.n" && mv "$REGF.n" "$REGF"
elif [[ "$1 $2 $4" == "agent config set" && "$5" == model=* ]]; then
  [[ -n "${FAIL_CONFIG:-}" ]] && exit 1
  m="${5#model=}"
  printf '%s %s\n' "$3" "$m" >>"$MODELS"
  case "$m" in opus|sonnet|fable|haiku) ;; *)
    jq --arg n "$3" 'del(.agents[$n].modelFamily)' "$REGF" >"$REGF.n" && mv "$REGF.n" "$REGF" ;;
  esac
fi
exit 0
SH
chmod +x "$TMP/fake5dive"
_compose_self()   { printf '%s' "$TMP/fake5dive"; }
ensure_state()    { :; }
ensure_state_ro() { :; }
registry_read()   { cat "$REGF"; }
registry_write()  { cat >"$REGF.w" && mv "$REGF.w" "$REGF"; }
persona_append_block() { :; }

fresh() {
  rm -rf "$TMP/state"
  STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
  mkdir -p "$TASKS_DIR"; tasks_db_init >/dev/null 2>&1
  printf '%s' '{"agents":{}}' >"$REGF"; : >"$MODELS"
}
import() { # <slug> [--auth-profile=P]
  fresh
  ( cmd_team import "$@" ) >"$TMP/import.out" 2>&1
}
model_of()  { awk -v n="$1" '$1==n {m=$2} END {print m}' "$MODELS"; }
family_of() { jq -r --arg n "$1" '.agents[$n].modelFamily // ""' "$REGF"; }

# The template's own pins are the oracle — not a copy of them typed in here.
PINS="$(TEAM_AUTH_PROFILE=fixture _compose_parse "$FIX/startup.5dive.yaml" 2>/dev/null | jq -r '.agents | to_entries[] | "\(.key) \(.value.model // "")"')"
NPINS="$(awk '$2 ~ /^(opus|sonnet)$/' <<<"$PINS" | grep -c .)"
if (( NPINS >= 4 )) && grep -q ' opus$' <<<"$PINS" && grep -q ' sonnet$' <<<"$PINS" \
   && grep -q 'auth_profile: "${TEAM_AUTH_PROFILE}"' "$FIX/startup.5dive.yaml"; then
  ok_t "T0 precondition: startup pins $NPINS roles to opus/sonnet and binds the team account"
else
  bad_t 'T0 precondition failed — every arm below is vacuous' "$PINS"
fi
tier_of() { case "$1" in opus) printf '%s' "$OPUS_T" ;; sonnet) printf '%s' "$SONNET_T" ;; esac; }

# grade_openrouter <label-prefix>: T1-T3 against whatever cmd_compose.sh is sourced.
grade_openrouter() {
  local p="$1" n fam want bad_tier="" claude_ids="" bad_fam=""
  import startup --auth-profile=demo-ai
  while read -r n fam; do
    [[ "$fam" == opus || "$fam" == sonnet ]] || continue
    want=$(tier_of "$fam")
    [[ "$(model_of "$n")" == "$want" ]] || bad_tier+=" $n=$(model_of "$n")(want $want)"
    [[ "$(family_of "$n")" == "$fam" ]] || bad_fam+=" $n=$(family_of "$n")(want $fam)"
  done <<<"$PINS"
  claude_ids=$(awk '$2 ~ /^claude-/' "$MODELS" | paste -sd' ' -)
  if [[ -z "$bad_tier" && -s "$MODELS" ]]; then ok_t "${p}1 OpenRouter account: every role lands on its own tier's mapped id"
  else bad_t "${p}1 OpenRouter account: a role is not on its account tier" "${bad_tier:-no model was set at all}"; fi
  eq_t "${p}2 OpenRouter account: no seat is set to a real claude-* id" "" "$claude_ids"
  if [[ -z "$bad_fam" ]]; then ok_t "${p}3 each seat remembers the family its template asked for"
  else bad_t "${p}3 a seat lost its family" "$bad_fam"; fi
}

echo '== OpenRouter-style account (the defect) =='
grade_openrouter T

echo '== T4 NEGATIVE CONTROL: an Anthropic account is unchanged =='
import startup --auth-profile=client-claude
bad=""
while read -r n fam; do
  [[ -n "$fam" ]] || continue
  [[ "$(model_of "$n")" == "$(resolve_model_alias "$fam")" ]] || bad+=" $n=$(model_of "$n")"
done <<<"$PINS"
[[ -z "$bad" && -s "$MODELS" ]] && ok_t 'T4 Anthropic account: every role gets exactly what resolve_model_alias gave before' \
  || bad_t 'T4 an Anthropic-account seat moved' "${bad:-no model was set at all}"

echo '== T5 no account yet (defer_auth template) =='
DPINS="$(_compose_parse "$FIX/distribution.5dive.yaml" 2>/dev/null | jq -r '.agents | to_entries[] | select((.value.model // "") | test("^(opus|sonnet)$")) | "\(.key) \(.value.model)"')"
import distribution
bad=""; badf=""
while read -r n fam; do
  [[ -n "$n" ]] || continue
  [[ "$(model_of "$n")" == "$(model_latest "$fam")" ]] || bad+=" $n=$(model_of "$n")"
  [[ "$(family_of "$n")" == "$fam" ]] || badf+=" $n"
done <<<"$DPINS"
if [[ -n "$DPINS" && -z "$bad" ]]; then ok_t 'T5 an unbound seat resolves as before (the current claude id)'
else bad_t 'T5 an unbound seat moved, or the template pins nothing' "${bad:-DPINS empty}"; fi
[[ -n "$DPINS" && -z "$badf" ]] && ok_t 'T5b and still records its family, so set-account can move it later' \
  || bad_t 'T5b an unbound seat has no recorded family' "$badf"

echo '== T6 a failed model set records no family =='
FAIL_CONFIG=1 import startup --auth-profile=demo-ai
eq_t 'T6 no family is recorded for a seat whose model was never set' "" \
  "$(jq -r '[.agents[] | .modelFamily // empty] | join(",")' "$REGF")"
grep -q 'set model=.* failed' "$TMP/import.out" && ok_t 'T6b and the import says so' \
  || bad_t 'T6b a failed model set was silent' "$(tail -3 "$TMP/import.out")"

echo '== mutants =='
MUT="$TMP/cmd_compose.mut.sh"
sed 's/model=$(resolve_model_for_profile "$model" "$profile")/model=$(resolve_model_alias "$model")/' \
  src/cmd_compose.sh >"$MUT"
if cmp -s src/cmd_compose.sh "$MUT"; then
  bad_t 'M1 mutant did not apply — the resolve line moved' ''
else
  # shellcheck source=/dev/null
  source "$MUT"; set +e; _compose_self() { printf '%s' "$TMP/fake5dive"; }
  out=$(grade_openrouter M1.)
  grep -q '^FAIL - M1.1' <<<"$out" && grep -q '^FAIL - M1.2' <<<"$out" \
    && ok_t 'M1 reverting to resolve_model_alias turns T1 and T2 red (claude ids on OpenRouter)' \
    || bad_t 'M1 the mutant survived' "$out"
fi
sed "s/'.agents\[\$n\].modelFamily = \$f'/'.'/" src/cmd_compose.sh >"$MUT"
if cmp -s src/cmd_compose.sh "$MUT"; then
  bad_t 'M2 mutant did not apply — the family write moved' ''
else
  # shellcheck source=/dev/null
  source "$MUT"; set +e; _compose_self() { printf '%s' "$TMP/fake5dive"; }
  out=$(grade_openrouter M2.)
  grep -q '^FAIL - M2.3' <<<"$out" && grep -q '^ok   - M2.1' <<<"$out" \
    && ok_t 'M2 dropping the family write turns T3 red and nothing else' \
    || bad_t 'M2 the mutant survived' "$out"
fi
# shellcheck source=/dev/null
source src/cmd_compose.sh; set +e

printf '\n%s\n' "team_import_model_for_account_unit: pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
