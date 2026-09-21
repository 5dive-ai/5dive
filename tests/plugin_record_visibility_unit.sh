#!/usr/bin/env bash
# DIVE-4709 — a plugin record this SEAT cannot read is not an unknown command.
#
# The bug: `browser@5dive-plugins` was enabled box-wide on two customer boxes
# and two seats' probe units failed EVERY fire with `unknown command: browser`,
# exit 2/INVALIDARGUMENT, while every other seat on the same boxes probed fine.
# `_plugin_verb_claims` opens with `[[ -r "$f" ]] || return 0`, so a record the
# caller cannot READ declares nothing — identical, from the dispatcher, to a
# record that genuinely declares nothing. The dispatcher printed the typo's
# message, the connected-sites tile silently never updated, and an empty tile
# reads to a customer as "nothing is connected".
#
# Asserts:
#   - a healthy box is unchanged: no blocker, and an unclaimed verb stays QUIET
#   - an unreadable record is named, with the refusing path, at E_PERMISSION
#   - an unreadable DIRECTORY above the record is named instead of the file
#   - the pre-fix defect is still there underneath (_plugin_verb_claims empty)
#   - doctor reports a blinded seat as an ERROR and names it
#   - doctor reports an UNMEASURABLE privilege drop as UNKNOWN, never as clean
#   - the drop's positive control is what separates those two (fail-open guard)
# Run: bash tests/plugin_record_visibility_unit.sh (no root, no systemd, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-/nonexistent}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/plugin-record-visibility.XXXXXX)"
export AGENT_SHARED_GROUP="fivedive-test"
export ENV_DIR="$TMP/env"; mkdir -p "$ENV_DIR"

# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/cmd_plugin.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
# header.sh:14 is `set -euo pipefail`; the arms below grade refusals, so errexit
# here would take the harness down with the first one. Same reason, same fix, as
# tests/plugin_verb_dispatch_unit.sh.
set +e -o pipefail

require_root() { :; }

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
t()      { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }
tc()     { if [[ "$3" == *"$2"* ]]; then ok_t "$1"; else bad_t "$1" "expected to contain [$2], got [$3]"; fi; }
tn()     { if [[ "$3" != *"$2"* ]]; then ok_t "$1"; else bad_t "$1" "expected NOT to contain [$2], got [$3]"; fi; }

# ROOT BYPASSES MODE BITS, and that is the trap this file would otherwise walk
# into: as root `test -r` on a 0000 file is TRUE, so every permission arm below
# would report the healthy verdict and PASS for the wrong reason — the exact
# shape of failure the row is about. Under root they are declared UNMEASURED and
# counted, never silently skipped.
IS_ROOT=0; [[ ${EUID:-$(id -u)} -eq 0 ]] && IS_ROOT=1
unmeasured() { SKIP=$((SKIP+1)); printf 'UNMEASURED - %s (running as root: mode bits do not refuse root, so this arm cannot observe a blocked read)\n' "$1"; }

OUT=""; ERR=""; RC=0
run() { local o="$TMP/.o" e="$TMP/.e"; ( "$@" ) >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }

# ---- fixture: a real store with one enabled plugin declaring one verb --------
export STATE_DIR="$TMP/state"
REC="$STATE_DIR/plugins/installed.json"
PDIR="$STATE_DIR/plugins"
mkdir -p "$PDIR/enabled/probe@fixture/bin"
cat > "$PDIR/enabled/probe@fixture/bin/zz-probe" <<'ENTRY'
#!/usr/bin/env bash
echo "ENTRY-RAN"
ENTRY
chmod +x "$PDIR/enabled/probe@fixture/bin/zz-probe"
cat > "$REC" <<'JSON'
{"probe@fixture":{"enabled":true,"capabilities":["verb"],"verbs":[{"name":"zz-probe"}]}}
JSON
chmod 644 "$REC"

# ---- T1: the healthy box is unchanged ---------------------------------------
t "T1a healthy box: no blocker path" "" "$(_plugin_record_blocker_path)"
run _plugin_dispatch_verb zz-probe
tc "T1b healthy box: a declared verb still EXECS" "ENTRY-RAN" "$OUT"

