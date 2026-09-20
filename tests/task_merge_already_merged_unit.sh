#!/usr/bin/env bash
# `task merge` closes a row whose pull request the maintainer ALREADY
# MERGED, without the machine-account credential.
#
# THE DEFECT. `_merge_do` demanded `$_GH_BOT_ENV` unconditionally, after standing
# and before anything had read the pull request. On a box with no bot connector a
# row whose pull request the MAINTAINER merged — the normal case for an outside
# contributor, who holds no merge right in the target repo — was closable by
# nobody: this verb wanted a credential to perform a merge that had already
# happened, `task done` refused (DIVE-4520 / DIVE-1830), `--force-redeliver`
# wants delivery fields, and `task assign` is refused when the closer is the
# verifier. Measured on DIVE-549 / 5dive-ai/5dive#998, 2026-09-17.
#
# WHAT IS EXECUTED HERE, AND WHAT IS NOT. `cmd_task_merge_do` is root-only behind
# a sudo hop, so this file cannot run it. It runs the two functions the fix put
# the decision in — `_merge_landed_read` (over a stubbed `gh`) and
# `_merge_do_already_landed` — plus `_merge_disp_read` and `cmd_task_merge` over
# a stubbed `sudo`. The one property no fixture can execute is the branch's
# POSITION relative to the credential demand, so that is asserted by LINE NUMBER
# in the real source, which moves when an edit moves it. This split is deliberate
# and is the DIVE-4428 iteration-2 lesson: a branch graded by grepping for its
# strings is not graded at all, and two mutants with every string intact survived
# that suite.
# DIVE-2211: name the tree this harness grades. Sourced BEFORE the cd, from
# BASH_SOURCE, so the tree named is the one this FILE lives in rather than $PWD.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-merge-already-merged.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"   # never the host's /var/log/5dive layout
mkdir -p "$TASKS_DIR"; set +e
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init

PR=https://github.com/5dive-ai/5dive/pull/998
SHA=9f3c1d77c0e14a2b5d6e8f0a1b2c3d4e5f607182
AT=2026-09-17T14:21:03Z

# ---------------------------------------------------------------------------
# The stub rail. `_gate_gh` is what `_merge_landed_read` calls; stubbing THAT
# rather than the `gh` binary keeps the token argument observable, which is the
# whole claim of this fix — the read is made with an EMPTY credential.
# ---------------------------------------------------------------------------
# The token is recorded in a FILE, not a variable: every call below is made
# inside a command substitution, which is a subshell, and a variable set there
# does not reach this scope. An arm that reads such a variable grades nothing.
TOKF="$TMP/tok"
_gate_gh_payload=""; _gate_gh_rc=0
_gate_gh() { printf '[%s]' "$1" >"$TOKF"; shift 2
             [[ -n "$_gate_gh_payload" ]] && printf '%s\n' "$_gate_gh_payload"
             return "$_gate_gh_rc"; }

# --- 1. THE READ ------------------------------------------------------------
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0
got=$(_merge_landed_read "$PR" 5dive-ai/5dive)
[[ "$got" == "$SHA|$AT" ]] \
  && ok_t "T1 a merged pull request reads back its merge sha and its mergedAt" \
  || bad_t "T1 merged read" "got '$got'"
[[ "$(cat "$TOKF" 2>/dev/null)" == "[]" ]] \
  && ok_t "T1b THE CLAIM OF THIS FIX: the read went out with an EMPTY token — no machine account was resolved to ask what a pull request IS" \
  || bad_t "T1b credential-free read" "token seen: '$(cat "$TOKF" 2>/dev/null)' (expected the empty string, bracketed)"

_gate_gh_payload="OPEN|null|null"; _gate_gh_rc=0
[[ -z "$(_merge_landed_read "$PR" 5dive-ai/5dive)" ]] \
  && ok_t "T2 an OPEN pull request reads back nothing — there is still a merge to perform" \
  || bad_t "T2 open reads empty" ""

# A closed-unmerged PR and a queue-evicted one both carry a sha-shaped field or a
# state, and NEITHER carries a mergedAt. mergedAt is the operand for that reason.
_gate_gh_payload="CLOSED|null|null"; _gate_gh_rc=0
[[ -z "$(_merge_landed_read "$PR" 5dive-ai/5dive)" ]] \
  && ok_t "T2b a CLOSED-unmerged pull request reads back nothing either (DIVE-4337: state cannot answer this, mergedAt can)" \
  || bad_t "T2b closed reads empty" ""

_gate_gh_payload=""; _gate_gh_rc=1
[[ -z "$(_merge_landed_read "$PR" 5dive-ai/5dive)" ]] \
  && ok_t "T3 FAILS TOWARDS TODAY: a GitHub that cannot be asked reads back nothing, so the caller lands on the credential demand rather than on a quiet success" \
  || bad_t "T3 unreachable reads empty" ""

