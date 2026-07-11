#!/usr/bin/env bash
# DIVE-1127 isolated unit harness for the ID/age-verification tripwire.
#
# Same isolation contract as supervisor_unit.sh / loop_*_unit.sh: sources src/
# libs directly and points STATE_DIR at a throwaway temp dir so it NEVER touches
# the live shared tasks.db. Asserts the false-positive-critical signature match
# (_sup_verify_match) and the alert dedup query against a seeded audit trail.
# The regex is the whole ballgame here: a false positive pings lodar, and this
# very task's title ("...ID/age-verification tripwire") is a benign string that
# MUST NOT trip it. Run: bash tests/verify_tripwire_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/verify-tripwire-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
# shellcheck source=/dev/null
source "$SRC/cmd_supervisor.sh"
tasks_db_init

PASS=0; FAIL=0
t() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}
# match-nonempty / match-empty helpers: run text through _sup_verify_match and
# assert it did / did not trip (we compare emptiness, not the exact excerpt).
hit()  { [[ -n "$(printf '%s\n' "$1" | _sup_verify_match)" ]] && echo tripped || echo clean; }

# --- POSITIVES: a challenge DIRECTED at the user must trip -------------------
t "verify your identity"       "tripped" "$(hit 'Please verify your identity to continue using Claude')"
t "verify your age"            "tripped" "$(hit 'Verify your age to access this feature')"
t "confirm your identity"      "tripped" "$(hit 'We need to confirm your identity before proceeding')"
t "government-issued ID"       "tripped" "$(hit 'Upload a government-issued photo ID')"
t "you must verify"            "tripped" "$(hit 'You must verify your account to keep going')"
t "over 18 age gate"           "tripped" "$(hit 'Please verify that you are over 18 years old')"
t "age-restricted phrasing"    "tripped" "$(hit 'This account is age-restricted pending review')"
t "trips on any line in block" "tripped" "$(hit $'some normal output\nmore output\nPlease verify your identity now')"

# --- NEGATIVES: benign strings must stay clean (no lodar ping) --------------
# The task's OWN title is the canonical false-positive trap — a bare
# "age-verification" noun phrase, not a directive.
t "this task's title (age-verification noun)" "clean" \
  "$(hit 'DIVE-1127 ToS-hedge A2: ID/age-verification tripwire - fleet watcher')"
t "generic verification challenge noun"        "clean" "$(hit 'working on the verification challenge task')"
t "verify the fix"                             "clean" "$(hit 'let me verify the fix works end to end')"
t "verification tests"                         "clean" "$(hit '39/39 verification tests passed')"
t "identity of the caller (code talk)"         "clean" "$(hit 'we assert the identity of the caller matches')"
t "empty pane"                                 "clean" "$(hit '')"

# --- env override: SUPERVISOR_VERIFY_PAT retunes without a release ----------
( export SUPERVISOR_VERIFY_PAT='banana-challenge'
  # re-source so the constant picks up the override
  source "$SRC/cmd_supervisor.sh"
  out=$([[ -n "$(printf '%s\n' 'here is a banana-challenge line' | _sup_verify_match)" ]] && echo tripped || echo clean)
  base=$([[ -n "$(printf '%s\n' 'Please verify your identity' | _sup_verify_match)" ]] && echo tripped || echo clean)
  [[ "$out" == "tripped" && "$base" == "clean" ]] && echo ok || echo bad
) > "$TMP/envout"
t "SUPERVISOR_VERIFY_PAT override replaces the default pattern" "ok" "$(cat "$TMP/envout")"

# --- alert dedup: one alert per account per _SUP_ALERT_WINDOW_H --------------
# Seed a recent alert row for agent 'oleg', a stale one for 'nadia' (outside the
# window). The dedup query should count oleg's (>0 -> skip) and not nadia's.
db "INSERT INTO supervisor_events (ts, agent, event, classification, cause)
    VALUES (datetime('now','-1 hours'), 'oleg', 'alert', 'verify-challenge', 'id-verification');"
db "INSERT INTO supervisor_events (ts, agent, event, classification, cause)
    VALUES (datetime('now','-48 hours'), 'nadia', 'alert', 'verify-challenge', 'id-verification');"
dedup_count() { # <agent>
  db "SELECT COUNT(*) FROM supervisor_events
      WHERE agent=$(sqlq "$1") AND event='alert'
        AND ts >= datetime('now', '-${_SUP_ALERT_WINDOW_H} hours');"
}
t "recent alert dedups (oleg counted)"          "1" "$(dedup_count oleg)"
t "stale alert past window ignored (nadia 0)"   "0" "$(dedup_count nadia)"
t "never-alerted account is 0 (fresh)"          "0" "$(dedup_count marcus)"

echo ""
echo "verify-tripwire unit: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
