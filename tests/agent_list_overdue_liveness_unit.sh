#!/usr/bin/env bash
# DIVE-4278 unit: `agent list` must not flag a seat OVERDUE while the heartbeat's
# own tick decided that seat was working.
#
# The defect, measured twice:
#   * main, 2026-09-10 22:37Z (control plane): quinn rendered `∿84m/5m!` while
#     /var/log/5dive-heartbeat.log printed `[quinn] busy — 1 in_progress, skip`
#     every tick and `5dive liveness` read alive (a task body written 38s prior).
#   * the v0.31.0 shakedown on lodar's box, 2026-09-11 04:49Z: 4 of 4 seats
#     flagged, 0 stalled — one mid-task, and one (`ceo`) flagged in the SAME tick
#     that logged `[ceo] active (mid-turn/conversation) — defer nudge this tick`.
# `lastRunAt` is stamped only when a wake is DELIVERED, so its age measures how
# long a seat has been continuously BUSY. The `!` inverted onto the seats doing
# the most work, and 4/4 teaches the operator to ignore the column — which is
# how the one real stall (that box had an 11-week silent timer death) is missed.
#
# Graded here, against the shared renderer both list paths use plus the stamp the
# tick writes:
#   - a seat past 2x its cadence whose tick saw it BUSY or MID-TURN is NOT
#     flagged, and its row says WHY instead of carrying a bare `!`;
#   - the reporter's 4/4 fixture reads 0/4, and the one killed-pane seat in it
#     still reads `!` — the true stall stays loud, which is the arm that matters;
#   - suppression needs POSITIVE, FRESH evidence: a lastSeenAt older than the
#     same 2x window does not clear the flag (negative control), and neither
#     does an absent one (every seat that predates this change);
#   - a never-run seat that was never seen still reads `never`+`!`;
#   - `--json` carries the verdict AND the reason string, so a dashboard need
#     not re-derive "overdue" from lastRunAt and re-create the defect;
#   - `_hb_mark_seen` writes lastSeenAt/lastSeenWhy for an enrolled seat and
#     refuses to conjure a heartbeat block for a seat that has none.
#
# Pure: no root, no systemd, no network, no tmux. The clock is PINNED as an
# argument so no arm races the wall clock.
#
# Run: bash tests/agent_list_overdue_liveness_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMPD:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent.sh"          # _agent_list_table / _agent_list_hb_json
set +e

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "output containing '$3'" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "output WITHOUT '$3'" "$2"; }

NOW=1788000000

mkrow() { # <name> <hb-json>
  jq -nc --arg n "$1" --argjson hb "$2" '[{
    name: $n, type: "claude", channels: "none", workdir: "/w", authProfile: "p",
    heartbeat: $hb, active: "active", enabled: "enabled",
    operationalState: "ready",
    sudo: {grant: "none", runas: "-", impliedIsolation: "none", measured: true,
           extraEntries: false, diverges: false},
    health: {auth: {state: "ok"}, startup: {state: "clear"}}
  }]'
}
# <everyMin> <lastRunAt> [lastSeenAt] [lastSeenWhy]
hb() {
  local base; base=$(jq -nc --argjson e "$1" --argjson l "$2" \
    '{enabled: true, everyMin: $e, fresh: false, lastRunAt: $l}')
  if [[ -n "${3:-}" ]]; then
    base=$(jq -c --argjson s "$3" --arg w "${4:-}" '. + {lastSeenAt: $s, lastSeenWhy: $w}' <<<"$base")
  fi
  printf '%s' "$base"
}
# The whole NAME field (badge + any reason), which is TAB-delimited pre-column.
namecell() { awk -v n="$1" -F'  +' '$1 ~ "^"n"( |$)" {print $1}' <<<"$2" | head -1; }
# How many seats carry the OVERDUE `!` on their badge (the `∿…!` token).
flagged() { grep -o '∿[^ ]*!' <<<"$1" | wc -l; }

