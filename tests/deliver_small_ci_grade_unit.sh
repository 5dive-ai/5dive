#!/usr/bin/env bash
# DIVE-6223 isolated unit harness — a small or docs-only DELIVERY books no grader
# session, and the row it leaves behind is one somebody may actually merge.
#
# The defect: DIVE-2719 (docs-only) and DIVE-4559 (verify-small) were asked only
# by `task done`, and the fleet delivers through `task deliver`, which routed
# every delivery to the grader. Measured 2026-10-14: a one-file README PR (+71/-5)
# under verify-small=150 sat in quinn's queue. And DIVE-6210: a review=check row
# whose command PASSED stayed unmergeable, because the pass was stamped with the
# maker's seat and writer != grader stripped merge standing from everyone.
#
# Every downgrade arm has a CONTROL beside it — same box, same stubs, one input
# changed — so a green arm cannot come from a build where the downgrade fires
# unconditionally.
#
# Run: bash tests/deliver_small_ci_grade_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/deliver-small-ci.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh lib/runs.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/verify_policy_fixture.sh"

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1
fixture_box_verify_policy delivered-only || bad_t "fixture" "policy"
fixture_box_verify_small 150 || bad_t "fixture" "verify-small"

# The diff and the seats are stubbed; what is under test is the branch.
_task_default_verifier() { printf 'grader'; }
_task_verify_skip_reason() { printf ''; }
_merge_hold_seat() { printf 'ops'; }
_task_companion_refs() { [[ "${COMP:-}" == 1 ]] && printf 'https://github.com/o/ops/pull/9\n'; return 0; }
# The diff reaches the rail the way it does in production: through the reach
# probe's ONE read (quinn, iteration 2). Every request is logged so the budget
# arm can count them.
mkdir -p "$TMP/bin"
# The stub answers with a JSON pull request and applies the CALLER's own -q, so
# the probe's jq (the changedFiles comparison included) is what runs, not a copy
# of it. EXTRA_DOCS=N puts N one-line docs files ahead of FILES_PATH; CHANGED
# overrides changedFiles (gh's real count when it cuts the list at 100);
# GH_NOFILES=1 answers in the anonymous rail's shape, a state and nothing else.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >>"$GH_ARGS_LOG"
[[ "$*" == *"--json state,files,changedFiles"* ]] || exit 1
q=.; while (( $# )); do [[ "$1" == -q ]] && { q="$2"; break; }; shift; done
if [[ "${GH_NOFILES:-0}" == 1 ]]; then printf '{"state":"OPEN"}' | jq -r "$q"; exit; fi
jq -nr --arg p "${FILES_PATH:-README.md}" --argjson n "${FILES_LINES:-76}" \
       --argjson x "${EXTRA_DOCS:-0}" --arg c "${CHANGED:-}" '
  ([range($x) | {path: "docs/f\(.).md", additions: 1, deletions: 0}] + [{path: $p, additions: $n, deletions: 0}]) as $f
  | {state: "OPEN", files: $f, changedFiles: (if $c == "" then ($f | length) else ($c | tonumber) end)}' \
  | jq -r "$q"
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"
_gate_gh_token() { printf 'tok'; }
files_tsv() { printf '%s\t%s' "${FILES_PATH:-README.md}" "${FILES_LINES:-76}"; }

col() { db "SELECT COALESCE($2,'') FROM tasks WHERE id=$1;"; }
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
# Every arm, control or not, first proves the delivery LANDED: a refused
# delivery leaves a row that is "not CI-graded" for a reason that has nothing to
# do with the rule under test.
landed() { [[ -n "$(col "$1" delivery_ref)" ]] || { bad_t "delivery refused ($2)" "$(head -c 300 "$TMP/out.$1")"; return 1; }; }

# deliver_row <flags...> -> id of a row delivered by dev2 to a temp grader lane
deliver_row() {
  local out id
  out=$(cmd_task_add "small fixture $RANDOM" --assignee=dev2 --from=main --priority=high --body="w" "$@" 2>/dev/null)
  id=$(jq -r '.data.id // empty' <<<"$out")
  ( actor_seam_as dev2; cmd_task_start "$id" >/dev/null 2>&1
    cmd_task_deliver "$id" --pr="https://github.com/o/r/pull/$id" \
      --result=$'CHANGED: x\nCHECKED: y\nDELIVERED-SHA: '"$HEAD_SHA"$'\nCI: not finished at delivery\nCRITERIA: z' ) >"$TMP/out.$id" 2>&1
  printf '%s' "$id"
}

echo "── the row's harness: +76 README closes without a grader, +290 code is graded ──"
id_doc=$(FILES_PATH=README.md FILES_LINES=76 deliver_row)
landed "$id_doc" id_doc
[[ "$(col "$id_doc" verify_forced)" != "1" ]] \
  && ok_t "fixture: the row is not force-flagged (the arms below are not vacuous)" \
  || bad_t "fixture forced" "verify_forced=1"
if [[ -z "$(col "$id_doc" verifier)" && "$(col "$id_doc" graded_by)" == "ci:docs-only" \
      && "$(col "$id_doc" graded_verdict)" == "pass" && "$(col "$id_doc" assignee)" == "ops" \
      && "$(col "$id_doc" merge_owner)" == "ops" && "$(col "$id_doc" status)" == "todo" ]]; then
  ok_t "a +76 README delivery books NO grader: CI-graded, handed to the merge seat"
else
  bad_t "README delivery skips the grader" "verifier='$(col "$id_doc" verifier)' graded_by='$(col "$id_doc" graded_by)' assignee='$(col "$id_doc" assignee)' out=$(head -c 400 "$TMP/out.$id_doc")"
fi
_gs=$(_gate_graded_sha "$(col "$id_doc" result)")
[[ -n "$_gs" && "$_gs" == "$(col "$id_doc" delivered_sha)" ]] \
  && ok_t "the CI grade names the delivered head as its graded-sha (the merge disposition pins it)" \
  || bad_t "graded-sha" "graded-sha='$_gs' delivered_sha='$(col "$id_doc" delivered_sha)'"
grep -q 'CHANGED: x' <<<"$(col "$id_doc" result)" \
  && ok_t "the maker's result is kept above the CI line" || bad_t "result kept" "$(col "$id_doc" result)"
grep -q 'DIVE-6223' "$TMP/out.$id_doc" \
  && ok_t "the skip names itself on stderr" || bad_t "silent skip" "$(head -c 300 "$TMP/out.$id_doc")"

# quinn, iteration 2: the rail spends no request of its own. The reach probe's
# one read is the whole GitHub cost of a delivery, skipped or not
# (tests/task_deliver_reach_probe_unit.sh R7a pins the same budget).
: >"$GH_ARGS_LOG"
id_one=$(FILES_PATH=README.md FILES_LINES=76 deliver_row)
landed "$id_one" id_one
_n=$(grep -c '^GH ' "$GH_ARGS_LOG")
[[ "$(col "$id_one" graded_by)" == "ci:docs-only" && "$_n" == "1" ]] \
  && ok_t "a CI-graded delivery spends ONE GitHub request, the reach probe's" \
  || bad_t "one request" "graded_by='$(col "$id_one" graded_by)' requests=$_n: $(cat "$GH_ARGS_LOG")"
# Unknown is graded: an answer with no file list (the anonymous rail's shape),
# and a probe that is switched off, both leave the row on its grader.
id_nof=$(GH_NOFILES=1 FILES_PATH=README.md FILES_LINES=5 deliver_row)
landed "$id_nof" id_nof
[[ "$(col "$id_nof" assignee)" == "grader" && -z "$(col "$id_nof" graded_by)" ]] \
  && ok_t "a readable PR with no file list in the answer is graded (unknown is not small)" \
  || bad_t "no file list graded" "assignee='$(col "$id_nof" assignee)' graded_by='$(col "$id_nof" graded_by)'"
# quinn, iteration 3: gh cuts the file list at 100 with no error. 100 docs files
# listed out of 101 changed would read as docs-only if the list were taken as
# whole; the probe hands over nothing, so the row is graded.
id_cut=$(EXTRA_DOCS=99 CHANGED=101 FILES_PATH=README.md FILES_LINES=1 deliver_row)
landed "$id_cut" id_cut
[[ "$(col "$id_cut" assignee)" == "grader" && "$(col "$id_cut" graded_by)" != ci:* ]] \
  && ok_t "a list gh cut off (100 docs files of 101 changed) is graded, not read as docs-only" \
  || bad_t "cut-off list graded" "assignee='$(col "$id_cut" assignee)' graded_by='$(col "$id_cut" graded_by)'"
# CONTROL: the same 100 docs files with nothing cut off still skip the grader.
id_full=$(EXTRA_DOCS=99 FILES_PATH=README.md FILES_LINES=1 deliver_row)
landed "$id_full" id_full
[[ "$(col "$id_full" graded_by)" == "ci:docs-only" ]] \
  && ok_t "CONTROL: 100 docs files, all listed, are still CI-graded" \
  || bad_t "full list control" "assignee='$(col "$id_full" assignee)' graded_by='$(col "$id_full" graded_by)'"
id_poff=$(FIVE_DELIVER_NO_REACH_PROBE=1 FILES_PATH=README.md FILES_LINES=5 deliver_row)
landed "$id_poff" id_poff
[[ "$(col "$id_poff" assignee)" == "grader" && -z "$(col "$id_poff" graded_by)" ]] \
  && ok_t "with the reach probe off the row is graded, and nothing is fetched to decide" \
  || bad_t "probe off graded" "assignee='$(col "$id_poff" assignee)' graded_by='$(col "$id_poff" graded_by)'"

id_big=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=290 deliver_row)
landed "$id_big" id_big
[[ "$(col "$id_big" verifier)" == "grader" && "$(col "$id_big" assignee)" == "grader" && -z "$(col "$id_big" graded_by)" ]] \
  && ok_t "CONTROL: a +290 code delivery is still routed to its grader" \
  || bad_t "big control" "verifier='$(col "$id_big" verifier)' assignee='$(col "$id_big" assignee)' graded_by='$(col "$id_big" graded_by)'"

echo "── size, and what beats it ──"
id_sm=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=40 deliver_row)
landed "$id_sm" id_sm
[[ "$(col "$id_sm" graded_by)" == "ci:small" && -z "$(col "$id_sm" verifier)" && "$(col "$id_sm" assignee)" == "ops" ]] \
  && ok_t "a 40-line code delivery under verify-small=150 is CI-graded" \
  || bad_t "small code" "graded_by='$(col "$id_sm" graded_by)' verifier='$(col "$id_sm" verifier)'"

