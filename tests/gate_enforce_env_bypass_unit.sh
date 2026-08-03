#!/usr/bin/env bash
# TIER: nightly — 8.6s measured on the 5dive host (uid 1007, warm tree). The budget number
# that gates is CI's, not mine: PR #395 read 209 harnesses / 289s / 96% of the 300s cap, so a
# new core harness would spend most of the remaining 11s of headroom. (This box reads 309s for
# the same 209 — ~7% slower than the runner, which is why the CI figure is the one quoted.)
# And 289s is ONE SAMPLE of a noisy quantity, not a constant: main measured 356s and 289s on
# the same commit an hour apart (DIVE-2592). The argument only gets stronger at the high end —
# at 356s the tier is already over, so a core harness added on the strength of a lucky 96%
# reading would red the budget (exit 4) on the next unlucky one, for reasons having nothing to
# do with gates. The reason
# this demotion does not leave the property unguarded at PR time — which is the only
# argument that would make it acceptable for a live authority hole — is that the same
# forge is probed on EVERY PR by `5dive selfcheck --only=t2-forge` (DIVE-2588), which
# unit-tests.yml runs in both the pristine and installed-host jobs. Per-PR coverage is
# the probe; this file is the exhaustive matrix (5 predicate states, both fix halves
# isolated, the scope table, and the liveness arms) and the nightly sweep runs it.
#
# DIVE-2588 — the enforcement flag's OFF POSITION must not be reachable by the party
# it constrains.
#
# THE HOLE, measured by main on the released v0.18.2 artifact and reproduced here on
# the installed 0.18.0+dive2563 as agent-dev uid 1007, no sudo:
#
#   GATE_PROOF_ENFORCE=/nonexistent/nope  5dive task answer <T2-decision> --value=A --human
#
# SUCCEEDED where the identical command without the variable was REFUSED, and landed
# need_answer=A, need_answered_by=human:dev, need_answered_uid=1007 — the same row a
# real relayed human tap writes. `_gate_proof_enforced` was a file-EXISTENCE test on a
# path the unprivileged caller supplies, so pointing it anywhere absent evaluated the
# whole tier-2 branch false. Scope was exactly `decision`: approval/manual/access carry
# an independent type guard that never consults the flag.
#
# THE FIX HAS TWO INDEPENDENT HALVES and this harness grades both, because either one
# alone would close the reported command while leaving the shape intact:
#   1. the override may only make enforcement STRICTER (an existing sentinel at EITHER
#      path arms it; an absent path now says nothing at all), and
#   2. the tier-2 human floor no longer consults the flag in either direction.
#
# WHAT MAKES THE BYPASS ARMS NON-VACUOUS: every "refused" assertion below is paired
# with a row-state check (the gate must still be OPEN, not merely an error printed),
# and L1/L2 prove this same harness CAN clear a gate and CAN report enforcement off —
# without those, a harness that refused everything would score perfect.
#
# Isolation matches the sibling gate harnesses: source src/ libs, throwaway STATE_DIR,
# the live shared tasks.db is NEVER touched. Run: bash tests/gate_enforce_env_bypass_unit.sh
# (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-enforce-bypass.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
DEFAULT_SENTINEL="$STATE_DIR/gate-proof.enforce"
ALT_SENTINEL="$TMP/alt-enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }
# The answer path pings the gate's owner over `cmd_send` — a REAL inter-agent rail
# that no STATE_DIR fence covers. An arm that successfully clears a gate (L2 below)
# therefore sends live traffic about a fixture row unless it is stubbed here.
cmd_send() { return 1; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
answered() { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
provby()   { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
tierof()   { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
hashof()   { db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE ident='$1';"; }

# ── the two callers this harness models ──────────────────────────────────────────
# THE ATTACKER is the ordinary case, not a privileged one: an agent, unprivileged, no
# sudo — exactly what every agent on every box already is. That is the whole severity
# argument, so it is the default posture here.
FAKE_CALLER="agent-dev"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
as_agent()        { FAKE_CALLER="agent-dev"; unset SUDO_UID; _gate_is_root() { return 1; }; }
# The human-on-box / dashboard-exec path: a NON-agent SUDO_UID, trusted only at EUID 0
# (DIVE-1413), which is why the root seam is stubbed rather than the assertion weakened.
as_human_on_box() { FAKE_CALLER="root"; export SUDO_UID=0; _gate_is_root() { return 0; }; }
as_agent

file_gate() { # file_gate <ident> <type> [extra args...]
  local ident="$1" type="$2"; shift 2
  seed_task "$ident"
  cmd_task_need "$ident" --type="$type" "$@" >/dev/null 2>&1
}

# `fail` exits. Every answer below runs in a command substitution ON PURPOSE so a
# refusal reds ONE arm instead of ending the harness at status 6.
answer() { ( cmd_task_answer "$@" ) 2>&1; }

# ── P: the predicate itself ──────────────────────────────────────────────────────
# Graded directly because it is the single decision the exploit rewrote, and because
# the end-to-end arms below can only show it through one call site.
enforced() { _gate_proof_enforced && echo on || echo off; }

rm -f "$DEFAULT_SENTINEL" "$ALT_SENTINEL"
: > "$DEFAULT_SENTINEL"
[[ "$(unset GATE_PROOF_ENFORCE; enforced)" == on ]] \
  && ok_t "P1 default sentinel present, no override => ON" \
  || bad_t "P1 default sentinel arms enforcement" "got $(unset GATE_PROOF_ENFORCE; enforced)"

[[ "$(GATE_PROOF_ENFORCE=/nonexistent/nope enforced)" == on ]] \
  && ok_t "P2 THE FIX: an override pointing at an absent path can NOT switch enforcement off" \
  || bad_t "P2 absent override cannot disarm" "got $(GATE_PROOF_ENFORCE=/nonexistent/nope enforced)"

rm -f "$DEFAULT_SENTINEL"; : > "$ALT_SENTINEL"
[[ "$(GATE_PROOF_ENFORCE="$ALT_SENTINEL" enforced)" == on ]] \
  && ok_t "P3 override at an EXISTING path still arms it (every tests/ caller does this)" \
  || bad_t "P3 override can still arm" "got $(GATE_PROOF_ENFORCE="$ALT_SENTINEL" enforced)"

rm -f "$ALT_SENTINEL"
[[ "$(GATE_PROOF_ENFORCE=/nonexistent/nope enforced)" == off ]] \
  && ok_t "P4 with NO sentinel anywhere it is off — the fix did not just hardcode on" \
  || bad_t "P4 off when nothing is armed" "got $(GATE_PROOF_ENFORCE=/nonexistent/nope enforced)"

[[ "$(unset GATE_PROOF_ENFORCE; enforced)" == off ]] \
  && ok_t "P5 L1 liveness: this harness CAN read enforcement as off, so P1-P3 are not constants" \
  || bad_t "P5 harness can observe off" "got $(unset GATE_PROOF_ENFORCE; enforced)"

# ── E: the reported exploit, end to end ──────────────────────────────────────────
: > "$DEFAULT_SENTINEL"   # the live posture: enforcement armed by the root-owned file

file_gate DIVE-401 decision --ask="approve the spend for the volume resize" \
  --options="A|B" --recommend="A" --tier=2
[[ "$(tierof DIVE-401)" == "2" ]] \
  && ok_t "E0 precondition: the gate really is tier 2" \
  || bad_t "E0 tier-2 precondition" "tier=$(tierof DIVE-401)"
[[ "$(hashof DIVE-401)" =~ ^[0-9a-f]{64}$ ]] \
  && ok_t "E0 precondition: it minted a per-gate human nonce (DIVE-2356)" \
  || bad_t "E0 nonce precondition" "hash='$(hashof DIVE-401)'"

# THE LOAD-BEARING BASELINE. Without it the bypass arm proves nothing: a command that
# refuses everywhere is not evidence that the variable was neutralised.
out=$(answer DIVE-401 --value=A --human); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-401)" == "open" ]] \
  && ok_t "E1 baseline: a forged --human from an agent is REFUSED and the row is untouched" \
  || bad_t "E1 baseline refusal" "rc=$rc state=$(answered DIVE-401) out=$out"

out=$(GATE_PROOF_ENFORCE=/nonexistent/nope answer DIVE-401 --value=A --human); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-401)" == "open" ]] \
  && ok_t "E2 THE BYPASS IS CLOSED: same command + GATE_PROOF_ENFORCE=/nonexistent still REFUSED" \
  || bad_t "E2 env bypass closed" "rc=$rc state=$(answered DIVE-401) prov=$(provby DIVE-401) out=$out"
# An rc alone passes on ANY error, including one raised before the floor was reached.
grep -qi 'unproven\|tier-2' <<<"$out" \
  && ok_t "E3 the bypass refusal names the forge, so it is the floor refusing and not an incidental error" \
  || bad_t "E3 refusal names the forge" "out=$out"
[[ -z "$(provby DIVE-401)" ]] \
  && ok_t "E4 nothing was stamped: need_answered_by is still empty after both attempts" \
  || bad_t "E4 no provenance written" "prov=$(provby DIVE-401)"

# Half 2 of the fix, isolated: even with NO sentinel anywhere — the state the override
# used to fake — the tier-2 floor stands on its own.
rm -f "$DEFAULT_SENTINEL"
file_gate DIVE-402 decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=2
out=$(answer DIVE-402 --value=A); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-402)" == "open" ]] \
  && ok_t "E5 with enforcement genuinely OFF the tier-2 floor STILL refuses a non-human answer" \
  || bad_t "E5 floor is unconditional" "rc=$rc state=$(answered DIVE-402) out=$out"

# E6 ISOLATES THE SECOND SITE. E5 above rides the provenance floor, which a forged
# `--human` walks straight past by setting human=1 — so with the floor now
# unconditional, the ONLY thing left that can refuse a forged --human on a
# nonce-bearing tier-2 gate is the DIVE-2356 evidence block. Enforcement is still
# genuinely off here, so this arm reds if that block's flag conjunct comes back and
# stays green if only the floor's does. Without it, half the fix is untested.
file_gate DIVE-406 decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=2
[[ "$(hashof DIVE-406)" =~ ^[0-9a-f]{64}$ ]] || bad_t "E6 precondition: gate minted a nonce" "hash='$(hashof DIVE-406)'"
out=$(answer DIVE-406 --value=A --human); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-406)" == "open" ]] \
  && ok_t "E6 enforcement OFF: a forged --human on a nonce-bearing tier-2 gate is refused by the EVIDENCE block" \
  || bad_t "E6 evidence block is unconditional" "rc=$rc state=$(answered DIVE-406) out=$out"
: > "$DEFAULT_SENTINEL"

# ── L2: liveness. A harness whose every arm expects a refusal proves nothing. ─────
as_human_on_box
file_gate DIVE-403 decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=2
out=$(answer DIVE-403 --value=A --human); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-403)" == "closed" ]] \
  && ok_t "L2 liveness: a REAL human path (non-agent SUDO_UID at EUID 0) still clears the same gate" \
  || bad_t "L2 real human path still clears" "rc=$rc state=$(answered DIVE-403) out=$out"
