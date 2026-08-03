#!/usr/bin/env bash
# TIER: nightly — 5.8s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2318 — the merge gate's REFUSALS must not assert things nobody measured.
#
# THE DEFECT THIS GRADES IS THE DIAGNOSTIC, NOT THE CHECK. The gate's acceptance
# behaviour is unchanged by DIVE-2318 and the anchor arms below pin that. What was
# wrong is what the refusal SAID, in three separate places, all the same shape:
# a question that could not be REACHED was rendered as a question that was ANSWERED NO.
#
#   1. no gh credential  -> "its delivery PR is not merged to main yet (pull/295,
#      state=unknown)". Measured on DIVE-2286: that PR had merged 90 minutes earlier.
#      The sentence is false about the world. dev2 went hunting a deleted branch,
#      then main filed a confident wrong mechanism (squash/ancestry) on top of it.
#      `task merge-audit` names the missing credential correctly on the SAME fault —
#      two verbs, one cause, opposite diagnostics.
#   2. attribution scan unreachable -> the generic "branch is NOT on main". An API
#      failure and an exhaustive miss printed the identical sentence.
#   3. the branch refusal named ANCESTRY as an acceptance route. It has not accepted
#      anything since DIVE-2120/2184, and under our default squash merge it is
#      unsatisfiable by construction (measured on PR #300 / DIVE-2301: the branch tip
#      is not an ancestor of main while the content diff over the changed paths is
#      EMPTY). An error naming an impossible condition sends readers to look for a
#      missing branch — it did, twice.
#
# MUTATION GRADE — RUN, not predicted (2026-07-29, against src/cmd_task.sh; the
# arm names below are the ones that ACTUALLY went red, 17/0 clean):
#   * neuter the `[[ -z "$_ghtok" ]]` guard        -> 14/3: T1 slug, T1 names-the-
#     credential, T4 branch-path-credential. NOTE which arms do NOT move: "T1 fail-safe"
#     and "T1 does NOT claim the PR is unmerged" stay green, because without the guard
#     the declared path falls through to done-pr-state-unresolved, which also refuses
#     and also asserts no verdict. Those two arms pin the DIRECTION, not this guard.
#   * neuter the `[[ -z "$_state" ]]` branch       -> 15/2: both T2 arms.
#   * neuter the `_attr_unreach` branch            -> 14/3: both T5 arms and T5b.
#   * restore "neither an ancestor of it nor the head of a MERGED PR" -> 15/2: both T6
#     wording arms (T6's slug arm stays green — the slug did not change, the text did).
#   * make the guard refuse UNCONDITIONALLY        -> 7/10, including T7 and T8. Those
#     two are the whole reason the anchors exist: a guard that simply refused everything
#     would satisfy every could-not-check arm in this file.
#
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh AND sudo are STUBBED on PATH.
# Run: bash tests/task_merge_gate_diagnostic_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-diagnostic-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# --- stub sudo (DIVE-1935 resolution order): the token resolver's last resort is
# `sudo -n -u claude gh auth token`. On THIS host that actually succeeds for an
# agent whose sudoers is `ALL=(ALL) NOPASSWD: ALL` (agent-dev), so without this
# stub the no-credential arms below would reach a LIVE oauth token, print it into
# the argv log, and grade against a credential the fleet does not uniformly have.
# Always fails: no arm here wants a real token.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"

