#!/usr/bin/env bash
# DIVE-6410 + DIVE-7143 unit: the box-wide rule for a new seat's tier, and a
# verb that re-isolates an existing seat to admin.
#
# WHAT IS ASSERTED HERE (one arm each)
#   CONFIG.  `5dive config seat-isolation=by-role|admin|standard` writes
#            .seat_isolation, `default` clears it, a bad value is refused and
#            NOTHING is written; unset (or a hand-edited value) reads by-role.
#   CREATE.  by-role (the default) and admin: a create that names no --isolation
#            is admin, first seat or not (a lone seat has no team lead); standard:
#            the DIVE-1002 rule (first admin, then standard).
#   IMPORT.  by-role: a lone import is admin, a manifest may narrow it (standard,
#            sandboxed) but never widen; admin beats the manifest; standard leaves
#            the manifest; an explicit --isolation always wins.
#   COMPOSE. by-role: a team seat with no tier of its own is pinned by where it
#            sits — the lead (no reports_to) admin, a member standard — on both the
#            create and the pack-import path; a spec's own tier is forwarded on
#            the pack path too (5dive-api renders one per seat); DIVE-6543's
#            non-pusher pin is untouched; under admin/standard nothing is added.
#            A member's Reporting block sends root work to its lead.
#   GRANT.   `agent grant <n> admin` plans update from a managed standard or root
#            policy and from none, current on the rendered admin policy, and refuses
#            a hand-written one. The rendered text is the one create writes.
#   MUTANTS. a rule reader that ignores the setting reds CREATE and IMPORT; a
#            compose that skips the member pin reads a member as a lone admin.
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
         lib/registry.sh lib/verify_policy.sh cmd_box_config.sh cmd_agent_create.sh cmd_pack.sh cmd_compose.sh; do
  source "src/$f"
done
set +e
require_root() { return 0; }     # the harness is not root; the setter's logic is the subject
JSON_MODE=0

setcfg(){ printf '%s\n' "$1" > "$BOX_CONFIG"; }

echo "CONFIG"
rm -f "$BOX_CONFIG"
eq_ "unset box stores nothing" "$(box_seat_isolation)" ""
eq_ "  and the rule in force is by-role" "$(box_seat_rule)" "by-role"
eq_ "  and config shows by-role" "$(JSON_MODE=1 cmd_box_config --json 2>/dev/null | jq -r '.data.seat_isolation // .seat_isolation')" "by-role"
for v in by-role admin standard; do
  cmd_box_config "seat-isolation=$v" >/dev/null 2>&1
  eq_ "seat-isolation=$v is stored" "$(jq -r '.seat_isolation' "$BOX_CONFIG")" "$v"
  eq_ "  and is the rule" "$(box_seat_rule)" "$v"
