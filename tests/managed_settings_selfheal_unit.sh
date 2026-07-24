#!/usr/bin/env bash
# DIVE-1843: managed-settings SELF-HEAL (existing boxes reconcile without a
# human rerunning install.sh).
#
# DIVE-1816 shipped the reconcile in install.sh, but an existing box only healed
# when a human reran install.sh per box — and `doctor` merely WARNED. This locks
# the two additions that close that gap:
#   1. reconcile_managed_settings() (src/lib/agent_setup.sh) — the reusable
#      in-place heal, with a change-signalling exit code (0=changed, 3=current,
#      1=can't). Driven here against the exact claude-leaf stale shape.
#   2. `doctor --fix` wires DOCTOR_REPAIR -> reconcile_managed_settings so a box
#      self-heals with a single box-local command (no per-box install.sh rerun).
# Run: bash tests/managed_settings_selfheal_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

TMP="$(mktemp -d /tmp/msj-selfheal.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---- source ONLY the reconcile helper (no other lib deps) --------------------
HELPER="$(sed -n '/^reconcile_managed_settings() {/,/^}/p' src/lib/agent_setup.sh)"
[[ -n "$HELPER" ]] \
  && ok_t "reconcile_managed_settings() present in src/lib/agent_setup.sh" \
  || bad_t "helper missing" "sed extract empty"
eval "$HELPER"

# ---- 1. heals the exact claude-leaf stale shape ------------------------------
# channelsEnabled:false, dashboard@5dive-plugins ABSENT, plus an operator entry
# and the upstream/official entries that must survive.
cat > "$TMP/stale.json" <<'J'
{"channelsEnabled":false,"allowedChannelPlugins":[{"plugin":"telegram","marketplace":"5dive-plugins"},{"plugin":"telegram","marketplace":"claude-plugins-official"},{"plugin":"myown","marketplace":"acme"}]}
J
reconcile_managed_settings "$TMP/stale.json"; rc=$?
[[ "$rc" -eq 0 ]] \
  && ok_t "stale claude-leaf file -> exit 0 (a change was written)" \
  || bad_t "stale exit code" "want 0 got $rc"
jq -e '.channelsEnabled == true' "$TMP/stale.json" >/dev/null \
  && ok_t "self-heal flips channelsEnabled -> true" || bad_t "channelsEnabled" "$(cat "$TMP/stale.json")"
jq -e '.allowedChannelPlugins | any(.plugin=="dashboard" and .marketplace=="5dive-plugins")' "$TMP/stale.json" >/dev/null \
  && ok_t "self-heal adds dashboard@5dive-plugins (the dropped-ping fix)" || bad_t "dashboard added" "$(cat "$TMP/stale.json")"
jq -e '.allowedChannelPlugins | any(.plugin=="myown" and .marketplace=="acme")' "$TMP/stale.json" >/dev/null \
  && ok_t "self-heal PRESERVES an operator's own channel entry" || bad_t "operator preserved" "$(cat "$TMP/stale.json")"
jq -e '.allowedChannelPlugins | any(.plugin=="telegram" and .marketplace=="claude-plugins-official")' "$TMP/stale.json" >/dev/null \
  && ok_t "self-heal PRESERVES the upstream/official entries" || bad_t "upstream preserved" "$(cat "$TMP/stale.json")"

# ---- 2. idempotent: a second heal is a no-op with exit 3 (already current) ----
reconcile_managed_settings "$TMP/stale.json"; rc=$?
[[ "$rc" -eq 3 ]] \
  && ok_t "re-run on healed file -> exit 3 (already current, no rewrite)" \
  || bad_t "idempotent exit code" "want 3 got $rc"

# ---- 3. missing file / bad json -> exit 1 (never brick; caller can warn) ------
reconcile_managed_settings "$TMP/nope.json"; rc=$?
[[ "$rc" -eq 1 ]] \
  && ok_t "missing file -> exit 1 (can't reconcile)" \
  || bad_t "missing-file exit code" "want 1 got $rc"
echo '{not valid json' > "$TMP/bad.json"
reconcile_managed_settings "$TMP/bad.json"; rc=$?
[[ "$rc" -eq 1 ]] \
  && ok_t "invalid JSON -> exit 1 (leaves the hand-managed file untouched)" \
  || bad_t "bad-json exit code" "want 1 got $rc"
grep -q 'not valid json' "$TMP/bad.json" \
  && ok_t "invalid JSON file is left byte-untouched" || bad_t "bad json clobbered" ""

# ---- 4. doctor --fix wires DOCTOR_REPAIR -> reconcile_managed_settings --------
grep -q 'reconcile_managed_settings' src/cmd_doctor.sh \
  && ok_t "cmd_doctor.sh calls reconcile_managed_settings under --fix" \
  || bad_t "doctor wiring" "managed-settings check must self-heal, not just warn"
# the heal must be gated behind DOCTOR_REPAIR (a bare `doctor` stays read-only)
awk '/reconcile_managed_settings "\$ms"/{found=1} END{exit !found}' src/cmd_doctor.sh \
  && ok_t "doctor heals the live managed-settings file (\$ms) under repair" \
  || bad_t "doctor heals \$ms" ""
if grep -q 'DOCTOR_REPAIR' src/cmd_doctor.sh; then
  # assert the reconcile call sits inside a DOCTOR_REPAIR guard (read-only default)
  sed -n '/managed-settings/,/allowlisted"/p' src/cmd_doctor.sh | grep -q 'DOCTOR_REPAIR' \
    && ok_t "reconcile is guarded by DOCTOR_REPAIR (bare doctor stays a preview)" \
    || bad_t "repair guard" "reconcile must only fire under --fix"
fi

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
