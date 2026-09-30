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
#   - an UNREADABLE credential is `unknown`, never an alarm;
#   - a codex seat is graded from the auth.json it RUNS on ($HOME/.codex), not
#     from the profile file 5dive-agent-start seeded it from once.
# Pure, no root, no network:
#   bash tests/agent_list_auth_health_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/agent-list-auth-health-unit.XXXXXX)"

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
# Seat homes too: a codex seat's live credential is read under
# $AGENT_HOME_ROOT/agent-<name>, and /home is the real box.
AGENT_HOME_ROOT="$TMP/home-root"

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

# (g2) configuration is not authentication. This is the DIVE-4032 false green:
#      ANTHROPIC_BASE_URL alone cannot authenticate a request.
mk "$AUTH_PROFILES_DIR/baseonly/combined.env" 'ANTHROPIC_BASE_URL=https://example.invalid'
mkdir -p "$AUTH_PROFILES_DIR/baseonly/claude"

# (g3) Keep the third credential spelling accepted by the launcher as a
#      positive control: the fix rejects non-credentials, not profile envs.
mk "$AUTH_PROFILES_DIR/authtok/combined.env" 'ANTHROPIC_AUTH_TOKEN=real-credential-shape'
mkdir -p "$AUTH_PROFILES_DIR/authtok/claude"

# (h) UNREADABLE: credential file exists but neither it nor its parent can be
#     read. Must be `unknown` — absence of evidence, not evidence of absence.
mk "$AUTH_PROFILES_DIR/opaque/grok/.grok/auth.json" '{"access_token":"t"}'
chmod 0000 "$AUTH_PROFILES_DIR/opaque/grok/.grok"

# (i) codex SEAT vs its profile SEED. 5dive-agent-start copies the profile's
#     auth.json into $HOME/.codex once and the seat rotates its own tokens from
#     then on, so the seed only ages. Measured shape: seed last refreshed months
#     ago, seat signed in yesterday. Both carry a refresh token, so only the
#     expiry tells them apart — which is what `agent info` prints.
jwt_fut=$(printf '{"exp":%s}' "$future" | base64 -w0 | tr '+/' '-_' | tr -d '=')
mk "$AUTH_PROFILES_DIR/codexseat/codex/auth.json" \
   "{\"tokens\":{\"id_token\":\"hdr.${jwt_pay}.sig\",\"refresh_token\":\"rt\"},\"last_refresh\":\"2026-05-26T19:55:39Z\"}"
mk "$AGENT_HOME_ROOT/agent-fresh/.codex/auth.json" \
   "{\"tokens\":{\"id_token\":\"hdr.${jwt_fut}.sig\",\"refresh_token\":\"rt2\"},\"last_refresh\":\"2026-09-29T11:04:23Z\"}"
# (j) the other direction: the seed still looks renewable, the seat's own file
#     has lapsed with no refresh token. The seat is the one that has to sign in.
mk "$AGENT_HOME_ROOT/agent-lapsed/.codex/auth.json" \
   "{\"tokens\":{\"id_token\":\"hdr.${jwt_pay}.sig\"}}"
# (k) a seat with NO file yet (first boot) has only the seed to go on.
mkdir -p "$AGENT_HOME_ROOT/agent-firstboot"

# --- assertions -----------------------------------------------------------
check "absent credential -> needs_login"                "$(state grok dead)"    needs_login
check "expired, unrenewable -> expired"                 "$(state grok lapsed)"  expired
check "expiry in the future -> ok"                      "$(state grok fresh)"   ok
check "expired JWT + refresh_token -> ok"               "$(state codex codexp)" ok
check "expired JWT, no refresh_token -> expired"        "$(state codex codexd)" expired
check "claude profile env-token, no creds file -> ok"   "$(state claude envtok)" ok
check "claude profile with empty env -> needs_login"    "$(state claude blank)" needs_login
check "claude config-only env -> needs_login (not false ok)" \
  "$(state claude baseonly)" needs_login
check "claude ANTHROPIC_AUTH_TOKEN -> ok"               "$(state claude authtok)" ok
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

# --- codex: the seat's live file wins over the seed -----------------------
# `sudo` is stubbed off for these arms: the fixtures are plain-readable, and a
# harness that escalated on a missing fixture would grade the box's sudoers.
seat() { ( sudo() { return 1; }; agent_auth_health "$@" ); }
check "codex seat: the seat's fresh expiry wins over a stale seed" \
  "$(seat codex codexseat fresh | cut -d'|' -f2)" "$future"
check "codex seat: fresh seat file -> ok, refreshable" \
  "$(seat codex codexseat fresh)" "ok|${future}|true"
check "codex seat: lapsed seat file -> expired, though the seed is renewable" \
  "$(seat codex codexseat lapsed | cut -d'|' -f1)" expired
