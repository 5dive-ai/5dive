#!/usr/bin/env bash
# DIVE-2296 — A MAKER WITH NO GITHUB CREDENTIAL CANNOT OBSERVE THEIR OWN WORK.
#
# THE MEASUREMENT (DIVE-2282/2286, 2026-07-29, dev2): on ONE task a builder needed
# another agent at five points. Three of them are "cannot ACT" and the credential
# separation intends every one — a builder who cannot force-push cannot quietly
# rewrite what a reviewer already read. The other two are "cannot OBSERVE", which
# nothing designed: they filed a gate asking main to open a PR they had opened
# fifteen minutes earlier, then two more asking for a merge that was waiting on an
# 18-minute CI run. Both are reads. Both were answerable without granting anything.
#
# This file grades the two surfaces that made those reads unavailable:
#
#   PART A (src/cmd_gh.sh) — `5dive gh` routed a READ to the caller's own
#   credential, and on a seat holding none that is a refusal. The message then
#   named the escape as "--as=bot IF THIS IS A WRITE", steering the one caller who
#   needed it away from the one path that works. A maker reads that as "reads are
#   closed to me" and falls back to asking.
#
#   PART B (src/cmd_task.sh) — the DIVE-1830 merge gate's branch-path refusal reads
#   the same whether NO PR exists for the branch or a PR is open and mid-CI. Those
#   demand opposite responses (open one / wait), and for a credential-less maker
#   that refusal is the ONLY window onto their own work. One instrument, two states,
#   no way to tell them apart — so the collapse does not merely under-inform, it
#   manufactures the round trips DIVE-2296 counted.
#
# WHAT IS NOT CLAIMED. Neither half grants authority. Part A's route is refused for
# admin-class work (A3), is a subset of what an authed caller sees, and reaches a
# token `--as=bot` already reached by hand. Part B's lookup is DIAGNOSTIC: an OPEN
# PR accepts nothing (B4 is the anchor that pins this), because done=merged-to-main
# is the entire point of the gate and a refusal that explains itself better is not a
# refusal that yields.
#
# ANCHORS, so no arm here is satisfiable by simply deleting a guard: A2/A4 pin that
# an authed caller and an explicit --as=caller are still routed to the caller (the
# fix fires ONLY where there is nothing to route to), A5 pins writes unchanged, and
# B4 pins that the better message still refuses.
#
# Isolation matches the sibling gate harnesses: src/ sourced into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched), `gh` and `sudo` STUBBED on PATH.
# Run: bash tests/gh_credentialless_read_route_unit.sh   (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# The merge gate's credential-free ANON rail would reach the real network on the
# no-token arms below and grade a LIVE PR instead of the fixture. Off here, as in
# every sibling harness; it has its own file. MUST sit after lib/grading_tree.sh,
# which clears inherited FIVE_* knobs.
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gh-credentialless-read-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# --- stub sudo. Always fails: the token resolver's last resort is
# `sudo -n -u claude gh auth token`, which on THIS host succeeds for agents whose
# sudoers is NOPASSWD:ALL — without the stub the no-credential arms would grade a
# real oauth token the fleet does not uniformly hold.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"

# --- stub gh. Unlike the older gate harnesses this one HONOURS `--state`, because
# the whole finding in Part B is that "no merged PR" and "an open PR exists" are
# different states; a stub that served one fixture to both queries could not grade
# the difference it exists to measure.
#   `auth token`  -> GH_STUB_AUTH_TOKEN (exit 1 when empty = no credential)
#   `pr list --repo <slug> --state open`   -> GH_STUB_OPEN_<REPO>   (JSON array)
#   `pr list --repo <slug> --state merged` -> GH_STUB_MERGED_<REPO> (JSON array)
#   `api repos/<slug>/commits?...`         -> GH_STUB_COMMITS_<REPO>_<BRANCH>
# NO FIXTURE => an EMPTY array, i.e. the query ran and found nothing.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"${GH_ARGS_LOG:-/dev/null}"
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0
fi
a=("$@"); expr='.'; repo=""; state=""; i=0
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -q|--jq)  expr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -q*)      expr="${a[$i]#-q}";    i=$((i+1)) ;;
    --repo)   repo="${a[$((i+1))]}"; i=$((i+2)) ;;
    --state)  state="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)        i=$((i+1)) ;;
  esac
