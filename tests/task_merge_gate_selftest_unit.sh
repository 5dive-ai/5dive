#!/usr/bin/env bash
# DIVE-1935 (iteration 2) — the merge-gate's INSTRUMENT CHECK.
#
# WHAT THIS GRADES, and why it is not another resolver test. Iteration 1 added a
# `sudo -n -u claude gh auth token` arm justified by "agents hold passwordless sudo
# on this host" — a per-SEAT grant written as a host property, false for the
# cli-scoped seats, and UNFALSIFIABLE FROM THE CODE: `sudo -n` cannot prompt, its
# refusal is silent, `|| true` swallows it, and an empty token is a legitimate
# state. So the seat where the gate is inert looks exactly like the seat where it
# works. This file grades the two properties that fix that:
#
#   (1) every resolution arm leaves a CRUMB naming its own outcome, and a REFUSED
#       sudo is distinguishable from a PERMITTED sudo that found no login — they
#       have different remedies and were previously the same silence;
#   (2) `task merge-gate-selftest` grades the rail against a control PR whose
#       answer is known, so "a credential resolved" cannot be mistaken for "this
#       seat can get a true answer out of GitHub".
#
# T5/T6 are the positive controls for T4: a self-test that cannot come out the
# other way measures nothing, which is the same defect the ticket is about.
# Run: bash tests/task_merge_gate_selftest_unit.sh  (no root, no network).
set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# The anon rail would otherwise reach the REAL network and grade a live PR instead
# of the fixture (and it must sit AFTER grading_tree.sh, which clears inherited
# FIVE_* knobs — see the sibling harnesses for the measurement).
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-selftest-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# --- stub sudo: SUDO_STUB_MODE constructs the seat each case needs. ------------
#   refused  -> the cli-scoped seat: sudo declines, on stderr, exactly as real
#               sudo does ("a password is required"). This is the string the
#               classifier reads, so the fixture must carry it verbatim.
#   nologin  -> sudo is permitted but `claude` has no gh login: silent, empty.
#   token    -> resolves.
# Also gates `-n -l` (the `_gh_do` bot-rail probe) so a case can hold a rail or
# hold none without touching the real host's sudoers.
cat >"$TMP/bin/sudo" <<'SUDOSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_CALLS"
if [[ "$*" == *"-l "* ]]; then
  [[ "${SUDO_STUB_BOT:-0}" == "1" ]] && exit 0
  exit 1
fi
case "${SUDO_STUB_MODE:-refused}" in
  token)   printf '%s\n' "${SUDO_STUB_TOKEN:-claude-token}"; exit 0 ;;
  nologin) exit 1 ;;
  *)       printf 'sudo: a password is required\n' >&2; exit 1 ;;
esac
SUDOSTUB
chmod +x "$TMP/bin/sudo"
export SUDO_CALLS="$TMP/sudo.calls"; : >"$SUDO_CALLS"

# --- stub gh: answers `auth token` and `pr view ... -q .state`. ---------------
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'TOKEN=%s ARGS=%s\n' "${GH_TOKEN:-}" "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; exit 0
fi
[[ -n "${GH_STUB_STATE:-}" ]] || exit 1
printf '%s\n' "$GH_STUB_STATE"
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# --- pin the caller identity: the arm-4 branch only fires for a NON-`claude`
# caller, and without a pin the harness grades whoever runs it (DIVE-2484's
# measurement — red under this repo's `sudo -u claude` local convention, green on a
# CI runner with no `claude` account).
#
# DIVE-2538 item 5 sealed that predicate onto `actor_caller_unix_name` ($EUID
# through a pure-bash passwd walk), so the PATH shim this file used to carry became
# INERT rather than red — the silent class tests/identity_stub_guard_unit.sh exists
# to catch. Pin the seams the derivation actually reads instead; they are functions,
# so only something already inside this shell can set them. Applied after the
# sources below, which would otherwise overwrite them.
_pin_identity_seams() {
  _gate_caller_uid()    { printf '%s' "${CALLER_UID_STUB:-990002}"; }
  _gate_passwd_stream() {
    printf '%s\n' "$(</etc/passwd)"
    printf 'claude:x:990001:990001::/nonexistent:/bin/false\n'
    printf 'agent-fixture:x:990002:990002::/nonexistent:/bin/false\n'
  }
}

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
_pin_identity_seams
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init
audit_log() { :; }

# T0: the pin, asserted THROUGH the real resolver before anything leans on it. A
# pin that yields '' or the host's own name makes every arm-4 assertion below read
# correct for the wrong reason.
{ [[ "$(actor_caller_unix_name)" == "agent-fixture" ]] && [[ "$(_gate_uid_to_agent "$(_gate_caller_uid)")" == "fixture" ]]; } \
  && ok_t "T0 the caller-identity pin lands through the real resolver (non-claude, so arm 4 is live)" \
  || bad_t "T0 identity pin" "name=[$(actor_caller_unix_name)] agent=[$(_gate_uid_to_agent "$(_gate_caller_uid)")]"

CTRL="https://github.com/5dive-ai/5dive/pull/163"

# --- T1: an env token resolves and SAYS SO. -----------------------------------
JSON_MODE=0
got=$(GH_TOKEN="env-tok-1" _gate_gh_token)
why=$(_gate_tok_why)
{ [[ "$got" == "env-tok-1" ]] && [[ "$why" == *"[1 env"*"RESOLVED"* ]]; } \
  && ok_t "T1 the env arm resolves and the trace names it" \
  || bad_t "T1 env arm trace" "got=[$got] why=[$why]"

