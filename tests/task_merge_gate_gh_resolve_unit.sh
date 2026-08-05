#!/usr/bin/env bash
# DIVE-1834 isolated unit harness for the merge-gate's gh resolution. The
# DIVE-1830 gate ran gh in the caller env with no --repo, so it false-BLOCKED a
# legitimately-merged close in two ways: (1) the Branch:-path `gh pr list` had no
# --repo and errored from a non-repo CWD; (2) both paths inherited whatever gh
# auth the caller had, so a sudo/root or non-authed-agent `task done` got
# state=unknown. This proves the fix: the branch path passes --repo and both
# paths propagate a resolved token, while the fail-SAFE direction (unknown =>
# BLOCK, never false-close) is preserved.
# Isolation matches the sibling gate harnesses: source src/ libs into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_gh_resolve_unit.sh  (no root, no network).
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
TMP="$(mktemp -d /tmp/gate-gh-resolve-unit.XXXXXX)"

# --- stub sudo (DIVE-1935): the resolver's last resort is
# `sudo -n -u claude gh auth token`, and real sudo resets PATH to secure_path — so
# without this stub the empty-token cases below reached the HOST's real gh login,
# printed a LIVE oauth token into this suite's argv log, and asserted against a
# credential the fleet doesn't have. Always fails: no test here wants a real one.
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"

# --- stub gh: records argv + the inherited GH_TOKEN per call, answers auth/pr. --
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Log the full invocation and the GH_TOKEN it inherited so the test can assert
# the gate passed --repo and propagated a resolved token.
printf 'TOKEN=%s ARGS=%s\n' "${GH_TOKEN:-}" "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; exit 0
fi
q=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q) q="$2"; shift 2 ;;
    -q*) q="${1#-q}"; shift ;;
    *)  shift ;;
  esac
done
case "$q" in
  .state)          printf '%s\n' "${GH_STUB_STATE:-}" ;;
  .mergedAt|'.[0].mergedAt') printf '%s\n' "${GH_STUB_MERGED:-}" ;;
  *)               printf '{"state":"%s","mergedAt":"%s"}\n' "${GH_STUB_STATE:-}" "${GH_STUB_MERGED:-}" ;;
esac
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
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }

seed_task()  { db "INSERT INTO tasks (ident, title, status, created_by, assignee, verifier)
                     VALUES ('$1','t','in_progress','main','$2','$3');"; }
statusof()   { db "SELECT status FROM tasks WHERE ident='$1';"; }

# --- T1: _gate_gh_token returns an explicit env token verbatim. ---------------
GH_TOKEN="env-tok-123" got=$(_gate_gh_token)
[[ "$got" == "env-tok-123" ]] \
  && ok_t "T1 _gate_gh_token honors an explicit env token" \
  || bad_t "T1 env token" "got=$got"

# --- T2: with no env token, it falls through to \`gh auth token\` (stubbed).
#     (export, not an inline prefix: an all-assignment line does not export the
#     var to the stub child, so the token must be in the environment proper.) ---
unset GH_TOKEN GITHUB_TOKEN
export GH_STUB_AUTH_TOKEN="resolved-tok-456"
got=$(SUDO_USER="" _gate_gh_token)
[[ "$got" == "resolved-tok-456" ]] \
  && ok_t "T2 _gate_gh_token falls back to a resolved gh auth token" \
  || bad_t "T2 resolved token" "got=$got"
unset GH_STUB_AUTH_TOKEN

# --- T3 (variant 1): a Branch:-bound task closes from a NON-repo CWD, and the
#     gate's query carries --repo <default-slug>. This is the CWD-independence
#     regression: `gh pr list` with no --repo errors outside a checkout. --------
seed_task DIVE-834 main main
cmd_task_set_branch DIVE-834 feat/dive-834-thing >/dev/null 2>&1
: >"$GH_ARGS_LOG"
export GH_STUB_STATE="" GH_STUB_MERGED="2026-07-23T12:00:00Z" GH_STUB_AUTH_TOKEN="tok"
NONREPO="$TMP/nonrepo"; mkdir -p "$NONREPO"
out=$( cd "$NONREPO" && cmd_task_done DIVE-834 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-834)" == "done" ]] \
  && ok_t "T3 Branch:-bound task closes from a non-repo CWD when its head is merged" \
  || bad_t "T3 close from non-repo CWD" "rc=$rc status=$(statusof DIVE-834) out=$out"
grep -q -- '--repo 5dive-ai/5dive' "$GH_ARGS_LOG" \
  && ok_t "T3 branch-path query passed --repo 5dive-ai/5dive (CWD-independent)" \
  || bad_t "T3 --repo present" "log=$(cat "$GH_ARGS_LOG")"

# --- T4 (variant 2): the gate propagates a resolved token to gh. With no env
#     token, the stubbed \`gh auth token\` supplies one and the pr-state calls
#     inherit it (proves sudo/non-authed callers no longer get state=unknown). --
seed_task DIVE-835 main main
: >"$GH_ARGS_LOG"
unset GH_TOKEN GITHUB_TOKEN
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-07-23T13:00:00Z" GH_STUB_AUTH_TOKEN="deleg-tok-789"
# delivery_ref path: bind a PR url directly.
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/835', delivered_at=datetime('now') WHERE ident='DIVE-835';"
out=$(cmd_task_done DIVE-835 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-835)" == "done" ]] \
  && ok_t "T4 delivery_ref task closes when merged (resolved token, no env GH_TOKEN)" \
  || bad_t "T4 close" "rc=$rc status=$(statusof DIVE-835) out=$out"
grep -q 'TOKEN=deleg-tok-789 ARGS=pr view' "$GH_ARGS_LOG" \
  && ok_t "T4 pr-state query inherited the resolved token (not the empty caller env)" \
  || bad_t "T4 token propagated" "log=$(cat "$GH_ARGS_LOG")"

# --- T5 (fail-safe): when gh reports nothing (unknown), the gate BLOCKS, never
#     false-closes — the direction must survive the resolution change. ----------
seed_task DIVE-836 main main
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/836', delivered_at=datetime('now') WHERE ident='DIVE-836';"
export GH_STUB_STATE="" GH_STUB_MERGED="" GH_STUB_AUTH_TOKEN=""
out=$(cmd_task_done DIVE-836 --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-836)" != "done" ]] \
  && ok_t "T5 unknown/empty state still BLOCKS (fail-safe, never false-close)" \
  || bad_t "T5 fail-safe" "rc=$rc status=$(statusof DIVE-836) out=$out"

echo "-----"
printf 'task_merge_gate_gh_resolve_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]