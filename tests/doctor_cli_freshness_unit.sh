#!/usr/bin/env bash
# DIVE-2640 (split of DIVE-2621 item a) — `5dive doctor --category=host` must
# answer "is what is RUNNING on this host what we merged?", and must NEVER
# answer it green when it could not run.
#
# TIER: nightly — 0.6s measured on the control-plane box (agent-dev uid, offline, no root, `time bash tests/doctor_cli_freshness_unit.sh` = 0.57s over 5 runs). It is not the runtime that demotes it: core is ALREADY over its own 300s cap at 397s, so a new guard there is charged to every contributor on every push against a budget that is red before it arrives. `changed-harnesses` runs and verdict-probes this file at introduction regardless of tier, so the demotion moves the recurring cost without giving up the grade that matters.
#
# THE ACCEPTING EVIDENCE IS THE STALE ARM GOING RED. A freshness check that
# passes on a host which happens to be current proves nothing — that arm is a
# non-vacuity control and never the result. So every arm here is a MUTANT: the
# check is pointed at a deliberately stale bundle, an unreadable one, a bundle
# with no version line, a bundle wearing a release number it did not earn, and a
# probe that could not resolve anything. Each must land on its own verdict.
#
# Run: bash tests/doctor_cli_freshness_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/doctor-cli-freshness.XXXXXX)"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
# version_lt and _published_cli_probe live here; the check reuses the ONE
# resolver rather than growing a second one that drifts from install.sh.
# shellcheck disable=SC1091
source src/cmd_selfupdate.sh
set +e

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n   %s\n' "$1" "${2:-}"; }

