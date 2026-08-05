#!/usr/bin/env bash
# TIER: nightly — 27s measured on the dev VM 2026-08-04 (DIVE-2719; was 24.4s, DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# OSS-7 isolated unit harness for the task-core verbs — the most-used surface
# that had no coverage (only the loop/gate slices were tested). Same isolation
# contract as the loop harnesses: source src/ directly, point STATE_DIR at a
# throwaway temp dir so the live shared tasks.db is NEVER touched. Asserts:
# project ident minting, add/show round-trip, the status lifecycle
# (start/done/cancel/block/park), decision need/answer, recurring templates,
# ls filters, and validation rejections.
# Run: bash tests/task_core_unit.sh   (no root, no network).
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
TMP="$(mktemp -d /tmp/task-core-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { local verb="$1"; shift; ( "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
jf()  { jq -r "$1" 2>/dev/null; }

tasks_db_init

# DIVE-2124: seed the org chart DIRECTLY, never through `org set`.
# `org set` is root-only now — the chart is trusted input to gate routing, so
# writing it is a privileged act. A FIXTURE has no business exercising authz: it
# needs the ROW, not the verb. Calling the verb here made 11 arms in this file and
# its sibling fail for a reason with nothing to do with what they test, and every
# one that died was a gate-routing verifier-resolution arm — the exact consumer the
# authz change exists to protect. Seeding the row keeps require_root REAL in this
# harness (no global stub, which would hide a future guard regression) while the
# arms go on testing what they are about.
org_seed() {  # <name> [--manager=x] [--role=x] [--title=x]
  local n="$1"; shift
  local mgr="" role="" title="" a
  for a in "$@"; do
    case "$a" in
      --manager=*) mgr="${a#*=}" ;;
      --role=*)    role="${a#*=}" ;;
      --title=*)   title="${a#*=}" ;;
    esac
  done
  db "INSERT OR IGNORE INTO agents_org (name) VALUES ($(sqlq "$n"));"
  if [[ -n "$mgr" ]]; then
    db "INSERT OR IGNORE INTO agents_org (name) VALUES ($(sqlq "$mgr"));
        UPDATE agents_org SET reports_to=$(sqlq "$mgr") WHERE name=$(sqlq "$n");"
  fi
  [[ -n "$role"  ]] && db "UPDATE agents_org SET role=$(sqlq "$role")   WHERE name=$(sqlq "$n");"
  [[ -n "$title" ]] && db "UPDATE agents_org SET title=$(sqlq "$title") WHERE name=$(sqlq "$n");"
  return 0
}

