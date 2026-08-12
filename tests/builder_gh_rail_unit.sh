#!/usr/bin/env bash
# DIVE-2605 — a builder reaches GitHub through the MACHINE-ACCOUNT rail.
#
# THE MEASUREMENT THIS PINS (2026-08-04, probed from agent-dev2's own uid, which is
# the only uid the answer is true of — agent-dev is `NOPASSWD: ALL` and resolves a
# token, so probing from there answers a different question):
#   * `sudo -n -u claude gh auth token`      -> "sudo: a password is required"
#   * `sudo -n -l /usr/local/bin/5dive _gh_do` -> 0
#   * that rail returns `5dive-bot` for `api user`, and real state for `pr view`.
# A standard-isolation builder's sudoers is `ALL=(root) NOPASSWD: /usr/local/bin/5dive *`
# — one binary as root, nothing as `claude`. So the merge gate's token resolution is
# empty for them BY CONSTRUCTION, while the rail DIVE-2448 shipped answers fine.
# Nothing routed the gate onto it, so every merge-gated close funnelled through an
# agent that happened to hold a credential (five proxied closes on 2026-08-03).
#
# WHAT IS GRADED HERE, and why each arm is not vacuous:
#   T1  no token + no grant   -> NOT reachable   (the fail-safe survives; the
#                                positive control for every arm below)
#   T2  no token + grant      -> reachable       (the fix; without it T2 == T1)
#   T3  token present         -> reachable, and the TOKEN rail is used and sudo is
#                                never touched   (DIVE-1935's ordering: a caller's
#                                own credential wins over borrowing another's)
#   T4  the routed args reach `_gh_do` on STDIN, NUL-separated, byte-intact —
#       including a multi-line jq filter, which is what the real call sites pass
#   T5  each call site's OWN wall-clock bound is carried, not flattened to one
#   T6  every shape the gate routes classifies `read` in DIVE-2448's map, so the
#       rail cannot be talked into a write
#   T7  `5dive push --open-pr` sends `pr create` down the same rail, with the PR
#       BODY on stdin and never in argv
#   T8  a failed PR open does NOT fail the push (the push is the irreversible half)
#   T9  the PR flags refuse to be silently inert without --open-pr
#
# Isolation matches the sibling gate harnesses: src/ sourced into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched), `sudo` and `gh` STUBBED on PATH.
# Run: bash tests/builder_gh_rail_unit.sh   (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/builder-gh-rail-unit.XXXXXX)"

mkdir -p "$TMP/bin"

# --- stub sudo. Modes are set per-arm through SUDO_MODE:
#     deny  — every sudo call fails (no grant, and no borrowing `claude` either)
#     grant — `-l ... _gh_do` succeeds and `_gh_do` runs, but `-u claude gh auth
#             token` still FAILS. That pair IS a standard-isolation builder, and
#             getting it wrong in the permissive direction would let a token
#             resolve and make every bot-rail arm below grade the token rail.
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
args=("$@")
printf 'SUDO %s\n' "$*" >>"${SUDO_LOG:-/dev/null}"
[[ "${SUDO_MODE:-deny}" == "grant" ]] || exit 1
# `-u claude gh auth token`: a builder cannot run anything as another user.
for a in "${args[@]}"; do [[ "$a" == "-u" ]] && exit 1; done
listing=0
for a in "${args[@]}"; do [[ "$a" == "-l" ]] && listing=1; done
[[ $listing -eq 1 ]] && exit 0
# The real thing: read the NUL-separated argv off stdin and record it verbatim.
: >"${GHDO_ARGS_LOG:-/dev/null}"
while IFS= read -r -d '' a; do printf '%s\n<<ARG>>\n' "$a" >>"${GHDO_ARGS_LOG:-/dev/null}"; done
if [[ -n "${GHDO_ERR:-}" ]]; then printf '%s\n' "$GHDO_ERR" >&2; exit 1; fi
[[ -n "${GHDO_FAIL:-}" ]] && exit 1
printf '%s\n' "${GHDO_OUT:-}"
STUB
chmod +x "$TMP/bin/sudo"

