#!/usr/bin/env bash
# DIVE-3191 — `gate-proof verify` must be HISTORY-AWARE.
#
# THE DEFECT (DIVE-3176, measured on DIVE-3170/3136/3113/2808): `verify` read
# `tasks` only, and `tasks` holds exactly one gate per row. The standard unblock
# for an unsigned lead clear is to RE-FILE the gate and have a signer clear it,
# which retires the unsigned closure into `gate_history`. So the workaround that
# unblocks the push also ERASES it from the tool you would audit with, and a full
# sweep comes back clean. See
# community/wiki/a-current-gate-only-read-undercounts-the-census-and-over-accuses-the-ships.md
#
# THE POSITIVE CONTROL IS THE POINT (arm 2). Without an arm whose expected value
# is NON-green, a clean store and a broken reader print the same thing — which is
# how the original census passed. Arm 3 is its negative twin, so the new line is
# proven to come out BOTH ways rather than being stuck on "accuse".
#
# ISOLATION: STATE_DIR/TASKS_DIR/TASKS_DB are re-pointed under $TMP and arm 0
# proves the override STUCK with a READ TAKEN BEFORE THE FIRST WRITE. Never
# /var/lib/5dive. (`_gate_proof_key_file`/`_gate_proof_enforce_file` are lazy
# getters off the CURRENT $STATE_DIR, so re-pointing after sourcing is safe.)
#
# SCOPE BOUNDARY, stated because it is the honest one: `require_root` is stubbed
# and the harness sources the tree in-process, mirroring
# tests/gate_proof_verify_unit.sh and tests/gate_unsigned_closure_notice_unit.sh
# ($EUID is read-only, so that is the established seam). Everything under test is
# the REAL code: real `cmd_task_need` re-file, real `cmd_task_answer` closure
# signing against a REAL key file and a real HMAC, real `cmd_gate_proof verify`.
# What is NOT exercised is the `sudo -n 5dive gate-proof sign` re-exec hop, which
# needs a second process; the in-process `_gate_closure_sign` it re-execs to IS
# driven, and arm 4 proves the archived signature actually re-verifies rather
# than merely being non-empty.
# TIER: core — 26.0s measured on this control-plane host (agent-main seat, non-root),
# wall-clock of the whole file INCLUDING its two mutant re-execs.
# Run: bash tests/gate_proof_verify_history_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC="${MUT_SRC:-src}"
MUTANT_CHILD="${MUTANT_CHILD:-}"
REPO_ROOT="$PWD"
TMP="$(mktemp -d /tmp/gate-proof-verify-history.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "$SRC/$f"
done

