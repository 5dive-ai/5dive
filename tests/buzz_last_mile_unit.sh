#!/usr/bin/env bash
# DIVE-3513 unit harness for the buzz last mile (steps 5 and 6 of six).
#
# What this can grade WITHOUT a relay, and deliberately only that: the two
# derivations the last mile is built on, the channel lookup, and the wiring that
# makes the verbs reachable at all. A join is a relay call; whether the relay
# accepts it is the fresh-VM smoke's job, not this file's, and pretending
# otherwise is the exact defect the arc is about.
#
#   1. the file is CONCATENATED into the bundle — the failure mode
#      tests/buzz_channel_wiring_unit.sh:359 already names for cmd_agent_buzz.sh
#   2. `agent buzz join|owner` are dispatched (usage text names them)
#   3. BIP-340 x-only derivation against the published test vector — this is the
#      customer pubkey that gets added as a MEMBER, so a wrong one silently adds
#      a stranger to the channel and the handset still sees nothing
#   4. bech32 `nsec` against the NIP-19 published vector — the app decodes this
#      or the pairing envelope dies on import (DIVE-3300)
#   5. channel lookup by name, WITH A CONTROL ARM (a name known to be present
#      must be found) — a matcher that finds nothing twice reads as green
#   6. the private key is never an argv element (the DIVE-3509 push-gate rule)
#
# Run: bash tests/buzz_last_mile_unit.sh   (no root, no network, no relay.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
JOINF="$SRC/cmd_agent_buzz_join.sh"

# shellcheck source=/dev/null
source "$JOINF"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- 1. the file is in the bundle -------------------------------------------
grep -q '^  src/cmd_agent_buzz_join\.sh \\$' build.sh \
  && ok_t "build.sh concatenates cmd_agent_buzz_join.sh" \
  || bad_t "build.sh concatenates cmd_agent_buzz_join.sh" \
           "the file is present but never concatenated — \`agent buzz join\` would be 'command not found' in the built bundle"

# --- 2. the verbs are dispatched --------------------------------------------
grep -qE '^\s+join\)\s+shift; _buzz_join' "$SRC/cmd_agent_buzz.sh" \
  && ok_t "cmd_agent_buzz dispatches 'join'" \
  || bad_t "cmd_agent_buzz dispatches 'join'" "the verb is unreachable"
grep -qE '^\s+owner\)\s+shift; _buzz_owner' "$SRC/cmd_agent_buzz.sh" \
  && ok_t "cmd_agent_buzz dispatches 'owner'" \
  || bad_t "cmd_agent_buzz dispatches 'owner'" "the verb is unreachable"

# --- 3. BIP-340 x-only pubkey, published vector -----------------------------
# BIP-340 test vector index 0: seckey 0x3. The same value the plugin derives with
# schnorr.getPublicKey (plugins/buzz/server.ts:86); a drift here is a member-add
# that names a pubkey nobody holds.
V3_SK=0000000000000000000000000000000000000000000000000000000000000003
V3_PK=f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9
got=$(printf '%s' "$V3_SK" | _buzz_xonly_pubkey 2>&1)
[[ "$got" == "$V3_PK" ]] \
  && ok_t "BIP-340 x-only pubkey matches the published vector for seckey=3" \
  || bad_t "BIP-340 x-only pubkey matches the published vector for seckey=3" "got '$got'"

# Control arm: a DIFFERENT key must give a DIFFERENT pubkey. Without this, a
# derivation stuck on one constant passes the arm above forever.
got2=$(printf '%s' "0000000000000000000000000000000000000000000000000000000000000004" | _buzz_xonly_pubkey 2>&1)
[[ -n "$got2" && "$got2" != "$got" ]] \
  && ok_t "control: a different private key derives a different pubkey" \
  || bad_t "control: a different private key derives a different pubkey" "seckey=4 gave '$got2'"

# Refusal arms: the derivation must not invent a pubkey for junk.
printf '%s' "nothex" | _buzz_xonly_pubkey >/dev/null 2>&1 \
  && bad_t "short/non-hex key is refused" "it returned success" \
  || ok_t "short/non-hex key is refused"
printf '%s' "0000000000000000000000000000000000000000000000000000000000000000" | _buzz_xonly_pubkey >/dev/null 2>&1 \
  && bad_t "a zero private key is refused" "it returned success" \
  || ok_t "a zero private key is refused"

