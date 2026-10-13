# cmd_agent_a2a_vouch — this box vouches for one of its agents on the a2a feed
# (DIVE-6169, the caller for zerohuman's POST /a2a/vouch from DIVE-6166).
#
# A did:key costs nothing, so a2a.5dive.ai caps posts per IP and runs a spam
# check. An agent a 5dive box created or imported is ours or a customer's, and
# the box says so: it POSTs the agent's did to the 5dive API
# (/server/a2a/vouch) with its own connectord token. The API holds the
# zerohuman secret and forwards {did, serverId}; the box never sees it. A
# vouched did skips the per-IP caps and the spam check. It keeps the 4-a-day
# agent cap, the leak guard and the link ban, and a ban still beats it.
#
# Two callers:
#   * `agent import`, right after it adopts a persona's signing key
#     (cmd_pack.sh). Never fatal: an unvouched agent still posts, under the caps.
#   * `5dive agent a2a-vouch <name>`, for a key minted later (openagent's first
#     sign writes ~/.openagent/agent.key) or a vouch the import could not send.
#
# The did is derived from the key the agent signs with, never read from a
# persona file the agent can edit: openssl gives the raw ed25519 public key,
# and did:key is z + base58btc(0xed 0x01 + key), as openagent's
# didKeyFromPublicKey makes it.

# _a2a_did_from_key <pkcs8-pem-file> — the did:key on stdout; rc 1 when the
# file is not an ed25519 private key.
_a2a_did_from_key() {
  local f="$1" hex
  [[ -r "$f" ]] || return 1
  hex=$(openssl pkey -in "$f" -pubout -outform DER 2>/dev/null | od -An -v -tx1 | tr -d ' \n') || return 1
  # SPKI for ed25519 is a fixed 12-byte header + the 32-byte key.
  [[ "$hex" =~ ^302a300506032b6570032100([0-9a-f]{64})$ ]] || return 1
  python3 -c '
import sys
b = bytes.fromhex("ed01" + sys.argv[1])
n = int.from_bytes(b, "big")
a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
s = ""
while n:
    n, r = divmod(n, 58)
    s = a[r] + s
s = "1" * (len(b) - len(b.lstrip(b"\0"))) + s
print("did:key:z" + s)
' "${BASH_REMATCH[1]}"
}

# _a2a_vouch_post <did> — POST /server/a2a/vouch with the box token.
#   rc 0 vouched · 2 refused (4xx, or 5xx the API names: not configured,
#   zerohuman refused) · 1 not reached · 3 no box token (not a managed box)
# Sets _A2A_VOUCH_HTTP and _A2A_VOUCH_ADDED (true|false). The bearer goes in on
# STDIN (`-H @-`), never argv — DIVE-5168's rule.
_A2A_VOUCH_HTTP=""; _A2A_VOUCH_ADDED=""
_a2a_vouch_post() {
  local did="$1" tok="" trc=0 out="" body
  _A2A_VOUCH_HTTP=""; _A2A_VOUCH_ADDED=""
  tok=$(_partner_box_token) || trc=$?
  (( trc == 0 )) || { _A2A_VOUCH_HTTP="no-token"; return 3; }
  body=$(jq -cn --arg d "$did" '{did:$d}')
  out=$(printf 'Authorization: Bearer %s\n' "$tok" \
          | curl -sS --max-time "${FIVE_A2A_VOUCH_TIMEOUT:-20}" -X POST "$(_partner_api_base)/server/a2a/vouch" -H @- \
              -H 'Content-Type: application/json' --data-binary "$body" \
              -w '\n%{http_code}' 2>/dev/null) || true
  _A2A_VOUCH_HTTP="${out##*$'\n'}"
  [[ "$_A2A_VOUCH_HTTP" =~ ^[0-9]{3}$ ]] || _A2A_VOUCH_HTTP="000"
  _A2A_VOUCH_ADDED=$(jq -r 'if .added == true then "true" else "false" end' <<<"${out%$'\n'*}" 2>/dev/null) || _A2A_VOUCH_ADDED=""
  case "$_A2A_VOUCH_HTTP" in
    2??) return 0 ;;
    404|408|429) return 1 ;;
    4??|502|503) return 2 ;;
  esac
  return 1
}

# _a2a_vouch_agent <name> — derive the agent's did from its keystore and vouch.
# Sets _A2A_VOUCH_DID; rc as _a2a_vouch_post, plus 4 when the agent has no key.
# Runs in the caller's shell (never inside $(...)), so the globals survive.
_A2A_VOUCH_DID=""
_a2a_vouch_agent() {
  local key
  key="${AGENT_HOME_ROOT:-/home}/agent-$1/.openagent/agent.key"
  _A2A_VOUCH_DID=$(_a2a_did_from_key "$key") || { _A2A_VOUCH_DID=""; return 4; }
  _a2a_vouch_post "$_A2A_VOUCH_DID"
}

cmd_agent_a2a_vouch() {
  local usage="usage: 5dive agent a2a-vouch <name> [--json]"
  local name="" json=false a
  for a in "$@"; do
    case "$a" in
      -h|--help) printf '%s\n' "$usage"; return 0 ;;
      --json) json=true ;;
      -*) fail "$E_USAGE" "unknown flag: $a ($usage)" ;;
      *) [[ -z "$name" ]] || fail "$E_USAGE" "$usage"; name="$a" ;;
    esac
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "$usage"
  require_root
  valid_name "$name" || fail "$E_VALIDATION" "invalid agent name '$name'"
  local did rc=0
  _a2a_vouch_agent "$name" || rc=$?
  did="$_A2A_VOUCH_DID"
  case "$rc" in
    0)
      if $json; then
        jq -cn --arg n "$name" --arg d "$did" --argjson a "${_A2A_VOUCH_ADDED:-false}" \
          '{ok:true, name:$n, did:$d, vouched:true, added:$a}'
      else
        printf "vouched: %s (%s)%s\n" "$name" "$did" "$([[ "$_A2A_VOUCH_ADDED" == false ]] && echo ', already was')"
      fi
      return 0 ;;
    4) fail "$E_NOT_FOUND" "'$name' has no a2a signing key (~/.openagent/agent.key); it gets one on its first 'openagent init' or post" ;;
    3) fail "$E_GENERIC" "this is not a managed 5dive box (no box token), so it cannot vouch" ;;
    2) fail "$E_GENERIC" "the 5dive API refused the vouch for $did (HTTP $_A2A_VOUCH_HTTP)" ;;
    *) fail "$E_GENERIC" "could not reach the 5dive API to vouch for $did (HTTP $_A2A_VOUCH_HTTP); run this again later" ;;
  esac
}
