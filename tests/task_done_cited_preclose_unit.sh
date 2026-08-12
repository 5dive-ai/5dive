#!/usr/bin/env bash
# TIER: nightly — 12.3s measured on the 5dive control plane (3 runs of the arms: the mutation grading re-executes the whole harness twice more, by design). Does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2096 isolated unit harness — cited-not-delivered as a PRE-CLOSE check.
#
# THE DEFECT. Two agents hit the identical wall from opposite sides inside ~2h on
# 2026-07-26: olivia on DIVE-2064, main on DIVE-2080. main closed, and the
# merge-gate warned IN THE SAME BREATH AS CLOSING that PR #209 was CITED not
# DELIVERED — so nothing bound it and its merge state was never checked. `done`
# then froze the body, so the record could not be repaired, and the only remedy
# the warning could name (bounce it back to the maker to fix the verifier's own
# metadata) is wildly disproportionate to the error. The diagnosis and the point
# of no return arrived together. Nothing hinted at the correct sequence — merge ->
# `task deliver --pr` -> `done` — until it was too late to act on it.
#
# THE FIX IS ORDERING, NOT INFERENCE, and the boundary is the whole design:
#   * DIVE-1965 (done) separates a PR the task DELIVERED from one it REPORTS ON.
#     Kept: this refuses, it never reclassifies.
#   * DIVE-1962 (CANCELLED) proposed INFERRING the binding from a PR number in
#     prose, and was cancelled because that OVERCLAIMS. So prose is the TRIGGER
#     for the prompt and NEVER the SOURCE of the binding — arm 8 is the pin: after
#     an opt-out close, `delivery_ref` is STILL empty. Nothing was inferred.
#
# What is pinned here:
#   1. a prose PR token with NO binding refuses, PRE-COMMIT, with the remedy named;
#   2. the refusal is genuinely pre-commit — status, result and body are untouched,
#      which is the entire point of the ticket and not a side detail;
#   3. a bound `delivery_ref` is unchanged (the declared DIVE-1830 path still runs);
#   4. a `Branch:` line is unchanged — it is the same structured declaration, and
#      the fleet's dominant delegated-push flow must not gain friction;
#   5. no PR token at all is unchanged — zero regression on research/docs closes;
#   6. `--no-pr` is the named opt-out for DIVE-1965's reports-on category, and it
#      is AUDITED (an unrecorded assertion is indistinguishable from a bypass);
#   7. `--force-merge-gate` also overrides (one escape hatch, not two policies);
#   8. NOTHING IS INFERRED — the DIVE-1962 line, pinned as an assertion;
#   9. a body-only citation triggers it too (the ask says "--result/body");
#  10. `task cancel` is untouched — abandoning a task is not closing one.
#
# MUTATION-GRADED (community/wiki/grade-absence-assertions-by-mutation.md). An
# absence assertion that asserts nothing looks exactly like a passing one, so the
# harness ends by re-running ITSELF against two mutant trees and REQUIRING each to
# red: (M1) the pre-check neutered, (M2) the `--no-pr` opt-out neutered. A build
# where either survives green is a harness that is grading nothing.
#
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_done_cited_preclose_unit.sh  (no root, no network).
set -uo pipefail

