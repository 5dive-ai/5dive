#!/usr/bin/env bash
# DIVE-4034 — codex seats use a different transcript root and cumulative schema.
# The collector must select that path from registry type, keep only the last
# valid cumulative record per rollout, and split cached input from headline burn.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/usage-codex.XXXXXX)"
SRC_DIR="${USAGE_SRC_DIR:-src}"
awk "/python3 - <<'PY'/{f=1;next} f&&/^PY$/{exit} f" "$SRC_DIR/cmd_usage.sh" > "$TMP/collect.py"
[[ -s "$TMP/collect.py" ]] || { echo "FAIL - could not extract usage_collect python"; exit 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

NOW="$(date +%s)"
TS="$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)"
TS_FIRST="$(date -u -d "@$((NOW-1))" +%Y-%m-%dT%H:%M:%SZ)"
TS_OLDER="$(date -u -d "@$((NOW-2))" +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(date -u -d "@$((NOW-7200))" +%Y-%m-%dT%H:%M:%SZ)"
ROOT="$TMP/homes"
mkdir -p "$ROOT/agent-alpha/.claude/projects/proj" \
         "$ROOT/agent-beta/.codex/sessions/2026/09/07" \
         "$ROOT/agent-gamma/.codex/sessions/2026/09/07"
printf '%s\n' '{"agents":{"alpha":{"type":"claude"},"beta":{"type":"codex"},"gamma":{"type":"opencode"}}}' > "$TMP/reg.json"
printf '%s\n' \
  "{\"type\":\"assistant\",\"timestamp\":\"$TS\",\"message\":{\"model\":\"claude-test\",\"usage\":{\"input_tokens\":60,\"output_tokens\":40}}}" \
  > "$ROOT/agent-alpha/.claude/projects/proj/session.jsonl"

# First snapshot is deliberately huge: a summing/first-record implementation
# turns this fixture red. The final snapshot is the session total that counts.
printf '%s\n' \
  "{\"type\":\"event_msg\",\"timestamp\":\"$TS_OLDER\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":900000,\"cached_input_tokens\":800000,\"cache_write_input_tokens\":0,\"output_tokens\":90000}}}}" \
  "{\"type\":\"event_msg\",\"timestamp\":\"$TS_FIRST\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":400,\"cached_input_tokens\":250,\"cache_write_input_tokens\":20,\"output_tokens\":40}},\"rate_limits\":{\"primary\":{\"used_percent\":17},\"secondary\":{\"used_percent\":23}}}}" \
  > "$ROOT/agent-beta/.codex/sessions/2026/09/07/rollout-one.jsonl"
printf '%s\n' \
  "{\"type\":\"event_msg\",\"timestamp\":\"$TS\",\"payload\":{\"type\":\"token_count\",\"info\":null}}" \
  "{\"type\":\"event_msg\",\"timestamp\":\"$TS\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":50,\"cache_write_input_tokens\":5,\"output_tokens\":20}},\"rate_limits\":{\"primary\":{\"used_percent\":19},\"secondary\":{\"used_percent\":29}}}}" \
  > "$ROOT/agent-beta/.codex/sessions/2026/09/07/rollout-two.jsonl"
printf '%s\n' \
  "{\"type\":\"event_msg\",\"timestamp\":\"$OLD\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":77777,\"cached_input_tokens\":0,\"output_tokens\":1}}}}" \
  > "$ROOT/agent-beta/.codex/sessions/2026/09/07/rollout-old.jsonl"
# A non-codex registry type with a codex-shaped tree must never be guessed in.
cp "$ROOT/agent-beta/.codex/sessions/2026/09/07/rollout-two.jsonl" \
   "$ROOT/agent-gamma/.codex/sessions/2026/09/07/rollout-two.jsonl"

collect_with() {
  REGISTRY="$TMP/reg.json" TASK_DB="$TMP/none.db" USAGE_SINCE="$((NOW-3600))" \
    USAGE_HOME_ROOT="$ROOT" python3 "$1" 2>"$TMP/collect.err"
}
OUT="$(collect_with "$TMP/collect.py")"
ROW="$(jq -c '.agents[] | select(.name=="beta")' <<<"$OUT")"

[[ -n "$ROW" ]] && ok_t "registered codex seat appears in the shared agents array" \
  || bad_t "codex seat missing" "$OUT"
[[ "$(jq -r '.models.codex | [.in,.out,.cc,.cr] | @csv' <<<"$ROW")" == '175,60,25,300' ]] \
  && ok_t "last record per rollout is split into uncached-in/out/cache-write/cache-read" \
  || bad_t "codex class mapping or cumulative fold" "$ROW"
[[ "$(jq -r '.total' <<<"$ROW")" == "260" && "$(jq -r '.cacheRead' <<<"$ROW")" == "300" ]] \
  && ok_t "headline excludes cached input while cache-read stays visible" \
  || bad_t "headline/cache-read semantics" "$ROW"
[[ "$(jq -r '.fiveHourPct' <<<"$ROW")" == "19" && "$(jq -r '.sevenDayPct' <<<"$ROW")" == "29" ]] \
  && ok_t "freshest included Codex snapshot supplies the existing 5h/7d columns" \
  || bad_t "rate-limit mapping" "$ROW"
[[ "$(jq -r '.coverage.agentsExpected' <<<"$OUT")" == "2" && "$(jq -r '.coverage.complete' <<<"$OUT")" == "true" ]] \
  && ok_t "coverage follows registry types (claude+codex), not guessed directories" \
  || bad_t "registry-keyed coverage" "$(jq -c .coverage <<<"$OUT")"
[[ "$(jq -r '[.agents[].name] | index("gamma")' <<<"$OUT")" == "null" ]] \
  && ok_t "codex-shaped files do not enroll a non-codex registry seat" \
  || bad_t "directory guessing admitted gamma" "$OUT"

# Mutation control: make the extracted collector keep the FIRST cumulative
# snapshot. This must make the exact-value assertion above fail.
cp "$TMP/collect.py" "$TMP/mut.py"
python3 - "$TMP/mut.py" <<'PYMUT'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "last_usage = usage\n                    last_ts = ts"
replacement = "last_usage = last_usage if last_usage is not None else usage\n                    last_ts = last_ts if last_ts is not None else ts"
assert s.count(anchor) == 1, "mutation anchor drifted"
open(p, "w").write(s.replace(anchor, replacement))
PYMUT
MUT="$(collect_with "$TMP/mut.py")"
if [[ "$(jq -r '.agents[] | select(.name=="beta") | .total' <<<"$MUT")" != "260" ]]; then
  ok_t "mutation control: choosing the first cumulative snapshot turns the gate red"
else
  bad_t "mutation control stayed green" "$(jq -c '.agents[] | select(.name=="beta")' <<<"$MUT")"
fi

# Any-uid unreadability arm at the Codex transcript root (ENOTDIR).
mv "$ROOT/agent-beta/.codex/sessions" "$ROOT/agent-beta/.codex/sessions-ok"
printf 'not-a-directory' > "$ROOT/agent-beta/.codex/sessions"
BLIND="$(collect_with "$TMP/collect.py")"
[[ "$(jq -r '.coverage.complete' <<<"$BLIND")" == "false" \
   && "$(jq -r '.coverage.unreadable[] | select(.name=="beta") | .name' <<<"$BLIND")" == "beta" ]] \
  && ok_t "unreadable Codex transcript root is unknown burn, not zero" \
  || bad_t "Codex unreadability disappeared" "$(jq -c .coverage <<<"$BLIND")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
