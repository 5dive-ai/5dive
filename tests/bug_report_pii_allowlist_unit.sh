#!/usr/bin/env bash
# DIVE-2323 — `5dive bug`'s payload is an ALLOWLIST, never a denylist.
#
# The whole design point (see src/cmd_bug.sh header and
# community/wiki/a-repo-scoped-pii-gate-cannot-see-what-the-repo-generates.md) is
# that `selfcheck --json`'s probes[] carry .reason and .detail as FREE TEXT — paths,
# hostnames, agent names, task idents land there — and nothing but .probe/.verdict
# may ever reach the payload this verb prints or files publicly. A review can
# confirm the code LOOKS right; only a planted marker proves a free-text field
# never actually reaches the emitted bytes, which is why the negative arm below is
# the one that matters (same shape as council_principal_redaction_unit.sh).
#
# Hermetic: _sc_dispatch is overridden with a fixture table (same technique as
# tests/selfcheck_unit.sh), so this never shells out, never hits the network and
# never touches the live task store. GH_ORG is pinned so cmd_bug.sh's gh_org()
# calls never probe github.com.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
SRC=src
export GH_ORG="5dive-ai"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/self.sh cmd_selfcheck.sh cmd_bug.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
chk()    { if [[ "$2" == "$3" ]]; then ok_t "$1"; else fail_t "$1 (expected '$2', got '$3')"; fi }

# ── 1. the allowlist shape, on a clean fixture ─────────────────────────────────
# THIS is the key-set pin: a literal expected list, so ANY new top-level field
# fails here, on purpose, even one wired in only via jq -cn --arg without also
# touching the object literal below (which is a silent no-op on the emitted
# bytes, not a leak — confirmed by diff during DIVE-2323 gate review, since an
# --arg that no field in the final `{...}` construction references never
# reaches the payload at all).
_sc_dispatch() { printf '%s\n' "pass||clean detail line, nothing sensitive"; }

payload=$(_bug_render_payload "doctor" "3" 1)

keys=$(jq -cS 'keys' <<<"$payload")
# DIVE-3136 added `what` and `invocation`. They are on the allowlist for the
# same reason everything else is: named here, one at a time, on purpose. The
# difference is that their content is the CALLER'S OWN TEXT, typed and then
# re-read before filing — never harvested from an object nobody looked at.
chk "payload top-level keys are EXACTLY the allowlist (no more, no less)" \
  '["bash_version","exit_code","install_method","invocation","os","probes","verb","version","what"]' "$keys"
chk "what is null when not supplied, never an empty string" 'null' "$(jq -c '.what' <<<"$payload")"
chk "invocation is null when not supplied" 'null' "$(jq -c '.invocation' <<<"$payload")"

probe_keys=$(jq -c '[.probes[] | keys] | unique' <<<"$payload")
chk "every probe object carries ONLY probe+verdict" '[["probe","verdict"]]' "$probe_keys"

chk "verb passes through" '"doctor"' "$(jq -c '.verb' <<<"$payload")"
chk "exit_code is numeric when given" '3' "$(jq -c '.exit_code' <<<"$payload")"

# ── 2. --no-probes / no exit code -> the honest absence, not a fabricated value ─
p2=$(_bug_render_payload "x" "" 0)
chk "include_probes=0 -> empty probes array, not omitted or null" '[]' "$(jq -c '.probes' <<<"$p2")"
chk "a non-numeric exit code renders as null, never coerced to 0" 'null' "$(jq -c '.exit_code' <<<"$p2")"

# ── 3. the negative arm: plant a PII-shaped marker in .reason AND .detail ──────
# Reserved-fake id per project convention (never a real identifier in a fixture).
MARKER="tg:1234567890/should-never-leave-this-box"
_sc_dispatch() { printf '%s\n' "fail|${MARKER}|detail also carries ${MARKER} right here"; }

raw=$(cmd_selfcheck --json 2>/dev/null)
if grep -q "$MARKER" <<<"$raw"; then
  ok_t "sanity: the marker DOES appear in raw selfcheck --json (fixture is live, not a vacuous test)"
else
  fail_t "sanity check failed — the marker never even reached raw selfcheck output, so the negative arm below proves nothing: $raw"
fi

probes_out=$(_bug_collect_probes)
if grep -q "$MARKER" <<<"$probes_out"; then
  fail_t "MARKER LEAKED into _bug_collect_probes output: $probes_out"
else
  ok_t "the marker does not reach _bug_collect_probes (reason/detail dropped, not just this key renamed)"
fi

payload2=$(_bug_render_payload "doctor" "1" 1)
if grep -q "$MARKER" <<<"$payload2"; then
  fail_t "MARKER LEAKED into the rendered payload: $payload2"
