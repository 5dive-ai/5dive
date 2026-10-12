#!/usr/bin/env bash
# DIVE-6049 — `5dive doctor` said `[error] host/cli-freshness: STALE … Fix: sudo
# 5dive update` on a box sitting EXACTLY on its fleet stable-route target, while
# `5dive update --check --json` on the same box in the same minute said
# `stale:false, resolvedTarget:v0.86.1, resolvedRung:route`. The published-version
# probe resolved "latest" as the newest unheld TAG; since DIVE-4140 the installer
# resolves the fleet stable ROUTE. Between a tag cut and the route promoting it —
# every release night — every box on the route target was told it was stale, and
# the fix it was handed reinstalls the same version and restarts its seats.
#
# This harness grades the ONE-RESOLVER property by running both resolvers against
# the SAME stubs: install.sh's resolve_cli_target (extracted verbatim) and
# _published_cli_probe (extracted verbatim), then the doctor check and
# `update --check` on the probe's answer. Hermetic: stubbed git/curl on a minimal
# PATH, every file either resolver consults pointed inside $TD, no network.
#
# Arms (the row's acceptance, numbered the same):
#   1  route vA, newest tag vB > vA, box on vA  -> freshness ok, provenance ok
#   2  box on vA-1, route vA -> STALE naming vA; route dead -> the installer's
#      own fall-through (last-known), rendered UNCONFIRMED, never a plain ok;
#      route dead and no last-known -> UNKNOWN
#   3  installer and probe pick the same tag on every rung; doctor and
#      `update --check` name the same target
#   4  mutation: the probe reverted to newest-tag turns arm 1 red
#
# Run: bash tests/cli_probe_route_target_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TD:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

probe_block="$(sed -n '/^# >>> DIVE-2042 published-version probe/,/^# <<< DIVE-2042 published-version probe/p' src/cmd_selfupdate.sh)"
inst_block="$(sed -n '/^# >>> DIVE-4223 release hold/,/^# <<< DIVE-4140 stable CLI target/p' install.sh)"
check_src="$(sed -n '/^cmd_update_check()/,/^}/p' src/cmd_selfupdate.sh)"
freeze_src="$(sed -n '/^# >>> DIVE-2287 version-freeze observer/,/^# <<< DIVE-2287 version-freeze observer/p' src/cmd_selfupdate.sh)"
if grep -q '_published_cli_probe()' <<<"$probe_block" && grep -q 'resolve_cli_target()' <<<"$inst_block" \
   && grep -q 'resolve_gh_tag()' <<<"$inst_block" && [[ -n "$check_src" && -n "$freeze_src" ]]; then
  ok_t "probe, installer ladder and update --check are extractable verbatim"
else
  bad_t "extraction failed" "probe=${#probe_block} installer=${#inst_block} check=${#check_src} freeze=${#freeze_src}"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
# shellcheck disable=SC1091
source src/cmd_selfupdate.sh
set +e

# ---------------------------------------------------------------- fixtures --
# v0.86.0 / v0.86.1 / v0.86.2 tagged; each tag serves its own bundle and real
# checksum, so a WRONG tag choice shows up as the wrong VERSION, not a state word.
TD="$(mktemp -d)"
mkdir -p "$TD/bin" "$TD/srv" "$TD/etc" "$TD/state"
for v in 0.86.0 0.86.1 0.86.2; do
  printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\n' "$v" > "$TD/srv/v$v"
  printf '%s  5dive\n' "$(sha256sum "$TD/srv/v$v" | awk '{print $1}')" > "$TD/srv/v$v.sha256"
