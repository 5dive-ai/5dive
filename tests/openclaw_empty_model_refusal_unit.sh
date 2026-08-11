#!/usr/bin/env bash
# DIVE-3130: `--type=openclaw --provider=<p>` where <p> has NO
# OPENCLAW_PROVIDER_MODEL row (zai, qwen, huggingface — minimax got one in
# DIVE-3184 and is now a control arm below) and no --model
# must REFUSE before the credential write, instead of writing a key with no
# model pin. openclaw then falls back to its built-in default, whose first path
# segment picks the provider AND the credential, so the seat reports AUTH ok and
# 401s on every message ("auth or provider access failed for openai").
#
# The DIVE-3113 wrong-provider check cannot cover this: it is guarded by
# `[[ -n "$model" ]]`, so an EMPTY resolved model walks through it. This harness
# grades the empty case specifically — see
# community/wiki/an-unconfigured-model-authenticates-against-the-wrong-provider.md
#
# Static/behavioural: `fail` and every writer (install/mktemp/mv/chown/chmod/
# sudo) are stubbed, so no root, no network, no filesystem state outside a
# tempdir, and no credential is ever written by the run.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMPD:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_auth.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || { echo "source FAIL: $f"; exit 7; }
done
set +e

TMPD=$(mktemp -d)
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Run _apply_byo_openclaw with every mutating call stubbed. Prints the refusal
# message on stdout; prints WROTE_AUTH=1 if the credential write was reached.
run_byo() { # <native> <canonical> [model]
  (
    export TMPD
    fail()    { printf 'FAIL[%s]: %s\n' "$1" "$2"; exit 90; }
    step()    { :; }
    warn()    { :; }
    install() { :; }
    chown()   { :; }
    chmod()   { :; }
    sudo()    { :; }
    mktemp()  { command mktemp -p "$TMPD" oc.XXXXXX; }
    mv()      { printf 'WROTE_AUTH=1\n'; command rm -f "$1"; }
    _apply_byo_openclaw "$1" "$2" "sk-test-0123456789" "" "${3:-}"
  ) 2>&1
}

# ── Defect arm: the exact create from the ticket (zai, no --model) ────────────
out=$(run_byo zai zai); rc=$?
if (( rc == 90 )) && [[ "$out" == *"no default model for provider 'zai'"* ]]; then
  ok_t "openclaw+zai with no --model refuses (rc=$rc)"
else
  bad_t "openclaw+zai with no --model did not refuse" "rc=$rc out=$out"
fi
[[ "$out" != *WROTE_AUTH=1* ]] \
  && ok_t "the refusal lands BEFORE the credential write (no auth-profiles.json)" \
  || bad_t "a credential was written despite the empty model pin" "$out"
[[ "$out" == *"--model"* && "$out" == *"models list --provider zai --plain"* ]] \
  && ok_t "refusal names the remedy and the oracle to grade it with" \
  || bad_t "refusal does not tell the operator how to proceed" "$out"

# Same hole, other providers with an id row and no model row. minimax was in
# this list until DIVE-3184 graded an id for it; it now sits in the control arm
# below, which is the same assertion with the sign flipped.
for p in qwen huggingface; do
  out=$(run_byo "$p" "$p"); rc=$?
  (( rc == 90 )) && [[ "$out" == *"no default model for provider '$p'"* ]] \
    && ok_t "openclaw+$p with no --model refuses too" \
    || bad_t "openclaw+$p was allowed through with no model pin" "rc=$rc out=$out"
done

# ── Control arm, expected value NON-ZERO: a provider WITH a catalog row must
# still create, and so must zai WITH an explicit --model. If either of these
# also refused, the guard above would be indistinguishable from a blanket
# breakage of the openclaw BYO path.
out=$(run_byo openai openai); rc=$?
[[ "$out" != *"no default model"* ]] \
  && ok_t "openclaw+openai (has a catalog row) is not caught by the guard" \
  || bad_t "the guard fires on a provider that HAS a model row" "rc=$rc out=$out"
# DIVE-3184: minimax moved out of the refusing set by being GIVEN a row, so it
# grades the transition, not just the guard: the refusal must stop firing AND
# the id that stopped it must be the graded pin, reaching openclaw_normalize_
# model unchanged (a wrong-provider prefix would fail there instead, so passing
# both arms is what says the row is routable and not merely non-empty).
out=$(run_byo minimax minimax); rc=$?
[[ "$out" != *"no default model"* ]] \
  && ok_t "openclaw+minimax with no --model now proceeds (DIVE-3184 row)" \
  || bad_t "the minimax row did not satisfy the guard" "rc=$rc out=$out"
[[ "${OPENCLAW_PROVIDER_MODEL[minimax]:-}" == "minimax/MiniMax-M2.7" ]] \
  && ok_t "minimax pin is the graded id (minimax/MiniMax-M2.7)" \
  || bad_t "minimax pin is not the graded id" "got '${OPENCLAW_PROVIDER_MODEL[minimax]:-<unset>}'"
[[ "$out" != *"selects provider"* ]] \
  && ok_t "the minimax pin's prefix routes to native 'minimax' (normalize clean)" \
  || bad_t "the minimax pin fails openclaw_normalize_model" "$out"
out=$(run_byo zai zai "zai/glm-4.6"); rc=$?
[[ "$out" != *"no default model"* ]] \
  && ok_t "openclaw+zai WITH --model still proceeds (zai kept, not dropped)" \
  || bad_t "an explicit --model does not satisfy the guard" "rc=$rc out=$out"

# ── Ordering, structurally: the refusal must sit inside the DIVE-3113
# precondition block, above the auth-profiles.json write. The behavioural arms
# above run with a stubbed writer; this one holds the ordering on any box.
body=$(declare -f _apply_byo_openclaw)
guard_line=$(grep -n 'no default model for provider' <<<"$body" | head -1 | cut -d: -f1)
write_line=$(grep -n 'Writing openclaw BYO auth-profiles.json' <<<"$body" | head -1 | cut -d: -f1)
if [[ -n "$guard_line" && -n "$write_line" ]] && (( guard_line < write_line )); then
  ok_t "empty-model refusal precedes the credential write in the source"
else
  bad_t "empty-model refusal is not above the credential write" \
        "guard=$guard_line write=$write_line"
fi

# The guard must not be re-nested under the `if [[ -n "$model" ]]` arm that made
# DIVE-3113 unable to see this case. Graded against the SOURCE, not `declare -f`:
# declare -f re-renders a line continuation as one line and would read the same
# either way.
create_src=$(<src/cmd_agent_create.sh)
grep -Eq '^  \[\[ -n "\$model" \]\] \\$' <<<"$create_src" \
  && ok_t "guard is an unconditional [[ -n \$model ]] || fail, not a nested if" \
  || bad_t "guard is not present in its unconditional form" \
           "$(grep -n 'n "\$model"' src/cmd_agent_create.sh)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
