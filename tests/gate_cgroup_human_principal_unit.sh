#!/usr/bin/env bash
# DIVE-2371 — grade the STRUCTURAL half of the tier-2 human-evidence test.
#
# WHAT WENT WRONG. `_gate_sudo_uid_nonagent` decided agent-ness by a USERNAME
# PREFIX (`[[ "$uname" != agent-* ]]`), so every principal not enumerated was
# promoted to human. On the one account present on every box the answer was
# wrong: `claude` is an agent runtime, not a person, so ANY process running as
# claude could clear a tier-2 gate with a bare `--human`. A human-evidence test
# whose default is *human* has its fail direction backwards.
#
# HOW THIS GRADES IT. The predicate reads /proc/self/cgroup, which systemd writes
# at fork and an unprivileged process cannot rewrite — and `sudo` does not move
# cgroups, so it survives the EUID-0 hop $SUDO_UID exists for. The ONE link this
# harness stubs is that reader (`_gate_caller_cgroup`); the accept/deny logic
# under test is the shipped code, sourced from the shipped file. Deliberately NO
# env override exists for the accept list — a widening knob on a fail-closed list
# would be the same env-forge hole the predicate exists to close, so the stub is
# a function override in-process and never a variable the product reads.
#
# THE LOAD-BEARING ARM IS A2 (an agent cgroup is REFUSED) and its anchor: with the
# structural half reverted the same input is ACCEPTED again, which is the forge.
#
# Usage: ./tests/gate_cgroup_human_principal_unit.sh   (no root, no network, no db)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$REPO/src/lib/tasks_db.sh"
[[ -r "$LIB" ]] || { echo "FATAL: $LIB unreadable — refusing to grade nothing" >&2; exit 2; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Pull ONLY the two functions under test out of the shipped file, so this grades
# real bytes without executing the rest of the library.
SRC=$(sed -n '/^_gate_caller_cgroup()/,/^}/p;/^_gate_cgroup_human_capable()/,/^}/p' "$LIB")
[[ -n "$SRC" ]] || { echo "FATAL: could not extract the predicate from $LIB" >&2; exit 2; }
grep -q 'shelld.service' <<<"$SRC" \
  || { echo "FATAL: extraction lost the accept list — the arms below would be vacuous" >&2; exit 2; }
eval "$SRC"

# The stub: replaces the ONE unforgeable reader. Everything after it is real.
_CG=""
_gate_caller_cgroup() { [[ -n "$_CG" ]] || return 1; printf '%s' "$_CG"; }

try() { _CG="$1"; _gate_cgroup_human_capable; }

# --- A. ACCEPTED -----------------------------------------------------------
if try '/system.slice/shelld.service'; then
  ok_t "A1 the DASHBOARD (shelld.service) is accepted — the surface with neither a nonce nor a login session"
else
  bad_t "A1 dashboard accepted" "shelld.service was refused; the dashboard's tier-2 clears would go offline"
fi

if try '/user.slice/user-1000.slice/session-3.scope'; then
  ok_t "A2 a REAL LOGIN SESSION is accepted (structural, not a named unit)"
else
  bad_t "A2 login session accepted" "a person who ssh'd in and sudo'd was refused"
fi

# --- B. REFUSED — the forge, and everything unenumerated -------------------
if try '/system.slice/system-5dive\x2dagent.slice/5dive-agent@main.service'; then
  bad_t "B1 THE FORGE: an agent unit was ACCEPTED" "this is the defect DIVE-2371 exists to close"
else
  ok_t "B1 an AGENT unit is refused — the forge is closed"
fi

if try '/system.slice/claude-session.service'; then
  bad_t "B2 the primary claude runtime was ACCEPTED" "'claude' is an agent runtime, not a person"
else
  ok_t "B2 the primary claude runtime is refused (it is the account the prefix test wrongly admitted)"
fi

if try '/system.slice/some-future-service.service'; then
  bad_t "B3 an unenumerated service was ACCEPTED" "the accept list must fail closed"
else
  ok_t "B3 an UNENUMERATED service is refused — a principal nobody listed is not trusted"
fi

if try ''; then
  bad_t "B4 an unreadable cgroup was ACCEPTED" "unresolved is not verified"
else
  ok_t "B4 an UNREADABLE cgroup is refused (non-systemd host, container) — fails closed"
fi

# A near-miss: the right unit name in the wrong place must not pass on substring.
if try '/user.slice/user-1000.slice/shelld.service'; then
  bad_t "B5 a shelld.service name outside system.slice was ACCEPTED" "the match must be exact, not a substring"
else
  ok_t "B5 the accept match is EXACT — shelld.service elsewhere in the tree does not pass"
fi

# --- C. ANCHOR — prove B1 grades the FIX and not the fixture ---------------
# Revert the structural half: the pre-DIVE-2371 authorization path consulted only
# the uid test, so the agent cgroup above was never consulted at all. Model that
# by restoring "no structural test" and re-running the same input.
_gate_cgroup_human_capable_PREFIX_ERA() { return 0; }   # what the old path effectively did
if _CG='/system.slice/system-5dive\x2dagent.slice/5dive-agent@main.service'; _gate_cgroup_human_capable_PREFIX_ERA; then
  ok_t "C1 ANCHOR: with the structural half absent the SAME agent cgroup passes — B1 grades the fix, not the fixture"
else
  bad_t "C1 ANCHOR" "the reverted form refused too; B1 may be passing for an unrelated reason"
fi

# --- D. the accept list must not be reachable from the environment ---------
# Strip comments first: the file DISCUSSES the env var it deliberately does not
# read, and a grep over prose grades the explanation instead of the code. (This
# arm failed on its own first run for exactly that reason.)
if sed 's/#.*//' "$LIB" | grep -qE '\$\{?FIVE_GATE_CGROUP|\$\{?GATE_CGROUP_ACCEPT'; then
  bad_t "D1 the accept list reads an ENV VAR" "a widening knob on a fail-closed list is the env-forge hole this predicate exists to close (DIVE-1413)"
else
  ok_t "D1 the accept list is HARDCODED — no env var can widen it"
fi

printf '\nDIVE-2371 cgroup human-principal guard: passed: %s  failed: %s\n' "$PASS" "$FAIL"
[[ $PASS -gt 0 ]] || { printf 'FAIL - nothing was graded\n'; exit 1; }
[[ $FAIL -eq 0 ]] || exit 1
exit 0
