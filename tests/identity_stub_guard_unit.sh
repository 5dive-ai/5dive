#!/usr/bin/env bash
# tests/identity_stub_guard_unit.sh — DIVE-2601.
#
# THE CLASS THIS GUARD CLOSES. Since DIVE-2330 the caller derivation does not read
# `id -un`: `_gate_caller_uid` reports $EUID and `_gate_passwd_stream` walks
# /etc/passwd in pure bash, precisely so a PATH-shimmed `id` cannot answer the
# question "who is calling?". Every harness that still stubs the `-un` branch of
# `id` therefore controls NOTHING — and it does not fail when it stops working. It
# goes quiet and keeps voting PASS while the answer comes from the uid of whoever
# ran the suite. DIVE-2588 is the worst case on record: 19/19 green on an agent box,
# 8 arms red on the CI runner, and the property the file claimed to grade had not
# been graded on either.
#
# THE RULE. A harness whose `id()` stub answers `-un` is making an identity claim.
# It must (1) pin the seams the derivation actually reads, and (2) assert the pin
# took effect THROUGH the real resolver before any arm leans on it. (2) is the part
# that converts this whole class from silent to loud: a pin that yields '' makes
# every "refused" arm below look correct for the wrong reason.
#
# WHY A CORPUS GUARD RATHER THAN 13 FIXES. The 13 were fixed (DIVE-2601). The next
# one gets written next week by someone who has not read this file, and the failure
# mode is silence — nothing in a code review distinguishes a green arm that grades
# something from a green arm that grades nothing.
#
# SELF-EXCLUSION, and it is not a formality. A corpus-wide checker matches its own
# pattern: this file must talk about `id()` stubs in order to look for them. The
# scan therefore skips its own basename, and arm A3 below proves the skip works by
# scanning a COPY of this file — because a self-exclusion that silently stopped
# working would make the guard flag itself forever, and a self-exclusion that was
# never needed would leave A3 passing vacuously. See
# community/wiki/a-consistency-check-cannot-see-a-substitution-that-rewrote-both-sides.md

set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SELF="$(basename "${BASH_SOURCE[0]}")"

# Harnesses allowed to answer `-un` without pinning the seams, each with the reason
# it is deliberate. Keep this list short and keep the reasons true: an entry here is
# a claim that the file's `id -un` is read by production code that genuinely still
# calls `id -un`, or that the file is testing `id` itself.
declare -A ALLOW=(
  [proof_identity_guard_unit.sh]='_proof_identity in cmd_proof.sh genuinely still reads `id -un`; this file is its test'
)

