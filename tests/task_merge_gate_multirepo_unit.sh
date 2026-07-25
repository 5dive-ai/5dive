#!/usr/bin/env bash
# DIVE-1955 isolated unit harness — the merge-gate across MORE THAN ONE REPO.
#
# DIVE-1935 made the gate live, for one repo. `_PUSH_DEFAULT_REPO` is a readonly
# constant pinned to 5dive-ai/5dive and every binding resolved against it, so
# lodar/5dive-api (== prod) and lodar/5dive-frontend had ZERO coverage — five tasks
# reached status=done there with genuinely unmerged work. The sharper half: off-repo
# the gate was not blind but WRONG. An api task whose result says "PR #6" was judged
# against the CLI repo's unrelated #6, which can refuse a legitimate close or bless a
# bad one. A confident verdict about the wrong pull request is worse than no verdict.
#
# What is pinned here:
#   1. the extractor emits refs QUALIFIED (`slug|n`), a URL carries its own repo, and
#      a URL beats the same number appearing bare;
#   2. a bare #N present in exactly ONE known repo resolves there — including a repo
#      that is not the CLI one (the coverage extension), and DIVE-1935 does not regress;
#   3. a bare #N present in TWO repos with nothing to tell them apart is AMBIGUOUS:
#      loud warn + audit row, close PROCEEDS, and crucially NO policy_refusals row —
#      the gate must not manufacture a verdict it cannot justify;
#   4. the same collision IS resolved when exactly one side names the ident;
#   5. an explicit `Repo:` body line and a full pull URL both defeat the collision;
#   6. `Branch:` is searched in every known repo (it was CLI-only and fail-CLOSED);
#   7. the mandatory auto-detect scan sweeps every repo, and a repo it could not list
#      makes the close UNVERIFIED rather than clean;
#   8. a bare delivery_ref is refused outright — a number is not a PR reference.
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_multirepo_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-multirepo-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- stub gh. REPO-AWARE, which is the whole point: a PR number exists in a
# specific repo, never in the abstract. `GH_STUB_PR_<REPO>_<n>` is the fixture for
# PR #n in that repo (REPO = the bare repo name, non-alnum -> _). A `pr view` with
# no --repo is a full URL and is served from the URL's own slug. No fixture for the
# repo asked about => exit 1, i.e. that PR does not exist THERE.
# `pr list` answers per-repo too, via GH_STUB_PRLIST_<REPO>; GH_STUB_LIST_FAIL_<REPO>
# makes one repo's listing fail so partial coverage can be exercised.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0; fi
a=("$@"); expr='.'; repo=""; i=0
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -q)      expr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -q*)     expr="${a[$i]#-q}";    i=$((i+1)) ;;
    --repo)  repo="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)       i=$((i+1)) ;;
  esac
