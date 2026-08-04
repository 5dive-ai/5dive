#!/usr/bin/env bash
# TIER: nightly — 5.0s measured on the 5dive dev host (slowest of three consecutive
# local runs of this file; 4.3/4.7/5.0). Demotion is argued, not defaulted: the core PR
# tier last read 270s against its 300s cap (DIVE-2525), so 30s of headroom is all that
# is left for every future harness, and this file needs no PR-time signal that the
# nightly sweep cannot give a day later.
#
# DIVE-2641 isolated unit harness — EVERY accepting arm of the merge gate must say
# what it did NOT establish.
#
# THE DEFECT (DIVE-2621, four independent instances on 2026-08-03): each accepting arm
# prints `done=merged-to-main satisfied`, which is TRUE, at the exact moment the reader
# assumes the STRONGER claim nobody checked — that the change is RUNNING. olivia
# (DIVE-2587), dev (DIVE-2571), dev3 (marketplace clones) and main (the v0.18.3-v0.18.6
# cuts) each made that substitution without knowing about the others. The system told
# them they were done. See
# community/wiki/merged-to-main-is-a-claim-about-the-authors-artifact-not-the-readers.md
#
# WHAT IS PINNED. The ticket says VERIFY BY MUTATION, not by reading the diff: drive an
# ACTUAL close down EACH accepting path and confirm the sentence appears on each. A
# green on one path is not evidence for the other, so there is one case per path:
#   D1  declared delivery_ref, PR MERGED           (the arm that was SILENT before this)
#   D2  `Branch:` binding, ATTRIBUTION on main     (DIVE-2120)
#   D3  `Branch:` binding, MERGED PR for the head  (DIVE-2217)
#   D4  branch named in the RESULT/BODY            (DIVE-2577)
# and the two arms that make the DEPLOYED-ARTIFACT prompt a measurement rather than a
# decoration:
#   D5  the SAME accepting path in a repo that ships no installed artifact -> generic
#       note, NO prompt. Without this arm a prompt that fires unconditionally scores
#       green on D1-D4 and proves nothing about the keying.
#   D6  the marketplace repo gets the PER-CLONE surface, never the host-CLI one.
# plus:
#   D7  a REFUSAL carries neither (this text is a property of ACCEPTANCE; a refused
#       close that printed an accept receipt would be a worse defect than the one
#       being fixed).
#   D8  SOURCE SHAPE: every `done=merged-to-main satisfied` in cmd_task.sh calls the
#       helper on its own line. Behaviour arms cannot see an accepting arm added LATER
#       and written the old way, and an unpatched accepting path is this whole defect
#       re-created (cf. DIVE-2210's "the ticket named 2 sites; there were 3").
#   D9  ZERO ACCEPTANCE CHANGE: the gate still refuses what it refused. The constraint
#       on the ticket is that this must not weaken the merge gate or add failure modes.
#
# MUTATION GRADE — RUN, not predicted. Baseline 21/0; each mutant applied to the
# committed tree, `git checkout --` between, tree clean before and after:
#   M1  `_gate_merged_not_deployed() { :; }`      -> 14/7: every note arm on all four
#                                                   paths, plus D5 and D6.
#   M2  helper keeps the generic half, `case` cut -> 16/5: D1-D4 and D6, i.e. the
#                                                   prompt is graded on every path.
#   M3  helper prints the CLI prompt UNCONDITIONALLY (the keying cut)
#                                                 -> 19/2: D5 (the arm that exists for
#                                                   it) and D6 (wrong surface cited).
#   M4  revert ONLY the D1 call site              -> 17/4: D1's two note arms and BOTH
#                                                   D8 arms (shape + non-vacuity).
#   M5  revert ONLY the D2 call site              -> 16/5: D2, and D5/D6 with it since
#                                                   they accept through the same
#                                                   attribution arm, plus both D8 arms.
#   M6  ANCHOR: put `--category=host` back into the GENERIC half (its first shape)
#                                                 -> 19/2: D5 and D6, the two arms added
#                                                   for it. A fix nobody can red is a fix
#                                                   nobody is grading.
#
# WHAT THE FIRST RUN CORRECTED, recorded because the prediction was wrong in a way that
# would have shipped: M2 was predicted to red D1-D4 and, run against the FIRST version of
# this file, it red only D1 and D6 (19/2). D2/D3/D4 asserted the SURFACE string, which the
# generic half also contains, so deleting the prompt entirely could not move them. They
# now assert $PROMPT as well and M2 was RE-RUN against the tightened arms for the 16/5
# above — a mutant graded before the test changed is a reading of a file that no longer
# exists. The mutation is what found the hole, which is the argument for grading a suite
# by mutation rather than by reading its assertions.
# Isolation matches the sibling gate harnesses: source src/ into a throwaway STATE_DIR
# (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_deploy_note_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-deploy-note-unit.XXXXXX)"