else
  ok_t "the marker does not reach the rendered payload"
fi

body=$(_bug_body_markdown "$payload2")
if grep -q "$MARKER" <<<"$body"; then
  fail_t "MARKER LEAKED into the rendered issue body: $body"
else
  ok_t "the marker does not reach the rendered issue body (the body is built from the payload only)"
fi

# ── 4. shape guard: a NEW emitter referencing .reason/.detail/.asserts fails here
#      too, in CI, rather than in a filed issue (same rationale as
#      council_principal_redaction_unit.sh's emit-site shape assertion). ───────
leaky_refs=$(grep -vE '^[[:space:]]*#' "$SRC/cmd_bug.sh" | grep -cE '\.reason\b|\.detail\b|\.asserts\b|\.label\b')
chk "no jq expression in cmd_bug.sh (outside comments) ever reads .reason/.detail/.asserts/.label" \
  0 "$leaky_refs"

# ── 5. --verb is bounded, not a second free-text channel ──────────────────────
long_verb=$(printf 'a%.0s' $(seq 1 200))
san=$(_bug_sanitize_verb "$long_verb")
chk "an oversized --verb is capped at 80 chars" 80 "${#san}"

nl_verb=$(_bug_sanitize_verb $'multi\nline\ntext')
if [[ "$nl_verb" == *$'\n'* ]]; then
  fail_t "newline survived verb sanitization: '$nl_verb'"
else
  ok_t "newlines are stripped from --verb"
fi

# ── 6. NEVER auto-files: the default (preview) path never calls cmd_gh ─────────
cmd_gh() { fail_t "cmd_gh was invoked WITHOUT --file — this is the auto-file bug the ticket forbids"; echo "unreachable"; }
_sc_dispatch() { printf '%s\n' "pass||clean"; }
out=$(cmd_bug --verb=doctor --exit=1 2>/tmp/bug_unit_err.$$)
rc=$?
chk "bare '5dive bug' (no --file) exits 0 without filing" 0 "$rc"
if grep -q "Nothing filed" /tmp/bug_unit_err.$$; then
  ok_t "bare '5dive bug' says nothing was filed"
else
  fail_t "no 'nothing filed' notice printed: $(cat /tmp/bug_unit_err.$$)"
fi
rm -f /tmp/bug_unit_err.$$

# ── 7. the failure-path hint (fail()'s E_GENERIC-only pointer to this verb) ────
CURRENT_VERB="doctor"
hint_err=$(fail "$E_GENERIC" "something internal broke" 2>&1)
if grep -q "5dive bug --verb=\"doctor\" --exit=1" <<<"$hint_err"; then
  ok_t "fail() hints at '5dive bug' with the real verb+code on E_GENERIC"
else
  fail_t "E_GENERIC hint missing or malformed: $hint_err"
fi

usage_err=$(fail "$E_USAGE" "bad flag" 2>&1)
if grep -q "5dive bug" <<<"$usage_err"; then
  fail_t "a routine E_USAGE mistake should NOT get the bug-report hint (noise on every typo): $usage_err"
else
  ok_t "a routine E_USAGE failure stays quiet — the hint is reserved for E_GENERIC"
fi

# ── 8. DIVE-3136: the placeholder can never ship again ────────────────────────
# Issues #526 and #553 went out with the template's own HTML comment sitting
# where the description belongs. The regression that matters is not "did we
# remember to fill it in" — nobody was at a prompt to fill it in — it is that
# the placeholder no longer EXISTS as a thing this file can emit. So both arms:
# the rendered body, and the source itself.
_sc_dispatch() { printf '%s\n' "pass||clean"; }
p_nowhat=$(_bug_render_payload "gh" "4" 1)
body_nowhat=$(_bug_body_markdown "$p_nowhat")
if grep -qF '<!--' <<<"$body_nowhat"; then
  fail_t "the rendered body still carries an HTML comment placeholder: $body_nowhat"
else
  ok_t "a description-less body carries NO html-comment placeholder (the #526/#553 shape)"
fi
if grep -qF '<!--' "$SRC/cmd_bug.sh"; then
  fail_t "cmd_bug.sh still contains an html comment it could emit into an issue body"
else
  ok_t "cmd_bug.sh cannot emit an html-comment placeholder — the string is gone from the source"
fi

WHAT='ran gh pr view and it died before reaching gh'
p_what=$(_bug_render_payload "gh" "4" 1 "$WHAT" 'gh pr view 51 --json state')
chk "--what reaches the payload verbatim" "\"$WHAT\"" "$(jq -c '.what' <<<"$p_what")"
body_what=$(_bug_body_markdown "$p_what")
if grep -qF "$WHAT" <<<"$body_what"; then
  ok_t "--what is rendered under '## What happened' in the issue body"
