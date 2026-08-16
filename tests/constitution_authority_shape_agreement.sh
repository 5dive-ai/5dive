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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