# --- stub gh. Four surfaces matter here:
#   `auth token`                              -> GH_STUB_AUTH_TOKEN
#   `pr view <url> --json ... -q <expr>`      -> keyed on the EXPRESSION the caller
#      asked for, because the declared-delivery path asks three different questions of
#      the same PR: `.state`, `.mergedAt`, and _gate_pr_state's joined rollup triple.
#   `pr list --repo <slug> --head <b> --state merged` -> GH_STUB_PRLIST_merged_<REPO>
#   `api repos/<slug>/commits?sha=main`       -> GH_STUB_COMMITS_<REPO>_main
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
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  # The rollup call joins three fields; the two single-field calls ask for one each.
  case "$expr" in
    *join*)     printf '%s\n' "${GH_STUB_PRVIEW_ROLLUP:-}" ;;
    .state)     printf '%s\n' "${GH_STUB_PRVIEW_STATE:-}" ;;
    .mergedAt)  printf '%s\n' "${GH_STUB_PRVIEW_MERGEDAT:-}" ;;
    *)          : ;;
  esac
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  st="open"; for x in "${a[@]}"; do [[ "$x" == "merged" ]] && st="merged"; done
  lx="GH_STUB_PRLIST_${st}_$(key "${repo##*/}")"
  printf '%s' "${!lx:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "api" ]]; then
  path="$2"
  slug=$(printf '%s' "$path" | cut -d/ -f2,3)
  case "$path" in
    */commits\?*)
      br="${path##*sha=}"; br="${br%%&*}"
      fx="GH_STUB_COMMITS_$(key "${slug##*/}")_$(key "$br")"
      pp=30; case "$path" in *per_page=*) pp="${path##*per_page=}"; pp="${pp%%&*}" ;; esac
      [[ "$pp" =~ ^[0-9]+$ ]] || pp=30
      (( pp > 100 )) && pp=100
      pg=1; case "$path" in *"&page="*) pg="${path##*&page=}"; pg="${pg%%&*}" ;; esac
      [[ "$pg" =~ ^[0-9]+$ && "$pg" -gt 0 ]] || pg=1
      slice=".[$(( (pg-1)*pp )):$(( pg*pp ))]" ;;
    *) exit 1 ;;
  esac
  json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -c "$slice" 2>/dev/null | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