# --- stub gh. Surfaces used here:
#   `auth token`                        -> GH_STUB_AUTH_TOKEN (exit 1 when empty)
#   `pr view <ref> --json state,...`    -> GH_STUB_STATE / GH_STUB_MERGED / rollup
#   `pr list --repo <slug> --head <br>` -> GH_STUB_PRLIST_<REPO> (JSON array)
#   `api repos/<slug>/commits?...`      -> GH_STUB_COMMITS_<REPO>_<BRANCH> (JSON)
#   `api repos/<slug>/compare/...`      -> GH_STUB_CMP_<REPO>_<HEAD> (JSON)
# NO FIXTURE => exit 1, i.e. the question could not be REACHED. That is a distinct
# state from a "no" answer and the whole suite turns on the difference.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'TOKEN=%s ARGS=%s\n' "${GH_TOKEN:-}" "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0
fi
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
  path="$2"; slug=$(printf '%s' "$path" | cut -d/ -f2,3)
  case "$path" in
    */commits\?*)
      br="${path##*sha=}"; br="${br%%&*}"
      fx="GH_STUB_COMMITS_$(key "${slug##*/}")_$(key "$br")" ;;
    */compare/*)
      cmp="${path##*/compare/}"; head="${cmp##*...}"
      fx="GH_STUB_CMP_$(key "${slug##*/}")_$(key "$head")" ;;
    *) exit 1 ;;
  esac
  json="${!fx:-}"; [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  lx="GH_STUB_PRLIST_$(key "${repo##*/}")"
  printf '%s' "${!lx:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  # An EMPTY GH_STUB_STATE models a query that returned nothing at all (the ref is
  # invisible to this token / deleted / gh failed), not a PR in state "".
  [[ -n "${GH_STUB_STATE:-}" ]] || exit 1
  printf '%s' "{\"state\":\"${GH_STUB_STATE}\",\"mergedAt\":${GH_STUB_MERGED:-null},\"statusCheckRollup\":[]}" \
    | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
# tasks_db_init only runs _tasks_db_migrate for a PRE-EXISTING store; a fresh one
# gets the CREATE TABLE schema, which does not carry delivery_ref. Without this the
# first bind_pr fails silently, the task closes with NO binding at all, and T1 grades
# a row the gate never looked at — a green that means nothing.
_tasks_db_migrate
task_need_notify() { :; }
audit_log() { :; }

seed()      { db "INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                    VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
statusof()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
slugof()    { db "SELECT policy FROM policy_refusals WHERE ident='$1' ORDER BY id DESC LIMIT 1;"; }
bind_pr()   { db "UPDATE tasks SET delivery_ref='$2', delivered_at=datetime('now') WHERE ident='$1';"; }
run_done()  { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }

# Fixture helpers. `commits` builds a main-history page; a page SHORTER than the
# per_page asked for is what the scan reads as history EXHAUSTED (a genuine miss).
commits()   { local o="["; local s; for s in "$@"; do o="$o{\"commit\":{\"message\":\"$s\"}},"; done; printf '%s]' "${o%,}"; }
no_token()  { unset GH_TOKEN GITHUB_TOKEN; export SUDO_USER=""; export GH_STUB_AUTH_TOKEN=""; }
a_token()   { unset GH_TOKEN GITHUB_TOKEN; export SUDO_USER=""; export GH_STUB_AUTH_TOKEN="tok-2318"; }
clear_fx()  { local v; for v in $(compgen -v | grep -E '^GH_STUB_(COMMITS|CMP|PRLIST)_' || true); do unset "$v"; done
              unset GH_STUB_STATE GH_STUB_MERGED; }

# ---------------------------------------------------------------------------
# T1 — NO CREDENTIAL, declared delivery_ref. The refusal must name the missing
# credential and must NOT assert the PR is unmerged. This is DIVE-2286 verbatim.
# ---------------------------------------------------------------------------
clear_fx; no_token
seed D-1; bind_pr D-1 'https://github.com/5dive-ai/5dive/pull/295'
run_done D-1 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(statusof D-1)" != "done" ]] \
  && ok_t 'T1 no-credential still REFUSES (fail-safe direction unchanged)' \
  || bad_t 'T1 fail-safe' "rc=$RC status=$(statusof D-1) out=$OUT"
[[ "$(slugof D-1)" == "done-merge-gate-no-credential" ]] \
  && ok_t 'T1 refuses under its OWN slug (the cause is recorded, not just the block)' \
  || bad_t 'T1 slug' "slug=[$(slugof D-1)] out=$OUT"
[[ "$OUT" == *"COULD NOT CHECK"* && "$OUT" == *"no gh credential"* ]] \
  && ok_t 'T1 the message names the missing credential, like merge-audit already does' \
  || bad_t 'T1 names the credential' "out=$OUT"
# THE REGRESSION ITSELF: the old string asserted a merge verdict nobody measured.
[[ "$OUT" != *"is not merged to main yet"* && "$OUT" != *"state=unknown"* ]] \
  && ok_t 'T1 does NOT claim the PR is unmerged — an unknown is not a negative' \
  || bad_t 'T1 must not assert a merge verdict' "out=$OUT"

# ---------------------------------------------------------------------------
# T2 — token present, PR-state query returns NOTHING. Distinct from T1 (the
# credential resolved) and distinct from T3 (no state was ever read).
# ---------------------------------------------------------------------------
clear_fx; a_token
seed D-2; bind_pr D-2 'https://github.com/5dive-ai/5dive/pull/296'
run_done D-2 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof D-2)" == "done-pr-state-unresolved" ]] \
  && ok_t 'T2 an unanswerable PR query refuses as UNRESOLVED, not as not-merged' \
  || bad_t 'T2 unresolved slug' "rc=$RC slug=[$(slugof D-2)] out=$OUT"
[[ "$OUT" == *"COULD NOT READ"* && "$OUT" != *"is not merged to main yet"* ]] \
  && ok_t 'T2 says the question was never answered' \
  || bad_t 'T2 wording' "out=$OUT"

# ---------------------------------------------------------------------------
# T3 — ANCHOR. A real negative must survive all of this: an OPEN PR is a MEASURED
# not-merged and must still refuse under the ORIGINAL DIVE-1830 slug. Without this
# arm, T1/T2 are satisfiable by deleting the not-merged refusal entirely.
# ---------------------------------------------------------------------------
clear_fx; a_token; export GH_STUB_STATE="OPEN" GH_STUB_MERGED="null"
seed D-3; bind_pr D-3 'https://github.com/5dive-ai/5dive/pull/297'
run_done D-3 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof D-3)" == "done-before-pr-merged" && "$OUT" == *"state=OPEN"* ]] \
  && ok_t 'T3 ANCHOR: a genuinely OPEN PR still refuses as not-merged, and names the MEASURED state' \
  || bad_t 'T3 real negative preserved' "rc=$RC slug=[$(slugof D-3)] out=$OUT"

# ---------------------------------------------------------------------------
# T4 — NO CREDENTIAL on the BRANCH path. Same fault, other binding: every probe
# on that path (attribution, ancestry, pr list) is an API call too.
# ---------------------------------------------------------------------------
clear_fx; no_token
seed B-1 'Branch: dive-2318-thing'
run_done B-1 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof B-1)" == "done-merge-gate-no-credential" ]] \
  && ok_t 'T4 the branch path refuses on the credential too, not on the branch' \
  || bad_t 'T4 branch-path credential' "rc=$RC slug=[$(slugof B-1)] out=$OUT"
[[ "$OUT" != *"is NOT on main"* ]] \
  && ok_t 'T4 does NOT blame the branch for a fault in the caller environment' \
  || bad_t 'T4 must not blame the branch' "out=$OUT"

# ---------------------------------------------------------------------------
# T5 — token present, attribution scan UNREACHABLE (no commits fixture => gh api
# exits 1). Previously indistinguishable from an exhaustive miss.
# ---------------------------------------------------------------------------
clear_fx; a_token
seed B-2 'Branch: dive-2318-unreachable'
run_done B-2 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof B-2)" == "done-attribution-unresolved" ]] \
  && ok_t 'T5 an unreachable attribution scan refuses as UNRESOLVED, under its own slug' \
  || bad_t 'T5 unreachable slug' "rc=$RC slug=[$(slugof B-2)] out=$OUT"