done
before=$(cat "$BOX_CONFIG")
( cmd_box_config seat-isolation=sandboxed ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok_ "seat-isolation=sandboxed is refused" || bad_ "seat-isolation=sandboxed is refused" "rc=$rc"
( cmd_box_config verify=never seat-isolation=root ) >/dev/null 2>&1
eq_ "  a refused value in a multi-key call writes nothing" "$(cat "$BOX_CONFIG")" "$before"
cmd_box_config seat-isolation=default >/dev/null 2>&1
eq_ "seat-isolation=default clears the key" "$(jq -r 'has("seat_isolation")' "$BOX_CONFIG")" "false"
setcfg '{"seat_isolation":"beyond-admin"}'
eq_ "a hand-edited value reads empty" "$(box_seat_isolation)" ""
eq_ "  and the rule is by-role" "$(box_seat_rule)" "by-role"
cmd_box_config --help 2>/dev/null | grep -q 'seat-isolation=.*by-role' \
  && ok_ "help names by-role on the seat-isolation line (5dive-api's build guard greps it)" \
  || bad_ "help names by-role on the seat-isolation line (5dive-api's build guard greps it)" "$(cmd_box_config --help 2>/dev/null | grep seat-isolation= | head -1)"

echo "CREATE"
rm -f "$BOX_CONFIG"
eq_ "no setting (by-role), empty registry -> admin" "$(_create_default_isolation 0)" "admin"
eq_ "no setting (by-role), later seat -> admin (no team lead)" "$(_create_default_isolation 3)" "admin"
setcfg '{"seat_isolation":"admin"}'
eq_ "seat-isolation=admin, later seat -> admin" "$(_create_default_isolation 3)" "admin"
eq_ "seat-isolation=admin, first seat -> admin" "$(_create_default_isolation 0)" "admin"
setcfg '{"seat_isolation":"standard"}'
eq_ "seat-isolation=standard, empty registry -> admin (DIVE-1002 bootstrap)" "$(_create_default_isolation 0)" "admin"
eq_ "seat-isolation=standard, later seat -> standard" "$(_create_default_isolation 3)" "standard"
grep -q 'isolation=$(_create_default_isolation "$(registry_read' src/cmd_agent_create.sh \
  && ok_ "cmd_create resolves its no-flag tier through _create_default_isolation" \
  || bad_ "cmd_create resolves its no-flag tier through _create_default_isolation" "the call is gone"

echo "IMPORT"
rm -f "$BOX_CONFIG"
eq_ "by-role: a lone import with no manifest tier is admin" "$(_import_resolve_isolation '' '' 0)" "admin"
eq_ "by-role: a manifest's admin stays admin" "$(_import_resolve_isolation admin '' 0)" "admin"
eq_ "by-role: a manifest may narrow to standard (an exported seat comes back as it was)" "$(_import_resolve_isolation standard '' 0)" "standard"
eq_ "by-role: ...or sandboxed" "$(_import_resolve_isolation sandboxed '' 0)" "sandboxed"
eq_ "by-role: an explicit --isolation=standard wins" "$(_import_resolve_isolation admin standard 1)" "standard"
setcfg '{"seat_isolation":"admin"}'
eq_ "setting admin beats a standard manifest" "$(_import_resolve_isolation standard '' 0)" "admin"
eq_ "setting admin fills a manifest with no tier" "$(_import_resolve_isolation '' '' 0)" "admin"
eq_ "an explicit --isolation=standard still wins" "$(_import_resolve_isolation admin standard 1)" "standard"
setcfg '{"seat_isolation":"standard"}'
eq_ "setting standard: the manifest stands" "$(_import_resolve_isolation admin '' 0)" "admin"
eq_ "setting standard, no manifest tier: empty (create decides)" "$(_import_resolve_isolation '' '' 0)" ""

echo "COMPOSE"
# The per-seat JSON both arg builders receive (defaults already merged in).
LEAD='{"type":"claude","pack":"kostya"}'
MEMBER='{"type":"claude","pack":"artyom","reports_to":["kostya"]}'
MEMBER_STR='{"type":"claude","reports_to":"kostya"}'
OWN='{"type":"claude","pack":"lena","reports_to":["kostya"],"isolation":"admin"}'
NONPUSH='{"type":"claude","pack":"q","reports_to":["kostya"],"can_push":false}'
iso_of(){ grep -E '^--isolation=' | tr '\n' ' ' | sed 's/ $//'; }
rm -f "$BOX_CONFIG"
eq_ "by-role, pack path: the lead is pinned admin" "$(_compose_import_args "$LEAD" kostya kostya . | iso_of)" "--isolation=admin"
eq_ "by-role, pack path: a member is pinned standard (its manifest never decides)" "$(_compose_import_args "$MEMBER" artyom artyom . | iso_of)" "--isolation=standard"
eq_ "by-role, create path: a member (reports_to as a string) is pinned standard" "$(_compose_create_args "$MEMBER_STR" ruslan . | iso_of)" "--isolation=standard"
eq_ "by-role, create path: the lead is pinned admin" "$(_compose_create_args '{"type":"claude"}' kostya . | iso_of)" "--isolation=admin"
eq_ "a spec's own tier is forwarded on the pack path, once, and wins" "$(_compose_import_args "$OWN" lena lena . | iso_of)" "--isolation=admin"
eq_ "DIVE-6543: a non-pusher is pinned standard once, by the push pin" "$(_compose_import_args "$NONPUSH" q q . | iso_of)" "--isolation=standard"
setcfg '{"seat_isolation":"admin"}'
eq_ "seat-isolation=admin: nothing added (the box default decides)" "$(_compose_import_args "$MEMBER" artyom artyom . | iso_of)" ""
setcfg '{"seat_isolation":"standard"}'
eq_ "seat-isolation=standard: nothing added" "$(_compose_create_args "$MEMBER_STR" ruslan . | iso_of)" ""
rm -f "$BOX_CONFIG"
grep -qF -- "- Work that needs root (sudo): ask **\${mgrs[0]}**" src/cmd_compose.sh \
  && ok_ "a member's Reporting block sends root work to its first manager" \
  || bad_ "a member's Reporting block sends root work to its first manager" "the line is gone"
grep -qF 'Standard-tier: ask your lead, `5dive agent send <lead> "<what+why>"`.' prompts/projects-CLAUDE.md \
  && ok_ "the box-wide CLAUDE.md sends a standard seat's root work to its lead, not to a sysadmin seat" \
  || bad_ "the box-wide CLAUDE.md sends a standard seat's root work to its lead, not to a sysadmin seat" "$(grep -n 'Standard-tier' prompts/projects-CLAUDE.md)"

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

echo "GRANT STANDARD"
u=agent-maya
sstate(){ local p; p=$(_agent_grant_standard_plan "$1"); printf '%s' "${p%%|*}"; }
rm -f "$SUDOERS_D/$u"
eq_ "no policy -> update" "$(sstate $u)" "update"
render_admin_sudoers "$u" > "$SUDOERS_D/$u"
eq_ "managed admin policy -> update (narrows it)" "$(sstate $u)" "update"
render_root_sudoers "$u" > "$SUDOERS_D/$u"
eq_ "managed root policy -> update (narrows it)" "$(sstate $u)" "update"
render_standard_sudoers "$u" 0 0 > "$SUDOERS_D/$u"
eq_ "rendered standard policy -> current" "$(sstate $u)" "current"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$u" > "$SUDOERS_D/$u"
eq_ "hand-written policy -> refuse" "$(sstate $u)" "refuse"
eq_ "sandboxed seat is refused before any write" \
  "$(_cmd_agent_grant_standard maya agent-maya sandboxed 2>&1 >/dev/null | grep -c 're-create')" "1"
body=$(sed -n '/^_cmd_agent_grant_standard()/,/^}/p' src/cmd_agent_create.sh)
w=$(grep -n 'update) write_standard_sudoers "$user" 0 0' <<<"$body" | cut -d: -f1)
st=$(grep -n '_agent_stamp_isolation "$name" "standard"' <<<"$body" | cut -d: -f1)
[[ -n "$w" && -n "$st" && "$w" -lt "$st" ]] \
  && ok_ "grant standard writes the standard policy (no push, no deploy) BEFORE it stamps the label (DIVE-2079)" \
  || bad_ "grant standard writes the standard policy (no push, no deploy) BEFORE it stamps the label (DIVE-2079)" "write@$w stamp@$st"
grep -q 'secrets_member_sync "$user" "standard"' <<<"$body" \
  && ok_ "  and takes the seat out of claude-keys" || bad_ "  and takes the seat out of claude-keys" "no secrets_member_sync"
grep -qE 'systemctl|_self_restart|agent restart' <<<"$body" \
  && bad_ "grant standard restarts nothing (a client's agent mid-task must not die)" "a restart is in the body" \
  || ok_ "grant standard restarts nothing (a client's agent mid-task must not die)"

echo "MUTANTS"
setcfg '{"seat_isolation":"admin"}'
(
  box_seat_rule() { printf 'standard'; }   # a reader that ignores the setting
  [[ "$(_create_default_isolation 3)" == standard ]] && echo red-create
  [[ "$(_import_resolve_isolation standard '' 0)" == standard ]] && echo red-import
) > "$TMPD/mut"
eq_ "a reader that ignores the setting reds CREATE" "$(grep -c red-create "$TMPD/mut")" "1"
eq_ "a reader that ignores the setting reds IMPORT" "$(grep -c red-import "$TMPD/mut")" "1"
rm -f "$BOX_CONFIG"
(
  _compose_role_tier() { :; }              # a compose that skips the member pin
  m=$(_compose_import_args "$MEMBER" artyom artyom . | iso_of)
  [[ -z "$m" && "$(_import_resolve_isolation '' '' 0)" == admin ]] && echo red-compose
) > "$TMPD/mut2"
eq_ "a compose without the member pin leaves a member to import's lone-seat admin" "$(grep -c red-compose "$TMPD/mut2")" "1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
