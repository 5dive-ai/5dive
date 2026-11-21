#!/usr/bin/env bash
# DIVE-8284 + DIVE-9004 unit harness: a sandboxed seat always gets its own team
# rail (_team_self), plus the two self-only chat rails when it has web chat, and
# nothing else.
#
# The defect this pins: `agent config <sandboxed> set channels=dashboard`
# succeeded, but the seat held no sudoers, so its chat adapter could not reach
# `_dashboard_relay` (or `_chat_e2e` on an encrypted server) and the chat was
# silently deaf (lodar's grok on chill-gorge, 2026-11-12).
#
# Sources the src/ libs directly — no root, no adduser, no network. Sudoers
# files go to a FIXTURE dir through the documented SUDOERS_D seam; visudo is
# stubbed for the write path (the real one is run once on the render itself).
#
# Run: bash tests/sandboxed_chat_sudoers_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/sandboxed-chat-sudoers-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent.sh"
set +e

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }

export SUDOERS_D="$TMP/sudoers.d"; mkdir -p "$SUDOERS_D"
U=agent-grok
F="$SUDOERS_D/$U"

echo "== render =="
r=$(render_sandboxed_chat_sudoers "$U" dashboard)
grants=$(grep -v '^#' <<<"$r" | grep -c .)
is "render (dashboard): exactly three grant lines" "$grants" "3"
is "render: team rail is exact path, no args" \
  "$(grep -c "^${U} ALL=(root) NOPASSWD: /usr/local/bin/5dive _team_self\$" <<<"$r")" "1"
is "render: relay line is exact path, no args" \
  "$(grep -c "^${U} ALL=(root) NOPASSWD: /usr/local/bin/5dive _dashboard_relay\$" <<<"$r")" "1"
is "render: e2e line is exact path, no args" \
  "$(grep -c "^${U} ALL=(root) NOPASSWD: /usr/local/bin/5dive _chat_e2e\$" <<<"$r")" "1"
is "render: no wildcard anywhere" "$(grep -v '^#' <<<"$r" | grep -c '\*')" "0"
r0=$(render_sandboxed_chat_sudoers "$U" telegram)
is "render (no dashboard): the team rail alone" "$(grep -v '^#' <<<"$r0")" "${U} ALL=(root) NOPASSWD: /usr/local/bin/5dive _team_self"
if command -v visudo >/dev/null 2>&1; then
  printf '%s\n' "$r" >"$TMP/render"; chmod 440 "$TMP/render"
  if visudo -cf "$TMP/render" >/dev/null 2>&1; then ok "render: real visudo -c accepts it"
  else bad "render: real visudo -c accepts it" "rc 0" "$(visudo -cf "$TMP/render" 2>&1 | head -2)"; fi
fi

echo "== classify (bash) =="
is "chat-only drop-in classifies chat-only|root|0" "$(classify_sudo_grant <<<"$r")" "chat-only|root|0"
is "chat-only implies sandboxed (no DISAGREE vs the label)" "$(isolation_implied_by_grant chat-only)" "sandboxed"
is "chat-only reads plainly" "$(sudo_grant_english chat-only)" "its own tasks, team messages and web chat only"
is "team rail alone classifies chat-only (implies sandboxed)" "$(classify_sudo_grant <<<"$r0")" "chat-only|root|0"
is "standard template still classifies cli-scoped" \
  "$(render_standard_sudoers agent-x 0 0 | classify_sudo_grant)" "cli-scoped|root|0"
is "an earlier scoped verb alone is still cli-scoped, not chat-only" \
  "$(printf 'agent-n ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _deliver *\nagent-n ALL=(root) NOPASSWD: /usr/local/bin/5dive _audit_append\n' | classify_sudo_grant)" "cli-scoped|root|0"
is "chat rail + a foreign line is chat-only with extra=1" \
  "$(printf '%s\n%s ALL=(root) NOPASSWD: /bin/ls\n' "$r" "$U" | classify_sudo_grant)" "chat-only|root|1"

echo "== sync =="
visudo() { return 0; }   # write path: the fixture is not root-owned
chown() { :; }
is "dashboard on, no file: written" "$(sync_sandboxed_chat_sudoers "$U" dashboard)" "written"
is "file equals the render" "$(cat "$F")" "$r"
is "file mode 440" "$(stat -c %a "$F")" "440"
is "again: current (idempotent)" "$(sync_sandboxed_chat_sudoers "$U" telegram,dashboard)" "current"
is "dashboard off: rewritten to the team rail alone" "$(sync_sandboxed_chat_sudoers "$U" telegram)" "written"
is "file is the team-only render" "$(cat "$F")" "$r0"
is "off again: current" "$(sync_sandboxed_chat_sudoers "$U" none)" "current"
rm -f "$F"; printf '%s\n' "# Managed by 5dive (DIVE-8284). Web chat only, for sandboxed agent ${U}." >"$F"
is "a pre-9004 managed file is upgraded" "$(sync_sandboxed_chat_sudoers "$U" none)" "written"
is "upgraded file carries the team rail" "$(cat "$F")" "$r0"
rm -f "$F"; printf '%s ALL=(root) NOPASSWD: /bin/true\n' "$U" >"$F"
is "hand-placed policy: kept" "$(sync_sandboxed_chat_sudoers "$U" none)" "kept"
is "hand-placed policy untouched" "$(cat "$F")" "$U ALL=(root) NOPASSWD: /bin/true"
rm -f "$F"
visudo() { return 1; }
out=$( (sync_sandboxed_chat_sudoers "$U" dashboard) 2>&1 ); rc=$?
is "visudo refusal fails loudly" "$([[ $rc -ne 0 ]] && echo fail || echo ok)" "fail"
is "visudo refusal leaves no file" "$([[ -e "$F" ]] && echo present || echo gone)" "gone"
visudo() { return 0; }