check "codex seat with no file yet -> graded from the seed, unchanged" \
  "$(seat codex codexseat firstboot)" "$(seat codex codexseat)"
check "no name -> the seed, as before (callers that pass none are untouched)" \
  "$(seat codex codexseat | cut -d'|' -f2)" "$past"

# MUTANT: the seed-only read (the 3rd argument ignored) must go red on the arm
# above. The sed is checked to have bitten, or this arm would grade nothing.
_mut=$(declare -f agent_auth_health | sed 's/name="\${3:-}"/name=""/')
if [[ "$_mut" == "$(declare -f agent_auth_health)" ]]; then
  echo "FAIL: MUTANT did not apply (agent_auth_health no longer binds name=\"\${3:-}\")"; fail=1
else
  _mut_exp=$( ( eval "$_mut"; sudo() { return 1; }; agent_auth_health codex codexseat fresh ) | cut -d'|' -f2)
  if [[ "$_mut_exp" != "$future" ]]; then
    echo "ok: MUTANT seed-only read goes red (reports expiry $_mut_exp, not the seat's $future)"
  else
    echo "FAIL: MUTANT seed-only read still reports the seat's expiry — the arm cannot tell them apart"; fail=1
  fi
fi

# The path read above is the path the seat runs on: 5dive-agent-start points
# CODEX_HOME at $HOME/.codex. Read off the shipped launcher, not restated.
if grep -qF 'AGENT_CODEX_HOME="$HOME/.codex"' 5dive-agent-start \
   && grep -qF 'export CODEX_HOME=$(printf %q "$AGENT_CODEX_HOME")' 5dive-agent-start; then
  echo "ok: 5dive-agent-start runs codex on \$HOME/.codex (the file graded above)"
else
  echo "FAIL: 5dive-agent-start no longer exports CODEX_HOME=\$HOME/.codex — the seat path above is stale"; fail=1
fi

# LIVE BOX (reads, never writes): a registered codex seat's home as the passwd
# database has it, and the expiry this function reports for that seat must be
# the one in the file under that home. Skipped where the box has no codex seat
# or its credential is unreadable (CI).
# live_codex_probe <registry> -> "skip:<why>" | "grade:<name>|<home>|<want>|<got>"
live_codex_probe() {
  local reg="$1" n h blob prof want got
  [[ -r "$reg" ]] && command -v jq >/dev/null 2>&1 || { echo "skip:no readable registry at $reg"; return; }
  n=$(jq -r '.agents|to_entries[]|select(.value.type=="codex")|.key' "$reg" 2>/dev/null | head -1)
  [[ -n "$n" ]] || { echo "skip:no codex seat in $reg"; return; }
  h=$(getent passwd "agent-${n}" 2>/dev/null | cut -d: -f6)
  [[ -n "$h" ]] || { echo "skip:no passwd entry for agent-${n}"; return; }
  blob=$(cat "$h/.codex/auth.json" 2>/dev/null || sudo -n cat "$h/.codex/auth.json" 2>/dev/null || true)
  [[ -n "$blob" ]] || { echo "skip:$h/.codex/auth.json is unreadable here"; return; }
  prof=$(jq -r --arg n "$n" '.agents[$n].authProfile // ""' "$reg")
  want=$(_cred_expiry_epoch "$blob" 2>/dev/null || true)
  got=$( ( unset AGENT_HOME_ROOT; AUTH_PROFILES_DIR=/var/lib/5dive/auth-profiles
           agent_auth_health codex "$prof" "$n" ) | cut -d'|' -f2)
  echo "grade:${n}|${h}|${want:--}|${got}"
}
_lv=$(live_codex_probe /var/lib/5dive/agents.json)
case "$_lv" in
  skip:*) echo "skip: live codex seat arm (${_lv#skip:})" ;;
  grade:*)
    IFS='|' read -r _lv_name _lv_home _lv_want _lv_got <<<"${_lv#grade:}"
    check "LIVE: codex seat '$_lv_name' is graded from $_lv_home/.codex/auth.json" \
      "$_lv_got" "$_lv_want" ;;
esac
# CONTROL: on a pristine runner (no registry) the live arm skips, never fails.
check "CONTROL: no registry -> the live arm skips" \
  "$(live_codex_probe "$TMP/absent/agents.json" | cut -d: -f1)" skip

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

echo
printf 'agent_list_auth_health_unit: %s\n' "$( (( fail == 0 )) && echo PASSED || echo FAILED )"
# The verdict expression is `(( fail == 0 ))`, not `if (( fail ))` + `exit 1`:
# tests/meta/harness-verdict-probe.sh identifies the verdict VARIABLE from this
# line so it can bump it and confirm the harness actually goes red. A literal
# `exit 1` names no variable, so the probe reports UNPROBEABLE — which is not a
# pass, and correctly so: an unmutatable harness is one nobody has shown can fail.
(( fail == 0 ))
