#!/usr/bin/env bash
# DIVE-3513 — buzz onboarding, the LAST MILE (steps 5 and 6 of six).
#
# `5dive agent buzz enable` (DIVE-3509) owns steps 1-4: plugin, binary
# resolution, identity, config. It says so out loud and then stops, because the
# two remaining steps are relay calls and a customer box had no `buzz` binary to
# make them with (DIVE-3512). This file is the rest:
#
#   5. join/create the channels, and add the CUSTOMER's key as a MEMBER
#   6. publish profile + presence for the agent's pubkey (DIVE-3507)
#
# WHY A SECOND IDENTITY. The DIVE-3300 pairing envelope is
# `{"relayUrl","pubkey","nsec"}` — it transfers a PRIVATE key, so the handset
# that scans it BECOMES that identity. If we transferred the agent's own nsec
# the handset and the agent would be one pubkey: the room would have a single
# occupant, the agent could not be @-mentioned by the human, and every message
# would be self-authored (plugins/buzz/mention.ts:101 drops self-delivery, so
# the agent would never answer). So `join` mints a SECOND key — the customer's
# handset identity, `owner.json` — adds THAT pubkey to each channel, and hands
# it to the pairing session. The agent's key never leaves the box.
#
# WHY IT READS BACK. `set-profile` answers `accepted:true` on writes that are
# not subsequently readable (measured, DIVE-3507), and the whole defect class
# this arc exists to end is a surface that reports success while connected to
# nothing (community/wiki/a-channel-is-six-wiring-sites-and-five-green-ones-is-
# what-broken-looks-like.md). Every write here is asserted by a READ: the
# channel must come back from `channels list --member`, and the customer pubkey
# must come back from `channels members`.

# ---------------------------------------------------------------------------
# BIP-340 x-only public key, derived LOCALLY.
#
# The customer's key never connects to the relay, so there is nothing to ask
# `buzz users get` for — its pubkey has to be derived here. Pure python, no new
# dependency, and identical to what the plugin derives with
# `schnorr.getPublicKey` (plugins/buzz/server.ts:86) so the two cannot drift.
# ---------------------------------------------------------------------------
_BUZZ_XONLY_PY='
import sys
P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

def add(a, b):
    if a is None: return b
    if b is None: return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0: return None
    if a == b:
        lam = 3 * a[0] * a[0] * pow(2 * a[1], P - 2, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], P - 2, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)

def mul(pt, k):
    r = None
    while k:
        if k & 1: r = add(r, pt)
        pt = add(pt, pt)
        k >>= 1
    return r

hexkey = sys.stdin.read().strip()
if len(hexkey) != 64:
    sys.exit("private key must be 64 hex chars")
d = int(hexkey, 16)
if not (0 < d < N):
    sys.exit("private key out of range for secp256k1")
pt = mul((Gx, Gy), d)
# x-only: the y-parity is dropped, which is exactly what BIP-340 specifies and
# what the relay stores as `pubkey`.
print("%064x" % pt[0])
'

# <hex private key on stdin> -> 64-char x-only pubkey hex on stdout
_buzz_xonly_pubkey() { python3 -c "$_BUZZ_XONLY_PY"; }

