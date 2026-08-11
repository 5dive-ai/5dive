#!/usr/bin/env bash
# OSS-38 isolated unit harness for the autonomy ledger (`_proof_ledger`), the
# honesty-critical core of `proof status`. Drives it against a fixture tasks.db
# — no live board, no network, no root. Asserts the badge math:
#   - shipped = done standard tasks (recurring + non-done excluded),
#   - an "ask" = a done task that carried a gate a HUMAN answered
#     (need_answered_by LIKE 'human:%' AND need_answered_at set, OR a
#     human_nonce_hash); a lead/agent clearance is NOT an ask, even though it
#     carries a need_answered_uid,
#   - DIVE-2119: the two arms of that OR are guarded DIFFERENTLY and both
#     directions are pinned below. The by-arm requires need_answered_at, so
#     re-file residue (a stale 'human:*' answerer on an UNANSWERED gate) counts
#     ZERO — while the nonce arm stays unguarded on purpose, because a minted
#     nonce means the gate was DELIVERED to a human and unanswered-still-needed-
#     a-human keeps the badge conservative. Guarding it too would have RAISED a
#     published metric. Both are asserted: a guard that merely zeroed the metric
#     would pass the residue case and fail the answered one.
#   - autonomyPct = 1 - asks/shipped, one decimal, trailing .0 dropped,
#   - an empty board yields shipped 0 and a null pct (no divide-by-zero).
# Run: bash tests/proof_ledger_unit.sh   (no root, no network).
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP - sqlite3 absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP - jq absent"; exit 0; }

TMP="$(mktemp -d /tmp/proof-ledger.XXXXXX)"

# --- stub the deps _proof_ledger reaches for, then source cmd_proof.sh -------
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
JSON_MODE=0
E_USAGE=2; E_GENERIC=1
require_root() { :; }
fail() { echo "fail($1): $2" >&2; exit "$1"; }
# db() runs the query against the fixture TASKS_DB, exactly like the real helper.
db() { sqlite3 "$TASKS_DB" "$1"; }

# DIVE-3227: _proof_ledger now excludes experiment-fixture rows by title, using
# the single definition in src/lib/tasks_db.sh. Pull those three functions out of
# THE PRODUCT FILE rather than restating them here — a harness that carries its
# own copy of the rule grades the copy (a test of the instrument, DIVE-3175).
eval "$(awk '/^sqlq\(\) \{/,/^\}/' src/lib/tasks_db.sh)"
eval "$(awk '/^five_fixture_title_prefixes\(\) \{/,/^\}/' src/lib/tasks_db.sh)"
eval "$(awk '/^five_fixture_title_sql\(\) \{/,/^\}/' src/lib/tasks_db.sh)"
declare -F five_fixture_title_sql >/dev/null \
  || { echo "FAIL - could not extract five_fixture_title_sql from src/lib/tasks_db.sh"; exit 1; }

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
  need_answered_by TEXT, need_answered_uid INTEGER, human_nonce_hash TEXT,
  need_answered_at TEXT, title TEXT
);
-- 5 clean shipped actions (done, standard, no gate)
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'ship a real thing');
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'ship a real thing');
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'ship a real thing');
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'ship a real thing');
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'ship a real thing');
-- 2 shipped that needed a human (answered through a human rail, DIVE-1117)
INSERT INTO tasks VALUES ('done','standard','decision','human:lodar',1000,NULL,'2026-07-01 10:00:00','ship a real thing');
INSERT INTO tasks VALUES ('done','standard','approval','human:olivia',1000,NULL,'2026-07-01 11:00:00','ship a real thing');
-- 1 shipped that needed a human (human-tap nonce, no human: prefix). DELIBERATELY
-- unanswered: the nonce arm counts a gate DELIVERED to a human, answered or not.
INSERT INTO tasks VALUES ('done','standard','manual',NULL,NULL,'abc123',NULL,'ship a real thing');
-- 1 shipped whose gate a LEAD cleared (uid captured, but NOT human) — NOT an ask
INSERT INTO tasks VALUES ('done','standard','decision','lead:main',1000,NULL,'2026-07-01 12:00:00','ship a real thing');
-- 1 shipped whose gate a bare AGENT answered (uid captured) — NOT an ask
INSERT INTO tasks VALUES ('done','standard','approval','olivia',1000,NULL,'2026-07-01 13:00:00','ship a real thing');
-- DIVE-2119 re-file RESIDUE: a LIVE gate wearing the PREVIOUS gate's human
-- answerer, need_answered_at NULL because nobody has answered THIS one. 8 rows
-- on the live board looked like this. Counting it invents an ask that never
-- happened, so it must NOT count — this is the row the guard exists for.
INSERT INTO tasks VALUES ('done','standard','secret','human:lodar',1000,NULL,NULL,'ship a real thing');
-- excluded: a still-blocked task (not shipped)
INSERT INTO tasks VALUES ('blocked','standard','decision','human:lodar',1000,NULL,'2026-07-01 14:00:00','ship a real thing');
-- excluded: a done RECURRING template (not a standard action)
INSERT INTO tasks VALUES ('done','recurring',NULL,NULL,NULL,NULL,NULL,'ship a real thing');
-- DIVE-3227 excluded: two EXPERIMENT-FIXTURE rows. Done, standard, no gate, and
-- indistinguishable from real work on every other column — pure denominator, so
-- they can only flatter the published badge. The second is padded and mixed-case
-- to pin the lower(trim(title)) normalisation.
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'stamp arm A');
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'  Stamp Arm B  ');
SQL
# shipped = 11 done standard; asks = 3 (2 human-rail + 1 nonce; lead + agent
# clearances excluded even though they carry a uid, and the DIVE-2119 re-file
# residue row excluded because its gate is unanswered); pct = (1-3/11)*100 = 72.7