done
key() { printf '%s' "${1//[^A-Za-z0-9]/_}"; }
if [[ "$1" == "api" ]]; then
  path="$2"; slug=$(printf '%s' "$path" | cut -d/ -f2,3)
  case "$path" in
    */commits\?*) br="${path##*sha=}"; br="${br%%&*}"
                  fx="GH_STUB_COMMITS_$(key "${slug##*/}")_$(key "$br")" ;;
    *) exit 1 ;;
  esac
  json="${!fx:-}"; [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  # GH_FAIL_OPEN models the query that could not RUN (no rail, invalid credential,
  # timeout). It must stay distinguishable from an empty result set.
  [[ "$state" == "open" && -n "${GH_FAIL_OPEN:-}" ]] && exit 1
  case "$state" in
    open)   fx="GH_STUB_OPEN_$(key "${repo##*/}")" ;;
    merged) fx="GH_STUB_MERGED_$(key "${repo##*/}")" ;;
    *)      fx="" ;;
  esac
  printf '%s' "${fx:+${!fx:-}}"     >/dev/null   # keep set -u honest under an unset fixture
  json="[]"; [[ -n "$fx" && -n "${!fx:-}" ]] && json="${!fx}"
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------------------
# PART A — `5dive gh` routing. --explain prints the decision and returns before
# anything is executed, so every arm here grades the ROUTE, never a network call.
# ---------------------------------------------------------------------------
(
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_gh.sh; do
  source "$SRC/$f"
done
JSON_MODE=0
gh_explain() { cmd_gh --explain "$@" 2>&1; }

export GH_STUB_AUTH_TOKEN=""          # a seat holding NOTHING — DIVE-2296's caller
A1=$(gh_explain pr list --repo 5dive-ai/5dive)
[[ "$A1" == *"actor=5dive-bot"* && "$A1" == *"DIVE-2296"* ]] \
  && ok_t 'A1 a READ from a credential-less seat routes to the bot, and says why' \
  || bad_t 'A1 credential-less read must route' "out=$A1"
[[ "$A1" != *"NONE IS RESOLVED"* ]] \
  && ok_t 'A1 and it no longer names a credential that does not exist' \
  || bad_t 'A1 must not refuse' "out=$A1"

export GH_STUB_AUTH_TOKEN="tok-2296"  # ANCHOR: the caller HAS one
A2=$(gh_explain pr list --repo 5dive-ai/5dive)
[[ "$A2" == *"actor=your own gh credential"* && "$A2" != *"actor=5dive-bot"* ]] \
  && ok_t 'A2 ANCHOR: an AUTHED caller still reads as themselves (the fix fires only where nothing is routable)' \
  || bad_t 'A2 authed caller must not be diverted' "out=$A2"

export GH_STUB_AUTH_TOKEN=""
A3=$(gh_explain api --method GET /repos/5dive-ai/5dive/collaborators)
[[ "$A3" != *"actor=5dive-bot"* ]] \
  && ok_t 'A3 an ADMIN-class call is NOT rerouted — the fix grants no authority the bot lacks' \
  || bad_t 'A3 admin must not route to the bot' "out=$A3"
[[ "$A3" == *"READS as well as writes"* && "$A3" != *"--as=bot if this is a write"* ]] \
  && ok_t 'A3 and the surviving refusal no longer says --as=bot is for writes only' \
  || bad_t 'A3 hint text' "out=$A3"

A4=$(gh_explain --as=caller pr list --repo 5dive-ai/5dive)
[[ "$A4" == *"you asked for --as=caller"* && "$A4" != *"actor=5dive-bot"* ]] \
  && ok_t 'A4 ANCHOR: an EXPLICIT --as=caller is still honoured, credential or not' \
  || bad_t 'A4 explicit intent overridden' "out=$A4"

# A6 — the arm main asked for on the gate. A fallback that fires BOTH when the seat
# holds nothing and when it holds something unusable is indistinguishable from one
# that ignores the credential entirely and always takes the bot. It does not: the
# route keys on RESOLUTION (`gh auth token`, which is offline and makes no network
# call), so a present-but-invalid login still routes to its owner and fails as
# itself. That is the correct direction — 5dive must not silently launder a caller's
# broken credential into the machine account's.
export GH_STUB_AUTH_TOKEN="tok-invalid-but-present"
A6=$(gh_explain pr view 349)
[[ "$A6" == *"actor=your own gh credential"* && "$A6" != *"actor=5dive-bot"* ]] \
  && ok_t 'A6 a RESOLVED-but-invalid login is NOT diverted — the route keys on resolution, not validity' \
  || bad_t 'A6 invalid credential must not divert' "out=$A6"
export GH_STUB_AUTH_TOKEN=""

A5=$(gh_explain pr create --repo 5dive-ai/5dive)
[[ "$A5" == *"actor=5dive-bot"* && "$A5" == *"class=write"* ]] \
  && ok_t 'A5 ANCHOR: writes route to the bot exactly as before (DIVE-2232 unchanged)' \
  || bad_t 'A5 write routing changed' "out=$A5"
printf '%s %s\n' "$PASS" "$FAIL" >"$TMP/partA.count"
)
read -r _pa _fa <"$TMP/partA.count"; PASS=$((PASS+_pa)); FAIL=$((FAIL+_fa))

