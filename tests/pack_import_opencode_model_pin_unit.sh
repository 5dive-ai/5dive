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
#
# DIVE-5620 — the pin was written and never read. profile.d exports
# XDG_CONFIG_HOME=/home/claude/.config into every seat's login shell, so OpenCode
# looked for its config there, not in the seat's ~/.config/opencode, and ran its
# own default (Gemini image preview on slate-clover). T1-T7 graded the writer only.
#   T8     the start script drops XDG_CONFIG_HOME for an opencode seat, and only there.
#   T9     the real opencode binary (SKIP when absent): the pin is invisible under
#          the box's XDG redirect and resolves once the start script's unset runs.
#   T10    agent create pins a non-BYO opencode seat too (the sysadmin install's path).
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

# T8: run the start script's own type case, then its unset, under the box's export.
cases=$(awk '/^STAGE_GUARD=""$/{f=1} f{print} f&&/^esac$/{exit}' 5dive-agent-start)
after_unset() { # <type> -> XDG_CONFIG_HOME as the seat's process sees it
  ( TYPE="$1"; eval "$cases"
    XDG_CONFIG_HOME=/home/claude/.config bash -c "unset CLAUDE_CONFIG_DIR ${UNSET_CREDS}; printf %s \"\${XDG_CONFIG_HOME-UNSET}\"" )
}
eq_t "T8a opencode seat: XDG_CONFIG_HOME dropped"   "UNSET"                "$(after_unset opencode)"
eq_t "T8b codex seat keeps the shared config home"  "/home/claude/.config" "$(after_unset codex)"
eq_t "T8c claude seat keeps the shared config home" "/home/claude/.config" "$(after_unset claude)"
if grep -q 'INNER="unset CLAUDE_CONFIG_DIR ${UNSET_CREDS}; ' 5dive-agent-start; then
  ok_t "T8d the launch line applies UNSET_CREDS"
else
  bad_t "T8d the launch line applies UNSET_CREDS" "INNER no longer starts with the unset"
fi

# T9: what OpenCode itself resolves. Offline: `debug config` reads files only.
OC="${OPENCODE_BIN:-/home/claude/.opencode/bin/opencode}"
if [[ -x "$OC" ]]; then
  H="$TMP/seat"; mkdir -p "$H/.config/opencode" "$H/shared" "$H/work"
  printf '{"model":"openrouter/vendor/sonnet-tier"}\n' > "$H/.config/opencode/opencode.json"
  oc_model() { (cd "$H/work" && env -u XDG_CONFIG_HOME HOME="$H" "$@" timeout 60 "$OC" debug config 2>/dev/null \
    | jq -r '.model // "NONE"' 2>/dev/null); }
  eq_t "T9a box redirect: the seat's pin is not read" "NONE" "$(oc_model XDG_CONFIG_HOME="$H/shared")"
  eq_t "T9b after the unset: the pin is the model"    "openrouter/vendor/sonnet-tier" "$(oc_model)"
else
  printf 'SKIP - T9 no opencode binary at %s\n' "$OC"
fi

# T10: the create path pins as well, after the seat's user exists.
cbody=$(cat src/cmd_agent_create.sh)
user_at=$(grep -n 'step "Creating user agent-\${name}"' <<<"$cbody" | head -1 | cut -d: -f1)
cguard=$(grep -n '\[\[ "\$type" == "opencode" && -z "\$byo_provider" && -n "\$profile" \]\]' <<<"$cbody" | head -1 | cut -d: -f1)
cpin=$(grep -n 'opencode_apply_model_default "\$name" openrouter "\$_oc_acct_model"' <<<"$cbody" | head -1 | cut -d: -f1)
cres=$(grep -n '_oc_acct_model=$(opencode_profile_model "\$profile" "\$byo_model")' <<<"$cbody" | head -1 | cut -d: -f1)
if [[ -n "$user_at" && -n "$cguard" && -n "$cres" && -n "$cpin" ]] && (( user_at < cguard && cguard < cres && cres < cpin )); then
  ok_t "T10 agent create pins a non-BYO opencode seat to the account's model"
else
  bad_t "T10 agent create pins a non-BYO opencode seat to the account's model" "user=$user_at guard=$cguard resolve=$cres pin=$cpin"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
