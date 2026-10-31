#!/usr/bin/env bash
# DIVE-7307 unit: `agent list` must show a seat's a2a spool depth, so a lead does
# not read `idle (no work)` as "my order never landed" while it waits to drain.
#
# The defect (chill-gorge, 2026-10-30): the row read `scout ∿25d/30m idle (no
# work)` while `agent send scout` had already spooled the order (#1). The lead
# nearly did the seat's work itself, one resend away from a duplicate order.
# The spool is only countable as `sudo -u agent-<seat>`, and `agent list` is a
# rootless read (DIVE-1074), so the depth has to be recorded where that read
# can see it — by the root parties that move the spool.
#
# Graded here:
#   A. a real `_a2a_queue_put` records the depth and the rootless reader sees it;
#   B. the real heartbeat sweep drains the spool and the marker is gone after it;
#   C. the sweep clears a marker the spool no longer backs (hand-emptied spool);
#   D. the row renders `idle (no work), 1 spooled`, --json carries a number, and
#      the legend says the message landed;
#   E. negative control: an empty spool renders byte-identical to a row from
#      before the field existed, and prints no spool legend;
#   F. the `idle (no work)` legend no longer says there was nothing to dispatch;
#   G. the Python snapshot `agent list` really runs (DIVE-4100) reads the same
#      marker, rootless.
#
# MUTATION: drop the `_a2a_spool_mark` call from `_a2a_queue_put` and arm A goes
# red; drop the one in the sweep's scan loop and arm C goes red; drop `sp_tag`
# from the row and arm D goes red; drop `a2aSpooled` from the shaper and arm G
# goes red. On the pre-fix tree the helpers do not exist
# and arms A-D fail on the first read.
#
# Boundaries only are stubbed: sudo, systemd, tmux delivery, the registry, the
# idle predicate. _a2a_queue_put, a2a_queue_flush_one, _hb_a2a_queue_sweep and
# _agent_list_table stay REAL.
#
# Run: bash tests/agent_list_spool_depth_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMPROOT="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-7307}"; echo "HARNESS-RC=$rc"' EXIT
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
source "$SRC/cmd_agent.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_runtime.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_heartbeat.sh"

set +e

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "output containing '$3'" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "output WITHOUT '$3'" "$2"; }

# --- boundaries -------------------------------------------------------------
STATE_DIR="${TMPROOT}/state"; mkdir -p "$STATE_DIR"
DELIVERED="${TMPROOT}/delivered.log"; : >"$DELIVERED"
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  [[ "${a[0]:-}" == "-u" ]] && a=("${a[@]:2}")
  "${a[@]}"
}
systemctl() { return 0; }
_hb_log() { :; }
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
_hb_agent_idle() { return 0; }
inject_and_submit() { printf '%s\t%s\n' "$1" "$2" >>"$DELIVERED"; return 0; }
registry_read() { printf '{"agents":{"scout":{},"head":{}}}\n'; }
# DIVE-6878: a budget, not 0. The sweep's deadline is whole seconds (date +%s),
# so with 0 a clock tick between computing it and the first check stopped the
# sweep after one message: the merge queue went red twice at 14.79->15.03s and
# 34.83->35.0s. 30s only bounds a broken drain; a working one never waits.
_HB_A2A_DRAIN_BUDGET_SEC=30; _HB_A2A_DRAIN_POLL_SEC=0

marker() { cat "${STATE_DIR}/a2a-spool/${1}" 2>/dev/null || printf 'absent'; }

echo "== A. a spooled send records the depth where a rootless read sees it =="
_a2a_queue_put scout "order one"
is  'one put records depth 1'               "$(marker scout)" '1'
_a2a_queue_put scout "order two"
is  'a second put records depth 2'          "$(marker scout)" '2'
is  'the rootless reader returns it'        "$(_a2a_spool_marked scout)" '2'
is  'a seat that never spooled reads 0'     "$(_a2a_spool_marked head)" '0'
perm=$(stat -c '%a' "${STATE_DIR}/a2a-spool/scout")
is  'the marker is group-readable, like the registry' "$perm" '640'

echo "== B. the drain empties the spool and the marker goes with it =="
_hb_a2a_queue_sweep
is  'the sweep delivered both messages'     "$(wc -l <"$DELIVERED" | tr -d ' ')" '2'
is  'no marker once the spool is drained'   "$(marker scout)" 'absent'
is  'and the reader is back to 0'           "$(_a2a_spool_marked scout)" '0'