# --- 4. bech32 nsec, NIP-19 published vector --------------------------------
# The envelope's `nsec` field. `_buzz_owner --envelope` needs a real agent home,
# so the encoder is graded here in isolation against the spec's own example.
NSEC_HEX=67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa
NSEC_WANT=nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5
enc=$(sed -n '/^CHARSET = /,/^nsec = bech32/p' "$JOINF")
got=$(python3 -c "
import sys
key = sys.argv[1]
$enc
print(nsec)
" "$NSEC_HEX" 2>&1)
[[ "$got" == "$NSEC_WANT" ]] \
  && ok_t "bech32 nsec matches the NIP-19 published vector" \
  || bad_t "bech32 nsec matches the NIP-19 published vector" "got '$got'"

# --- 5. channel lookup by name, with a control arm --------------------------
LISTING='[{"channel_id":"aaaa-1111","name":"general"},{"channel_id":"bbbb-2222","name":"ops"}]'
[[ "$(_buzz_channel_id ops <<<"$LISTING")" == "bbbb-2222" ]] \
  && ok_t "control: a channel that IS present is found by name" \
  || bad_t "control: a channel that IS present is found by name" "got '$(_buzz_channel_id ops <<<"$LISTING")'"
[[ -z "$(_buzz_channel_id nope <<<"$LISTING")" ]] \
  && ok_t "an absent channel yields empty (so the caller creates it)" \
  || bad_t "an absent channel yields empty (so the caller creates it)"
# Exact match only: a prefix must not be mistaken for the channel, or `general`
# would join `general-2` and the customer's handset lands in the wrong room.
[[ -z "$(_buzz_channel_id gener <<<"$LISTING")" ]] \
  && ok_t "channel lookup is an exact-name match, not a prefix" \
  || bad_t "channel lookup is an exact-name match, not a prefix"
[[ -z "$(_buzz_channel_id ops <<<'not json at all')" ]] \
  && ok_t "unparseable relay output yields empty, not a crash" \
  || bad_t "unparseable relay output yields empty, not a crash"

# --- 6. the key is never an argv element ------------------------------------
# /proc/<pid>/cmdline is world-readable on our boxes and there is no hidepid
# (positive-controlled on the DIVE-3509 gate). `env BUZZ_PRIVATE_KEY=<hex> …`
# would put a live key where every other agent user can read it.
# The predicate: EVERY mention of BUZZ_PRIVATE_KEY= must be the in-hop export.
# Anything else (an `env BUZZ_PRIVATE_KEY=…`, a literal) is the defect.
argv_key_hits() { grep -n 'BUZZ_PRIVATE_KEY=' "$1" | grep -vc 'export BUZZ_PRIVATE_KEY="\$k"'; }
[[ "$(argv_key_hits "$JOINF")" == "0" ]] \
  && ok_t "no private key on argv" \
  || bad_t "no private key on argv" "an assignment of BUZZ_PRIVATE_KEY appears outside the stdin hop: $(grep -n 'BUZZ_PRIVATE_KEY=' "$JOINF" | grep -v 'export BUZZ_PRIVATE_KEY="\$k"')"
# Prove the arm can FIRE — a check that only ever reads clean is not a check.
_canary=$(mktemp) && printf 'sudo -u x env BUZZ_PRIVATE_KEY=%s buzz users get\n' 'deadbeef' >"$_canary"
[[ "$(argv_key_hits "$_canary")" != "0" ]] \
  && ok_t "control: the argv arm rejects a planted \`env BUZZ_PRIVATE_KEY=…\`" \
  || bad_t "control: the argv arm rejects a planted \`env BUZZ_PRIVATE_KEY=…\`" "the arm cannot fire; its green means nothing"
rm -f "$_canary"
grep -q 'IFS= read -r k' "$JOINF" \
  && ok_t "_buzz_cli takes the key on stdin" \
  || bad_t "_buzz_cli takes the key on stdin" "the stdin hop is gone — check how the key reaches buzz"
grep -q 'export BUZZ_PRIVATE_KEY="\$k"' "$JOINF" \
  && ok_t "the key is exported INSIDE the sudo hop (/proc/<pid>/environ is 0400)" \
  || bad_t "the key is exported INSIDE the sudo hop"

# --- 7. the last mile is not silently optional ------------------------------
# `join` must refuse when there is no binary rather than reporting success over a
# box that cannot make a relay call. That refusal is the whole DIVE-3512 lesson.
grep -q 'E_NOT_INSTALLED' "$JOINF" \
  && ok_t "join refuses when no buzz binary resolves" \
  || bad_t "join refuses when no buzz binary resolves" "it would 'succeed' having made no relay call"
# And it must read back rather than trust the write (DIVE-3507: accepted:true is
# not evidence).
grep -q 'channels members --channel' "$JOINF" \
  && ok_t "membership is asserted by a read-back, not by the write's ack" \
  || bad_t "membership is asserted by a read-back, not by the write's ack"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
