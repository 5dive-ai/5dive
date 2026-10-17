#!/usr/bin/env bash
# DIVE-6410 unit: a box-wide tier for new seats, and a verb that re-isolates an
# existing seat to admin.
#
# WHAT IS ASSERTED HERE (one arm each)
#   CONFIG.  `5dive config seat-isolation=admin` writes .seat_isolation, `default`
#            clears it, a bad value is refused and NOTHING is written, and the
#            reader returns admin only for admin (a hand-edited value reads empty).
#   CREATE.  with the setting, a create that names no --isolation is admin, first
#            seat or not; without it, the DIVE-1002 rule (first admin, then standard).
#   IMPORT.  with the setting, a pack whose manifest names standard imports admin;
#            an explicit --isolation still wins; without it, the manifest stands.
#   GRANT.   `agent grant <n> admin` plans update from a managed standard or root
#            policy and from none, current on the rendered admin policy, and refuses
#            a hand-written one. The rendered text is the one create writes.
#   MUTANTS. a reader that ignores the setting reds CREATE and IMPORT.
#
# Sources the src/ libs directly — no root, no adduser, no sudo, no network.
# Run: bash tests/seat_isolation_default_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }
eq_(){ [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1" "want [$3], got [$2]"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/seat-isolation.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

export STATE_DIR="$TMPD/state"; mkdir -p "$STATE_DIR"
export BOX_CONFIG="$TMPD/box.json"
export CONNECTORS_DIR="$TMPD/connectors"
export SUDOERS_D="$TMPD/sudoers.d"; mkdir -p "$SUDOERS_D"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh lib/audit.sh \
         lib/registry.sh lib/verify_policy.sh cmd_box_config.sh cmd_agent_create.sh cmd_pack.sh; do
  source "src/$f"
done
set +e
require_root() { return 0; }     # the harness is not root; the setter's logic is the subject
JSON_MODE=0

setcfg(){ printf '%s\n' "$1" > "$BOX_CONFIG"; }

echo "CONFIG"
rm -f "$BOX_CONFIG"
eq_ "unset box reads empty" "$(box_seat_isolation)" ""
cmd_box_config seat-isolation=admin >/dev/null 2>&1
eq_ "seat-isolation=admin is stored" "$(jq -r '.seat_isolation' "$BOX_CONFIG")" "admin"
eq_ "  and read back" "$(box_seat_isolation)" "admin"
eq_ "  and shown by config" "$(JSON_MODE=1 cmd_box_config --json 2>/dev/null | jq -r '.data.seat_isolation // .seat_isolation')" "admin"
before=$(cat "$BOX_CONFIG")
( cmd_box_config seat-isolation=standard ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok_ "seat-isolation=standard is refused" || bad_ "seat-isolation=standard is refused" "rc=$rc"
( cmd_box_config verify=never seat-isolation=root ) >/dev/null 2>&1
eq_ "  a refused value in a multi-key call writes nothing" "$(cat "$BOX_CONFIG")" "$before"
cmd_box_config seat-isolation=default >/dev/null 2>&1
eq_ "seat-isolation=default clears the key" "$(jq -r 'has("seat_isolation")' "$BOX_CONFIG")" "false"
setcfg '{"seat_isolation":"beyond-admin"}'
eq_ "a hand-edited value outside admin reads empty" "$(box_seat_isolation)" ""

echo "CREATE"
rm -f "$BOX_CONFIG"
eq_ "no setting, empty registry -> admin (DIVE-1002 bootstrap)" "$(_create_default_isolation 0)" "admin"
eq_ "no setting, later seat -> standard" "$(_create_default_isolation 3)" "standard"
setcfg '{"seat_isolation":"admin"}'
eq_ "seat-isolation=admin, later seat -> admin" "$(_create_default_isolation 3)" "admin"
eq_ "seat-isolation=admin, first seat -> admin" "$(_create_default_isolation 0)" "admin"
grep -q 'isolation=$(_create_default_isolation "$(registry_read' src/cmd_agent_create.sh \
  && ok_ "cmd_create resolves its no-flag tier through _create_default_isolation" \
  || bad_ "cmd_create resolves its no-flag tier through _create_default_isolation" "the call is gone"

echo "IMPORT"
setcfg '{"seat_isolation":"admin"}'
eq_ "setting admin beats a standard manifest" "$(_import_resolve_isolation standard '' 0)" "admin"
eq_ "setting admin fills a manifest with no tier" "$(_import_resolve_isolation '' '' 0)" "admin"
eq_ "an explicit --isolation=standard still wins" "$(_import_resolve_isolation admin standard 1)" "standard"
rm -f "$BOX_CONFIG"
eq_ "no setting: the manifest stands" "$(_import_resolve_isolation standard '' 0)" "standard"
eq_ "no setting, no manifest tier: empty (create decides)" "$(_import_resolve_isolation '' '' 0)" ""

echo "GRANT"
u=agent-maya
state(){ local p; p=$(_agent_grant_admin_plan "$1"); printf '%s' "${p%%|*}"; }
eq_ "no policy -> update" "$(state $u)" "update"
render_standard_sudoers "$u" 0 0 > "$SUDOERS_D/$u"
eq_ "managed standard policy -> update" "$(state $u)" "update"
render_root_sudoers "$u" > "$SUDOERS_D/$u"
eq_ "managed root policy -> update (narrows it)" "$(state $u)" "update"
render_admin_sudoers "$u" > "$SUDOERS_D/$u"
eq_ "rendered admin policy -> current" "$(state $u)" "current"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$u" > "$SUDOERS_D/$u"
eq_ "hand-written policy -> refuse" "$(state $u)" "refuse"
grep -q "^${u} ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive \*\$" <(render_admin_sudoers "$u") \
  && ok_ "the admin render is the CLI-as-root grant create writes" \
  || bad_ "the admin render is the CLI-as-root grant create writes" "$(render_admin_sudoers "$u" | tail -1)"
eq_ "  and classifies as cli-root" "$(render_admin_sudoers "$u" | classify_sudo_grant | cut -d'|' -f1)" "cli-root"
grep -q 'render_admin_sudoers "$user" > "$tmp"' src/cmd_agent_create.sh \
  && ok_ "write_admin_sudoers installs render_admin_sudoers' text" \
  || bad_ "write_admin_sudoers installs render_admin_sudoers' text" "a second copy of the policy"
eq_ "sandboxed seat is refused before any write" \
  "$(_cmd_agent_grant_admin maya agent-maya sandboxed 2>&1 >/dev/null | grep -c 're-create')" "1"

echo "MUTANTS"
setcfg '{"seat_isolation":"admin"}'
(
  box_seat_isolation() { printf ''; }   # a reader that ignores the setting
  [[ "$(_create_default_isolation 3)" == standard ]] && echo red-create
  [[ "$(_import_resolve_isolation standard '' 0)" == standard ]] && echo red-import
) > "$TMPD/mut"
eq_ "a reader that ignores the setting reds CREATE" "$(grep -c red-create "$TMPD/mut")" "1"
eq_ "a reader that ignores the setting reds IMPORT" "$(grep -c red-import "$TMPD/mut")" "1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