# --- T2: THE DISTINCTION THE TICKET IS ABOUT — a REFUSED sudo is not an empty
#     one. Before this, both arms printed nothing and an inert seat could not be
#     told from an unlucky one. -----------------------------------------------
unset GH_TOKEN GITHUB_TOKEN
export GH_STUB_AUTH_TOKEN=""
got=$(SUDO_USER="" SUDO_STUB_MODE=refused _gate_gh_token)
why=$(_gate_tok_why)
{ [[ -z "$got" ]] && [[ "$why" == *"[4 sudo -u claude gh auth token] REFUSED by sudoers"* ]]; } \
  && ok_t "T2 a cli-scoped seat's REFUSED sudo is named as a refusal, not as an absence" \
  || bad_t "T2 refused arm" "got=[$got] why=[$why]"

got=$(SUDO_USER="" SUDO_STUB_MODE=nologin _gate_gh_token)
why2=$(_gate_tok_why)
{ [[ -z "$got" ]] && [[ "$why2" == *"[4 sudo -u claude gh auth token] empty (sudo permitted"* ]]; } \
  && ok_t "T2b a PERMITTED sudo that finds no login is named differently (different remedy)" \
  || bad_t "T2b permitted-but-no-login arm" "got=[$got] why=[$why2]"

# --- T3: the trace names the SEAT. The whole defect was a per-seat fact read as
#     a host-wide one, so a diagnostic without the seat reproduces it. ---------
[[ "$why" == "seat "*"@"*"uid="*": "* ]] \
  && ok_t "T3 the trace names the seat it was taken on" \
  || bad_t "T3 seat in trace" "why=[$why]"

# --- T4: the self-test PASSES when the control PR reads MERGED. ---------------
JSON_MODE=1
out=$(GH_TOKEN="tok" GH_STUB_STATE="MERGED" cmd_task_merge_gate_selftest --pr="$CTRL" 2>&1); rc=$?
{ [[ $rc -eq 0 ]] && [[ "$out" == *'"verdict":"ok"'* ]] && [[ "$out" == *'"state":"MERGED"'* ]]; } \
  && ok_t "T4 a seat that can query GitHub passes, and reports the control's state" \
  || bad_t "T4 passing seat" "rc=$rc out=$out"

# --- T5: POSITIVE CONTROL for T4 — a seat with NO rail FAILS, non-zero. -------
out=$(GH_TOKEN="" GITHUB_TOKEN="" SUDO_USER="" SUDO_STUB_MODE=refused SUDO_STUB_BOT=0 \
      GH_STUB_STATE="" GH_STUB_AUTH_TOKEN="" cmd_task_merge_gate_selftest --pr="$CTRL" 2>&1); rc=$?
{ [[ $rc -ne 0 ]] && [[ "$out" == *'"verdict":"blind"'* ]] \
  && [[ "$out" == *"REFUSED by sudoers"* ]]; } \
  && ok_t "T5 a blind seat FAILS non-zero and the payload names the arm that stopped it" \
  || bad_t "T5 blind seat" "rc=$rc out=$out"

# --- T6: POSITIVE CONTROL for the GRADE — a rail that answers, but answers
#     something other than MERGED about a known-merged control, must not pass.
#     "A credential resolved" was never the property the gate needs. ----------
out=$(GH_TOKEN="tok" GH_STUB_STATE="OPEN" cmd_task_merge_gate_selftest --pr="$CTRL" 2>&1); rc=$?
{ [[ $rc -ne 0 ]] && [[ "$out" == *'"verdict":"wrong"'* ]]; } \
  && ok_t "T6 a rail whose answer about the control is wrong FAILS (grade, not mere reachability)" \
  || bad_t "T6 wrong answer" "rc=$rc out=$out"

# --- T7: the verb refuses a non-PR --pr rather than grading against nothing. --
out=$(cmd_task_merge_gate_selftest --pr="https://example.com/x" 2>&1); rc=$?
[[ $rc -ne 0 ]] \
  && ok_t "T7 --pr must be a pull-request URL" \
  || bad_t "T7 --pr validation" "rc=$rc out=$out"

# --- T8/T9: THE ADVICE THE REFUSAL HANDS OUT MUST ALSO BE TRUE. -------------
# These are TEXT assertions on the emitted string, and deliberately so: the exit the
# `done-merge-gate-no-credential` refusal prints is a shell script the CALLER runs, so
# its correctness cannot be executed from here — only read. It shipped wrong in
# v0.19.20 (quinn, 2026-08-11): clause 1 was `git ls-remote <url> refs/heads/main |
# grep -q <merge-sha>`, which resolves ONE ref to its CURRENT value and therefore only
# matches while the merge sha is still the TIP of main. Main takes 20+ commits a day,
# so the gate's own authorised exit worked for about one commit and reported NOT MERGED
# for merged PRs outside that window — failing closed, on the rows it exists to rescue.
# Comment lines are excluded because the defect is documented in one, on purpose.
CODE_NOCOMMENT="$TMP/cmd_task.nocomment"
grep -vh '^[[:space:]]*#' "$SRC/cmd_task.sh" "$SRC"/task/*.sh >"$CODE_NOCOMMENT"

grep -q -- 'merge-base --is-ancestor <merge-sha> origin/main' "$CODE_NOCOMMENT" \
  && ok_t "T8 the documented exit tests ANCESTRY (reachable from main whenever it landed)" \
  || bad_t "T8 ancestry form in the refusal" "not found in emitted (non-comment) source"

grep -q -- 'ls-remote <repo-url> refs/heads/main' "$CODE_NOCOMMENT" \
  && bad_t "T9 the refusal must not hand out a tip-equality test" \
          "the ls-remote|grep -q form is still emitted" \
  || ok_t "T9 the tip-equality form is gone from the emitted refusal (kept only in a comment)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
