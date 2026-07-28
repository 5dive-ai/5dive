#!/usr/bin/env bash
# DIVE-1140 isolated unit harness for _hb_gate_shipped_sweep (cmd_heartbeat.sh).
# When a commit referencing an OPEN gate's ident lands on a configured repo's
# origin/main, the sweep FLAGS the gate (stamp shipped_flag_at + ping the owner)
# — flag-only for ALL tiers, NEVER auto-answers/closes, and throttles to one flag
# per gate. Runs on a throwaway tasks.db (STATE_DIR -> tmp), stubbing the git
# lookup and send helpers so no real repo/network is touched.
# Run: bash tests/heartbeat_gate_shipped_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
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

# DIVE-2003: keep a handle on the REAL _hb_repo_grep_ident before the stub below
# shadows it, so the format-contract case can exercise production code itself
# rather than a reimplementation of it.
eval "_hb_repo_grep_ident_REAL() $(declare -f _hb_repo_grep_ident | tail -n +2)"

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
# DIVE-2054: the "gate shipped-flag" audit_log calls are now routed through
# _task_store_audit_log (STORE IDENTITY fence, DIVE-2010/2054) — declare this
# fixture store as prod so the existing on-store assertions below (Case 9)
# keep exercising the real audit path, mirroring gate_telemetry_fence_unit.sh's
# on-store case. Case 12 below flips this off to prove the fence's other side.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
set +e

tasks_db_init

