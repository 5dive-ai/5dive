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

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz.sh"
# shellcheck source=/dev/null
source "$JOINF"
set +e  # header.sh enables set -e; the arms below deliberately probe non-zero rc

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

# --- 7. the read-back is anchored, not a substring --------------------------
# `[[ "$mine" == *"$cid"* ]]` over raw JSON is vacuous when the relay numbers its
# channels: cid=1 matches almost any payload, so "the agent is in the room"
# degrades to "the relay answered something". _buzz_lists_channel_id parses the
# field; the substring survives only as an UNPARSEABLE-payload fallback, and only
# for an id long enough to still be evidence.
MEMBER_JSON='[{"channel_id":"aaaa-1111-bbbb","name":"general"},{"channel_id":"cccc-2222-dddd","name":"ops"}]'
_buzz_lists_channel_id "aaaa-1111-bbbb" <<<"$MEMBER_JSON" \
  && ok_t "control: an id that IS in the member listing is found" \
  || bad_t "control: an id that IS in the member listing is found" "the predicate cannot say yes; its no means nothing"
_buzz_lists_channel_id "eeee-3333-ffff" <<<"$MEMBER_JSON" \
  && bad_t "an id absent from the member listing is a MISS" "it accepted an id that is not there" \
  || ok_t "an id absent from the member listing is a MISS"
# THE DEFECT ARM. "1" is a substring of "aaaa-1111-bbbb" and of the payload at
# large; the field parse must still say no.
_buzz_lists_channel_id "1" <<<"$MEMBER_JSON" \
  && bad_t "a short id is not accepted by substring luck" "cid=1 matched a payload that contains no channel_id 1 — the DIVE-3513 iteration-1 defect" \
  || ok_t "a short id is not accepted by substring luck"
# An id that IS the relay's own short id must still match, by FIELD.
_buzz_lists_channel_id "1" <<<'[{"channel_id":"1","name":"general"}]' \
  && ok_t "a short id that really is a channel_id matches by field" \
  || bad_t "a short id that really is a channel_id matches by field" "the anchoring broke short-id relays outright"
# A non-channel_id field carrying the same value must not be mistaken for it.
_buzz_lists_channel_id "42" <<<'[{"channel_id":"aaaa-1111-bbbb","name":"general","unread":42}]' \
  && bad_t "a value in some other field is not a membership hit" "unread:42 was read as a channel_id" \
  || ok_t "a value in some other field is not a membership hit"
# Fallback: an unparseable payload with a LONG id is still evidence...
_buzz_lists_channel_id "aaaa-1111-bbbb" <<<'channel aaaa-1111-bbbb  general  (member)' \
  && ok_t "unparseable payload + long id falls back to substring" \
  || bad_t "unparseable payload + long id falls back to substring" "the fallback is dead code; a listing format change would red every join"
# ...and with a SHORT id it is not.
_buzz_lists_channel_id "1" <<<'channel 1  general  (member) 11 messages' \
  && bad_t "unparseable payload + short id is refused" "the vacuous path is still reachable" \
  || ok_t "unparseable payload + short id is refused"

# ===========================================================================
# 8. THE ORCHESTRATION ITSELF, DRIVEN THROUGH A FAKE RELAY
#
# Everything above grades a helper in isolation or a string in a file. None of it
# executes _buzz_join, so none of it would notice the function being deleted —
# the defect community/wiki/a-grep-arm-can-only-grade-the-string-not-the-branch-
# it-names.md names, at whole-harness scale (quinn, DIVE-3513 iteration 1).
#
# Offline was never the constraint. A fake `buzz` on PATH answering fixture JSON
# reaches every branch that does not need a real relay: create-when-absent, the
# member-add, the read-back predicate, the rc-3 partial wire, the comma-split
# loop, step 6, and — with the same stub — `enable` actually CALLING `join`.
#
# What it still does NOT grade, and no local harness can: that a real relay
# accepts these calls in this order with these field names. That is the fresh-VM
# smoke's job and it is signed for, not implied.
# ===========================================================================
STUB_ROOT=$(mktemp -d)

# DIVE-3592: the OWNER identity is per SERVER now — `_buzz_owner_key` reads and
# writes ${STATE_DIR}/buzz/owner.json and mirrors it per agent. The default
# /var/lib/5dive is root-owned, so an unprivileged harness that exercises `join`
# has to own a STATE_DIR of its own. Set AFTER the source on purpose: REGISTRY
# and friends are computed from STATE_DIR at source time and the seams below
# depend on those staying put; the owner path is read at CALL time.
STATE_DIR="$STUB_ROOT/state"
trap 'rc=$?; rm -rf "$STUB_ROOT"; echo "HARNESS-RC=$rc"' EXIT
STUB_BIN="$STUB_ROOT/buzz"

cat >"$STUB_BIN" <<'STUB'
#!/usr/bin/env bash
# Fake `buzz` — DIVE-3513 harness only. Keeps a channel/member store in
# $BUZZ_STUB_DIR and logs every invocation so the harness can assert on the
# CALLS as well as the outcome. $BUZZ_STUB_MODE is a comma list of defects to
# simulate.
set -u
D="${BUZZ_STUB_DIR:?stub needs BUZZ_STUB_DIR}"
M=",${BUZZ_STUB_MODE:-normal},"
has() { [[ "$M" == *",$1,"* ]]; }
# The log records ARGV and whether the key arrived through the environment. If
# the key ever appears here it is on argv, which is the thing the stdin hop
# exists to prevent — arm 8h asserts exactly that.
printf 'argv: %s\n' "$*" >>"$D/log"
printf 'env: relay=%s keylen=%s\n' "${BUZZ_RELAY_URL:-NONE}" "${#BUZZ_PRIVATE_KEY}" >>"$D/log"
touch "$D/channels" "$D/joined"

new_id() {
  if has shortid; then
    printf '%s' "$(( $(wc -l <"$D/channels") + 1 ))"
  else
    printf 'ch-%s-9f3b1c7a2e5d' "$1"
  fi
}
cid_of() { awk -F'\t' -v n="$1" '$2==n{print $1}' "$D/channels"; }
name_of() { awk -F'\t' -v c="$1" '$1==c{print $2}' "$D/channels"; }

json_channels() { # <file of cids, or empty for all>
  local first=1 line cid nm
  printf '['
  while IFS=$'\t' read -r cid nm; do
    [[ -n "${1:-}" ]] && ! grep -qxF "$cid" "$1" && continue
    ((first)) || printf ','
    first=0
    printf '{"channel_id":"%s","name":"%s"}' "$cid" "$nm"
  done <"$D/channels"
  printf ']\n'
}

