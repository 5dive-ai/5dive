#!/usr/bin/env bash
# DIVE-3493 — the VALIDATOR and the ENFORCING READER must accept the same YAML.
#
# `authority.gate_clear_leads` is written through `council amend` / `constitution set`
# (validated by src/council/engine.mjs, node) and enforced by `_gate_clear_leads`
# (src/task/need.sh, node-free bash). Before this harness the two accepted DISJOINT
# subsets: the validator threw `use inline arrays in constitution v0` on a block sequence
# while the reader returns rc=1 on an inline flow one — so the key could not be set
# through any path, and the shipped template's own worked example (a block sequence)
# failed the validator shipping beside it.
#
# The invariant graded here is not "block sequences parse". It is the AGREEMENT:
#
#   for every document, if the validator ACCEPTS it with a non-empty gate_clear_leads,
#   the bash reader must return the SAME list — and if the reader would deny, the
#   validator must REFUSE the document rather than seal bytes nobody will enforce.
#
# The second half is the security half. A document that validates and seals while the
# enforcer denies every name it lists is a silent false grant: the refusal reason it
# emits (`no-gate-clear-leads-key`) is indistinguishable from "never sealed", so it does
# not surface itself.
#
# Run: bash tests/constitution_authority_shape_agreement.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/constitution-shape-agreement.XXXXXX)"

STATE_DIR="$TMP"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_council.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
COUNCIL_DIR="$STATE_DIR/council"; COUNCIL_LINEAGE="$COUNCIL_DIR/lineage.jsonl"
mkdir -p "$STATE_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node is required to grade the validator half"; exit 0; }

# --- the two halves, each fed the same bytes ---------------------------------------
# validator: prints the normalized list one name per line, or `INVALID <message>`.
validate() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs"
    const E = await import(process.argv[1])
    try {
      const c = E.normalizeConstitution(E.parseConstitutionFrontmatter(readFileSync(process.argv[2], "utf8")))
      process.stdout.write(c.authority.gateClearLeads.join("\n"))
    } catch (e) { process.stdout.write("INVALID " + String(e && e.message || e)) }
  ' "$PWD/src/council/engine.mjs" "$1" 2>&1
}
# reader: the shipped bash enforcer, against a SEALED copy of the same bytes.
read_bash() {
  cp "$1" "$STATE_DIR/constitution.yaml"
  mkdir -p "$COUNCIL_DIR"
  printf '{"seq":1,"record":{"constitutionDigest":"%s"}}\n' \
    "$(sha256sum < "$STATE_DIR/constitution.yaml" | awk '{print $1}')" > "$COUNCIL_LINEAGE"
  _gate_clear_leads 2>/dev/null
}

doc() { printf '%s' "$2" > "$TMP/$1.yaml"; printf '%s' "$TMP/$1.yaml"; }

# --- A0 THE READER UNDER TEST IS THE SHIPPED ONE -------------------------------------
# "the node-free reader is UNTOUCHED" is the whole safety argument of this change, and an
# untouched file is only safe if it is the file being exercised. A copy, a stub, or a
# stale sourced bundle would grade the same green. Name it.
shopt -s extdebug
reader_src="$(declare -F _gate_clear_leads | awk '{print $3}')"
shopt -u extdebug
[[ "$reader_src" == *"src/task/need.sh" && -f "$reader_src" ]] \
  && ok_t "A0 the enforcing reader under test is the real src/task/need.sh ($reader_src)" \
  || bad_t "A0 reader provenance" "_gate_clear_leads came from '${reader_src:-nowhere}', not src/task/need.sh"
git diff --quiet HEAD -- src/task/need.sh 2>/dev/null \
  && ok_t "A0 src/task/need.sh is unmodified against HEAD — the reader is not being bent to fit" \
  || bad_t "A0 reader untouched" "src/task/need.sh differs from HEAD; the safety argument of this change is that it does not"

# --- A1..A3 THE AGREEMENT: accepted + non-empty => the reader reads the same names ---
# Both indentations, because YAML permits a block sequence at its key's own indent as
# well as one level in, and the bash reader accepts both. A validator that took only one
# would re-open the same asymmetry in a narrower form.
for case in "indented:    - main
    - olivia
" "flush:  - main
  - olivia
"; do
  name="${case%%:*}"; body="${case#*:}"
  f="$(doc "block_$name" "ship:
comms:
authority:
  eng_approval_lead: main
  gate_clear_leads:
