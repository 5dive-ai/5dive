#!/usr/bin/env bash
# DIVE-4906 — THE COMPUTED GRADE'S RECOGNISER, WIDENED, AND REPLAYED.
#
# DIVE-4828 measured the first 25 PR deliveries after DIVE-4825 was installed:
# the computed pass took 0 of them. The derivation read `tests/*.sh` only, only
# off a line that STARTS with `CHECKED:`, only in the delivering shell's checkout,
# and refused any CHECKED naming two harnesses. This harness grades the widened
# recogniser at the places those misses lived:
#
#   PART A  MENTIONS   node/bun/npm invocations, `*.test.sh` / `*_unit.sh` paths
#                      anywhere, a one-line template, sudo-run harnesses skipped,
#                      other labels not read.
#   PART B  PLAN       a bare file name resolves when unique and not when two
#                      files share it; `npm test` needs a test script; the
#                      harness the diff touched is taken over the ones it did not;
#                      the same test file named twice is one harness.
#   PART C  REPO       a delivery made from the OTHER checkout of a two-repo row
#                      is derived against the PR's own repository — and not at all
#                      when that checkout is ambiguous or absent.
#   PART D  ROUTE      a derived check that is red at the sha routes to the
#                      grader the row would have had, the derivation undone —
#                      never a refused delivery. Control: an EXPLICIT check row
#                      that is red still refuses. A derived check with no mutant
#                      is still COMPUTED (its source-revert control ran). A
#                      two-PR row's green table is still READ.
#   PART E  REPLAY     the 26 field deliveries DIVE-4828 read, rebuilt as repos
#                      from tests/fixtures/grade_derive_corpus/: how many derive
#                      now, against the pre-DIVE-4906 recogniser on the same text.
#   PART F  MUTATION   the one-line split, the sudo skip and the un-derive are cut
#                      out of the shipping functions; the arms above go RED.
#
# Isolation: src/ sourced directly, STATE_DIR on a throwaway dir, every git
# operation inside $TMP. No root, no network, no node (the node/bun commands are
# derived and compared as text; PART D runs bash harnesses only).
# Run: bash tests/task_grade_derive_widen_unit.sh
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP="$(mktemp -d /tmp/derive-widen.XXXXXX)"
REPO_ROOT="$PWD"
CORPUS="$REPO_ROOT/tests/fixtures/grade_derive_corpus"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
printf '{"verify":"always"}\n' > "$BOX_CONFIG"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export FIVEDIVE_GRADE_SAMPLE_N=0

PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { grep -qxF -- "$2" <<<"$1"; }

tasks_db_init >/dev/null 2>&1
_task_default_verifier() { printf 'grader'; }
_task_require_lane()      { return 0; }
_task_deliver_reach_probe() { return 0; }
_grader_spawn_request() { return 0; }
add_row() { local t="$1"; shift
  cmd_task_add "$t $RANDOM" --assignee=dev --from=main --priority=high "$@" 2>/dev/null \
    | jq -r '.data.ident // empty' 2>/dev/null; }
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
# ROUTED means the row was HANDED to the grader seat (assignee=grader). The
# verifier column alone is not the signal: this box is verify=always, so every
# ordinary row carries one from filing and an arm keyed on it reads green always.

# The pre-DIVE-4906 extraction, verbatim, for the before/after count.
old_mentions() {
  _task_grade_claim_block \
    | sed -n '/^CHECKED[[:space:]]*[:(=-]/,/^[A-Z][A-Z0-9_-]*[[:space:]]*[:(=-]/p' \
    | grep -oE '(tests|test)/[A-Za-z0-9_./-]+\.sh' | sort -u
}

echo "── PART A — mentions: what the CHECKED text names ────────────────────────"

M=$(printf 'CHANGED: x\nCHECKED: bash host-bin/5dive-mirror.test.sh 91/0; ./scripts/test-soft-update.test.sh 24/0; tests/pace_unit.sh 19/19; per_model_unit.sh 54/54\nCI: green\n' \
    | _task_grade_harness_mentions)
