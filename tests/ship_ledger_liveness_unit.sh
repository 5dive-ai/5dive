#!/usr/bin/env bash
# DIVE-2129 unit: the ship-ledger LIVENESS probe — 0 rows is VACUOUS until a push
# crosses the rail post-arming.
#
# What this grades, and why each case exists. The probe's whole job is to refuse to
# report a number it has not earned, so this harness is weighted toward the two
# FALSE readings that motivated the ticket:
#
#   FALSE PASS   — an unexercised instrument renders identically to a healthy one.
#                  DIVE-1923 closed saying "no row after the fleet rolls is a real
#                  signal"; measured, there had been ZERO pushes since arming, so
#                  the watch would have fired on nothing. Cases 2/3/9 are that.
#   FALSE BROKEN — a refused push never reaches the writer. 519 of 528 audit push
#                  rows on the origin host were `error`, one of them a refused push
#                  of DIVE-1923 itself. Counting them alarms on a healthy rail.
#                  Case 8 is that, and it is a NEGATIVE CONTROL, not a nicety.
#
# And the two structural properties that make the verdict mean anything:
#
#   THE DENOMINATOR NEVER COMES FROM ship_events (case 9). A check that counted
#   pushes from the table under test would be 0/0 self-certifying forever.
#   ARMING READS THE ARTIFACT, NOT A VERSION STRING (cases 1, 12). Case 12 is the
#   self-match control: the probe's own source names the symbols it greps for, so
#   a pattern that could match its own text would arm the probe by existing.
#
# Isolated: temp bundle, temp audit log, temp sqlite store, a stub `journalctl` on
# PATH, temp sticky record. No prod DB, no root, no network, and it NEVER writes a
# ship_events row — seeding the ledger is the one thing DIVE-1923 exists to prevent.
#   bash tests/ship_ledger_liveness_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
SRC=src
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh cmd_selfcheck.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 absent"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sll-unit.XXXXXX") || exit 2
mkdir -p "$TMP/bin"
PATH="$TMP/bin:$PATH"

# ── the stub journal ──────────────────────────────────────────────────────────
# Witness B is sudo's own sink, a DIFFERENT writer to a DIFFERENT file. The stub is
# driven by two knobs so "recording but saw no push" and "not recording at all" are
# separable — which is the entire point of constraint 4 and cannot be tested with a
# single on/off.
cat > "$TMP/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
[[ "${STUB_JOURNAL:-ok}" == "unreadable" ]] && exit 1
i=0; while (( i < ${STUB_JOURNAL_NOISE:-0} )); do echo "Aug 09 20:00:00 box systemd[1]: noise $i"; i=$((i+1)); done
i=0; while (( i < ${STUB_JOURNAL_PUSH:-0} )); do
  echo "Aug 09 20:0$i:00 box sudo[1000]:     root : PWD=/x ; USER=root ; COMMAND=/usr/local/bin/5dive _push_do"; i=$((i+1)); done
exit 0
STUB
chmod +x "$TMP/bin/journalctl"

ARMED_EPOCH=1754700000                       # 2026-08-09 01:20:00Z, the arming stamp
ARMED_SQL=$(date -u -d "@$ARMED_EPOCH" '+%Y-%m-%d %H:%M:%S')
BEFORE_ISO=$(date -u -d "@$((ARMED_EPOCH-3600))" '+%Y-%m-%dT%H:%M:%S+00:00')
AFTER_ISO=$(date -u -d "@$((ARMED_EPOCH+3600))" '+%Y-%m-%dT%H:%M:%S+00:00')
AFTER_SQL=$(date -u -d "@$((ARMED_EPOCH+3600))" '+%Y-%m-%d %H:%M:%S')

mk_bundle() { # mk_bundle <path> <armed:1|0> [epoch]
  if [[ "$2" == 1 ]]; then
    { echo '#!/usr/bin/env bash'
      echo 'ship_ledger_record() { :; }'
      echo '_push_record_ship_ledger() { :; }'; } > "$1"
  else
    # Names the symbols the way the PROBE'S OWN SOURCE does — indented, quoted,
    # inside prose. An unanchored grep would arm on this. That is case 12.
    { echo '#!/usr/bin/env bash'
      echo "  # calls ship_ledger_record and _push_record_ship_ledger one day"
      echo "  grep -q '^ship_ledger_record()' \"\$b\" && grep -q '^_push_record_ship_ledger()' \"\$b\""; } > "$1"
  fi
  touch -d "@${3:-$ARMED_EPOCH}" "$1"
}

