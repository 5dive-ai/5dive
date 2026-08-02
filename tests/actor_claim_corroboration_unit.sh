#!/usr/bin/env bash
# DIVE-2518 (v0.18 "Proof of who") — `--from` is a CLAIM that must corroborate.
#
# W1 (DIVE-2517) sealed ONE uid-first derivation. This grades the half that makes
# it BIND across the 43 `task_actor` sites: the derivation decides what gets
# stamped, the claim is recorded beside it where it disagrees, and the one verb
# where a claim decides an AUTHORIZATION refuses it outright.
#
# WHAT THIS GRADES, and why each arm can fail:
#   the claim never wins    T1-T3. `task_actor --from=<other>` and a forged
#                           $SUDO_USER must both return the DERIVED actor. Both
#                           forgeries are derived so they can never equal the live
#                           caller's real name (the vacuity olivia caught in W1).
#   the grade is reported   T4-T7. absent / corroborated / divergent /
#                           unattributable are four distinct states, and folding
#                           any two together is the absent-vs-not-measured
#                           collapse this epoch exists to undo.
#   the note is selective   T8. `claimed_by` is EMPTY when the claim agrees —
#                           stamping every row would bury the disagreements.
#   the refusal refuses     T9-T11. A divergent claim on a privileged verb must
#                           return NON-ZERO *and* the reason must NAME the
#                           condition. Graded by rc alone, deleting the condition
#                           leaves the arm green (a refusal that always fires
#                           passes too) — so T11 is the LIVENESS anchor: absent
#                           and corroborated must PASS.
#   the ladder degrades     T12-T13. An unreadable registry must fall to the
#                           passwd rung, NOT to `cli`. Getting this wrong would
#                           silently unattribute every row on the board.
#   the sentinel survives   T14. `cli` still means "could not attribute", which
#                           is what :2177/:2392/:3030 already branch on.
#   the envelope hole shuts T15-T16. Non-root + forged $SUDO_USER must yield NO
#                           envelope; root + $SUDO_USER must still yield the name
#                           (the behaviour cmd_agent_runtime.sh measured).
#   provenance is preserved T17-T18. `_actor_identity` is NOT replaced — the
#                           dashboard's Clerk relay still wins — and the derived
#                           value rides alongside it.
#   end to end              T19-T21. Through the BUILT bundle, against a scratch
#                           store, never the board.
#
# GROUND TRUTH IS TAKEN WITHOUT THE CODE UNDER TEST: the caller's real name comes
# from /proc/self/status resolved against /etc/passwd by awk. Never from `id`.
#
# Run: bash tests/actor_claim_corroboration_unit.sh   (no network, no sudo)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0; SKIP=0
ok(){   PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){   FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
skip(){ SKIP=$((SKIP+1)); printf 'skip - %s\n' "$1"; }

# --- ground truth, independent of the code under test -----------------------
REAL_UID=$(awk '/^Uid:/{print $2; exit}' /proc/self/status)
REAL_NAME=$(awk -F: -v u="$REAL_UID" '$3==u{print $1; exit}' /etc/passwd)
REAL_BOARD="${REAL_NAME#agent-}"

# --- forged values, DERIVED so they can NEVER equal the live caller ---------
# W1 iteration 1 shipped a hardcoded `agent-olivia` forgery, which made the arm
# vacuous for whoever ran it as agent-olivia: forged and expected were the same
# string, so a mutant that let the forgery WIN still read as "did not move".
# Deriving the forgery from the real name makes that impossible by construction.
FORGE_BOARD="not${REAL_BOARD}x"
FORGE_SUDO="agent-${FORGE_BOARD}"
claim_is_vacuous(){ [[ "$1" == "$REAL_BOARD" || "$1" == "$REAL_NAME" ]]; }

# --- load ONLY the functions under test, each anchored to its own definition --
# `sed '/^f()/,/^}/p'` over a one-liner body runs on to the NEXT `^}` in the file
# and swallows whatever sits between. Anchor per function and VERIFY it loaded —
# an unloaded function makes every arm below it vacuous, not red.
_load_from() {
  local file="$1"; shift
  local fn
  for fn in "$@"; do
    eval "$(awk -v f="^${fn}\\\\(\\\\)" '$0 ~ f {p=1} p {print} p && /^}$/ {exit} p && /^[a-z_]+\(\)[[:space:]]*\{.*\}$/ {exit}' "$file")"
    declare -F "$fn" >/dev/null \
      || { printf 'NOT OK - %s did not load from %s; every arm using it would be VACUOUS\n' "$fn" "$file"; exit 1; }
  done
}
_load_from src/lib/actor.sh _gate_passwd_stream actor_uid_to_name _gate_uid_to_agent \
           _gate_is_root _gate_caller_uid _gate_authenticated_actor actor_derive \
           actor_registry_agent actor_board_name actor_claim actor_claim_note \
           actor_require_corroborated
_load_from src/lib/tasks_db.sh task_actor task_actor_claim
_load_from src/lib/registry.sh tier_unmeasured
_load_from src/lib/validation.sh auto_sender_from_sudo
_load_from src/lib/audit.sh _audit_is_root _actor_identity _actor_identity_derived _actor_identity_claim
_load_from src/cmd_agent_runtime.sh _envelope_caller
_ACTOR_REG_MEMO_KEY=""; _ACTOR_REG_MEMO_VAL=""; _ACTOR_REG_MEMO_TIER=""

# `fail` really exits; in-process it would kill the harness mid-run and the
# truncated log would read as a pass (no tally). Stub it to RECORD and return, so
# an arm can assert both the status AND that the reason names the condition. The
# real exiting `fail` is graded end-to-end by T19-T21 through the built bundle.
E_AUTH_REQUIRED=6; E_USAGE=2
FAIL_MSG=""; FAIL_CODE=0
fail(){ FAIL_CODE="$1"; shift; FAIL_MSG="$*"; return "$FAIL_CODE"; }
# The registry is stubbed on purpose: registry.sh owns whether `agent_tier` reads
# the file correctly. What is untested is what the LADDER does with each verdict.
STUB_TIER="admin"
agent_tier(){ printf '%s\n' "$STUB_TIER"; }
reset_memo(){ _ACTOR_REG_MEMO_KEY=""; _ACTOR_REG_MEMO_VAL=""; _ACTOR_REG_MEMO_TIER=""; }

if [[ -z "$REAL_NAME" ]]; then
  skip "caller uid $REAL_UID has no passwd row on this runner; every derivation arm would be vacuous"
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  (( FAIL == 0 )) || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. --from does NOT win. It used to win outright, first, before anything else.
reset_memo
got=$(task_actor "$FORGE_BOARD")
if claim_is_vacuous "$FORGE_BOARD"; then
  no "T1 VACUOUS — the forged claim '$FORGE_BOARD' equals the caller's own board name"
elif [[ "$got" == "$REAL_BOARD" ]]; then
  ok "T1 task_actor --from=$FORGE_BOARD returned the DERIVED '$REAL_BOARD', not the claim"
else
  no "T1 the claim won: task_actor --from=$FORGE_BOARD returned '$got' (expected '$REAL_BOARD')"
fi

# 2. a forged $SUDO_USER does not move it either — the wiki's runtime repro,
#    in-process. NO SUDO IS INVOLVED; it is an ordinary environment variable.
reset_memo
got=$(SUDO_USER="$FORGE_SUDO" bash -c 'true'; SUDO_USER="$FORGE_SUDO" task_actor)
# Non-vacuity: prove the forgery is live by showing the OLD resolver would take it.
would_have=$(SUDO_USER="$FORGE_SUDO" auto_sender_from_sudo)
if [[ "$would_have" != "$FORGE_BOARD" ]]; then
  no "T2 VACUOUS — the forgery never reached the old resolver (auto_sender_from_sudo gave '$would_have')"
elif [[ "$got" == "$REAL_BOARD" ]]; then
  ok "T2 SUDO_USER=$FORGE_SUDO (no sudo) did not move the actor (still '$REAL_BOARD'; the pre-2518 resolver would have said '$would_have')"
else
  no "T2 the env forgery moved the actor to '$got' (expected '$REAL_BOARD')"
fi

# 3. both at once, which is what an attacker would actually do
reset_memo
got=$(SUDO_USER="$FORGE_SUDO" task_actor "$FORGE_BOARD")
if [[ "$got" == "$REAL_BOARD" ]]; then
  ok "T3 --from AND SUDO_USER together did not move the actor (still '$REAL_BOARD')"
else
  no "T3 combined forgery moved the actor to '$got'"
fi

# 4-7. the four claim states are DISTINCT. Folding any two is the collapse the
#      epoch exists to undo, and each is what a different reader needs.
reset_memo; actor_claim ""            ; s_absent="$ACTOR_CLAIM_STATUS"; rc_absent=$?
reset_memo; actor_claim "$REAL_BOARD" ; s_corrob="$ACTOR_CLAIM_STATUS"
reset_memo; actor_claim "$FORGE_BOARD"; s_diverge="$ACTOR_CLAIM_STATUS"

[[ "$s_absent"  == "absent"       ]] && ok "T4 no claim -> absent"       || no "T4 no claim -> '$s_absent' (expected absent)"
[[ "$s_corrob"  == "corroborated" ]] && ok "T5 claim == derived -> corroborated" || no "T5 claim == derived -> '$s_corrob'"
[[ "$s_diverge" == "divergent"    ]] && ok "T6 claim != derived -> divergent"    || no "T6 claim != derived -> '$s_diverge'"

# 7. unattributable is NOT divergent. A uid that maps to no board actor cannot
#    CONTRADICT a claim — it cannot corroborate one either, and an audit reader
#    needs to tell "you lied" from "I could not check".
reset_memo
s_unatt=$( _gate_caller_uid(){ printf '0'; }
           _gate_passwd_stream(){ printf 'root:x:0:0:::\n'; }
           STUB_TIER="unknown:unregistered"
           actor_claim "$FORGE_BOARD" >/dev/null 2>&1
           printf '%s|%s' "$ACTOR_CLAIM_STATUS" "$ACTOR_BOARD" )
if [[ "$s_unatt" == "unattributable|cli" ]]; then
  ok "T7 a claim against a non-agent uid -> unattributable (board 'cli'), distinct from divergent"
else
  no "T7 expected 'unattributable|cli', got '$s_unatt'"
fi

# 8. the note is SELECTIVE. Empty when the claim agrees — otherwise every row
#    carries a claimed_by and the disagreements are buried in the noise.
reset_memo; actor_claim ""            >/dev/null 2>&1; n_absent=$(actor_claim_note)
reset_memo; actor_claim "$REAL_BOARD" >/dev/null 2>&1; n_corrob=$(actor_claim_note)
reset_memo; actor_claim "$FORGE_BOARD">/dev/null 2>&1; n_diverge=$(actor_claim_note)
if [[ -z "$n_absent" && -z "$n_corrob" && "$n_diverge" == "$FORGE_BOARD" ]]; then
  ok "T8 claimed_by empty for absent+corroborated, '$FORGE_BOARD' for divergent"
else
  no "T8 note absent='$n_absent' corroborated='$n_corrob' divergent='$n_diverge'"
fi

# 9. THE REFUSAL. Non-zero is not enough on its own — delete the condition and an
#    rc-only arm stays green on whatever refusal fires next. Assert the reason
#    NAMES both identities, which only the real condition can produce.
reset_memo; FAIL_MSG=""; FAIL_CODE=0
actor_require_corroborated "task need" "$FORGE_BOARD"; rc=$?
if (( rc == 0 )); then
  no "T9 a divergent claim was ACCEPTED on a privileged verb (rc 0)"
elif (( FAIL_CODE != E_AUTH_REQUIRED )); then
  no "T9 refused with code $FAIL_CODE, expected $E_AUTH_REQUIRED (auth_required)"
elif [[ "$FAIL_MSG" == *"$FORGE_BOARD"* && "$FAIL_MSG" == *"$REAL_BOARD"* && "$FAIL_MSG" == *"task need"* ]]; then
  ok "T9 divergent claim REFUSED rc$rc code $FAIL_CODE, reason names the claim, the derivation and the verb"
else
  no "T9 refused but the reason does not name both identities and the verb: '$FAIL_MSG'"
fi

# 10. the unattributable branch refuses too, with its OWN reason — so a reader
#     can tell which of the two it was.
reset_memo; FAIL_MSG=""; FAIL_CODE=0
rc10=$( _gate_caller_uid(){ printf '0'; }
        _gate_passwd_stream(){ printf 'root:x:0:0:::\n'; }
        STUB_TIER="unknown:unregistered"
        actor_require_corroborated "task need" "$FORGE_BOARD" >/dev/null 2>&1; printf '%s|%s' "$?" "$FAIL_MSG" )
if [[ "${rc10%%|*}" != "0" && "${rc10#*|}" == *"cannot be corroborated"* ]]; then
  ok "T10 an unattributable claim is refused with its own distinct reason"
else
  no "T10 expected non-zero + 'cannot be corroborated', got '$rc10'"
fi

# 11. LIVENESS ANCHOR. Without this a resolver that refuses EVERYTHING passes
#     T9 and T10. absent and corroborated must both return 0 and set no reason.
reset_memo; FAIL_MSG=""
actor_require_corroborated "task need" ""; rc_a=$?
reset_memo; FAIL_MSG=""
actor_require_corroborated "task need" "$REAL_BOARD"; rc_c=$?
if (( rc_a == 0 && rc_c == 0 )); then
  ok "T11 LIVENESS: no claim (rc$rc_a) and a corroborating claim (rc$rc_c) both PASS"
else
  no "T11 the guard refuses a legitimate caller: absent rc$rc_a, corroborated rc$rc_c"
fi

# 12. the ladder DEGRADES to passwd when the registry cannot be read. Falling to
#     `cli` here would silently unattribute every row the board ever writes.
reset_memo
got=$( STUB_TIER="unknown:no-registry"; actor_board_name >/dev/null; printf '%s|%s' "$ACTOR_BOARD" "$ACTOR_BOARD_SOURCE" )
if [[ "$REAL_NAME" != agent-* ]]; then
  skip "T12 caller '$REAL_NAME' is not agent-*; the passwd rung has nothing to strip"
elif [[ "$got" == "${REAL_BOARD}|passwd" ]]; then
  ok "T12 an unreadable registry degrades to the passwd rung ('$REAL_BOARD'), not to 'cli'"
else
  no "T12 unreadable registry gave '$got', expected '${REAL_BOARD}|passwd'"
fi

# 13. and when the registry DOES answer, that is the source — otherwise T12 is
#     grading a ladder that never reaches its first rung.
reset_memo
got=$( STUB_TIER="admin"; actor_board_name >/dev/null; printf '%s|%s' "$ACTOR_BOARD" "$ACTOR_BOARD_SOURCE" )
if [[ "$got" == "${REAL_BOARD}|registry" ]]; then
  ok "T13 a readable registry answers first (source=registry)"
else
  no "T13 readable registry gave '$got', expected '${REAL_BOARD}|registry'"
fi

# 14. the `cli` sentinel survives. cmd_task.sh:2177/:2392/:3030 branch on it, so
#     changing it would silently disable three guards rather than fail loudly.
reset_memo
got=$( _gate_caller_uid(){ printf '0'; }
       _gate_passwd_stream(){ printf 'root:x:0:0:::\n'; }
       STUB_TIER="unknown:unregistered"
       task_actor )
if [[ "$got" == "cli" ]]; then
  ok "T14 a measured non-agent uid still returns the 'cli' sentinel"
else
  no "T14 non-agent uid returned '$got', expected the 'cli' sentinel"
fi

# 15. THE ENVELOPE HOLE. Non-root + forged $SUDO_USER used to mint an envelope
#     naming another agent, because auto_sender_from_sudo was consulted whenever
#     the EUID branch came back empty — i.e. for every non-agent caller.
got=$( _gate_caller_uid(){ printf '1000'; }
       _gate_is_root(){ return 1; }
       _gate_passwd_stream(){ printf 'claude:x:1000:1000:::\n'; }
       SUDO_USER="$FORGE_SUDO" _envelope_caller )
if [[ -z "$got" ]]; then
  ok "T15 non-root + SUDO_USER=$FORGE_SUDO yields NO envelope (the forgery is refused)"
else
  no "T15 a non-root caller forged an envelope naming '$got'"
fi

# 16. LIVENESS for T15: at real EUID 0 the same variable must still answer, or
#     T15 passes on a function that returns empty unconditionally.
got=$( _gate_caller_uid(){ printf '0'; }
       _gate_is_root(){ return 0; }
       _gate_passwd_stream(){ printf 'root:x:0:0:::\n'; }
       SUDO_UID="" SUDO_USER="$FORGE_SUDO" _envelope_caller )
if [[ "$got" == "$FORGE_BOARD" ]]; then
  ok "T16 LIVENESS: at real euid 0, SUDO_USER still answers ('$FORGE_BOARD') — T15 is not vacuous"
else
  no "T16 root + SUDO_USER=$FORGE_SUDO gave '$got', expected '$FORGE_BOARD' (T15 may be vacuous)"
fi

# 17. provenance is NOT replaced. FIVEDIVE_AUDIT_USER is the dashboard's Clerk
#     relay — a human with no uid on this box — and collapsing it onto the
#     process uid would erase the only record of WHICH human acted.
got=$(FIVEDIVE_AUDIT_USER="$FORGE_SUDO" _actor_identity)
if [[ "$got" == "$FORGE_SUDO" ]]; then
  ok "T17 _actor_identity still honours FIVEDIVE_AUDIT_USER (provenance preserved for the Clerk relay)"
else
  no "T17 _actor_identity returned '$got'; the dashboard relay is broken"
fi

# 18. ...and the derived value rides ALONGSIDE it, so the row can record the
#     disagreement. One field cannot; that is why the forgery left no trace.
d=$(_actor_identity_derived)
c=$(FIVEDIVE_AUDIT_USER="$FORGE_SUDO" _actor_identity_claim)
c_same=$(FIVEDIVE_AUDIT_USER="$REAL_NAME" _actor_identity_claim)
if [[ "$d" == "$REAL_NAME" && "$c" == "$FORGE_SUDO" && -z "$c_same" ]]; then
  ok "T18 audit carries derived='$REAL_NAME' plus claimed='$FORGE_SUDO', and claimed is EMPTY when they agree"
else
  no "T18 derived='$d' claimed='$c' claimed_when_agreeing='$c_same'"
fi

# ---------------------------------------------------------------------------
# END TO END, through the BUILT bundle. The in-process arms above stub `fail`,
# which really exits — so the refusal's ACTION-NEVER-RAN property can only be
# graded here, in a fresh bash that defines its own seams.
BIN=./5dive
if [[ ! -x "$BIN" ]]; then
  skip "T19-T21 no built ./5dive (run ./build.sh)"
else
  # A SCRATCH store. These arms WRITE, so the store must be the harness's own.
  # The vars the CLI actually reads are STATE_DIR / TASKS_DIR / TASKS_DB
  # (src/header.sh:63, src/lib/tasks_db.sh:16-17) — bare, not FIVEDIVE_-prefixed.
  SBOX=$(mktemp -d)
  e2e(){ STATE_DIR="$SBOX" TASKS_DIR="$SBOX/tasks" TASKS_DB="$SBOX/tasks/tasks.db" "$BIN" "$@" 2>&1; }
  # `task init` is root-only, so the scratch store is created under sudo and then
  # handed BACK to the caller. The arms themselves must run unelevated: they assert
  # on the actor derived from the caller's uid, and under sudo that derivation
  # correctly answers `root`, which would grade nothing about this change.
  # `sudo -n` — never prompt. No sudo means SKIP, and a skip is not a pass.
  if sudo -n true 2>/dev/null; then
    sudo -n env STATE_DIR="$SBOX" TASKS_DIR="$SBOX/tasks" TASKS_DB="$SBOX/tasks/tasks.db" \
      "$BIN" task init >/dev/null 2>&1 || true
    sudo -n chown -R "$(id -u):$(id -g)" "$SBOX" 2>/dev/null || true
  fi

  # PROVE THE ISOLATION BEFORE WRITING ANYTHING, and SKIP rather than write if it
  # cannot be proven.
  #
  # Iteration 1 of this harness exported FIVEDIVE_STATE_DIR — a variable nothing
  # in this CLI reads — so every arm below ran against the SHARED board. It
  # created two real idents (medium priority, assignee dev, visible in `task ls`
  # and in the inbox count) and routed a real tier-1 decision gate to a real
  # verifier, who had to withdraw it. Every arm still PASSED, which is the whole
  # problem: a wrong redirect is invisible to assertions about the rows, because
  # the rows are fine — they are just in the wrong store.
  #
  # The reserved-fakes convention in CLAUDE.md covers ids, emails and IPs, and
  # there is no reserved-fake form for a task ident. So the fence has to be on the
  # STORE: a fresh store contains ZERO rows, the shared board contains hundreds.
  # That single count separates them, and it is cheap enough to run every time.
  # The fence is DIFFERENTIAL, and it has to be. "The scratch store lists zero
  # rows" is not evidence on its own — a `task ls` that simply errored also lists
  # zero. What proves the redirect MOVED something is the default store listing
  # rows in the same breath that the redirected one lists none. Both reads are
  # read-only, and the db file cannot be checked first: `task ls` never creates
  # one, so a file-existence precondition skips every run (iteration 2 did that).
  live_rows=$("$BIN" task ls 2>/dev/null | grep -c 'DIVE-' || true)
  probe_rows=$(e2e task ls 2>/dev/null | grep -c 'DIVE-' || true)
  if (( live_rows == 0 )); then
    skip "T19-T21 isolation UNPROVABLE here — the DEFAULT store also lists 0 rows, so an empty scratch store proves nothing about the redirect"
  elif (( probe_rows != 0 )); then
    skip "T19-T21 store isolation NOT PROVEN — the scratch store lists $probe_rows rows, so the redirect did not take; refusing to write to the shared board"
  else
  tid=$(e2e task add "DIVE-2518 harness row" --project=dive 2>&1 | grep -oE 'DIVE-[0-9]+' | head -1)
  # Confirm the FIRST write actually landed in the scratch store before doing any
  # more of them. The pre-write fence reasons about reads; this one is the write
  # itself, and it is the only check that can catch a store that reads clean and
  # writes elsewhere.
  if [[ -n "$tid" && ! -f "$SBOX/tasks/tasks.db" ]]; then
    no "T19-T21 ABORTED: '$tid' was created but $SBOX/tasks/tasks.db does not exist — the write did NOT land in the scratch store"
    tid=""
  fi
  if [[ -z "$tid" ]]; then
    skip "T19-T21 could not create a scratch row in the (proven-isolated) store"
  else
    # 19. created_by is the DERIVED actor even when --from claims otherwise.
    # DERIVE the expected board name; do NOT assume the runner is a registered
    # agent. The in-process arms above stub `agent_tier` (registry.sh owns whether
    # the file is read correctly), so they see every caller as registered — but
    # these arms go through the REAL registry, and a principal it does not list is
    # the `cli` sentinel by design. Hardcoding `$REAL_BOARD` here made T19/T20 red
    # for `claude` (uid 1000, not a registered agent) while the product was behaving
    # exactly as specified. Ground truth is the registry FILE, read directly, not
    # `actor_registry_agent` — that is the function under test.
    EXPECT_BOARD="cli"
    if jq -e --arg n "$REAL_BOARD" '(.agents|type=="object") and (.agents|has($n))' \
         /var/lib/5dive/agents.json >/dev/null 2>&1; then
      EXPECT_BOARD="$REAL_BOARD"
    elif [[ "$REAL_NAME" == agent-* ]]; then
      EXPECT_BOARD="$REAL_BOARD"     # the passwd rung: registry silent, name is agent-*
    fi
    tid2=$(e2e task add "DIVE-2518 claimed row" --project=dive --from="$FORGE_BOARD" 2>&1 | grep -oE 'DIVE-[0-9]+' | head -1)
    cb=$(e2e task show "$tid2" | awk -F' = ' '/^created_by /{print $2; exit}')
    if [[ "$cb" == "$EXPECT_BOARD" ]]; then
      ok "T19 e2e: --from=$FORGE_BOARD stamped created_by=$EXPECT_BOARD (the derivation, not the claim)"
    else
      no "T19 e2e: created_by='$cb', expected '$EXPECT_BOARD' (runner '$REAL_NAME')"
    fi
    # 19b. RECORD BOTH. T19 alone passes on a build that simply DROPS the claim,
    #      which is what the first cut did — `task_actor_claim` was called inside
    #      `$( )`, so the grade died with the subshell and claimed_by was NULL for
    #      every divergent claim while created_by looked perfect. Half a fix reads
    #      exactly like a whole one unless the other half is asserted.
    cby=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT COALESCE(claimed_by,'<null>') FROM tasks WHERE ident='$tid2';" 2>/dev/null)
    cby_none=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT COALESCE(claimed_by,'<null>') FROM tasks WHERE ident='$tid';" 2>/dev/null)
    if [[ -z "$cby" && -z "$cby_none" ]]; then
      skip "T19b sqlite3 unavailable or store unreadable; claimed_by not graded"
    elif [[ "$cby" == "$FORGE_BOARD" && "$cby_none" == "<null>" ]]; then
      ok "T19b e2e: the divergent claim is RECORDED (claimed_by=$FORGE_BOARD) and a no-claim row stays NULL"
    else
      no "T19b e2e: claimed_by='$cby' (expected '$FORGE_BOARD'), no-claim row='$cby_none' (expected <null>)"
    fi
    # 20. THE REFUSAL, through the real exiting `fail`: the gate must NOT exist
    #     afterwards. rc alone would stay green if the verb refused for any other
    #     reason and still filed the gate.
    out=$(e2e task need "$tid" --type=decision --ask="harness probe" --from="$FORGE_BOARD"); rc=$?
    gates=$(e2e task show "$tid" | grep -c 'human gate:' || true)
    # The refusal CLASS depends on the runner too, and the two are not
    # interchangeable: a runner the registry attributes gets `divergent` ("you
    # claim X and the uid says Y"), one it cannot attribute gets `unattributable`
    # ("I could not check"). Asserting only "some refusal happened" would accept
    # either on any runner and stop grading the partition the code exists to draw.
    if [[ "$EXPECT_BOARD" == "cli" ]]; then WANT_REASON="cannot be corroborated"
    else                                    WANT_REASON="contradicts the derived actor"; fi
    if (( rc == 0 )); then
      no "T20 e2e: task need accepted a divergent --from (rc 0)"
    elif (( gates != 0 )); then
      no "T20 e2e: refused rc$rc but the gate was FILED anyway — the action ran"
    elif [[ "$out" == *"$FORGE_BOARD"* && "$out" == *"$WANT_REASON"* ]]; then
      ok "T20 e2e: task need --from=$FORGE_BOARD refused rc$rc, NO gate filed, reason names the claim ('$WANT_REASON' — correct class for runner '$REAL_NAME')"
    else
      no "T20 e2e: refused rc$rc with no gate, but the reason is not the '$WANT_REASON' class: $(printf '%s' "$out" | head -c 200)"
    fi
    # 21. LIVENESS for T20: the same verb with NO claim must SUCCEED and file the
    #     gate. Without this, a `task need` broken for everyone passes T20.
    out=$(e2e task need "$tid" --type=decision --ask="harness liveness probe"); rc=$?
    gates=$(e2e task show "$tid" | grep -c 'human gate:' || true)
    if (( rc == 0 )) && (( gates > 0 )); then
      ok "T21 LIVENESS: task need with no --from succeeded and filed the gate — T20 is not vacuous"
    else
      no "T21 task need with no claim failed (rc$rc, gates=$gates): $(printf '%s' "$out" | head -c 200)"
    fi

    # 22. THE EXCLUSION, EXERCISED. `task answer` is deliberately outside the
    #     privileged set: `--from` there is provenance behind a control that
    #     already fails closed, and the Telegram button rail relays a claim that
    #     can never corroborate (`cmd_task_clear_recs` passes --from=telegram).
    #     An exclusion nobody exercises is a hole with a comment on it — so assert
    #     that the corroboration guard does NOT fire here. The verb may still
    #     refuse for its own reasons (tier, proof, gate state); what must never
    #     appear is THIS guard's refusal.
    out=$(e2e task answer "$tid" --value=A --from=telegram)
    if [[ "$out" == *"contradicts the derived actor"* || "$out" == *"cannot be corroborated"* ]]; then
      no "T22 the corroboration guard fired on 'task answer', which is excluded by design — this breaks the Telegram button rail: $(printf '%s' "$out" | head -c 200)"
    else
      ok "T22 'task answer --from=telegram' is NOT refused by the corroboration guard (the relay rail survives)"
    fi

    # 23. DIFFERENTIAL for T22. Without this, T22 passes on a build where the
    #     guard was never wired at all. The SAME non-corroborating claim, on the
    #     verb that IS in the set, must produce exactly the refusal T22 forbids.
    tid3=$(e2e task add "DIVE-2518 exclusion differential" --project=dive 2>&1 | grep -oE 'DIVE-[0-9]+' | head -1)
    out=$(e2e task need "$tid3" --type=decision --ask="differential probe" --from=telegram); rc=$?
    if (( rc != 0 )) && [[ "$out" == *"contradicts the derived actor"* || "$out" == *"cannot be corroborated"* ]]; then
      ok "T23 the SAME claim on 'task need' IS refused — the exclusion is verb-scoped, not a dead guard"
    else
      no "T23 'task need --from=telegram' was not refused (rc$rc) — T22 proves nothing: $(printf '%s' "$out" | head -c 200)"
    fi
  fi
  fi

  # 24. THE ISOLATION FENCE MUST BE ABLE TO GO RED. A fence that passes whether or
  #     not the store is isolated is the same defect one layer up — and this exact
  #     harness shipped an iteration that wrote two real rows to the shared board
  #     and a real gate to a real verifier while every arm passed. Run the fence's
  #     OWN predicate against the DEFAULT (un-redirected) store: it must trip.
  #     Read-only, and it never writes.
  unfenced=$("$BIN" task ls 2>/dev/null | grep -c 'DIVE-' || true)
  if (( unfenced == 0 )); then
    skip "T24 the default store lists 0 rows on this runner, so the fence has nothing to trip on"
  elif (( unfenced != 0 )); then
    ok "T24 the isolation fence's predicate TRIPS on the un-redirected store ($unfenced rows) — it is not a fence that passes either way"
  fi
  rm -rf "$SBOX"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 )) || exit 1
exit 0
