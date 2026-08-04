#!/usr/bin/env bash
# DIVE-2679 isolated unit harness — the secret tripwire matches a secret's VALUE,
# not the English word for one, and --audience=self is not sold as a way past it.
#
# The incident: 'agent export --with-memory' refused on 6 of 6 live agents, so the
# portable-memory feature had never once succeeded. The cause was not policy. The
# tripwire was a single case-insensitive alternation and two branches matched prose:
#
#   sk-[A-Za-z0-9]   unanchored -> ta"sk-"need, a"sk-"rail, ri"sk-"tier, ma"sk-"wt
#   credentials      the bare English word, which operational memory is full of
#
# Measured against a real 411-fact store: the old rule flagged 41 files on `sk-`
# alone and NOT ONE held a key; against the same store scoped to its 365 shareable
# facts the old tripwire flagged 58 files and refused, the new one is clean. On a
# board whose nouns are task/ask/risk that one rule is a total refusal.
#
# Every rule is graded IN ISOLATION, one fixture per rule. That is not tidiness:
# the private-key rule begins with '-' and grep read it as flags, so it silently
# matched nothing — invisible in a mixed fixture, because anything carrying a PEM
# block trips some other rule too and the tripwire still returned "refused".
# A rule is only proven by a fixture that trips IT and nothing else.
# Run: bash tests/pack_secret_tripwire_precision_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/tripwire-precision.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"

JSON_MODE=1
set +e   # header.sh enabled `set -e`; tests deliberately probe non-zero paths

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1 (want [$3] got [$2])"; fi; }
has()   { if grep -qF -- "$2" <<<"$1"; then ok_ "$3"; else bad_ "$3 (missing [$2])"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then bad_ "$3 (unexpectedly present: [$2])"; else ok_ "$3"; fi; }

# One fixture, one file, one rule. Returns the stderr report; asserts the verdict
# AND (for a refusal) that the rule which fired is the one under test — a fixture
# that trips the wrong rule would otherwise read as a pass.
probe() {  # probe <label> <content> refuse:<rule>|clean
  local label="$1" content="$2" want="$3" d out rc
  d=$(mktemp -d "$TMP/p.XXXXXX"); printf '%s\n' "$content" > "$d/fact.md"
  out=$(_pack_secret_tripwire "$d" 2>&1); rc=$?
  if [[ "$want" == clean ]]; then
    if [[ $rc -eq 0 ]]; then ok_ "$label -> clean"; else bad_ "$label -> REFUSED, want clean [$out]"; fi
  else
    local rule="${want#refuse:}"
    if [[ $rc -ne 1 ]]; then bad_ "$label -> rc=$rc, want refusal"
    elif ! grep -qF -- "$rule" <<<"$out"; then bad_ "$label -> refused by the WRONG rule [$out], want [$rule]"
    else ok_ "$label -> refused by $rule"; fi
  fi
}

printf '\n1. every VALUE rule fires, in isolation (reserved fakes only)\n'
probe "openssh private key"  '-----BEGIN OPENSSH PRIVATE KEY-----'                 refuse:private-key-block
probe "rsa private key"      '-----BEGIN RSA PRIVATE KEY-----'                     refuse:private-key-block
# Caught in review: an armoured PGP secret key carries a word AFTER "PRIVATE KEY",
# so a trailing literal could not reach it and it exported clean. Its own fixture,
# because the three PEM shapes are one rule and only this one was broken.
probe "pgp private key block" '-----BEGIN PGP PRIVATE KEY BLOCK-----'              refuse:private-key-block
probe "encrypted private key" '-----BEGIN ENCRYPTED PRIVATE KEY-----'              refuse:private-key-block
probe "openai-style key"     'k=sk-abcdefghijklmnopqrstuvwxyz0123'                 refuse:openai-style-key
probe "github token"         'ghp_abcdefghijklmnopqrstuvwxyz0123456789'            refuse:github-token
probe "slack token"          'xoxb-1234567890-abcdefghijklm'                       refuse:slack-token
probe "aws access key id"    'AKIAIOSFODNN7EXAMPLE '                               refuse:aws-access-key-id
probe "telegram bot token"   '1234567890:AAHfakefakefakefakefakefakefake123'       refuse:telegram-bot-token
probe "assigned credential"  'BOT_TOKEN=abcdefghijklmnop1234'                      refuse:assigned-credential

