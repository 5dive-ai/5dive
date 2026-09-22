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

# DIVE-4815 — a rollout that SPANS the window boundary. Its own scenario tree and
# registry, so the arms above keep their exact totals. The window is [NOW-3600, NOW]
# and the dispatcher shape is a file opened long before it and still being written
# inside it: only the spend BETWEEN the two snapshots belongs to the window.
ROOT2="$TMP/homes2"
mkdir -p "$ROOT2/agent-delta/.codex/sessions/2026/09/08" \
         "$ROOT2/agent-epsilon/.codex/sessions/2026/09/08"
printf '%s\n' '{"agents":{"delta":{"type":"codex"},"epsilon":{"type":"codex"}}}' > "$TMP/reg2.json"
PRE="$(date -u -d "@$((NOW-7200))" +%Y-%m-%dT%H:%M:%SZ)"
MID="$(date -u -d "@$((NOW-1800))" +%Y-%m-%dT%H:%M:%SZ)"
LATE="$(date -u -d "@$((NOW-60))" +%Y-%m-%dT%H:%M:%SZ)"
snap() { # ts in cached cw out
  printf '{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"cache_write_input_tokens":%s,"output_tokens":%s}},"rate_limits":{"primary":{"used_percent":11},"secondary":{"used_percent":13}}}}\n' "$@"
}
{ snap "$PRE"  1000000  900000 50000 20000
  snap "$MID"  1200000 1080000 60000 25000
  snap "$LATE" 1300000 1160000 65000 30000
} > "$ROOT2/agent-delta/.codex/sessions/2026/09/08/rollout-spanning.jsonl"
# A cumulative counter that RESTARTS mid-window: no subtraction spans a restart,
# so the post-restart snapshot is the whole of the window's spend.
{ snap "$PRE"  5000000 4000000 10000 90000
  snap "$LATE"     400     250    20    40
} > "$ROOT2/agent-epsilon/.codex/sessions/2026/09/08/rollout-restarted.jsonl"

collect2_with() { # $1=collector $2=since
  REGISTRY="$TMP/reg2.json" TASK_DB="$TMP/none.db" USAGE_SINCE="$2" \
    USAGE_HOME_ROOT="$ROOT2" python3 "$1" 2>"$TMP/collect2.err"
}
OUT24="$(collect2_with "$TMP/collect.py" "$((NOW-3600))")"
ROWD="$(jq -c '.agents[] | select(.name=="delta")' <<<"$OUT24")"
[[ "$(jq -r '.models.codex | [.in,.out,.cc,.cr] | @csv' <<<"$ROWD")" == '25000,10000,15000,260000' ]] \
  && ok_t "a spanning rollout contributes the in-window DELTA, not its lifetime" \
  || bad_t "spanning rollout windowing" "$ROWD"
[[ "$(jq -r '.total' <<<"$ROWD")" == "50000" && "$(jq -r '.cacheRead' <<<"$ROWD")" == "260000" ]] \
  && ok_t "headline and cache-read are both windowed" \
  || bad_t "spanning headline/cache-read" "$ROWD"
[[ "$(jq -r '.models.codex.turns' <<<"$ROWD")" == "2" ]] \
  && ok_t "turns count only the snapshots inside the window" \
  || bad_t "turn count still spans the boundary" "$ROWD"
ROWE="$(jq -c '.agents[] | select(.name=="epsilon")' <<<"$OUT24")"
[[ "$(jq -r '.models.codex | [.in,.out,.cc,.cr] | @csv' <<<"$ROWE")" == '130,40,20,250' ]] \
  && ok_t "a restarted cumulative counter reports the post-restart total, never a negative or a zero" \
  || bad_t "counter-restart handling" "$ROWE"

# The field tell (DIVE-4815): the same seat read 661.8M in BOTH the 24h and the 7d
# window, because one un-rotated file answered both. Two windows over one fixture
# must now disagree, and the wider one must be the larger.
OUT7D="$(collect2_with "$TMP/collect.py" "$((NOW-604800))")"
T24="$(jq -r '.agents[] | select(.name=="delta") | .total' <<<"$OUT24")"
T7D="$(jq -r '.agents[] | select(.name=="delta") | .total' <<<"$OUT7D")"
[[ "$T7D" == "170000" && "$T24" == "50000" ]] \
  && ok_t "widening the window raises the spanning rollout's contribution instead of repeating it" \
  || bad_t "24h and 7d still answer the same number" "24h=$T24 7d=$T7D"

# Mutation control for the windowing itself: drop the pre-window baseline (the
# pre-fix behaviour exactly) and the spanning arm must go red at the lifetime total.
cp "$TMP/collect.py" "$TMP/mut2.py"
( python3 - "$TMP/mut2.py" <<'PYMUT2'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "                        pre_usage = usage\n"
replacement = "                        pre_usage = None\n"
assert s.count(anchor) == 1, "windowing mutation anchor drifted"
open(p, "w").write(s.replace(anchor, replacement))
PYMUT2
) || { bad_t "windowing mutation could not be applied" "anchor drifted — the arms above are ungraded"; }
MUT2="$(collect2_with "$TMP/mut2.py" "$((NOW-3600))")"
if [[ "$(jq -r '.agents[] | select(.name=="delta") | .total' <<<"$MUT2")" == "170000" ]]; then
  ok_t "mutation control: dropping the pre-window baseline restores the lifetime total"
else
  bad_t "windowing mutation control did not reproduce the defect" \
        "$(jq -c '.agents[] | select(.name=="delta")' <<<"$MUT2")"
fi

# Mutation control for the restart branch: stop detecting the restart and the
# per-field clamp silently reports ZERO for a seat that spent the whole window.
cp "$TMP/collect.py" "$TMP/mut3.py"
( python3 - "$TMP/mut3.py" <<'PYMUT3'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "        if cur_total < pre_total:\n"
replacement = "        if False:\n"
assert s.count(anchor) == 1, "restart mutation anchor drifted"
open(p, "w").write(s.replace(anchor, replacement))
PYMUT3
) || { bad_t "restart mutation could not be applied" "anchor drifted — the restart arm is ungraded"; }
MUT3="$(collect2_with "$TMP/mut3.py" "$((NOW-3600))")"
if [[ "$(jq -r '.agents[] | select(.name=="epsilon") | .total' <<<"$MUT3")" == "0" ]]; then
  ok_t "mutation control: an undetected counter restart clamps the seat to zero"
else
  bad_t "restart mutation control did not reproduce the clamp" \
        "$(jq -c '.agents[] | select(.name=="epsilon")' <<<"$MUT3")"
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
