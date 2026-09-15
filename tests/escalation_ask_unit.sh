#!/usr/bin/env bash
# TIER: core
# DIVE-4476 — THE GATE THE PRODUCT WRITES WHEN A LOOP STOPS.
#
# lodar, 2026-09-14 02:36Z, on the DIVE-4471 escalation that reached his phone:
# "confusing phrasing.. do i [open the PR] and submit approve?" — and 02:37Z
# "our human gate is still unfriendly and not fixed then?". What he was sent was
#
#     A piece of work has failed review 2 times and stopped.
#     Decide whether to keep going or drop it.
#     ✋ Tap ✅ Done below once it is handled, which closes this out.
#
# It names NO work, its single button answers NEITHER of the two outcomes it
# offers, and it went to him first. DIVE-4176 fixed this string's READABILITY and
# nothing grades the three properties above, because they are not properties of
# the words: they are the row's title, the gate's TYPE, and its route.
#
# THE CONSTRAINT THAT MAKES THIS HARNESS WORTH HAVING. Naming the row means
# interpolating an agent-written title into an ask that `task need` REFUSES over
# internal vocabulary — and that refusal `exit`s rather than returns, so it would
# make `task reject` itself fail at the iteration cap, which is the one bounce
# that ends a loop (measured on DIVE-4176; see
# community/wiki/the-readability-rule-is-about-the-reader-not-the-tier.md §6).
# So the composer's contract is not "usually readable", it is UNCONDITIONALLY
# FILEABLE, and the hostile titles in section C are the point of the file.
#
# Run: bash tests/escalation_ask_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/escalation-ask.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
_tasks_db_migrate