# ---------------------------------------------------------------------------
# Run the buzz binary as the agent user.
#
# NO `--format json` ON ANY SUBCOMMAND, and this is load-bearing rather than a
# style choice. `--format` is declared on buzz's top-level clap `Cli` struct
# WITHOUT `global = true` (crates/buzz-cli/src/lib.rs:93-95 at cli-v0.1.0's
# release commit 484f884), so it is only legal to the LEFT of the subcommand.
# `buzz channels list --format json` is an ARGUMENT-PARSE ERROR — exit 1,
# `{"error":"user_error","message":"unexpected argument '--format' found"}` on
# stderr, nothing on stdout. Measured against /usr/local/bin/buzz, 2026-08-17.
#
# It fails CLOSED and SILENTLY: the listing comes back empty, so every configured
# channel reads as absent, `create` fires on every run, the re-list is empty too,
# and join reports "neither found nor created" against a perfectly healthy relay.
# json is ALREADY the default output, so the correct fix is to omit the flag —
# not to move it left. Do not add it back. (Found by quinn grading DIVE-3513
# iteration 2; the harness could not see it because the fake `buzz` was a bash
# case that ignored trailing flags, i.e. a SUPERSET of the real grammar. The
# stub now exits 64 on leftover argv, and `tests/buzz_last_mile_unit.sh` grades
# every outgoing invocation against the real parser when a binary is present.)
#
# THE KEY TRAVELS ON STDIN, NEVER ON ARGV — the same rule `_buzz_write_config`
# is built around, for the same reason: `/proc/<pid>/cmdline` is world-readable
# on our boxes and `sudo -u x env KEY=<hex> buzz …` makes the secret an argv
# element of the sudo process. `/proc/<pid>/environ` is 0400, so exporting it
# INSIDE the hop is fine; getting it there via argv is not. The buzz subcommand
# args (channel names, pubkeys, URLs) are not secret and stay on argv.
# ---------------------------------------------------------------------------
_buzz_cli() { # <runas> <bin> <relay> <key> <buzz args...>
  local runas="$1" bin="$2" relay="$3" key="$4"; shift 4
  local -a pre=()
  [[ "$runas" != "$(id -un)" ]] && pre=(sudo -u "$runas")
  printf '%s' "$key" | "${pre[@]}" env BUZZ_RELAY_URL="$relay" bash -c '
    IFS= read -r k || true
    [ -n "$k" ] || { echo "no private key on stdin" >&2; exit 64; }
    export BUZZ_PRIVATE_KEY="$k"
    b="$1"; shift
    exec "$b" "$@"
  ' _ "$bin" "$@"
}

# Pull one field out of a buzz JSON array/object without assuming jq can see a
# file only the agent user can read (this parses a string we already hold).
_buzz_pick() { # <python expr over `d`> ; json on stdin
  python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = None
v = ($1)
print('' if v is None else v)
" 2>/dev/null
}

