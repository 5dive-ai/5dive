#!/usr/bin/env bash
# DIVE-1830 isolated unit harness for `task deliver` + the opt-in merge-gate on
# `task done`. Design (main, option A): a maker records the delivering PR via
# `task deliver --pr=<url>` (which reuses the DIVE-477 verifier handoff), and a
# task that carries a delivery_ref cannot close via `task done` until that PR is
# MERGED to main. Tasks that never declared a delivery are untouched (opt-in →
# zero regression). Isolation matches the sibling gate harnesses: source src/
# libs into a throwaway STATE_DIR — the live shared tasks.db is NEVER touched;
# `gh` is STUBBED on PATH so the gate's merge check is fully controllable.
# Run: bash tests/task_deliver_merge_gate_unit.sh  (no root, no network).
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
TMP="$(mktemp -d /tmp/deliver-gate-unit.XXXXXX)"

# --- stub gh: emits state/mergedAt from env, keyed off the -q '.field' arg. -----
# DIVE-1935: stub sudo fail-closed. The token resolver's last resort is
# `sudo -n -u claude gh auth token`, and real sudo resets PATH to secure_path — so
# an unstubbed harness reaches the HOST's real gh login and asserts against a live
# credential the fleet does not have. No test here wants a real token.
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"
# DIVE-2114/DIVE-2066: PIN THE ACTOR. Tb/Tc call cmd_task_done with no actor, so
# task_actor() (src/lib/tasks_db.sh) falls through auto_sender_from_sudo — dead
# here because sudo is stubbed to exit 1 — and lands on the REAL $USER, stripped
# of an `agent-` prefix. The fixture hardcodes DIVE-201's verifier as `dev`, and
# DIVE-2007's writer-!=-grader rail refuses anyone else with a DIVE-477 message.
# Tb/Tc assert on the DIVE-1830 merge-gate text, so they read GREEN only on a box
# whose $USER strips to literally `dev` and RED everywhere else. That is the same
# env leak sudo/gh are already stubbed against three lines up — the harness's own
# greenness depended on who ran it, which makes it a regression detector for
# nobody. Measured before the pin: 9 passed / 2 failed as both `claude` and
# `agent-dev2`; the refusal named DIVE-477, not DIVE-1830.
# BOTH vars, and SUDO_USER is the one that actually bit: task_actor() consults
# auto_sender_from_sudo() FIRST, which reads $SUDO_USER (validation.sh:73) — so
# under any `sudo -u X bash tests/...` the invoking agent leaks in and wins
# before $USER is ever read. DIVE-2066 recorded this as a $USER leak; measured
# here it is SUDO_USER that dominates, which is why pinning $USER alone changed
# nothing (still 9/2, actor still resolved to 'main').
#
# DIVE-2601 — AND THEN THAT PIN WENT INERT TOO, which is the whole point of this
# row. DIVE-2518 sealed the `$USER`/`$SUDO_USER` path: it was never a test seam,
# it was THE FORGERY (any unprivileged caller could act as another agent through
# it), and `task_actor` no longer reads either var to decide WHO IS ACTING. So the
# two exports below stopped pinning anything and the actor fell back to the host
# again — 9/11 for dev2, and the same four-harness red that cost dev3 an hour on
# DIVE-1953. Two agents lost an hour each to this exact file, one after the other,
# because a pin that stops working does not fail: it goes quiet.
#
# The pin now goes through the SEALED seam (`tests/lib/actor_seam.sh`, DIVE-2518),
# below and AFTER the libraries are sourced — `_gate_caller_uid`/`_gate_passwd_stream`
# are functions, so sourcing lib/actor.sh after an override silently discards it.
# The old exports are kept ONLY because `auto_sender_from_sudo` still reads them
# for envelope PROVENANCE; they no longer decide the actor, and nothing below may
# rely on them for that.
SUDO_USER=agent-dev
USER=agent-dev
export SUDO_USER USER
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal stand-in for all three merge-gate calls:
#   gh pr view <url>  --json state,mergedAt              -q '.state' | -q '.mergedAt'
#   gh pr list --head <b> --state merged --json ...      -q '.[0].mergedAt'  (DIVE-1830 branch path)
#   gh pr list --state open --limit 200 --json ...       -q '[.[]|select(...)]...'  (DIVE-1835 auto-detect)
argv="$*"; q=""; state=""
# DIVE-2318: the DIVE-2120 attribution scan (`gh api repos/<slug>/commits?sha=main`)
# had no arm here at all, so it fell to the field-keyed default below, got an
# unparseable payload, and read as UNREACHABLE. That was invisible while every
# not-reached answer rendered as "not merged"; it is not invisible now, and Tc2's
# fixture INTENDS "no PR for this head", not "the scan never ran". Emit the raw TSV
# the gate's own -q expression would produce: <walked>\t<hits>. 1 walked with 0 hits
# is a page SHORTER than the one requested, i.e. main's history EXHAUSTED inside the
# window with nothing naming the ident — a MEASURED miss, which is what these arms
# are about. Anything else (compare/... for ancestry) stays unreachable, which is
# harmless: ancestry is diagnostic-only since DIVE-2120.
if [[ "$1" == "api" ]]; then
  case "$2" in
    */commits\?*) printf '%s\n' "${GH_STUB_COMMITS_TSV:-$'1\t0'}"; exit 0 ;;
    *) exit 1 ;;
  esac
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q) q="$2"; shift 2 ;;
    -q*) q="${1#-q}"; shift ;;
    --state) state="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
