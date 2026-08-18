#!/usr/bin/env bash
# DIVE-3592 unit harness — pairing is per SERVER, not per agent.
#
# What this grades without a relay, a phone, or root:
#
#   1. src/cmd_buzz.sh is CONCATENATED into the bundle (the buzz_channel_wiring
#      failure mode: a file that exists and is never bundled is "command not
#      found" in the shipped binary), dispatched, and in the usage text
#   2. `agent buzz pair` is on the LOCK-FREE side of the dispatch — a 600s
#      pairing session must not hold the fleet-wide registry lock
#   3. ONE IDENTITY PER BOX: _buzz_owner_key returns the same key for two
#      different agents, and mirrors it into both state dirs
#   4. ADOPTION, not a fresh mint: an agent that already holds an owner key
#      (a handset paired before this row) becomes the server identity. Minting
#      a new one would evict that handset from every room while every surface
#      still reported success — so this arm is the eviction guard
#   5. the wire-up runs for EVERY buzz agent, not just the session host (a
#      handset that is not a member cannot see the channel at all, DIVE-3331)
#   6. REFUSALS ARE RESULTS: no buzz agent, and wire-up-wired-nothing, both
#      print `BUZZ-PAIR-RESULT: fail …` and exit NON-ZERO, and neither reaches
#      the pairing session. The panel reads a PTY, where the exit status it can
#      see is the shell's — a silent refusal is indistinguishable from success
#
# Run: bash tests/buzz_server_pairing_unit.sh   (no root, no network, no relay.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz_join.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz_pair.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_buzz.sh"
set +e  # header.sh enables set -e; the arms below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- 1. bundled, dispatched, documented --------------------------------------
grep -q '^  src/cmd_buzz\.sh \\$' build.sh \
  && ok_t "build.sh concatenates cmd_buzz.sh" \
  || bad_t "build.sh concatenates cmd_buzz.sh" \
           "present but never concatenated — \`5dive buzz pair\` would be 'command not found' in the built bundle"
grep -qE '^\s+buzz\)' "$SRC/main.sh" \
  && ok_t "main.sh has a top-level 'buzz' verb" \
  || bad_t "main.sh has a top-level 'buzz' verb" "the verb is unreachable"
grep -q 'cmd_buzz "\$@"' "$SRC/main.sh" \
  && ok_t "main.sh dispatches cmd_buzz" || bad_t "main.sh dispatches cmd_buzz" "unreachable"
grep -q '5dive buzz pair' "$SRC/main.sh" \
  && ok_t "usage text names '5dive buzz pair'" || bad_t "usage text names '5dive buzz pair'" "undiscoverable"

# --- 2. the pairing session does not hold the fleet lock ---------------------
if grep -q '"${1:-}" == "inbound" || "${1:-}" == "pair"' "$SRC/main.sh"; then
  ok_t "agent buzz pair is dispatched WITHOUT with_registry_lock"
else
  bad_t "agent buzz pair is dispatched WITHOUT with_registry_lock" \
        "a 600s pairing session would hold the fleet-wide registry lock for its whole width"
fi

