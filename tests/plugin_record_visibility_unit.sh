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
# DIVE-4730 adds:
#   - the repair doctor prescribes is keyed on the SEAT, not on the record: a
#     sandboxed seat gets the traverse-only ACL and is told NOT to join the
#     group; an unregistered one is named as an orphan; only a registered
#     non-sandboxed seat gets `gpasswd -a`
#   - an unreadable registry makes the class UNKNOWN, never a guessed repair
#   - blind `agent-*` accounts the registry does not know are graded at all
#     (the DIVE-4709 population was the registry, so box 10's blind seat could
#     not appear in it)
#   - --fix applies the sandboxed repair in place, and only that one
#   - the components the grant touches are exactly the non-o+x ancestors
#   - the seat-side message branches on what a blind seat can observe itself
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
source src/lib/registry.sh
# shellcheck disable=SC1091
source src/lib/plugin_seats.sh
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

# DIVE-4730 — header.sh froze REGISTRY from STATE_DIR at source time, before
# this file moved STATE_DIR into the fixture. Re-point it, or every agent_tier()
# below reads the real box.
REGISTRY="$STATE_DIR/agents.json"
cat > "$REGISTRY" <<'JSON'
{"agents":{"mp":{"type":"claude","isolation":"sandboxed"},
           "ops":{"type":"claude","isolation":"standard"}}}
JSON

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
# DIVE-4730 reverses this arm in place rather than deleting it. It used to pin
# the one flat prescription `gpasswd -a agent-<seat> fivedive-test`, and that is
# precisely the defect: `mp` is SANDBOXED in the fixture registry, so adding it
# to the shared group would dissolve the sandbox to fix a plugin verb. The arm
# still asserts "the finding names the fix" — it just asserts the right one.
tc "T6e the finding names the fix, and for a SANDBOXED seat that is the ACL" "setfacl -m u:agent-mp:--x" "$R"
tn "T6e2 and it does NOT send a sandboxed seat to the shared group" "gpasswd -a agent-mp" "$R"
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

# ---- T11: the repair is keyed on the SEAT (DIVE-4730) -----------------------
# T9 replaced the fixture with a skill-only record on purpose; restore the
# verb-claiming one, or every arm below returns at "no plugin declares a verb"
# and passes for having measured nothing.
cat > "$REC" <<'JSON'
{"probe@fixture":{"enabled":true,"capabilities":["verb"],"verbs":[{"name":"zz-probe"}]}}
JSON
t "T10d fixture restored: the record declares a verb again" "probe@fixture" "$(doctor_verb_claiming_plugins "$REC")"
# T10 replaced the seam with the REAL drop (graded against a fake `runuser`),
# and that fake answers READ for everything. Re-install the table-driven stub,
# or every arm below grades a box where no seat is blind at all.
doctor_record_probe_as() { printf '%s\n' "${PROBE[$1]:-READ}"; }
reset_doctor; SEAT_ROWS=$'mp\tclaude\nops\tclaude\n'; PROBE=([agent-mp]=BLOCKED)
doctor_check_plugin_record_visibility >/dev/null 2>&1
t "T10e seam restored: a BLOCKED seat is seen again" "error" "$(doctor_row record-visibility | cut -d'|' -f1)"

# The three classes have three different repairs and two of them are not group
# membership. Graded through doctor_record_repair_for so each class is one arm.
cls_of()  { doctor_record_repair_for "$1" "$REC" | cut -f1; }
sent_of() { doctor_record_repair_for "$1" "$REC" | cut -f2-; }

t  "T11a a sandboxed seat classifies as sandboxed" "sandboxed" "$(cls_of mp)"
tc "T11b and is told, in words, not to rejoin the group" "do NOT add it back" "$(sent_of mp)"
tc "T11c and is given the reverse of the grant it is handed"  "setfacl -x u:agent-mp" "$(sent_of mp)"
t  "T11d a registered non-sandboxed seat classifies as drift" "drift" "$(cls_of ops)"
tc "T11e and drift IS the case gpasswd repairs"   "gpasswd -a agent-ops fivedive-test" "$(sent_of ops)"
t  "T11f an account with no registry row classifies as orphan" "orphan" "$(cls_of ghost)"
tc "T11g and an orphan is reaped, not granted"    "doctor --category=registry --fix" "$(sent_of ghost)"
tn "T11h an orphan is never handed the credentials group" "gpasswd -a agent-ghost" "$(sent_of ghost)"