$body")"
  v="$(validate "$f")"; b="$(read_bash "$f")"
  [[ "$v" == $'main\nolivia' ]] \
    && ok_t "A1/$name the validator ACCEPTS a block sequence and normalizes both names" \
    || bad_t "A1/$name validator" "got '$v'"
  [[ "$v" == "$b" ]] \
    && ok_t "A2/$name validator and enforcing reader return the IDENTICAL list" \
    || bad_t "A2/$name agreement" "validator='$v' reader='$b'"
done

# A3 — the template's own worked example must pass the validator shipping beside it.
node --input-type=module -e '
  const E = await import(process.argv[1]); process.stdout.write(E.renderConstitutionV0())
' "$PWD/src/council/engine.mjs" > "$TMP/rendered.yaml" 2>/dev/null
# The example is commented out in the template, so strip exactly the comment marker and
# the one indent level the comment adds — relative indentation is the thing under test.
tmpl="$(grep -A2 '^#       gate_clear_leads:$' "$TMP/rendered.yaml" | sed 's/^#     //')"
if [[ "$tmpl" == *"- main"* ]]; then
  f="$(doc tmpl "ship:
comms:
authority:
$tmpl
")"
  v="$(validate "$f")"; b="$(read_bash "$f")"
  [[ "$v" != INVALID* && -n "$v" && "$v" == "$b" ]] \
    && ok_t "A3 the SHIPPED TEMPLATE's worked example validates and reads back identically" \
    || bad_t "A3 template example" "validator='$v' reader='$b'"
else
  bad_t "A3 template example" "could not extract the gate_clear_leads example from renderConstitutionV0()"
fi

# --- A4 THE SECURITY HALF: a shape the reader denies must not VALIDATE ---------------
# This is the arm that fires on the false grant. An inline flow sequence names holders,
# validates, seals — and then the enforcer denies all of them. Refusing it at write time
# is what keeps the sealed bytes and the enforced authority the same document.
f="$(doc flow "ship:
comms:
authority:
  gate_clear_leads: [main, olivia]
")"
v="$(validate "$f")"; b="$(read_bash "$f")"
[[ -z "$b" ]] \
  && ok_t "A4 (control) the enforcing reader does deny the inline flow form" \
  || bad_t "A4 control" "the reader accepted the flow form ('$b') — the premise of this arm is gone"
[[ "$v" == INVALID*block\ sequence* ]] \
  && ok_t "A4 a NON-EMPTY inline flow list is REFUSED by the validator, naming the block form" \
  || bad_t "A4 flow refused" "got '$v'"

# A5 — an EMPTY `[]` stays valid. It grants nobody under either half, it is the
# documented safe default, and reddening it would fail a document already correct.
f="$(doc flowempty "ship:
comms:
authority:
  gate_clear_leads: []
")"
v="$(validate "$f")"
[[ "$v" == "" ]] \
  && ok_t "A5 an EMPTY inline list stays valid (both halves grant nobody — the safe default)" \
  || bad_t "A5 empty flow" "got '$v'"

# --- A6 THE WRITER: a structured guardrail edit must not rewrite the shape ------------
# `constitution set --json` re-serializes the WHOLE document. An inline emitter there
# converts a sealed block list into the form the reader treats as absent — revoking the
# allowlist as a side effect of editing an unrelated section.
f="$(doc writer "ship:
comms:
authority:
  gate_clear_leads:
    - main
    - olivia
")"
merged="$(printf '{"ship":{"require_ci":true}}' | node src/council/cli.mjs constitution-merge --path="$f" 2>"$TMP/merge.err")"
if [[ -n "$merged" ]]; then
  printf '%s' "$merged" > "$TMP/merged.yaml"
  v="$(validate "$TMP/merged.yaml")"; b="$(read_bash "$TMP/merged.yaml")"
  [[ "$v" == $'main\nolivia' && "$v" == "$b" ]] \
    && ok_t "A6 constitution-merge round-trips the block list through BOTH halves intact" \
    || bad_t "A6 merge round-trip" "validator='$v' reader='$b'"
  grep -q 'gate_clear_leads: \[' "$TMP/merged.yaml" \
    && bad_t "A6 merge shape" "the writer emitted the inline form the reader cannot read" \
    || ok_t "A6 the writer emits a BLOCK sequence, not the unreadable inline form"
else
  bad_t "A6 merge round-trip" "constitution-merge produced nothing ($(head -c 200 "$TMP/merge.err"))"
