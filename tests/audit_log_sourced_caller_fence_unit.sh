#!/usr/bin/env bash
# The fleet audit log WITHHOLDS a row from a sourced-library caller, so a harness
# that never stubbed audit_log — or never pointed AUDIT_LOG under its STATE_DIR —
# cannot write fixture rows into the live /var/log/5dive/agent-audit.log.
#
# THE DEFECT. src/header.sh sets AUDIT_LOG to the live path unconditionally and
# tests/lib/env_isolation.sh clears only FIVE_*, so every harness that sources
# src/ starts aimed at the real log. 124 harnesses stub audit_log, 10 re-point
# AUDIT_LOG, and the rest audit for real: on a box that runs 5dive, one run of the
# corpus put `task cancel`, `deploy gate` and `agent ask` fixture rows in the live
# log. Same class as DIVE-1500 (gate-notify), DIVE-1506 (human DM relay), DIVE-2010
# (task audit telemetry) and DIVE-2249 (the task board): an outbound rail with no
# fence, reached by a caller that never entered through the CLI.
#
# WHY IT WAS INVISIBLE, and why arm 2 exists. Where the log is 640 root:claude the
# non-root append fails the `-w` test and the row goes to the privileged fallback:
# `sudo -n 5dive _audit_append`. On a box with that sudoers grant the row LANDS —
# through sudo, from a test. On a box without it, `sudo -n` fails and the drop note
# goes to notify/, or nowhere. A clean grep of the log on the second kind of box
# does not disprove the leak; it shows only that this box could not write.
#
# HERMETIC BY CONSTRUCTION. Every arm designates a decoy under $TMP as "the live
# log" via FIVEDIVE_FENCE_EXTRA_AUDIT_LOG and aims the writers at that decoy;
# `sudo` is shadowed inside every sourced caller so the fallback can be OBSERVED (a
# file marker) and can never reach the real primitive. The real /var/log/5dive is never opened,
# written, or compared against. The one arm that needs the hardcoded live path
# (arm 5) only reads the caller's stderr, and skips — as a SKIP, not a pass —
# whenever this process could actually append to the real log or its notify/.
#
# THE RED ARMS. Against a src/ without the fence, arm 1 (the row lands), arm 2
# (sudo is reached for), arm 3 (the drop note lands) and arm 5 (no withheld line)
# all go red. Arm 0 and arm 4 are the liveness pair: the same writes LAND from the
# CLI entrypoint and into an isolated sink, so a zero in the red arms is not a
# malformed row, a missing dir, or a dead writer.
#
# Run: bash tests/audit_log_sourced_caller_fence_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/audit-sourced-fence.XXXXXX)"
SUMMARY_PRINTED=0
# DIVE-2610: fd 8 is a dup of the REAL stderr, taken before any arm runs, so the
# abort backstop is not swallowed by a redirect that was live when a caller died.
exec 8>&2
trap 'rc=$?; chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - audit_log_sourced_caller_fence_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The decoy that plays "the live fleet log" for the whole suite. notify/ exists
# because audit_init creates it on a real box, and _audit_note_drop only writes
# when it does — a decoy without it would make arm 3 pass for the wrong reason.
LIVE_DIR="$TMP/livelog"; LIVE_LOG="$LIVE_DIR/agent-audit.log"; LIVE_DROPS="$LIVE_DIR/notify/audit-drops.log"
mkdir -p "$LIVE_DIR/notify"; : > "$LIVE_LOG"
export FIVEDIVE_FENCE_EXTRA_AUDIT_LOG="$LIVE_LOG"

