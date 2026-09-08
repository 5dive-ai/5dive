#!/usr/bin/env bash
# DIVE-4037 unit: `usage` must report PLAN CONSUMPTION, not only API-equivalent
# cost, and the two must never be confusable for each other.
#
# The bug this guards: usage_collect's headline `total` is
# input+output+cache-write and DELIBERATELY excludes cache-read. On real agentic
# traffic cache-read is ~98% of every token moved, so `total` was ~2% of what a
# flat-rate subscription actually meters — measured 2026-09-07 on this fleet,
# `main` showed 9.8M against ~400M moved. Every capacity reader (the board, the
# `cost` view, the budget alert path) read that number, so a seat could wall
# with no warning while `usage` looked comfortable.
#
# WHY THIS SHAPE:
#   * BOTH LAYERS. The collector is driven directly (its python is extracted at
#     the same seam tests/usage_coverage_unit.sh uses) AND the real presenters
#     are sourced and driven with stubbed sources. A number that is collected
#     and not rendered is a fix that has not shipped (DIVE-1937); a column that
#     is rendered from a number the collector never computed is worse.
#   * ANY UID. Nothing here depends on what the caller may read: the fixtures
#     are synthetic, so root and a narrowed seat run identical assertions.
#   * THE NEGATIVE HALF IS ASSERTED. It is not enough that QUOTA appears; the
#     old bare `TOTAL` header must be GONE (a header that keeps its name while a
#     sibling appears beside it still reads as "the total"), and `total` must
#     still EXCLUDE cache-read — a fix that quietly redefines the existing
#     number is the failure mode the row explicitly forbids.
#   * THE 40x TRIP IS ASSERTED. Re-basing existing budgets from cost to quota
#     multiplies measured burn ~40x against unchanged thresholds and would trip
#     every ceiling at once — on an agent with hardStop on, that is a stop fired
#     by a presentation change. A basis-absent budget MUST stay on cost.
#
# NEGATIVE CONTROL (how to re-run it):
#   mkdir -p /tmp/pre4037 && git show origin/main:src/cmd_usage.sh > /tmp/pre4037/cmd_usage.sh
#   USAGE_SRC_DIR=/tmp/pre4037 bash tests/usage_quota_basis_unit.sh   # must FAIL
#
#   Re-measured after merging origin/main past DIVE-4034 (#784), with PART C
#   added: 7 passed / 29 failed against origin/main (was 6/20 pre-merge). The 7
#   are the must-not-regress half — `total` still excludes cache-read,
#   cache-read still visible in the agent view, `cost` exits 0, no silent 40x
#   trip on a basis-absent budget, the board still sorts a quota-less payload,
#   an absent quota still falls back to the cost floor, and the all-claude
#   window still makes no codex weight claim. Everything the row ADDS fails, as
#   it must. `--basis=bogus` is NOT among the 7: pre-row `budget set` rejects
#   the unknown flag with a different message, so that arm fails on the control
#   rather than passing vacuously.
#
#   bash tests/usage_quota_basis_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

SRC_DIR="${USAGE_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/usage-quota.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { grep -qF -- "$2" <<<"$1"; }

# ============================================================================
# PART A — the COLLECTOR. Same seam as usage_coverage_unit.sh: extract the
# heredoc'd python and drive it with env-var fixtures.
# ============================================================================
awk "/python3 - <<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" "$SRC_DIR/cmd_usage.sh" > "$TMP/collect.py"
[[ -s "$TMP/collect.py" ]] || { echo "FAIL - could not extract usage_collect python"; exit 1; }

NOW="$(date +%s)"
TS="$(date -u -d @"$NOW" +%Y-%m-%dT%H:%M:%SZ)"

# The shape the row was filed about: a cache-read-dominated turn.
#   in=100 out=50 cache_write=250  -> cost basis  =   400
#   cache_read=39600               -> quota basis = 40000  (100x, i.e. 99% reads)
mk_agent() {
  local root="$1" name="$2" d="$1/agent-$2/.claude/projects/proj"
  mkdir -p "$d"
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$TS\",\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"cache_creation_input_tokens\":250,\"cache_read_input_tokens\":39600}}}" \
    > "$d/session.jsonl"
}