# --- stubs -------------------------------------------------------------------
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send()            { printf '%s\n' "$1" >>"$SEND_LOG"; }   # $1 = target agent
_task_agent_channel() { return 0; }                          # everyone has a channel
AUDIT_LOG_CALLS="$TMP/audit"; : >"$AUDIT_LOG_CALLS"
audit_log()           { printf '%s\n' "$*" >>"$AUDIT_LOG_CALLS"; return 0; }
# Stub the git lookup: the ident in $MERGED is "on main"; everything else misses.
MERGED=""
DRIFT=""
_hb_repo_grep_ident() {  # <repo> <ident>
  [[ -n "$MERGED" && "$2" == "$MERGED" ]] || return 1
  # DRIFT=1 models the PRE-DIVE-2001 format (no epoch field) — i.e. the real
  # --format string drifting away from what the consumer's awk field 3 expects.
  [[ -n "$DRIFT" ]] && { printf '%s abc1234 fix: %s landed\n' "$1" "$2"; return 0; }
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
reset() { db "DELETE FROM tasks;"; : >"$SEND_LOG"; : >"$AUDIT_LOG_CALLS"; MERGED=""; MERGED_EPOCH=""; DRIFT=""; }

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


# --- Case 9 (DIVE-2003): a lookup format drift must be LOUD, not silent ------
# olivia's measurement: reverting the stub to a no-epoch format and DELETING the
# guard outright produced the IDENTICAL 8/2 signature, because the fall-through
# logged nothing anywhere. Fail-open is still correct; invisible fail-open is not.
reset
gid=$(mk_gate 1 decision); MERGED="DIVE-$gid"; DRIFT=1
out=$(_hb_gate_shipped_sweep 2>&1)
flag=$(db "SELECT COALESCE(shipped_flag_at,'') FROM tasks WHERE id=$gid;")
[[ -n "$flag" ]] \
  && ok_t "DIVE-2003: fail-open preserved — a drifted lookup still flags (withholding would be its own silence)" \
  || bad_t "DIVE-2003: drifted lookup withheld the flag" "shipped_flag_at empty"
grep -q "UNPARSEABLE" <<<"$out" \
  && ok_t "DIVE-2003: the drift is announced in _hb_log (guard can no longer vanish silently)" \
  || bad_t "DIVE-2003: drift not logged" "out=[${out//$'\n'/ | }]"
grep -q "reason=epoch-unparseable" "$AUDIT_LOG_CALLS" \
  && ok_t "DIVE-2003: the drift leaves an audit row (degraded), not just a log line" \
  || bad_t "DIVE-2003: no audit row for the drift" "audit=[$(tr '\n' ',' <"$AUDIT_LOG_CALLS")]"

# --- Case 12 (DIVE-2054): OFF the prod store, the shipped-flag audit row is ---
# withheld, not written — proves the _task_store_audit_log fence actually gates
# this call site (not just that it compiles). Mirrors
# tests/audit_task_store_fence_unit.sh's off-store case, for a cmd_heartbeat.sh
# site instead of a cmd_task.sh one.
reset
unset _TASK_STORE_AUDIT_FENCED
gid=$(mk_gate 1 decision); MERGED="DIVE-$gid"; DRIFT=1
FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db" _hb_gate_shipped_sweep >/dev/null 2>"$TMP/offstore.err"
[[ ! -s "$AUDIT_LOG_CALLS" ]] \
  && ok_t "DIVE-2054: off the prod store, gate shipped-flag writes NO audit row" \
  || bad_t "DIVE-2054: off-store must not audit" "$(cat "$AUDIT_LOG_CALLS")"
grep -q "telemetry withheld" "$TMP/offstore.err" \
  && ok_t "DIVE-2054: the withholding is ANNOUNCED, not silent" \
  || bad_t "DIVE-2054: fence must announce" "err=$(cat "$TMP/offstore.err")"
unset _TASK_STORE_AUDIT_FENCED

# --- Case 10 (DIVE-2003): hermetic FORMAT CONTRACT on the real function ------
# COVERAGE GAP, deliberate and recorded (DIVE-2014): _HB_GATE_SHIPPED_REF=HEAD here
# because a throwaway repo has no origin/main. The CONTRACT pinned below (field 3
# numeric, repo stem prepended, %ct not %at) is ref-INDEPENDENT — a --format string
# cannot drift per-ref — so the only uncovered slice is ref RESOLUTION. Its read half
# was closed on DIVE-2001 against the real repo (field 3 = 1785006908). Do NOT buy the
# rest with a network dependency. Do not assume ref resolution is covered here.
# The suite stubs _hb_repo_grep_ident, so production's --format string is
# exercised by no test at all. This pins it without network or a real repo:
# field 3 must be a unix epoch, which is exactly what the consumer awks out.
RREPO="$TMP/fmt/5dive-cli"; mkdir -p "$RREPO"
( cd "$RREPO" && git init -q . \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fix: DIVE-999001 landed" ) >/dev/null 2>&1
_HB_REPO_BASE="$TMP/fmt" _HB_GATE_SHIPPED_REF=HEAD \
  hit=$(_hb_repo_grep_ident_REAL 5dive-cli DIVE-999001)
f3=$(awk '{print $3}' <<<"$hit")
[[ "$f3" =~ ^[0-9]+$ ]] \
  && ok_t "DIVE-2003: REAL lookup's field 3 is a numeric epoch (format contract pinned, no stub involved)" \
  || bad_t "DIVE-2003: field 3 of the real lookup is not an epoch" "hit=[$hit] field3=[$f3]"
[[ "$(awk '{print $1}' <<<"$hit")" == "5dive-cli" ]] \
  && ok_t "DIVE-2003: REAL lookup prepends the repo stem (field 3 is only correct because of this)" \
  || bad_t "DIVE-2003: repo stem not prepended" "hit=[$hit]"
_HB_REPO_BASE="$TMP/fmt" _HB_GATE_SHIPPED_REF=HEAD \
  miss=$(_hb_repo_grep_ident_REAL 5dive-cli DIVE-99900 2>/dev/null)
[[ -z "$miss" ]] \
  && ok_t "DIVE-2003: digit-boundary grep holds — DIVE-99900 does not match DIVE-999001" \
  || bad_t "DIVE-2003: prefix ident matched" "miss=[$miss]"

# --- Case 11 (DIVE-2014, salvaged from the superseded PR #181) ---------------
# %ct (COMMITTER date) not %at (author date). With %at, a commit authored long ago
# but merged AFTER the ask would look like it predates the ask and be wrongly
# skipped — a silence, which is the exact failure class this guard exists to stop.
# On our squash-merge flow the two coincide, so until now this was protected by
# INTENT and not by evidence; a rebase-merge would separate them. This is the
# evidence. The commit below is authored in 2001 and committed in 2026.
CTREPO="$TMP/ct/5dive-cli"; mkdir -p "$CTREPO"
( cd "$CTREPO" && git init -q . \
  && GIT_AUTHOR_DATE="2001-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
     git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fix: DIVE-999002 landed" ) >/dev/null 2>&1
_HB_REPO_BASE="$TMP/ct" _HB_GATE_SHIPPED_REF=HEAD \
  cthit=$(_hb_repo_grep_ident_REAL 5dive-cli DIVE-999002)
ctf3=$(awk '{print $3}' <<<"$cthit")
at_epoch=978307200    # 2001-01-01Z, the AUTHOR date
ct_epoch=1767225600   # 2026-01-01Z, the COMMITTER date
[[ "$ctf3" == "$ct_epoch" ]] \
  && ok_t "DIVE-2014: field 3 is the COMMITTER date (%ct), not the author date (%at)" \
  || bad_t "DIVE-2014: field 3 is not %ct" "got [$ctf3]; %at would be $at_epoch, %ct is $ct_epoch"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# DIVE-2003 (olivia's reject): this MUST be the LAST command in the file. When the
# tally printf was moved to the end, this line was left stranded mid-file and the
# harness's exit status became the printf's constant 0. CI (`for t in tests/*.sh`)
# and `5dive task verify --cmd` BOTH grade on $?, so every regression here passed
# green. A mutation signature is a set of assertion NAMES; a VERDICT is $?. Only
# the second one gates. Check this by MUTATING and asserting exit 1 — a green run
# exits 0 whether or not this line is present, so a passing run proves nothing.
[[ "$FAIL" -eq 0 ]]