id_deny=$(FILES_PATH=src/lib/verify_policy.sh FILES_LINES=5 deliver_row)
landed "$id_deny" id_deny
[[ "$(col "$id_deny" assignee)" == "grader" ]] \
  && ok_t "a 5-line shared-lib delivery is still graded (the denylist beats the size)" \
  || bad_t "denylist" "assignee='$(col "$id_deny" assignee)' graded_by='$(col "$id_deny" graded_by)'"

id_force=$(FILES_PATH=README.md FILES_LINES=5 deliver_row --verify)
landed "$id_force" id_force
[[ "$(col "$id_force" assignee)" == "grader" && -z "$(col "$id_force" graded_by)" ]] \
  && ok_t "--verify beats both rails at delivery, docs-only included" \
  || bad_t "forced" "assignee='$(col "$id_force" assignee)' graded_by='$(col "$id_force" graded_by)'"

id_pin=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=10 deliver_row --review=quinn)
landed "$id_pin" id_pin
[[ "$(col "$id_pin" graded_by)" != ci:* && "$(col "$id_pin" assignee)" != "ops" ]] \
  && ok_t "a row pinned to a NAMED grader keeps it" \
  || bad_t "pinned seat" "graded_by='$(col "$id_pin" graded_by)' assignee='$(col "$id_pin" assignee)'"

