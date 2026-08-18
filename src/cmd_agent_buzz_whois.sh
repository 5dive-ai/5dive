#!/usr/bin/env bash
# DIVE-3572 — buzz IDENTITY in the registry, and the lookup that reads it back.
#
# WHY THIS EXISTS. The buzz trust model (DIVE-3569, ratified by lodar 2026-08-18,
# community/wiki/the-trust-decision-does-not-live-in-the-plugin-it-rides-the-
# 5dive-layer.md) re-classifies an inbound channel event by WHOSE KEY SIGNED IT:
# the owner's paired handset key routes like a paired human, a known teammate's
# key is delivered on the existing a2a rail, an unknown key stays untrusted data.
# Every one of those branches needs one answer the fleet could not give:
#
#   pubkey -> which seat?
#
# Measured on this host 2026-08-18 (olivia, DIVE-3569): /var/lib/5dive/agents.json
# contained ZERO occurrences of `pubkey` or `npub`. A seat's buzz identity existed
# only as a PRIVATE key in its own ~/.claude/channels/buzz/config.json (0600,
# agent-owned) and the paired handset key only in that seat's owner.json. Nothing
# on the box could map a key to a name.
#
# WHY THE PLUGIN CANNOT DO THIS ITSELF. plugins/buzz/server.ts runs AS the agent,
# so the only pubkey it can derive is its own; it has no privileged read of any
# other seat's 0600 config, and it must not get one. The answer has to come from a
# host-side source it shells to. So: the CLI is the SINGLE WRITER, the registry is
# the SINGLE STORE, and `whois` is the read the plugin makes
# ([[the-writer-wrote-names-the-reader-polled-uuids-and-both-sides-were-green]] —
# DIVE-3565's lesson is grade the writer against the READER, and keep one writer).
#
# THE PUBLIC HALF ONLY. Nothing here ever reads, moves or records a private key.
# `enable` and `join` already hold the secret to derive from; this file records
# the x-only pubkey they hand it, which is exactly what the relay publishes and
# what any member of the room can already see. A registry that is group-readable
# by `claude` therefore leaks nothing that the channel does not.

# ---------------------------------------------------------------------------
# THE WRITER
# ---------------------------------------------------------------------------
# _buzz_registry_record <name> <pubkey|owner_pubkey> <64-hex>
#
# Idempotent, and it REFUSES rather than records junk: a registry holding a
# malformed key is worse than one holding none, because `whois` would then answer
# "unknown" for a seat that IS wired and the bridge would silently drop a
# teammate into the untrusted class. Writes only the named field, so recording an
# owner key never disturbs the agent key and vice versa.
#
# Callers hold the registry lock already (main.sh wraps every mutating `agent
# buzz` verb in with_registry_lock), and with_registry_lock is re-entrant.
_buzz_registry_record() {
  local name="$1" field="$2" value="$3"
  case "$field" in
    pubkey|owner_pubkey) : ;;
    *) warn "buzz identity: refusing to record unknown field '$field'"; return 1 ;;
  esac
  if [[ ! "$value" =~ ^[0-9a-fA-F]{64}$ ]]; then
    warn "buzz identity: refusing to record a malformed $field for '$name' (not 64 hex chars) — \`5dive agent buzz whois\` would answer 'unknown' for a seat that is wired"
    return 1
  fi
  # Lowercase on the way in, so the STORE holds one spelling of a key. The relay
  # and the plugin both render x-only keys in lowercase hex, but a copy-pasted or
  # hand-typed one can arrive mixed-case. The reader downcases too — a registry
  # can be hand-edited, and this writer is not the only way bytes get into that
  # file — so this is belt AND braces on purpose, not the sole guard: dropping it
  # leaves whois correct and leaves the file inconsistent for every other jq
  # consumer. tests/buzz_identity_registry_unit.sh grades the two independently.
  value="${value,,}"
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null || {
    warn "buzz identity: no agent named '$name' in the registry — nothing recorded"
    return 1
  }
  # The pipeline's rc is taken EXPLICITLY. A trailing `step` returns 0, so a
  # registry_write that failed would be reported by this function as a successful
  # record — the callers branch on that rc to decide whether to warn the operator
  # that whois will call this seat unknown, and a write failure is precisely when
  # they must.
  local wrc=0
  { jq --arg n "$name" --arg f "$field" --arg v "$value" \
      '.agents[$n].buzz = ((.agents[$n].buzz // {}) + {($f): $v})' <<<"$reg" \
    | registry_write; } || wrc=$?
  ((wrc == 0)) || { warn "buzz identity: writing buzz.$field for '$name' to the registry FAILED (rc=$wrc)"; return "$wrc"; }
  step "Recorded buzz.$field for '$name' in the registry (${value:0:16}…)"
}

