#!/usr/bin/env bash
# DIVE-5842 unit harness: `5dive host journal` searches the whole journal, and
# never prints a secret value in any mode.
#
# WHY. DIVE-5805 took every seat out of systemd-journal: that group reads every
# secret that ever crossed a sudo line (`ENV=NAME=value`, `COMMAND=` argv). An
# admin seat still has to diagnose the box, and it reaches root only through
# `sudo 5dive …`. The old verb read one unit at a time and printed it raw, so an
# old leaked line came back in clear to a `--unit` read of the right unit.
#
# WHAT THIS PINS.
#   A. the masker: every named secret shape is masked, nothing else on the line
#      moves, and a line that is already masked is not counted again;
#   B. the verb end to end (journalctl stubbed with a planted journal): the
#      search, the selectors handed to journalctl, `--grep` matched AFTER masking
#      (otherwise it is an oracle that spells a key one character at a time),
#      `--count-secrets` = 1 for the one planted line, and unit mode masked too;
#   C. MUTANT: with the masker replaced by `cat`, arm B's planted value shows and
#      the count is 0 — the arms below are proven to be able to go red;
#   D. refusals: non-root is refused, no standard seat's sudoers reaches
#      `5dive host`, and the new flags take no free-form journalctl syntax.
#
# Sources the src/ libs directly — no root, no systemd, no network.
# Run: bash tests/dive5842_journal_search_masked_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP="$(mktemp -d /tmp/dive5842-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_host.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); printf 'ok   — %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL — %s\n' "$1"; }

# Fake values, built so no literal secret shape sits in this file's source.
FAKE_ANT="sk-ant-oat01-$(printf 'F%.0s' {1..24})dive5842"
FAKE_OR="sk-or-v1-$(printf '0%.0s' {1..32})"
FAKE_GHP="ghp_$(printf 'a%.0s' {1..36})"
FAKE_PAT="github_pat_$(printf 'B%.0s' {1..40})"
FAKE_TG="1234567890:$(printf 'A%.0s' {1..35})"

# The planted journal: one sudo line carrying the DIVE-5805 C1 shape, plus noise.
JOURNAL="$TMP/journal.txt"
cat > "$JOURNAL" <<EOF
Oct 08 03:00:01 box sudo[100]:     root : PWD=/root ; USER=agent-devops ; ENV=CLAUDE_CODE_OAUTH_TOKEN=${FAKE_ANT} ; COMMAND=/usr/bin/bash -c 'exec 5dive memory consolidate'
Oct 08 03:00:02 box sudo[101]:     root : PWD=/root ; USER=agent-x ; COMMAND=/usr/local/bin/5dive task ls
Oct 08 03:00:03 box systemd[1]: Started cron.service.
Oct 08 03:00:04 box sudo[102]: pam_unix(sudo:session): session closed for user agent-x
EOF

# Stub journalctl: record argv, print the planted journal.
_host_journalctl() { printf '%s\n' "$@" > "$TMP/jargs"; cat "$JOURNAL"; }
require_root() { :; }
jargs() { tr '\n' ' ' < "$TMP/jargs"; }

echo "== A. the masker =="
masked=$(printf '%s\n' \
  "ENV=CLAUDE_CODE_OAUTH_TOKEN=${FAKE_ANT} ; COMMAND=/x" \
  "key ${FAKE_OR} end" \
  "COMMAND=/usr/bin/env GH=${FAKE_GHP} bash -s" \
  "pat ${FAKE_PAT} end" \
  "bot ${FAKE_TG} end" \
  "ENV=ANTHROPIC_AUTH_TOKEN=abc123 DB_PASSWORD=hunter2 MY_SECRET=s3 API_KEY=k1 ; COMMAND=/y" \
  "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123" \
  "Oct 08 03:00:03 box systemd[1]: Started cron.service." \
  | _host_mask_secrets)
for v in "$FAKE_ANT" "$FAKE_OR" "$FAKE_GHP" "$FAKE_PAT" "$FAKE_TG" abc123 hunter2 '=s3' '=k1' abcdefghijklmnopqrstuvwxyz0123; do
  if [[ "$masked" == *"$v"* ]]; then bad "masker left '$v' in clear"; else pass "masker hides '${v:0:14}…'"; fi
done
for keep in 'ENV=CLAUDE_CODE_OAUTH_TOKEN=[masked] ; COMMAND=/x' 'sk-or-[masked]' 'ghp_[masked]' \
            'github_pat_[masked]' '1234567890:[masked]' 'DB_PASSWORD=[masked]' 'Bearer [masked]' \
            'Started cron.service.'; do
  if [[ "$masked" == *"$keep"* ]]; then pass "masker keeps the context: '$keep'"; else bad "masker lost the context '$keep': $masked"; fi
done
tags=$(printf '%s\n' 'ENV=X_TOKEN=[masked] ; COMMAND=/x' 'plain line 03:00:04' | _host_mask_tagged | cut -c1 | tr -d '\n')
if [[ "$tags" == "00" ]]; then pass "an already-masked line and a clean line are not counted"; else bad "tags were '$tags', expected 00"; fi

echo
echo "== B. the verb, journalctl stubbed with a planted journal =="
run_verb() { ( cmd_host_journal "$@" ) 2>&1; }

