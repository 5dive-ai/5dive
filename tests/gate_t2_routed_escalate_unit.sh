#!/usr/bin/env bash
# TIER: nightly — 5.8s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-1437 isolated unit harness for the T2-floor-refused ROUTED-gate escalation in
# cmd_task_answer. ROOT (DIVE-1429): a builder gate that DIVE-1145/1182 lead-routed
# (routed_reviewer set) but whose effective tier is 2 (a non-floored `manual` gate —
# manual still defaults to tier 2 per DIVE-1284) cannot be cleared by the agent lead:
# the DIVE-1117 tier-2 hard-human floor refuses the lead's non-human answer. And
# cmd_task_need RETURNED before task_need_notify when it routed, so the human never got
# a tap button — the gate STALLS (the lead hand-asks the human in plain chat with no
# button). FIX: at the T2-floor refusal, if the gate is a ROUTED approval/manual gate,
# ESCALATE to the human via task_need_notify (fires the tap keyboard), take the lead out
# (routed_reviewer NULL), re-arm the ping (gate_pinged_at NULL), and mint a FRESH human
# nonce so anti-forge holds (only a real tap/nonce/non-agent SUDO_UID clears it). A
# NON-routed tier-2 gate is unchanged (already got its human button at filing → still
# refused). Isolation matches the sibling harnesses. Run: bash tests/gate_t2_routed_escalate_unit.sh
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-t2-routed-escalate-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# File-backed observer: cmd_task_answer runs inside a `$(...)` subshell in the cases
# that capture its output, so a plain var would be lost — record the ping on disk.
NOTIFIED_FILE="$TMP/notified"; : > "$NOTIFIED_FILE"
# DIVE-2233 item 2: also capture the RAW nonce the notifier is handed ($8), in a SEPARATE
# file so the _nf_reset the arms call between cases cannot clobber it. The notifier is the
# only place the raw value is ever exposed — it is deliberately never printed to stdout,
# so the filing agent cannot read it back — and E3 needs it to simulate a REAL human tap.
NONCE_FILE="$TMP/nonce"; : > "$NONCE_FILE"
task_need_notify() { echo "$1:$2" > "$NOTIFIED_FILE"; printf '%s' "${8:-}" > "$NONCE_FILE"; }
_nf()   { cat "$NOTIFIED_FILE" 2>/dev/null; }
_nf_reset() { : > "$NOTIFIED_FILE"; }
last_nonce() { cat "$NONCE_FILE" 2>/dev/null; }
audit_log() { :; }

# The immediate caller is the agent LEAD (agent-marcus) attempting to clear a gate that
# was routed to it — the DIVE-1429 shape.
#
# DIVE-2330: this used to stub `id -un`, because the gate's identity resolver READ
# `id -un` — which is precisely the forgery this row closed. `_gate_authenticated_actor`
# now resolves `$EUID` in pure bash over a passwd stream, so the pin moves to those two
# seams. `id()` is kept below for `_gate_sudo_uid_nonagent`, which still reads `id -u`
# and is not part of this change.
FAKE_CALLER="agent-marcus"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
MARCUS_UID=4321
_gate_caller_uid() { printf '%s' "$MARCUS_UID"; }
_gate_passwd_stream() {
  printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$FAKE_CALLER" "$MARCUS_UID" "$MARCUS_UID" "$FAKE_CALLER"
  printf '%s\n' "$(</etc/passwd)"
}

