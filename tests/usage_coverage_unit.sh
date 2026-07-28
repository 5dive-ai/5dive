#!/usr/bin/env bash
# DIVE-1929 unit: usage_collect must report what it COVERED, and must never let
# an unreadable agent pass as an idle one.
#
# The bug this guards: every read failure hit a bare `continue`, the agent fell
# out of the result, and the token sum came out confident and low — root saw
# 1,938,127,926 tokens for a window where agent-olivia saw 91,462,388 (4.7%),
# both rendered as complete. Nothing in the output said which one you were
# looking at.
#
# NEGATIVE CONTROL, and the reason it is built this way: a test that only runs
# as one uid cannot see this bug at all. As root every home is readable and the
# partial case never fires; as a normal user a chmod-000 case fires but proves
# nothing about root. So the primary case makes a transcript dir unreadable in a
# way that defeats EVERY uid (a regular file where a directory belongs -> ENOTDIR
# for root too), and the EACCES path — the one that actually bites in production
# — is exercised additionally whenever the suite is NOT root.
#
#   bash tests/usage_coverage_unit.sh
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
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/usage-coverage.XXXXXX)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Drive the collector's python directly, same seam the scorecard unit uses.
awk "/python3 - <<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" src/cmd_usage.sh > "$TMP/collect.py"
[[ -s "$TMP/collect.py" ]] || { echo "FAIL - could not extract usage_collect python"; exit 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

NOW="$(date +%s)"
TS="$(date -u -d @"$NOW" +%Y-%m-%dT%H:%M:%SZ)"

# one agent home with a real transcript line worth 100 total tokens
mk_agent() {
  local root="$1" name="$2" d="$1/agent-$2/.claude/projects/proj"
  mkdir -p "$d"
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$TS\",\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":60,\"output_tokens\":40}}}" \
    > "$d/session.jsonl"
}

mk_registry() {
  printf '{"agents":{"alpha":{"type":"claude"},"beta":{"type":"claude"},"gamma":{"type":"claude"}}}' > "$1"
}

collect() {  # collect <home_root> <registry>
  REGISTRY="$2" TASK_DB="$TMP/none.db" USAGE_SINCE="$((NOW - 3600))" \
  USAGE_HOME_ROOT="$1" python3 "$TMP/collect.py" 2>/dev/null
}

# --- Case 1: a COMPLETE read declares itself complete. -----------------------
R1="$TMP/r1"; mkdir -p "$R1"; mk_registry "$TMP/reg.json"
for a in alpha beta gamma; do mk_agent "$R1" "$a"; done
OUT1="$(collect "$R1" "$TMP/reg.json")"
[[ "$(jq -r '.coverage.complete' <<<"$OUT1")" == "true" ]] \
  && ok_t "all transcript sets readable -> coverage.complete=true" || bad_t "complete" "$OUT1"
[[ "$(jq -r '.coverage.agentsRead' <<<"$OUT1")" == "3" && "$(jq -r '.coverage.agentsExpected' <<<"$OUT1")" == "3" ]] \
  && ok_t "coverage counts sets READ against sets that EXIST (3 of 3)" \
  || bad_t "counts" "$(jq -c .coverage <<<"$OUT1")"
[[ "$(jq -r '[.agents[].total]|add' <<<"$OUT1")" == "300" ]] \
  && ok_t "token total is unchanged by the coverage work (3 x 100)" || bad_t "total" "$OUT1"

# --- Case 2: THE CORE ASSERTION. The collector sees a SUBSET. ----------------
#     gamma's transcript dir is a regular file: ENOTDIR defeats root as well.
R2="$TMP/r2"; mkdir -p "$R2"
mk_agent "$R2" alpha; mk_agent "$R2" beta
mkdir -p "$R2/agent-gamma/.claude"; printf 'not-a-dir' > "$R2/agent-gamma/.claude/projects"
OUT2="$(collect "$R2" "$TMP/reg.json")"
[[ "$(jq -r '.coverage.complete' <<<"$OUT2")" == "false" ]] \
  && ok_t "a subset read is reported as INCOMPLETE (any uid, incl. root)" \
  || bad_t "subset not flagged" "$(jq -c .coverage <<<"$OUT2")"
[[ "$(jq -r '.coverage.agentsRead' <<<"$OUT2")" == "2" ]] \
  && ok_t "coverage.agentsRead drops to 2 of 3 when one set is unreadable" \
  || bad_t "agentsRead" "$(jq -c .coverage <<<"$OUT2")"
[[ "$(jq -r '.coverage.unreadable[0].name' <<<"$OUT2")" == "gamma" ]] \
  && ok_t "the unreadable agent is NAMED, not silently dropped" \
  || bad_t "unreadable name" "$(jq -c .coverage <<<"$OUT2")"
[[ -n "$(jq -r '.coverage.unreadable[0].reason // ""' <<<"$OUT2")" ]] \
  && ok_t "every unreadable set carries a REASON" || bad_t "reason" "$(jq -c .coverage <<<"$OUT2")"
# and the thing that made the bug invisible: the sum still looks fine on its own.
[[ "$(jq -r '[.agents[].total]|add' <<<"$OUT2")" == "200" ]] \
  && ok_t "the partial sum is still emitted (200) — coverage is what makes it honest" \
  || bad_t "partial sum" "$OUT2"

# --- Case 3: a genuinely IDLE agent is not slandered as unreadable. ----------
#     Absence (ENOENT) is the ONE failure that really does mean "nothing here".
R3="$TMP/r3"; mkdir -p "$R3"
mk_agent "$R3" alpha; mk_agent "$R3" beta
mkdir -p "$R3/agent-gamma"          # home exists, never ran, no .claude at all
OUT3="$(collect "$R3" "$TMP/reg.json")"
[[ "$(jq -r '.coverage.complete' <<<"$OUT3")" == "true" ]] \
  && ok_t "an agent with no transcripts counts as READ, not as blind spot" \
  || bad_t "idle agent misreported" "$(jq -c .coverage <<<"$OUT3")"

# --- Case 4: the PRODUCTION failure mode (EACCES on a 700 home). -------------
#     Only meaningful unprivileged — root reads it regardless. Stated, not faked.
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip - EACCES case not runnable as root (Case 2 covers root via ENOTDIR)\n'
else
  R4="$TMP/r4"; mkdir -p "$R4"
  mk_agent "$R4" alpha; mk_agent "$R4" beta; mk_agent "$R4" gamma
  chmod 000 "$R4/agent-gamma"
  OUT4="$(collect "$R4" "$TMP/reg.json")"
  [[ "$(jq -r '.coverage.complete' <<<"$OUT4")" == "false" \
     && "$(jq -r '.coverage.unreadable[0].name' <<<"$OUT4")" == "gamma" ]] \
    && ok_t "an unreadable home (EACCES, the real 21x case) is reported, not skipped" \
    || bad_t "EACCES not detected" "$(jq -c .coverage <<<"$OUT4")"
  jq -e '.coverage.unreadable[0].reason|test("root")' <<<"$OUT4" >/dev/null \
    && ok_t "the EACCES reason tells the reader what would fix it (root)" \
    || bad_t "EACCES reason" "$(jq -c .coverage <<<"$OUT4")"
  chmod 755 "$R4/agent-gamma"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