grp="${1:-}"; shift || true
verb="${1:-}"; shift || true
# flags
#
# STRICTER THAN THE CALLER, ON PURPOSE. The first version of this stub ended its
# flag loop with `*) shift ;;` — it silently swallowed anything it had not been
# told to read, which makes it a SUPERSET of the real clap parser. A stub written
# by the same hand as the caller then encodes that hand's belief about the
# callee's ARGUMENT GRAMMAR, and no mutant can reach a belief the caller and the
# stub share: `channels list --format json` is a parse error on the real binary
# and the harness read 63/0 across it (quinn, DIVE-3513 iteration 2).
#
# So: an unrecognised argument is exit 64, the way clap exits non-zero on
# `unexpected argument '--format' found`. `--member` is the one bare flag the
# real parser accepts here and it is named explicitly rather than tolerated.
CH=""; NAME=""; PUB=""; MEMBER=0; AVATAR=""
while (($#)); do
  case "$1" in
    --channel) CH="$2"; shift 2 ;;
    --name)    NAME="$2"; shift 2 ;;
    --pubkey)  PUB="$2"; shift 2 ;;
    --member)  MEMBER=1; shift ;;
    --avatar)  AVATAR="$2"; shift 2 ;;
    --role|--type|--visibility|--about|--status) shift 2 ;;
    *) printf 'error: unexpected argument %s found\n' "$1" >&2; exit 64 ;;
  esac
done

case "$grp:$verb" in
  channels:list)
    if ((MEMBER)); then
      if has unparseable_member_list; then
        while IFS=$'\t' read -r c n; do
          grep -qxF "$c" "$D/joined" && printf 'channel %s  %s  (member) 11 messages\n' "$c" "$n"
        done <"$D/channels"
      else
        json_channels "$D/joined"
      fi
    else
      json_channels ""
    fi
    ;;
  channels:create)
    has nocreate && exit 0
    [[ -n "$(cid_of "$NAME")" ]] && exit 0
    printf '%s\t%s\n' "$(new_id "$NAME")" "$NAME" >>"$D/channels"
    ;;
  channels:join)
    [[ -n "$(name_of "$CH")" ]] || exit 1
    grep -qxF "$CH" "$D/joined" || printf '%s\n' "$CH" >>"$D/joined"
    ;;
  channels:add-member)
    [[ -n "$(name_of "$CH")" ]] || exit 1
    # `accepted:true` on a write that is not subsequently readable is the
    # DIVE-3507 defect; `dropmember` reproduces it exactly.
    has dropmember || { grep -qxF "$PUB" "$D/members-$CH" 2>/dev/null || printf '%s\n' "$PUB" >>"$D/members-$CH"; }
    printf '{"accepted":true}\n'
    ;;
  channels:members)
    printf '['
    first=1
    while read -r p; do ((first)) || printf ','; first=0; printf '{"pubkey":"%s"}' "$p"; done <"$D/members-$CH" 2>/dev/null
    printf ']\n'
    ;;
  users:set-profile)
    printf '%s' "$NAME" >"$D/profile"
    # kind:0 IS A REPLACING EVENT (DIVE-3625). A set-profile that carries no
    # --avatar does not leave the old picture standing — it erases it. Modelled
    # unconditionally, because a stub that preserved the picture would make the
    # ordering arms below pass against the very bug they exist to catch.
    printf '%s' "$AVATAR" >"$D/picture"
    printf '{"accepted":true}\n' ;;
  users:set-presence) touch "$D/presence"; printf '{"accepted":true}\n' ;;
  users:get)
    has noprofile && { printf '{}\n'; exit 0; }
    # An ARRAY, which is what the real binary answers — publish-profile.sh reads
    # `json.load(stdin)[0]`, so an object here would be a stub that is easier
    # than the caller.
    printf '[{"display_name":"%s","about":"","picture":"%s"}]\n' \
      "$(cat "$D/profile" 2>/dev/null)" "$(cat "$D/picture" 2>/dev/null)"
    ;;
  *) exit 64 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN"

# --- the shadows the fixture needs -----------------------------------------
# `sudo -u <agent>` becomes "run it as me", the state dir becomes a temp dir, and
# the registry becomes one fixture agent. Nothing about _buzz_join itself is
# stubbed: the function under test is the real one, unmodified.
sudo() {
  while (($#)); do
    case "$1" in
      -u) shift 2 ;;
      -H|-n) shift ;;
      *) break ;;
    esac
  done
  "$@"
}
ensure_state() { :; }
registry_read() { printf '%s' '{"agents":{"dev":{"type":"claude","channels":"buzz"}}}'; }
_buzz_state_dir() { printf '%s\n' "$AGENT_STATE"; }
# No binary anywhere except the one a config names — so the E_NOT_INSTALLED arm
# is a real absence, not a PATH accident.
_buzz_resolve_binary() { return 1; }

# Write the config `enable` writes, so join reads a real one.
seed_agent() { # <buzz_path> <channels-csv>
  AGENT_STATE=$(mktemp -d -p "$STUB_ROOT")
  BUZZ_STUB_DIR=$(mktemp -d -p "$STUB_ROOT")
  export BUZZ_STUB_DIR
  python3 - "$AGENT_STATE/config.json" "$1" "$2" <<'PY'
import json, sys
json.dump({"relay_url": "https://relay.example.com",
           "private_key": "3" * 63 + "7",
           "channels": [c for c in sys.argv[3].split(",") if c],
           "poll_ms": 15000,
           "buzz_path": sys.argv[2]}, open(sys.argv[1], "w"), indent=2)
PY
}

# Run the REAL _buzz_join in a subshell (it refuses with `fail`, which exits) and
# capture rc + everything it said.
run_join() { # <mode> [join args...]
  local mode="$1"; shift
  export BUZZ_STUB_MODE="$mode"
  JOIN_OUT=$( ( _buzz_join "$@" ) 2>&1 )
  JOIN_RC=$?
  return 0
}
stub_log() { cat "$BUZZ_STUB_DIR/log" 2>/dev/null; }

# --- 8a. the happy path: create-when-absent, join, add the customer ---------
seed_agent "$STUB_BIN" "general"
run_join normal dev
if [[ "$JOIN_RC" -eq 0 ]]; then ok_t "8a join returns 0 when every read-back confirms"; else
  bad_t "8a join returns 0 when every read-back confirms" "rc=$JOIN_RC; said: $JOIN_OUT"; fi
grep -q 'argv: channels create --name general' <<<"$(stub_log)" \
  && ok_t "8a a channel the relay does not have is CREATED" \
  || bad_t "8a a channel the relay does not have is CREATED" "no create call reached the relay: $(stub_log)"
OWNER_PUB=$(python3 -c "import json;print(json.load(open('$AGENT_STATE/owner.json'))['pubkey'])" 2>/dev/null)
[[ "$OWNER_PUB" =~ ^[0-9a-f]{64}$ ]] \
  && ok_t "8a owner.json holds a 64-hex customer pubkey" \
  || bad_t "8a owner.json holds a 64-hex customer pubkey" "got '$OWNER_PUB'"
grep -q "argv: channels add-member --channel .* --pubkey $OWNER_PUB --role owner" <<<"$(stub_log)" \
  && ok_t "8a the CUSTOMER's key is the one added as a member" \
  || bad_t "8a the CUSTOMER's key is the one added as a member" "add-member did not name owner.json's pubkey: $(stub_log)"