out=$(run_verb --comm=sudo --grep=ENV= --since=7d)
if [[ "$out" == *'ENV=CLAUDE_CODE_OAUTH_TOKEN=[masked]'* ]]; then pass "search over sudo lines returns the planted line, masked"; else bad "search did not return the masked line: $out"; fi
if [[ "$out" != *"$FAKE_ANT"* ]]; then pass "search never prints the planted value"; else bad "search printed the planted value"; fi
if [[ $(grep -c . <<<"$out") -eq 1 ]]; then pass "--grep keeps only the matching line"; else bad "--grep returned $(grep -c . <<<"$out") lines: $out"; fi
ja=$(jargs)
if [[ "$ja" == *"_COMM=sudo"* && "$ja" == *"--since 7 days ago"* && "$ja" != *"-n "* ]]; then
  pass "journalctl got _COMM=sudo, the fixed --since phrase, and no -n (a search reads the window): $ja"
else
  bad "journalctl argv was: $ja"
fi

n=$(run_verb --comm=sudo --since=7d --count-secrets)
if [[ "$n" == "1" ]]; then pass "--count-secrets reports the planted line as 1"; else bad "--count-secrets said '$n', expected 1"; fi
n=$(run_verb --grep=agent-x --count-secrets)
if [[ "$n" == "0" ]]; then pass "--count-secrets with --grep counts only matching lines (0)"; else bad "count with --grep said '$n'"; fi
if [[ "$(jargs)" == *"--since 1 days ago"* ]]; then pass "a count with no --since reads one day, not the whole journal"; else bad "no default window: $(jargs)"; fi

out=$(run_verb --unit=sudo.service)
if [[ "$out" != *"$FAKE_ANT"* && "$out" == *'[masked]'* ]]; then pass "unit mode is masked too (the old raw read is closed)"; else bad "unit mode printed: $out"; fi
if [[ "$(jargs)" == *"-n 200"* ]]; then pass "unit mode keeps its -n 200 default"; else bad "unit mode argv: $(jargs)"; fi

# The oracle: a needle that is a prefix of the SECRET must not find the line.
out=$(run_verb --grep="${FAKE_ANT:0:16}")
if [[ -z "$out" ]]; then pass "--grep matches the MASKED text: a secret prefix finds nothing (no oracle)"; else bad "a secret prefix matched: $out"; fi
n=$(run_verb --grep="${FAKE_ANT:0:16}" --count-secrets)
if [[ "$n" == "0" ]]; then pass "no oracle through --count-secrets either"; else bad "count oracle: $n"; fi

json=$(JSON_MODE=1 run_verb --comm=sudo --grep=ENV=)
if [[ "$json" != *"$FAKE_ANT"* ]] && jq -e '.data.log | contains("[masked]")' >/dev/null 2>&1 <<<"$json"; then
  pass "--json carries the masked log"
else
  bad "--json: $json"
fi

echo
echo "== C. MUTANT: masking disabled =="
(
  _host_mask_tagged() { LC_ALL=C sed -e 's/^/0\t/'; }
  out=$(cmd_host_journal --comm=sudo --grep=ENV= 2>&1)
  n=$(cmd_host_journal --comm=sudo --count-secrets 2>&1)
  [[ "$out" == *"$FAKE_ANT"* && "$n" == "0" ]]
)
if (( $? == 0 )); then
  pass "mutant: with no masker the planted value prints and the count is 0, so arms B go red"
else
  bad "mutant did not surface the planted value: arms B cannot go red"
fi

echo
echo "== D. refusals =="
run_verb_rc() { ( cmd_host_journal "$@" ) >/dev/null 2>&1; }
refuses() {
  local desc="$1"; shift
  if "$@"; then bad "$desc — ACCEPTED"; else pass "$desc"; fi
}
refuses "no selector at all"                 run_verb_rc --lines=10
refuses "--unit and --comm together"         run_verb_rc --unit=sudo.service --comm=sudo
refuses "--comm with a leading '-'"          run_verb_rc --comm=-o
refuses "--comm with '=' (a second match)"   run_verb_rc --comm='sudo=_UID=0'
refuses "--comm with '+' (journalctl OR)"    run_verb_rc --comm='sudo+'
refuses "--comm longer than 15"              run_verb_rc --comm=abcdefghijklmnop
refuses "--grep empty"                       run_verb_rc --grep=
refuses "--grep with a newline"              run_verb_rc --grep="$(printf 'a\nb')"
refuses "--since free-form on a search"      run_verb_rc --grep=x --since=yesterday
refuses "a raw journalctl flag"              run_verb_rc --grep=x --output=cat

# Non-root is refused by the real require_root, whoever runs the harness.
NONROOT_SCRIPT="$TMP/nonroot.sh"
cat > "$NONROOT_SCRIPT" <<EOF
cd "$PWD"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh lib/audit.sh cmd_host.sh; do source "$SRC/\$f"; done
set +e
( cmd_host_journal --comm=sudo ) 2>&1; echo "RC=\$?"
EOF
if (( EUID == 0 )); then
  nr=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$NONROOT_SCRIPT" 2>&1)
else
  nr=$(bash "$NONROOT_SCRIPT" 2>&1)
fi
if [[ "$nr" == *"must run as root"* && "$nr" != *"RC=0"* ]]; then pass "a non-root caller is refused"; else bad "non-root was not refused: $nr"; fi

# A standard seat's sudoers must not reach `5dive host` (only admin's `5dive *` does).
grants=""
for p in 0 1; do for d in 0 1; do grants+=$(render_standard_sudoers agent-x "$p" "$d"); grants+=$'\n'; done; done
hits=$(grep -E '^agent-x .*NOPASSWD: .*/usr/local/bin/5dive( \*|$| host)' <<<"$grants")
if [[ -z "$hits" && -n "$grants" ]]; then pass "no standard-seat sudoers line reaches '5dive host'"; else bad "a standard seat reaches 5dive host: ${hits:-<no grants rendered>}"; fi

echo
echo "passed=$PASSED failed=$FAILED"
(( FAILED == 0 ))
