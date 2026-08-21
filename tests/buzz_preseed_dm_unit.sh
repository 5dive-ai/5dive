#!/usr/bin/env bash
# DIVE-3665 unit harness: preseed a DM thread per buzz-enabled agent.
#
# lodar, mid-walk: "we need to preseed dms for all agents that are in buzz. so
# user dont have to click plus and search." Today `_buzz_join` wires the owner
# key into the NAMED channels and stops; the handset opens with the team room
# and an empty DM list, and every agent costs the customer a plus-and-search.
#
# THE HOOK IS `_buzz_join`, and that is the whole reason this row needs one edit
# rather than two: `5dive buzz pair` calls it once per buzz-enabled agent
# (cmd_buzz.sh, the wire loop) and `agent buzz enable` calls it at the end of the
# last mile (cmd_agent_buzz.sh:179). So "at pair time" and "on a later enable"
# are the SAME call site, and an arm that grades the call site grades both.
#
# WHAT THIS FILE GRADES, and it drives the real function rather than grepping it:
#   1. join OPENS a DM, and does it as the OWNER key with the AGENT's pubkey
#      (the direction matters — the thread has to land in the handset's list)
#   2. it READS BACK from the owner's own view; a write the relay acknowledged
#      and cannot serve is the defect class this whole arc exists to end
#   3. IDEMPOTENCE: a DM that already exists is not opened a second time.
#      join runs on every pair and every enable, so a missing dedupe is N
#      identical threads in the customer's list, not a wasted call.
#   4. the named team channels are NOT mistaken for the DM (a 2-member team
#      room would otherwise satisfy the dedupe and suppress the seed forever)
#   5. an unreadable seed WARNS rather than reporting success
#   6. the private key never reaches argv (the DIVE-3509 rule, re-armed on the
#      new call site because this one is made with the OWNER's key)
#
# Run: bash tests/buzz_preseed_dm_unit.sh   (no root, no network, no relay.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
JOINF="$SRC/cmd_agent_buzz_join.sh"
[[ -f "$JOINF" ]] || { echo "FAIL - $JOINF is not on disk — this harness would grade nothing"; echo "0 passed, 1 failed"; exit 1; }

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

AGENT_SK="$(printf '3%.0s' {1..63})7"
AGENT_PUB=$(printf '%s' "$AGENT_SK" | _buzz_xonly_pubkey 2>/dev/null)
[[ "$AGENT_PUB" =~ ^[0-9a-f]{64}$ ]] \
  || { bad_t "fixture: the agent pubkey derives" "got '$AGENT_PUB'"; printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }

