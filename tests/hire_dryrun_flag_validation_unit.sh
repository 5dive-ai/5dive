#!/usr/bin/env bash
# DIVE-4416 isolated unit harness for the two customer-reported CLI defects
# (report 2026-09-13, items 5 and 6):
#
#   ITEM 1 — `hire --from-market --dry-run` did not validate the flags it
#            previewed. Unknown flags were collected into import_args and only
#            ever parsed by cmd_import on the REAL run, so the dry-run printed
#            the disclosure and exited 0 on an argv the identical command
#            without --dry-run rejects. Graded here through _import_parse_args,
#            the validate-only entry the dry-run branch now calls.
#   ITEM 2 — `5dive agent rotation get|set|rotate|cooldown|clear-cooldown` is
#            dispatched in src/main.sh and appeared in NO help page. Graded as a
#            text assertion over the help block: every verb main.sh dispatches
#            must be documented, and nothing may be documented that it does not
#            dispatch (so the help cannot rot in either direction).
#
# Sources src/ libs directly — no root, no network, creates nothing.
# Run: bash tests/hire_dryrun_flag_validation_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_pack.sh is function-defs-only at source time; it carries _import_parse_args
# and the flag tables. cmd_hire.sh gives us cmd_hire_market's own parser shape.
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_hire.sh"

set +e   # header.sh enabled `set -e`; tests deliberately probe non-zero paths

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# `fail` exits the shell, so every probe runs in a subshell and we grade rc+stderr.
probe() { ( _import_parse_args "$@" ) 2>&1; }
probe_rc() { ( _import_parse_args "$@" ) >/dev/null 2>&1; printf '%s' "$?"; }

# ---- 1. the customer's exact flags now validate (and are forwarded) ---------
# Reported command:
#   sudo 5dive hire engineer --from-market --as=marcus --dry-run \
#        --isolation=admin --heartbeat-every=30m --inherit-memory=wiki
# hire consumes --as/--dry-run itself; --isolation is import's own flag and
# --heartbeat-every/--inherit-memory are the create-only pair hire forwards.
RC=$(probe_rc --isolation=admin --heartbeat-every=30m --inherit-memory=wiki)
[[ "$RC" == "0" ]] \
  && ok_t "the reported argv validates (import flag + two forwarded create flags)" \
  || bad_t "reported argv rejected" "rc=$RC out=$(probe --isolation=admin --heartbeat-every=30m --inherit-memory=wiki)"

# ---- 2. an unknown flag is rejected, and the message NAMES it ---------------
OUT=$(probe --isolation=admin --not-a-real-flag=7)
RC=$(probe_rc --isolation=admin --not-a-real-flag=7)
[[ "$RC" != "0" ]] \
  && ok_t "unknown flag -> non-zero (dry-run can no longer exit 0 on it)" \
  || bad_t "unknown flag accepted" "rc=$RC"
[[ "$OUT" == *"--not-a-real-flag=7"* ]] \
  && ok_t "the rejection names the offending flag" \
  || bad_t "flag not named in message" "$OUT"
[[ "$OUT" == *"unknown flag"* ]] \
  && ok_t "the rejection reuses cmd_import's own wording" \
  || bad_t "wording drifted from cmd_import" "$OUT"

# ---- 3. the validator is VALIDATE-ONLY -------------------------------------
# The whole point of the dry-run branch is that it creates nothing. Assert the
# validator calls none of the mutating entry points, by trapping them.
_tripped=""
cmd_create()  { _tripped="cmd_create";  return 0; }
cmd_import()  { _tripped="cmd_import";  return 0; }
cmd_org_set() { _tripped="cmd_org_set"; return 0; }
_import_parse_args --isolation=admin --heartbeat-every=30m >/dev/null 2>&1
[[ -z "$_tripped" ]] \
  && ok_t "validate-only: touches no create/import/org path" \
  || bad_t "validator mutated" "called $_tripped"

# ---- 4. the space form is rejected, exactly as the real run rejects it ------
# cmd_import's arms are `--flag=*)` only; `--as nova` falls to "unknown flag" on
# the real run, so the preview must reject it too or it lies the other way.
# (See community/wiki/repo-docs-vs-installed-cli-sweep-sep06.md for the
# space-form oracle blind spot this mirrors.)
[[ "$(probe_rc --as nova)" != "0" ]] \
  && ok_t "space form '--as nova' rejected, matching the real parser" \
  || bad_t "space form accepted" "the real run would fail on this"
[[ "$(probe_rc --as=nova)" == "0" ]] \
  && ok_t "'=' form '--as=nova' accepted" \
  || bad_t "'=' form rejected" ""

# ---- 5. every forwarded create flag is a flag cmd_create actually parses ----
# The passthrough is only customer-friendly if cmd_create accepts what we hand
# it; a typo here would move the "unknown flag" one call deeper instead of
# fixing it. Grade the tables against cmd_agent_create.sh's case arms.
CREATE_SRC="$SRC/cmd_agent_create.sh"
for f in "${_IMPORT_CREATE_PASSTHRU_VALUE_FLAGS[@]}"; do
  grep -q -- "^[[:space:]]*$f=\*)" "$CREATE_SRC" \
    && ok_t "forwarded value flag $f= is a cmd_create case arm" \
    || bad_t "forwarded flag not in cmd_create" "$f="
done
for f in "${_IMPORT_CREATE_PASSTHRU_BOOL_FLAGS[@]}"; do
  grep -q -- "^[[:space:]]*$f)" "$CREATE_SRC" \
    && ok_t "forwarded bool flag $f is a cmd_create case arm" \
    || bad_t "forwarded flag not in cmd_create" "$f"
