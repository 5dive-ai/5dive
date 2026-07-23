#!/usr/bin/env bash
# OSS-38 isolated unit harness for the autonomy ledger (`_proof_ledger`), the
# honesty-critical core of `proof status`. Drives it against a fixture tasks.db
# — no live board, no network, no root. Asserts the badge math:
#   - shipped = done standard tasks (recurring + non-done excluded),
#   - an "ask" = a done task that carried a gate a HUMAN answered
#     (need_answered_by LIKE 'human:%' OR a human_nonce_hash); a lead/agent
#     clearance is NOT an ask, even though it carries a need_answered_uid,
#   - autonomyPct = 1 - asks/shipped, one decimal, trailing .0 dropped,
#   - an empty board yields shipped 0 and a null pct (no divide-by-zero).
# Run: bash tests/proof_ledger_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP - sqlite3 absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP - jq absent"; exit 0; }

TMP="$(mktemp -d /tmp/proof-ledger.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- stub the deps _proof_ledger reaches for, then source cmd_proof.sh -------
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
JSON_MODE=0
E_USAGE=2; E_GENERIC=1
require_root() { :; }
fail() { echo "fail($1): $2" >&2; exit "$1"; }
# db() runs the query against the fixture TASKS_DB, exactly like the real helper.
db() { sqlite3 "$TASKS_DB" "$1"; }

# shellcheck disable=SC1091
source src/cmd_proof.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- build a fixture tasks.db (only the columns the ledger reads) ------------
export TASKS_DB="$TMP/tasks.db"
sqlite3 "$TASKS_DB" <<'SQL'
CREATE TABLE tasks (
  status TEXT, kind TEXT, need_type TEXT,
  need_answered_by TEXT, need_answered_uid INTEGER, human_nonce_hash TEXT
);
-- 5 clean shipped actions (done, standard, no gate)
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL);
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL);
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL);
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL);
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL);
-- 2 shipped that needed a human (answered through a human rail, DIVE-1117)
INSERT INTO tasks VALUES ('done','standard','decision','human:lodar',1000,NULL);
INSERT INTO tasks VALUES ('done','standard','approval','human:olivia',1000,NULL);
-- 1 shipped that needed a human (human-tap nonce, no human: prefix)
INSERT INTO tasks VALUES ('done','standard','manual',NULL,NULL,'abc123');
-- 1 shipped whose gate a LEAD cleared (uid captured, but NOT human) — NOT an ask
INSERT INTO tasks VALUES ('done','standard','decision','lead:main',1000,NULL);
-- 1 shipped whose gate a bare AGENT answered (uid captured) — NOT an ask
INSERT INTO tasks VALUES ('done','standard','approval','olivia',1000,NULL);
-- excluded: a still-blocked task (not shipped)
INSERT INTO tasks VALUES ('blocked','standard','decision','human:lodar',1000,NULL);
-- excluded: a done RECURRING template (not a standard action)
INSERT INTO tasks VALUES ('done','recurring',NULL,NULL,NULL,NULL);
SQL
# shipped = 10 done standard; asks = 3 (2 human-rail + 1 nonce; lead + agent
# clearances excluded even though they carry a uid); pct = (1-3/10)*100 = 70

led="$(_proof_ledger)"
got_ship="$(jq -r '.shipped' <<<"$led")"
got_ask="$(jq -r '.asks' <<<"$led")"
got_auto="$(jq -r '.autonomous' <<<"$led")"
got_pct="$(jq -r '.autonomyPct' <<<"$led")"

[ "$got_ship" = 10 ] && ok_t "shipped counts done standard tasks (10)" || bad_t "shipped" "got $got_ship"
[ "$got_ask" = 3 ]   && ok_t "asks = human-answered gates only (3)"     || bad_t "asks" "got $got_ask"
[ "$got_auto" = 7 ]  && ok_t "autonomous = shipped - asks (7)"          || bad_t "autonomous" "got $got_auto"
[ "$got_pct" = 70 ]  && ok_t "autonomyPct = 1 - asks/shipped (70)"      || bad_t "pct" "got $got_pct"

# --- lead + agent clearances (uid set, not human) must NOT count as asks -----
# The fixture has a 'lead:main' and a bare-'olivia' clearance, both with a uid;
# asks stayed at 3, proving need_answered_uid does NOT inflate the human count.
[ "$got_ask" = 3 ] && ok_t "lead/agent clearance (uid-only) is not an ask" || bad_t "uid-only excluded" "asks=$got_ask"

# --- empty board: shipped 0, null pct, no divide-by-zero --------------------
export TASKS_DB="$TMP/empty.db"
sqlite3 "$TASKS_DB" 'CREATE TABLE tasks (status TEXT, kind TEXT, need_type TEXT, need_answered_by TEXT, need_answered_uid INTEGER, human_nonce_hash TEXT);'
led2="$(_proof_ledger)"
[ "$(jq -r '.shipped' <<<"$led2")" = 0 ] && ok_t "empty board: shipped 0" || bad_t "empty shipped" "$led2"
[ "$(jq -r '.autonomyPct' <<<"$led2")" = null ] && ok_t "empty board: null pct (no div0)" || bad_t "empty pct" "$led2"

# --- 100% autonomy: all clean, no asks --------------------------------------
export TASKS_DB="$TMP/clean.db"
sqlite3 "$TASKS_DB" <<'SQL'
CREATE TABLE tasks (status TEXT, kind TEXT, need_type TEXT, need_answered_by TEXT, need_answered_uid INTEGER, human_nonce_hash TEXT);
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL);
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL);
SQL
led3="$(_proof_ledger)"
[ "$(jq -r '.autonomyPct' <<<"$led3")" = 100 ] && ok_t "all-clean board: 100% autonomy" || bad_t "100pct" "$led3"

echo
echo "proof_ledger_unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
