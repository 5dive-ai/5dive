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
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/deliver-gate-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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
[[ "$out" == *"not merged to main"* ]] \
  && ok_t "Tb refusal names the merge gate's criterion" \
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
[[ "$out" == *"landed"* && "$out" == *"feat/dive-210-thing"* ]] \
  && ok_t "Tc2 refusal names the criterion + the branch name" \
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

echo "-----"
printf 'task_deliver_merge_gate_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
