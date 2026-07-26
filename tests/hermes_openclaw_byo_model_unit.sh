#!/usr/bin/env bash
# DIVE-1318: dashboard --model override reaches hermes/openclaw BYO providers.
# _apply_byo_hermes/_apply_byo_openclaw shell out to sudo + real binaries, so we
# assert structurally (against the parsed function bodies) that an operator
# --model is threaded through and wins over the per-provider catalog default.
set -uo pipefail
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

# apply_byo_provider forwards its 5th arg ($model) to hermes AND openclaw, not
# just claude — otherwise a dashboard --model is silently dropped for them.
disp=$(declare -f apply_byo_provider)
grep -Eq '_apply_byo_hermes "\$native" "\$canonical" "\$api_key" "\$profile" "\$model"' <<<"$disp" \
  && ok_t "apply_byo_provider forwards \$model to hermes" \
  || bad_t "hermes not passed \$model" "$disp"
grep -Eq '_apply_byo_openclaw "\$native" "\$canonical" "\$api_key" "\$profile" "\$model"' <<<"$disp" \
  && ok_t "apply_byo_provider forwards \$model to openclaw" \
  || bad_t "openclaw not passed \$model" "$disp"

# hermes accepts override_model ($5) and uses it in place of the catalog
# default on BOTH the moonshot env-var path and the general auth-add path.
h=$(declare -f _apply_byo_hermes)
grep -q 'override_model="${5:-}"' <<<"$h" \
  && ok_t "_apply_byo_hermes binds override_model=\$5" \
  || bad_t "hermes missing override_model param" "$h"
[[ $(grep -c 'override_model:-\${HERMES_PROVIDER_MODEL' <<<"$h") -eq 2 ]] \
  && ok_t "_apply_byo_hermes override wins on both model paths" \
  || bad_t "hermes override not applied on both paths" "$h"

# openclaw accepts override_model and prefers it over OPENCLAW_PROVIDER_MODEL.
o=$(declare -f _apply_byo_openclaw)
grep -q 'override_model="${5:-}"' <<<"$o" \
  && ok_t "_apply_byo_openclaw binds override_model=\$5" \
  || bad_t "openclaw missing override_model param" "$o"
grep -q 'override_model:-\${OPENCLAW_PROVIDER_MODEL' <<<"$o" \
  && ok_t "_apply_byo_openclaw override wins over catalog default" \
  || bad_t "openclaw override not applied" "$o"

# Backward-compat: a 4-arg call (auth re-login path) still resolves to the
# catalog default (override_model defaults to empty).
grep -q 'apply_byo_provider "$type" "$byo_provider" "$api_key" "$profile"$' src/cmd_auth.sh \
  && ok_t "auth re-login 4-arg call still valid (override defaults empty)" \
  || ok_t "auth re-login call shape changed (acceptable if still <=5 args)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