led="$(_proof_ledger)"
got_ship="$(jq -r '.shipped' <<<"$led")"
got_ask="$(jq -r '.asks' <<<"$led")"
got_auto="$(jq -r '.autonomous' <<<"$led")"
got_pct="$(jq -r '.autonomyPct' <<<"$led")"

[ "$got_ship" = 11 ] && ok_t "shipped counts done standard tasks (11)" || bad_t "shipped" "got $got_ship"
[ "$got_ask" = 3 ]   && ok_t "asks = human-answered gates only (3)"     || bad_t "asks" "got $got_ask"
[ "$got_auto" = 8 ]  && ok_t "autonomous = shipped - asks (8)"          || bad_t "autonomous" "got $got_auto"
[ "$got_pct" = 72.7 ] && ok_t "autonomyPct = 1 - asks/shipped (72.7)"   || bad_t "pct" "got $got_pct"

# --- lead + agent clearances (uid set, not human) must NOT count as asks -----
# The fixture has a 'lead:main' and a bare-'olivia' clearance, both with a uid;
# asks stayed at 3, proving need_answered_uid does NOT inflate the human count.
[ "$got_ask" = 3 ] && ok_t "lead/agent clearance (uid-only) is not an ask" || bad_t "uid-only excluded" "asks=$got_ask"

# --- DIVE-2119: the by-arm guard, asserted in BOTH directions ---------------
# The fixture's residue row (need_type set, need_answered_by='human:lodar',
# need_answered_at NULL) is already excluded from the 3 above. Prove the guard
# CORRECTS rather than DISABLES: answer that same gate and the ask must appear.
# A guard that simply zeroed the by-arm would pass the exclusion and fail here.
sqlite3 "$TASKS_DB" "UPDATE tasks SET need_answered_at='2026-07-02 09:00:00'
                     WHERE need_type='secret' AND need_answered_by='human:lodar';"
after_ask="$(jq -r '.asks' <<<"$(_proof_ledger)")"
[ "$after_ask" = 4 ] \
  && ok_t "re-file residue excluded, but the SAME gate once answered counts (3 -> 4)" \
  || bad_t "the by-arm guard must correct, not disable" "asks after answering=$after_ask"
sqlite3 "$TASKS_DB" "UPDATE tasks SET need_answered_at=NULL
                     WHERE need_type='secret' AND need_answered_by='human:lodar';"

# The nonce arm keeps its DELIVERED semantics: the fixture's nonce row has no
# need_answered_at at all and is one of the 3. Pin it, because 'add the missing
# guard' to both arms would silently drop it and RAISE the published number.
nonce_off="$(sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM tasks
   WHERE status='done' AND kind='standard' AND human_nonce_hash IS NOT NULL
     AND need_answered_at IS NULL;")"
[ "$nonce_off" = 1 ] && [ "$got_ask" = 3 ] \
  && ok_t "a delivered-but-UNANSWERED nonce gate still counts (conservative, unguarded)" \
  || bad_t "the nonce arm must keep its delivered semantics" "unanswered-nonce rows=$nonce_off asks=$got_ask"