printf '{"agents":{"alpha":{"type":"claude"}}}' > "$TMP/reg.json"
R="$TMP/homes"; mkdir -p "$R"; mk_agent "$R" alpha

# a task open for alpha across the window, so attribution has somewhere to land
DB="$TMP/tasks.db"
sqlite3 "$DB" "CREATE TABLE tasks (ident TEXT, title TEXT, assignee TEXT, started_at TEXT, done_at TEXT, iteration INT, status TEXT);
  INSERT INTO tasks VALUES ('DIVE-9001','a cache-heavy task','alpha','$(date -u -d @$((NOW-600)) +'%Y-%m-%d %H:%M:%S')',NULL,NULL,'in_progress');" 2>/dev/null \
  || { echo "SKIP - sqlite3 unavailable"; exit 0; }

OUT="$(REGISTRY="$TMP/reg.json" TASK_DB="$DB" USAGE_SINCE="$((NOW-3600))" \
       USAGE_HOME_ROOT="$R" python3 "$TMP/collect.py" 2>/dev/null)"
[[ -n "$OUT" ]] || { echo "FAIL - collector produced nothing"; exit 1; }

# A1. the existing number is NOT redefined.
[[ "$(jq -r '.agents[0].total' <<<"$OUT")" == "400" ]] \
  && ok_t "collector: .total still EXCLUDES cache-read (400 = in+out+cache-write)" \
  || bad_t "total was redefined" "$(jq -c '.agents[0]|{total,quota,cacheRead}' <<<"$OUT")"

# A2. the number that runs out exists and includes all four classes.
[[ "$(jq -r '.agents[0].quota' <<<"$OUT")" == "40000" ]] \
  && ok_t "collector: .quota is all FOUR classes (40000 = +cache-read)" \
  || bad_t "quota missing or wrong — the capacity figure is not collected" \
           "$(jq -c '.agents[0]|{total,quota,cacheRead}' <<<"$OUT")"

# A3. quota > total on cache-heavy traffic, i.e. the gap is real and directional.
[[ "$(jq -r '.agents[0] | (.quota > .total)' <<<"$OUT")" == "true" ]] \
  && ok_t "collector: quota exceeds cost basis on cache-heavy traffic" || bad_t "no gap" "$OUT"

# A4. the payload SAYS what each figure is made of — a consumer must be able to
#     check the composition, not infer it from a comment in the source.
[[ "$(jq -r '.basis.quota.formula' <<<"$OUT")" == *cache_read* \
   && "$(jq -r '.basis.total.formula' <<<"$OUT")" != *cache_read* ]] \
  && ok_t "collector: .basis declares both formulae and only quota names cache_read" \
  || bad_t "basis block absent or wrong" "$(jq -c '.basis' <<<"$OUT")"

# A5. TASK ATTRIBUTION carries both. This is the half a ratio applied after the
#     fact cannot reproduce: per-task quota must be summed per turn.
[[ "$(jq -r '.tasks[0].total' <<<"$OUT")" == "400" \
   && "$(jq -r '.tasks[0].quota' <<<"$OUT")" == "40000" ]] \
  && ok_t "collector: per-TASK rows carry both bases (400 / 40000)" \
  || bad_t "task attribution lost the quota basis" "$(jq -c '.tasks' <<<"$OUT")"

# A6. and so does the untracked bucket (turns outside any task window).
OUT_U="$(REGISTRY="$TMP/reg.json" TASK_DB="$TMP/empty.db" USAGE_SINCE="$((NOW-3600))" \
         USAGE_HOME_ROOT="$R" python3 "$TMP/collect.py" 2>/dev/null)"
[[ "$(jq -r '.untracked.alpha.quota' <<<"$OUT_U")" == "40000" ]] \
  && ok_t "collector: the UNTRACKED bucket carries quota too" \
  || bad_t "untracked lost quota" "$(jq -c '.untracked' <<<"$OUT_U")"