echo "== the defect: a busy seat is not a stalled seat =="
# quinn's exact shape: 84m past a 5m cadence, and the tick 2 minutes ago logged
# 'busy — 1 in_progress, skip'.
Q=$(mkrow quinn "$(hb 5 $((NOW-84*60)) $((NOW-120)) 'busy 1 in_progress')")
OUT=$(_agent_list_table "$Q" "$NOW")
hasnt 'a seat the tick saw BUSY is not flagged'        "$OUT" '∿84m/5m!'
has   'and the row still reports the wake age'         "$OUT" '∿84m/5m'
has   'and the row says WHY, in the tick own words'    "$OUT" 'busy 1 in_progress'
hasnt 'a busy seat is not named in the OVERDUE legend' "$OUT" 'OVERDUE'
has   'the not-stalled legend explains the age'        "$OUT" 'not a stall'

echo "== mid-turn: the flag and the tick disagreed in the SAME pass =="
C=$(mkrow ceo "$(hb 15 $((NOW-4*3600)) $((NOW-60)) 'mid-turn')")
OUT=$(_agent_list_table "$C" "$NOW")
hasnt 'a mid-turn seat carries no ! ' "$OUT" '!'
has   'and its row reads mid-turn'    "$OUT" 'mid-turn'

echo "== the reporter 4/4 case reads 0/4, and the killed pane stays loud =="
# One seat mid-task (busy-skip), one idle (tick had no work), one mid-turn, one
# whose pane was killed: the wake is attempted and fails, so nothing stamps it.
FOUR=$(jq -nc \
  --argjson a "$(mkrow devops "$(hb 15 $((NOW-5*3600))  $((NOW-90))  'busy 1 in_progress')")" \
  --argjson b "$(mkrow ops    "$(hb 15 $((NOW-3*3600))  $((NOW-200)) 'idle (no work)')")" \
  --argjson c "$(mkrow ceo    "$(hb 15 $((NOW-4*3600))  $((NOW-45))  'mid-turn')")" \
  --argjson d "$(mkrow dead   "$(hb 15 $((NOW-11*86400)))")" '$a + $b + $c + $d')
OUT=$(_agent_list_table "$FOUR" "$NOW")
is 'exactly ONE of the four seats is flagged' "$(flagged "$OUT")" '1'
has   'and it is the killed-pane seat'        "$(namecell dead "$OUT")" '!'
hasnt 'the mid-task seat is not flagged'      "$(namecell devops "$OUT")" '!'
hasnt 'the idle seat is not flagged'          "$(namecell ops "$OUT")" '!'
hasnt 'the mid-turn seat is not flagged'      "$(namecell ceo "$OUT")" '!'
has   'the OVERDUE legend names only the dead seat' "$OUT" 'never run): dead'
has   'an idle reason is NOT sold as proof of life' "$OUT" '5dive liveness'

echo "== suppression requires POSITIVE, FRESH evidence (negative controls) =="
# Same seat, same wake age; only the observation's age moves across the window.
FRESH=$(mkrow edge "$(hb 10 $((NOW-3600)) $((NOW-1200)) 'busy 2 in_progress')")   # seen exactly 2x ago
STALE=$(mkrow edge "$(hb 10 $((NOW-3600)) $((NOW-1201)) 'busy 2 in_progress')")   # one second past 2x
hasnt 'an observation inside the window clears the flag' "$(namecell edge "$(_agent_list_table "$FRESH" "$NOW")")" '!'
has   'an observation PAST the window does not'          "$(namecell edge "$(_agent_list_table "$STALE" "$NOW")")" '!'
ZERO=$(mkrow edge "$(hb 10 $((NOW-3600)) 0 'busy 2 in_progress')")
has 'a zero lastSeenAt is absence, not evidence' "$(namecell edge "$(_agent_list_table "$ZERO" "$NOW")")" '!'
NONE=$(mkrow legacy "$(hb 5 $((NOW-68*60)))")
is 'a seat with no stamp at all is judged exactly as before' \
   "$(namecell legacy "$(_agent_list_table "$NONE" "$NOW")")" 'legacy ∿68m/5m!'
NEVER=$(mkrow newborn '{"enabled":true,"everyMin":15}')
has 'a never-run, never-seen seat still reads never and flags' \
    "$(namecell newborn "$(_agent_list_table "$NEVER" "$NOW")")" '∿never/15m!'
