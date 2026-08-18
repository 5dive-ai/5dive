#!/usr/bin/env bash
# DIVE-3572 unit harness — buzz identity in the registry, and the whois read.
#
# WHAT THIS GRADES, and deliberately only this: the WRITER and the READER against
# each other, on a real registry file in a scratch state dir. No relay, no root,
# no network. DIVE-3565's defect was a writer and a reader that were each green in
# isolation and disagreed in production, so every arm below reads back through the
# verb an actual caller uses rather than asserting the jq that wrote it.
#
# THE ARM THAT MATTERS MOST is 8: an unreadable registry must NOT answer the same
# as a key that is genuinely unknown. In this trust model those two collapse into
# a fleet-wide, silent demotion of every teammate to "stranger" — invisible,
# because "stranger" is also the correct answer for a real stranger. It carries a
# POSITIVE CONTROL (the same key resolves when the file IS readable), because an
# arm that only shows a non-answer cannot tell a refusal from a broken fixture.
#
# Run: bash tests/buzz_identity_registry_unit.sh   (no root, no network, no relay.)
#
# TIER: core — 0.7s measured on the 5dive control plane (agent-dev seat, 2026-08-18,
# slowest of 3: 0.66/0.74/0.68s). Stated, not defaulted: it is 0.23% of the 300s PR
# core budget, and it guards the precondition the whole buzz trust model rests on —
# a writer and a reader that must agree, which is the one class a per-PR run catches
# and a nightly one catches a day late. No demotion argued here, per
# [[project_core_tier_is_over_budget_file_new_harnesses_nightly]]: a demotion needs a
# core budget number read off a recent CI run, not off this seat.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz_join.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz_whois.sh"
set +e  # header.sh enables set -e; the arms below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- 1. the file is in the bundle -------------------------------------------
grep -q '^  src/cmd_agent_buzz_whois\.sh \\$' build.sh \
  && ok_t "build.sh concatenates cmd_agent_buzz_whois.sh" \
  || bad_t "build.sh concatenates cmd_agent_buzz_whois.sh" \
           "present but never concatenated — \`agent buzz whois\` is 'command not found' in the built bundle"

# --- 2. the verb is dispatched and documented -------------------------------
grep -qE '^\s+whois\)\s+shift; _buzz_whois' "$SRC/cmd_agent_buzz.sh" \
  && ok_t "cmd_agent_buzz dispatches 'whois'" \
  || bad_t "cmd_agent_buzz dispatches 'whois'" "the verb is unreachable"
grep -q 'buzz whois' "$SRC/cmd_agent_buzz.sh" \
  && ok_t "buzz usage names whois" || bad_t "buzz usage names whois" "undiscoverable"
grep -q '5dive agent buzz whois' "$SRC/main.sh" \
  && ok_t "top-level usage names whois" || bad_t "top-level usage names whois" "undiscoverable"

# --- 3. whois is routed LOCK-FREE (its caller is a non-root agent) ----------
# with_registry_lock -> ensure_state -> require_root. Routed through the mutating
# arm, the lookup the plugin exists to make would refuse for the plugin.
grep -qE '\[\[ "\$\{1:-\}" == "status" \|\| "\$\{1:-\}" == "whois" \]\]' "$SRC/main.sh" \
  && ok_t "main.sh routes whois without the registry lock (no require_root)" \
  || bad_t "main.sh routes whois without the registry lock" \
           "the buzz plugin runs as the agent user; a root-only lookup is unusable by the only caller it has"

# --- 4. both writers are wired ----------------------------------------------
grep -q '_buzz_registry_record "$name" pubkey' "$SRC/cmd_agent_buzz.sh" \
  && ok_t "enable records the seat's own pubkey" \
  || bad_t "enable records the seat's own pubkey" "a seat is wired to the relay and invisible to whois"
grep -q '_buzz_registry_record "$name" owner_pubkey' "$SRC/cmd_agent_buzz_join.sh" \
  && ok_t "join records the paired handset pubkey" \
  || bad_t "join records the paired handset pubkey" "the OWNER cannot be told from a stranger"

# --- 5. npub decode, against the published NIP-19 vector + a control ---------
NPUB='npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6'
HEXV='3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d'
got=$(printf '%s' "$NPUB" | _buzz_npub_to_hex 2>/dev/null)
[[ "$got" == "$HEXV" ]] \
  && ok_t "npub decodes to the NIP-19 x-only vector" \
  || bad_t "npub decodes to the NIP-19 x-only vector" "got '$got', want '$HEXV'"