# ============================================================================
# PART B — the PRESENTERS, sourced for real with only the sources stubbed.
# ============================================================================
# shellcheck disable=SC1091
source src/lib/error_codes.sh 2>/dev/null || { E_USAGE=2; E_GENERIC=1; E_PERMISSION=77; E_VALIDATION=3; }
JSON_MODE=0
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
fail() { printf 'error: %s\n' "${2:-}" >&2; exit "${1:-1}"; }
ok()   { printf 'ok: %s\n' "${1:-}"; }
# shellcheck disable=SC1090
source "$SRC_DIR/cmd_usage.sh"
ensure_state()  { :; }
require_root()  { :; }
usage_budget_load() { printf '%s\n' "${BUDGETS:-{\}}"; }
usage_budget_save() { printf "%s\n" "$1" > "$TMP/saved.json"; }   # takes an ARG, like the real one — a `cat` stub blocks on stdin
usage_resolve_owner_channel() { return 0; }
_task_send_owner() { printf '%s\n' "$1" >> "$TMP/alerts.txt"; }
with_registry_lock() { :; }
cmd_heartbeat_off() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TMP/stops.txt"; }
usage_collect() { printf '%s\n' "$DATA"; }
USAGE_BUDGET_STATE_FILE="$TMP/budget-state.json"
USAGE_BUDGETS_FILE="$TMP/budgets.json"

# one cache-heavy agent, one fresh-token-heavy one, SAME account. Ranked by cost
# basis, `fresh` wins; ranked by what the plan meters, `cachey` wins by 20x.
# That inversion is the defect: the board pointed at the wrong seat.
DATA="$(jq -cn '{
  window:{since:0,now:1},
  basis:{total:{formula:"input + output + cache_creation"},
         quota:{formula:"input + output + cache_creation + cache_read"}},
  agents:[
    {name:"cachey",account:"a",models:{m:{in:100,out:50,cc:250,cr:399600,turns:1}},
     total:400,quota:400000,output:50,cacheRead:399600,sevenDayPct:80,fiveHourPct:5},
    {name:"fresh",account:"a",models:{m:{in:9000,out:1000,cc:0,cr:0,turns:1}},
     total:10000,quota:10000,output:1000,cacheRead:0,sevenDayPct:80,fiveHourPct:5}],
  tasks:[{ident:"DIVE-9001",title:"cache heavy",assignee:"cachey",total:400,quota:400000,
           output:50,turns:1,iteration:null,dispatched:true}],
  untracked:{},
  coverage:{agentsExpected:2,agentsRead:2,unreadable:[],complete:true}}')"

# --- B1. the board names both columns, and the bare TOTAL header is gone -----
OUT="$(usage_render_board "$DATA" 24h '{}' 2>&1)"
{ has "$OUT" "QUOTA" && has "$OUT" "API-EQ"; } \
  && ok_t "board: both bases are COLUMNS, each named for what it is" || bad_t "board columns" "$OUT"
! grep -qE '^\s*AGENT\s+MODEL\s+OUTPUT\s+TOTAL\b' <<<"$OUT" \
  && ok_t "board: the unqualified 'TOTAL' header is GONE (not reused beside a sibling)" \
  || bad_t "board still headlines a bare TOTAL" "$OUT"
has "$OUT" "the number that runs out" \
  && ok_t "board: the key ships on the same screen as the table" || bad_t "no basis legend" "$OUT"

# --- B2. ORDER and SHARE follow the plan basis -------------------------------
# The whole point: "TOP" on a capacity board must mean closest to running out.
AG_ORDER="$(sed -n '/TOP AGENTS/,/TOP TASKS/p' <<<"$OUT" | grep -oE '\b(cachey|fresh)\b' | head -2 | tr '\n' ' ')"
[[ "$AG_ORDER" == "cachey fresh " ]] \
  && ok_t "board: TOP AGENTS ranks by QUOTA (cache-heavy seat first), not by cost" \
  || bad_t "board still ranks by the cost basis — it points at the wrong seat" "order=[$AG_ORDER]"
# SHARE apportions the account's vendor 7D% by plan weight: cachey holds
# 400000/410000 = 97.5% of the account's plan burn, so 80% * .975 = 78%.
grep -qE 'cachey.*\b78%' <<<"$OUT" \
  && ok_t "board: SHARE apportions the vendor 7D% on the PLAN basis (78%)" \
  || bad_t "SHARE still computed on cost basis — the percentage lands on the wrong seat" "$OUT"