# ...and it is NOT the agent's own key. Transferring that would collapse the two
# identities and mention.ts:101 would drop every message as self-authored.
AGENT_PUB=$(printf '%s' "$(python3 -c "import json;print(json.load(open('$AGENT_STATE/config.json'))['private_key'])")" | _buzz_xonly_pubkey)
[[ -n "$AGENT_PUB" && "$OWNER_PUB" != "$AGENT_PUB" ]] \
  && ok_t "8a the customer identity is SECOND — not the agent's own pubkey" \
  || bad_t "8a the customer identity is SECOND — not the agent's own pubkey" "owner=$OWNER_PUB agent=$AGENT_PUB"
[[ "$(stat -c %a "$AGENT_STATE/owner.json")" == "600" ]] \
  && ok_t "8a owner.json is 0600" \
  || bad_t "8a owner.json is 0600" "mode $(stat -c %a "$AGENT_STATE/owner.json")"
# step 6 really ran
{ grep -q 'argv: users set-profile' <<<"$(stub_log)" && grep -q 'argv: users set-presence' <<<"$(stub_log)"; } \
  && ok_t "8a profile AND presence are published (step 6, DIVE-3507)" \
  || bad_t "8a profile AND presence are published (step 6, DIVE-3507)" "$(stub_log)"

# --- 8b. idempotence: a re-run neither recreates nor rotates ----------------
FIRST_PUB="$OWNER_PUB"
PREV_LOG="$BUZZ_STUB_DIR"
run_join normal dev
[[ "$(python3 -c "import json;print(json.load(open('$AGENT_STATE/owner.json'))['pubkey'])")" == "$FIRST_PUB" ]] \
  && ok_t "8b a re-run REUSES the customer key (a rotation loses the paired handset)" \
  || bad_t "8b a re-run REUSES the customer key" "the key rotated under a paired handset"
[[ "$(grep -c 'argv: channels create' "$PREV_LOG/log")" == "1" ]] \
  && ok_t "8b a channel that already exists is joined, not recreated" \
  || bad_t "8b a channel that already exists is joined, not recreated" "create ran $(grep -c 'argv: channels create' "$PREV_LOG/log") times"
[[ "$JOIN_RC" -eq 0 ]] && ok_t "8b the re-run is still rc 0" || bad_t "8b the re-run is still rc 0" "rc=$JOIN_RC"
# --rotate-owner-key is the explicit escape hatch, and must actually rotate.
run_join normal dev --rotate-owner-key
[[ "$(python3 -c "import json;print(json.load(open('$AGENT_STATE/owner.json'))['pubkey'])")" != "$FIRST_PUB" ]] \
  && ok_t "8b control: --rotate-owner-key DOES mint a new one" \
  || bad_t "8b control: --rotate-owner-key DOES mint a new one" "the reuse arm above proves nothing if rotate is a no-op"

# --- 8c. the comma-split loop wires EVERY channel ---------------------------
seed_agent "$STUB_BIN" "general,ops,alerts"
run_join normal dev
[[ "$JOIN_RC" -eq 0 ]] && ok_t "8c three channels from the config all wire" \
  || bad_t "8c three channels from the config all wire" "rc=$JOIN_RC; $JOIN_OUT"
[[ "$(grep -c 'argv: channels add-member' "$BUZZ_STUB_DIR/log")" == "3" ]] \
  && ok_t "8c the customer is added to all three, not just the first" \
  || bad_t "8c the customer is added to all three, not just the first" "add-member ran $(grep -c 'argv: channels add-member' "$BUZZ_STUB_DIR/log") times"
# --channels= overrides the config, and the loop tolerates spaces.
seed_agent "$STUB_BIN" "general"
run_join normal dev "--channels=ops, alerts"
[[ "$(grep -c 'argv: channels add-member' "$BUZZ_STUB_DIR/log")" == "2" ]] \
  && ok_t "8c --channels= overrides the config and tolerates spaces" \
  || bad_t "8c --channels= overrides the config and tolerates spaces" "$(stub_log)"

# --- 8d. the rc-3 partial wire — the arm the whole arc exists for ----------
# The relay ACCEPTS the member-add and does not show it on read-back. That is
# DIVE-3507's `accepted:true`, and it must NOT be reported as wired.
seed_agent "$STUB_BIN" "general"
run_join dropmember dev
[[ "$JOIN_RC" -eq 3 ]] \
  && ok_t "8d an accepted-but-unreadable member-add returns 3, not 0" \
  || bad_t "8d an accepted-but-unreadable member-add returns 3, not 0" "rc=$JOIN_RC — a surface reporting success while connected to nothing"
grep -q 'the customer as a member' <<<"$JOIN_OUT" \
  && ok_t "8d it says WHICH half of the read-back failed" \
  || bad_t "8d it says WHICH half of the read-back failed" "$JOIN_OUT"
# A relay that silently refuses to create is the same class.
seed_agent "$STUB_BIN" "general"
run_join nocreate dev
[[ "$JOIN_RC" -eq 3 ]] \
  && ok_t "8d a channel that is neither found nor created returns 3" \
  || bad_t "8d a channel that is neither found nor created returns 3" "rc=$JOIN_RC"
# And a profile write that does not read back is warned, not silently green.
seed_agent "$STUB_BIN" "general"
run_join noprofile dev
grep -q 'blank circle' <<<"$JOIN_OUT" \
  && ok_t "8d an unreadable profile write is warned (DIVE-3507)" \
  || bad_t "8d an unreadable profile write is warned" "$JOIN_OUT"

# --- 8e. the anchored read-back, END TO END --------------------------------
# A short-id relay whose member listing does not parse: under the iteration-1
# substring this returned 0. It must now be a partial wire.
seed_agent "$STUB_BIN" "general"
run_join shortid,unparseable_member_list dev
[[ "$JOIN_RC" -eq 3 ]] \
  && ok_t "8e short id + unparseable member listing is NOT reported as wired" \
  || bad_t "8e short id + unparseable member listing is NOT reported as wired" "rc=$JOIN_RC — the vacuous substring is still reachable through _buzz_join"
# Control: the same unparseable listing with the normal LONG ids still passes,
# so the anchoring did not simply red every relay whose format we don't know.
seed_agent "$STUB_BIN" "general"
run_join unparseable_member_list dev
[[ "$JOIN_RC" -eq 0 ]] \
  && ok_t "8e control: long id + unparseable listing still wires" \
  || bad_t "8e control: long id + unparseable listing still wires" "rc=$JOIN_RC; the fallback is dead and a listing-format change would red every join"
# Control: a short-id relay that DOES answer JSON is fine.
seed_agent "$STUB_BIN" "general"
run_join shortid dev
[[ "$JOIN_RC" -eq 0 ]] \
  && ok_t "8e control: a short-id relay answering JSON wires normally" \
  || bad_t "8e control: a short-id relay answering JSON wires normally" "rc=$JOIN_RC"

# --- 8f. no binary — the refusal, executed rather than grepped -------------
seed_agent "/nonexistent/buzz" "general"
run_join normal dev
[[ "$JOIN_RC" -eq "$E_NOT_INSTALLED" ]] \
  && ok_t "8f join REFUSES with E_NOT_INSTALLED when no buzz binary resolves" \
  || bad_t "8f join REFUSES with E_NOT_INSTALLED when no buzz binary resolves" "rc=$JOIN_RC (wanted $E_NOT_INSTALLED); $JOIN_OUT"
