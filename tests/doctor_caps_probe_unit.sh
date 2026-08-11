#!/usr/bin/env bash
# DIVE-3076 unit harness: `5dive doctor --caps` must not print a confident
# `github:read YES` on a seat that has no path to the claude uid.
#
# THE DEFECT UNDER REPAIR is an agent forming a false belief about its OWN
# capability (DIVE-3017: a seat declined to grade two items citing three true
# observations and a false conclusion). The probe's whole value is that its NO
# is trustworthy and its YES is live, so this harness grades exactly those two
# edges and does not bother re-testing jq plumbing.
#
# WHY THE NEGATIVE ARM ASSERTS A REASON STRING AND NOT "not YES". An
# absence-assertion (`! grep YES`) passes on EMPTY OUTPUT, which is the state a
# crashed probe produces — so it would have graded the probe green for not
# running (see community/wiki/grade-absence-assertions-by-mutation.md and the
# fail-open `[[ -z ... ]]` finding in
# community/wiki/pin-the-seam-the-derivation-reads-then-assert-the-pin.md).
# Every arm below requires a POSITIVE literal, and T5 mutates the derivation to
# prove the negative arm is wired to the code rather than to the fixture.
#
# Drives the three documented seams (doctor_caps_seat / doctor_caps_runas /
# doctor_caps_gh_probe) so no arm depends on the sudo policy, gh credential or
# uid of whoever runs the suite — that caller-scoping is itself the class this
# row is about, and a harness that inherits it grades its runner.
#
# Run: bash tests/doctor_caps_probe_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"   # agent_sudo_grant / classify_sudo_grant
# shellcheck source=/dev/null
source "$SRC/cmd_doctor.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

ok=0; fail=0
pass() { ok=$((ok+1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'NOT OK - %s\n' "$1"; }
has()  { # has <label> <needle> <haystack>
  case "$3" in *"$2"*) pass "$1" ;; *) bad "$1 (missing: $2)"; printf '  got: %s\n' "$3" ;; esac
}
hasnt() { case "$3" in *"$2"*) bad "$1 (present but must not be: $2)"; printf '  got: %s\n' "$3" ;; *) pass "$1" ;; esac
}

# --- seam liveness, asserted POSITIVELY before any arm leans on it ----------
# The seams are functions, which is what makes them overridable by a sourcing
# harness and not by an external caller. If a rename ever silently orphans one,
# every arm below would grade a stub nobody is calling — so prove the real
# implementation is reachable FIRST, by a value only the real one produces.
for _fn in doctor_caps_seat doctor_caps_runas doctor_caps_gh_probe doctor_build_caps; do
  if declare -F "$_fn" >/dev/null; then pass "seam $_fn is defined"
  else bad "seam $_fn is NOT defined — every arm below would grade nothing"; fi
done
SUDO_USER=agent-probe-live _live=$(doctor_caps_seat)
[[ "$_live" == "agent-probe-live" ]] \
  && pass "doctor_caps_seat resolves the real sudo caller (agent-probe-live)" \
  || bad "doctor_caps_seat is inert: expected agent-probe-live, got '${_live}'"

# --- fixtures ---------------------------------------------------------------
# Overridden per case. Defaults are deliberately hostile: an arm that forgets to
# set them gets a grant that does not exist and a gh that refuses.
_FAKE_CLASS="cli-root"; _FAKE_RUNAS="root"
_FAKE_GH_RC=1; _FAKE_GH_OUT="gh: not authenticated"
doctor_caps_runas()    { printf '%s|%s' "$_FAKE_CLASS" "$_FAKE_RUNAS"; }
doctor_caps_gh_probe() { printf '%s' "$_FAKE_GH_OUT"; return "$_FAKE_GH_RC"; }
# NOT `t=$(caps)`. doctor_build_caps mutates DOCTOR_CHECKS, and a command
# substitution would run it in a subshell where that mutation dies — which is
# the exact production bug T3 caught on the first cut. Call it in THIS shell and
# read the global.
caps() { SUDO_USER="agent-fixture" doctor_build_caps; printf '%s' "$DOCTOR_CAPS"; }
read_state()  { jq -r '."github:read".state'  <<<"$1"; }
read_detail() { jq -r '."github:read".detail' <<<"$1"; }

