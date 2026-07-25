#!/usr/bin/env bash
# DIVE-1140 isolated unit harness for _hb_gate_shipped_sweep (cmd_heartbeat.sh).
# When a commit referencing an OPEN gate's ident lands on a configured repo's
# origin/main, the sweep FLAGS the gate (stamp shipped_flag_at + ping the owner)
# — flag-only for ALL tiers, NEVER auto-answers/closes, and throttles to one flag
# per gate. Runs on a throwaway tasks.db (STATE_DIR -> tmp), stubbing the git
# lookup and send helpers so no real repo/network is touched.
# Run: bash tests/heartbeat_gate_shipped_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-gate-shipped.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

# --- stubs -------------------------------------------------------------------
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send()            { printf '%s\n' "$1" >>"$SEND_LOG"; }   # $1 = target agent
_task_agent_channel() { return 0; }                          # everyone has a channel
audit_log()           { return 0; }
# Stub the git lookup: the ident in $MERGED is "on main"; everything else misses.
MERGED=""
_hb_repo_grep_ident() {  # <repo> <ident>
  [[ -n "$MERGED" && "$2" == "$MERGED" ]] || return 1
  printf '%s abc1234 %s fix: %s landed\n' "$1" "${MERGED_EPOCH:-$(date +%s)}" "$2"
}

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk_gate() {  # <tier> <need_type> -> echoes id (ident auto = DIVE-<id>)
  db "INSERT INTO tasks (title, priority, assignee, created_by, kind, status,
                         need_type, tier, ask, need_asked_at)
      VALUES ('shipped gate', 'medium', 'dev', 'main', 'standard', 'blocked',
              $(sqlq "$2"), $1, 'need a human call', datetime('now','-1 days'));
      SELECT last_insert_rowid();"
}
reset() { db "DELETE FROM tasks;"; : >"$SEND_LOG"; MERGED=""; MERGED_EPOCH=""; }

# --- Case 1: tier-1 gate whose ident merged -> flagged + owner pinged ---------
reset
gid=$(mk_gate 1 decision)
MERGED="DIVE-${gid}"
_hb_gate_shipped_sweep
flag=$(db "SELECT COALESCE(shipped_flag_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$flag" != "NULL" ]] \
  && ok_t "tier-1 merged gate gets shipped_flag_at stamped" \
  || bad_t "tier-1 gate not flagged" "shipped_flag_at=$flag"
grep -qx 'dev' "$SEND_LOG" \
  && ok_t "owner pinged on flag" \
  || bad_t "owner not pinged" "sent=[$(tr '\n' ',' <"$SEND_LOG")]"

# --- Case 2: flag-only — NEVER auto-answers/closes (all tiers) ----------------
reset
gid=$(mk_gate 2 approval)
MERGED="DIVE-${gid}"
_hb_gate_shipped_sweep
read -r ans st < <(db "SELECT COALESCE(need_answered_at,'NULL')||' '||status FROM tasks WHERE id=${gid};")
[[ "$ans" == "NULL" && "$st" == "blocked" ]] \
  && ok_t "tier-2 gate flagged but NEVER answered/closed (still blocked, answer NULL)" \
  || bad_t "tier-2 gate was auto-resolved" "answered=$ans status=$st"

# --- Case 3: gate whose ident did NOT merge -> untouched ----------------------
reset
gid=$(mk_gate 1 decision)
MERGED="DIVE-999999"          # a different ident is on main
_hb_gate_shipped_sweep
flag=$(db "SELECT COALESCE(shipped_flag_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$flag" == "NULL" && ! -s "$SEND_LOG" ]] \
  && ok_t "un-merged gate is not flagged and owner not pinged" \
  || bad_t "un-merged gate was flagged" "shipped_flag_at=$flag sent=[$(tr '\n' ',' <"$SEND_LOG")]"

# --- Case 4: throttle — an already-flagged gate is not re-flagged/re-pinged ----
reset
gid=$(mk_gate 1 decision)
MERGED="DIVE-${gid}"
_hb_gate_shipped_sweep        # first pass flags it
: >"$SEND_LOG"
_hb_gate_shipped_sweep        # second pass must be a no-op
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "already-flagged gate is not re-pinged (shipped_flag_at throttle)" \
  || bad_t "gate re-pinged" "sent=[$(tr '\n' ',' <"$SEND_LOG")]"