# --- B3. the per-agent detail gets a quota line, and it keeps the cost one ---
OUT="$(usage_render_agent "$DATA" cachey 24h 2>&1)"
{ has "$OUT" "QUOTA" && has "$OUT" "API-EQ cost"; } \
  && ok_t "agent view: BOTH bases get a named total line" || bad_t "agent view lines" "$OUT"
has "$OUT" "cache-read" \
  && ok_t "agent view: cache-read stays visible beside the totals" || bad_t "cache-read gone" "$OUT"

# --- B4. `cost` shows both, and names which one is being ENFORCED -----------
BUDGETS='{}'; JSON_MODE=0
OUT="$(cmd_cost 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && ok_t "cost: a healthy board exits 0 (DIVE-2751 shape)" || bad_t "cost rc=$RC" "$OUT"
{ has "$OUT" "API-EQ" && has "$OUT" "QUOTA" && has "$OUT" "BASIS"; } \
  && ok_t "cost: both bases plus the BASIS being enforced are on the row" || bad_t "cost columns" "$OUT"

# --- B5. THE 40x TRIP. A basis-absent budget must stay on the cost basis. ----
# 400 cost / 400000 quota against a 1000-token soft cap: on cost it is UNDER,
# on quota it is 400x OVER. A legacy budget re-based silently would fire here —
# and with hardStop on, would stop the agent.
BUDGETS='{"cachey":{"soft":1000,"hard":5000,"hardStop":true,"notified":{},"stopped":false}}'
: > "$TMP/alerts.txt"; : > "$TMP/stops.txt"
OUT="$(cmd_usage_budget_check --dry-run 2>&1)"
[[ "$(jq -r '.agents.cachey.state' "$USAGE_BUDGET_STATE_FILE")" == "ok" ]] \
  && ok_t "budget: a basis-ABSENT budget is enforced on cost — no silent 40x trip" \
  || bad_t "a legacy budget was re-based and now trips (a stop fired by a presentation fix)" \
           "$(jq -c '.agents.cachey' "$USAGE_BUDGET_STATE_FILE")"
[[ "$(jq -r '.agents.cachey.basis' "$USAGE_BUDGET_STATE_FILE")" == "cost" ]] \
  && ok_t "budget: the state cache RECORDS which basis was enforced" \
  || bad_t "state cache does not name its basis" "$(jq -c '.agents.cachey' "$USAGE_BUDGET_STATE_FILE")"
[[ "$(jq -r '.agents.cachey.burnQuota' "$USAGE_BUDGET_STATE_FILE")" == "400000" ]] \
  && ok_t "budget: the state cache carries the figure it is NOT watching" \
  || bad_t "state cache hides the plan figure" "$(jq -c '.agents.cachey' "$USAGE_BUDGET_STATE_FILE")"
# and `cost` must SAY the ceiling cannot fire, rather than leave it to be spotted
OUT="$(cmd_cost 2>&1)"
has "$OUT" "cannot fire before the plan runs out" \
  && ok_t "cost: a cost-basis budget on cache-heavy traffic is called out as unable to fire" \
  || bad_t "the unfireable ceiling is silent" "$OUT"

# --- B6. an explicit quota-basis budget DOES fire on plan burn ---------------
BUDGETS='{"cachey":{"soft":1000,"hard":5000,"hardStop":false,"notified":{},"stopped":false,"basis":"quota"}}'
: > "$TMP/alerts.txt"
OUT="$(cmd_usage_budget_check 2>&1)"
[[ "$(jq -r '.agents.cachey.state' "$USAGE_BUDGET_STATE_FILE")" == "hard" ]] \
  && ok_t "budget: a --basis=quota ceiling FIRES on plan consumption" \
  || bad_t "quota budget did not fire — the alert path still cannot predict a wall" \
           "$(jq -c '.agents.cachey' "$USAGE_BUDGET_STATE_FILE")"
grep -qF 'basis: quota' "$TMP/alerts.txt" \
  && ok_t "budget: the ALERT names its basis (the message that wakes someone up)" \
  || bad_t "alert does not name its basis" "$(cat "$TMP/alerts.txt")"