# --- DIVE-3227: fixture rows are excluded, COUNTED, and the rule is anchored --
# The two fixture rows above are already netted out of the 11/3/72.7 asserted
# above — an exclusion that moved those numbers would have failed there. Here we
# pin the count that must travel WITH the number (a silent filter on a published
# metric is the same defect class as the inflation it removes).
got_fx="$(jq -r '.fixturesExcluded' <<<"$led")"
[ "$got_fx" = 2 ] \
  && ok_t "fixturesExcluded reports what the filter removed (2)" \
  || bad_t "fixturesExcluded" "got $got_fx"
[ "$got_ship" = 11 ] \
  && ok_t "shipped nets out fixture-shaped rows (11, not 13)" \
  || bad_t "fixture rows must not count as shipped" "got $got_ship"

# ANCHORING, in both directions and in ONE fixture db so the counts are exact:
# a row whose title merely CONTAINS the words must still count as shipped —
# DIVE-3227's own title contains them while reporting the bug, and a substring
# rule would delete the bug report from the ledger.
export TASKS_DB="$TMP/anchor.db"
sqlite3 "$TASKS_DB" <<'SQL'
CREATE TABLE tasks (status TEXT, kind TEXT, need_type TEXT, need_answered_by TEXT, need_answered_uid INTEGER, human_nonce_hash TEXT, need_answered_at TEXT, title TEXT);
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'the badge counts stamp arm % rows as shipped work');
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'stamp arm C');
SQL
led_a="$(_proof_ledger)"
[ "$(jq -r '.shipped' <<<"$led_a")" = 1 ] && [ "$(jq -r '.fixturesExcluded' <<<"$led_a")" = 1 ] \
  && ok_t "prefix-anchored: a title that CONTAINS the words still ships (1 kept, 1 excluded)" \
  || bad_t "anchoring" "$led_a"

# The predicate escapes LIKE metacharacters and carries ESCAPE, so a prefix is
# matched literally. Asserted on the generated SQL because no prefix in the
# shipped list contains one yet — this is what stops the next prefix widening the
# rule silently.
_pex="$(five_fixture_title_sql exclude)"; _pma="$(five_fixture_title_sql match)"
case "$_pex$_pma" in
  *"NOT LIKE"*"ESCAPE"*) ok_t "predicate carries NOT LIKE + ESCAPE (literal prefixes)" ;;
  *) bad_t "predicate form" "exclude=$_pex match=$_pma" ;;
esac
case "$(five_fixture_title_sql bogus-mode 2>/dev/null; echo "rc=$?")" in
  "0rc=1") ok_t "an unknown mode fails closed (prints 0, rc 1) — never a match-all" ;;
  *) bad_t "unknown mode must fail closed" "$(five_fixture_title_sql bogus-mode 2>/dev/null; echo "rc=$?")" ;;
esac

# --- empty board: shipped 0, null pct, no divide-by-zero --------------------
export TASKS_DB="$TMP/empty.db"
sqlite3 "$TASKS_DB" 'CREATE TABLE tasks (status TEXT, kind TEXT, need_type TEXT, need_answered_by TEXT, need_answered_uid INTEGER, human_nonce_hash TEXT, need_answered_at TEXT, title TEXT);'
led2="$(_proof_ledger)"
[ "$(jq -r '.shipped' <<<"$led2")" = 0 ] && ok_t "empty board: shipped 0" || bad_t "empty shipped" "$led2"
[ "$(jq -r '.autonomyPct' <<<"$led2")" = null ] && ok_t "empty board: null pct (no div0)" || bad_t "empty pct" "$led2"

# --- 100% autonomy: all clean, no asks --------------------------------------
export TASKS_DB="$TMP/clean.db"
sqlite3 "$TASKS_DB" <<'SQL'
CREATE TABLE tasks (status TEXT, kind TEXT, need_type TEXT, need_answered_by TEXT, need_answered_uid INTEGER, human_nonce_hash TEXT, need_answered_at TEXT, title TEXT);
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'ship a real thing');
INSERT INTO tasks VALUES ('done','standard',NULL,NULL,NULL,NULL,NULL,'ship a real thing');
SQL
led3="$(_proof_ledger)"
[ "$(jq -r '.autonomyPct' <<<"$led3")" = 100 ] && ok_t "all-clean board: 100% autonomy" || bad_t "100pct" "$led3"

echo
echo "proof_ledger_unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
