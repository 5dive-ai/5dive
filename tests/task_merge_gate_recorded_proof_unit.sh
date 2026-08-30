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
# Isolation matches the sibling gate harnesses (task_merge_gate_anon_rail_unit.sh):
# src/ sourced into a throwaway STATE_DIR — the live tasks.db is NEVER touched — and
# gh/sudo/curl are stubbed on PATH, so this file makes no network call and needs no
# root.
# TIER: nightly — 4.9s measured on the 5dive dev host (slowest of three consecutive
# runs: 4.9/4.5/4.9s): does not fit the 300s PR core, and its closest sibling
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
  [[ -n "${GH_STUB_STATE:-}" ]] || exit 1
  printf '%s' "{\"state\":\"${GH_STUB_STATE}\",\"mergedAt\":${GH_STUB_MERGED:-null},\"statusCheckRollup\":[],\"headRefOid\":\"${GH_STUB_HEAD:-}\",\"mergeCommit\":null}" \
    | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/gh"

# --- stub curl: the anon rail's only transport. FIVE_GATE_NO_ANON=1 already disables
# it; this exists so a regression that re-enables it cannot reach the network.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/curl"
chmod +x "$TMP/bin/curl"

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
              export SUDO_USER=""; export GH_STUB_AUTH_TOKEN=""; : >"$GH_ARGS_LOG"; }
a_token()   { unset GH_TOKEN GITHUB_TOKEN; export SUDO_USER=""
              export GH_STUB_AUTH_TOKEN="tok-3823"; : >"$GH_ARGS_LOG"; }

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
sub "T8 it says it could not ASK"              "$OUT" "could not ASK anything"
sub "T8 it names the recorded evidence"        "$OUT" "RECORDED MACHINE EVIDENCE"
sub "T8 it quotes the command that was run"    "$OUT" "printf ancestor"
sub "T8 it names the binding proved"           "$OUT" "$PRIVATE_PR"
sub "T8 and does not oversell the attestation" "$OUT" "not an API answer"

printf '\n%s\n' "---- $PASS passed, $FAIL failed ----"
[[ $FAIL -eq 0 ]]
