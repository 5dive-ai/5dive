#!/usr/bin/env bash
# DIVE-4680 isolated unit harness for `5dive project set-status <key> <status>`.
#
# THE DEFECT this pins: `projects.status` and `projects.archived_at` have been
# declared, read back (`project ls --json`, `project show`) and BRANCHED ON
# (`cmd_goal.sh`'s `… AND status='active'`, `task/crud.sh`'s "no active project")
# since DIVE-484 — with no writer anywhere in src/. Every project on every box was
# therefore stuck at 'active' for its whole life, and `5dive project set-status`
# died "unknown project command". A writable column nothing writes reads exactly
# like a column that works, which is why the read side shipped without anyone
# noticing the write side never had.
#
# Same posture as tests/project_show_graph_unit.sh: sources src/ directly against
# a throwaway TASKS_DB, so the shared queue is never touched. No root, no network.
#
# PRISTINE-RUNNER CONTROL (T9): CI has no /usr/local/bin/5dive, no /etc/5dive and
# no /var/log/5dive. Every path this harness writes lives under $TMP, and T9
# re-runs a positive arm with the audit sink pointed at a directory that does not
# exist — the runner's case — so a verb that only lands its UPDATE on a box with
# an initialised audit log cannot pass here and fail there.
#
# MUTANT (T10): the UPDATE is swallowed by a shadowed `db`, reproducing the
# pre-fix tree (verb present, column still unwritten). The positive predicates of
# T1/T2 must go red under it, and the arm proves the mutation TOOK rather than
# asserting into a vacuum.
#
#   bash tests/project_set_status_unit.sh   (no root, no network)
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/projsetstatus-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR" "$TMP/audit"
# Throwaway audit sink: header.sh points AUDIT_LOG at the live fleet log, and a
# sourced caller aimed there is withheld by the DIVE-2249 fence. Pre-created
# because _emit_audit_line tests `-w` on the FILE, and a missing one routes the
# row to the privileged sudo fallback that CI cannot take either.
AUDIT_LOG="$TMP/audit/agent-audit.log"; : > "$AUDIT_LOG"
set +e   # header.sh enabled `set -e`; tests deliberately expect non-zero exits

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { ( "$@" ) 2>/dev/null; }
run_err() { ( "$@" ) 2>&1; }

# Precondition, said rather than crashed into. Against a tree that predates
# DIVE-4680 the verb and the constant are simply absent, and `set -u` kills this
# harness on the first line of T1 with "PROJECT_STATUSES: unbound variable" — a
# red that names nothing. This is also the arm the grade's own mutant
# (`git checkout <base> -- src/cmd_project.sh`) lands on, so it is the line a
# reader sees when the fix is reverted.
if ! declare -F cmd_project_set_status >/dev/null 2>&1 || [[ -z "${PROJECT_STATUSES:-}" ]]; then
  bad_t "precondition: $SRC/cmd_project.sh carries neither cmd_project_set_status nor PROJECT_STATUSES" \
        "this tree predates DIVE-4680 — the column still has no writer"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi

db "INSERT INTO projects (key, prefix, name, lead_agent) VALUES ('widget','WID','Widget','dev');"

col() { db "SELECT COALESCE($1,'<NULL>') FROM projects WHERE key='widget';"; }
show_json() { JSON_MODE=1 run cmd_project_show widget; }
ls_json()   { JSON_MODE=1 run cmd_project_ls; }

# ============ T1: each of the five statuses lands, in show AND in ls ============
# The list is read back out of src so a sixth status added to PROJECT_STATUSES
# without a harness arm cannot pass unnoticed.
for s in $PROJECT_STATUSES; do
  JSON_MODE=0 run cmd_project_set_status widget "$s" >/dev/null
  rc=$?
  got_show=$(show_json | jq -r '.data.project.status')
  got_ls=$(ls_json | jq -r '.data.projects[] | select(.key=="widget") | .status')
  if [[ $rc -eq 0 && "$got_show" == "$s" && "$got_ls" == "$s" ]]; then
    ok_t "T1 set-status $s lands in show --json and ls --json"
  else
    bad_t "T1 set-status $s" "rc=$rc show=$got_show ls=$got_ls"
  fi
done

# five arms ran, not four: the source list must still be the five named on #1036
n_statuses=$(printf '%s\n' $PROJECT_STATUSES | wc -l)
[[ "$n_statuses" == "5" ]] && ok_t "T1 PROJECT_STATUSES is exactly five" \
  || bad_t "T1 status count" "got=$n_statuses ($PROJECT_STATUSES)"

# ============ T2: archived_at stamped on the retiring three, cleared on the live two ============
for s in complete archived binned; do
  JSON_MODE=0 run cmd_project_set_status widget "$s" >/dev/null
  a=$(col archived_at)
  # dbfmt -json DROPS null keys, so absence — not a null value — is how the read
  # side says "never archived"; assert both the column and what a consumer sees.
  hask=$(show_json | jq -r '.data.project | has("archived_at")')
  [[ "$a" != "<NULL>" && "$hask" == "true" ]] \
    && ok_t "T2 $s stamps archived_at ($a)" || bad_t "T2 $s stamp" "col=$a has=$hask"