# DIVE-1835 auto-detect fires on `pr list --state open`; evaluate its client-side
# jq filter against the fixture (default [] => no match, so a plain no-binding
# close is NOT false-blocked). The DIVE-1830 branch path (`--state merged`) and
# `pr view` keep the field-keyed behaviour below.
if [[ "$argv" == *"pr list"* && "$state" == "open" ]]; then
  printf '%s' "${GH_STUB_PRLIST:-[]}" | jq -r "$q" 2>/dev/null
  exit 0
fi
# DIVE-2656: the head/merge sha probe. Keyed on the -q expression naming
# headRefOid so it cannot be confused with the state/mergedAt arms above.
if [[ "$q" == *headRefOid* ]]; then
  printf '%s|%s\n' "${GH_STUB_HEAD_SHA-}" "${GH_STUB_MERGE_SHA-}"
  exit 0
fi
case "$q" in
  .state)          printf '%s\n' "${GH_STUB_STATE:-}" ;;
  .mergedAt|.\[0\].mergedAt|'.[0].mergedAt') printf '%s\n' "${GH_STUB_MERGED:-}" ;;
  *)               printf '{"state":"%s","mergedAt":"%s"}\n' "${GH_STUB_STATE:-}" "${GH_STUB_MERGED:-}" ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# DIVE-2601: the actor pin, through the sealed seam and AFTER the sources above —
# `_gate_caller_uid` / `_gate_passwd_stream` are FUNCTIONS, so an override placed
# before `source lib/actor.sh` is redefined out of existence without a word.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh" \
  || { printf 'NOT OK - tests/lib/actor_seam.sh not reachable; the actor cannot be pinned\n'; exit 1; }
# ASSERT the pin through the real resolver before any arm leans on it. Without this
# line the file is exactly what it was for two years: green where the host happens
# to be `dev`, red everywhere else, and silent about which.
actor_seam_selftest dev \
  || { printf 'NOT OK - actor seam is inert: task_actor did not resolve to dev under the pin\n'; exit 1; }
actor_seam_as dev
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
# No DMs / root-owned audit log in this harness.
task_need_notify() { :; }
audit_log() { :; }

