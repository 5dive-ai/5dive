#!/usr/bin/env bash
# DIVE-3964 isolated unit harness for the Codex channel BRIDGE HANDSHAKE — the
# reader (_channel_health_read / agent_channel_handshake), the verdict
# (_channel_health_classify), the `bound:` render, the JSON record, and the
# supervisor's repair selection.
#
# The property under test is NOT "does it spot a broken bridge". It is the pair
# of claims the whole ticket rests on:
#
#   1. NO UNTRUSTWORTHY READING IS EVER REPORTED AS BOUND. A record that is
#      absent, stale, or written to a schema this build does not know must not
#      have its own `"bound": true` believed — that is the DIVE-2766 defect one
#      layer down, and it is the only way this change could be worse than the
#      banner probe it sits above.
#   2. A RESTART IS ONLY OFFERED FOR A CAUSE A RESTART CAN FIX, AND NEVER
#      FOREVER. A named failure cause survives every restart, and a budget that
#      never runs out is how a broken bridge becomes a restart loop.
#
# Everything here runs with no root, no tmux, no agent and no bridge: the
# classifier is a pure function of (record, declared, service-state, attempts),
# and the two render programs are extracted from source the same way.
#
# Run: bash tests/codex_channel_health_unit.sh
set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# DIVE-4440: the tempdir cleanup for section 4b is FOLDED IN HERE rather than
# registered as its own `trap ... EXIT` further down. bash keeps only the LAST trap
# per signal, so the second registration this replaces had silently unarmed this
# line since DIVE-3964 landed: at c7462480 this harness printed ZERO HARNESS-RC
# lines on a PASSING run while every neighbour printed one, and the corpus contract
# that is supposed to guarantee it stayed green throughout (it matched this line and
# never looked further down the file). ${_h4b:-} because the trap is armed ~165
# lines before the variable exists, and an early exit must still print the marker.
trap 'rc=$?; [[ -n "${_h4b:-}" ]] && rm -rf "$_h4b"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"
  fi
}
tc() {  # <desc> <needle> <haystack> — contains
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual:              $3"
  fi
}
tnc() { # <desc> <needle> <haystack> — does NOT contain
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual:                  $3"
  fi
}

# Extracted by name rather than pasted: a copy would grade the copy.
for _fn in _channel_health_classify _channel_health_read agent_channel_handshake agent_channels_binding; do
  fnsrc=$(sed -n "/^${_fn}() {/,/^}/p" "$SRC/cmd_agent.sh")
  [[ -n "$fnsrc" ]] || { echo "FAIL: could not extract ${_fn} from $SRC/cmd_agent.sh"; exit 1; }
  eval "$fnsrc"
done
CODEX_HEALTH_SCHEMA=$(sed -n 's/^CODEX_HEALTH_SCHEMA=\([0-9]*\)$/\1/p' "$SRC/cmd_agent.sh")
CODEX_HEALTH_REL=$(sed -n 's/^CODEX_HEALTH_REL="\(.*\)"$/\1/p' "$SRC/cmd_agent.sh")
[[ -n "$CODEX_HEALTH_SCHEMA" && -n "$CODEX_HEALTH_REL" ]] || { echo "FAIL: could not read the handshake constants"; exit 1; }

# The clock is REAL, not a frozen date. Arms below reach the classifier two ways:
# `cl` injects $NOW as its 6th arg, but §5 calls agent_channel_handshake /
# agent_channels_binding, which have no clock seam and read wall-clock `now`.
# A pinned NOW therefore built records that were fresh to `cl` and, from the
# moment real time passed the pin + the 60s window, STALE to §5 — the harness
# reds on the calendar rather than on the tree (DIVE-4438; it froze main and 2
# PRs at 2026-09-13T12:01Z). Every timestamp here is now relative to real now.
NOW=$(date -u +%s)
at() { date -u -d "@$(( NOW - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }   # <secs-ago> -> iso

# One record, every arm varies a field off it. The shape is the one
# 5dive-plugins:plugins/telegram-codex/health.ts writes.
rec() { # rec [jq-filter-to-apply]
  jq -c --arg u "$(at 5)" --arg in "$(at 30)" --arg out "$(at 20)" \
    '{schema:1, bridge:"codex-dispatcher", bridgeVersion:"0.5.18", pid:4242,
      startedAt:"2026-09-13T11:50:00Z", updatedAt:$u, heartbeatMs:15000,
      declared:["telegram","dashboard"], listening:["telegram","dashboard"],
      bound:true, threadId:"thread-1", lastInboundAt:$in, lastOutboundAt:$out,
      queueDepth:0}' <<<'{}' | jq -c "${1:-.}"
}
cl() { # cl <record> [attempts] [max] [active] [declared]
  _channel_health_classify "$1" "${5:-telegram,dashboard}" "${4:-yes}" "${2:-0}" "${3:-2}" "$NOW"
}
st() { printf '%s' "${1%%|*}"; }                                        # state
de() { local r="${1#*|}"; printf '%s' "${r%%|*}"; }                     # detail
rp() { local r="${1%|*}"; printf '%s' "${r##*|}"; }                     # repair
ev() { printf '%s' "${1##*|}"; }                                        # evidence

