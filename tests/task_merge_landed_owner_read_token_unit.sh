#!/usr/bin/env bash
# TIER: core — stubbed gh + stubbed anonymous rail, a scratch task store, no network.
#
# DIVE-5632 — `task merge-landed` read a MERGED lodar companion as "state NOT READ"
# on the same seat where `merge-gate-selftest` read it MERGED.
#
# MEASURED 2026-10-05 on DIVE-5622 (quinn's seat): cli#1252 (5dive-ai, public) and
# api#411 (lodar, private) had both merged; `merge-landed` refused with
# "also binds lodar/5dive-api#411 (state NOT READ ...)". The landing probe hands
# `_gate_gh` an EMPTY token on purpose (credential-free by construction), which
# goes straight to the bot rail / anonymous rail. A verifier seat has no bot rail
# and a private repo declines the anonymous read, so the probe was UNKNOWN. The
# selftest resolves the seat's own (5dive-ai) token, fails BLIND on lodar, and
# `_gate_gh`'s DIVE-3888 escalation finds GH_READ_TOKEN_LODAR — an arm the empty
# token never enters.
#
# THE SEAT THIS FILE BUILDS is that one, exactly:
#   - no bot rail (sudo refuses),
#   - the anonymous rail answers PUBLIC 5dive-ai repos only,
#   - `gh` answers only for the owner-scoped read token minted for the repo's owner,
#   - the seat's tokens file holds GH_READ_TOKEN_LODAR / GH_READ_TOKEN_5DIVE_AI.
#
#   F  the fixture reproduces the refusal before the fix (via the mutant, M1)
#   A  the companion the owner token resolves counts as LANDED: merge-landed
#      records the landing and clears merge_owner
#   N  a read the credential-free rail answers spends NO owner token (narrowness)
#   B  with every arm failing it still refuses with "NOT READ" and writes nothing
#   O  an OPEN companion read through the owner token is still "not merged"
#   M  mutant: the fallback removed -> A is red
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
export FIVE_GATE_NO_ANON=1
TMP="$(mktemp -d /tmp/task-merge-landed-ownertok.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/curl"; chmod +x "$TMP/bin/curl"