seed_task()  { db "INSERT INTO tasks (ident, title, status, created_by, assignee, verifier)
                     VALUES ('$1','t','in_progress','main','$2','$3');"; }
statusof()   { db "SELECT status FROM tasks WHERE ident='$1';"; }
assigneeof() { db "SELECT COALESCE(assignee,'') FROM tasks WHERE ident='$1';"; }
drefof()     { db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE ident='$1';"; }
delivof()    { db "SELECT CASE WHEN delivered_at IS NULL THEN 'no' ELSE 'yes' END FROM tasks WHERE ident='$1';"; }

PR="https://github.com/5dive-ai/5dive/pull/999"

# --- Ta: deliver on a task WITH a distinct verifier records the delivery and
#     routes to the verifier (status non-done, assignee flips to verifier). ------
seed_task DIVE-201 main dev
out=$(cmd_task_deliver DIVE-201 --pr="$PR" 2>&1); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "Ta deliver succeeds" \
  || bad_t "Ta deliver exit" "rc=$rc out=$out"
[[ "$(drefof DIVE-201)" == "$PR" && "$(delivof DIVE-201)" == "yes" ]] \
  && ok_t "Ta delivery_ref + delivered_at recorded" \
  || bad_t "Ta delivery recorded" "dref=$(drefof DIVE-201) delivered=$(delivof DIVE-201)"
[[ "$(assigneeof DIVE-201)" == "dev" && "$(statusof DIVE-201)" != "done" ]] \
  && ok_t "Ta routed to verifier (assignee=dev, status not done)" \
  || bad_t "Ta routed" "assignee=$(assigneeof DIVE-201) status=$(statusof DIVE-201)"

# --- Tb: a `task done` on a delivery_ref task whose PR is NOT merged is REFUSED
#     (non-zero, E_CONFLICT), and the task stays open. --------------------------
# DIVE-201 now sits with assignee==verifier (dev), so done reaches the merge-gate.
export GH_STUB_STATE="OPEN" GH_STUB_MERGED=""
out=$(cmd_task_done DIVE-201 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT ]] \
  && ok_t "Tb done on an unmerged delivery PR is REFUSED (E_CONFLICT)" \
  || bad_t "Tb refused rc" "rc=$rc (want $E_CONFLICT) out=$out"
[[ "$(statusof DIVE-201)" != "done" ]] \
  && ok_t "Tb the task did NOT close" \
  || bad_t "Tb not closed" "status=$(statusof DIVE-201)"
[[ "$out" == *"DIVE-1830"* ]] \
  && ok_t "Tb refusal cites the merge-gate (DIVE-1830)" \
  || bad_t "Tb message" "out=$out"

# --- Tc: same task, but gh now reports MERGED + a mergedAt → closes for real. ---
GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-07-23T10:00:00Z" \
  out=$(cmd_task_done DIVE-201 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-201)" == "done" ]] \
  && ok_t "Tc done on a MERGED delivery PR closes the task" \
  || bad_t "Tc close" "rc=$rc status=$(statusof DIVE-201) out=$out"

# --- Tc2: a task bound via the REAL `task set-branch` path (writes a `Branch:`
#     body line) and NO delivery_ref is REFUSED when gh reports no merged PR for
#     that head. Binding it through set-branch proves the gate covers the actual
#     delegated-push binding (DIVE-1462), not just a hand-written body line. -----
seed_task DIVE-210 main main
cmd_task_set_branch DIVE-210 feat/dive-210-thing >/dev/null 2>&1
[[ "$(db "SELECT body FROM tasks WHERE ident='DIVE-210';")" == *"feat/dive-210-thing"* ]] \
  || bad_t "Tc2 precond set-branch wrote the Branch: line" "body=$(db "SELECT body FROM tasks WHERE ident='DIVE-210';")"
[[ -z "$(drefof DIVE-210)" ]] || bad_t "Tc2 precond no delivery_ref" "dref=$(drefof DIVE-210)"
export GH_STUB_STATE="" GH_STUB_MERGED=""
out=$(cmd_task_done DIVE-210 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-210)" != "done" ]] \
  && ok_t "Tc2 done refused when the Branch: head has no merged PR (E_CONFLICT)" \
  || bad_t "Tc2 refused" "rc=$rc (want $E_CONFLICT) status=$(statusof DIVE-210) out=$out"
[[ "$out" == *"DIVE-1830"* && "$out" == *"feat/dive-210-thing"* ]] \
  && ok_t "Tc2 refusal cites DIVE-1830 + the branch name" \
  || bad_t "Tc2 message" "out=$out"

