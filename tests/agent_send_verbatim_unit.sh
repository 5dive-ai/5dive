#!/usr/bin/env bash
# TIER: nightly — ~9s measured on the 5dive control-plane VM (standalone runs: 8.4s,
# 9.1s; the slower is claimed on purpose, a low claim is what the DIVE-2555 grader
# reds). Most of that is ONE `build.sh` into a throwaway path, which arm A needs and
# cannot fake: the acceptance clause says grade the RENDERED --help, not the source,
# and the source is not the artifact a caller reads. Nightly rather than core for the
# same reason prose_file_flags_unit.sh gives — core is already over its 300s ratchet
# on this box — and the bill is the same one: a future PR that breaks this file reds
# it after merging. changed-harnesses covers the PR that touches this file.
#
# DIVE-4421 unit harness: `agent send` / `agent ask` teach the VERBATIM body form
# first, accept it from stdin, and nudge a caller who is hand-assembling a body.
#
# WHY THE RENDERED HELP IS GRADED AND NOT src/main.sh. The usage block lives in an
# UNQUOTED heredoc (`cat <<USAGE`), so bash expands `$` and backticks inside it
# before a human ever sees the text. That is not hypothetical: the first draft of
# this very fix wrote "and `-` reads it from stdin" and the rendered help said
# "and  reads it from stdin" — the help text teaching people to avoid command
# substitution was itself eaten by command substitution. A grep of the source would
# have passed. So arm A builds the bundle and reads what a caller reads.
#
# Run: bash tests/agent_send_verbatim_unit.sh   (no root, no network, no tmux).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/agent-send-verbatim.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------------------
# THE PAYLOAD — every hazard the customer report names, at once.
# ---------------------------------------------------------------------------
# Quoted-delimiter heredoc, the one form safe in both directions, so this file's
# own authoring does not mangle the thing it grades. `US$4,500` and the backticked
# verb are the two VERBATIM instances from the 2026-09-13 report; $HOME and $(date)
# are the classes those two instances belong to. All four are needed: a payload
# carrying three of them passes against a half-fix.
PAYLOAD=$(cat <<'PAYLOAD_EOF'
budget is US$4,500 and $HOME must not expand, nor $(date)
run `5dive task need DIVE-1 --ask="x"` first, then `5dive push`
don't drop the maker's words — an apostrophe ends a single-quoted string
PAYLOAD_EOF
)
PAYLOAD="$PAYLOAD"$'\n'   # trailing newline, on purpose: it is what $(cat f) eats

anchor_ok=1
[[ "$PAYLOAD" == *'US$4,500'* ]] || { anchor_ok=0; bad_t "ANCHOR: payload carries the reported currency case" ""; }
[[ "$PAYLOAD" == *'`'* ]]        || { anchor_ok=0; bad_t "ANCHOR: payload carries a backtick" ""; }
[[ "$PAYLOAD" == *'$(date)'* ]]  || { anchor_ok=0; bad_t "ANCHOR: payload carries a command substitution" ""; }
[[ "$PAYLOAD" == *"'"* ]]        || { anchor_ok=0; bad_t "ANCHOR: payload carries an apostrophe" ""; }
[[ "$PAYLOAD" == *$'\n' ]]       || { anchor_ok=0; bad_t "ANCHOR: payload ends with a newline" ""; }
(( anchor_ok )) && ok_t "ANCHOR: payload carries every reported hazard class + a trailing newline"

