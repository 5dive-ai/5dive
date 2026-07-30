#!/usr/bin/env bash
# DIVE-2101 isolated unit harness — ANCESTRY satisfies the DIVE-1830 merge-gate.
#
# The gate demanded a MERGED PR for a `Branch:` binding. The delegated-push path
# (DIVE-1496 — the only way an agent without gh auth lands a branch) puts the commits
# ON main without ever opening a PR, and once they are on main a PR for that branch
# would be an EMPTY diff. So the two requirements were mutually unsatisfiable and
# EVERY delegated-push delivery was permanently unclosable (measured on DIVE-2051:
# `git rev-list --count origin/main..<branch>` = 0, gate still refused).
#
# The fix is proxy-vs-direct, NOT strict-vs-loose: "a PR was merged" is a proxy for
# "the code is in main"; ancestry measures that fact directly. What is pinned here:
#   1. on main, no PR                   -> CLOSES        (the DIVE-2051 shape).
#      Post-DIVE-2120 the accepting evidence is ATTRIBUTION, not ancestry: a commit
#      reachable from main names the ident. Ancestry is diagnostic only.
#   2. SQUASH-merged, NOT an ancestor, merged PR -> STILL CLOSES  (fall-through kept)
#   3. genuinely unmerged, no PR        -> STILL REFUSES (the non-vacuity partner:
#      without it, a fix that always passes scores green on 1 and 2)
#  3b. an EMPTY branch (zero commits: its tip IS a commit on main, so ancestry is
#      trivially true) is REFUSED — ancestry says "this tip is on main", never "this
#      task put something there", so acceptance rests on ATTRIBUTION: some commit
#      reachable from main names the ident. ("as well" until DIVE-2184 — attribution
#      is not a second half, it is the whole of acceptance.) Raised by main pre-merge; it
#      is the MIRROR of case 3, and neither covers the other.
#   4. ancestry UNREACHABLE (gh/network/token) is not "no": with a merged PR it still
#      closes, and WITHOUT one it still refuses — an outage can never invent either
#      verdict.
#   5. the ATTRIBUTION pass is AUDIBLE in the close (which evidence closed it), and
#      the refusal text names both roads it tried. DIVE-2184: it said "ancestry pass"
#      and the close line said ANCESTOR, so the assertion and the message agreed with
#      each other and with nothing else.
#
# MUTATION GRADE (run by hand against src/cmd_task.sh, both must go red):
#   * neuter the ATTRIBUTION acceptance — `_gate_branch_ident_on_main() { printf '0'; }`
#     -> case 1 FAILS (refuses work that is on main).
#     DIVE-2184: this bullet used to name `_gate_branch_ancestry() { printf '0'; }`
#     and claim case 1 would fail. RUN IT: case 1 PASSES. Since DIVE-2120 ancestry
#     accepts nothing, so that mutation is a VOID one — and a void mutation
#     instruction is worse than a stale comment, because the next verifier runs it,
#     sees green, and concludes either the suite is broken or their change is safe.
#   * neuter the attribution arm — `_gate_branch_ident_on_main() { printf '1'; }`
#     -> case 3b FAILS (an empty branch closes).
#   * neuter the refusal — delete/short-circuit the `policy_refuse` in the branch
#     path -> case 3 FAILS (closes genuinely unmerged work).
#   * DIVE-2266: change the bound-hit accumulator back to last-write-wins
#     (`_attr_bound="$_slug:${_attr#bound:}"`) -> ANC-2266 FAILS because the first two
#     bound-hit repos and their own walked counts disappear from the refusal.
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_ancestry_unit.sh  (no root, no network).
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
TMP="$(mktemp -d /tmp/gate-ancestry-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- stub gh. Three surfaces matter here:
#   `api repos/<slug>/compare/<base>...<head>` -> GH_STUB_CMP_<REPO>_<HEAD> (JSON).
#      No fixture => exit 1, i.e. the question could NOT be reached (which is a
#      distinct state from a "no" answer, and case 4 depends on the difference).
#   `pr list --repo <slug> --head <branch>`    -> GH_STUB_PRLIST_<REPO> (JSON array).
#   `auth token`                               -> GH_STUB_AUTH_TOKEN.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0; fi
a=("$@"); expr='.'; repo=""; i=0; slice='.'
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -q|--jq) expr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -q*)     expr="${a[$i]#-q}";    i=$((i+1)) ;;
    --repo)  repo="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)       i=$((i+1)) ;;
  esac
