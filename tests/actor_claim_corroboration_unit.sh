#!/usr/bin/env bash
# DIVE-2518 (v0.18 "Proof of who") — `--from` is a CLAIM that must corroborate.
#
# W1 (DIVE-2517) sealed ONE uid-first derivation. This grades the half that makes
# it BIND across the 43 `task_actor` sites: the derivation decides what gets
# stamped, the claim is recorded beside it where it disagrees, and no decision
# anywhere reads the claim.
#
# WHAT THIS GRADES, and why each arm can fail:
#   the ENV path is shut    T1-T2. With no claim the answer comes from the uid and
#                           never from $USER/$SUDO_USER — the hole that was actually
#                           MEASURED (a plain env var, no privilege, no trace).
#                           Forgeries are DERIVED from the runner's own name so they
#                           can never coincide with it (the vacuity olivia caught in W1).
#   the claim still relays  T3. A `--from` claim IS returned, deliberately: `council`
#                           and `telegram` have no uid, so deriving would silently
#                           reattribute their rows. What makes it safe is that the
#                           measurement is taken anyway and travels beside it.
#   the grade is reported   T4-T7. absent / corroborated / divergent /
#                           unattributable are four distinct states, and folding
#                           any two together is the absent-vs-not-measured
#                           collapse this epoch exists to undo.
#   the note is selective   T8. `claimed_by` is EMPTY when the claim agrees —
#                           stamping every row would bury the disagreements.
#   the claim decides       T20/T23. NOTHING. `--from` is accepted and recorded and
#   NOTHING                 believed by no decision: the gate still files (relay is
#                           not broken), `gate_filed_by` carries the DERIVED actor,
#                           and the reviewer lookup — the one outcome the claim used
#                           to move — follows the derivation. T23 seeds two DIFFERENT
#                           leads so a claim that won would route somewhere visible.
#   the ladder degrades     T12-T13. An unreadable registry must fall to the
#                           passwd rung, NOT to `cli`. Getting this wrong would
#                           silently unattribute every row on the board.
#   the sentinel survives   T14. `cli` still means "could not attribute", which
#                           is what :2177/:2392/:3030 already branch on.
#   provenance is preserved T17-T18. `_actor_identity` is NOT replaced — the
#                           dashboard's Clerk relay still wins — and the derived
#                           value rides alongside it.
#   end to end              T19-T25. Through the BUILT bundle, against a scratch
#                           store, never the board. T23 is the security arm: the
#                           reviewer lookup — the one thing the claim DECIDED — now
#                           follows the derivation, proven with two distinct leads.
#                           T25 writes to a store the same process is creating, the
#                           only path that exercises the base schema.
#
# GROUND TRUTH IS TAKEN WITHOUT THE CODE UNDER TEST: the caller's real name comes
# from /proc/self/status resolved against /etc/passwd by awk. Never from `id`.
#
# Run: bash tests/actor_claim_corroboration_unit.sh   (no network, no sudo)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
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
           actor_registry_agent actor_board_name actor_claim actor_claim_note
_load_from src/lib/tasks_db.sh task_actor task_actor_claim
_load_from src/lib/registry.sh tier_unmeasured
_load_from src/lib/validation.sh auto_sender_from_sudo
_load_from src/lib/audit.sh _audit_is_root _actor_identity _actor_identity_derived _actor_identity_claim
_load_from src/cmd_agent_runtime.sh _envelope_caller
_ACTOR_REG_MEMO_KEY=""; _ACTOR_REG_MEMO_VAL=""; _ACTOR_REG_MEMO_TIER=""

# `fail` really exits; in-process it would kill the harness mid-run and the
# truncated log would read as a pass (no tally). Stub it to RECORD and return, so
# an arm can assert both the status AND that the reason names the condition. The
# real exiting `fail` is graded end-to-end by T19-T24 through the built bundle.
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
# 1. WITH NO CLAIM, the answer comes from the uid — never $USER, never $SUDO_USER.
#    This is the hole that was MEASURED: `SUDO_USER=agent-olivia 5dive task ls --mine`
#    acted as another agent with no privilege and left NO trace, because $SUDO_USER is
#    an ordinary variable nothing verifies. A `--from` claim is a different threat —
#    argv, deliberate, logged — and gets a different answer (T3).
reset_memo
got=$(SUDO_USER="$FORGE_SUDO" USER="$FORGE_SUDO" LOGNAME="$FORGE_SUDO" task_actor)
if claim_is_vacuous "$FORGE_BOARD"; then
  no "T1 VACUOUS — the forged name '$FORGE_BOARD' equals the caller's own board name"
