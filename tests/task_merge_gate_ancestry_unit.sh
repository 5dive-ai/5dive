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
#   1. ANCESTOR, no PR                  -> CLOSES        (the DIVE-2051 shape)
#   2. SQUASH-merged, NOT an ancestor, merged PR -> STILL CLOSES  (fall-through kept)
#   3. genuinely unmerged, no PR        -> STILL REFUSES (the non-vacuity partner:
#      without it, a fix that always passes scores green on 1 and 2)
#  3b. an EMPTY branch (zero commits: its tip IS a commit on main, so ancestry is
#      trivially true) is REFUSED — ancestry says "this tip is on main", never "this
#      task put something there", so acceptance needs ATTRIBUTION as well: some
#      commit reachable from the tip names the ident. Raised by main pre-merge; it
#      is the MIRROR of case 3, and neither covers the other.
#   4. ancestry UNREACHABLE (gh/network/token) is not "no": with a merged PR it still
#      closes, and WITHOUT one it still refuses — an outage can never invent either
#      verdict.
#   5. the ancestry pass is AUDIBLE in the close (which evidence closed it), and the
#      refusal text names both roads it tried.
#
# MUTATION GRADE (run by hand against src/cmd_task.sh, both must go red):
#   * neuter the ancestry acceptance — `_gate_branch_ancestry() { printf '0'; }`
#     -> case 1 FAILS (refuses the ancestor).
#   * neuter the attribution arm — `_gate_branch_ident_on_main() { printf '1'; }`
#     -> case 3b FAILS (an empty branch closes).
#   * neuter the refusal — delete/short-circuit the `policy_refuse` in the branch
#     path -> case 3 FAILS (closes genuinely unmerged work).
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_ancestry_unit.sh  (no root, no network).
set -uo pipefail
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
a=("$@"); expr='.'; repo=""; i=0
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
    */commits\?*)  # repos/<owner>/<repo>/commits?sha=<branch>&per_page=N
      br="${path##*sha=}"; br="${br%%&*}"
      fx="GH_STUB_COMMITS_$(key "${slug##*/}")_$(key "$br")" ;;
    */compare/*)   # repos/<owner>/<repo>/compare/<base>...<head>
      cmp="${path##*/compare/}"; head="${cmp##*...}"
      fx="GH_STUB_CMP_$(key "${slug##*/}")_$(key "$head")" ;;
    *) exit 1 ;;
  esac
  json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
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
# Commits reachable from a branch tip, newest first, as the API returns them.
commits() { printf '[{"commit":{"message":"%s"}},{"commit":{"message":"chore: unrelated"}}]' "$1"; }

# GitHub's compare(base=main, head=branch) vocabulary: ahead_by counts commits the
# HEAD has that main does not. 0 == the tip is an ancestor of main.
ANCESTOR='{"status":"behind","ahead_by":0,"behind_by":7}'
IDENTICAL='{"status":"identical","ahead_by":0,"behind_by":0}'
NOT_ANCESTOR='{"status":"diverged","ahead_by":3,"behind_by":9}'
AHEAD='{"status":"ahead","ahead_by":2,"behind_by":0}'
MERGED_PR='[{"number":41,"mergedAt":"2026-07-26T09:00:00Z"}]'

# --- 1. THE DIVE-2051 SHAPE: strict ancestor, no PR anywhere -> CLOSES ---------
clear_fx; export GH_STUB_CMP_5dive_dive_2051_git_identity_guard="$ANCESTOR"
export GH_STUB_COMMITS_5dive_dive_2051_git_identity_guard="$(commits 'fix(proof): refuse on unset identity (ANC-1)')"
seed ANC-1 'Branch: dive-2051-git-identity-guard'
run_done ANC-1 --result='verified PASS, landed by delegated push'
if [[ $RC -eq 0 && "$(statusof ANC-1)" == "done" && "$(refusals ANC-1)" == "0" ]]; then
  ok_t 'an ancestor branch with NO PR closes — the delegated-push shape is satisfiable'
else
  bad_t 'ancestor must close' "rc=$RC status=$(statusof ANC-1) refusals=$(refusals ANC-1) out=$OUT"
fi
# ...and the record says WHICH road closed it, not just that it closed.
[[ "$OUT" == *ANCESTOR* && "$OUT" == *"dive-2051-git-identity-guard"* && "$OUT" == *"5dive-ai/5dive"* ]] \
  && ok_t 'the close names the ancestry evidence and the repo it was proved in' \
  || bad_t 'ancestry pass must be audible' "out=$OUT"
# `identical` is the same fact (a tip that IS main) and must read the same way.
clear_fx; export GH_STUB_CMP_5dive_dive_2051_tip="$IDENTICAL"
export GH_STUB_COMMITS_5dive_dive_2051_tip="$(commits 'fix: landed (ANC-2)')"
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
seed UNM-1 'Branch: dive-2101-wip'
run_done UNM-1 --result='I think it is fine'
if [[ $RC -ne 0 && "$(statusof UNM-1)" == "in_progress" && "$(refusals UNM-1)" == "1" ]]; then
  ok_t 'a branch 2 commits AHEAD of main with no PR is still REFUSED — DIVE-1830 intact'
else
  bad_t 'unmerged must still refuse' "rc=$RC status=$(statusof UNM-1) refusals=$(refusals UNM-1) out=$OUT"
fi
[[ "$OUT" == *"ancestor"* && "$OUT" == *"MERGED PR"* && "$OUT" == *"dive-2101-wip"* ]] \
  && ok_t 'the refusal names BOTH roads it tried, so the reader knows what would fix it' \
  || bad_t 'refusal text must name both roads' "out=$OUT"

# --- 3b. VACUITY (main, pre-merge): an ancestor tip is NOT delivered work --------
# A branch with ZERO commits has a tip that IS a commit on main, so ancestry alone
# is trivially true and would close a task that delivered nothing. This is a
# DIFFERENT shape from case 3 (commits that did not land) and neither covers the
# other. Ancestry answers "is this tip on main", never "did this task put anything
# there" — so acceptance needs attribution too.
clear_fx
export GH_STUB_CMP_5dive_dive_2101_empty="$ANCESTOR"          # tip IS on main...
export GH_STUB_COMMITS_5dive_dive_2101_empty="$(commits 'chore(deps): bump something (DIVE-1)')"  # ...carrying nothing of ours
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
export GH_STUB_COMMITS_5dive_dive_2101_novac_with_pr="$(commits 'chore: unrelated (DIVE-1)')"
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
