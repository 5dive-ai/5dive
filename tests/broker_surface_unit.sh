#!/usr/bin/env bash
# TIER: core — 2.4s measured (DIVE-2525, CI): fits the 300s PR core; stated, not defaulted.
# DIVE-2801 added section 10 (18 arms). Cost of the ADDITION, measured as a paired
# delta rather than an absolute so the box cancels: same host, interleaved runs,
# origin/main@828c1ea 2.98s vs this branch 3.23s -> +0.25s (control plane,
# 2026-08-05, `date +%s%N` either side of `bash tests/broker_surface_unit.sh`).
# The 2.4s above is a CI number and is deliberately NOT overwritten with a
# control-plane one — the two environments are not interchangeable, and a delta
# transfers between them where an absolute does not.
# tests/broker_surface_unit.sh — INST-5.
#
# Two questions, and the first is the one that decides whether this refactor was
# safe to make at all.
#
# 1. IS THE PUSH PATH INERT? `_push_gate_check` and `_push_bind_branch` are the
#    predicates that stand between a granted agent and a git write. INST-5 moved
#    their bodies into lib/broker.sh and left one-line wrappers behind. "I only
#    parameterized the nouns" is exactly the claim that is cheap to assert and
#    expensive to be wrong about, so this file does not assert it — it MEASURES
#    it, differentially, against origin/main's own copies of those functions,
#    driving BOTH implementations through the same fixture states and comparing
#    the refusal text and the exit status byte for byte.
#
# 2. IS THE PARAMETERIZATION ACTUALLY LIVE? A differential test that passes
#    because both sides are equally dead is the standard way this shape lies. So
#    every string arm is paired with a liveness arm: the SAME predicate, on the
#    SAME state, under the `deploy` surface must say "deploy" where push says
#    "push" — and the case set must produce distinct messages, or the harness is
#    grading one sentence six times.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2549: the differential baseline is PINNED, not branch-named. See the
# block at "the baseline" below for why. Unlike grading_tree.sh this helper is
# load-bearing — without it there is no baseline at all — so a missing copy
# refuses rather than warning.
. "$(dirname "${BASH_SOURCE[0]}")/lib/pinned_baseline.sh" || {
  echo "REFUSING: tests/lib/pinned_baseline.sh is not reachable — the differential arms have no baseline resolver."
  exit 1
}

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
want() { local n="$1"; shift; if eval "$@"; then echo "  ok   $n"; PASS=$((PASS+1)); else echo "  FAIL $n"; FAIL=$((FAIL+1)); fi; }
same() { # <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"; PASS=$((PASS+1));
  else echo "  FAIL $1"; echo "    old: $2"; echo "    new: $3"; FAIL=$((FAIL+1)); fi
}

TMP=$(mktemp -d)

# RETIRED (DIVE-2645): section 1 was a pinned-baseline differential proving the
# INST-5 wrapper refactor left push's refusals byte-identical. That refactor is
# merged and was proven inert; the class it guarded — a refactor silently moving
# push's behaviour — can no longer occur. What the arms had become was a freeze on
# refusal TEXT: any deliberate edit reds them, and the pin must predate INST-5, so
# no pin can ever carry the new text. Sections 2-7 below grade live behaviour and
# are kept.

