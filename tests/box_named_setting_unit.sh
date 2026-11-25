#!/usr/bin/env bash
# DIVE-9315 — the box settings that replaced 5dive's own names in the core
# (wake-protected, own-orgs, principals, projects-root): the box's value wins,
# an unset one takes the devteam plugin's core/box-defaults.json, `none` is an
# explicit empty the plugin does not fill, and a bad value reads as unset.
# Pure: no root, no network. Run: bash tests/box_named_setting_unit.sh
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/box-named-setting.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/verify_policy.sh lib/devteam.sh; do
  source "src/$f"
done
set +e
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "ok   - $1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want [%s] got [%s]\n' "$1" "$2" "$3"; fi; }

export BOX_CONFIG="$TMP/box.json"; unset FIVE_PROJECTS_ROOT
PLUG="$TMP/plugin"; mkdir -p "$PLUG/core"; chmod 755 "$PLUG" "$PLUG/core"
printf '{"wake_protected":"main marketing","own_orgs":"5dive-ai lodar","principals":"lodar","projects_root":"/srv/checkouts"}\n' > "$PLUG/core/box-defaults.json"
chmod 644 "$PLUG/core/box-defaults.json"

echo '{}' > "$BOX_CONFIG"; _DEVTEAM_DIR=""
t "T1 no box value, no plugin: empty" "" "$(box_named_setting wake_protected)"
t "T2 projects-root falls back to the default workdir" "$DEFAULT_WORKDIR" "$(box_projects_root)"
_DEVTEAM_DIR="$PLUG"
t "T3 no box value: the plugin's" "main marketing" "$(box_named_setting wake_protected)"
t "T4 the plugin's projects root" "/srv/checkouts" "$(box_projects_root)"
echo '{"wake_protected":"ops","own_orgs":"none","projects_root":"/opt/work"}' > "$BOX_CONFIG"
t "T5 the box's value wins over the plugin's" "ops" "$(box_named_setting wake_protected)"
t "T6 none is empty and the plugin does not fill it" "" "$(box_named_setting own_orgs)"
t "T7 the box's projects root wins" "/opt/work" "$(box_projects_root)"
t "T8 FIVE_PROJECTS_ROOT wins over both" "/env/root" "$(FIVE_PROJECTS_ROOT=/env/root box_projects_root)"
echo '{"wake_protected":"a|b","projects_root":"rel/path"}' > "$BOX_CONFIG"
t "T9 a hand-edited bad list reads as unset (plugin value)" "main marketing" "$(box_named_setting wake_protected)"
t "T10 a relative projects root reads as unset" "/srv/checkouts" "$(box_projects_root)"
chmod 666 "$PLUG/core/box-defaults.json"
t "T11 a plugin file others can write is not read" "" "$(box_named_setting principals)"
chmod 644 "$PLUG/core/box-defaults.json"
t "T12 commas read as spaces" "x y" "$(echo '{"principals":"x,y"}' > "$BOX_CONFIG"; box_named_setting principals)"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
