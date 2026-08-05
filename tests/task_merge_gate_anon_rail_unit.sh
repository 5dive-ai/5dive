#!/usr/bin/env bash
# TIER: nightly — 13.8s measured (2026-08-05, this host, smallest of 3 runs: 13.8/15.2/15.3s): does not fit the 300s PR core. 16 real `task done` closes at ~0.85s each is the cost, and the sibling DIVE-2318 diagnostic harness was demoted at 5.8s for the same reason. A PR that touches this file still runs it — the changed-harnesses job ignores tier.
# DIVE-2770 — the merge gate must be able to ask "did this land?" WITHOUT a credential.
#
# THE DEADLOCK THIS GRADES. DIVE-2449 was bound to PR #483, #483 was merged (squash
# 0396d920), and the row could not be recorded closed. The DIVE-477 rail requires the
# close come from the VERIFIER OF RECORD; that seat holds no gh credential by design
# (`_gh_do` is the can-push grant a grader must not hold), so `_gate_gh_reachable` was
# false and the gate refused with COULD-NOT-CHECK. The agent permitted to close could
# not see the evidence; the agent who could see it was barred from closing. Both
# refusals were correct on their own and together they enclosed the caller — and the
# refusal's two printed remedies (`5dive gh whoami`, "hand it to agent-main") are the
# two things that caller cannot do. `--force-merge-gate` does not reach it either: it
# escapes a gate that RAN and disagreed, not one that asked nothing.
#
# THE FIX IS TO STOP DEMANDING A CREDENTIAL FOR A PUBLIC FACT. `GET /repos/O/R/pulls/N`
# is anonymous on a public repo. The rail is tried LAST, after the token and the bot,
# so nothing that resolves a credential today changes path — which is what T6 pins.
#
# AND THE SQUASH HALF, which is a second bug wearing the first one's clothes: REST
# reports a squash-merged PR as `state: "closed"` while gh reports `"MERGED"`. Copying
# `.state` across would false-refuse `done-before-pr-merged` on exactly the population
# this rail exists to unblock, so gh's state is DERIVED from `.merged`. Every merged
# fixture below is deliberately `"state":"closed"` — the squash shape — so T1 and T5
# are red the moment that derivation is replaced by a copy.
#
# MUTATION GRADE — RUN against the shipping tree, not predicted (2026-08-05,
# src/cmd_task.sh in this worktree; the arm names are the ones that ACTUALLY went
# red, each from 25/0 clean). Eight mutants, eight distinct signatures:
#   * `_gate_gh_reachable`: drop the `_gate_anon_ok` arm       -> 13/12: T1 (all 3),
#     T2 (both), T5, T5b, T7's label, T8, T8b, T9. The rail is load-bearing for most
#     of the file, which is why the anchors below matter more than the pass count.
#   * the reshape: `state: (.state|ascii_upcase)` instead of DERIVING it from
#     `.merged`                                                -> 19/6: T1 (close +
#     no-refusal), T5, T5b, T9. T2 stays GREEN — an OPEN PR reads OPEN under either
#     rule, so T2 alone cannot grade the squash derivation and T1 must sit beside it.
#     THIS IS THE SQUASH MUTANT: REST says "closed" for a merged PR, and the copy
#     false-refuses done-before-pr-merged on every squash-merged row.
#   * `_gate_anon_gh`: serve `pr list --state open` too        -> 24/1: T7's third
#     arm and ONLY that one. A one-arm kill is what a deliberate omission looks like.
#   * `_gate_anon_gh` returns 0 with "MERGED" for everything   -> 9/16, incl. all of
#     T3 and T8. The anchor set: a rail that answers everything satisfies "did the
#     row close?" and fails every arm about whether it ASKED.
#   * ignore FIVE_GATE_NO_ANON                                 -> 23/2: both T4 arms.
#   * classify a 403-rate-limit as a 404                       -> 23/2: T8's naming
#     and mislabel arms. T8b stays green, which is correct — the 404 case is
#     unaffected, and that asymmetry is the point of having both.
#   * blank the `_why` clause in the refusal                   -> 23/2: T8, T8b.
#   * `_gate_anon_gh`: refuse the `pr list --head --state merged` branch listing
#                                                              -> 30/1: T10 alone.
#   * never fetch the rollup (leave `statusCheckRollup` absent) -> 29/2: T11's red-
#     merge arm and its both-surfaces arm. An absent key renders NONE — "no checks
#     reported" for a question nobody asked — so DIVE-1935's guard goes blind and a
#     RED merged PR closes clean. T11b anchors the other side.
#   * drop the `_gate_gh_credentialed` branch at the LATE site -> 17/8: all of T3
#     and T8. Without it a private repo lands on done-pr-state-unresolved, whose text
#     says "a gh credential resolved" to a seat that has never held one — DIVE-2318's
#     own defect, reintroduced one refusal further down by this ticket's own fix.
#
# Isolation matches the sibling gate harnesses: src/ sourced into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh, sudo AND curl are STUBBED on
# PATH, so this file makes no network call and needs no root.
# Run: bash tests/task_merge_gate_anon_rail_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-anon-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# --- stub sudo: kills BOTH the `sudo -n -u claude gh auth token` last resort and the
# `sudo -n -l ... _gh_do` bot-rail probe, so every arm below runs with the two
# pre-DIVE-2770 rails genuinely absent. That is the verifier seat this ticket is about.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"