printf '\n2. the prose each rule used to eat is NOT a secret\n'
# Every line here is drawn from the shape of real agent memory that refused.
probe "task-/ask-/risk- nouns" 'the task-need rail, ask-rail, risk-tiers, mask-wt'  clean
probe "the word credentials"   'a workflow-file push is NOT blocked by credentials' clean
probe "elided key value"       'run OPENROUTER_API_KEY=... opencode models'         clean
probe "bare key NAME"          'git grep GH_BOT_TOKEN over the tree is EMPTY'       clean
probe "PEM words in prose"     'we discussed BEGIN and PRIVATE KEY handling'        clean
probe "short assignment"       'PASSWORD=hunter2'                                   clean
# A DELIBERATE narrowing, asserted so nobody "restores" it as a missing case: the
# old bare `-----BEGIN` refused on a certificate. A certificate is public material.
probe "certificate (public)"   '-----BEGIN CERTIFICATE-----'                        clean

printf '\n3. a staged credential FILE is caught by name (the allowlist regression)\n'
D="$TMP/files"; mkdir -p "$D"
printf 'nothing to see\n' > "$D/.env"
OUT=$(_pack_secret_tripwire "$D" 2>&1); RC=$?
check ".env refuses even with innocuous contents" "$RC" "1"
has "$OUT" "credential-file" ".env is reported as a credential FILE, not a content hit"
rm -f "$D/.env"; printf 'x\n' > "$D/id_ed25519"
_pack_secret_tripwire "$D" >/dev/null 2>&1; check "id_ed25519 refuses" "$?" "1"
rm -f "$D/id_ed25519"
# A FACT whose name merely contains the word must not be mistaken for a store.
printf 'a lesson about secret handling\n' > "$D/dive931-secret-drop-cli.md"
_pack_secret_tripwire "$D" >/dev/null 2>&1; check "a fact named ...secret....md is clean" "$?" "0"

printf '\n4. the refusal is actionable and is not itself a leak\n'
D2="$TMP/report"; mkdir -p "$D2"
printf 'line one\nOPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz0123\n' > "$D2/fact.md"
OUT=$(_pack_secret_tripwire "$D2" 2>&1)
has "$OUT" "fact.md:2" "names file AND line, so the fact is findable"
has "$OUT" "openai-style-key" "names the rule that fired"
hasnt "$OUT" "sk-abcdefghijklmnopqrstuvwxyz0123" "NEVER echoes the matched secret back"
hasnt "$OUT" "$D2" "reports a path relative to the stage, not the temp dir"

printf '\n5. binaries are skipped (avatar.png is staged beside memory)\n'
D3="$TMP/bin"; mkdir -p "$D3"
head -c 4096 /dev/urandom > "$D3/avatar.png"
printf 'clean fact\n' > "$D3/fact.md"
_pack_secret_tripwire "$D3" >/dev/null 2>&1
check "random binary bytes do not trip a text rule" "$?" "0"

printf '\n6. --audience=self is not sold as a way past the tripwire\n'
# The reporter'\''s wasted cycle: usage says self "skips that scan", so they re-ran
# with it and were refused again. Assert the copy names WHICH scan, everywhere it
# is stated, and that the refusal pre-empts the wrong turn.
USAGE=$(_pack_usage 2>&1)
has "$USAGE" "skips THAT scan and ONLY that scan" "usage scopes what self skips"
has "$USAGE" "runs on BOTH audiences" "usage says the tripwire is audience-independent"
REFUSAL=$(grep -n 'tripped the secret tripwire' "$SRC/cmd_pack.sh")
check "both tripwire refusals exist" "$(wc -l <<<"$REFUSAL")" "2"
for arm in "scoped fact tripped" "approved memory tripped"; do
  line=$(grep -F "$arm" "$SRC/cmd_pack.sh")
  has "$line" 'audience=self does NOT bypass' "the '$arm' refusal names the non-bypass"
  has "$line" "file:line: rule above" "the '$arm' refusal points at the new report shape"
done
# -e again, and for the same reason the shipped fix needed it: this pattern starts
# with '-'. The bug this file grades bit the file grading it.
VALIDATION=$(grep -F -e "--audience must be" "$SRC/cmd_pack.sh")
has "$VALIDATION" "the secret tripwire still runs" "the --audience validation error says so too"

printf '\n7. the zero-facts refusal explains WHY rather than only reporting a count\n'
ZERO=$(grep -F "nothing shareable: 0 reference/project" "$SRC/cmd_pack.sh")
has "$ZERO" "Only metadata.type 'reference' or 'project' facts are eligible" "names the eligibility rule"
has "$ZERO" "never exported" "says private types are excluded by design, not by accident"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