# --- Tc3: same Branch:-bound task, but gh now reports a merged PR for the head
#     → closes. ----------------------------------------------------------------
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-07-23T11:00:00Z"
out=$(cmd_task_done DIVE-210 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-210)" == "done" ]] \
  && ok_t "Tc3 done closes once the Branch: head has a merged PR" \
  || bad_t "Tc3 close" "rc=$rc status=$(statusof DIVE-210) out=$out"

# --- Td: regression — a task with NO delivery_ref closes on `task done` exactly
#     as before (gate does not fire; gh irrelevant). ----------------------------
# No verifier so done is a real close (verifier==assignee==main path: verifier '').
seed_task DIVE-202 main ''
GH_STUB_STATE="OPEN" GH_STUB_MERGED="" \
  out=$(cmd_task_done DIVE-202 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-202)" == "done" ]] \
  && ok_t "Td plain task (no delivery_ref) closes unchanged" \
  || bad_t "Td regression" "rc=$rc status=$(statusof DIVE-202) out=$out"

# --- Te/Tf (DIVE-2204): `deliver`'s no-distinct-verifier branch covers TWO
#     different rows and must not claim the stronger one for both. Te has a
#     verifier, just not distinct from the assignee (self-assigned rail from
#     community/wiki/deliver-branches-on-verifier-vs-assignee.md); Tf has none
#     at all. The old single message ("it has no distinct verifier") was true
#     for Tf but FALSE for Te, and reads as "unverified — safe to self-close".
# The prose only exists outside JSON_MODE (src/lib/output.sh ok(): JSON_MODE=1
# drops it entirely) — switch off for these two so the assertions see it.
JSON_MODE=0
seed_task DIVE-220 main main
out=$(cmd_task_deliver DIVE-220 --pr="$PR" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-220)" == "in_progress" ]] \
  && ok_t "Te deliver on verifier==assignee stays in_progress" \
  || bad_t "Te deliver exit/status" "rc=$rc status=$(statusof DIVE-220) out=$out"
[[ "$out" == *"verifier is the current assignee"* && "$out" != *"no distinct verifier"* && "$out" != *"no verifier is set"* ]] \
  && ok_t "Te message says verifier==assignee, not 'no verifier'" \
  || bad_t "Te message" "out=$out"

seed_task DIVE-221 main ''
out=$(cmd_task_deliver DIVE-221 --pr="$PR" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-221)" == "in_progress" ]] \
  && ok_t "Tf deliver with no verifier stays in_progress" \
  || bad_t "Tf deliver exit/status" "rc=$rc status=$(statusof DIVE-221) out=$out"
[[ "$out" == *"no verifier is set"* && "$out" != *"verifier is the current assignee"* ]] \
  && ok_t "Tf message says no verifier is set" \
  || bad_t "Tf message" "out=$out"

# === DIVE-2656: head-sha vs the sha the VERIFIER STATES it graded ==============
# Every arm below runs against a MERGED PR — i.e. a row that satisfies DIVE-1830,
# DIVE-1935 and every other predicate on this gate. That is the point: the shape
# this guards (PR #425 carrying a REJECTED commit while GitHub read CLEAN and 14
# checks green) is invisible to all of them.
HEAD_SHA="aa11bb22cc33dd44ee55ff6600112233445566aa"
MERGE_SHA="99887766554433221100ffeeddccbbaa99887766"
OTHER_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# deliver_merged <ident> — seed a maker->verifier loop row, bind a delivery PR,
# and put gh into "that PR is MERGED". Leaves the row assigned to the verifier
# (dev == the pinned actor) so `task done` is a REAL close and reaches the gate.
deliver_merged() {
  seed_task "$1" main dev
  cmd_task_deliver "$1" --pr="$PR" >/dev/null 2>&1
  export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-08-04T10:00:00Z"
}

