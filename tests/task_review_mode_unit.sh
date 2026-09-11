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
# THE MUTATION ARMS MUTATE THE SHIPPING PREDICATE, NEVER A STUB. The first
# version of this harness replaced the whole resolver with
# `{ [[ -n "$1" ]] && printf 'none' || printf 'temp'; }` and then asserted only
# that the answer was not 'none' — a different function, ignoring six of its
# seven parameters, satisfying the assertion trivially. It proved that a stub
# returning 'temp' returns 'temp', and it stayed green when quinn deleted the
# ACTUAL box-policy term (iteration 2). So every arm below cuts a NAMED TERM out
# of `declare -f` output of the function that ships, checks that the cut landed
# (a sed matching nothing would leave the arm green having mutated nothing), and
# requires the arms that term guards to CHANGE ANSWER. If they do not, that is a
# FAIL of this harness, not a pass.
#
# WHERE THE CAP LIVES, since it takes two mutations to cover: `verify=never`
# reaches the mode by two independent routes — `verify_grants_grader` refusing,
# which stops a grader being assigned at all, and the `_grants` term in
# `_task_effective_review_mode`, which is what refuses a verifier the row
# already names (`--review=<seat>` / `--verifier=<seat>`). Mutating either alone
# leaves the other's arms green, so both are mutated.
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
# `temp` books the pool grader, and it must do so WITHOUT writing verify_forced.
# That column is `--verify`'s DIVE-4251 override of the BOX, and setting it here
# is what let any filer defeat `verify=never` by typing --review=temp
# (iteration 2, FINDING 1). The demand it does carry is over the code's own
# title/priority classifier, asserted two sections down.
_r=$(add_row "alias temp" --review=temp)
[[ -n "$(cut -d'|' -f2 <<<"$_r")" && "$(cut -d'|' -f4 <<<"$_r")" == "0" ]] \
  && ok_t "--review=temp books the pool grader and does NOT set verify_forced" \
  || bad_t "--review=temp books the pool grader without verify_forced" "row='$_r'"
_r=$(add_row "alias seat" --review=quinn)
[[ "$(cut -d'|' -f2 <<<"$_r")" == "quinn" && "$(cut -d'|' -f4 <<<"$_r")" == "0" ]] \
  && ok_t "--review=<seat> pins that seat as verifier, without verify_forced" \
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
# The other half of `--review=temp`: it OVERRULES the classifier that would have
# auto-skipped this row. Same rows as the low-priority and tagged-mechanical
# arms above, one flag apart. Without these, dropping verify_forced would have
# made --review=temp a control that silently does nothing on exactly the rows a
# filer reaches for it on.
expect_mode "temp overrules the low-priority auto-skip" temp --review=temp --priority=low --body="something real"
expect_mode "temp overrules the tagged-mechanical auto-skip" temp --review=temp --body=$'tag: mechanical\nbump the pinned version in three manifests'

echo "── the box policy CAPS the mode (never wins) ────────────────────"
# THE ROW'S ACCEPTANCE CRITERION, VERBATIM: "`verify=never` box policy overrides
# all to none." Iteration 1 of this file encoded the OPPOSITE for `temp` and had
# no arm at all for `<seat>`, so the suite asserted the escape was correct
# (quinn, iteration 2, FINDING 1). Both modes BOOK A SESSION and `never` is the
# box's statement about that spend, so both are capped. `check` is the one
# exemption — a command spends nothing, so a spend control has nothing to refuse
# — and bare `--verify` stays the one way to buy a single row back.
_task_verify_skip_reason() { printf ''; }   # isolate the policy from the classifier
set_policy never
expect_mode "verify=never + no flag"           none  --body="a real code row"
expect_mode "verify=never + --review=temp"     none  --review=temp --body="a real code row"
expect_mode "verify=never + --review=<seat>"   none  --review=quinn --body="a real code row"
expect_mode "verify=never + --verifier=<seat>" none  --verifier=quinn --body="a real code row"
expect_mode "verify=never + --review=check"    check --review=check --verify="npm test" --body="a real code row"
expect_mode "verify=never + bare --verify buys the row back" temp --verify --body="a real code row"

# FINDING 2: the two spellings must land on the SAME ROW, or `--review=` is a
# fifth mechanism and not an alias. Iteration 1 failed this under `never`:
# `--verifier=quinn` gave none/forced=0 and `--review=quinn` gave seat:quinn/
# forced=1 — one stated intent, two different rows, and the extra forced=1 was
# the fifth mechanism. Asserted on EVERY stored field, under both policies, so a
# future divergence on any of them is a failure and not a thing to notice later.
# (`--verifier=` has pinned its seat since before this row — crud.sh:65 — which
# is why the mode agrees too, not only the flags.)
_a=$(add_row "spelling review"   --review=quinn   --body="a real code row")
_b=$(add_row "spelling verifier" --verifier=quinn --body="a real code row")
[[ "$_a" == "$_b" ]] \
  && ok_t "under verify=never --review=<seat> and --verifier=<seat> store the identical row ($_a)" \
  || bad_t "under verify=never the two spellings store the identical row" "--review='$_a' vs --verifier='$_b'"
set_policy always
_a=$(add_row "spelling review always"   --review=quinn   --body="a real code row")
_b=$(add_row "spelling verifier always" --verifier=quinn --body="a real code row")
[[ "$_a" == "$_b" ]] \
  && ok_t "under verify=always the two spellings store the identical row ($_a)" \
  || bad_t "under verify=always the two spellings store the identical row" "--review='$_a' vs --verifier='$_b'"