# ---- §1 the six states, each from the record that defines it --------------
v=$(cl "$(rec)")
t  "1.1 a fresh, bound, matching record is bound" "bound" "$(st "$v")"
t  "1.2 and asks for no repair"                   "none"  "$(rp "$v")"
tc "1.3 naming what it is listening on"  "listening on telegram,dashboard" "$(de "$v")"

v=$(cl "$(rec '.updatedAt="'"$(at 1200)"'"')")
t  "1.4 a record past its window is stale" "stale"   "$(st "$v")"
t  "1.5 and a restart is worth trying"     "restart" "$(rp "$v")"
tc "1.6 it says how far past"              "1200s ago" "$(de "$v")"
tc "1.7 and which process to look for"     "pid 4242"  "$(de "$v")"

v=$(cl "$(rec '.listening=["telegram"]')")
t  "1.8 a listening set that disagrees is mismatched" "mismatched" "$(st "$v")"
tc "1.9 naming the channel nobody is serving" "declared but not listening: dashboard" "$(de "$v")"
v=$(cl "$(rec)" 0 2 yes telegram)
tc "1.10 and the reverse disagreement too" "listening but not declared: dashboard" "$(de "$v")"

v=$(cl "$(rec '.bound=false | .threadId=null')")
t  "1.11 running with no live thread is unbound" "unbound" "$(st "$v")"
t  "1.12 which a restart may fix"                "restart" "$(rp "$v")"

v=$(cl "$(rec '.bound=false | .failure={at:"2026-09-13T11:59:00Z",channel:"dashboard",cause:"adapter exited code=1 signal=none"}')")
t  "1.13 an unbound bridge WITH a cause is failed" "failed" "$(st "$v")"
tc "1.14 and reports the cause verbatim" "adapter exited code=1 signal=none" "$(de "$v")"
tc "1.15 with the channel it belongs to" "dashboard:" "$(de "$v")"

v=$(cl "")
t  "1.16 no record under a live service is absent" "absent" "$(st "$v")"
t  "1.17 and the bridge is worth starting"         "restart" "$(rp "$v")"
v=$(cl "" 0 2 no)
t  "1.18 no record under a dead service is expected" "absent" "$(st "$v")"
t  "1.19 so nothing is repaired"                     "none"   "$(rp "$v")"
tc "1.20 and it says what to do first" "start the agent first" "$(de "$v")"

v=$(cl "$(rec)" 0 2 yes none)
t  "1.21 nothing declared is its own state" "n/a" "$(st "$v")"
t  "1.22 with no detail to print"           ""    "$(de "$v")"

# ---- §2 an untrustworthy reading is NEVER reported as bound ---------------
# This is claim 1, and it is the only way this change could be worse than the
# probe it sits above: every record below says `"bound": true` about itself.
for arm in \
  '2.1 stale:.updatedAt="'"$(at 3600)"'"' \
  '2.2 unparseable timestamp:.updatedAt="whenever"' \
  '2.3 a schema this build does not know:.schema=2' \
  '2.4 a listening set that disagrees:.listening=[]' ; do
  desc="${arm%%:*}"; filt="${arm#*:}"
  v=$(cl "$(rec "$filt")")
  t "$desc is not reported bound" "true" "$([[ "$(st "$v")" != "bound" ]] && echo true || echo false)"
done
t "2.5 a corrupt file reads as absent, never as an error" "absent" "$(st "$(cl '{ not json')")"
t "2.6 an empty record reads as absent"                   "absent" "$(st "$(cl '{}')")"
tc "2.7 an unknown schema says which way to fix it" "upgrade the CLI or the plugin" "$(de "$(cl "$(rec '.schema=99')")")"
t  "2.8 and is never restarted blind"                "report" "$(rp "$(cl "$(rec '.schema=99')")")"

