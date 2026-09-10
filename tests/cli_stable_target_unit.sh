#!/usr/bin/env bash
# DIVE-4140: grade the customer CLI target resolver from install.sh verbatim.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
TD="$(mktemp -d)"; trap 'rc=$?; rm -rf "$TD"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

block="$(sed -n '/^# >>> DIVE-4140 stable CLI target/,/^# <<< DIVE-4140 stable CLI target/p' install.sh)"
if [[ -n "$block" ]] && grep -q 'resolve_cli_target()' <<<"$block"; then ok "stable resolver is extractable from install.sh"
else bad "stable resolver is missing"; echo "$PASS passed, $FAIL failed"; exit 1; fi

handoff="$(sed -n '/^[[:space:]]*# >>> DIVE-4140 stable installer handoff/,/^[[:space:]]*# <<< DIVE-4140 stable installer handoff/p' src/cmd_selfupdate.sh)"
if [[ -n "$handoff" ]] && grep -q 'CLI_VERSION_URL=' <<<"$handoff" \
   && grep -q 'bash "$installer" --upgrade' <<<"$handoff"; then
  ok "self-update installer handoff is extractable from src/cmd_selfupdate.sh"
else
  bad "self-update installer handoff is missing"
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

mkdir -p "$TD/bin" "$TD/etc" "$TD/state"
cat > "$TD/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "${FAKE_ROUTE:-fail}" in
  fail) exit 22 ;;
  *) printf '%s\n' "$FAKE_ROUTE" ;;
esac
CURL
cat > "$TD/bin/installed" <<'CLI'
#!/usr/bin/env bash
printf '5dive %s\n' "${FAKE_INSTALLED:-0.0.0}"
CLI
chmod +x "$TD/bin/curl" "$TD/bin/installed"

run_target(){ # route [installed] [allow]
  env -i PATH="$TD/bin:/usr/bin:/bin" FAKE_ROUTE="$1" FAKE_INSTALLED="${2:-0.0.0}" \
    FIVE_ALLOW_DOWNGRADE="${3:-0}" CLI_VERSION_OVERRIDE_FILE="$TD/etc/override" \
    CLI_CANARY_FILE="$TD/etc/canary" CLI_VERSION_KNOWN_FILE="$TD/state/known" \
    CLI_VERSION_URL=https://control.invalid/cli-version CLI_INSTALLED_BIN="$TD/bin/installed" \
    bash -c "set -euo pipefail
resolve_gh_tag(){ printf 'v9.9.9\\n'; }
$block
resolve_cli_target" 2>&1
}

printf 'v1.2.3\n' > "$TD/etc/override"
out="$(run_target v8.0.0)"; rc=$?
[[ $rc -eq 0 && "$out" == v1.2.3 ]] && ok "local override wins" || bad "local override did not win" "$out"
rm -f "$TD/etc/override"

out="$(run_target v1.4.0)"; rc=$?
[[ $rc -eq 0 && "$out" == v1.4.0 && "$(cat "$TD/state/known")" == v1.4.0 ]] \
  && ok "route target is validated and cached" || bad "route target/cache failed" "$out"

out="$(run_target fail)"; rc=$?
[[ $rc -eq 0 && "$out" == v1.4.0 ]] && ok "unreachable route uses last-known stable" || bad "last-known fallback failed" "$out"

out="$(run_target latest)"; rc=$?
[[ $rc -eq 0 && "$out" == v1.4.0 && "$out" != latest ]] && ok "invalid route never resolves latest" || bad "invalid route escaped stable rail" "$out"

rm -f "$TD/state/known"
out="$(run_target fail)"; rc=$?
[[ $rc -ne 0 && "$out" == *"NO STABLE CLI TAG RESOLVED"* ]] && ok "route failure without cache fails closed" || bad "empty fallback did not fail closed" "$out"

: > "$TD/etc/canary"
out="$(run_target fail)"; rc=$?
[[ $rc -eq 0 && "$out" == v9.9.9 ]] && ok "canary opt-in follows newest release" || bad "canary did not follow newest" "$out"
rm -f "$TD/etc/canary"

printf 'v1.4.0\n' > "$TD/state/known"
out="$(run_target v1.3.9 1.4.0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"below installed floor 1.4.0"* ]] && ok "installed version is a downgrade floor" || bad "downgrade floor failed" "$out"
out="$(run_target v1.3.9 1.4.0 1)"; rc=$?
[[ $rc -eq 0 && "$out" == v1.3.9 ]] && ok "explicit rollback hatch permits lower stable tag" || bad "rollback hatch failed" "$out"

# Red-smoke rehearsal: the ring file remains on the old tag while newest moves.
printf 'v1.4.0\n' > "$TD/state/known"
out="$(run_target v1.4.0 1.4.0)"; rc=$?
[[ $rc -eq 0 && "$out" == v1.4.0 && "$out" != v9.9.9 ]] \
  && ok "held stable tag keeps box self-update put" || bad "held box followed newest" "$out"

# Exercise the real self-update handoff, not only resolve_cli_target in
# isolation. This fake installer contains the shipped resolver. A fake red
# smoke writes the one-call brake, then the updater must keep the box on the
# held tag even while the route advertises a newer release.
cat > "$TD/bin/fetched-installer" <<EOF
#!/usr/bin/env bash
set -euo pipefail
resolve_gh_tag(){ printf 'v9.9.9\\n'; }
$block
resolve_cli_target
EOF
chmod +x "$TD/bin/fetched-installer"
printf 'v1.4.0\n' > "$TD/etc/override"
out="$(env -i PATH="$TD/bin:/usr/bin:/bin" FAKE_ROUTE=v9.9.9 FAKE_INSTALLED=1.4.0 \
  CLI_VERSION_OVERRIDE_FILE="$TD/etc/override" CLI_CANARY_FILE="$TD/etc/canary" \
  CLI_VERSION_KNOWN_FILE="$TD/state/known" CLI_INSTALLED_BIN="$TD/bin/installed" \
  bash -c "set -euo pipefail
installer=\"\$1\"
$handoff
" _ "$TD/bin/fetched-installer" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == v1.4.0 ]] \
  && ok "fake-red brake holds the real self-update installer handoff" \
  || bad "fake-red self-update rehearsal failed" "$out"
rm -f "$TD/etc/override"

mutant="$(sed '/if \[\[ -r "\$known_file"/,/^[[:space:]]*fi/ s/target=""/target="$(resolve_gh_tag)"/' <<<"$block")"
if [[ "$mutant" == "$block" ]]; then
  bad "fallback mutation applied" "mutation did not change extracted source"
else
  rm -f "$TD/state/known"
  set +e
  out="$(env -i PATH="$TD/bin:/usr/bin:/bin" FAKE_ROUTE=fail CLI_VERSION_OVERRIDE_FILE="$TD/etc/override" CLI_CANARY_FILE="$TD/etc/canary" CLI_VERSION_KNOWN_FILE="$TD/state/known" CLI_INSTALLED_BIN="$TD/bin/installed" bash -c "set -euo pipefail
resolve_gh_tag(){ echo v9.9.9; }
$mutant
resolve_cli_target" 2>&1)"; rc=$?
  set -e
  [[ $rc -eq 0 && "$out" == v9.9.9 ]] && ok "newest-on-error mutation is caught by the fail-closed assertion" || bad "newest-on-error mutation was not exercised" "$out"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