# --- stub gh: records argv + the GH_TOKEN it inherited, so an arm can prove which
#     rail ran. Never answers `auth token` unless an arm asks it to.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'TOKEN=%s ARGS=%s\n' "${GH_TOKEN:-}" "$*" >>"${GH_ARGS_LOG:-/dev/null}"
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; exit 0
fi
printf '%s\n' "${GH_STUB_OUT:-}"
STUB
chmod +x "$TMP/bin/gh"
# `timeout` must resolve for the bounded arms; PATH is prefixed, not replaced.
export PATH="$TMP/bin:$PATH"
export SUDO_LOG="$TMP/sudo.log" GH_ARGS_LOG="$TMP/gh.args" GHDO_ARGS_LOG="$TMP/ghdo.args"
: >"$SUDO_LOG"; : >"$GH_ARGS_LOG"; : >"$GHDO_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_gh.sh cmd_push.sh \
         cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }

# --- PRECONDITION, asserted rather than assumed. `_gate_gh_bot_ok` requires the
# INSTALLED CLI to be executable at the exact path the sudoers grant names. On a
# runner without it every bot-rail arm below would report "unreachable" and PASS
# for the wrong reason — a green suite that graded nothing. Name the skip instead.
RAIL_TESTABLE=1
[[ -x /usr/local/bin/5dive ]] || RAIL_TESTABLE=0

unset GH_TOKEN GITHUB_TOKEN
export SUDO_USER=""

# --- T1: POSITIVE CONTROL — no token, no grant => not reachable. --------------
# Every arm below is a difference from this line. If T1 ever passes for the wrong
# reason the whole file is vacuous, so it is asserted, not assumed.
SUDO_MODE=deny GH_STUB_AUTH_TOKEN="" _gate_gh_reachable "" \
  && bad_t "T1 no token + no grant must NOT be reachable" "reachable anyway" \
  || ok_t "T1 no token + no grant is not reachable (fail-safe preserved)"

# --- T2: THE FIX — no token, grant present => reachable. ----------------------
if [[ $RAIL_TESTABLE -eq 1 ]]; then
  SUDO_MODE=grant GH_STUB_AUTH_TOKEN="" _gate_gh_reachable "" \
    && ok_t "T2 no token + _gh_do grant IS reachable (the bot rail)" \
    || bad_t "T2 bot rail not reachable" "sudo=$(tail -2 "$SUDO_LOG")"
else
  skip_t "T2 bot rail reachability" "/usr/local/bin/5dive is not executable here — the rail cannot be exercised, and asserting it would grade nothing"
fi

# --- T3: a resolvable token WINS and sudo is never consulted. ------------------
# DIVE-1935 put the caller's own credential ahead of a borrowed one on purpose;
# this proves the new arm did not quietly jump the queue.
: >"$SUDO_LOG"; : >"$GH_ARGS_LOG"
out=$(SUDO_MODE=grant _gate_gh "tok-abc" 10 pr view 7 --repo o/r 2>/dev/null)
if grep -q '_gh_do' "$SUDO_LOG"; then
  bad_t "T3 token rail must not route through _gh_do" "sudo=$(cat "$SUDO_LOG")"
else
  grep -q 'TOKEN=tok-abc ARGS=pr view 7 --repo o/r' "$GH_ARGS_LOG" \
    && ok_t "T3 a resolved token runs gh directly and never touches the bot rail" \
    || bad_t "T3 token rail" "gh=$(cat "$GH_ARGS_LOG")"
fi