fi

# --- A7 the parser stays a STRICT subset ---------------------------------------------
# Widening it to "some YAML" is how a reader ends up granting authority from bytes nobody
# verified. Each of these must throw rather than be partially interpreted.
while IFS='|' read -r label body; do
  [[ -n "$label" ]] || continue
  f="$(doc "strict_$label" "$(printf '%b' "$body")")"
  v="$(validate "$f")"
  [[ "$v" == INVALID* ]] \
    && ok_t "A7 rejected: $label" \
    || bad_t "A7 $label" "accepted, got '$v'"
done <<'CASES'
a mapping inside a block sequence|authority:\n  gate_clear_leads:\n    - name: main\n
a nested sequence inside one|authority:\n  gate_clear_leads:\n    - [a, b]\n
a mapping and a sequence under one key|authority:\n  gate_clear_leads:\n    - main\n    foo: 1\n
a key under a block sequence|authority:\n  gate_clear_leads:\n    - main\n  gate_clear_leads:\n
an empty sequence entry|authority:\n  gate_clear_leads:\n    -\n
a sequence with no owning key|- main\n
CASES

# --- A8 THE CONTROL, INSIDE THE HARNESS ----------------------------------------------
# A green suite proves nothing unless the same suite can go red. So run A1 and A4 against
# the PRE-FIX validator (main's own bytes) and require them to fail in the two specific
# directions this row exists to close. A substitution that silently did not apply and a
# test that cannot fail look identical from the outside — both all-green — so the swap is
# asserted BEFORE the arms: the mutant must differ from the file under test, and it must
# still be importable. If either check cannot be made, this is a FAIL, never a skip.
# The control MUTATES the current validator rather than fetching the pre-fix one: a git ref
# is a moving target (once this lands, `origin/main` carries the fix and a base-ref control
# silently inverts), while a mutation stays valid for as long as the code it removes exists.
mutant_validate() {
  node --input-type=module -e '
    import { readFileSync } from "node:fs"
    const E = await import(process.argv[1])
    try {
      const c = E.normalizeConstitution(E.parseConstitutionFrontmatter(readFileSync(process.argv[2], "utf8")))
      process.stdout.write(c.authority.gateClearLeads.join("\n"))
    } catch (e) { process.stdout.write("INVALID " + String(e && e.message || e)) }
  ' "$1" "$2" 2>&1
}
# $1 label · $2 sed program · $3 document · $4 expected output
mutate_and_expect() {
  local label="$1" prog="$2" docf="$3" want="$4" m="$TMP/mutant.$RANDOM.mjs" got
  sed "$prog" src/council/engine.mjs > "$m"
  if cmp -s "$m" src/council/engine.mjs; then
    bad_t "A8 mutation '$label' DID NOT APPLY" "the mutant is byte-identical to the validator under test — this arm proves nothing, and a mutation that silently missed looks exactly like a passing test"
    return
  fi
  ok_t "A8 mutation '$label' landed (mutant differs from the file under test)"
  got="$(mutant_validate "$m" "$TMP/flowempty.yaml")"
  [[ "$got" == "" ]] \
    && ok_t "A8 mutation '$label': the mutant still LOADS (its red below is the mutation, not a syntax error)" \
    || bad_t "A8 mutation '$label' unusable" "the mutant failed on a document every version accepts ('$got')"
  got="$(mutant_validate "$m" "$docf")"
  [[ "$got" == "$want" ]] \
    && ok_t "A8 mutation '$label' goes RED as required — this suite can fail" \
    || bad_t "A8 mutation '$label' did not go red" "wanted '$want', got '$got'"
}
# M1 — remove block-sequence support: the block form must stop validating, which is the bug
# this row closes and the shape the enforcing reader is the only consumer of.
mutate_and_expect 'block sequences unsupported (the pre-fix parser)' \
  's#frame\.value\.push(val)#throw new Error("mutant: use inline arrays in constitution v0")#' \
  "$TMP/block_indented.yaml" 'INVALID mutant: use inline arrays in constitution v0'
# M2 — remove the flow refusal: a list the enforcer denies must start validating again. This
# is the security arm; if it cannot be made to fail, the guard is not being exercised.
mutate_and_expect 'flow refusal removed (the silent false grant)' \
  's|authority\.gate_clear_leads\.yamlFlow|false|' \
  "$TMP/flow.yaml" "$(printf 'main\nolivia')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