# The window is max(60s, cadence x 3) both ways: one missed beat must not
# restart a working bridge, and a tiny declared cadence must not make one
# permanently stale.
t "2.9 one missed heartbeat is not stale"  "bound" "$(st "$(cl "$(rec '.updatedAt="'"$(at 16)"'"')")")"
t "2.10 59s is not stale"                  "bound" "$(st "$(cl "$(rec '.updatedAt="'"$(at 59)"'"')")")"
t "2.11 a 10ms cadence still gets 60s"     "bound" "$(st "$(cl "$(rec '.heartbeatMs=10 | .updatedAt="'"$(at 59)"'"')")")"
t "2.12 a slow cadence widens the window"  "bound" "$(st "$(cl "$(rec '.heartbeatMs=120000 | .updatedAt="'"$(at 300)"'"')")")"
t "2.13 but not without limit"             "stale" "$(st "$(cl "$(rec '.heartbeatMs=120000 | .updatedAt="'"$(at 400)"'"')")")"
t "2.14 fractional-second timestamps parse" "bound" "$(st "$(cl "$(rec '.updatedAt="'"$(at 5 | sed 's/Z$/.123Z/')"'"')")")"

# ---- §3 the repair is bounded, and matched to the cause ------------------
# Claim 2. The ceiling lives in the classifier so the CLI and the bridge cannot
# drift apart on it, and so no caller can decide to try "just one more".
t "3.1 a restart is offered while the budget holds" "restart" "$(rp "$(cl "$(rec '.updatedAt="'"$(at 1200)"'"')" 1 2)")"
v=$(cl "$(rec '.updatedAt="'"$(at 1200)"'"')" 2 2)
t  "3.2 and withdrawn once it is spent"             "report"  "$(rp "$v")"
t  "3.3 without changing what is wrong"             "stale"   "$(st "$v")"
tc "3.4 saying why a person is needed" "did not heal it" "$(de "$v")"
t "3.5 an unbound bridge honours the ceiling"   "report" "$(rp "$(cl "$(rec '.bound=false')" 3 2)")"
t "3.6 an absent bridge honours the ceiling"    "report" "$(rp "$(cl "" 3 2)")"
t "3.7 a mismatch honours the ceiling"          "report" "$(rp "$(cl "$(rec '.listening=[]')" 3 2)")"
t "3.8 a healthy bridge is never restarted, whatever the count" "none" "$(rp "$(cl "$(rec)" 9 2)")"
# A named cause survives every restart, so it is reported on the FIRST pass.
t "3.9 a mismatch with a named cause is reported at once" "report" \
  "$(rp "$(cl "$(rec '.listening=["telegram"] | .failure={at:"x",channel:"dashboard",cause:"token revoked"}')" 0 2)")"
tc "3.10 and the cause rides along" "token revoked" \
  "$(de "$(cl "$(rec '.listening=["telegram"] | .failure={at:"x",channel:"dashboard",cause:"token revoked"}')" 0 2)")"

# ---- §4 the evidence line, and the separator that cannot be smuggled ------
v=$(cl "$(rec '.queueDepth=3 | .active={turnId:"turn-9",source:"telegram",startedAt:"x"}')")
for want in "bridge 0.5.18" "pid 4242" "queue 3" "thread thread-1" "turn turn-9 from telegram"; do
  tc "4.x the evidence carries: $want" "$want" "$(ev "$v")"
done
tc "4.6 an inbound timestamp"  "$(at 30)" "$(ev "$v")"
tc "4.7 an outbound timestamp" "$(at 20)" "$(ev "$v")"
t  "4.8 never-used channels say so, not null" "true" \
  "$([[ "$(ev "$(cl "$(rec 'del(.lastInboundAt)')")")" == *"in never"* ]] && echo true || echo false)"
# The record is JSON written by another process; a `|` inside any field would
# otherwise split this function's own output and hand the caller a wrong state.
v=$(cl "$(rec '.bound=false | .failure={at:"t",channel:"dash|board",cause:"a|b\nc"}')")
t  "4.9 a pipe in the record cannot add a field" "4" "$(awk -F'|' '{print NF}' <<<"$v")"
tnc "4.10 and is scrubbed from the detail"       "|" "$(de "$v")"
t  "4.11 a newline cannot add a line"            "1" "$(wc -l <<<"$v")"