# The control: one flipped character must be REFUSED, not silently decoded into a
# lookup that then answers 'unknown' (= 'do not trust') about the wrong key.
printf '%s' "${NPUB%?}7" | _buzz_npub_to_hex >/dev/null 2>&1 \
  && bad_t "a bad-checksum npub is refused" "it decoded — a typo would silently become a distrust verdict" \
  || ok_t "a bad-checksum npub is refused"

# --- fixture: a real registry in a scratch state dir ------------------------
TMP=$(mktemp -d); trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
REGISTRY="$TMP/agents.json"
REGISTRY_LOCK="$TMP/agents.lock"
IN_REGISTRY_LOCK=1        # writer is called under the lock in production
AGENT_PUB='aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff0011abcd'
OWNER_PUB='ff00112233445566778899aabbccddeeff00112233445566778899aabbccddee'
OTHER_PUB='1111111111111111111111111111111111111111111111111111111111111111'
CASE_PUB='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'  # has letters: an all-digit key cannot grade case at all
cat > "$REGISTRY" <<JSON
{"schemaVersion":2,"agents":{
  "dev":{"type":"claude","channels":"buzz","isolation":"admin"},
  "quinn":{"type":"claude","channels":"telegram","isolation":"admin"}}}
JSON
# registry_write chowns root:claude, which a non-root harness cannot do; the mv
# still lands. Silence only that, never the jq.
_rw() { registry_write 2>/dev/null; }