id_comp=$(COMP=1 FILES_PATH=README.md FILES_LINES=5 deliver_row)
landed "$id_comp" id_comp
[[ "$(col "$id_comp" graded_by)" != ci:* ]] \
  && ok_t "a row binding companion PRs is still graded (the measurement read one PR, DIVE-4899)" \
  || bad_t "companion" "graded_by='$(col "$id_comp" graded_by)'"

fixture_box_verify_small off || bad_t "fixture" "small off"
id_off=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=10 deliver_row)
landed "$id_off" id_off
[[ "$(col "$id_off" assignee)" == "grader" ]] \
  && ok_t "with verify-small=off a 10-line code delivery is graded" \
  || bad_t "knob off" "assignee='$(col "$id_off" assignee)' graded_by='$(col "$id_off" graded_by)'"
fixture_box_verify_small 150 || bad_t "fixture" "small on"

fixture_box_verify_policy never || bad_t "fixture" "never"
fixture_box_verify_small 150 || true
id_never=$(FILES_PATH=README.md FILES_LINES=5 deliver_row)
landed "$id_never" id_never
[[ -z "$(col "$id_never" graded_by)" ]] \
  && ok_t "a verify=never box keeps its own declined arm (no CI grade is invented)" \
  || bad_t "never" "graded_by='$(col "$id_never" graded_by)'"