has "$M" $'sh\thost-bin/5dive-mirror.test.sh' && has "$M" $'sh\tscripts/test-soft-update.test.sh' \
  && has "$M" $'sh\ttests/pace_unit.sh' && has "$M" $'sh\tper_model_unit.sh' \
  && ok_t "shell harnesses: host-bin/*.test.sh, ./scripts/*.test.sh (./ dropped), tests/*.sh, a bare *_unit.sh" \
  || bad_t "shell harness shapes" "$M"

M=$(printf 'CHECKED: api `node --import tsx --test src/routes/browser.test.ts` 44/44; app node --test server-plugins.test.ts 11/11; node scripts/viewer-graph.test.mjs PASS; bun test test/react.test.ts 12/0; full bun test 1610; npm test 904/904\n' \
    | _task_grade_harness_mentions)
has "$M" $'node\tnode --import tsx --test src/routes/browser.test.ts' \
  && has "$M" $'node\tnode --test server-plugins.test.ts' \
  && has "$M" $'node\tnode scripts/viewer-graph.test.mjs' \
  && has "$M" $'bun\tbun test test/react.test.ts' && has "$M" $'bun\tbun test' \
  && has "$M" $'npm\tnpm test' \
  && ok_t "node --test (with flags), plain node *.test.mjs, bun test (with and without a file), npm test" \
  || bad_t "node/bun/npm invocation shapes" "$M"

ONELINE='CHANGED: src/x.ts adds y. CHECKED: node --test src/x.test.ts 10/10, npm test 937/937. DELIVERED-SHA: abc1234. CI: green. CRITERIA: y is shown.'
M=$(printf '%s\n' "$ONELINE" | _task_grade_harness_mentions)
has "$M" $'node\tnode --test src/x.test.ts' \
  && ok_t "a ONE-LINE template (all five labels on one line, DIVE-4875) is read" \
  || bad_t "a one-line template is read" "mentions='$M'"
[[ -z "$(printf '%s\n' "$ONELINE" | old_mentions)" ]] \
  && ok_t "…and the pre-DIVE-4906 extraction reads nothing from it (the arm above is not vacuous)" \
  || bad_t "…the old extraction reads nothing" "it read something"

M=$(printf 'CHECKED: sudo -E scripts/relay.test.sh 66/0; bash tests/mutants/DIVE-1.sh; node scripts/graph.test.mjs PASS\nCRITERIA: tests/crit_unit.sh closes it\n' \
    | _task_grade_harness_mentions)
! grep -q 'relay.test.sh' <<<"$M" && ! grep -q 'mutants' <<<"$M" && ! grep -q 'crit_unit' <<<"$M" \
  && has "$M" $'node\tnode scripts/graph.test.mjs' \
  && ok_t "a sudo-run harness, a mutants/ file and a harness named under ANOTHER label are not mentions" \
  || bad_t "sudo/mutants/other-label exclusions" "$M"

echo "── PART B — plan: which mentions exist at the sha, and which are taken ───"

RB="$TMP/planrepo"; mkdir -p "$RB/src/a" "$RB/src/b" "$RB/tests"
git -C "$RB" init -q
printf 'x\n' > "$RB/src/a/dup.test.ts"; printf 'x\n' > "$RB/src/b/dup.test.ts"
printf 'x\n' > "$RB/src/a/only.test.ts"; printf 'x\n' > "$RB/tests/old_unit.sh"
printf '{"scripts":{"build":"x"}}\n' > "$RB/package.json"
git -C "$RB" add -A; git -C "$RB" commit -qm base
BASEB=$(git -C "$RB" rev-parse HEAD)
printf 'y\n' > "$RB/tests/new_unit.sh"; printf 'y\n' >> "$RB/src/a/only.test.ts"
git -C "$RB" add -A; git -C "$RB" commit -qm head
SHAB=$(git -C "$RB" rev-parse HEAD)
plan() { _task_grade_derive_plan "$RB" "$SHAB" "$1" | cut -f1; }

P=$(printf 'node\tnode --test only.test.ts\n' | plan "")
[[ "$P" == "node --test src/a/only.test.ts" ]] \
  && ok_t "a bare file name resolves to its path when exactly one file carries it" \
  || bad_t "bare name resolves" "plan='$P'"