# --- 6. the writer records, and the READER reads it back --------------------
_buzz_registry_record dev pubkey "$AGENT_PUB" >/dev/null 2>&1
got=$(_buzz_whois "$AGENT_PUB" 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$got" == "dev" ]] \
  && ok_t "whois <agent pubkey> -> seat name, rc 0" \
  || bad_t "whois <agent pubkey> -> seat name, rc 0" "rc=$rc out='$got' (writer and reader disagree — DIVE-3565's shape)"

# Case is graded on BOTH sides, independently, because they are separate guards.
# READER: a mixed-case argument against a canonical store.
got=$(_buzz_whois "${AGENT_PUB^^}" 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$got" == "dev" ]] \
  && ok_t "whois accepts a mixed-case argument" || bad_t "whois accepts a mixed-case argument" "rc=$rc out='$got'"
# READER again, against a store this writer did not produce: a hand-edited or
# migrated registry holding an upper-case key must still resolve. Written with jq
# directly, deliberately bypassing _buzz_registry_record's canonicalisation.
jq --arg v "${AGENT_PUB^^}" '.agents.quinn.buzz = {pubkey:$v}' "$REGISTRY" > "$TMP/x" && mv "$TMP/x" "$REGISTRY"
got=$(_buzz_whois "$AGENT_PUB" --role 2>/dev/null); rc=$?
[[ $rc -eq 5 ]] \
  && ok_t "whois matches a mixed-case key already IN the registry (seen as the second holder)" \
  || bad_t "whois matches a mixed-case key already in the registry" \
           "rc=$rc out='$got' — a hand-edited or migrated entry would read as an unknown key, i.e. 'do not trust'"
jq '.agents.quinn |= del(.buzz)' "$REGISTRY" > "$TMP/x" && mv "$TMP/x" "$REGISTRY"
# WRITER: the stored form is canonical, so every other jq consumer sees one spelling.
_buzz_registry_record quinn pubkey "${CASE_PUB^^}" >/dev/null 2>&1
got=$(jq -r '.agents.quinn.buzz.pubkey' "$REGISTRY" 2>/dev/null)
[[ "$got" == "$CASE_PUB" ]] \
  && ok_t "the writer stores the key lowercased" || bad_t "the writer stores the key lowercased" "stored '$got'"
jq '.agents.quinn |= del(.buzz)' "$REGISTRY" > "$TMP/x" && mv "$TMP/x" "$REGISTRY"

# --- 7. the owner half is a DIFFERENT trust class, and whois says which -----
_buzz_registry_record dev owner_pubkey "$OWNER_PUB" >/dev/null 2>&1
got=$(_buzz_whois "$OWNER_PUB" --role 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$got" == "dev owner" ]] \
  && ok_t "whois --role distinguishes the owner key from the agent key" \
  || bad_t "whois --role distinguishes the owner key from the agent key" \
           "rc=$rc out='$got' — the bridge cannot separate trust class (b) from (c)"
got=$(_buzz_whois "$AGENT_PUB" --role 2>/dev/null)
[[ "$got" == "dev agent" ]] \
  && ok_t "whois --role reports the agent key as 'agent'" || bad_t "whois --role reports the agent key as 'agent'" "got '$got'"

# recording the owner half must not have disturbed the agent half or the sibling seat
got=$(jq -r '.agents.dev.buzz.pubkey' "$REGISTRY" 2>/dev/null)
[[ "$got" == "$AGENT_PUB" ]] \
  && ok_t "a second field write preserves the first" || bad_t "a second field write preserves the first" "got '$got'"
jq -e '.agents.quinn.type == "claude" and .schemaVersion == 2' "$REGISTRY" >/dev/null 2>&1 \
  && ok_t "the write preserves other seats and the schema version" \
  || bad_t "the write preserves other seats and the schema version" "the writer clobbered the registry"

# --- 8. NO PRIVATE KEY EVER REACHES THE REGISTRY ----------------------------
# The store is group-readable by `claude`; a secret landing here is a fleet-wide
# leak. Asserted against the file's bytes, not against intent.
# NOT a claim that the writer can recognise a secret — a private key is 64 hex
# too, so it CANNOT, which is exactly why the derivation lives at the two call
# sites and never here. What is asserted is that neither the store nor this file
# carries private material by construction.
grep -qE '"private_key"|"nsec"' "$REGISTRY" \
  && bad_t "the registry holds no private material" "a secret field was written into a group-readable file" \
  || ok_t "the registry holds no private material (no private_key/nsec fields)"
grep -q 'private_key' "$SRC/cmd_agent_buzz_whois.sh" \
  && bad_t "the identity writer never touches a private key" "cmd_agent_buzz_whois.sh mentions private_key" \
  || ok_t "the identity writer never touches a private key"

# --- 9. MEASURED unknown: rc 4, and stdout is EMPTY -------------------------
out=$(_buzz_whois "$OTHER_PUB" 2>/dev/null); rc=$?
[[ $rc -eq 4 && -z "$out" ]] \
  && ok_t "an unknown key: rc 4 (E_NOT_FOUND), empty stdout" \
  || bad_t "an unknown key: rc 4 (E_NOT_FOUND), empty stdout" "rc=$rc out='$out'"

# --- 10. THE ROW'S DECIDE-AND-DOCUMENT CLAUSE -------------------------------
# An unreadable registry must NOT answer like an unknown key. registry_read()
# collapses them onto {"agents":{}}; registry_read_checked() does not.
# POSITIVE CONTROL FIRST: the same key resolves while the file is readable, so a
# green here cannot come from a fixture that was already broken.
ctl=$(_buzz_whois "$AGENT_PUB" 2>/dev/null); ctl_rc=$?
REGISTRY="$TMP/does-not-exist.json"
out=$(_buzz_whois "$AGENT_PUB" 2>/dev/null); rc=$?
REGISTRY="$TMP/agents.json"
if [[ $ctl_rc -eq 0 && "$ctl" == "dev" ]]; then
  [[ $rc -eq 1 && -z "$out" ]] \
    && ok_t "an unreadable registry: rc 1, NOT the rc 4 an unknown key gets (control: same key resolves when readable)" \
    || bad_t "an unreadable registry is distinguishable from an unknown key" \
             "rc=$rc (want 1, and never 4) out='$out' — a box fault would silently demote every teammate to 'stranger'"
else
  bad_t "an unreadable registry is distinguishable from an unknown key" \
        "NOT REACHED: the positive control failed (rc=$ctl_rc out='$ctl'), so the arm proves nothing"
fi
# and the reason token is on stderr, so a caller can branch without parsing prose
REGISTRY="$TMP/does-not-exist.json"
err=$(_buzz_whois "$AGENT_PUB" 2>&1 >/dev/null)
REGISTRY="$TMP/agents.json"
[[ "$err" == *"unknown:no-registry"* ]] \
  && ok_t "the not-measured reason is a token on stderr" || bad_t "the not-measured reason is a token on stderr" "got '$err'"

# an UNPARSEABLE registry is also not-measured, not 'unknown key'
printf '{"agents":{' > "$TMP/truncated.json"
REGISTRY="$TMP/truncated.json"
out=$(_buzz_whois "$AGENT_PUB" 2>/dev/null); rc=$?
REGISTRY="$TMP/agents.json"
[[ $rc -eq 1 && -z "$out" ]] \
  && ok_t "a truncated registry: rc 1, not rc 4" || bad_t "a truncated registry: rc 1, not rc 4" "rc=$rc out='$out'"

# --- 11. ambiguity is refused, never resolved by jq ordering ----------------
_buzz_registry_record quinn pubkey "$AGENT_PUB" >/dev/null 2>&1
out=$(_buzz_whois "$AGENT_PUB" 2>/dev/null); rc=$?
[[ $rc -eq 5 && -z "$out" ]] \
  && ok_t "two seats on one key: rc 5 (E_CONFLICT), no name printed" \
  || bad_t "two seats on one key: rc 5, no name printed" \
           "rc=$rc out='$out' — naming one of them hands the bridge an identity it cannot prove"
jq '.agents.quinn |= del(.buzz)' "$REGISTRY" > "$TMP/x" && mv "$TMP/x" "$REGISTRY"

# --- 12. a malformed argument is refused BEFORE any read --------------------
for bad in "" "not-a-key" "aa11bb" "$(printf 'z%.0s' {1..64})" "npub1notreal"; do
  ( _buzz_whois "$bad" ) >/dev/null 2>&1; rc=$?
  case "$rc" in
    2|3) ;;
    *) bad_t "a malformed key is refused (usage/validation)" "input '${bad:0:20}' gave rc=$rc, which a caller reads as a verdict about a key"; continue ;;
  esac
done
ok_t "malformed keys are refused with usage/validation, never a key verdict"

# --- 13. the writer refuses junk rather than recording it -------------------
before=$(cat "$REGISTRY")
_buzz_registry_record dev pubkey "not-64-hex" >/dev/null 2>&1; rc=$?
after=$(cat "$REGISTRY")
[[ $rc -ne 0 && "$before" == "$after" ]] \
  && ok_t "the writer refuses a malformed key and leaves the registry untouched" \
  || bad_t "the writer refuses a malformed key" "rc=$rc; registry changed=$( [[ "$before" == "$after" ]] && echo no || echo yes )"
_buzz_registry_record nosuchseat pubkey "$OTHER_PUB" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok_t "the writer refuses an unregistered seat" || bad_t "the writer refuses an unregistered seat" "rc=$rc"

# A FAILED WRITE MUST BE REPORTED AS ONE. The callers branch on this rc to decide
# whether to tell the operator that whois will call the seat unknown; a trailing
# `step` returning 0 would report a lost write as a recorded identity.
mkdir -p "$TMP/ro" && printf '{"agents":{"dev":{}}}' > "$TMP/ro/agents.json" && chmod 500 "$TMP/ro"
REGISTRY="$TMP/ro/agents.json"
_buzz_registry_record dev pubkey "$OTHER_PUB" >/dev/null 2>&1; rc=$?
chmod 700 "$TMP/ro"
REGISTRY="$TMP/agents.json"
[[ $rc -ne 0 ]] \
  && ok_t "a write that could not land is reported as a failure, not as a record" \
  || bad_t "a write that could not land is reported as a failure" \
           "rc=$rc — the caller would skip the warning that whois now calls this seat unknown"

# --- 14. npub end-to-end through the verb -----------------------------------
_buzz_registry_record dev pubkey "$HEXV" >/dev/null 2>&1
got=$(_buzz_whois "$NPUB" 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$got" == "dev" ]] \
  && ok_t "whois resolves an npub1… the same as its hex" || bad_t "whois resolves an npub1…" "rc=$rc out='$got'"

# --- 15. the PRODUCTION data path, end to end on a published vector ----------
# enable/join do not hand the writer a literal: they derive the x-only pubkey
# from the private key they already hold and record THAT. Compose the real three
# steps — derive -> record -> look up — so a drift in any one of them is caught
# by the arm rather than by a customer whose teammate reads as a stranger.
# BIP-340 vector: d=3 -> P=F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9.
BIP340_D='0000000000000000000000000000000000000000000000000000000000000003'
BIP340_P='f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9'
derived=$(printf '%s' "$BIP340_D" | _buzz_xonly_pubkey 2>/dev/null)
if [[ "${derived,,}" != "$BIP340_P" ]]; then
  bad_t "derive -> record -> whois round-trips on the BIP-340 vector" \
        "NOT REACHED: _buzz_xonly_pubkey gave '$derived', want '$BIP340_P'"
else
  _buzz_registry_record quinn pubkey "$derived" >/dev/null 2>&1
  got=$(_buzz_whois "$derived" --role 2>/dev/null); rc=$?
  [[ $rc -eq 0 && "$got" == "quinn agent" ]] \
    && ok_t "derive -> record -> whois round-trips on the BIP-340 vector" \
    || bad_t "derive -> record -> whois round-trips on the BIP-340 vector" "rc=$rc out='$got'"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