fixture_box_verify_policy delivered-only || true
fixture_box_verify_small 150 || true

echo "── a seat's FAIL is not overruled by a smaller diff (quinn, iteration 1) ──"
# The realistic shape: the reject says "drop the extra files", the fix shrinks
# the PR under the cutoff. The re-delivery goes back to the grader that
# rejected it; CI does not stamp 'pass' over a seat's verdict.
id_rj=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=290 deliver_row)
landed "$id_rj" id_rj
[[ "$(col "$id_rj" assignee)" == "grader" ]] || bad_t "reject fixture" "first delivery not on grader: '$(col "$id_rj" assignee)'"
( actor_seam_as grader
  cmd_task_reject "$id_rj" --feedback="FINDING: too wide. FIX: drop the extra files. VERIFY: re-run the harness." ) >"$TMP/out.rj" 2>&1
[[ -n "$(col "$id_rj" handoff_rejected_at)" && "$(col "$id_rj" assignee)" == "dev2" ]] \
  || bad_t "reject fixture" "the reject did not land: $(head -c 400 "$TMP/out.rj")"
( actor_seam_as dev2
  FILES_PATH=src/cmd_agent.sh FILES_LINES=40 cmd_task_deliver "$id_rj" --pr="https://github.com/o/r/pull/$id_rj" \
    --result=$'CHANGED: dropped the extra files\nCHECKED: y2\nDELIVERED-SHA: '"$HEAD_SHA"$'\nCI: not finished at delivery\nCRITERIA: z' ) >"$TMP/out.rj2" 2>&1
[[ "$(col "$id_rj" assignee)" == "grader" && "$(col "$id_rj" verifier)" == "grader" \
   && "$(col "$id_rj" graded_by)" != ci:* && "$(col "$id_rj" graded_verdict)" != "pass" ]] \
  && ok_t "reject, then a +40 re-delivery: back on its grader, not CI-graded" \
  || bad_t "reject-then-shrink" "assignee='$(col "$id_rj" assignee)' verifier='$(col "$id_rj" verifier)' graded_by='$(col "$id_rj" graded_by)' verdict='$(col "$id_rj" graded_verdict)' out=$(head -c 400 "$TMP/out.rj2")"

# A recorded seat FAIL verdict (task verify, rc!=0) holds the same way; a ci:*
# fail is the rail's own and is not a seat's.
id_vf=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=40 deliver_row)
landed "$id_vf" id_vf
db "UPDATE tasks SET graded_by='quinn', graded_verdict='fail', graded_at=datetime('now'),
       graded_verdict_at=datetime('now') WHERE id=${id_vf};"
[[ -z "$(_task_delivery_grader_skip "$id_vf" "$(FILES_PATH=src/cmd_agent.sh FILES_LINES=40 files_tsv)")" ]] \
  && ok_t "a seat-recorded FAIL verdict keeps the grader on a small re-delivery" \
  || bad_t "seat fail verdict" "skip='$(_task_delivery_grader_skip "$id_vf" "$(FILES_PATH=src/cmd_agent.sh FILES_LINES=40 files_tsv)")'"