P=$(printf 'node\tnode --test dup.test.ts\n' | plan "")
[[ -z "$P" ]] && ok_t "…and is NOT guessed between when two files share the name" \
  || bad_t "two files sharing a name are not guessed between" "plan='$P'"
P=$(printf 'npm\tnpm test\n' | plan "")
[[ -z "$P" ]] && ok_t "npm test is not derived when package.json has no test script" \
  || bad_t "npm test needs a test script" "plan='$P'"
P=$(printf 'sh\ttests/old_unit.sh\nsh\ttests/new_unit.sh\n' | plan "$BASEB")
[[ "$P" == "bash tests/new_unit.sh" ]] \
  && ok_t "of two named harnesses, the one the DIFF touched is taken" \
  || bad_t "the touched harness is taken" "plan='$P'"
P=$(printf 'sh\ttests/old_unit.sh\nsh\tnew_unit.sh\n' | plan "")
[[ "$(wc -l <<<"$P")" == 2 ]] \
  && ok_t "…and with no diff to prefer by, every named harness runs" \
  || bad_t "every harness runs when none is preferred" "plan='$P'"
P=$(printf 'node\tnode --import L --test src/a/only.test.ts\nnode\tnode --test only.test.ts\nnode\tnode --test only.test.ts tests/old_unit.sh.test.js\n' | plan "")
[[ "$P" == "node --import L --test src/a/only.test.ts" ]] \
  && ok_t "the same test file named twice is ONE harness (the first invocation of it is kept)" \
  || bad_t "the same test file named twice is one harness" "plan='$P'"

printf '{"scripts":{"test":"node --import tsx --experimental-test-module-mocks --test src/**/*.test.ts"}}\n' > "$RB/package.json"
git -C "$RB" commit -qam "a node test script"; SHAB=$(git -C "$RB" rev-parse HEAD)
P=$(printf 'node\tnode --test only.test.ts\n' | plan "")
[[ "$P" == "node --import tsx --experimental-test-module-mocks --test src/a/only.test.ts" ]] \
  && ok_t "a shorthand 'node --test <file>' runs under the REPOSITORY's own test-script flags" \
  || bad_t "shorthand node --test takes the repository's flags" "plan='$P'"

echo "── PART C — repo: derived against the PR's repository ────────────────────"

HARNESS='#!/usr/bin/env bash
if grep -q GUARD src/foo.sh; then echo "ok   - A1 guard"; exit 0; fi
echo "FAIL - A1 guard"; exit 1
'
# <dir> <origin-url> <branch> [harness-body] — base without the guard, head adds
# the guard and the harness; origin/main at base.
mkrepo() {
  local d="$1" hb="${4:-$HARNESS}"
  mkdir -p "$d/src" "$d/tests"; git -C "$d" init -q -b "$3" 2>/dev/null
  [[ -n "$2" ]] && git -C "$d" remote add origin "$2"
  printf 'echo hi\n' > "$d/src/foo.sh"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base
  git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse HEAD)"
  printf 'echo hi\nGUARD\n' > "$d/src/foo.sh"; printf '%s' "$hb" > "$d/tests/h_unit.sh"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm guard
}
R() { printf 'CHANGED: src/foo.sh\nCHECKED: bash tests/h_unit.sh 1/1\nDELIVERED-SHA: x\nCI: green\nCRITERIA: guard\n'; }
PR_CLI=https://github.com/5dive-ai/5dive/pull/991

W="$TMP/ws1"; mkdir -p "$W"
IDC=$(add_row "delivered from the other checkout")
NUM=$(tr '[:upper:]' '[:lower:]' <<<"$IDC")
mkrepo "$W/plugins-x" https://github.com/5dive-ai/5dive-plugins.git "${NUM}-plugins-side" '#!/bin/sh
exit 0
'
rm -f "$W/plugins-x/tests/h_unit.sh"; git -C "$W/plugins-x" commit -qam "no harness here"
mkrepo "$W/cli-x" https://github.com/5dive-ai/5dive.git "${NUM}-cli-side"
mkrepo "$W/cli-other" https://github.com/5dive-ai/5dive.git "an-unrelated-branch"
( cd "$W/plugins-x" && cmd_task_deliver "$IDC" --pr="$PR_CLI" --result="$(R)" >/dev/null 2>&1 ); rc=$?
[[ "$(col "$IDC" verify_command)" == "bash tests/h_unit.sh" ]] && grep -q "@ $(git -C "$W/cli-x" rev-parse --short=12 HEAD)" <<<"$(col "$IDC" result)" \
  && ok_t "delivered from the plugins checkout, PR in the CLI repo: derived and COMPUTED in the CLI checkout on this row's branch" \
  || bad_t "derived against the PR's repository" "rc=$rc cmd='$(col "$IDC" verify_command)' result='$(col "$IDC" result | head -c 300)'"