[[ "$OUT" == *"COULD NOT SCAN"* && "$OUT" != *"MEASURED"* ]] \
  && ok_t 'T5 describes the scan, and asserts nothing about the branch' \
  || bad_t 'T5 wording' "out=$OUT"

# T5b — PARTIAL COVERAGE, which is the shape that actually occurs: the default
# search set spans three repos, one answers an exhaustive miss and the others cannot
# be read by this token. A negative over a set that was not fully covered is not a
# negative. This arm is why the unresolved branch is keyed on ANY unreachable repo
# rather than on ALL of them.
clear_fx; a_token
export GH_STUB_COMMITS_5dive_main="$(commits 'chore(deps): bump something (DIVE-1)')"
seed B-5 'Branch: dive-2318-partial'
run_done B-5 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof B-5)" == "done-attribution-unresolved" && "$OUT" == *"PARTIAL COVERAGE"* ]] \
  && ok_t 'T5b one repo answered and two did not — refuses as PARTIAL COVERAGE, not as absent' \
  || bad_t 'T5b partial coverage' "rc=$RC slug=[$(slugof B-5)] out=$OUT"

# T5c — DIVE-2324: ACCUMULATE every unreachable repo, not just the last one seen.
# A plain overwrite (`_attr_unreach="$_slug"`) named only the FINAL unreachable repo
# of a multi-repo search, under-reporting the coverage gap this message exists to
# describe — the same overwrite-vs-accumulate bug DIVE-2266 fixed for `_attr_bound`.
# Stub the attribution seam directly (as ANC-2266 does) rather than the raw gh commit
# pages: it gives exact per-repo control without depending on pagination fixtures.
attr_impl=$(declare -f _gate_branch_ident_on_main)
_gate_branch_ident_on_main() {
  case "$1" in
    5dive-ai/5dive)       printf '0' ;;  # one repo answers cleanly (exhausted, no hit)
    lodar/5dive-api)      printf ''  ;;  # unreachable
    lodar/5dive-frontend) printf ''  ;;  # unreachable
  esac
}
clear_fx; a_token
seed B-6 'Branch: dive-2324-multi-unreach'
FIVE_GATE_REPOS='5dive-ai/5dive,lodar/5dive-api,lodar/5dive-frontend' \
  run_done B-6 --result='landed'