# ---------------------------------------------------------------------------
# PART B — the DIVE-1830 branch-path refusal must distinguish "no PR" from
# "PR #N open, checks <state>".
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
task_need_notify() { :; }
audit_log() { :; }

seed()     { db "INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                   VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
slugof()   { db "SELECT policy FROM policy_refusals WHERE ident='$1' ORDER BY id DESC LIMIT 1;"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
clear_fx() { local v; for v in $(compgen -v | grep -E '^GH_STUB_(OPEN|MERGED|COMMITS)_' || true); do unset "$v"; done; }
# A token so the gate's probes RUN — Part B is about what the refusal SAYS once
# GitHub is reachable, which is a different fault from having no rail at all.
export GH_STUB_AUTH_TOKEN="tok-2296"
rollup() { # <conclusion> — one completed check with the given conclusion
  printf '[{"name":"ci","conclusion":"%s","completedAt":"2026-08-11T00:00:00Z"}]' "$1"; }
# A SHORT page of main history naming nothing — the attribution scan reads a page
# shorter than the one it asked for as history EXHAUSTED, i.e. a genuine miss. Set
# on every branch arm: without it the scan is UNREACHABLE and refuses one arm
# earlier (done-attribution-unresolved), which is a different, already-graded fault.
main_history() { export GH_STUB_COMMITS_5dive_main='[{"commit":{"message":"chore: unrelated"}}]'; }

# B1 — an OPEN PR with GREEN checks. This is DIVE-2286's item 5: the maker asked
# three times for a merge that was simply not ready yet.
clear_fx; main_history
export GH_STUB_OPEN_5dive="[{\"number\":295,\"statusCheckRollup\":$(rollup SUCCESS)}]"
seed B-1 'Repo: 5dive-ai/5dive
Branch: dive-2296-observe'
run_done B-1 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof B-1)" == "done-before-branch-merged" ]] \
  && ok_t 'B1 ANCHOR: an open PR still REFUSES under the DIVE-1830 slug — diagnosis is not acceptance' \
  || bad_t 'B1 must still refuse' "rc=$RC slug=[$(slugof B-1)] out=$OUT"
[[ "$OUT" == *"AN OPEN PR ALREADY EXISTS"* && "$OUT" == *"295"* ]] \
  && ok_t 'B1 the refusal NAMES the open PR instead of implying nothing is happening' \
  || bad_t 'B1 must name the open PR' "out=$OUT"
[[ "$OUT" == *"GREEN"* && "$OUT" == *"waiting on a MERGE"* ]] \
  && ok_t 'B1 and reads its checks, so "wait" and "act" are distinguishable' \
  || bad_t 'B1 must report check state' "out=$OUT"
[[ "$OUT" != *"No OPEN PR was found"* ]] \
  && ok_t 'B1 and does NOT tell the maker to go open the PR they already opened (DIVE-2286 item 4)' \
  || bad_t 'B1 contradictory advice' "out=$OUT"

# B2 — the genuinely-nothing case. The old sentence was RIGHT here, and must survive.
clear_fx; main_history
seed B-2 'Repo: 5dive-ai/5dive
Branch: dive-2296-nothing'
run_done B-2 --result='landed'
[[ $RC -eq $E_CONFLICT && "$OUT" == *"No OPEN PR was found"* && "$OUT" == *"5dive push B-2"* ]] \
  && ok_t 'B2 with no PR at all the refusal says so and gives the push remedy' \
  || bad_t 'B2 no-PR wording' "rc=$RC out=$OUT"
[[ "$OUT" != *"ALREADY EXISTS"* ]] \
  && ok_t 'B2 and does not invent a PR (the two states are really being told apart)' \
  || bad_t 'B2 false positive' "out=$OUT"

# B3 — RED checks. "Open" alone would send the maker to ask for a merge that
# cannot happen; the next step here is the PR, not another agent.
clear_fx; main_history
export GH_STUB_OPEN_5dive="[{\"number\":296,\"statusCheckRollup\":$(rollup FAILURE)}]"
seed B-3 'Repo: 5dive-ai/5dive
Branch: dive-2296-red'
run_done B-3 --result='landed'
[[ "$OUT" == *"296"* && "$OUT" == *"RED"* && "$OUT" == *"merging it is not the next step"* ]] \
  && ok_t 'B3 a RED open PR is named as red, with the action that follows from it' \
  || bad_t 'B3 red wording' "out=$OUT"

# B4 — ANCHOR. The accepting path is untouched: a MERGED PR for the branch still
# closes. Without this arm every arm above is satisfiable by making the gate
# refuse unconditionally.
clear_fx
export GH_STUB_MERGED_5dive='[{"number":297,"mergedAt":"2026-08-11T01:00:00Z"}]'
seed B-4 'Repo: 5dive-ai/5dive
Branch: dive-2296-landed'
run_done B-4 --result='landed'
[[ "$(statusof B-4)" == "done" ]] \
  && ok_t 'B4 ANCHOR: a MERGED PR for the branch still CLOSES (acceptance unchanged)' \
  || bad_t 'B4 acceptance regressed' "rc=$RC status=$(statusof B-4) out=$OUT"

# B5 — the other condition on the gate: the new lookup must DEGRADE HONESTLY. A
# query that could not run must never print as "no open PR" — that is the DIVE-2318
# shape this whole ticket sits downstream of, and the sibling surface has already
# been bitten by it (an invalid credential made `task done` refuse on a row whose
# merge WAS on main, because the gate asked gh and not git).
clear_fx; main_history
export GH_FAIL_OPEN=1
seed B-5 'Repo: 5dive-ai/5dive
Branch: dive-2296-unreadable'
run_done B-5 --result='landed'
unset GH_FAIL_OPEN
[[ "$OUT" == *"is UNKNOWN"* && "$OUT" == *"NOT 'there is no PR'"* ]] \
  && ok_t 'B5 an unanswerable lookup prints UNKNOWN, never a green-looking blank' \
  || bad_t 'B5 must degrade honestly' "out=$OUT"
[[ "$OUT" != *"No OPEN PR was found"* ]] \
  && ok_t 'B5 and does NOT assert an absence it never measured (DIVE-2318 shape)' \
  || bad_t 'B5 false absence' "out=$OUT"
[[ $RC -eq $E_CONFLICT && "$(statusof B-5)" != "done" ]] \
  && ok_t 'B5 ANCHOR: and it still REFUSES — an unreadable probe is not an escape' \
  || bad_t 'B5 must still refuse' "rc=$RC status=$(statusof B-5)"

printf -- '-----\n%s: %s passed, %s failed\n' "$(basename "$0" .sh)" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