(( rc == 0 )) && [[ "$(col "$IDC" assignee)" == dev ]] && grep -q 'verify PASS' <<<"$(col "$IDC" result)" \
  && ok_t "…and its green table closed it with no grader session" \
  || bad_t "…green closes" "rc=$rc assignee='$(col "$IDC" assignee)'"

W="$TMP/ws2"; mkdir -p "$W"
IDC2=$(add_row "two sibling checkouts on the row's branch")
NUM2=$(tr '[:upper:]' '[:lower:]' <<<"$IDC2")
mkrepo "$W/plugins-y" https://github.com/5dive-ai/5dive-plugins.git "${NUM2}-p"
mkrepo "$W/cli-y1" https://github.com/5dive-ai/5dive.git "${NUM2}-a"
mkrepo "$W/cli-y2" https://github.com/5dive-ai/5dive.git "${NUM2}-b"
( cd "$W/plugins-y" && cmd_task_deliver "$IDC2" --pr="$PR_CLI" --result="$(R)" >/dev/null 2>&1 )
[[ "$(col "$IDC2" review_mode)" != "check" && "$(col "$IDC2" assignee)" == grader ]] \
  && ok_t "two candidate checkouts are NOT guessed between: not derived, the ordinary grader takes it" \
  || bad_t "two sibling checkouts are not guessed between" "mode='$(col "$IDC2" review_mode)'"

W="$TMP/ws3"; mkdir -p "$W"
IDC3=$(add_row "no sibling checkout of the PR's repo")
mkrepo "$W/ops-z" https://github.com/5dive-ai/ops.git "$(tr '[:upper:]' '[:lower:]' <<<"$IDC3")-ops"
( cd "$W/ops-z" && cmd_task_deliver "$IDC3" --pr="$PR_CLI" --result="$(R)" >/dev/null 2>&1 )
[[ "$(col "$IDC3" review_mode)" != "check" ]] \
  && ok_t "a checkout of ANOTHER repository with no sibling of the PR's is not derived against" \
  || bad_t "the wrong repository is not derived against" "mode='$(col "$IDC3" review_mode)'"

echo "── PART D — route: a derived check never subtracts a delivery ────────────"

RR="$TMP/red"; mkrepo "$RR" "" main '#!/usr/bin/env bash
echo "FAIL - A1 needs a fixture that was never pushed"; exit 1
'
IDR=$(add_row "derived, red at the sha")
( cd "$RR" && cmd_task_deliver "$IDR" --pr="$PR_CLI" --result="$(R)" >/dev/null 2>&1 ); rc=$?
(( rc == 0 )) && ok_t "a derived check that is RED at the sha does NOT refuse the delivery" \
  || bad_t "a derived red does not refuse" "exit $rc"
[[ "$(col "$IDR" assignee)" == grader ]] && grep -q 'RED AT SHA' <<<"$(col "$IDR" body)" \
  && ok_t "…it goes to the grader the row would have had, with the table on the row" \
  || bad_t "…routed with the table" "verifier='$(col "$IDR" verifier)' body='$(col "$IDR" body | tail -c 300)'"
[[ "$(col "$IDR" review_mode)" != "check" && -z "$(col "$IDR" verify_command)" ]] \
  && ok_t "…and the derivation is UNDONE, so the next delivery derives afresh instead of refusing" \
  || bad_t "…the derivation is undone" "mode='$(col "$IDR" review_mode)' cmd='$(col "$IDR" verify_command)'"