# --- B7. a cost-basis alert carries the plan figure it is not watching -------
BUDGETS='{"fresh":{"soft":100,"hard":null,"hardStop":false,"notified":{},"stopped":false}}'
: > "$TMP/alerts.txt"
cmd_usage_budget_check >/dev/null 2>&1
{ grep -qF 'EXCLUDES cache-read' "$TMP/alerts.txt" && grep -qF -e '--basis=quota' "$TMP/alerts.txt"; } \
  && ok_t "budget: a cost-basis alert states the gap and the one-command fix" \
  || bad_t "cost-basis alert quotes a bare figure" "$(cat "$TMP/alerts.txt")"

# --- B8. AN ABSENT QUOTA IS UNKNOWN, NOT THE COST FIGURE --------------------
# Found by rendering real fleet data (2026-09-07) through the new presenters
# while feeding them the OLD collector's payload: every QUOTA cell silently
# printed the API-EQ number. A ~40x understatement under a header that says
# "what runs out" is worse than the defect this row fixes, because the reader
# now believes they are looking at plan consumption. Absence must render as
# absence (the DIVE-1929/2312 rule, applied to a second field).
DATA_OLD="$(jq -c 'del(.basis) | (.agents |= map(del(.quota))) | (.tasks |= map(del(.quota)))' <<<"$DATA")"
OUT="$(usage_render_board "$DATA_OLD" 24h '{}' 2>&1)"
grep -qE 'cachey +m +50 +400 +\?' <<<"$OUT" \
  && ok_t "board: an ABSENT quota renders '?', never the cost figure under a QUOTA header" \
  || bad_t "a quota-less payload prints the cost number as plan burn (~40x low, unmarked)" "$OUT"
# the board must still SORT (ordering may fall back; the cell may not)
has "$OUT" "cachey" && has "$OUT" "fresh" \
  && ok_t "board: ordering still works on a quota-less payload (falls back to cost)" || bad_t "board broke" "$OUT"
OUT="$(usage_render_agent "$DATA_OLD" cachey 24h 2>&1)"
has "$OUT" "UNKNOWN" \
  && ok_t "agent view: a quota-less payload says UNKNOWN and disclaims the cost line" \
  || bad_t "agent view invents a quota" "$OUT"

# --- B9. and a quota-basis budget must not PASS on an absent quota ----------
# `// 0` here would be a confident 0, and a confident 0 is a passing check —
# the unearned "ok" DIVE-1937 removed for unreadable agents.
BUDGETS='{"cachey":{"soft":100,"hard":null,"hardStop":false,"notified":{},"stopped":false,"basis":"quota"}}'
DATA_SAVE="$DATA"; DATA="$DATA_OLD"; : > "$TMP/alerts.txt"
cmd_usage_budget_check --dry-run >/dev/null 2>&1
[[ "$(jq -r '.agents.cachey.state' "$USAGE_BUDGET_STATE_FILE")" == "soft" \
   && "$(jq -r '.agents.cachey.burnQuota' "$USAGE_BUDGET_STATE_FILE")" == "null" ]] \
  && ok_t "budget: an absent quota falls back to the cost FLOOR (crossing still fires) and caches null, not 0" \
  || bad_t "absent quota became a confident 0 — the check reports 'ok' for a figure it never had" \
           "$(jq -c '.agents.cachey' "$USAGE_BUDGET_STATE_FILE")"
DATA="$DATA_SAVE"

# ============================================================================
# PART C — the VERIFIER RESIDUAL (quinn, 2026-09-07) and the DIVE-4034 MERGE.
#
# C1-C2 close the coverage hole quinn found by mutation: the absence guard was
# held on TOP AGENTS and open-coded on TOP TASKS, so restoring `.quota //
# .total` at the TOP TASKS site left this suite 26/26 GREEN. Both surfaces now
# reach the guard through one named jq function; these arms mutate-kill it.
#
# C3-C6 drive `cmd_usage_budget set`, which had NO test at all — commenting out
# the new-budgets-default-to-quota line left the suite green. It is root-gated,
# so the only way a non-root seat covers it is here, with require_root stubbed.
#
# C7-C9 are the DIVE-4034 merge. #784 feeds Codex into the same class dict
# `quota` sums, so the trees joining silently started counting Codex cache reads
# at 1.0x. That weight is now DECLARED per provider instead of being an
# accident of a clean merge, and these arms assert the declaration exists, says
# which provider is measured and which assumed, and reaches the screen.
# ============================================================================

