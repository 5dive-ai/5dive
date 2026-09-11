#!/usr/bin/env bash
# DIVE-4324 isolated unit harness — the review mode is CHOSEN AT FILING.
#
# lodar, 2026-09-11: "I think it should be per task. easy tasks no reviewer at
# all. some with spawnable temp reviewer some with agent reviewer .. encoded
# into 5dive and 5dive skill"
#
# WHAT IS ASSERTED, AND WHY IT IS THE PERSISTED COLUMN AND NOT THE PRINTED LINE.
# All four modes were reachable before this row through four unrelated flags, so
# a test that only read the notice would pass against a build that printed the
# mode and stored nothing — and the whole point of the column is that a CHOICE
# and a DEFAULT stop being the same stored state. Every arm below therefore
# reads `tasks.review_mode` (plus the flag column the alias is supposed to have
# set), and only the two surface arms read output.
#
# THE MUTATION ARM IS NOT DECORATION. Nine of these arms are satisfied by a
# resolver that simply prints 'temp' for anything not opted out, so the harness
# breaks the box-policy term in `_task_effective_review_mode` and asserts the
# capped arms go RED. If they stay green the matrix is measuring nothing, and
# that is reported as a FAIL of this harness, not a pass.
#
# Same isolation contract as the other task harnesses: src/ sourced directly,
# STATE_DIR on a throwaway temp dir, BOX_CONFIG inside it, so the live box's
# policy is never read and the shared tasks.db is never touched.
# Run: bash tests/task_review_mode_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-review-mode.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

# ok_t / bad_t, never ok / fail: src/lib/output.sh owns those two names and a
# harness that redefines them breaks the very code it is grading.
PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1

# A distinct grader always exists, so an EMPTY verifier can only mean the mode or
# the policy declined — never "none was available", which is a third state
# (verify_unavailable) that would make negative arms pass for a wrong reason.
_task_default_verifier() { printf 'grader'; }
# Lane validation needs a live org; the modes under test are about WHICH
# reviewer, not whether that seat exists, and DIVE-4324 changes nothing there.
_task_require_lane() { return 0; }

set_policy() { printf '{"verify":"%s"}\n' "$1" > "$BOX_CONFIG"; }
set_policy always

# add_row <label> [flags...] -> echoes "<review_mode>|<verifier>|<optout>|<forced>|<verify_cmd>"
add_row() {
  local label="$1"; shift
  local out ident
  out=$(cmd_task_add "$label $RANDOM" --assignee=dev2 --from=main --priority=high "$@" 2>/dev/null)
  ident=$(jq -r '.data.ident // empty' <<<"$out" 2>/dev/null)
  [[ -n "$ident" ]] || { printf '__ADD_FAILED__'; return 0; }
  db "SELECT COALESCE(review_mode,'')||'|'||COALESCE(verifier,'')||'|'||COALESCE(verify_optout,0)
             ||'|'||COALESCE(verify_forced,0)||'|'||COALESCE(verify_command,'')
        FROM tasks WHERE ident=$(sqlq "$ident");"
}
mode_of() { add_row "$@" | cut -d'|' -f1; }

expect_mode() { # <label> <want> <flags...>
  local label="$1" want="$2"; shift 2
  local got; got=$(mode_of "$label" "$@")
  [[ "$got" == "$want" ]] && ok_t "$label -> $want" || bad_t "$label -> $want" "review_mode='$got'"
}

echo "── the four modes, explicitly chosen ────────────────────────────"
expect_mode "review none"  none        --review=none
expect_mode "review check" check       --review=check --verify="npm test"
expect_mode "review temp"  temp        --review=temp
expect_mode "review seat"  seat:quinn  --review=quinn

echo "── the alias sets the flag the mode is built on ─────────────────"
_r=$(add_row "alias none" --review=none)
[[ "$(cut -d'|' -f3 <<<"$_r")" == "1" ]] && ok_t "--review=none writes verify_optout=1" \
  || bad_t "--review=none writes verify_optout=1" "row='$_r'"
_r=$(add_row "alias temp" --review=temp)
[[ "$(cut -d'|' -f4 <<<"$_r")" == "1" && -n "$(cut -d'|' -f2 <<<"$_r")" ]] \
  && ok_t "--review=temp demands a grader (verify_forced=1, verifier set)" \
  || bad_t "--review=temp demands a grader" "row='$_r'"
_r=$(add_row "alias seat" --review=quinn)
[[ "$(cut -d'|' -f2 <<<"$_r")" == "quinn" ]] && ok_t "--review=<seat> pins that seat as verifier" \
  || bad_t "--review=<seat> pins that seat" "row='$_r'"