# --- Te1: the stated graded sha IS the merged head → the row closes. -----------
# The ACCEPT arm, and it is the control for the whole block: a guard that only
# ever refuses passes every reject arm below trivially.
deliver_merged DIVE-260
export GH_STUB_HEAD_SHA="$HEAD_SHA" GH_STUB_MERGE_SHA="$MERGE_SHA"
out=$(cmd_task_done DIVE-260 --result="PASS. graded-sha: $HEAD_SHA" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-260)" == "done" ]] \
  && ok_t "Te1 graded-sha == merged head → closes (ACCEPT control)" \
  || bad_t "Te1 close" "rc=$rc status=$(statusof DIVE-260) out=$out"

# --- Te2: the stated graded sha is NEITHER the head NOR the merge commit → the
#     close is REFUSED even though the PR is MERGED. This is DIVE-2654's shape. -
deliver_merged DIVE-261
export GH_STUB_HEAD_SHA="$HEAD_SHA" GH_STUB_MERGE_SHA="$MERGE_SHA"
out=$(cmd_task_done DIVE-261 --result="PASS. graded-sha: $OTHER_SHA" 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT ]] \
  && ok_t "Te2 graded-sha != merged sha is REFUSED on a MERGED PR (E_CONFLICT)" \
  || bad_t "Te2 refused rc" "rc=$rc (want $E_CONFLICT) out=$out"
[[ "$(statusof DIVE-261)" != "done" ]] \
  && ok_t "Te2 the task did NOT close" \
  || bad_t "Te2 not closed" "status=$(statusof DIVE-261)"
[[ "$out" == *"DIVE-2656"* && "$out" == *"$OTHER_SHA"* && "$out" == *"$HEAD_SHA"* ]] \
  && ok_t "Te2 refusal cites DIVE-2656 and BOTH operands" \
  || bad_t "Te2 message" "out=$out"

# --- Te3: --force-merge-gate is the audited override on the same row. ----------
out=$(cmd_task_done DIVE-261 --force-merge-gate --result="PASS. graded-sha: $OTHER_SHA" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-261)" == "done" ]] \
  && ok_t "Te3 --force-merge-gate overrides the sha mismatch" \
  || bad_t "Te3 override" "rc=$rc status=$(statusof DIVE-261) out=$out"

# --- Te4: THE SQUASH CASE. A verifier that graded the LANDED result names the
#     MERGE COMMIT, not the branch head. Refusing that would false-RED every
#     squash-merged PR, which is worse than the false green this guard fixes. ---
deliver_merged DIVE-262
export GH_STUB_HEAD_SHA="$HEAD_SHA" GH_STUB_MERGE_SHA="$MERGE_SHA"
out=$(cmd_task_done DIVE-262 --result="PASS. graded-sha: $MERGE_SHA" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-262)" == "done" ]] \
  && ok_t "Te4 graded-sha == the MERGE COMMIT also closes (squash path)" \
  || bad_t "Te4 close" "rc=$rc status=$(statusof DIVE-262) out=$out"

# --- Te5: an ABBREVIATED stated sha matches by prefix. -------------------------
deliver_merged DIVE-263
export GH_STUB_HEAD_SHA="$HEAD_SHA" GH_STUB_MERGE_SHA="$MERGE_SHA"
out=$(cmd_task_done DIVE-263 --result="PASS. graded-sha: ${HEAD_SHA:0:9}" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-263)" == "done" ]] \
  && ok_t "Te5 an abbreviated graded-sha matches by prefix" \
  || bad_t "Te5 close" "rc=$rc status=$(statusof DIVE-263) out=$out"

# --- Te6: THE FENCE. A bare 40-hex sha in prose is NOT a graded-sha claim. A
#     result routinely names shas it did not grade (a base, a cited squash, a
#     sha inside a quoted error). Scraping those would manufacture refusals on
#     honest closes, so only the LABELLED form may drive the comparison. -------
deliver_merged DIVE-264
export GH_STUB_HEAD_SHA="$HEAD_SHA" GH_STUB_MERGE_SHA="$MERGE_SHA"
out=$(cmd_task_done DIVE-264 --result="PASS. Rebased onto $OTHER_SHA before review." 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-264)" == "done" ]] \
  && ok_t "Te6 an UNLABELLED sha in prose is not a claim → no refusal" \
  || bad_t "Te6 fence" "rc=$rc status=$(statusof DIVE-264) out=$out"

