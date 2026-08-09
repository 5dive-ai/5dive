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

# DIVE-2770: the merge gate gained a CREDENTIAL-FREE rail (an unauthenticated read
# of a public repo). Every no-token arm below was written when "no credential"
# meant "no rail", and with the anon rail live they would reach the real network
# and grade a LIVE PR instead of the fixture. Turn it off here: these harnesses
# grade the pre-2770 rails, and tests/task_merge_gate_anon_rail_unit.sh grades the
# new one. This is also what keeps `no root, no network` true of this file.
#
# IT MUST SIT AFTER lib/grading_tree.sh, AND THAT IS NOT A STYLE CHOICE: that file
# sources lib/env_isolation.sh, which CLEARS inherited FIVE_* knobs so a harness
# never grades the caller's environment. Set above it, this export is wiped and the
# harness silently reaches the network instead — measured, and it read as three
# unrelated assertion failures naming a live PR's real state.
export FIVE_GATE_NO_ANON=1
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
out=$(cmd_task_done DIVE-201 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
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
# `--no-graded-sha` for the DIVE-2940 isolation reason noted at the Tg block: this
# case grades the DIVE-1830 merge gate's ACCEPT arm and nothing else. Tb directly
# above is the evidence the two are ordered and not merely coexisting — it still
# refuses on the UNMERGED PR with the flag absent, so DIVE-1830 is reached first
# and DIVE-2940 only ever speaks about rows that already cleared it.
GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-07-23T10:00:00Z" \
  out=$(cmd_task_done DIVE-201 --no-graded-sha --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
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
out=$(cmd_task_done DIVE-210 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-210)" != "done" ]] \
  && ok_t "Tc2 done refused when the Branch: head has no merged PR (E_CONFLICT)" \
  || bad_t "Tc2 refused" "rc=$rc (want $E_CONFLICT) status=$(statusof DIVE-210) out=$out"
[[ "$out" == *"DIVE-1830"* && "$out" == *"feat/dive-210-thing"* ]] \
  && ok_t "Tc2 refusal cites DIVE-1830 + the branch name" \
  || bad_t "Tc2 message" "out=$out"

# --- Tc3: same Branch:-bound task, but gh now reports a merged PR for the head
#     → closes. ----------------------------------------------------------------
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-07-23T11:00:00Z"
out=$(cmd_task_done DIVE-210 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-210)" == "done" ]] \
  && ok_t "Tc3 done closes once the Branch: head has a merged PR" \
  || bad_t "Tc3 close" "rc=$rc status=$(statusof DIVE-210) out=$out"

# --- Td: regression — a task with NO delivery_ref closes on `task done` exactly
#     as before (gate does not fire; gh irrelevant). ----------------------------
# No verifier so done is a real close (verifier==assignee==main path: verifier '').
seed_task DIVE-202 main ''
GH_STUB_STATE="OPEN" GH_STUB_MERGED="" \
  out=$(cmd_task_done DIVE-202 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
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

# --- Te6: THE FENCE, re-graded for DIVE-2940. A bare 40-hex sha in prose is NOT
#     a graded-sha claim. A result routinely names shas it did not grade (a base,
#     a cited squash, a sha inside a quoted error). Scraping those would drive the
#     COMPARISON off a sha nobody graded, so only the LABELLED form may feed it.
#
#     WHAT CHANGED AND WHY THIS IS A SHARPER ASSERTION THAN THE OLD ONE: before
#     DIVE-2940 this row CLOSED, so the fence was graded by rc=0 — which is the
#     same rc a broken extractor that scraped $OTHER_SHA and got lucky would
#     produce. Now an unlabelled sha refuses, and the fence is graded by WHICH
#     refusal fires. `done-without-graded-sha` means the extractor correctly saw
#     NO claim; `done-graded-sha-not-the-merged-sha` would mean it scraped the
#     prose sha and compared it. Two distinct outcomes where there was one. -----
deliver_merged DIVE-264
export GH_STUB_HEAD_SHA="$HEAD_SHA" GH_STUB_MERGE_SHA="$MERGE_SHA"
out=$(cmd_task_done DIVE-264 --result="PASS. Rebased onto $OTHER_SHA before review." 2>&1); rc=$?
[[ "$out" != *"$OTHER_SHA"* && "$out" != *"not the merged sha"* && "$out" != *"merged head"* ]] \
  && ok_t "Te6 an UNLABELLED sha in prose is not a claim (it never reached the comparison)" \
  || bad_t "Te6 fence" "rc=$rc status=$(statusof DIVE-264) out=$out"

# --- Te7: DIVE-2940. PART 2 was a NUDGE and is now a PRE-CLOSE REFUSAL. The warn
#     it replaces printed AFTER the result row was written, so its only printed
#     remedy ("state the sha you graded") was advice for the next row, not an
#     action available on this one — missed three times by one seat (DIVE-2862,
#     DIVE-2891, DIVE-2867) for exactly that reason. The load-bearing assertion
#     is not the exit code, it is that NOTHING WAS WRITTEN: a refusal that still
#     closed the row would reproduce the original defect while looking fixed. ---
[[ $rc -ne 0 && "$(statusof DIVE-264)" != "done" ]] \
  && ok_t "Te7 a loop close with no stated sha is REFUSED and the row stays OPEN" \
  || bad_t "Te7 refusal" "rc=$rc status=$(statusof DIVE-264) out=$out"
[[ "$out" == *"DIVE-2940"* && "$out" == *"--no-graded-sha"* ]] \
  && ok_t "Te7 the refusal names its ticket and its declared escape" \
  || bad_t "Te7 refusal text" "out=$out"
# The remedy must be reachable FROM THE STATE THE GATE FIRES IN — the whole point
# of moving it before the write. A refusal that told the closer to --append-result
# would be the old post-hoc errand wearing a refusal's clothes.
[[ "$out" == *"NOTHING IS WRITTEN YET"* && "$out" != *"append-result"* ]] \
  && ok_t "Te7 the printed remedy is 're-run', reachable from the pre-close state" \
  || bad_t "Te7 remedy reachability" "out=$out"

# --- Te7b: THE ESCAPE. A row genuinely graded on something other than a sha (a
#     docs row, a decision) must still be closable, and the escape is DECLARED
#     and audited rather than silent. Without this arm the refusal is a wall. ---
out=$(cmd_task_done DIVE-264 --no-graded-sha --result="PASS. Docs-only; nothing sha-shaped to grade." 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-264)" == "done" ]] \
  && ok_t "Te7b --no-graded-sha closes the row the refusal blocked" \
  || bad_t "Te7b escape" "rc=$rc status=$(statusof DIVE-264) out=$out"
[[ "$out" == *"comparison did NOT run"* ]] \
  && ok_t "Te7b the escape still SAYS the comparison did not run (audited, not silent)" \
  || bad_t "Te7b escape warn" "out=$out"

# --- Te7c: SCOPE — the negative control, and the arm that keeps this from being
#     a blanket "every close needs a sha". DIVE-2940 fires only on the maker->
#     verifier + merged-PR intersection. A row with NO verifier has no verdict to
#     bind a sha to, so it must close untouched. Without this arm, a refusal that
#     had accidentally been hoisted above the loop predicate would pass every
#     assertion above and block every close in the fleet. -----------------------
seed_task DIVE-266 main ''
cmd_task_deliver DIVE-266 --pr="$PR" >/dev/null 2>&1
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-08-04T10:00:00Z"
export GH_STUB_HEAD_SHA="$HEAD_SHA" GH_STUB_MERGE_SHA="$MERGE_SHA"
out=$(cmd_task_done DIVE-266 --result="PASS. No verifier on this row." 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-266)" == "done" ]] \
  && ok_t "Te7c a row with NO verifier closes without a sha (refusal is scoped)" \
  || bad_t "Te7c scope" "rc=$rc status=$(statusof DIVE-266) out=$out"

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
# DIVE-2940 NOTE, and it is isolation rather than a concession: every close below
# is graded on the ITERATION binding, and none of them is graded on the graded-sha
# gate (Te6/Te7 above own that). Since DIVE-2940 a loop close with no stated sha
# refuses, so without `--no-graded-sha` these cases would all go red for a reason
# that has nothing to do with what they assert — and, worse, Tga/Tgc would go GREEN
# on the WRONG refusal, since a test that only checks rc!=0 cannot tell which gate
# spoke. The flag keeps one gate per case. Tga still refuses on the stale binding
# with the flag set, which is the proof the iteration check runs FIRST.
iterof()  { db "SELECT COALESCE(iteration,0) FROM tasks WHERE ident='$1';"; }
binditerof() { db "SELECT COALESCE(CAST(delivery_ref_iteration AS TEXT),'NULL') FROM tasks WHERE ident='$1';"; }
PR2="https://github.com/5dive-ai/5dive/pull/1000"

# The well-behaved delivery first: deliver stamps the binding's iteration in the
# SAME update that bumps the counter, so the two agree. If these ever disagree at
# this point the ordering hazard is live and every arm below is meaningless.
seed_task DIVE-270 main dev
cmd_task_deliver DIVE-270 --pr="$PR" >/dev/null 2>&1
[[ "$(iterof DIVE-270)" == "1" && "$(binditerof DIVE-270)" == "1" ]] \
  && ok_t "Tg0 ROUTING deliver stamps binding-iteration == iteration (no two-moment read)" \
  || bad_t "Tg0 stamp/bump agree" "iter=$(iterof DIVE-270) bind=$(binditerof DIVE-270)"

# ARM (a): the loop bounces and the maker re-delivers WITHOUT re-pointing the
# binding — `task done` from the maker routes to the verifier again and bumps the
# counter, leaving the binding behind at iteration 1. The close must REFUSE.
db "UPDATE tasks SET assignee='main', status='in_progress', handoff_rejected_at=datetime('now') WHERE ident='DIVE-270';"   # verifier rejected → back to maker
( actor_seam_as main; cmd_task_done DIVE-270 --result="fixed, re-delivering" ) >/dev/null 2>&1
[[ "$(iterof DIVE-270)" == "2" && "$(binditerof DIVE-270)" == "1" ]] \
  && ok_t "Tga re-delivery bumps the counter and leaves the binding at its old iteration" \
  || bad_t "Tga stale gap created" "iter=$(iterof DIVE-270) bind=$(binditerof DIVE-270)"
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-08-04T00:00:00Z"
out=$( actor_seam_as dev; cmd_task_done DIVE-270 --no-graded-sha --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1 ); rc=$?
[[ $rc -eq $E_CONFLICT ]] \
  && ok_t "Tga close on a STALE binding is REFUSED even though the PR is MERGED" \
  || bad_t "Tga refused rc" "rc=$rc (want $E_CONFLICT) out=$out"
[[ "$out" == *"DIVE-2682"* || "$out" == *"iteration"* ]] \
  && ok_t "Tga the refusal names the iteration mismatch, not the merge state" \
  || bad_t "Tga refusal message" "out=$out"
[[ "$(statusof DIVE-270)" != "done" ]] \
  && ok_t "Tga the task did NOT close" \
  || bad_t "Tga task closed anyway" "status=$(statusof DIVE-270)"

# ARM (b) — THE CONTROL, and the one that catches the ordering hazard. Same loop,
# but the maker RE-POINTS the binding with `task deliver --pr=<new>`. The stamp
# and the bump happen in one update, so they agree, and the close is ACCEPTED.
# Without this arm a fix that refuses unconditionally would pass arm (a) and look
# correct while blocking every legitimate close on the board.
seed_task DIVE-271 main dev
cmd_task_deliver DIVE-271 --pr="$PR" >/dev/null 2>&1
db "UPDATE tasks SET assignee='main', status='in_progress', handoff_rejected_at=datetime('now') WHERE ident='DIVE-271';"   # rejected → back to maker
( actor_seam_as main; cmd_task_deliver DIVE-271 --pr="$PR2" ) >/dev/null 2>&1
[[ "$(iterof DIVE-271)" == "2" && "$(binditerof DIVE-271)" == "2" ]] \
  && ok_t "Tgb re-pointing the binding stamps it at the NEW iteration (no false refuse)" \
  || bad_t "Tgb re-point stamp" "iter=$(iterof DIVE-271) bind=$(binditerof DIVE-271)"
out=$( actor_seam_as dev; cmd_task_done DIVE-271 --no-graded-sha --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-271)" == "done" ]] \
  && ok_t "Tgb close on a RE-POINTED binding is ACCEPTED and the task closes" \
  || bad_t "Tgb accepted" "rc=$rc status=$(statusof DIVE-271) out=$out"

# ARM (d) — THE REMEDY ARM, and it INHERITS arm (a)'s refused row rather than
# re-seeding one that resembles it. dev's reject (iteration 1) found that arm (b),
# though an honest control, re-seeds assignee='main' BEFORE re-pointing, which puts
# it on the ROUTING deliver arm. A real maker reading the refusal is not there: the
# gate fires on a VERIFIER's close, so at that instant assignee IS the verifier and
# `task deliver --pr=<new>` takes the NON-routing arm. That arm stamped nothing, so
# the remedy the refusal printed re-pointed the binding for real and then refused
# again, naming the CORRECT new PR as "recorded at loop iteration 1".
# A refusal that prints an instruction has made a testable claim about reachability.
# This arm runs that instruction VERBATIM, from the state the refusal left behind.
[[ "$(assigneeof DIVE-270)" == "dev" && "$(iterof DIVE-270)" == "2" && "$(binditerof DIVE-270)" == "1" ]] \
  && ok_t "Tgd inherits arm (a)'s refused row (assignee=verifier, iter=2, bind=1)" \
  || bad_t "Tgd wrong start state" "assignee=$(assigneeof DIVE-270) iter=$(iterof DIVE-270) bind=$(binditerof DIVE-270)"
( actor_seam_as main; cmd_task_deliver DIVE-270 --pr="$PR2" ) >/dev/null 2>&1
[[ "$(iterof DIVE-270)" == "2" && "$(binditerof DIVE-270)" == "2" ]] \
  && ok_t "Tgd the printed remedy stamps the binding at the CURRENT iteration, no bump" \
  || bad_t "Tgd remedy did not move the stamp" "iter=$(iterof DIVE-270) bind=$(binditerof DIVE-270)"
out=$( actor_seam_as dev; cmd_task_done DIVE-270 --no-graded-sha --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-270)" == "done" ]] \
  && ok_t "Tgd following the refusal's OWN remedy makes the close succeed" \
  || bad_t "Tgd remedy is inert — false refuse on a correctly-bound row" "rc=$rc status=$(statusof DIVE-270) out=$out"

# ARM (e) — THE SAME-PASS RE-DELIVERY, and it exists because the first version of
# this fix was UNGRADED. DIVE-2624 made the counter's bump CONDITIONAL ("re-delivery
# of the same pass, not rework": iteration moves only on a first delivery or after a
# reject). The stamp was still an unconditional +1, so a same-pass re-delivery left
# bind = iter+1 — a state the guard's predicate (bind < iter) can NEVER flag, i.e. it
# fails SILENTLY. Every other arm here bounces via handoff_rejected_at, which takes
# the +1 branch and makes the two forms identical, so mutating the CASE back to +1
# scored 41/0 and proved nothing. This arm is the one that reds it.
seed_task DIVE-273 main dev
cmd_task_deliver DIVE-273 --pr="$PR" >/dev/null 2>&1
# Re-deliver with NO reject in between: assignee back to the maker, handoff_rejected_at
# left NULL — the "same pass" state.
db "UPDATE tasks SET assignee='main', status='in_progress' WHERE ident='DIVE-273';"
( actor_seam_as main; cmd_task_deliver DIVE-273 --pr="$PR2" ) >/dev/null 2>&1
[[ "$(iterof DIVE-273)" == "$(binditerof DIVE-273)" ]] \
  && ok_t "Tge same-pass re-delivery keeps stamp == counter (no silent bind>iter)" \
  || bad_t "Tge stamp outran the counter" "iter=$(iterof DIVE-273) bind=$(binditerof DIVE-273)"
out=$( actor_seam_as dev; cmd_task_done DIVE-273 --no-graded-sha --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-273)" == "done" ]] \
  && ok_t "Tge and the close is ACCEPTED (bind>iter would have been unflaggable, not refused)" \
  || bad_t "Tge same-pass close" "rc=$rc status=$(statusof DIVE-273) out=$out"

# ARM (c): a row bound BEFORE this column existed has a NULL stamp. NULL is not
# stale — "I cannot judge" must never become a refusal, or the gate false-REDs
# every legacy row on the board the moment it ships.
seed_task DIVE-272 main dev
cmd_task_deliver DIVE-272 --pr="$PR" >/dev/null 2>&1
db "UPDATE tasks SET delivery_ref_iteration=NULL, iteration=7 WHERE ident='DIVE-272';"
out=$( actor_seam_as dev; cmd_task_done DIVE-272 --no-graded-sha --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-272)" == "done" ]] \
  && ok_t "Tgc a NULL binding-iteration (legacy row) is NOT treated as stale" \
  || bad_t "Tgc legacy row false-refused" "rc=$rc status=$(statusof DIVE-272) out=$out"
echo "-----"
printf 'task_deliver_merge_gate_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