# ------------------------------------------------------------- fixtures --
# Real bundles a release apart. `readonly FIVE_VERSION=` is the same line the
# published-probe reads, so both sides of every comparison are read the one way.
mkbundle() { printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\n# %s\n' "$1" "${2:-}" > "$3"; }
mkbundle 0.18.4 ''          "$TMP/bundle-old"
mkbundle 0.18.6 'published' "$TMP/bundle-new"
mkbundle 0.18.6 'HAND-BUILT — same version string, different bytes' "$TMP/bundle-stamped"
printf '#!/usr/bin/env bash\n# a bundle that declares no version\n'   > "$TMP/bundle-nover"
SHA_NEW="$(sha256sum "$TMP/bundle-new" | awk '{print $1}')"

# The probe's four-line contract, substituted so no arm needs the network.
probe_ok()    { printf 'consistent\n0.18.6\nv0.18.6\n%s\n' "$SHA_NEW"; }
probe_unavail(){ printf 'unavailable\n\nno release tag resolves — the installer could not upgrade this box either\n\n'; }
probe_indet() { printf 'indeterminate\n\nthe bundle published at v0.18.6 does not match its own checksum\n\n'; }

# run_check <bin> <probe> -> the three rows as one compact JSON array
run_check() {
  DOCTOR_CHECKS='[]'
  doctor_check_cli_freshness "$1" "$2" >/dev/null 2>&1
  jq -c '[.[] | {name, severity, message}]' <<<"$DOCTOR_CHECKS"
}

# assert_row <label> <rows-json> <name> <severity> <message-regex>
assert_row() {
  local label="$1" rows="$2" name="$3" sev="$4" rx="$5"
  if jq -e --arg n "$name" --arg s "$sev" --arg rx "$rx" \
      'map(select(.name == $n)) | length == 1 and (.[0].severity == $s) and (.[0].message | test($rx))' \
      <<<"$rows" >/dev/null 2>&1; then
    ok_t "$label"
  else
    bad_t "$label" "$(jq -c --arg n "$name" 'map(select(.name == $n))' <<<"$rows")"
  fi
}

# =========================================================================
# 1. THE ACCEPTING ARM. Installed 0.18.4, published 0.18.6 -> STALE, error.
#    An `ok` or a `warn` here is the whole defect: the board says merged, the
#    host runs something older, and nothing complains.
rows="$(run_check "$TMP/bundle-old" "$(probe_ok)")"
assert_row "stale install is an ERROR, and names both versions" \
  "$rows" cli-freshness error 'STALE.*0\.18\.4.*0\.18\.6'
# and it must not be reported as identified-against-main just because it is old
assert_row "a stale bundle's provenance is CANNOT TELL, never ok" \
  "$rows" cli-provenance warn 'CANNOT TELL'
# THE ARM THAT CARRIES THE ROW'S VALUE. Ancestry under squash merges is a
# POSITIVE-ONLY oracle — a match proves the build landed, a non-match proves
# nothing, because the squash rewrote the sha. A row that rendered the negative
# as "not merged" would manufacture alarms about healthy boxes, which is the
# class of false report this row exists to end, pointed the other way. So the
# unproven verdict must SAY it is unproven and must carry the reason.
assert_row "CANNOT TELL names the positive-only oracle and says UNPROVEN" \
  "$rows" cli-provenance warn 'POSITIVE-ONLY oracle.*a non-match proves NOTHING.*Read this as UNPROVEN'
# DIFFERENTIAL, not a substring ban: a `test("not merged")` arm would red on this
# check's own DISCLAIMER, which contains that phrase in order to forbid it. The
# property that actually matters is that UNPROVEN and DEFECTIVE land on different
# severities — so grade them against each other, on the same function, in one
# comparison. Stale bytes differ innocently (warn); hand-stamped bytes differ
# while CLAIMING the published version (error). If provenance ever collapsed
# those two, this arm reds and no wording change can quiet it.
sev_unproven="$(jq -r 'map(select(.name=="cli-provenance"))|.[0].severity' <<<"$rows")"
sev_defect="$(jq -r 'map(select(.name=="cli-provenance"))|.[0].severity' <<<"$(run_check "$TMP/bundle-stamped" "$(probe_ok)")")"
if [[ "$sev_unproven" == "warn" && "$sev_defect" == "error" ]]; then
  ok_t "unproven (warn) and defective (error) are different severities on the same check"
else
  bad_t "unproven (warn) and defective (error) are different severities on the same check" \
    "stale-bytes=$sev_unproven hand-stamped=$sev_defect — a non-match that cannot prove anything must not escalate like one that can"
fi
assert_row "a stale bundle still reports what it is" \
  "$rows" cli-installed ok '0\.18\.4.*mtime'

# 2. NON-VACUITY CONTROL (never the result): a genuinely current, byte-identical
#    install is the only shape allowed to read ok on all three rows.
rows="$(run_check "$TMP/bundle-new" "$(probe_ok)")"
assert_row "current install is ok" "$rows" cli-freshness ok 'matches the newest published release 0\.18\.6 \(from v0\.18\.6\)'
assert_row "byte-identical install is identified against the published tag" \
  "$rows" cli-provenance ok 'byte-identical to the bundle published at v0\.18\.6'
assert_row "current install reports version and mtime" "$rows" cli-installed ok '0\.18\.6.*mtime.*sha256'

# 3. THE HAND-STAMP. Same version string as the newest release, different bytes:
#    `0.18.0+dive2563` satisfied a 0.18.x criterion while running neither the
#    release nor main. Version equal + sha differing is a DEFECT, not a lag.
rows="$(run_check "$TMP/bundle-stamped" "$(probe_ok)")"
assert_row "a bundle wearing a release number it did not earn is an ERROR" \
  "$rows" cli-provenance error 'bytes differ from the bundle published at v0\.18\.6'
assert_row "...and freshness alone cannot see it — version comparison says current" \
  "$rows" cli-freshness ok 'matches the newest published release'

# 4. AHEAD is its own state (DIVE-2287), not "up to date": the monotonicity
#    guard refuses every upgrade from here, so it never self-corrects.
mkbundle 0.19.0 '' "$TMP/bundle-ahead"
rows="$(run_check "$TMP/bundle-ahead" "$(probe_ok)")"
assert_row "a box above the newest release reads AHEAD, not ok" \
  "$rows" cli-freshness warn 'AHEAD.*0\.19\.0.*above the newest published 0\.18\.6'

# =========================== the cannot-run arms =========================
# Each of these defaults to the empty, reassuring answer if written naively.
# None of them is staleness and none of them may be green.

# 5. No installed binary at all.
rows="$(run_check "$TMP/does-not-exist" "$(probe_ok)")"
for n in cli-installed cli-freshness cli-provenance; do
  assert_row "absent binary: $n is UNKNOWN, not ok" "$rows" "$n" warn 'UNKNOWN'
done

# 6. Present but unreadable — a permission answer, not a freshness one.
cp "$TMP/bundle-new" "$TMP/bundle-denied"; chmod 000 "$TMP/bundle-denied"
if [[ -r "$TMP/bundle-denied" ]]; then
  # chmod is inert against root; a root run cannot reach this arm, and a pass it
  # cannot reach is worse than a skip that says so.
  skip_t "unreadable binary is UNKNOWN" "running as uid $(id -u): chmod 000 is inert, the arm is UNREACHABLE here (re-run as non-root)"
else
  rows="$(run_check "$TMP/bundle-denied" "$(probe_ok)")"
  assert_row "unreadable binary is UNKNOWN and names the uid" \
    "$rows" cli-installed warn "UNKNOWN.*not readable by $(id -un)"
  assert_row "unreadable binary: freshness is UNKNOWN, not ok" "$rows" cli-freshness warn 'UNKNOWN'
fi

# 7. A bundle that will not say what it is.
rows="$(run_check "$TMP/bundle-nover" "$(probe_ok)")"
assert_row "a bundle with no FIVE_VERSION is UNKNOWN" \
  "$rows" cli-installed warn 'UNKNOWN.*declares no FIVE_VERSION'
assert_row "no version: freshness is UNKNOWN, not ok" "$rows" cli-freshness warn 'UNKNOWN'

# 8. The REFERENCE could not be resolved. This is the one that matters most for
#    a NAT'd fleet sharing a rate limit: no tag, no network, no answer — and
#    "no answer" must not read as "you are current".
for pf in probe_unavail probe_indet; do
  rows="$(run_check "$TMP/bundle-new" "$($pf)")"
  assert_row "$pf: freshness is UNKNOWN and disclaims currency" \
    "$rows" cli-freshness warn 'UNKNOWN.*not a statement that 0\.18\.6 is current'
  assert_row "$pf: provenance is UNKNOWN, no published bundle to identify against" \
    "$rows" cli-provenance warn 'UNKNOWN'
  assert_row "$pf: what IS installed is still reported" "$rows" cli-installed ok '0\.18\.6'
done

# 9. A consistent probe with an EMPTY sha (an older probe, or a caller that
#    dropped the field) must not silently pass provenance.
rows="$(run_check "$TMP/bundle-new" "$(printf 'consistent\n0.18.6\nv0.18.6\n\n')")"
assert_row "a probe with no published sha leaves provenance UNKNOWN" \
  "$rows" cli-provenance warn 'UNKNOWN.*unverified claim'

# ======================= the wiring, not the logic =======================
# 10. A check nobody dispatches is a check that never runs (DIVE-2327 shape).
# Captured into a variable, NOT piped into `grep -q`: under `pipefail` a -q grep
# closes the pipe on its first match and the upstream awk dies of SIGPIPE, so the
# pipeline reports failure on exactly the runs where the assertion PASSED
# fastest. That arm flaked green-then-red on two consecutive runs of this file.
host_block="$(awk '/if \(\( run_host \)\); then/,/^  fi$/' src/cmd_doctor.sh)"
if grep -q 'doctor_check_cli_freshness' <<<"$host_block"; then
  ok_t "the check is dispatched inside the run_host block"
else
  bad_t "the check is dispatched inside the run_host block" "not called under run_host — --category=host would never run it"
fi
# and `host` must be reachable through the --category allow-list. Read the list
# OUT of the usage string rather than asserting the whole string: that list grows
# (`plugins` arrived with DIVE-2642) and a literal match would red on someone
# else's addition while saying nothing about `host`.
catlist="$(grep -m1 -oP '(?<=unknown --category \()[^)]+' src/cmd_doctor.sh)"
if [[ -n "$catlist" ]] && grep -qE '(^|\|)host(\||$)' <<<"$catlist"; then
  ok_t "host is in the --category allow-list the usage error advertises"
else
  bad_t "host is in the --category allow-list the usage error advertises" "list read as '${catlist:-<unreadable>}'"
fi
# non-vacuity for the line above: the extraction really did find a list, and it
# really can say no — an always-true probe would pass this arm on an empty file.
if [[ -n "$catlist" ]] && ! grep -qE '(^|\|)notacategory(\||$)' <<<"$catlist"; then
  ok_t "the allow-list probe can also return false"
else
  bad_t "the allow-list probe can also return false" "list read as '${catlist:-<unreadable>}'"
fi

# 11. THE PROBE'S FOURTH LINE, run rather than grepped. The provenance row is
#     only as real as the published sha it compares against, so the resolver has
#     to actually emit it — with stubs, offline, from the shipped source.
block="$(sed -n '/^# >>> DIVE-2042 published-version probe/,/^# <<< DIVE-2042 published-version probe/p' src/cmd_selfupdate.sh)"
if [[ -z "$block" ]] || ! grep -q '_published_cli_probe()' <<<"$block"; then
  bad_t "probe block is extractable" "markers not found in src/cmd_selfupdate.sh"
else
  STUBS="$TMP/stubs"; mkdir -p "$STUBS"
  TOOLS="$(dirname "$(command -v sha256sum)")"
  cat >"$STUBS/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\trefs/tags/v0.18.6\n' 0000000000000000000000000000000000000000
EOF
  # Serve the real bundle and its real checksum, the way an intact tag does.
  cp "$TMP/bundle-new" "$STUBS/served"
  printf '%s  5dive\n' "$SHA_NEW" > "$STUBS/served.sha256"
  cat >"$STUBS/curl" <<EOF
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
case "\${!#}" in
  */5dive.sha256) cp "$STUBS/served.sha256" "\$out" ;;
  */5dive)        cp "$STUBS/served" "\$out" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$STUBS/git" "$STUBS/curl"
  out="$(env -i PATH="$STUBS:$TOOLS" HOME="$STUBS" bash -c "set -uo pipefail