# ---------------------------------------------------------------------------
# ARM A — the RENDERED help (acceptance (a))
# ---------------------------------------------------------------------------
HELP_BIN="$TMP/5dive-help"
if BUILD_OUT="$HELP_BIN" ./build.sh >"$TMP/build.log" 2>&1; then
  "$HELP_BIN" --help >"$TMP/help.txt" 2>&1
  send_line=$(grep -n '^  5dive agent send ' "$TMP/help.txt" | head -1 | cut -d: -f1)
  if [[ -n "$send_line" ]]; then
    sed -n "${send_line},\$p" "$TMP/help.txt" | sed -n '1,25p' > "$TMP/send_block.txt"
    # BYTE offsets, not line numbers: both forms sit on the SAME synopsis line, so
    # a line-number comparison reads 1 < 1 and grades nothing about the order.
    mf=$(grep -b -o -m1 -- '--message-file' "$TMP/send_block.txt" | head -1 | cut -d: -f1)
    mi=$(grep -b -o -m1 -- '--message=' "$TMP/send_block.txt" | head -1 | cut -d: -f1)
    { [[ -n "$mf" && -n "$mi" ]] && (( mf < mi )); } \
      && ok_t "A1 rendered help: --message-file is named BEFORE --message on the send synopsis" \
      || bad_t "A1 --message-file first" "message-file at byte ${mf:-none}, message at byte ${mi:-none}: $(head -1 "$TMP/send_block.txt")"
    # The expansion warning, graded on the RENDERED bytes. The literal "\$VAR" and
    # the backticks below are exactly what the unquoted heredoc would have eaten.
    { grep -q 'expands \$VAR' "$TMP/send_block.txt" \
      && grep -q '`cmd`' "$TMP/send_block.txt" \
      && grep -q '\$(cmd)' "$TMP/send_block.txt" \
      && grep -q 'US\$4,500' "$TMP/send_block.txt"; } \
      && ok_t "A2 rendered help carries the shell-expansion line, unexpanded (\$VAR, \`cmd\`, \$(cmd), US\$4,500)" \
      || bad_t "A2 expansion line survives rendering" "$(cat "$TMP/send_block.txt")"
    grep -q "message-file=- <<'EOF'" "$TMP/send_block.txt" \
      && ok_t "A3 rendered help shows the stdin heredoc form with a QUOTED delimiter" \
      || bad_t "A3 stdin form in help" "$(cat "$TMP/send_block.txt")"
  else
    bad_t "A1-A3 rendered help" "no '5dive agent send' line in --help"
  fi
  # `agent send --help` itself: it used to die with `unknown flag: --help`.
  "$HELP_BIN" agent send --help >"$TMP/send_help.txt" 2>"$TMP/send_help.err"; rc=$?
  { [[ $rc -eq 0 ]] && grep -q -- '--message-file' "$TMP/send_help.txt"; } \
    && ok_t "A4 '5dive agent send --help' exits 0 and renders the body flags (was: unknown flag)" \
    || bad_t "A4 send --help" "rc=$rc err: $(cat "$TMP/send_help.err")"
  "$HELP_BIN" agent ask --help >"$TMP/ask_help.txt" 2>&1; rc=$?
  { [[ $rc -eq 0 ]] && grep -q -- '--message-file' "$TMP/ask_help.txt"; } \
    && ok_t "A5 '5dive agent ask --help' exits 0 and renders the body flags" \
    || bad_t "A5 ask --help" "rc=$rc out: $(head -3 "$TMP/ask_help.txt")"
else
  bad_t "A1-A5 rendered help" "NOT-REACHED: build.sh failed — $(tail -3 "$TMP/build.log")"
fi

# ---------------------------------------------------------------------------
# In-process arms: source src/ directly (same isolation contract as
# prose_file_flags_unit.sh — nothing here touches the live registry or tmux).
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"
set +e   # header.sh enabled `set -e`; these arms expect non-zero exits

hexof()  { od -An -tx1 -v | tr -d ' \n' | tr 'a-f' 'A-F'; }
PAYLOAD_HEX=$(printf '%s' "$PAYLOAD" | hexof)

# THE CAPTURE. cmd_send's last act before it needs a live agent is the round
# guard, which receives the fully-resolved body as $3. Stubbing it is how this
# harness reads the bytes cmd_send would deliver without a tmux session: the real
# guard is called inside `$( )`, so the stub writes to a FILE — a variable
# assignment in that subshell would vanish (DIVE-4342's lesson, same shape).
# a2a_needs_scoped is forced false so cmd_send does not exec into sudo.
a2a_needs_scoped() { return 1; }
a2a_round_guard()  { printf '%s' "$3" > "$TMP/captured"; return 0; }
require_agent()    { echo "require_agent stub: stop here" >&2; return 1; }
# usage() lives in main.sh, which is not sourced here (it ends in `main "$@"`).
usage() { echo "<usage>"; }

send_capture() {   # send_capture <stdin-file|-> <args...> ; prints nothing, sets CAP_RC
  local stdin_src="$1"; shift
  rm -f "$TMP/captured"
  if [[ "$stdin_src" == "none" ]]; then
    ( cmd_send "$@" ) >"$TMP/out" 2>"$TMP/err"
  else
    ( cmd_send "$@" ) <"$stdin_src" >"$TMP/out" 2>"$TMP/err"
  fi
  CAP_RC=$?
}