# A sourced-library caller, run as a child with the entrypoint marker unset.
# $1 = assignments run AFTER the sources, $2 = the body. AFTER, because that is
# the defect's own mechanism: header.sh assigns AUDIT_LOG unconditionally, so a
# value exported before it is overwritten — which is also why the shared test lib
# (sourced before header.sh) could never re-point it. The first cut of this
# harness set it before and put two probe drop notes in a live notify/ log.
# `sudo` is shadowed after the sources too, so nothing in src/ can replace it:
# the privileged fallback then leaves a FILE marker and fails instead of running.
# A file, not stderr: the call site is `| sudo -n ... >/dev/null 2>&1`, so a
# marker printed there is swallowed and "sudo was never reached" would be
# asserted on a stream that could not show it.
SUDO_MARK="$TMP/sudo-invoked"
sudo_reached() { [[ -e "$SUDO_MARK" ]]; }
sourced_caller() {
  env -u _TASKS_STORE_ENTRY bash -c "
    set -uo pipefail
    cd '$PWD'
    export FIVEDIVE_FENCE_EXTRA_AUDIT_LOG='$LIVE_LOG'
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/actor.sh lib/audit.sh; do source '$SRC'/\$f; done
    sudo() { printf '%s\n' \"\$*\" >> '$SUDO_MARK'; return 1; }
    $1
    $2
  " 2>&1
}
rows()  { wc -l < "$LIVE_LOG" 2>/dev/null | tr -d ' ' || echo MISSING; }
drops() { if [[ -e "$LIVE_DROPS" ]]; then wc -l < "$LIVE_DROPS" | tr -d ' '; else echo 0; fi; }
PROBE='audit_log probe ok 0 -- a=1 b=2'

# ---------------------------------------------------------------- arm 0: liveness
# The identical write, from the CLI entrypoint, must LAND in the decoy. Without
# this arm every "unchanged" below would also hold for a dead writer.
out0=$(sourced_caller "export AUDIT_LOG='$LIVE_LOG'" "_TASKS_STORE_ENTRY=cli; $PROBE")
if [[ "$(rows)" == "1" ]] && jq -e 'select(.cmd=="probe" and .args==["a=1","b=2"])' "$LIVE_LOG" >/dev/null 2>&1; then
  ok_t "0: the CLI entrypoint still writes the designated log (fence is not a lockout)"
else
  bad_t "0: the CLI entrypoint still writes the designated log" "rows=$(rows) log='$(head -c 200 "$LIVE_LOG")' out='$(head -c 200 <<<"$out0")'"
fi
[[ "$out0" != *"withheld"* ]] \
  && ok_t "0b: ... and says nothing about withholding" \
  || bad_t "0b: the entrypoint write is silent" "$(head -c 300 <<<"$out0")"
BASE=$(rows)

# ------------------------------------------- arm 1: the fence (RED without it)
out1=$(sourced_caller "export AUDIT_LOG='$LIVE_LOG'" "$PROBE; printf 'EXECUTION-CONTINUED rc=%s\n' \$?")
if [[ "$(rows)" == "$BASE" ]]; then
  ok_t "1: a sourced-library audit_log aimed at the live log adds NO row (rows unchanged: $BASE)"
else
  bad_t "1: a sourced-library audit_log aimed at the live log adds NO row" "rows went $BASE -> $(rows): this is the leak, live"
fi
if grep -q 'audit row withheld' <<<"$out1" && grep -q 'DIVE-2249' <<<"$out1"; then
  ok_t "1b: the withholding is SAID, once, and names the class and the path (the line is the payload)"
else
  bad_t "1b: the withholding is said" "expected 'audit row withheld' + DIVE-2249 on stderr; got: $(head -c 300 <<<"$out1")"
fi
# The INVERSE of the store fence's loudness arm, and deliberately so: audit_log
# runs from the EXIT trap of every mutating verb, so a fence that exited here
# would kill a harness in its teardown. Withheld, rc 0, caller carries on.
if grep -q 'EXECUTION-CONTINUED rc=0' <<<"$out1"; then
  ok_t "1c: ... while audit_log still returns 0 and the caller carries on (best-effort contract kept)"
else
  bad_t "1c: audit_log stays best-effort under the fence" "$(head -c 300 <<<"$out1")"
fi
# Once per process: a harness that audits N times reads one line, not N.
outN=$(sourced_caller "export AUDIT_LOG='$LIVE_LOG'" "$PROBE; $PROBE; $PROBE")
n_said=$(grep -c 'audit row withheld' <<<"$outN")
[[ "$n_said" == "1" && "$(rows)" == "$BASE" ]] \
  && ok_t "1d: three withheld rows produce ONE line (n=$n_said), and still no row" \
  || bad_t "1d: the withheld line is once per process" "lines=$n_said rows=$(rows)"

# ---------------------- arm 2: the root-owned box — the route the leak took
# Make the decoy unwritable so the non-root branch of _emit_audit_line runs: the
# `-w` test fails and, without the fence, the row goes to `sudo -n 5dive
# _audit_append`. The shadowed sudo turns that into an observable marker.
chmod 444 "$LIVE_LOG"
if [[ -w "$LIVE_LOG" ]]; then
  printf 'SKIP - 2: this process can still write a 444 file (running as root?); the privileged-fallback route cannot be modelled here (precondition unavailable, NOT a pass)\n'
else
  rm -f "$SUDO_MARK"
  out2=$(sourced_caller "export AUDIT_LOG='$LIVE_LOG'" "$PROBE")
  if ! sudo_reached; then
    ok_t "2: on a log the caller cannot write, a sourced caller does NOT reach for sudo (the leak's route on a live box)"
  else
    bad_t "2: a sourced caller never reaches for sudo" "the privileged fallback was invoked: sudo $(head -1 "$SUDO_MARK")"
  fi
  [[ "$(drops)" == "0" ]] \
    && ok_t "2b: ... and leaves no drop note in the live notify/ either" \
    || bad_t "2b: no drop note on the live notify/" "drops=$(drops): $(head -c 200 "$LIVE_DROPS" 2>/dev/null)"
fi
chmod 644 "$LIVE_LOG"

# ------------------------------ arm 3: the drop note is fenced on its own
# notify/ is 2770 by construction — the ONE live surface a sourced non-root caller
# can reach without sudo — so _audit_note_drop is a writer in its own right.
out3=$(sourced_caller "export AUDIT_LOG='$LIVE_LOG'" "_audit_note_drop '{\"cmd\":\"probe\"}' harness-probe")
[[ "$(drops)" == "0" ]] \
  && ok_t "3: a sourced-library _audit_note_drop aimed at the live notify/ adds NO note" \
  || bad_t "3: a sourced-library drop note is withheld" "drops=$(drops)"
out3b=$(sourced_caller "export AUDIT_LOG='$LIVE_LOG'" "_TASKS_STORE_ENTRY=cli; _audit_note_drop '{\"cmd\":\"probe\"}' harness-probe")
[[ "$(drops)" == "1" ]] \
  && ok_t "3b: the identical drop note LANDS from the CLI entrypoint (arm 3's zero is not vacuous)" \
  || bad_t "3b: the drop note lands from the entrypoint" "drops=$(drops) out='$(head -c 200 <<<"$out3b")'"

# --------------------------------------- arm 4: an ISOLATED sink still works
# The fence keys on the live path, not on "is a test". If this reds, the fence has
# broken every harness that already isolates its AUDIT_LOG.
ISO="$TMP/iso"; mkdir -p "$ISO/notify"; : > "$ISO/agent-audit.log"   # the file exists on a real box: audit_init creates it
out4=$(sourced_caller "export AUDIT_LOG='$ISO/agent-audit.log'" "$PROBE")
iso_rows=$(wc -l < "$ISO/agent-audit.log" 2>/dev/null | tr -d ' ' || echo MISSING)
if [[ "$iso_rows" == "1" && "$out4" != *"withheld"* ]]; then
  ok_t "4: an isolated AUDIT_LOG is unaffected — properly-fenced harnesses still write, silently"
else
  bad_t "4: an isolated AUDIT_LOG is unaffected" "expected 1 row and no withheld line; rows='$iso_rows' out='$(head -c 200 <<<"$out4")'"
fi
[[ "$(rows)" == "$BASE" ]] \
  && ok_t "4b: ... and the designated live log is still at $BASE" \
  || bad_t "4b: live log untouched by the isolated write" "rows=$(rows)"

# ---------------------- arm 5: the HARDCODED live path, with nothing designated
# A harness that forgets AUDIT_LOG starts on header.sh's own value. Nothing below
# exports the decoy knob or AUDIT_LOG, so the fence must fire on the literal path
# alone.
#
# 5b/5c drive the PREDICATE rather than a writer, and that is the whole point of
# the arm. `audit_log` opens with `[[ -d "${AUDIT_LOG%/*}" ]] || return 0` (the
# DIVE-1307 guard against a noisy redirect before audit_init has run), so on a box
# with no /var/log/5dive — CI, every container — it returns BEFORE the fence is
# ever consulted. An arm that drove audit_log here would therefore demand a
# withheld line from a box that cannot produce one, and would credit the dir guard
# on a box that can. The predicate is what this fix added, it decides the
# withholding, and calling it opens no file, so these two arms need no skip and
# read the same everywhere. Against a src/ without the fence both functions are
# undefined, rc is 127, and both arms go red.
REAL_LOG=/var/log/5dive/agent-audit.log
rm -f "$SUDO_MARK"
out5=$(env -u FIVEDIVE_FENCE_EXTRA_AUDIT_LOG bash -c "
  set -uo pipefail; cd '$PWD'
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/actor.sh lib/audit.sh; do source '$SRC'/\$f; done
  sudo() { printf '%s\n' \"\$*\" >> '$SUDO_MARK'; return 1; }
  printf 'AUDIT_LOG=%s\n' \"\$AUDIT_LOG\" >&2
  set +e
  _audit_sink_is_live;            printf 'SINK-IS-LIVE=%s\n' \$?
  _audit_sourced_caller_fence;    printf 'FENCE=%s\n' \$?
  " 2>&1)
if grep -q "AUDIT_LOG=$REAL_LOG" <<<"$out5"; then
  ok_t "5: precondition — header.sh still aims a sourced caller at $REAL_LOG (the arm grades the real default)"
else
  bad_t "5: precondition" "header.sh no longer sets AUDIT_LOG to $REAL_LOG; re-derive this arm: $(head -c 200 <<<"$out5")"
fi
[[ "$out5" == *"SINK-IS-LIVE=0"* ]] \
  && ok_t "5b: with nothing designated, the hardcoded path is still recognised as the live sink" \
  || bad_t "5b: the hardcoded live path is recognised without a designation" "expected SINK-IS-LIVE=0; got: $(head -c 300 <<<"$out5")"
if [[ "$out5" == *"FENCE=0"* ]] && grep -q 'audit row withheld' <<<"$out5" && ! sudo_reached; then
  ok_t "5c: ... so a sourced caller there is WITHHELD, says so once, and never reaches for sudo"
else
  bad_t "5c: the hardcoded live path is fenced without a designation" "expected FENCE=0 + the withheld line, sudo unreached; withheld=$(grep -c 'audit row withheld' <<<"$out5") sudo_reached=$(sudo_reached && echo yes || echo no): $(head -c 300 <<<"$out5")"
fi

# ---- arm 5d: the same thing through the real writer, where that is safe to run
# The end-to-end counterpart to 5b/5c. Skipped — as a SKIP, not a pass — whenever
# this process could actually append to the real log or its notify/, because a
# regressed src/ would then make this arm itself the leak it grades. Where it does
# run it is also satisfied by the dir guard above, which is why it supplements
# 5b/5c rather than replacing them.
if [[ $EUID -eq 0 || -w "$REAL_LOG" || -w "${REAL_LOG%/*}/notify" ]]; then
  printf 'SKIP - 5d: this process can write %s or its notify/, so a regressed src/ would leak a real row or drop note from this arm (precondition unavailable, NOT a pass)\n' "$REAL_LOG"
else
  rm -f "$SUDO_MARK"
  before5=$(cat "$REAL_LOG" 2>/dev/null | wc -l | tr -d ' ')
  out5d=$(env -u _TASKS_STORE_ENTRY env -u FIVEDIVE_FENCE_EXTRA_AUDIT_LOG bash -c "
    set -uo pipefail; cd '$PWD'
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/actor.sh lib/audit.sh; do source '$SRC'/\$f; done
    sudo() { printf '%s\n' \"\$*\" >> '$SUDO_MARK'; return 1; }
    $PROBE; printf 'EXECUTION-CONTINUED rc=%s\n' \$?" 2>&1)
  after5=$(cat "$REAL_LOG" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$after5" == "$before5" ]] && ! sudo_reached && grep -q 'EXECUTION-CONTINUED rc=0' <<<"$out5d"; then
    ok_t "5d: a real audit_log on the hardcoded path adds no row, never reaches for sudo, and still returns 0"
  else
    bad_t "5d: the real writer is inert on the hardcoded path" "rows $before5 -> $after5 sudo_reached=$(sudo_reached && echo yes || echo no): $(head -c 300 <<<"$out5d")"
  fi
fi

printf -- '-----\naudit_log_sourced_caller_fence_unit: %s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
(( FAIL == 0 ))