# THE FAIL-SHUT HALF, and it is the one that matters: a registry we could not
# read must not pick a repair. A sandboxed seat and a drifted one are
# indistinguishable without it and their repairs are opposites, so guessing here
# is worse than saying UNKNOWN.
( REGISTRY="$TMP/no-such-registry.json"
  printf '%s\n' "$(doctor_record_repair_for mp "$REC" | cut -f1)" > "$TMP/t11.cls"
  doctor_record_repair_for mp "$REC" | cut -f2- > "$TMP/t11.sent" )
t  "T11i an unreadable registry classifies as unmeasured, not as a guess" "unmeasured" "$(cat "$TMP/t11.cls")"
tc "T11j and it says the two repairs are opposites" "opposites" "$(cat "$TMP/t11.sent")"
tn "T11k and it prescribes NOTHING" "setfacl -m" "$(cat "$TMP/t11.sent")"

# ---- T12: the population the DIVE-4709 check could not contain --------------
# It graded plugin_seat_graded_rows, which is the REGISTRY. Box 10's blind seat
# was `agent-mp`, absent from the registry, so that box read GREEN while the
# seat had been blind for five days. A check whose population cannot contain the
# case it was written for is not evidence about that case.
doctor_orphan_passwd_users() { printf 'agent-ghost:/home/agent-ghost\nagent-mp:/home/agent-mp\n'; }
reset_doctor; SEAT_ROWS=$'mp\tclaude\nops\tclaude\n'; PROBE=([agent-ghost]=BLOCKED)
doctor_check_plugin_record_visibility >/dev/null 2>&1
R="$(doctor_row record-visibility-orphans)"
t  "T12a a blind unregistered account is reported at all" "warn" "${R%%|*}"
tc "T12b it is named"                                     "ghost" "$R"
tc "T12c it is sent to the reap, not to the group"        "--category=registry --fix" "$R"
tn "T12d it is NOT handed the credentials group"          "gpasswd" "$R"
t  "T12e and the registered seats still read ok on their own line" "ok" "$(doctor_row record-visibility | cut -d'|' -f1)"
# A registered seat is NEVER counted twice, whatever passwd says about it.
reset_doctor; PROBE=([agent-mp]=BLOCKED)
doctor_check_plugin_record_visibility >/dev/null 2>&1
t  "T12f a REGISTERED seat in passwd is not re-reported as an orphan" "" "$(doctor_row record-visibility-orphans)"
doctor_orphan_passwd_users() { printf ''; }

# ---- T13: the grant is sized by what refuses --------------------------------
# Only a component with no o+x bit. Granting on a 2755 directory would be a
# no-op ACL that makes the next reader think the mode was load-bearing, and
# every extra opened directory widens the residual.
TT="$TMP/tt"; mkdir -p "$TT/a/b/c"
chmod 755 "$TT"; chmod 2750 "$TT/a"; chmod 2755 "$TT/a/b"; chmod 700 "$TT/a/b/c"
GOT="$(plugin_root_traverse_components "$TT/a/b/c" | grep "^$TT" | tr '\n' ' ' | sed 's/ $//')"
t  "T13a only the non-o+x components are named, top-down" "$TT/a $TT/a/b/c" "$GOT"
# Not "nothing": $TT/a genuinely refuses and is genuinely grantable. The
# property is that the walk STOPS at the absent component and never names
# anything below it — a component under an absent parent is unknowable, not
# refusing, and granting on a guess is how you widen a path you never measured.
GOT="$(plugin_root_traverse_components "$TT/a/nope/deep" | grep "^$TT/" | tr '\n' ' ' | sed 's/ $//')"
t  "T13b a walk through an absent component stops there" "$TT/a" "$GOT"
tn "T13b2 and never names anything below it" "nope" "$GOT"
t  "T13c a relative path is refused outright" "" "$(plugin_root_traverse_components "relative/path")"
# Stops AT the first absent component rather than walking past it: a stat below
# an untraversable parent fails for the parent's reason, so continuing would
# report "absent" for something merely hidden.
chmod 2750 "$TT/a"
t  "T13d and it stops at the first absent component, not after it" "$TT/a" \
   "$(plugin_root_traverse_components "$TT/a/gone/x" | grep "^$TT" | tr '\n' ' ' | sed 's/ $//')"

if command -v setfacl >/dev/null 2>&1 && setfacl -m "u:$(id -un):--x" "$TT/a" 2>/dev/null; then
  setfacl -b "$TT/a" 2>/dev/null
  G1="$(plugin_root_traverse_grant "$(id -un)" "$TT/a/b/c" 2>/dev/null | grep "^$TT/" | tr '\n' ' ' | sed 's/ $//')"
  t  "T13e the grant reports exactly the components it touched" "$TT/a $TT/a/b/c" "$G1"
  G2="$(plugin_root_traverse_grant "$(id -un)" "$TT/a/b/c" 2>/dev/null | grep "^$TT/" | tr '\n' ' ' | sed 's/ $//')"
  t  "T13f and it is idempotent — a re-run is the same grant, not an error" "$G1" "$G2"
  tc "T13g the ACL is traverse-ONLY: no read, no listing" "user:$(id -un):--x" "$(getfacl -p "$TT/a" 2>/dev/null | tr -d ' ')"
