#!/usr/bin/env bash
# TIER: core
#
# DIVE-2693 — the recurring-instance stall sweep's PREDICATE.
#
# What this grades and why it is a predicate test rather than an end-to-end one:
# the sweep's whole value is which rows it selects. Everything after the SELECT is
# two cmd_send calls and an UPDATE, and booting a heartbeat to observe those costs
# a registry, a tmux pane and a clock. The selection is the part that can be wrong
# in a way nobody notices — a stall sweep that silently selects nothing looks
# exactly like a fleet with no stalls, which is the defect this row exists to fix.
#
# THE QUERY IS EXTRACTED FROM THE SOURCE, NOT RETYPED. A retyped copy grades a
# query that no longer exists the moment someone edits the real one, and it would
# keep passing while doing so. Same reasoning as tests that derive a table from its
# call sites instead of pinning a literal.
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_heartbeat.sh"

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '   %s\n' "$2"; FAIL=$((FAIL+1)); }

command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DB="$TMP/t.db"

# ---------------------------------------------------------------------------
# 1. EXTRACT the live predicate. If this fails the test fails loudly rather than
#    falling back to a hand-copy — a fallback here would silently grade nothing.
# ---------------------------------------------------------------------------
QUERY=$(awk '/SELECT t\.id\|\|x.1f.\|\|COALESCE\(t\.ident/,/hours.\);"\)/' "$SRC" \
        | sed -e 's/^ *//' -e '1s/^.*db "//' -e 's/;")$/;/')
if [[ -z "$QUERY" || "$QUERY" != *"from_template_id"* ]]; then
  bad_t "extract the live predicate from $SRC" "awk matched nothing, or the match does not mention from_template_id — the sweep query moved or was renamed; this test is now blind and must be re-anchored, NOT deleted"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi
ok_t "the sweep's SELECT is extracted from cmd_heartbeat.sh, not retyped here"

# The threshold is interpolated by the shell in the real caller; bind the default.
QUERY="${QUERY//\$\{_HB_RECURRING_STALL_HOURS\}/24}"
case "$QUERY" in
  *'${'*) bad_t "predicate has no unbound shell expansions left" "still contains \${...}: $QUERY" ;;
  *)      ok_t  "predicate has no unbound shell expansions left" ;;
esac

# ---------------------------------------------------------------------------
# 2. Fixture. One row per behaviour, each differing from the SURFACED row in
#    exactly one column, so a red arm names its own cause.
# ---------------------------------------------------------------------------
sqlite3 "$DB" <<'SQL'
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY, ident TEXT, title TEXT, status TEXT, assignee TEXT,
  kind TEXT NOT NULL DEFAULT 'standard', created_at TEXT, started_at TEXT,
  from_template_id INTEGER, parked_at TEXT, need_type TEXT, need_answered_at TEXT,
  recurring_stall_pinged_at TEXT, schedule TEXT
);
-- the template itself
INSERT INTO tasks (id,ident,status,kind,schedule,created_at) VALUES
  (100,'DIVE-1237','todo','recurring','0 4 * * *',datetime('now','-30 days'));
-- SURFACED: never-started instance, older than the window
INSERT INTO tasks (id,ident,status,kind,assignee,created_at,from_template_id) VALUES
  (1,'DIVE-2403','todo','standard','dev',datetime('now','-5 days'),100);
-- NOT surfaced, one column different each:
INSERT INTO tasks (id,ident,status,kind,assignee,created_at,from_template_id) VALUES
  (2,'DIVE-2694','todo','standard','dev',datetime('now','-1 hours'),100);      -- too young
INSERT INTO tasks (id,ident,status,kind,assignee,created_at,started_at,from_template_id) VALUES
  (3,'DIVE-2695','todo','standard','dev',datetime('now','-5 days'),datetime('now','-4 days'),100); -- started
INSERT INTO tasks (id,ident,status,kind,assignee,created_at,from_template_id) VALUES
  (4,'DIVE-2696','todo','standard','dev',datetime('now','-5 days'),NULL);      -- not from a template