# ---- §4b the reader builds its own path ----------------------------------
# Every arm below §5 stubs `_channel_health_read` out — it is "the one seam" —
# so nothing there executes the path this function constructs. That is exactly
# how the SC2318 defect survived: `local name="$1" path=".../${name}/..."`
# expands its words BEFORE its assignments take effect, so `${name}` read the
# CALLER's variable under dynamic scoping and was right only by accident. These
# arms call the real reader from a scope where no outer `name` exists, which is
# the condition the whole-file stub can never reproduce.
_h4b=$(mktemp -d)   # DIVE-4440: cleanup folded into the HARNESS-RC trap at the head.
mkdir -p "$_h4b/home/agent-zed/$(dirname "$CODEX_HEALTH_REL")"
printf '{"bound":true}' > "$_h4b/home/agent-zed/$CODEX_HEALTH_REL"
# Read through a `cat` shim so the arm needs no real /home seat and no sudo.
_h4b_probe() { cat() { command cat "$_h4b$1" 2>/dev/null; }; _channel_health_read "$1"; unset -f cat; }
t "4b.1 the record is read from the named seat's own path" '{"bound":true}' "$(_h4b_probe zed)"
t "4b.2 a different seat does not read it"                 ""               "$(_h4b_probe other)"
# The mutation that reds exactly this pair and nothing else: rejoin the two
# `local`s. Under dynamic scoping 4b.1 then reads `/home/agent-/...` and empties.
name=zed
t "4b.3 and a caller's unrelated \$name cannot supply it" ""               "$(_h4b_probe other)"
unset name

# ---- §5 the reader: absence is evidence only when it was expected --------
# A claude seat runs no Codex bridge. Reporting `absent` there would invent a
# fault on every seat in the fleet that is working exactly as designed.
_channel_health_read() { printf '%s' "${FAKE_RECORD:-}"; }   # the one seam
FAKE_RECORD=""
t "5.1 no record, no bridge expected -> the reader declines to answer" "" \
  "$(agent_channel_handshake a telegram,dashboard claude yes)"
t "5.2 no record, a bridge WAS expected -> absent" "absent" \
  "$(st "$(agent_channel_handshake a telegram,dashboard codex yes)")"
FAKE_RECORD=$(rec)
t "5.3 a record is believed whatever the registry calls the seat" "bound" \
  "$(st "$(agent_channel_handshake a telegram,dashboard claude yes)")"
t "5.4 nothing declared is never probed at all" "" \
  "$(agent_channel_handshake a none codex yes)"

# The banner probe must still answer for a runtime with no handshake — the
# fall-through is what keeps DIVE-2766 working, and 38 arms next door grade it.
SESSION=yes; PANE="--channels ignored (x)"$'\n'"Channels are not supported for this account"
sudo() { case "$*" in *has-session*) [[ "$SESSION" == yes ]] ;; *capture-pane*) printf '%s\n' "$PANE" ;; *) return 1 ;; esac; }
FAKE_RECORD=""
out=$(agent_channels_binding a telegram,dashboard claude yes)
t  "5.5 with no handshake a refusal still reports refused" "refused" "$(st "$out")"
t  "5.6 and keeps the three-field contract"                "3"       "$(awk -F'|' '{print NF}' <<<"$out")"
FAKE_RECORD=$(rec '.listening=["telegram"]')
out=$(agent_channels_binding a telegram,dashboard codex yes)
t  "5.7 the handshake outranks the pane when it exists" "mismatched" "$(st "$out")"
t  "5.8 and still emits three fields, not four"         "3"          "$(awk -F'|' '{print NF}' <<<"$out")"
tnc "5.9 the repair field is not printed to a human"    "restart"    "$out"

# ---- §6 the render, which is the half a human actually reads -------------
render=$(sed -n '/^      "name:        .(.name)",$/,/^    . <<<"\$obj"$/p' "$SRC/cmd_agent.sh" | sed '$d')
[[ -n "$render" ]] || { echo "FAIL: could not extract the info render program"; exit 1; }
rrec() { # rrec <state> <detail> <evidence>
  jq -nc --arg s "$1" --arg d "$2" --arg e "$3" '{
    name:"a", type:"codex", cliName:"codex", cliVersion:"1", model:null, effort:null,
    modelUnpinnedWithCreds:false, channels:"telegram,dashboard", channelsDeclared:"telegram,dashboard",
    channelsBinding:{state:$s, measured:true, detail:$d, evidence:(if $e=="" then null else $e end)},
    botUsername:"b", authProfile:null, workdir:"/w", isolation:"admin", isolationLabelled:true,
    sudo:{measured:true,grant:"g",scope:"s",runas:"r",extraEntries:false,diverges:false},
    supervisor:{stateNote:"n",note:"o",line:"l",verdict:null}, createdAt:"t"}'
}
out=$(rrec bound "listening on telegram,dashboard" "bridge 0.5.18 · queue 0" | jq -r --arg authLine ok "$render")
tc  "6.1 a bound seat finally prints YES" "bound:       YES" "$out"
tc  "6.2 and says where that came from"   "bridge handshake, fresh" "$out"
tc  "6.3 with the evidence beneath it"    "↳ bridge 0.5.18" "$out"
tnc "6.4 and raises no warning"           "WARNING: this agent DECLARES channels (telegram,dashboard) and its own channel bridge" "$out"