# _scan_identity_stubs <dir> — print one `<file>\t<reason>` line per violation.
#
# Taking the directory as an argument is what makes this testable: the same code
# that grades tests/ grades the synthetic fixtures in A1-A3 below. A guard that can
# only be pointed at the real corpus can only be graded by the corpus being clean,
# which is indistinguishable from the guard being broken.
_scan_identity_stubs() {
  local dir="$1" f base
  for f in "$dir"/*.sh; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == "$SELF" ]] && continue                    # self-exclusion (A3)
    [[ -n "${ALLOW[$base]:-}" ]] && continue
    # Only an `id()` stub that ANSWERS -un is making an identity claim. A stub that
    # only handles `id -u` (deploy_unit, agent_git_identity_unit) is pinning a
    # numeric uid for a different guard and is out of scope.
    grep -qE '^[[:space:]]*id\(\)' "$f" || continue
    grep -qE '^[[:space:]]*id\(\).*\-un' "$f" \
      || grep -qzE 'id\(\)[[:space:]]*\{[^}]*\-un' "$f" || continue
    # (1) the seams the derivation actually reads must be pinned
    if ! grep -qE '^[[:space:]]*_gate_(caller_uid|passwd_stream)\(\)|actor_seam_as' "$f"; then
      printf '%s\tstubs `id -un` but never pins _gate_caller_uid/_gate_passwd_stream — the caller identity comes from the HOST\n' "$base"
      continue
    fi
    # (2) and the pin must be asserted through the real resolver
    if ! grep -qE '_gate_authenticated_actor|_gate_uid_to_agent|actor_seam_selftest' "$f"; then
      printf '%s\tpins the identity seams but never asserts the pin through the real resolver (_gate_authenticated_actor / _gate_uid_to_agent / actor_seam_selftest)\n' "$base"
    fi
  done
}

FIX='tests/gate_enforce_env_bypass_unit.sh:127-154 is the in-tree pattern to copy'

# ── A1 positive control: a violating fixture MUST be flagged ──────────────────
# Without this the whole file could be a no-op that reports a clean corpus.
TMP="$(mktemp -d /tmp/identity-stub-guard.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/violator_unit.sh" <<'EOF'
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == violator_unit.sh*never\ pins* ]] \
  && ok_t "A1 a harness that stubs \`id -un\` with no seam pin is flagged" \
  || bad_t "A1 violating fixture is flagged" "scan returned '${got:-<nothing>}' — the guard cannot see the defect it exists for, so a clean corpus below would prove nothing"

# ── A2 the second half of the rule: pinned but unasserted is still a violation ─
cat > "$TMP/violator_unit.sh" <<'EOF'
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
_gate_caller_uid() { printf 0; }
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == *"never asserts the pin"* ]] \
  && ok_t "A2 a pinned-but-unasserted harness is flagged (the DIVE-2588 shape)" \
  || bad_t "A2 pinned-but-unasserted is flagged" "scan returned '${got:-<nothing>}' — a pin that silently yields nothing would pass this guard"

# ── A2b negative control: the compliant shape is NOT flagged ──────────────────
cat > "$TMP/violator_unit.sh" <<'EOF'
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
_gate_caller_uid() { printf 0; }
_pin=$(_gate_uid_to_agent "$(_gate_caller_uid)")
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ -z "$got" ]] \
  && ok_t "A2b the compliant shape (pin + assertion) is not flagged" \
  || bad_t "A2b compliant fixture passes" "scan flagged it: '$got' — a guard that rejects the fix it demands cannot be satisfied"

# ── A3 self-exclusion actually works, and is load-bearing ────────────────────
# This file necessarily contains the pattern it hunts for. The pair below is what
# makes the skip observable: IDENTICAL BYTES, one under this file's basename and
# one under another. Copying the real guard would not do it — the guard also
# mentions `_gate_caller_uid` and `_gate_authenticated_actor` in its own greps, so
# it reads as COMPLIANT and A3 would pass whether or not the skip exists. The
# fixture is therefore a known violator wearing the guard's name.
rm -f "$TMP"/*.sh
cat > "$TMP/$SELF" <<'EOF'
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ -z "$got" ]] \
  && ok_t "A3 the guard skips its own basename (a checker matches its own pattern)" \
  || bad_t "A3 self-exclusion" "the guard flags its own basename: '$got'"
mv "$TMP/$SELF" "$TMP/not_the_guard_unit.sh"
got="$(_scan_identity_stubs "$TMP")"
[[ -n "$got" ]] \
  && ok_t "A3b the self-exclusion is load-bearing (same bytes, other name, flagged)" \
  || bad_t "A3b self-exclusion is load-bearing" "the same bytes are not flagged under another name, so A3 passed for free and proves nothing"

# ── A4 the real corpus ────────────────────────────────────────────────────────
rm -f "$TMP"/*.sh
mapfile -t viol < <(_scan_identity_stubs tests)
if (( ${#viol[@]} == 0 )); then
  ok_t "A4 no harness in tests/ stubs \`id -un\` without a pinned, asserted identity"
else
  bad_t "A4 tests/ is free of inert identity stubs" \
    "$(printf '%s violation(s):\n' "${#viol[@]}"; printf '     %s\n' "${viol[@]}"; printf '     %s' "$FIX")"
fi

# ── A5 the allowlist may not rot ──────────────────────────────────────────────
# An entry naming a file that no longer exists is an allowlist nobody is reading.
for base in "${!ALLOW[@]}"; do
  if [[ -f "tests/$base" ]]; then
    ok_t "A5 allowlist entry $base still exists"
  else
    bad_t "A5 allowlist entry $base still exists" "allowlisted file is gone — drop the entry rather than leaving a silent exemption"
  fi
done

printf '\n%s: %d passed, %d failed\n' "$SELF" "$PASS" "$FAIL"
(( FAIL == 0 ))
