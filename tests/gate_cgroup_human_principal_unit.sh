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
# DIVE-2692 corpus contract: report our own rc honestly. Registered BEFORE the
# two `exit 2` precondition guards below, so an unreadable lib or a lost accept
# list is reported as a nonzero HARNESS-RC rather than as a silent short read.
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT

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
SRC=$(sed -n '/^_gate_cgroup_pick_line()/,/^}/p;/^_gate_caller_cgroup()/,/^}/p;/^_gate_cgroup_human_capable()/,/^}/p' "$LIB")
[[ -n "$SRC" ]] || { echo "FATAL: could not extract the predicate from $LIB" >&2; exit 2; }
grep -q 'shelld.service' <<<"$SRC" \
  || { echo "FATAL: extraction lost the accept list — the arms below would be vacuous" >&2; exit 2; }
grep -q 'name=systemd' <<<"$SRC" \
  || { echo "FATAL: extraction lost the line picker — the E arms below would be vacuous" >&2; exit 2; }
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

# --- E. WHICH LINE the reader picks (the `head -1` defect) -------------------
# Graded through _gate_cgroup_pick_line, which takes the stream on stdin, so the
# selection rule is testable while /proc/self/cgroup stays HARDCODED at the single
# call site — no readable-path override is introduced to make a test possible.
pick() { _gate_cgroup_pick_line <<<"$1"; }

# E1 pure v2: one unified line.
[[ "$(pick '0::/system.slice/shelld.service')" == "/system.slice/shelld.service" ]] \
  && ok_t "E1 v2 unified line yields its path" \
  || bad_t "E1 v2 unified" "got '$(pick '0::/system.slice/shelld.service')'"

# E2 THE LOAD-BEARING ARM. v1/hybrid, systemd line NOT first and a DIFFERENT path on
# the line that is. `head -1` returned the pids controller's '/', so a real login
# session read as unrecognised and the human was refused. Order is the whole point.
_V1=$'12:pids:/\n5:memory:/user.slice\n1:name=systemd:/user.slice/user-1000.slice/session-3.scope'
[[ "$(pick "$_V1")" == "/user.slice/user-1000.slice/session-3.scope" ]] \
  && ok_t "E2 v1/hybrid picks the name=systemd line, not the first line" \
  || bad_t "E2 v1/hybrid systemd line" "got '$(pick "$_V1")' — head -1 behaviour is back"

# E3 the E2 path must survive into the real ACCEPT decision, not just the reader.
_CG="$(pick "$_V1")"
if _gate_cgroup_human_capable; then
  ok_t "E3 the v1/hybrid login session is ACCEPTED end-to-end (reader -> accept list)"
else
  bad_t "E3 v1/hybrid session accepted" "the picked path '$_CG' did not satisfy the accept list"
fi

# E4 hybrid where the unified line is bare '/': the systemd hierarchy still wins.
_HY=$'0::/\n1:name=systemd:/system.slice/shelld.service'
[[ "$(pick "$_HY")" == "/system.slice/shelld.service" ]] \
  && ok_t "E4 hybrid with a bare '/' unified line still resolves the unit" \
  || bad_t "E4 hybrid bare unified" "got '$(pick "$_HY")'"

# E5 NO PERMISSIVE FALLBACK: a stream with neither line REFUSES rather than
# returning some other hierarchy's path into a fail-closed accept list.
if pick $'3:cpu:/some/other/path\n4:blkio:/whatever' >/dev/null 2>&1; then
  bad_t "E5 unknown hierarchy refused" "the picker returned a path for a stream with no systemd line — that is the permissive fallback"
else
  ok_t "E5 a stream with no systemd line is REFUSED (no permissive fallback)"
fi

# E6 an empty/unreadable stream refuses.
if pick '' >/dev/null 2>&1; then
  bad_t "E6 empty stream refused" "the picker accepted an empty cgroup stream"
else
  ok_t "E6 an empty cgroup stream is REFUSED"
fi

# E7 a colon inside the unit path is not truncated — `${line##*:}` took only the
# tail, this takes everything after the two leading columns.
[[ "$(pick '0::/system.slice/weird:name.service')" == "/system.slice/weird:name.service" ]] \
  && ok_t "E7 a colon in the unit path is preserved" \
  || bad_t "E7 colon in path" "got '$(pick '0::/system.slice/weird:name.service')'"

printf '\nDIVE-2371 cgroup human-principal guard: passed: %s  failed: %s\n' "$PASS" "$FAIL"
[[ $PASS -gt 0 ]] || { printf 'FAIL - nothing was graded\n'; exit 1; }
[[ $FAIL -eq 0 ]] || exit 1
exit 0