# ---------------------------------------------------------------------------
# THE FAKE RELAY.
#
# A stub `buzz` with STATE: channels it has been told to create, the members of
# each, and the DMs opened. It answers `channels list`/`members`/`list --member`
# out of that state, so a read-back arm is reading what the writes actually did
# and not a canned string. Every invocation is appended to $CALLS as
#   <BUZZ_PRIVATE_KEY> <argv…>
# which is what lets the arms below assert WHICH KEY made a call — the key
# travels on stdin and is exported inside the hop, so /proc is not the only
# place it is observable and argv can be checked for its absence.
#
# DMS LIST IS DELIBERATELY EMPTY unless DMS_LIST_WORKS=1. That is not a
# convenience: it is the measured behaviour of the live relay
# (community/wiki/dms-list-returns-empty-so-a-dm-poller-has-nothing-to-
# discover.md, two real keys on sure-redwood, 2026-08-18) — the conversation
# exists, both sides are members, `channels list` shows it, and `dms list`
# answers []. A dedupe built on `dms list` alone would therefore reopen the DM
# on every join forever, and would look perfect against a helpful fixture.
# ---------------------------------------------------------------------------
make_relay() { # <dir>
  cat >"$1/buzz" <<'STUB'
#!/usr/bin/env bash
# fake relay. state lives in $RELAY_STATE (channels.json), calls in $CALLS.
printf '%s %s\n' "${BUZZ_PRIVATE_KEY:-<none>}" "$*" >>"$CALLS"
python3 - "$RELAY_STATE" "$@" <<'PY'
import json, os, sys
path = sys.argv[1]; a = sys.argv[2:]
try:    st = json.load(open(path))
except Exception: st = {"channels": {}}
def save(): json.dump(st, open(path, "w"))
def opt(name):
    return a[a.index(name)+1] if name in a and a.index(name)+1 < len(a) else None
def me():
    # the fake relay identifies the caller by pubkey, same as the real one
    return os.environ.get("STUB_PUB_%s" % os.environ.get("BUZZ_PRIVATE_KEY","")[:8], "") \
        or os.environ.get("STUB_SELF", "")
ch = st["channels"]
if a[:2] == ["channels", "list"]:
    mine = [c for c in ch.values() if "--member" not in a or me() in c["members"]]
    if os.environ.get("STUB_HIDE_DMS") == "1":
        # accepted-but-unservable: the write lands, the listing never shows it
        mine = [c for c in mine if not c.get("dm")]
    print(json.dumps(mine)); sys.exit(0)
if a[:2] == ["channels", "create"]:
    name = opt("--name") or "?"
    cid = "cid-%s" % name
    ch.setdefault(cid, {"channel_id": cid, "name": name, "members": [me()]}); save()
    print(json.dumps(ch[cid])); sys.exit(0)
if a[:2] == ["channels", "join"]:
    c = ch.get(opt("--channel"))
    if c is None: sys.exit(1)
    if me() not in c["members"]: c["members"].append(me())
    save(); print("{}"); sys.exit(0)
if a[:2] == ["channels", "add-member"]:
    c = ch.get(opt("--channel"))
    if c is None: sys.exit(1)
    p = opt("--pubkey")
    if p and p not in c["members"]: c["members"].append(p)
    save(); print("{}"); sys.exit(0)
if a[:2] == ["channels", "members"]:
    c = ch.get(opt("--channel"))
    if c is None: sys.exit(1)
    print(json.dumps([{"pubkey": p, "role": "member"} for p in c["members"]])); sys.exit(0)
if a[:2] == ["dms", "open"]:
    others = [x for x in a[3:] if not x.startswith("--")]
    # the relay does NOT dedupe: every open is a new conversation. (Whether the
    # real one does is unknown and must not be assumed — if it does, our dedupe
    # is merely redundant; if it does not, ours is the only thing between the
    # customer and a list of identical threads.)
    n = len([c for c in ch.values() if c.get("dm")])
    cid = "dm-%d" % (n + 1)
    ch[cid] = {"channel_id": cid, "name": "DM", "dm": True, "members": [me()] + others}
    save(); print(json.dumps({"dm_id": cid})); sys.exit(0)
if a[:2] == ["dms", "list"]:
    if os.environ.get("DMS_LIST_WORKS") == "1":
        print(json.dumps([{"id": c["channel_id"], "participants": c["members"]}
                          for c in ch.values() if c.get("dm")]))
    else:
        print("[]")            # measured live behaviour; see the note above
    sys.exit(0)
if a[:2] == ["users", "get"]:
    print(json.dumps([{"name": os.environ.get("STUB_NAME","dev"), "picture": "https://x/y.png"}])); sys.exit(0)
if a[0] == "users":
    print("{}"); sys.exit(0)
print("{}")
PY
STUB
  chmod +x "$1/buzz"
}

