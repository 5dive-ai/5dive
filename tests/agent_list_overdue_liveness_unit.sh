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

echo "== DIVE-4310: the stall window has a 15-minute FLOOR =="
# Measured on the control plane 2026-09-11 11:44Z: quinn and main2 read OVERDUE
# while both were mid-grade at a 1-minute cadence. 2x a 1m cadence is 120
# SECONDS, so any turn longer than two minutes outruns the window and the seat
# reads stalled while it is working. The window is now max(2x cadence, 15m).
FAST=$(mkrow quinn "$(hb 1 $((NOW-10*60)))")            # 10m since the last wake, 1m cadence, never observed
hasnt 'a 1m-cadence seat 10m past its wake is inside the floor' \
      "$(namecell quinn "$(_agent_list_table "$FAST" "$NOW")")" '!'
FAST2=$(mkrow quinn "$(hb 1 $((NOW-16*60)))")           # past the floor
has   'and past 15m it flags again — the floor is not a mute' \
      "$(namecell quinn "$(_agent_list_table "$FAST2" "$NOW")")" '!'
EDGE_IN=$(mkrow edge2 "$(hb 1 $((NOW-900)))")           # exactly 15m
EDGE_OUT=$(mkrow edge2 "$(hb 1 $((NOW-901)))")          # one second past
hasnt 'exactly 15m is inside the window' "$(namecell edge2 "$(_agent_list_table "$EDGE_IN" "$NOW")")"  '!'
has   'one second past 15m is outside'   "$(namecell edge2 "$(_agent_list_table "$EDGE_OUT" "$NOW")")" '!'
# A FLOOR, never a cap: every cadence at or above 8 minutes is judged exactly as
# before, which is the arm that keeps this from being a fleet-wide mute.
SLOW=$(mkrow slow "$(hb 30 $((NOW-31*60)))")            # 31m at a 30m cadence: inside 2x (60m), as before
hasnt 'a 30m-cadence seat inside 2x is not flagged' "$(namecell slow "$(_agent_list_table "$SLOW" "$NOW")")" '!'
SLOW2=$(mkrow slow "$(hb 30 $((NOW-61*60)))")           # past 2x
has 'a 30m-cadence seat past 2x still flags on 2x, not on 15m' \
    "$(namecell slow "$(_agent_list_table "$SLOW2" "$NOW")")" '!'
MED=$(mkrow med "$(hb 15 $((NOW-16*60)))")              # 16m at 15m: 2x=30m, floor irrelevant
hasnt 'a 15m-cadence seat is unmoved by the floor' "$(namecell med "$(_agent_list_table "$MED" "$NOW")")" '!'
# The observation window moves with it, or a fast seat seen working 10m ago is
# still called stalled by the other half of the predicate.
SEEN=$(mkrow fastseen "$(hb 1 $((NOW-3600)) $((NOW-600)) 'mid-turn')")
hasnt 'an observation 10m old clears a 1m-cadence seat' \
      "$(namecell fastseen "$(_agent_list_table "$SEEN" "$NOW")")" '!'
SEEN2=$(mkrow fastseen "$(hb 1 $((NOW-3600)) $((NOW-1000)) 'mid-turn')")
has 'an observation past the floor does not' \
    "$(namecell fastseen "$(_agent_list_table "$SEEN2" "$NOW")")" '!'

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
# Same class as the arm below (DIVE-4299): a raw grep counts a COMMENT that
# quotes the call as readily as the call itself. Drop whole-line comments.
stamp_call_sites() { # <source-file> -> code lines calling _hb_mark_seen "$name"
  grep -v '^[[:space:]]*#' "$1" | grep -c '_hb_mark_seen "\$name"'
}
n_seen=$(stamp_call_sites "$SRC/cmd_heartbeat.sh")
is 'busy-skip, active-defer and no-work each record their decision' "$n_seen" '3'
CMT_FIX="$TMPD/stamp_comment.sh"
{ printf '# a comment quoting the call: _hb_mark_seen "$name" "$now" "why"\n'
  cat "$SRC/cmd_heartbeat.sh"; } > "$CMT_FIX"