# --- Te7: PART 2's nudge. A loop row closed with NO stated sha still closes —
#     the enabling half costs nothing — but says the comparison did not run. ----
[[ "$out" == *"no \`graded-sha: <sha>\` in the result"* && "$out" == *"DIVE-2656"* ]] \
  && ok_t "Te7 a loop close with no stated sha is NUDGED (comparison did not run)" \
  || bad_t "Te7 nudge" "out=$out"

# --- Te8: the probe could not be reached → NOT CHECKED, not a mismatch. A query
#     that never ran must never render as a negative verdict (DIVE-2318's rule,
#     one level down). The close proceeds and says so out loud. ----------------
deliver_merged DIVE-265
export GH_STUB_HEAD_SHA="" GH_STUB_MERGE_SHA=""
out=$(cmd_task_done DIVE-265 --result="PASS. graded-sha: $OTHER_SHA" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-265)" == "done" ]] \
  && ok_t "Te8 an unreadable head/merge sha does NOT refuse" \
  || bad_t "Te8 unreached" "rc=$rc status=$(statusof DIVE-265) out=$out"
[[ "$out" == *"COULD NOT BE READ"* && "$out" == *"not checked"* ]] \
  && ok_t "Te8 it says NOT CHECKED rather than accepting silently" \
  || bad_t "Te8 message" "out=$out"

# --- Te9: the extractor itself, direct. Last labelled occurrence wins (an
#     --append-result close prepends the earlier text), separators are all
#     accepted, and prose without the label yields nothing. --------------------
[[ "$(_gate_graded_sha "graded-sha: ${HEAD_SHA^^}")" == "$HEAD_SHA" ]] \
  && ok_t "Te9a extractor lowercases an UPPERCASE sha" \
  || bad_t "Te9a" "got=$(_gate_graded_sha "graded-sha: ${HEAD_SHA^^}")"
[[ "$(_gate_graded_sha "graded-sha: $OTHER_SHA"$'\n'"--- appended ---"$'\n'"graded sha = $HEAD_SHA")" == "$HEAD_SHA" ]] \
  && ok_t "Te9b extractor takes the LAST labelled statement" \
  || bad_t "Te9b" "got=$(_gate_graded_sha "graded-sha: $OTHER_SHA"$'\n'"graded sha = $HEAD_SHA")"
[[ -z "$(_gate_graded_sha "merged $OTHER_SHA and shipped")" ]] \
  && ok_t "Te9c extractor ignores an unlabelled sha" \
  || bad_t "Te9c" "got=$(_gate_graded_sha "merged $OTHER_SHA and shipped")"
[[ -z "$(_gate_graded_sha "graded-sha: nothex")" ]] \
  && ok_t "Te9d extractor ignores a non-hex label value" \
  || bad_t "Te9d" "got=$(_gate_graded_sha "graded-sha: nothex")"
# --- Tg: DIVE-2682 — a binding that PREDATES the current loop iteration is stale,
#     and a close on it is refused. Graded by mutation, both arms, because a fix
#     that only ever refuses passes the refusing arm trivially. ------------------
iterof()  { db "SELECT COALESCE(iteration,0) FROM tasks WHERE ident='$1';"; }
binditerof() { db "SELECT COALESCE(CAST(delivery_ref_iteration AS TEXT),'NULL') FROM tasks WHERE ident='$1';"; }
PR2="https://github.com/5dive-ai/5dive/pull/1000"

# The well-behaved delivery first: deliver stamps the binding's iteration in the
# SAME update that bumps the counter, so the two agree. If these ever disagree at
# this point the ordering hazard is live and every arm below is meaningless.
seed_task DIVE-260 main dev
cmd_task_deliver DIVE-260 --pr="$PR" >/dev/null 2>&1
[[ "$(iterof DIVE-260)" == "1" && "$(binditerof DIVE-260)" == "1" ]] \
  && ok_t "Tg0 deliver stamps binding-iteration == iteration (no two-moment read)" \
  || bad_t "Tg0 stamp/bump agree" "iter=$(iterof DIVE-260) bind=$(binditerof DIVE-260)"