[[ ! -f "$AGENT_STATE/owner.json" ]] \
  && ok_t "8f it refuses BEFORE minting a key it cannot register" \
  || bad_t "8f it refuses BEFORE minting a key it cannot register" "owner.json exists for an agent that made no relay call"
# And with no config at all.
AGENT_STATE=$(mktemp -d -p "$STUB_ROOT")
run_join normal dev
[[ "$JOIN_RC" -eq "$E_VALIDATION" ]] \
  && ok_t "8f join refuses when \`enable\` has not written a config" \
  || bad_t "8f join refuses when \`enable\` has not written a config" "rc=$JOIN_RC"

# --- 8g. the envelope, from the REAL _buzz_owner ---------------------------
# Not a sed-lift of the encoder: the actual verb, over the actual owner.json.
seed_agent "$STUB_BIN" "general"
run_join normal dev
ENV_JSON=$( ( _buzz_owner dev --envelope ) 2>/dev/null )
ENV_RC=$?
[[ "$ENV_RC" -eq 0 ]] && ok_t "8g \`owner --envelope\` exits 0 after a join" \
  || bad_t "8g \`owner --envelope\` exits 0 after a join" "rc=$ENV_RC"
python3 - "$ENV_JSON" <<'PY' && ok_t "8g _buzz_owner --envelope emits exactly {relayUrl,pubkey,nsec}" \
  || bad_t "8g _buzz_owner --envelope emits exactly {relayUrl,pubkey,nsec}" "got: $ENV_JSON"
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {"relayUrl", "pubkey", "nsec"}, d
assert d["relayUrl"] == "https://relay.example.com", d
assert d["nsec"].startswith("nsec1") and len(d["nsec"]) == 63, d
assert len(d["pubkey"]) == 64, d
PY
# The nsec must be the bech32 of THIS agent's owner key — a hardcoded or stale
# one would still satisfy the shape check above.
python3 - "$ENV_JSON" "$AGENT_STATE/owner.json" <<'PY' && ok_t "8g the envelope's nsec is the bech32 of THIS owner.json's private key" \
  || bad_t "8g the envelope's nsec is the bech32 of THIS owner.json's private key" "the envelope does not correspond to the key that was added as a member"
import json, sys
env = json.loads(sys.argv[1]); own = json.load(open(sys.argv[2]))
CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
data = env["nsec"].split("1", 1)[1][:-6]
acc = bits = 0; out = bytearray()
for c in data:
    acc = (acc << 5) | CHARSET.index(c); bits += 5
    while bits >= 8:
        bits -= 8; out.append((acc >> bits) & 0xFF)
assert out.hex() == own["private_key"], (out.hex(), own["private_key"])
assert env["pubkey"] == own["pubkey"]
PY
# Default output is the PUBLIC half only — `5dive agent buzz` is an audited rail.
PUB_ONLY=$( ( _buzz_owner dev ) 2>/dev/null )
[[ "$PUB_ONLY" =~ ^[0-9a-f]{64}$ ]] \
  && ok_t "8g \`owner\` without --envelope prints the pubkey only" \
  || bad_t "8g \`owner\` without --envelope prints the pubkey only" "got '$PUB_ONLY'"
grep -qF "$(python3 -c "import json;print(json.load(open('$AGENT_STATE/owner.json'))['private_key'])")" <<<"$PUB_ONLY" \
  && bad_t "8g the default output does not leak the private key" "a private key was printed without --envelope" \
  || ok_t "8g the default output does not leak the private key"

# --- 8h. the key reached buzz through the ENVIRONMENT, never argv ----------
# Section 6 grades the source text. This grades the RUN: the stub records both
# its argv and the length of BUZZ_PRIVATE_KEY it received.
grep -q 'env: relay=https://relay.example.com keylen=64' <<<"$(stub_log)" \
  && ok_t "8h buzz received relay + a 64-char key through the environment" \
  || bad_t "8h buzz received relay + a 64-char key through the environment" "the stdin hop did not deliver: $(stub_log)"
grep -q '^argv:.*3333333333' <<<"$(stub_log)" \
  && bad_t "8h no private key on the executed argv" "the key appeared in the stub's argv — /proc/<pid>/cmdline is world-readable here" \
  || ok_t "8h no private key on the executed argv"

# ===========================================================================
# 8t-8w. DIVE-3625 — the enable path must INVOKE publish-profile.sh, and the
# invocation must be the LAST kind:0 write.
#
# The defect these grade is not "the call is missing". It is that the call was
# PRINTED, behind a guard on a path that exists on no box, so the room filled
# with faceless agents while every log said the last mile was green. The arms
# therefore assert on the RUN (did the publisher execute, in what order) and on
# the READ THAT FAILED (does `users get` come back with a picture) — never on
# the source text, which is what made the original defect invisible.
# ===========================================================================
PP_STUB="$STUB_ROOT/publish-profile.sh"
cat >"$PP_STUB" <<'PPS'
#!/usr/bin/env bash
# Fake publish-profile.sh. Stands in for the PLUGIN's tiered-art publisher: logs
# that it ran, then publishes name+about+avatar in ONE kind:0 the way the real
# one does. Calls a BARE `buzz` on purpose — the real script does, so this is
# also the arm that grades the caller putting the resolved binary on PATH.
set -u
printf 'publish-profile: %s\n' "$*" >>"${BUZZ_STUB_DIR}/log"
# The real script reads the SEAT's config (relay_url + private_key) and exports
# them — `buzz` is invoked with the identity in the environment, never on argv.
# Modelled here because it is what makes the bare `buzz` below resolvable at all.
eval "$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
print("export BUZZ_RELAY_URL=%s BUZZ_PRIVATE_KEY=%s" % (c["relay_url"], c["private_key"]))
' "${BUZZ_STUB_SEAT_CFG:?}")"
buzz users set-profile --name "${1:-seat}" --about "5dive agent ${1:-seat}" \
  --avatar "https://example.com/avatar/${1:-seat}.png" >/dev/null || exit 1
PPS
chmod +x "$PP_STUB"

# A publisher that runs and publishes NOTHING. The control for 8r: without it,
# a read-back arm that can only ever pass is not evidence.
PP_INERT="$STUB_ROOT/publish-profile-inert.sh"
printf '#!/usr/bin/env bash\nprintf "publish-profile: %%s\\n" "$*" >>"${BUZZ_STUB_DIR}/log"\nexit 0\n' >"$PP_INERT"
chmod +x "$PP_INERT"

# publish-profile.sh resolves the seat's config ITSELF, with its own
# `config_path()` (plugins/buzz/publish-profile.sh). If the two spellings ever
# drift, the publisher SKIPS the seat — "no buzz config" — and the last mile
# reports a green publish over an agent that was never touched.
# Source text, not a call: section 8 SHADOWS _buzz_state_dir with a temp dir so
# join can run unprivileged, so the live function is not reachable from here.
grep -q "/home/agent-%s/.claude/channels/buzz" "$SRC/cmd_agent_buzz.sh" \
  && ok_t "8t the CLI's buzz state dir is the path the plugin's publisher looks in" \
  || bad_t "8t the CLI's buzz state dir is the path the plugin's publisher looks in" \
           "the spelling moved; publish-profile.sh's own config_path() would skip the seat"

