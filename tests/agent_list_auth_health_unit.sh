#!/usr/bin/env bash
# DIVE-1953 unit: `agent list` reports CREDENTIAL health, so a seat whose auth
# has lapsed stops rendering identically to a live one.
#
# The defect (DIVE-1869 item 3, found on the flagship demo box): a grok seat's
# credential expired, the systemd unit stayed `active`, and `agent list` kept
# showing it live — the only signal was a line in the runtime's own log. A
# council convene then dispatched a ballot to that dead seat and recorded a
# normal-looking abstain. DIVE-1803 is the same shape.
#
# What is graded here is the honesty of the badge in BOTH directions, because a
# column that cries wolf gets ignored and a column that never fires is
# decoration:
#   - it FIRES on a provably-absent credential and on an expired-and-
#     unrenewable one;
#   - it does NOT fire on a claude agent authenticated by its profile
#     env-token (no .credentials.json is ever written — the shape that false-
#     flagged every healthy claude agent on the control plane in iteration 1);
#   - it does NOT fire on a short-lived token that carries a refresh token
#     (codex/claude renew themselves; "expiresAt is past" is their normal
#     steady state);
#   - an UNREADABLE credential is `unknown`, never an alarm.
# Pure, no root, no network:
#   bash tests/agent_list_auth_health_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/agent-list-auth-health-unit.XXXXXX)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

# Point every credential store at the throwaway tmp BEFORE sourcing the unit,
# and re-point the shared connectors dir too: the api-key fallback inside
# auth_creds_present reads CONNECTORS_DIR for default-profile agents, and a
# harness that left it aimed at /etc/5dive would grade the host's real keys.
AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
mkdir -p "$CONNECTORS_DIR"

# Minimal type tables. `grok` gets a sentinel (the ticket's type), `opencode`
# is deliberately absent from TYPE_AUTH — that is how a type declares itself
# auth-optional, and it must read `ok`, not `needs_login`.
declare -A TYPE_AUTH=(
  [claude]="$TMP/connectors/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN"
  [codex]="$TMP/home/claude/.codex/auth.json"
  [grok]="$TMP/home/claude/.grok/auth.json"
)
declare -A TYPE_API_FILE=([codex]="openai.env" [grok]="xai.env")
is_known_type() { case "$1" in claude|codex|grok|opencode) return 0;; *) return 1;; esac; }

# shellcheck source=/dev/null
source "$SRC/cmd_auth.sh"

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }
state() { agent_auth_health "$1" "${2:-}" | cut -d'|' -f1; }

now=$(date +%s)
past=$(( now - 3600 ))
future=$(( now + 86400 ))

# --- fixtures -------------------------------------------------------------
mk() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

# (a) grok, credential provably ABSENT: the profile dir exists and is readable,
#     the auth.json is not there. This is the DIVE-1803 shape.
mkdir -p "$AUTH_PROFILES_DIR/dead/grok/.grok"

# (b) grok, EXPIRED with no refresh token — the ticket's case. An x.ai-shaped
#     credential carrying an epoch-seconds expiry that has passed.
mk "$AUTH_PROFILES_DIR/lapsed/grok/.grok/auth.json" \
   "{\"access_token\":\"xai-tok\",\"expires_at\":$past}"

# (c) grok, expiry in the FUTURE -> ok.
mk "$AUTH_PROFILES_DIR/fresh/grok/.grok/auth.json" \
   "{\"access_token\":\"xai-tok\",\"expires_at\":$future}"

# (d) codex, id_token JWT whose `exp` is long past, WITH a refresh token. codex
#     renews this itself, so the honest answer is ok. Payload is base64url with
#     the padding stripped, exactly as a real JWT arrives.
jwt_pay=$(printf '{"exp":%s}' "$past" | base64 -w0 | tr '+/' '-_' | tr -d '=')
mk "$AUTH_PROFILES_DIR/codexp/codex/auth.json" \
   "{\"tokens\":{\"id_token\":\"hdr.${jwt_pay}.sig\",\"refresh_token\":\"rt\"},\"last_refresh\":\"2026-07-14T03:03:20Z\"}"

# (e) SAME expired JWT, refresh token REMOVED. The only difference between (d)
#     and (e) is renewability, so this pair is what proves the badge keys on
#     renewability rather than on expiry alone.
mk "$AUTH_PROFILES_DIR/codexd/codex/auth.json" \
   "{\"tokens\":{\"id_token\":\"hdr.${jwt_pay}.sig\"}}"

# (f) claude on a profile: authenticated by the profile's combined.env token and
#     NO .credentials.json, ever. Iteration 1 marked this needs_login.
mk "$AUTH_PROFILES_DIR/envtok/combined.env" 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-xxx'
mkdir -p "$AUTH_PROFILES_DIR/envtok/claude"

# (g) claude on a profile with an EMPTY combined.env and no credentials file.
mk "$AUTH_PROFILES_DIR/blank/combined.env" ''
mkdir -p "$AUTH_PROFILES_DIR/blank/claude"

# (h) UNREADABLE: credential file exists but neither it nor its parent can be
#     read. Must be `unknown` — absence of evidence, not evidence of absence.
mk "$AUTH_PROFILES_DIR/opaque/grok/.grok/auth.json" '{"access_token":"t"}'
chmod 0000 "$AUTH_PROFILES_DIR/opaque/grok/.grok"

# --- assertions -----------------------------------------------------------
check "absent credential -> needs_login"                "$(state grok dead)"    needs_login
check "expired, unrenewable -> expired"                 "$(state grok lapsed)"  expired
check "expiry in the future -> ok"                      "$(state grok fresh)"   ok
check "expired JWT + refresh_token -> ok"               "$(state codex codexp)" ok
check "expired JWT, no refresh_token -> expired"        "$(state codex codexd)" expired
check "claude profile env-token, no creds file -> ok"   "$(state claude envtok)" ok
check "claude profile with empty env -> needs_login"    "$(state claude blank)" needs_login
check "auth-optional type (no sentinel) -> ok"          "$(state opencode '')"  ok

# `unknown` is only meaningful when the process cannot already read everything.
# root ignores the 0000 mode, so the assertion would pass for the wrong reason —
# skip it rather than let a root run silently grade nothing (a skip here is a
# statement about the ENVIRONMENT; a wrong verdict would be a statement about
# the code).
if [[ "$(id -u)" == "0" ]]; then
  echo "skip: unreadable credential -> unknown (running as root; 0000 mode does not apply)"
else
  check "unreadable credential -> unknown"              "$(state grok opaque)"  unknown
fi

# The expiry timestamp itself must survive to the caller — it is what turns
# "expired" into "expired at 09:14, re-mint it" for whoever reads the row.
check "expired row carries its epoch" \
  "$(agent_auth_health grok lapsed | cut -d'|' -f2)" "$past"
check "renewable row reports refreshable=true" \
  "$(agent_auth_health codex codexp | cut -d'|' -f3)" "true"

# --- non-vacuity ----------------------------------------------------------
# Every assertion above is a claim about a function that must EXIST. If a future
# refactor renames it, `state` would return the empty string and several checks
# would fail loudly, but the two `ok` expectations would not distinguish "absent
# function" from "healthy credential". Prove the instrument is wired.
if declare -F agent_auth_health >/dev/null; then
  echo "ok: agent_auth_health is defined (assertions above were reachable)"
else
  echo "FAIL: agent_auth_health is NOT defined — every check above graded nothing"; fail=1
fi

if (( fail )); then echo "FAILED"; exit 1; fi
echo "PASSED"
