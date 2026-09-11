#!/usr/bin/env bash
# TIER: nightly — 60.9s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-1835 isolated unit harness for the MANDATORY auto-detect merge-gate.
# The DIVE-1830 gate only fired when the maker DECLARED a binding
# (delivery_ref / Branch:); 8 code-tasks closed with NEITHER and slipped past it.
# This gate auto-detects an OPEN unmerged PR whose TITLE or HEAD-BRANCH names the
# ident (never the body), is FAIL-OPEN (gh outage/timeout/absence never blocks a
# close), persists a concrete title/branch match as `delivery_ref`, and honours
# `task done --force-merge-gate` as an audited escape.
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_autodetect_unit.sh  (no root, no network).
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
TMP="$(mktemp -d /tmp/gate-autodetect-unit.XXXXXX)"

# --- stub gh: answers `pr list` from env-driven fixtures, records argv. --------
# DIVE-1935: stub sudo fail-closed. The token resolver's last resort is
# `sudo -n -u claude gh auth token`, and real sudo resets PATH to secure_path — so
# an unstubbed harness reaches the HOST's real gh login and asserts against a live
# credential the fleet does not have. No test here wants a real token.
mkdir -p "$TMP/bin"
# DIVE-4282 needs the OTHER seat shape too — no own gh login, but `sudo -u claude gh
# auth token` RESOLVES (arm 4). That is the shape every managed customer box has, and
# it is the one the 0-of-11 report came from. Default stays exit 1, so every arm
# written before this one keeps the seat it was written against.
cat >"$TMP/bin/sudo" <<'SUDOSTUB'
#!/usr/bin/env bash
[[ "${SUDO_STUB_MODE:-refused}" == "token" ]] || exit 1
[[ "$*" == *"-l "* ]] && exit 1          # the bot rail stays unavailable
printf '%s\n' "${SUDO_STUB_TOKEN:-claude-token}"
SUDOSTUB
chmod +x "$TMP/bin/sudo"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'TOKEN=%s ARGS=%s\n' "${GH_TOKEN:-}" "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; exit 0; fi
# DIVE-4282: a repo that DECLINES the listing, with gh's own words on stderr.
if [[ -n "${GH_STUB_FAIL:-}" ]]; then printf '%s\n' "$GH_STUB_FAIL" >&2; exit 1; fi
# `pr list ... --json ...`: emit the fixture JSON array, let the caller's -q jq run.
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  # honour a simulated hang so the gate's `timeout 5s` can be exercised.
  [[ -n "${GH_STUB_HANG:-}" ]] && sleep "$GH_STUB_HANG"
  # find the -q expression to evaluate against the fixture with real jq.
  expr='.'; while [[ $# -gt 0 ]]; do case "$1" in -q) expr="$2"; shift 2;; -q*) expr="${1#-q}"; shift;; *) shift;; esac; done
  printf '%s' "${GH_STUB_PRLIST:-[]}" | jq -r "$expr" 2>/dev/null
  exit 0
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
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
# DIVE-2054: "task.force-merge-gate" is now routed through _task_store_audit_log
# (STORE IDENTITY fence, DIVE-2010) — declare this fixture store as prod so the
# T7 audit-row assertion keeps exercising the real path.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
# capture audit calls instead of touching the real log.
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"

seed()     { db "INSERT INTO tasks (ident, title, status, created_by, assignee)
                   VALUES ('$1','t','in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- T1: an OPEN PR whose TITLE names the ident BLOCKS the no-binding close. ---
seed DIVE-901
export GH_STUB_PRLIST='[{"number":901,"headRefName":"feat/x","title":"DIVE-901 add thing"}]'
before=$( (JSON_MODE=0 cmd_task_show DIVE-901) 2>/dev/null )
[[ "$before" == *"delivery_ref = absent"* ]] \
  && ok_t "T1 DIVE-2316 precondition: task show reports the binding absent" \
  || bad_t "T1 precondition display" "$before"
out=$(cmd_task_done DIVE-901 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-901)" != "done" ]] \
  && ok_t "T1 open PR naming the ident in its TITLE blocks the close" \
  || bad_t "T1 title match blocks" "rc=$rc status=$(statusof DIVE-901) out=$out"
after=$( (JSON_MODE=0 cmd_task_show DIVE-901) 2>/dev/null )
[[ "$after" == *"delivery_ref = https://github.com/5dive-ai/5dive/pull/901"* \
   && "$(db "SELECT delivered_at IS NOT NULL AND delivery_ref_iteration=0 FROM tasks WHERE ident='DIVE-901';")" == "1" ]] \
  && ok_t "T1 DIVE-2316: title discovery persists the full PR binding, visible through task show" \
  || bad_t "T1 title discovery write" "show=$after row=$(db "SELECT delivery_ref,delivered_at,delivery_ref_iteration FROM tasks WHERE ident='DIVE-901';")"

# --- T2: an OPEN PR whose HEAD BRANCH names the ident BLOCKS (title doesn't). --
seed DIVE-902
export GH_STUB_PRLIST='[{"number":902,"headRefName":"feat/DIVE-902-fix","title":"unrelated title"}]'
out=$(cmd_task_done DIVE-902 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-902)" != "done" ]] \
  && ok_t "T2 open PR naming the ident in its HEAD BRANCH blocks the close" \
  || bad_t "T2 branch match blocks" "rc=$rc status=$(statusof DIVE-902) out=$out"
[[ "$(db "SELECT delivery_ref FROM tasks WHERE ident='DIVE-902';")" == "https://github.com/5dive-ai/5dive/pull/902" ]] \
  && ok_t "T2 DIVE-2316: head-branch discovery persists the full PR binding" \
  || bad_t "T2 branch discovery write" "ref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE ident='DIVE-902';")"

# --- T2b (word-boundary): a longer ident that merely PREFIX-shares does NOT
#     block. Open PRs name DIVE-2021 + DIVE-2029; closing DIVE-202 must proceed —
#     the ident is matched at word boundaries, not as a bare substring. ---------
seed DIVE-202
export GH_STUB_PRLIST='[{"number":2021,"headRefName":"feat/DIVE-2021","title":"DIVE-2021 thing"},{"number":2029,"headRefName":"feat/DIVE-2029-x","title":"DIVE-2029 other"}]'
out=$(cmd_task_done DIVE-202 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-202)" == "done" ]] \
  && ok_t "T2b DIVE-2021/2029 PRs do NOT false-block the shorter DIVE-202 close" \
  || bad_t "T2b substring false-block" "rc=$rc status=$(statusof DIVE-202) out=$out"

# --- T2c: the exact ident (adjacent to a non-alnum) STILL blocks even when a
#     prefix-sharing sibling PR is also open — boundary match, not over-loose. --
seed DIVE-203
export GH_STUB_PRLIST='[{"number":2031,"headRefName":"feat/DIVE-2031","title":"DIVE-2031 sibling"},{"number":203,"headRefName":"feat/x","title":"DIVE-203 real fix"}]'
out=$(cmd_task_done DIVE-203 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-203)" != "done" ]] \
  && ok_t "T2c exact ident 'DIVE-203 ...' blocks despite an open DIVE-2031 sibling" \
  || bad_t "T2c exact-ident still blocks" "rc=$rc status=$(statusof DIVE-203) out=$out"

# --- T2d: a lowercase branch naming the ident blocks (real branches are
#     lowercase; match is case-insensitive so the uppercase ident still hits). --
seed DIVE-204
export GH_STUB_PRLIST='[{"number":204,"headRefName":"dive-204-fix","title":"unrelated title"}]'
out=$(cmd_task_done DIVE-204 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-204)" != "done" ]] \
  && ok_t "T2d lowercase branch 'dive-204-fix' blocks the uppercase-ident close" \
  || bad_t "T2d case-insensitive branch match" "rc=$rc status=$(statusof DIVE-204) out=$out"

# --- T3: a PR that mentions the ident ONLY in its BODY does NOT block. ---------
#     (the fixture has no ident in title/headRefName -> client-side filter drops it)
seed DIVE-903
export GH_STUB_PRLIST='[{"number":903,"headRefName":"feat/other","title":"follow-up work"}]'
out=$(cmd_task_done DIVE-903 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-903)" == "done" ]] \
  && ok_t "T3 body-only mention (no title/branch match) closes normally" \
  || bad_t "T3 body-only does not block" "rc=$rc status=$(statusof DIVE-903) out=$out"

# --- T4: no matching PR at all -> a legitimate no-code close proceeds. ---------
seed DIVE-904
export GH_STUB_PRLIST='[]'
out=$(cmd_task_done DIVE-904 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-904)" == "done" ]] \
  && ok_t "T4 no matching PR => research/docs/no-code close proceeds" \
  || bad_t "T4 no-match closes" "rc=$rc status=$(statusof DIVE-904) out=$out"
[[ -z "$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE ident='DIVE-904';")" ]] \
  && ok_t "T4 DIVE-2316: no match writes no binding" \
  || bad_t "T4 no-match binding" "ref=$(db "SELECT delivery_ref FROM tasks WHERE ident='DIVE-904';")"

# --- T5 (FAIL-OPEN): a slow gh (past the 5s timeout) must NOT block the close. -
seed DIVE-905
export GH_STUB_PRLIST='[{"number":905,"headRefName":"feat/DIVE-905","title":"DIVE-905 thing"}]'
export GH_STUB_HANG=7   # > the gate's `timeout 5s` -> killed -> empty -> fail-open
out=$(cmd_task_done DIVE-905 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
unset GH_STUB_HANG
[[ $rc -eq 0 && "$(statusof DIVE-905)" == "done" ]] \
  && ok_t "T5 fail-open: a gh that hangs past the timeout does NOT block the fleet" \
  || bad_t "T5 fail-open on timeout" "rc=$rc status=$(statusof DIVE-905) out=$out"

# (gh-absent fail-open is the trivial `command -v gh` guard; not unit-tested here
#  because removing gh from PATH also removes sqlite3/date the close itself needs.)

# --- T7 (override): --force-merge-gate closes despite a blocking PR, AUDITED. --
seed DIVE-907
export GH_STUB_PRLIST='[{"number":907,"headRefName":"feat/DIVE-907","title":"DIVE-907 thing"}]'
: >"$AUDIT_CALLS"
out=$(cmd_task_done DIVE-907 --result="close under test (DIVE-2773: a first close must carry a reason)" --force-merge-gate 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-907)" == "done" ]] \
  && ok_t "T7 --force-merge-gate overrides a blocking PR and closes" \
  || bad_t "T7 override closes" "rc=$rc status=$(statusof DIVE-907) out=$out"
grep -q 'task.force-merge-gate.*DIVE-907.*override_pr=907' "$AUDIT_CALLS" \
  && ok_t "T7 the forced close is written to the audit log with the overridden PR #" \
  || bad_t "T7 override audited" "audit=$(cat "$AUDIT_CALLS")"

# --- T7b (DIVE-2062): OFF the prod store, the SAME override writes NO row ------
# T7 above only ever ran ON the prod store (FIVEDIVE_PROD_TASKS_DB was declared
# at the top of this file and never unset) — per the DIVE-2054 verifier pass
# (dev3, 2026-07-26) this suite reached the site but only ever on its ALLOWED
# side. This proves the WITHHELD side too, and that it is announced.
unset _TASK_STORE_AUDIT_FENCED
: >"$AUDIT_CALLS"
seed DIVE-909
export GH_STUB_PRLIST='[{"number":909,"headRefName":"feat/DIVE-909","title":"DIVE-909 thing"}]'
out=$(FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db" cmd_task_done DIVE-909 --result="close under test (DIVE-2773: a first close must carry a reason)" --force-merge-gate 2>"$TMP/offstore.err"); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-909)" == "done" ]] \
  && ok_t "T7b off-store: the override itself still closes (fail-open on the WRITE side)" \
  || bad_t "T7b override still closes" "rc=$rc status=$(statusof DIVE-909)"
[[ ! -s "$AUDIT_CALLS" ]] \
  && ok_t "T7b off the prod store, the forced-close override writes NO audit row" \
  || bad_t "T7b off-store must not audit" "$(cat "$AUDIT_CALLS")"
grep -q "telemetry withheld" "$TMP/offstore.err" \
  && ok_t "T7b the withholding is ANNOUNCED, not silent" \
  || bad_t "T7b fence must announce" "err=$(cat "$TMP/offstore.err")"
unset _TASK_STORE_AUDIT_FENCED

# --- T8: a DECLARED-binding task is handled by the DIVE-1830 path, NOT this one
#     (auto-detect must be skipped when a delivery_ref exists — no double gate). -
seed DIVE-908
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/908', delivered_at=datetime('now') WHERE ident='DIVE-908';"
export GH_STUB_PRLIST='[]'   # auto-detect would find nothing; DIVE-1830 gate must still run
export GH_STUB_STATE="" GH_STUB_MERGED=""
out=$(cmd_task_done DIVE-908 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-908)" != "done" ]] \
  && ok_t "T8 declared delivery_ref still gated by the DIVE-1830 (fail-closed) path" \
  || bad_t "T8 declared path intact" "rc=$rc status=$(statusof DIVE-908) out=$out"

# ── DIVE-4282: the scan's CREDENTIAL and the scan's FAILURE ────────────────────
# The customer report was "arm 4 RESOLVED and the scan still returned 0 of 11", and
# its suggested fix was "check whether the resolved token is handed to the scan, or
# resolved and then dropped". T10 is that check, standing: it asserts the arm-4 token
# reaches `gh` on every repo listing. MUTATION (run by hand, DIVE-4282): drop the
# `"$_ghtok2"` argument at the _gate_gh call site in src/task/status.sh and T10 goes
# red on the TOKEN= assertion while T11 stays green — the two arms are independent.
#
# The identity pin is load-bearing for the same reason the selftest harness carries
# one: arm 4 only fires for a non-`claude` caller, and without the pin this grades
# whoever runs it (DIVE-2484).
_gate_caller_uid()    { printf '%s' "${CALLER_UID_STUB:-990002}"; }
_gate_passwd_stream() {
  printf '%s\n' "$(</etc/passwd)"
  printf 'claude:x:990001:990001::/nonexistent:/bin/false\n'
  printf 'agent-fixture:x:990002:990002::/nonexistent:/bin/false\n'
}
[[ "$(actor_caller_unix_name)" == "agent-fixture" ]] \
  && ok_t "T10a the caller-identity pin lands (non-claude, so arm 4 is live)" \
  || bad_t "T10a identity pin" "name=[$(actor_caller_unix_name)]"

# The property is "whatever _gate_gh_token RESOLVED is what `gh` is invoked with",
# which is independent of WHICH arm resolved it — so it is graded on an arm that runs
# everywhere (arm 1), and then again on the customer's own arm 4 where the host allows
# it. tests/lib/env_isolation.sh replaces `sudo` with a refusing FUNCTION on any host
# whose PAM restores FIVE_* knobs from /etc/environment (DIVE-3096) — that neuters the
# sudo stub, so the arm-4 case SKIPS WITH ITS REASON PRINTED rather than passing
# vacuously. (Measured on this dev host 2026-09-11: the guard is installed, which is
# also why T2/T5 of tests/task_merge_gate_selftest_unit.sh are red here on origin/main.)
seed DIVE-910
export GH_STUB_PRLIST='[]'
export GH_STUB_AUTH_TOKEN=""
: >"$GH_ARGS_LOG"
out=$(GH_TOKEN="resolved-tok-4282" cmd_task_done DIVE-910 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
scanned=$(grep -c 'ARGS=pr list' "$GH_ARGS_LOG")
tokened=$(grep 'ARGS=pr list' "$GH_ARGS_LOG" | grep -c '^TOKEN=resolved-tok-4282 ')
{ [[ $rc -eq 0 && "$(statusof DIVE-910)" == "done" ]] && (( scanned > 0 )) && (( tokened == scanned )); } \
  && ok_t "T10 the RESOLVED token is handed to the scan — $tokened/$scanned repo listings carried it" \
  || bad_t "T10 resolved token reaches the scan" "rc=$rc scanned=$scanned tokened=$tokened log=$(head -3 "$GH_ARGS_LOG")"
[[ "$out" != *"UNVERIFIED"* ]] \
  && ok_t "T10 a scan that answered on every repo closes verified-clean (no UNVERIFIED warning)" \
  || bad_t "T10 clean close must not warn" "out=$out"

if [[ "$(type -t sudo)" == "function" ]]; then
  printf 'SKIP - T10b arm-4 hand-off: tests/lib/env_isolation.sh has replaced sudo with a refusing function on this host (DIVE-3096), so the arm-4 fixture cannot be built here. Runs on a host without the PAM knob restore.\n'
else
  seed DIVE-9101
  : >"$GH_ARGS_LOG"
  out=$(SUDO_STUB_MODE=token SUDO_USER="" cmd_task_done DIVE-9101 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
  scanned=$(grep -c 'ARGS=pr list' "$GH_ARGS_LOG")
  tokened=$(grep 'ARGS=pr list' "$GH_ARGS_LOG" | grep -c '^TOKEN=claude-token ')
  { [[ $rc -eq 0 ]] && (( scanned > 0 )) && (( tokened == scanned )) && [[ "$out" != *"UNVERIFIED"* ]]; } \
    && ok_t "T10b THE CUSTOMER SEAT: no own gh login, arm 4 (sudo -u claude) resolves — $tokened/$scanned listings carried that token and the close is verified-clean" \
    || bad_t "T10b arm-4 token reaches the scan" "rc=$rc scanned=$scanned tokened=$tokened out=$out"
fi

# T11: THE SENTENCE THE OPERATOR READS. A held rail plus a failing listing used to
# print "merge-gate could not query GitHub (partial-repo-scan-0-of-11)" — a statement
# about the credential, on a box whose credential read the org's issues by hand. The
# reason existed (gh wrote it to stderr) and died in the command substitution.
seed DIVE-911
: >"$GH_ARGS_LOG"
out=$(GH_TOKEN="resolved-tok-4282" \
      GH_STUB_FAIL="HTTP 403: API rate limit exceeded for user ID 4242 (https://api.github.com/repos/x)" \
      cmd_task_done DIVE-911 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-911)" == "done" ]] \
  && ok_t "T11 fail-open intact: a scan whose every listing fails still does not stall the close" \
  || bad_t "T11 fail-open on scan failure" "rc=$rc status=$(statusof DIVE-911)"
{ [[ "$out" == *"repo scan FAILED"* ]] && [[ "$out" == *"rate limit exceeded"* ]] \
  && [[ "$out" == *"partial-repo-scan-0-of-"* ]]; } \
  && ok_t "T11 the warning NAMES what the scan failed on, not 'could not query GitHub'" \
  || bad_t "T11 warning names the scan failure" "out=$out"
[[ "$out" != *"could not query GitHub"* ]] \
  && ok_t "T11 the credential wording is GONE from a close whose credential resolved" \
  || bad_t "T11 credential wording must not appear" "out=$out"

# T12: POSITIVE CONTROL for T11's wording swap — a seat with NO rail at all still
# gets the original credential sentence. That case is the one it is true of, and a
# fix that relabelled it too would have destroyed the distinction it exists to make.
seed DIVE-912
unset GH_STUB_FAIL
out=$(SUDO_STUB_MODE=refused SUDO_USER="" GH_STUB_AUTH_TOKEN="" \
      cmd_task_done DIVE-912 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
{ [[ $rc -eq 0 ]] && [[ "$out" == *"could not query GitHub"* ]] && [[ "$out" == *"no-gh-token"* ]]; } \
  && ok_t "T12 control: a seat holding NO rail still reads 'could not query GitHub (no-gh-token)'" \
  || bad_t "T12 no-rail wording preserved" "rc=$rc out=$out"
export GH_STUB_AUTH_TOKEN="tok"

echo "-----"
printf 'task_merge_gate_autodetect_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