# --- 8t. it is INVOKED, not printed ----------------------------------------
seed_agent "$STUB_BIN" "general"
export BUZZ_PUBLISH_PROFILE="$PP_STUB" BUZZ_STUB_SEAT_CFG="$AGENT_STATE/config.json"
run_join normal dev
[[ "$JOIN_RC" -eq 0 ]] \
  && ok_t "8t join still returns 0 with the avatar publisher wired in" \
  || bad_t "8t join still returns 0 with the avatar publisher wired in" "rc=$JOIN_RC; $JOIN_OUT"
grep -q '^publish-profile: dev$' <<<"$(stub_log)" \
  && ok_t "8t publish-profile.sh is EXECUTED with the agent name (DIVE-3625)" \
  || bad_t "8t publish-profile.sh is EXECUTED with the agent name (DIVE-3625)" \
           "the last mile printed the remedy instead of running it — this is the shipped defect: $(stub_log)"
grep -q 'argv: users set-profile .*--avatar ' <<<"$(stub_log)" \
  && ok_t "8t a kind:0 carrying --avatar reached the relay" \
  || bad_t "8t a kind:0 carrying --avatar reached the relay" "$(stub_log)"

# --- 8u. THE ORDER, which is the actual trap -------------------------------
# kind:0 is replacing, so a pictureless set-profile AFTER the avatar publish
# ships the identical bug with a green log. The assertion is positional: the
# LAST set-profile the relay saw must be the one carrying --avatar.
LAST_SETPROF=$(grep '^argv: users set-profile' "$BUZZ_STUB_DIR/log" | tail -1)
[[ "$LAST_SETPROF" == *"--avatar "* ]] \
  && ok_t "8u the LAST kind:0 write of the last mile is the avatar one" \
  || bad_t "8u the LAST kind:0 write of the last mile is the avatar one" \
           "a pictureless set-profile ran after the avatar publish and erased it: '$LAST_SETPROF'"
# Control: the pictureless one really did run first, so the arm above is
# ordering evidence and not just "only one set-profile exists".
[[ "$(grep -c '^argv: users set-profile' "$BUZZ_STUB_DIR/log")" -ge 2 ]] \
  && ok_t "8u control: both kind:0 writes happened, so the order is what was graded" \
  || bad_t "8u control: both kind:0 writes happened" "only one set-profile in $(stub_log)"

# --- 8v. THE READ THAT FAILED ----------------------------------------------
# The row's acceptance, verbatim: `users get` returns a non-empty picture AFTER
# the full path has run. Graded through the last mile's own report.
grep -q "has a face: picture reads back as https://example.com/avatar/dev.png" <<<"$JOIN_OUT" \
  && ok_t "8v the last mile READS the picture back and says so" \
  || bad_t "8v the last mile READS the picture back and says so" "$JOIN_OUT"

seed_agent "$STUB_BIN" "general"
export BUZZ_PUBLISH_PROFILE="$PP_INERT"
run_join normal dev
grep -q "has NO picture on https://relay.example.com" <<<"$JOIN_OUT" \
  && ok_t "8v control: a publisher that publishes nothing is REPORTED, not passed" \
  || bad_t "8v control: a publisher that publishes nothing is REPORTED, not passed" \
           "the read-back reported success against an empty picture: $JOIN_OUT"
[[ "$JOIN_RC" -eq 0 ]] \
  && ok_t "8v a faceless profile is reported without failing the join" \
  || bad_t "8v a faceless profile is reported without failing the join" "rc=$JOIN_RC"

# --- 8w. the cold box: the plugin is not there yet (DIVE-3620) -------------
# The remedy printed here must be reachable FROM THIS STATE — naming
# publish-profile.sh would name a file the box does not have.
seed_agent "$STUB_BIN" "general"
export BUZZ_PUBLISH_PROFILE="$STUB_ROOT/does-not-exist.sh"
run_join normal dev
[[ "$JOIN_RC" -eq 0 ]] \
  && ok_t "8w a missing publisher does not break the last mile" \
  || bad_t "8w a missing publisher does not break the last mile" "rc=$JOIN_RC; $JOIN_OUT"
grep -q 'no publish-profile.sh in agent-dev' <<<"$JOIN_OUT" \
  && ok_t "8w the absence is REPORTED (the handset would show a blank circle)" \
  || bad_t "8w the absence is REPORTED" "$JOIN_OUT"
grep -q 'sudo 5dive agent buzz join dev' <<<"$JOIN_OUT" \
  && ok_t "8w the printed remedy is reachable from the state it fires in" \
  || bad_t "8w the printed remedy is reachable from the state it fires in" \
           "it names a command that cannot run on a box with no plugin cache: $JOIN_OUT"
unset BUZZ_PUBLISH_PROFILE

# The path the shipped code guarded on exists on no box — the cache is
# <cache>/5dive-plugins/<plugin>/<version>/. A regression back to it is silent,
# so it is named here.
grep -v '^[[:space:]]*#' "$JOINF" | grep -q 'cache/5dive-plugins/plugins/buzz' \
  && bad_t "8w the false hardcoded plugin path is gone" \
           "the guard is back on a path no box has; it can only ever be false" \
  || ok_t "8w the false hardcoded plugin path is gone"

# --- 8i. FINDING 2: `enable` actually CALLS the last mile -------------------
# The row's DONE MEANS is "ENABLING buzz for an agent JOINS the default channel
# set". Iteration 1 made the verb reachable and left the customer-visible flow
# unchanged — six wiring sites, still five. This runs the real _buzz_enable.
install_channel_for_agent() { printf 'install_channel_for_agent %s\n' "$*" >>"$BUZZ_STUB_DIR/log"; }
cmd_config() { printf 'cmd_config %s\n' "$*" >>"$BUZZ_STUB_DIR/log"; }
id() { [[ "${1:-}" == "-u" && -n "${2:-}" ]] && return 0; command id "$@"; }

