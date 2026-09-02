#!/usr/bin/env bash
# DIVE-3823 — A VERIFIER CAN BE THE ONLY SEAT ALLOWED TO CLOSE A ROW AND THE ONLY
# SEAT UNABLE TO. The merge gate now reads the proof its own refusal already asks for.
#
# THE DEADLOCK THIS GRADES. Two rails, each correct:
#   1. DIVE-477/DIVE-2007 — only the verifier of record may close a live delivered
#      loop. Purely actor-based.
#   2. The merge gate — the closer must be able to READ the delivery PR, or it fails
#      closed, correctly: an unreadable PR and an unmerged one are indistinguishable.
# On a PRIVATE repo they intersect on a seat that can satisfy neither. `agent-vesper`
# (measured 2026-08-30): no GH_TOKEN/GITHUB_TOKEN, no non-root SUDO_USER, own gh token
# empty, `sudo -u claude` refused by scoped sudoers, no `_gh_do` grant — and that last
# absence is CORRECT on a grader, not a provisioning fault. Anonymous rail 404s.
# `--force-merge-gate` does not reach it: that flag escapes a gate that RAN and
# disagreed, never one that asked nothing. DIVE-3808 merged at 2033057e and no seat
# could close it.
#
# WHAT THE ARMS ARE FOR. The acceptance is only safe because it is NARROW, and most
# of the arms below grade the narrowness rather than the fix:
#   T2  a CREDENTIALED caller never consults the proof — it takes the API path, so a
#       recorded attestation can never substitute for an answer the gate could get
#   T3  a proof whose ref is not the row's CURRENT binding is INERT (re-point and it
#       stops counting), and the close refuses exactly as before
#   T5  a FAILING proof command records NOTHING — a failing proof is evidence the
#       delivery did not land, and recording it would hand the gate its opposite
#   T6  `--merge-proof` without a command is refused: prose asserts a merge, it does
#       not prove one (DIVE-2832's distinction, which this must not erode)
#   T7  `--merge-proof` on a row with no delivery binding is refused — there is
#       nothing for the evidence to be ABOUT
#   T8  the close is LOUD and AUDITED: it names who proved it, with what, and when
#   T9  ITERATION 2, and the arm the first iteration could not have: with the
#       ANONYMOUS rail LIVE over a PUBLIC unmerged PR the gate refuses on the API
#       ANSWER, and it went and asked for it. Iteration 1 scoped the rail on what the
#       caller HOLDS (`! _gate_gh_credentialed`), and the anon rail holds nothing
#       either — so a recorded proof pre-empted a query that would have answered.
#       quinn measured it: an OPEN public PR closed on `--cmd=true`, curl called ZERO
#       times. Every arm above runs under FIVE_GATE_NO_ANON=1, which is exactly why
#       none of them saw it.
#   T9b the same live rail over a PRIVATE repo (404) still closes on the proof —
#       the other direction, and the reason the predicate ASKS rather than testing
#       `_gate_gh_reachable`: that is true wherever curl and jq merely exist, i.e.
#       on every seat, so it would make this rail dead code on DIVE-3808 itself.
#
# MUTATION GRADE — RUN against this worktree's src/, not predicted (2026-08-30;
# each mutant from 37/0 clean, and the arm names are the ones that ACTUALLY went red):
#   * gate never consults the proof (`(( _mg_proof_ok ))` -> `(( 0 ))`)  -> 30/7:
#     both T1 close arms and four of T8. T1b/T2/T3/T5/T6/T7 stay GREEN, and that is
#     the point of writing them — they grade the NARROWNESS, so a fix that does
#     nothing must not be able to buy their greens.
#   * `_gate_merge_proof_ok` drops the ref-equality test               -> 33/4: T0's
#     different-ref arm and all three T3 arms. A four-arm kill on one predicate line.
#   * a FAILING proof is recorded anyway (`rc == 0` -> always)         -> 34/3: all
#     of T5. That is the direction arm: without it the flag would record evidence
#     that the delivery did NOT land as evidence that it did.
#
# ITERATION 2 MUTANTS — also RUN, each from 49/0 clean (2026-08-30):
#   * the predicate reverts to iteration 1 (`! _gate_gh_credentialed` alone)
#                                                                     -> 42/7: all
#     five T9 arms plus two of T9b. This is the graded reject reproduced as a test.
#   * the predicate becomes quinn's literal suggestion, `! _gate_gh_reachable`
#                                                                     -> 47/2: both
#     T9b close arms. Written down because it is the fix that LOOKS right: it closes
#     T9, and it silently kills the feature on the private-repo row the ticket is
#     about, since reachability is true wherever curl exists.
#   * gate never consults the proof (`(( _mg_proof_ok ))` -> `(( 0 ))`) -> 39/10:
#     T1, T8 and T9b. T9 stays GREEN under it — it grades the narrowness.
#
# Isolation matches the sibling gate harnesses (task_merge_gate_anon_rail_unit.sh):
# src/ sourced into a throwaway STATE_DIR — the live tasks.db is NEVER touched — and
# gh/sudo/curl are stubbed on PATH, so this file makes no network call and needs no
# root.
# TIER: nightly — 6.7s measured on the 5dive dev host at iteration 2 (three
# consecutive runs: 6.66/6.40/6.66s; it was 4.9s at 12 fewer arms): does not fit the
# 300s PR core, and its closest sibling
# task_merge_gate_deploy_note_unit.sh was demoted at 5.8s for the same reason. The
# cost is real `task done` closes at ~0.5s each. A PR that touches this file still
# runs it — the changed-harnesses job ignores tier.
# Run: bash tests/task_merge_gate_recorded_proof_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# MUST sit AFTER grading_tree.sh — it sources lib/env_isolation.sh, which clears
# inherited FIVE_* knobs, so an export above this line is silently wiped.
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-proof-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# --- stub sudo: kills BOTH the `sudo -n -u claude gh auth token` last resort and the
# `sudo -n -l ... _gh_do` bot-rail probe. That is the verifier seat, exactly.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"

