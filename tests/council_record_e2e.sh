#!/usr/bin/env bash
# CNCL-17 bash e2e — the seat TRACK RECORD wiring (not just the pure scorer). Drives the real
# `5dive council record` bundle end-to-end against an isolated STATE_DIR + TASKS_DB:
#   - seeds two decided tasks (one DONE → good outcome, one CANCELLED → bad outcome) + one still-open,
#   - drops sealed-shape receipts whose canonical carries `vote <seat>:` lines + a `subject` ident,
#   - asserts the scorer credits an approve on a good outcome, VINDICATES a dissent on a bad one,
#     and NEVER scores the still-open task (no eventual outcome).
# `council record` itself is read-only, but seeding the isolated tasks store needs `task init`
# (root). Re-execs under passwordless sudo when available; SKIPs (green) otherwise — same posture
# as council_gate_e2e.sh, so CI never reds on a runner that can't init. Offline.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIVE="$ROOT/5dive"

for b in node jq sqlite3; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council record e2e needs it)"; exit 0; }
done
[[ -x "$FIVE" ]] || { echo "SKIP: built ./5dive not found (run ./build.sh first)"; exit 0; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then exec sudo -n env PATH="$PATH" bash "$0" "$@"; fi
  echo "SKIP: council record e2e needs root (isolated task init) and passwordless sudo is unavailable"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export STATE_DIR="$TMP" TASKS_DB="$TMP/tasks.db" FIVEDIVE_PROD_TASKS_DB="$TMP/tasks.db" COUNCIL_5DIVE_BIN="$FIVE"
mkdir -p "$TMP/council/receipts"

pass=0; fail=0
ok(){ if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1"; fi; }

# --- seed decided + open tasks --------------------------------------------------------------------
"$FIVE" task init >/dev/null 2>&1 || { echo "SKIP: could not init the isolated tasks store"; exit 0; }
GOOD="$("$FIVE" task add "shipped feature" --json 2>/dev/null | jq -r '.data.ident // .data.id // empty')"
BAD="$("$FIVE" task add "abandoned idea"  --json 2>/dev/null | jq -r '.data.ident // .data.id // empty')"
OPEN="$("$FIVE" task add "still cooking"  --json 2>/dev/null | jq -r '.data.ident // .data.id // empty')"
[[ -n "$GOOD" && -n "$BAD" && -n "$OPEN" ]] || { echo "SKIP: could not seed tasks in the isolated DB"; exit 0; }
"$FIVE" task done   "$GOOD" --result="landed" >/dev/null 2>&1 || sqlite3 "$TASKS_DB" "UPDATE tasks SET status='done' WHERE ident='$GOOD';"
"$FIVE" task cancel "$BAD"  --result="dropped" >/dev/null 2>&1 || sqlite3 "$TASKS_DB" "UPDATE tasks SET status='cancelled' WHERE ident='$BAD';"

mkrcpt(){ # $1=file $2=subject $3=canonical-votes
  cat > "$TMP/council/receipts/$1" <<EOF
{"stampedAt":"2026-01-0${1:0:1}T00:00:00Z","sealedDigest":"d$1","council":"council","question":"gate $2","disposition":"pass","subject":"$2","verdict":{"recommendation":"approve"},"canonical":"$3"}
EOF
}
# alice always approves; bob always dissents (reject). GOOD → alice✓ bob✗; BAD → alice✗ bob✓(vindicated).
mkrcpt "1.json" "$GOOD" "vote alice: approve :: ship it\nvote bob: reject :: risky"
mkrcpt "2.json" "$BAD"  "vote alice: approve :: ship it\nvote bob: reject :: risky"
mkrcpt "3.json" "$OPEN" "vote alice: approve :: ship it\nvote bob: reject :: risky"

REC="$("$FIVE" council record --json 2>/dev/null)"
ok "record returns ok"                 '[[ "$(printf "%s" "$REC" | jq -r .ok)" == "true" ]]'
ok "only the 2 decided receipts scored" '[[ "$(printf "%s" "$REC" | jq -r .data.scoredReceipts)" == "2" ]]'
A="$(printf '%s' "$REC" | jq -c '.data.seats[]|select(.seat=="alice")')"
B="$(printf '%s' "$REC" | jq -c '.data.seats[]|select(.seat=="bob")')"
ok "alice scored 2, correct 1 (approve: good✓ bad✗)" '[[ "$(printf "%s" "$A" | jq -r .scored)" == "2" && "$(printf "%s" "$A" | jq -r .correct)" == "1" ]]'
ok "bob scored 2, correct 1, 1 vindicated dissent"   '[[ "$(printf "%s" "$B" | jq -r .scored)" == "2" && "$(printf "%s" "$B" | jq -r .correct)" == "1" && "$(printf "%s" "$B" | jq -r .vindicated)" == "1" ]]'
ok "open task never scored (no seat credited it)"    '[[ "$(printf "%s" "$REC" | jq -r "[.data.seats[].scored]|max")" == "2" ]]'

echo "CNCL-17 record e2e: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