# --- stub gh. `auth token` honours GH_STUB_AUTH_TOKEN; `pr view` answers only when
# GH_STUB_STATE is set (the token arm, T6). Everything else exits 1 — the token rail
# is dead, which is the precondition for reaching the anon rail at all.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0
fi
a=("$@"); expr='.'; i=0
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -q|--jq) expr="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)       i=$((i+1)) ;;
  esac
done
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  [[ -n "${GH_STUB_STATE:-}" ]] || exit 1
  printf '%s' "{\"state\":\"${GH_STUB_STATE}\",\"mergedAt\":${GH_STUB_MERGED:-null},\"statusCheckRollup\":[],\"headRefOid\":\"${GH_STUB_HEAD:-}\",\"mergeCommit\":null}" \
    | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/gh"

# --- stub curl: THE ANON RAIL'S ONLY TRANSPORT. Fixture per URL path, keyed the same
# way the sibling harnesses key gh fixtures. NO FIXTURE => HTTP 404, which is what an
# unauthenticated read of a PRIVATE repo really returns — that is T3, and it is a
# fall-through rather than a separate code path. CURL_STUB_RATELIMIT => HTTP 403 with
# `x-ratelimit-remaining: 0`, the shared 60/hour anonymous budget, which is T8.
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Models the three outcomes the rail must tell apart: a 200 with a body, a 404
# (private repo / gone), and a 403 with `x-ratelimit-remaining: 0` (the shared
# 60/hour anonymous budget). It honours -o/-D/-w because the rail reads the STATUS
# and the HEADERS, not just the body — a stub that only echoed a body would make
# the rate-limit arm unreachable.
a=("$@"); out=""; hdr=""; w=""; i=0
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -o) out="${a[$((i+1))]}"; i=$((i+2)) ;;
    -D) hdr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -w) w="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)  i=$((i+1)) ;;
  esac
done
url="${a[$((${#a[@]}-1))]}"
printf 'URL=%s\n' "$url" >>"$CURL_LOG"
emit() { # <code> <body> <extra-headers>
  [[ -n "$hdr" ]] && { printf 'HTTP/2 %s\r\n' "$1" >"$hdr"; [[ -n "${3:-}" ]] && printf '%s\r\n' "$3" >>"$hdr"; printf '\r\n' >>"$hdr"; }
  if [[ -n "$out" ]]; then printf '%s' "$2" >"$out"; else printf '%s' "$2"; fi
  [[ -n "$w" ]] && printf '%s' "$1"
  exit 0
}
if [[ -n "${CURL_STUB_RATELIMIT:-}" ]]; then
  emit 403 '{"message":"API rate limit exceeded"}' \
    "x-ratelimit-remaining: 0