# --- C1. TOP TASKS: an absent quota renders '?', same rule as TOP AGENTS -----
OUT="$(usage_render_board "$DATA_OLD" 24h '{}' 2>&1)"
TT="$(sed -n '/TOP TASKS/,$p' <<<"$OUT")"
grep -qE 'DIVE-9001 +cachey +- +50 +400 +\?' <<<"$TT" \
  && ok_t "TOP TASKS: an ABSENT quota renders '?' too — the guard is held on BOTH surfaces" \
  || bad_t "TOP TASKS prints the cost figure under a QUOTA header (quinn's mutant: .quota // .total)" "$TT"

# --- C2. and the guard did not eat the DIVE-2312 unverified qualifier --------
# qcellu must still be qtok, not htok: an unverified quota figure has to carry
# the word with it, or lifting the cell loses the caveat.
DATA_UNV="$(jq -c '(.tasks |= map(.dispatched = false))' <<<"$DATA")"
TT="$(usage_render_board "$DATA_UNV" 24h '{}' 2>&1 | sed -n '/TOP TASKS/,$p')"
grep -qF '(unverified)' <<<"$TT" && grep -qF '~400k(unverified)' <<<"$TT" \
  && ok_t "TOP TASKS: the quota cell keeps the DIVE-2312 unverified qualifier" \
  || bad_t "the shared guard dropped qtok — an unverified plan figure now renders liftable" "$TT"

# --- C3. `budget set` on a NEW agent defaults to the QUOTA basis -------------
# The whole alert path exists to predict a wall; a new budget that cannot is a
# budget filed against the wrong number on day one.
BUDGETS='{}'; rm -f "$TMP/saved.json"
OUT="$(cmd_usage_budget set newbie --daily=1000 2>&1)"; RC=$?
[[ $RC -eq 0 && "$(jq -r '.newbie.basis' "$TMP/saved.json")" == "quota" ]] \
  && ok_t "budget set: a NEW budget defaults to quota (it can predict a wall)" \
  || bad_t "a new budget was filed on the cost basis" "rc=$RC $(cat "$TMP/saved.json" 2>/dev/null) $OUT"

# --- C4. an UPDATE preserves the stored basis — never a silent re-base -------
BUDGETS='{"keeper":{"soft":1000,"hard":null,"hardStop":false,"notified":{},"stopped":false,"basis":"cost"}}'
rm -f "$TMP/saved.json"
cmd_usage_budget set keeper --daily=2000 >/dev/null 2>&1
[[ "$(jq -r '.keeper.basis' "$TMP/saved.json")" == "cost" \
   && "$(jq -r '.keeper.soft' "$TMP/saved.json")" == "2000" ]] \
  && ok_t "budget set: an UPDATE keeps the stored basis (no silent 40x re-base)" \
  || bad_t "editing a threshold silently moved its basis" "$(cat "$TMP/saved.json" 2>/dev/null)"

# --- C5. a LEGACY bare-int entry is an existing budget, so it stays cost -----
BUDGETS='{"legacy":5000}'; rm -f "$TMP/saved.json"
cmd_usage_budget set legacy --ceiling=9000 >/dev/null 2>&1
[[ "$(jq -r '.legacy.basis' "$TMP/saved.json")" == "cost" ]] \
  && ok_t "budget set: a legacy bare-int budget normalizes to cost, not quota" \
  || bad_t "a legacy threshold was re-based by an unrelated edit" "$(cat "$TMP/saved.json" 2>/dev/null)"

# --- C6. and an unknown basis is refused by NAME, not silently accepted ------
BUDGETS='{}'
OUT="$(cmd_usage_budget set newbie --basis=bogus 2>&1)"; RC=$?
[[ $RC -eq "$E_USAGE" ]] && has "$OUT" "--basis must be" \
  && ok_t "budget set: --basis=bogus fails E_USAGE and names the two valid bases" \
  || bad_t "an unknown basis was accepted (or failed with the wrong code)" "rc=$RC $OUT"