done
rkey() { local k="${1##*/}"; printf '%s' "${k//[^A-Za-z0-9]/_}"; }
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  ref="$3"
  # A full pull URL identifies its own repo; --repo is only sent for a bare number.
  if [[ -z "$repo" && "$ref" == https://github.com/* ]]; then
    repo=$(printf '%s' "$ref" | cut -d/ -f4,5)
  fi
  n="${ref##*/}"
  fx="GH_STUB_PR_$(rkey "$repo")_${n}"; json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  ff="GH_STUB_LIST_FAIL_$(rkey "$repo")"; [[ -n "${!ff:-}" ]] && exit 1
  lx="GH_STUB_PRLIST_$(rkey "$repo")"
  printf '%s' "${!lx:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

# sudo must be stubbed for the whole run or the token resolver reaches the HOST's
# real gh login (real sudo resets PATH to secure_path, so the gh stub is bypassed).
cat >"$TMP/bin/sudo" <<SUDOSTUB
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
# The three real repos, pinned explicitly so the suite does not silently follow a
# future default change (and so it never depends on the host's own config).
export FIVE_GATE_REPOS="5dive-ai/5dive,lodar/5dive-api,lodar/5dive-frontend"

OPEN_RED='{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"conclusion":"FAILURE"}],"title":"unrelated","headRefName":"unrelated"}'
MERGED_OK='{"state":"MERGED","mergedAt":"2026-07-25T02:52:00Z","statusCheckRollup":[{"conclusion":"SUCCESS"}],"title":"unrelated","headRefName":"unrelated"}'

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
seed()     { db "DELETE FROM tasks WHERE ident='$1';
                 INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                   VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
refusals() { db "SELECT COUNT(*) FROM policy_refusals WHERE ident='$1';"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
clear_fx() { unset "${!GH_STUB_PR_@}" "${!GH_STUB_PRLIST_@}" "${!GH_STUB_LIST_FAIL_@}" 2>/dev/null; }

# --- 1. the QUALIFIED extractor ----------------------------------------------
# The number alone was the bug. These pin that the repo now travels with the ref.
q_case() { # <name> <expected> <text>
  local name="$1" want="$2" got; got=$(_gate_pr_refs_qualified_from_text "$3")
  [[ "$got" == "$want" ]] && ok_t "qualified extractor $name" \
                          || bad_t "qualified extractor $name" "want [$want] got [$got]"
}
q_case 'a pull URL carries its own owner/repo' \
  'lodar/5dive-api|6' 'landed https://github.com/lodar/5dive-api/pull/6 yesterday'
q_case 'a bare "PR #6" carries NO repo (empty slug), which is the honest answer' \
  '|6' 'merged as PR #6'
q_case 'a URL beats the same number appearing bare in the same text' \
  'lodar/5dive-api|6' 'PR #6 — see https://github.com/lodar/5dive-api/pull/6'
q_case 'the same number in TWO repos is TWO refs, not one' \
  'lodar/5dive-api|6
5dive-ai/5dive|6' 'https://github.com/lodar/5dive-api/pull/6 and https://github.com/5dive-ai/5dive/pull/6'
# The back-compat number-only view still behaves (the DIVE-1935 canary rides on it).
_gate_pr_refs_engine_ok && ok_t 'the DIVE-1935 parser canary still passes on the qualified path' \
                        || bad_t 'parser canary broke' "$(_gate_pr_refs_from_text 'ship PR #4242 via https://github.com/o/r/pull/99')"

# --- 2. coverage: a bare #N that exists ONLY in the api repo ------------------
# Before DIVE-1955 this resolved against the CLI repo — where #6 is some other pull
# request — so an api task could close over an OPEN api PR. The number exists in
# exactly one known repo here, so there is nothing to disambiguate.
clear_fx; export GH_STUB_PR_5dive_api_6="$OPEN_RED"
seed API-1
run_done API-1 --result='backend fix landed, merged as PR #6'
if [[ $RC -ne 0 && "$(statusof API-1)" == "in_progress" && "$OUT" == *"lodar/5dive-api"* && "$OUT" == *"#6"* ]]; then
  ok_t 'an OPEN PR in 5dive-api now blocks the close, and the refusal names THAT repo'
else
  bad_t 'api-repo coverage' "rc=$RC status=$(statusof API-1) out=$OUT"
fi

# --- 3. DIVE-1935 must not regress: CLI-only number still resolves ------------
clear_fx; export GH_STUB_PR_5dive_156="$OPEN_RED"
seed CLI-1
run_done CLI-1 --result='SHIPPED and VERIFIED on the rolled binary. Merged as PR #156 into v0.15.4.'
[[ $RC -ne 0 && "$(statusof CLI-1)" == "in_progress" && "$OUT" == *"5dive-ai/5dive"* ]] \
  && ok_t 'the DIVE-1922 shape (CLI-only #156) still refuses — no coverage regression' \
  || bad_t 'DIVE-1935 regression' "rc=$RC status=$(statusof CLI-1) out=$OUT"

# --- 4. THE ANTI-FABRICATION CASE: a real collision, nothing to break the tie --
# #6 exists in the CLI repo (merged, green) and in api (OPEN). Picking either is an
# invented verdict: the CLI one would BLESS a close over an open api PR, the api one
# would REFUSE a legitimate CLI close. The gate must do neither.
clear_fx
export GH_STUB_PR_5dive_6="$MERGED_OK"
export GH_STUB_PR_5dive_api_6="$OPEN_RED"
: >"$AUDIT_CALLS"
seed AMB-1
run_done AMB-1 --result='merged as PR #6'
amb_row=$(grep -c 'task.merge-gate-ambiguous' "$AUDIT_CALLS")
if [[ $RC -eq 0 && "$(statusof AMB-1)" == "done" && "$OUT" == *AMBIGUOUS* \
      && "$OUT" == *"5dive-ai/5dive"* && "$OUT" == *"lodar/5dive-api"* \
      && "$amb_row" -ge 1 && "$(refusals AMB-1)" == "0" ]]; then
  ok_t 'a colliding bare #N reports AMBIGUOUS: loud + audited, close proceeds, NO invented verdict'
else
  bad_t 'ambiguous handling' "rc=$RC status=$(statusof AMB-1) audit=$amb_row refusals=$(refusals AMB-1) out=$OUT"
fi

# --- 5. the collision IS resolved when exactly one side names the ident -------
# Evidence, not a default: the api PR's title names the task, the CLI one does not.
clear_fx
export GH_STUB_PR_5dive_6="$MERGED_OK"
export GH_STUB_PR_5dive_api_6='{"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"title":"fix: thing (EVI-1)","headRefName":"chore/x"}'
seed EVI-1
run_done EVI-1 --result='merged as PR #6'
[[ $RC -ne 0 && "$(statusof EVI-1)" == "in_progress" && "$OUT" == *"lodar/5dive-api"* ]] \
  && ok_t 'ident evidence breaks a collision — the PR that NAMES the task binds, the other is ignored' \
  || bad_t 'ident-evidence disambiguation' "rc=$RC status=$(statusof EVI-1) out=$OUT"

# --- 6. an explicit `Repo:` body line defeats the collision -------------------
clear_fx
export GH_STUB_PR_5dive_6="$MERGED_OK"
export GH_STUB_PR_5dive_api_6="$OPEN_RED"
seed REPO-1 'Repo: lodar/5dive-api
some body'
run_done REPO-1 --result='merged as PR #6'
[[ $RC -ne 0 && "$OUT" == *"lodar/5dive-api"* ]] \
  && ok_t 'a `Repo: owner/repo` body line binds the bare number to that repo' \
  || bad_t 'Repo: body line' "rc=$RC status=$(statusof REPO-1) out=$OUT"
# ...and the symmetric case: declaring the CLI repo means the merged+green #6 there
# is the answer, so the task closes. Same input, different declaration, no guessing.
seed REPO-2 'Repo: 5dive-ai/5dive'
run_done REPO-2 --result='merged as PR #6'
[[ $RC -eq 0 && "$(statusof REPO-2)" == "done" ]] \
  && ok_t 'the same bare #6 declared against the CLI repo resolves there and closes' \
  || bad_t 'Repo: body line (CLI)' "rc=$RC status=$(statusof REPO-2) out=$OUT"

# --- 7. a full pull URL is always resolved in ITS OWN repo --------------------
clear_fx
export GH_STUB_PR_5dive_6="$MERGED_OK"
export GH_STUB_PR_5dive_api_6="$OPEN_RED"
seed URL-1
run_done URL-1 --result='see https://github.com/lodar/5dive-api/pull/6'
[[ $RC -ne 0 && "$OUT" == *"lodar/5dive-api"* ]] \
  && ok_t 'a pull URL is judged in the repo it names, never against the default slug' \
  || bad_t 'url-qualified ref' "rc=$RC status=$(statusof URL-1) out=$OUT"

# --- 8. `Branch:` is searched in EVERY repo (was CLI-only and fail-CLOSED) ----
# This one could not pass before: an api branch had no merged PR "in 5dive-ai/5dive",
# so a legitimately landed api task was permanently unclosable.
clear_fx
export GH_STUB_PRLIST_5dive_api='[{"number":6,"mergedAt":"2026-07-25T01:00:00Z"}]'
seed BR-1 'Branch: fix/api-thing'
run_done BR-1 --result='landed'
[[ $RC -eq 0 && "$(statusof BR-1)" == "done" ]] \
  && ok_t 'a `Branch:` merged in 5dive-api satisfies the gate (it was CLI-only before)' \
  || bad_t 'multi-repo branch search' "rc=$RC status=$(statusof BR-1) out=$OUT"
# ...and a branch merged NOWHERE still refuses, naming every repo it looked in.
clear_fx
seed BR-2 'Branch: fix/ghost'
run_done BR-2 --result='landed'
[[ $RC -ne 0 && "$OUT" == *"5dive-ai/5dive"* && "$OUT" == *"lodar/5dive-frontend"* ]] \
  && ok_t 'an unmerged branch still refuses, and says which repos were searched' \
  || bad_t 'branch fail-closed intact' "rc=$RC status=$(statusof BR-2) out=$OUT"

# --- 9. the mandatory auto-detect scan sweeps every repo ----------------------
clear_fx
export GH_STUB_PRLIST_5dive_frontend='[{"number":16,"headRefName":"dive-1672-council","title":"council rules"}]'
seed DIVE-1672
run_done DIVE-1672 --result='done'
[[ $RC -ne 0 && "$OUT" == *"lodar/5dive-frontend#16"* ]] \
  && ok_t 'an open frontend PR whose BRANCH names the ident blocks the close (scan is fleet-wide)' \
  || bad_t 'auto-detect multi-repo' "rc=$RC status=$(statusof DIVE-1672) out=$OUT"

# --- 10. a repo we could not list makes the close UNVERIFIED, not clean -------
# Partial coverage announced as a clean scan is this ticket's own defect one level up.
clear_fx; export GH_STUB_LIST_FAIL_5dive_api=1
: >"$AUDIT_CALLS"
seed PART-1
run_done PART-1 --result='done'
if [[ $RC -eq 0 && "$OUT" == *UNVERIFIED* && "$OUT" == *partial-repo-scan* ]] \
   && grep -q 'merge-gate-unverified' "$AUDIT_CALLS"; then
  ok_t 'one unlistable repo makes the whole scan UNVERIFIED (partial-repo-scan), audited, fail-open'
else
  bad_t 'partial scan honesty' "rc=$RC out=$OUT audit=$(cat "$AUDIT_CALLS")"
fi

# --- 11. a bare delivery_ref is refused outright ------------------------------
# The fail-CLOSED declared path must not silently invent a repo either. No live task
# carries one (all 7 delivery_refs are URLs, checked 2026-07-25); this keeps it so.
clear_fx; export GH_STUB_PR_5dive_6="$MERGED_OK"; export GH_STUB_PR_5dive_api_6="$OPEN_RED"
seed DR-1
db "UPDATE tasks SET delivery_ref='#6' WHERE ident='DR-1';"
run_done DR-1 --result='landed'
[[ $RC -ne 0 && "$(statusof DR-1)" == "in_progress" \
   && "$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy='done-with-ambiguous-delivery-ref' AND ident='DR-1';")" == "1" ]] \
  && ok_t 'a bare delivery_ref is refused with its own slug — a number is not a PR reference' \
  || bad_t 'bare delivery_ref' "rc=$RC status=$(statusof DR-1) out=$OUT"

# --- 12. cancel is never gated, on any repo -----------------------------------
clear_fx; export GH_STUB_PR_5dive_api_6="$OPEN_RED"
seed CAN-1
out=$(cmd_task_cancel CAN-1 --result='abandoning, api PR #6 stays open' 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof CAN-1)" == "cancelled" ]] \
  && ok_t 'task cancel is never merge-gated, multi-repo included' \
  || bad_t 'cancel must not be gated' "rc=$rc status=$(statusof CAN-1) out=$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