x-ratelimit-reset: ${CURL_STUB_RESET:-1785919621}"
fi
path="${url#*://*/}"
key="CURL_FX_$(printf '%s' "$path" | tr -c 'A-Za-z0-9' '_')"
body="${!key:-}"
[[ -n "$body" ]] || emit 404 '{"message":"Not Found"}'
emit 200 "$body" 'x-ratelimit-remaining: 42'
STUB
chmod +x "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"
export CURL_LOG="$TMP/curl.log"; : >"$CURL_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
_tasks_db_migrate
task_need_notify() { :; }
audit_log() { :; }

seed()      { db "INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                    VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
statusof()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
slugof()    { db "SELECT policy FROM policy_refusals WHERE ident='$1' ORDER BY id DESC LIMIT 1;"; }
bind_pr()   { db "UPDATE tasks SET delivery_ref='$2', delivered_at=datetime('now') WHERE ident='$1';"; }
run_done()  { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }

no_token()  { unset GH_TOKEN GITHUB_TOKEN; export SUDO_USER=""; export GH_STUB_AUTH_TOKEN=""; }
a_token()   { unset GH_TOKEN GITHUB_TOKEN; export SUDO_USER=""; export GH_STUB_AUTH_TOKEN="tok-2770"; }
# The rail records WHY its last read failed in a per-pid file (it runs inside `$( )`,
# so a variable would not survive). This harness is one pid, so an arm would inherit
# the previous arm's outcome and T8/T8b would grade a stale classification rather
# than their own.
clear_fx()  { local v; for v in $(compgen -v | grep -E '^CURL_FX_' || true); do unset "$v"; done
              unset GH_STUB_STATE GH_STUB_MERGED GH_STUB_HEAD FIVE_GATE_NO_ANON
              unset CURL_STUB_RATELIMIT CURL_STUB_RESET
              rm -f "$_GATE_ANON_STATEF" 2>/dev/null
              : >"$CURL_LOG"; : >"$GH_ARGS_LOG"; }

# The squash shape, verbatim from GitHub: `state` is "closed" and `merged` is true.
SQUASH_SHA=0396d9206f88e8776cd7369a5003e5497811dfb1
HEAD_SHA=1111111111111111111111111111111111111111
merged_pr() {
  printf '{"number":483,"state":"closed","merged":true,"merged_at":"2026-08-05T08:10:00Z",'
  printf '"title":"task: warn on unparented follow-ups (DIVE-2449)",'
  printf '"head":{"ref":"dive-2449-followups","sha":"%s"},' "$HEAD_SHA"
  printf '"merge_commit_sha":"%s","html_url":"https://github.com/5dive-ai/5dive/pull/483"}' "$SQUASH_SHA"
}
open_pr() {
  printf '{"number":484,"state":"open","merged":false,"merged_at":null,'
  printf '"title":"wip","head":{"ref":"dive-2770-wip","sha":"%s"},' "$HEAD_SHA"
  printf '"merge_commit_sha":null,"html_url":"https://github.com/5dive-ai/5dive/pull/484"}'
}

# ---------------------------------------------------------------------------
# T1 — THE TICKET. No token, no bot rail, a SQUASH-MERGED public PR. The close
# must SUCCEED, on evidence, with no credential anywhere in the environment.
# ---------------------------------------------------------------------------
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
seed A-1; bind_pr A-1 'https://github.com/5dive-ai/5dive/pull/483'
run_done A-1 --result='landed'
[[ $RC -eq 0 && "$(statusof A-1)" == "done" ]] \
  && ok_t 'T1 a credential-less seat CLOSES a squash-merged row (the DIVE-2449 deadlock)' \
  || bad_t 'T1 anon close' "rc=$RC status=$(statusof A-1) out=$OUT"
[[ -z "$(slugof A-1)" ]] \
  && ok_t 'T1 no refusal was recorded — the gate ANSWERED, it did not get overridden' \
  || bad_t 'T1 unexpected refusal' "slug=[$(slugof A-1)] out=$OUT"
grep -q 'pulls/483' "$CURL_LOG" \
  && ok_t 'T1 the answer came from the anonymous rail (the PR was actually fetched)' \
  || bad_t 'T1 rail not used' "curl=$(cat "$CURL_LOG")"

# ---------------------------------------------------------------------------
# T2 — ANCHOR, and the one that stops T1 from being satisfiable by deleting the
# gate. A genuinely OPEN PR, same missing credentials, must still refuse under
# the original DIVE-1830 slug and name the MEASURED state.
# ---------------------------------------------------------------------------
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_484="$(open_pr)"
seed A-2; bind_pr A-2 'https://github.com/5dive-ai/5dive/pull/484'
run_done A-2 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(statusof A-2)" != "done" && "$(slugof A-2)" == "done-before-pr-merged" ]] \
  && ok_t 'T2 ANCHOR: an OPEN PR still refuses as not-merged over the anon rail' \
  || bad_t 'T2 real negative preserved' "rc=$RC slug=[$(slugof A-2)] out=$OUT"
[[ "$OUT" == *"state=OPEN"* ]] \
  && ok_t 'T2 the refusal names the state the rail MEASURED, not "unknown"' \
  || bad_t 'T2 measured state' "out=$OUT"

# ---------------------------------------------------------------------------
# T3 — PRIVATE REPO. No fixture => curl exits 22, exactly as `curl -f` does on a
# 404. There is no anonymous read of a private repo, so the rail declines and the
# close must land on the SAME refusal as before this ticket — and that refusal
# must now tell the two causes apart and name a move the caller can actually make.
# ---------------------------------------------------------------------------
clear_fx; no_token
seed A-3; bind_pr A-3 'https://github.com/lodar/5dive-api/pull/59'
run_done A-3 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof A-3)" == "done-merge-gate-no-credential" ]] \
  && ok_t 'T3 a private repo falls through to the no-rail refusal, unchanged slug' \
  || bad_t 'T3 fall-through' "rc=$RC slug=[$(slugof A-3)] out=$OUT"
