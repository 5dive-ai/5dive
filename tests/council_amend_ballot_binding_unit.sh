#!/usr/bin/env bash
# DIVE-2889 — the amend BALLOT MINT must refuse a motion it cannot bind, and must carry the
# candidate's path + FULL digest + diff-vs-live into the ballot body.
#
# Incident: the eng_approval_lead amendment was balloted TWICE on digest 6498adcb…, which resolves
# to no file anywhere on disk, while both approving rationales claimed "I verified the on-disk
# content directly" — true statements about the LIVE constitution (8ee23dff…), which is not what
# was balloted. Two seats ran a verification that silently resolved to the live file and got a
# CONFIRMATION instead of a finding. codex rejected on exactly this ground both times and was right;
# only the inquorate failure stopped an unreviewed policy from sealing.
#
# The distinction the old ballot could not express: "the candidate is unavailable" and "the
# candidate is available and fine" are THE SAME SENTENCE ONE DIGEST APART — the ballot named neither
# path nor full digest, and the precedent block propagates a verdict's prose but not the digest it
# was about.
#
# Graded here, at the mint, offline (node + cli.mjs only — no council, no root, no network):
#   A. the digest balloted must BE the digest of the candidate's bytes (the 6498adcb shape)
#   B. a truncated digest is refused (a prefix is not a binding)
#   C. a candidate with no resolvable path is refused
#   D. the happy path carries path + FULL 64-hex digest + the one-command bind + the diff
#   E. an oversized diff is capped LOUDLY and still names the command for the whole of it
# Run: bash tests/council_amend_ballot_binding_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh). No `2>/dev/null` —
# the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }
CLI="$ROOT/src/council/cli.mjs"
[[ -f "$CLI" ]] || { echo "SKIP: $CLI not found"; exit 0; }
TMP="$(mktemp -d /tmp/amend-binding-unit.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SEATS='[{"id":"a","lens":"a"},{"id":"b","lens":"b"},{"id":"c","lens":"c"}]'

cat > "$TMP/candidate.yaml" <<'YAML'
council:
  bench: security
quorum: none
thresholds:
  ordinary: 1
  promote: majority
  demote: 3/4
  constitutional:
    rule: fraction
    value: 0.75
    quorum: all
    require_quorum: true
veto:
  principals: [human:main, human:owner]
  hold_secs: 0
  posthoc_secs: 86400
hard_gates:
  money: 'spend|billing'
  comms: 'brand|press'
ship:
  require_ci: true
comms:
  public_requires_human: true
YAML
cp "$TMP/candidate.yaml" "$TMP/live.yaml"
# The amendment under test: purely additive, and inside a field the schema actually accepts —
# an unknown top-level key is refused by the PARSE gate, which would make every binding arm below
# pass for the wrong reason. (Found by the precondition arm, which is what it is for.)
printf "  eng_approval_lead: 'deploy|release'\n" >> "$TMP/candidate.yaml"

CAND="$TMP/candidate.yaml"; LIVE="$TMP/live.yaml"
CAND_SHA="$(sha256sum < "$CAND" | awk '{print $1}')"
LIVE_SHA="$(sha256sum < "$LIVE" | awk '{print $1}')"
diff -u "$LIVE" "$CAND" > "$TMP/diff.txt" 2>/dev/null || true

# PRECONDITION, asserted not assumed: the fixture must actually be a VALID constitution, or every
# refusal arm below would pass for the wrong reason (the parse gate, not the binding gate) and the
# happy-path arm would be the only thing that could ever fail.
if node "$CLI" amend-plan --seats-json="$SEATS" --constitution="@$CAND" \
     --constitution-digest="$CAND_SHA" --constitution-path="$CAND" \
     --live-path="$LIVE" --live-digest="$LIVE_SHA" --diff="@$TMP/diff.txt" >"$TMP/ok.json" 2>"$TMP/ok.err"; then
  ok_t "PRECOND the fixture is a valid constitution and a correctly-bound mint SUCCEEDS"
else
  bad_t "PRECOND valid fixture mints" "rc=$? err=$(cat "$TMP/ok.err")"
fi

# --- A: THE CORE GUARD. A digest that is not the digest of the candidate's bytes is REFUSED.
#     This is the 6498adcb shape, and it is what makes that motion structurally unable to reach a
#     seat: the mint holds the bytes, so it can always answer "is this digest about them?" --------
WRONG_SHA="6498adcb$(printf '%056d' 0)"
out=$(node "$CLI" amend-plan --seats-json="$SEATS" --constitution="@$CAND" \
        --constitution-digest="$WRONG_SHA" --constitution-path="$CAND" \
        --live-path="$LIVE" --live-digest="$LIVE_SHA" --diff="@$TMP/diff.txt" 2>&1); rc=$?
[[ $rc -ne 0 ]] \
  && ok_t "A a digest that does not match the candidate's bytes is REFUSED (non-zero exit)" \
  || bad_t "A wrong digest refused" "rc=$rc out=$out"
[[ "$out" == *"DIVE-2889"* && "$out" == *"$WRONG_SHA"* && "$out" == *"$CAND_SHA"* ]] \
  && ok_t "A the refusal names BOTH digests — the one balloted and the one the bytes actually have" \
  || bad_t "A refusal names both digests" "out=$out"
[[ "$out" != *"CANDIDATE BINDING"* ]] \
  && ok_t "A no ballot text is emitted on the refusal (the motion does not reach seats at all)" \
  || bad_t "A no ballot on refusal" "out=$out"

