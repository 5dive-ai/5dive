#!/usr/bin/env bash
# TIER: core — 5.4s measured (agent-dev seat, this host, 2026-08-17, median of 3 `time bash tests/gate_evidence_form_unit.sh` -> rc 0): fits the 300s PR core. It got FASTER while gaining two arms (DIVE-2752): the same reading was 10.1s here before the gate-delivery log seam below was pointed at TMP, because the retirement pass on every answer was walking the live fleet log. The "~6s (dev3, control plane, 2026-08-05)" figure this replaces was a different box AND a different fence — quote the environment when you replace this number.
# DIVE-2799 acceptance clause 3 — the gate-answer AUDIT ROW must NAME which
# evidence form cleared the gate, so one grep separates the forms across history.
#
# WHY THIS EXISTS, and it is not "the boolean fields are ugly". DIVE-2412 already
# names the form — in `tasks.human_evidence`, ONE cell on ONE mutable row. A
# re-answer overwrites it and `_gate_archive_and_clear_sql` clears it when the gate
# retires, so it is not a history and cannot answer "separate the forms ACROSS
# HISTORY" for any gate since retired. The append-only audit log is the only sink
# with that property and it carried the per-form BOOLEANS but never the form's
# NAME — and a different SUBSET of those booleans at each of the two audit sites.
# That is what made the answer path-dependent, which is the same defect class as
# the ticket's subject: a sweep keyed on a field under-counts by exactly the paths
# that log a different arg set.
#
# WHAT THIS SUITE DOES NOT CLAIM, pinned here so no reader upgrades it. It does
# NOT show that a relayed human tap can be told apart from a filer-presented
# nonce. It cannot be shown, because the deployed Telegram plugin's tap sends
# `--human --human-proof=<nonce>` and nothing else — byte-identical at the input.
# EV3 pins the reachable half: the sole-nonce class (the unfalsifiable one) is
# selectable by one exact grep instead of reconstructed from a join.
#
# What is pinned:
#   EV1 the audit row's `evidence=` and the `tasks.human_evidence` column agree
#       BYTE-FOR-BYTE on the same answer — one vocabulary, not two that drift;
#   EV2 the field reaches BOTH audit sites (`task answer gate` and
#       `task answer t2-human-evidence`) on a single tier-2 answer;
#   EV3 the value is EXACT-MATCHABLE in the JSON log: `"evidence=nonce"` selects
#       sole-nonce and does NOT prefix-match `"evidence=nonce+channel-session"`;
#   EV4 the field is ALWAYS emitted with a value — a non-human decision-gate
#       answer reads `evidence=none`, never an absent key (an absent key is what
#       makes a historical sweep return a confident zero);
#   EV5 `filer_answered=` names whether the answering caller is the gate's filer
#       of record, and falls back to `unknown` — never to `0` — when the row
#       carries no filer;
#   EV6 the token VOCABULARY is DIVE-2412's, unchanged, so the column and the log
#       can be joined;
#   EV7 the real fleet audit log is untouched by this suite.
# Run: bash tests/gate_evidence_form_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
# EV_SRC_DIR lets the mutation grader point this suite at a mutated copy of src.
SRC="${EV_SRC_DIR:-src}"
printf 'grading src: %s%s\n' "$SRC" "${EV_MUTATED:+  (mutant: $EV_MUTATED)}" >&2
TMP="$(mktemp -d /tmp/gate-evform.XXXXXX)"
FAILURES=()
cleanup() {
  local rc="$1"
  if [[ "${FAIL:-0}" -gt 0 || "$rc" -ne 0 ]]; then
    printf '\n=== FAILURE: TMP preserved for inspection: %s ===\n' "$TMP" >&2
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
      printf -- '--- failing assertions ---\n' >&2
      printf '%s\n' "${FAILURES[@]}" >&2
    fi
    for f in "${AUDIT_CALLS:-}" "$TMP"/*.out "$TMP"/*.err; do
      [[ -n "$f" && -s "$f" ]] || continue
      printf -- '--- %s ---\n' "$f" >&2; cat "$f" >&2
    done
  else
    rm -rf "$TMP"
  fi
}
trap 'rc=$?; cleanup "$rc"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

# Suite guard: remember the REAL log's length up front (EV7).
REALLOG=/var/log/5dive/agent-audit.log
REALLOG_OFFSET=0
[[ -r "$REALLOG" ]] && REALLOG_OFFSET=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() {
  FAIL=$((FAIL+1))
  printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"
  FAILURES+=("FAIL - $1"$'\n'"   ${2:-}")
}
addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
# Preconditions, not observables: never ping a channel; keep the tier-2 floor on
# so the evidence sites are reached deterministically on any box.
task_need_notify() { return 0; }
_gate_proof_enforced() { return 0; }
# Deterministic nonce so a "valid tap" can present the right --human-proof.
KNOWN_NONCE="ffffffffffffffffffffffffffffffff"
_human_nonce_mint() { printf '%s' "$KNOWN_NONCE"; }
# DIVE-2752: the SUDO-UID evidence form, pinned — and pinned as a PRECONDITION of
# every arm above, not only of EV8 below. Each exact-string arm here asserts the
# sole form ('nonce', never 'nonce+sudo-uid'), which was true only because the
# seat running the suite happens to be an agent; on a control-plane box or a
# dashboard-exec shell the same bytes would read 'nonce+sudo-uid' and the arm
# would grade the runner rather than the tree
# (tests/test_that_needs_the_host_is_not_a_test — the sibling harness
# gate_channel_session_t2_unit.sh took that lesson at its CS13).
#
# 1 = false = an agent-* caller contributes no sudo-uid evidence. BOTH helpers
# follow the one switch because `_gate_human_principal` is the conjunction of
# them (uid test AND cgroup test, DIVE-2371): stubbing only the uid reader leaves
# the cgroup half reading the real host, and the pin silently stops being
# differential. The READERS are stubbed; the accept/deny logic stays shipped bytes.
#
# DIVE-2752, found while adding EV8 and fixed here because it is this suite's
# fence rather than a product defect: the gate-button retirement that runs on
# EVERY answer resolves its targets from `/var/log/5dive/notify/gate-notify.log`
# — a FLEET-WIDE absolute path, not STATE_DIR — and matches on IDENT. This
# suite's fixture idents are `DIVE-1`, `DIVE-2`, … in a fresh TMP db, and those
# collide with real rows on the live board, so the lookup returned the real
# gate's chat and message ids (a human's DM) and `_task_gate_bot_token` resolved
# a real bot token from an equally unfenced CONNECTORS_DIR. Nothing was edited
# only because `_mirror_edit_markup` is absent from the source list above — an
# accident of that list, not a fence: add the file holding it and this unit test
# strips approve buttons off live messages in a human's chat. Point the seam at
# TMP and stub the writer, so the containment is asserted rather than inherited.
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"; : >"$FIVEDIVE_GATE_NOTIFY_LOG"
_mirror_edit_markup() { printf '%s' '{"ok":true}'; }
_PIN_SUDO_HUMAN=1
_gate_sudo_uid_nonagent() { return "$_PIN_SUDO_HUMAN"; }
_gate_caller_cgroup() {
  if [[ "$_PIN_SUDO_HUMAN" == "0" ]]; then printf '%s' '/system.slice/shelld.service'
  else printf '%s' '/system.slice/system-5dive.slice/5dive-agent@dev.service'; fi
}
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"   # active store IS prod -> log allowed
reset() { : >"$AUDIT_CALLS"; unset _TASK_STORE_AUDIT_FENCED; }

hev() { db "SELECT COALESCE(human_evidence,'') FROM tasks WHERE id=${1};"; }
# Pull the value of one arg out of a captured row.
argval() { sed -n "s/.*[[:space:]]${2}=\([^[:space:]]*\).*/\1/p" <<<"$1" | head -1; }

# ── EV1+EV2+EV6: a sole-nonce tier-2 clear ───────────────────────────────────
# The tap shape: --human --human-proof=<nonce>, SUDO_UID still the agent's.
reset
t1=$(addt --assignee=dev -- "fixture t2 nonce gate")
cmd_task_need "$t1" --type=decision --options="A|B" --recommend="A" \
  --ask="pick one" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
cmd_task_answer "$t1" --value="A" --human --human-proof="$KNOWN_NONCE" \
  >"$TMP/ev1.out" 2>"$TMP/ev1.err"
WROW=$(grep 'task answer gate' "$AUDIT_CALLS" | grep 'answered_by=' | head -1)
T2ROW=$(grep 't2-human-evidence' "$AUDIT_CALLS" | head -1)
COL=$(hev "$t1")

if [[ -n "$COL" && "$COL" != "none" ]]; then
  ok_t "EV0 liveness: the answer landed and recorded a form (human_evidence=$COL)"
else
  bad_t "EV0 liveness: the answer path did not run, so nothing below measures the fix" \
        "col='$COL' out=$(cat "$TMP/ev1.out") err=$(cat "$TMP/ev1.err")"
fi

EV_W=$(argval "$WROW" evidence)
if [[ -n "$EV_W" && "$EV_W" == "$COL" ]]; then
  ok_t "EV1 the audit row's evidence= agrees byte-for-byte with human_evidence ($EV_W)"
else
  bad_t "EV1 the audit row's evidence= must equal the human_evidence column" \
        "row evidence='$EV_W' column='$COL' row='$WROW'"
fi

EV_T2=$(argval "$T2ROW" evidence)
if [[ -n "$EV_T2" ]]; then
  ok_t "EV2 the t2-human-evidence site also names the form (evidence=$EV_T2)"
else
  bad_t "EV2 the tier-2 evidence site must carry evidence= too" \
        "one grep has to span BOTH sites; row='$T2ROW'"
fi

if [[ "$EV_W" == "nonce" ]]; then
  ok_t "EV6 the token vocabulary is DIVE-2412's: a sole-nonce clear reads 'nonce'"
else
  bad_t "EV6 sole-nonce must spell 'nonce' exactly (the column's own word)" \
        "got '$EV_W' — a rename here breaks the join to tasks.human_evidence"
fi

# ── EV5: filer_answered names the filer-of-record relation ───────────────────
FA=$(argval "$WROW" filer_answered)
FILER=$(db "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE id=${t1};")
if [[ -n "$FA" ]]; then
  ok_t "EV5a the row records filer_answered (=$FA, filer of record '$FILER')"
else
  bad_t "EV5a the row must record whether the caller is the gate's filer" "row='$WROW'"
fi

# ── EV3: EXACT-MATCH discrimination in the JSON log shape ────────────────────
# The real audit_log JSON-encodes each arg as its own array element, so the
# closing quote is what makes the sole-nonce grep exact. Build the two rows the
# way audit_log does and prove the discrimination on that shape — asserting it on
# this suite's space-separated stub would grade the stub, not the log.
SOLE=$(_gate_evidence_form 1 0 0 0 0)
COMPOUND=$(_gate_evidence_form 1 0 1 0 0)
JSON_SOLE=$(jq -cn --arg a "evidence=$SOLE" '{args:[$a]}')
JSON_COMPOUND=$(jq -cn --arg a "evidence=$COMPOUND" '{args:[$a]}')
if grep -q '"evidence=nonce"' <<<"$JSON_SOLE" \
   && ! grep -q '"evidence=nonce"' <<<"$JSON_COMPOUND"; then
  ok_t "EV3 '\"evidence=nonce\"' selects sole-nonce and skips '$COMPOUND'"
else
  bad_t "EV3 the sole-nonce grep must not prefix-match a compound value" \
        "sole='$SOLE' compound='$COMPOUND' — token order or separator changed"
fi
if [[ "$COMPOUND" == "nonce+channel-session" ]]; then
  ok_t "EV3b compound tokens keep the fixed order and '+' separator"
else
  bad_t "EV3b compound order/separator is load-bearing for historical sweeps" \
        "got '$COMPOUND', want 'nonce+channel-session'"
fi

# ── EV4: the field is always emitted, with a value ───────────────────────────
# A tier-1 decision answer takes NEITHER of the human-evidence branches, which is
# exactly the path that would otherwise omit the key. `none` is a measurement;
# an absent key is what makes a sweep return a confident zero.
reset
t2=$(addt --assignee=dev -- "fixture tier-1 decision gate")
cmd_task_need "$t2" --type=decision --options="A|B" --recommend="A" \
  --ask="pick one" --tier=1 >/dev/null 2>&1
cmd_task_answer "$t2" --value="B" --human >"$TMP/ev4.out" 2>"$TMP/ev4.err"
WROW2=$(grep 'task answer gate' "$AUDIT_CALLS" | grep 'answered_by=' | head -1)
EV_2=$(argval "$WROW2" evidence)
if [[ -n "$WROW2" && -n "$EV_2" ]]; then
  ok_t "EV4 a tier-1 decision answer still carries evidence= (=$EV_2), key never absent"
else
  bad_t "EV4 evidence= must be present on EVERY write-site row, with a value" \
        "row='$WROW2' — an absent key reads as a confident zero to a sweep"
fi

# ── EV5b: no filer of record -> 'unknown', never '0' ─────────────────────────
UNK=$(_gate_filer_answered 999999 "agent-dev3")
if [[ "$UNK" == "unknown" ]]; then
  ok_t "EV5b a row with no filer of record reads 'unknown', not '0'"
else
  bad_t "EV5b a missing filer must not be reported as a measured 0" "got '$UNK'"
fi
SAME=$(_gate_filer_answered "$t1" "agent-${FILER}")
DIFF=$(_gate_filer_answered "$t1" "agent-nobodyelse")
if [[ "$SAME" == "1" && "$DIFF" == "0" ]]; then
  ok_t "EV5c filer_answered discriminates: same caller=1, different caller=0"
else
  bad_t "EV5c filer_answered must separate the filer from another principal" \
        "same='$SAME' diff='$DIFF' filer='$FILER'"
fi

# ── EV8: the SUDO-UID half of the same defect, which EV0/EV6 do not reach ────
# DIVE-2752. The recorder ORs two variables per form —
# `(( ${_hp:-0} || ${_t2_hp:-0} ))` and `(( ${_su:-0} || ${_t2_su:-0} ))` — because
# the tier-2 floor computes its own copy of each. EV0/EV6 above grade the FIRST
# OR only: measured on d650adc, deleting `|| ${_t2_su:-0}` while leaving the nonce
# half alone left all 44 arms in this file and gate_channel_session_t2_unit.sh
# green. So half of the fix shipped unguarded, and the two halves are separate
# defects rather than one — they are raised by different helpers on different
# inputs, and nothing makes them fail together.
#
# THE SHAPE: a tier-2 DECISION gate cleared by a human ON THE BOX — a dashboard
# exec or an interactive login, no tap, no nonce. `_su` is raised only inside the
# approval/secret/manual/access block (answer.sh:832), which a `decision` gate
# never enters, so `_t2_su` is the ONLY variable carrying that fact and dropping
# it records `none` — a genuine human clear written down as an auto-answer, which
# is the false negative this ticket was filed on.
reset
t8=$(addt --assignee=dev -- "fixture t2 decision gate, human on the box")
cmd_task_need "$t8" --type=decision --options="A|B" --recommend="A" \
  --ask="pick one" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
_PIN_SUDO_HUMAN=0
cmd_task_answer "$t8" --value="A" --human >"$TMP/ev8.out" 2>"$TMP/ev8.err"
_PIN_SUDO_HUMAN=1
COL8=$(hev "$t8")
if [[ "$COL8" == "sudo-uid" ]]; then
  ok_t "EV8 a tier-2 DECISION gate cleared on the box records 'sudo-uid', not 'none'"
else
  bad_t "EV8 the sudo-uid form must reach the column on the tier-2 decision path" \
        "got '$COL8' — 'none' is the DIVE-2752 defect: a human clear recorded as an auto-answer; out=$(cat "$TMP/ev8.out") err=$(cat "$TMP/ev8.err")"
fi

# The pin has to be DIFFERENTIAL or EV8 grades nothing: if a bare `--human` from
# an agent caller also cleared this gate, EV8 would pass on code that never read
# the sudo-uid at all. Same gate shape, pin left at the agent case — the tier-2
# floor must REFUSE, and the refusal must leave no evidence recorded (an rc-only
# arm stays green when the guarded write happens anyway).
reset
t9=$(addt --assignee=dev -- "fixture t2 decision gate, agent caller")
cmd_task_need "$t9" --type=decision --options="A|B" --recommend="A" \
  --ask="pick one" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
out9=$(cmd_task_answer "$t9" --value="A" --human 2>&1); rc9=$?
COL9=$(hev "$t9")
ANS9=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${t9};")
if [[ $rc9 -ne 0 && -z "$ANS9" && ( -z "$COL9" || "$COL9" == "none" ) ]]; then
  ok_t "EV8 ANCHOR: the same gate with an agent caller is REFUSED and records nothing (the pin is live)"
else
  bad_t "EV8 ANCHOR: a bare --human from an agent must not clear a tier-2 gate" \
        "rc=$rc9 answered_at='$ANS9' col='$COL9' out=$out9"
fi

# ── EV7: the real fleet log must carry nothing THIS suite wrote ──────────────
# NOT a byte-offset comparison, and the difference is measured rather than
# stylistic. The sibling guards in tests/gate_answer_audit_unit.sh and
# tests/audit_task_store_fence_unit.sh assert the file did not GROW — which on a
# live shared box is a claim about the whole fleet, not about this suite. Measured
# here 2026-08-05: this arm went red at +1810 bytes and every appended row was
# `"user":"claude"` — another agent's harness (fixture idents DIVE-6..9) running
# concurrently. A guard that reds on someone else's write is a false positive, and
# a false positive on a leak guard is how a leak guard gets deleted.
# So: read only the bytes appended since the offset and look for rows written by
# THIS user with the commands THIS suite invokes. That is the claim the suite can
# actually make. It stays non-vacuous because the fence is what withholds those
# rows — flip FIVEDIVE_PROD_TASKS_DB off the fixture store and they would appear.
LEAKED=""
if [[ -r "$REALLOG" ]]; then
  LEAKED=$(tail -c "+$((REALLOG_OFFSET + 1))" "$REALLOG" 2>/dev/null \
    | jq -rc --arg me "$(id -un 2>/dev/null)" \
        'select(.user == $me) | select(.cmd | startswith("task answer") or startswith("task need")) | .cmd + " " + ((.args // []) | join(" "))' \
        2>/dev/null | head -5)
fi
if [[ -z "$LEAKED" ]]; then
  ok_t "EV7 no row from THIS suite reached the real fleet audit log (fence held)"
else
  bad_t "EV7 this suite leaked fixture rows into the REAL audit log" "$LEAKED"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