gh_org() { printf 'testorg\n'; }
$block
_published_cli_probe" 2>/dev/null)"
  got4="$(sed -n '4p' <<<"$out")"
  if [[ "$(sed -n '1p' <<<"$out")" == "consistent" && "$got4" == "$SHA_NEW" ]]; then
    ok_t "the published probe emits the bundle's sha256 as line 4"
  else
    bad_t "the published probe emits the bundle's sha256 as line 4" "want '$SHA_NEW', got line4='$got4' (line1='$(sed -n '1p' <<<"$out")')"
  fi
  # Line 4 is EMPTY unless the answer is consistent — an unavailable probe must
  # not hand out a digest that would let provenance read green off nothing.
  cat >"$STUBS/git" <<'EOF'
#!/usr/bin/env bash
exit 128
EOF
  cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUBS/git" "$STUBS/curl"
  out="$(env -i PATH="$STUBS:$TOOLS" HOME="$STUBS" bash -c "set -uo pipefail
gh_org() { printf 'testorg\n'; }
$block
_published_cli_probe" 2>/dev/null)"
  if [[ "$(sed -n '1p' <<<"$out")" == "unavailable" && -z "$(sed -n '4p' <<<"$out")" ]]; then
    ok_t "an unavailable probe emits an EMPTY sha, not a stale one"
  else
    bad_t "an unavailable probe emits an EMPTY sha, not a stale one" "$(tr '\n' '|' <<<"$out")"
  fi
fi

echo
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]] || exit 1
