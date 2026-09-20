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

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

TMP="$(mktemp -d /tmp/msj-selfheal.XXXXXX)"

# ---- source ONLY the reconcile helper (no other lib deps) --------------------
HELPER="$(sed -n '/^reconcile_managed_settings() {/,/^}/p' src/lib/agent_setup.sh)"
[[ -n "$HELPER" ]] \
  && ok_t "reconcile_managed_settings() present in src/lib/agent_setup.sh" \
  || bad_t "helper missing" "sed extract empty"
eval "$HELPER"

# DIVE-3537: the helper no longer carries its own copy of the channel list — it
# reads FIVEDIVE_CHANNEL_PLUGINS_JSON, the ONE constant the doctor gate also
# reads (the two used to be separate literals and drifted the day buzz shipped).
# Extract it the same narrow way, and FAIL if it cannot be found: an unset
# constant makes reconcile return 1, which would read here as a broken helper.
CONST="$(grep -m1 '^readonly FIVEDIVE_CHANNEL_PLUGINS_JSON=' src/header.sh)"
[[ -n "$CONST" ]] \
  && ok_t "FIVEDIVE_CHANNEL_PLUGINS_JSON present in src/header.sh" \
  || bad_t "channel-plugin constant missing" "grep found no readonly FIVEDIVE_CHANNEL_PLUGINS_JSON= in src/header.sh"
eval "$CONST"

# DIVE-4697: the same narrow extraction for the claude.ai account-sync opt-out
# constant and its two gates. reconcile_managed_settings RETURNS 1 when the sync
# constant is unset, so a missing constant would read here as a broken helper —
# assert it directly instead.
SYNC_CONST="$(grep -m1 '^readonly FIVEDIVE_MANAGED_SYNC_OFF_JSON=' src/header.sh)"
[[ -n "$SYNC_CONST" ]] \
  && ok_t "FIVEDIVE_MANAGED_SYNC_OFF_JSON present in src/header.sh" \
  || bad_t "sync-off constant missing" "grep found no readonly FIVEDIVE_MANAGED_SYNC_OFF_JSON= in src/header.sh"
eval "$SYNC_CONST"
for _fn in managed_settings_sync_off_ok managed_settings_sync_missing; do
  _EXTRACT="$(sed -n "/^${_fn}() {/,/^}/p" src/lib/agent_setup.sh)"
  [[ -n "$_EXTRACT" ]] \
    && ok_t "${_fn}() present in src/lib/agent_setup.sh" \
    || bad_t "${_fn}() missing" "sed extract empty"
  eval "$_EXTRACT"
done

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
# DIVE-3537: every entry of the constant, not just the two this harness was
# written for — that hand-listing is how the gate on this fixer went stale.
while read -r p m; do
  jq -e --arg p "$p" --arg m "$m" '.allowedChannelPlugins | any(.plugin==$p and .marketplace==$m)' "$TMP/stale.json" >/dev/null \
    && ok_t "self-heal adds $p@$m" \
    || bad_t "self-heal adds $p@$m" "$(cat "$TMP/stale.json")"
done < <(jq -r '.[] | "\(.plugin) \(.marketplace)"' <<<"$FIVEDIVE_CHANNEL_PLUGINS_JSON")
jq -e '.allowedChannelPlugins | any(.plugin=="myown" and .marketplace=="acme")' "$TMP/stale.json" >/dev/null \
  && ok_t "self-heal PRESERVES an operator's own channel entry" || bad_t "operator preserved" "$(cat "$TMP/stale.json")"
jq -e '.allowedChannelPlugins | any(.plugin=="telegram" and .marketplace=="claude-plugins-official")' "$TMP/stale.json" >/dev/null \
  && ok_t "self-heal PRESERVES the upstream/official entries" || bad_t "upstream preserved" "$(cat "$TMP/stale.json")"