# Drive the real `_buzz_join` against the fake relay. Everything shadowed here is
# the BOX (sudo, state dir, registry, binary search) — never the code under test.
# Echoes the calls log path on stdout.
drive_join() { # <dir> [env assignments…]
  local dir="$1"; shift
  mkdir -p "$dir/state"
  make_relay "$dir"
  python3 - "$dir/state/config.json" "$dir/buzz" "$AGENT_SK" <<'PYCFG'
import json, sys
json.dump({"relay_url": "https://relay.example.com", "private_key": sys.argv[3],
           "channel_names": ["general"], "channels": [], "buzz_path": sys.argv[2]},
          open(sys.argv[1], "w"), indent=2)
PYCFG
  (
    set +e
    export CALLS="$dir/calls.log" RELAY_STATE="$dir/relay.json"
    printf '{"channels":{}}' >"$RELAY_STATE"
    while (($#)); do export "${1?}"; shift; done
    sudo() { while (($#)); do case "$1" in -u) shift 2 ;; -H|-n) shift ;; *) break ;; esac; done; "$@"; }
    ensure_state() { :; }
    registry_read() { printf '%s' '{"agents":{"dev":{"type":"claude","channels":"buzz"}}}'; }
    _buzz_state_dir() { printf '%s\n' "$dir/state"; }
    _buzz_server_owner_file() { printf '%s/owner-server.json\n' "$dir"; }
    _buzz_resolve_binary() { return 1; }
    _buzz_registry_record() { :; }
    _buzz_publish_profile_script() { printf ''; }
    # The stub answers as whoever holds the key: _buzz_cli exports
    # BUZZ_PRIVATE_KEY inside the hop, and the stub maps it to a pubkey here.
    _buzz_cli() {
      local runas="$1" bin="$2" relay="$3" key="$4"; shift 4
      local pub; pub=$(printf '%s' "$key" | _buzz_xonly_pubkey 2>/dev/null)
      printf '%s' "$key" | env BUZZ_RELAY_URL="$relay" STUB_SELF="$pub" bash -c '
        IFS= read -r k || true
        [ -n "$k" ] || { echo "no private key on stdin" >&2; exit 64; }
        export BUZZ_PRIVATE_KEY="$k"
        b="$1"; shift
        exec "$b" "$@"
      ' _ "$bin" "$@"
    }
    ( _buzz_join dev ) 2>"$dir/join.err" >"$dir/join.out"
    echo "$?" >"$dir/join.rc"
  ) >/dev/null 2>&1
  printf '%s\n' "$dir/calls.log"
}

D1=$(mktemp -d)
CALLS1=$(drive_join "$D1")
LOG1=$(cat "$CALLS1" 2>/dev/null)
OUT1=$(cat "$D1/join.out" "$D1/join.err" 2>/dev/null)
OWNER_SK=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['private_key'])" "$D1/state/owner.json" 2>/dev/null)
OWNER_PUB=$(printf '%s' "$OWNER_SK" | _buzz_xonly_pubkey 2>/dev/null)
[[ "$OWNER_PUB" =~ ^[0-9a-f]{64}$ ]] || OWNER_PUB="__no_owner__"

# --- control: the rig actually drove the function ---------------------------
# Without this every absence arm below is vacuous — a stub that was never called
# and a code path that was never added produce an identical empty log.
grep -q 'channels list' <<<"$LOG1" \
  && ok_t "control: the rig drives the real _buzz_join against the fake relay" \
  || bad_t "control: the rig drives the real _buzz_join against the fake relay" \
           "the calls log is empty — every arm below would be grading nothing. log: ${LOG1:-<empty>}"

# --- 1. a DM is opened, with the AGENT's pubkey -----------------------------
DM_OPEN=$(grep 'dms open' <<<"$LOG1" | head -1)
[[ -n "$DM_OPEN" ]] \
  && ok_t "join opens a DM thread (the customer does not have to plus-and-search)" \
  || bad_t "join opens a DM thread (the customer does not have to plus-and-search)" \
           "no 'dms open' in the calls log — the handset opens with the team room and an empty DM list"
grep -q "dms open .*--pubkey $AGENT_PUB" <<<"$LOG1" \
  && ok_t "the DM names the AGENT's pubkey" \
  || bad_t "the DM names the AGENT's pubkey" "want --pubkey $AGENT_PUB; saw: ${DM_OPEN:-<no open at all>}"

# --- 2. it is opened BY THE OWNER key ---------------------------------------
# Direction is not cosmetic. The thread has to be in the HANDSET's conversation
# list; opening it from the agent side is a different write with a different
# membership row, and the memory that measured this relay could only confirm the
# owner's view by reading with the owner's key.
if [[ -n "$OWNER_SK" ]] && grep -q "^$OWNER_SK dms open" <<<"$LOG1"; then
  ok_t "the DM is opened with the OWNER key, so it lands in the handset's list"
else
  bad_t "the DM is opened with the OWNER key, so it lands in the handset's list" \
        "the 'dms open' line was made by $(grep 'dms open' <<<"$LOG1" | head -1 | awk '{print substr($1,1,12)}')…, owner key starts ${OWNER_SK:0:12}…"
fi
# and the owner's pubkey must NOT be the pubkey it DMs — that would be a thread
# with itself, which is what a copy-paste of the add-member line produces.
grep -q "dms open .*--pubkey $OWNER_PUB" <<<"$LOG1" \
  && bad_t "the DM is not addressed to the owner itself" "saw --pubkey $OWNER_PUB (the owner's own key)" \
  || ok_t "the DM is not addressed to the owner itself"

# --- 3. the seed is READ BACK from the owner's own view ---------------------
# `dms list` is empty on the live relay, so the read-back has to be a listing the
# relay actually serves. Whatever it is, it must be made with the OWNER key: a
# read-back with the AGENT key proves the agent can see the thread and says
# nothing about the handset, which is the only view the customer has.
READBACK=$(grep -c "^${OWNER_SK:-__} channels list" <<<"$LOG1")
(( READBACK > 0 )) \
  && ok_t "the seeded DM is read back with the OWNER key (the handset's own view)" \
  || bad_t "the seeded DM is read back with the OWNER key (the handset's own view)" \
           "no owner-key listing in the log — an accepted write that the relay cannot serve reads as success"
grep -qi 'dm\|direct message' <<<"$OUT1" \
  && ok_t "join says on the stream what it seeded" \
  || bad_t "join says on the stream what it seeded" "no DM line in join's output: $(tail -3 <<<"$OUT1" | tr '\n' ' ')"

# --- 4. IDEMPOTENCE: a second join does not open a second thread ------------
# This is the arm the row lives or dies on. `join` runs on every `5dive buzz
# pair` AND at the end of every `agent buzz enable`, so a missing dedupe is not
# a wasted relay call, it is the customer's DM list filling with identical rows.
D2=$(mktemp -d)
drive_join "$D2" >/dev/null   # seeds the relay state the re-run below reuses
# re-run against the SAME relay state and the same owner mirror
(
  set +e
  export CALLS="$D2/calls2.log" RELAY_STATE="$D2/relay.json"
  : >"$CALLS"
  sudo() { while (($#)); do case "$1" in -u) shift 2 ;; -H|-n) shift ;; *) break ;; esac; done; "$@"; }
  ensure_state() { :; }
  registry_read() { printf '%s' '{"agents":{"dev":{"type":"claude","channels":"buzz"}}}'; }
  _buzz_state_dir() { printf '%s\n' "$D2/state"; }
  _buzz_server_owner_file() { printf '%s/owner-server.json\n' "$D2"; }
  _buzz_resolve_binary() { return 1; }
  _buzz_registry_record() { :; }
  _buzz_publish_profile_script() { printf ''; }
  _buzz_cli() {
    local bin="$2" relay="$3" key="$4"; shift 4   # $1 (runas) is the box, shadowed away here
    local pub; pub=$(printf '%s' "$key" | _buzz_xonly_pubkey 2>/dev/null)
    printf '%s' "$key" | env BUZZ_RELAY_URL="$relay" STUB_SELF="$pub" bash -c '
      IFS= read -r k || true
      export BUZZ_PRIVATE_KEY="$k"; b="$1"; shift; exec "$b" "$@"
    ' _ "$bin" "$@"
  }
  ( _buzz_join dev ) >"$D2/join2.out" 2>&1
) >/dev/null 2>&1
LOG2=$(cat "$D2/calls2.log" 2>/dev/null)
DMS_AFTER=$(python3 -c "
import json,sys
d=json.load(open('$D2/relay.json'))
print(len([c for c in d['channels'].values() if c.get('dm')]))" 2>/dev/null)
[[ "$DMS_AFTER" == "1" ]] \
  && ok_t "a second join leaves exactly ONE DM thread (idempotent — join runs on every pair and every enable)" \
  || bad_t "a second join leaves exactly ONE DM thread (idempotent — join runs on every pair and every enable)" \
           "the relay holds ${DMS_AFTER:-?} DM threads after two joins; the customer's list grows one row per pair"
grep -q 'dms open' <<<"$LOG2" \
  && bad_t "the second join does not call 'dms open' at all" "it did: $(grep 'dms open' <<<"$LOG2" | head -1)" \
  || ok_t "the second join does not call 'dms open' at all"

# --- 5. the team channel is not mistaken for the DM -------------------------
# 'general' has exactly two members after the join (agent + owner), the same
# shape a DM has. A dedupe that matches on membership shape alone finds it,
# concludes the DM is already there, and never seeds anything — green forever,
# and the customer still has an empty DM list. Arm 4 cannot see this; only a
# FIRST join that still opens a DM can, which is arm 1 — so what is asserted
# here is that the general channel survived un-dm'd and the seed is separate.
GEN_OK=$(python3 -c "
import json
d=json.load(open('$D1/relay.json'))['channels']
gen=[c for c in d.values() if c.get('name')=='general']
dms=[c for c in d.values() if c.get('dm')]
print('yes' if len(gen)==1 and not gen[0].get('dm') and len(dms)==1 and len(gen[0]['members'])==2 else 'no:%d/%d'%(len(gen),len(dms)))" 2>/dev/null)
[[ "$GEN_OK" == "yes" ]] \
  && ok_t "the 2-member team channel is NOT counted as the DM (the seed is a separate thread)" \
  || bad_t "the 2-member team channel is NOT counted as the DM (the seed is a separate thread)" \
           "relay shape: ${GEN_OK:-unreadable}"

# --- 6. an unreadable seed warns, it does not report success ----------------
# The failure this arc keeps re-finding is a write the relay accepts and cannot
# serve. Break exactly the read-back — the open still succeeds — and join must
# say the handset will not see it.
D3=$(mktemp -d)
CALLS3=$(drive_join "$D3" "STUB_HIDE_DMS=1")
OUT3=$(cat "$D3/join.out" "$D3/join.err" 2>/dev/null)
if grep -qi 'dms open' <<<"$(cat "$CALLS3")"; then
  # The warn must be THIS one. A bare /warn/ matches the avatar warning the
  # publish-profile shadow always emits, and a mutation that reports the seed
  # green survives that grep — measured (M6, 12/12 with the read-back gutted).
  # So: the DM warn is present AND the DM success line is absent.
  WARNED=no; CLAIMED=no
  grep -qE 'warn:.*(plus-and-search|DIVE-3665)' <<<"$OUT3" && WARNED=yes
  grep -qE 'reads back in the OWNER' <<<"$OUT3" && CLAIMED=yes
  { [[ "$WARNED" == "yes" && "$CLAIMED" == "no" ]]; } \
    && ok_t "a seed the owner cannot read back WARNS and does NOT claim success (accepted-but-unservable is the defect class)" \
    || bad_t "a seed the owner cannot read back WARNS and does NOT claim success (accepted-but-unservable is the defect class)" \
             "warned=$WARNED claimed-success=$CLAIMED; join said: $(tail -4 <<<"$OUT3" | tr '\n' ' ')"
else
  bad_t "a seed the owner cannot read back WARNS (accepted-but-unservable is the defect class)" \
        "the hidden-DM fixture never reached 'dms open' — the arm is vacuous"
fi

# --- 7. no private key on argv ----------------------------------------------
# Re-armed on the new call site because it is the first one made with the OWNER
# key, and /proc/<pid>/cmdline is world-readable on our boxes.
grep 'dms ' <<<"$LOG1" | sed 's/^[0-9a-f]* //' | grep -qE '[0-9a-f]{64}' && ARGV_HEX=yes || ARGV_HEX=no
if [[ "$ARGV_HEX" == "yes" ]]; then
  # a pubkey on argv is fine and expected; a PRIVATE key is not
  if grep 'dms ' <<<"$LOG1" | sed 's/^[0-9a-f]* //' | grep -qE "$AGENT_SK|${OWNER_SK:-__nope__}"; then
    bad_t "no private key reaches argv on the DM call site" "a private key is an argv element of the dms call"
  else
    ok_t "no private key reaches argv on the DM call site"
  fi
else
  ok_t "no private key reaches argv on the DM call site"
fi

rm -rf "$D1" "$D2" "$D3"
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