# ---------------------------------------------------------------------------
# npub -> x-only hex
#
# The lookup's callers do not all speak the same spelling. The plugin derives and
# compares 64-char hex (schnorr x-only, server.ts), while a handset, a QR and
# `5dive human add --buzz=<npub>` all show the bech32 `npub1…` form of the SAME
# 32 bytes. Accepting only one of them would make half the operators' copy-pastes
# read as "unknown key" — the answer that, in this trust model, means "do not
# trust". So decode, and decode STRICTLY: a bad checksum is refused, never
# silently truncated into a lookup that then misses.
# ---------------------------------------------------------------------------
_BUZZ_NPUB_DECODE_PY='
import sys
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk
def hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]
s = sys.stdin.read().strip()
if s.lower() != s and s.upper() != s:
    sys.exit("mixed case")
s = s.lower()
pos = s.rfind("1")
if pos < 1 or pos + 7 > len(s):
    sys.exit("not bech32")
hrp, data = s[:pos], s[pos+1:]
if hrp != "npub":
    sys.exit("not an npub")
try:
    dec = [CHARSET.index(c) for c in data]
except ValueError:
    sys.exit("bad bech32 character")
if polymod(hrp_expand(hrp) + dec) != 1:
    sys.exit("bad checksum")
acc = bits = 0
out = bytearray()
for v in dec[:-6]:
    acc = (acc << 5) | v
    bits += 5
    if bits >= 8:
        bits -= 8
        out.append((acc >> bits) & 0xff)
if bits >= 5 or (acc << (8 - bits)) & 0xff:
    sys.exit("bad padding")
if len(out) != 32:
    sys.exit("npub payload is not 32 bytes")
print(out.hex())
'
_buzz_npub_to_hex() { python3 -c "$_BUZZ_NPUB_DECODE_PY"; }

# ---------------------------------------------------------------------------
# THE READER
# ---------------------------------------------------------------------------
# 5dive agent buzz whois <pubkey|npub1…> [--role]
#
# Read-only, and deliberately runnable WITHOUT root: the plugin runs as the agent
# user, and it is the caller this verb exists for. It therefore never calls
# ensure_state (which is require_root) and never takes the registry lock — it
# reads the group-readable registry directly. main.sh routes it the way it routes
# `status`: no lock, no audit.
#
# EXIT CODES, AND THE ONE THE ROW ASKED US TO DECIDE.
#
#   0   FOUND        — the seat name is on stdout (with --role: "<name> <role>")
#   3   VALIDATION   — the argument is not an x-only pubkey or a decodable npub;
#                      refused before any read, so it can never be mistaken for
#                      an answer about a key
#   4   NOT_FOUND    — MEASURED absence. The registry was present, readable and
#                      parsed, and no seat holds that key. THIS, and only this,
#                      means "unknown key" — the input to the untrusted branch.
#   5   CONFLICT     — two or more seats record the same key. Ambiguous, so no
#                      name is printed: picking one would hand the bridge a
#                      teammate identity that is not provably that teammate.
#   1   GENERIC      — NOT MEASURED. The registry is absent, unreadable or
#                      unparseable, so no verdict about the key is possible. The
#                      reason token is on stderr.
#
# rc=4 and rc=1 are SEPARATE ON PURPOSE, and this is the whole of the row's
# "decide and document" clause. registry_read() collapses "no registry yet", "I
# could not read it" and "the fleet is genuinely empty" onto one empty-but-valid
# body, so a caller built on it would read a permission failure as "this key
# belongs to nobody". In this trust model that collapse is not cosmetic: it
# converts a box-level fault into a silent, fleet-wide DEMOTION of every teammate
# to the untrusted class — the failure is invisible precisely because untrusted
# is also the correct answer for a real stranger. So this uses
# registry_read_checked (src/lib/registry.sh), which never invents a body, and it
# is the caller's job to treat rc=1 as "ask again later", not as "stranger".
# Same property as DIVE-2210's `unknown:<reason>` tiers: we-could-not-check must
# never be spelled like we-checked-and-it-was-fine.
# _buzz_whois_no <exit-code> <reason-token> — every non-answer, in one shape.
#
# stdout stays EMPTY on every one of them (the row's contract: "empty/non-zero on
# unknown"), the reason token goes to stderr where a shell caller can branch on
# it, and JSON callers get the same token in an error object rather than prose
# they would have to parse. mark_reported is not optional: these are by-design
# non-zero exits, and without it lib/output.sh's EXIT backstop staples "this is a
# bug in the CLI ... its effect is UNKNOWN" under an answer that is correct and
# complete (DIVE-3558, the same fix `status` needed for its rc=3).
_buzz_whois_no() {
  local code="$1" token="$2"
  if (( JSON_MODE )); then
    jq -cn --argjson c "$code" --arg cl "$(err_class_for "$code")" --arg m "$token" \
      '{ok:false, error:{code:$c, class:$cl, message:$m}}'
  fi
  printf 'whois: %s\n' "$token" >&2
  mark_reported
  return "$code"
}

