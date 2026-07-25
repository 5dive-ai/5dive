#!/usr/bin/env bash
# DIVE-1900 unit: the per-type credential seed blocks in `5dive-agent-start`
# must work for an agent with NO passwordless sudo.
#
# The defect: the antigravity and openclaw blocks routed *every* probe through
# `sudo -n` (test -e, test -nt, cat). Standard-isolation agents get no NOPASSWD
# sudoers rule, so the first `sudo -n test -e` failed, the whole branch was
# skipped, and nothing was printed. A SUCCESSFUL login sat in the auth profile
# while the agent home had no token at all — the agent then fell back to its own
# auth-code exchange and died with `invalid_grant "Malformed auth code"`, which
# reads as an EXPIRED credential. Profile contents, `5dive agent list` and the
# seat row all said healthy.
#
# This test runs the real seed blocks, extracted from the real script, with
# `sudo` stubbed to always fail (exactly what a standard agent sees) and asserts
# the credential still arrives. Pure, no root, no network:
#   bash tests/agent_start_cred_seed_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
START=5dive-agent-start
TMP="$(mktemp -d /tmp/agent-start-seed-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }
has()   { if grep -q "$2" <<<"$1"; then echo "ok: $3"; else echo "FAIL: $3"; fail=1; fi; }

# A standard-isolation agent: `sudo -n <anything>` fails with status 1.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"

# Pull a block out of the real script by its exact `if [[ "$TYPE" == ... ` guard
# line so this test can never drift from the shipped code. Exact match (not a
# regex) so the plain type block isn't confused with the `&& CHANNELS` one that
# follows it; the closing `fi` is the only one at column 0.
extract_block() { # <type>
  awk -v marker="if [[ \"\$TYPE\" == \"$1\" ]]; then" '
    $0 == marker { on=1 }
    on { print }
    on && $0 == "fi" { exit }
  ' "$START"
}

run_block() { # <block> <extra-env-assignments...>  -> stdout+stderr of the block
  local block="$1"; shift
  env PATH="$TMP/bin:$PATH" "$@" bash -c "
    set -uo pipefail
    $block
  " 2>&1
}

# ---------- antigravity ----------
AGY_BLOCK="$(extract_block antigravity)"
[[ -n "$AGY_BLOCK" ]] || { echo "FAIL: could not extract antigravity block"; exit 1; }

PROFILE="$TMP/profile-agy"
AGY_SHARED="$PROFILE/.gemini/antigravity-cli/antigravity-oauth-token"
mkdir -p "$(dirname "$AGY_SHARED")"
printf 'ya29.valid-agy-token\n' > "$AGY_SHARED"   # 0644: normalized + traversable
AGY_HOME="$TMP/home-agy"
mkdir -p "$AGY_HOME"

out=$(run_block "$AGY_BLOCK" TYPE=antigravity HOME="$AGY_HOME" \
        PROFILE_STATE_DIR="$PROFILE" WORKDIR="$TMP")
LOCAL_AGY="$AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
check "agy: token seeded with sudo unavailable" \
      "$( [[ -s "$LOCAL_AGY" ]] && cat "$LOCAL_AGY" )" "ya29.valid-agy-token"
check "agy: no false alarm on a successful seed" \
      "$(grep -c 'ERROR: antigravity credential EXISTS' <<<"$out")" "0"

# Re-seed on a NEWER profile token (the re-auth path) — this is what `agent
# restart` is documented to do and what silently never happened.
sleep 1
printf 'ya29.rotated-agy-token\n' > "$AGY_SHARED"
run_block "$AGY_BLOCK" TYPE=antigravity HOME="$AGY_HOME" \
  PROFILE_STATE_DIR="$PROFILE" WORKDIR="$TMP" >/dev/null
check "agy: rotated token re-seeded on restart" "$(cat "$LOCAL_AGY")" "ya29.rotated-agy-token"

# Unreadable profile + no sudo => must be LOUD, not a silent no-op. (Skipped
# under root, which can read anything.)
if [[ $EUID -ne 0 ]]; then
  chmod 0000 "$AGY_SHARED"
  AGY_HOME2="$TMP/home-agy-2"; mkdir -p "$AGY_HOME2"
  out=$(run_block "$AGY_BLOCK" TYPE=antigravity HOME="$AGY_HOME2" \
          PROFILE_STATE_DIR="$PROFILE" WORKDIR="$TMP")
  has "$out" 'ERROR: antigravity credential EXISTS' \
      "agy: unreadable-but-present credential is announced, not silent"
  has "$out" 'Malformed auth code' \
      "agy: warning names the misleading downstream symptom"
  chmod 0644 "$AGY_SHARED"
fi

# ---------- openclaw ----------
OC_BLOCK="$(extract_block openclaw)"
[[ -n "$OC_BLOCK" ]] || { echo "FAIL: could not extract openclaw block"; exit 1; }

PROFILE_OC="$TMP/profile-oc"
OC_SHARED="$PROFILE_OC/.openclaw/agents/main/agent/auth-profiles.json"
mkdir -p "$(dirname "$OC_SHARED")"
printf '{"token":"oc-valid"}\n' > "$OC_SHARED"
OC_HOME="$TMP/home-oc"; mkdir -p "$OC_HOME"

out=$(run_block "$OC_BLOCK" TYPE=openclaw HOME="$OC_HOME" \
        PROFILE_STATE_DIR="$PROFILE_OC" WORKDIR="$TMP")
LOCAL_OC="$OC_HOME/.openclaw/agents/main/agent/auth-profiles.json"
check "openclaw: auth-profiles.json seeded with sudo unavailable" \
      "$( [[ -s "$LOCAL_OC" ]] && cat "$LOCAL_OC" )" '{"token":"oc-valid"}'

if [[ $EUID -ne 0 ]]; then
  chmod 0000 "$OC_SHARED"
  OC_HOME2="$TMP/home-oc-2"; mkdir -p "$OC_HOME2"
  out=$(run_block "$OC_BLOCK" TYPE=openclaw HOME="$OC_HOME2" \
          PROFILE_STATE_DIR="$PROFILE_OC" WORKDIR="$TMP")
  has "$out" 'ERROR: openclaw credential EXISTS' \
      "openclaw: unreadable-but-present credential is announced, not silent"
  chmod 0644 "$OC_SHARED"
fi

# ---------- guard: no seed block may be sudo-ONLY again ----------
# Every credential seed must attempt a plain read before falling back to sudo.
# Catches a future block (or a revert) that reintroduces the DIVE-1900 shape.
for guard in 'antigravity' 'openclaw' 'grok' 'hermes'; do
  blk="$(extract_block "$guard")"
  if [[ -z "$blk" ]]; then
    echo "FAIL: could not extract $guard seed block"; fail=1; continue
  fi
  if grep -qE '^[[:space:]]*if[[:space:]]+sudo -n test -e' <<<"$blk"; then
    echo "FAIL: $guard seed block still gates on a bare 'sudo -n test -e' (DIVE-1900 regression)"
    fail=1
  else
    echo "ok: $guard seed block does not gate solely on sudo"
  fi
done

exit $fail