# --- stub gh. `auth token` honours GH_STUB_AUTH_TOKEN; `pr view` answers only when
# GH_STUB_STATE is set (T2's credentialed arm). Everything else exits 1.
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
  # DIVE-3888: a LIVE credential that cannot see the repository. This is not the
  # same as "no credential" and not the same as a bare failure: gh exits non-zero
  # and says so on STDERR, which is the string _gate_gh_blind_err keys the
  # DIVE-3496 escalation on. Reproduced verbatim from agent-quinn's own uid,
  # 2026-09-02, against lodar/5dive-api.
  if [[ "${GH_STUB_BLIND:-0}" == "1" ]]; then
    printf 'GraphQL: Could not resolve to a Repository with the name %s. (repository)\n' \
      "'lodar/5dive-frontend'" >&2
    exit 1
  fi
  [[ -n "${GH_STUB_STATE:-}" ]] || exit 1
  printf '%s' "{\"state\":\"${GH_STUB_STATE}\",\"mergedAt\":${GH_STUB_MERGED:-null},\"statusCheckRollup\":[],\"headRefOid\":\"${GH_STUB_HEAD:-}\",\"mergeCommit\":null}" \
    | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/gh"

# --- stub curl: the anon rail's only transport, and the ONLY thing that can reach
# api.github.com from any arm in this file. OFF by default (rc 1) so T0-T8 keep
# grading the seat they were written for; CURL_STUB_ON=1 turns it into a serving
# transport for T9, which needs the anon rail LIVE. It answers exactly one path
# (`repos/<slug>/pulls/<num>` for CURL_STUB_PR) and 404s everything else, because a
# stub that serves every URL would let an unrelated probe below the gate look
# answered and quietly re-open the fail-open this arm exists to close.
cat >"$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
[[ "${CURL_STUB_ON:-0}" == "1" ]] || exit 1
out=""; hdr=""; url=""; a=("$@"); i=0
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -o) out="${a[$((i+1))]}"; i=$((i+2)) ;;
    -D) hdr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -H|-w) i=$((i+2)) ;;
    -*) i=$((i+1)) ;;
    *)  url="${a[$i]}"; i=$((i+1)) ;;
  esac