# ... and a never-run seat the tick DID observe is not a stall either.
NEVER2=$(mkrow newborn2 "$(jq -nc --argjson s $((NOW-60)) '{enabled:true,everyMin:15,lastSeenAt:$s,lastSeenWhy:"mid-turn"}')")
hasnt 'a never-run seat observed working is not flagged' "$(namecell newborn2 "$(_agent_list_table "$NEVER2" "$NOW")")" '!'

echo "== a fresh seat is unchanged, and carries no reason noise =="
is 'a seat inside its cadence renders the bare badge' \
   "$(namecell fresh "$(_agent_list_table "$(mkrow fresh "$(hb 5 $((NOW-60)) $((NOW-60)) 'busy 1 in_progress')")" "$NOW")")" \
   'fresh ∿1m/5m'

echo "== --json carries the verdict and the reason =="
J=$(_agent_list_hb_json "$FOUR" "$NOW")
is 'the busy seat is not overdue in json'   "$(jq -r '.[]|select(.name=="devops").heartbeatStatus.overdue' <<<"$J")" 'false'
is 'and carries the reason string'          "$(jq -r '.[]|select(.name=="devops").heartbeatStatus.reason' <<<"$J")" 'busy 1 in_progress'
is 'and the observation age'                "$(jq -r '.[]|select(.name=="devops").heartbeatStatus.seenAgeSec' <<<"$J")" '90'
is 'the killed-pane seat IS overdue in json' "$(jq -r '.[]|select(.name=="dead").heartbeatStatus.overdue' <<<"$J")" 'true'
has 'and says why it is overdue'             "$(jq -r '.[]|select(.name=="dead").heartbeatStatus.reason' <<<"$J")" 'no observed activity'
UNENROLLED=$(_agent_list_hb_json "$(mkrow asleep '{"enabled":false,"everyMin":15,"lastRunAt":0}')" "$NOW")
is 'an unenrolled seat reports null, not "not overdue"' \
   "$(jq -r '.[0].heartbeatStatus' <<<"$UNENROLLED")" 'null'