# --- T1: add mints DIVE-N idents from the per-project counter
id1=$(run add --assignee=alice -- "first task" | jf '.data.id')
ident1=$(db "SELECT ident FROM tasks WHERE id=$id1;")
id2=$(run add -- "second task" | jf '.data.id')
ident2=$(db "SELECT ident FROM tasks WHERE id=$id2;")
n1=${ident1#DIVE-}; n2=${ident2#DIVE-}
[[ "$ident1" == DIVE-* && "$ident2" == DIVE-* && "$n2" -eq $((n1 + 1)) ]] \
  && ok_t "sequential DIVE-N idents ($ident1, $ident2)" || bad_t "ident mint" "got $ident1 / $ident2"

# --- T2: project add + tasks in it mint PREFIX-1, PREFIX-2
( cmd_project_add frog --prefix=FROG --name="Frog" ) >/dev/null 2>"$TMP"/err
pid1=$(run add --project=frog -- "frog one" | jf '.data.ident')
pid2=$(run add --project=frog -- "frog two" | jf '.data.ident')
[[ "$pid1" == "FROG-1" && "$pid2" == "FROG-2" ]] \
  && ok_t "per-project counter (FROG-1, FROG-2)" || bad_t "project idents" "got $pid1 / $pid2"

# --- T3: show round-trips body/priority/assignee
id3=$(run add --assignee=bob --priority=high --body="the body" -- "show me" | jf '.data.id')
row=$(run show "$id3")
[[ "$(echo "$row" | jf '.data.task.title')" == "show me" && \
   "$(echo "$row" | jf '.data.task.priority')" == "high" && \
   "$(echo "$row" | jf '.data.task.assignee')" == "bob" && \
   "$(echo "$row" | jf '.data.task.body')" == "the body" ]] \
  && ok_t "add/show round-trip (title/priority/assignee/body)" || bad_t "round-trip" "$row"

# --- T4: lifecycle start -> in_progress -> done (+result), done_at stamped
run start "$id3" >/dev/null
st=$(db "SELECT status FROM tasks WHERE id=$id3;")
run done "$id3" --result="all good" >/dev/null
st2=$(db "SELECT status FROM tasks WHERE id=$id3;")
res=$(db "SELECT result FROM tasks WHERE id=$id3;")
da=$(db "SELECT done_at IS NOT NULL FROM tasks WHERE id=$id3;")
[[ "$st" == "in_progress" && "$st2" == "done" && "$res" == "all good" && "$da" == "1" ]] \
  && ok_t "lifecycle start->done with result + done_at" || bad_t "lifecycle" "st=$st st2=$st2 res=$res"

# --- DIVE-2316: delivery_ref is visible through the CLI, including absence.
# JSON show already reads the whole row; the regression was the human presenter
# omitting the enforcement field. Prove both states before the list audit below.
show_absent=$( (JSON_MODE=0 cmd_task_show "$id3") 2>"$TMP"/err )
echo "$show_absent" | grep -q '^delivery_ref = absent$' \
  && ok_t "DIVE-2316: task show makes an absent delivery_ref explicit" \
  || bad_t "DIVE-2316 show absent" "$show_absent"

delivery_url='https://github.com/example/project/pull/999'
db "UPDATE tasks SET delivery_ref=$(sqlq "$delivery_url") WHERE id=$id3;"
show_bound=$( (JSON_MODE=0 cmd_task_show "$id3") 2>"$TMP"/err )
echo "$show_bound" | grep -Fqx "delivery_ref = $delivery_url" \
  && ok_t "DIVE-2316: task show prints the bound delivery_ref" \
  || bad_t "DIVE-2316 show bound" "$show_bound"

# The operator's audit is normally list-shaped. Seed a second DONE row with no
# binding, then require the human table to distinguish the bound and absent rows.
id_no_ref=$(run add -- "done without a delivery binding" | jf '.data.id')
run done "$id_no_ref" --result="no code delivery" >/dev/null
done_ls=$( (JSON_MODE=0 cmd_task_ls --status=done) 2>"$TMP"/err )
[[ "$done_ls" == *"delivery_ref"* && "$done_ls" == *"$delivery_url"* && "$done_ls" == *"absent"* ]] \
  && ok_t "DIVE-2316: task ls --status=done surfaces bound and absent delivery_ref values" \
  || bad_t "DIVE-2316 done listing" "$done_ls"

ls_json_ref=$(run ls --status=done | jq -r --argjson i "$id3" '.data.tasks[] | select(.id==$i) | .delivery_ref')
[[ "$ls_json_ref" == "$delivery_url" ]] \
  && ok_t "DIVE-2316: task ls JSON carries delivery_ref" \
  || bad_t "DIVE-2316 ls JSON" "got=$ls_json_ref"

# --- T5: cancel is terminal with done_at
idc=$(run add -- "doomed" | jf '.data.id')
run cancel "$idc" --result="not needed" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=$idc;")" == "cancelled" && \
   "$(db "SELECT done_at IS NOT NULL FROM tasks WHERE id=$idc;")" == "1" ]] \
  && ok_t "cancel -> cancelled + done_at" || bad_t "cancel" "$(db "SELECT status FROM tasks WHERE id=$idc;")"

# --- T6: block --by creates a dep edge; unblock clears deps and restores todo
idb=$(run add -- "blocked task" | jf '.data.id')
idby=$(run add -- "the blocker" | jf '.data.id')
run block "$idb" --by="$idby" >/dev/null
stb=$(db "SELECT status FROM tasks WHERE id=$idb;")
dep=$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=$idb AND blocked_by=$idby;")
run unblock "$idb" >/dev/null
stu=$(db "SELECT status FROM tasks WHERE id=$idb;")
depu=$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=$idb;")
[[ "$stb" == "blocked" && "$dep" == "1" && "$stu" == "todo" && "$depu" == "0" ]] \
  && ok_t "block --by dep edge / unblock round-trip" || bad_t "block" "blocked=$stb dep=$dep unblocked=$stu depu=$depu"

