#!/usr/bin/env bash
# DIVE-8294 unit: two OpenClaw agents on one box get two gateway ports.
#
# Seen live (DIVE-8283's arm, 0.129.1): every OpenClaw seat bound openclaw's
# default 127.0.0.1:18789. Loopback ports belong to the whole host, so the
# second OpenClaw seat's gateway could not bind and that agent never answered.
#
#   C  two creates (write_agent_env, the one writer of agents.d/<name>.env) get
#      two different ports; the first gets 18789; a rewrite keeps the port; a
#      switch away from openclaw drops it; a non-openclaw seat never gets one
#   M  an existing seat with no port (made before this fix) gets one from
#      openclaw_port_ensure, the pre-start step's call; the first keeps 18789,
#      a later one moves; a port held by a running listener is skipped
#   S  5dive-agent-start writes the port into the seat's openclaw config and
#      exports OPENCLAW_GATEWAY_PORT for the pane; `agent _seed_perms` calls
#      openclaw_port_ensure for an openclaw seat
#
#   bash tests/dive8294_openclaw_port_per_seat_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${TMP:-}" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/dive8294-unit.XXXXXX)"
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR/agents.d"
# No real host listener may decide a pick in this harness.
: > "$TMP/net-empty"
export OPENCLAW_PORT_NET_FILES="$TMP/net-empty"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/agent_env.sh cmd_agent_create.sh; do
  # shellcheck disable=SC1090
  source "src/$f"
done
set +e
chown() { :; }   # write_agent_env stamps root:claude; not ours to grade as a user

fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1${2:+ ($2)}"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want=$3 got=$2"; fi; }
port_of() { sed -n 's/^AGENT_OPENCLAW_PORT=//p' "$ENV_DIR/$1.env" 2>/dev/null | head -1; }

# ---------- C: create ----------
write_agent_env oc1 openclaw dashboard "" "" standard 2>/dev/null
write_agent_env oc2 openclaw telegram "" "" standard 2>/dev/null
p1=$(port_of oc1); p2=$(port_of oc2)
if [[ -n "$p1" && -n "$p2" && "$p1" != "$p2" ]]; then
  ok "C1 two OpenClaw creates get two different gateway ports ($p1, $p2)"
else
  bad "C1 two OpenClaw creates get two different gateway ports" "oc1=${p1:-none} oc2=${p2:-none}"
fi
check "C2 the first OpenClaw seat keeps openclaw's default port" "$p1" 18789
check "C3 the second is one slot up (room for openclaw's derived ports)" "$p2" 18989
write_agent_env oc1 openclaw "dashboard,telegram" "/tmp" "" standard 2>/dev/null
check "C4 a rewrite (channels/workdir change) keeps the port" "$(port_of oc1)" "$p1"
check "C5 a rewrite leaves one port line" "$(grep -c '^AGENT_OPENCLAW_PORT=' "$ENV_DIR/oc1.env")" 1
write_agent_env cl1 claude telegram "" "" standard 2>/dev/null
check "C6 a non-openclaw seat gets no port" "$(port_of cl1)" ""
write_agent_env oc2 hermes telegram "" "" standard 2>/dev/null
check "C7 a seat switched away from openclaw drops its port" "$(port_of oc2)" ""
write_agent_env oc3 openclaw dashboard "" "" standard 2>/dev/null
check "C8 a freed port is reused by the next create" "$(port_of oc3)" 18989
check "C9 the env file keeps its other fields" "$(sed -n 's/^AGENT_TYPE=//p' "$ENV_DIR/oc3.env")" openclaw
# A rewrite must keep the RECORDED port, not re-pick: free the slot below
# oc3's (18789) first, so a re-pick would land somewhere else.
rm -f "$ENV_DIR/oc1.env"
write_agent_env oc3 openclaw "dashboard,telegram" "" "" standard 2>/dev/null
check "C10 a rewrite keeps its port even when a lower slot is free" "$(port_of oc3)" 18989