# ---- T2: an absent record stays QUIET (the typo's path) ---------------------
( export STATE_DIR="$TMP/absent"; mkdir -p "$STATE_DIR"
  printf '%s\n' "$(_plugin_record_blocker_path)" > "$TMP/t2.blocker"
  _plugin_dispatch_verb zz-probe 2>"$TMP/t2.err"; echo $? > "$TMP/t2.rc" )
t  "T2a absent record: no blocker (nothing is installed, and that is not a refusal)" "" "$(cat "$TMP/t2.blocker")"
t  "T2b absent record: dispatch returns 1 so main() reaches 'unknown command'" "1" "$(cat "$TMP/t2.rc")"
t  "T2c absent record: dispatch stays SILENT (the quiet contract main() relies on)" "" "$(cat "$TMP/t2.err")"

# ---- T3: an unreadable record is named, not swallowed -----------------------
if (( IS_ROOT )); then
  unmeasured "T3 unreadable record"
else
  chmod 000 "$REC"
  t  "T3a unreadable record: the blocker is the record itself" "$REC" "$(_plugin_record_blocker_path)"
  # PRE-FIX CONTROL. The underlying defect is untouched — claims is still empty,
  # so this arm fails if someone "fixes" the row by making the read succeed and
  # leaves the dispatcher's silence in place for the next cause.
  t  "T3b pre-fix control: _plugin_verb_claims is STILL empty (the defect is intact underneath)" "" "$(_plugin_verb_claims zz-probe)"
  run _plugin_dispatch_verb zz-probe
  tc "T3c unreadable record: the refusal names the cause" "cannot read the box's plugin record" "$ERR"
  tc "T3d unreadable record: the refusal names the refusing path" "$REC" "$ERR"
  # The refusal QUOTES the phrase on purpose — it is the symptom the operator
  # arrived with — so the arm asserts the thing that matters: the verb is not
  # reported as unknown. Matching the bare phrase would grade the citation.
  tn "T3e unreadable record: the verb is NOT reported as an unknown command" "unknown command: zz-probe" "$ERR"
  tc "T3f unreadable record: it says this is not a missing install" "NOT a missing" "$ERR"
  t  "T3g unreadable record: exit is E_PERMISSION, not E_USAGE=2" "$E_PERMISSION" "$RC"
  # A typo on a BLINDED seat speaks too, and deliberately: on such a seat NO
  # plugin verb can resolve, so "unknown command" is never the true answer for
  # anything plugin-shaped, and the seat is broken in a way worth saying once.
  run _plugin_dispatch_verb definitely-not-a-verb
  tc "T3h a typo on a blinded seat reports the visibility gap, not the typo" "cannot read the box's plugin record" "$ERR"
  chmod 644 "$REC"
fi

# ---- T4: an untraversable DIRECTORY is named instead of the file ------------
if (( IS_ROOT )); then
  unmeasured "T4 untraversable plugins directory"
else
  chmod 000 "$PDIR"
  t  "T4a untraversable dir: the blocker is the DIRECTORY, not the unreachable file" "$PDIR" "$(_plugin_record_blocker_path)"
  run _plugin_dispatch_verb zz-probe
  tc "T4b untraversable dir: the refusal names the directory an operator must fix" "$PDIR" "$ERR"
  chmod 755 "$PDIR"
fi

# ---- doctor seams -----------------------------------------------------------
# Two real accounts is what this check needs on a box and what a unit suite must
# not require, so the privilege drop is its own function and is replaced here.
SEAT_ROWS=""; declare -A PROBE=()
plugin_seat_graded_rows() { printf '%s' "$SEAT_ROWS"; }
doctor_record_probe_as()  { printf '%s\n' "${PROBE[$1]:-READ}"; }

doctor_row() { # doctor_row <name> -> "<severity>|<message>"
  jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.severity)|\(.message)"' <<<"$DOCTOR_CHECKS"
}
reset_doctor() { DOCTOR_CHECKS='[]'; }

# ---- T5: every seat can read it -> ok ---------------------------------------
reset_doctor; SEAT_ROWS=$'mp\tclaude\nops\tclaude\n'; PROBE=()
doctor_check_plugin_record_visibility >/dev/null 2>&1
R="$(doctor_row record-visibility)"
t  "T5a all seats readable: ok" "ok" "${R%%|*}"
tc "T5b all seats readable: the ok line states how many it MEASURED" "all 2 graded seat(s)" "$R"