is 'and a COMMENT quoting that call does not inflate the count' \
   "$(stamp_call_sites "$CMT_FIX")" '3'
# The wake-failure path must NOT stamp: an undeliverable wake is the stall this
# column exists to show, and stamping it would make the alarm unreachable.
#
# DIVE-4299 + DIVE-4310, RECONCILED. Two rows fixed half of this arm each, and
# the halves are both load-bearing:
#
#   * DIVE-4278's original anchored on the FIRST line carrying the verdict's
#     PROSE ("wake failed — will retry next tick") — which a comment carries as
#     readily as code — then counted `_hb_mark_seen` to END OF FILE. On
#     2026-09-11 DIVE-4279's header comment quoted that sentence verbatim and
#     this arm ejected PR #874 from the merge queue twice, over an invariant
#     that diff never touched (it adds zero stamps). Same shape as DIVE-3591.
#   * DIVE-4310 replaced the prose anchor with the branch's own CODE line and
#     added the two arms below — but kept scanning to EOF and kept matching
#     comments, so a bare comment naming `_hb_mark_seen` three lines under its
#     own anchor still reds it (measured by quinn on main, 2026-09-11).
#
# So, together: (a) the anchor is `sk_fail=$((sk_fail + 1))`, and
# `^[[:space:]]*sk_fail=` is unsatisfiable by a comment because the `#` would
# have to come first — that is what makes it STRUCTURAL, not that it is short;
# (b) the window is the BRANCH, bounded by indentation in BOTH directions —
# forward-only misses a stamp placed above the counter, the likeliest real
# violation; (c) comments inside that window are dropped, because the invariant
# is about CODE; (d) a vanished anchor prints NO-ANCHOR, never a passing 0, so
# renaming the counter fails LOUD instead of grading nothing forever; (e) a
# branch collapsed onto its own if/else line carries the enclosing block's
# indent, so it is graded alone rather than expanded into its siblings.
FAIL_LN=$(grep -n '^[[:space:]]*sk_fail=\$((sk_fail + 1))' "$SRC/cmd_heartbeat.sh" | cut -d: -f1 | head -1)
is 'the wake-failure verdict is exactly one code line' \
   "$(grep -c '^[[:space:]]*sk_fail=\$((sk_fail + 1))' "$SRC/cmd_heartbeat.sh")" '1'
has 'and the verdict names the step that failed' \
    "$(sed -n "${FAIL_LN}p" "$SRC/cmd_heartbeat.sh")" '_HB_WAKE_FAIL_REASON'