RX="$TMP/redx"; mkrepo "$RX" "" main '#!/usr/bin/env bash
echo "FAIL - A1 red"; exit 1
'
IDX=$(add_row "explicit check, red" --review=check --verify="bash tests/h_unit.sh" --mutant="sed -i s/GUARD/x/ src/foo.sh")
( cd "$RX" && cmd_task_deliver "$IDX" --pr="$PR_CLI" --result="$(R)" >/dev/null 2>&1 ); rc=$?
(( rc != 0 )) && ok_t "control: an EXPLICIT check row that is red at the sha is still refused (the filer chose that command)" \
  || bad_t "control: an explicit red still refuses" "exit 0 — the derived arm above would not be distinguishing anything"

RN="$TMP/nomut"; mkrepo "$RN" "" main
IDN=$(add_row "derived, no mutant")
( cd "$RN" && cmd_task_deliver "$IDN" --pr="$PR_CLI" --result="$(R)" >/dev/null 2>&1 )
RES="$(col "$IDN" result)"
grep -q '^control src/foo.sh' <<<"$RES" && grep -q 'VERDICT computed: PASS' <<<"$RES" \
  && ok_t "a derived check with NO mutant is still computed: its source-revert control ran and went red" \
  || bad_t "a derived check with no mutant is computed" "result='${RES:0:400}'"