# --- harness seams -----------------------------------------------------------
TMP=$(mktemp -d)
# DIVE-2692: ONE EXIT trap — bash has a single slot, so the tempdir cleanup folds
# into the HARNESS-RC line rather than replacing it (a replaced trap prints no
# marker, and a harness killed mid-run then reads exactly like a pass).
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
# Every sudo hop collapses onto this user: the harness owns the files it writes,
# and the DIVE-3096 isolation layer refuses a real sudo inside a harness anyway.
sudo() {
  while (($#)); do case "$1" in -u) shift 2 ;; -H) shift ;; *) break ;; esac; done
  "$@"
}
_buzz_state_dir() { printf '%s/home/%s\n' "$TMP" "$1"; }
AGENTS_OUT=$'alpha\nbeta\n'
_buzz_enabled_agents() { printf '%s' "$AGENTS_OUT"; }

# --- 3. one identity per box -------------------------------------------------
KA=$(_buzz_owner_key alpha "$(id -un)" 2>/dev/null)
KB=$(_buzz_owner_key beta  "$(id -un)" 2>/dev/null)
if [[ "$KA" =~ ^[0-9a-f]{64}$ && "$KA" == "$KB" ]]; then
  ok_t "two agents hand out ONE owner key (the picker is now a choice about nothing)"
else
  bad_t "two agents hand out ONE owner key" "alpha=${KA:0:12}… beta=${KB:0:12}…"
fi
[[ -f "$STATE_DIR/buzz/owner.json" ]] \
  && ok_t "the owner identity is written at the SERVER level (\$STATE_DIR/buzz/owner.json)" \
  || bad_t "the owner identity is written at the SERVER level" "no $STATE_DIR/buzz/owner.json"
MIRROR=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['private_key'])" \
  "$TMP/home/alpha/owner.json" 2>/dev/null)
[[ "$MIRROR" == "$KA" ]] \
  && ok_t "the agent's owner.json is a MIRROR of the server key" \
  || bad_t "the agent's owner.json is a MIRROR of the server key" "mirror=${MIRROR:0:12}… server=${KA:0:12}…"
PERM=$(stat -c '%a' "$STATE_DIR/buzz/owner.json" 2>/dev/null)
[[ "$PERM" == "600" ]] && ok_t "the server owner key is 0600" \
  || bad_t "the server owner key is 0600" "mode=$PERM"
K2=$(_buzz_owner_key alpha "$(id -un)" 2>/dev/null)
[[ "$K2" == "$KA" ]] && ok_t "a re-run does NOT rotate the paired handset's key" \
  || bad_t "a re-run does NOT rotate the paired handset's key" "the handset would silently lose every room"

# --- 4. adoption beats minting ----------------------------------------------
rm -rf "$STATE_DIR/buzz" "$TMP/home"
PRE=$(openssl rand -hex 32)
mkdir -p "$TMP/home/beta"
python3 -c "
import json,sys
json.dump({'private_key': sys.argv[1], 'role': 'owner'}, open(sys.argv[2],'w'))
" "$PRE" "$TMP/home/beta/owner.json"
ADOPTED=$(_buzz_server_owner_key 2>/dev/null)
[[ "$ADOPTED" == "$PRE" ]] \
  && ok_t "an owner key minted before DIVE-3592 is ADOPTED, not replaced" \
  || bad_t "an owner key minted before DIVE-3592 is ADOPTED, not replaced" \
           "a handset paired tonight would be evicted from every room; got ${ADOPTED:0:12}… want ${PRE:0:12}…"
ROT=$(_buzz_server_owner_key true 2>/dev/null)
[[ "$ROT" =~ ^[0-9a-f]{64}$ && "$ROT" != "$PRE" ]] \
  && ok_t "rotate=true still mints a new identity (the explicit escape hatch)" \
  || bad_t "rotate=true still mints a new identity" "got ${ROT:0:12}…"

# --- 5 + 6. the server pair verb --------------------------------------------
ensure_state() { :; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
JOINED="$TMP/joined"; PAIRED="$TMP/paired"
_buzz_join() { printf '%s\n' "$1" >>"$JOINED"; return "${JOIN_RC:-0}"; }
_buzz_pair() { printf '%s\n' "$1" >>"$PAIRED"; return 0; }

: >"$JOINED"; : >"$PAIRED"
OUT=$( _buzz_server_pair --timeout=5 2>&1 ); RC=$?
if ((RC == 0)) && [[ "$(sort -u "$JOINED" | tr '\n' ' ')" == "alpha beta " ]]; then
  ok_t "the wire-up runs for EVERY buzz agent, not just the session host"
else
  bad_t "the wire-up runs for EVERY buzz agent" "rc=$RC joined='$(tr '\n' ' ' <"$JOINED")'"
fi
[[ $(wc -l <"$PAIRED") -eq 1 ]] \
  && ok_t "exactly one pairing session is opened (one QR, one identity)" \
  || bad_t "exactly one pairing session is opened" "$(wc -l <"$PAIRED") sessions"

# no buzz agent at all
AGENTS_OUT=""
OUT=$( _buzz_server_pair 2>&1 ); RC=$?
grep -q '^BUZZ-PAIR-RESULT: fail ' <<<"$OUT" \
  && ok_t "no buzz agent: prints the terminal fail marker" \
  || bad_t "no buzz agent: prints the terminal fail marker" \
           "the panel reads a PTY and cannot see an exit code — a silent refusal reads as success. got: $OUT"
((RC != 0)) && ok_t "no buzz agent: exits NON-ZERO" \
  || bad_t "no buzz agent: exits NON-ZERO" "rc=$RC — an error: line with rc 0 is the DIVE-3592 defect"

# every join failed: the owner is in no channel, so pairing must not happen
AGENTS_OUT=$'alpha\nbeta\n'; JOIN_RC=1
: >"$PAIRED"
OUT=$( _buzz_server_pair 2>&1 ); RC=$?
grep -q '^BUZZ-PAIR-RESULT: fail ' <<<"$OUT" && ((RC != 0)) \
  && ok_t "zero channels wired: refuses with a marker and a non-zero rc" \
  || bad_t "zero channels wired: refuses with a marker and a non-zero rc" "rc=$RC out=$OUT"
[[ ! -s "$PAIRED" ]] \
  && ok_t "zero channels wired: no pairing session is opened" \
  || bad_t "zero channels wired: no pairing session is opened" \
           "the handset would have been handed an identity that opens an empty app"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