# ------------------------------------------------------------------- the stubs
E_VALIDATION=2; E_USAGE=1; E_GENERIC=1; E_PERMISSION=3
warn() { printf 'warn: %s\n' "$*" >&2; }
fail() { printf '%s\n' "$2"; exit 9; }
# One fixture row, addressed by column name pulled out of the SQL. Both
# implementations issue the identical SELECTs, so one stub serves both.
declare -A ROW=()
db() {
  local col; col=$(sed -nE 's/.*COALESCE\(([a-z_]+),.*/\1/p' <<<"$1")
  printf '%s' "${ROW[$col]:-}"
}
# DIVE-2801: the stub now models the real function's FIRST LINE — `[[ -n "$sig" ]]
# || return 1`. It used to return CLOSURE_RC unconditionally, i.e. it reported a
# valid closure for a row with no signature at all, which is the one input this
# section is about. A stub that differs from its subject on the very case under
# test scores the arm, not the code.
_gate_closure_verify() { [[ -n "${7:-}" ]] || return 1; return "${CLOSURE_RC:-0}"; }
_gate_agent_for_uid()  { printf '%s' "${UID_AGENT:-}"; }
# DIVE-2614: broker_gate_check now audit_logs the rejected-gate refusal before
# fail()ing. This harness doesn't source lib/audit.sh, so stub it. `run()`
# below exercises broker_gate_check in a subshell (to contain fail()'s exit),
# so a plain array wouldn't survive back to the parent shell — a file does.
AUDIT_LOG_CALLS="$TMP/audit_log_calls"
: > "$AUDIT_LOG_CALLS"
audit_log() { printf '%s\n' "$*" >> "$AUDIT_LOG_CALLS"; }

# shellcheck source=../src/lib/broker.sh
. "$ROOT/src/lib/broker.sh"
# shellcheck source=/dev/null
# The new wrappers, taken from the real file rather than retyped here.
eval "$(awk '/^_push_gate_check\(\) \{/,/^\}$/' "$ROOT/src/cmd_push.sh")"
eval "$(awk '/^_push_bind_branch\(\) \{/,/^\}$/' "$ROOT/src/cmd_push.sh")"
eval "$(awk '/^_push_task_branch\(\) \{/,/^\}$/' "$ROOT/src/cmd_push.sh")"

run() { ( "$@" ) 2>/dev/null; printf 'rc=%s' "$?"; }

# DIVE-2801: the default fixture now carries a closure SIGNATURE. Every arm below
# that is about something else — verdict parsing, authorization provenance, target
# binding — used to leave this column empty incidentally, and an empty signature is
# now a refusal in its own right at require_sig=0. Seeding it keeps those arms
# measuring their own subject; the arms that are ABOUT the empty column clear it
# explicitly (== 10 below), which is also what makes the seed non-vacuous.
reset_row() { ROW=( [need_type]="" [need_answered_at]="" [need_answer]="" \
                    [need_answered_by]="" [need_answered_uid]="" [need_answer_sig]="sig-fixture" \
                    [routed_reviewer]="" [body]="" ); CLOSURE_RC=0; UID_AGENT=""; }

echo "== 2. the parameterization is LIVE, not dead: deploy says deploy"
reset_row
d_nogate=$(run broker_gate_check deploy 7 DIVE-7)
p_nogate=$(run broker_gate_check push   7 DIVE-7)
want "deploy's no-gate refusal names deploy"  '[[ "$d_nogate" == *"deploy-for-review gate"* ]]'
want "push's no-gate refusal still names push" '[[ "$p_nogate" == *"push-for-review gate"* ]]'
want "the two differ (the surface argument is load-bearing)" '[[ "$d_nogate" != "$p_nogate" ]]'
want "deploy suggests its own --ask, not push's" \
     '[[ "$d_nogate" == *"approve production deploy of <project>@<ref>"* ]]'

reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes; ROW[need_answered_by]=agent-dev
d_unauth=$(run broker_gate_check deploy 7 DIVE-7)
want "deploy's unauthorized refusal says 'delegated deploy'" '[[ "$d_unauth" == *"delegated deploy accepts"* ]]'

echo
echo "== 3. deploy binds to ITS OWN body key, and a push task cannot satisfy it"
reset_row; ROW[body]=$'Branch: feat/a\nDeploy: app@feat/a\n'
want "deploy reads the Deploy: line"  '[[ "$(broker_task_target deploy 7)" == "app@feat/a" ]]'
want "push still reads the Branch: line" '[[ "$(broker_task_target push 7)" == "feat/a" ]]'
b_ok=$(run broker_bind_target deploy 7 DIVE-7 "app@feat/a")
b_no=$(run broker_bind_target deploy 7 DIVE-7 "other@feat/a")
want "the declared deploy target binds"  '[[ "$b_ok" == "rc=0" ]]'
want "a DIFFERENT project is refused"    '[[ "$b_no" == *"is not the deploy target bound to DIVE-7"* ]]'
want "…and the refusal cites the declared value, not the requested one" \
     '[[ "$b_no" == *"(&#39;app@feat/a&#39;)"* || "$b_no" == *"('"'"'app@feat/a'"'"')"* ]]'