INSERT INTO tasks (id,ident,status,kind,assignee,created_at,from_template_id,recurring_stall_pinged_at) VALUES
  (5,'DIVE-2697','todo','standard','dev',datetime('now','-5 days'),100,datetime('now','-1 days')); -- already pinged
INSERT INTO tasks (id,ident,status,kind,assignee,created_at,from_template_id,parked_at) VALUES
  (6,'DIVE-2698','todo','standard','dev',datetime('now','-5 days'),100,datetime('now','-2 days')); -- parked
INSERT INTO tasks (id,ident,status,kind,assignee,created_at,from_template_id,need_type) VALUES
  (7,'DIVE-2699','todo','standard','dev',datetime('now','-5 days'),100,'decision'); -- open human gate
INSERT INTO tasks (id,ident,status,kind,assignee,created_at,from_template_id) VALUES
  (8,'DIVE-2700','done','standard','dev',datetime('now','-5 days'),100);       -- closed
SQL

run_predicate() { sqlite3 "$DB" "$(printf '%s' "$QUERY")" 2>/dev/null | cut -d$'\x1f' -f2 | sort | tr '\n' ' '; }

GOT=$(run_predicate)
if [[ "$GOT" == "DIVE-2403 " ]]; then
  ok_t "surfaces EXACTLY the never-started, over-age recurring instance"
else
  bad_t "surfaces EXACTLY the never-started, over-age recurring instance" "got: [$GOT] want: [DIVE-2403 ]"
fi

# Each exclusion asserted by NAME, so a future predicate that drops one arm reds
# the arm that owns it rather than one uninformative aggregate.
for spec in "DIVE-2694:younger than the window" \
            "DIVE-2695:already started" \
            "DIVE-2696:not materialized from a template" \
            "DIVE-2697:already surfaced once (no re-ping)" \
            "DIVE-2698:parked with a wake date" \
            "DIVE-2699:blocked on an unanswered human gate" \
            "DIVE-2700:already closed" \
            "DIVE-1237:the recurring TEMPLATE itself"; do
  id="${spec%%:*}"; why="${spec#*:}"
  case " $GOT " in
    *" $id "*) bad_t "excludes $id — $why" "it was surfaced; got: [$GOT]" ;;
    *)         ok_t  "excludes $id — $why" ;;
  esac
done

# ---------------------------------------------------------------------------
# 3. NON-VACUITY. Every exclusion above also passes on a predicate that returns
#    NOTHING, so they cannot distinguish "correctly filtered" from "broken and
#    silent". This arm is what makes the eight above mean anything.
# ---------------------------------------------------------------------------
if [[ -n "${GOT// /}" ]]; then
  ok_t "ANCHOR: the predicate returns a non-empty set (the exclusions are not vacuous)"
else
  bad_t "ANCHOR: the predicate returns a non-empty set" "empty result — every exclusion arm above is passing for free"
fi

# ---------------------------------------------------------------------------
# 4. MUTATION. Drop the started_at conjunct and row 3 must appear. Asserts the
#    mutation APPLIED before trusting the arm — a no-op mutant is otherwise
#    indistinguishable from a killed one.
# ---------------------------------------------------------------------------
MUT="${QUERY/AND t.started_at IS NULL/}"
if [[ "$MUT" == "$QUERY" ]]; then
  bad_t "MUTATION applies: the started_at conjunct is present to remove" "anchor 'AND t.started_at IS NULL' not found — the mutant reverted nothing and this arm graded NOTHING"
else
  MGOT=$(sqlite3 "$DB" "$(printf '%s' "$MUT")" 2>/dev/null | cut -d$'\x1f' -f2 | sort | tr '\n' ' ')
  case " $MGOT " in
    *" DIVE-2695 "*) ok_t "MUTATION: dropping the started_at conjunct lets the started row through (the conjunct is load-bearing)" ;;
    *)               bad_t "MUTATION: dropping the started_at conjunct lets the started row through" "got: [$MGOT] — the conjunct is NOT what excludes it, so the real cause is unknown" ;;
  esac
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
