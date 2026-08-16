#!/usr/bin/env bash
# DIVE-3113: the two defects DIVE-3112 diagnosed on the openclaw BYO create path.
#
#   1. ORDERING. _apply_byo_openclaw wrote the credential, THEN hit a runtime
#      guard and aborted — leaving a profile holding a key with no model pin,
#      which `agent list` reports as AUTH ok. Graded structurally here: the
#      precondition must appear BEFORE the auth-profiles.json write in the
#      function body, because that ordering IS the fix and nothing else in the
#      function is reachable without sudo + a real binary.
#   2. PROVIDER-PREFIX MISMATCH. An openclaw model id is `<provider>/<model>` and
#      the first segment selects the provider AND the credential, so
#      `--provider=openrouter --model=openai/gpt-5.6-luna` authenticates against
#      openclaw's `openai` provider. openclaw_normalize_model is pure, so this
#      half is graded behaviourally with real calls, not by grepping the body.
#
# The expected ids below were read off the runtime's own catalog
# (openclaw 2026.7.1-2, `openclaw models list --provider <p> --plain`), which is
# the only oracle with authority over them: openrouter nests the vendor one level
# down (openrouter/moonshotai/kimi-k2.6), every other provider does not.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path.
cd "$(dirname "$0")/.."
SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_auth.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || { echo "source FAIL: $f"; exit 7; }
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ── 1. the normaliser, called for real ──────────────────────────────────────
# <native> <model> <expected-stdout> <expected-rc> <what>
norm_is() {
  local native="$1" model="$2" want="$3" want_rc="$4" what="$5" got rc
  got=$(openclaw_normalize_model "$native" "$model"); rc=$?
  if [[ "$got" == "$want" && "$rc" == "$want_rc" ]]; then
    ok_t "$what"
  else
    bad_t "$what" "openclaw_normalize_model '$native' '$model' -> '$got' rc=$rc (want '$want' rc=$want_rc)"
  fi
}

# The DIVE-3112 payload itself: an OpenRouter catalog slug under --provider=openrouter.
norm_is openrouter "openai/gpt-5.6-luna" "openrouter/openai/gpt-5.6-luna" 0 \
  "openrouter re-prefixes an OpenRouter catalog slug (the DIVE-3112 input)"
# Already-correct ids are untouched, including the nested openrouter shape.
norm_is openrouter "openrouter/auto" "openrouter/auto" 0 \
  "openrouter/auto passes through untouched"
norm_is openrouter "openrouter/moonshotai/kimi-k2.6" "openrouter/moonshotai/kimi-k2.6" 0 \
  "an already-nested openrouter id is not double-prefixed"
norm_is anthropic "anthropic/claude-sonnet-5" "anthropic/claude-sonnet-5" 0 \
  "a matching prefix passes through untouched"
# A bare model name inherits the selected provider.
norm_is anthropic "claude-sonnet-5" "anthropic/claude-sonnet-5" 0 \
  "a bare model id is prefixed with the selected provider"
norm_is openrouter "auto" "openrouter/auto" 0 \
  "a bare model id under openrouter is prefixed too"
# The genuine disagreement: refuse rather than guess.
norm_is deepseek "openai/gpt-5.6" "" 1 \
  "a foreign prefix under a non-openrouter provider is REFUSED"
norm_is openai "anthropic/claude-sonnet-5" "" 1 \
  "openai/anthropic mismatch is REFUSED"
# Empty in, empty out (the no-catalog-default case) — must not become "native/".
norm_is anthropic "" "" 0 \
  "an empty model stays empty (no bare '<provider>/' is synthesised)"

# NEGATIVE CONTROL: the refusal must be a real branch, not the function being
# broken for everything. If every call returned rc=1 the refusal asserts above
# would still pass, so prove a rejected input and an accepted one differ.
{ openclaw_normalize_model deepseek "openai/gpt-5.6" >/dev/null; rc_bad=$?; } 2>/dev/null
{ openclaw_normalize_model deepseek "deepseek/deepseek-chat" >/dev/null; rc_ok=$?; } 2>/dev/null
[[ "$rc_bad" == 1 && "$rc_ok" == 0 ]] \
  && ok_t "refusal is input-dependent (same provider: bad rc=1, good rc=0)" \
  || bad_t "refusal not input-dependent" "rc_bad=$rc_bad rc_ok=$rc_ok"

# ── 2. the ordering, graded on the parsed function body ─────────────────────
o=$(declare -f _apply_byo_openclaw)

line_of() { grep -n -- "$1" <<<"$o" | head -1 | cut -d: -f1; }

l_norm=$(line_of 'openclaw_normalize_model')
l_node=$(line_of 'node runtime missing for openclaw')
# DIVE-3489: the credential write is `models auth paste-api-key` now, not the jq
# auth-profiles.json heredoc. Anchor on the SUBCOMMAND rather than on the step
# text — the ordering property under test is unchanged, and a prose anchor is
# what made this arm red on a rename instead of on a regression.
l_key=$(line_of 'paste-api-key')

if [[ -n "$l_norm" && -n "$l_node" && -n "$l_key" ]]; then
  (( l_node < l_key )) \
    && ok_t "runtime precondition runs BEFORE the credential write (l_node=$l_node < l_key=$l_key)" \
    || bad_t "runtime guard still fires after the key is on disk" "l_node=$l_node l_key=$l_key"
  (( l_norm < l_key )) \
    && ok_t "model-prefix validation runs BEFORE the credential write (l_norm=$l_norm < l_key=$l_key)" \
    || bad_t "model normalisation happens after the key write" "l_norm=$l_norm l_key=$l_key"
else
  bad_t "could not locate the ordering anchors in _apply_byo_openclaw" \
    "l_norm=${l_norm:-?} l_node=${l_node:-?} l_key=${l_key:-?}"
fi

# The mismatch must ABORT, not warn — a warn here is what produced a 401 on a
# valid key. Assert the refusal is wired to fail with a validation code.
grep -q 'fail "\$E_VALIDATION" "openclaw model' <<<"$o" \
  && ok_t "a provider/model mismatch aborts with E_VALIDATION" \
  || bad_t "mismatch does not fail(E_VALIDATION)" "$o"

# A failed model pin must be fatal, not a warn: with the key already written, a
# warn returns success over a profile that reports AUTH ok and cannot auth.
grep -q 'openclaw model pin failed' <<<"$o" \
  && ok_t "a failed model pin aborts instead of warning" \
  || bad_t "model pin failure is still a warn" "$o"

# Regression guard for DIVE-1318/1826, which live in the block we reordered.
grep -q 'override_model:-\${OPENCLAW_PROVIDER_MODEL' <<<"$o" \
  && ok_t "DIVE-1318 --model override still wins over the catalog default" \
  || bad_t "override_model precedence lost in the reorder" "$o"
grep -q 'models.providers.\${native}.baseUrl' <<<"$o" \
  && ok_t "DIVE-1826 zai baseUrl pin survived the reorder" \
  || bad_t "baseUrl pin lost in the reorder" "$o"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