# ARM (a): the loop bounces and the maker re-delivers WITHOUT re-pointing the
# binding — `task done` from the maker routes to the verifier again and bumps the
# counter, leaving the binding behind at iteration 1. The close must REFUSE.
db "UPDATE tasks SET assignee='main', status='in_progress' WHERE ident='DIVE-260';"   # verifier rejected → back to maker
( actor_seam_as main; cmd_task_done DIVE-260 --result="fixed, re-delivering" ) >/dev/null 2>&1
[[ "$(iterof DIVE-260)" == "2" && "$(binditerof DIVE-260)" == "1" ]] \
  && ok_t "Tga re-delivery bumps the counter and leaves the binding at its old iteration" \
  || bad_t "Tga stale gap created" "iter=$(iterof DIVE-260) bind=$(binditerof DIVE-260)"
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-08-04T00:00:00Z"
out=$( actor_seam_as dev; cmd_task_done DIVE-260 2>&1 ); rc=$?
[[ $rc -eq $E_CONFLICT ]] \
  && ok_t "Tga close on a STALE binding is REFUSED even though the PR is MERGED" \
  || bad_t "Tga refused rc" "rc=$rc (want $E_CONFLICT) out=$out"
[[ "$out" == *"DIVE-2682"* || "$out" == *"iteration"* ]] \
  && ok_t "Tga the refusal names the iteration mismatch, not the merge state" \
  || bad_t "Tga refusal message" "out=$out"
[[ "$(statusof DIVE-260)" != "done" ]] \
  && ok_t "Tga the task did NOT close" \
  || bad_t "Tga task closed anyway" "status=$(statusof DIVE-260)"

# ARM (b) — THE CONTROL, and the one that catches the ordering hazard. Same loop,
# but the maker RE-POINTS the binding with `task deliver --pr=<new>`. The stamp
# and the bump happen in one update, so they agree, and the close is ACCEPTED.
# Without this arm a fix that refuses unconditionally would pass arm (a) and look
# correct while blocking every legitimate close on the board.
seed_task DIVE-261 main dev
cmd_task_deliver DIVE-261 --pr="$PR" >/dev/null 2>&1
db "UPDATE tasks SET assignee='main', status='in_progress' WHERE ident='DIVE-261';"   # rejected → back to maker
( actor_seam_as main; cmd_task_deliver DIVE-261 --pr="$PR2" ) >/dev/null 2>&1
[[ "$(iterof DIVE-261)" == "2" && "$(binditerof DIVE-261)" == "2" ]] \
  && ok_t "Tgb re-pointing the binding stamps it at the NEW iteration (no false refuse)" \
  || bad_t "Tgb re-point stamp" "iter=$(iterof DIVE-261) bind=$(binditerof DIVE-261)"
out=$( actor_seam_as dev; cmd_task_done DIVE-261 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-261)" == "done" ]] \
  && ok_t "Tgb close on a RE-POINTED binding is ACCEPTED and the task closes" \
  || bad_t "Tgb accepted" "rc=$rc status=$(statusof DIVE-261) out=$out"

# ARM (c): a row bound BEFORE this column existed has a NULL stamp. NULL is not
# stale — "I cannot judge" must never become a refusal, or the gate false-REDs
# every legacy row on the board the moment it ships.
seed_task DIVE-262 main dev
cmd_task_deliver DIVE-262 --pr="$PR" >/dev/null 2>&1
db "UPDATE tasks SET delivery_ref_iteration=NULL, iteration=7 WHERE ident='DIVE-262';"
out=$( actor_seam_as dev; cmd_task_done DIVE-262 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-262)" == "done" ]] \
  && ok_t "Tgc a NULL binding-iteration (legacy row) is NOT treated as stale" \
  || bad_t "Tgc legacy row false-refused" "rc=$rc status=$(statusof DIVE-262) out=$out"
echo "-----"
printf 'task_deliver_merge_gate_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
