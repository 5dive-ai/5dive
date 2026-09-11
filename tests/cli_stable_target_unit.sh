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
# DIVE-4256 iteration 2: anchor on the ROUTE, not the presence of the var — a presence
# grep passes on a repointed literal, which is the value this arm exists to protect.
if [[ -n "$handoff" ]] \
   && grep -q 'CLI_VERSION_URL="${CLI_VERSION_URL:-https://api.5dive.com/cli-version}"' <<<"$handoff" \
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
    CLI_TARGET_RECEIPT_FILE="${RECEIPT:-$TD/state/cli-target.json}" \
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

# ---------------------------------------------------------------------------
# DIVE-4294: the resolution RECEIPT. The tag and the rung existed only in this
# function's locals; the dashboard could not name either. These arms grade the
# receipt as the READER sees it, and the load-bearing one is the negative:
# a pinned box and a canary box ON THE SAME TAG must not read identically.
# ---------------------------------------------------------------------------
RECEIPT="$TD/state/cli-target.json"
rget(){ jq -r "$1 // empty" "$RECEIPT" 2>/dev/null; }

rm -f "$RECEIPT"; printf 'v1.2.3\n' > "$TD/etc/override"
out="$(run_target v8.0.0)"
[[ "$out" == v1.2.3 ]] && ok "receipt: resolver return value is still ONLY the tag (no receipt noise on stdout/stderr)" \
  || bad "receipt writing leaked onto the resolver's own output" "$out"
[[ "$(rget .tag)" == v1.2.3 && "$(rget .rung)" == override ]] \
  && ok "receipt: override rung is recorded with its tag" \
  || bad "override receipt wrong" "$(cat "$RECEIPT" 2>/dev/null)"
[[ "$(rget .rungDetail)" == *"$TD/etc/override"* ]] \
  && ok "receipt: rungDetail names the file the pin came from" \
  || bad "rungDetail did not name the override file" "$(rget .rungDetail)"
