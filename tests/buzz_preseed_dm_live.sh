#!/usr/bin/env bash
# TIER: nightly — needs a live buzz relay (postgres + redis + a seeded community
# host row) that the 5-minute PR core does not stand up. In core it would SKIP every
# arm and report RC=0, which is a green that graded nothing; nightly keeps the skip
# honest and out of the PR budget. Run it by hand against a local relay per the
# recipe below, and cite the run in the row — that is how DIVE-3665 was graded.
# DIVE-3665 LIVE harness: _buzz_preseed_dm against a REAL buzz binary and a REAL
# relay. The unit harness (tests/buzz_preseed_dm_unit.sh) drives the same function
# against a stub *we wrote*, so it can only confirm our model of the relay — and
# this arc's named defect class is accepted-but-unservable, which is exactly what
# a self-authored stub cannot produce. This file removes that circularity.
#
# WHAT IT NEEDS: a reachable relay (BUZZ_LIVE_RELAY, default http://127.0.0.1:3399)
# and a real `buzz` on PATH. Stand one up from the buzz repo with postgres+redis:
#   DATABASE_URL=postgres://…  REDIS_URL=redis://127.0.0.1:6379 \
#   BUZZ_BIND_ADDR=127.0.0.1:3399 BUZZ_AUTO_MIGRATE=1 BUZZ_GIT_CONFORMANCE_PROBE=false \
#   ./target/debug/buzz-relay
#   scripts/seed-local-community.sh    # the relay fails closed on an unbound Host
#
# IT SKIPS LOUDLY when no relay is reachable — a skip and a pass must never render
# the same, so the skip prints SKIP lines and names the reason, and the summary
# reports the arms it could not run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
JOINF="$SRC/cmd_agent_buzz_join.sh"
[[ -f "$JOINF" ]] || { echo "FAIL - $JOINF is not on disk — this harness would grade nothing"; echo "0 passed, 1 failed"; exit 1; }

RELAY="${BUZZ_LIVE_RELAY:-http://127.0.0.1:3399}"
BIN="${BUZZ_LIVE_BIN:-$(command -v buzz 2>/dev/null)}"