seed_agent "$STUB_BIN" "general"
rm -f "$AGENT_STATE/config.json"   # enable writes it; join must not need one first
export BUZZ_STUB_MODE=normal
EN_OUT=$( ( _buzz_enable dev --relay=https://relay.example.com --channels=general --buzz-path="$STUB_BIN" ) 2>&1 )
EN_RC=$?
[[ "$EN_RC" -eq 0 ]] && ok_t "8i enable returns 0 when the whole chain wires" \
  || bad_t "8i enable returns 0 when the whole chain wires" "rc=$EN_RC; $EN_OUT"
grep -q 'argv: channels add-member' <<<"$(stub_log)" \
  && ok_t "8i ENABLE joined the channel and added the customer — six sites, not five" \
  || bad_t "8i ENABLE joined the channel and added the customer" "no relay call came out of enable; the verb exists and the customer-visible flow is unchanged (DIVE-3513 iteration 1)"
grep -q 'argv: users set-presence' <<<"$(stub_log)" \
  && ok_t "8i enable published profile + presence (step 6)" \
  || bad_t "8i enable published profile + presence (step 6)" "$(stub_log)"
[[ -f "$AGENT_STATE/owner.json" ]] \
  && ok_t "8i enable left a pairing envelope ready to hand out" \
  || bad_t "8i enable left a pairing envelope ready to hand out" "owner.json was never minted"
grep -q 'Neither is done by this command' <<<"$EN_OUT" \
  && bad_t "8i enable no longer tells the operator to go do steps 5 and 6" "the prose survived the change; it now contradicts the behaviour" \
  || ok_t "8i enable no longer tells the operator to go do steps 5 and 6"

# Control: --no-join keeps the old stop-at-4 behaviour, and SAYS so.
seed_agent "$STUB_BIN" "general"
rm -f "$AGENT_STATE/config.json"
EN_OUT=$( ( _buzz_enable dev --relay=https://relay.example.com --channels=general --buzz-path="$STUB_BIN" --no-join ) 2>&1 )
EN_RC=$?
{ [[ "$EN_RC" -eq 0 ]] && ! grep -q 'argv: channels' <<<"$(stub_log)"; } \
  && ok_t "8i control: --no-join makes NO relay call" \
  || bad_t "8i control: --no-join makes NO relay call" "rc=$EN_RC; $(stub_log)"
grep -q 'not yet reachable from a handset' <<<"$EN_OUT" \
  && ok_t "8i control: --no-join says the agent is not reachable yet" \
  || bad_t "8i control: --no-join says the agent is not reachable yet" "$EN_OUT"

# Control: no binary — enable still writes the identity, skips the last mile,
# and does not pretend. (This is the DIVE-3512 ordering.)
seed_agent "$STUB_BIN" "general"
rm -f "$AGENT_STATE/config.json"
EN_OUT=$( ( _buzz_enable dev --relay=https://relay.example.com --channels=general ) 2>&1 )
EN_RC=$?
{ [[ "$EN_RC" -eq 0 ]] && [[ -f "$AGENT_STATE/config.json" ]] && grep -q 'Last mile SKIPPED' <<<"$EN_OUT"; } \
  && ok_t "8i control: no binary -> config written, last mile skipped OUT LOUD" \
  || bad_t "8i control: no binary -> config written, last mile skipped OUT LOUD" "rc=$EN_RC; $EN_OUT"

# Control: enable PROPAGATES a partial wire instead of reporting success.
seed_agent "$STUB_BIN" "general"
rm -f "$AGENT_STATE/config.json"
export BUZZ_STUB_MODE=dropmember
EN_OUT=$( ( _buzz_enable dev --relay=https://relay.example.com --channels=general --buzz-path="$STUB_BIN" ) 2>&1 )
EN_RC=$?
[[ "$EN_RC" -eq 3 ]] \
  && ok_t "8i control: a partial wire comes back out of ENABLE as rc 3" \
  || bad_t "8i control: a partial wire comes back out of enable as rc 3" "rc=$EN_RC — enable reported success over a room the customer is not in"

# --- 8j. ARGV GRAMMAR: the stub is stricter than the caller ----------------
# The defect this section exists for: `channels list --format json` is a parse
# error on the real binary (`--format` is a top-level clap arg without
# global=true, so it is only legal LEFT of the subcommand), and iteration 2 read
# 63/0 straight across it — because the fake `buzz` was a bash case ending in
# `*) shift ;;`, which accepts a SUPERSET of the real grammar. A stub more
# permissive than the real parser cannot see an argv defect, and no mutant helps:
# the caller and the stub shared the belief.
#
# The stub now exits 64 on an unrecognised argument. First, prove that FIRES —
# an arm that only ever reads clean is not an arm.
seed_agent "$STUB_BIN" "general"
export BUZZ_STUB_MODE=normal
BUZZ_PRIVATE_KEY=deadbeef BUZZ_RELAY_URL=https://relay.example.com "$STUB_BIN" channels list --format json >/dev/null 2>&1 \
  && bad_t "8j control: the stub REJECTS an argument the real parser rejects" \
           "the stub accepted --format json; it is a superset of the real grammar and cannot see an argv defect" \
  || ok_t "8j control: the stub REJECTS an argument the real parser rejects"
BUZZ_PRIVATE_KEY=deadbeef BUZZ_RELAY_URL=https://relay.example.com "$STUB_BIN" channels list >/dev/null 2>&1 \
  && ok_t "8j control: and it still ACCEPTS the form the product actually sends" \
  || bad_t "8j control: and it still ACCEPTS the form the product actually sends" \
           "the strictness overshot; every join arm below is now vacuous"

# With a strict stub, the defect is simply a failing join.
seed_agent "$STUB_BIN" "general"
run_join normal dev
[[ "$JOIN_RC" -eq 0 ]] \
  && ok_t "8j every invocation _buzz_join makes is accepted by a strict parser" \
  || bad_t "8j every invocation _buzz_join makes is accepted by a strict parser" \
           "rc=$JOIN_RC — an argument the real binary would reject: $JOIN_OUT"

# The product must not carry the flag at all. json is ALREADY buzz's default
# output, so the fix is omission, not relocation — an arm on the source because
# a future maker adding it back is the whole failure mode.
# Comment lines are excluded deliberately: the file carries a block explaining
# why the flag must never come back, and grading the raw file text would make
# that explanation itself the failure. The predicate is EXECUTABLE lines.
grep -v '^[[:space:]]*#' "$JOINF" | grep -q -- '--format' \
  && bad_t "8j no --format on any subcommand in the product" \
           "--format is only legal LEFT of the subcommand; on a subcommand it is exit 1 user_error, the listing comes back empty, and join fails closed against a healthy relay" \
  || ok_t "8j no --format on any subcommand in the product"

# --- 8k. GRADED AGAINST THE REAL PARSER, when one is on this box -----------
# The residual signature said "no relay was contacted, so the wire format is the
# smoke's". That over-claimed: a parse error is decided BEFORE any socket opens,
# so argv grammar is gradeable offline TODAY against the real binary. user_error
# is grammar and ours; network_error is transport and the smoke's. Skipped, never
# faked, when no binary is present.
REAL_BUZZ=$(command -v buzz 2>/dev/null || true)
[[ -z "$REAL_BUZZ" && -x /usr/local/bin/buzz ]] && REAL_BUZZ=/usr/local/bin/buzz
if [[ -z "$REAL_BUZZ" ]]; then
  printf 'skip - 8k no `buzz` binary on this box; argv grammar not graded against the real parser\n'
else
  # A UUID, because the relay's channel_id is one — a short id is rejected by the
  # UUID parser as a user_error and would read as a grammar failure that is not.
  REAL_UUID=550e8400-e29b-41d4-a716-446655440000
  REAL_PK=f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9
  # A relay that cannot resolve: grammar is decided first, so anything that gets
  # as far as transport has parsed.
  grammar_ok() { # <buzz args...>
    local o
    o=$(BUZZ_RELAY_URL=https://relay.invalid.example.com \
        BUZZ_PRIVATE_KEY=$(printf '3%.0s' {1..63})7 \
        "$REAL_BUZZ" "$@" 2>&1)
    [[ "$o" != *'"user_error"'* ]]
  }
  # Every distinct invocation _buzz_join and _buzz_owner make.
  while IFS='|' read -r label args; do
    [[ -n "$label" ]] || continue
    # shellcheck disable=SC2086
    if grammar_ok $args; then
      ok_t "8k real parser accepts: $label"
    else
      bad_t "8k real parser accepts: $label" \
            "user_error from the real binary — this call fails before any socket opens"
    fi
  done <<REALGRAMMAR
channels list|channels list
channels list --member|channels list --member
channels create|channels create --name general --type stream --visibility open
channels join|channels join --channel $REAL_UUID
channels add-member|channels add-member --channel $REAL_UUID --pubkey $REAL_PK --role owner
channels members|channels members --channel $REAL_UUID
users set-profile|users set-profile --name dev --about 5dive-agent-dev
users get|users get
REALGRAMMAR
  # Control: the arm must be able to FAIL. The exact defect, against the real
  # parser — if this passes, `grammar_ok` is not detecting anything.
  grammar_ok channels list --format json \
    && bad_t "8k control: the real parser REJECTS \`channels list --format json\`" \
             "grammar_ok cannot detect a user_error; every 8k green above is meaningless" \
    || ok_t "8k control: the real parser REJECTS \`channels list --format json\`"
  # ...and the same flag LEFT of the subcommand parses, which is what makes it a
  # placement defect rather than an unknown flag.
  grammar_ok --format json channels list \
    && ok_t "8k control: the same flag LEFT of the subcommand parses (placement, not spelling)" \
    || bad_t "8k control: the same flag LEFT of the subcommand parses" \
             "then --format is not a global at all and this diagnosis is wrong"
fi

# ===========================================================================
# 8m. DIVE-3565 — THE WRITER MUST SPEAK THE READER'S LANGUAGE.
#
# plugins/buzz/server.ts:38 declares `channels: string[] // channel UUIDs to
# watch for mentions` and hands each entry to `buzz messages get --channel`.
# `enable` wrote NAMES there, so a fully-wired seat answered `invalid UUID:
# general` every tick, silently, forever (jolly-birch, DIVE-3559). These arms
# grade the WRITER against that reader: after a join, the field the poller reads
# must hold the ids the relay actually returned.
# ===========================================================================
cfg_json() { python3 -c "import json,sys;print(json.dumps(json.load(open('$AGENT_STATE/config.json'))))"; }
cfg_field() { python3 -c "
import json,sys
d=json.load(open('$AGENT_STATE/config.json'))
v=d.get(sys.argv[1])
print(','.join(str(x) for x in v) if isinstance(v,list) else ('' if v is None else v))
" "$1"; }
# The id the STUB minted, read out of its own store — derived independently of
# anything the CLI wrote, so the assertion is not comparing the code to itself.
stub_cid() { awk -F'\t' -v n="$1" '$2==n{print $1}' "$BUZZ_STUB_DIR/channels"; }

seed_agent "$STUB_BIN" "general"
run_join normal dev
REAL_CID=$(stub_cid general)
[[ -n "$REAL_CID" ]] \
  && ok_t "8m the stub minted a channel id for 'general' (fixture sanity)" \
  || bad_t "8m the stub minted a channel id for 'general'" "no id in the stub store; every arm below is vacuous"
[[ "$(cfg_field channels)" == "$REAL_CID" ]] \
  && ok_t "8m join writes the RESOLVED channel id into config.json .channels" \
  || bad_t "8m join writes the RESOLVED channel id into config.json .channels" \
           "the poller reads .channels as UUIDs; it holds '$(cfg_field channels)' and the relay's id is '$REAL_CID' — every tick will be 'invalid UUID'"
# The mutation this arm exists to catch: the pre-fix code left the NAME here,
# i.e. .channels was literally equal to .channel_names. NOT a substring test —
# a relay is free to build an id out of the name ("ch-general-9f3b…"), and that
# id is a perfectly good UUID-shaped answer.
{ [[ "$(cfg_field channels)" != "general" ]] && [[ "$(cfg_field channels)" != "$(cfg_field channel_names)" ]]; } \
  && ok_t "8m .channels is no longer just the channel NAME" \
  || bad_t "8m .channels is no longer just the channel NAME" ".channels == .channel_names == '$(cfg_field channels)' — nothing was resolved; this is the DIVE-3565 defect, unfixed"
[[ "$(cfg_field channel_names)" == "general" ]] \
  && ok_t "8m the human name is preserved in .channel_names" \
  || bad_t "8m the human name is preserved in .channel_names" "got '$(cfg_field channel_names)' — join has no name to look up on a re-run"
# Nothing else in the config may move: this file holds the agent's identity.
[[ "$(cfg_field private_key)" == "$(printf '3%.0s' $(seq 63))7" ]] \
  && ok_t "8m the writeback does not disturb private_key" \
  || bad_t "8m the writeback does not disturb private_key" "identity changed under a config edit"
{ [[ "$(cfg_field relay_url)" == "https://relay.example.com" ]] && [[ "$(cfg_field poll_ms)" == "15000" ]] \
  && [[ "$(cfg_field buzz_path)" == "$STUB_BIN" ]]; } \
  && ok_t "8m relay_url, poll_ms and buzz_path survive the writeback" \
  || bad_t "8m relay_url, poll_ms and buzz_path survive the writeback" "$(cfg_json)"
[[ "$(stat -c %a "$AGENT_STATE/config.json")" == "600" ]] \
  && ok_t "8m config.json is still 0600 after the writeback" \
  || bad_t "8m config.json is still 0600 after the writeback" "mode $(stat -c %a "$AGENT_STATE/config.json")"

# --- 8n. the regression the fix could introduce ----------------------------
# Now that .channels holds a uuid, a re-run must resolve it to ITSELF. If it
# treated it as a name it would create a second channel literally named after
# the uuid and the customer's room would silently fork.
CREATES_BEFORE=$(grep -c 'argv: channels create' "$BUZZ_STUB_DIR/log")
run_join normal dev
[[ "$(grep -c 'argv: channels create' "$BUZZ_STUB_DIR/log")" == "$CREATES_BEFORE" ]] \
  && ok_t "8n a re-run over an id-bearing config creates NOTHING" \
  || bad_t "8n a re-run over an id-bearing config creates NOTHING" \
           "the writeback made join non-idempotent: $(grep 'argv: channels create' "$BUZZ_STUB_DIR/log")"
[[ "$JOIN_RC" -eq 0 && "$(cfg_field channels)" == "$REAL_CID" ]] \
  && ok_t "8n the re-run is rc 0 and the id is unchanged" \
  || bad_t "8n the re-run is rc 0 and the id is unchanged" "rc=$JOIN_RC ids=$(cfg_field channels)"
# Control: the resolver must still find a channel by NAME, or 8n passes because
# nothing resolves at all.
[[ "$(_buzz_channel_ref_id general <<<"[{\"channel_id\":\"$REAL_CID\",\"name\":\"general\"}]")" == "$REAL_CID" ]] \
  && ok_t "8n control: the resolver still resolves a NAME to its id" \
  || bad_t "8n control: the resolver still resolves a NAME to its id" "name lookup broke; 8n is vacuous"
[[ -z "$(_buzz_channel_ref_id nosuch <<<"[{\"channel_id\":\"$REAL_CID\",\"name\":\"general\"}]")" ]] \
  && ok_t "8n control: an unknown token resolves to NOTHING (it does not echo itself)" \
  || bad_t "8n control: an unknown token resolves to NOTHING" "the resolver returns its input, so every id 'resolves' and create never fires"

# The arm above re-runs join over an id-BEARING config, but that config also
# carries `channel_names`, and the new precedence reads names FIRST — so the id
# never reaches the resolver and 8n is named for the ID path while measuring the
# NAME path (quinn, iteration 1). This is the route that actually walks it:
# `--channels=<uuid>` is an explicit id, `from_ids` stays false, and without the
# id-to-itself branch the resolver returns nothing and join CREATES a channel
# literally named after a uuid — the silent second room. Graded by the create
# count in the stub's own log, not by anything the CLI reports.
CREATES_BEFORE_ID=$(grep -c 'argv: channels create' "$BUZZ_STUB_DIR/log")
run_join normal dev --channels="$REAL_CID"
[[ "$(grep -c 'argv: channels create' "$BUZZ_STUB_DIR/log")" == "$CREATES_BEFORE_ID" ]] \
  && ok_t "8n an explicit --channels=<uuid> resolves to ITSELF and creates NOTHING" \
  || bad_t "8n an explicit --channels=<uuid> resolves to ITSELF and creates NOTHING" \
           "join created a channel named after a uuid — the customer's room forked: $(grep 'argv: channels create' "$BUZZ_STUB_DIR/log" | tail -1)"

# --- 8o. only a CONFIRMED membership is recorded ---------------------------
# rc=3 is the accepted-but-not-readable case (DIVE-3507). Recording that id
# would tell the poller to watch a room the agent is not in — success reported
# while connected to nothing, one layer further down.
# Seeded in the POST-fix shape (names in .channel_names, .channels empty) —
# that is what `enable` now writes, and the question is whether a failed join
# fills it in anyway.
seed_agent "$STUB_BIN" "general"
python3 -c "
import json
p='$AGENT_STATE/config.json'
d=json.load(open(p)); d['channel_names']=d.pop('channels'); d['channels']=[]
json.dump(d, open(p,'w'), indent=2)
"
run_join dropmember dev
{ [[ "$JOIN_RC" -eq 3 ]] && [[ -z "$(cfg_field channels)" ]]; } \
  && ok_t "8o an unconfirmed join records NO channel id" \
  || bad_t "8o an unconfirmed join records NO channel id" "rc=$JOIN_RC ids='$(cfg_field channels)' — the poller would watch an unjoined room"
# Control: the SAME seed with a relay that confirms DOES get an id written, or
# the arm above passes because the writeback never fires at all.
seed_agent "$STUB_BIN" "general"
python3 -c "
import json
p='$AGENT_STATE/config.json'
d=json.load(open(p)); d['channel_names']=d.pop('channels'); d['channels']=[]
json.dump(d, open(p,'w'), indent=2)
"
run_join normal dev
{ [[ "$JOIN_RC" -eq 0 ]] && [[ "$(cfg_field channels)" == "$(stub_cid general)" ]]; } \
  && ok_t "8o control: a CONFIRMED join over the same seed does record the id" \
  || bad_t "8o control: a CONFIRMED join over the same seed does record the id" "rc=$JOIN_RC ids='$(cfg_field channels)'; 8o is vacuous"

# --- 8p. `enable` writes a config the reader can use, or an empty one ------
# Not names-in-.channels. The honest state before resolution is EMPTY: the
# poller watches nothing and says nothing, instead of erroring every 15s.
seed_agent "$STUB_BIN" "general"
rm -f "$AGENT_STATE/config.json"
_buzz_write_config "$(id -un)" "$AGENT_STATE" "https://relay.example.com" "$(printf '3%.0s' $(seq 63))7" "general,ops" 15000 "$STUB_BIN" >/dev/null 2>&1
{ [[ "$(cfg_field channel_names)" == "general,ops" ]] && [[ -z "$(cfg_field channels)" ]]; } \
  && ok_t "8p enable writes names to .channel_names and leaves .channels EMPTY (never a name)" \
  || bad_t "8p enable writes names to .channel_names and leaves .channels EMPTY" \
           "names='$(cfg_field channel_names)' ids='$(cfg_field channels)' — a name in .channels is the DIVE-3565 defect"
# ...and a re-run of enable must not throw away ids join already resolved, since
# enable CALLS join and a re-enable is the ordinary repair command.
_buzz_set_channel_ids "$(id -un)" "$AGENT_STATE/config.json" "id-1,id-2" "general,ops" >/dev/null 2>&1
_buzz_write_config "$(id -un)" "$AGENT_STATE" "https://relay.example.com" "$(printf '3%.0s' $(seq 63))7" "general,ops" 15000 "$STUB_BIN" >/dev/null 2>&1
[[ "$(cfg_field channels)" == "id-1,id-2" ]] \
  && ok_t "8p re-running enable with the SAME names keeps the resolved ids" \
  || bad_t "8p re-running enable with the SAME names keeps the resolved ids" \
           "got '$(cfg_field channels)' — a re-enable would take a working seat back to silent"
# Control: a DIFFERENT name list makes the old ids the wrong answer, not a stale
# one, so they must be dropped.
_buzz_write_config "$(id -un)" "$AGENT_STATE" "https://relay.example.com" "$(printf '3%.0s' $(seq 63))7" "alerts" 15000 "$STUB_BIN" >/dev/null 2>&1
{ [[ -z "$(cfg_field channels)" ]] && [[ "$(cfg_field channel_names)" == "alerts" ]]; } \
  && ok_t "8p control: changing the names DROPS the stale ids" \
  || bad_t "8p control: changing the names DROPS the stale ids" "ids='$(cfg_field channels)' point at rooms that are no longer configured"

# --- 8q. a legacy config (names in .channels, no .channel_names) still wires
# Every already-provisioned seat looks like this. It must be REPAIRED by a plain
# `join`, not refused — the key is the ABSENCE of the .channel_names key.
seed_agent "$STUB_BIN" "general"   # seed_agent writes the legacy shape
python3 -c "
import json,sys
d=json.load(open('$AGENT_STATE/config.json'))
assert 'channel_names' not in d, 'fixture is not the legacy shape'
assert d['channels'] == ['general'], d
" && ok_t "8q fixture sanity: the seed IS the legacy name-in-.channels shape" \
   || bad_t "8q fixture sanity: the seed IS the legacy shape" "the arm below proves nothing"
run_join normal dev
LEG_CID=$(stub_cid general)
{ [[ "$JOIN_RC" -eq 0 ]] && [[ "$(cfg_field channels)" == "$LEG_CID" ]] && [[ "$(cfg_field channel_names)" == "general" ]]; } \
  && ok_t "8q a legacy config is REPAIRED in place by one \`buzz join\`" \
  || bad_t "8q a legacy config is REPAIRED in place by one \`buzz join\`" \
           "rc=$JOIN_RC ids='$(cfg_field channels)' names='$(cfg_field channel_names)' — every existing seat stays silent"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