seed_task()  { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
route_to()   { db "UPDATE tasks SET routed_reviewer='$2' WHERE ident='$1';"; }
answered()   { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
routedrev()  { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
noncehash()  { db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE ident='$1';"; }
pinged()     { db "SELECT COALESCE(gate_pinged_at,'') FROM tasks WHERE ident='$1';"; }
tierof()     { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }

export SUDO_UID=1234   # an agent-ish uid: not the non-agent (root/claude) evidence form
touch "$GATE_PROOF_ENFORCE"   # enforcement ON (the floor + escalation are live)

# --- CALLER-IDENTITY PIN (DIVE-2365) ---------------------------------------------------
# The export above is INERT here. `_gate_sudo_uid_nonagent` reads SUDO_UID only in its
# root branch (DIVE-1413); unprivileged it reads `id -u` — whoever ran the suite. That is
# `agent-*` on a 5dive box and `runner` in CI, so E3b's "from an agent" was supplied by
# the host rather than by this file, and on the runner the forge CLEARED instead. Pin it:
# seam `_gate_is_root`, stub the passwd lookup for the pinned uid only, leave the
# resolver's own root-branch / unknown-uid / `agent-*` logic real. Full write-up lives at
# the top of tests/gate_t2_nonce_proof_unit.sh.
AGENT_UID=1234
agent_caller_on() {
  _gate_is_root() { return 0; }
  getent() {
    if [[ "${1:-}" == passwd && "${2:-}" == "$AGENT_UID" ]]; then
      printf 'agent-fixture:x:%s:%s::/home/agent-fixture:/bin/bash\n' "$AGENT_UID" "$AGENT_UID"
      return 0
    fi
    command getent "$@"
  }
  export SUDO_UID="$AGENT_UID"
}
# DIVE-2330 companion to assert_agent_caller: the LEAD identity the clear authorizes on
# comes from the seams above, so assert it resolves before any arm depends on it. A pin
# that silently yields '' makes _lead_clear=0 and the arms below grade a refusal.
assert_lead_identity() { # <label>
  local got; got=$(_gate_authenticated_actor)
  if [[ "$got" == "${FAKE_CALLER#agent-}" ]]; then
    ok_t "$1 precond: the pinned LEAD resolves to '${FAKE_CALLER#agent-}' through the real resolver"
  else
    bad_t "$1 precond: pinned LEAD identity" "resolver returned '$got', expected '${FAKE_CALLER#agent-}' — the arms below would grade a refusal, not a lead-clear"
  fi
}

assert_agent_caller() { # <label>
  if _gate_sudo_uid_nonagent; then
    bad_t "$1 precond: caller pinned as an AGENT" \
      "the real resolver still reports NON-AGENT human evidence — the arm below would grade \
the opposite behaviour and report ok (DIVE-2365)"
  else
    ok_t "$1 precond: the pinned caller reads as an AGENT to the real resolver"
  fi
}
agent_caller_on
assert_lead_identity PIN

# --- E1: THE FIX — a ROUTED tier-2 manual gate, answered by its lead, ESCALATES to the
#     human instead of dead-ending: routed_reviewer cleared, ping re-armed, fresh nonce
#     minted, human ping fired, and the gate stays OPEN (awaiting the human tap). -------
seed_task DIVE-301
cmd_task_need DIVE-301 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
[[ "$(tierof DIVE-301)" == "2" ]] || bad_t "E1 precond manual defaults tier 2" "got '$(tierof DIVE-301)'"
route_to DIVE-301 marcus
db "UPDATE tasks SET gate_pinged_at='2026-07-18 00:00:00' WHERE ident='DIVE-301';"  # a prior stale ping
_nf_reset
out=$(cmd_task_answer DIVE-301 --value=approved 2>&1); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "E1 escalation returns success (not a dead-end fail)" \
  || bad_t "E1 escalation rc 0" "rc=$rc out=$out"
[[ "$(answered DIVE-301)" == "open" ]] \
  && ok_t "E1 gate stays OPEN (the lead did NOT clear it; awaiting the human)" \
  || bad_t "E1 gate open" "state=$(answered DIVE-301)"
[[ "$(routedrev DIVE-301)" == "" ]] \
  && ok_t "E1 routed_reviewer CLEARED (lead taken out of the loop)" \
  || bad_t "E1 routed_reviewer cleared" "got '$(routedrev DIVE-301)'"
[[ "$(pinged DIVE-301)" == "" ]] \
  && ok_t "E1 gate_pinged_at RE-ARMED to NULL (ping fires fresh)" \
  || bad_t "E1 gate_pinged_at re-armed" "got '$(pinged DIVE-301)'"
[[ -n "$(noncehash DIVE-301)" ]] \
  && ok_t "E1 fresh human nonce minted (anti-forge: only a real tap clears)" \
  || bad_t "E1 nonce minted" "human_nonce_hash empty"
[[ "$(_nf)" == "DIVE-301:manual" ]] \
  && ok_t "E1 task_need_notify FIRED with the tap keyboard (human gets a button)" \
  || bad_t "E1 human ping fired" "notified='$(_nf)'"
[[ "$out" == *'"escalated_to_human":true'* ]] \
  && ok_t "E1 result flags escalated_to_human (actionable to the caller)" \
  || bad_t "E1 escalation message" "out=$out"

# --- E2: a NON-routed tier-2 manual gate is UNCHANGED — it already got its human button
#     at filing, so a bare-agent answer is still REFUSED (no escalation, no re-ping). ---
seed_task DIVE-302
cmd_task_need DIVE-302 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
# no route_to: routed_reviewer stays NULL
_nf_reset
out=$(cmd_task_answer DIVE-302 --value=approved 2>&1); rc=$?
[[ "$(answered DIVE-302)" == "open" && $rc -ne 0 ]] \
  && ok_t "E2 non-routed tier-2 manual still REFUSED (unchanged)" \
  || bad_t "E2 non-routed refused" "rc=$rc state=$(answered DIVE-302) out=$out"
[[ -z "$(_nf)" ]] \
  && ok_t "E2 no escalation ping on a non-routed gate" \
  || bad_t "E2 no ping" "notified='$(_nf)'"
# DIVE-2801 CHANGED THE EXPECTED STRING, not this arm's claim. The claim here is
# "refused, and by the plain refusal rather than the escalation path" — it was
# keyed on "only a human", a sentence that row deleted for being false (the
# lead-clear seat answers these with no human). Re-keyed onto what still
# discriminates the two paths: the standing refusal names the caller's standing,
# and escalation would have flagged itself (E1 asserts that flag's presence).
[[ "$out" == *"lead-clear standing"* && "$out" != *"escalated_to_human"* ]] \
  && ok_t "E2 gets the plain standing refusal, not the escalation path" \
  || bad_t "E2 refusal message" "out=$out"
# And the remedy it offers must fit THIS gate: DIVE-302 is unrouted, so there is
# no lead-clear seat to point at. Asserting the absence is the whole point — the
# type-level sentence is exactly what would reappear here.
[[ "$out" == *"no routed reviewer"* ]] \
  && ok_t "E2 unrouted gate is not told a lead-clear seat can answer it (DIVE-2801)" \
  || bad_t "E2 unrouted remedy names a seat that does not exist" "out=$out"

# --- E3: a routed tier-2 manual gate cleared by a real HUMAN (--human) clears normally —
#     escalation only fires for the NON-human refusal path (DIVE-525: taps never break). -
#
# DIVE-2233 item 2 CHANGED THIS ARM'S FIXTURE, not its claim. The caller here is a stubbed
# agent-marcus (line ~62), so the pre-item-2 form — a bare `--human` from an agent process
# with no proof — IS the DIVE-2131 forge this ships to kill, and it is now refused. What
# the arm means to grade is that a REAL human clear still works, so it supplies what a real
# tap actually carries: the minted nonce. E3b withholds ONLY the proof on the same shape.
seed_task DIVE-303
cmd_task_need DIVE-303 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
route_to DIVE-303 marcus
E3_NONCE="$(last_nonce)"
[[ -n "$E3_NONCE" ]] \
  && ok_t "E3 precond: filing a tier-2 manual gate minted a nonce for the tap to carry" \
  || bad_t "E3 precond nonce minted" "notifier was handed no nonce"
_nf_reset
out=$(cmd_task_answer DIVE-303 --value=approved --human --human-proof="$E3_NONCE" 2>&1); rc=$?
[[ "$(answered DIVE-303)" == "closed" ]] \
  && ok_t "E3 a REAL human tap (--human + the minted nonce) on a routed tier-2 gate CLEARS" \
  || bad_t "E3 real tap clears" "rc=$rc still $(answered DIVE-303) out=$out"
[[ -z "$(_nf)" ]] \
  && ok_t "E3 no re-escalation on a genuine human clear" \
  || bad_t "E3 no re-escalation" "notified='$(_nf)'"

# --- E3b NON-VACUITY FOR E3 (DIVE-2233 item 2): same gate shape, same caller — only the
#     proof is withheld. This is the exact answer that closed DIVE-2131 with
#     need_answered_uid=1004 and human_nonce_hash NULL. Without it, an E3 that accepted
#     anything is indistinguishable from an E3 that verifies. ----------------------------
seed_task DIVE-305
cmd_task_need DIVE-305 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
route_to DIVE-305 marcus
_nf_reset
assert_agent_caller E3b
out=$(cmd_task_answer DIVE-305 --value=approved --human 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-305)" == "open" ]] \
  && ok_t "E3b bare --human from an agent (the DIVE-2131 forge) is REFUSED on the same gate" \
  || bad_t "E3b forge refused" "rc=$rc state=$(answered DIVE-305) out=$out"

# --- E4: DIVE-2588 — enforcement OFF IS NO LONGER A DOWNGRADE PATH. This arm used
#     to assert that clearing the flag made the floor (and this escalation) dormant,
#     so a routed tier-2 manual gate fell to a direct lead clear. That dormancy is
#     what the DIVE-2588 bypass bought with one env var, and the tier-2 floor no
#     longer consults the flag at all. With it OFF the box now behaves exactly as it
#     does with it ON — which, since the rollout completed 2026-07-30, is what every
#     live box was already doing. Same assertions as E1, deliberately: the claim is
#     that the two are INDISTINGUISHABLE, so they must be graded the same way.
rm -f "$GATE_PROOF_ENFORCE"
seed_task DIVE-304
cmd_task_need DIVE-304 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
route_to DIVE-304 marcus
_nf_reset
out=$(cmd_task_answer DIVE-304 --value=approved 2>&1); rc=$?
[[ "$(answered DIVE-304)" == "open" ]] \
  && ok_t "E4 enforce OFF: routed tier-2 gate still NOT lead-cleared — stays open for the human (DIVE-2588)" \
  || bad_t "E4 floor survives enforce OFF" "rc=$rc state=$(answered DIVE-304) out=$out"
[[ -n "$(_nf)" ]] \
  && ok_t "E4 enforce OFF: the human was notified with a tap — escalation fires identically to enforce ON" \
  || bad_t "E4 escalation fires with enforce OFF" "notified='$(_nf)'"
touch "$GATE_PROOF_ENFORCE"

# --- E5: DIVE-2801's POSITIVE CONTROL. Every arm above grades a caller WITHOUT
#     lead-clear standing, so all of them would still pass against a build that
#     refuses every caller — and that build is precisely what the old wording
#     ("only a human can clear it") described. The row's claim is that standing,
#     not gate type, decides; a claim about a discriminator is not tested until
#     both sides of it are run. Same caller identity as E2, tier-1 approval gate
#     routed to that caller: it must clear, and see no refusal at all.
#     (Ident DIVE-306, not 305: E3b already holds 305. Seeded onto a taken ident
#     `seed_task` hits a UNIQUE constraint, the gate filing is refused as already
#     filed, and the arm then grades the PREVIOUS arm's leftover row — which is
#     how the first draft of this control passed while proving nothing.)
seed_task DIVE-306
cmd_task_need DIVE-306 --type=approval --tier=1 --ask="ship it" >/dev/null 2>&1
[[ "$(tierof DIVE-306)" == "1" ]] \
  && ok_t "E5 precond: a tier-1 approval gate is filed on a FRESH ident" \
  || bad_t "E5 precond: fixture is not the gate this arm claims" "tier='$(tierof DIVE-306)' — a collided ident would grade a leftover row"
route_to DIVE-306 marcus
_nf_reset
out5=$(cmd_task_answer DIVE-306 --value=approve 2>&1); rc5=$?
[[ "$(answered DIVE-306)" == "closed" && $rc5 -eq 0 ]] \
  && ok_t "E5 CONTROL: the caller WITH lead-clear standing clears its own gate, no human" \
  || bad_t "E5 standing caller could not clear" "rc=$rc5 state=$(answered DIVE-306) out=$out5"
[[ "$out5" != *"lead-clear standing"* && "$out5" != *"only a human"* ]] \
  && ok_t "E5 CONTROL: standing caller sees no refusal text (standing decides, not type)" \
  || bad_t "E5 standing caller was refused" "out=$out5"

echo "-----"
printf 'gate_t2_routed_escalate_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
