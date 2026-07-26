#!/usr/bin/env bash
# DIVE-2058 unit harness for the usage TOP TASKS misattribution flag.
#
# Bug reproduced: usage_collect's task attribution assigns a turn to whichever
# task-window [started_at, done_at-or-now] for that assignee contains the
# turn's timestamp, newest-started-first. A task that never closes (blocked —
# done_at stays NULL forever) leaves its window open-ended, so it silently
# absorbs every later turn from a task that was NEVER `task start`-ed (e.g.
# dispatched via a /goal nudge the agent hadn't yet claimed) — no error, no
# indication, just a wrong number under the wrong ident. Live incident:
# DIVE-1817 (blocked since 2026-07-23, one dispatch, 3 days before the window)
# read as a confident 13.8M-token row while the actual work (DIVE-2007/2039)
# had no window of its own at all. See community/wiki/gated-task-burns-no-park-lever.md.
#
# Fix under test: usage_collect cross-checks each attributed row's ident
# against /goal pins (the literal task ident named in the heartbeat's fixed
# nudge template) found in that agent's transcripts WITHIN THE REPORTING
# WINDOW (since..now) — independent of the started_at/done_at columns used to
# build the window, and independent of heartbeat.log. Zero pins for that ident
# in the window => dispatched=false => the CLI flags the row (⚠) instead of
# printing it as a confident number.
#
# Isolation: tasks.db lives in a throwaway dir (standard pattern). The
# transcript scan can't be redirected via env (home_of() hardcodes
# /home/agent-<name>, resolved via pwd.getpwnam), so this test runs as the
# CURRENT user/agent and writes fixture transcripts into a uniquely-named,
# throwaway subdirectory of the real home (never touches any real session
# file; only that one subdirectory is removed in the EXIT trap). Assertions
# select rows by their fake DIVE-900xx ident rather than by position, so real
# concurrent session activity in the same home can't affect the result.
# Run: bash tests/usage_dispatch_flag_unit.sh  (no sudo, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_usage.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

TMP="$(mktemp -d /tmp/usage-dispatch-flag-unit.XXXXXX)"
AGENT="$(whoami | sed 's/^agent-//')"
HOMEDIR="$HOME"
PROJDIR="$HOMEDIR/.claude/projects/dive2058-unittest-$$"
mkdir -p "$PROJDIR"
cleanup() { rm -rf "$TMP" "$PROJDIR"; }
trap cleanup EXIT

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/registry.json"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

printf '{"agents":{"%s":{"authProfile":"acctT","type":"claude"}}}' "$AGENT" > "$REGISTRY"

# --- fixture clock: NOW is fixed relative to `date`, all timestamps derived from it ---
NOW_EPOCH=$(date +%s)
iso() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }
SINCE_EPOCH=$(( NOW_EPOCH - 86400 ))          # usage --24h cutoff
T_DISPATCH_OLD=$(( SINCE_EPOCH - 3*86400 ))   # DIVE-90001's ONE dispatch, 3 days before the window (like DIVE-1817)
T_STOLEN=$(( NOW_EPOCH - 3600 ))              # DIVE-90002's real (unstarted) work, 1h ago, inside the window

# DIVE-90001: dispatched once long before the window, then blocked (done_at NULL forever).
db "INSERT INTO tasks (ident, title, status, assignee, created_by, started_at)
    VALUES ('DIVE-90001','blocked task with a stale dispatch','blocked','$AGENT','main','$(iso "$T_DISPATCH_OLD")');"
# DIVE-90002: real work in-window, but NEVER 'task start'-ed — no row at all,
# exactly like the live DIVE-2039 case (started_at empty). Its turns have
# nowhere of their own to land.

# --- transcript: the ORIGINAL /goal dispatch for DIVE-90001 (outside the window) ---
cat > "$PROJDIR/old.jsonl" <<EOF
{"type":"user","timestamp":"$(iso "$T_DISPATCH_OLD")","message":{"role":"user","content":"/goal Task DIVE-90001 shows status done or cancelled..."}}
EOF
touch -d "@$T_DISPATCH_OLD" "$PROJDIR/old.jsonl"

# --- transcript: no /goal pin for DIVE-90002 (it was never formally dispatched),
#     just assistant turns burning tokens inside the window ---
cat > "$PROJDIR/recent.jsonl" <<EOF
{"type":"assistant","timestamp":"$(iso "$T_STOLEN")","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":100000,"output_tokens":5000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
touch -d "@$NOW_EPOCH" "$PROJDIR/recent.jsonl"

data=$(usage_collect "$SINCE_EPOCH")
[[ -n "$data" ]] || { bad_t "usage_collect produced output" "empty"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }
ok_t "usage_collect produced JSON"

row=$(jq -c '.tasks[] | select(.ident=="DIVE-90001")' <<<"$data")
[[ -n "$row" ]] && ok_t "stolen turns land under DIVE-90001 (reproduces the misattribution)" \
  || bad_t "expected a DIVE-90001 row in .tasks" "$(jq -c '.tasks' <<<"$data")"

total=$(jq -r '.total // 0' <<<"$row")
[[ "${total:-0}" -gt 0 ]] && ok_t "DIVE-90001 row carries the stolen tokens ($total)" \
  || bad_t "expected nonzero total on the misattributed row" "got $total"

dispatched=$(jq -r '.dispatched' <<<"$row")
[[ "$dispatched" == "false" ]] && ok_t "misattributed row is flagged dispatched=false (no pin for DIVE-90001 in [since,now])" \
  || bad_t "expected dispatched=false" "got $dispatched"

# --- CLI text rendering: the ⚠ marker and caveat line must actually appear ---
rendered=$(JSON_MODE=0 usage_render_board "$data" "24h" "{}")
echo "$rendered" | grep -q "DIVE-90001 ⚠" && ok_t "TOP TASKS marks the flagged row inline with ⚠" \
  || bad_t "expected 'DIVE-90001 ⚠' in rendered board" "$(echo "$rendered" | grep DIVE-90001)"
echo "$rendered" | grep -q "no /goal dispatch found" && ok_t "caveat footer line printed" \
  || bad_t "expected a caveat line about missing dispatch" ""

# --- control: a task genuinely dispatched and worked inside the window is NOT flagged ---
T2=$(( NOW_EPOCH - 1800 ))
db "INSERT INTO tasks (ident, title, status, assignee, created_by, started_at)
    VALUES ('DIVE-90003','genuinely dispatched task','in_progress','$AGENT','main','$(iso "$T2")');"
cat > "$PROJDIR/recent.jsonl" <<EOF
{"type":"user","timestamp":"$(iso "$T2")","message":{"role":"user","content":"/goal Task DIVE-90003 shows status done or cancelled..."}}
{"type":"assistant","timestamp":"$(iso "$T2")","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
touch -d "@$NOW_EPOCH" "$PROJDIR/recent.jsonl"

data2=$(usage_collect "$SINCE_EPOCH")
d3=$(jq -r '.tasks[] | select(.ident=="DIVE-90003") | .dispatched' <<<"$data2")
[[ "$d3" == "true" ]] && ok_t "genuinely dispatched task reads dispatched=true (no false positives)" \
  || bad_t "expected DIVE-90003 dispatched=true" "got $d3"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