[[ "$OUT" == *"COULD NOT CHECK"* && "$OUT" != *"is not merged to main yet"* ]] \
  && ok_t 'T3 still asserts no merge verdict (DIVE-2318 held)' \
  || bad_t 'T3 must not assert a verdict' "out=$OUT"
[[ "$OUT" == *"BY DESIGN"* && "$OUT" == *"BY FAULT"* ]] \
  && ok_t 'T3 separates cannot-check-BY-FAULT from cannot-check-BY-DESIGN' \
  || bad_t 'T3 cause separation' "out=$OUT"
[[ "$OUT" == *"task verify"* ]] \
  && ok_t 'T3 names a terminal move the verifier seat can REACH' \
  || bad_t 'T3 reachable remedy' "out=$OUT"
[[ "$OUT" == *"--force-merge-gate\` does NOT reach this refusal"* ]] \
  && ok_t 'T3 says the audited escape does NOT apply here (it advertised itself before)' \
  || bad_t 'T3 force-merge-gate disclaimer' "out=$OUT"

# ---------------------------------------------------------------------------
# T4 — the opt-out. FIVE_GATE_NO_ANON=1 restores the pre-2770 world even with a
# perfectly good fixture sitting there. This is what the sibling harnesses set,
# so it is load-bearing for the whole corpus, not a convenience.
# ---------------------------------------------------------------------------
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
export FIVE_GATE_NO_ANON=1
seed A-4; bind_pr A-4 'https://github.com/5dive-ai/5dive/pull/483'
run_done A-4 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof A-4)" == "done-merge-gate-no-credential" ]] \
  && ok_t 'T4 FIVE_GATE_NO_ANON=1 turns the rail off (the opt-out is real)' \
  || bad_t 'T4 opt-out' "rc=$RC slug=[$(slugof A-4)] out=$OUT"
[[ ! -s "$CURL_LOG" ]] \
  && ok_t 'T4 and it does not merely ignore the answer — no request was made' \
  || bad_t 'T4 no request' "curl=$(cat "$CURL_LOG")"
unset FIVE_GATE_NO_ANON