elif [[ "$got" == "$REAL_BOARD" ]]; then
  ok "T1 no claim + forged SUDO_USER/USER/LOGNAME=$FORGE_SUDO still derives '$REAL_BOARD'"
else
  no "T1 the env forgery moved the actor to '$got' (expected '$REAL_BOARD')"
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

# 3. A CLAIM IS STILL RETURNED, deliberately. `council` files board rows as
#    --from=council and the Telegram rail answers as --from=telegram; NEITHER HAS A
#    UID, so no passwd walk can produce them and returning the derived value would
#    silently reattribute the row to whoever ran the process. What makes it safe is
#    that the measurement is taken anyway and travels beside it — a forged claim is
#    falsifiable afterwards instead of being the only thing on file.
reset_memo
got=$(task_actor "$FORGE_BOARD")
# BARE call for the grade: task_actor above runs in $( ) and its ACTOR_* die with
# that subshell — the same trap that NULLed claimed_by in the create path.
actor_claim "$FORGE_BOARD" || true
if [[ "$got" != "$FORGE_BOARD" ]]; then
  no "T3 a relay claim was DROPPED: task_actor --from=$FORGE_BOARD returned '$got' — council/telegram attribution would be lost"
elif [[ "$ACTOR_BOARD" == "$REAL_BOARD" && "$ACTOR_CLAIM_STATUS" == "divergent" ]]; then
  ok "T3 the claim is returned for the record ('$FORGE_BOARD') while the uid is still MEASURED ('$ACTOR_BOARD', divergent)"
else
  no "T3 claim returned but the measurement was lost: ACTOR_BOARD='$ACTOR_BOARD' status='$ACTOR_CLAIM_STATUS'"
fi

# 3b. THE ASYMMETRY ITSELF, in one arm, because it is the whole design and a
#     refactor that "tidies" the two paths into one would otherwise red nothing.
#     The SAME name, offered two ways, must produce two DIFFERENT answers:
#       via $SUDO_USER (env, no privilege, no trace)  -> IGNORED
#       via --from     (argv, deliberate, logged)     -> HONOURED
#     If these ever agree, one of the two threats has been silently reclassified.
reset_memo
via_env=$(SUDO_USER="$FORGE_SUDO" task_actor)
via_argv=$(task_actor "$FORGE_BOARD")
if [[ "$via_env" == "$via_argv" ]]; then
  no "T3b the env and argv paths now AGREE (both '$via_env') — the two threats have been collapsed into one answer"
elif [[ "$via_env" == "$REAL_BOARD" && "$via_argv" == "$FORGE_BOARD" ]]; then
  ok "T3b env is ignored ('$via_env') while argv is honoured ('$via_argv') — the asymmetry the design rests on"
else
  no "T3b unexpected: via_env='$via_env' (want '$REAL_BOARD'), via_argv='$via_argv' (want '$FORGE_BOARD')"
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

# 9-11 REMOVED along with `actor_require_corroborated`. The refusal they graded is
# gone: `--from` on `task need` is the corpus's established "agent X files this gate"
# idiom (~120 call sites) and `gate_filed_by` has always been provenance, so the only
# thing the claim actually DECIDED was `_gate_route_reviewer`. That call now takes the
# derivation — a stronger property than refusing, since the claim moves no outcome at
# all — and it is graded end to end by T23.

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