# --- C7. THE MERGE: the per-provider cache-read weight is DECLARED -----------
# Both providers are summed at 1.0x, and that is fine — but only one of them is
# MEASURED (DIVE-4028, Codex, n=1). A consumer must be able to tell which
# figure rests on a measurement and which on an upper bound, and it must not
# have to read a source comment to find out.
PW="$(jq -c '.basis.quota.providerWeights' <<<"$OUT_U")"
[[ "$(jq -r '.codex.basis' <<<"$PW")" == "measured" \
   && "$(jq -r '.claude.basis' <<<"$PW")" == "assumed" \
   && "$(jq -r '.codex.cacheRead' <<<"$PW")" == "1.0" \
   && "$(jq -r '.claude.cacheRead' <<<"$PW")" == "1.0" ]] \
  && ok_t "collector: cache-read weight declared PER PROVIDER — codex measured, claude assumed" \
  || bad_t "the merge with DIVE-4034 left Codex's 1.0x weight unstated" "$PW"

# --- C8. a CODEX seat lands in the agent row and in NO task row -------------
# quinn's check (a). #784 aggregates CUMULATIVE per-rollout snapshots, so those
# tokens cannot be assigned to a task window and the collector deliberately
# does not try. That is correct, and it means `sum(tasks[].quota)` is NOT fleet
# plan burn on a mixed fleet — so the payload has to SAY so.
CXD="$R/agent-cx/.codex/sessions/$(date -u -d @"$NOW" +%Y/%m/%d)"
mkdir -p "$CXD"
printf '%s\n' "{\"type\":\"event_msg\",\"timestamp\":\"$TS\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":40000,\"cached_input_tokens\":39600,\"cache_write_input_tokens\":250,\"output_tokens\":50}},\"rate_limits\":{\"primary\":{\"used_percent\":5},\"secondary\":{\"used_percent\":80}}}}" \
  > "$CXD/rollout-test.jsonl"
printf '{"agents":{"cx":{"type":"codex"}}}' > "$TMP/reg-cx.json"
OUT_CX="$(REGISTRY="$TMP/reg-cx.json" TASK_DB="$DB" USAGE_SINCE="$((NOW-3600))" \
          USAGE_HOME_ROOT="$R" python3 "$TMP/collect.py" 2>/dev/null)"
# in = 40000 - 39600 - 250 = 150; cost = 150+50+250 = 450; quota = +39600 = 40050
[[ "$(jq -r '.agents[0].quota' <<<"$OUT_CX")" == "40050" \
   && "$(jq -r '.agents[0].total' <<<"$OUT_CX")" == "450" \
   && "$(jq -r '.tasks | length' <<<"$OUT_CX")" == "0" \
   && "$(jq -r '.basis.quota.taskAttribution.codex' <<<"$OUT_CX")" == *"agent-row only"* ]] \
  && ok_t "collector: a CODEX seat's quota is on the agent row, in NO task row, and the payload says so" \
  || bad_t "codex quota is wrong, or leaked into task attribution, or the gap is undeclared" \
           "$(jq -c '{a:.agents[0]|{total,quota},t:(.tasks|length),d:.basis.quota.taskAttribution}' <<<"$OUT_CX")"

# --- C9. and the weight REACHES THE SCREEN, only when a codex seat is present -
DATA_CX="$(jq -c '(.agents[0].models.codex = .agents[0].models.m)' <<<"$DATA")"
OUT="$(usage_render_board "$DATA_CX" 24h '{}' 2>&1)"
has "$OUT" "1.0x on BOTH providers" \
  && ok_t "board: with a codex seat present, the legend names the 1.0x weight and which half is measured" \
  || bad_t "the merge's weighting decision never reaches the reader" "$OUT"
OUT="$(usage_render_board "$DATA" 24h '{}' 2>&1)"
! has "$OUT" "1.0x on BOTH providers" \
  && ok_t "board: an all-claude window does NOT claim a codex measurement it has no seat for" \
  || bad_t "the codex weight line prints with no codex seat in the window" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