_gate_gh_payload="OPEN|$SHA|"; _gate_gh_rc=0
[[ -z "$(_merge_landed_read "$PR" 5dive-ai/5dive)" ]] \
  && ok_t "T3b a sha with an EMPTY mergedAt is not a landing either" \
  || bad_t "T3b empty mergedAt" ""

# --- 1b. THE PROBE'S THREE ANSWERS (DIVE-4701) ------------------------------
# `_merge_landed_read` above collapses "not landed" and "could not be asked" into
# one empty string, which is right for the verb and wrong for a POLLER: the tick
# must report an unreachable rail as a standing condition and must never report
# an open pull request as one. `_merge_landed_probe` is the single reader both
# now share, so these arms grade the distinction the sweep depends on. The
# separator is x1f, so each expectation is written with the literal byte.
US=$'\x1f'
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0
[[ "$(_merge_landed_probe "$PR" 5dive-ai/5dive)" == "MERGED${US}${SHA}${US}${AT}" ]] \
  && ok_t "T3c the probe reports MERGED with the sha and the mergedAt" \
  || bad_t "T3c probe merged" "got '$(_merge_landed_probe "$PR" 5dive-ai/5dive)'"

_gate_gh_payload="OPEN|null|null"; _gate_gh_rc=0
[[ "$(_merge_landed_probe "$PR" 5dive-ai/5dive)" == "OPEN${US}OPEN" ]] \
  && ok_t "T3d AN OPEN PULL REQUEST IS A VERDICT, NOT A SILENCE — the probe says OPEN and names the state, so a poller never files it as an unreadable rail" \
  || bad_t "T3d probe open" "got '$(_merge_landed_probe "$PR" 5dive-ai/5dive)'"

_gate_gh_payload="CLOSED|null|null"; _gate_gh_rc=0
[[ "$(_merge_landed_probe "$PR" 5dive-ai/5dive)" == "OPEN${US}CLOSED" ]] \
  && ok_t "T3e a CLOSED-unmerged pull request is OPEN to this probe (the verdict is about the LANDING) and still carries its real state" \
  || bad_t "T3e probe closed" "got '$(_merge_landed_probe "$PR" 5dive-ai/5dive)'"

_gate_gh_payload=""; _gate_gh_rc=1
[[ "$(_merge_landed_probe "$PR" 5dive-ai/5dive)" == "UNKNOWN${US}" ]] \
  && ok_t "T3f a GitHub that cannot be asked is UNKNOWN — distinguishable from OPEN, which is the whole reason this function exists" \
  || bad_t "T3f probe unknown" "got '$(_merge_landed_probe "$PR" 5dive-ai/5dive)'"

# THE SHORT-RECORD GUARD. A rail that answers with something other than the three
# fields asked for must be UNKNOWN, not a verdict assembled out of the wrong
# fields — UNKNOWN and OPEN both change nothing, but MERGED WRITES.
_gate_gh_payload="$SHA|$AT"; _gate_gh_rc=0
[[ "$(_merge_landed_probe "$PR" 5dive-ai/5dive)" == "UNKNOWN${US}" ]] \
  && ok_t "T3g a TWO-field record (rail/format drift) is UNKNOWN, never a landing read out of the wrong field positions" \
  || bad_t "T3g probe short record" "got '$(_merge_landed_probe "$PR" 5dive-ai/5dive)'"
[[ -z "$(_merge_landed_read "$PR" 5dive-ai/5dive)" ]] \
  && ok_t "T3h ...and the verb reads nothing from it either" || bad_t "T3h short record via verb" ""

# --- 2. THE DECISION --------------------------------------------------------
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0
out=$(_merge_do_already_landed "$PR" 2>&1); rc=$?
(( rc == 0 )) \
  && ok_t "T4 a landed pull request short-circuits the primitive (rc 0 — the caller returns before the credential demand)" \
  || bad_t "T4 landed returns 0" "rc=$rc"
[[ "$out" == *"_merge_do: disposition=already-merged"* ]] \
  && ok_t "T4a ...and writes the disposition marker its two callers read" || bad_t "T4a marker" "$out"
[[ "$out" == *"$SHA"* && "$out" == *"$AT"* ]] \
  && ok_t "T4b ...naming the sha and the time, so the operator line is a measurement" || bad_t "T4b sha/time" "$out"
[[ "$out" == *"NOTHING WAS MERGED"* && "$out" == *"no machine account was used"* ]] \
  && ok_t "T4c ...and says plainly that it performed nothing — this seat is not credited with the maintainer's merge" \
  || bad_t "T4c performed-nothing wording" "$out"

