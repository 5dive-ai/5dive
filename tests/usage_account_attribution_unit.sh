#!/usr/bin/env bash
# DIVE-4589 unit: `usage` must attribute each turn to the auth profile that was
# bound AT THAT TURN'S TIMESTAMP, and must never claim more confidence than the
# binding trail supports.
#
# THE DEFECT THIS GUARDS (verified at origin/main before the fix):
#   src/cmd_usage.sh built every agent row as `"account": meta.get("authProfile")`
#   — the CURRENT registry binding, stamped onto every historical turn the
#   collector parsed. One rotation therefore re-attributed the entire past to the
#   new profile. DIVE-4584's Pro burn measurement hit exactly that and could only
#   be repaired with a hand-typed constant in a bespoke script.
#
# WHY THIS SHAPE:
#   * BOTH LAYERS. The collector is driven at the same seam as
#     tests/usage_quota_basis_unit.sh (its python is extracted and fed fixtures),
#     AND the real presenters are sourced and driven. A number that is collected
#     and never rendered is a fix that has not shipped (DIVE-1937).
#   * THE FALLBACK IS ASSERTED AS LOUDLY AS THE PROOF. Nothing is backfilled, so
#     most turns on a real board will read `current-binding-fallback` for a while.
#     A view that showed that as a proven attribution would be the original defect
#     wearing a new column.
#   * BACKWARD COMPATIBILITY IS ASSERTED (criterion 10): agents[].account still
#     carries the CURRENT binding and the plain board still renders.
#
# NEGATIVE CONTROL (re-run against the pre-fix tree):
#   mkdir -p /tmp/pre4589 && git show origin/main:src/cmd_usage.sh > /tmp/pre4589/cmd_usage.sh
#   USAGE_SRC_DIR=/tmp/pre4589 bash tests/usage_account_attribution_unit.sh   # must FAIL
#
# Run: bash tests/usage_account_attribution_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