_buzz_whois() {
  local want="" show_role="false"
  while (($#)); do
    case "$1" in
      --role) show_role="true" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$want" ]] && want="$1" || fail "$E_USAGE" "unexpected argument: $1" ;;
    esac
    shift
  done
  [[ -n "$want" ]] || fail "$E_USAGE" "usage: 5dive agent buzz whois <pubkey|npub1…> [--role]"

  local key=""
  if [[ "$want" =~ ^[0-9a-fA-F]{64}$ ]]; then
    key="${want,,}"
  elif [[ "${want:0:5}" == "npub1" || "${want:0:5}" == "NPUB1" ]]; then
    key=$(printf '%s' "$want" | _buzz_npub_to_hex 2>/dev/null) \
      || fail "$E_VALIDATION" "not a decodable npub (checksum, character set or payload length) — refusing to look up a key we could not decode, because a truncated lookup would answer 'unknown', and in the buzz trust model 'unknown' means 'do not trust'"
  else
    fail "$E_VALIDATION" "not a buzz identity: expected 64 hex characters (an x-only pubkey) or an npub1… — got ${#want} character(s)"
  fi

  local body rc=0
  body="$(registry_read_checked)" || rc=$?
  case "$rc" in
    0) : ;;
    3) _buzz_whois_no "$E_GENERIC" "unknown:no-registry"         || return $? ;;
    5) _buzz_whois_no "$E_GENERIC" "unknown:registry-unparsable" || return $? ;;
    *) _buzz_whois_no "$E_GENERIC" "unknown:registry-unreadable" || return $? ;;
  esac

  # ONE pass returns every (seat, role) pair holding the key, so the ambiguous
  # case is VISIBLE rather than settled by whichever entry jq happened to emit
  # first. `.agents` not being an object is its own not-measured answer, for the
  # same reason the read failures above are.
  local hits
  hits=$(jq -r --arg k "$key" '
      if (.agents | type) != "object" then "!no-agents-map"
      else
        ( [ .agents | to_entries[]
            | select((.value.buzz.pubkey // "" | ascii_downcase) == $k)
            | "\(.key) agent" ]
        + [ .agents | to_entries[]
            | select((.value.buzz.owner_pubkey // "" | ascii_downcase) == $k)
            | "\(.key) owner" ]
        ) | .[]
      end' <<<"$body" 2>/dev/null) \
    || { _buzz_whois_no "$E_GENERIC" "unknown:lookup-failed" || return $?; }
  if [[ "$hits" == "!no-agents-map" ]]; then
    _buzz_whois_no "$E_GENERIC" "unknown:no-agents-map" || return $?
  fi

  local n=0
  # `|| n=0` is REQUIRED, not cosmetic: whitespace-only $hits is non-empty, yet
  # `grep -c .` prints 0 and exits 1 — under header.sh's `set -euo pipefail` that
  # kills this function with nothing on stdout or stderr, the exact silent-death
  # this command's rc split exists to prevent. scripts/unguarded-probe-scan.sh
  # enforces it (DIVE-2604).
  if [[ -n "$hits" ]]; then
    n=$(printf '%s\n' "$hits" | grep -c .) || n=0
  fi
  if (( n == 0 )); then
    # MEASURED absence: the registry was read, parsed, and holds no such key.
    # This is the ONLY code that means "stranger", and it is the input the
    # untrusted-by-default branch is allowed to act on.
    _buzz_whois_no "$E_NOT_FOUND" "no-match" || return $?
  fi
  if (( n > 1 )); then
    _buzz_whois_no "$E_CONFLICT" "ambiguous:$(tr '\n' ',' <<<"$hits" | sed 's/,$//')" || return $?
  fi

  local seat role
  seat="${hits%% *}"
  role="${hits##* }"
  if (( JSON_MODE )); then
    jq -cn --arg a "$seat" --arg r "$role" --arg k "$key" \
      '{ok:true, data:{agent:$a, role:$r, pubkey:$k}}'
  elif [[ "$show_role" == "true" ]]; then
    printf '%s %s\n' "$seat" "$role"
  else
    printf '%s\n' "$seat"
  fi
  return 0
}