# --- stubs: nothing leaves the box -------------------------------------------
cmd_send()               { return 0; }
_task_agent_channel()    { return 0; }
_task_send_owner()       { return 0; }
task_need_notify()       { return 0; }
_task_gate_retire_buttons() { return 0; }
audit_log()              { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log()  { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }
# NO LEAD ABOVE THE FILER — the human-fallback condition, which is the ONLY one
# in which the readability and options rules run at all (DIVE-4431: they key on
# the resolved route, not the declared tier). Grading the composer under the
# lead-routed route would grade nothing: every string passes there. Section D
# asserts the routed case separately, with the stub lifted.
_gate_route_reviewer()   { printf ''; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] does not contain [$3]"; fi; }
no_t()  { if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] unexpectedly contains [$3]"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }
rowid() { db "SELECT id FROM tasks WHERE ident='$1';"; }

N=0
seed() { N=$((N+1)); db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status)
      VALUES ('$1', $(sqlq "${2:-a plain internal row}"), 'medium', 'dev', 'main', 'standard', 'todo');"; }

RC=0; OUT=""
# File the gate EXACTLY as src/task/delivery.sh does at the iteration cap: the
# same type, the same two options, the same recommendation, and the ask the
# composer produced for this row. A case that hand-typed the flags would grade a
# gate the product never files.
file_escalation() { # <ident> <iterations> <feedback>
  local _fe_id; _fe_id=$(rowid "$1")
  ESC_ASK=$(_task_escalation_ask "$_fe_id" "$2" "${3:-}")
  OUT=$( (cmd_task_need "$_fe_id" --type=decision --from=quinn \
            --options="$_ESCALATION_OPTIONS" --recommend="$_ESCALATION_RECOMMEND" \
            --ask="$ESC_ASK") 2>&1 ); RC=$?
}

# A real reject's `result` text, in the shape the call site passes: the attributed
# prefix, then the verifier's own FINDING/FIX prose, jargon and all.
FB='❌ quinn rejected (iteration 2): FINDING: the acceptance arm never ran on this branch, `bun test` was green on a stale tree at 3e2ce2fa / FIX: re-run tests/gate_seam.sh against origin/main / VERIFY: the arm reds without the patch'

# ============ PRECONDITION: the composer and the constants exist =============
# Without this every "the gate filed" below is indistinguishable from an empty
# ask sailing through a rule that never saw a defect.
declare -F _task_escalation_ask >/dev/null 2>&1 \
  && ok_t "PRECONDITION: the product's ask composer is reachable in this harness" \
  || bad_t "PRECONDITION: _task_escalation_ask not sourced" "the call site is graded by nothing"
eq_t "PRECONDITION: the two options the call site passes are the two buttons" \
     "$_ESCALATION_OPTIONS" "keep going — send it back for another pass|drop it — stop the work, keep the findings"
has_t "PRECONDITION: the recommendation is one of them, or task need refuses the pair" \
      "$_ESCALATION_OPTIONS" "$_ESCALATION_RECOMMEND"

# ============ A. THE ORDINARY ROW — it names the work and it files ===========
# The defect verbatim: "A piece of work" is every row on the board.
seed ESC-A "Wizard tile ships broken on every box because the relay never landed"
file_escalation ESC-A 2 "$FB"
eq_t  "A1: the escalation gate the product files is READABLE and FILES (rc 0)" "$RC" "0"
eq_t  "A2: ... and it really was written, as a decision" "$(field ESC-A need_type)" "decision"
has_t "A3: the ask NAMES THE WORK (this is the whole defect)" "$ESC_ASK" "Wizard tile ships broken"
no_t  "A4: ... and no longer says 'a piece of work'" "$ESC_ASK" "A piece of work"
has_t "A5: the ask offers the two outcomes as a question" "$ESC_ASK" "Keep going, or drop it?"
no_t  "A6: it does not tell him to tap Done — that button belongs to type=manual" "$ESC_ASK" "Tap"
eq_t  "A7: the two buttons are on the row, so the taps ARE the outcomes" \
      "$(field ESC-A need_options)" "keep going — send it back for another pass|drop it — stop the work, keep the findings"
eq_t  "A8: ... with the lead's default recommended" \
      "$(field ESC-A recommend)" "keep going — send it back for another pass"
eq_t  "A9: a decision gate is tier 1 by type — the human is the FALLBACK, not the destination" \
      "$(field ESC-A tier)" "1"

# ============ B. the sentence is graded, not assumed ========================
# Each assertion here is a property `task need` would refuse on, asserted against
# the string itself so a red names WHICH property moved.
eq_t  "B1: the composed ask is inside the person-facing word cap" \
      "$(( $(_gate_ask_word_count "$ESC_ASK") <= _GATE_ASK_MAX_WORDS ))" "1"
_j=$(_gate_ask_jargon_term "$ESC_ASK" 2>/dev/null) || _j="CLEAN"
eq_t  "B2: ... and carries no ident, sha, branch, path, flag or internal name" "$_j" "CLEAN"
_j=$(_gate_ask_jargon_term "$_ESCALATION_OPTIONS" 2>/dev/null) || _j="CLEAN"
eq_t  "B3: the BUTTONS are held to the same rule (they are read by the same person)" "$_j" "CLEAN"
# The count is the row's own, not a constant: DIVE-4471 stopped at 2 and read as
# "failed review 2 times", which is machine phrasing for a person.
seed ESC-B "Release cut drops a job when the pipe closes early"
file_escalation ESC-B 2 "$FB"
has_t "B4: two bounces reads as 'twice', not '2 times'" "$ESC_ASK" "twice"
seed ESC-B2 "Release cut drops a job when the pipe closes early"
file_escalation ESC-B2 3 "$FB"
has_t "B5: ... and a cap above two still states the count" "$ESC_ASK" "3 times"

# ============ C. THE HOSTILE TITLES — the contract is UNCONDITIONALLY FILEABLE
# Every one of these titles is a real shape from this board. A title that cannot
# be made readable must DEGRADE the ask, never refuse the gate: a refusal here is
# `task reject` failing at the iteration cap, i.e. the loop that stopped also
# loses the gate that would have reported it.
C_TITLES=(
  "DIVE-4462 --options seam leaves bare-letter fixtures unswept"
  "sweepKeySync touches zero boxes at head 3e2ce2fa"
  "src/task/need.sh:2039 defaults approval to tier 1"
  "dive-3754-launcher-entrypoint-overwrite pins the entry point"
  "PR #957 is red on core-pristine"
  "a"
  # The category floor reads the TITLE as well as the ask (_gate_hit_either), so
  # a title carrying a floor word raises this gate to tier 2 — where a
  # recommendation is normally refused as a rubber stamp (DIVE-2848). It is not
  # refused here because that refusal requires a HAND-PINNED --tier=2 and the
  # call site pins nothing; this case is what keeps that true, because the
  # consequence of getting it wrong is `task reject` failing at the cap.
  "Purge the stale credentials and delete every wiped server record"
  "Billing charges a refund twice on an annual subscription"
)
_ci=0
for t in "${C_TITLES[@]}"; do
  _ci=$((_ci+1))
  seed "ESC-C$_ci" "$t"
  file_escalation "ESC-C$_ci" 2 "$FB"
  eq_t "C$_ci: a hostile title still FILES the gate (rc 0) — \"${t:0:38}…\"" "$RC" "0"
  _j=$(_gate_ask_jargon_term "$ESC_ASK" 2>/dev/null) || _j="CLEAN"
  eq_t "C${_ci}b: ... because the unreadable part was DROPPED, not passed through" "$_j" "CLEAN"
  eq_t "C${_ci}c: ... and the degraded ask still asks the decision" \
       "$([[ "$ESC_ASK" == *"Keep going, or drop it?"* ]] && echo yes || echo no)" "yes"
done
# NON-DEGENERATE: C7/C8 only prove anything if the floor actually fired on them.
# A floor word that stopped matching would leave two tier-1 cases wearing the
# label of a tier-2 one, and the arm would pass for the wrong reason.
eq_t "C7-floor: the floor-word title really was raised to tier 2 (or C7 is vacuous)" \
     "$(field ESC-C7 tier)" "2"
eq_t "C8-floor: ... and so was the billing one" "$(field ESC-C8 tier)" "2"

# The floor is reached, not merely survived: a title with nothing readable in it
# must fall all the way back to the subject-free sentence.
seed ESC-C-FLOOR "DIVE-4476"
ESC_FLOOR=$(_task_escalation_ask "$(rowid ESC-C-FLOOR)" 2 "$FB")
eq_t "C-floor: a title that is only an ident degrades to the subject-free sentence" \
     "$ESC_FLOOR" "The work was sent back twice and has stopped. Keep going, or drop it?"

# C-backstop — THE GUARD OF LAST RESORT, GRADED DIRECTLY.
# The composer checks the FINISHED string against the classifier after building
# it word by word. No title can reach that check today (the per-word walk has
# already dropped everything it would catch), so a mutant that deletes it
# SURVIVES the cases above — which means the guard is untested code, and untested
# code in the position "this is what stops `task reject` failing at the cap" is
# the wrong kind of comfort. It is graded here by disabling the per-word walk,
# which is exactly the future in which the guard becomes load-bearing: a
# classifier that gains a rule the word walk cannot express.
_esc_phrase_real=$(declare -f _task_escalation_phrase)
_task_escalation_phrase() { printf '%s' "${1:-}"; }   # let everything through
seed ESC-BACKSTOP "DIVE-4476 regressed the ask at head e131860"
ESC_BACKSTOP=$(_task_escalation_ask "$(rowid ESC-BACKSTOP)" 2 "$FB")
_j=$(_gate_ask_jargon_term "$ESC_BACKSTOP" 2>/dev/null) || _j="CLEAN"
eq_t "C-backstop: with the word walk disabled the FINISHED string is still clean" "$_j" "CLEAN"
eq_t "C-backstop2: ... because it fell all the way to the subject-free floor" \
     "$ESC_BACKSTOP" "The work was sent back twice and has stopped. Keep going, or drop it?"
eval "$_esc_phrase_real"
# The control: the walk really is back, or every case after this grades a stub.
eq_t "C-backstop3: CONTROL — the real phrase builder was restored" \
     "$(_task_escalation_phrase "keep this part DIVE-1 drop that" 9)" "keep this part"

# ============ D. THE ROUTE — a two-strike stop is the lead's call first ======
# DIVE-4346/4365: the orchestrator clears first. The old gate was `manual`, which
# is tier 2 BY TYPE and therefore reached lodar whatever the chart said. This is
# the assertion that the type change is a ROUTING change and not a cosmetic one.
_gate_route_reviewer() { printf 'main'; }
seed ESC-D "Wizard tile ships broken on every box because the relay never landed"
file_escalation ESC-D 2 "$FB"
eq_t "D1: with a lead in the chart the escalation still files (rc 0)" "$RC" "0"
eq_t "D2: ... and it is routed to the LEAD, not parked on the paired human" \
     "$(field ESC-D routed_reviewer)" "main"
# The control that makes D2 mean something: the type it replaced cannot route.
seed ESC-D-OLD "Wizard tile ships broken on every box because the relay never landed"
OUT=$( (cmd_task_need "$(rowid ESC-D-OLD)" --type=manual --from=quinn \
          --ask="A piece of work has failed review 2 times and stopped. Decide whether to keep going or drop it.") 2>&1 )
eq_t "D3: CONTROL — the manual gate it replaced is tier 2 by type, lead or no lead" \
     "$(field ESC-D-OLD tier)" "2"
eq_t "D4: CONTROL — ... and reaches nobody in the chart" \
     "$(field ESC-D-OLD routed_reviewer)" "∅"
_gate_route_reviewer() { printf ''; }

# ============ E. the call site is the one being graded =======================
# Sections A-D grade the composer. This grades that `task reject` at the cap
# actually calls it, with these flags — the seam a later edit is most likely to
# break silently, because nothing else reads it.
CALL=$(grep -A3 'cmd_task_need "\$id" --type=decision --from=' "$SRC/task/delivery.sh")
has_t "E1: the iteration-cap escalation files a DECISION" "$CALL" '--type=decision'
has_t "E2: ... with the two options this harness graded" "$CALL" '--options="$_ESCALATION_OPTIONS"'
has_t "E3: ... and the recommendation" "$CALL" '--recommend="$_ESCALATION_RECOMMEND"'
has_t "E4: ... and the ask comes from the composer, not a literal" "$CALL" '_task_escalation_ask "$id"'
no_t  "E5: no --type=manual survives on the escalation path" \
      "$(grep -c 'cmd_task_need "\$id" --type=manual' "$SRC/task/delivery.sh")" "1"

# ============ F. THE INPUT THE PRODUCT ACTUALLY GIVES THE COMPOSER ===========
# Sections A-C feed the composer a BARE rejection string. The call site does not.
# `cmd_task_reject` passes `fb_txt` AFTER `_task_guard_result_over_closed`
# (src/task/status.sh:122) has merged the MAKER'S OWN PRIOR RESULT in front of the
# verifier's feedback under the DIVE-2483 seam. So every arm above graded the
# composer on input the product never hands it, and a "first colon wins" fallback
# was reading the maker's self-report and showing it to the human AS the verifier's
# finding — on a gate whose two buttons are keep-going / drop-it, which is to say
# it argued for the wrong button with the maker's words.
#
# This is the COMMON path, not the edge: unlabelled feedback is legal (the refusal
# in `cmd_task_reject` requires a FIX label only, and `--no-fix=` is a second legal
# exit carrying neither label), and 196 of 285 rejects recorded on the live board —
# 69% — have no FINDING label. Feed the real shape here, or F grades nothing.
MAKER_RESULT='STATUS: shipped it and went home'
SEAM=$'\n\n--- appended 2026-09-14 04:19:02Z by a later write (DIVE-2483); the text above was already on the row ---\n'
# No FINDING label. Legal, and the majority shape.
FB_NOLABEL='❌ quinn rejected (iteration 2): the acceptance arm never reds without the patch / FIX: re-run it on the merged tree'
PROD_FB="${MAKER_RESULT}${SEAM}${FB_NOLABEL}"

seed ESC-F "Wizard tile ships broken on every box because the relay never landed"
file_escalation ESC-F 2 "$PROD_FB"
eq_t "F1: the production-shaped feedback still files (rc 0)" "$RC" "0"
no_t "F2: THE DEFECT — the MAKER's own result is not quoted to the human as the finding" \
     "$ESC_ASK" "shipped it and went home"
no_t "F3: ... not even a fragment of it" "$ESC_ASK" "shipped"
no_t "F4: ... and the DIVE-2483 merge seam does not leak into the ask either" \
     "$ESC_ASK" "appended"
eq_t "F5: no FINDING label means NO clause — the sentence degrades, it does not invent one" \
     "$ESC_ASK" "Wizard tile ships broken on every box because: sent back twice and stopped. Keep going, or drop it?"

# The control that stops F2-F5 passing vacuously: with a FINDING label present,
# on the SAME merged shape, the clause is still produced. Without this arm a
# composer that returned the floor for everything would grade green above.
FB_LABELLED="${MAKER_RESULT}${SEAM}"'❌ quinn rejected (iteration 2): FINDING: the acceptance arm never reds / FIX: re-run it on the merged tree'
seed ESC-F2 "Wizard tile ships broken on every box because the relay never landed"
file_escalation ESC-F2 2 "$FB_LABELLED"
has_t "F6: CONTROL — a LABELLED finding on the same merged shape still yields its clause" \
      "$ESC_ASK" "(the acceptance arm never reds)"
no_t  "F7: CONTROL — ... and still not the maker's words" "$ESC_ASK" "shipped"

# `--no-fix=<reason>` (DIVE-4144) is the second legal exit: neither label.
seed ESC-F3 "Wizard tile ships broken on every box because the relay never landed"
file_escalation ESC-F3 2 "${MAKER_RESULT}${SEAM}"'❌ quinn rejected (iteration 2): I cannot name the fix: the failure is not reproducible from here'
no_t "F8: a --no-fix bounce carries neither label, and still quotes nobody" "$ESC_ASK" "shipped"

# ============ G. the clause builder's own edges =============================
# All three found by quinn on the same builder; all three reach a person.
seed ESC-G1 "Wizard tile ships broken on every box because the relay never landed"
file_escalation ESC-G1 1 "$FB"
no_t "G1: a one-strike loop (max_iterations=1, legal) does not say '1 times'" "$ESC_ASK" "1 times"
has_t "G2: ... it says 'once'" "$ESC_ASK" "sent back once"

# The reject template's " / " between FINDING and FIX is a convention, not a rule.
seed ESC-G2 "Wizard tile ships broken on every box because the relay never landed"
file_escalation ESC-G2 2 '❌ quinn rejected (iteration 2): FINDING: the relay never lands FIX: re-run the installer'
no_t "G3: the FIX label does not leak into the clause when the ' / ' is absent" "$ESC_ASK" "FIX"
has_t "G4: ... the finding half still survives the cut" "$ESC_ASK" "(the relay never lands)"

# A phrase cut mid-clause must not end on a dangling function word.
eq_t "G5: 'but' dangles like every other function word and is trimmed" \
     "$(_task_escalation_phrase 'the tile renders but the relay never lands' 4)" "the tile renders"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
