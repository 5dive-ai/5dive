#!/usr/bin/env bash
# DIVE-3442: an openclaw BYO seat booted with NO credential and NO model pin.
#
# Measured on a live throwaway seat (openclaw + openrouter, --isolation=standard,
# no --auth-profile): /home/agent-<name>/.openclaw/agents/main/agent/
# auth-profiles.json DID NOT EXIST and the seat's openclaw.json carried
# primary=null, while /home/claude's copy was correct on every field. Telegram
# worked (channel/gateway config is written straight into the seat and needs no
# credential); every provider call 401'd.
#
# The seed in 5dive-agent-start is a PULL: the seat reads claude's copy at launch.
# Both its arms fail for a BYO seat — /home/claude/.openclaw is 0700 claude:claude
# so a group member cannot traverse it, and a standard-isolation seat has no
# NOPASSWD sudo for the fallback. The profile-scoped path escapes this only
# because normalize_profile_seed_perms relaxes it at bind time; the DEFAULT
# (no --auth-profile) path is never normalized, which is the shape lodar hit.
#
# The fix is a PUSH from root at create/auth-set time. This harness grades the
# push helper, its wiring, and the two silences that let the defect ship:
# selfcheck_cred_reached_agent had no witness that looks at the SEAT, and
# assert_cred_seeded's unreadable-source verdict never left a breadcrumb (the
# only channel `agent list`'s health rail reads).
#
# Pure: no root, no network, no runtime state.  bash tests/openclaw_seat_seed_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }
has()   { if grep -qF -- "$2" <<<"$1"; then echo "ok: $3"; else echo "FAIL: $3"; fail=1; fi; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3"; fail=1; else echo "ok: $3"; fi; }

TMP="$(mktemp -d /tmp/openclaw-seat-seed.XXXXXX)"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh
step() { :; }
WARNS=""
warn() { WARNS+="$*"$'\n'; }

# ---------- 1. the push helper ----------
# Shared source, as _apply_byo_openclaw leaves it.
SHARED="$TMP/shared"
mkdir -p "$SHARED/.openclaw/agents/main/agent"
printf '{"version":1,"profiles":{"openrouter:manual":{"type":"api_key","provider":"openrouter","key":"sk-or-test-1234567890"}}}\n' \
  > "$SHARED/.openclaw/agents/main/agent/auth-profiles.json"
printf '{"agents":{"defaults":{"model":{"primary":"openrouter/auto"}}},"models":{"providers":{"zai":{"baseUrl":"https://example.invalid/coding"}}}}\n' \
  > "$SHARED/.openclaw/openclaw.json"

# The seat as `agent create` leaves it just before the push: its own
# openclaw.json already holds channels + gateway token, and NO credential.
SEATS="$TMP/home"
mkdir -p "$SEATS/agent-octest/.openclaw"
printf '{"gateway":{"mode":"local","token":"gw-secret"},"channels":{"telegram":{"enabled":true}}}\n' \
  > "$SEATS/agent-octest/.openclaw/openclaw.json"

# profile="" -> the DEFAULT path, which is the measured-broken one. Point the
# helper's two roots at the fixture: AGENT_HOME_ROOT is the existing test seam,
# and the shared base is /home/claude, so run with a stubbed profile_type_dir
# only on the profiled leg below.
HOME_ROOT_SEAM_OK=0
grep -q 'AGENT_HOME_ROOT' <<<"$(declare -f seed_openclaw_state_into_seat)" && HOME_ROOT_SEAM_OK=1
check "helper honours the AGENT_HOME_ROOT test seam" "$HOME_ROOT_SEAM_OK" "1"

# Exercise the default (no-profile) path by pointing /home/claude's stand-in at
# the fixture through profile_type_dir's caller: the helper hardcodes
# /home/claude for profile="", so grade the profiled leg (identical code below
# the base resolution) plus an explicit assertion that the default base is
# /home/claude — the path the live repro used.
has "$(declare -f seed_openclaw_state_into_seat)" 'base="/home/claude"' \
    "helper defaults to the shared /home/claude base (the measured-broken path)"

profile_type_dir() { printf '%s' "$SHARED"; }
AGENT_HOME_ROOT="$SEATS" seed_openclaw_state_into_seat octest qa-profile

SEAT_AUTH="$SEATS/agent-octest/.openclaw/agents/main/agent/auth-profiles.json"
SEAT_CFG="$SEATS/agent-octest/.openclaw/openclaw.json"
check "seat now has its own auth-profiles.json" "$( [[ -s "$SEAT_AUTH" ]] && echo yes )" "yes"
check "seat credential is byte-identical to the shared one" \
      "$(cmp -s "$SEAT_AUTH" "$SHARED/.openclaw/agents/main/agent/auth-profiles.json" && echo same)" "same"
check "seat credential is 0600" "$(stat -c '%a' "$SEAT_AUTH")" "600"
check "seat model pin lands" "$(jq -r '.agents.defaults.model.primary' "$SEAT_CFG")" "openrouter/auto"
# models.providers is in the copy set on purpose: the boot seed syncs only
# agents.defaults, so a zai baseUrl override reached the shared config and never
# the seat — same failure class, one line away.
check "provider baseUrl override reaches the seat too" \
      "$(jq -r '.models.providers.zai.baseUrl' "$SEAT_CFG")" "https://example.invalid/coding"
# MERGE, not overwrite: the seat's gateway token and channels predate the push.
check "seat gateway token survives the merge" "$(jq -r '.gateway.token' "$SEAT_CFG")" "gw-secret"
check "seat channel config survives the merge" "$(jq -r '.channels.telegram.enabled' "$SEAT_CFG")" "true"

# Idempotent: a re-run (key rotation via `agent auth set`) must not corrupt it.
AGENT_HOME_ROOT="$SEATS" seed_openclaw_state_into_seat octest qa-profile
check "second push is idempotent" "$(jq -r '.gateway.token + "|" + .agents.defaults.model.primary' "$SEAT_CFG")" \
      "gw-secret|openrouter/auto"

# A seat that does not exist is a no-op, never an error.
AGENT_HOME_ROOT="$TMP/nope" seed_openclaw_state_into_seat ghost qa-profile
check "missing seat home is a silent no-op (rc 0)" "$?" "0"

# ---------- 2. wiring: create + auth set must actually call it ----------
create_src=$(cat src/cmd_agent_create.sh)
has "$create_src" 'seed_openclaw_state_into_seat "$name" "$profile"' \
    "cmd_create pushes openclaw state into the seat"
# It has to run AFTER the channel install, or the channel writer's own
# openclaw.json write lands on top of the merge.
# `|| var=` on both: under `set -o pipefail` a grep that finds nothing makes the
# whole substitution non-zero, and an unguarded one aborted this harness mid-run
# under mutation — it reported the first FAIL and then never reached RESULT.
create_line=$(grep -n 'seed_openclaw_state_into_seat "\$name"' src/cmd_agent_create.sh | head -1 | cut -d: -f1) || create_line=""
chan_line=$(grep -n 'install_channel_for_agent "\$type" telegram' src/cmd_agent_create.sh | head -1 | cut -d: -f1) || chan_line=""
if [[ -n "$create_line" && -n "$chan_line" && "$create_line" -gt "$chan_line" ]]; then
  echo "ok: the push runs after the channel install (merge lands on top)"
else
  echo "FAIL: the push must run after install_channel_for_agent (create=$create_line channel=$chan_line)"; fail=1
fi
has "$(cat src/cmd_auth.sh)" 'seed_openclaw_state_into_seat "$_agent" "$profile"' \
    "agent auth set pushes a rotated key into each bound openclaw seat"

# ---------- 3. selfcheck must grade the SEAT, not just the source ----------
# The broken seat printed a CLEAN create: on the BYO path with no profile,
# witness 2 resolves src="" and returns without a word.
AUTH_PROFILES_DIR="$TMP/profiles"; mkdir -p "$AUTH_PROFILES_DIR"
out=$(AGENT_HOME_ROOT="$TMP/broken" selfcheck_cred_reached_agent octest2 openclaw "" openrouter 2>&1)
mkdir -p "$TMP/broken/agent-octest2"
out=$(AGENT_HOME_ROOT="$TMP/broken" selfcheck_cred_reached_agent octest2 openclaw "" openrouter 2>&1)
has "$out" "issue:openclaw credential never reached the seat" \
    "selfcheck flags a seat with no credential of its own"

# Credential present, model pin null — the DIVE-3113/3130 shape: reports AUTH ok,
# 401s on every message because openclaw falls back to a built-in default whose
# provider prefix selects a credential nobody wrote.
mkdir -p "$TMP/nullmodel/agent-octest3/.openclaw/agents/main/agent"
printf '{"version":1,"profiles":{"x":{"type":"api_key"}}}\n' \
  > "$TMP/nullmodel/agent-octest3/.openclaw/agents/main/agent/auth-profiles.json"
printf '{"agents":{"defaults":{"model":{"primary":null}}},"gateway":{"mode":"local"}}\n' \
  > "$TMP/nullmodel/agent-octest3/.openclaw/openclaw.json"
out=$(AGENT_HOME_ROOT="$TMP/nullmodel" selfcheck_cred_reached_agent octest3 openclaw "" openrouter 2>&1)
has "$out" "issue:openclaw seat has a credential but NO model pin" \
    "selfcheck flags a credential with a null model pin"

# The healthy seat the fix produces must NOT alarm — a witness that always fires
# is not a witness.
out=$(AGENT_HOME_ROOT="$SEATS" selfcheck_cred_reached_agent octest openclaw "" openrouter 2>&1)
has "$out" "ok:openclaw seat has its own credential and model pin (openrouter/auto)" \
    "selfcheck passes the seat the fix produces"
hasnt "$out" "issue:openclaw" "no false alarm on a correctly seeded seat"

# A bare-string model (openclaw accepts it) must not blow up the jq probe —
# indexing a string with .primary is a jq ERROR, not a null.
mkdir -p "$TMP/strmodel/agent-octest4/.openclaw/agents/main/agent"
printf '{"version":1,"profiles":{"x":{"type":"api_key"}}}\n' \
  > "$TMP/strmodel/agent-octest4/.openclaw/agents/main/agent/auth-profiles.json"
printf '{"agents":{"defaults":{"model":"openrouter/auto"}}}\n' \
  > "$TMP/strmodel/agent-octest4/.openclaw/openclaw.json"
out=$(AGENT_HOME_ROOT="$TMP/strmodel" selfcheck_cred_reached_agent octest4 openclaw "" openrouter 2>&1)
has "$out" "ok:openclaw seat has its own credential and model pin (openrouter/auto)" \
    "string-shaped model pin is read, not mis-flagged"

# ---------- 4. the boot-time verdict must leave a breadcrumb ----------
# assert_cred_seeded already printed an ERROR for a present-but-unreadable
# source — to journald, which neither the health rail nor selfcheck reads.
extract_fn() { awk -v m="$1() {" 'substr($0,1,length(m))==m { on=1 } on { print } on && $0 == "}" { exit }' 5dive-agent-start; }
HELPER=""
for _fn in assert_cred_seeded cred_seed_breadcrumb_path cred_seed_breadcrumb_write cred_seed_failed cred_seed_ok cred_src_readable cred_seed_why; do
  _def="$(extract_fn "$_fn")"
  [[ -n "$_def" ]] || { echo "FAIL: could not extract $_fn from 5dive-agent-start"; fail=1; }
  HELPER+="$_def"$'\n'
done
if [[ $EUID -eq 0 ]]; then
  echo "skip: breadcrumb leg needs a non-root euid (root can read anything)"
else
  mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
  UNREADABLE="$TMP/unreadable/.openclaw/agents/main/agent/auth-profiles.json"
  mkdir -p "$(dirname "$UNREADABLE")"
  printf '{"version":1}\n' > "$UNREADABLE"; chmod 0000 "$UNREADABLE"
  BCHOME="$TMP/bchome"; mkdir -p "$BCHOME"
  out=$(env PATH="$TMP/bin:$PATH" HOME="$BCHOME" bash -c "
    set -uo pipefail
    $HELPER
    assert_cred_seeded openclaw '$UNREADABLE' '$BCHOME/nonexistent-local.json'
  " 2>&1)
  has "$out" "ERROR: openclaw credential EXISTS" "boot verdict still names the fault on stderr"
  has "$out" "Malformed auth code" "boot verdict still names the misleading downstream symptom"
  check "the verdict now leaves the breadcrumb the health rail reads" \
        "$( [[ -s "$BCHOME/.5dive-cred-seed-failed" ]] && echo yes )" "yes"
  has "$(cat "$BCHOME/.5dive-cred-seed-failed" 2>/dev/null)" "UNAUTHENTICATED" \
      "breadcrumb text names the consequence"
  chmod 0644 "$UNREADABLE"
fi

# Verdict shape is load-bearing, not style: tests/meta/harness-verdict-probe.sh
# proves a harness is WIRED by injecting `fail=$((fail+1))` before the verdict and
# asserting the exit status flips. It recognises `exit $(( VAR > 0 ))` (and a few
# siblings) within the last handful of statements; a bare `if (( fail )); then
# exit 1; fi` is UNPROBEABLE — "not counted clean", which is a red check, not a
# green one. Keep the counter numeric-only for the same reason.
if (( fail )); then echo "RESULT: FAIL"; else echo "RESULT: PASS"; fi
exit $(( fail > 0 ))