# ---- T6: a blinded seat is an ERROR and is named ----------------------------
reset_doctor; PROBE=([agent-mp]=BLOCKED)
doctor_check_plugin_record_visibility >/dev/null 2>&1
R="$(doctor_row record-visibility)"
t  "T6a a blinded seat is an error, not a warn" "error" "${R%%|*}"
tc "T6b the blinded seat is named" "1 of 2 seat(s) cannot read" "$R"
tc "T6c the finding names the seat" "mp" "$R"
tc "T6d the finding names the consequence, not just the state" "fails on every fire" "$R"
tc "T6e the finding names the fix" "gpasswd -a agent-<seat> fivedive-test" "$R"
tc "T6f the finding refuses the wrong remedy out loud" "Reinstalling the plugin does NOT fix this" "$R"

# ---- T7: an unmeasurable drop is UNKNOWN, never clean -----------------------
reset_doctor; PROBE=([agent-mp]=UNMEASURED)
doctor_check_plugin_record_visibility >/dev/null 2>&1
R="$(doctor_row record-visibility)"
t  "T7a an unmeasured seat is a warn" "warn" "${R%%|*}"
tc "T7b it says UNKNOWN in those words" "UNKNOWN for 1 of 2 seat(s)" "$R"
tn "T7c an unmeasured seat is NOT reported as blocked" "cannot read" "$R"

# A BLOCKED seat outranks an UNMEASURED one: a measured dead seat is not made
# less true by a second seat we could not measure.
reset_doctor; PROBE=([agent-mp]=BLOCKED [agent-ops]=UNMEASURED)
doctor_check_plugin_record_visibility >/dev/null 2>&1
t "T7d a measured BLOCKED seat outranks an unmeasured one" "error" "$(doctor_row record-visibility | cut -d'|' -f1)"

# ---- T8: no seat graded -> UNKNOWN, not ok ----------------------------------
reset_doctor; SEAT_ROWS=""; PROBE=()
doctor_check_plugin_record_visibility >/dev/null 2>&1
R="$(doctor_row record-visibility)"
t  "T8a zero graded seats is a warn, not a green bill of health" "warn" "${R%%|*}"
tc "T8b it says nothing was measured" "nothing was measured" "$R"

# ---- T9: nothing claims a verb -> ok, and says why --------------------------
reset_doctor; SEAT_ROWS=$'mp\tclaude\n'
cat > "$REC" <<'JSON'
{"skillonly@fixture":{"enabled":true,"capabilities":["skill"]}}
JSON
doctor_check_plugin_record_visibility >/dev/null 2>&1
R="$(doctor_row record-visibility)"
t  "T9a no verb-claiming plugin: ok" "ok" "${R%%|*}"
tc "T9b and it says what made it ok" "no enabled plugin declares a verb" "$R"

# ---- T10: the fail-open guard, graded on the REAL drop function -------------
# The projects rule this check would otherwise walk into: a privilege drop the
# sudoers policy DENIES exits non-zero exactly like a real negative, so BLOCKED
# inferred from a drop that never ran would report every seat on a hardened box
# as dead. The positive control is the only thing separating them — so grade it
# with a drop that always refuses, and with one that refuses only the record.
unset -f doctor_record_probe_as
# shellcheck disable=SC1091
source <(sed -n '/^doctor_record_probe_as() {/,/^}/p' src/cmd_doctor.sh)
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/runuser" <<'DROP'
#!/usr/bin/env bash
# argv: -u <user> -- test -r <path>
[[ -n "${DROP_DENY_ALL:-}" ]] && exit 1
path="${!#}"
[[ "$path" == "${DROP_REFUSES:-}" ]] && exit 1
exit 0
DROP
chmod +x "$FAKEBIN/runuser"
PATH="$FAKEBIN:$PATH"

t "T10a a drop that fails its own positive control reads UNMEASURED, not BLOCKED" \
  "UNMEASURED" "$(DROP_DENY_ALL=1 doctor_record_probe_as agent-mp "$REC")"
t "T10b a drop that works but cannot read the record reads BLOCKED" \
  "BLOCKED" "$(DROP_REFUSES="$REC" doctor_record_probe_as agent-mp "$REC")"
t "T10c a drop that works and can read the record reads READ" \
  "READ" "$(doctor_record_probe_as agent-mp "$REC")"

printf '\n%d pass, %d fail, %d unmeasured\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
