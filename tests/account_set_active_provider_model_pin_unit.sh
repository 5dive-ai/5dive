#!/usr/bin/env bash
# DIVE-2666: cmd_account_set_active_provider indexed HERMES_PROVIDER_MODEL
# (canonical-keyed) with the NATIVE hermes provider id straight out of
# auth.json's credential_pool, so the lookup missed silently for every
# provider HERMES_PROVIDER_ID renames (google->gemini, moonshot->kimi,
# qwen->alibaba) and model.default was left on whatever the PREVIOUS
# provider had. The defect's whole character is silence -- it fails by
# doing nothing, with no warn -- so this harness exists to make a future
# regression loud instead of unnoticed.
#
# Fixed by resolve_canonical_provider_hermes() (src/header.sh), which
# reverses HERMES_PROVIDER_ID by scan so the two tables can't drift, plus
# canonicalizing $provider before the HERMES_PROVIDER_MODEL index in
# cmd_account.sh, warning on a genuine key-space miss instead.
#
# NOT covered by the fix, and asserted explicitly below so silence here
# doesn't read as "still broken": qwen. HERMES_PROVIDER_MODEL has no
# [qwen] entry at all -- a missing table row, not a key-space mismatch --
# so alibaba correctly canonicalizes to "qwen" and STILL resolves empty,
# same "no pin -> leave the agent's own default alone" design as
# nous/minimax/zai/huggingface. See community/wiki/where-a-model-id-gets-
# written.md, DIVE-2666 addendum, for the full scope correction.

set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_account.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || { echo "source FAIL: $f"; exit 7; }
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- the repro: the exact expression the old code ran ----------------------
# Pre-fix, cmd_account_set_active_provider did
#   local model="${HERMES_PROVIDER_MODEL[$provider]:-}"
# with $provider NATIVE. That raw native-keyed lookup being empty for the
# renamed providers IS the bug DIVE-2666's title describes.
old_gemini="${HERMES_PROVIDER_MODEL[gemini]:-}"
[[ -z "$old_gemini" ]] \
  && ok_t "repro: raw native-keyed lookup for gemini is empty (the bug)" \
  || bad_t "repro: expected empty, HERMES_PROVIDER_MODEL[gemini] not empty" "$old_gemini"
old_kimi="${HERMES_PROVIDER_MODEL[kimi]:-}"
[[ -z "$old_kimi" ]] \
  && ok_t "repro: raw native-keyed lookup for kimi is empty (the bug)" \
  || bad_t "repro: expected empty, HERMES_PROVIDER_MODEL[kimi] not empty" "$old_kimi"

# --- the fix: canonicalize, then index --------------------------------------
assert_pin() {
  local native="$1" want_canonical="$2" want_model="$3" label="$4"
  local canonical new_lookup
  canonical="$(resolve_canonical_provider_hermes "$native")"
  new_lookup="${HERMES_PROVIDER_MODEL[${canonical:-$native}]:-}"

  [[ "$canonical" == "$want_canonical" ]] \
    && ok_t "$label: native '$native' canonicalizes to '$want_canonical'" \
    || bad_t "$label: canonical mismatch" "got '$canonical', want '$want_canonical'"

  [[ "$new_lookup" == "$want_model" && -n "$new_lookup" ]] \
    && ok_t "$label: post-fix model.default resolves to '$want_model'" \
    || bad_t "$label: post-fix lookup wrong" "got '$new_lookup', want '$want_model'"
}
assert_pin gemini google "${HERMES_PROVIDER_MODEL[google]:-}" "google/gemini"
assert_pin kimi moonshot "${HERMES_PROVIDER_MODEL[moonshot]:-}" "moonshot/kimi"

# Unrenamed providers (native id == canonical id) must be untouched.
for native in anthropic deepseek openrouter; do
  direct="${HERMES_PROVIDER_MODEL[$native]:-}"
  canonical="$(resolve_canonical_provider_hermes "$native")"
  via_fix="${HERMES_PROVIDER_MODEL[${canonical:-$native}]:-}"
  [[ "$canonical" == "$native" && "$via_fix" == "$direct" && -n "$direct" ]] \
    && ok_t "$native: unrenamed provider untouched by the fix ('$direct')" \
    || bad_t "$native: unrenamed provider regressed" "canonical='$canonical' direct='$direct' via_fix='$via_fix'"
done

# qwen/alibaba: canonicalization now works (the other half of the original
# bug report), but the model-pin table simply has no [qwen] row. Both
# halves asserted so this can't silently start "passing" for the wrong
# reason if someone later adds a [qwen] entry without re-reading the row.
qwen_canonical="$(resolve_canonical_provider_hermes alibaba)"
[[ "$qwen_canonical" == "qwen" ]] \
  && ok_t "alibaba: native id now canonicalizes to 'qwen' (key-space bug fixed)" \
  || bad_t "alibaba: canonicalization broken" "got '$qwen_canonical'"
qwen_model="${HERMES_PROVIDER_MODEL[qwen]:-}"
[[ -z "$qwen_model" ]] \
  && ok_t "qwen: HERMES_PROVIDER_MODEL has no entry -- missing-pin gap, NOT fixed by DIVE-2666, by design" \
  || bad_t "qwen: unexpectedly has a model pin now -- update this assertion and the wiki row" "$qwen_model"

# Unknown native id must resolve to no canonical -- that emptiness is what
# drives the warn branch in cmd_account_set_active_provider, instead of a
# silent fall-through to the (possibly wrong-key-space) raw id.
bogus_canonical="$(resolve_canonical_provider_hermes bogus-provider-id)"
[[ -z "$bogus_canonical" ]] \
  && ok_t "unknown native id resolves to no canonical (drives the warn branch)" \
  || bad_t "unknown native id unexpectedly resolved" "$bogus_canonical"

# --- structural: the real call site is actually wired this way -------------
fn=$(declare -f cmd_account_set_active_provider)
grep -q 'resolve_canonical_provider_hermes "\$provider"' <<<"$fn" \
  && ok_t "cmd_account_set_active_provider canonicalizes \$provider before the model lookup" \
  || bad_t "cmd_account_set_active_provider does not call resolve_canonical_provider_hermes" "$fn"
grep -q 'HERMES_PROVIDER_MODEL\[\$canonical_provider\]' <<<"$fn" \
  && ok_t "cmd_account_set_active_provider indexes HERMES_PROVIDER_MODEL with the canonical id" \
  || bad_t "cmd_account_set_active_provider still indexes with the raw native id" "$fn"
grep -q 'warn "no canonical id maps to hermes native provider' <<<"$fn" \
  && ok_t "cmd_account_set_active_provider warns on a canonicalization miss" \
  || bad_t "cmd_account_set_active_provider missing the warn-on-miss branch" "$fn"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