# --- T7: decision need blocks the task and records the gate shape
idn=$(run add -- "needs a call" | jf '.data.id')
run need "$idn" --type=decision --ask="A or B?" --options="A|B" --recommend="A" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=$idn;")" == "blocked" && \
   "$(db "SELECT need_type FROM tasks WHERE id=$idn;")" == "decision" && \
   "$(db "SELECT need_options FROM tasks WHERE id=$idn;")" == "A|B" ]] \
  && ok_t "decision need -> blocked with gate shape" || bad_t "need" "$(db "SELECT status,need_type FROM tasks WHERE id=$idn;")"

# --- T8: decision answer unblocks (agent-clearable type) and stores the value
run answer "$idn" --value="A" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=$idn;")" == "todo" && \
   "$(db "SELECT need_answer FROM tasks WHERE id=$idn;")" == "A" ]] \
  && ok_t "decision answer -> unblocked, value stored" || bad_t "answer" "$(db "SELECT status,need_answer FROM tasks WHERE id=$idn;")"

# --- T9: need rejects --options on non-decision types
ida=$(run add -- "approval shaped" | jf '.data.id')
run need "$ida" --type=approval --ask="ok?" --options="A|B" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "--options rejected on approval gate" || bad_t "options guard" "exit 0"

# --- T10: park stores wake_at + park_reason; unpark clears them
idp=$(run add -- "sleepy" | jf '.data.id')
run park "$idp" --wake="2030-01-01" --reason="waiting on winter" >/dev/null
pw=$(db "SELECT wake_at IS NOT NULL FROM tasks WHERE id=$idp;")
run unpark "$idp" >/dev/null
[[ "$pw" == "1" && "$(db "SELECT status FROM tasks WHERE id=$idp;")" == "todo" ]] \
  && ok_t "park --wake / unpark round-trip" || bad_t "park" "wake_set=$pw status=$(db "SELECT status FROM tasks WHERE id=$idp;")"

# --- T11: recurring add creates a template, listed by ls --recurring only
idr=$(run add --recurring="0 2 * * *" -- "nightly job" | jf '.data.id')
kind=$(db "SELECT kind FROM tasks WHERE id=$idr;")
rec_seen=$(run ls --recurring | jf '.data.tasks | map(.id) | index('"$idr"') != null')
open_seen=$(run ls | jf '.data.tasks | map(.id) | index('"$idr"') != null')
[[ "$kind" == "recurring" && "$rec_seen" == "true" && "$open_seen" == "false" ]] \
  && ok_t "recurring template hidden from open ls, shown by --recurring" \
  || bad_t "recurring" "kind=$kind rec=$rec_seen open=$open_seen"

# --- T12: ls --assignee filter
seen=$(run ls --assignee=alice | jf '.data.tasks | map(.id) | index('"$id1"') != null')
other=$(run ls --assignee=alice | jf '.data.tasks | map(.id) | index('"$id2"') != null')
[[ "$seen" == "true" && "$other" == "false" ]] \
  && ok_t "ls --assignee filters" || bad_t "ls filter" "seen=$seen other=$other"

# --- T13: validation — bad priority and unknown id rejected
run add --priority=ludicrous -- "nope" >/dev/null 2>&1
rc1=$?
run done 999999 >/dev/null 2>&1
rc2=$?
[[ $rc1 -ne 0 && $rc2 -ne 0 ]] \
  && ok_t "bad priority + unknown id rejected" || bad_t "validation" "rc1=$rc1 rc2=$rc2"

# --- T14: ident resolution — verbs accept DIVE-N as well as raw id
idz=$(run add -- "by ident" | jf '.data.id')
identz=$(db "SELECT ident FROM tasks WHERE id=$idz;")
run start "$identz" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=$idz;")" == "in_progress" ]] \
  && ok_t "verbs resolve DIVE-N idents ($identz)" || bad_t "ident resolve" "$(db "SELECT status FROM tasks WHERE id=$idz;")"

# --- T15: DIVE-969 verifier-by-default posture
# Stand up a coordinator so a grader distinct from the maker can be resolved.
org_seed carol --role=coordinator
# --- DIVE-1568: `task coordinator` verb exposes the resolved coordinator so the
# needs-you banner can pin on ONE agent only. carol holds role='coordinator'.
[[ "$(run coordinator | jf '.data.coordinator')" == "carol" ]] \
  && ok_t "DIVE-1568: task coordinator resolves the role='coordinator' agent" \
  || bad_t "coordinator verb" "got=$(run coordinator | jf '.data.coordinator')"