# ---------------------------------------------------------------------------
# T5 — DIVE-2656 over the anon rail, which is where SQUASH bites hardest. The
# verifier states the sha it graded; a squash rewrites the branch head, so the
# only sha that can match is the MERGE COMMIT — `merge_commit_sha` in REST,
# `mergeCommit.oid` in gh's schema. If the reshape drops that mapping the row
# refuses done-graded-sha-not-the-merged-sha on a correctly graded close.
# ---------------------------------------------------------------------------
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
seed A-5; bind_pr A-5 'https://github.com/5dive-ai/5dive/pull/483'
run_done A-5 --result="verified on the merged tip. graded-sha: ${SQUASH_SHA}"
[[ $RC -eq 0 && "$(statusof A-5)" == "done" ]] \
  && ok_t 'T5 a graded-sha naming the SQUASH commit closes over the anon rail' \
  || bad_t 'T5 squash sha close' "rc=$RC slug=[$(slugof A-5)] out=$OUT"
[[ "$OUT" == *"the merged work IS the graded work"* ]] \
  && ok_t 'T5 the comparison RAN (not skipped as "could not be read")' \
  || bad_t 'T5 comparison ran' "out=$OUT"

# T5b — the negative of T5: a graded-sha matching NEITHER sha must still refuse.
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
seed A-6; bind_pr A-6 'https://github.com/5dive-ai/5dive/pull/483'
run_done A-6 --result='graded-sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
[[ $RC -eq $E_CONFLICT && "$(slugof A-6)" == "done-graded-sha-not-the-merged-sha" ]] \
  && ok_t 'T5b ANCHOR: a graded-sha that matches neither sha still refuses' \
  || bad_t 'T5b mismatch preserved' "rc=$RC slug=[$(slugof A-6)] out=$OUT"

# ---------------------------------------------------------------------------
# T6 — ANCHOR: ORDER. A caller that HOLDS a token must never touch the anon rail.
# The rail is last by construction; if it ever moved ahead of the token rail, a
# private-repo close that works today would start 404ing.
# ---------------------------------------------------------------------------
clear_fx; a_token
export GH_STUB_STATE="MERGED" GH_STUB_MERGED='"2026-08-05T08:10:00Z"'
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
seed A-7; bind_pr A-7 'https://github.com/5dive-ai/5dive/pull/483'
run_done A-7 --result='landed'
[[ $RC -eq 0 && "$(statusof A-7)" == "done" ]] \
  && ok_t 'T6 a token-holding caller still closes exactly as before' \
  || bad_t 'T6 token path' "rc=$RC out=$OUT"
[[ ! -s "$CURL_LOG" ]] \
  && ok_t 'T6 ANCHOR: and it never reached for the anon rail (tried LAST, not first)' \
  || bad_t 'T6 rail order' "curl=$(cat "$CURL_LOG")"

# ---------------------------------------------------------------------------
# T7 — THE DELIBERATE OMISSION. The fail-OPEN auto-detect scan lists OPEN PRs and
# reads an empty list as coverage. The anon rail does not serve that listing (it
# would page differently and turn "I did not see it" into "there is none"), so an
# unbound close must still report UNVERIFIED — and must say WHY in the language of
# a missing rail, not of partial coverage.
# ---------------------------------------------------------------------------
clear_fx; no_token
seed A-8
run_done A-8 --result='research note, nothing shipped'
[[ $RC -eq 0 && "$(statusof A-8)" == "done" ]] \
  && ok_t 'T7 an unbound close still proceeds (the auto-detect gate stays fail-open)' \
  || bad_t 'T7 fail-open' "rc=$RC out=$OUT"
[[ "$OUT" == *"UNVERIFIED"* && "$OUT" == *"no-gh-rail-for-listing"* ]] \
  && ok_t 'T7 and it is labelled a missing rail, not "partial-repo-scan-0-of-N"' \
  || bad_t 'T7 scan label' "out=$OUT"
! grep -q 'pulls?state=open' "$CURL_LOG" \
  && ok_t 'T7 the anon rail declined the open-PR listing rather than guessing at it' \
  || bad_t 'T7 open listing must not be served' "curl=$(cat "$CURL_LOG")"