echo "== reconcile (the update path that fixes an existing seat) =="
REG='{"agents":{"grok":{"isolation":"sandboxed","channels":"dashboard"},"quiet":{"isolation":"sandboxed","channels":"telegram"},"std":{"isolation":"standard","channels":"dashboard"}}}'
registry_read() { printf '%s\n' "$REG"; }
require_root() { :; }
printf '%s\n' "# Managed by 5dive (DIVE-8284). Web chat only, for sandboxed agent agent-quiet." "agent-quiet ALL=(root) NOPASSWD: /usr/local/bin/5dive _dashboard_relay" >"$SUDOERS_D/agent-quiet"
out=$(cmd_agent_reconcile_sudoers 2>&1)
is "sandboxed+dashboard seat got its drop-in" "$(cat "$SUDOERS_D/agent-grok" 2>/dev/null)" "$(render_sandboxed_chat_sudoers agent-grok dashboard)"
is "sandboxed seat without dashboard: stale chat rail replaced by the team rail" \
  "$(cat "$SUDOERS_D/agent-quiet" 2>/dev/null)" "$(render_sandboxed_chat_sudoers agent-quiet telegram)"
is "standard seat is not given the chat-only file" \
  "$([[ -e "$SUDOERS_D/agent-std" ]] && echo present || echo gone)" "gone"
is "reconcile counts two sandboxed changes" "$(grep -o 'sandboxed chat grants changed=[0-9]*' <<<"$out")" "sandboxed chat grants changed=2"

echo "== unit drop-in: the seat's own group (DIVE-9004) =="
export SYSTEMD_UNIT_DIR="$TMP/units"
id() { case "$*" in "-gn agent-sandy") echo agent-sandy ;; "-gn agent-bad") echo claude ;; *) command id "$@" ;; esac; }
DI="$SYSTEMD_UNIT_DIR/5dive-agent@sandy.service.d/isolation.conf"
is "drop-in: written" "$(sync_sandboxed_isolation_dropin sandy)" "written"
is "drop-in: sets the seat's own group" "$(grep -c '^Group=agent-sandy$' "$DI")" "1"
is "drop-in: keeps the resource limits" "$(grep -cE '^(MemoryMax=512M|CPUQuota=50%)$' "$DI")" "2"
is "drop-in: again is current" "$(sync_sandboxed_isolation_dropin sandy)" "current"
printf '[Service]\nMemoryMax=512M\nCPUQuota=50%%\n' >"$DI"
is "drop-in: a pre-9004 file (no Group=) is rewritten" "$(sync_sandboxed_isolation_dropin sandy)" "written"
out=$( (sync_sandboxed_isolation_dropin bad) 2>&1 ); rc=$?
is "drop-in: a seat whose primary group is claude is refused, never written" "$([[ $rc -ne 0 && ! -e "$SYSTEMD_UNIT_DIR/5dive-agent@bad.service.d/isolation.conf" ]] && echo refused || echo written)" "refused"
is "create writes the drop-in through the one helper" "$(grep -c 'sync_sandboxed_isolation_dropin "$name" >/dev/null' "$SRC/cmd_agent_create.sh")" "1"
is "reconcile regroups existing sandboxed units" "$(grep -c 'sync_sandboxed_isolation_dropin "$name") 2>/dev/null' "$SRC/cmd_agent_create.sh")" "1"
unset -f id

echo "== wiring =="
is "agent config syncs on a channels change for a sandboxed seat" \
  "$(grep -c 'sync_sandboxed_chat_sudoers "agent-${name}" "$channels_changed_to"' "$SRC/cmd_agent_config.sh")" "1"
is "agent create syncs a sandboxed seat with its channels" \
  "$(grep -c 'sync_sandboxed_chat_sudoers "agent-${name}" "$channels"' "$SRC/cmd_agent_create.sh")" "1"
is "routed-answer capability treats chat-only as no" \
  "$(grep -c "cli-scoped|chat-only|none) printf 'no|" "$SRC/task/need.sh")" "1"

echo "== classify (python, the production agent list) =="
mkdir -p "$TMP/home/agent-grok" "$TMP/auth" "$TMP/conn" "$TMP/env"
printf '%s\n' '{"version":2,"agents":{"grok":{"type":"grok","isolation":"sandboxed","channels":"dashboard"}}}' >"$TMP/reg.json"
rm -f "$SUDOERS_D/agent-grok"; render_sandboxed_chat_sudoers agent-grok dashboard >"$SUDOERS_D/agent-grok"
py=$(REGISTRY="$TMP/reg.json" AUTH_PROFILES_DIR="$TMP/auth" CONNECTORS_DIR="$TMP/conn" \
     AGENT_HOME_ROOT="$TMP/home" ENV_DIR="$TMP/env" DEFAULT_WORKDIR="$TMP" \
     QUOTA_SNAPSHOT_FILE="$TMP/none.json" QUOTA_WALL_PCT=100 QUOTA_SNAPSHOT_MAX_AGE=1 \
     _agent_list_snapshot_python 2>"$TMP/py.err")
g=$(jq -r '[.. | objects | select(has("grant"))][0] | "\(.grant)|\(.impliedIsolation)"' <<<"$py" 2>/dev/null)
is "python: chat-only drop-in -> chat-only|sandboxed" "$g" "chat-only|sandboxed"

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