# non-trivial task (has a body) assigned to a different agent → verifier defaulted
vd=$(run add --assignee=alice --body="real work here" -- "build the widget pipeline")
[[ "$(echo "$vd" | jf '.data.verifyDefaulted')" == "true" && \
   "$(echo "$vd" | jf '.data.verifier')" == "carol" ]] \
  && ok_t "non-trivial task gets a default grader (carol != alice)" \
  || bad_t "verify default" "vd=$(echo "$vd" | jf '.data.verifyDefaulted') v=$(echo "$vd" | jf '.data.verifier')"
vdid=$(echo "$vd" | jf '.data.id')
[[ -n "$(db "SELECT acceptance_criteria FROM tasks WHERE id=$vdid;")" ]] \
  && ok_t "default engages derived acceptance_criteria" || bad_t "default accept" "empty"

# --no-verify opts out: no verifier, no acceptance criteria
nov=$(run add --assignee=alice --no-verify --body="real work" -- "another non-trivial job")
novid=$(echo "$nov" | jf '.data.id')
[[ "$(echo "$nov" | jf '.data.verifyDefaulted')" == "false" && \
   -z "$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=$novid;")" ]] \
  && ok_t "--no-verify opts out of the default" || bad_t "no-verify" "verifier=$(db "SELECT verifier FROM tasks WHERE id=$novid;")"

# trivial chore (bodyless, mechanical title) skips the default silently
triv=$(run add --assignee=alice -- "fix typo in readme")
[[ "$(echo "$triv" | jf '.data.verifyDefaulted')" == "false" ]] \
  && ok_t "trivial chore skips the verifier default" || bad_t "trivial skip" "$(echo "$triv" | jf '.data.verifyDefaulted')"

# low priority is trivial regardless of body
lowp=$(run add --assignee=alice --priority=low --body="some work" -- "nice to have")
[[ "$(echo "$lowp" | jf '.data.verifyDefaulted')" == "false" ]] \
  && ok_t "low-priority task skips the verifier default" || bad_t "low-prio skip" "$(echo "$lowp" | jf '.data.verifyDefaulted')"

# explicit --verifier is respected (not overridden) and stays engaged
expl=$(run add --assignee=alice --verifier=dave --body="work" -- "explicit grader task")
[[ "$(echo "$expl" | jf '.data.verifier')" == "dave" ]] \
  && ok_t "explicit --verifier is preserved" || bad_t "explicit verifier" "$(echo "$expl" | jf '.data.verifier')"

# no distinct grader available (assignee IS the only coordinator) → silent no-op
selfg=$(run add --assignee=carol --body="work" -- "carol's own task")
[[ "$(echo "$selfg" | jf '.data.verifyDefaulted')" == "false" ]] \
  && ok_t "no self-grading when maker is the only grader" || bad_t "self-grade guard" "$(echo "$selfg" | jf '.data.verifyDefaulted')"

# INST-2: that silent no-op is now LABELLED, not hidden. The add output flags
# verifyUnavailable, the column persists it, and `task show` surfaces the label.
selfgid=$(echo "$selfg" | jf '.data.id')
[[ "$(echo "$selfg" | jf '.data.verifyUnavailable')" == "true" && \
   "$(db "SELECT verify_unavailable FROM tasks WHERE id=$selfgid;")" == "1" ]] \
  && ok_t "INST-2: no-grader no-op is flagged verifyUnavailable" \
  || bad_t "INST-2 flag" "vu=$(echo "$selfg" | jf '.data.verifyUnavailable') col=$(db "SELECT verify_unavailable FROM tasks WHERE id=$selfgid;")"
selfg_show=$( (JSON_MODE=0 cmd_task_show "$selfgid") 2>"$TMP"/err )
echo "$selfg_show" | grep -q "unverified: no independent verifier available" \
  && ok_t "INST-2/DIVE-1673: task show surfaces the quiet 'unverified' detail" \
  || bad_t "INST-2 show label" "$selfg_show"
# task ls --json exposes the canonical flag for the dashboard
selfg_ls=$(run ls --all | jq -r --argjson i "$selfgid" '.data.tasks[] | select(.id==$i) | .verify_unavailable')
[[ "$selfg_ls" == "1" ]] \
  && ok_t "INST-2: task ls --json exposes verify_unavailable=1" || bad_t "INST-2 ls flag" "got=$selfg_ls"
# a task WITH a distinct grader is NOT flagged (no false positives)
[[ "$(run ls --all | jq -r --argjson i "$vdid" '.data.tasks[] | select(.id==$i) | .verify_unavailable')" == "0" ]] \
  && ok_t "INST-2: graded task is not flagged unverified" || bad_t "INST-2 no false-pos" "vdid flagged"

# --- DIVE-989: maker==coordinator no longer silently no-ops.
# The lone-root coordinator (carol) owns every auto-coordinated task, so
# maker==coordinator constantly. Give the org a designated technical deputy and
# carol's OWN work grades to that deputy instead of getting no grader at all.
org_seed zoe --manager=carol --title="Zoe · CTO"
zg=$(run add --assignee=carol --body="coordinator's own work" -- "carol builds it")
[[ "$(echo "$zg" | jf '.data.verifyDefaulted')" == "true" && \
   "$(echo "$zg" | jf '.data.verifier')" == "zoe" ]] \
  && ok_t "DIVE-989: maker==coordinator grades to the designated deputy (zoe)" \
  || bad_t "989 coord fallback" "vd=$(echo "$zg" | jf '.data.verifyDefaulted') v=$(echo "$zg" | jf '.data.verifier')"

# A mid-chart maker grades UP the chain (coordinator/manager), never to itself.
mgr=$(run add --assignee=zoe --body="zoe's real work" -- "zoe builds it")
[[ "$(echo "$mgr" | jf '.data.verifier')" == "carol" ]] \
  && ok_t "DIVE-989: mid-chart maker gets a distinct up-chain grader (carol)" \
  || bad_t "989 up-chain" "verifier=$(echo "$mgr" | jf '.data.verifier')"

# --- DIVE-980: org-chart assignee-token routing on `task add` --------------
# Place a small org: eng (role=engineer, charter mentions "backend"), doc,
# and two designers (ambiguous role) to prove deterministic single-match only.
org_seed eng --role=engineer --title="backend platform"
org_seed doc --role=writer --title="docs and copy"
org_seed d1  --role=designer
org_seed d2  --role=designer

# role:<r> routes to the unique holder
r1=$(run add --assignee=role:engineer --body="w" -- "route by role")
[[ "$(echo "$r1" | jf '.data.assignee')" == "eng" ]] \
  && ok_t "--assignee=role:engineer resolves to eng" || bad_t "role token resolve" "$(echo "$r1" | jf '.data.assignee')"

# role match is case-insensitive
r1b=$(run add --assignee=role:Engineer --body="w" -- "route by role ci")
[[ "$(echo "$r1b" | jf '.data.assignee')" == "eng" ]] \
  && ok_t "role token is case-insensitive" || bad_t "role ci" "$(echo "$r1b" | jf '.data.assignee')"

# charter:<kw> routes to the unique holder whose title contains the keyword
r2=$(run add --assignee=charter:backend --body="w" -- "route by charter")
[[ "$(echo "$r2" | jf '.data.assignee')" == "eng" ]] \
  && ok_t "--assignee=charter:backend resolves to eng" || bad_t "charter token resolve" "$(echo "$r2" | jf '.data.assignee')"

# ambiguous role (two designers) is a hard, explainable error — never a guess
run add --assignee=role:designer --body="w" -- "ambiguous role" >/dev/null 2>"$TMP"/err
[[ $? -ne 0 && "$(cat "$TMP"/err)" == *"unique holder"* ]] \
  && ok_t "ambiguous role token rejected (explainable)" || bad_t "ambiguous role guard" "$(cat "$TMP"/err)"

# unknown role token is rejected too
run add --assignee=role:ghost --body="w" -- "unknown role" >/dev/null 2>"$TMP"/err
[[ $? -ne 0 ]] \
  && ok_t "unknown role token rejected" || bad_t "unknown role guard" "resolved anyway"

# explicit literal name still wins verbatim — never re-routed through the org
r3=$(run add --assignee=eng --body="w" -- "explicit name wins")
[[ "$(echo "$r3" | jf '.data.assignee')" == "eng" ]] \
  && ok_t "explicit literal --assignee is trusted verbatim" || bad_t "explicit name" "$(echo "$r3" | jf '.data.assignee')"

# @name form is accepted and stripped to the bare name
r4=$(run add --assignee=@eng --body="w" -- "at-name form")
[[ "$(echo "$r4" | jf '.data.assignee')" == "eng" ]] \
  && ok_t "@name is stripped to bare name" || bad_t "@name" "$(echo "$r4" | jf '.data.assignee')"

# --- T-2719: verification DEPTH is re-measured at delivery, and the default
# GRADER is no longer structurally a leader.
#
# _task_delivery_depth is the pure half (path list on stdin -> class), so it is
# graded directly: no gh, no network, no PR. The gh-backed half
# (_task_delivery_paths) is exercised on the box, not here — every one of its
# failure paths prints nothing, and "prints nothing" is the input the class
# function already gets its unknown-stays-unknown arm from (T-2719d).
d=$(printf 'tests/foo_unit.sh\ndocs/x.md\nchangelog.d/DIVE-1.md\n' | _task_delivery_depth)
[[ "$d" == "shallow" ]] \
  && ok_t "delivery depth: tests/docs/changelog only -> shallow" || bad_t "shallow class" "got '$d'"

# deep WINS over shallow — a mixed set is never downgraded, and the deep path is
# read even though it arrives after two shallow ones.
d=$(printf 'docs/x.md\ntests/y.sh\nsrc/cmd_heartbeat.sh\n' | _task_delivery_depth)
[[ "$d" == "deep" ]] \
  && ok_t "delivery depth: a blast-radius path beats a shallow majority" || bad_t "deep wins" "got '$d'"

# ORDINARY code is neither: the class must stay EMPTY so the caller changes
# nothing. Without this arm the two above are satisfied by a function that only
# ever answers deep-or-shallow, which would rewrite every close on the fleet.
d=$(printf 'src/cmd_agent.sh\ntests/y.sh\n' | _task_delivery_depth)
[[ -z "$d" ]] \
  && ok_t "delivery depth: ordinary code -> unchanged behaviour (empty)" || bad_t "ordinary class" "got '$d'"

# T-2719d: an EMPTY list is UNKNOWN, not shallow. This is the arm that keeps a
# missing gh credential from silently waiving the rail — the all_shallow flag is
# vacuously true on an empty list, so nothing but the `have` guard stops it.
d=$(printf '' | _task_delivery_depth)
[[ -z "$d" ]] \
  && ok_t "delivery depth: no paths -> unknown, never shallow" || bad_t "empty list class" "got '$d'"

# The named exclusion list: data, not a code change.
FIVE_VERIFY_EXCLUDE="main, dev2" _task_verify_excluded main \
  && ok_t "verify exclusion: a listed name is excluded" || bad_t "exclusion hit" "main not excluded"
FIVE_VERIFY_EXCLUDE="main, dev2" _task_verify_excluded eng \
  && bad_t "exclusion miss" "eng excluded by a list that does not name it" \
  || ok_t "verify exclusion: an unlisted name is untouched"
_task_verify_excluded main \
  && bad_t "exclusion default" "excluded with FIVE_VERIFY_EXCLUDE unset" \
  || ok_t "verify exclusion: ships inert (unset list excludes nobody)"

# BASELINE FIRST, so the QA rung below is proven to be what moved the answer and
# not something the fixture already did: with no QA agent in the chart, the
# picker walks up and lands on the leader.
org_seed vfmaker --manager=vflead
org_seed vflead --title="Engineering Lead"
base_v=$(_task_default_verifier vfmaker "")
[[ -n "$base_v" && "$base_v" != "vfmaker" ]] \
  && ok_t "default verifier baseline: walks up to '$base_v' with no QA in the chart" \
  || bad_t "verifier baseline" "got '$base_v'"

# Now name a QA agent. It must win — the chart had already answered who grades.
org_seed vfquinn --title="QA / testing"
v=$(_task_default_verifier vfmaker "")
[[ "$v" == "vfquinn" ]] \
  && ok_t "default verifier: a designated QA agent outranks the up-chain leader" \
  || bad_t "QA rung" "got '$v' (baseline was '$base_v')"
[[ "$v" != "$base_v" ]] \
  && ok_t "default verifier: the QA rung CHANGED the answer (not a coincidence)" \
  || bad_t "QA rung non-vacuity" "same answer as the baseline"

# ...and the exclusion list reaches the picker, not just the predicate.
v=$(FIVE_VERIFY_EXCLUDE="vfquinn" _task_default_verifier vfmaker "")
[[ -n "$v" && "$v" != "vfquinn" ]] \
  && ok_t "default verifier: an excluded candidate is skipped for the next rung" \
  || bad_t "picker exclusion" "got '$v'"

# The maker is still never their own grader, with or without the new rungs.
v=$(_task_default_verifier vfquinn "")
[[ "$v" != "vfquinn" ]] \
  && ok_t "default verifier: the QA agent does not grade its own work" || bad_t "self-grade" "got '$v'"

echo "-----"
echo "task_core_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