[[ "$(rget .at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "receipt: carries an ISO-8601 UTC stamp" || bad "receipt stamp malformed" "$(rget .at)"
jq -e . "$RECEIPT" >/dev/null 2>&1 && ok "receipt: is parseable JSON" || bad "receipt is not JSON" "$(cat "$RECEIPT")"

# THE NEGATIVE ARM. Same tag, two rungs. `latest` is identical on these two
# boxes and so is `tag`; only `rung` separates them, which is why the rung is
# a field and not a nicety.
pin_json="$(cat "$RECEIPT")"
rm -f "$TD/etc/override" "$RECEIPT"; : > "$TD/etc/canary"
out="$(run_target fail)"
canary_tag="$(rget .tag)"; canary_rung="$(rget .rung)"
[[ "$out" == v9.9.9 && "$canary_tag" == v9.9.9 && "$canary_rung" == canary ]] \
  && ok "receipt: canary rung is recorded" || bad "canary receipt wrong" "$out / $(cat "$RECEIPT" 2>/dev/null)"
# Re-pin the override to the SAME tag the canary resolved, then compare.
printf 'v9.9.9\n' > "$TD/etc/override"; rm -f "$RECEIPT"
out="$(run_target fail)"
[[ "$(rget .tag)" == "$canary_tag" && "$(rget .rung)" != "$canary_rung" ]] \
  && ok "receipt: pin and canary ON THE SAME TAG are distinguishable (rung differs, tag does not)" \
  || bad "pin and canary read identically on the same tag" "$(cat "$RECEIPT" 2>/dev/null)"
rm -f "$TD/etc/override" "$TD/etc/canary"

rm -f "$RECEIPT" "$TD/state/known"
out="$(run_target v1.4.0)"
[[ "$(rget .tag)" == v1.4.0 && "$(rget .rung)" == route ]] \
  && ok "receipt: fleet-route rung is recorded" || bad "route receipt wrong" "$(cat "$RECEIPT" 2>/dev/null)"
rm -f "$RECEIPT"
out="$(run_target fail)"
[[ "$(rget .tag)" == v1.4.0 && "$(rget .rung)" == last-known ]] \
  && ok "receipt: last-known rung is recorded and is NOT reported as the route" \
  || bad "last-known receipt wrong" "$(cat "$RECEIPT" 2>/dev/null)"

set +e
# A resolve that FAILS must leave no receipt: a stale "this box installs X"
# outliving the failure is the exact lie the dashboard would then print.
rm -f "$RECEIPT" "$TD/state/known"
out="$(run_target fail)"; rc=$?
[[ $rc -ne 0 && ! -e "$RECEIPT" ]] \
  && ok "receipt: a failed resolve writes no receipt" || bad "failed resolve left a receipt" "rc=$rc $(cat "$RECEIPT" 2>/dev/null)"
# Same for the downgrade refusal — it returns before the record.
printf 'v1.0.0\n' > "$TD/etc/override"; rm -f "$RECEIPT"
out="$(run_target fail 9.9.9)"; rc=$?
[[ $rc -ne 0 && ! -e "$RECEIPT" ]] \
  && ok "receipt: a refused downgrade writes no receipt" || bad "downgrade refusal left a receipt" "rc=$rc"
rm -f "$TD/etc/override"

# An unwritable state directory must cost NOTHING on either stream — this is
# the arm that caught the redirection-order bug where bash printed the denial.
rm -f "$TD/etc/override" "$TD/etc/canary"; printf 'v1.4.0\n' > "$TD/state/known"
out="$(RECEIPT=/proc/self/nonexistent-dir/cli-target.json run_target fail)"
[[ "$out" == v1.4.0 ]] \
  && ok "receipt writing is silent when the state dir is unwritable" \
  || bad "unwritable state dir leaked onto the resolver's output" "$out"

# Mutation anchor: collapse the canary rung onto the override rung. If the
# negative arm above is real, this must go red.
mutant4294="$(sed 's/rung=canary/rung=override/' <<<"$block")"
if [[ "$mutant4294" == "$block" ]]; then
  bad "rung mutation applied" "mutation did not change extracted source"
else
  rm -f "$RECEIPT" "$TD/etc/override"; : > "$TD/etc/canary"
  env -i PATH="$TD/bin:/usr/bin:/bin" FAKE_ROUTE=fail CLI_VERSION_OVERRIDE_FILE="$TD/etc/override" \
    CLI_CANARY_FILE="$TD/etc/canary" CLI_VERSION_KNOWN_FILE="$TD/state/known" \
    CLI_INSTALLED_BIN="$TD/bin/installed" CLI_TARGET_RECEIPT_FILE="$RECEIPT" \
    bash -c "set -euo pipefail
resolve_gh_tag(){ printf 'v9.9.9\n'; }
$mutant4294
resolve_cli_target" >/dev/null 2>&1
  [[ "$(rget .rung)" == override ]] \
    && ok "rung mutation is reachable by the pin/canary arm (mutant reports a canary as a pin)" \
    || bad "rung mutation was not exercised" "$(cat "$RECEIPT" 2>/dev/null)"
  rm -f "$TD/etc/canary" "$RECEIPT"
fi
unset RECEIPT

# --- the READER half: `update --check --json` must report the receipt, and must
# never mint a target it did not observe.
reader="$(sed -n '/# >>> DIVE-4294 resolved target readback/,/# <<< DIVE-4294 resolved target readback/p' src/cmd_selfupdate.sh)"
if [[ -n "$reader" ]] && grep -q 'CLI_TARGET_RECEIPT_FILE' <<<"$reader"; then
  ok "resolved-target readback is extractable from src/cmd_selfupdate.sh"
else
  bad "resolved-target readback is missing from src/cmd_selfupdate.sh"
fi
read_receipt(){ # receipt-file -> "rt|rr|rd"
  # The block uses `local`, so it is graded inside a function — the same way
  # cmd_selfupdate runs it.
  bash -c "set -uo pipefail
CLI_TARGET_RECEIPT_FILE='$1'
readback(){
$reader
printf '%s|%s|%s\n' \"\$rt_json\" \"\$rr_json\" \"\$rd_json\"
}
readback" 2>&1
}
printf '{"tag":"v1.2.3","rung":"override","rungDetail":"local override /etc/5dive/cli-version","at":"2026-09-11T00:00:00Z"}\n' > "$TD/state/r.json"
got="$(read_receipt "$TD/state/r.json")"
[[ "$got" == '"v1.2.3"|"override"|"local override /etc/5dive/cli-version"' ]] \
  && ok "readback: a good receipt becomes JSON fields the dashboard can render" || bad "readback wrong" "$got"
got="$(read_receipt "$TD/state/absent.json")"
[[ "$got" == 'null|null|null' ]] && ok "readback: an ABSENT receipt reads as null, never as a guess" || bad "absent receipt did not read null" "$got"
printf '{"tag":"v1.2' > "$TD/state/trunc.json"
got="$(read_receipt "$TD/state/trunc.json")"
[[ "$got" == 'null|null|null' ]] && ok "readback: a truncated receipt reads as null (no half-tag on a customer screen)" || bad "truncated receipt leaked" "$got"
printf '{"tag":"main","rung":"override"}\n' > "$TD/state/bad.json"
got="$(read_receipt "$TD/state/bad.json")"
[[ "$got" == 'null|null|null' ]] && ok "readback: a non-tag value is refused (a ref is not a version)" || bad "non-tag value leaked" "$got"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
