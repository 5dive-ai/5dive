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
_sc_dispatch() { printf '%s\n' "pass||clean detail line, nothing sensitive"; }

payload=$(_bug_render_payload "doctor" "3" 1)

keys=$(jq -cS 'keys' <<<"$payload")
chk "payload top-level keys are EXACTLY the allowlist (no more, no less)" \
  '["bash_version","exit_code","install_method","os","probes","verb","version"]' "$keys"

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