# ---------------------------------------------------------------------------
# T8 — THE BUDGET. Unauthenticated api.github.com is 60 requests/hour PER IP, and
# this host shares one IP across the whole fleet — measured by exhausting it during
# this ticket's own end-to-end run. Exhaustion and a private repo are both "the rail
# could not answer", and collapsing them prints "this repo is private" for something
# that clears by itself inside an hour. That is DIVE-2318's defect wearing this
# ticket's clothes, so the refusal has to tell them apart.
# ---------------------------------------------------------------------------
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
export CURL_STUB_RATELIMIT=1 CURL_STUB_RESET=1785919621
seed A-9; bind_pr A-9 'https://github.com/5dive-ai/5dive/pull/483'
run_done A-9 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof A-9)" == "done-merge-gate-no-credential" ]] \
  && ok_t 'T8 an exhausted budget still REFUSES — it never guesses a verdict' \
  || bad_t 'T8 refuses' "rc=$RC slug=[$(slugof A-9)] out=$OUT"
[[ "$OUT" == *"RATE-LIMITED"* && "$OUT" == *"TRANSIENT"* ]] \
  && ok_t 'T8 and it names the budget, and says the condition CLEARS' \
  || bad_t 'T8 names the rate limit' "out=$OUT"
[[ "$OUT" != *"the repo is PRIVATE"* ]] \
  && ok_t 'T8 does NOT blame a private repo for a shared hourly budget' \
  || bad_t 'T8 must not mislabel as private' "out=$OUT"
# T8b — the CONTRAST arm. Same refusal, other cause: a 404 must say PRIVATE and must
# NOT say transient, or the two clauses are decorative rather than diagnostic.
clear_fx; no_token
seed A-10; bind_pr A-10 'https://github.com/lodar/5dive-api/pull/59'
run_done A-10 --result='landed'
[[ "$OUT" == *"PRIVATE"* && "$OUT" != *"RATE-LIMITED"* ]] \
  && ok_t 'T8b CONTRAST: a 404 says PRIVATE and does not claim a budget' \
  || bad_t 'T8b contrast' "out=$OUT"

# ---------------------------------------------------------------------------
# T9 — THE PRICE OF ONE CLOSE, pinned. Against a 60-request hourly bucket shared by
# every agent on this host, how many requests a close costs IS a design constraint,
# not an implementation detail: at 4 requests the fleet gets ~15 closes an hour. The
# obvious saving (the declared path reads the SAME PR for `.state` and again for
# `.mergedAt`) was tried and reverted — five sibling harnesses stub `gh` by matching
# the exact `-q` filter string, so merging the two queries breaks fixtures in files
# unrelated to this rail. So the cost is not optimised here; it is MEASURED here, and
# this arm fails if anything multiplies it.
# ---------------------------------------------------------------------------
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
seed A-11; bind_pr A-11 'https://github.com/5dive-ai/5dive/pull/483'
run_done A-11 --result="graded-sha: ${SQUASH_SHA}"
_n=$(grep -c 'pulls/483' "$CURL_LOG")
[[ $RC -eq 0 && "$_n" -le 4 ]] \
  && ok_t "T9 a graded close spends a pinned number of requests from the shared 60/hr budget (measured $_n)" \
  || bad_t 'T9 request count' "rc=$RC requests=$_n log=$(cat "$CURL_LOG")"

# ---------------------------------------------------------------------------
# T10 — THE BRANCH PATH. A row bound by a `Branch:` line in body prose, not by a
# delivery_ref, is the other fail-CLOSED shape and the common one on this fleet.
# The rail answers it with `pulls?state=closed&head=<owner>:<branch>` filtered to
# merged — squash-proof for the same reason as T1, because it reads `merged_at`
# rather than comparing shas against a branch whose commits no longer exist.
# ---------------------------------------------------------------------------
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_state_closed_per_page_100_head_5dive_ai_dive_2770_branch="[$(merged_pr)]"
seed B-1 'Branch: dive-2770-branch'
run_done B-1 --result='landed on that branch'
[[ $RC -eq 0 && "$(statusof B-1)" == "done" ]] \
  && ok_t 'T10 a Branch:-bound row closes over the anon rail too' \
  || bad_t 'T10 branch path' "rc=$RC slug=[$(slugof B-1)] out=$OUT"