db "UPDATE tasks SET graded_by='ci:small' WHERE id=${id_vf};"
[[ "$(_task_delivery_grader_skip "$id_vf" "$(FILES_PATH=src/cmd_agent.sh FILES_LINES=40 files_tsv)")" == small\|* ]] \
  && ok_t "CONTROL: the same FAIL stamped ci:* does not block the size rail" \
  || bad_t "ci fail control" "skip='$(_task_delivery_grader_skip "$id_vf" "$(FILES_PATH=src/cmd_agent.sh FILES_LINES=40 files_tsv)")'"

echo "── merge standing on a CI-graded row ──"
stand() { db "SELECT COUNT(*) FROM tasks WHERE id=$1 AND $(_task_merge_standing_sql "$2");"; }
[[ "$(stand "$id_doc" ops)" == "1" ]] \
  && ok_t "the merge owner holds merge standing on a CI-graded row" || bad_t "owner standing" "count=$(stand "$id_doc" ops)"
[[ "$(stand "$id_doc" dev2)" == "0" && "$(stand "$id_doc" grader)" == "0" ]] \
  && ok_t "the maker and an unrelated seat hold none" || bad_t "others" "dev2=$(stand "$id_doc" dev2) grader=$(stand "$id_doc" grader)"
# CONTROL: the same merge_owner on a SEAT-graded row confers nothing — the
# widening is scoped to graded_by 'ci:*' and nowhere else.
db "UPDATE tasks SET graded_by='quinn', graded_verdict='pass', graded_at=datetime('now'),
       graded_verdict_at=datetime('now'), merge_owner='ops' WHERE id=${id_big};"
[[ "$(stand "$id_big" ops)" == "0" && "$(stand "$id_big" quinn)" == "1" ]] \
  && ok_t "CONTROL: merge_owner on a seat-graded row grants nothing; its grader keeps standing" \
  || bad_t "seat-graded control" "ops=$(stand "$id_big" ops) quinn=$(stand "$id_big" quinn)"
_idoc=$(col "$id_doc" ident)
( _task_merge_preflight "$_idoc" ops ) >/dev/null 2>&1 \
  && ok_t "preflight lets the merge owner through" || bad_t "preflight owner" "refused ops"
( _task_merge_preflight "$_idoc" dev2 ) >/dev/null 2>&1 \
  && bad_t "preflight maker" "the maker passed the preflight" || ok_t "preflight refuses the maker"

echo "── DIVE-6210: a command PASS on a row that already recorded its maker ──"
# Delivered once to a temp grader (maker_agent recorded), then re-delivered with
# --verify=<cmd>: the command grades it, run in the maker's seat.
id_chk=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=290 deliver_row)
landed "$id_chk" id_chk
[[ "$(col "$id_chk" maker_agent)" == "dev2" ]] || bad_t "check fixture" "maker_agent='$(col "$id_chk" maker_agent)'"
( actor_seam_as dev2
  cmd_task_deliver "$id_chk" --pr="https://github.com/o/r/pull/$id_chk" --verify='true' \
    --result=$'CHANGED: x2\nCHECKED: true\nDELIVERED-SHA: '"$HEAD_SHA"$'\nCI: not finished at delivery\nCRITERIA: z' ) >"$TMP/out.chk" 2>&1
if [[ "$(col "$id_chk" graded_verdict)" == "pass" ]]; then
  [[ "$(col "$id_chk" graded_by)" == "ci:command" && "$(col "$id_chk" merge_owner)" == "ops" \
     && -z "$(col "$id_chk" verifier)" && "$(stand "$id_chk" ops)" == "1" ]] \
    && ok_t "the PASS is recorded as the command's, and the merge seat can merge it" \
    || bad_t "check restamp" "graded_by='$(col "$id_chk" graded_by)' merge_owner='$(col "$id_chk" merge_owner)' verifier='$(col "$id_chk" verifier)' standing=$(stand "$id_chk" ops)"
else
  bad_t "check fixture" "the command grade did not pass: $(head -c 500 "$TMP/out.chk")"
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAILN"
(( FAILN == 0 ))
