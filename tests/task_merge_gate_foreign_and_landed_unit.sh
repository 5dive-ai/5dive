#!/usr/bin/env bash
# DIVE-3458: two shapes the merged-to-main gate could not express, and the negative
# controls that prove it did not simply get weaker.
#
# ARM 1 — EXTERNAL REPO. The gate refuses `task done` until the bound PR is merged.
# For a submission into a repo we do not own, merging is a third party's action and
# NO work we do can satisfy it: 6 rows were in that class on 2026-08-16, two already
# blocked. The row closes on the delivered URL, and the close must still RECORD what
# was submitted, where, its measured state, and whose decision the merge is —
# losing that sentence is how "we submitted it" becomes "we're listed there".
#
# ARM 2 — CLOSED-UNMERGED BINDING, WORK LANDED ANOTHER WAY. Measured on DIVE-3292:
# pull/629 CLOSED, merged=null, while fd945c2 is an ancestor of main. The gate read
# only the merge flag, so it could not tell "delivered by another route" from "never
# delivered", and printed a remedy that CANNOT BE PERFORMED — you cannot merge a
# closed PR whose content is already in main. `--force-merge-gate` does not reach
# that refusal either (main2's source read), so the row was unclosable from any seat.
#
# THE NEGATIVE CONTROLS ARE THE POINT. Both arms ADD an acceptance, so a harness
# that only proves the new closes work would be green against a gate that accepts
# everything. Asserted here: our own repo with an unmerged PR still REFUSES (A4), an
# ancestor with NO attribution still REFUSES (B2, the DIVE-2101 vacuity shape), and
# an UNREADABLE attribution still REFUSES rather than accepting on an outage (B4).
#
# DIVE-3534 corrected arm 2's ACCEPTOR: attribution alone closes; ancestry of the PR
# head is diagnostic. B1 modelled the landed commit AS the PR head, which is the one
# arrangement "landed by another route" cannot have — on the canonical row (DIVE-3292)
# head e2bad22 is NOT on main and fd945c2 is what landed, so the old conjunction
# refused the exact shape it was written for. B1b/B1c cover the real shape.
#
# MUTATION GRADE (both must go red):
#   * `_gate_foreign_delivery() { return 1; }`  -> A1/A2/A3 fail (foreign rows blocked again)
#   * `_gate_foreign_delivery() { return 0; }`  -> A4 fails (our own repo stops being gated)
#   * `_gate_branch_ident_on_main() { printf '1'; }` -> B2 fails (vacuous close accepted)
#   * re-add the ancestry conjunct to arm 2's accept -> B1b/B1c fail (DIVE-3534)
#   * drop the `_mg_foreign` result stamp      -> A1-record / B1-record fail (silent close)
#
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_foreign_and_landed_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# Must sit AFTER grading_tree.sh: it sources lib/env_isolation.sh, which clears
# inherited FIVE_* knobs, so an export above this line is wiped and the harness
# silently reaches the real network instead of the fixtures.
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-foreign-unit.XXXXXX)"

# --- stub gh. Surfaces used by the two arms:
#   `pr view <url> --json state,mergedAt`        -> GH_STUB_PR_<key(url)> as "STATE|MERGEDAT"
#   `pr view <url> --json headRefOid,mergeCommit`-> GH_STUB_SHAS_<key(url)> as "HEAD|MERGE"
#   `api repos/<slug>/compare/<base>...<head>`   -> GH_STUB_CMP_<repo>_<head> (JSON)
#   `api repos/<slug>/commits?sha=main`          -> GH_STUB_COMMITS_<repo>_main (JSON)
# No fixture => exit 1, i.e. the question could NOT be reached — a distinct state
# from a "no" answer, and A3/B4 depend on the difference.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0; fi
a=("$@"); expr='.'; i=0; json_fields=""
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -q|--jq)  expr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -q*)      expr="${a[$i]#-q}";    i=$((i+1)) ;;
    --json)   json_fields="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)        i=$((i+1)) ;;
  esac