reset_row; ROW[body]=$'Branch: feat/a\n'
b_unb=$(run broker_bind_target deploy 7 DIVE-7 "app@feat/a")
want "a task with ONLY a Branch: line cannot authorize a deploy" \
     '[[ "$b_unb" == *"declares no deploy target"* ]]'

echo
echo "== 4. an unknown surface is a hard failure, never an empty noun"
u=$(run broker_surface bananas noun)
want "unknown surface fails loudly" '[[ "$u" == *"unknown surface/field"* ]]'
# Subshell parens deliberate: `want` evals in THIS shell, so a bare `exit` here
# would end the harness with status 0 and skip the tally (see the same note in
# tests/capability_registry_unit.sh — it cost a vacuous mutation pass there).
want "every surface in broker_surfaces resolves every field" \
     '( for s in $(broker_surfaces); do for f in noun Noun cap verb key target ask ticket; do [[ -n "$(broker_surface "$s" "$f")" ]] || exit 1; done; done )'

# == 6. every consumer of the broker asserts the broker is LOADED (INST-5).
# The consumer list is DERIVED from the tree, never hand-written: a seventh
# surface folded in later gets swept automatically, which is the whole point —
# a hand list would go stale exactly when a new surface is added. A consumer
# that calls a broker predicate without require_loaded is the fail-open shape
# CI caught on this branch (push reporting "gate cleared" on an unread gate).
echo "== 6. brokered surfaces fail closed when lib/broker.sh is absent"
_consumers=$(grep -rlE '(^|[^_[:alnum:]])broker_(gate_check|bind_target|task_target)\b' \
               "$ROOT/src" --include='cmd_*.sh' | sort)
want "the derived consumer sweep is non-vacuous (found at least push + deploy)" \
     '[[ "$(printf "%s\n" "$_consumers" | grep -c .)" -ge 2 ]]'
for _c in $_consumers; do
  want "$(basename "$_c") guards its broker calls with require_loaded" \
       'grep -q "require_loaded" "$_c"'
done
# And the guard itself must live OUTSIDE lib/broker.sh — a check for a missing
# file cannot be defined in the file that might be missing.
want "require_loaded is not defined in lib/broker.sh" \
     '! grep -q "^require_loaded()" "$ROOT/src/lib/broker.sh"'
want "require_loaded is defined in header.sh (always first in the bundle)" \
     'grep -q "^require_loaded()" "$ROOT/src/header.sh"'