PASS=0; FAIL=0; SKIP=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t(){ SKIP=$((SKIP+1)); printf 'SKIP - %s\n   %s\n' "$1" "${2:-}"; }
summary(){ printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"; [[ "$FAIL" -eq 0 ]]; }

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do source "$SRC/$f"; done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz.sh"
# shellcheck source=/dev/null
source "$JOINF"
set +e

# ---------------------------------------------------------------------------
# PRE-FLIGHT. Both of these are the difference between "measured" and "assumed".
# ---------------------------------------------------------------------------
# DIVE-3675: THE VERDICT LINE MUST BE REACHED IN AN ENVIRONMENT THAT HAS NEITHER.
# Each pre-flight skip below used to call summary and exit the process. That is a correct
# verdict for a reader and an invisible one for tests/meta/harness-verdict-probe.sh: the
# probe injects its mutation immediately before the FINAL verdict line and requires the
# harness to report it, so a harness that leaves earlier reports `not-reached`. No CI
# runner has a `buzz` binary or a reachable relay, so EVERY lane took the binary-missing
# exit, the union read NEVER PROBED across all seven environments, and
# harness-verdict-union went red — which is what refused the v0.21.3 cut on 2026-08-22
# and pinned the fleet at v0.21.2.
#
# So the pre-flight skips `return` out of this function instead of leaving the process,
# and the file ends with exactly ONE terminal `summary`. Reached in every environment,
# mutable by the probe, and the skip still renders as a skip: PASS/FAIL/SKIP are globals,
# summary() is unchanged, and a relay-less run prints the same SKIP lines and the same
# tally it printed before. The exit STATUS is unchanged too, in both directions: summary
# ends in `[[ "$FAIL" -eq 0 ]]`, so a skip-only run still exits 0 and the fixture failure
# still exits 1 — it now does so from the bottom of the file rather than from the middle.
#
# NOT an ALLOW_UNPROBEABLE entry: that list means "no identifiable verdict variable", and
# this harness has one. NOT a SLOW_HARNESSES entry either — it is not killed by the
# timeout, it leaves early. Naming it in either place would have put a false reason on
# the record for a harness that is neither unprobeable nor slow.
live_arms() {
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  skip_t "live arms need a real buzz binary" "no executable buzz on PATH (set BUZZ_LIVE_BIN)"
  return
fi

CALLS=$(mktemp)
_buzz_cli() { # the ONLY thing shadowed is the sudo hop; the binary and relay are real
  local runas="$1" bin="$2" relay="$3" key="$4"; shift 4
  printf '%s\n' "[$runas] $*" >>"$CALLS"
  printf '%s' "$key" | env BUZZ_RELAY_URL="$relay" bash -c \
    'IFS= read -r k; export BUZZ_PRIVATE_KEY="$k"; b="$1"; shift; exec "$b" "$@"' _ "$bin" "$@"
}

# fresh keys per run, so a re-run never grades a thread a previous run left behind
SEED="${BUZZ_LIVE_SEED:-$$}"
OWNER_SK=$(python3 -c "print('%064x' % ((int('$SEED')*2654435761 + 0x11a1) % (2**256-1) or 1))")
AGENT_SK=$(python3 -c "print('%064x' % ((int('$SEED')*40503 + 0x22b2) % (2**256-1) or 1))")
OWNER_PUB=$(printf '%s' "$OWNER_SK" | _buzz_xonly_pubkey 2>/dev/null)
AGENT_PUB=$(printf '%s' "$AGENT_SK" | _buzz_xonly_pubkey 2>/dev/null)
[[ "$OWNER_PUB" =~ ^[0-9a-f]{64}$ && "$AGENT_PUB" =~ ^[0-9a-f]{64}$ ]] \
  || { bad_t "fixture: two real keypairs derive" "owner='$OWNER_PUB' agent='$AGENT_PUB'"; return; }

REACH=$(_buzz_cli q "$BIN" "$RELAY" "$OWNER_SK" channels list 2>&1)
if [[ "$REACH" == *'"network_error"'* || -z "$REACH" ]]; then
  skip_t "live arms need a reachable relay at $RELAY" "channels list answered: ${REACH:0:160}"
  skip_t "the seed round-trips against a real relay" "no relay"
  skip_t "a second preseed leaves exactly ONE thread on a real relay" "no relay"
  skip_t "the dms-list fast path is exercised against the real relay" "no relay"
  return
fi

# NEGATIVE CONTROL, and it runs BEFORE the positive arms on purpose: an empty answer
# and an unasked question are indistinguishable otherwise. A dead port must produce a
# visibly DIFFERENT shape from the live relay's empty list, or every "it is not there"
# below is unfalsifiable. (community/wiki/dms-list-returns-empty-so-a-dm-poller-has-
# nothing-to-discover.md — the same control that caught the DIVE-3560 discovery bug.)
DEAD=$(_buzz_cli q "$BIN" "http://127.0.0.1:1" "$OWNER_SK" channels list 2>&1)
[[ "$DEAD" == *'network_error'* && "$REACH" != *'network_error'* ]] \
  && ok_t "negative control: a dead relay answers network_error, the live one does not (an empty list is the RELAY's answer)" \
  || bad_t "negative control: a dead relay answers network_error, the live one does not" \
           "dead='${DEAD:0:120}' live='${REACH:0:120}' — an empty result here would be unreadable"

# --- 1. the seed round-trips: opened on a real relay, read back from the owner's view
: >"$CALLS"
OUT1=$(_buzz_preseed_dm quinn "$BIN" "$RELAY" "$OWNER_SK" "$OWNER_PUB" "$AGENT_PUB" dev ",," 2>&1); RC1=$?
MINE1=$(_buzz_cli q "$BIN" "$RELAY" "$OWNER_SK" channels list --member 2>/dev/null)
DMID=$(python3 -c "
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
print(next((r.get('channel_id') or r.get('id') for r in rows if r.get('name')=='DM'), ''))" <<<"$MINE1")
[[ "$RC1" -eq 0 && -n "$DMID" ]] \
  && ok_t "the seed round-trips: _buzz_preseed_dm opens a DM on a REAL relay and it reads back in the owner's own room list ($DMID)" \
  || bad_t "the seed round-trips against a real relay" "rc=$RC1 dm_id='${DMID:-<none>}' out=${OUT1:0:200} list=${MINE1:0:200}"

# the direction is the whole point: the thread must hold the AGENT's key, not just exist
MEM=$(_buzz_cli q "$BIN" "$RELAY" "$OWNER_SK" channels members --channel "$DMID" 2>/dev/null)
[[ "$MEM" == *"$AGENT_PUB"* && "$MEM" == *"$OWNER_PUB"* ]] \
  && ok_t "the real relay reports BOTH the owner and the agent as members (the thread is the customer's, addressed to the agent)" \
  || bad_t "the real relay reports both participants" "members=${MEM:0:240}"

# --- 2. idempotence on the real relay -------------------------------------------
: >"$CALLS"
OUT2=$(_buzz_preseed_dm quinn "$BIN" "$RELAY" "$OWNER_SK" "$OWNER_PUB" "$AGENT_PUB" dev ",," 2>&1); RC2=$?
CALLS2=$(cat "$CALLS")
MINE2=$(_buzz_cli q "$BIN" "$RELAY" "$OWNER_SK" channels list --member 2>/dev/null)
NDM=$(python3 -c "
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
print(len([r for r in rows if r.get('name')=='DM']))" <<<"$MINE2")
[[ "$RC2" -eq 0 && "$NDM" == "1" ]] && ! grep -q 'dms open' <<<"$CALLS2" \
  && ok_t "a second preseed leaves exactly ONE thread on the REAL relay and does not call 'dms open' (join runs on every pair and every enable)" \
  || bad_t "a second preseed leaves exactly ONE thread on the REAL relay" \
           "rc=$RC2 threads=$NDM opened_again=$(grep -c 'dms open' <<<"$CALLS2") out=${OUT2:0:160} — the customer's DM list grows one row per pair"

# --- 3. the dms-list FAST PATH, measured against the real relay -----------------
# DIVE-3560 measured `dms list` empty on sure-redwood (2026-08-18) and the dedupe was
# therefore built on `channels list --member` as the authority. That root cause was
# fixed upstream, so a current relay MAY serve the verb — and if it does, the fast
# path is the branch that actually runs in production. This arm reports which one
# answered instead of assuming, and grades the fast path only when the relay serves it.
DMSL=$(_buzz_cli q "$BIN" "$RELAY" "$OWNER_SK" dms list 2>/dev/null)
if [[ "$DMSL" == *"$DMID"* ]]; then
  # the relay serves the verb: the fast path must SHORT-CIRCUIT, i.e. the dedupe
  # answers without ever reaching the channels-list authority.
  : >"$CALLS"
  FOUND=$(_buzz_dm_id_for quinn "$BIN" "$RELAY" "$OWNER_SK" "$OWNER_PUB" "$AGENT_PUB" ",,")
  TRACE=$(cat "$CALLS")
  [[ "$FOUND" == "$DMID" ]] && ! grep -q 'channels list' <<<"$TRACE" \
    && ok_t "the relay SERVES 'dms list' and the fast path short-circuits on it (no channels-list fallback) — the branch is live in production, not dead code" \
    || bad_t "the fast path short-circuits on a real 'dms list'" \
             "found='${FOUND:-<none>}' want='$DMID'; calls made: $(tr '\n' '|' <<<"$TRACE") — a parse failure here falls through silently and the branch never runs"
else
  skip_t "the dms-list fast path is exercised against the real relay" \
         "this relay answers 'dms list' without the seeded id (${DMSL:0:120}) — the DIVE-3560 shape; the channels-list authority is what runs here, and arms 1-2 above already graded it"
fi

# --- 4. a DM PER buzz-enabled agent, not one DM ------------------------------
# The row says "preseed a DM thread per buzz-enabled agent", and arms 1-3 only ever
# had one agent in play — so they cannot see the failure where the SECOND agent's
# preseed finds the FIRST agent's thread and suppresses itself. That is a live risk
# rather than a theoretical one: the channels-list authority matches on membership
# SHAPE (a 2-occupant room containing the owner), and every preseeded DM has exactly
# that shape. A dedupe that checked shape without checking WHICH agent is in it would
# give the customer one thread and N-1 agents still needing plus-and-search.
AGENT2_SK=$(python3 -c "print('%064x' % ((int('$SEED')*77003 + 0x33c3) % (2**256-1) or 1))")
AGENT2_PUB=$(printf '%s' "$AGENT2_SK" | _buzz_xonly_pubkey 2>/dev/null)
if [[ ! "$AGENT2_PUB" =~ ^[0-9a-f]{64}$ || "$AGENT2_PUB" == "$AGENT_PUB" ]]; then
  bad_t "fixture: a SECOND distinct agent key derives" "agent2='$AGENT2_PUB' agent1='$AGENT_PUB'"
else
  : >"$CALLS"
  OUT3=$(_buzz_preseed_dm quinn "$BIN" "$RELAY" "$OWNER_SK" "$OWNER_PUB" "$AGENT2_PUB" dev2 ",," 2>&1); RC3=$?
  MINE3=$(_buzz_cli q "$BIN" "$RELAY" "$OWNER_SK" channels list --member 2>/dev/null)
  NDM3=$(python3 -c "
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
print(len([r for r in rows if r.get('name')=='DM']))" <<<"$MINE3")
  [[ "$RC3" -eq 0 && "$NDM3" == "2" ]] \
    && ok_t "a SECOND buzz-enabled agent gets its OWN thread — 2 agents, 2 DMs (the row is 'a DM per agent', not 'a DM')" \
    || bad_t "a second buzz-enabled agent gets its own thread" \
             "rc=$RC3 threads=$NDM3 (want 2) out=${OUT3:0:200} — agent 2's preseed matched agent 1's thread and suppressed itself; that agent still costs the customer a plus-and-search"

  # and the threads must be addressed to DIFFERENT agents. Two rooms of the right
  # shape is not the claim; two rooms holding the two DIFFERENT agent keys is.
  IDS=$(python3 -c "
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
print(' '.join(str(r.get('channel_id') or r.get('id')) for r in rows if r.get('name')=='DM'))" <<<"$MINE3")
  SEEN1=0; SEEN2=0
  for cid in $IDS; do
    M=$(_buzz_cli q "$BIN" "$RELAY" "$OWNER_SK" channels members --channel "$cid" 2>/dev/null)
    [[ "$M" == *"$AGENT_PUB"*  ]] && SEEN1=1
    [[ "$M" == *"$AGENT2_PUB"* ]] && SEEN2=1
  done
  (( SEEN1 == 1 && SEEN2 == 1 )) \
    && ok_t "the two threads are addressed to the two DIFFERENT agents (per-agent, verified by membership on the real relay)" \
    || bad_t "the two threads are addressed to two different agents" \
             "agent1_found=$SEEN1 agent2_found=$SEEN2 over ids [$IDS] — a duplicate thread for one agent reads the same as per-agent coverage by count alone"
fi
}

live_arms
# CALLS is only assigned once the binary pre-flight passes, and `set -u` is in force.
rm -f "${CALLS:-}"
summary
# …and the verdict is spelled HERE, at top level, as the last executable line of the
# file. summary() already ends in the same expression, but harness-verdict-probe.sh
# scans BACKWARDS for the last verdict-SHAPED line and stops at the first one it can
# mutate — which, before this line existed, was the `(( SEEN1 == 1 && SEEN2 == 1 ))`
# assertion inside the last live-only arm. SEEN1 is a real flag with numeric
# assignments, so the probe accepted it and injected there: deep inside the branch
# that needs a relay, i.e. somewhere no CI runner ever reaches. That is why this
# harness read `not-reached` in all seven environments rather than UNPROBEABLE, and
# why the union called it NEVER PROBED.
#
# So: an unambiguous, always-reached verdict on FAIL, after the last arm and outside
# every branch. The probe injects `FAIL=$((FAIL+1))` above it and the harness must
# exit non-zero — which is the claim the union needs and could not previously obtain.
[[ "$FAIL" -eq 0 ]]