# DIVE-4697: the same heal writes the claude.ai account-sync opt-out. The stale
# shape above carries NEITHER key — which is the state of every box provisioned
# before 2026-09-20, so this is the arm that proves the fleet converges.
_sync_arms=0
while read -r k v; do
  _sync_arms=$((_sync_arms+1))
  jq -e --arg k "$k" --argjson v "$v" '.[$k] == $v' "$TMP/stale.json" >/dev/null \
    && ok_t "self-heal writes $k=$v (claude.ai account sync opted out)" \
    || bad_t "self-heal writes $k=$v" "$(cat "$TMP/stale.json")"
done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"$FIVEDIVE_MANAGED_SYNC_OFF_JSON")
# A data-driven loop over an EMPTY constant runs zero arms and reports nothing —
# it reads identical to a clean pass. Count them: an arm that cannot fail is not
# an arm.
(( _sync_arms >= 2 )) \
  && ok_t "the sync-key loop ran $_sync_arms arms (constant is non-empty)" \
  || bad_t "sync-key loop ran $_sync_arms arms" "FIVEDIVE_MANAGED_SYNC_OFF_JSON is empty/unparseable — the arms above asserted NOTHING"

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

# ---- 3b. DIVE-4697: the sync GATE, and the value it must CORRECT --------------
# Only `false` is honoured by Claude Code; `true` turns nothing on (the feature
# is enabled server-side) and reads as "not opted out". So a box carrying `true`
# must be corrected, not preserved — this is the one place the reconcile
# overwrites a value an operator could have typed, and it is deliberate.
cat > "$TMP/synctrue.json" <<'J'
{"channelsEnabled":true,"syncClaudeAiSkills":true,"syncClaudeAiPlugins":false,"allowedChannelPlugins":[{"plugin":"telegram","marketplace":"5dive-plugins"},{"plugin":"dashboard","marketplace":"5dive-plugins"},{"plugin":"buzz","marketplace":"5dive-plugins"}],"myOwnKey":"keep me"}
J
managed_settings_sync_off_ok "$TMP/synctrue.json" \
  && bad_t "gate rejects syncClaudeAiSkills:true" "gate returned ok on a file that is NOT opted out" \
  || ok_t "gate rejects syncClaudeAiSkills:true (true is not an opt-out)"
[[ "$(managed_settings_sync_missing "$TMP/synctrue.json")" == "syncClaudeAiSkills" ]] \
  && ok_t "missing-gate names exactly the key that is wrong" \
  || bad_t "missing-gate naming" "got '$(managed_settings_sync_missing "$TMP/synctrue.json")'"
reconcile_managed_settings "$TMP/synctrue.json"; rc=$?
[[ "$rc" -eq 0 ]] \
  && ok_t "a file carrying sync:true -> exit 0 (corrected)" \
  || bad_t "sync:true exit code" "want 0 got $rc"
managed_settings_sync_off_ok "$TMP/synctrue.json" \
  && ok_t "gate passes after the correction" \
  || bad_t "gate after correction" "$(cat "$TMP/synctrue.json")"
jq -e '.myOwnKey == "keep me"' "$TMP/synctrue.json" >/dev/null \
  && ok_t "the correction leaves an operator's unrelated key intact" \
  || bad_t "operator key clobbered" "$(cat "$TMP/synctrue.json")"
# ABSENT must not read as opted out. `null == false` is false in jq, and this is
# the arm that holds that: if the gate ever treated absent as clean, every box
# provisioned before this change would report [ok] while the sync ran.
echo '{"channelsEnabled":true}' > "$TMP/syncabsent.json"
managed_settings_sync_off_ok "$TMP/syncabsent.json" \
  && bad_t "gate treats an ABSENT key as opted out" "absent must route to repair, never to ok" \
  || ok_t "gate treats an ABSENT sync key as NOT opted out"
managed_settings_sync_off_ok "$TMP/nope.json" \
  && bad_t "gate returns ok on a missing file" "cannot-prove must not read as clean" \
  || ok_t "gate on a missing file -> not ok (cannot prove it is off)"