# gh stub: answers ONLY when the token is the one minted for the owner the call
# names. The answer per owner is GH_STUB_<OWNER>_ANSWER (an `a|b|c` record).
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "token" ]]; then exit 1; fi
printf '%s\n' "${GH_TOKEN:-<none>}" >>"$TOK_LOG"
args="$*"
if [[ "${GH_TOKEN:-}" == "tok-lodar" && "$args" == *github.com/lodar/* ]]; then
  printf '%s\n' "${GH_STUB_LODAR_ANSWER:-}"; [[ -n "${GH_STUB_LODAR_ANSWER:-}" ]] && exit 0
fi
if [[ "${GH_TOKEN:-}" == "tok-5dive-ai" && "$args" == *github.com/5dive-ai/* ]]; then
  printf '%s\n' "${GH_STUB_5DIVE_ANSWER:-}"; [[ -n "${GH_STUB_5DIVE_ANSWER:-}" ]] && exit 0
fi
printf "GraphQL: Could not resolve to a Repository with the name 'x/y'. (repository)\n" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export TOK_LOG="$TMP/tokens.log"; : >"$TOK_LOG"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh \
         cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/isolate_read_tokens.sh"
isolate_read_tokens "$TMP/bin"

# The anonymous rail, as it behaves for real: a public 5dive-ai repo answers, a
# private lodar repo declines. Counted, so narrowness is graded.
ANON_LOG="$TMP/anon.log"; : >"$ANON_LOG"
_gate_anon_gh() { shift
  printf '%s\n' "$*" >>"$ANON_LOG"
  [[ "$*" == *github.com/5dive-ai/* && -n "${ANON_5DIVE_ANSWER:-}" ]] || return 1
  printf '%s\n' "$ANON_5DIVE_ANSWER"; }

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"
mkdir -p "$TASKS_DIR"; set +e
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init

export HOME="$TMP/home"
mkdir -p "$HOME/.config/5dive"
cat >"$HOME/.config/5dive/gh-read-tokens.env" <<ENV
GH_READ_TOKEN_5DIVE_AI=tok-5dive-ai
GH_READ_TOKEN_LODAR=tok-lodar
ENV
chmod 600 "$HOME/.config/5dive/gh-read-tokens.env"

OWNER=ops; GRADER=quinn; MAKER=dev
PR=https://github.com/5dive-ai/5dive/pull/1252
COMP=https://github.com/lodar/5dive-api/pull/411
SHA=7b959ba9c0e14a2b5d6e8f0a1b2c3d4e5f607182
CSHA=1b8cf094c0e14a2b5d6e8f0a1b2c3d4e5f607182
AT=2026-10-05T15:57:12Z
MERGED_PR="MERGED|$SHA|$AT"
MERGED_COMP="MERGED|$CSHA|$AT"

seed() { # <ident>
  db "DELETE FROM tasks WHERE ident='$1';"
  db "INSERT INTO tasks(ident,title,status,kind,created_by,assignee,maker_agent,verifier,
        graded_at,graded_verdict_at,graded_by,graded_verdict,handoff_delivered_at,
        delivery_ref,delivery_companions,merge_owner,merge_hold_reason,started_at)
      VALUES('$1','two-repo row, both merged','todo','standard','ops',
        '$GRADER','$MAKER','$GRADER','2026-10-05 15:40:00',
        '2026-10-05 15:40:00','$GRADER','pass','2026-10-05 15:00:00','$PR','$COMP',
        '$OWNER','merger:no-graded-sha-stated','2026-10-05 15:00:00');"
  db "SELECT id FROM tasks WHERE ident='$1';"
}
col() { db "SELECT COALESCE($2,'-') FROM tasks WHERE ident='$1';"; }
ACT="$OWNER"
task_actor_claim() { ACTOR_BOARD="$ACT"; }
task_actor() { printf '%s\n' "$ACT"; }

# ---------------------------------------------------------------------------
# T0 — the sandbox is real (a live seat token must never reach the stub).
# ---------------------------------------------------------------------------
[[ "$(read_tokens_stub_control)" == "STUBBED" && -z "$(read_tokens_isolated_probe)" ]] \
  && ok_t "T0 the real seat's tokens file cannot leak in" || bad_t "T0 isolation" ""
[[ "$(_gate_read_tokens_file)" == "$HOME/.config/5dive/gh-read-tokens.env" ]] \
  && ok_t "T0a the sandbox tokens file is the one that resolves" || bad_t "T0a" "$(_gate_read_tokens_file)"

# ---------------------------------------------------------------------------
# A — the companion only the owner read token can see counts as LANDED.
# ---------------------------------------------------------------------------
export ANON_5DIVE_ANSWER="$MERGED_PR" GH_STUB_LODAR_ANSWER="$MERGED_COMP"
unset GH_STUB_5DIVE_ANSWER
id=$(seed DIVE-5622)
[[ -n "$id" ]] && ok_t "A0 fixture: primary $PR, companion $COMP, merge_owner=$OWNER" || bad_t "A0 seed" ""
p=$(_merge_landed_probe "$COMP" "")
[[ "${p%%$'\x1f'*}" == "MERGED" ]] \
  && ok_t "A1 the probe reads the private companion MERGED through GH_READ_TOKEN_LODAR" || bad_t "A1 probe" "$(cat -v <<<"$p")"
[[ -z "$(_task_companions_unlanded "$id")" ]] \
  && ok_t "A2 _task_companions_unlanded is EMPTY — the companion is landed" || bad_t "A2" "$(_task_companions_unlanded "$id")"
: >"$TOK_LOG"
out=$(cmd_task_merge_landed DIVE-5622 2>&1); rc=$?
(( rc == 0 )) && ok_t "A3 merge-landed exits 0 on the DIVE-5622 shape" || bad_t "A3 rc" "rc=$rc out=$out"
[[ "$(col DIVE-5622 merge_landed_sha)" == "$SHA" && "$(col DIVE-5622 merge_landed_ref)" == "$PR" ]] \
  && ok_t "A4 the landing is RECORDED against the primary" || bad_t "A4 record" "sha=$(col DIVE-5622 merge_landed_sha)"
[[ "$(col DIVE-5622 merge_owner)" == "-" ]] \
  && ok_t "A5 merge_owner is CLEARED — the row left MERGING" || bad_t "A5 merge_owner" "$(col DIVE-5622 merge_owner)"
grep -qx 'tok-lodar' "$TOK_LOG" \
  && ok_t "A6 the lodar owner token is what answered" || bad_t "A6 token" "$(cat "$TOK_LOG")"
! grep -qx 'tok-5dive-ai' "$TOK_LOG" \
  && ok_t "A7 the PUBLIC primary was answered credential-free; no owner token was spent on it" \
  || bad_t "A7 narrowness" "$(cat "$TOK_LOG")"

# ---------------------------------------------------------------------------
# N — narrowness: a companion the credential-free rail answers spends no token.
# ---------------------------------------------------------------------------
: >"$TOK_LOG"
p=$(_merge_landed_probe "$PR" "")
{ [[ "${p%%$'\x1f'*}" == "MERGED" ]] && [[ ! -s "$TOK_LOG" ]]; } \
  && ok_t "N1 an answered credential-free read never reaches gh with an owner token" \
  || bad_t "N1" "probe=$(cat -v <<<"$p") tokens=$(cat "$TOK_LOG")"

# ---------------------------------------------------------------------------
# O — an OPEN companion read through the owner token is "not merged", never landed.
# ---------------------------------------------------------------------------
export GH_STUB_LODAR_ANSWER="OPEN|null|null"
id2=$(seed DIVE-5623)
u=$(_task_companions_unlanded "$id2")
[[ "$u" == "$COMP (OPEN, not merged)" ]] \
  && ok_t "O1 an open companion read via the owner token says 'not merged'" || bad_t "O1" "$u"
out=$(cmd_task_merge_landed DIVE-5623 2>&1); rc=$?
{ (( rc != 0 )) && [[ "$(col DIVE-5623 merge_landed_at)" == "-" && "$(col DIVE-5623 merge_owner)" == "$OWNER" ]]; } \
  && ok_t "O2 ...and merge-landed refuses and writes nothing" || bad_t "O2" "rc=$rc out=$out"

# ---------------------------------------------------------------------------
# B — every arm fails: still "NOT READ", still refused, nothing written.
# ---------------------------------------------------------------------------
unset GH_STUB_LODAR_ANSWER
id3=$(seed DIVE-5624)
u=$(_task_companions_unlanded "$id3")
[[ "$u" == *"state NOT READ"* ]] \
  && ok_t "B1 with the owner token unable to answer the companion is NOT READ" || bad_t "B1" "$u"
out=$(cmd_task_merge_landed DIVE-5624 2>&1); rc=$?
{ (( rc != 0 )) && [[ "$out" == *"NOT READ"* && "$(col DIVE-5624 merge_landed_at)" == "-" \
   && "$(col DIVE-5624 merge_owner)" == "$OWNER" ]]; } \
  && ok_t "B2 merge-landed still refuses with NOT READ and records nothing" || bad_t "B2" "rc=$rc out=$out"
export GH_STUB_LODAR_ANSWER="$MERGED_COMP"
( export HOME="$TMP/nohome"; [[ "$(_merge_landed_probe "$COMP" "")" == UNKNOWN* ]] ) \
  && ok_t "B3 a seat with NO tokens file is UNKNOWN, not MERGED" || bad_t "B3" ""
GH_STUB_LODAR_ANSWER="MERGED|short"
[[ "$(_merge_landed_probe "$COMP" "")" == UNKNOWN* ]] \
  && ok_t "B4 a short owner-token record is UNKNOWN, never a verdict" || bad_t "B4" ""
export GH_STUB_LODAR_ANSWER="$MERGED_COMP"

# ---------------------------------------------------------------------------
# M — mutant: the fallback removed, the DIVE-5622 refusal comes back.
# ---------------------------------------------------------------------------
MUT="$TMP/mut"; mkdir -p "$MUT"; cp src/task/delivery.sh "$MUT/delivery.sh"
sed -i 's@^  if ! _merge_landed_record_ok "\$out"; then$@  if false; then # MUTANT@' "$MUT/delivery.sh"
[[ "$(grep -c 'if false; then # MUTANT' "$MUT/delivery.sh")" == "1" ]] && bash -n "$MUT/delivery.sh" \
  && ok_t "M0 the mutant substitutes exactly once and parses" || bad_t "M0 substitution" ""
( set +e; source "$MUT/delivery.sh" >/dev/null 2>&1
  id4=$(seed DIVE-5625)
  u=$(_task_companions_unlanded "$id4")
  [[ "$u" == *"state NOT READ"* ]] ) \
  && ok_t "M1 MUTANT (fallback removed): the merged companion reads NOT READ again — A2/A3 measure the fix" \
  || bad_t "M1 mutant" "the companion still reads landed without the fallback"

printf -- '-----\n'
printf 'task_merge_landed_owner_read_token: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