else
  fail_t "--what never reached the issue body: $body_what"
fi
if grep -qF 'gh pr view 51 --json state' <<<"$body_what"; then
  ok_t "--argv is rendered as the failing invocation"
else
  fail_t "--argv never reached the issue body: $body_what"
fi

# ── 9. --argv redaction + the secret backstop ─────────────────────────────────
# Reserved-fake secret shapes only — never a real credential in a fixture.
p_secret=$(_bug_render_payload "agent" "1" 0 "" 'agent create bob --token=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
if grep -qF 'ghp_AAAA' <<<"$p_secret"; then
  fail_t "a --token= value survived _bug_redact_argv into the payload: $p_secret"
else
  ok_t "--argv's sensitive =<value> flags are redacted (same rule as audit_log)"
fi
chk "the redacted marker is what lands instead" '"agent create bob --token=<redacted>"' \
  "$(jq -c '.invocation' <<<"$p_secret")"

if _bug_secret_scan 'here is ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA for you'; then
  ok_t "_bug_secret_scan catches a bare token-shaped string"
else
  fail_t "_bug_secret_scan missed a token-shaped string"
fi
if _bug_secret_scan 'a perfectly ordinary sentence about gh pr view'; then
  fail_t "_bug_secret_scan fires on ordinary prose (it would block real reports)"
else
  ok_t "_bug_secret_scan stays quiet on ordinary prose"
fi

# ── 10. THE arm this ticket exists for: --file REFUSES with no description ────
# Non-interactive is the path that filed both empty issues (an agent, on an
# error path, with nobody at a prompt), so it is the path graded here: stdin is
# closed so [[ -t 0 ]] is false whether or not a human ran this harness.
# The stub records through the FILESYSTEM, not a variable: every cmd_bug call
# below runs inside a command substitution, so a `FILED=1` assignment would die
# with the subshell and leave "nothing was filed" asserting nothing at all.
FILEMARK=$(mktemp); BODYMARK=$(mktemp)
: > "$FILEMARK"; : > "$BODYMARK"
cmd_gh() {
  echo filed >> "$FILEMARK"
  while [[ $# -gt 0 ]]; do [[ "$1" == "--body-file" ]] && cat "$2" > "$BODYMARK"; shift; done
  echo "https://github.com/5dive-ai/5dive/issues/999"
}
# sanity: the marker file mechanism actually records a call (else every
# "nothing was filed" arm below is vacuous — the exact trap this replaced).
cmd_gh --body-file /dev/null >/dev/null
chk "sanity: the stub records a filing through the marker file" 1 "$(wc -l < "$FILEMARK")"
: > "$FILEMARK"

err=$(cmd_bug --verb=gh --exit=4 --file </dev/null 2>&1)
rc=$?
chk "--file with no --what exits non-zero (E_USAGE)" "$E_USAGE" "$rc"
chk "...and nothing was filed" 0 "$(wc -l < "$FILEMARK")"
if grep -q -- '--what' <<<"$err"; then
  ok_t "the refusal NAMES the flag that satisfies it non-interactively"
else
  fail_t "the refusal does not tell an agent how to satisfy it: $err"
fi
# A whitespace-only description is the same empty report wearing a hat.
err_ws=$(cmd_bug --verb=gh --exit=4 --what='   ' --file </dev/null 2>&1)
chk "--what of pure whitespace is refused too" "$E_USAGE" "$?"

# ...and the positive arm, so the refusal is not just "filing is broken now".
: > "$FILEMARK"; : > "$BODYMARK"
cmd_bug --verb=gh --exit=4 --what="$WHAT" --file </dev/null >/dev/null 2>&1
chk "--file WITH --what still files (the guard did not just break the verb)" 1 "$(wc -l < "$FILEMARK")"
# End to end: the bytes gh was actually handed carry the description. This is
# the whole ticket — #526/#553 reached exactly this point with a placeholder.
if grep -qF "$WHAT" "$BODYMARK"; then
  ok_t "the body handed to 'gh issue create' carries the description"
else
  fail_t "the FILED body does not carry --what: $(cat "$BODYMARK")"
fi
if grep -qF '<!--' "$BODYMARK"; then
  fail_t "the FILED body still carries a template placeholder: $(cat "$BODYMARK")"
else
  ok_t "the FILED body carries no placeholder comment"
fi

# The two guards must not fight. A token behind a KNOWN flag is _bug_redact_argv's
# job, so it is redacted and the report still files; only a token the redactor
# could not absorb reaches the refusal. Scanning the RAW argv instead made the
# refusal swallow every case redaction was written for — caught end to end
# through the built bundle, not by any arm above, which is why this one exists.
: > "$FILEMARK"; : > "$BODYMARK"
cmd_bug --verb=gh --exit=4 --what="$WHAT" \
  --argv='gh pr view 51 --token=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' --file </dev/null >/dev/null 2>&1
chk "a token behind a known flag is REDACTED, not refused — the report still files" 1 "$(wc -l < "$FILEMARK")"
if grep -qF 'ghp_AAAA' "$BODYMARK"; then
  fail_t "the token reached the FILED body: $(cat "$BODYMARK")"
else
  ok_t "...and the token is absent from the filed body"
fi

# A token-shaped string in the description is refused, not silently published.
: > "$FILEMARK"
err_sec=$(cmd_bug --verb=agent --exit=1 --what="broke while using ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" --file </dev/null 2>&1)
chk "--file refuses a token-shaped string in --what" "$E_USAGE" "$?"
chk "...and files nothing" 0 "$(wc -l < "$FILEMARK")"
rm -f "$FILEMARK" "$BODYMARK"

# ── 11. the failure hint PREFILLS the description ─────────────────────────────
# The mechanism arm: #553's hint would have carried gh's real parser error, so
# the filed issue says what broke instead of nothing.
CURRENT_VERB="gh"
hint2=$(fail "$E_GENERIC" "accepts at most 1 arg(s), received 2" 2>&1)
if grep -q -- '--what="accepts at most 1 arg(s), received 2"' <<<"$hint2"; then
  ok_t "fail()'s hint prefills --what with the error text it just printed"
else
  fail_t "the hint does not prefill --what: $hint2"
fi
hint3=$(fail "$E_GENERIC" $'quoted \'x\' and "y"\nsecond line' 2>&1)
hint3_line=$(grep '^hint:' <<<"$hint3")
if [[ "$hint3_line" == *"'"*"'"*"'"* ]]; then
  fail_t "a quote in the message survived into the single-quoted hint command: $hint3_line"
else
  ok_t "quotes/newlines are stripped from the prefilled --what (the hint stays copy-pasteable)"
fi

# ── 12. the hint is INERT when pasted (DIVE-3136 review, quinn) ───────────────
# Stripping only the quotes left a live command injection: --what sits inside
# DOUBLE quotes, which do NOT suppress $(...) or `...`, and $msg is
# caller-influenced via `fail "unknown flag: $1"`. The victim is whoever trusts
# the tool enough to paste its own suggestion. Graded on the EXACT payload from
# the review, and on the paste ACTUALLY being inert rather than on the strip
# having been performed — an echoed expectation is not a tested one.
# The marker path is STATIC on purpose. A $$ in it re-expands to the PASTED
# shell's own pid, so the arm would look for a file the injection never wrote
# and stay green while the payload fired — a false negative caught only by
# reverting the fix and watching this arm fail to notice.
#
# The path is also SHORT, and both metacharacters sit right after the marker
# word, because fail() truncates an "unknown flag" message 40 chars past it
# (the DIVE-2323 payload guard above). A longer payload pushed the backtick off
# the end, so that arm passed while asserting nothing — the truncation was
# grading the test instead of the code.
PWNED=/tmp/d3136p
EVIL="unknown flag: \`whoami\`\$(touch $PWNED)"
CURRENT_VERB="x"
hint4=$(fail "$E_GENERIC" "$EVIL" 2>&1)
hint4_line=$(grep '^hint:' <<<"$hint4")
what_arg="${hint4_line#*--what=\"}"; what_arg="${what_arg%%\"*}"
for ch in '$' '`' '\' "'"; do
  if [[ "$what_arg" == *"$ch"* ]]; then
    fail_t "shell metacharacter [$ch] survived into the pasteable --what: $hint4_line"
  else
    ok_t "metacharacter [$ch] is stripped from the prefilled --what"
  fi
done
# The end-to-end arm: extract the suggested command and RUN it through a shell
# that would betray any surviving substitution, then assert nothing happened.
rm -f "$PWNED"
suggested=$(sed -n "s/^hint: run '\(.*\)' to preview.*/\1/p" <<<"$hint4_line")
bash -c "cmd_bug() { :; }; five_probe() { :; }; : $suggested" >/dev/null 2>&1 || true
if [[ -e "$PWNED" ]]; then
  fail_t "PASTING the hint executed a substitution — the strip did not hold: $hint4_line"
else
  ok_t "pasting the suggested command executes nothing (the hint is inert end to end)"
fi
rm -f "$PWNED"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
