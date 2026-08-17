#!/usr/bin/env bash
# TIER: core — the digest's BUZZ count (DIVE-3228).
#
# WHY THIS NUMBER EXISTS. The autonomy badge printed "asked you N×" built from
# need_answered_by LIKE 'human:%' — i.e. gates the human ANSWERED, wearing the
# asked count's name. On 2026-08-11 that read 6 while his phone rang 19 times.
# The structural half is worse than the arithmetic: withdrawing a gate archives it
# to gate_history and clears the need_* fields OFF the tasks row, and the digest
# reads tasks rows — so a withdrawal DELETES the evidence from the metric's input
# AFTER the buzz was sent. 21 of that day's 36 filings were invisible by
# construction, which is why a month of burn-control passes read a number trending
# fine and moved on.
#
# So the buzz count reads gate_cards, which survives the withdrawal, and a MINT is
# exactly one buzz — editing a Telegram message does not push.
#
# The arms that matter are the two that make it honest rather than merely present:
#   unknown-not-zero   a store with no gate_cards table answers UNKNOWN. "No table"
#                      and "no buzzes" must never share an answer — that is the
#                      absent-vs-forbidden rule this rail has been burned by.
#   partial            a window reaching back before the table existed under-reports,
#                      and an under-report presented as a total is the defect itself.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/digest-buzz.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_digest.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
chk() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}

# ---- the store cannot be read at all ---------------------------------------
# NOT "a store with no gate_cards table": _digest_buzz_count runs tasks_db_init,
# which CREATES the table, so that state cannot survive the call and testing for
# it would be testing a branch production never reaches. What the refuse path
# actually guards is a store that cannot be read — corrupt, locked, wrong file —
# and there the rule bites: unknown must not come back as 0, because a badge
# reading "buzzed your phone 0×" on an unreadable store is the same false calm
# the old ask-count gave for a month.
STATE_DIR="$TMP/broken"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
printf 'this is not a sqlite database, not even close\n' >"$TASKS_DB"
out=$(_digest_buzz_count 86400 2>/dev/null); rc=$?
chk "unreadable store: the helper REFUSES rather than answering 0" "1" "$rc"
chk "unreadable store: and prints nothing that could be read as a count" "" "$out"

# ---- a real, freshly migrated store -----------------------------------------
# A separate directory, never a `rm` over the previous one: the tasks store has a
# vanished-board guard (DIVE-1479) that correctly refuses to recreate a board it
# has seen before, and deleting the file mid-harness trips it.
STATE_DIR="$TMP/good"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate >/dev/null 2>&1
chk "precondition: the migration created gate_cards" "gate_cards" \
    "$(db "SELECT name FROM sqlite_master WHERE type='table' AND name='gate_cards';")"

# One card per TASK: the partial unique index allows a single live card per
# (task_id, chat_id), so four mints sharing task_id 1 would be four attempts to
# hold the same slot and three would be correctly refused. Caught by this harness
# reading 1 where it expected 4 — the invariant working, and a fixture that had
# quietly encoded "many live cards on one task", which is the thing it forbids.
mint() { # <task_id> <ident> <message_id> <minted_at-sql>
  db "INSERT INTO gate_cards (task_id,ident,gate_epoch,chat_id,message_id,via,state,minted_at)
      VALUES ($1,'$2',1,'123','$3','marketing','live',$4);" >/dev/null 2>&1
}

out=$(_digest_buzz_count 86400)
chk "an empty table counts 0 buzzes — and says the span is partial" "0|1" "$out"

# Three mints inside the window, one outside it.
mint 1 DIVE-B1  1 "datetime('now','-1 hours')"
mint 2 DIVE-B2  2 "datetime('now','-2 hours')"
mint 3 DIVE-B3  3 "datetime('now','-23 hours')"
mint 4 DIVE-OLD 4 "datetime('now','-40 hours')"
out=$(_digest_buzz_count 86400)
chk "counts only mints inside the rolling window" "3" "${out%%|*}"
chk "and the span is NOT partial once a mint predates the window" "0" "${out##*|}"

# A 7d window reaches back before the earliest mint, so it under-reports.
out=$(_digest_buzz_count 604800)
chk "a window wider than the table's history counts everything" "4" "${out%%|*}"
chk "...and is flagged PARTIAL, because a total it cannot cover is not a total" "1" \
    "${out##*|}"

# ---- a MINT is the buzz, not a card and not an edit -------------------------
# A superseded card was a real message that really rang the phone; retiring one
# does not un-ring it. Both must stay counted, or the metric reproduces exactly
# the blindness it was added to remove.
db "UPDATE gate_cards SET state='superseded' WHERE ident='DIVE-B1';" >/dev/null 2>&1
db "UPDATE gate_cards SET state='deleted' WHERE ident='DIVE-B2';" >/dev/null 2>&1
out=$(_digest_buzz_count 86400)
chk "a superseded or deleted card still counts (the buzz already happened)" "3" "${out%%|*}"

printf -- '-----\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