# The mutant re-run points this at a patched copy of src/. It is deliberately NOT
# FIVE_-prefixed: tests/lib/env_isolation.sh (sourced by grading_tree.sh, below)
# CLEARS inherited FIVE_* knobs so a harness never grades the caller's env, and a
# FIVE_-prefixed name here would be wiped between this line and its first use.
MUT_SRC="${MUT_SRC:-}"
MUTANT_CHILD="${MUTANT_CHILD:-}"

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the obvious hardening also swallows the
# helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2770: the merge gate has a CREDENTIAL-FREE rail (unauthenticated read of a
# public repo). Left on, the arms below would reach the real network and grade a
# LIVE PR instead of the fixture. Must sit AFTER grading_tree.sh, which clears
# inherited FIVE_* knobs.
export FIVE_GATE_NO_ANON=1

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
SRC="${MUT_SRC:-src}"
TMP="$(mktemp -d /tmp/cited-preclose-unit.XXXXXX)"

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
  if [[ -z "$repo" && "$ref" == https://github.com/* ]]; then repo=$(printf '%s' "$ref" | cut -d/ -f4,5); fi
  n="${ref##*/}"
  fx="GH_STUB_PR_$(rkey "$repo")_${n}"; json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  lx="GH_STUB_PRLIST_$(rkey "$repo")"
  printf '%s' "${!lx:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
# sudo must be stubbed or the token resolver reaches the HOST's real gh login.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-2010 STORE IDENTITY fence: declare the fixture store as prod so the
# `task.done-no-pr` audit-row assertion exercises the real path.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
_task_close_notify() { :; }
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"
export FIVE_GATE_REPOS="5dive-ai/5dive,lodar/5dive-api,lodar/5dive-frontend"

MERGED_OK='{"state":"MERGED","mergedAt":"2026-07-26T02:52:00Z","statusCheckRollup":[{"conclusion":"SUCCESS"}],"title":"unrelated","headRefName":"unrelated"}'

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
seed()     { db "DELETE FROM tasks WHERE ident='$1';
                 INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                   VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
resultof() { db "SELECT COALESCE(result,'') FROM tasks WHERE ident='$1';"; }
bodyof()   { db "SELECT COALESCE(body,'')   FROM tasks WHERE ident='$1';"; }
drefof()   { db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE ident='$1';"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }

# The distinctive sentence of THIS refusal. Every "unchanged" arm below asserts
# its ABSENCE, so it is defined once — a per-arm literal is how a typo turns an
# absence assertion into a tautology.
MARK='A citation in prose is not a binding'

# --- 1. the refusal itself ----------------------------------------------------
seed CIT-1 'no binding here'
run_done CIT-1 --result='shipped, see PR #209 for the change'
[[ $RC -ne 0 && "$OUT" == *"$MARK"* ]] \
  && ok_t '1. prose PR token + no binding REFUSES' \
  || bad_t '1. must refuse' "rc=$RC out=$OUT"
[[ "$OUT" == *"task deliver CIT-1 --pr="* ]] \
  && ok_t '1b. the refusal names the remedy, with the ident already filled in' \
  || bad_t '1b. remedy must be actionable' "out=$OUT"
[[ "$OUT" == *"--no-pr"* ]] \
  && ok_t '1c. the refusal names the opt-out for the reports-on case' \
  || bad_t '1c. must name --no-pr' "out=$OUT"
[[ "$OUT" == *"#209"* ]] \
  && ok_t '1d. the refusal names the ref it saw' \
  || bad_t '1d. must name the ref' "out=$OUT"

# --- 2. PRE-COMMIT is the whole ticket ---------------------------------------
# The DIVE-2414 disclosure this replaces was correct and useless: it arrived WITH
# the irreversible close. If the row moved, the fix did not happen.
[[ "$(statusof CIT-1)" == "in_progress" ]] \
  && ok_t '2. status is untouched — the close did not commit' \
  || bad_t '2. status must not move' "status=$(statusof CIT-1)"
[[ -z "$(resultof CIT-1)" ]] \
  && ok_t '2b. result is untouched — the record is still repairable' \
  || bad_t '2b. result must not be written' "result=$(resultof CIT-1)"
[[ "$(bodyof CIT-1)" == 'no binding here' ]] \
  && ok_t '2c. body is untouched — it did not freeze' \
  || bad_t '2c. body must not move' "body=$(bodyof CIT-1)"

# --- 3. a bound delivery_ref is UNCHANGED ------------------------------------
export GH_STUB_PR_5dive_api_209="$MERGED_OK"
seed CIT-3 'declared'
db "UPDATE tasks SET delivery_ref='https://github.com/lodar/5dive-api/pull/209',
                     delivered_at=datetime('now') WHERE ident='CIT-3';"
run_done CIT-3 --result='shipped, see PR #209 for the change'
[[ "$OUT" != *"$MARK"* ]] \
  && ok_t '3. a bound delivery_ref never reaches this refusal' \
  || bad_t '3. bound field must be unchanged' "out=$OUT"
[[ "$(statusof CIT-3)" == "done" ]] \
  && ok_t '3b. ...and the declared DIVE-1830 path still closes it' \
  || bad_t '3b. bound+merged+green must close' "status=$(statusof CIT-3) out=$OUT"

# --- 4. a `Branch:` line is UNCHANGED ----------------------------------------
# The other structured declaration (DIVE-1462). It routes to the declared path,
# where the delivery IS verified by ancestry — so refusing here would add friction
# to the fleet's dominant delegated-push flow and buy no safety. Asserted on the
# refusal's ABSENCE, not on the close: the ancestry scan has its own verdicts and
# this arm is not about them.
seed CIT-4 'Branch: dive-2096-cited-preclose

work landed, see PR #209'
run_done CIT-4 --result='landed'
[[ "$OUT" != *"$MARK"* ]] \
  && ok_t '4. a `Branch:` binding never reaches this refusal' \
  || bad_t '4. Branch: must be unchanged' "out=$OUT"

# --- 5. no PR token at all is UNCHANGED --------------------------------------
seed CIT-5 'a research task'
run_done CIT-5 --result='wrote the analysis; no code'
[[ $RC -eq 0 && "$(statusof CIT-5)" == "done" && "$OUT" != *"$MARK"* ]] \
  && ok_t '5. no PR token: closes clean, zero regression' \
  || bad_t '5. must close clean' "rc=$RC status=$(statusof CIT-5) out=$OUT"

# --- 6. --no-pr is the named opt-out, and it is AUDITED ----------------------
: >"$AUDIT_CALLS"
seed CIT-6 'a review close'
run_done CIT-6 --no-pr --result='reviewed PR #209 for olivia; nothing of mine to ship'
[[ $RC -eq 0 && "$(statusof CIT-6)" == "done" ]] \
  && ok_t '6. --no-pr closes the genuine reports-on case (DIVE-1965 category)' \
  || bad_t '6. --no-pr must close' "rc=$RC status=$(statusof CIT-6) out=$OUT"
[[ "$OUT" == *"--no-pr"*"REPORTED ON"* ]] \
  && ok_t '6b. the assertion is announced, not silently honoured' \
  || bad_t '6b. --no-pr must warn' "out=$OUT"
grep -q 'task.done-no-pr' "$AUDIT_CALLS" \
  && ok_t '6c. ...and it lands an audit row — an unrecorded claim is a bypass' \
  || bad_t '6c. --no-pr must be audited' "audit=$(cat "$AUDIT_CALLS")"

# --- 7. --force-merge-gate also overrides ------------------------------------
seed CIT-7 'forced'
run_done CIT-7 --force-merge-gate --result='shipped, see PR #209'
[[ "$OUT" != *"$MARK"* && "$(statusof CIT-7)" == "done" ]] \
  && ok_t '7. --force-merge-gate overrides it too (one escape, not two policies)' \
  || bad_t '7. force must override' "status=$(statusof CIT-7) out=$OUT"

# --- 8. NOTHING IS INFERRED — the DIVE-1962 line -----------------------------
# The cancelled ticket's whole failure was reading a prose number into the
# binding. Prose is the TRIGGER for the prompt; the operator supplies the SOURCE.
[[ -z "$(drefof CIT-6)" ]] \
  && ok_t '8. no delivery_ref was inferred from the prose ref (DIVE-1962 stays dead)' \
  || bad_t '8. must never infer a binding' "dref=$(drefof CIT-6)"
[[ -z "$(drefof CIT-7)" ]] \
  && ok_t '8b. ...on the forced path either' \
  || bad_t '8b. must never infer a binding' "dref=$(drefof CIT-7)"

# --- 9. a BODY-only citation triggers it too ---------------------------------
# The ask says "--result/body". A maker who put the PR in the body and closed with
# a bare `--result` is the same defect wearing a different hat.
seed CIT-9 'follow-up to PR #209'
run_done CIT-9 --result='done'
[[ $RC -ne 0 && "$OUT" == *"$MARK"* && "$(statusof CIT-9)" == "in_progress" ]] \
  && ok_t '9. a body-only citation refuses as well' \
  || bad_t '9. body must be read too' "rc=$RC status=$(statusof CIT-9) out=$OUT"

# --- 10. `task cancel` is untouched ------------------------------------------
# Abandoning a task is not closing one: there is no delivery to bind, and a gate
# that blocks the abandon path is how a bad row becomes immortal.
seed CIT-10 'abandoned'
OUT=$(cmd_task_cancel CIT-10 --result='superseded by PR #209' 2>&1); RC=$?
[[ "$(statusof CIT-10)" == "cancelled" && "$OUT" != *"$MARK"* ]] \
  && ok_t '10. cancel is unaffected' \
  || bad_t '10. cancel must not be gated' "status=$(statusof CIT-10) out=$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"

# --- MUTATION GRADING --------------------------------------------------------
# Everything above is an assertion about a REFUSAL and about absences of one.
# Both shapes pass trivially against a build where the check does nothing, so the
# arms are worth exactly what the mutants below say they are.
MPASS=0; MFAIL=0
if [[ -z "$MUTANT_CHILD" ]]; then
  mutate() { # <name> <sed-expr> <must-red-arm-hint>
    local name="$1" expr="$2" hint="$3" md out rc
    md="$TMP/mut-$name"; mkdir -p "$md"; cp -r "$REPO_ROOT/src/." "$md/"
    # DIVE-3278: `task` is src/task/*.sh now, so a mutant anchor may live in any
    # of them. sed the whole set and let the no-op check below catch a moved anchor.
    if ! sed -i "$expr" "$md/cmd_task.sh" "$md"/task/*.sh; then
      MFAIL=$((MFAIL+1)); printf 'FAIL - mutant %s: sed could not apply\n' "$name"; return
    fi
    if diff -qr "$REPO_ROOT/src/cmd_task.sh" "$md/cmd_task.sh" >/dev/null \
       && diff -qr "$REPO_ROOT/src/task" "$md/task" >/dev/null; then
      # A mutation that changed nothing greens for the wrong reason and would
      # read as "the mutant survived was not even built".
      MFAIL=$((MFAIL+1)); printf 'FAIL - mutant %s: the sed matched NOTHING — the anchor moved\n' "$name"; return
    fi
    out=$(MUT_SRC="$md" MUTANT_CHILD=1 bash "$REPO_ROOT/tests/$(basename "$0")" 2>&1); rc=$?
    if [[ $rc -ne 0 ]]; then
      MPASS=$((MPASS+1)); printf 'ok   - mutant %s reds the harness (%s)\n' "$name" "$hint"
    else
      MFAIL=$((MFAIL+1)); printf 'FAIL - mutant %s SURVIVED — the arms for %s assert nothing\n   %s\n' \
        "$name" "$hint" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
  }
  printf '\n--- mutation grading (community/wiki/grade-absence-assertions-by-mutation.md) ---\n'
  mutate precheck \
    's#if \[\[ -z "$_dref" \&\& -z "$_branch" \]\] \&\& _gate_text_names_a_ref "$result#if false \&\& _gate_text_names_a_ref "$result#' \
    'arms 1, 2, 9 — the pre-check itself'
  mutate optout \
    's#^      if \[\[ $no_pr -eq 1 \]\]; then$#      if false; then#' \
    'arm 6 — the --no-pr opt-out'
  printf '%d mutants killed, %d survived\n' "$MPASS" "$MFAIL"
fi
# THE VERDICT IS ONE STATEMENT ON THE LAST EXECUTABLE LINE, reachable in BOTH the
# parent and the MUTANT_CHILD re-exec. Stranding it in an if/else put the probe's
# injection point (the `else` arm) on a branch the parent never takes, while the
# parent's exit came from the other arm — so tests/meta/harness-verdict-probe.sh
# reported this file UNWIRED: an exit status that cannot fail CI. The child's own
# canary file then defeated the not-reached classification, so the miss surfaced
# as a flat accusation with a green 19/19 sitting next to it. MFAIL is initialised
# to 0 above the branch, so the child (which never mutates) reads 0.
[[ $FAIL -eq 0 && $MFAIL -eq 0 ]]