command -v sqlite3 >/dev/null 2>&1 || { echo "skip - sqlite3 not available"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "skip - jq not available"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip - python3 not available"; exit 0; }

SRC_DIR="${USAGE_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/usage-acct.XXXXXX)"

PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
      else FAIL=$((FAIL+1)); printf 'FAIL - %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
# has <what-it-asserts> <rendered-output> <needle>
has() { if grep -qF -- "$3" <<<"$2"; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL - %s (missing: %s)\n' "$1" "$3"; fi; }

# Extract the FIRST heredoc'ed python block only — usage_collect. cmd_usage.sh
# carries a second one (the per-agent activity reader), and the obvious
# f=1/f=0 toggle silently concatenates both: the second block then dies on a
# KeyError for an env var only its own caller sets. The existing usage harnesses
# survive that by never checking the collector's exit status, which means they
# are scoring a python run that ended in a traceback. `exit` after the first
# terminator keeps this harness reading only the thing it grades.
awk "/python3 - <<'PY'/{f=1;next} f&&/^PY\$/{exit} f" "$SRC_DIR/cmd_usage.sh" > "$TMP/collect.py"
[[ -s "$TMP/collect.py" ]] || { echo "FAIL - could not extract usage_collect python"; exit 1; }

NOW=$(date +%s)
T0=$((NOW-7200)); T1=$((NOW-3600)); T2=$((NOW-1800))
iso() { date -u -d @"$1" +%Y-%m-%dT%H:%M:%SZ; }
sqlts() { date -u -d @"$1" +'%Y-%m-%d %H:%M:%S'; }

R="$TMP/homes"
# one assistant turn per line; in=100 out=50 cache_write=250 cache_read=39600
# (the cache-read-dominated shape real agentic traffic has).
turn() {  # <agent> <epoch>
  local d="$R/agent-$1/.claude/projects/proj"; mkdir -p "$d"
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$(iso "$2")\",\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"cache_creation_input_tokens\":250,\"cache_read_input_tokens\":39600}}}" \
    >> "$d/session.jsonl"
}
turn coder $((T0+60))    # bound to max-a then
turn coder $((T1+60))    # bound to max-b then — SAME seat, SAME task
turn quinn $((T2+60))    # a second seat on max-b
turn solo  $((T0+60))    # no binding events at all -> fallback
turn ghost $((T0+60))    # no events AND no current binding -> unknown

cat > "$TMP/reg.json" <<JSON
{"agents":{
  "coder":{"type":"claude","authProfile":"max-b"},
  "quinn":{"type":"claude","authProfile":"max-b"},
  "solo": {"type":"claude","authProfile":"max-a"},
  "ghost":{"type":"claude"}
}}
JSON

DB="$TMP/tasks.db"
sqlite3 "$DB" "
CREATE TABLE tasks (ident TEXT, title TEXT, assignee TEXT, started_at TEXT, done_at TEXT, iteration INT, status TEXT);
INSERT INTO tasks VALUES ('DIVE-9001','a task worked across a rebind','coder','$(sqlts $((T0-600)))',NULL,NULL,'in_progress');
CREATE TABLE account_binding_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, agent TEXT NOT NULL, account TEXT, reason TEXT);
INSERT INTO account_binding_events(ts,agent,account,reason) VALUES
  ($T0,'coder','max-a','create'),
  ($T1,'coder','max-b','rotation'),
  ($T2,'quinn','max-b','create');
CREATE TABLE account_usage_samples (account TEXT NOT NULL, as_of INTEGER NOT NULL, five_pct REAL, five_reset TEXT, seven_pct REAL, seven_reset TEXT, source_agent TEXT NOT NULL, UNIQUE(account,as_of));
INSERT INTO account_usage_samples VALUES
  ('max-b',$((T1+10)),10,'r5',20,'r7','quinn'),
  ('max-b',$((NOW-60)),25,'r5',32,'r7','quinn');
" >/dev/null

D=$(REGISTRY="$TMP/reg.json" TASK_DB="$DB" USAGE_SINCE=$((NOW-86400)) \
    USAGE_HOME_ROOT="$R" python3 "$TMP/collect.py") || { echo "FAIL - collector errored"; exit 1; }

acct() { jq -r --arg a "$1" '.accounts[]|select(.account==$a)|'"$2" <<<"$D"; }

# --- criterion 2: one seat that switched mid-window splits by event ---------
t "criterion 2 — the pre-rebind turn is attributed to the OLD account" \
  "1" "$(acct max-a '.agents[]|select(.name=="coder")|.turns')"
t "criterion 2 — the post-rebind turn is attributed to the NEW account" \
  "1" "$(acct max-b '.agents[]|select(.name=="coder")|.turns')"
t "the split is by EVENT, not by seat: coder appears under two accounts" \
  "2" "$(jq -r '[.accounts[]|select(.agents|map(.name)|index("coder"))]|length' <<<"$D")"

# --- criterion 1: two seats sharing a profile aggregate into ONE row --------
t "criterion 1 — two seats on one profile are one account row" \
  "1" "$(jq -r '[.accounts[]|select(.account=="max-b")]|length' <<<"$D")"
t "criterion 1 — and that row carries both seats" \
  "coder,quinn" "$(acct max-b '.agents|map(.name)|sort|join(",")')"
t "criterion 1 — and sums both seats' turns" "2" "$(acct max-b '.turns')"

# --- criterion 3: one task, two profiles -----------------------------------
t "criterion 3 — the task appears under the old account" \
  "DIVE-9001" "$(acct max-a '.tasks[0].ident')"
t "criterion 3 — and under the new one" \
  "DIVE-9001" "$(acct max-b '.tasks[]|select(.ident=="DIVE-9001")|.ident')"
t "criterion 3 — with the turns split, not duplicated" \
  "1 1" "$(acct max-a '.tasks[0].turns') $(acct max-b '.tasks[]|select(.ident=="DIVE-9001")|.turns')"

# --- criterion 6: an unproven binding is MARKED, never claimed --------------
t "criterion 6 — a seat with no events falls back to its current binding" \
  "1" "$(acct max-a '.attribution["current-binding-fallback"]')"
t "criterion 6 — and the row says the attribution is mixed, not proven" \
  "mixed" "$(acct max-a '.attributionSource')"
t "criterion 6 — max-b's turns are all proven" \
  "binding-event" "$(acct max-b '.attributionSource')"
t "criterion 6 — a seat with neither event nor binding is 'unattributed', not guessed" \
  "1" "$(jq -r '[.accounts[]|select(.account==null)]|first|.turns' <<<"$D")"
t "criterion 6 — and that bucket is labelled unknown" \
  "unknown" "$(jq -r '[.accounts[]|select(.account==null)]|first|.attributionSource' <<<"$D")"

# --- criterion 9: --json carries profile, confidence and snapshot coverage ---
t "criterion 9 — the payload names the auth profile" "max-b" "$(acct max-b '.account')"
t "criterion 9 — and the attribution source" "binding-event" "$(acct max-b '.attributionSource')"
t "criterion 9 — and the quota snapshot coverage" "2" "$(acct max-b '.quotaSnapshots.samples')"
t "criterion 9 — naming the seat whose reading it was" \
  "quinn" "$(acct max-b '.quotaSnapshots.sourceAgents|join(",")')"
t "an account with no snapshots says so rather than showing a delta" \
  "fewer than two provider snapshots inside the window" "$(acct max-a '.diagnostics.unknown')"

# --- section 4: the diagnostic is a ratio of two measurements ---------------
t "section 4 — the 7d delta is measured between the bracketing snapshots" \
  "12.0" "$(acct max-b '.diagnostics.sevenDayPpDelta')"
# Both of max-b's turns sit inside the snapshot bracket, so both count. The arm
# that matters is the NEXT one: a turn OUTSIDE the bracket must not.
t "section 4 — tokens are summed over the SNAPSHOT interval, not the window" \
  "80000" "$(acct max-b '.diagnostics.quotaTokens')"
t "section 4 — coder's PRE-rebind turn is counted under max-a and nowhere else" \
  "40000" "$(acct max-a '.agents[]|select(.name=="coder")|.quota')"
t "section 4 — and the pp-per-1M ratio is derived from those two" \
  "150.0" "$(acct max-b '.diagnostics.sevenDayPpPerMQuota')"
t "section 4 — the cache-read denominator is reported too" \
  "79200" "$(acct max-b '.diagnostics.cacheReadTokens')"
t "section 4 — the diagnostic declares itself observational" \
  "true" "$(acct max-b '.diagnostics.basis|test("observational")')"

# --- criterion 10: nothing existing moved ----------------------------------
t "criterion 10 — agents[].account is STILL the seat's current binding" \
  "max-b" "$(jq -r '.agents[]|select(.name=="coder")|.account' <<<"$D")"
t "criterion 10 — the task row is unchanged and still whole" \
  "2" "$(jq -r '.tasks[]|select(.ident=="DIVE-9001")|.turns' <<<"$D")"
t "criterion 10 — cost and quota bases are untouched" \
  "400 40000" "$(jq -r '.agents[]|select(.name=="quinn")|"\(.total) \(.quota)"' <<<"$D")"

# ===========================================================================
# PART B — the PRESENTERS. A field the collector computes and no view renders
# is not a shipped fix.
# ===========================================================================
# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
JSON_MODE=0
# cmd_usage.sh resolves its budget store at source time; point it at the scratch
# dir so sourcing it cannot reach the real one.
export STATE_DIR="$TMP"
# shellcheck source=/dev/null
source "$SRC_DIR/cmd_usage.sh"

OUT=$(usage_render_accounts "$D" 24h 2>&1)
has "the board has an ACCOUNT column" "$OUT" "ACCOUNT"
has "the board reports cache-read (the class that runs the plan out)" "$OUT" "CACHE-READ"
has "the board shows both profiles" "$OUT" "max-a"
has "the board names the attribution source per row" "$OUT" "current-binding-fallback"
has "the board explains a withheld RATIO instead of printing a bare ?" "$OUT" "no pp-per-1M-tokens ratio"
has "and names the reason" "$OUT" "fewer than two provider snapshots"
has "the legend says a fallback is NOT proof" "$OUT" "is NOT proof"
has "the unattributed bucket is visible, not dropped" "$OUT" "(unattributed)"

OUT=$(usage_render_account "$D" max-b task 24h 2>&1)
has "--by=task lists the task that spent the profile" "$OUT" "DIVE-9001"
OUT=$(usage_render_account "$D" max-b agent 24h 2>&1)
has "--by=agent lists both seats" "$OUT" "quinn"
OUT=$(usage_render_account "$D" max-b summary 24h 2>&1)
has "the summary names the attribution breakdown" "$OUT" "attribution:"
has "the summary reports snapshot coverage" "$OUT" "snapshots:"
OUT=$(usage_render_account "$D" nosuch summary 24h 2>&1)
has "an account with no attributed usage is answered, not failed" "$OUT" "no usage attributed"

JSON_MODE=1
OUT=$(usage_render_accounts "$D" 24h)
t "--json is a well-formed envelope" "true" "$(jq -r '.ok' <<<"$OUT")"
t "--json carries the accounts array" "3" "$(jq -r '.data.accounts|length' <<<"$OUT")"
OUT=$(usage_render_account "$D" max-b summary 24h)
t "--json for one account carries its attribution source" \
  "binding-event" "$(jq -r '.data.attributionSource' <<<"$OUT")"

echo "-----"
echo "usage_account_attribution_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