# ---------------------------------------------------------------------------
# T1 — THE NEGATIVE ARM. A seat whose grant is root-only has NO path, and the
# output must say so with the reason. This is the false positive the row exists
# to prevent: five of nine seats measured 2026-08-09 are in this state.
# ---------------------------------------------------------------------------
_FAKE_CLASS="cli-root"; _FAKE_RUNAS="root"
DOCTOR_CHECKS='[]'
caps >/dev/null; t1="$DOCTOR_CAPS"
[[ "$(read_state "$t1")" == "NO" ]] \
  && pass "T1 runas=root -> github:read NO" \
  || bad "T1 runas=root must be NO, got '$(read_state "$t1")'"
d1=$(read_detail "$t1")
has  "T1 detail names the grant class that caused the NO" "cli-root" "$d1"
has  "T1 detail says root only, not arbitrary uids"       "root only, not arbitrary uids" "$d1"
has  "T1 detail forecloses the password hunt"             "no password will make one" "$d1"
has  "T1 detail routes the read somewhere it can happen"  "runas" "$d1"
# The gh probe must NOT be consulted at all on this arm: calling it would prompt
# or hang on a seat that cannot switch uid, and its answer is irrelevant.
hasnt "T1 does not leak a gh probe result into the NO" "not authenticated" "$d1"
# A NO is a normal, permanent, by-design state — it must file no check row.
[[ "$(jq 'length' <<<"$DOCTOR_CHECKS")" == "0" ]] \
  && pass "T1 files no check row (a by-design NO is not a fault)" \
  || bad "T1 filed a check row: $DOCTOR_CHECKS"

# ---------------------------------------------------------------------------
# T2 — THE POSITIVE ARM. Permitted uid switch AND a live token: YES, with the
# account and scopes read off the LIVE call, never off a cached string.
# ---------------------------------------------------------------------------
_FAKE_CLASS="root-all"; _FAKE_RUNAS="any"
_FAKE_GH_RC=0; _FAKE_GH_OUT=$'octofixture\tgist, read:org, repo, workflow'
DOCTOR_CHECKS='[]'
caps >/dev/null; t2="$DOCTOR_CAPS"
[[ "$(read_state "$t2")" == "YES" ]] \
  && pass "T2 runas=any + live token -> github:read YES" \
  || bad "T2 must be YES, got '$(read_state "$t2")'"
d2=$(read_detail "$t2")
has "T2 detail carries the LIVE account"  "octofixture" "$d2"
has "T2 detail carries the LIVE scopes"   "read:org" "$d2"
has "T2 detail names the command"         "sudo -u claude gh" "$d2"
# The independence point, in the output rather than only in a wiki page: this is
# what stops a verifier handing a grade back to the maker on identity grounds.
has "T2 detail states a read mints nothing" "mints nothing and authors nothing" "$d2"
[[ "$(jq 'length' <<<"$DOCTOR_CHECKS")" == "0" ]] \
  && pass "T2 files no check row" \
  || bad "T2 filed a check row: $DOCTOR_CHECKS"

# ---------------------------------------------------------------------------
# T3 — PERMITTED BUT DEAD. `runas: any` says the uid switch is allowed; it does
# NOT say the token is valid or still scoped. This is the one genuinely
# check-shaped state, and the only arm that may file a row.
# ---------------------------------------------------------------------------
_FAKE_CLASS="root-all"; _FAKE_RUNAS="any"
_FAKE_GH_RC=1; _FAKE_GH_OUT="gh: You are not logged into any GitHub hosts"
DOCTOR_CHECKS='[]'
caps >/dev/null; t3="$DOCTOR_CAPS"
[[ "$(read_state "$t3")" == "NO" ]] \
  && pass "T3 runas=any + dead token -> github:read NO" \
  || bad "T3 must be NO (permitted != usable), got '$(read_state "$t3")'"