wake_failure_stamps() { # <source-file> -> _hb_mark_seen calls inside the wake-failure branch
  awk '
    {
      raw[NR] = $0
      bare = $0; sub(/^[[:space:]]*/, "", bare); txt[NR] = bare
      match($0, /^[[:space:]]*/); ind[NR] = RLENGTH
      if (bare ~ /^#/) cmt[NR] = 1
      if (!anchor && !cmt[NR] && $0 ~ /(^|[[:space:];&|])sk_fail=\$\(\([[:space:]]*sk_fail[[:space:]]*\+[[:space:]]*1[[:space:]]*\)\)/) {
        anchor = NR
        # A branch collapsed onto its own if/else line carries the indent of the
        # enclosing block, so expanding by indent would swallow its siblings.
        # Such a line IS the whole branch: grade it alone.
        if ($0 ~ /(^|[[:space:];])(if|elif|else|then)([[:space:];]|$)/) solo = 1
      }
    }
    END {
      if (!anchor) { print "NO-ANCHOR"; exit }
      lo = anchor; hi = anchor; base = ind[anchor]
      if (!solo) {
        for (i = anchor - 1; i >= 1;  i--) { if (cmt[i] || txt[i] == "") continue; if (ind[i] < base) break; lo = i }
        for (i = anchor + 1; i <= NR; i++) { if (cmt[i] || txt[i] == "") continue; if (ind[i] < base) break; hi = i }
      }
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

# (1) the PR #874 shape, now in the form that survives BOTH rewordings: a
# comment quotes the retired log sentence AND a comment names the stamp, while
# the code stamps nothing. This is the control main fails today.
is 'comments quoting the log sentence and the stamp are not the wake-failure path' \
   "$(wake_failure_stamps "$(fixture comment '#!/usr/bin/env bash
# incident log, quoted verbatim: wake failed — will retry next tick
# and the invariant it guards: the branch must not call _hb_mark_seen
tick() {
  if wake; then
    _hb_mark_seen "$name" "$now" "mid-turn"
  else
    sk_fail=$((sk_fail + 1)); _hb_log "[$name] wake failed at ${_HB_WAKE_FAIL_REASON} — will retry next tick"
  fi
}')")" '0'

# (2) the EOF bug: a stamp on an unrelated path after the branch closes.
is 'a stamp AFTER the branch closes is outside the window' \
   "$(wake_failure_stamps "$(fixture after '#!/usr/bin/env bash
tick() {
  if wake; then
    :
  else
    sk_fail=$((sk_fail + 1)); _hb_log "[$name] wake failed"
  fi
  _hb_mark_seen "$name" "$now" "idle (no work)"
}')")" '0'

# (3) positive control, ABOVE the counter — an arm that cannot fail grades nothing.
is 'a stamp inside the branch, before the counter, is caught' \
   "$(wake_failure_stamps "$(fixture before '#!/usr/bin/env bash
tick() {
  if wake; then
    :
  else
    _hb_mark_seen "$name" "$now" "wake failed"
    sk_fail=$((sk_fail + 1))
    _hb_log "[$name] wake failed"
  fi
}')")" '1'

# (4) positive control, BELOW the counter.
is 'a stamp inside the branch, after the counter, is caught' \
   "$(wake_failure_stamps "$(fixture behind '#!/usr/bin/env bash
tick() {
  if wake; then
    :
  else
    sk_fail=$((sk_fail + 1))
    _hb_mark_seen "$name" "$now" "wake failed"
  fi
}')")" '1'

# (5) a COMMENT naming the stamp INSIDE the window is prose, not a violation.
# This is precisely the line quinn injected three below main's own anchor to
# show the wire was still live there.
is 'a COMMENT naming the stamp inside the branch is not a violation' \
   "$(wake_failure_stamps "$(fixture incomment '#!/usr/bin/env bash
tick() {
  if wake; then
    :
  else
    sk_fail=$((sk_fail + 1))
    # deliberately does NOT call _hb_mark_seen — see DIVE-4278
    _hb_log "[$name] wake failed"
  fi
}')")" '0'

# (6) the counter renamed out from under the arm must be loud, not a silent 0.
is 'a missing anchor reads NO-ANCHOR, not a passing 0' \
   "$(wake_failure_stamps "$(fixture gone '#!/usr/bin/env bash
tick() { if wake; then :; else wake_failures=$((wake_failures + 1)); fi; }')")" 'NO-ANCHOR'

# (7)/(8) a branch collapsed onto one line is graded alone, not widened to its siblings.
is 'a collapsed one-line branch does not swallow the next statement' \
   "$(wake_failure_stamps "$(fixture collapsed '#!/usr/bin/env bash
tick() {
  if wake; then :; else sk_fail=$((sk_fail + 1)); fi
  _hb_mark_seen "$name" "$now" "idle (no work)"
}')")" '0'
is 'and a violation ON that collapsed line is still caught' \
   "$(wake_failure_stamps "$(fixture collapsed_bad '#!/usr/bin/env bash
tick() {
  if wake; then :; else sk_fail=$((sk_fail + 1)); _hb_mark_seen "$n" "$t" "x"; fi
}')")" '1'

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