done
key() { printf '%s' "${1//[^A-Za-z0-9]/_}"; }
if [[ "$1" == "api" ]]; then
  path="$2"
  slug=$(printf '%s' "$path" | cut -d/ -f2,3)
  case "$path" in
    */commits\?*)  # repos/<owner>/<repo>/commits?sha=<branch>&per_page=N&page=K
      br="${path##*sha=}"; br="${br%%&*}"
      fx="GH_STUB_COMMITS_$(key "${slug##*/}")_$(key "$br")"
      # THE STUB MODELS GITHUB'S per_page CLAMP, and that fidelity is the whole point
      # of the DIVE-2120 arms. The real API caps per_page at 100 (olivia, measured
      # live: 50->50 rows, 100->100, 200->100, 500->100), so a caller asking for 200
      # gets a SHORT page for a reason that has nothing to do with history ending.
      # A stub that honoured per_page literally would hand back 200 rows and no
      # fixture could ever reproduce the bug — the harness would score the fix green
      # against a world where the bug is impossible.
      pp=30; case "$path" in *per_page=*) pp="${path##*per_page=}"; pp="${pp%%&*}" ;; esac
      [[ "$pp" =~ ^[0-9]+$ ]] || pp=30
      (( pp > 100 )) && pp=100                       # <- the clamp itself
      pg=1; case "$path" in *"&page="*) pg="${path##*&page=}"; pg="${pg%%&*}" ;; esac
      [[ "$pg" =~ ^[0-9]+$ && "$pg" -gt 0 ]] || pg=1
      slice=".[$(( (pg-1)*pp )):$(( pg*pp ))]" ;;
    */compare/*)   # repos/<owner>/<repo>/compare/<base>...<head>
      cmp="${path##*/compare/}"; head="${cmp##*...}"
      fx="GH_STUB_CMP_$(key "${slug##*/}")_$(key "$head")" ;;
    *) exit 1 ;;
  esac
  json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -c "$slice" 2>/dev/null | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  lx="GH_STUB_PRLIST_$(key "${repo##*/}")"
  printf '%s' "${!lx:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then exit 1; fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

# sudo must be stubbed for the whole run or the token resolver reaches the HOST's
# real gh login (real sudo resets PATH to secure_path, so the gh stub is bypassed).
cat >"$TMP/bin/sudo" <<'SUDOSTUB'
#!/usr/bin/env bash
exit 1
SUDOSTUB
chmod +x "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_push.sh cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
_task_close_notify() { :; }
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"
# One repo, pinned, so the suite never follows a default change or the host's config.
export FIVE_GATE_REPOS="5dive-ai/5dive"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
seed()     { db "DELETE FROM tasks WHERE ident='$1';
                 INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                   VALUES ('$1','t',$(sqlq "$2"),'in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
refusals() { db "SELECT COUNT(*) FROM policy_refusals WHERE ident='$1';"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
clear_fx() { unset "${!GH_STUB_CMP_@}" "${!GH_STUB_PRLIST_@}" "${!GH_STUB_COMMITS_@}" 2>/dev/null; }
# DIVE-2120: commits ON MAIN, newest first. Attribution used to query commits?sha=<branch>,
# which 404s once the branch is deleted — making a merged-and-deleted branch identical to
# one that never existed. It now queries sha=main, so these stubs key on main, and only the
# commit SUBJECT is matched (a whole-message match accepted incidental mentions).
commits() { printf '[{"commit":{"message":"%s"}},{"commit":{"message":"chore: unrelated"}}]' "$1"; }
# A history LONGER than one page. Every DIVE-2120 pagination arm needs a main whose
# size is comparable to the real one (1000+ commits): the original defect is invisible
# on any fixture that fits inside a single page, which is why every arm above missed it.
many() { jq -cn --argjson n "$1" '[range(0;$n) | {commit:{message:("chore: filler " + (.|tostring))}}]'; }

# GitHub's compare(base=main, head=branch) vocabulary: ahead_by counts commits the
# HEAD has that main does not. 0 == the tip is an ancestor of main.
ANCESTOR='{"status":"behind","ahead_by":0,"behind_by":7}'
IDENTICAL='{"status":"identical","ahead_by":0,"behind_by":0}'
NOT_ANCESTOR='{"status":"diverged","ahead_by":3,"behind_by":9}'
AHEAD='{"status":"ahead","ahead_by":2,"behind_by":0}'
MERGED_PR='[{"number":41,"mergedAt":"2026-07-26T09:00:00Z"}]'

# --- 1. THE DIVE-2051 SHAPE: strict ancestor, no PR anywhere -> CLOSES ---------
clear_fx; export GH_STUB_CMP_5dive_dive_2051_git_identity_guard="$ANCESTOR"
export GH_STUB_COMMITS_5dive_main="$(commits 'fix(proof): refuse on unset identity (ANC-1)')"
seed ANC-1 'Branch: dive-2051-git-identity-guard'
run_done ANC-1 --result='verified PASS, landed by delegated push'
if [[ $RC -eq 0 && "$(statusof ANC-1)" == "done" && "$(refusals ANC-1)" == "0" ]]; then
  ok_t 'an ancestor branch with NO PR closes — the delegated-push shape is satisfiable'
else
  bad_t 'ancestor must close' "rc=$RC status=$(statusof ANC-1) refusals=$(refusals ANC-1) out=$OUT"
fi
# ...and the record says WHICH road closed it, not just that it closed.
#
# DIVE-2184: this asserted *ANCESTOR* and was green only because the MESSAGE said so.
# This scenario sets BOTH an ancestry stub and an attribution stub, and since DIVE-2120
# it is ATTRIBUTION that accepts — measured by removing the attribution stub from this
# very case, which makes the gate REFUSE (rc=5, "NO commit reachable from it names
# ANC-1"). So ancestry accepts nothing on its own and the old assertion was checking the
# false claim rather than the mechanism, which is how the wording survived the DIVE-2120
# semantics change. Assert the evidence that actually accepted.
[[ "$OUT" == *"names ANC-1 in its SUBJECT"* && "$OUT" == *"5dive-ai/5dive"* ]] \
  && ok_t 'the close names the ATTRIBUTION evidence and the repo it was proved in' \
  || bad_t 'attribution pass must be audible' "out=$OUT"
[[ "$OUT" != *"is an ANCESTOR of"* ]] \
  && ok_t 'and does not claim ancestry, which accepts nothing since DIVE-2120' \
  || bad_t 'close line still claims ancestry' "out=$OUT"
# `identical` is the same fact (a tip that IS main) and must read the same way.
clear_fx; export GH_STUB_CMP_5dive_dive_2051_tip="$IDENTICAL"
export GH_STUB_COMMITS_5dive_main="$(commits 'fix: landed (ANC-2)')"
seed ANC-2 'Branch: dive-2051-tip'
run_done ANC-2 --result='landed'
[[ $RC -eq 0 && "$(statusof ANC-2)" == "done" ]] \
  && ok_t 'status=identical (tip == main) closes too' \
  || bad_t 'identical must close' "rc=$RC status=$(statusof ANC-2) out=$OUT"

# --- 2. THE SQUASH CASE: not an ancestor, but its PR merged -> STILL CLOSES ----
# A squash-merged branch tip is NOT an ancestor of main even though its content is
# in. If ancestry were a veto instead of an alternative, this fix would have created
# a NEW hole in the opposite direction.
clear_fx
export GH_STUB_CMP_5dive_dive_1999_squashed="$NOT_ANCESTOR"
export GH_STUB_PRLIST_5dive="$MERGED_PR"
seed SQ-1 'Branch: dive-1999-squashed'
run_done SQ-1 --result='squash-merged'
if [[ $RC -eq 0 && "$(statusof SQ-1)" == "done" && "$(refusals SQ-1)" == "0" ]]; then
  ok_t 'a squash-merged, NON-ancestor branch still closes on its merged PR (no new hole)'
else
  bad_t 'squash fall-through' "rc=$RC status=$(statusof SQ-1) refusals=$(refusals SQ-1) out=$OUT"
fi
[[ "$OUT" != *ANCESTOR* ]] \
  && ok_t 'the squash close does NOT claim ancestry evidence it does not have' \
  || bad_t 'squash close must not claim ancestry' "out=$OUT"

# --- 3. NON-VACUITY: genuinely unmerged commits, no PR -> STILL REFUSES --------
clear_fx; export GH_STUB_CMP_5dive_dive_2101_wip="$AHEAD"
# DIVE-2318: this case had NO commits fixture, so the attribution scan was
# UNREACHABLE, not answered-no. It graded as "genuinely unmerged" only because every
# not-reached answer used to render as "not merged" — the exact conflation this
# ticket deletes. Give main a history that ANSWERS: one commit, naming nothing of
# ours, and a page shorter than the one requested, which is main's history exhausted
# inside the window. Now the refusal below is a MEASURED absence, which is what this
# arm always claimed to be testing.
export GH_STUB_COMMITS_5dive_main="$(commits 'chore(deps): bump something (DIVE-1)')"
seed UNM-1 'Branch: dive-2101-wip'
run_done UNM-1 --result='I think it is fine'
if [[ $RC -ne 0 && "$(statusof UNM-1)" == "in_progress" && "$(refusals UNM-1)" == "1" ]]; then
  ok_t 'a branch 2 commits AHEAD of main with no PR is still REFUSED — DIVE-1830 intact'
else
  bad_t 'unmerged must still refuse' "rc=$RC status=$(statusof UNM-1) refusals=$(refusals UNM-1) out=$OUT"
fi
# DIVE-2318: this used to assert the refusal named "ancestor" and "MERGED PR" as the
# two roads tried. Ancestry is NOT a road — it has accepted nothing since DIVE-2120,
# and a squash merge makes it unsatisfiable by construction. Naming it sent dev2
# (DIVE-2286) and dev3 (DIVE-2301) hunting a missing branch. Assert the roads that can
# ACCEPT (attribution on main, a merged PR for the head), and assert that ancestry is
# presented as the dead end it is rather than as something to go satisfy.
[[ "$OUT" == *"attribution"* && "$OUT" == *"MERGED PR"* && "$OUT" == *"dive-2101-wip"* ]] \
  && ok_t 'the refusal names the two roads that can ACCEPT, so the reader knows what would fix it' \
  || bad_t 'refusal text must name the accepting roads' "out=$OUT"
[[ "$OUT" == *"Ancestry is NOT one of the ways"* && "$OUT" == *"squash"* ]] \
  && ok_t 'and it says ancestry is NOT one of them, naming squash as why (DIVE-2318)' \
  || bad_t 'refusal must not leave ancestry looking satisfiable' "out=$OUT"

# --- 3b. VACUITY (main, pre-merge): an ancestor tip is NOT delivered work --------
# A branch with ZERO commits has a tip that IS a commit on main, so ancestry alone
# is trivially true and would close a task that delivered nothing. This is a
# DIFFERENT shape from case 3 (commits that did not land) and neither covers the
# other. Ancestry answers "is this tip on main", never "did this task put anything
# there" — so acceptance needs attribution too.
clear_fx
export GH_STUB_CMP_5dive_dive_2101_empty="$ANCESTOR"          # tip IS on main...
export GH_STUB_COMMITS_5dive_main="$(commits 'chore(deps): bump something (DIVE-1)')"  # ...carrying nothing of ours
seed VAC-1 'Branch: dive-2101-empty'
run_done VAC-1 --result='nothing was ever committed here'
if [[ $RC -ne 0 && "$(statusof VAC-1)" == "in_progress" && "$(refusals VAC-1)" == "1" ]]; then
  ok_t 'an EMPTY branch (ancestor tip, no commit naming the ident) is REFUSED — ancestry alone cannot close'
else
  bad_t 'vacuous ancestry must refuse' "rc=$RC status=$(statusof VAC-1) refusals=$(refusals VAC-1) out=$OUT"
fi
slug=$(db "SELECT policy FROM policy_refusals WHERE ident='VAC-1' ORDER BY id DESC LIMIT 1;")
[[ "$slug" == "done-on-vacuous-branch-ancestry" && "$OUT" == *"EMPTY branch"* ]] \
  && ok_t 'the vacuous case refuses under its OWN slug and names the shape, not a generic "not merged"' \
  || bad_t 'vacuity must be named as itself' "slug=[$slug] out=$OUT"
# Attribution UNREACHABLE must decline the acceptance, never grant it: an outage on
# the second half cannot be worth more than the half it was added to check.
clear_fx; export GH_STUB_CMP_5dive_dive_2101_attr_unreachable="$ANCESTOR"
seed VAC-2 'Branch: dive-2101-attr-unreachable'
run_done VAC-2 --result='unknowable'
[[ $RC -ne 0 && "$(statusof VAC-2)" == "in_progress" ]] \
  && ok_t 'attribution unreachable declines the ancestry close (an unresolved half is not a pass)' \
  || bad_t 'unreachable attribution must not close' "rc=$RC status=$(statusof VAC-2) out=$OUT"
# ...and declining is SUBTRACTIVE only: it must not veto a perfectly good merged PR.
clear_fx
export GH_STUB_CMP_5dive_dive_2101_novac_with_pr="$ANCESTOR"
export GH_STUB_COMMITS_5dive_main="$(commits 'chore: unrelated (DIVE-1)')"
export GH_STUB_PRLIST_5dive="$MERGED_PR"
seed VAC-3 'Branch: dive-2101-novac-with-pr'
run_done VAC-3 --result='merged by PR'
[[ $RC -eq 0 && "$(statusof VAC-3)" == "done" ]] \
  && ok_t 'no attribution + a MERGED PR still closes — the vacuity arm subtracts an acceptance, it adds no refusal' \
  || bad_t 'vacuity arm must not veto the PR path' "rc=$RC status=$(statusof VAC-3) out=$OUT"

# --- 4. UNREACHABLE != "not an ancestor" --------------------------------------
# No compare fixture => the stub exits 1, exactly like no token / no network / gh
# absent. That must change NOTHING in either direction.
clear_fx; export GH_STUB_PRLIST_5dive="$MERGED_PR"
seed UNR-1 'Branch: dive-2101-unreachable-with-pr'
run_done UNR-1 --result='merged'
[[ $RC -eq 0 && "$(statusof UNR-1)" == "done" ]] \
  && ok_t 'ancestry unreachable + merged PR still closes (the check cannot veto)' \
  || bad_t 'unreachable must fall through' "rc=$RC status=$(statusof UNR-1) out=$OUT"
clear_fx
seed UNR-2 'Branch: dive-2101-unreachable-no-pr'
run_done UNR-2 --result='trust me'
[[ $RC -ne 0 && "$(statusof UNR-2)" == "in_progress" && "$(refusals UNR-2)" == "1" ]] \
  && ok_t 'ancestry unreachable + no PR still REFUSES (an outage cannot bless a close)' \
  || bad_t 'unreachable must not bless' "rc=$RC status=$(statusof UNR-2) refusals=$(refusals UNR-2) out=$OUT"

# --- 5. the compare call is well-formed and READ-ONLY --------------------------
# A gate that asks the wrong question can still score green on stubs; pin the shape
# of the request itself (base...head against main, in the searched repo).
if grep -q 'ARGS=api repos/5dive-ai/5dive/compare/main\.\.\.dive-2101-wip' "$GH_ARGS_LOG"; then
  ok_t 'the ancestry probe is `gh api repos/<slug>/compare/main...<branch>` (read-only)'
else
  bad_t 'compare request shape' "$(grep -c . "$GH_ARGS_LOG") gh calls, none matching"
fi

# --- 6. a task with NO branch binding is untouched by any of this --------------
clear_fx
seed NOB-1 'a research task, no branch, no PR'
run_done NOB-1 --result='wrote it up'
[[ $RC -eq 0 && "$(statusof NOB-1)" == "done" ]] \
  && ok_t 'a close with no binding at all is unaffected (zero regression)' \
  || bad_t 'no-binding close must be untouched' "rc=$RC status=$(statusof NOB-1) out=$OUT"

# --- DIVE-2120: THE DELETED BRANCH ---------------------------------------------
# Deleting a merged branch is routine hygiene (we deleted four the night DIVE-2101
# shipped). Both old arms queried the API BY BRANCH NAME, so an absent ref 404s and a
# merged-and-deleted branch became byte-identical to one that NEVER EXISTED — the task
# then permanently un-closeable, with a refusal telling the reader to "land the branch"
# for work already on main. No compare stub here AT ALL: that IS the deleted ref.
clear_fx
export GH_STUB_COMMITS_5dive_main="$(commits 'task: the fix (ANC-7)')"
seed ANC-7 'Branch: deleted-after-merge'
run_done ANC-7 --result='landed by delegated push; branch since deleted'
[[ $RC -eq 0 && "$(statusof ANC-7)" == "done" ]] \
  && ok_t 'a DELETED branch still closes — attribution is measured on main, not on the ref' \
  || bad_t 'deleted branch must close' "rc=$RC status=$(statusof ANC-7) out=$OUT"

# --- DIVE-2120: BOUND-HIT IS NOT A MISS ----------------------------------------
# A bounded search whose negative reads like an exhaustive one asserts something it
# never measured. Two commits with the bound forced to 2 means the scan STOPPED, it did
# not exhaust main — so this must refuse under its OWN slug, not the generic one.
clear_fx
export GH_STUB_COMMITS_5dive_main="$(commits 'chore: something else entirely')"
seed ANC-8 'Branch: some-branch'
FIVE_GATE_ANCESTRY_SCAN=2 run_done ANC-8 --result='landed ages ago'
slug=$(db "SELECT COALESCE(policy,'') FROM policy_refusals WHERE ident='ANC-8' ORDER BY rowid DESC LIMIT 1;")
[[ $RC -ne 0 && "$slug" == "done-ident-not-found-within-scan-bound" ]] \
  && ok_t 'a bound-hit refuses under its OWN slug, distinct from a genuine miss' \
  || bad_t 'bound must be named as itself' "rc=$RC slug=[$slug] out=$OUT"
[[ "$OUT" == *INCONCLUSIVE* ]] \
  && ok_t 'the bound refusal says INCONCLUSIVE, not that the work is absent' \
  || bad_t 'bound message must not read as a miss' "out=$OUT"

# --- DIVE-2266: A SET-BOUND REFUSAL NAMES THE WHOLE SET -----------------------
# The branch has no Repo: line and no delivery_ref, so every configured repo is
# searched. Stub the attribution seam directly to give each repo a distinct measured
# count: that makes both membership and count attachment observable. The old overwrite
# leaves only the frontend entry and MUST score red here.
attr_impl=$(declare -f _gate_branch_ident_on_main)
_gate_branch_ident_on_main() {
  case "$1" in
    5dive-ai/5dive)       printf 'bound:2' ;;
    lodar/5dive-api)      printf 'bound:7' ;;
    lodar/5dive-frontend) printf 'bound:11' ;;
  esac
}
clear_fx
seed ANC-2266 'Branch: lives-somewhere-in-the-set'
FIVE_GATE_REPOS='5dive-ai/5dive,lodar/5dive-api,lodar/5dive-frontend' \
  run_done ANC-2266 --result='landed somewhere'
eval "$attr_impl"
if [[ $RC -ne 0 && "$OUT" == *"5dive-ai/5dive:2"* \
      && "$OUT" == *"lodar/5dive-api:7"* \
      && "$OUT" == *"lodar/5dive-frontend:11"* ]]; then
  ok_t 'a bound-hit refusal names EVERY repo in the searched set with its OWN walked count'
else
  bad_t 'bound-hit set must not collapse to its last repo' "rc=$RC out=$OUT"
fi
if [[ "$OUT" == *"NEVER SCANNED"* && "$OUT" == *'Repo: <owner/repo>'* \
      && "$OUT" == *'task deliver ANC-2266 --pr=https://github.com/<owner>/<repo>/pull/N'* ]]; then
  ok_t 'the bound refusal names the unscanned-repo case and both terminating bindings'
else
  bad_t 'bound remediation must cover work outside the searched set' "out=$OUT"
fi

# --- DIVE-2120: AN INCIDENTAL MENTION IS NOT A DELIVERY -------------------------
# Searching main widened the attribution set: every commit reachable from a branch tip
# is on main, but not every commit on main is reachable from that tip — so a
# WHOLE-MESSAGE match accepts commits that merely REFERENCE the ident. Measured live
# while building this: DIVE-2112 matched inside a 2-commit bound because the 0.16.20
# RELEASE commit body names it, having delivered nothing for it. Only the SUBJECT is
# matched. This arm exists because the first mutation run proved the tightening was
# ungraded — every other fixture here is single-line, so subject == message and no
# assertion could tell the two apart.
clear_fx
export GH_STUB_COMMITS_5dive_main='[{"commit":{"message":"release: assign the version four merges landed without\n\nsilently never receives ANC-9 or anything else"}},{"commit":{"message":"chore: unrelated"}}]'
seed ANC-9 'Branch: mentioned-only'
run_done ANC-9 --result='should NOT close on a body mention'
[[ $RC -ne 0 && "$(statusof ANC-9)" != "done" ]] \
  && ok_t 'an ident named only in a commit BODY does not close (incidental mention != delivery)' \
  || bad_t 'body mention must not close' "rc=$RC status=$(statusof ANC-9) out=$OUT"

# --- DIVE-2120 iter.2: A FULL PAGE IS NOT AN EXHAUSTED HISTORY -----------------
# THE DEFECT olivia measured. The first cut asked for per_page=$n in ONE call and read
# a short page as "history ran out". GitHub clamps per_page at 100, so at n=200 the
# page was short for a reason unrelated to exhaustion: the scan saw 100 of main's
# 1000+ commits and returned a GENUINE MISS, which fell through to the generic
# "land the branch" refusal — the exact wrong advice this ticket was filed to kill.
# Worse, the bound refusal's only documented remedy was "raise FIVE_GATE_ANCESTRY_SCAN",
# i.e. the single input that triggers it. Someone whose work landed 150 commits ago
# followed the instruction and ended up worse off than before the fix.
# 300 commits, none naming the ident, bound 200: the scan must stop at its BOUND.
clear_fx
export GH_STUB_COMMITS_5dive_main="$(many 300)"
: >"$GH_ARGS_LOG"
seed ANC-10 'Branch: landed-long-ago'
FIVE_GATE_ANCESTRY_SCAN=200 run_done ANC-10 --result='landed 250 commits back'
slug=$(db "SELECT COALESCE(policy,'') FROM policy_refusals WHERE ident='ANC-10' ORDER BY rowid DESC LIMIT 1;")
[[ $RC -ne 0 && "$slug" == "done-ident-not-found-within-scan-bound" ]] \
  && ok_t 'n=200 over a 300-commit main is a BOUND-hit, not a miss (a clamped page is not an exhausted history)' \
  || bad_t 'a full page must never read as exhaustion' "rc=$RC slug=[$slug] out=$OUT"
# ...and the number in the message is what was WALKED. Reporting the CONFIGURED bound
# was the lie inside the original defect: it claimed 200 having looked at 100.
[[ "$OUT" == *"200 COMMITS WALKED"* ]] \
  && ok_t 'the refusal reports the commits actually WALKED (200), not the number requested' \
  || bad_t 'bound message must report the measurement' "out=$OUT"
# ...and it must offer BOTH surviving explanations. A bound-hit cannot distinguish
# "landed earlier" from "nothing ever named it", and advertising only the first sends
# an empty-branch author off to raise a bound that can never help them.
[[ "$OUT" == *"EMPTY branch"* && "$OUT" == *"FIVE_GATE_ANCESTRY_SCAN"* ]] \
  && ok_t 'the bound refusal names BOTH live explanations, not just the one raising the bound fixes' \
  || bad_t 'bound message must not present one hypothesis as the only one' "out=$OUT"

# --- DIVE-2120 iter.2: THE SCAN ACTUALLY PAGINATES ------------------------------
# What makes the refusal's advice TRUE. If n>100 did not paginate, "raise the bound"
# would still be the instruction that converts an honest INCONCLUSIVE into a false
# miss. Pin the request shape: a second page is fetched, and no request ever asks for
# more than the API will give.
grep -q 'per_page=100&page=2' "$GH_ARGS_LOG" \
  && ok_t 'n>100 fetches page 2 — raising the bound really does walk further' \
  || bad_t 'the scan must paginate past the clamp' "$(grep -c . "$GH_ARGS_LOG") gh calls, none for page 2"
if grep -oE 'per_page=[0-9]+' "$GH_ARGS_LOG" | cut -d= -f2 | awk '$1>100{f=1} END{exit f?1:0}'; then
  ok_t 'no request exceeds the 100 clamp, so a short page can only mean exhaustion'
else
  bad_t 'a request asked for more than the clamp' "$(grep -oE 'per_page=[0-9]+' "$GH_ARGS_LOG" | sort -u | tr '\n' ' ')"
fi

# --- DIVE-2120 iter.2: EXHAUSTION IS STILL DETECTABLE ABOVE THE CLAMP -----------
# The mirror of ANC-10, and it is what keeps the fix from being "call everything
# inconclusive". 150 commits with the bound at 200: page 2 comes back SHORT, which now
# means what it says. This also revives DIVE-2101's anti-vacuity refusal, which
# olivia found UNREACHABLE in production: at the default bound on a 1000+ commit main
# the scan ALWAYS hit the bound, so _attr was never "0" and the arm never fired — it
# passed only because every fixture here was smaller than one page. With exhaustion
# detectable, an ancestor tip carrying nothing attributable is named as itself again.
clear_fx
export GH_STUB_CMP_5dive_dive_2120_empty_big="$ANCESTOR"
export GH_STUB_COMMITS_5dive_main="$(many 150)"
seed ANC-11 'Branch: dive-2120-empty-big'
FIVE_GATE_ANCESTRY_SCAN=200 run_done ANC-11 --result='nothing was ever committed here'
slug=$(db "SELECT COALESCE(policy,'') FROM policy_refusals WHERE ident='ANC-11' ORDER BY rowid DESC LIMIT 1;")
[[ $RC -ne 0 && "$slug" == "done-on-vacuous-branch-ancestry" ]] \
  && ok_t 'a history SHORTER than the bound still exhausts, so the anti-vacuity arm is reachable above one page' \
  || bad_t 'exhaustion above the clamp must still be detectable' "rc=$RC slug=[$slug] out=$OUT"

# --- DIVE-2120 iter.2: a hit on a LATER page still closes -----------------------
# The acceptance path has to survive pagination too, or the fix trades a false miss
# for a false refusal.
clear_fx
export GH_STUB_COMMITS_5dive_main="$(jq -cn --argjson f "$(many 120)" \
  '$f + [{commit:{message:"task: the delivery (ANC-12)"}}] + $f')"
seed ANC-12 'Branch: landed-on-page-two'
FIVE_GATE_ANCESTRY_SCAN=300 run_done ANC-12 --result='landed, just not recently'
[[ $RC -eq 0 && "$(statusof ANC-12)" == "done" ]] \
  && ok_t 'a commit found on page 2 closes the task (pagination does not lose the acceptance)' \
  || bad_t 'a later-page hit must close' "rc=$RC status=$(statusof ANC-12) out=$OUT"

# --- DIVE-2184: the close-evidence line must name the evidence that ACTUALLY closed
# The accepting branch is fed by _gate_branch_ident_on_main (ATTRIBUTION). It used to
# print "is an ANCESTOR of main ... (no PR needed; delegated push)" — false on both
# counts for a squash-merged PR, whose tip is not an ancestor of main at all. A close
# record that names the wrong evidence is worse than a terse one: nobody re-derives it.
clear_fx
export GH_STUB_COMMITS_5dive_main='[{"commit":{"message":"cli: the thing (ANC-84) (#248)"}}]'
seed ANC-84 'Branch: squash-merged-so-not-an-ancestor'
run_done ANC-84 --result='landed via a squash-merged PR'
[[ $RC -eq 0 && "$(statusof ANC-84)" == "done" ]]   && ok_t 'attribution still closes the task'   || bad_t 'attribution must still close' "rc=$RC status=$(statusof ANC-84) out=$OUT"
grep -q 'names ANC-84 in its SUBJECT' <<<"$OUT"   && ok_t 'the close line names ATTRIBUTION as the evidence'   || bad_t 'close line must say a commit subject named the ident' "out=$OUT"
grep -qi 'is an ANCESTOR of' <<<"$OUT"   && bad_t 'close line must NOT claim ancestry (it was not measured)' "out=$OUT"   || ok_t 'no false ancestry claim'
grep -q 'no PR needed; delegated push' <<<"$OUT"   && bad_t 'close line must NOT assert the delegated-push route (the corrected text may MENTION it while disclaiming)' "out=$OUT"   || ok_t 'no false delegated-push claim'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