d3=$(read_detail "$t3")
has "T3 detail distinguishes permitted from usable" "is permitted here" "$d3"
has "T3 detail quotes what gh actually said"        "not logged into any GitHub hosts" "$d3"
[[ "$(jq 'length' <<<"$DOCTOR_CHECKS")" == "1" ]] \
  && pass "T3 files exactly one check row" \
  || bad "T3 expected 1 check row, got: $DOCTOR_CHECKS"
has "T3 check row is a warn"            '"severity":"warn"'        "$DOCTOR_CHECKS"
has "T3 check row is in category caps"  '"category":"caps"'        "$DOCTOR_CHECKS"
has "T3 check row names the repair"     'gh auth login'            "$DOCTOR_CHECKS"

# ---------------------------------------------------------------------------
# T4 — github:write is NO on EVERY arm, and its text must foreclose the borrow
# rather than merely withhold a flag. A reader who sees `read YES` one line up
# is exactly the reader who would otherwise reach for the claude uid to push.
# ---------------------------------------------------------------------------
for _case in t1 t2 t3; do
  _c="${!_case}"
  [[ "$(jq -r '."github:write".state' <<<"$_c")" == "NO" ]] \
    && pass "T4 $_case github:write NO" \
    || bad "T4 $_case github:write must be NO"
done
w=$(jq -r '."github:write".detail' <<<"$t2")
has "T4 write detail says the borrow is RETIRED" "RETIRED" "$w"
has "T4 write detail cites the row that retired it" "DIVE-3017" "$w"
has "T4 write detail refuses to read as permission" "NOT permission" "$w"
has "T4 write detail names the delegated route" "5dive push" "$w"

# ---------------------------------------------------------------------------
# T5 — MUTATION. Everything above passes just as well if the arms are wired to
# the FIXTURE rather than to the derivation. Force the one input that must flip
# the verdict and require T1's arm to go the other way; if it does not, this
# file grades nothing.
# ---------------------------------------------------------------------------
_FAKE_CLASS="cli-root"; _FAKE_RUNAS="any"    # the ONLY change from T1
_FAKE_GH_RC=0; _FAKE_GH_OUT=$'octofixture\trepo'
DOCTOR_CHECKS='[]'
caps >/dev/null; t5="$DOCTOR_CAPS"
[[ "$(read_state "$t5")" == "YES" ]] \
  && pass "T5 mutating runas root->any flips the verdict (the negative arm is wired to the derivation)" \
  || bad "T5 INERT: T1's NO survives runas=any, so it is not reading the derivation"
# And the inverse: the live probe must be load-bearing too, not decoration.
_FAKE_GH_RC=1; _FAKE_GH_OUT="gh: token expired"
caps >/dev/null
[[ "$(read_state "$DOCTOR_CAPS")" == "NO" ]] \
  && pass "T5b mutating the live probe to failing flips YES->NO (both arms are required)" \
  || bad "T5b INERT: YES survives a failing gh probe, so the live arm is decoration"

# ---------------------------------------------------------------------------
# T6 — the non-agent caller. `doctor` is require_root, so a human at a root
# shell has no SUDO_USER=agent-*. That is its own answer, not a seat's, and it
# must not be reported as though some seat measured YES.
# ---------------------------------------------------------------------------
_FAKE_GH_RC=0; _FAKE_GH_OUT=$'octofixture\trepo'
SUDO_USER="" doctor_build_caps; t6="$DOCTOR_CAPS"
has "T6 non-agent caller is labelled as not a seat" "not an agent seat" "$(jq -r '.seat' <<<"$t6")"
has "T6 non-agent caller says whose answer it is"   "ROOT caller's answer" "$(jq -r '.seat' <<<"$t6")"
[[ "$(jq -r '.sudoGrant' <<<"$t6")" == "not-an-agent-seat" ]] \
  && pass "T6 sudoGrant is not silently reported as a measured grant class" \
  || bad "T6 sudoGrant should be not-an-agent-seat, got '$(jq -r '.sudoGrant' <<<"$t6")'"

printf '\ndoctor_caps_probe_unit: %d passed, %d failed\n' "$ok" "$fail"
[[ "$fail" -eq 0 ]]