mk_audit() { # mk_audit <path> <spec...>  spec = cmd:result:when(before|after)
  : > "$1"
  local s cmd res when ts
  for s in "${@:2}"; do
    IFS=: read -r cmd res when <<<"$s"
    [[ "$when" == before ]] && ts="$BEFORE_ISO" || ts="$AFTER_ISO"
    printf '{"ts":"%s","user":"agent-dev","cmd":"%s","result":"%s","code":0,"args":["DIVE-2129"]}\n' \
      "$ts" "$cmd" "$res" >> "$1"
  done
}

mk_db() { # mk_db <path> <ship_rows_after_arming> [--no-table]
  rm -f "$1"
  [[ "${3:-}" == "--no-table" ]] && { sqlite3 "$1" "CREATE TABLE other(x);" ; return; }
  sqlite3 "$1" "CREATE TABLE ship_events (id INTEGER PRIMARY KEY, kind TEXT, actor TEXT, ident TEXT, repo TEXT, branch TEXT, sha TEXT, reverts TEXT, self INT, ts TEXT DEFAULT (datetime('now')));"
  local i=0
  while (( i < $2 )); do
    sqlite3 "$1" "INSERT INTO ship_events (kind,sha,ts) VALUES ('ship','sha$i','$AFTER_SQL');"; i=$((i+1))
  done
}

# run <name> — dispatch the probe under the current fixture env; sets V/R/D
run() {
  local line
  line=$(SELFCHECK_SLL_BUNDLE="$BUNDLE" AUDIT_LOG="$AUDITLOG" TASKS_DB="$DB" \
         SELFCHECK_SLL_STATE="$STATE" \
         STUB_JOURNAL="${STUB_JOURNAL:-ok}" STUB_JOURNAL_PUSH="${STUB_JOURNAL_PUSH:-0}" \
         STUB_JOURNAL_NOISE="${STUB_JOURNAL_NOISE:-0}" \
         _sc_probe_ship_ledger_liveness 2>/dev/null | tail -1)
  V="${line%%|*}"; local rest="${line#*|}"; R="${rest%%|*}"; D="${rest#*|}"
}
expect() { # expect <case> <verdict> <reason-or-empty>
  if [[ "$V" == "$2" && ( -z "$3" || "$R" == "$3" ) ]]; then ok_t "$1"
  else fail_t "$1 (wanted verdict='$2' reason='${3:-*}', got verdict='$V' reason='$R'; detail=$D)"; fi
}

BUNDLE="$TMP/5dive"; AUDITLOG="$TMP/audit.log"; DB="$TMP/tasks.db"; STATE="$TMP/sticky.state"

# ── 1. an UNARMED bundle is not-reached, never a pass ─────────────────────────
mk_bundle "$BUNDLE" 0; mk_audit "$AUDITLOG" push:ok:after; mk_db "$DB" 0
STUB_JOURNAL_PUSH=1 STUB_JOURNAL_NOISE=5 run
expect "an unarmed bundle -> not-reached(not-armed), NOT a pass over an empty ledger" not-reached not-armed

# ── 12. the self-match control: prose naming the symbols must NOT arm ─────────
grep -q 'ship_ledger_record' "$BUNDLE" \
  && ok_t "the unarmed fixture DOES contain the symbol name (so case 1 proves anchoring, not absence)" \
  || fail_t "the unarmed fixture lost the symbol name — case 1 no longer grades the anchor"

# ── 2. armed, both witnesses recording, ZERO pushes -> the honest NOT-REACHED ──
mk_bundle "$BUNDLE" 1; mk_audit "$AUDITLOG" task:ok:after push:ok:before; mk_db "$DB" 0
STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=5 run
expect "no post-arming push, both sinks recording -> not-reached(no-post-arming-push)" not-reached no-post-arming-push
grep -q 'NOT-REACHED' <<<"$D" && ok_t "the detail speaks the ticket's vocabulary (NOT-REACHED)" \
                              || fail_t "detail does not say NOT-REACHED: $D"

# ── 3. constraint 4: an EMPTY count from a sink with no rows at all is untrusted ─
mk_audit "$AUDITLOG" task:ok:before; mk_db "$DB" 0
STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=5 run
expect "audit sink silent since arming -> not-reached(denominator-source-unproven)" not-reached denominator-source-unproven
mk_audit "$AUDITLOG" task:ok:after
STUB_JOURNAL=unreadable STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=0 run
expect "journal sink unreadable -> not-reached(denominator-source-unproven)" not-reached denominator-source-unproven

