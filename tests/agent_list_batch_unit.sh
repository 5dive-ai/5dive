#!/usr/bin/env bash
# DIVE-4100 — the fleet survey is one batch, not one privilege/process fan-out
# per seat. This grades the embedded shaper without reading the live fleet.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/agent-list-batch-unit.XXXXXX)"
trap 'rc=$?; chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
pass=0
fail=0

ok() { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
check() { if "$@"; then ok "$1"; else bad "$1"; fi; }

PY="$TMP/snapshot.py"
awk '
  /^# __5DIVE_AGENT_LIST_PY_BEGIN__$/ { emit=1; next }
  /^# __5DIVE_AGENT_LIST_PY_END__$/   { exit }
  emit { print }
' "$ROOT/src/cmd_agent.sh" >"$PY"

[[ -s "$PY" ]] && ok 'embedded snapshot shaper is extractable' || bad 'embedded snapshot shaper is missing'
[[ "$(grep -c '^# __5DIVE_AGENT_LIST_PY_BEGIN__$' "$ROOT/src/cmd_agent.sh")" == 1 &&
   "$(grep -c '^# __5DIVE_AGENT_LIST_PY_END__$' "$ROOT/src/cmd_agent.sh")" == 1 ]] \
  && ok 'shaper has exactly one bounded extraction region' || bad 'shaper extraction markers are ambiguous'

mkdir -p "$TMP/home/agent-alpha" "$TMP/profiles" "$TMP/connectors" "$TMP/sudoers"
printf '%s\n' '{"agents":{"alpha":{"type":"opencode","channels":"none","workdir":"/work","isolation":"sandboxed","heartbeat":{"enabled":false},"createdAt":"2026-09-09T00:00:00Z"}}}' >"$TMP/agents.json"

OUT=$(python3 "$PY" "$TMP/agents.json" "$TMP/profiles" "$TMP/connectors" \
  "$TMP/home" "$TMP/sudoers" /default 2>"$TMP/stderr")
[[ "$(jq 'length' <<<"$OUT")" == 1 ]] && ok 'one registry row produces one snapshot row' || bad 'snapshot changed row cardinality'
[[ "$(jq -r '.[0].name' <<<"$OUT")" == alpha ]] && ok 'snapshot preserves the agent identity' || bad 'snapshot lost the agent identity'
[[ "$(jq -r '.[0].health.auth.state' <<<"$OUT")" == ok ]] && ok 'auth-optional agents remain healthy' || bad 'auth-optional agent was degraded'
[[ "$(jq -r '.[0].sudo.grant' <<<"$OUT")" == none &&
   "$(jq -r '.[0].sudo.measured' <<<"$OUT")" == true ]] \
  && ok 'readable empty sudoers is measured none, not unknown' || bad 'sudo measurement collapsed none into unknown'
[[ "$(jq -r '.[0].health.startup.state' <<<"$OUT")" == clear ]] \
  && ok 'readable absent startup breadcrumb is clear' || bad 'startup health changed'
[[ ! -s "$TMP/stderr" ]] && ok 'batch shaper is quiet on a valid fixture' || bad 'batch shaper wrote unexpected stderr'

grep -q '^bundle=/usr/local/bin/5dive$' "$ROOT/5dive-agent-list-snapshot" \
  && ! grep -q '\$@\|\${[1-9]' "$ROOT/5dive-agent-list-snapshot" \
  && ok 'privileged helper uses fixed paths and no caller arguments' || bad 'privileged helper accepts caller-controlled paths'
grep -q "printf '%%claude ALL=(root) NOPASSWD: %s/agent-list-snapshot" "$ROOT/install.sh" \
  && ok 'installer backfills one exact fleet-reader grant' || bad 'installer does not backfill the fleet-reader grant'

echo "agent_list_batch_unit: $pass passed, $fail failed"
(( fail == 0 ))