# T10b — ANCHOR, and the discipline of the whole rail: a listing that matched
# NOTHING is NOT-REACHED, never "not merged". The anon rail cannot see a
# fork-headed PR and does not page a long closed list, so an empty array must
# decline rather than answer. If it ever answers, a perfectly-merged row gets a
# confident false refusal — the DIVE-2318 defect on a new rail.
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_state_closed_per_page_100_head_5dive_ai_dive_2770_empty="[]"
seed B-2 'Branch: dive-2770-empty'
run_done B-2 --result='landed'
# Both halves matter, and the first is the one that makes this an ANCHOR rather than
# a negative-only assertion: an empty listing must not CLOSE the row either. A test
# that only forbade the wrong refusal would pass on a false green.
[[ "$(statusof B-2)" != "done" ]] \
  && ok_t 'T10b an empty listing does not close the row (it is not a green either)' \
  || bad_t 'T10b must not false-close' "rc=$RC out=$OUT"
[[ "$(slugof B-2)" != "done-before-branch-merged" && "$OUT" != *"is NOT on main"* ]] \
  && ok_t 'T10b and it never asserts not-merged — an unseen PR is unreached, not absent' \
  || bad_t 'T10b empty listing must not become a verdict' "slug=[$(slugof B-2)] out=$OUT"

# ---------------------------------------------------------------------------
# T11 — THE ROLLUP, which is where the rail spends most of its budget. gh returns
# statusCheckRollup inside `pr view`; anonymously it is TWO more requests, because
# GitHub keeps Actions check-runs and legacy commit statuses in different places
# and gh merges them for you. Leaving the key absent would render NONE — "no checks
# reported" for a question nobody asked — so DIVE-1935's red-merge guard has to see
# a real FAILURE come back through the reshape.
# ---------------------------------------------------------------------------
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
export CURL_FX_repos_5dive_ai_5dive_commits_${HEAD_SHA}_check_runs='{"check_runs":[{"name":"test","conclusion":"failure","completed_at":"2026-08-05T08:00:00Z"}]}'
export CURL_FX_repos_5dive_ai_5dive_commits_${HEAD_SHA}_status='{"statuses":[]}'
seed C-1; bind_pr C-1 'https://github.com/5dive-ai/5dive/pull/483'
run_done C-1 --result='landed'
[[ $RC -eq $E_CONFLICT && "$(slugof C-1)" == "done-after-red-merge" ]] \
  && ok_t 'T11 a RED merged PR is caught over the anon rail (the rollup is really read)' \
  || bad_t 'T11 red merge' "rc=$RC slug=[$(slugof C-1)] out=$OUT"
grep -q 'check-runs' "$CURL_LOG" && grep -q "commits/${HEAD_SHA}/status" "$CURL_LOG" \
  && ok_t 'T11 and BOTH check surfaces were asked — Actions runs and commit statuses' \
  || bad_t 'T11 both surfaces' "curl=$(cat "$CURL_LOG")"

# T11b — ANCHOR: a GREEN merged PR must still close. Without this, T11 is satisfiable
# by a rollup that reports FAILURE for everything.
clear_fx; no_token
export CURL_FX_repos_5dive_ai_5dive_pulls_483="$(merged_pr)"
export CURL_FX_repos_5dive_ai_5dive_commits_${HEAD_SHA}_check_runs='{"check_runs":[{"name":"test","conclusion":"success","completed_at":"2026-08-05T08:00:00Z"}]}'
export CURL_FX_repos_5dive_ai_5dive_commits_${HEAD_SHA}_status='{"statuses":[]}'
seed C-2; bind_pr C-2 'https://github.com/5dive-ai/5dive/pull/483'
run_done C-2 --result='landed'
[[ $RC -eq 0 && "$(statusof C-2)" == "done" ]] \
  && ok_t 'T11b ANCHOR: a GREEN merged PR still closes (the rollup is not a blanket red)' \
  || bad_t 'T11b green merge' "rc=$RC slug=[$(slugof C-2)] out=$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