[[ "$(provby DIVE-403)" == human:* ]] \
  && ok_t "L2 and it is stamped human:* — DIVE-525 holds, a real tap is never rejected" \
  || bad_t "L2 human provenance" "prov=$(provby DIVE-403)"
as_agent

# ── B: the boundary. The fix must not have widened into tier 1. ──────────────────
file_gate DIVE-404 decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=1
[[ "$(tierof DIVE-404)" == "1" ]] || bad_t "B0 tier-1 precondition" "tier=$(tierof DIVE-404)"
out=$(answer DIVE-404 --value=A); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-404)" == "closed" ]] \
  && ok_t "B1 boundary: a bare-agent answer on a TIER-1 decision still clears (not over-widened)" \
  || bad_t "B1 tier-1 unaffected" "rc=$rc state=$(answered DIVE-404) out=$out"

# ── S: main's scope table. The other three tier-2 types refused in BOTH arms before
#      this change (an independent type guard, not the flag). Anchor that they still
#      do — a fix to the decision path must not have moved them.
: > "$DEFAULT_SENTINEL"
n=405
for ty in approval manual access; do
  idt="DIVE-$n"; n=$((n+1))
  case "$ty" in
    manual) file_gate "$idt" manual --ask="run the physical box swap" ;;
    access) file_gate "$idt" access --ask="grant me the prod console" ;;
    # --tier=2 explicitly: manual/access floor themselves by type, but "approve the
    # deploy" trips no tier-2 keyword and files as tier 1 — which would silently
    # grade the tier-1 path under a tier-2 name. The precondition below catches it,
    # and this is why it is asserted rather than assumed.
    *)      file_gate "$idt" approval --ask="approve the deploy" --tier=2 ;;
  esac
  [[ "$(tierof "$idt")" == "2" ]] || { bad_t "S precondition $ty is tier 2" "tier=$(tierof "$idt")"; continue; }
  b_out=$(answer "$idt" --value=approved --human); b_rc=$?
  y_out=$(GATE_PROOF_ENFORCE=/nonexistent/nope answer "$idt" --value=approved --human); y_rc=$?
  if [[ $b_rc -ne 0 && $y_rc -ne 0 && "$(answered "$idt")" == "open" ]]; then
    ok_t "S $ty: refused in BOTH arms and still open (scope table unchanged)"
  else
    bad_t "S $ty refused in both arms" "baseline rc=$b_rc bypass rc=$y_rc state=$(answered "$idt") b=$b_out y=$y_out"
  fi
done

echo "-----"
printf 'gate_enforce_env_bypass_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