eval "$attr_impl"
# ANCHORED, not a bare substring match: $_searched (every repo that was searched,
# regardless of whether it answered) ALSO contains 'lodar/5dive-api' and
# 'lodar/5dive-frontend', so asserting on the names alone is true whether
# _attr_unreach accumulated or overwrote — it does not grade the fix (main, on
# review: verified by mutation, the overwrite-reverted source still passed this
# exact assertion). Pin the phrase that immediately precedes $_attr_unreach in the
# message instead, so the comma-joined list is graded in its own position.
[[ $RC -eq $E_CONFLICT && "$(slugof B-6)" == "done-attribution-unresolved" \
   && "$OUT" == *"COULD NOT SCAN main in lodar/5dive-api, lodar/5dive-frontend for a commit naming"* ]] \
  && ok_t 'T5c DIVE-2324: names EVERY unreachable repo, not just the last' \
  || bad_t 'T5c accumulate unreachable' "rc=$RC slug=[$(slugof B-6)] out=$OUT"

# ---------------------------------------------------------------------------
# T6 — token present, main's history EXHAUSTED with no commit naming the ident and
# no merged PR. This is the one true "not landed" on the branch path. It must
# refuse under DIVE-1830 — and must no longer offer ANCESTRY as a way to satisfy
# the gate, because a squash merge makes that unsatisfiable by construction.
# ---------------------------------------------------------------------------
clear_fx; a_token
# EVERY repo in the default search set must answer, or this is T5b's partial-coverage
# case rather than a genuine miss.
#
# DIVE-2431: this used to hardcode the three slugs the default set happened to contain.
# When the default went 3 -> 11, the eight new repos had no stub, read as UNREACHABLE,
# and this arm stopped testing what it says it tests — a genuine miss became T5b's
# partial-coverage refusal and T6 went red for a reason unrelated to its subject. A
# fixture that names a set the CODE owns is a second copy of that set, and the copy is
# the one nobody updates. So derive it: whatever `_gate_repo_slugs` returns is what gets
# stubbed, and this arm keeps its meaning through the next widening without an edit.
stub_every_default_repo() {
  local slug name n=0
  while read -r slug; do
    [[ -n "$slug" ]] || continue
    n=$((n+1))
    name="${slug##*/}"; name="${name//[^A-Za-z0-9]/_}"
    # A page SHORTER than per_page = history exhausted, which is what makes this a
    # genuine miss rather than a bounded scan. Distinct idents so no stub can
    # accidentally name the ident under test.
    eval "export GH_STUB_COMMITS_${name}_main=\"\$(commits 'chore(deps): bump ${name} (DIVE-90${n})')\""
  done < <(FIVE_GATE_REPOS='' _gate_repo_slugs)
  # An empty set would stub nothing and the arm would pass for the wrong reason.
  (( n >= 3 )) || { echo "T6 fixture: _gate_repo_slugs returned $n repos — refusing to assert a genuine miss against a set that small" >&2; return 1; }
}
stub_every_default_repo || bad_t 'T6 fixture could not stub the default repo set' 'see stderr'
seed B-3 'Branch: dive-2318-genuinely-absent'
run_done B-3 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof B-3)" == "done-before-branch-merged" ]] \
  && ok_t 'T6 a genuine miss still refuses under DIVE-1830 (acceptance unchanged)' \
  || bad_t 'T6 genuine miss' "rc=$RC slug=[$(slugof B-3)] out=$OUT"
