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

# DIVE-4274. The two streams are graded SEPARATELY now, and that is a
# strengthening, not an accommodation. resolve_cli_target's stdout is a RETURN
# VALUE — every caller does GH_PINNED_TAG="$(resolve_cli_target)" — while its
# diagnostics are stderr. Merging them with 2>&1, as this harness used to, meant
# an arm could not tell "returned v1.2.3" from "printed something that contains
# v1.2.3", so a human-facing line accidentally emitted on stdout would have been
# installed as a version string with every arm still green.
LOGF="$TD/stderr"
run_target(){ # route [installed] [allow]   -> stdout only; stderr in $LOGF
  env -i PATH="$TD/bin:/usr/bin:/bin" FAKE_ROUTE="$1" FAKE_INSTALLED="${2:-0.0.0}" \
    FIVE_ALLOW_DOWNGRADE="${3:-0}" CLI_VERSION_OVERRIDE_FILE="$TD/etc/override" \
    CLI_CANARY_FILE="$TD/etc/canary" CLI_VERSION_KNOWN_FILE="$TD/state/known" \
    CLI_VERSION_URL=https://control.invalid/cli-version CLI_INSTALLED_BIN="$TD/bin/installed" \
    bash -c "set -euo pipefail
resolve_gh_tag(){ printf 'v9.9.9\\n'; }
$block
resolve_cli_target" 2>"$LOGF"
}
tlog(){ cat "$LOGF" 2>/dev/null; }

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
[[ $rc -ne 0 && "$(tlog)" == *"NO STABLE CLI TAG RESOLVED"* && -z "$out" ]] \
  && ok "route failure without cache fails closed (and returns nothing on stdout)" \
  || bad "empty fallback did not fail closed" "$out / $(tlog)"

: > "$TD/etc/canary"
out="$(run_target fail)"; rc=$?
[[ $rc -eq 0 && "$out" == v9.9.9 ]] && ok "canary opt-in follows newest release" || bad "canary did not follow newest" "$out"
rm -f "$TD/etc/canary"

printf 'v1.4.0\n' > "$TD/state/known"
out="$(run_target v1.3.9 1.4.0)"; rc=$?
[[ $rc -ne 0 && "$(tlog)" == *"below installed floor 1.4.0"* && -z "$out" ]] \
  && ok "installed version is a downgrade floor (and returns nothing on stdout)" \
  || bad "downgrade floor failed" "$out / $(tlog)"
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
" _ "$TD/bin/fetched-installer" 2>"$LOGF")"; rc=$?
# DIVE-4274: stderr is split out of this capture like every other arm, and for
# THIS arm that is a correction, not just a tidy-up. The shipped handoff runs
# `bash "$installer" --upgrade >&2` on purpose — the installer's output is log
# noise for the self-update caller, not a value — so the tag this arm looks for
# was never on stdout. Under the old `2>&1` that was invisible: the capture
# merged the two streams, so the arm could not distinguish "the handoff returned
# v1.4.0" (which it never does) from "something in the run mentioned v1.4.0".
# Assert against the stream the product actually uses, and pin the `>&2` while
# we are here: a handoff that leaked the installer's stdout to the caller would
# now be caught.
[[ $rc -eq 0 && "$(tlog)" == *v1.4.0* && "$(tlog)" != *v9.9.9* ]] \
  && ok "fake-red brake holds the real self-update installer handoff" \
  || bad "fake-red self-update rehearsal failed" "rc=$rc out='$out' log='$(tlog)'"
[[ -z "$out" ]] \
  && ok "the handoff keeps the installer's output off the caller's stdout" \
  || bad "the handoff leaked installer output onto stdout" "$out"
# And the rung that answered is named, so a rehearsal that silently fell through
# to a different rung cannot read as a held brake.
[[ "$(tlog)" == *"local override"* ]] \
  && ok "the held handoff names the rung it resolved from" \
  || bad "the held handoff did not name its rung" "$(tlog)"
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
resolve_cli_target" 2>/dev/null)"; rc=$?
  set -e
  [[ $rc -eq 0 && "$out" == v9.9.9 ]] && ok "newest-on-error mutation is caught by the fail-closed assertion" || bad "newest-on-error mutation was not exercised" "$out"
fi

# --- DIVE-4274: the resolution must SAY which rung answered -----------------
# "Updates started" followed by the same version, with no reason, is what
# produced "why it skipped update?". A pinned box and a canary box that happen
# to agree print the same tag; only the source distinguishes them.
rm -f "$TD/etc/override" "$TD/etc/canary"; printf 'v1.4.0\n' > "$TD/state/known"

out="$(run_target v1.4.0)"
[[ "$out" == v1.4.0 && "$(tlog)" == *"CLI target v1.4.0"* && "$(tlog)" == *"fleet stable route"* ]] \
  && ok "pin rung names itself" || bad "pin rung did not name itself" "$out / $(tlog)"

: > "$TD/etc/canary"
out="$(run_target fail)"
[[ "$out" == v9.9.9 && "$(tlog)" == *"canary"* && "$(tlog)" == *"CLI target v9.9.9"* ]] \
  && ok "canary rung names itself (the word the dashboard shows)" \
  || bad "canary rung did not name itself" "$out / $(tlog)"
# The two rungs must be DISTINGUISHABLE when they resolve the same tag —
# otherwise naming the source buys nothing over printing the version.
canary_log="$(tlog)"
rm -f "$TD/etc/canary"
out="$(run_target v9.9.9)"
[[ "$out" == v9.9.9 && "$(tlog)" != "$canary_log" && "$(tlog)" != *"canary"* ]] \
  && ok "same tag from a different rung reads differently" \
  || bad "pin and canary are indistinguishable on the same tag" "$(tlog)"

printf 'v9.9.9\n' > "$TD/etc/override"
out="$(run_target fail 0.0.0)"
[[ "$out" == v9.9.9 && "$(tlog)" == *"local override"* ]] \
  && ok "override rung names itself" || bad "override rung did not name itself" "$out / $(tlog)"
rm -f "$TD/etc/override"

# The diagnostic must never reach stdout: stdout is the RETURN VALUE, and a
# stray line there is installed as a version string.
out="$(run_target v1.4.0)"
[[ "$out" == v1.4.0 ]] && ok "stdout carries the tag and nothing else" \
  || bad "diagnostics leaked onto stdout — the caller would install this" "$out"

# Mutation anchor: move the diagnostic to stdout and the arm above must catch
# it. Without this, "stdout carries the tag" passes on a function that prints
# no diagnostic at all.
leak="${block//>&2/}"
if [[ "$leak" == "$block" ]]; then
  bad "stdout-leak mutation applied" "no >&2 redirect found to remove"
else
  out="$(env -i PATH="$TD/bin:/usr/bin:/bin" FAKE_ROUTE=v1.4.0 FAKE_INSTALLED=0.0.0 \
    FIVE_ALLOW_DOWNGRADE=0 CLI_VERSION_OVERRIDE_FILE="$TD/etc/override" \
    CLI_CANARY_FILE="$TD/etc/canary" CLI_VERSION_KNOWN_FILE="$TD/state/known" \
    CLI_VERSION_URL=https://control.invalid/cli-version CLI_INSTALLED_BIN="$TD/bin/installed" \
    bash -c "set -euo pipefail
resolve_gh_tag(){ printf 'v9.9.9\\n'; }
$leak
resolve_cli_target" 2>/dev/null)"
  [[ "$out" != v1.4.0 ]] && ok "mutation anchor: a diagnostic on stdout is caught" \
    || bad "mutation anchor: a diagnostic on stdout was NOT caught" "$out"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