done

# ---- 6. the forwarded set must not collide with what import computes -------
# import builds its own --type/--channels/--isolation/--model/--auth-profile/
# --workdir/tokens/--no-skills/--defer-auth/BYO args; forwarding any of those
# would append a second, conflicting copy to the same cmd_create argv.
_collide=""
for f in "${_IMPORT_CREATE_PASSTHRU_VALUE_FLAGS[@]}" "${_IMPORT_CREATE_PASSTHRU_BOOL_FLAGS[@]}"; do
  for o in "${_IMPORT_OWN_VALUE_FLAGS[@]}" "${_IMPORT_OWN_BOOL_FLAGS[@]}"; do
    [[ "$f" == "$o" ]] && _collide="$_collide $f"
  done
done
[[ -z "$_collide" ]] \
  && ok_t "no forwarded flag collides with an import-owned flag" \
  || bad_t "forwarded flag collides with import's own" "$_collide"

# ---- 7. ITEM 2: rotation verbs are documented, and the help matches dispatch -
# main.sh dispatches the verbs inside the `rotation)` arm; the help block must
# carry a `5dive agent rotation <verb>` line for each, and no extra ones.
MAIN="$SRC/main.sh"
DISPATCHED=$(sed -n '/^        rotation)/,/^        ;;/p' "$MAIN" \
  | grep -oE '^\s+(get|set|rotate|cooldown|clear-cooldown)\)' \
  | tr -d ' )' | sort -u)
DOCUMENTED=$(grep -oE '^  5dive agent rotation [a-z-]+' "$MAIN" \
  | awk '{print $4}' | sort -u)
[[ -n "$DOCUMENTED" ]] \
  && ok_t "help block documents 'agent rotation' at all (was absent entirely)" \
  || bad_t "rotation still undocumented" "no '5dive agent rotation' help line"
[[ -n "$DISPATCHED" && "$DISPATCHED" == "$DOCUMENTED" ]] \
  && ok_t "documented rotation verbs == dispatched rotation verbs" \
  || bad_t "help/dispatch drift" "dispatched=[$(echo "$DISPATCHED" | tr '\n' ' ')] documented=[$(echo "$DOCUMENTED" | tr '\n' ' ')]"

# ---- 8. WIRING: the real `hire --from-market --dry-run` argv, end to end -----
# quinn's iteration-1 finding, and the reason this arm exists: every arm above
# calls _import_parse_args DIRECTLY, so they grade the COMPONENT and not the
# WIRING. Neutering the single line that connects the new parser to the dry-run
# branch (src/cmd_hire.sh, the `_import_parse_args "${import_args[@]}"` call)
# left this harness at full green while the customer's exact command went back to
# rc=0 with the disclosure printed — the acceptance harness could not fail for
# the reason the row exists. An arm that proves a part is correct is not an arm
# that proves the part is connected (same shape as the DIVE-4328 finding).
#
# So: build a throwaway bundle and run the REAL argv through it. It dies in the
# flag parser before the market is resolved — no root, no network, creates
# nothing — and we assert BOTH halves: non-zero, and the offending flag NAMED.
# Naming the flag is what makes the arm precise rather than merely non-zero: with
# the wiring cut, a box with no registry reachable would also exit non-zero, but
# its message would be about the registry, not about --bogus-flag=1.
_bin_tmp="$(mktemp -d /tmp/dive4416-hire-e2e.XXXXXX)"
if BUILD_OUT="$_bin_tmp/5dive" bash ./build.sh >"$_bin_tmp/build.log" 2>&1 && [[ -x "$_bin_tmp/5dive" ]]; then
  E2E_OUT=$("$_bin_tmp/5dive" hire engineer --from-market --as=marcus --dry-run --bogus-flag=1 2>&1)
  E2E_RC=$?
  [[ "$E2E_RC" != "0" ]] \
    && ok_t "E2E: 'hire --from-market --dry-run --bogus-flag=1' exits non-zero (was a constant 0)" \
    || bad_t "E2E: the dry-run still exits 0 on a flag the real run rejects" "rc=$E2E_RC out=$(printf '%s' "$E2E_OUT" | head -3)"
  [[ "$E2E_OUT" == *"--bogus-flag=1"* ]] \
    && ok_t "E2E: the rejection names the offending flag (not a registry error standing in)" \
    || bad_t "E2E: non-zero but the flag is not named" "out=$(printf '%s' "$E2E_OUT" | head -5)"
  # A dry run that dies in the parser must still create NOTHING and must not have
  # reached the disclosure — the operator should see the error, not a green preview.
  [[ "$E2E_OUT" != *"DRY RUN — nothing created"* && "$E2E_OUT" != *"install-time disclosure"* ]] \
    && ok_t "E2E: no disclosure and no DRY-RUN banner printed on a rejected argv" \
    || bad_t "E2E: the disclosure/banner printed despite the bad flag" "out=$(printf '%s' "$E2E_OUT" | head -8)"
else
  # Do NOT skip green: this is the only arm that binds the wiring, and a silent
  # skip is exactly how the gap above survived a full-green run.
  bad_t "E2E: could not build a throwaway bundle to grade the wiring" "$(tail -3 "$_bin_tmp/build.log" 2>/dev/null)"
fi
rm -rf "$_bin_tmp"

echo
printf 'DIVE-4416 hire dry-run flag validation + rotation help: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