# ---------------------------------------------------------------------------
# ARM B — --message-file=- is byte-identical (acceptance (b))
# ---------------------------------------------------------------------------
printf '%s' "$PAYLOAD" > "$TMP/payload.txt"
send_capture "$TMP/payload.txt" dev --message-file=-
if [[ -f "$TMP/captured" ]]; then
  [[ "$(hexof < "$TMP/captured")" == "$PAYLOAD_HEX" ]] \
    && ok_t "B1 --message-file=- delivers the body BYTE-identically (currency, backticks, \$HOME, \$(date), apostrophe, trailing newline)" \
    || bad_t "B1 stdin body byte-identical" "got: $(cat "$TMP/captured")"
else
  bad_t "B1 stdin body byte-identical" "cmd_send never reached the round guard; err: $(cat "$TMP/err")"
fi

# B2 — THE MUTATION ARM. Cut the stdin branch out of the SHIPPING function's own
# text (not a substituted stub) and assert the same assertion goes red. A reader
# that keeps `-` as a literal path is the obvious wrong implementation.
_real_reader=$(declare -f _read_prose_file)
eval "$(declare -f _read_prose_file | sed 's/if \[\[ "$path" == "-" \]\]; then/if false; then/')"
declare -f _read_prose_file | grep -q 'if false; then' \
  && ok_t "B2a MUTATION: the stdin branch is cut out of the shipping function's own text" \
  || bad_t "B2a mutation landed" "$(declare -f _read_prose_file | head -20)"
send_capture "$TMP/payload.txt" dev --message-file=-
{ [[ ! -f "$TMP/captured" ]] || [[ "$(hexof < "$TMP/captured")" != "$PAYLOAD_HEX" ]]; } \
  && ok_t "B2b MUTATION: without the stdin branch the SAME assertion fails (it is not vacuous)" \
  || bad_t "B2b mutation should have failed the round-trip" "the assertion grades nothing"
eval "$_real_reader"
declare -f _read_prose_file | grep -q 'if \[\[ "$path" == "-" \]\]' \
  && ok_t "B2c MUTATION: the real reader is restored before the remaining arms" \
  || bad_t "B2c reader not restored" "$(declare -f _read_prose_file | head -20)"

# B3 — the same body through `agent ask`, which had no file form at all before this.
CAP_ASK=""
rm -f "$TMP/captured"
( cmd_ask dev --message-file=- ) <"$TMP/payload.txt" >"$TMP/out" 2>"$TMP/err"
# cmd_ask does not reach a2a_round_guard, so grade the reader it now calls.
_PROSE_FILE_VALUE=""
( _read_prose_file --message-file - <"$TMP/payload.txt"; printf '%s' "$_PROSE_FILE_VALUE" > "$TMP/ask_body" )
{ [[ -f "$TMP/ask_body" ]] && [[ "$(hexof < "$TMP/ask_body")" == "$PAYLOAD_HEX" ]]; } \
  && ok_t "B3 'agent ask' accepts --message-file and reads it byte-identically (it had no file form at all)" \
  || bad_t "B3 ask --message-file" "err: $(cat "$TMP/err")"

# ---------------------------------------------------------------------------
# ARM C — a real path keeps every refusal DIVE-2627 shipped (acceptance (c))
# ---------------------------------------------------------------------------
# CORRECTION TO THE ROW, recorded here because the harness is where it is
# checkable: DIVE-4421's clause (c) asks that "a real path still refuses a
# symlink / a file another seat owns". NO SUCH CHECK EXISTS on main and none was
# added — _read_prose_file gates on -e / -f|-p|-c / -r only, and `-f` FOLLOWS a
# symlink, so a symlink to a readable regular file is accepted today and still is.
# Asserting a refusal that never existed would red this file for a reason unrelated
# to the diff; asserting the ones that DO exist is what "arms unchanged" can mean.
send_capture none dev --message-file="$TMP/nope.txt"
{ [[ $CAP_RC -eq $E_USAGE ]] && grep -q "no such file" "$TMP/err"; } \
  && ok_t "C1 a real path that does not exist is still refused (E_USAGE)" \
  || bad_t "C1 missing path refusal" "rc=$CAP_RC err: $(cat "$TMP/err")"
mkdir -p "$TMP/adir"
send_capture none dev --message-file="$TMP/adir"
{ [[ $CAP_RC -eq $E_USAGE ]] && grep -q "not a readable file" "$TMP/err"; } \
  && ok_t "C2 a non-regular path (directory) is still refused (E_USAGE)" \
  || bad_t "C2 directory refusal" "rc=$CAP_RC err: $(cat "$TMP/err")"