echo "== C. the tick clears a marker the spool no longer backs =="
_a2a_queue_put scout "order three"
is  'marker back at 1'                      "$(marker scout)" '1'
rm -f "$(_a2a_queue_dir scout)"/*.msg       # emptied by hand, no writer told
_hb_a2a_queue_sweep
is  'the next sweep clears the stale marker' "$(marker scout)" 'absent'

echo "== D. the row, the --json and the legend =="
NOW=1788000000
mkrow() { # <name> <spooled-json-or-null>
  jq -nc --arg n "$1" --argjson sp "$2" --argjson now "$NOW" '[{
    name: $n, type: "claude", channels: "none", workdir: "/w", authProfile: "p",
    heartbeat: {enabled: true, everyMin: 30, fresh: false,
                lastRunAt: ($now - 25*86400), lastSeenAt: ($now - 60),
                lastSeenWhy: "idle (no work)"},
    active: "active", enabled: "enabled", operationalState: "ready",
    sudo: {grant: "none", runas: "-", impliedIsolation: "none", measured: true,
           extraEntries: false, diverges: false},
    health: {auth: {state: "ok"}, startup: {state: "clear"}}
  } + (if $sp == null then {} else {a2aSpooled: $sp} end)]'
}
OUT=$(_agent_list_table "$(mkrow scout 1)" "$NOW")
has   'the reporter row shows the spool'      "$OUT" 'scout ∿25d/30m idle (no work), 1 spooled'
has   'the legend names the seat and depth'   "$OUT" 'waiting in its spool: scout (1)'
has   'and says not to re-send'               "$OUT" 'Do not re-send'
J=$(_agent_list_hb_json "$(mkrow scout 3)" "$NOW" | jq -r '.[0].a2aSpooled | type + ":" + tostring')
is    '--json carries the depth as a number'  "$J" 'number:3'
UNENR=$(jq -c '.[0].heartbeat.enabled = false' <<<"$(mkrow quiet 2)")
OUT=$(_agent_list_table "$UNENR" "$NOW")
has   'a seat with no badge still shows it'   "$OUT" 'quiet 2 spooled'

echo "== E. negative control: an empty spool renders as before =="
BEFORE=$(_agent_list_table "$(mkrow scout null)" "$NOW")
ZERO=$(_agent_list_table "$(mkrow scout 0)" "$NOW")
is    'depth 0 is byte-identical to no field' "$ZERO" "$BEFORE"
hasnt 'and the row carries no spool tag'       "$(grep '^scout' <<<"$ZERO")" 'spooled'
hasnt 'and no spool legend is printed'         "$ZERO" 'waiting in its spool'

echo "== F. the idle legend no longer says nothing was waiting =="
hasnt 'the old claim is gone'                 "$ZERO" 'the tick had nothing to dispatch'
has   'it points at the spool marker'         "$ZERO" 'N spooled'

echo "== G. the production snapshot (the rootless shaper) reads the marker =="
SNAP="${TMPROOT}/snap"; mkdir -p "$SNAP/a2a-spool"
printf '{"agents":{"scout":{"type":"claude","channels":"none"},"head":{"type":"claude","channels":"none"}}}\n' >"$SNAP/agents.json"
printf '1\n' >"$SNAP/a2a-spool/scout"
sed -n '/^# __5DIVE_AGENT_LIST_PY_BEGIN__$/,/^# __5DIVE_AGENT_LIST_PY_END__$/p' "$SRC/cmd_agent.sh" >"$SNAP/shaper.py"
SJ=$(AGENT_ENV_DIR="$SNAP/none" QUOTA_SNAPSHOT_FILE="$SNAP/none" python3 -I "$SNAP/shaper.py" \
       "$SNAP/agents.json" "$SNAP/none" "$SNAP/none" "$SNAP/none" "$SNAP/none" /w 2>/dev/null)
is  'a spooled seat carries its depth'      "$(jq -r '.[] | select(.name=="scout") | .a2aSpooled' <<<"$SJ")" '1'
is  'an empty spool reads 0'                "$(jq -r '.[] | select(.name=="head") | .a2aSpooled' <<<"$SJ")" '0'

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