done
for s in active backlogged; do
  JSON_MODE=0 run cmd_project_set_status widget "$s" >/dev/null
  a=$(col archived_at)
  hask=$(show_json | jq -r '.data.project | has("archived_at")')
  [[ "$a" == "<NULL>" && "$hask" == "false" ]] \
    && ok_t "T2 $s clears archived_at back to NULL" || bad_t "T2 $s clear" "col=$a has=$hask"
done

# Each transition RE-stamps rather than keeping the first retirement's time. A
# planted sentinel beats `sleep 1`: datetime('now') has one-second granularity,
# so two back-to-back transitions would otherwise be indistinguishable.
JSON_MODE=0 run cmd_project_set_status widget complete >/dev/null
db "UPDATE projects SET archived_at='2000-01-01 00:00:00' WHERE key='widget';"
JSON_MODE=0 run cmd_project_set_status widget binned >/dev/null
a=$(col archived_at)
[[ "$a" != "2000-01-01 00:00:00" && "$a" != "<NULL>" ]] \
  && ok_t "T2 each transition re-stamps archived_at ($a)" || bad_t "T2 re-stamp" "archived_at=$a"

# ============ T3: unknown status refused E_VALIDATION, naming all five ============
JSON_MODE=0
out=$(run_err cmd_project_set_status widget bogus); rc=$?
miss=""
for s in $PROJECT_STATUSES; do [[ "$out" == *"$s"* ]] || miss+="$s "; done
[[ $rc -eq 3 && -z "$miss" ]] \
  && ok_t "T3 unknown status -> rc 3 naming all five" \
  || bad_t "T3 unknown status" "rc=$rc missing='$miss' out=$out"
# and it refused rather than half-writing
st=$(col status)
[[ "$st" == "binned" ]] && ok_t "T3 refusal left the row untouched" || bad_t "T3 row touched" "status=$st"

# ============ T4: unknown key refused E_NOT_FOUND ============
out=$(run_err cmd_project_set_status nosuchproject active); rc=$?
[[ $rc -eq 4 && "$out" == *"no such project: nosuchproject"* ]] \
  && ok_t "T4 unknown key -> rc 4 'no such project'" || bad_t "T4 unknown key" "rc=$rc out=$out"

# ============ T5: same status twice still exits 0 and says 'already' ============
JSON_MODE=0 run cmd_project_set_status widget complete >/dev/null
out=$(run cmd_project_set_status widget complete); rc=$?
[[ $rc -eq 0 && "$out" == *"already complete"* ]] \
  && ok_t "T5 same status twice -> rc 0, 'already complete'" || bad_t "T5 no-op" "rc=$rc out=$out"
# a no-op is not a transition: it must NOT re-stamp
db "UPDATE projects SET archived_at='2000-01-01 00:00:00' WHERE key='widget';"
run cmd_project_set_status widget complete >/dev/null
a=$(col archived_at)
[[ "$a" == "2000-01-01 00:00:00" ]] \
  && ok_t "T5 a no-op leaves archived_at alone" || bad_t "T5 no-op re-stamped" "archived_at=$a"