require_root() { :; }

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$TMP/gate-proof.key"
openssl rand -hex 32 >"$GATE_PROOF_KEY"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
MPASS=0; MFAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- 0. THE OVERRIDE STICKS, PROVEN BY A READ BEFORE THE FIRST WRITE ---------
# Ordering is the whole assertion: a read taken AFTER the first write cannot tell
# "the override held" from "the write created the file the override names".
if [[ "$TASKS_DB" == "$TMP"/* && ! -e "$TASKS_DB" && "$TASKS_DB" != /var/lib/5dive/* ]]; then
  ok_t "0. isolation: TASKS_DB points under TMP and does NOT yet exist (read taken pre-write)"
else
  bad_t "0. isolation is unproven — refusing to run against a store this arm cannot vouch for" \
        "TASKS_DB=$TASKS_DB exists=$([[ -e "$TASKS_DB" ]] && echo yes || echo no)"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi
tasks_db_init
if [[ -s "$TASKS_DB" && ! -e /var/lib/5dive/tasks/tasks.db.gate3191 ]]; then
  ok_t "0b. the first write landed in the overridden store, not the host store"
else
  bad_t "0b. the store the writes reached is not the overridden one" "TASKS_DB=$TASKS_DB"
fi

# --- helpers ----------------------------------------------------------------
# Every seeding verb runs in a SUBSHELL: these call `fail`, which `exit`s, and an
# exit inside the harness's own shell would end the run mid-arm and read as a pass
# on everything after it. The subshell is the containment, not decoration.
addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
task_need_notify() { return 0; }
_task_store_audit_log() { :; }
sigof()  { db "SELECT COALESCE(need_answer_sig,'') FROM tasks WHERE id=${1};"; }
histn()  { db "SELECT COUNT(*) FROM gate_history WHERE task_id=${1};"; }
mkgate() { ( cmd_task_need "$1" --type=decision --options="A|B" --recommend="A" \
               --ask="${2:-pick one}" --tier=1 ) >/dev/null 2>&1; }
# `task answer` has no --by flag; the answerer is derived from the actor, and the
# fixture's is deterministic. Arm 2d asserts the PRINTED answerer equals the
# STORED one rather than a literal, which is the stronger assertion anyway.
answer() { ( cmd_task_answer "$1" --value="$2" --human ) >/dev/null 2>&1; }
# The unsignable box: the REAL cmd_task_answer runs, its best-effort mint fails.
# CAPTURE THE REAL SIGNER FIRST. Overriding `_gate_closure_sign` with a stub does
# not shadow the sourced one, it REPLACES it — so `unset -f` afterwards deletes the
# real implementation for the rest of the run, and every later "signed" arm then
# silently produces an unsigned or unverifiable closure. That failure is quiet in
# exactly the direction this harness exists to catch, so the restore is by
# re-evaluating the captured definition, never by unset.
_REAL_GATE_SIGN="$(declare -f _gate_closure_sign)"
[[ -n "$_REAL_GATE_SIGN" ]] || { printf 'FATAL: _gate_closure_sign not sourced; the signable arms would be vacuous\n' >&2; exit 1; }
# `sudo` is stubbed DENIED for the whole run and never restored. cmd_task_answer
# prefers the `sudo -n 5dive gate-proof sign` re-exec, which signs with the HOST's
# key under /var/lib/5dive — so leaving real sudo reachable both breaks isolation
# and makes every archived signature unverifiable against the fixture key, which
# presents as "the feature miscounts" rather than "the harness escaped its store".
# WHAT THE `sudo` STUB SUBSTITUTES, precisely: cmd_task_answer signs by piping the
# canonical payload to `sudo -n 5dive gate-proof sign` whenever it is not root, and
# only calls the in-process signer when it IS. Leaving real sudo reachable would
# sign with the HOST key under /var/lib/5dive — breaking isolation AND making every
# archived signature unverifiable against the fixture key, which presents as "the
# feature miscounts" rather than "the harness escaped its store". So the stub
# replaces the PRIVILEGE HOP and nothing else: same stdin payload, same
# `_gate_proof_hmac`, fixture key. `valid` below is therefore a real cryptographic
# re-verification against the ARCHIVED facts, not a string comparison.
# The stub answers ONLY the `gate-proof sign` invocation. An unconditional
# `$(cat)` hangs forever on any other sudo call whose stdin is not the payload
# pipe — which is a wedged harness, not a failing one, and reads as a timeout
# rather than as a bug.
_sudo_sign_stub() {
  local a
  # TWO sudo calls carry the word `sign`, and only ONE of them has a payload on
  # stdin. `sudo -n -l /usr/local/bin/5dive gate-proof sign` is the PERMISSION
  # PROBE ("may this seat sign?"), invoked with no pipe — reading stdin there
  # blocks forever, which is a WEDGED harness reported as a timeout rather than a
  # failure. Answer the probe 0 (this seat may sign) and cat only the real exec.
  local a probe=0 sign=0
  for a in "$@"; do
    [[ "$a" == "-l"   ]] && probe=1
    [[ "$a" == "sign" ]] && sign=1
  done
  (( probe )) && return 0
  (( sign  )) && { _gate_proof_hmac "$(cat)"; return 0; }
  return 1
}
signable()   { sudo() { _sudo_sign_stub "$@"; }; eval "$_REAL_GATE_SIGN"; }
unsignable() { sudo() { return 1; }; _gate_closure_sign() { return 1; }; }
vfy()  { local o; JSON_MODE=0; o=$( ( cmd_gate_proof verify "$1" ) 2>&1 ); JSON_MODE=1; printf %s "$o"; }
vfyj() { ( cmd_gate_proof verify "$1" ) 2>&1; }

# --- 2. POSITIVE CONTROL: the superseded UNSIGNED clear must surface ---------
# Built through the REAL paths: unsigned clear -> re-file (which archives it)
# -> signed clear. Nothing is hand-inserted into gate_history.
signable
t1=$(addt --assignee=dev -- "fixture: unsigned clear superseded by a signed one")
mkgate "$t1" "clear this to push"
unsignable
answer "$t1" "B"
UNSIGNED_LANDED=$([[ -z "$(sigof "$t1")" ]] && echo yes || echo no)
signable
mkgate "$t1" "re-filed so a signer can clear it"      # <- archives the unsigned closure
answer "$t1" "B"
OUT1=$(vfy "$t1")

if [[ "$UNSIGNED_LANDED" == yes ]]; then
  ok_t "2a. liveness: the fixture really stored an EMPTY signature (else nothing below measures anything)"
else
  bad_t "2a. the unsignable arm signed anyway — the positive control is not armed" "sig=$(sigof "$t1")"
fi
if [[ "$(histn "$t1")" -ge 1 ]]; then
  ok_t "2b. liveness: the re-file really archived the prior gate into gate_history"
else
  bad_t "2b. nothing was archived — the re-file path did not supersede" "count=$(histn "$t1")"
fi
if [[ -n "$(sigof "$t1")" ]]; then
  ok_t "2c. liveness: the CURRENT closure is signed — this is the row that used to read green"
else
  bad_t "2c. the current closure is unsigned, so this is not the defect's shape" "sig=empty"
fi
if [[ "$OUT1" == *"SUPERSEDED-UNSIGNED"* ]]; then
  ok_t "2. POSITIVE CONTROL: verify does NOT print an unqualified green on a superseded unsigned clear"
else
  bad_t "2. THE DEFECT IS BACK: verify printed no superseded-unsigned verdict" "$OUT1"
fi
HANS=$(db "SELECT COALESCE(need_answered_by,'') FROM gate_history
           WHERE task_id=${t1} AND COALESCE(need_answered_at,'')<>''
             AND COALESCE(need_answer_sig,'')='' LIMIT 1;")
if [[ -n "$HANS" && "$OUT1" == *"$HANS"* ]]; then
  ok_t "2d. the ANSWERER of the displaced closure is named, and it MATCHES the archived value ($HANS)"
else
  bad_t "2d. answerer missing or not the stored one (acceptance requires count, answerer, timestamp)" \
        "stored='$HANS' out=$OUT1"
fi
[[ "$OUT1" =~ answered\ [0-9]{4}-[0-9]{2}-[0-9]{2} ]] \
  && ok_t "2e. the TIMESTAMP of the displaced closure is named" \
  || bad_t "2e. timestamp missing" "$OUT1"
[[ "$OUT1" == *"1 UNSIGNED"* ]] \
  && ok_t "2f. the COUNT is named" \
  || bad_t "2f. count missing" "$OUT1"
[[ "$OUT1" == *"signed: present"* && "$OUT1" == *"valid:  true"* ]] \
  && ok_t "2g. the CURRENT closure still reports signed/valid — the new line ADDS, it does not reclassify" \
  || bad_t "2g. the current-gate verdict was disturbed" "$OUT1"

# --- 3. NEGATIVE ARM: a signed clear with no history stays green -------------
signable
t2=$(addt --assignee=dev -- "fixture: signed clear, no history")
mkgate "$t2"
answer "$t2" "B"
OUT2=$(vfy "$t2")
[[ "$(histn "$t2")" -eq 0 ]] \
  && ok_t "3a. liveness: this row genuinely has an EMPTY archive" \
  || bad_t "3a. fixture is not clean" "count=$(histn "$t2")"
if [[ "$OUT2" == *"history: clean"* && "$OUT2" != *"SUPERSEDED"* && "$OUT2" != *"UNKNOWN"* ]]; then
  ok_t "3. NEGATIVE ARM: a clean row still reads clean — the line comes out BOTH ways"
else
  bad_t "3. the new line is stuck on accuse (a check that cannot say clean is not a check)" "$OUT2"
fi

# --- 4. AN ARCHIVED SIGNED CLOSURE RE-VERIFIES AS valid, NOT MERELY present --
signable
t3=$(addt --assignee=dev -- "fixture: signed clear superseded by another signed one")
mkgate "$t3"
answer "$t3" "B"
mkgate "$t3" "re-filed"
answer "$t3" "A"
OUT3=$(vfy "$t3")
if [[ "$OUT3" == *"history: clean"* && "$OUT3" != *"UNSIGNED"* && "$OUT3" != *"INVALID"* ]]; then
  ok_t "4. an archived SIGNED closure re-verifies against the ARCHIVED facts (valid, not just present)"
else
  bad_t "4. a signed displaced closure was miscounted" "$OUT3"
fi
OUT3J=$(vfyj "$t3")
[[ "$(printf '%s' "$OUT3J" | jq -r '.data.history.valid' 2>/dev/null)" == "1" ]] \
  && ok_t "4b. --json reports the archived closure as valid=1" \
  || bad_t "4b. json history.valid wrong" "$OUT3J"

# --- 5. A GATE RETIRED WITH NO ANSWER IS NOT A CLOSURE ----------------------
# The mirror of the under-count: counting a withdrawn gate would OVER-ACCUSE.
signable
t4=$(addt --assignee=dev -- "fixture: gate displaced without ever being answered")
mkgate "$t4"
mkgate "$t4" "re-filed over an UNANSWERED gate"
answer "$t4" "B"
OUT4=$(vfy "$t4")
[[ "$(histn "$t4")" -ge 1 ]] \
  && ok_t "5a. liveness: an unanswered gate really was archived" \
  || bad_t "5a. nothing archived" "count=$(histn "$t4")"
if [[ "$OUT4" == *"history: clean"* ]]; then
  ok_t "5. a gate retired WITHOUT an answer is not counted as a closure (no over-accusation)"
else
  bad_t "5. an unanswered displaced gate was counted as a closure" "$OUT4"
fi

# --- 6. COVERAGE IS AN EVIDENCE BOUNDARY: zero out of coverage is UNKNOWN ----
# The same defect one level down — an unqualified green off a zero count on a
# store whose archive cannot account for the row's whole life.
signable
t5=$(addt --assignee=dev -- "fixture: clean row on an OUT-OF-COVERAGE store")
mkgate "$t5"
answer "$t5" "B"
db "INSERT OR REPLACE INTO task_prefs(key,value) VALUES('gate_history_coverage','inferred:2099-01-01 00:00:00');" >/dev/null 2>&1
OUT5=$(vfy "$t5")
db "INSERT OR REPLACE INTO task_prefs(key,value) VALUES('gate_history_coverage','fresh:2000-01-01 00:00:00');" >/dev/null 2>&1
if [[ "$OUT5" == *"UNKNOWN"* && "$OUT5" != *"history: clean"* ]]; then
  ok_t "6. a ZERO count outside archive coverage reads UNKNOWN, never clean"
else
  bad_t "6. an out-of-coverage zero printed an unqualified green — the defect, one level down" "$OUT5"
fi
[[ "$OUT5" == *"cannot mean clean"* ]] \
  && ok_t "6b. the qualification says WHY, so the reader can act on it" \
  || bad_t "6b. UNKNOWN with no reason is not actionable" "$OUT5"

# --- 7. THE AUDIT ROW CARRIES THE HISTORY VERDICT ---------------------------
# Or the audit trail inherits exactly the blind spot this change closes.
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
vfy "$t1" >/dev/null
if grep -q 'history=SUPERSEDED-UNSIGNED' "$AUDIT_CALLS" 2>/dev/null; then
  ok_t "7. the audit row records the history verdict, not just the current gate"
else
  bad_t "7. the audit trail still reads current-gate-only" "$(cat "$AUDIT_CALLS")"
fi
_task_store_audit_log() { :; }

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"

# --- MUTATION GRADING -------------------------------------------------------
# Every arm above asserts about a REFUSAL or an ABSENCE, both of which are
# satisfied by a build that does nothing. The arms are worth exactly what these
# mutants say they are (community/wiki/grade-absence-assertions-by-mutation.md).
if [[ -z "$MUTANT_CHILD" ]]; then
  mutate() { # <name> <sed-expr> <must-red-hint>
    local name="$1" expr="$2" hint="$3" md out rc
    md="$TMP/mut-$name"; mkdir -p "$md"; cp -r "$REPO_ROOT/src/." "$md/"
    if ! sed -i "$expr" "$md/cmd_task.sh"; then
      MFAIL=$((MFAIL+1)); printf 'FAIL - mutant %s: sed could not apply\n' "$name"; return
    fi
    if diff -q "$REPO_ROOT/src/cmd_task.sh" "$md/cmd_task.sh" >/dev/null; then
      MFAIL=$((MFAIL+1)); printf 'FAIL - mutant %s: the sed matched NOTHING — the anchor moved\n' "$name"; return
    fi
    out=$(MUT_SRC="$md" MUTANT_CHILD=1 bash "$REPO_ROOT/tests/$(basename "$0")" 2>&1); rc=$?
    if [[ $rc -ne 0 ]]; then
      MPASS=$((MPASS+1)); printf 'ok   - mutant %s reds the harness (%s)\n' "$name" "$hint"
    else
      MFAIL=$((MFAIL+1)); printf 'FAIL - mutant %s SURVIVED — the arms for %s assert nothing\n   %s\n' \
        "$name" "$hint" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
  }
  printf '\n--- mutation grading ---\n'
  # M1 neuters the whole history read back to the pre-DIVE-3191 shape: current
  # gate only, always clean. Arm 2 (the positive control) must red.
  mutate historyread \
    's#^    _gate_proof_history_scan "\$vid"$#    _GPH_VERDICT=clean; _GPH_ARCHIVED=0; _GPH_CLOSED=0; _GPH_UNSIGNED=0; _GPH_INVALID=0; _GPH_VALID=0; _GPH_STATE=complete; _GPH_BASIS=fresh; _GPH_COVERAGE=""; _GPH_TEXT="history: clean"; _GPH_TRAILER=""#' \
    'arm 2 — the superseded unsigned closure'
  # M2 neuters ONLY the coverage boundary, leaving the closure scan intact. Arm 6
  # must red on its own; without this, arm 6 is carried by M1 and asserts nothing.
  mutate coverage \
    's#^  elif \[\[ "\$_GPH_STATE" == complete \]\]; then _GPH_VERDICT="clean"$#  elif true; then _GPH_VERDICT="clean"#' \
    'arm 6 — the out-of-coverage zero'
  printf '%d mutants killed, %d survived\n' "$MPASS" "$MFAIL"
fi
# DIVE-2096: ONE verdict statement on the LAST executable line, reachable by both
# the parent and the MUTANT_CHILD re-exec. A verdict stranded in an if/else puts
# the harness-verdict probe's injection point on a branch the parent never takes,
# and the file reads UNWIRED — green, mutation-graded, and unable to fail CI.
[[ $FAIL -eq 0 && $MFAIL -eq 0 ]]