# --- T4: routed args reach _gh_do NUL-separated and byte-intact. ---------------
# The real call sites pass jq filters containing newlines, quotes and $-signs. If
# these were flattened into one argv string (or word-split) the gate would query
# the wrong thing and report unverified — a silent wrong answer, not an error.
if [[ $RAIL_TESTABLE -eq 1 ]]; then
  : >"$GHDO_ARGS_LOG"
  multiline='[ .state,
   (.mergedAt // "null") ] | join("|")'
  out=$(SUDO_MODE=grant GHDO_OUT='MERGED|2026-08-04T00:00:00Z' \
        _gate_gh "" 10 pr view 430 --repo 5dive-ai/5dive -q "$multiline" 2>/dev/null)
  got=$(awk 'BEGIN{RS="\n<<ARG>>\n"} {print NR": "$0}' "$GHDO_ARGS_LOG" | head -20)
  if [[ "$out" == 'MERGED|2026-08-04T00:00:00Z' ]]; then
    ok_t "T4 the bot rail returns the routed call's stdout to the gate"
  else
    bad_t "T4 bot rail stdout" "out=$out"
  fi
  # The multi-line filter must arrive as ONE argument, newlines and all.
  if grep -qF '(.mergedAt // "null") ] | join("|")' "$GHDO_ARGS_LOG" \
     && grep -qF 'pr' "$GHDO_ARGS_LOG"; then
    ok_t "T4 a multi-line jq filter survives the NUL transport as one argument"
  else
    bad_t "T4 arg transport" "args=$got"
  fi
else
  skip_t "T4 NUL arg transport" "/usr/local/bin/5dive is not executable here"
fi

# --- T5: each site's OWN wall-clock bound is carried, not flattened. -----------
# The autodetect scan is bounded at 5s BECAUSE it is fail-open: a slow gh there
# must not stall a close that is allowed to proceed. Flattening every site to one
# number would have doubled that wait while looking like a tidy refactor.
: >"$GH_ARGS_LOG"
cat >"$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf 'TIMEOUT %s\n' "$1" >>"${TIMEOUT_LOG:-/dev/null}"
shift; exec "$@"
STUB
chmod +x "$TMP/bin/timeout"
export TIMEOUT_LOG="$TMP/timeout.log"; : >"$TIMEOUT_LOG"
SUDO_MODE=deny _gate_gh "tok" 5 pr list --repo o/r >/dev/null 2>&1
SUDO_MODE=deny _gate_gh "tok" 0 pr view 1 --repo o/r >/dev/null 2>&1
if grep -q '^TIMEOUT 5s$' "$TIMEOUT_LOG" && [[ $(grep -c '^TIMEOUT' "$TIMEOUT_LOG") -eq 1 ]]; then
  ok_t "T5 a site's own bound is carried (5s stays 5s) and 0 means unbounded on the token rail"
else
  bad_t "T5 timeout carry" "log=$(cat "$TIMEOUT_LOG")"
fi
rm -f "$TMP/bin/timeout"

# --- T6: every shape the gate routes is class `read` in DIVE-2448's map. -------
# The rail re-derives its own class as root and refuses admin, but a gate that
# routed a WRITE would still be a gate that writes as the bot. Grade the shapes.
cls_bad=""
while IFS='|' read -r label call; do
  # shellcheck disable=SC2086
  c=$(_gh_route_class $call)
  [[ "$c" == "read" ]] || cls_bad="${cls_bad}${label}=${c} "
done <<'SHAPES'
pr-view|pr view 430 --repo o/r --json state,mergedAt
pr-list|pr list --repo o/r --head b --state merged --json number
api-compare|api repos/o/r/compare/main...b
api-commits|api repos/o/r/commits?sha=main&per_page=100&page=1
SHAPES
[[ -z "$cls_bad" ]] \
  && ok_t "T6 every gh shape the merge gate routes classifies as read (never write/admin)" \
  || bad_t "T6 routed shape is not read" "$cls_bad"

# --- T7: push --open-pr sends `pr create` down the rail, body on STDIN. --------
# The body must never reach argv: a multi-paragraph PR body in the process table
# is worse than what a human typing `gh pr create --body "$(cat f)"` would leak.
if [[ $RAIL_TESTABLE -eq 1 ]]; then
  db "INSERT INTO tasks (ident, title, status, created_by, assignee)
        VALUES ('DIVE-2605','a title that is the PR subject line','in_progress','main','dev');" >/dev/null 2>&1
  : >"$GHDO_ARGS_LOG"; : >"$SUDO_LOG"
  printf 'line one\n\nline two with "quotes" and $dollars\n' >"$TMP/body.md"
  out=$(SUDO_MODE=grant GHDO_OUT='https://github.com/o/r/pull/99' \
        _push_open_pr DIVE-2605 o/r feat/x "" "" "$TMP/body.md" 0 2>&1); rc=$?
  if [[ $rc -eq 0 && "$out" == *"pull/99"* ]]; then
    ok_t "T7 --open-pr opens the PR through _gh_do and reports the URL"
  else
    bad_t "T7 open-pr" "rc=$rc out=$out"
  fi
  if grep -qF 'line two with "quotes" and $dollars' "$GHDO_ARGS_LOG" \
     && grep -qF 'pr' "$GHDO_ARGS_LOG" && grep -qF 'create' "$GHDO_ARGS_LOG"; then
    ok_t "T7 the PR body travels over stdin, intact, with quotes and dollars"
  else
    bad_t "T7 body transport" "args=$(cat "$GHDO_ARGS_LOG")"
  fi
  # The body must NOT be in the argv sudo itself was invoked with.
  grep -qF 'line two with' "$SUDO_LOG" \
    && bad_t "T7 PR body leaked into sudo's argv" "sudo=$(cat "$SUDO_LOG")" \
    || ok_t "T7 the PR body never appears in sudo's argv (no process-table leak)"
  # Default title binds the ident, which is the evidence the merge gate matches on.
  : >"$GHDO_ARGS_LOG"
  SUDO_MODE=grant GHDO_OUT='https://github.com/o/r/pull/100' \
    _push_open_pr DIVE-2605 o/r feat/x "" "" "" 0 >/dev/null 2>&1
  grep -qF 'DIVE-2605: a title that is the PR subject line' "$GHDO_ARGS_LOG" \
    && ok_t "T7 the default PR title carries the ident (the gate's ident-match evidence)" \
    || bad_t "T7 default title" "args=$(cat "$GHDO_ARGS_LOG")"
else
  skip_t "T7 push --open-pr routing" "/usr/local/bin/5dive is not executable here"
fi

# --- T8: a failed PR open returns non-zero WITHOUT killing the push. -----------
# The push already happened and is the irreversible half; a red exit there invites
# a re-push for a step anyone can redo by hand.
if [[ $RAIL_TESTABLE -eq 1 ]]; then
  SUDO_MODE=grant GHDO_FAIL=1 _push_open_pr DIVE-2605 o/r feat/x "" "" "" 0 >/dev/null 2>&1
  [[ $? -ne 0 ]] \
    && ok_t "T8 a failed PR open reports failure to its caller (which only warns)" \
    || bad_t "T8 failed open" "returned 0"
else
  skip_t "T8 failed PR open" "/usr/local/bin/5dive is not executable here"
fi

# --- T10: "a PR already exists" is the DESIRED END STATE, not a failure. -------
# Measured live on 2026-08-04: re-running `push --open-pr` after a second commit on
# the same branch hits this every time, and the first cut reported it as a failure
# and then advised `5dive gh pr create` — the exact command that had just refused.
# Advice that is wrong in the most likely failure mode is worse than none.
if [[ $RAIL_TESTABLE -eq 1 ]]; then
  out=$(SUDO_MODE=grant GHDO_ERR='a pull request for branch "feat/x" into branch "main" already exists:
https://github.com/o/r/pull/431' _push_open_pr DIVE-2605 o/r feat/x "" "" "" 0 2>&1); rc=$?
  if [[ $rc -eq 0 && "$out" == *"already has a pull request"* && "$out" == *"pull/431"* ]]; then
    ok_t "T10 an existing PR is reported as success and names the PR's URL"
  else
    bad_t "T10 already-exists" "rc=$rc out=$out"
  fi
  # ANCHOR: a DIFFERENT failure must still be a failure — otherwise T10 would have
  # been bought by swallowing every error, which is the cheap wrong version of it.
  SUDO_MODE=grant GHDO_ERR='HTTP 403: Resource not accessible by integration' \
    _push_open_pr DIVE-2605 o/r feat/x "" "" "" 0 >/dev/null 2>&1
  [[ $? -ne 0 ]] \
    && ok_t "T10 ANCHOR: a 403 is still a failure (the already-exists arm is specific, not a blanket swallow)" \
    || bad_t "T10 anchor" "a 403 returned 0"
else
  skip_t "T10 already-exists handling" "/usr/local/bin/5dive is not executable here"
fi

# --- T9: the PR flags refuse to be silently inert without --open-pr. ----------
# A flag you think attached a body, on a verb you run once per branch, is worth a
# usage error rather than a shrug.
out=$(cmd_push DIVE-2605 --pr-title=x 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"without --open-pr"* ]] \
  && ok_t "T9 --pr-title without --open-pr is a usage error, not a silent no-op" \
  || bad_t "T9 inert PR flag" "rc=$rc out=$out"
out=$(cmd_push DIVE-2605 --open-pr --pr-body-file=/nope/missing.md 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"not readable"* ]] \
  && ok_t "T9 an unreadable --pr-body-file is refused BEFORE the push" \
  || bad_t "T9 body-file validation" "rc=$rc out=$out"

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]] || exit 1
[[ $PASS -gt 0 ]] || { printf 'FAIL - nothing was graded\n'; exit 1; }
exit 0
