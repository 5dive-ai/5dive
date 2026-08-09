#!/usr/bin/env bash
# DIVE-2642 (split of DIVE-2621 item d) — the marketplace reader is a CLONED
# AGENT, and the clone lives under each agent's own $HOME. Four agents sat on
# four distinct shas of one merged commit on 2026-08-03 and no surface reported
# it, so this harness grades the surface that now does.
#
# The accepting evidence is the STALE arm going RED and the CANNOT-RUN arms
# reading UNKNOWN. A green on a fleet that happens to be current proves nothing,
# which is why the all-current arm is here only as the non-vacuity control: it
# shows the check CAN say ok, so the warns above are not a constant.
#
# Runs against synthetic homes: no root, no network, no real agent home touched.
# Run: bash tests/doctor_marketplace_freshness_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-mp-freshness.XXXXXX)"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

G=(git -c user.email=agent@example.com -c user.name=fixture -c commit.gpgsign=false -c init.defaultBranch=main)

# --- fixture: an upstream marketplace with two commits ---------------------
UP="$TMP/upstream"
mkdir -p "$UP"; "${G[@]}" -C "$UP" init -q .
echo v1 >"$UP/plugin.json"; "${G[@]}" -C "$UP" add -A; "${G[@]}" -C "$UP" commit -qm v1
OLD_SHA=$("${G[@]}" -C "$UP" rev-parse HEAD)
echo v2 >"$UP/plugin.json"; "${G[@]}" -C "$UP" add -A; "${G[@]}" -C "$UP" commit -qm v2
NEW_SHA=$("${G[@]}" -C "$UP" rev-parse HEAD)

REL=".claude/plugins/marketplaces/5dive-plugins"
HOMES="$TMP/home"

# make_home <name> <current|stale|none|broken|unreadable>
make_home() {
  local name="$1" kind="$2"
  local h="$HOMES/$name"
  mkdir -p "$h/.claude"
  case "$kind" in
    none) ;;
    broken) mkdir -p "$h/$REL" ;;                        # a directory, but no git
    unreadable)
      mkdir -p "$h/$REL"
      "${G[@]}" clone -q "$UP" "$h/$REL" 2>/dev/null
      chmod 000 "$h/.claude/plugins" ;;
    *)
      "${G[@]}" clone -q "$UP" "$h/$REL"
      [[ "$kind" == stale ]] && "${G[@]}" -C "$h/$REL" reset -q --hard "$OLD_SHA"
      ;;
  esac
}

run_check() {                                            # run_check <ref-sha>
  DOCTOR_CHECKS='[]'
  doctor_check_marketplace_clones "$HOMES" "$1" "$REL" >/dev/null
  jq -c '.[0]' <<<"$DOCTOR_CHECKS"
}

assert_row() {                                           # <label> <ref> <sev> <rx>
  local label="$1" ref="$2" severity="$3" rx="$4" row
  row=$(run_check "$ref")
  if jq -e --arg s "$severity" --arg rx "$rx" \
      '.category == "plugins" and .name == "marketplace-freshness"
       and .severity == $s and (.message | test($rx))' <<<"$row" >/dev/null; then
    ok_t "$label"
  else
    bad_t "$label" "$row"
  fi
}

# 1. THE ACCEPTING ARM. One stale clone among current ones is reported red, by
#    NAME and sha, with the distance — not as a fleet boolean.
make_home a-current current
make_home b-stale   stale
assert_row "a stale clone reads warn and names agent, sha and distance" \
  "$NEW_SHA" warn "^STALE: 1 of 2 .*behind: b-stale:${OLD_SHA:0:7} \\(behind by 1\\)"

# 2. Every stale clone is listed. A population, not a first-hit report: four
#    agents on four shas have no single refresh, so all four must be nameable.
make_home c-stale stale
assert_row "a second stale clone is listed too (N of M, not a boolean)" \
  "$NEW_SHA" warn "^STALE: 1 of 3 .*b-stale:${OLD_SHA:0:7}.*c-stale:${OLD_SHA:0:7}"

# 3. CANNOT-RUN ARM 1: no published reference (ls-remote failed / no network).
#    The fleet below is unchanged, so ONLY the missing reference moves this.
assert_row "an unresolvable published head reads UNKNOWN, never fresh" \
  "" warn "^UNKNOWN: the published marketplace head could not be resolved"

# 4. CANNOT-RUN ARM 2: a clone directory that is not a git checkout is UNKNOWN,
#    not fresh and not absent. Presence of the directory is not a version.
rm -rf "${HOMES:?}/b-stale" "${HOMES:?}/c-stale"
make_home d-broken broken
assert_row "a non-git clone dir reads UNKNOWN, not fresh" \
  "$NEW_SHA" warn "UNKNOWN:.*d-broken:unreadable-clone"

# 5. A path we cannot LOOK at is not a path we know is absent.
rm -rf "${HOMES:?}/d-broken"
if (( EUID == 0 )); then
  printf 'SKIP - unreadable-home arm: running as root, chmod 000 does not deny root (arm would be vacuous)\n'