# Is <channel_id> present in a `channels list --member` payload?
#
# WHY NOT A SUBSTRING. This is the assertion that the AGENT is in the room, so
# it has to be evidence. `[[ "$mine" == *"$cid"* ]]` over raw JSON is evidence
# only when the id is long and random; a relay that numbers its channels makes
# `cid=1` match almost any payload — the field name, a timestamp, another id —
# and the arm silently becomes "the relay answered something". So: parse the
# payload and match a channel_id FIELD exactly. The substring survives only as a
# fallback for a payload we cannot parse at all (a schema change, or a
# non-JSON listing), and then only for an id long enough that it is still
# evidence. A short id with an unparseable payload is a MISS, not a pass.
_BUZZ_MIN_SUBSTRING_ID=8
_buzz_lists_channel_id() { # <cid> ; json on stdin
  local cid="$1" body verdict
  [[ -n "$cid" ]] || return 1
  body=$(cat)
  verdict=$(python3 -c "
import json, sys
want = sys.argv[1]
try:
    rows = json.loads(sys.stdin.read())
except Exception:
    print('UNPARSEABLE'); sys.exit(0)
def ids(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ('channel_id', 'channelId', 'id') and isinstance(v, (str, int)):
                yield str(v)
            else:
                yield from ids(v)
    elif isinstance(o, list):
        for x in o:
            yield from ids(x)
print('HIT' if want in set(ids(rows)) else 'MISS')
" "$cid" <<<"$body" 2>/dev/null) || verdict="UNPARSEABLE"
  case "$verdict" in
    HIT)  return 0 ;;
    MISS) return 1 ;;
  esac
  (( ${#cid} >= _BUZZ_MIN_SUBSTRING_ID )) || return 1
  [[ "$body" == *"$cid"* ]]
}

# channel_id for <name> in a \`channels list\` payload, or empty.
_buzz_channel_id() { # <name> ; json on stdin
  python3 -c "
import json, sys
want = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
if not isinstance(rows, list):
    rows = []
for r in rows:
    if isinstance(r, dict) and str(r.get('name', '')) == want:
        print(str(r.get('channel_id', '') or ''))
        break
" "$1" 2>/dev/null
}

# DIVE-3565 — the same lookup, but a token that is ALREADY a channel_id
# resolves to itself. `join` writes resolved ids back into config.json
# `channels`, and `--channels=` is allowed to name one directly, so the lookup
# has to close over its own output or the second run creates a channel LITERALLY
# NAMED after a uuid. Name match first: a relay is free to reuse a string in
# both fields and the name is what the operator meant.
_buzz_channel_ref_id() { # <name-or-id> ; json on stdin
  python3 -c "
import json, sys
want = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
if not isinstance(rows, list):
    rows = []
for r in rows:
    if isinstance(r, dict) and str(r.get('name', '')) == want:
        print(str(r.get('channel_id', '') or ''))
        break
else:
    for r in rows:
        if isinstance(r, dict) and str(r.get('channel_id', '') or '') == want:
            print(want)
            break
" "$1" 2>/dev/null
}

# Write the RESOLVED channel ids back into config.json.
#
# THIS IS THE FIX. Everything above already knew the ids; nothing ever told the
# reader. Rewrites only `channels` and `channel_names` — relay_url, private_key,
# poll_ms and buzz_path are read and written back untouched, so this can never
# be the thing that loses an agent its identity. Same discipline as
# `_buzz_write_config`: run AS the agent user, 0600, key never on argv (it is
# not even read out here — the file is edited in place by the owner).
_buzz_set_channel_ids() { # <runas> <cfg-path> <ids-csv> <names-csv>
  local runas="$1" cfg="$2" ids="$3" names="$4"
  local -a pre=()
  [[ "$runas" != "$(id -un)" ]] && pre=(sudo -u "$runas")
  "${pre[@]}" env CFG="$cfg" IDS="$ids" NAMES="$names" python3 -c '
import json, os, sys
path = os.environ["CFG"]
with open(path) as f:
    cfg = json.load(f)
ids   = [c.strip() for c in os.environ["IDS"].split(",") if c.strip()]
names = [c.strip() for c in os.environ["NAMES"].split(",") if c.strip()]
if not ids:
    sys.exit(0)                      # never blank a working config
if cfg.get("channels") == ids and cfg.get("channel_names") == names:
    sys.exit(0)                      # idempotent: no write, no mtime churn
cfg["channels"] = ids                # what plugins/buzz/server.ts polls
cfg["channel_names"] = names         # what a human and `join` work from
fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(path + ".tmp", 0o600)
os.replace(path + ".tmp", path)      # atomic: the poller may be reading it
print("    resolved channel ids written to " + path)
' >&2
}

# Mint (once) the customer's handset identity. Same one-key-per-agent rule the
# agent's own identity follows: a re-run must not rotate a key a paired handset
# already holds, or the customer silently loses the room.
_buzz_owner_key() { # <name> <user> [rotate]
  local name="$1" user="$2" rotate="${3:-false}" state file key=""
  state=$(_buzz_state_dir "$name")
  file="${state}/owner.json"
  if [[ "$rotate" != "true" ]]; then
    key=$(sudo -u "$user" python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('private_key', ''))
except Exception:
    print('')
" "$file" 2>/dev/null || echo "")
  fi
  if [[ ! "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
    key=$(openssl rand -hex 32 2>/dev/null) \
      || { echo "openssl is required to mint the customer's pairing key" >&2; return 1; }
    local pub
    pub=$(printf '%s' "$key" | _buzz_xonly_pubkey) || return 1
    # Written by the same stdin discipline as config.json — 0600, agent-owned,
    # and the key is never an argv element.
    printf '%s' "$key" | sudo -u "$user" env STATE="$state" PUB="$pub" python3 -c '
import json, os, sys
key = sys.stdin.read().strip()
state = os.environ["STATE"]
os.makedirs(state, mode=0o700, exist_ok=True)
path = os.path.join(state, "owner.json")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"private_key": key, "pubkey": os.environ["PUB"],
               "role": "owner",
               "note": "the CUSTOMER handset identity — transferred by the DIVE-3300 pairing envelope. Not the agent key."}, f, indent=2)
os.chmod(path, 0o600)
' >&2 || return 1
  fi
  printf '%s\n' "$key"
}

# cmd: 5dive agent buzz join <name> [--channels=csv] [--rotate-owner-key]
#
# Idempotent by construction: a channel that exists is joined rather than
# recreated, a member that is already there is a no-op add, and the owner key is
# minted once. Safe to re-run, which is what makes it safe for `enable` to call.
_buzz_join() {
  local name="" chans="" rotate="false"
  while (($#)); do
    case "$1" in
      --channels=*)       chans="${1#*=}" ;;
      --rotate-owner-key) rotate="true" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected argument: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent buzz join <name> [--channels=<csv>]"

  ensure_state
  local reg user state cfg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  user="agent-${name}"
  state=$(_buzz_state_dir "$name")
  cfg="${state}/config.json"

  # Everything below needs the config `enable` writes. Refuse rather than
  # half-do it: a join against a guessed relay is the same defect one layer on.
  local raw relay key bin
  raw=$(sudo -u "$user" cat "$cfg" 2>/dev/null) \
    || fail "$E_VALIDATION" "no buzz config for '$name' — run: sudo 5dive agent buzz enable $name --relay=<https://…>"
  relay=$(_buzz_pick "d.get('relay_url')" <<<"$raw")
  key=$(_buzz_pick "d.get('private_key')" <<<"$raw")
  [[ -n "$relay" && "$key" =~ ^[0-9a-fA-F]{64}$ ]] \
    || fail "$E_VALIDATION" "buzz config for '$name' is missing relay_url or a 64-hex private_key"
  # DIVE-3565. `channel_names` is the operator's list and the thing a relay can
  # look up; `channels` now holds resolved ids. Prefer the names — an id that a
  # relay has forgotten (a rebuilt relay, a restored box) still resolves by name,
  # and a name never resolves from an id. `from_ids` remembers when we had to
  # fall back, because an unresolvable ID must NOT be created as a channel name.
  #
  # WHICH FIELD HOLDS NAMES depends on whether the config predates this fix, and
  # guessing wrong is destructive in one direction: treating a legacy NAME as an
  # id skips the create and reports a channel missing, while treating an ID as a
  # name creates a second room named after a uuid. The tell is the KEY, not the
  # value — `channel_names` is written by every post-DIVE-3565 `enable`, so its
  # ABSENCE means `channels` still holds names.
  local from_ids="false" has_names
  has_names=$(_buzz_pick "'yes' if 'channel_names' in (d or {}) else ''" <<<"$raw")
  [[ -n "$chans" ]] || chans=$(_buzz_pick "','.join(d.get('channel_names') or [])" <<<"$raw")
  if [[ -z "$chans" ]]; then
    chans=$(_buzz_pick "','.join(d.get('channels') or [])" <<<"$raw")
    [[ -n "$chans" && "$has_names" == "yes" ]] && from_ids="true"
  fi
  [[ -n "$chans" ]] || chans="general"

  # The binary, from the config first (that is the path the plugin will use) and
  # then the same search `enable` does. Never invented.
  bin=$(_buzz_pick "d.get('buzz_path')" <<<"$raw")
  [[ -n "$bin" && "$bin" != /* ]] && bin=""
  [[ -n "$bin" ]] && ! sudo -u "$user" test -x "$bin" && bin=""
  [[ -n "$bin" ]] || bin=$(_buzz_resolve_binary "$user" || true)
  [[ -n "$bin" ]] || fail "$E_NOT_INSTALLED" \
    "no \`buzz\` binary for '$name' (config buzz_path, the agent's PATH, /usr/local/bin/buzz, /opt/buzz/bin/buzz all came up empty). Joining a channel IS a relay call; there is nothing to make it with. See DIVE-3512."

  # --- the customer's handset identity -------------------------------------
  local owner_key owner_pub
  owner_key=$(_buzz_owner_key "$name" "$user" "$rotate") \
    || fail "$E_GENERIC" "could not mint the customer's pairing key for '$name'"
  owner_pub=$(printf '%s' "$owner_key" | _buzz_xonly_pubkey) \
    || fail "$E_GENERIC" "could not derive the customer pubkey"
  step "Customer pairing key for '$name': ${owner_pub:0:16}… (${state}/owner.json, 0600)"

  # DIVE-3572. `join` is the SECOND (and last) writer of buzz identity into the
  # registry, and it records BOTH halves:
  #
  #  - owner_pubkey, because this is the only place the paired handset key is
  #    decided. It is what separates trust class (b) — an inbound event signed by
  #    the OWNER's handset, routed like a paired human — from class (c), a
  #    teammate on the a2a rail. Without it the bridge cannot tell the customer
  #    from a stranger.
  #  - pubkey, unconditionally, because every seat enabled BEFORE this row has a
  #    config and no registry identity. Re-running `join` is idempotent, so this
  #    is the backfill path that needs no new verb (`enable --no-join` is the
  #    relay-free equivalent for a box whose relay is down).
  #
  # Both are the PUBLIC halves, derived from keys already in hand.
  local self_pub=""
  self_pub=$(printf '%s' "$key" | _buzz_xonly_pubkey 2>/dev/null) || self_pub=""
  # An `[[ … ]] && { … }` here would be a landmine: header.sh runs the bundle under
  # `set -e`, so the whole list returning 1 on an empty derivation would abort the
  # join mid-way. Spelled as an `if`, deliberately.
  if [[ -n "$self_pub" ]]; then
    _buzz_registry_record "$name" pubkey "$self_pub" || true
  fi
  _buzz_registry_record "$name" owner_pubkey "$owner_pub" || \
    warn "the paired handset key for '$name' was NOT recorded in the registry — \`5dive agent buzz whois $owner_pub\` will call the OWNER a stranger"

  # --- step 5: join or create each channel, and add the customer -----------
  local listing joined=0 created=0 failed=0 ch cid
  local resolved_ids="" resolved_names=""
  listing=$(_buzz_cli "$user" "$bin" "$relay" "$key" channels list 2>/dev/null) || listing=""
  local IFS_SAVE="$IFS"
  IFS=','
  for ch in $chans; do
    IFS="$IFS_SAVE"
    ch="${ch// /}"
    [[ -n "$ch" ]] || continue
    cid=$(_buzz_channel_ref_id "$ch" <<<"$listing")
    if [[ -z "$cid" && "$from_ids" == "true" ]]; then
      # The token came from the resolved-id list, so it is an id, and creating a
      # channel NAMED after it would be a silent second room nobody is in.
      warn "channel id '$ch' is not on $relay — re-run with the name: sudo 5dive agent buzz join $name --channels=<name>"
      failed=$((failed + 1))
      IFS=','
      continue
    fi
    if [[ -z "$cid" ]]; then
      step "Creating channel '$ch' on $relay"
      _buzz_cli "$user" "$bin" "$relay" "$key" \
        channels create --name "$ch" --type stream --visibility open >/dev/null 2>&1 || true
      # Re-list rather than parse the create output: the authority on whether a
      # channel exists is the relay, not the acknowledgement of the write.
      listing=$(_buzz_cli "$user" "$bin" "$relay" "$key" channels list 2>/dev/null) || listing=""
      cid=$(_buzz_channel_ref_id "$ch" <<<"$listing")
      [[ -n "$cid" ]] && created=$((created + 1))
    fi
    if [[ -z "$cid" ]]; then
      warn "channel '$ch': neither found nor created on $relay"
      failed=$((failed + 1))
      IFS=','
      continue
    fi
    _buzz_cli "$user" "$bin" "$relay" "$key" channels join --channel "$cid" >/dev/null 2>&1 || true
    _buzz_cli "$user" "$bin" "$relay" "$key" \
      channels add-member --channel "$cid" --pubkey "$owner_pub" --role owner >/dev/null 2>&1 || true

    # THE ASSERTION. Not "the write was accepted" — the agent must come back as
    # a member of the channel, and so must the customer. This is the exact check
    # whose absence made DIVE-3331 look like a broken relay.
    local members mine cust_ok="no" agent_ok="no"
    members=$(_buzz_cli "$user" "$bin" "$relay" "$key" channels members --channel "$cid" 2>/dev/null) || members=""
    mine=$(_buzz_cli "$user" "$bin" "$relay" "$key" channels list --member 2>/dev/null) || mine=""
    # The customer half stays a substring: 64 hex chars is evidence on its own,
    # and it survives a rename of whatever field carries it. The agent half does
    # NOT — see _buzz_lists_channel_id.
    [[ "$members" == *"$owner_pub"* ]] && cust_ok="yes"
    _buzz_lists_channel_id "$cid" <<<"$mine" && agent_ok="yes"
    if [[ "$cust_ok" == "yes" && "$agent_ok" == "yes" ]]; then
      ok "channel '$ch' ($cid): agent is a member, customer key added"
      joined=$((joined + 1))
      # Only a channel whose membership READ BACK earns a place in the list the
      # poller watches. A write we could not confirm is not a subscription.
      resolved_ids="${resolved_ids:+${resolved_ids},}${cid}"
      resolved_names="${resolved_names:+${resolved_names},}${ch}"
    else
      warn "channel '$ch' ($cid): write accepted but the read-back does not show $( [[ "$cust_ok" == "yes" ]] || echo 'the customer as a member'; [[ "$agent_ok" == "yes" ]] || echo 'the agent in its own member list' )"
      failed=$((failed + 1))
    fi
    IFS=','
  done
  IFS="$IFS_SAVE"

  # --- THE HANDOFF TO THE READER (DIVE-3565) -------------------------------
  # Every site above wired the relay side. This is the one that wires the
  # PLUGIN: without it config.json still says `channels: ["general"]`, the
  # poller sends that name to `buzz messages get --channel`, and every tick dies
  # on `invalid UUID: general` — a seat that is green everywhere and answers
  # nothing. Grade the writer against the reader:
  # plugins/buzz/server.ts:38 `channels: string[] // channel UUIDs to watch`.
  if [[ -n "$resolved_ids" ]]; then
    step "Recording resolved channel ids in the buzz config (the poller reads ids, not names)"
    _buzz_set_channel_ids "$user" "$cfg" "$resolved_ids" "$resolved_names" \
      || warn "could not record the resolved channel ids in $cfg — the poller will not watch anything until it can"
  fi

  # --- step 6: profile + presence (DIVE-3507) ------------------------------
  # Without this the room fills with faceless agents that read as offline, which
  # is indistinguishable from a relay that is not working.
  step "Publishing profile + presence for '$name'"
  _buzz_cli "$user" "$bin" "$relay" "$key" \
    users set-profile --name "$name" --about "5dive agent ${name}" >/dev/null 2>&1 || true
  _buzz_cli "$user" "$bin" "$relay" "$key" users set-presence --status online >/dev/null 2>&1 || true
  local prof
  prof=$(_buzz_cli "$user" "$bin" "$relay" "$key" users get 2>/dev/null) || prof=""
  if [[ "$prof" == *"$name"* ]]; then
    ok "profile readable for '$name'"
  else
    warn "profile write was not readable back — the room will show '$name' as a blank circle (DIVE-3507)"
  fi
  # The plugin's avatar tiering already exists and is not reimplemented here.
  if [[ -x "/home/${user}/.claude/plugins/cache/5dive-plugins/plugins/buzz/publish-profile.sh" ]]; then
    step "Avatar: sudo /home/${user}/.claude/plugins/cache/5dive-plugins/plugins/buzz/publish-profile.sh $name"
  fi

  if ((failed > 0)); then
    warn "buzz join for '$name': ${joined} channel(s) wired, ${failed} not. The customer's handset will not see the unwired ones."
    mark_reported  # DIVE-3558: by-design rc=3, already reported on the line above
    return 3
  fi
  ok "buzz last mile done for '$name' — ${joined} channel(s) (${created} created), customer key ${owner_pub:0:16}… is a member, profile + presence published."
  ok "The poller picks the resolved ids up on restart: sudo 5dive agent restart $name"
  ok "Pair a handset: the envelope is \`5dive agent buzz owner $name --envelope\` (relayUrl/pubkey/nsec, DIVE-3300)."
  return 0
}

# cmd: 5dive agent buzz owner <name> [--envelope]
#
# The customer's handset identity, for the pairing session and for the
# dashboard's Connect Buzz panel. Default output is the PUBLIC half only —
# printing a private key needs asking for it, because this runs from a rail that
# logs its argv (`5dive agent buzz` is audited, src/main.sh:722).
_buzz_owner() {
  local name="" envelope="false"
  while (($#)); do
    case "$1" in
      --envelope) envelope="true" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected argument: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent buzz owner <name> [--envelope]"
  ensure_state
  local user="agent-${name}" state file raw relay
  state=$(_buzz_state_dir "$name")
  file="${state}/owner.json"
  raw=$(sudo -u "$user" cat "$file" 2>/dev/null) \
    || fail "$E_NOT_FOUND" "no customer pairing key for '$name' — run: sudo 5dive agent buzz join $name"
  if [[ "$envelope" != "true" ]]; then
    _buzz_pick "d.get('pubkey')" <<<"$raw"
    return 0
  fi
  relay=$(sudo -u "$user" cat "${state}/config.json" 2>/dev/null | _buzz_pick "d.get('relay_url')")
  [[ -n "$relay" ]] || fail "$E_VALIDATION" "no relay_url in the buzz config for '$name'"
  # The three fields the Buzz apps decode, and only those (DIVE-3300). `nsec` is
  # the bech32 form the app's importer expects; `pubkey` is derived from the same
  # key rather than copied, so the pair cannot drift.
  RELAY="$relay" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
key = d['private_key']
CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
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
def convertbits(data, frm, to):
    acc = bits = 0; ret = []; maxv = (1 << to) - 1
    for value in data:
        acc = (acc << frm) | value; bits += frm
        while bits >= to:
            bits -= to; ret.append((acc >> bits) & maxv)
    if bits:
        ret.append((acc << (to - bits)) & maxv)
    return ret
def bech32(hrp, data):
    combined = data + [(polymod(hrp_expand(hrp) + data + [0,0,0,0,0,0]) ^ 1) >> 5*(5-i) & 31 for i in range(6)]
    return hrp + '1' + ''.join([CHARSET[d] for d in combined])
nsec = bech32('nsec', convertbits(bytes.fromhex(key), 8, 5))
print(json.dumps({'relayUrl': os.environ['RELAY'], 'pubkey': d['pubkey'], 'nsec': nsec}))
" <<<"$raw"
}