done
key() { printf '%s' "${1//[^A-Za-z0-9]/_}"; }
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  ref="$3"
  case "$json_fields" in
    *headRefOid*)
      fx="GH_STUB_SHAS_$(key "$ref")"; v="${!fx:-}"
      [[ -n "$v" ]] || exit 1
      printf '{"headRefOid":"%s","mergeCommit":%s}' "${v%%|*}" \
        "$( [[ -n "${v##*|}" ]] && printf '{"oid":"%s"}' "${v##*|}" || printf 'null' )" \
        | jq -r "$expr"; exit 0 ;;
    *)
      fx="GH_STUB_PR_$(key "$ref")"; v="${!fx:-}"
      [[ -n "$v" ]] || exit 1
      printf '{"state":"%s","mergedAt":%s}' "${v%%|*}" \
        "$( [[ -n "${v##*|}" ]] && printf '"%s"' "${v##*|}" || printf 'null' )" \
        | jq -r "$expr"; exit 0 ;;
  esac
fi
if [[ "$1" == "api" ]]; then
  path="$2"
  slug=$(printf '%s' "$path" | cut -d/ -f2,3)
  slice='.'
  case "$path" in
    */commits\?*)
      br="${path##*sha=}"; br="${br%%&*}"
      fx="GH_STUB_COMMITS_$(key "${slug##*/}")_$(key "$br")"
      pp=30; case "$path" in *per_page=*) pp="${path##*per_page=}"; pp="${pp%%&*}" ;; esac
      [[ "$pp" =~ ^[0-9]+$ ]] || pp=30
      (( pp > 100 )) && pp=100      # GitHub's real clamp, modelled (DIVE-2120)
      pg=1; case "$path" in *"&page="*) pg="${path##*&page=}"; pg="${pg%%&*}" ;; esac
      [[ "$pg" =~ ^[0-9]+$ && "$pg" -gt 0 ]] || pg=1
      slice=".[$(( (pg-1)*pp )):$(( pg*pp ))]" ;;
    */compare/*)
      cmp="${path##*/compare/}"; head="${cmp##*...}"
      fx="GH_STUB_CMP_$(key "${slug##*/}")_$(key "$head")" ;;
    *) exit 1 ;;
  esac
  json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -c "$slice" 2>/dev/null | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
# Real sudo resets PATH to secure_path and would bypass the gh stub, so the token
# resolver must never reach the host's own login.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
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
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
_task_close_notify() { :; }
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
# Capture at _task_store_audit_log, NOT at audit_log. DIVE-2010 fences the store's
# audit rows whenever TASKS_DB is not the production store — which is every harness,
# by construction — so an assertion on audit_log here can only ever measure the
# fence. Recording the product's own seam grades the CALL, which is the claim.
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; return 0; }
export GH_STUB_AUTH_TOKEN="tok"
# One repo, pinned, so the OWNER set under test is exactly {5dive-ai} and the suite
# never follows a default change or the host's config.
export FIVE_GATE_REPOS="5dive-ai/5dive"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
seed() { db "DELETE FROM tasks WHERE ident='$1';
             INSERT INTO tasks (ident, title, body, status, created_by, assignee, delivery_ref)
               VALUES ('$1','t','','in_progress','main','main',$(sqlq "$2"));"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
resultof() { db "SELECT COALESCE(result,'') FROM tasks WHERE ident='$1';"; }
refusals() { db "SELECT COUNT(*) FROM policy_refusals WHERE ident='$1';"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
clear_fx() { unset "${!GH_STUB_PR_@}" "${!GH_STUB_SHAS_@}" "${!GH_STUB_CMP_@}" "${!GH_STUB_COMMITS_@}" 2>/dev/null; }
commits() { printf '[{"commit":{"message":"%s"}},{"commit":{"message":"chore: unrelated"}}]' "$1"; }
ANCESTOR='{"status":"behind","ahead_by":0,"behind_by":7}'
NOT_ANCESTOR='{"status":"diverged","ahead_by":3,"behind_by":9}'

FOREIGN_PR="https://github.com/kyrolabs/awesome-agents/pull/709"
OURS_PR="https://github.com/5dive-ai/5dive/pull/629"

# ── 0. the predicate itself, before any gate runs ──────────────────────────────
# Ownership must come from the ref's HOST+OWNER. A title-keyword test is what bound
# PR #649 to DIVE-3419 and cost two refused closes.
_gate_foreign_delivery "$FOREIGN_PR" \
  && ok_t 'predicate: a github PR under another owner is FOREIGN' \
  || bad_t 'predicate: kyrolabs must read as foreign'
! _gate_foreign_delivery "$OURS_PR" \
  && ok_t 'predicate: our own repo is NOT foreign' \
  || bad_t 'predicate: 5dive-ai must not read as foreign'
! _gate_foreign_delivery "https://github.com/5Dive-AI/5dive/pull/7" \
  && ok_t 'predicate: owner match is case-insensitive (5Dive-AI is still ours)' \
  || bad_t 'predicate: owner comparison must be case-insensitive'
_gate_foreign_delivery "git@github.com:alebcay/awesome-shell.git" \
  && ok_t 'predicate: an ssh remote parses too' \
  || bad_t 'predicate: ssh remote form must resolve an owner'
# FAIL CLOSED on anything it cannot read: the expensive mistake is exempting one of
# OUR deliveries, never gating a foreign one.
! _gate_foreign_delivery "https://gitlab.com/someone/thing/-/merge_requests/2" \
  && ok_t 'predicate: a non-github host is NOT foreign (fails closed)' \
  || bad_t 'non-github host must fail closed'
! _gate_foreign_delivery "" \
  && ok_t 'predicate: an empty ref is NOT foreign (fails closed)' \
  || bad_t 'empty ref must fail closed'
! _gate_foreign_delivery "https://github.com/notaslug" \
  && ok_t 'predicate: a URL with no owner/repo pair is NOT foreign (fails closed)' \
  || bad_t 'ownerless URL must fail closed'

# ── A1. foreign repo, PR OPEN -> CLOSES, and the record says so ────────────────
clear_fx; export GH_STUB_PR_https___github_com_kyrolabs_awesome_agents_pull_709="OPEN|"
seed FGN-1 "$FOREIGN_PR"
run_done FGN-1 --result='submitted to the list'
if [[ $RC -eq 0 && "$(statusof FGN-1)" == "done" && "$(refusals FGN-1)" == "0" ]]; then
  ok_t 'a submission into a repo we do not own CLOSES on the delivered URL'
else
  bad_t 'foreign+open must close' "rc=$RC status=$(statusof FGN-1) refusals=$(refusals FGN-1) out=$OUT"
fi
R=$(resultof FGN-1)
[[ "$R" == *"$FOREIGN_PR"* && "$R" == *"kyrolabs/awesome-agents"* ]] \
  && ok_t 'the RESULT records what was submitted and where' \
  || bad_t 'result must name the submission and the repo' "result=$R"
[[ "$R" == *"OPEN (not merged)"* ]] \
  && ok_t 'the result records the MEASURED state, not an assumption' \
  || bad_t 'result must carry the measured state' "result=$R"
[[ "$R" == *"kyrolabs's decision"* || "$R" == *"Merging is kyrolabs"* ]] \
  && ok_t 'the result names WHOSE decision the merge is' \
  || bad_t 'result must name the deciding owner' "result=$R"
[[ "$R" == *"asserts nothing about its acceptance"* ]] \
  && ok_t 'the result refuses to imply acceptance ("submitted" is not "listed there")' \
  || bad_t 'result must disclaim acceptance' "result=$R"
[[ "$R" == *"submitted to the list"* ]] \
  && ok_t "the maker's own result text is APPENDED to, never substituted" \
  || bad_t 'original result text must survive' "result=$R"
grep -q 'task.foreign-delivery' "$AUDIT_CALLS" \
  && ok_t 'the close is audited as a foreign delivery, not as an override' \
  || bad_t 'expected a task.foreign-delivery audit row' "$(cat "$AUDIT_CALLS")"
grep -q 'force-merge-gate' "$AUDIT_CALLS" \
  && bad_t 'a foreign close must NOT record as a bypassed safety check' \
  || ok_t 'and NOT as task.force-merge-gate — the audit trail says the right thing'

# ── A2. foreign repo, upstream ACCEPTED it -> closes, and says merged ──────────
clear_fx; export GH_STUB_PR_https___github_com_kyrolabs_awesome_agents_pull_709="MERGED|2026-08-16T09:00:00Z"
seed FGN-2 "$FOREIGN_PR"
run_done FGN-2 --result='submitted'
R=$(resultof FGN-2)
[[ $RC -eq 0 && "$(statusof FGN-2)" == "done" && "$R" == *"MERGED — kyrolabs accepted it"* ]] \
  && ok_t 'a foreign PR that DID merge closes and the record says accepted' \
  || bad_t 'foreign+merged must close and say so' "rc=$RC result=$R"

# ── A3. foreign repo, state unreadable -> closes, and says NOT READ ────────────
# "not checked" and "not merged" are different claims; only one of them is true here.
clear_fx    # no PR fixture at all => the query cannot be reached
seed FGN-3 "$FOREIGN_PR"
run_done FGN-3 --result='submitted'
R=$(resultof FGN-3)
[[ $RC -eq 0 && "$(statusof FGN-3)" == "done" ]] \
  && ok_t 'an unreadable foreign PR still closes (the row can never satisfy the gate)' \
  || bad_t 'foreign+unread must close' "rc=$RC status=$(statusof FGN-3) out=$OUT"
[[ "$R" == *"NOT READ"* && "$R" != *"OPEN (not merged)"* ]] \
  && ok_t "an unread state is recorded as NOT READ, never as 'not merged'" \
  || bad_t 'unread must not be rendered as a merge verdict' "result=$R"

# ── A4. NEGATIVE CONTROL: our own repo is still gated ──────────────────────────
clear_fx; export GH_STUB_PR_https___github_com_5dive_ai_5dive_pull_629="OPEN|"
export GH_STUB_SHAS_https___github_com_5dive_ai_5dive_pull_629="cafe1234|"
export GH_STUB_CMP_5dive_cafe1234="$NOT_ANCESTOR"
seed OWN-1 "$OURS_PR"
run_done OWN-1 --result='delivered'
if [[ $RC -ne 0 && "$(statusof OWN-1)" == "in_progress" && "$(refusals OWN-1)" == "1" ]]; then
  ok_t 'NEGATIVE CONTROL: an unmerged PR in OUR repo is still REFUSED'
else
  bad_t 'our own repo must stay gated' "rc=$RC status=$(statusof OWN-1) refusals=$(refusals OWN-1) out=$OUT"
fi
[[ "$(resultof OWN-1)" != *"DIVE-3458"* ]] \
  && ok_t 'and a refused close writes no foreign-delivery record' \
  || bad_t 'refused close must not stamp the result' "result=$(resultof OWN-1)"

# ── B1. our repo, PR CLOSED unmerged, work landed by another route -> CLOSES ───
clear_fx; export GH_STUB_PR_https___github_com_5dive_ai_5dive_pull_629="CLOSED|"
export GH_STUB_SHAS_https___github_com_5dive_ai_5dive_pull_629="fd945c2b99e4|"
export GH_STUB_CMP_5dive_fd945c2b99e4="$ANCESTOR"
export GH_STUB_COMMITS_5dive_main="$(commits 'docs(changelog): correct four stale release headings (LND-1)')"
seed LND-1 "$OURS_PR"
run_done LND-1 --result='landed as a direct commit'
if [[ $RC -eq 0 && "$(statusof LND-1)" == "done" && "$(refusals LND-1)" == "0" ]]; then
  ok_t 'a CLOSED-unmerged PR whose work is on main CLOSES on attribution'
else
  bad_t 'closed-but-landed must close' "rc=$RC status=$(statusof LND-1) refusals=$(refusals LND-1) out=$OUT"
fi
R=$(resultof LND-1)
[[ "$R" == *"ATTRIBUTION"* && "$R" == *"NOT on the pull request's merge flag"* ]] \
  && ok_t 'the record names WHICH evidence closed it, and which evidence did not' \
  || bad_t 'the close must say what accepted it' "result=$R"
grep -q 'task.landed-without-merge' "$AUDIT_CALLS" \
  && ok_t 'and it is audited under its own name' \
  || bad_t 'expected a task.landed-without-merge audit row' "$(cat "$AUDIT_CALLS")"

# ── B1b. DIVE-3534: THE REAL SHAPE — the PR head is NOT on main, and that is what
# "landed by another route" MEANS. B1 above modelled the landed commit AS the PR
# head, which is the one arrangement the canonical row cannot have: measured on
# DIVE-3292, head e2bad22 is not an ancestor of main and fd945c2 is what landed.
# The arm required BOTH ancestry-of-head and attribution, so it refused its own
# canonical row and left it unclosable from any seat.
#
# MUTATION GRADE for this case: re-add the ancestry conjunct
# (`[[ "$_cu_anc" == "1" && "$_cu_attr" == "1" ]]`) -> B1b fails.
clear_fx; export GH_STUB_PR_https___github_com_5dive_ai_5dive_pull_629="CLOSED|"
export GH_STUB_SHAS_https___github_com_5dive_ai_5dive_pull_629="e2bad22f6f62|"
export GH_STUB_CMP_5dive_e2bad22f6f62="$NOT_ANCESTOR"
export GH_STUB_COMMITS_5dive_main="$(commits 'docs(changelog): correct four stale release headings (LND-5)')"
seed LND-5 "$OURS_PR"
run_done LND-5 --result='landed as fd945c2, a different sha to the PR head'
if [[ $RC -eq 0 && "$(statusof LND-5)" == "done" && "$(refusals LND-5)" == "0" ]]; then
  ok_t 'DIVE-3534: an abandoned PR head NOT on main still closes when a commit on main names the ident'
else
  bad_t 'landed-by-another-route (different sha) must close' "rc=$RC status=$(statusof LND-5) refusals=$(refusals LND-5) out=$OUT"
fi
R=$(resultof LND-5)
[[ "$R" == *"ATTRIBUTION"* && "$R" != *"ancestry+attribution"* ]] \
  && ok_t 'and the record credits attribution alone, never an ancestry that did not hold' \
  || bad_t 'record must not claim ancestry for a head that is not on main' "result=$R"

# ── B1c. the branch is DELETED, so the head cannot be read at all — the routine
# state for a closed PR. Ancestry is diagnostic now, so an unreadable head must not
# be able to block an acceptance the attribution already earned.
clear_fx; export GH_STUB_PR_https___github_com_5dive_ai_5dive_pull_629="CLOSED|"
# no SHAS fixture => head unreadable; no CMP fixture => ancestry unreachable
export GH_STUB_COMMITS_5dive_main="$(commits 'fix(task): land it directly (LND-6)')"
seed LND-6 "$OURS_PR"
run_done LND-6 --result='branch deleted, work on main'
[[ $RC -eq 0 && "$(statusof LND-6)" == "done" ]] \
  && ok_t 'an unreadable PR head does not block a close the attribution earned' \
  || bad_t 'deleted-branch shape must close on attribution' "rc=$RC status=$(statusof LND-6) out=$OUT"

# ── B2. NEGATIVE CONTROL: ancestor but NOTHING on main names the ident ─────────
# DIVE-2101's vacuity shape: an EMPTY branch's tip IS on main, so ancestry alone
# would accept a row that delivered nothing.
clear_fx; export GH_STUB_PR_https___github_com_5dive_ai_5dive_pull_629="CLOSED|"
export GH_STUB_SHAS_https___github_com_5dive_ai_5dive_pull_629="beef0001|"
export GH_STUB_CMP_5dive_beef0001="$ANCESTOR"
export GH_STUB_COMMITS_5dive_main="$(commits 'chore: something else entirely')"
seed LND-2 "$OURS_PR"
run_done LND-2 --result='claiming it landed'
[[ $RC -ne 0 && "$(statusof LND-2)" == "in_progress" ]] \
  && ok_t 'NEGATIVE CONTROL: ancestry with NO attribution is REFUSED (vacuity, DIVE-2101)' \
  || bad_t 'vacuous ancestry must refuse' "rc=$RC status=$(statusof LND-2) out=$OUT"
[[ "$OUT" == *"NO commit subject on main names LND-2"* || "$OUT" == *"NO commit subject on main names"* ]] \
  && ok_t 'and the refusal names attribution as the missing operand' \
  || bad_t 'refusal must explain what was missing' "out=$OUT"

# ── B3. the CLOSED refusal must not print advice that cannot be performed ──────
clear_fx; export GH_STUB_PR_https___github_com_5dive_ai_5dive_pull_629="CLOSED|"
export GH_STUB_SHAS_https___github_com_5dive_ai_5dive_pull_629="dead0002|"
export GH_STUB_CMP_5dive_dead0002="$NOT_ANCESTOR"
seed LND-3 "$OURS_PR"
run_done LND-3 --result='not actually landed'
[[ $RC -ne 0 && "$(statusof LND-3)" == "in_progress" ]] \
  && ok_t 'a CLOSED PR whose work is NOT on main is still refused' \
  || bad_t 'closed+absent must refuse' "rc=$RC out=$OUT"
[[ "$OUT" != *"merge it, then task done"* ]] \
  && ok_t 'and the refusal does NOT tell the reader to merge a closed PR' \
  || bad_t 'impossible remedy printed for a CLOSED pr' "out=$OUT"
[[ "$OUT" == *"it is CLOSED, so it cannot be merged"* ]] \
  && ok_t 'it prints the remedies that actually exist for a closed binding' \
  || bad_t 'closed refusal must name a performable remedy' "out=$OUT"

# ── B4. NEGATIVE CONTROL: an outage must not manufacture an acceptance ─────────
# Attribution is the acceptor (DIVE-3534), so it is attribution's unreachability
# that must decline here — the compare probe is diagnostic and cannot accept.
clear_fx; export GH_STUB_PR_https___github_com_5dive_ai_5dive_pull_629="CLOSED|"
export GH_STUB_SHAS_https___github_com_5dive_ai_5dive_pull_629="c0ffee03|"
# no compare fixture => ancestry UNREACHABLE (empty), which is not "yes"
seed LND-4 "$OURS_PR"
run_done LND-4 --result='unknown'
[[ $RC -ne 0 && "$(statusof LND-4)" == "in_progress" ]] \
  && ok_t 'NEGATIVE CONTROL: unreachable attribution REFUSES (empty is not yes)' \
  || bad_t 'unreachable attribution must refuse' "rc=$RC out=$OUT"
[[ "$OUT" == *"COULD NOT BE READ"* ]] \
  && ok_t 'and the refusal says unresolved, not ruled out' \
  || bad_t 'refusal must distinguish unread from absent' "out=$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# Verdict shape is load-bearing: tests/meta/harness-verdict-probe.sh proves a
# harness is WIRED by injecting FAIL=$((FAIL+1)) and asserting the exit flips, and
# it recognises `exit $(( VAR > 0 ))`. A bare `if` is graded UNPROBEABLE, which is a
# red check (DIVE-3442).
exit $(( FAIL > 0 ))