else
  make_home e-denied unreadable
  assert_row "an unreadable home reads UNKNOWN, not 'no clone'" \
    "$NEW_SHA" warn "UNKNOWN:.*e-denied:unreadable-home"
  chmod 755 "$HOMES/e-denied/.claude/plugins"
  rm -rf "${HOMES:?}/e-denied"
fi

# 6. CANNOT-RUN ARM 3: a home root with no agent homes in it. Nothing measured
#    is not the same as everything fresh — the emptiest possible green.
EMPTY="$HOMES"; HOMES="$TMP/emptyroot"; mkdir -p "$HOMES/not-an-agent"
assert_row "a home root with no agent homes reads UNKNOWN, not fresh" \
  "$NEW_SHA" warn "^UNKNOWN: no agent home found under"
HOMES="$EMPTY"

# 7. An agent with no marketplace clone is reported, but is not itself staleness:
#    it has no reader to be stale. Listed as context on an otherwise-ok row.
make_home f-noclone none
assert_row "a home without a clone is listed but does not fabricate staleness" \
  "$NEW_SHA" ok "^1 of 2 agent clones run published main ${NEW_SHA:0:7}.*no clone: f-noclone"

# 8. NON-VACUITY CONTROL: an all-current fleet is the ONLY shape that says ok,
#    which is what makes every warn above a real discrimination.
rm -rf "${HOMES:?}/f-noclone"
make_home g-current current
assert_row "an all-current fleet is ok (control: the check can say ok)" \
  "$NEW_SHA" ok "^2 of 2 agent clones run published main ${NEW_SHA:0:7}$"

# 9. The reference resolver reports FAILURE rather than a bare empty string, so
#    a caller cannot mistake "could not ask" for "nothing published".
out=$(doctor_marketplace_reference_sha "file://$TMP/no-such-repo" main 2>/dev/null); rc=$?
if (( rc != 0 )) && [[ -z "$out" ]]; then
  ok_t "the reference resolver exits non-zero on an unresolvable remote"
else
  bad_t "the reference resolver exits non-zero on an unresolvable remote" "rc=$rc out=$out"
fi

out=$(doctor_marketplace_reference_sha "file://$UP" main); rc=$?
if (( rc == 0 )) && [[ "$out" == "$NEW_SHA" ]]; then
  ok_t "the reference resolver returns the published head sha"
else
  bad_t "the reference resolver returns the published head sha" "rc=$rc out=$out"
fi

# 10. THE WIRING, EXECUTED — not read. A check nobody dispatches is a check that
#     never runs, and `--category=plugins` failing usage would make the surface
#     unreachable exactly the way `--category=policy` was (DIVE-2327). Stub the
#     root requirement and the two workers, then drive the real cmd_doctor.
require_root() { :; }
MP_CALLED=""
doctor_marketplace_reference_sha() { printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'; }
doctor_check_marketplace_clones() { MP_CALLED="$1|$2"; }

cmd_doctor --category=plugins >/dev/null 2>&1
if [[ "$MP_CALLED" == "/home|deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]]; then
  ok_t "--category=plugins dispatches the clone check with the resolved reference"
else
  bad_t "--category=plugins dispatches the clone check with the resolved reference" "MP_CALLED=$MP_CALLED"
fi

HOST_CALLED=""
doctor_check_audit_drop_dir() { HOST_CALLED=yes; }
MP_CALLED=""
cmd_doctor --category=plugins >/dev/null 2>&1
if [[ -n "$MP_CALLED" && -z "$HOST_CALLED" ]]; then
  ok_t "the filter is real: --category=plugins runs the clone check and not the host ones"
else
  bad_t "the filter is real: --category=plugins runs the clone check and not the host ones" "MP_CALLED=$MP_CALLED HOST_CALLED=$HOST_CALLED"
fi

# A category the parser does not know must still fail usage, and the usage text
# must NAME plugins — an unlisted-but-dispatched category is unreachable by
# every caller who reads the error (DIVE-2327).
usage_out=$( (cmd_doctor --category=definitely-not-a-category) 2>&1 ); usage_rc=$?
if (( usage_rc != 0 )) && [[ "$usage_out" == *plugins* ]]; then
  ok_t "an unknown category fails usage and the usage text lists plugins"
else
  bad_t "an unknown category fails usage and the usage text lists plugins" "rc=$usage_rc out=$usage_out"
fi

# 11. A reference that could not be resolved must reach the check as EMPTY, so
#     the UNKNOWN branch above is the one that fires. Silently substituting a
#     local checkout here would re-create the defect one layer down.
MP_CALLED="unset"
doctor_marketplace_reference_sha() { return 1; }
cmd_doctor --category=plugins >/dev/null 2>&1
if [[ "$MP_CALLED" == "/home|" ]]; then
  ok_t "an unresolvable reference reaches the check as empty (UNKNOWN, not substituted)"
else
  bad_t "an unresolvable reference reaches the check as empty (UNKNOWN, not substituted)" "MP_CALLED=$MP_CALLED"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