RP="$TMP/twopr"; mkrepo "$RP" "" main
IDP=$(add_row "derived, two PRs")
( cd "$RP" && cmd_task_deliver "$IDP" --pr="$PR_CLI" --pr=https://github.com/5dive-ai/5dive-plugins/pull/77 --result="$(R)" >/dev/null 2>&1 )
[[ "$(col "$IDP" assignee)" == grader ]] && grep -q 'companion pull requests' <<<"$(col "$IDP" body)" \
  && ok_t "a GREEN table on a two-PR row is still READ: it graded the primary PR's repository only" \
  || bad_t "a two-PR green table is read" "verifier='$(col "$IDP" verifier)'"

echo "── PART E — replay: the 26 field deliveries DIVE-4828 read ───────────────"

# Each fixture is rebuilt as a repo: base holds its TREE-FILEs, head adds its
# CHANGED-FILEs, package.json carries a test script when the real one did.
n_rows=0 n_named=0 n_old=0 n_new=0 n_unreplayable=0 misses=""
for fx in "$CORPUS"/DIVE-*.txt; do
  id=$(basename "$fx" .txt); n_rows=$((n_rows+1))
  text=$(sed '1,/^---$/d' "$fx")
  mentions=$(printf '%s\n' "$text" | _task_grade_harness_mentions)
  [[ -n "$mentions" ]] && n_named=$((n_named+1))
  [[ -n "$(printf '%s\n' "$text" | old_mentions)" && "$(printf '%s\n' "$text" | old_mentions | wc -l)" == 1 ]] && n_old=$((n_old+1))
  if ! grep -q '^REPLAYABLE: yes' "$fx"; then
    [[ -n "$mentions" ]] && n_unreplayable=$((n_unreplayable+1)); continue
  fi
  d="$TMP/corpus/$id"; mkdir -p "$d"; git -C "$d" init -q
  while IFS= read -r p; do mkdir -p "$d/$(dirname "$p")"; printf 'x\n' > "$d/$p"; done \
    < <(sed -n 's/^TREE-FILE: //p' "$fx")
  if grep -q '^PACKAGE-TEST-SCRIPT: yes' "$fx"; then printf '{"scripts":{"test":"x"}}\n' > "$d/package.json"; fi
  git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm base --allow-empty
  b=$(git -C "$d" rev-parse HEAD)
  while IFS= read -r p; do mkdir -p "$d/$(dirname "$p")"; printf 'y\n' > "$d/$p"; done \
    < <(sed -n 's/^CHANGED-FILE: //p' "$fx")
  git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm head --allow-empty
  plan=$(printf '%s\n' "$mentions" | _task_grade_derive_plan "$d" "$(git -C "$d" rev-parse HEAD)" "$b")
  np=0; [[ -n "$plan" ]] && np=$(wc -l <<<"$plan")
  if (( np >= 1 && np <= 3 )); then n_new=$((n_new+1)); else [[ -n "$mentions" ]] && misses+=" $id"; fi
done
printf '   corpus: %s rows · %s name a harness · derived before DIVE-4906: %s · derived now: %s · not replayable here: %s · missed:%s\n' \
  "$n_rows" "$n_named" "$n_old" "$n_new" "$n_unreplayable" "${misses:- none}"
(( n_rows == 26 )) && ok_t "the corpus is the 26 deliveries DIVE-4828 read" || bad_t "corpus size" "$n_rows"
(( n_new * 2 > n_named )) \
  && ok_t "the MAJORITY of rows that name a harness now derive: ${n_new} of ${n_named} (before: at most ${n_old})" \
  || bad_t "the majority of harness-naming rows derive" "${n_new} of ${n_named}"
(( n_new >= 22 )) && ok_t "…and the measured count holds: ≥22 derive (24 of 26 at DIVE-4906's delivery)" \
  || bad_t "…the measured count holds" "${n_new} derive — the recogniser regressed on the field corpus"

echo "── PART F — mutation: cut the new predicates, the arms above go RED ──────"

CUT="$TMP/cut.sh"
mutate() { # <fn> <sed-expr> <marker-that-must-disappear>
  local fn="$1" expr="$2" gone="$3" body cut
  body=$(declare -f "$fn") || { printf 'NOFN'; return 1; }
  cut=$(printf '%s\n' "$body" | sed "$expr")
  [[ "$cut" == "$body" ]] && { printf 'NOOP'; return 1; }
  grep -q -- "$gone" <<<"$cut" && { printf 'STILLTHERE'; return 1; }
  printf '%s\n' "$cut" > "$CUT"
  bash -n "$CUT" || { printf 'BADSYNTAX'; return 1; }
  printf 'OK'
}

ORIG=$(declare -f _task_grade_checked_text)
r=$(mutate _task_grade_checked_text 's/(CHANGED|CHECKED|/(CHANGED|NOPE|/' 'CHANGED|CHECKED')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation 1 landed: the one-line label split is cut out"
  M=$(printf '%s\n' "$ONELINE" | _task_grade_harness_mentions)
  [[ -z "$M" ]] && ok_t "…and the one-line arm goes red (nothing is read)" \
    || bad_t "…and the one-line arm goes red" "still read: $M"
else bad_t "mutation 1 landed" "$r"; fi
eval "$ORIG"

ORIG=$(declare -f _task_grade_harness_mentions)
r=$(mutate _task_grade_harness_mentions "s/| sed -E 's\/sudo.*g')/)/" 'sudo')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation 2 landed: the sudo skip is cut out"
  M=$(printf 'CHECKED: sudo -E scripts/relay.test.sh 66/0\n' | _task_grade_harness_mentions)
  grep -q relay.test.sh <<<"$M" && ok_t "…and the sudo arm goes red (the sudo-run harness is now a mention)" \
    || bad_t "…and the sudo arm goes red" "not mentioned: '$M'"
else bad_t "mutation 2 landed" "$r"; fi
eval "$ORIG"

ORIG=$(declare -f _task_deliver_command_grade)
r=$(mutate _task_deliver_command_grade 's/_task_grade_underive "\$id" "\$_mode_before"/:/' '_task_grade_underive')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation 3 landed: the un-derive on a non-green derived check is cut out"
  RM="$TMP/redm"; mkrepo "$RM" "" main '#!/usr/bin/env bash
echo "FAIL - A1 red"; exit 1
'
  IDM=$(add_row "derived red, un-derive cut")
  ( cd "$RM" && cmd_task_deliver "$IDM" --pr="$PR_CLI" --result="$(R)" >/dev/null 2>&1 )
  [[ "$(col "$IDM" review_mode)" == "check" ]] \
    && ok_t "…and the undone-derivation arm goes red (the row is left as an explicit check row)" \
    || bad_t "…and the undone-derivation arm goes red" "mode='$(col "$IDM" review_mode)'"
else bad_t "mutation 3 landed" "$r"; fi
eval "$ORIG"

echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAILN"
(( FAILN == 0 )) || exit 1