done
printf '%s\n' "$url" >>"${CURL_ARGS_LOG:-/dev/null}"
code=404; body=''
if [[ -n "${CURL_STUB_PR:-}" && "$url" == *"${CURL_STUB_PR}" ]]; then
  code=200; body="${CURL_STUB_BODY:-}"
fi
[[ -n "$out" ]] && printf '%s' "$body" >"$out"
[[ -n "$hdr" ]] && printf 'HTTP/2 %s\n' "$code" >"$hdr"
printf '%s' "$code"
[[ "$code" == 200 ]] || exit 0
exit 0
CURL
chmod +x "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"
export CURL_ARGS_LOG="$TMP/curl.args"; : >"$CURL_ARGS_LOG"

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
chk()   { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
sub()   { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "want substring [$3] in: $2"; fi; }
nsub()  { if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "unwanted substring [$3] in: $2"; fi; }

tasks_db_init
_tasks_db_migrate
task_need_notify() { :; }
audit_log() { :; }

PRIVATE_PR='https://github.com/lodar/5dive-frontend/pull/12'
OTHER_PR='https://github.com/lodar/5dive-frontend/pull/13'

seed()      { db "INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                    VALUES ('$1','t','','in_progress','main','main');"; }
bind_pr()   { db "UPDATE tasks SET delivery_ref='$2', delivered_at=datetime('now') WHERE ident='$1';"; }
statusof()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
slugof()    { db "SELECT COALESCE(policy,'') FROM policy_refusals WHERE ident='$1' ORDER BY id DESC LIMIT 1;"; }
proofof()   { db "SELECT COALESCE(merge_proof_at,'')||'|'||COALESCE(merge_proof_ref,'')||'|'||COALESCE(merge_proof_by,'')||'|'||COALESCE(merge_proof_cmd,'') FROM tasks WHERE ident='$1';"; }
run_done()  { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
run_verify(){ VOUT=$(cmd_task_verify "$@" 2>&1); VRC=$?; }

# The verifier seat: no token anywhere, no runas, no bot grant.
no_rail()   { unset GH_TOKEN GITHUB_TOKEN GH_STUB_STATE GH_STUB_MERGED
              export SUDO_USER=""; export GH_STUB_AUTH_TOKEN=""
              : >"$GH_ARGS_LOG"; : >"$CURL_ARGS_LOG"; }
a_token()   { unset GH_TOKEN GITHUB_TOKEN; export SUDO_USER=""
              export GH_STUB_AUTH_TOKEN="tok-3823"; : >"$GH_ARGS_LOG"; }
# DIVE-3888 — THE SEAT THIS TICKET IS ABOUT. A verifier holding a GitHub App
# installation token that is LIVE (arm 3 of _gate_gh_token resolves it) and BLIND to
# the target repo. sudo is stubbed rc 1 above, so the machine-account rail is not
# permitted — which is the real agent-quinn, whose sudoers is a five-command
# allowlist with no `_gh_do`.
blind_tok() { unset GH_TOKEN GITHUB_TOKEN GH_STUB_STATE GH_STUB_MERGED
              export SUDO_USER=""; export GH_STUB_AUTH_TOKEN="ghs_blind-3888"
              export GH_STUB_BLIND=1
              : >"$GH_ARGS_LOG"; : >"$CURL_ARGS_LOG"; }

# ---------------------------------------------------------------------------
# T0 — THE PREDICATE, on its own. Pure string logic: no db, no network, so it
# cannot fail open through a query that did not run.
# ---------------------------------------------------------------------------
_gate_merge_proof_ok '2026-08-30T10:00:00' "$PRIVATE_PR" "$PRIVATE_PR"
chk "T0 a proof against the CURRENT binding is accepted" "$?" "0"
_gate_merge_proof_ok '2026-08-30T10:00:00' "$OTHER_PR" "$PRIVATE_PR"
chk "T0 a proof against a DIFFERENT ref is not"          "$?" "1"
_gate_merge_proof_ok '' "$PRIVATE_PR" "$PRIVATE_PR"
chk "T0 no timestamp means no proof was ever run"        "$?" "1"
_gate_merge_proof_ok '2026-08-30T10:00:00' '' "$PRIVATE_PR"
chk "T0 a proof bound to nothing is not a proof"         "$?" "1"
_gate_merge_proof_ok '2026-08-30T10:00:00' "$PRIVATE_PR" ''
chk "T0 an unbound row cannot be satisfied by any proof" "$?" "1"

# ---------------------------------------------------------------------------
# T1 — THE TICKET. No rail of any kind, a private PR, a recorded proof. The
# close must SUCCEED, on evidence, with no credential anywhere.
# ---------------------------------------------------------------------------
no_rail
seed A-1; bind_pr A-1 "$PRIVATE_PR"
run_verify A-1 --no-done --merge-proof --cmd='true'
chk "T1 the proving run passes"  "$VRC" "0"
PROOF=$(proofof A-1)
sub "T1 the proof is stamped against the binding" "$PROOF" "|$PRIVATE_PR|"
sub "T1 and records the command text"             "$PROOF" "|true"
run_done A-1 --result='landed at 2033057e'
chk "T1 the close succeeds"          "$RC" "0"
chk "T1 and the row is done"         "$(statusof A-1)" "done"

# ---------------------------------------------------------------------------
# T1b — THE CONTROL. Byte-identical seat and binding, NO proof recorded. This is
# the deadlock itself, and it must still refuse: the acceptance is what changed,
# not the gate.
# ---------------------------------------------------------------------------
no_rail
seed B-1; bind_pr B-1 "$PRIVATE_PR"
run_done B-1 --result='landed'
chk "T1b no proof: the close still refuses"    "$((RC != 0))" "1"
chk "T1b and the row stays open"               "$(statusof B-1)" "in_progress"
chk "T1b on the unchanged no-credential slug"  "$(slugof B-1)" "done-merge-gate-no-credential"
sub "T1b whose text now names the new exit"    "$OUT" "--merge-proof"

# ---------------------------------------------------------------------------
# T2 — NARROWNESS: A CREDENTIALED CALLER NEVER CONSULTS THE PROOF. A recorded
# attestation must not substitute for an answer the gate could have gotten, or
# every credentialed close silently starts trusting words over a measurement.
# ---------------------------------------------------------------------------
a_token; export GH_STUB_STATE=OPEN GH_STUB_MERGED=null
seed C-1; bind_pr C-1 "$PRIVATE_PR"
db "UPDATE tasks SET merge_proof_at=datetime('now'), merge_proof_by='vesper',
       merge_proof_ref='$PRIVATE_PR', merge_proof_cmd='true' WHERE ident='C-1';"
run_done C-1 --result='landed'
chk "T2 a credentialed caller takes the API path and refuses an OPEN PR" "$((RC != 0))" "1"
chk "T2 and the row stays open"                                          "$(statusof C-1)" "in_progress"
sub "T2 the API was actually asked"  "$(cat "$GH_ARGS_LOG")" "pr view"
nsub "T2 the proof did not close it" "$OUT" "RECORDED MACHINE EVIDENCE"

# ---------------------------------------------------------------------------
# T3 — NARROWNESS: A RE-POINTED BINDING MAKES THE PROOF INERT. The proof is
# evidence about ONE pull request; carrying it onto another is the failure this
# equality test exists to prevent.
# ---------------------------------------------------------------------------
no_rail
seed D-1; bind_pr D-1 "$PRIVATE_PR"
run_verify D-1 --no-done --merge-proof --cmd='true'
bind_pr D-1 "$OTHER_PR"     # re-delivered against a different PR
run_done D-1 --result='landed'
chk "T3 a stale proof does not close the row" "$((RC != 0))" "1"
chk "T3 and the row stays open"               "$(statusof D-1)" "in_progress"
chk "T3 on the no-credential refusal"         "$(slugof D-1)" "done-merge-gate-no-credential"

# ---------------------------------------------------------------------------
# T5 — DIRECTION: A FAILING PROOF RECORDS NOTHING. Recording it would hand the
# gate the exact opposite of what it asked for.
# ---------------------------------------------------------------------------
no_rail
seed E-1; bind_pr E-1 "$PRIVATE_PR"
run_verify E-1 --no-done --merge-proof --cmd='false'
chk "T5 the proving run fails"                "$((VRC != 0))" "1"
chk "T5 and NOTHING was recorded"             "$(proofof E-1)" "|||"
sub "T5 and it says why"                      "$VOUT" "nothing recorded"
run_done E-1 --result='landed'
chk "T5 so the close still refuses"           "$((RC != 0))" "1"

# ---------------------------------------------------------------------------
# T6 — PROSE IS NOT A PROOF (DIVE-2832's distinction, which this must not erode).
# ---------------------------------------------------------------------------
no_rail
seed F-1; bind_pr F-1 "$PRIVATE_PR"
run_verify F-1 --no-done --merge-proof --result='I looked and it is on main'
chk "T6 --merge-proof with no command is refused" "$((VRC != 0))" "1"
sub "T6 and names what is missing"                "$VOUT" "--cmd="
chk "T6 nothing was recorded"                     "$(proofof F-1)" "|||"

# ---------------------------------------------------------------------------
# T7 — NOTHING TO BE EVIDENCE ABOUT. An unbound row cannot carry a merge proof.
# ---------------------------------------------------------------------------
no_rail
seed G-1
run_verify G-1 --no-done --merge-proof --cmd='true'
chk "T7 --merge-proof on an unbound row is refused" "$((VRC != 0))" "1"
sub "T7 and says to bind a delivery first"          "$VOUT" "task deliver"
chk "T7 nothing was recorded"                       "$(proofof G-1)" "|||"

# ---------------------------------------------------------------------------
# T8 — THE CLOSE IS LOUD AND ATTRIBUTED. The value of an attestation is entirely
# in the record it leaves: a silent acceptance would be indistinguishable from a
# gate that was never there.
# ---------------------------------------------------------------------------
no_rail
seed H-1; bind_pr H-1 "$PRIVATE_PR"
FIVE_ACTOR=vesper run_verify H-1 --no-done --merge-proof --cmd='printf ancestor'
run_done H-1 --result='landed'
chk "T8 the close succeeds"                    "$RC" "0"
sub "T8 it says it could not get an answer"    "$OUT" "could not GET AN ANSWER"
sub "T8 and names WHY no rail answered"       "$OUT" "No credential-free rail was available"
sub "T8 it names the recorded evidence"        "$OUT" "RECORDED MACHINE EVIDENCE"
sub "T8 it quotes the command that was run"    "$OUT" "printf ancestor"
sub "T8 it names the binding proved"           "$OUT" "$PRIVATE_PR"
sub "T8 and does not oversell the attestation" "$OUT" "not an API answer"

# ---------------------------------------------------------------------------
# T9 — THE ITERATION-1 FAIL-OPEN, GRADED WITH THE ANONYMOUS RAIL LIVE. Every arm
# above runs under FIVE_GATE_NO_ANON=1 with curl stubbed to exit 1, i.e. in a world
# where the credential-free rail structurally cannot answer — so none of them can
# see the hole quinn measured: the anon rail needs NO credential, so an
# uncredentialed caller over a PUBLIC repo IS answerable, and iteration 1's
# `! _gate_gh_credentialed` scoping let a recorded proof pre-empt a query that
# would have refused. Measured then: an OPEN public PR closed on `--cmd=true` with
# curl called ZERO times.
#
# Here the rail is LIVE over a PUBLIC, UNMERGED PR. The gate must refuse on the API
# ANSWER, and it must have gone and ASKED for it.
# ---------------------------------------------------------------------------
PUBLIC_PR='https://github.com/5dive-ai/5dive/pull/999'
export CURL_STUB_ON=1 CURL_STUB_PR='repos/5dive-ai/5dive/pulls/999'
export CURL_STUB_BODY='{"number":999,"state":"open","merged":false,"merged_at":null,"title":"t","head":{"ref":"dive-3823-merge-proof","sha":"0c9a0d5b"},"merge_commit_sha":"","html_url":"'"$PUBLIC_PR"'"}'
FIVE_GATE_NO_ANON=0
no_rail
seed I-1; bind_pr I-1 "$PUBLIC_PR"
run_verify I-1 --no-done --merge-proof --cmd='true'
chk "T9 the proof is recorded (the flag is not what is under test)" "$VRC" "0"
sub "T9 and it is stamped against the public binding" "$(proofof I-1)" "|$PUBLIC_PR|"
: >"$CURL_ARGS_LOG"
run_done I-1 --result='landed'
chk "T9 an UNMERGED public PR is not closed by a proof" "$((RC != 0))" "1"
chk "T9 and the row stays open"                        "$(statusof I-1)" "in_progress"
nsub "T9 the proof did not close it"                   "$OUT" "RECORDED MACHINE EVIDENCE"
sub "T9 the refusal quotes the MEASURED state"         "$OUT" "state=OPEN"
sub "T9 and the rail was actually asked"               "$(cat "$CURL_ARGS_LOG")" "pulls/999"

# ---------------------------------------------------------------------------
# T9b — THE SAME LIVE RAIL, A PRIVATE REPO. The other direction of T9, and the
# reason the predicate ASKS instead of testing `_gate_gh_reachable`: curl and jq
# EXIST here (the rail is live), so a reachability test would be true and would
# make this rail dead code on the very row it was written for. The rail answers
# 404 for a repo it cannot see, and the recorded proof is then the only evidence
# there is — which is DIVE-3808 exactly.
# ---------------------------------------------------------------------------
no_rail
seed J-1; bind_pr J-1 "$PRIVATE_PR"
run_verify J-1 --no-done --merge-proof --cmd='true'
: >"$CURL_ARGS_LOG"
run_done J-1 --result='landed at 2033057e'
chk "T9b a private PR the live rail 404s still closes on the proof" "$RC" "0"
chk "T9b and the row is done"                    "$(statusof J-1)" "done"
sub "T9b the rail was asked before trusting it"  "$(cat "$CURL_ARGS_LOG")" "pulls/12"
sub "T9b and the close names the 404 it got"     "$OUT" "404"
unset CURL_STUB_ON CURL_STUB_PR CURL_STUB_BODY
export FIVE_GATE_NO_ANON=1

# ---------------------------------------------------------------------------
# T10 — DIVE-3888: A LIVE TOKEN THAT CANNOT SEE THE REPO. Every arm above models
# the caller's credential as present-and-working or absent. The seat that filed
# this ticket is neither: agent-quinn's `gh` is authenticated as a GitHub App
# INSTALLATION token minted against the single pinned installation (the 5dive-ai
# org), so against a PERSONAL-account repo it is live and blind — measured
# 2026-09-02 from that uid, `gh api rate_limit` answers 5100 while
# `gh api repos/lodar/5dive-api` is a 404.
#
# Pre-fix, `_gate_merge_proof_ok && ! _gate_gh_credentialed && ! answerable` read
# that token as a credential, skipped the recorded-proof rail, and refused with
# `done-pr-state-unresolved` — whose printed remedy ("check by hand and re-run")
# can never succeed, because the blindness is permanent. So holding a WRONG-SCOPE
# token was strictly worse than holding none, which reaches this rail (T8/T9b).
# T10a is that defect; it goes red if the credential clause comes back.
#
# Restoring the clause reds T10a. Deleting the answerable check instead — the fix
# that looks right — reds T10c. Both halves are graded.
# ---------------------------------------------------------------------------
blind_tok
seed K-1; bind_pr K-1 "$PRIVATE_PR"
run_verify K-1 --no-done --merge-proof --cmd='printf blind-ancestor'
chk "T10a the proof is recorded on the blind-token seat" "$VRC" "0"
run_done K-1 --result='landed at feb7b12c'
chk "T10a a blind LIVE token still closes on the proof" "$RC" "0"
chk "T10a and the row is done"                          "$(statusof K-1)" "done"
sub "T10a it closes on the recorded evidence"           "$OUT" "RECORDED MACHINE EVIDENCE"
sub "T10a the token WAS asked before trusting the proof" "$(cat "$GH_ARGS_LOG")" "pull/12"
nsub "T10a it does not claim the seat holds no credential" "$OUT" "holds no gh credential"

# T10b — THE NARROWNESS, over the escalation. Same blind token, but the
# credential-free rail is LIVE and the PR is public and OPEN. `_gate_gh` escalates
# past the blind token (DIVE-3496) to a rail that ANSWERS, so the proof must not be
# consulted and the refusal must quote the measured state.
export CURL_STUB_ON=1 CURL_STUB_PR='repos/5dive-ai/5dive/pulls/998'
PUBLIC_OPEN='https://github.com/5dive-ai/5dive/pull/998'
export CURL_STUB_BODY='{"number":998,"state":"open","merged":false,"merged_at":null,"title":"t","head":{"ref":"b","sha":"0c9a0d5b"},"merge_commit_sha":"","html_url":"'"$PUBLIC_OPEN"'"}'
FIVE_GATE_NO_ANON=0
blind_tok
seed K-2; bind_pr K-2 "$PUBLIC_OPEN"
run_verify K-2 --no-done --merge-proof --cmd='true'
: >"$CURL_ARGS_LOG"
run_done K-2 --result='landed'
chk "T10b an OPEN PR an escalation rail CAN read is not closed by a proof" "$((RC != 0))" "1"
chk "T10b and the row stays open"               "$(statusof K-2)" "in_progress"
nsub "T10b the proof did not close it"          "$OUT" "RECORDED MACHINE EVIDENCE"
sub "T10b the refusal quotes the MEASURED state" "$OUT" "state=OPEN"
sub "T10b and the escalation rail was asked"    "$(cat "$CURL_ARGS_LOG")" "pulls/998"
unset CURL_STUB_ON CURL_STUB_PR CURL_STUB_BODY
export FIVE_GATE_NO_ANON=1

# T10c — A WORKING TOKEN IS UNCHANGED. The credential clause also bought
# cheap-first ordering; `_gate_pr_state_answerable` now carries that weight alone.
# A caller whose own token answers must still query, get a state, and never reach
# the proof — no close that passes or refuses today changes path.
a_token; export GH_STUB_BLIND=0 GH_STUB_STATE=OPEN; unset GH_STUB_MERGED
seed K-3; bind_pr K-3 "$PRIVATE_PR"
run_verify K-3 --no-done --merge-proof --cmd='true'
run_done K-3 --result='landed'
chk "T10c a working token is not overridden by a proof" "$((RC != 0))" "1"
chk "T10c and the row stays open"               "$(statusof K-3)" "in_progress"
nsub "T10c the proof was never consulted"       "$OUT" "RECORDED MACHINE EVIDENCE"
sub "T10c the refusal quotes the token's answer" "$OUT" "state=OPEN"
unset GH_STUB_BLIND GH_STUB_STATE

printf '\n%s\n' "---- $PASS passed, $FAIL failed ----"
[[ $FAIL -eq 0 ]]