[[ "$OUT" != *"neither an ancestor of it nor the head of a MERGED PR"* ]] \
  && ok_t 'T6 the refusal no longer names ANCESTRY as an acceptance route' \
  || bad_t 'T6 stale ancestry claim is back' "out=$OUT"
[[ "$OUT" == *"squash"* && "$OUT" == *"attribution"* ]] \
  && ok_t 'T6 states why ancestry cannot serve (squash rewrites the sha) and what does' \
  || bad_t 'T6 must explain the real criterion' "out=$OUT"

# ---------------------------------------------------------------------------
# T7/T8 — ANCHORS on the ACCEPTING side. The new credential guard sits ahead of
# every probe, so a bug in it would refuse everything and T1-T6 would all still
# pass. These two are the arms that catch that.
# ---------------------------------------------------------------------------
clear_fx; a_token; export GH_STUB_STATE="MERGED" GH_STUB_MERGED='"2026-07-29T04:10:37Z"'
seed D-4; bind_pr D-4 'https://github.com/5dive-ai/5dive/pull/298'
run_done D-4 --result='landed'
[[ $RC -eq 0 && "$(statusof D-4)" == "done" ]] \
  && ok_t 'T7 ANCHOR: a MERGED delivery PR still CLOSES with a resolved token' \
  || bad_t 'T7 merged PR must still close' "rc=$RC status=$(statusof D-4) out=$OUT"

clear_fx; a_token
export GH_STUB_COMMITS_5dive_main="$(commits 'fix(gate): name the missing credential (B-4)')"
seed B-4 'Branch: dive-2318x-landed'
run_done B-4 --result='landed'
[[ $RC -eq 0 && "$(statusof B-4)" == "done" ]] \
  && ok_t 'T8 ANCHOR: attribution on main still CLOSES the branch path (squash-merge shape)' \
  || bad_t 'T8 attribution must still close' "rc=$RC status=$(statusof B-4) out=$OUT"

echo "-----"
printf 'task_merge_gate_diagnostic_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