# ── 4. LIVE: post-arming pushes on BOTH witnesses + rows in the same window ────
mk_audit "$AUDITLOG" push:ok:after task:ok:after; mk_db "$DB" 3
STUB_JOURNAL_PUSH=1 STUB_JOURNAL_NOISE=5 run
expect "post-arming push + rows -> pass" pass ""
grep -q 'LIVE' <<<"$D" && ok_t "the pass names LIVE and is not silent about what it observed" \
                       || fail_t "pass detail does not say LIVE: $D"

# ── 5. BROKEN: corroborated pushes, ZERO rows. The only alarming state ────────
rm -f "$STATE"; mk_db "$DB" 0
STUB_JOURNAL_PUSH=1 STUB_JOURNAL_NOISE=5 run
expect "corroborated post-arming push + zero rows -> fail" fail ""
grep -q 'BROKEN' <<<"$D" && ok_t "the fail names BROKEN" || fail_t "fail detail does not say BROKEN: $D"
grep -q '^broken_at=' "$STATE" && ok_t "the BROKEN is written down (constraint 3 prerequisite)" \
                               || fail_t "no broken_at persisted: $(cat "$STATE" 2>/dev/null)"

# ── 6. constraint 3: the alarm SURVIVES a new arming epoch ────────────────────
# A nightly roll moves the bundle's mtime, so the window resets and this box sees
# no traffic. Without stickiness that reads as a fresh, blameless not-reached.
NEW_EPOCH=$(date -u +%s)
mk_bundle "$BUNDLE" 1 "$NEW_EPOCH"; mk_audit "$AUDITLOG" task:ok:before; : > "$AUDITLOG"
printf '{"ts":"%s","user":"u","cmd":"task","result":"ok","code":0,"args":[]}\n' \
  "$(date -u -d "@$((NEW_EPOCH+1))" '+%Y-%m-%dT%H:%M:%S+00:00')" > "$AUDITLOG"
STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=5 run
expect "a new arming epoch with no traffic still reports the earlier BROKEN" fail ""
grep -q 'sticky' <<<"$D" && ok_t "the sticky fail says WHY it is still failing" \
                         || fail_t "sticky fail does not name itself: $D"

# ── 7. and a later LIVE clears it, so the alarm is not permanent ──────────────
printf '{"ts":"%s","user":"u","cmd":"push","result":"ok","code":0,"args":[]}\n' \
  "$(date -u -d "@$((NEW_EPOCH+2))" '+%Y-%m-%dT%H:%M:%S+00:00')" >> "$AUDITLOG"
sqlite3 "$DB" "INSERT INTO ship_events (kind,sha,ts) VALUES ('ship','sX','$(date -u -d "@$((NEW_EPOCH+2))" '+%Y-%m-%d %H:%M:%S')');"
STUB_JOURNAL_PUSH=1 STUB_JOURNAL_NOISE=5 run
expect "a LIVE at-or-after the BROKEN clears the sticky alarm" pass ""
grep -q 'clears the sticky' <<<"$D" && ok_t "the clearing pass says which alarm it cleared" \
                                    || fail_t "pass did not name the cleared alarm: $D"
: > "$AUDITLOG"
printf '{"ts":"%s","user":"u","cmd":"task","result":"ok","code":0,"args":[]}\n' \
  "$(date -u -d "@$((NEW_EPOCH+3))" '+%Y-%m-%dT%H:%M:%S+00:00')" > "$AUDITLOG"
STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=5 run
expect "after clearing, a quiet window is not-reached again (the alarm is not permanent)" not-reached no-post-arming-push

# ── 8. NEGATIVE CONTROL — constraint 2: a REFUSED push must not alarm ─────────
rm -f "$STATE"; mk_bundle "$BUNDLE" 1; mk_db "$DB" 0
mk_audit "$AUDITLOG" push:error:after push:error:after task:ok:after
STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=5 run
expect "post-arming push rows that all FAILED do not manufacture a BROKEN" not-reached no-post-arming-push

# ── 9. NEGATIVE CONTROL — constraint 1: the denominator is never ship_events ──
mk_db "$DB" 9
STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=5 run
expect "9 ledger rows and no witnessed push is STILL not-reached (rows cannot certify themselves)" not-reached no-post-arming-push