# ---- 3c. DIVE-4697: install.sh's two copies must not drift from the constant --
# install.sh is curl-piped and cannot source src/header.sh, so it carries its
# own literals in BOTH the new-file template and the reconcile jq. Same drift
# shape the channel list has, so the same guard: diff them against the constant.
_drift_arms=0
while read -r k v; do
  _drift_arms=$((_drift_arms+1))
  awk -v k="\"$k\": $v," 'index($0, k) { found = 1 } END { exit !found }' install.sh \
    && ok_t "install.sh new-file template carries $k: $v" \
    || bad_t "install.sh template missing $k" "the template a NEW box gets must carry the opt-out"
  grep -qE "^[[:space:]]*\\|[[:space:]]*\\.$k[[:space:]]*=[[:space:]]*$v\$" install.sh \
    && ok_t "install.sh reconcile assigns .$k = $v" \
    || bad_t "install.sh reconcile missing .$k" "an EXISTING box only gains the key through the reconcile"
done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"$FIVEDIVE_MANAGED_SYNC_OFF_JSON")
(( _drift_arms >= 2 )) \
  && ok_t "the install.sh drift loop ran $_drift_arms arms (constant is non-empty)" \
  || bad_t "install.sh drift loop ran $_drift_arms arms" "an empty constant makes this guard silently cover nothing"

# ---- 4. doctor --fix wires DOCTOR_REPAIR -> reconcile_managed_settings --------
grep -q 'reconcile_managed_settings' src/cmd_doctor.sh \
  && ok_t "cmd_doctor.sh calls reconcile_managed_settings under --fix" \
  || bad_t "doctor wiring" "managed-settings check must self-heal, not just warn"
# the heal must be gated behind DOCTOR_REPAIR (a bare `doctor` stays read-only)
awk '/reconcile_managed_settings "\$ms"/{found=1} END{exit !found}' src/cmd_doctor.sh \
  && ok_t "doctor heals the live managed-settings file (\$ms) under repair" \
  || bad_t "doctor heals \$ms" ""
if grep -q 'DOCTOR_REPAIR' src/cmd_doctor.sh; then
  # Assert the reconcile call sits inside a DOCTOR_REPAIR guard (read-only default).
  # DIVE-1919: anchor on the CALL, not on a sed range. The old range
  # (/managed-settings/,/allowlisted"/) closed on the first later line ending in
  # `allowlisted"` — which is the check's own OK message, several lines ABOVE the
  # guard — so the range never contained DOCTOR_REPAIR and this assertion red-ed
  # on correct code as soon as that message was worded that way. Look at the lines
  # immediately preceding the call instead: that is the property under test.
  grep -B 5 'reconcile_managed_settings "\$ms"' src/cmd_doctor.sh | grep -q 'DOCTOR_REPAIR' \
    && ok_t "reconcile is guarded by DOCTOR_REPAIR (bare doctor stays a preview)" \
    || bad_t "repair guard" "reconcile must only fire under --fix"
fi


# ---- 5. DIVE-4697: doctor reports the sync gate, and heals it under --fix -----
# The gate must be the helper, not a hand-inlined jq: that is precisely how the
# channels check went stale on buzz and printed [ok] on every affected box.
grep -q 'managed_settings_sync_off_ok' src/cmd_doctor.sh \
  && ok_t "doctor gates the claude.ai sync check on managed_settings_sync_off_ok" \
  || bad_t "doctor sync gate" "the check must read the shared helper, never a re-typed jq"
grep -q 'doctor_add plugins claudeai-sync' src/cmd_doctor.sh \
  && ok_t "doctor reports a claudeai-sync row under --category=plugins" \
  || bad_t "doctor sync row" "no doctor_add plugins claudeai-sync in cmd_doctor.sh"
grep -B 5 'reconcile_managed_settings "\$_sync_ms"' src/cmd_doctor.sh | grep -q 'DOCTOR_REPAIR' \
  && ok_t "the sync heal is guarded by DOCTOR_REPAIR (bare doctor stays a preview)" \
  || bad_t "sync repair guard" "the sync reconcile must only fire under --fix"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