# ============ T6: an archived project drops out of the status='active' query ============
# The exact predicate cmd_goal.sh uses to resolve a project's planner, and
# task/crud.sh to accept a new row into the lane.
active_lead() { db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key='widget' AND status='active';"; }
JSON_MODE=0 run cmd_project_set_status widget archived >/dev/null
[[ -z "$(active_lead)" ]] \
  && ok_t "T6 archived project is no longer picked by status='active'" \
  || bad_t "T6 still active" "lead=$(active_lead)"
JSON_MODE=0 run cmd_project_set_status widget active >/dev/null
[[ "$(active_lead)" == "dev" ]] \
  && ok_t "T6 back to active and the lane is pickable again" || bad_t "T6 not restored" "lead=$(active_lead)"

# ============ T7: usage, case folding, dispatcher, enumeration ============
out=$(run_err cmd_project_set_status); rc=$?
[[ $rc -eq 2 && "$out" == *"usage: 5dive project set-status <key> <status>"* ]] \
  && ok_t "T7 missing args -> rc 2 with usage" || bad_t "T7 usage" "rc=$rc out=$out"
out=$(run_err cmd_project_set_status widget); rc=$?
[[ $rc -eq 2 ]] && ok_t "T7 missing status -> rc 2" || bad_t "T7 one-arg usage" "rc=$rc out=$out"

run cmd_project_set_status WIDGET COMPLETE >/dev/null; rc=$?
st=$(col status)
[[ $rc -eq 0 && "$st" == "complete" ]] \
  && ok_t "T7 key and status accepted in any case, stored lowercase" || bad_t "T7 case fold" "rc=$rc status=$st"

run cmd_project set-status widget active >/dev/null; rc=$?
[[ $rc -eq 0 && "$(col status)" == "active" ]] \
  && ok_t "T7 dispatcher routes 'project set-status'" || bad_t "T7 dispatch" "rc=$rc status=$(col status)"

# DIVE-2029 invariant, locally: a usage string that enumerates siblings must name
# every arm the case dispatches.
out=$(run_err cmd_project frobnicate); rc=$?
[[ $rc -eq 2 && "$out" == *"set-status"* ]] \
  && ok_t "T7 unknown-command usage names set-status" || bad_t "T7 enumeration" "rc=$rc out=$out"

# ============ T8: the audit row records WHICH project moved ============
# `key=` would be written `key=<redacted>` — DIVE-4297 redacts on the key NAME,
# and "key" contains "key". The row would then say a project moved and not which.
: > "$AUDIT_LOG"
run cmd_project_set_status widget binned >/dev/null
row=$(tail -1 "$AUDIT_LOG")
if [[ -n "$row" ]] \
   && printf '%s' "$row" | jq -e '.cmd=="project set-status"' >/dev/null 2>&1 \
   && printf '%s' "$row" | jq -e '.args | index("project=widget")' >/dev/null 2>&1 \
   && printf '%s' "$row" | jq -e '.args | index("status=binned")' >/dev/null 2>&1; then
  ok_t "T8 audit row carries project=widget status=binned, unredacted"
else
  bad_t "T8 audit row" "row=$row"
fi

# ============ T9: pristine-runner control — no audit sink, no installed CLI ============
# On the CI runner /var/log/5dive does not exist, so audit_log early-returns and
# the privileged /usr/local/bin/5dive fallback is unreachable. The mutation must
# still land. A verb that needs an initialised box passes at a desk and reds here.
JSON_MODE=0 run cmd_project_set_status widget active >/dev/null
pr_out=$( AUDIT_LOG="$TMP/no-such-dir/agent-audit.log" run cmd_project_set_status widget archived ); pr_rc=$?
pr_st=$(col status)
[[ $pr_rc -eq 0 && "$pr_st" == "archived" && ! -e "$TMP/no-such-dir" ]] \
  && ok_t "T9 pristine runner (absent audit sink): verb still lands, writes nothing outside TMP" \
  || bad_t "T9 pristine control" "rc=$pr_rc status=$pr_st sink_created=$([[ -e "$TMP/no-such-dir" ]] && echo yes || echo no)"
[[ "$TASKS_DB" == "$TMP"/* && "$AUDIT_LOG" == "$TMP"/* ]] \
  && ok_t "T9 every path this harness writes is under \$TMP" \
  || bad_t "T9 state escaped TMP" "TASKS_DB=$TASKS_DB AUDIT_LOG=$AUDIT_LOG"

# ============ T10: MUTANT — the column has no writer again ============
# Re-introduces the defect narrowly: the verb dispatches, validates and reports
# ok, but its one UPDATE never reaches sqlite. T1's and T2's predicates must both
# go RED, and the arm asserts the mutation TOOK (the UPDATE was really swallowed)
# so a strike-out cannot pass vacuously.
JSON_MODE=0 run cmd_project_set_status widget active >/dev/null
mutant_report=$(
  eval "$(declare -f db | sed '1s/^db /_real_db /')"
  swallowed=0
  db() {
    case "$1" in
      *"UPDATE projects SET status"*) swallowed=$((swallowed+1)); return 0 ;;
    esac
    _real_db "$1"
  }
  # NOT in a nested subshell: the counter above has to survive the call, which is
  # what proves the swallow happened rather than being assumed.
  JSON_MODE=0
  cmd_project_set_status widget complete >/dev/null 2>&1; m_rc=$?
  m_st=$(_real_db "SELECT status FROM projects WHERE key='widget';")
  m_at=$(_real_db "SELECT COALESCE(archived_at,'<NULL>') FROM projects WHERE key='widget';")
  printf '%s %s %s %s' "$swallowed" "$m_rc" "$m_st" "$m_at"
)
read -r m_swallowed m_rc m_st m_at <<< "$mutant_report"
[[ "$m_swallowed" -ge 1 ]] \
  && ok_t "T10 mutation took: $m_swallowed UPDATE(s) swallowed" \
  || bad_t "T10 mutation did NOT take — the arms below would strike out vacuously" "report='$mutant_report'"
[[ "$m_rc" -eq 0 ]] \
  && ok_t "T10 mutant still reports ok — which is exactly why the gap survived" \
  || bad_t "T10 mutant rc" "rc=$m_rc"
[[ "$m_st" != "complete" ]] \
  && ok_t "T10 mutant RED against T1: status stayed '$m_st'" || bad_t "T10 T1 not red" "status=$m_st"
[[ "$m_at" == "<NULL>" ]] \
  && ok_t "T10 mutant RED against T2: archived_at never stamped" || bad_t "T10 T2 not red" "archived_at=$m_at"
# AFTER the mutant subshell: the real writer is back and still works, so T10
# graded the mutation rather than a tree it left broken.
JSON_MODE=0 run cmd_project_set_status widget complete >/dev/null
[[ "$(col status)" == "complete" ]] \
  && ok_t "T10 after: the unmutated writer still lands" || bad_t "T10 after" "status=$(col status)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