echo "== the tick writes the stamp (_hb_mark_seen) =="
TMPD=$(mktemp -d /tmp/dive4278.XXXXXX)
REGISTRY="$TMPD/registry.json"; REGISTRY_LOCK="$TMPD/registry.lock"
printf '{"agents":{"dev":{"heartbeat":{"enabled":true,"everyMin":15,"lastRunAt":7}},"bare":{"type":"claude"}}}' > "$REGISTRY"
registry_read()  { cat "$REGISTRY"; }
registry_write() { local tmp; tmp=$(mktemp "${REGISTRY}.XXXXXX"); cat > "$tmp"; mv "$tmp" "$REGISTRY"; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
# shellcheck source=/dev/null
source "$SRC/cmd_heartbeat.sh" 2>/dev/null
if declare -F _hb_mark_seen >/dev/null; then
  _hb_mark_seen dev "$NOW" "busy 3 in_progress"
  is 'the stamp lands on lastSeenAt'  "$(jq -r '.agents.dev.heartbeat.lastSeenAt' "$REGISTRY")"  "$NOW"
  is 'the reason lands verbatim'      "$(jq -r '.agents.dev.heartbeat.lastSeenWhy' "$REGISTRY")" 'busy 3 in_progress'
  is 'and the wake receipt is untouched' "$(jq -r '.agents.dev.heartbeat.lastRunAt' "$REGISTRY")" '7'
  _hb_mark_seen bare "$NOW" "mid-turn"
  is 'a seat with no heartbeat block grows no half-object' \
     "$(jq -r '.agents.bare.heartbeat // "absent"' "$REGISTRY")" 'absent'
else
  bad '_hb_mark_seen is defined' 'a function' 'missing'
fi

echo "== the tick decisions that mean 'working' all stamp =="
n_seen=$(grep -c '_hb_mark_seen "\$name"' "$SRC/cmd_heartbeat.sh")
is 'busy-skip, active-defer and no-work each record their decision' "$n_seen" '3'
# The wake-failure path must NOT stamp: an undeliverable wake is the stall this
# column exists to show, and stamping it would make the alarm unreachable.
#
# DIVE-4299 — the first version of this arm lied twice. It anchored on the FIRST
# line containing the log sentence, which a COMMENT carries as readily as code,
# and then counted `_hb_mark_seen` to END OF FILE. On 2026-09-11 DIVE-4279's own
# header comment quoted that sentence verbatim and this arm ejected PR #874 from
# the merge queue twice, over an invariant that diff never touched (it adds zero
# _hb_mark_seen calls). Same shape as DIVE-3591: a naive source scan matching the
# file's own prose. So the scan below (a) drops whole-line comments — the
# invariant is about CODE — (b) bounds its window to the wake-failure BRANCH by
# indentation instead of running to EOF, and (c) says NO-ANCHOR rather than 0
# when the log line is gone, so a renamed message fails loud instead of passing
# an arm that is no longer looking at anything.
wake_failure_stamps() { # <source-file> -> _hb_mark_seen calls inside the wake-failure branch
  awk '
    {
      raw[NR] = $0
      bare = $0; sub(/^[[:space:]]*/, "", bare); txt[NR] = bare
      match($0, /^[[:space:]]*/); ind[NR] = RLENGTH
      if (bare ~ /^#/) cmt[NR] = 1
      if (!anchor && !cmt[NR] && /_hb_log/ && /wake failed — will retry next tick/) anchor = NR
    }
    END {
      if (!anchor) { print "NO-ANCHOR"; exit }
      lo = anchor; hi = anchor; base = ind[anchor]
      for (i = anchor - 1; i >= 1;  i--) { if (cmt[i] || txt[i] == "") continue; if (ind[i] < base) break; lo = i }
      for (i = anchor + 1; i <= NR; i++) { if (cmt[i] || txt[i] == "") continue; if (ind[i] < base) break; hi = i }
      c = 0
      for (i = lo; i <= hi; i++) if (!cmt[i] && raw[i] ~ /_hb_mark_seen/) c++
      print c
    }
  ' "$1"
}
is 'the wake-failure path stamps nothing' \
   "$(wake_failure_stamps "$SRC/cmd_heartbeat.sh")" '0'

echo "== and the scan that says so is pinned, in both directions =="
FIXD="$TMPD/fx"; mkdir -p "$FIXD"
fixture() { printf '%s\n' "$2" > "$FIXD/$1.sh"; printf '%s' "$FIXD/$1.sh"; }

# (1) the PR #874 shape: a COMMENT quotes the sentence, the code stamps nothing.
is 'a COMMENT quoting the log sentence is not the wake-failure path' \
   "$(wake_failure_stamps "$(fixture comment '#!/usr/bin/env bash
# incident log, quoted verbatim: wake failed — will retry next tick
tick() {
  if wake; then
    _hb_mark_seen "$name" "$now" "mid-turn"
  else
    _hb_log "[$name] wake failed — will retry next tick"
  fi
}')")" '0'

# (2) the EOF bug: a stamp on an unrelated path after the branch closes.
is 'a stamp AFTER the branch closes is outside the window' \
   "$(wake_failure_stamps "$(fixture after '#!/usr/bin/env bash
tick() {
  if wake; then
    :
  else
    _hb_log "[$name] wake failed — will retry next tick"
  fi
  _hb_mark_seen "$name" "$now" "idle (no work)"
}')")" '0'

# (3) positive control, ABOVE the log line — an arm that cannot fail grades nothing.
is 'a stamp inside the branch, before the log, is caught' \
   "$(wake_failure_stamps "$(fixture before '#!/usr/bin/env bash
tick() {
  if wake; then
    :
  else
    _hb_mark_seen "$name" "$now" "wake failed"
    _hb_log "[$name] wake failed — will retry next tick"
  fi
}')")" '1'

# (4) positive control, BELOW the log line.
is 'a stamp inside the branch, after the log, is caught' \
   "$(wake_failure_stamps "$(fixture behind '#!/usr/bin/env bash
tick() {
  if wake; then
    :
  else
    _hb_log "[$name] wake failed — will retry next tick"
    _hb_mark_seen "$name" "$now" "wake failed"
  fi
}')")" '1'

# (5) the message renamed out from under the arm must be loud, not a silent 0.
is 'a missing log line reads NO-ANCHOR, not a passing 0' \
   "$(wake_failure_stamps "$(fixture gone '#!/usr/bin/env bash
tick() { if wake; then :; else _hb_log "[$name] could not wake"; fi; }')")" 'NO-ANCHOR'

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