echo "── refusals: a contradiction is never silently ordered ──────────"
refuses() { # <label> <substring> <flags...>
  local label="$1" want="$2"; shift 2
  local out; out=$(cmd_task_add "refusal $RANDOM" --assignee=dev2 --from=main "$@" 2>&1)
  [[ "$out" == *"$want"* ]] && ok_t "$label" || bad_t "$label" "got: ${out:0:170}"
}
refuses "--review=check without --verify=<cmd> is refused" "needs the command"  --review=check
refuses "--review=none + --verify is refused"              "contradict"         --review=none --verify
refuses "--review=none + --verifier= is refused"           "contradict"         --review=none --verifier=quinn
refuses "--review=temp + --verifier= is refused"           "contradict"         --review=temp --verifier=quinn
refuses "--review=<seat> + --no-verify is refused"         "contradict"         --review=quinn --no-verify
refuses "--review= with two different seats is refused"    "two different"      --review=quinn --verifier=olivia
refuses "a malformed --review value is refused"            "bad --review value" '--review=not a seat!'

echo "── the DEFAULT RULE, when the filer passes nothing ──────────────"
# Restored per-arm: the harness stubs the classifier open for the policy arms
# below, and a default-rule arm that ran against the stub would measure nothing.
expect_mode "plain code row defaults to"      temp        --body="Refactor the dispatcher so the claim path is one function."
expect_mode "low priority defaults to"        none        --priority=low --body="something real"
expect_mode "tagged mechanical defaults to"   none        --body=$'tag: mechanical\nbump the pinned version in three manifests'
expect_mode "tagged doc defaults to"          none        --body=$'kind: doc\nfix the install section wording'
expect_mode "single read-back command row"    none        --body='5dive task ls --json | jq ".data.tasks | length"'
expect_mode "customer-facing row pins a seat" seat:grader --customer --body="the wizard tile renders the wrong price"
# The negative control for the two new body arms: prose that MENTIONS docs must
# keep its grader, or the arms above are matching sentences, not declarations.
expect_mode "prose mentioning docs keeps its grader" temp \
  --body="The docs are wrong because the mechanical copy path in the dispatcher drops a field; fix the code."

echo "── the box policy CAPS the mode (never wins) ────────────────────"
_task_verify_skip_reason() { printf ''; }   # isolate the policy from the classifier
set_policy never
expect_mode "verify=never + no flag"        none  --body="a real code row"
expect_mode "verify=never + --review=temp"  temp  --review=temp --body="a real code row"
expect_mode "verify=never + --review=check" check --review=check --verify="npm test" --body="a real code row"
set_policy delivered-only
expect_mode "verify=delivered-only defers, it does not refuse" temp --body="a real code row"
set_policy always

echo "── the mode is SURFACED (task show / task ls) ───────────────────"
JSON_MODE=0
_o=$(cmd_task_add "surfaced row $RANDOM" --assignee=dev2 --from=main --priority=high --review=none 2>/dev/null)
_i=$(sed -n 's/.*created \(DIVE-[0-9]*\).*/\1/p' <<<"$_o" | head -1)
[[ "$_o" == *"review: none"* ]] && ok_t "'task add' prints the mode with its cost" \
  || bad_t "'task add' prints the mode" "got: ${_o:0:200}"
_s=$(cmd_task_show "$_i" 2>/dev/null)
[[ "$_s" == *"review: none"* ]] && ok_t "'task show' prints the mode" \
  || bad_t "'task show' prints the mode" "no review line for $_i"
_l=$(cmd_task_ls 2>/dev/null)
[[ "$_l" == *"review"* ]] && ok_t "'task ls' carries a review column" \
  || bad_t "'task ls' carries a review column" "got: ${_l:0:200}"
# A row filed before the column existed must read as UNRECORDED, never as 'none'
# — that distinction is the column's stated contract.
db "UPDATE tasks SET review_mode=NULL WHERE ident=$(sqlq "$_i");"
_s=$(cmd_task_show "$_i" 2>/dev/null)
[[ "$_s" == *"review: unrecorded"* ]] && ok_t "a NULL review_mode reads as unrecorded, not as none" \
  || bad_t "a NULL review_mode reads as unrecorded" "got: $(grep -i review <<<"$_s" | head -1)"
JSON_MODE=1

echo "── MUTATION: break the policy cap, the capped arms must go RED ──"
_real_resolver=$(declare -f _task_effective_review_mode)
_task_effective_review_mode() { [[ -n "${1:-}" ]] && printf 'none' || printf 'temp'; }
set_policy never
_mut=$(mode_of "mutant" --body="a real code row")
if [[ "$_mut" == "none" ]]; then
  bad_t "MUTATION DETECTED the policy cap" \
        "with the box-policy term removed the capped arm STILL read 'none' — this harness is not measuring the cap"
else
  ok_t "MUTATION DETECTED the policy cap (capped arm went red: '$_mut')"
fi
eval "$_real_resolver"
set_policy always
_back=$(mode_of "restored" --body="a real code row")
[[ "$_back" == "temp" ]] && ok_t "resolver restored after the mutation" \
  || bad_t "resolver restored after the mutation" "got '$_back'"

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAILN"
[[ $FAILN -eq 0 ]]