else
  SKIP=$((SKIP+1)); printf 'UNMEASURED - T13e-g grant arms (no usable setfacl here)\n'
fi

# ---- T14: --fix applies the sandboxed repair, and ONLY that one -------------
# Additive, reversible by one setfacl -x, idempotent, and identical to what the
# create path writes for a seat minted today — so it is safe to auto-heal.
# `gpasswd -a` changes what a credentials group contains and reaping deletes an
# account: neither is a doctor auto-heal, and the arms below pin that.
HEAL_CALLS=""
plugin_root_traverse_grant() { HEAL_CALLS="$HEAL_CALLS $1"; PROBE[agent-mp]=READ; printf '%s\n' "$2"; }
reset_doctor; DOCTOR_REPAIR=1; SEAT_ROWS=$'mp\tclaude\nops\tclaude\n'; PROBE=([agent-mp]=BLOCKED)
doctor_check_plugin_record_visibility >/dev/null 2>&1
R="$(doctor_row record-visibility)"
t  "T14a --fix on a sandboxed blind seat repairs it in place" "warn" "${R%%|*}"
tc "T14b and says so"                        "granted traverse-only access in place" "$R"
tc "T14c and it stays out of the group"      "still outside group fivedive-test" "$R"
tc "T14d and hands back the reverse"         "setfacl -x u:agent-<seat>" "$R"
t  "T14e the grant ran for exactly that seat" " agent-mp" "$HEAL_CALLS"
t  "T14f and the row is marked repaired"     "true" "$(jq -r '.[]|select(.name=="record-visibility")|.repaired' <<<"$DOCTOR_CHECKS")"

# A DRIFTED seat is NOT auto-healed under the same --fix.
HEAL_CALLS=""
reset_doctor; DOCTOR_REPAIR=1; PROBE=([agent-ops]=BLOCKED)
doctor_check_plugin_record_visibility >/dev/null 2>&1
R="$(doctor_row record-visibility)"
t  "T14g --fix does NOT auto-join a drifted seat to the group" "error" "${R%%|*}"
t  "T14h and the ACL grant was not run for it" "" "$HEAL_CALLS"
tc "T14i it is still told the group is its repair" "gpasswd -a agent-ops" "$R"
DOCTOR_REPAIR=0
unset -f plugin_root_traverse_grant
# shellcheck disable=SC1091
source <(sed -n '/^plugin_root_traverse_grant() {/,/^}/p' src/lib/plugin_seats.sh)

# ---- T15: the seat-side message, which cannot read the registry -------------
# _plugin_record_blocked_message runs AS the blind seat, and the registry is
# 0640 root:<group> — the same group the seat is outside of. So it branches on
# what the seat can observe about ITSELF, and the arms grade that partition.
msg() { _plugin_record_blocked_message "$1"; }
_plugin_seat_in_shared_group() { [[ "${FAKE_IN_GROUP:-0}" == 1 ]]; }
_plugin_seat_has_sandbox_grant() { [[ "${FAKE_SANDBOX:-0}" == 1 ]]; }

M="$(FAKE_IN_GROUP=1 msg "$PDIR")"
tc "T15a in the group and still refused: the MODE is the problem" "is not what is \
missing" "$M"
tn "T15b and it does not send an account already in the group to gpasswd" "gpasswd -a" "$M"

M="$(FAKE_IN_GROUP=0 FAKE_SANDBOX=1 msg "$PDIR")"
tc "T15c the sandbox signature is read as a sandbox" "SANDBOXED seat" "$M"
tc "T15d and it refuses the group out loud"          "Do NOT add this account" "$M"
tc "T15e and prescribes the narrow grant"            "setfacl -m u:" "$M"
tn "T15f and never prescribes the group"             "gpasswd -a" "$M"

M="$(FAKE_IN_GROUP=0 FAKE_SANDBOX=0 msg "$PDIR")"
tc "T15g outside with no grant: the seat cannot tell which it is, and says so" "If this seat is" "$M"
tc "T15h so it names the group repair as CONDITIONAL"  "gpasswd -a" "$M"
tc "T15i and names the orphan case too"                "orphan account" "$M"
tc "T15j all three hand the question to doctor, which CAN read the registry" "5dive doctor --category=plugins" "$M"


printf '\n%d pass, %d fail, %d unmeasured\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