for arm in "stale:NO" "unbound:NO" "failed:NO" "mismatched:PARTIAL"; do
  state="${arm%%:*}"; word="${arm#*:}"
  out=$(rrec "$state" "the detail" "the evidence" | jq -r --arg authLine ok "$render")
  tc "6.x $state prints $word"          "bound:       $word — the detail" "$out"
  tc "6.x $state warns about reach"     "NOT all carrying messages"       "$out"
  tc "6.x $state names the repair"      "5dive agent restart a"           "$out"
  tc "6.x $state disarms the green lines" "not evidence against it"       "$out"
done
out=$(rrec absent "no handshake" "" | jq -r --arg authLine ok "$render")
tc  "6.21 absent prints unknown, not NO" "bound:       unknown — no handshake" "$out"
tnc "6.22 and does not page anyone"      "NOT all carrying messages" "$out"

# ---- §7 the JSON record, which is what the dashboard reads ---------------
# §6 cannot see the object program that feeds it — the hole the sibling harness
# fell into on its own mutation pass, where flipping `measured` to true for
# every state survived every printed-line arm.
cbprog=$(sed -n '/^      channelsBinding: {$/,/^      },$/p' "$SRC/cmd_agent.sh" | sed '$s/,$//')
[[ -n "$cbprog" ]] || { echo "FAIL: could not extract the channelsBinding object program"; exit 1; }
cb() { jq -nc --arg cbState "$1" --arg cbDetail "${2:-d}" --arg cbEvidence "${3:-}" "{ $cbprog }"; }
for s2 in bound stale mismatched unbound failed refused; do
  t "7.x $s2 is a MEASUREMENT" "true" "$(cb "$s2" | jq -r '.channelsBinding.measured')"
done
for s2 in unknown absent "n/a"; do
  t "7.x $s2 measured nothing" "false" "$(cb "$s2" | jq -r '.channelsBinding.measured')"
done

# ---- §8 the supervisor acts on the VERDICT, never on the state ------------
# STRUCTURAL, and labelled as such: the repair loop lives inside cmd_tick and
# cannot be extracted by name like the functions above. What these arms grade is
# the one property that keeps the ceiling meaningful — if the loop ever decides
# to restart by looking at the state itself, the classifier's withdrawal of the
# restart becomes advisory and the bridge can be restart-looped after all.
sup=$(sed -n '/DIVE-3964: CHANNEL BINDING/,/done < <(jq -c/p' "$SRC/cmd_supervisor.sh")
[[ -n "$sup" ]] || { echo "FAIL: could not extract the supervisor channel loop"; exit 1; }
tc  "8.1 it reads the repair the classifier chose" 'channelBinding.repair' "$sup"
tc  "8.2 restarting only on that verdict"          '"$cb_repair" == "restart"' "$sup"
tc  "8.3 and only when actions are armed"          '"$actions_on" == "true"' "$sup"
tnc "8.4 it never restarts on a state name"        'cb_state" == "stale"' "$sup"
tc  "8.5 a bound seat is skipped"                  '"$cb_state" != "bound"' "$sup"
tc  "8.6 the repair is audited as its own rung"    'channel-restart' "$sup"
tc  "8.7 and the report path is deduped"           "_SUP_ALERT_WINDOW_H" "$sup"
hist=$(sed -n '/^_sup_channel_repair_history() {/,/^}/p' "$SRC/cmd_supervisor.sh")
tc  "8.8 the attempt count reads that same rung"   'channel-restart' "$hist"
tc  "8.9 off the audit trail, with no new state file" "supervisor_events" "$hist"

echo "-- $PASS passed, $FAIL failed --"
(( FAIL == 0 ))