# ── 10. disagreement is its own reason, never a silent preference ─────────────
mk_db "$DB" 0; mk_audit "$AUDITLOG" push:ok:after task:ok:after
STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=5 run
expect "one witness sees traffic, its recording partner sees none, ledger empty -> witness-disagreement" not-reached witness-disagreement

# ── 11. and an UNCORROBORATED positive is not an alarm either ─────────────────
STUB_JOURNAL=unreadable STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=0 run
expect "a lone positive with no live partner -> uncorroborated-denominator, not BROKEN" not-reached uncorroborated-denominator

# ── 13. a missing ship_events table with real traffic is BROKEN, and says so ──
mk_db "$DB" 0 --no-table; mk_audit "$AUDITLOG" push:ok:after task:ok:after
STUB_JOURNAL_PUSH=1 STUB_JOURNAL_NOISE=5 run
expect "traffic + no ship_events table -> fail" fail ""
grep -q 'table does not exist' <<<"$D" && ok_t "the fail names the absent table rather than reporting a bare zero" \
                                       || fail_t "fail does not name the missing table: $D"

# ── 14. an unreadable ledger is not-reached, never a BROKEN ──────────────────
# Fresh sticky record from here on: case 13 legitimately raised an alarm, and an
# OUTSTANDING alarm correctly outranks everything below it (that is case 6). Reusing
# the file would grade the sticky path a third time instead of what these cases say.
rm -f "$STATE"
mk_db "$DB" 0; DB_SAVE="$DB"; DB="$TMP/nope.db"
STUB_JOURNAL_PUSH=1 STUB_JOURNAL_NOISE=5 run
expect "an absent ledger store -> not-reached(ledger-unreadable), never an alarm" not-reached ledger-unreadable
DB="$DB_SAVE"

# ── 15. a non-UTC timestamp is reported, not silently lexically compared ──────
rm -f "$STATE"; mk_db "$DB" 0; : > "$AUDITLOG"
printf '{"ts":"%s","user":"u","cmd":"push","result":"ok","code":0,"args":[]}\n' \
  "$(date -u -d "@$((ARMED_EPOCH+3600))" '+%Y-%m-%dT%H:%M:%S+05:30')" > "$AUDITLOG"
STUB_JOURNAL_PUSH=0 STUB_JOURNAL_NOISE=5 run
expect "a non-UTC audit ts leaves the audit witness unproven rather than lexically miscounted" not-reached denominator-source-unproven
grep -q 'mixed-offset' <<<"$D" && ok_t "the unproven witness names mixed-offset as the cause" \
                               || fail_t "cause not named: $D"

# ── 16. a malformed line must not truncate the stream (and shrink the denominator) ─
mk_audit "$AUDITLOG" push:ok:after
sed -i '1i {"ts":"broken' "$AUDITLOG"
printf '{"ts":"%s","user":"u","cmd":"task","result":"ok","code":0,"args":[]}\n' "$AFTER_ISO" >> "$AUDITLOG"
mk_db "$DB" 2; STUB_JOURNAL_PUSH=1 STUB_JOURNAL_NOISE=5 run
expect "one malformed audit line does not abort the count and hide the traffic" pass ""

# ── 17. the probe is registered everywhere the runner reads ──────────────────
printf '%s\n' "${SELFCHECK_PROBES[@]}" | grep -qx ship-ledger-liveness \
  && ok_t "ship-ledger-liveness is in SELFCHECK_PROBES (so --list, the report header and the union all see it)" \
  || fail_t "probe missing from SELFCHECK_PROBES"
[[ "$(_sc_title ship-ledger-liveness)" != "ship-ledger-liveness" ]] \
  && ok_t "the probe has a title, so a run says what it asserts" || fail_t "no title registered"
d=$(_sc_dispatch ship-ledger-liveness 2>/dev/null | tail -1)
[[ "$d" == error* ]] && fail_t "dispatch does not route ship-ledger-liveness ($d)" \
                     || ok_t "the dispatcher routes ship-ledger-liveness"

# ── 18. it NEVER writes to the ledger ────────────────────────────────────────
before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM ship_events;" 2>/dev/null)
STUB_JOURNAL_PUSH=1 STUB_JOURNAL_NOISE=5 run
after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM ship_events;" 2>/dev/null)
[[ "$before" == "$after" ]] && ok_t "the probe seeds nothing — ship_events is unchanged across a run ($before)" \
                            || fail_t "the probe MUTATED the ledger ($before -> $after) — the exact corruption DIVE-1923 exists to prevent"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