# --- B: a truncated digest is not a binding. The old ballot printed exactly this — 12 chars and an
#     ellipsis — which is why seats compared by eye against a file located by guesswork. ----------
out=$(node "$CLI" amend-plan --seats-json="$SEATS" --constitution="@$CAND" \
        --constitution-digest="${CAND_SHA:0:12}" --constitution-path="$CAND" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"DIVE-2889"* ]] \
  && ok_t "B a TRUNCATED digest is refused — a prefix is not a binding" \
  || bad_t "B truncated digest refused" "rc=$rc out=$out"

# --- C: no path means no route to the bytes. A seat with no sibling row to read has nothing to
#     bind to, which is presumably how the first two rounds went. -----------------------------
out=$(node "$CLI" amend-plan --seats-json="$SEATS" --constitution="@$CAND" \
        --constitution-digest="$CAND_SHA" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"DIVE-2889"* ]] \
  && ok_t "C a candidate with no --constitution-path is refused" \
  || bad_t "C missing path refused" "rc=$rc out=$out"

# --- D: THE HAPPY PATH DELIVERS THE BINDING. Everything a seat needs to bind must be IN the
#     ballot body, because "it worked when a seat went looking" is not the same as delivery. ----
q=$(jq -r '.question' < "$TMP/ok.json" 2>/dev/null)
[[ "$q" == *"$CAND_SHA"* ]] \
  && ok_t "D the ballot carries the FULL 64-hex digest" \
  || bad_t "D full digest in ballot" "q=$q"
[[ "$q" == *"$CAND"* ]] \
  && ok_t "D the ballot names the candidate's PATH" \
  || bad_t "D path in ballot" "q=$q"
[[ "$q" == *"sha256sum $CAND"* ]] \
  && ok_t "D the ballot spells the ONE-COMMAND binding a seat should run" \
  || bad_t "D bind command in ballot" "q=$q"
[[ "$q" == *"eng_approval_lead"* ]] \
  && ok_t "D the ballot carries the DIFF vs live (the amendment's actual content)" \
  || bad_t "D diff in ballot" "q=$q"
[[ "$q" == *"$LIVE_SHA"* && "$q" == *"$LIVE"* ]] \
  && ok_t "D the ballot names what the candidate is being compared AGAINST (live path + digest)" \
  || bad_t "D live side named" "q=$q"
[[ "$q" == *"DO NOT verify by reading the live constitution"* ]] \
  && ok_t "D the ballot warns off the exact verification that returned a confirmation twice" \
  || bad_t "D anti-confirmation warning" "q=$q"
# The JSON envelope carries it too, for anything reading the plan rather than the prose.
[[ "$(jq -r '.candidatePath' < "$TMP/ok.json")" == "$CAND" \
   && "$(jq -r '.constitutionDigest' < "$TMP/ok.json")" == "$CAND_SHA" ]] \
  && ok_t "D the plan JSON carries candidatePath + the full constitutionDigest" \
  || bad_t "D plan JSON binding" "$(cat "$TMP/ok.json")"

# --- E: an oversized diff is CAPPED — this question becomes a Telegram ballot body for human
#     seats, and an uncapped diff turns a governance change into a capture failure, which is the
#     same fail-open wearing a new coat. The truncation must be LOUD and name the full command. --
cp "$TMP/live.yaml" "$TMP/big.yaml"
for i in $(seq 1 400); do printf "  gate_%03d: 'pattern_%03d'\n" "$i" "$i" >> "$TMP/big.yaml"; done
BIG_SHA="$(sha256sum < "$TMP/big.yaml" | awk '{print $1}')"
diff -u "$LIVE" "$TMP/big.yaml" > "$TMP/bigdiff.txt" 2>/dev/null || true
node "$CLI" amend-plan --seats-json="$SEATS" --constitution="@$TMP/big.yaml" \
  --constitution-digest="$BIG_SHA" --constitution-path="$TMP/big.yaml" \
  --live-path="$LIVE" --live-digest="$LIVE_SHA" --diff="@$TMP/bigdiff.txt" >"$TMP/big.json" 2>"$TMP/big.err"
bq=$(jq -r '.question' < "$TMP/big.json" 2>/dev/null)
[[ -n "$bq" && "$bq" == *"TRUNCATED"* && "$bq" == *"THIS IS A PREFIX"* ]] \
  && ok_t "E an oversized diff is capped with a LOUD truncation marker" \
  || bad_t "E diff capped" "len=${#bq} err=$(cat "$TMP/big.err")"
[[ "$bq" == *"diff -u $LIVE $TMP/big.yaml"* ]] \
  && ok_t "E the truncated ballot still names the command that yields the WHOLE diff" \
  || bad_t "E truncation names the command" "bq=$bq"
[[ "$bq" == *"$BIG_SHA"* ]] \
  && ok_t "E the BINDING is never truncated even when the diff is (it is the part a seat cannot rebuild)" \
  || bad_t "E binding survives truncation" "bq=$bq"
# Bounded enough to survive the human-ballot transport it will be embedded in.
# NON-EMPTY is half the assertion: a mint that DIED produces a 0-length body, which sails through
# a bare `< 4000` and reports the bound as proven. Measured — this arm passed green on an empty
# string while every sibling arm was red.
[[ -n "$bq" && ${#bq} -lt 4000 ]] \
  && ok_t "E the capped ballot body is non-empty AND under the human-tap transport limit (${#bq} chars)" \
  || bad_t "E ballot body bounded" "len=${#bq}"

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