# ---------- M: migration of seats made before the fix ----------
rm -f "$ENV_DIR"/*.env
printf 'AGENT_NAME=old1\nAGENT_TYPE=openclaw\nAGENT_CHANNELS=telegram\n' > "$ENV_DIR/old1.env"
printf 'AGENT_NAME=old2\nAGENT_TYPE=openclaw\nAGENT_CHANNELS=dashboard\n' > "$ENV_DIR/old2.env"
chmod 640 "$ENV_DIR/old1.env"
m1=$(openclaw_port_ensure old1); m2=$(openclaw_port_ensure old2)
check "M1 the first existing seat to start keeps 18789" "$m1" 18789
check "M2 a later existing seat moves" "$m2" 18989
check "M3 the port is recorded in the seat's env file" "$(port_of old2)" 18989
check "M4 ensure is stable (asking again returns the same port)" "$(openclaw_port_ensure old1)" 18789
check "M5 the migrated file keeps its mode" "$(stat -c %a "$ENV_DIR/old1.env")" 640
check "M6 the migrated file keeps its other fields" "$(sed -n 's/^AGENT_CHANNELS=//p' "$ENV_DIR/old1.env")" telegram
printf 'AGENT_NAME=bad\nAGENT_TYPE=openclaw\nAGENT_OPENCLAW_PORT=nope\n' > "$ENV_DIR/bad.env"
check "M7 a malformed port is replaced" "$(openclaw_port_ensure bad)" 19189
check "M8 ... leaving one port line" "$(grep -c '^AGENT_OPENCLAW_PORT=' "$ENV_DIR/bad.env")" 1
# A listener on the next slot (say another service on 19389) is skipped.
printf '  sl  local_address rem_address   st\n   0: 0100007F:%04X 00000000:0000 0A\n' 19389 > "$TMP/net-busy"
printf 'AGENT_NAME=new\nAGENT_TYPE=openclaw\n' > "$ENV_DIR/new.env"
check "M9 a port something already listens on is skipped" \
  "$(OPENCLAW_PORT_NET_FILES="$TMP/net-busy" openclaw_port_ensure new)" 19589
printf '  sl  local_address rem_address   st\n   0: 0100007F:%04X 00000000:0000 01\n' 19389 > "$TMP/net-est"
printf 'AGENT_NAME=new2\nAGENT_TYPE=openclaw\n' > "$ENV_DIR/new2.env"
check "M10 a port only seen in a non-listening socket is still free" \
  "$(OPENCLAW_PORT_NET_FILES="$TMP/net-est" openclaw_port_ensure new2)" 19389
check "M11 a seat with no env file gets no port" "$(openclaw_port_ensure ghost; echo "rc=$?")" "rc=1"

# ---------- S: the start script and the pre-start step ----------
blk=$(awk '/DIVE-8294: this seat.s own gateway port/{on=1} on{print} on&&/^  fi$/{exit}' bin/5dive-agent-start)
if [[ -n "$blk" ]] && grep -q '{gateway: {port: \$p}}' <<<"$blk" \
   && grep -q 'openclaw config patch --stdin' <<<"$blk"; then
  ok "S1 5dive-agent-start patches gateway.port into the seat's openclaw config"
else
  bad "S1 5dive-agent-start patches gateway.port into the seat's openclaw config"
fi
if grep -q 'export OPENCLAW_GATEWAY_PORT="\$AGENT_OPENCLAW_PORT"' <<<"$blk" \
   && grep -q 'OPENCLAW_PATH_OVERRIDE+="export OPENCLAW_GATEWAY_PORT=' <<<"$blk"; then
  ok "S2 it exports OPENCLAW_GATEWAY_PORT for the bridge and the pane"
else
  bad "S2 it exports OPENCLAW_GATEWAY_PORT for the bridge and the pane"
fi
# The patch the block sends, built the same way, is what openclaw reads.
patch=$(jq -cn --argjson p 18989 '{gateway: {port: $p}}')
check "S3 the patch sets a numeric gateway.port" "$(jq -r '.gateway.port | type' <<<"$patch")" number
blk_ln=$(grep -n 'DIVE-8294: this seat.s own gateway port' bin/5dive-agent-start | cut -d: -f1)
inner_ln=$(grep -n '^INNER=' bin/5dive-agent-start | cut -d: -f1)
if [[ -n "$blk_ln" && -n "$inner_ln" ]] && (( blk_ln < inner_ln )) \
   && grep -q 'OPENCLAW_PATH_OVERRIDE}' <<<"$(sed -n "${inner_ln}p" bin/5dive-agent-start)"; then
  ok "S4 the export lands before the pane command is built"
else
  bad "S4 the export lands before the pane command is built" "blk=$blk_ln inner=$inner_ln"
fi
sp=$(awk '/^cmd_agent_seed_perms\(\) \{/{on=1} on{print} on&&/^}/{exit}' src/cmd_agent_lifecycle.sh)
if grep -q 'openclaw_port_ensure "\$name"' <<<"$sp" && ! grep -qE 'with_registry_lock|flock' <<<"$sp"; then
  ok "S5 agent _seed_perms gives an openclaw seat its port, outside the registry lock"
else
  bad "S5 agent _seed_perms gives an openclaw seat its port, outside the registry lock"
fi
fn=$(awk '/^openclaw_port_ensure\(\) \{/{on=1} on{print} on&&/^}/{exit}' src/lib/agent_env.sh)
if grep -q 'openclaw-port.lock' <<<"$fn" && ! grep -q 'REGISTRY_LOCK\|with_registry_lock' <<<"$fn"; then
  ok "S6 the pick runs under its own lock, never the registry lock"
else
  bad "S6 the pick runs under its own lock, never the registry lock"
fi

[[ "$fail" -eq 0 ]]