cat >"$TMP/bin/sudo" <<'SUDOSTUB'
#!/usr/bin/env bash
exit 1
SUDOSTUB
chmod +x "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
# `tasks_db_init` creates the BASE schema only; the columns added since (delivery_ref
# among them) come from _tasks_db_migrate, which a fresh fixture store has never run.
# Measured, not assumed: PRAGMA table_info(tasks) counts 0 delivery_ref after init and 1
# after this line. Without it D1's binding lands nowhere, the DIVE-1830 gate sees no
# declared delivery, and the case reports a clean close having exercised NOTHING — a
# green that means the opposite of what it reads as.
_tasks_db_migrate >/dev/null 2>&1
task_need_notify() { :; }
_task_close_notify() { :; }
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"
export FIVE_GATE_REPOS="5dive-ai/5dive"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
seed()     { db "DELETE FROM tasks WHERE ident='$1';
                 INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                   VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
# Bind the delivery_ref by UPDATE, the same shape the sibling harnesses use
# (task_merge_gate_diagnostic_unit.sh:147).
seed_dref() { seed "$1"; db "UPDATE tasks SET delivery_ref='$2', delivered_at=datetime('now') WHERE ident='$1';"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
refusals() { db "SELECT COUNT(*) FROM policy_refusals WHERE ident='$1';"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
clear_fx() { unset "${!GH_STUB_PRLIST_@}" "${!GH_STUB_COMMITS_@}" "${!GH_STUB_PRVIEW_@}" 2>/dev/null; }
commits() { printf '[{"commit":{"message":"%s"}},{"commit":{"message":"chore: unrelated"}}]' "$1"; }
NO_MATCH_COMMITS='[{"commit":{"message":"chore(deps): bump something"}}]'
MERGED_PR='[{"number":41,"mergedAt":"2026-07-26T09:00:00Z","headRefName":"x"}]'

# The two halves, asserted as ANCHORED CLAUSES rather than loose substrings: a bare
# grep for "DEPLOYED" would pass on any sentence containing the word, including the
# generic half, so the arms could not tell each other apart (DIVE-2324's lesson).
NOTE='NOT ESTABLISHED by this: that the change is DEPLOYED'
PROMPT='DEPLOYED-ARTIFACT ROW'
CLI_SURFACE='5dive doctor --category=host'
CLONE_SURFACE='5dive doctor --category=plugins'

# --- D1. DECLARED delivery_ref, PR MERGED -------------------------------------
# The arm that printed NOTHING before this change, and the most common close route
# in the product. Patching only the three arms that already spoke would have left the
# defect fully intact for every row that binds a PR.
clear_fx
export GH_STUB_PRVIEW_STATE="MERGED"
export GH_STUB_PRVIEW_MERGEDAT="2026-08-01T10:00:00Z"
export GH_STUB_PRVIEW_ROLLUP="MERGED|2026-08-01T10:00:00Z|SUCCESS"
seed_dref DEP-1 'https://github.com/5dive-ai/5dive/pull/457'
run_done DEP-1 --result='landed'
[[ $RC -eq 0 && "$(statusof DEP-1)" == "done" && "$(refusals DEP-1)" == "0" ]] \
  && ok_t 'D1: a merged delivery_ref still closes (acceptance unchanged)' \
  || bad_t 'D1 must close' "rc=$RC status=$(statusof DEP-1) refusals=$(refusals DEP-1) out=$OUT"
[[ "$OUT" == *"done=merged-to-main satisfied"* ]] \
  && ok_t 'D1: the declared-delivery accept is now AUDIBLE (it printed nothing before)' \
  || bad_t 'D1 accept must emit a receipt' "out=$OUT"
[[ "$OUT" == *"$NOTE"* ]] \
  && ok_t 'D1: and it says what it did NOT establish' \
  || bad_t 'D1 must carry the not-deployed note' "out=$OUT"
[[ "$OUT" == *"$PROMPT"* && "$OUT" == *"$CLI_SURFACE"* ]] \
  && ok_t 'D1: a CLI-repo delivery is prompted for the installed-side check' \
  || bad_t 'D1 must prompt for the host check' "out=$OUT"

# --- D2. `Branch:` binding, ATTRIBUTION on main -------------------------------
clear_fx
export GH_STUB_COMMITS_5dive_main="$(commits 'fix: the thing (DEP-2)')"
seed DEP-2 'Branch: dep-2-attribution'
run_done DEP-2 --result='landed by delegated push'
[[ $RC -eq 0 && "$(statusof DEP-2)" == "done" && "$(refusals DEP-2)" == "0" ]] \
  && ok_t 'D2: the attribution arm still closes (acceptance unchanged)' \
  || bad_t 'D2 must close' "rc=$RC status=$(statusof DEP-2) refusals=$(refusals DEP-2) out=$OUT"
[[ "$OUT" == *"names DEP-2 in its SUBJECT"* && "$OUT" == *"$NOTE"* \
   && "$OUT" == *"$PROMPT"* && "$OUT" == *"$CLI_SURFACE"* ]] \
  && ok_t 'D2: the ATTRIBUTION receipt carries the note, the prompt and the surface' \
  || bad_t 'D2 attribution arm must carry the note' "out=$OUT"

# --- D3. `Branch:` binding, MERGED PR for the head ----------------------------
clear_fx
export GH_STUB_COMMITS_5dive_main="$NO_MATCH_COMMITS"
export GH_STUB_PRLIST_merged_5dive="$MERGED_PR"
seed DEP-3 'Branch: dep-3-squashed'
run_done DEP-3 --result='squash-merged'
[[ $RC -eq 0 && "$(statusof DEP-3)" == "done" && "$(refusals DEP-3)" == "0" ]] \
  && ok_t 'D3: the merged-PR arm still closes (acceptance unchanged)' \
  || bad_t 'D3 must close' "rc=$RC status=$(statusof DEP-3) refusals=$(refusals DEP-3) out=$OUT"
[[ "$OUT" == *"is the head of a MERGED PR"* && "$OUT" == *"$NOTE"* \
   && "$OUT" == *"$PROMPT"* && "$OUT" == *"$CLI_SURFACE"* ]] \
  && ok_t 'D3: the MERGED-PR receipt carries the note, the prompt and the surface' \
  || bad_t 'D3 merged-PR arm must carry the note' "out=$OUT"

# --- D4. branch named in the RESULT/BODY (DIVE-2577) --------------------------
clear_fx
export GH_STUB_COMMITS_5dive_main="$(commits 'fix: the thing (DEP-4)')"
seed DEP-4
run_done DEP-4 --result='landed via delegated push on branch dep-4-maker-credit'
[[ $RC -eq 0 && "$(statusof DEP-4)" == "done" && "$(refusals DEP-4)" == "0" ]] \
  && ok_t 'D4: the result/body branch arm still closes (acceptance unchanged)' \
  || bad_t 'D4 must close' "rc=$RC status=$(statusof DEP-4) refusals=$(refusals DEP-4) out=$OUT"
[[ "$OUT" == *"named in the result/body"* && "$OUT" == *"$NOTE"* \
   && "$OUT" == *"$PROMPT"* && "$OUT" == *"$CLI_SURFACE"* ]] \
  && ok_t 'D4: the result/body receipt carries the note, the prompt and the surface' \
  || bad_t 'D4 result/body arm must carry the note' "out=$OUT"

# --- D5. THE DIFFERENTIAL: a repo that ships no installed artifact ------------
# Same accepting path as D2, only the repo differs. The generic note is universal;
# the PROMPT is a claim about the deliverable and must not fire where no reader
# executes the artifact. Without this arm, a helper that always prints the prompt is
# green on every case above.
clear_fx
export GH_STUB_COMMITS_5dive_api_main="$(commits 'fix: the api thing (DEP-5)')"
seed DEP-5 'Branch: dep-5-api-side'
FIVE_GATE_REPOS='lodar/5dive-api' run_done DEP-5 --result='landed in the api'
[[ $RC -eq 0 && "$(statusof DEP-5)" == "done" ]] \
  && ok_t 'D5: an api-repo close still closes' \
  || bad_t 'D5 must close' "rc=$RC status=$(statusof DEP-5) out=$OUT"
[[ "$OUT" == *"$NOTE"* ]] \
  && ok_t 'D5: the merged-is-not-deployed note is UNIVERSAL — every accept carries it' \
  || bad_t 'D5 must still carry the generic note' "out=$OUT"
[[ "$OUT" != *"$PROMPT"* && "$OUT" != *"/usr/local/bin/5dive"* && "$OUT" != *"$CLI_SURFACE"* ]] \
  && ok_t 'D5: no prompt and no host-binary check for lodar/5dive-api (keyed, not unconditional)' \
  || bad_t 'D5 prompt must be keyed to the accepting repo' "out=$OUT"

# --- D6. the marketplace repo gets the PER-CLONE surface ----------------------
# Naming the host-CLI check here would cite a surface that cannot answer the question:
# `--category=host` reads /usr/local/bin/5dive and can say nothing about a clone in an
# agent's $HOME (DIVE-2642 built the one that can).
clear_fx
export GH_STUB_COMMITS_5dive_plugins_main="$(commits 'feat: the plugin thing (DEP-6)')"
seed DEP-6 'Branch: dep-6-plugin-side'
FIVE_GATE_REPOS='5dive-ai/5dive-plugins' run_done DEP-6 --result='landed in plugins'
[[ $RC -eq 0 && "$(statusof DEP-6)" == "done" ]] \
  && ok_t 'D6: a plugins-repo close still closes' \
  || bad_t 'D6 must close' "rc=$RC status=$(statusof DEP-6) out=$OUT"
# `!= $CLI_SURFACE` is the arm that matters here and it is not decoration: the first cut
# of the generic half named `--category=host` unconditionally, so a marketplace close
# handed the reader a check that reads /usr/local/bin/5dive and is silent about clones.
# The `/usr/local/bin/5dive` arm alone did NOT catch it — the generic half never carried
# that path — so the assertion has to name the CATEGORY, which is the thing that was wrong.
[[ "$OUT" == *"$PROMPT"* && "$OUT" == *"$CLONE_SURFACE"* \
   && "$OUT" != *"/usr/local/bin/5dive"* && "$OUT" != *"$CLI_SURFACE"* ]] \
  && ok_t 'D6: the marketplace repo is prompted for PER-CLONE freshness and never handed the host check' \
  || bad_t 'D6 must name the clone surface and not the host one' "out=$OUT"

# --- D7. a REFUSAL carries neither -------------------------------------------
clear_fx
export GH_STUB_COMMITS_5dive_main="$NO_MATCH_COMMITS"
seed DEP-7 'Branch: dep-7-never-landed'
run_done DEP-7 --result='trust me'
[[ $RC -ne 0 && "$(statusof DEP-7)" == "in_progress" && "$(refusals DEP-7)" == "1" ]] \
  && ok_t 'D7: genuinely unlanded work is still REFUSED — the gate is not weakened' \
  || bad_t 'D7 must refuse' "rc=$RC status=$(statusof DEP-7) refusals=$(refusals DEP-7) out=$OUT"
[[ "$OUT" != *"$NOTE"* && "$OUT" != *"$PROMPT"* ]] \
  && ok_t 'D7: and it prints no accept receipt (this text is a property of ACCEPTANCE)' \
  || bad_t 'a refusal must not carry an accept receipt' "out=$OUT"

# --- D8. SOURCE SHAPE: no accepting arm can be added without the note ---------
# The behaviour arms above grade the four arms that exist TODAY. They are structurally
# blind to a FIFTH written next year in the old style, and an unpatched accepting path
# is this entire defect re-created — which is exactly how DIVE-2641 came to be filed
# naming two sites when there were three. Grade the shape as well as the behaviour.
_bad_lines=$(grep -n 'done=merged-to-main satisfied' "$SRC/cmd_task.sh" \
             | grep -v '^[0-9]*:[[:space:]]*#' \
             | grep -v '_gate_merged_not_deployed' || true)
[[ -z "$_bad_lines" ]] \
  && ok_t 'D8: EVERY accepting arm in cmd_task.sh calls _gate_merged_not_deployed on its own line' \
  || bad_t 'an accepting arm prints the grade without the note' "$_bad_lines"
# ...and the assertion above is not vacuous: there ARE accepting arms to find.
_n_accepts=$(grep -c 'done=merged-to-main satisfied.*_gate_merged_not_deployed' "$SRC/cmd_task.sh")
[[ "$_n_accepts" -ge 4 ]] \
  && ok_t "D8: non-vacuity — $_n_accepts accepting arms matched, so D8 is grading a real population" \
  || bad_t 'D8 is vacuous: fewer than 4 accepting arms found' "n=$_n_accepts"

# --- D9. ZERO ACCEPTANCE CHANGE: an unbound, code-free close is untouched -----
clear_fx
seed DEP-9
run_done DEP-9 --result='decision recorded, no code involved'
[[ $RC -eq 0 && "$(statusof DEP-9)" == "done" && "$(refusals DEP-9)" == "0" ]] \
  && ok_t 'D9: a close with no binding at all is unaffected (zero regression)' \
  || bad_t 'no-binding close must be untouched' "rc=$RC status=$(statusof DEP-9) out=$OUT"
[[ "$OUT" != *"$NOTE"* ]] \
  && ok_t 'D9: and it carries no note — nothing claimed merged-to-main, so nothing to disclaim' \
  || bad_t 'an ungated close must not carry the note' "out=$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
