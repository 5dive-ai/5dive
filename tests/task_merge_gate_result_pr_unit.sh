#!/usr/bin/env bash
# DIVE-1935 isolated unit harness. DIVE-1922 reached status=done while its PR was
# OPEN, unmerged AND red on its own new unit test — both declared bindings were
# empty (no delivery_ref, no 'Branch:' line) and the DIVE-1835 repo-wide scan
# fail-opened silently because the closing agent had no resolvable gh token.
# What is pinned here:
#   1. a PR number the maker merely TYPED into --result blocks the close (the
#      DIVE-1922 shape, reproduced from its real result text),
#   2. a MERGED-but-RED PR blocks it too (merged != green),
#   3. prose safety: a merged reference, a CLOSED-unmerged reference and an
#      unresolvable '#12' all still CLOSE (loudly, in the unresolvable case),
#   4. the unverified scan is ANNOUNCED instead of passing as verified-clean,
#   5. --force-merge-gate still escapes, audited.
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_result_pr_unit.sh  (no root, no network).
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
TMP="$(mktemp -d /tmp/gate-resultpr-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- stub gh: `pr view` answers per-PR fixtures from GH_STUB_PR_<n>, `pr list`
# answers the repo-wide scan, `auth token` answers token resolution. A PR with no
# fixture EXITS NON-ZERO — that is the real unresolvable case (not a PR / no
# access), and the gate must treat it as unverified rather than clean.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0; fi
expr='.'; ref=""
if [[ "$1" == "pr" && "$2" == "view" ]]; then ref="$3"; fi
a=("$@"); i=0
while [[ $i -lt ${#a[@]} ]]; do case "${a[$i]}" in -q) expr="${a[$((i+1))]}"; i=$((i+2));; -q*) expr="${a[$i]#-q}"; i=$((i+1));; *) i=$((i+1));; esac; done
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  ref="${ref##*/}"                       # tolerate a full pull URL
  # DIVE-1955: the stub is REPO-AWARE. A PR number exists in a specific repo, not
  # in the abstract — an unaware stub answers every `--repo` identically, which
  # makes every bare number look like a three-way collision and is exactly the
  # confusion the gate now refuses to paper over. `GH_STUB_PR_<n>` means "in the
  # CLI repo (and via a bare URL)"; `GH_STUB_PR_<REPO>_<n>` targets one repo.
  repo=""; j=0
  while [[ $j -lt ${#a[@]} ]]; do [[ "${a[$j]}" == "--repo" ]] && { repo="${a[$((j+1))]}"; break; }; j=$((j+1)); done
  key="${repo##*/}"; key="${key//[^A-Za-z0-9]/_}"
  json=""
  if [[ -n "$key" ]]; then fx="GH_STUB_PR_${key}_${ref}"; json="${!fx:-}"; fi
  if [[ -z "$json" && ( -z "$repo" || "$repo" == "5dive-ai/5dive" ) ]]; then
    fx="GH_STUB_PR_${ref}"; json="${!fx:-}"
  fi
  [[ -n "$json" ]] || exit 1             # no fixture in THIS repo => unresolvable
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  [[ -n "${GH_STUB_LIST_FAIL:-}" ]] && exit 1
  printf '%s' "${GH_STUB_PRLIST:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

# --- stub sudo: MUST be stubbed for the whole run, not per-test. The token
# resolver's last resort is `sudo -n -u claude gh auth token`, and real sudo
# resets PATH to secure_path — so an unstubbed harness silently reached the HOST's
# real gh login and the no-token case could never be exercised (it passed by
# borrowing a token the fleet doesn't have). Fails closed unless a test opts in.
cat >"$TMP/bin/sudo" <<SUDOSTUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/sudo.calls"
if [[ -n "\${SUDO_STUB_TOKEN:-}" && "\$*" == *"-u claude gh auth token"* ]]; then
  printf '%s\n' "\$SUDO_STUB_TOKEN"; exit 0
fi
exit 1
SUDOSTUB
chmod +x "$TMP/bin/sudo"
: >"$TMP/sudo.calls"

# --- stub id: DIVE-2484. The token resolver's last branch is guarded on
# `id -un != claude` (it must not borrow a credential from the account it is
# already running as). This harness stubbed `gh` and `sudo` but NOT `id`, so that
# arm inherited the HOST's identity and graded the running user rather than the
# code: red as `claude`, green as anyone else. Since this repo's own convention is
# to run local tests via `sudo -u claude`, the conventional local run was the red
# one, while CI — where no `claude` account exists — was permanently green. Same
# tree, two verdicts, and neither was about the tree. Opt-in override so a test
# CONSTRUCTS the identity its scenario needs; everything else passes through to
# the real binary, which keeps the other arms reading the true host.
REAL_ID=$(command -v id)
cat >"$TMP/bin/id" <<IDSTUB
#!/usr/bin/env bash
if [[ -n "\${ID_STUB_UN:-}" && "\$*" == "-un" ]]; then
  printf '%s\n' "\$ID_STUB_UN"; exit 0
fi
exec $REAL_ID "\$@"
IDSTUB
chmod +x "$TMP/bin/id"

export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_push.sh cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
_task_close_notify() { :; }
# DIVE-2010: audit_log for task-store events is now fenced on store identity
# (_task_human_send_allowed). Declare this fixture store PROD for the purposes
# of that fence so the audit-content assertions below still exercise the real
# call, exactly as tests/gate_telemetry_fence_unit.sh's on-store case does.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"
export GH_STUB_PRLIST='[]'

# PR fixtures. 156 = the DIVE-1922 shape (OPEN + red). 150 = merged, green.
# 149 = merged but RED. 148 = CLOSED unmerged (abandoned). 12 has NO fixture.
export GH_STUB_PR_156='{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"conclusion":"FAILURE"}]}'
export GH_STUB_PR_150='{"state":"MERGED","mergedAt":"2026-07-25T02:52:00Z","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
export GH_STUB_PR_149='{"state":"MERGED","mergedAt":"2026-07-25T02:00:00Z","statusCheckRollup":[{"conclusion":"FAILURE"}]}'
export GH_STUB_PR_148='{"state":"CLOSED","mergedAt":null,"statusCheckRollup":[]}'

seed()     { db "DELETE FROM tasks WHERE ident='$1';
                 INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                   VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# run `task done` capturing stdout+stderr and the exit code.
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }

# --- 1. the reference extractor: NAMED equivalence fixtures --------------------
# The extractor was rewritten from PCRE to POSIX ERE to delete a silent-empty
# dependency on `grep -P`. That rewrite gave up \K, the lookbehind AND the
# lookahead in one move — which is precisely the machinery that kept "payer #4" and
# a column "#25" out. The canary (_gate_pr_refs_engine_ok) only proves the parser
# RAN; these fixtures prove it is still CORRECT, and name which case died if a
# future edit breaks one. Every case below is one Marcus asked to see pinned.
extractor_case() { # <name> <expected-newline-joined> <text>
  local name="$1" want="$2" text="$3" got
  got=$(_gate_pr_refs_from_text "$text")
  [[ "$got" == "$want" ]] && ok_t "extractor $name" \
                          || bad_t "extractor $name" "want [$want] got [$got]"
}
# POSITIVES — each must yield the PR number.
extractor_case 'positive: "Merged as PR #156" (the real DIVE-1922 result text)' \
  '156' 'SHIPPED and VERIFIED on the rolled binary. Merged as PR #156 into v0.15.4.'
extractor_case 'positive: a full https pull URL' \
  '150' 'delivery: https://github.com/5dive-ai/5dive/pull/150 landed'
extractor_case 'positive: "PRs 156" (plural, no hash)' \
  '156' 'both PRs 156 are in'
extractor_case 'positive: "pull request #156"' \
  '156' 'opened pull request #156 against main'
# NEGATIVES — each must yield NOTHING. These are the false-positive classes the
# retrospective sweep surfaced on the real board.
extractor_case 'negative: "arms-length payer #4" (prose count, not a PR)' \
  '' 'arms-length payer #4 converted this week'
extractor_case 'negative: a column labelled "#25"' \
  '' 'landing_path is column #25 in the sheet'
extractor_case 'negative: a markdown heading with no digits' \
  '' '# Heading
## Another heading'
extractor_case 'negative: a 7-plus digit id' \
  '' 'telegram user PR 1234567 and PR #12345678'
extractor_case 'negative: a number glued to alnum on either side' \
  '' 'ref PR abc#12x and PR 12ab and xPR 55'
# ordering + dedup (url first, then PR-context refs, each once).
extractor_case 'ordering: url refs precede hash refs, deduped' \
  '150
156' 'Merged as PR #156, see https://github.com/5dive-ai/5dive/pull/150 and PR #156 again'
# the canary itself must pass on this host, or every empty result above is vacuous.
_gate_pr_refs_engine_ok && ok_t "canary: the ref parser demonstrably RUNS on this host" \
                        || bad_t "canary: ref parser broken" "engine self-test failed"

# --- 2. THE DIVE-1922 REGRESSION: open PR named only in the result -------------
seed FIX-1
run_done FIX-1 --result='SHIPPED and VERIFIED on the rolled binary. Merged as PR #156 into v0.15.4.'
if [[ $RC -ne 0 && "$(statusof FIX-1)" == "in_progress" && "$OUT" == *"#156"*"OPEN"* ]]; then
  ok_t "open PR named ONLY in --result refuses the close (the DIVE-1922 shape)"
else
  bad_t "open PR in --result must refuse" "rc=$RC status=$(statusof FIX-1) out=$OUT"
fi
# the refusal is recorded as a policy refusal (the DIVE-1922 metric's own source)
n=$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy='done-with-open-pr-in-result';")
[[ "$n" == "1" ]] && ok_t "refusal is recorded in policy_refusals" \
                  || bad_t "refusal recorded" "count=$n"

# --- 3. same shape via the BODY, and via a full pull URL ----------------------
seed FIX-2 'Delivery: https://github.com/5dive-ai/5dive/pull/156'
run_done FIX-2 --result='done'
[[ $RC -ne 0 && "$(statusof FIX-2)" == "in_progress" ]] \
  && ok_t "open PR named in the BODY as a full url refuses the close" \
  || bad_t "open PR url in body must refuse" "rc=$RC status=$(statusof FIX-2)"

# --- 4. merged BUT RED is refused too (merged != green) -----------------------
seed FIX-3
run_done FIX-3 --result='landed in PR #149'
[[ $RC -ne 0 && "$OUT" == *RED* ]] \
  && ok_t "merged-but-RED PR refuses the close" \
  || bad_t "merged-but-red must refuse" "rc=$RC out=$OUT"

# --- 5. prose safety: these must all CLOSE -----------------------------------
# DIVE-1965 re-phrased three of these to assert a DELIVERY ("merged as", "landed
# in"). They used to read as citations ("same defect class as PR #150", "reported in
# PR #12"), which the gate now deliberately does not judge at all — so as written
# they would have passed for the wrong reason and stopped covering the MERGED+green,
# CLOSED-unmerged and unresolvable branches they exist for. The citation shapes are
# not lost: they are the subject of tests/task_merge_gate_delivered_vs_cited_unit.sh.
seed OK-1
run_done OK-1 --result='Merged as PR #150, green.'
[[ $RC -eq 0 && "$(statusof OK-1)" == "done" ]] \
  && ok_t "a MERGED+green reference closes normally" \
  || bad_t "merged reference must close" "rc=$RC status=$(statusof OK-1) out=$OUT"

seed OK-2
run_done OK-2 --result='Landed in PR #148, after the earlier attempt was abandoned.'
[[ $RC -eq 0 && "$(statusof OK-2)" == "done" ]] \
  && ok_t "a CLOSED-unmerged reference never makes a task unclosable (DIVE-1835 rule)" \
  || bad_t "closed-unmerged reference must close" "rc=$RC status=$(statusof OK-2) out=$OUT"

seed OK-3
run_done OK-3 --result='Landed in PR #12.'
if [[ $RC -eq 0 && "$(statusof OK-3)" == "done" && "$OUT" == *UNVERIFIED* ]]; then
  ok_t "an unresolvable reference closes but says UNVERIFIED out loud"
else
  bad_t "unresolvable reference: close + announce" "rc=$RC status=$(statusof OK-3) out=$OUT"
fi

seed OK-4
run_done OK-4 --result='No PR here at all.'
[[ $RC -eq 0 && "$(statusof OK-4)" == "done" ]] \
  && ok_t "a result naming no PR closes (zero regression on ordinary closes)" \
  || bad_t "no-PR result must close" "rc=$RC out=$OUT"

# --- 6. the scan that COULD NOT RUN is announced, not silent ------------------
: >"$AUDIT_CALLS"
seed LOUD-1
GH_STUB_LIST_FAIL=1 run_done LOUD-1 --result='no pr named'
if [[ $RC -eq 0 && "$OUT" == *"could not query GitHub"* ]] && grep -q "merge-gate-unverified" "$AUDIT_CALLS"; then
  ok_t "a scan that could not run is announced + audited (not silently 'clean')"
else
  bad_t "unverified scan must be loud + audited" "rc=$RC out=$OUT audit=$(cat "$AUDIT_CALLS")"
fi
: >"$AUDIT_CALLS"
seed LOUD-2
GH_STUB_AUTH_TOKEN="" run_done LOUD-2 --result='no pr named'
[[ "$OUT" == *"no-gh-token"* ]] \
  && ok_t "a missing gh token is named as the reason (the DIVE-1935 root cause)" \
  || bad_t "no-token reason must be named" "out=$OUT"

# --- 7. the audited escape still works ---------------------------------------
: >"$AUDIT_CALLS"
seed ESC-1
run_done ESC-1 --force-merge-gate --result='Merged as PR #156.'
if [[ $RC -eq 0 && "$(statusof ESC-1)" == "done" ]] && grep -q "force-merge-gate" "$AUDIT_CALLS"; then
  ok_t "--force-merge-gate escapes the result-PR gate, audited"
else
  bad_t "--force-merge-gate must escape + audit" "rc=$RC status=$(statusof ESC-1) audit=$(cat "$AUDIT_CALLS")"
fi

# --- 8. the token resolver reaches `claude` for a NON-root caller -------------
# The whole gate was inert for the agent fleet because this fallback was gated on
# `id -un == root`; every agent-* closes tasks as itself, unauthed.
#
# DIVE-2484: the two arms below are a DIFFERENTIAL PAIR. They hold every variable
# equal and change only the caller's identity, because the identity is the whole
# subject: the fallback must fire for an agent-* caller and must NOT fire for
# `claude` itself. `ID_STUB_UN` is what makes each one construct its own
# precondition — before it existed this arm read the host's identity and its
# verdict tracked whoever ran it.
: >"$TMP/sudo.calls"
got=$(ID_STUB_UN="agent-fixture" GH_TOKEN="" GITHUB_TOKEN="" SUDO_USER="" GH_STUB_AUTH_TOKEN="" \
      SUDO_STUB_TOKEN="claude-token" _gate_gh_token)
if [[ "$got" == "claude-token" ]] && grep -q -- "-u claude gh auth token" "$TMP/sudo.calls"; then
  ok_t "a non-root NON-claude caller resolves the gh token via claude (gate is live for agents)"
else
  bad_t "non-root token resolution via claude" "got=[$got] sudo=$(cat "$TMP/sudo.calls")"
fi

# The negative half, and the case this suite never covered at all: when the caller
# IS `claude`, the fallback must not borrow from the account it is already running
# as. Empty resolution is the CORRECT answer here — `claude`'s own credential is
# the arm above this one's business (`gh auth token`, line ~1257), not this branch.
# Liveness for the negative: the arm directly above differs from this one ONLY in
# ID_STUB_UN and DOES record a sudo call, so a silent sudo.calls here is a real
# absence and not a dead stub.
: >"$TMP/sudo.calls"
got=$(ID_STUB_UN="claude" GH_TOKEN="" GITHUB_TOKEN="" SUDO_USER="" GH_STUB_AUTH_TOKEN="" \
      SUDO_STUB_TOKEN="claude-token" _gate_gh_token)
if [[ -z "$got" ]] && ! grep -q -- "-u claude gh auth token" "$TMP/sudo.calls"; then
  ok_t "a caller who IS claude never borrows a token from itself"
else
  bad_t "claude caller must not self-borrow" "got=[$got] sudo=$(cat "$TMP/sudo.calls")"
fi

# ...and that refusal to self-borrow costs `claude` nothing, because its OWN login
# resolves one branch earlier. This is the arm that proves the empty result above
# is a scoped no-op rather than a broken resolver for the claude account.
: >"$TMP/sudo.calls"
got=$(ID_STUB_UN="claude" GH_TOKEN="" GITHUB_TOKEN="" SUDO_USER="" GH_STUB_AUTH_TOKEN="own-login-tok" \
      SUDO_STUB_TOKEN="claude-token" _gate_gh_token)
if [[ "$got" == "own-login-tok" ]] && ! grep -q -- "-u claude gh auth token" "$TMP/sudo.calls"; then
  ok_t "claude resolves via its OWN gh login, not the borrow branch"
else
  bad_t "claude own-login resolution" "got=[$got] sudo=$(cat "$TMP/sudo.calls")"
fi
# an explicit env token still wins, and a real SUDO_USER is still tried first.
got=$(GH_TOKEN="env-tok" SUDO_STUB_TOKEN="claude-token" _gate_gh_token)
[[ "$got" == "env-tok" ]] && ok_t "an explicit GH_TOKEN still takes precedence" \
                          || bad_t "env token precedence" "got=[$got]"

# --- 9. declared-binding paths are untouched ---------------------------------
seed DECL-1
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/156' WHERE ident='DECL-1';"
run_done DECL-1 --result='x'
[[ $RC -ne 0 && "$(statusof DECL-1)" == "in_progress" ]] \
  && ok_t "declared delivery_ref on an unmerged PR still refuses (DIVE-1830 intact)" \
  || bad_t "declared unmerged must refuse" "rc=$RC status=$(statusof DECL-1)"
seed DECL-2
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/149' WHERE ident='DECL-2';"
run_done DECL-2 --result='x'
[[ $RC -ne 0 && "$OUT" == *RED* ]] \
  && ok_t "declared delivery_ref that merged RED now refuses (DIVE-1935 addition)" \
  || bad_t "declared merged-red must refuse" "rc=$RC out=$OUT"
seed DECL-3
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/150' WHERE ident='DECL-3';"
run_done DECL-3 --result='x'
[[ $RC -eq 0 && "$(statusof DECL-3)" == "done" ]] \
  && ok_t "declared delivery_ref merged + green closes" \
  || bad_t "declared merged-green must close" "rc=$RC status=$(statusof DECL-3) out=$OUT"

# --- 9b. the two red-merge causes are DISTINGUISHABLE in policy_refusals ------
# Both sites refuse a red merge, but for different reasons: one on the PR bound as
# delivery_ref, one on a PR merely NAMED in the result/body. A shared slug would make
# the series unable to answer WHICH binding caught it — and policy_refusals is the
# exact instrumentation DIVE-1922 was about, so a name preserving "something happened"
# but not "what" is a smaller instance of this ticket's own defect. It shipped that way
# and tests/policy_refusals_unit.sh caught it by asserting slug uniqueness STRUCTURALLY.
# That suite proves the names differ; this one proves the right one differs, so a future
# edit cannot satisfy uniqueness by renaming the wrong site.
db "DELETE FROM policy_refusals;"
seed RED-1; db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/149' WHERE ident='RED-1';"
run_done RED-1 --result='x'
seed RED-2
run_done RED-2 --result='landed in PR #149'
declared=$(db  "SELECT COUNT(*) FROM policy_refusals WHERE policy='done-after-red-merge'       AND ident='RED-1';")
named=$(db     "SELECT COUNT(*) FROM policy_refusals WHERE policy='done-after-named-red-merge' AND ident='RED-2';")
crosstalk=$(db "SELECT COUNT(*) FROM policy_refusals
                  WHERE (policy='done-after-red-merge'       AND ident='RED-2')
                     OR (policy='done-after-named-red-merge' AND ident='RED-1');")
if [[ "$declared" == "1" && "$named" == "1" && "$crosstalk" == "0" ]]; then
  ok_t "the delivery_ref and prose red-merge causes record DISTINCT slugs, each on its own site"
else
  bad_t "red-merge slugs must be distinct per cause" "declared=$declared named=$named crosstalk=$crosstalk"
fi

# --- 10. cancel is never gated ----------------------------------------------
seed CAN-1
out=$(cmd_task_cancel CAN-1 --result='abandoning, #156 stays open' 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof CAN-1)" == "cancelled" ]] \
  && ok_t "task cancel is never merge-gated (the documented way out)" \
  || bad_t "cancel must not be gated" "rc=$rc status=$(statusof CAN-1) out=$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