done
cat > "$TD/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '0\trefs/tags/v0.86.0\n0\trefs/tags/v0.86.2\n0\trefs/tags/v0.86.1\n'
EOF
# FAKE_ROUTE: the tag the fleet route serves, or "" = route unreachable.
# FAKE_HOLD: "" = open, else the one tag held.
cat > "$TD/bin/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in -o) out="\$2"; shift 2;; --max-time|-H) shift 2;; -*) shift;; *) url="\$1"; shift;; esac
done
emit() { if [[ -n "\$out" ]]; then cat > "\$out"; else cat; fi; }
case "\$url" in
  *cli-version) [[ -n "\${FAKE_ROUTE:-}" ]] || exit 22; printf '%s\n' "\$FAKE_ROUTE" | emit ;;
  *.release-hold*) printf '# 5dive-release-hold v1\n%s\n' "\${FAKE_HOLD:-}" | emit ;;
  */v0.86.[0-2]/5dive.sha256) t="\${url%/5dive.sha256}"; emit < "$TD/srv/\${t##*/}.sha256" ;;
  */v0.86.[0-2]/5dive) t="\${url%/5dive}"; emit < "$TD/srv/\${t##*/}" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$TD/bin/git" "$TD/bin/curl"

# Every file either resolver consults lives in $TD — left at the defaults both
# would read THIS HOST (poke-two carries /etc/5dive/cli-canary), and a harness
# whose verdict depends on the machine grades the machine.
ladder_env() {
  printf '%s\n' PATH="$TD/bin:/usr/bin:/bin" GH_ORG=testorg \
    FAKE_ROUTE="${ROUTE-}" FAKE_HOLD="${HOLD-}" \
    CLI_VERSION_OVERRIDE_FILE="$TD/etc/override" CLI_CANARY_FILE="$TD/etc/canary" \
    CLI_VERSION_KNOWN_FILE="$TD/state/known" CLI_VERSION_URL=https://route.invalid/cli-version \
    CLI_INSTALLED_BIN="$TD/bin/installed-absent" CLI_TARGET_RECEIPT_FILE="$TD/state/cli-target.json"
}
run_installer() { # -> the tag install.sh would pin, or "" on refusal
  local -a e; mapfile -t e < <(ladder_env)
  env -i "${e[@]}" bash -c "set -euo pipefail
$inst_block
resolve_cli_target" 2>/dev/null
}
run_probe() { # [$1 = probe block override] -> the probe's five lines
  local -a e; mapfile -t e < <(ladder_env)
  env -i "${e[@]}" bash -c "set -uo pipefail
gh_org() { printf 'testorg\n'; }
${1:-$probe_block}
_published_cli_probe" 2>/dev/null
}
# The doctor check on a given installed bundle and probe answer -> rows JSON
run_doctor() {
  DOCTOR_CHECKS='[]'
  doctor_check_cli_freshness "$1" "$2" >/dev/null 2>&1
  jq -c '[.[] | {name, severity, message}]' <<<"$DOCTOR_CHECKS"
}
row() { jq -r --arg n "$2" 'map(select(.name == $n)) | .[0] | "\(.severity)|\(.message)"' <<<"$1"; }
# `update --check --json` on the same stubs. `ok` renders the JSON the real one
# would; the receipt it reads back is the one run_installer just wrote.
run_update_check() { # $1 = installed version
  local -a e; mapfile -t e < <(ladder_env)
  env -i "${e[@]}" HOME="$TD" bash -c "set -euo pipefail
E_USAGE=2; E_GENERIC=1; E_NOT_FOUND=4; FIVE_VERSION='$1'
STATE_DIR='$TD/state'
readonly UPDATE_STALE_AFTER_SECS=\$((36 * 3600))
gh_org() { printf 'testorg\n'; }
fail() { local c=\"\$1\"; shift; printf 'error: %s\n' \"\$*\"; exit \"\$c\"; }
ok() { shift; local f=\"\$1\"; shift; jq -nc \"\$@\" \"\$f\"; }
version_lt() { [[ \"\$1\" != \"\$2\" && \"\$(printf '%s\n%s\n' \"\$1\" \"\$2\" | sort -V | head -n1)\" == \"\$1\" ]]; }
$probe_block
$freeze_src
$check_src
cmd_update_check" 2>/dev/null
}
reset_ladder() { rm -f "$TD/etc/override" "$TD/etc/canary" "$TD/state/known" "$TD/state/cli-target.json"; ROUTE=""; HOLD=""; }

# =========================================================================
# 1. THE REPORTED BOX. Route serves v0.86.1, v0.86.2 is tagged, box runs the
#    v0.86.1 bundle byte-for-byte. Before the fix: STALE error + CANNOT TELL.
arm1_green() { # [$1 = probe block override]
  reset_ladder; ROUTE=v0.86.1
  local p r; p="$(run_probe "${1:-}")"; r="$(run_doctor "$TD/srv/v0.86.1" "$p")"
  [[ "$(row "$r" cli-freshness)" == ok\|*"matches the release target 0.86.1"* \
     && "$(row "$r" cli-provenance)" == ok\|*byte-identical* ]]
}
if arm1_green; then
  ok_t "route v0.86.1, newest tag v0.86.2, box on v0.86.1: freshness ok, provenance byte-identical"
else
  reset_ladder; ROUTE=v0.86.1; p="$(run_probe)"
  bad_t "box on the route target is not green" "probe=$(tr '\n' '|' <<<"$p") doctor=$(run_doctor "$TD/srv/v0.86.1" "$p")"
fi
reset_ladder; ROUTE=v0.86.1; p="$(run_probe)"
if [[ "$(sed -n 5p <<<"$p")" == "fleet stable route https://route.invalid/cli-version" ]]; then
  ok_t "the probe names the rung that chose the target (line 5: fleet stable route)"
else bad_t "probe line 5 does not name the route rung" "$(tr '\n' '|' <<<"$p")"; fi

# 2. NEGATIVE CONTROLS.
# 2a. One behind the route is STALE, and names the ROUTE target, not the newest tag.
reset_ladder; ROUTE=v0.86.1; p="$(run_probe)"; r="$(run_doctor "$TD/srv/v0.86.0" "$p")"
got="$(row "$r" cli-freshness)"
if [[ "$got" == error\|STALE*0.86.0*"but 0.86.1 is the release"* && "$got" != *0.86.2* ]]; then
  ok_t "box on v0.86.0 with the route at v0.86.1: STALE naming 0.86.1 (not the newest tag 0.86.2)"
else bad_t "one-behind-route did not read STALE naming the route target" "$got"; fi
# 2b. Route dead, last-known recorded: the installer's own fall-through. Same tag
#     as the installer, rendered UNCONFIRMED — never a plain green.
reset_ladder; printf 'v0.86.1\n' > "$TD/state/known"; inst="$(run_installer)"; p="$(run_probe)"
r="$(run_doctor "$TD/srv/v0.86.1" "$p")"; got="$(row "$r" cli-freshness)"
if [[ "$inst" == v0.86.1 && "$(sed -n 3p <<<"$p")" == v0.86.1 && "$(sed -n 5p <<<"$p")" == "last known stable"* \
      && "$got" == warn\|UNCONFIRMED* ]]; then
  ok_t "route unreachable: probe falls to last-known like the installer (both v0.86.1), doctor says UNCONFIRMED, not ok"
else bad_t "route-dead fall-through diverged or read green" "installer=$inst probe=$(tr '\n' '|' <<<"$p") doctor=$got"; fi
# 2c. Route dead, nothing recorded: no target. Installer refuses, doctor UNKNOWN.
reset_ladder; inst="$(run_installer)"; p="$(run_probe)"; r="$(run_doctor "$TD/srv/v0.86.1" "$p")"
got="$(row "$r" cli-freshness)"
if [[ -z "$inst" && "$(sed -n 1p <<<"$p")" == unavailable && "$got" == warn\|UNKNOWN* ]]; then
  ok_t "route unreachable and no last-known: installer refuses, probe unavailable, doctor UNKNOWN — not fresh"
else bad_t "route-dead/no-known read as fresh" "installer=$inst probe=$(tr '\n' '|' <<<"$p") doctor=$got"; fi

# 3. ONE RESOLVER. Same stubs, every rung: the tag install.sh pins is the tag the
#    probe names. A refusal on one side is a refusal on the other.
parity() { # $1 label
  local inst p pref
  inst="$(run_installer)"; p="$(run_probe)"
  pref=""; [[ "$(sed -n 1p <<<"$p")" == consistent ]] && pref="$(sed -n 3p <<<"$p")"
  if [[ "$inst" == "$pref" ]]; then ok_t "parity [$1]: installer and probe both resolve '${inst:-<refuse>}'"
  else bad_t "parity [$1]: installer and probe disagree" "installer='$inst' probe=$(tr '\n' '|' <<<"$p")"; fi
}
reset_ladder; ROUTE=v0.86.1;                                   parity "route"
reset_ladder; ROUTE=v0.86.1; : > "$TD/etc/canary";             parity "canary -> newest tag"
reset_ladder; ROUTE=v0.86.1; : > "$TD/etc/canary"; HOLD=v0.86.2; parity "canary, newest held -> previous"
reset_ladder; ROUTE=v0.86.2; printf 'v0.86.0\n' > "$TD/etc/override"; parity "local override"
reset_ladder; ROUTE=v0.86.1; HOLD=v0.86.1;                     parity "route target held -> both refuse"
reset_ladder; printf 'v0.86.1\n' > "$TD/state/known";          parity "route dead -> last-known"

# 3b. doctor and `update --check`, same minute, same stubs: same target. The
#     installer runs first so the receipt `update --check` reads back is real.
reset_ladder; ROUTE=v0.86.1; run_installer >/dev/null
p="$(run_probe)"; r="$(run_doctor "$TD/srv/v0.86.1" "$p")"; uc="$(run_update_check 0.86.1)"
if [[ "$(jq -r '.latest' <<<"$uc" 2>/dev/null)" == 0.86.1 && "$(jq -r '.resolvedTarget' <<<"$uc")" == v0.86.1 \
      && "$(jq -r '.behind' <<<"$uc")" == false && "$(jq -r '.stale' <<<"$uc")" == false \
      && "$(row "$r" cli-freshness)" == ok\|*0.86.1* ]]; then
  ok_t "doctor and update --check agree: target 0.86.1 (latest == resolvedTarget), not behind, doctor ok"
else bad_t "doctor and update --check disagree" "update --check=$uc doctor=$(row "$r" cli-freshness)"; fi

# 4. MUTATION. Revert the probe to newest-tag (every box takes the tag-list rung,
#    the pre-fix behaviour) and arm 1 must go red. Asserted to APPLY first — a
#    mutation that changed nothing grades green for the same reason a pass does.
mut="$(sed 's/^  elif \[\[ -e "\$canary_file" \]\]; then$/  elif true; then/' <<<"$probe_block")"
if [[ "$mut" == "$probe_block" ]]; then
  bad_t "mutation 'probe reads the newest tag' did not apply" "sed changed nothing — the arm is vacuous"
elif arm1_green "$mut"; then
  bad_t "mutation 'probe reads the newest tag' still passes arm 1" "arm 1 cannot detect the DIVE-6049 defect"
else
  reset_ladder; ROUTE=v0.86.1; got="$(row "$(run_doctor "$TD/srv/v0.86.1" "$(run_probe "$mut")")" cli-freshness)"
  if [[ "$got" == error\|STALE*0.86.2* ]]; then
    ok_t "mutation 'probe reads the newest tag' turns arm 1 red with the reported symptom (STALE naming 0.86.2)"
  else bad_t "mutation red, but not with the reported symptom" "$got"; fi
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
