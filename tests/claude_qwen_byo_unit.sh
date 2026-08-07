#!/usr/bin/env bash
# DIVE-2756: the fifth claude BYO tile — Qwen / Alibaba Token Plan. The tile was
# blocked for two days on "no key to smoke with"; a live Token Plan key then made
# the endpoint + model ids VERIFIED (200 with a real completion, plus hours of real
# agent turns), so this harness pins the catalog values and the full
# _apply_byo_claude write path against them. No root, network, credentials, users,
# or runtime state are touched.
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
cd "$(dirname "$0")/.."
SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || { echo "source FAIL: $f"; exit 7; }
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# 1. The four catalog maps all carry qwen, pinned at the values verified live
#    2026-08-07 with a real Token Plan key.
[[ "${CLAUDE_PROVIDER_BASEURL[qwen]:-}" == "https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic" ]] \
  && ok_t "CLAUDE_PROVIDER_BASEURL[qwen] = smoked token-plan endpoint" \
  || bad_t "qwen base url wrong/missing" "got: '${CLAUDE_PROVIDER_BASEURL[qwen]:-}'"
[[ "${CLAUDE_PROVIDER_OPUS_MODEL[qwen]:-}" == "qwen3.8-max" ]] \
  && ok_t "CLAUDE_PROVIDER_OPUS_MODEL[qwen] = qwen3.8-max" \
  || bad_t "qwen opus model wrong/missing" "got: '${CLAUDE_PROVIDER_OPUS_MODEL[qwen]:-}'"
[[ "${CLAUDE_PROVIDER_SONNET_MODEL[qwen]:-}" == "qwen3.8-max" ]] \
  && ok_t "CLAUDE_PROVIDER_SONNET_MODEL[qwen] = qwen3.8-max" \
  || bad_t "qwen sonnet model wrong/missing" "got: '${CLAUDE_PROVIDER_SONNET_MODEL[qwen]:-}'"
[[ "${CLAUDE_PROVIDER_HAIKU_MODEL[qwen]:-}" == "qwen3.6-flash" ]] \
  && ok_t "CLAUDE_PROVIDER_HAIKU_MODEL[qwen] = qwen3.6-flash" \
  || bad_t "qwen haiku model wrong/missing" "got: '${CLAUDE_PROVIDER_HAIKU_MODEL[qwen]:-}'"

# 2. The endpoint is https:// — the DIVE-2757 invariant for any URL that carries
#    an API key on every request.
[[ "${CLAUDE_PROVIDER_BASEURL[qwen]:-}" == https://* ]] \
  && ok_t "qwen endpoint is https://" \
  || bad_t "qwen endpoint is not https" "got: '${CLAUDE_PROVIDER_BASEURL[qwen]:-}'"

# 3. The wiring that was MISSING before this change: qwen passes the BYO label
#    gate AND resolves as a native claude provider. Without the catalog rows,
#    resolve_native_provider returned empty and `auth set claude --provider=qwen`
#    failed with "claude does not support provider 'qwen'".
valid_byo_provider qwen \
  && ok_t "valid_byo_provider qwen passes" \
  || bad_t "qwen missing from BYO_PROVIDER_LABEL"
[[ "$(resolve_native_provider claude qwen)" == "qwen" ]] \
  && ok_t "resolve_native_provider claude qwen -> qwen" \
  || bad_t "claude does not resolve qwen natively" "got: '$(resolve_native_provider claude qwen)'"

# 4. Behavioral: _apply_byo_claude writes the exact env shape the live smoke
#    proved. Stub the writer (as byo_model_create_unit.sh does) and read back.
capture=$(mktemp)
trap 'rm -f "$capture"' EXIT
step() { :; }
profile_set_var() {
  local profile="$1" var="$2" value
  value=$(cat)
  printf '%s %s=%s\n' "$profile" "$var" "$value" >>"$capture"
}
_apply_byo_claude qwen sk-sp-test-123456 qa-qwen ""
for want in \
  "qa-qwen ANTHROPIC_BASE_URL=https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic" \
  "qa-qwen ANTHROPIC_AUTH_TOKEN=sk-sp-test-123456" \
  "qa-qwen ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8-max" \
  "qa-qwen ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3.8-max" \
  "qa-qwen ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.6-flash" \
  "qa-qwen API_TIMEOUT_MS=3000000" \
  "qa-qwen CLAUDE_CODE_OAUTH_TOKEN=" \
  "qa-qwen ANTHROPIC_API_KEY=" \
; do
  grep -qxF "$want" "$capture" \
    && ok_t "_apply_byo_claude writes: $want" \
    || bad_t "_apply_byo_claude did not write" "$want"
done
# The empty ANTHROPIC_API_KEY is load-bearing: a NON-empty value makes the claude
# harness treat the profile as a custom-API-key login and block headless on a
# yes/no prompt (measured live 2026-08-07 — the agent goes silent). Guard the
# emptiness explicitly, not just the line's presence.
grep -qxF "qa-qwen ANTHROPIC_API_KEY=" "$capture" && ! grep -qE "^qa-qwen ANTHROPIC_API_KEY=.+" "$capture" \
  && ok_t "ANTHROPIC_API_KEY is written EMPTY (Bearer-token shape)" \
  || bad_t "ANTHROPIC_API_KEY must be empty for the token-plan shape" "$(grep ANTHROPIC_API_KEY "$capture")"

# 5. The init wizard offers the tile in the claude custom-provider picker.
grep -q '"qwen|Qwen|' "$SRC/cmd_init.sh" \
  && ok_t "cmd_init.sh claude custom picker offers qwen" \
  || bad_t "init wizard does not offer qwen for claude"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