# PRECEDENCE, the rung the resolver's header calls the non-obvious one and which
# nothing policed until now: a row carrying BOTH a pinned seat and a command is
# graded by the person; the command is that person's instrument.
expect_mode "a pinned seat outranks check" seat:quinn --review=quinn --verify="npm test" --body="a real code row"

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
# A CAP THE FILER IS NOT TOLD ABOUT is the no-op-that-looks-like-a-control this
# file's seven refusal arms exist to prevent. Now that `never` caps `temp`, the
# created line must name what overruled the flag.
set_policy never
_c=$(cmd_task_add "capped row $RANDOM" --assignee=dev2 --from=main --priority=high --review=temp --body="a real code row" 2>/dev/null)
[[ "$_c" == *"you asked for 'temp'"* && "$_c" == *"verify=never"* ]] \
  && ok_t "a capped --review is SAID on the created line, not silently downgraded" \
  || bad_t "a capped --review is said on the created line" "got: ${_c:0:240}"
set_policy always
JSON_MODE=1

echo "── MUTATION: break the SHIPPING predicate, the arms it guards must go RED ──"
# Never a stub. See the header: substituting a different function for the
# resolver proved only that the substitute returns what it returns. Each arm
# here cuts a NAMED TERM out of `declare -f` of the function that ships, proves
# the cut landed (a sed that matched nothing would leave the arm green having
# mutated nothing), and requires the arms that term guards to change answer.
_real_resolver=$(declare -f _task_effective_review_mode)
_real_grants=$(declare -f verify_grants_grader)

mutate() { # <function> <sed-expr> <label>
  local fn="$1" expr="$2" label="$3" src mutated
  src=$(declare -f "$fn")
  mutated=$(sed "$expr" <<<"$src")
  if [[ "$mutated" == "$src" ]]; then
    bad_t "mutation landed: $label" "the sed matched nothing in $fn — the arm below would have passed having mutated nothing"
    return 1
  fi
  eval "$mutated" 2>/dev/null || { bad_t "mutation landed: $label" "the mutated $fn does not parse"; return 1; }
  ok_t "mutation landed: $label"
}

# M1 — the `_grants` term in the resolver. It is what refuses a verifier the row
# ALREADY NAMES, so the arms it uniquely guards are the two seat-under-never
# arms; quinn measured both flipping none -> temp with it deleted.
set_policy never
if mutate _task_effective_review_mode '/\[\[ "\$_grants" == 1 \]\] ||/,+3d' 'delete the box-policy term from _task_effective_review_mode'; then
  _m1=$(mode_of "mut cap review-seat" --review=quinn   --body="a real code row")
  _m2=$(mode_of "mut cap verifier"    --verifier=quinn --body="a real code row")
  [[ "$_m1" != "none" && "$_m2" != "none" ]] \
    && ok_t "MUTATION DETECTED the box-policy term (capped seat arms went red: '$_m1' / '$_m2')" \
    || bad_t "MUTATION: the box-policy term is NOT measured" \
             "with the term deleted the capped seat arms still read '$_m1' / '$_m2' — these arms are not policing the cap"
fi
eval "$_real_resolver"

# M2 — the `never` arm of verify_grants_grader, the OTHER route the cap takes:
# it stops a grader being assigned at all, which is what caps the rows that name
# no verifier. Flipped to `return 0` rather than deleted, so the case stays
# syntactically whole and the mutation is a wrong ANSWER, not a parse error.
if mutate verify_grants_grader '/never)/{n;s/return 1/return 0/;}' 'flip the never arm of verify_grants_grader to grant'; then
  _m3=$(mode_of "mut never plain" --body="a real code row")
  _m4=$(mode_of "mut never temp"  --review=temp --body="a real code row")
  [[ "$_m3" != "none" && "$_m4" != "none" ]] \
    && ok_t "MUTATION DETECTED the never policy (capped arms went red: '$_m3' / '$_m4')" \
    || bad_t "MUTATION: the never policy is NOT measured" \
             "with never granting, the capped arms still read '$_m3' / '$_m4'"
fi
eval "$_real_grants"

# M3 — the pinned-seat rung. Deleting it makes `check` win, so the precedence
# arm above must change answer. Undetected before this file was rewritten.
set_policy always
if mutate _task_effective_review_mode '/\[\[ "\$_pinned" == 1/,+3d' 'delete the seat-outranks-check rung from _task_effective_review_mode'; then
  _m5=$(mode_of "mut precedence" --review=quinn --verify="npm test" --body="a real code row")
  [[ "$_m5" != "seat:quinn" ]] \
    && ok_t "MUTATION DETECTED the seat-outranks-check rung (precedence arm went red: '$_m5')" \
    || bad_t "MUTATION: the seat-outranks-check rung is NOT measured" "the precedence arm still read '$_m5'"
fi
eval "$_real_resolver"

# The whole-resolver constant, kept from iteration 1 because quinn measured it
# failing TWELVE arms: it is the breadth check, not the cap check.
_task_effective_review_mode() { printf 'temp'; }
_m6=$(mode_of "mut constant" --review=none)
[[ "$_m6" != "none" ]] && ok_t "MUTATION DETECTED a constant resolver (mode arm went red: '$_m6')" \
  || bad_t "MUTATION: a constant resolver is NOT measured" "got '$_m6'"
eval "$_real_resolver"

_back=$(mode_of "restored" --body="a real code row")
[[ "$_back" == "temp" ]] && ok_t "resolver and policy restored after the mutations" \
  || bad_t "resolver restored after the mutations" "got '$_back'"

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAILN"
[[ $FAILN -eq 0 ]]
