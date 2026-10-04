#!/usr/bin/env bash
# DIVE-5514 — an opencode seat imported onto the seeded OpenRouter account is
# pinned to the account's model.
#
# THE BUG: Anthropic region-blocks Russia, so 5dive-api imports a Russian
# partner box's agents onto opencode, bound to the box's seeded `openrouter`
# account. A non-BYO import never wrote opencode.json, so the seat ran whatever
# OpenCode picks by default for OpenRouter — not the account's model, and not
# what the box's spend cap was set up for.
#
#   T1-T3  an OpenRouter alias-mapping account with an opencode key: the pack's
#          family resolves to that tier's slug; no family = sonnet's.
#   T4     NEGATIVE: an Anthropic account (no base url) pins nothing.
#   T5     NEGATIVE: an OpenRouter claude map with NO opencode key pins nothing.
#   T6     NEGATIVE: a base url that is not OpenRouter pins nothing.
#   T7     the import calls the pin for an opencode, non-BYO seat only, after create.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/models.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/oc-model-pin.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

AUTH_PROFILES_DIR="$TMP/profiles"
mk() { mkdir -p "$AUTH_PROFILES_DIR/$1"; printf '%s\n' "${@:2}" > "$AUTH_PROFILES_DIR/$1/combined.env"; }
mk openrouter "ANTHROPIC_BASE_URL=https://openrouter.ai/api" "ANTHROPIC_AUTH_TOKEN=sk-or-v1-test" \
  "ANTHROPIC_DEFAULT_OPUS_MODEL=vendor/opus-tier" "ANTHROPIC_DEFAULT_SONNET_MODEL=vendor/sonnet-tier" \
  "ANTHROPIC_DEFAULT_HAIKU_MODEL=vendor/haiku-tier" "OPENROUTER_API_KEY=sk-or-v1-test"
mk anthropic "ANTHROPIC_API_KEY=sk-ant-test" "OPENROUTER_API_KEY=sk-or-v1-test"
mk claude-only "ANTHROPIC_BASE_URL=https://openrouter.ai/api" "ANTHROPIC_DEFAULT_SONNET_MODEL=vendor/sonnet-tier"
mk deepseek "ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic" "ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-chat" "OPENROUTER_API_KEY=sk-or-v1-test"

eq_t "T1 sonnet pack -> the account's sonnet slug" "vendor/sonnet-tier" "$(opencode_profile_model openrouter sonnet)"
eq_t "T2 opus pack -> the account's opus slug"     "vendor/opus-tier"   "$(opencode_profile_model openrouter opus)"
eq_t "T3 no family -> sonnet's slug"               "vendor/sonnet-tier" "$(opencode_profile_model openrouter "")"
eq_t "T4 Anthropic account pins nothing"           ""                   "$(opencode_profile_model anthropic sonnet)"
eq_t "T5 no opencode key pins nothing"             ""                   "$(opencode_profile_model claude-only sonnet)"
eq_t "T6 a non-OpenRouter map pins nothing"        ""                   "$(opencode_profile_model deepseek sonnet)"

# T7: the call site, read off the import function (it needs a root box to run).
body=$(awk '/^cmd_pack_import\(\)|^_pack_import\(\)|^cmd_agent_import\(\)/{f=1} f' src/cmd_pack.sh)
[[ -n "$body" ]] || body=$(cat src/cmd_pack.sh)
create_at=$(grep -n 'create step failed while importing' <<<"$body" | head -1 | cut -d: -f1)
pin_at=$(grep -n 'opencode_apply_model_default "\$as" openrouter "\$_oc_model"' <<<"$body" | head -1 | cut -d: -f1)
guard=$(grep -n '\[\[ "\$type" == "opencode" \]\] && (( ! byo ))' <<<"$body" | head -1 | cut -d: -f1)
if [[ -n "$pin_at" && -n "$guard" && -n "$create_at" ]] && (( create_at < guard && guard < pin_at )); then
  ok_t "T7 the import pins an opencode non-BYO seat after create"
else
  bad_t "T7 the import pins an opencode non-BYO seat after create" "create=$create_at guard=$guard pin=$pin_at"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