_gate_gh_payload="OPEN|null|null"; _gate_gh_rc=0
out=$(_merge_do_already_landed "$PR" 2>&1); rc=$?
(( rc == 1 )) \
  && ok_t "T5 AN OPEN PULL REQUEST CARRIES ON (rc 1) — the credential demand is untouched on every row with a merge left to perform" \
  || bad_t "T5 open carries on" "rc=$rc out=$out"
[[ -z "$out" ]] && ok_t "T5a ...silently, claiming no disposition it did not achieve" || bad_t "T5a silent" "$out"

_gate_gh_rc=1; _gate_gh_payload=""
out=$(_merge_do_already_landed "$PR" 2>&1); rc=$?
(( rc == 1 )) && ok_t "T5b an unreachable GitHub carries on too (rc 1)" || bad_t "T5b unreachable carries on" "rc=$rc"

# --- 3. THE DISPOSITION READER ---------------------------------------------
[[ "$(_merge_disp_read 0 'x
_merge_do: disposition=already-merged
y')" == "already-merged" ]] \
  && ok_t "T6 the ONE reader maps the new marker to already-merged" || bad_t "T6 reader already-merged" ""
[[ "$(_merge_disp_read 0 '_merge_do: disposition=enqueued')" == "enqueued" ]] \
  && ok_t "T6a ...and still reads an enqueue as an enqueue (DIVE-4428 unregressed)" || bad_t "T6a enqueued" ""
[[ "$(_merge_disp_read 0 'merged at last')" == "merged" ]] \
  && ok_t "T6b ...and a real merge as a merge" || bad_t "T6b merged" ""
[[ -z "$(_merge_disp_read 1 '_merge_do: disposition=already-merged')" ]] \
  && ok_t "T6c A REFUSAL STILL ACHIEVES NO DISPOSITION — rc is read before the marker, so a refused rail cannot report a landing" \
  || bad_t "T6c refusal names nothing" ""

# --- 4. THE VERB, over a stubbed sudo ---------------------------------------
db "INSERT INTO tasks(ident,title,status,created_by,maker_agent,graded_at,graded_by,
     graded_verdict,delivery_ref,merge_owner,merge_hold_reason)
    VALUES('DIVE-900','t','in_progress','luca','dev','2026-09-17 09:00:00','quinn',
     'pass','$PR','quinn','hold:merger:credential');"

SUDO_OUT=""; SUDO_RC=0
# `cmd_task_merge` makes TWO sudo calls on a refusal: the primitive, and then
# `sudo -n -l <path>` to tell "refused" apart from "this seat has no grant".
# A stub that fails both makes every refusal arm grade the grant message instead
# of the refusal it was written for — which is what the first run of this file
# did.
sudo() { for a in "$@"; do [[ "$a" == "-l" ]] && return 0; done
         printf '%s\n' "$SUDO_OUT" >&2; return "$SUDO_RC"; }
task_actor_claim() { ACTOR_BOARD=quinn; }
task_actor() { printf 'quinn\n'; }

SUDO_OUT="$PR is ALREADY MERGED upstream as $SHA at $AT — NOTHING WAS MERGED by this call and no machine account was used. Recording the landing that already happened.
_merge_do: disposition=already-merged"; SUDO_RC=0
out=$(cmd_task_merge DIVE-900 2>&1); rc=$?
(( rc == 0 )) && ok_t "T7 task merge exits 0 on a row whose pull request already merged, with NO credential on the box" \
  || bad_t "T7 rc" "rc=$rc out=$out"
[[ "$out" == *"ALREADY MERGED"* && "$out" == *"NO MERGE PERFORMED"* ]] \
  && ok_t "T7a ...and its operator line says what happened, not that this seat merged it" || bad_t "T7a wording" "$out"
[[ "$(db "SELECT COALESCE(merge_owner,'-')||'/'||COALESCE(merge_hold_reason,'-') FROM tasks WHERE ident='DIVE-900';")" == "-/-" ]] \
  && ok_t "T7b THE RECORD: the merge hold is retired — a landed pull request is owed a merge by nobody, so the board stops painting an action no seat can take" \
  || bad_t "T7b hold retired" "$(db "SELECT merge_owner||'/'||merge_hold_reason FROM tasks WHERE ident='DIVE-900';")"

# The negative the ticket asks for: an OPEN pull request with no credential is
# refused EXACTLY as it is today. This arm is what stops the fix from becoming a
# way to close a row whose work has not landed.
db "UPDATE tasks SET merge_owner='quinn', merge_hold_reason='hold:merger:credential' WHERE ident='DIVE-900';"
SUDO_OUT="machine-account credential missing (/etc/5dive/connectors/github-bot.env) — 5dive secret write GH_BOT_TOKEN --connector=github-bot"; SUDO_RC=1
out=$(cmd_task_merge DIVE-900 2>&1); rc=$?
(( rc != 0 )) \
  && ok_t "T8 THE NEGATIVE: an OPEN pull request with no machine account is still REFUSED, unchanged" || bad_t "T8 open refused" "rc=$rc"
[[ "$out" == *"machine-account credential missing"* ]] \
  && ok_t "T8a ...with the same refusal text, so the remedy a reader acts on did not move" || bad_t "T8a refusal text" "$out"
[[ "$(db "SELECT COALESCE(merge_owner,'-') FROM tasks WHERE ident='DIVE-900';")" == "quinn" ]] \
  && ok_t "T8b ...and NOTHING was written: the hold a refused merge leaves is still on the row" || bad_t "T8b hold intact" ""

# --- 5. POSITION. The one property no fixture can execute -------------------
# Asserted against the REAL source by line number, so an edit that moves the
# credential demand back above the read is a failing test rather than a silent
# regression to the defect.
f=src/task/delivery.sh
call_ln=$(grep -n '^  _merge_do_already_landed "\$pr" && return 0$' "$f" | head -1 | cut -d: -f1)
cred_ln=$(grep -n '^  \[\[ -r "\$_GH_BOT_ENV" \]\]' "$f" | head -1 | cut -d: -f1)
stand_ln=$(grep -n 'holds no merge standing on' "$f" | head -1 | cut -d: -f1)
[[ -n "$call_ln" && -n "$cred_ln" && -n "$stand_ln" ]] \
  && ok_t "T9 all three landmarks are findable in $f (call=$call_ln cred=$cred_ln standing=$stand_ln)" \
  || bad_t "T9 landmarks" "call='$call_ln' cred='$cred_ln' standing='$stand_ln'"
[[ -n "$call_ln" && -n "$cred_ln" ]] && (( call_ln < cred_ln )) \
  && ok_t "T9a THE ORDER THAT IS THE FIX: the landed-read runs BEFORE the credential demand" \
  || bad_t "T9a read before credential" "call=$call_ln cred=$cred_ln"
[[ -n "$call_ln" && -n "$stand_ln" ]] && (( stand_ln < call_ln )) \
  && ok_t "T9b ...and AFTER standing, so it widens no authority: a row that fails the standing query never reaches it" \
  || bad_t "T9b standing before read" "standing=$stand_ln call=$call_ln"

# --- 6. MUTANT: put the defect back and require this file to go red ----------
MUT="$TMP/mut"; mkdir -p "$MUT"
cp "$f" "$MUT/delivery.sh"
# The mutation is the revert: the early read is removed from the primitive, which
# is the tree as it stood before this change.
sed -i 's@^  _merge_do_already_landed "\$pr" \&\& return 0$@  : MUTANT-early-read-reverted@' "$MUT/delivery.sh"
m_hits=$(grep -c '^  : MUTANT-early-read-reverted$' "$MUT/delivery.sh")
[[ "$m_hits" == "1" ]] \
  && ok_t "M0a BEFORE — the mutation substituted the early read EXACTLY ONCE" || bad_t "M0a substitution count" "hits=$m_hits"
[[ -z "$(grep -n '^  _merge_do_already_landed "\$pr" && return 0$' "$MUT/delivery.sh")" ]] \
  && ok_t "M0b ...and the line it replaces is GONE, so the revert is real and not an addition" || bad_t "M0b line gone" ""
m_diff=$(diff <(cat "$f") <(cat "$MUT/delivery.sh") | grep -c '^[<>]')
[[ "$m_diff" == "2" ]] \
  && ok_t "M0c ...and the mutant is otherwise the shipped file, exactly one line different" || bad_t "M0c diff size" "changed lines=$m_diff"
bash -n "$MUT/delivery.sh" \
  && ok_t "M0d ...and the mutant is still valid bash — a working primitive, not a syntax error" || bad_t "M0d mutant parses" ""
# T9a, run against the mutant, must FAIL: that is this file going red on the defect.
m_call=$(grep -n '^  _merge_do_already_landed "\$pr" && return 0$' "$MUT/delivery.sh" | head -1 | cut -d: -f1)
[[ -z "$m_call" ]] \
  && ok_t "M1 MUTANT — T9a is RED on it: there is no landed-read before the credential demand, which is the defect, live" \
  || bad_t "M1 mutant red on T9a" "found call at $m_call"
# ...while the functions themselves are untouched, so the mutant is a primitive
# that differs in exactly this case rather than a broken file.
grep -q '^_merge_landed_read() {' "$MUT/delivery.sh" && grep -q '^_merge_do_already_landed() {' "$MUT/delivery.sh" \
  && ok_t "M2 MUTANT — the reader and the decider still exist and still work; only the CALL SITE moved (T1/T4 stay green on it)" \
  || bad_t "M2 mutant keeps helpers" ""
printf 'M0/M1/M2 graded the mutant; the shipped file at %s is unmodified\n' "$f" >/dev/null

printf -- '-----\n'
printf 'task_merge_already_merged: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