: > "$TMP/empty.txt"
send_capture none dev --message-file="$TMP/empty.txt"
{ [[ $CAP_RC -eq $E_VALIDATION ]] && grep -q "is empty" "$TMP/err"; } \
  && ok_t "C3 an EMPTY file is still refused (E_VALIDATION), not sent as an empty body" \
  || bad_t "C3 empty file refusal" "rc=$CAP_RC err: $(cat "$TMP/err")"
send_capture "$TMP/empty.txt" dev --message-file=-
{ [[ $CAP_RC -eq $E_VALIDATION ]] && grep -q "stdin was empty" "$TMP/err"; } \
  && ok_t "C4 EMPTY stdin is refused the same way a file is — '-' is not a hole in the guard" \
  || bad_t "C4 empty stdin refusal" "rc=$CAP_RC err: $(cat "$TMP/err")"
send_capture "$TMP/payload.txt" dev --message-file=- --message=x
{ [[ $CAP_RC -eq $E_USAGE ]] && grep -q "conflicts with" "$TMP/err"; } \
  && ok_t "C5 --message-file + --message is still refused rather than silently picking one" \
  || bad_t "C5 dupe refusal" "rc=$CAP_RC err: $(cat "$TMP/err")"
send_capture "$TMP/payload.txt" dev --message-file=- trailing words
{ [[ $CAP_RC -eq $E_USAGE ]] && grep -q "conflicts with the positional" "$TMP/err"; } \
  && ok_t "C6 --message-file + positional text is still refused rather than dropping the words" \
  || bad_t "C6 positional conflict" "rc=$CAP_RC err: $(cat "$TMP/err")"
rm -f "$TMP/captured"
( cmd_ask dev --message-file="$TMP/payload.txt" extra words ) >"$TMP/out" 2>"$TMP/err"; rc=$?
{ [[ $rc -eq $E_USAGE ]] && grep -q "conflicts with the positional" "$TMP/err"; } \
  && ok_t "C7 the same positional guard covers 'agent ask' (the new flag there gets the guard too)" \
  || bad_t "C7 ask positional conflict" "rc=$rc err: $(cat "$TMP/err")"

# ---------------------------------------------------------------------------
# ARM D — the send-side hint (acceptance (d))
# ---------------------------------------------------------------------------
hint_fires() { _agent_body_shell_hint "$1" "${2:-}" 2>&1; }
[[ -n "$(hint_fires 'a $x' '--message')" ]] \
  && ok_t "D1 the hint FIRES on --message='a \$x'" \
  || bad_t "D1 hint on \$" "printed nothing"
[[ -n "$(hint_fires 'see `5dive push`' '--message')" ]] \
  && ok_t "D2 the hint FIRES on a --message body carrying a backtick" \
  || bad_t "D2 hint on backtick" "printed nothing"
[[ -n "$(hint_fires 'a $x' '')" ]] \
  && ok_t "D3 the hint FIRES on the POSITIONAL form too (it went through the same shell)" \
  || bad_t "D3 hint on positional" "printed nothing"
[[ -z "$(hint_fires 'a $x' '--message-file')" ]] \
  && ok_t "D4 the hint is SILENT on --message-file (the form it exists to recommend)" \
  || bad_t "D4 hint silent on --message-file" "$(hint_fires 'a $x' '--message-file')"
[[ -z "$(hint_fires 'plain prose, no metacharacters' '--message')" ]] \
  && ok_t "D5 the hint is SILENT on an ordinary --message body (no nag on every send)" \
  || bad_t "D5 hint silent on plain prose" "$(hint_fires 'plain prose, no metacharacters' '--message')"
out=$(hint_fires 'a $x' '--message'); rc=$?
{ [[ $rc -eq 0 ]] && grep -q -- '--message-file' <<<"$out"; } \
  && ok_t "D6 the hint returns 0 (it can never fail a send) and NAMES --message-file" \
  || bad_t "D6 hint rc/content" "rc=$rc out=$out"
# The property that makes D1-D6 a reminder and not a detector, asserted rather
# than only commented: the reported CORRUPTED body has no metacharacter left in
# it by the time argv exists, so the hint is silent on it. This arm documents the
# declined request 2 in code — if someone later "fixes" the hint into a detector,
# this is the arm that tells them what they changed.
[[ -z "$(hint_fires 'the fee is US,500' '--message')" ]] \
  && ok_t "D7 the hint is SILENT on the already-corrupted body ('US,500') — a reminder, NOT a detector" \
  || bad_t "D7 hint must not claim to detect corruption" "$(hint_fires 'the fee is US,500' '--message')"

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