# --- Case 5: answered/closed gates are ignored --------------------------------
reset
gid=$(mk_gate 2 decision)
db "UPDATE tasks SET need_answered_at=datetime('now') WHERE id=${gid};"
MERGED="DIVE-${gid}"
_hb_gate_shipped_sweep
flag=$(db "SELECT COALESCE(shipped_flag_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$flag" == "NULL" ]] \
  && ok_t "already-answered gate is skipped (no flag)" \
  || bad_t "answered gate was flagged" "shipped_flag_at=$flag"

# --- Case 6: empty repo allow-list -> no-op, no error -------------------------
reset
gid=$(mk_gate 1 decision)
MERGED="DIVE-${gid}"
_HB_GATE_SHIPPED_REPOS=""
_hb_gate_shipped_sweep
rc=$?
_HB_GATE_SHIPPED_REPOS="5dive-cli"
flag=$(db "SELECT COALESCE(shipped_flag_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$rc" -eq 0 && "$flag" == "NULL" ]] \
  && ok_t "empty repo allow-list is a graceful no-op" \
  || bad_t "empty allow-list not handled" "rc=$rc shipped_flag_at=$flag"


# --- DIVE-2001: a merge PREDATING the open ask is not evidence the ask is met ---
# One fixture per direction so a future edit names which case died. mk_gate sets
# need_asked_at to now-1day, so "before" is now-2days and "after" is now.
reset
gid=$(mk_gate 1 decision); MERGED="DIVE-${gid}"; MERGED_EPOCH=$(date -d '2 days ago' +%s)
_hb_gate_shipped_sweep
flag=$(db "SELECT COALESCE(shipped_flag_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$flag" == "NULL" ]] \
  && ok_t "DIVE-2001: commit PREDATING the ask does not stamp shipped_flag_at (gate stays eligible)" \
  || bad_t "pre-ask commit flagged" "shipped_flag_at=$flag"
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "DIVE-2001: commit predating the ask does not ping the owner to close" \
  || bad_t "pre-ask commit pinged owner" "sent=[$(tr '\n' ',' <"$SEND_LOG")]"

# NEGATIVE CONTROL: same fixture, same gate, commit AFTER the ask -> must flag.
# Without this, the two assertions above pass just as happily on a sweep that has
# stopped flagging anything at all.
reset
gid=$(mk_gate 1 decision); MERGED="DIVE-${gid}"; MERGED_EPOCH=$(date +%s)
_hb_gate_shipped_sweep
flag=$(db "SELECT COALESCE(shipped_flag_at,'NULL') FROM tasks WHERE id=${gid};")
{ [[ "$flag" != "NULL" ]] && grep -qx 'dev' "$SEND_LOG"; } \
  && ok_t "DIVE-2001 control: commit AFTER the ask still flags and pings" \
  || bad_t "post-ask commit did not flag" "shipped_flag_at=$flag sent=[$(tr '\n' ',' <"$SEND_LOG")]"


# --- DIVE-2003: the fail-open path must SPEAK -----------------------------------
# Reverting only this stub to a no-epoch format produced 8/2 — byte-identical to
# the signature of deleting the guard outright (olivia, DIVE-2001 verify). Two
# defects, one signature, because the fail-open branch was silent. It now logs.
reset
gid=$(mk_gate 1 decision); MERGED="DIVE-${gid}"; MERGED_EPOCH="not-an-epoch"
_hb_gate_shipped_sweep 2>"$TMP/hblog"
flag=$(db "SELECT COALESCE(shipped_flag_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$flag" != "NULL" ]] \
  && ok_t "DIVE-2003: unparseable epoch still FLAGS (fail-open, never a silent withhold)" \
  || bad_t "unparseable epoch withheld the flag" "shipped_flag_at=$flag"
grep -q "epoch UNPARSEABLE" "$TMP/hblog" \
  && ok_t "DIVE-2003: and it SAYS SO — a guard that could not run is visible in the log" \
  || bad_t "fail-open was silent" "log=[$(tr '\n' ';' <"$TMP/hblog")]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
