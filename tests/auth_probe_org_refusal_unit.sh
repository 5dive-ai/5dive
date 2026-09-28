#!/usr/bin/env bash
# DIVE-5098 #3 unit: `agent auth status --probe` (and doctor's `auth/claude`)
# must read a 403 ORG REFUSAL as stale, not ok.
#
# The defect (luca's 2026-09-28 report, measured on teal-fox): a login whose org
# had turned off Claude Code subscription access made `claude --print ping`
# print "Your organization has disabled Claude subscription access for Claude
# Code" (API: 403 permission_error, transcripts: oauth_org_not_allowed), and
# the stale matcher in auth_probe_one knew only the 401 family — so the probe
# said `claude: ok` for 13 seats that failed every turn.
#
# Second half: the probe ran with a stdin attached, and `claude --print` spent
# ~3 of its 5s waiting on it; a probe that times out prints nothing, which the
# matcher reads as ok. auth_probe_output now runs the probe with </dev/null.
#
# Both directions, because a matcher that says "stale" to everything would pass
# the refusal arms: a normal reply and a rate-limit reply must stay ok (the
# comment on auth_probe_one: throttled is not stale, by design).
# Pure, no root, no network:
#   bash tests/auth_probe_org_refusal_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ "$BASHPID" == "$$" ]] || exit "$rc"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh cmd_auth.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- the matcher: auth_probe_output stubbed to replay a captured reply -------
PROBE_OUT=""
auth_probe_output() { printf '%s\n' "$PROBE_OUT"; }
verdict() { PROBE_OUT="$1"; auth_probe_one claude; echo $?; }

# stale (rc 1)
declare -A STALE=(
  [org_text]='Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access'
  [api_403]='API Error: 403 {"type":"error","error":{"type":"permission_error","message":"OAuth authentication is currently not allowed for this organization."}}'
  [code_org_not_allowed]='{"error":{"code":"oauth_org_not_allowed"}}'
  [code_not_allowed_for_org]='{"error":{"code":"oauth_not_allowed_for_organization"}}'
  [not_logged_in]='Not logged in · Please run /login'
  [api_401]='API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'
)
for k in "${!STALE[@]}"; do
  v=$(verdict "${STALE[$k]}")
  [[ "$v" == 1 ]] && ok "stale: $k" || bad "stale: $k (got rc $v)" "${STALE[$k]}"
done

# ok (rc 0) — the controls
declare -A OKAY=(
  [pong]='Pong!'
  [rate_limit]='API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your rate limit"}}'
  [usage_limit]='Claude usage limit reached. Your limit will reset at 5pm.'
  [number_4030]='ping took 4030ms'
)
for k in "${!OKAY[@]}"; do
  v=$(verdict "${OKAY[$k]}")
  [[ "$v" == 0 ]] && ok "ok: $k" || bad "ok: $k (got rc $v)" "${OKAY[$k]}"
done
unset -f auth_probe_output

# --- stdin: the probe must not be handed the caller's stdin ------------------
# Re-source the real auth_probe_output; `sudo -u claude -i` is stubbed to drop
# its own flags and run the rest as us (no root needed). The probe command
# reports whether a line was waiting on its stdin.
# shellcheck source=/dev/null
source "$SRC/cmd_auth.sh"
sudo() { while [[ "$1" == -* ]]; do [[ "$1" == -u ]] && shift; shift; done; "$@"; }
probe='if IFS= read -r -t 1 line; then echo "STDIN:$line"; else echo NO-STDIN; fi'
got=$(printf 'caller-stdin\n' | auth_probe_output claude "" 5 "$probe")
[[ "$got" == *NO-STDIN* && "$got" != *caller-stdin* ]] \
  && ok "the probe runs with </dev/null (the caller's stdin never reaches it)" \
  || bad "the probe runs with </dev/null (the caller's stdin never reaches it)" "$got"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