# == 7. no harness loads a broker CONSUMER without lib/broker.sh (INST-5).
# This is how the branch broke: tests/ harnesses hand-maintain a source list
# mirroring build.sh, and a new lib is invisible to every one of them. push_unit
# and gate_lead_standing failed loudly because they CALL cmd_push; 18 others
# sourced cmd_push.sh and stayed green only because they never called it —
# latent, and the next arm added to any of them would have graded through a
# missing predicate. Derived from the tree, so it also covers surface N+1.
echo "== 7. every harness sourcing a broker consumer also sources lib/broker.sh"
_bad=""
for _t in "$ROOT"/tests/*.sh; do
  awk '/for f in/,/; do/' "$_t" | grep -qE 'cmd_push\.sh|cmd_deploy\.sh' || continue
  grep -q 'lib/broker.sh' "$_t" || _bad="$_bad $(basename "$_t")"
done
want "no harness sources a broker consumer without lib/broker.sh" '[[ -z "$_bad" ]]'
[[ -n "$_bad" ]] && echo "    missing:$_bad"
# Non-vacuity: the sweep must actually be finding harnesses to check, or it
# passes by inspecting nothing — the exact way this check could rot silently.
_seen=$(for _t in "$ROOT"/tests/*.sh; do
          awk '/for f in/,/; do/' "$_t" | grep -qE 'cmd_push\.sh|cmd_deploy\.sh' && echo x
        done | grep -c x)
want "non-vacuity: the harness sweep inspected at least 15 harnesses (saw $_seen)" \
     '[[ "$_seen" -ge 15 ]]'

echo
echo "== 8. DIVE-2614: verdict is read off the FIRST LINE ONLY, as a WHOLE WORD"
# Each case is authorized (human:lodar) so a rc=0 unambiguously means the
# reject-check let it through; these are direct broker_gate_check calls, not
# the old/new differential above — the pinned baseline still carries the bug,
# so diffing against it here would assert the fix never happened.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]=$'approve — ship it.\nNote: this line used to trip the prefix list.'
ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "a later line beginning 'Note:' no longer inverts a first-line approval" '[[ "$out" == "rc=0" ]]'

reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Nothing blocks this"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "'Nothing' no longer prefix-matches 'no'" '[[ "$out" == "rc=0" ]]'

reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Blocking issues: none"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "'Blocking' no longer prefix-matches 'block'" '[[ "$out" == "rc=0" ]]'

reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="non-agent, same sha: exit 0, 12 arms"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "'non-agent' no longer prefix-matches 'no'" '[[ "$out" == "rc=0" ]]'

reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Reject as-is — rebase first"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "a genuine first-line reject ('Reject as-is') still refuses" \
     '[[ "$out" == *"REJECTED"* && "$out" == *"rc=9" ]]'

# "not" was never one of the five stems (no|reject|deny|denied|block) — it only
# ever tripped via the OLD "no" prefix bug, the same bug that caught "Note"/
# "Nothing"/"None". Required property #2 in DIVE-2614 names "Not" explicitly
# among the words that must stop reading as a veto, so this is the intended
# behavior change, not a miss — though it means a real reject that opens with
# a bare "Not ..." (DIVE-2577's "NOT AS-IS — rebase first" is exactly this
# shape) now needs "no"/"reject"/"deny"/"denied"/"block" as its actual first
# word to be caught. Flagged, not silently resolved: see the DIVE-2614 result.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Not a blocker"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "'Not' alone no longer prefix-matches 'no' (required property #2)" '[[ "$out" == "rc=0" ]]'

# main (2026-08-04, reviewing this same fix): `head -n1` reads "line 1", not
# "the first line" — the moment line 1 is blank/whitespace, a genuine
# rejection on a LATER line cleared the gate. A false APPROVE is worse than
# the false REJECT this row exists to fix, and it lands on cmd_deploy.sh too.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]=$'\nNo — rejected'; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "a leading blank line no longer hides a rejection on line 2" \
     '[[ "$out" == *"REJECTED"* && "$out" == *"rc=9" ]]'

reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]=$'  \nrejected, do not push'; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "a whitespace-only line 1 no longer hides 'rejected' on line 2" \
     '[[ "$out" == *"REJECTED"* && "$out" == *"rc=9" ]]'

# "rejected" needs its own stem, same as deny/denied already had — with a
# word boundary, "reject" (no trailing \b match into "...ed") no longer
# prefix-matches "rejected", so the inflected form would silently stop
# tripping without this entry.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Rejected — needs another pass"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "'Rejected' (inflected) still refuses, not just bare 'Reject'" \
     '[[ "$out" == *"REJECTED"* && "$out" == *"rc=9" ]]'

# main (2026-08-04, second review pass): "block" was left bare while
# reject/rejected and deny/denied were both split — with the word boundary,
# "block" no longer prefix-matches "blocked" ('k' then 'e', both word chars,
# no boundary), the exact same inflection gap as "rejected". "Blocked —
# needs a rebase first" is how a reviewer actually refuses, not an exotic
# phrasing, and it's on the cmd_deploy.sh path.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Blocked — needs a rebase first"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "'Blocked' (inflected) still refuses, not just bare 'Block'" \
     '[[ "$out" == *"REJECTED"* && "$out" == *"rc=9" ]]'
# ...and it trips on nothing else it shouldn't: the false positives this row
# exists to fix stay fixed with 'blocked' added to the alternation.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Blocking issues: none"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "adding 'blocked' didn't re-admit 'Blocking issues: none'" '[[ "$out" == "rc=0" ]]'

reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Denied for now"; ROW[need_answered_by]="human:lodar"
out=$(run broker_gate_check push 7 DIVE-7)
want "'Denied' still refuses (existing stem, non-regression check)" \
     '[[ "$out" == *"REJECTED"* && "$out" == *"rc=9" ]]'

# An answer that is nothing but blank lines must not crash broker_gate_check
# under set -euo pipefail (the real caller's mode, per header.sh — `run()`
# above does not set -e, so this needs its own subshell to actually exercise
# it): gverdict's `grep -m1 -v` finds no non-blank line and exits 1, and
# pipefail promotes that to the whole substitution unless it's guarded.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]=$'   \n   '; ROW[need_answered_by]="human:lodar"
out=$(( set -euo pipefail; broker_gate_check push 7 DIVE-7 ) 2>/dev/null; printf 'rc=%s' "$?")
want "a wholly-blank answer doesn't crash the guarded gverdict assignment under set -e" \
     '[[ "$out" == "rc=0" ]]'

echo
echo "== 9. DIVE-2614: the rejected-gate refusal is audit-logged"
: > "$AUDIT_LOG_CALLS"
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]="no, not yet"
run broker_gate_check push 7 DIVE-7 >/dev/null
want "exactly one audit_log call fired on the reject path" \
     '[[ "$(wc -l < "$AUDIT_LOG_CALLS")" -eq 1 ]]'
want "the audit call names the surface and ident" \
     '[[ "$(cat "$AUDIT_LOG_CALLS")" == *"push gate"* && "$(cat "$AUDIT_LOG_CALLS")" == *"ident=DIVE-7"* ]]'

: > "$AUDIT_LOG_CALLS"
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t
ROW[need_answer]="Nothing blocks this"; ROW[need_answered_by]="human:lodar"
run broker_gate_check push 7 DIVE-7 >/dev/null
want "no audit_log call on a clean approval" '[[ "$(wc -l < "$AUDIT_LOG_CALLS")" -eq 0 ]]'

echo
echo "== 10. DIVE-2801: the PREFLIGHT can see an absent closure signature, and says so"
# The defect: `push --dry-run` reported OK and the real push refused the same row
# seconds later (DIVE-2798). Cause — the dry-run runs this predicate at
# require_sig=0 and the real push at 1, so the rehearsal evaluated a weaker
# predicate than the performance and reported its verdict as the whole gate.
#
# The fix rests on a fact about _gate_closure_verify, not on a new policy: it
# returns 1 on an EMPTY sig before computing anything, so "no signature at all" is
# a refusal the executor is CERTAIN to make, and an unprivileged caller can read
# that column even though it can never verify the HMAC. Absent is therefore
# decidable here; invalid-but-present is not, and stays the executor's to call.

# POSITIVE CONTROL FIRST, so this section cannot pass by always refusing.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes
ROW[need_answered_by]="human:lodar"
want "a SIGNED closure still clears the preflight cleanly (rc=0, no warning)" \
     '[[ "$(run broker_gate_check push 7 DIVE-7)" == "rc=0" ]]'
want "…and publishes state 'unverified' — present, but this caller could not check it" \
     '[[ "$( broker_gate_check push 7 DIVE-7 >/dev/null 2>&1; printf "%s" "$BROKER_GATE_SIG_STATE" )" == "unverified" ]]'

# THE ARM. Same authorized row, signature column empty.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes
ROW[need_answered_by]="human:lodar"; ROW[need_answer_sig]=""
unsigned_pre=$(run broker_gate_check push 7 DIVE-7)
want "an UNSIGNED closure is refused by the preflight, not reported as cleared" \
     '[[ "$unsigned_pre" != "rc=0" ]]'
want "…and the refusal names the state it observed (no signature), not a verdict it did not reach" \
     '[[ "$unsigned_pre" == *"carries NO closure signature"* ]]'
want "…and says the executor is what refuses it, so the reader knows where the real check lives" \
     '[[ "$unsigned_pre" == *"root-only executor"* ]]'
want "…and names the remedy (re-answer so the closure signs), not just the fault" \
     '[[ "$unsigned_pre" == *"5dive task answer DIVE-7"* ]]'

# The preflight must NOT preempt the executor's own refusal: that message covers
# unsigned AND tampered, it is the string DIVE-2798 measured, and moving the
# authoritative refusal into a less-privileged reader would be a different change.
want "at require_sig=1 the AUTHORITATIVE message is unchanged — the preflight did not steal it" \
     '[[ "$(run broker_gate_check push 7 DIVE-7 1)" == *"no valid signed closure"* ]]'
want "…and the preflight's own wording does NOT appear on the executor path" \
     '[[ "$(run broker_gate_check push 7 DIVE-7 1)" != *"carries NO closure signature"* ]]'

# Parameterization is live here too — deploy inherits the same preflight.
want "deploy's preflight refuses an unsigned closure in ITS OWN noun" \
     '[[ "$(run broker_gate_check deploy 7 DIVE-7)" == *"delegated deploy and refuses an unsigned one"* ]]'

# A state left over from a PREVIOUS call must not be rendered as this call's answer.
# Every refusal above returns before the signature block, so without an explicit
# clear at entry a stale "verified" would survive into the next gate's rendering.
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes
ROW[need_answered_by]="human:lodar"
# An EXIT trap, because `fail` exits: the second call cannot return to a printf, so
# the reading has to be taken on the way out. Both calls run in the SAME (sub)shell,
# so the first call's assignment really is visible to the second — which is exactly
# the leak being tested, and why a plain `run` wrapper could not detect it.
# The trap writes to a FILE, not to stdout: `fail`'s `exit` happens while the
# refused call's `>/dev/null` redirection is still in force, so a trap printing to
# stdout is swallowed and the arm reads '' — indistinguishable from a real clear,
# i.e. the instrument would have passed this arm for the wrong reason.
STALE_OUT="$TMP/stale_state"
(
  trap 'printf "%s" "${BROKER_GATE_SIG_STATE:-<cleared>}" > "$STALE_OUT"' EXIT
  broker_gate_check push 7 DIVE-7 >/dev/null 2>&1   # sets 'unverified'
  ROW[need_type]=""                                  # …now the row has no gate at all
  broker_gate_check push 7 DIVE-7 >/dev/null 2>&1   # refuses EARLY, before the sig block
)
stale=$(cat "$STALE_OUT")
want "state from a prior call does not survive into a gate that refuses EARLY (got '${stale}')" \
     '[[ "$stale" == "<cleared>" ]]'

echo "-- the note a rehearsal renders: four states, four distinct sentences"
note() { ( BROKER_GATE_SIG_STATE="$1"; broker_gate_sig_note "${2:-push}" ); }
want "verified reads as VERIFIED"        '[[ "$(note verified)"   == *"VERIFIED against the root HMAC"* ]]'
want "unverified says it was NOT checked here, and names who does check it" \
     '[[ "$(note unverified)" == *"NOT verified here"* && "$(note unverified)" == *"root executor verifies it at push time"* ]]'
want "unverified names the DEPLOY surface when asked for deploy" \
     '[[ "$(note unverified deploy)" == *"at deploy time"* ]]'
want "absent reads as ABSENT"            '[[ "$(note absent)"     == *"ABSENT"* ]]'
# The silence case: a caller that renders the note without ever running a gate
# check must get a statement, never an empty string — an empty parenthetical in a
# dry-run line is exactly the confident-looking silence this ticket is about.
want "an UNSET state renders 'NOT CHECKED', never empty" \
     '[[ -n "$(note "")" && "$(note "")" == *"NOT CHECKED"* ]]'
want "the four sentences are actually distinct (the case arms are not one string)" \
     '[[ "$(printf "%s\n" "$(note verified)" "$(note unverified)" "$(note absent)" "$(note "")" | sort -u | wc -l)" -eq 4 ]]'

echo
echo "broker surface unit: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