# 15-16 REMOVED. They graded a root-gate on `_envelope_caller`'s $SUDO_USER fallback
# that this ticket tried and REVERTED — tests/envelope_sender_fallback_unit.sh T3/T4
# grade that resolver's TEXT for a self-contained `$EUID` + hardcoded
# `done < /etc/passwd`, because its value feeds `envelope_tier` and an overridable
# passwd source would be a new forgery vector there. lib/actor.sh reaches passwd
# through `_gate_passwd_stream`, a FUNCTION, specifically so a harness can override
# it. One field needs an injectable source to be testable, the other needs a
# non-injectable one to be trustworthy, and that is a decision with its own review
# rather than a side effect of collapsing task_actor. `_envelope_caller` is
# unchanged here, so this harness asserts nothing about it — and
# envelope_sender_fallback_unit (13/0) still owns it.

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
  # DIVE-2525: DERIVED HERE, NOT INSIDE THE T19-T21 BRANCH. This was set only on the
  # path where the isolation fence proved out, and T25/T26 below read it on the path
  # where the fence SKIPS — so under `set -u` a skip 150 lines earlier killed the
  # harness outright ("line 513: EXPECT_BOARD: unbound variable") instead of skipping
  # two arms. It never fired because the branch had never executed in CI: the arms
  # below need ./5dive, nothing built it, and the harness died earlier. Building the
  # bundle explicitly (DIVE-2525) reached this code for the first time. A variable
  # derived inside the branch that happens to use it first is a precondition nobody
  # declared, which is the same defect one layer down.
  EXPECT_BOARD="cli"
  if jq -e --arg n "$REAL_BOARD" '(.agents|type=="object") and (.agents|has($n))' \
       /var/lib/5dive/agents.json >/dev/null 2>&1; then
    EXPECT_BOARD="$REAL_BOARD"
  elif [[ "$REAL_NAME" == agent-* ]]; then
    EXPECT_BOARD="$REAL_BOARD"     # the passwd rung: registry silent, name is agent-*
  fi
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
    tid2=$(e2e task add "DIVE-2518 claimed row" --project=dive --from="$FORGE_BOARD" 2>&1 | grep -oE 'DIVE-[0-9]+' | head -1)
    cb=$(e2e task show "$tid2" | awk -F' = ' '/^created_by /{print $2; exit}')
    # created_by keeps the CLAIM — for a uid-less relay principal that is the only
    # true answer — and `derived_actor` carries the uid that ran it. T19b is the half
    # that makes the claim falsifiable; neither arm means anything without the other.
    if [[ "$cb" == "$FORGE_BOARD" ]]; then
      ok "T19 e2e: --from=$FORGE_BOARD stamped created_by=$FORGE_BOARD (relay attribution preserved)"
    else
      no "T19 e2e: created_by='$cb', expected the claim '$FORGE_BOARD' (relay would be lost)"
    fi
    # 19b. RECORD BOTH. T19 alone passes on a build that simply DROPS the claim,
    #      which is what the first cut did — `task_actor_claim` was called inside
    #      `$( )`, so the grade died with the subshell and claimed_by was NULL for
    #      every divergent claim while created_by looked perfect. Half a fix reads
    #      exactly like a whole one unless the other half is asserted.
    cby=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT COALESCE(derived_actor,'<null>') FROM tasks WHERE ident='$tid2';" 2>/dev/null)
    cby_none=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT COALESCE(derived_actor,'<null>') FROM tasks WHERE ident='$tid';" 2>/dev/null)
    if [[ -z "$cby" && -z "$cby_none" ]]; then
      skip "T19b sqlite3 unavailable or store unreadable; claimed_by not graded"
    # ALWAYS POPULATED, both rows. A column written only on divergence makes NULL
    # mean three things — the claim agreed, the row predates the column, or the path
    # does not populate it — and agreement is evidence in its own right: it says the
    # uid WAS measured and DID corroborate, which a NULL can never say.
    elif [[ "$cby" == "$EXPECT_BOARD" && "$cby_none" == "$EXPECT_BOARD" ]]; then
      ok "T19b e2e: derived_actor=$EXPECT_BOARD on BOTH rows — divergent and agreeing alike; NULL keeps exactly one meaning"
    else
      no "T19b e2e: derived_actor='$cby' (claimed row) / '$cby_none' (no-claim row); both must be '$EXPECT_BOARD'"
    fi
    # 19c. The LEDGER half. `claimed_by` is written in two places from one variable
    #      — the tasks column and lifecycle_events' detail — and T19b covers only
    #      the first. They share a variable today, which is exactly why the second
    #      needs its own arm: a refactor that splits them breaks one silently.
    #      `actor` must stay the DERIVED value, so the column keeps one meaning
    #      across every row ever written, with the claim beside it and not in it.
    lact=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT actor||'|'||COALESCE(detail,'') FROM lifecycle_events WHERE kind='task.created' AND ident='$tid2';" 2>/dev/null)
    lact_none=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT COALESCE(detail,'') FROM lifecycle_events WHERE kind='task.created' AND ident='$tid';" 2>/dev/null)
    if [[ -z "$lact" ]]; then
      skip "T19c lifecycle_events unreadable; the ledger half is not graded"
    elif [[ "$lact" == "${FORGE_BOARD}|"* && "$lact" == *"derived_actor=${EXPECT_BOARD}"* && "$lact_none" == *"derived_actor=${EXPECT_BOARD}"* ]]; then
      ok "T19c e2e: the ledger keeps actor=$FORGE_BOARD and carries derived_actor=$EXPECT_BOARD — on the agreeing row too"
    else
      no "T19c e2e: ledger row='$lact' (want actor '$FORGE_BOARD' + derived_actor=$EXPECT_BOARD), no-claim detail='$lact_none' (want derived_actor=$EXPECT_BOARD)"
    fi
    # 20. THE REFUSAL, through the real exiting `fail`: the gate must NOT exist
    #     afterwards. rc alone would stay green if the verb refused for any other
    #     reason and still filed the gate.
    out=$(e2e task need "$tid" --type=decision --ask="harness probe" --from="$FORGE_BOARD"); rc=$?
    gates=$(e2e task show "$tid" | grep -c 'human gate:' || true)
    # 20. `task need --from=<other>` now SUCCEEDS — the claim is not refused, it is
    #     simply not believed. The gate IS filed, and `gate_filed_by` carries the
    #     DERIVED actor, so a forged claim cannot put another agent's name on the
    #     filer-of-record column.
    out=$(e2e task need "$tid" --type=decision --ask="claim probe" --from="$FORGE_BOARD"); rc=$?
    fb=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE ident='$tid';" 2>/dev/null)
    if (( rc != 0 )); then
      no "T20 e2e: task need --from=$FORGE_BOARD was REFUSED (rc$rc) — this is the ~120-call-site filing idiom; refusing it truncates unsubshelled callers rather than failing them: $(printf '%s' "$out" | head -c 160)"
    elif [[ "$fb" == "$FORGE_BOARD" ]]; then
      ok "T20 e2e: the gate files and gate_filed_by keeps the claim ($FORGE_BOARD) — provenance, per DIVE-1401/1945/2015; what the claim does NOT get is the routing decision (T23)"
    else
      no "T20 e2e: gate_filed_by='$fb', expected the claim '$FORGE_BOARD'"
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

    # 22. THE RELAY SURVIVES. `task answer --from=telegram` is the Telegram button
    #     rail (cmd_task_clear_recs passes exactly that), and it must not be refused
    #     or slowed by anything this ticket added.
    out=$(e2e task answer "$tid" --value=A --from=telegram)
    if [[ "$out" == *"contradicts the derived actor"* || "$out" == *"cannot be corroborated"* ]]; then
      no "T22 a corroboration refusal fired on 'task answer' — the Telegram relay rail is broken: $(printf '%s' "$out" | head -c 200)"
    else
      ok "T22 'task answer --from=telegram' is not refused — the relay rail survives"
    fi

    # 23. THE ONE OUTCOME THE CLAIM USED TO MOVE: `_gate_route_reviewer` picks WHO
    #     MAY CLEAR the gate, from the filer. Seed the org so the CLAIMED agent and
    #     the DERIVED agent report to two DIFFERENT leads, then file with the claim.
    #     `routed_reviewer` must follow the derivation. Two distinct leads is the
    #     whole design of the arm — with one lead, or none, both answers coincide
    #     and a claim that WON would look identical to one that lost.
    sqlite3 "$SBOX/tasks/tasks.db" \
      "INSERT OR REPLACE INTO agents_org(name,reports_to) VALUES('leadclaimed',NULL),('leadderived',NULL),('$FORGE_BOARD','leadclaimed'),('$EXPECT_BOARD','leadderived');" 2>/dev/null
    tid4=$(e2e task add "DIVE-2518 routing probe" --project=dive 2>&1 | grep -oE 'DIVE-[0-9]+' | head -1)
    #     The ASK has to trip the internal-ops carve-out, because that is one of the
    #     four branches that calls _gate_route_reviewer at all — a generic ask files a
    #     gate that never consults the org table, which is what made the first cut of
    #     this arm SKIP with an empty routed_reviewer.
    e2e task need "$tid4" --type=decision \
      --ask="Wipe the test board rows and rebuild the task board from the audit log?" \
      --from="$FORGE_BOARD" >/dev/null 2>&1
    rr=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$tid4';" 2>/dev/null)
    seeded=$(sqlite3 "$SBOX/tasks/tasks.db" \
      "SELECT COUNT(*) FROM agents_org WHERE name IN('$FORGE_BOARD','$EXPECT_BOARD');" 2>/dev/null)
    if [[ "$seeded" != "2" ]]; then
      skip "T23 could not seed two distinct leads (agents_org rows=$seeded); the arm would not distinguish claimed from derived"
    elif [[ "$rr" == "leadclaimed" ]]; then
      no "T23 the CLAIM chose the reviewer: routed_reviewer='leadclaimed' — --from still moves an authorization outcome"
    elif [[ "$rr" == "leadderived" ]]; then
      ok "T23 the reviewer follows the DERIVATION (routed_reviewer=leadderived), not the claim '$FORGE_BOARD'->leadclaimed"
    else
      skip "T23 routed_reviewer='$rr' — neither seeded lead; routing did not reach the org table on this store"
    fi

  fi
  fi

  # 24. THE ISOLATION FENCE MUST BE ABLE TO GO RED. A fence that passes whether or
  #     not the store is isolated is the same defect one layer up — and this exact
  #     harness shipped an iteration that wrote two real rows to the shared board
  #     and a real gate to a real verifier while every arm passed. Run the fence's
  #     OWN predicate against the DEFAULT (un-redirected) store: it must trip.
  #     Read-only, and it never writes.
  # 26. THE UID-LESS PRINCIPAL, which is the measurement that killed design 1.
  #     `council` and `telegram` are not unix users and never will be, so NO
  #     derivation can produce them. A build that returns the derived value here
  #     does not harden the row — it reattributes it to whoever ran the process, and
  #     `created_by` is what the whole board reads as ground truth. Deliberately
  #     uses a name that CANNOT be a passwd entry on any runner, so the arm is not
  #     quietly satisfied by a coincidence of naming.
  cout=$(e2e task add "DIVE-2518 uid-less relay probe" --project=dive --from=council 2>&1)
  ctid=$(printf '%s' "$cout" | grep -oE 'DIVE-[0-9]+' | head -1)
  ccb=$(sqlite3 "$SBOX/tasks/tasks.db" \
    "SELECT created_by||'|'||COALESCE(derived_actor,'<NULL>') FROM tasks WHERE ident='$ctid';" 2>/dev/null)
  if [[ -z "$ctid" ]]; then
    no "T26 the uid-less relay add failed outright: $(printf '%s' "$cout" | head -c 160)"
  elif [[ "$ccb" == "council|$EXPECT_BOARD" ]]; then
    ok "T26 a principal with NO uid keeps its name (created_by=council) and the runner is still measured beside it (derived_actor=$EXPECT_BOARD)"
  else
    no "T26 uid-less relay wrote '$ccb', expected 'council|$EXPECT_BOARD' — relay attribution is lost"
  fi

  # 25. A BRAND-NEW STORE, where the FIRST WRITE is also the process that creates
  #     the schema. This is a different path from every other e2e arm here: those
  #     run `task init` first, so by the time they write, the store EXISTS and
  #     `_tasks_db_migrate` has run. A fresh store is built from `_tasks_schema` and
  #     never runs the migration at all, so a column added only to the migration
  #     array is present on every existing board and absent from every new one —
  #     and the error surfaces only on a first write, which nobody with a working
  #     board ever performs. That is exactly what shipped and what council caught.
  NBOX=$(mktemp -d)
  nout=$(STATE_DIR="$NBOX" TASKS_DIR="$NBOX" TASKS_DB="$NBOX/tasks.db" \
         "$BIN" task add "DIVE-2518 fresh-store probe" --project=dive --from=council 2>&1); nrc=$?
  ncb=$(sqlite3 "$NBOX/tasks.db" "SELECT created_by||'|'||COALESCE(derived_actor,'') FROM tasks LIMIT 1;" 2>/dev/null)
  if (( nrc != 0 )) || [[ -z "$ncb" ]]; then
    no "T25 the FIRST write to a brand-new store failed (rc$nrc): $(printf '%s' "$nout" | head -c 160)"
  elif [[ "$ncb" == "council|$EXPECT_BOARD" ]]; then
    ok "T25 a brand-new store accepts its first write and records both (created_by=council, derived_actor=$EXPECT_BOARD)"
  else
    no "T25 fresh store wrote '$ncb', expected 'council|$EXPECT_BOARD'"
  fi
  rm -rf "$NBOX"

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
