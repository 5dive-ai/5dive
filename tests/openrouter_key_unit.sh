#!/usr/bin/env bash
# DIVE-5026 unit: `5dive config openrouter-key=-` — the OpenRouter key voice
# reads, written into the connector store from stdin, so the dashboard can take
# it in a form instead of opening a server terminal.
#
# WHAT IS ASSERTED HERE (the row's acceptance, one arm each)
#   WRITE.   openrouter-key=- reads one key from stdin and writes
#            OPENROUTER_API_KEY=<key> to <connectors>/openrouter.env, 640; config
#            (--json and text) reads it back as set; voice's own parser finds it.
#            Other lines in the file survive a set and a clear; clear on a
#            key-only file removes it.
#   TTY.     a terminal on stdin is refused before anything is read, and
#            nothing is written — driven through a real pty (`script`).
#   NOLEAK.  the key never appears in any output: the set's own output, config
#            (--json and text), the refusals (inline value, malformed stdin, a
#            second stdin reader, the tty).
#   BAD.     inline value, malformed stdin, two stdin readers: refused, and the
#            old key stays.
#   MUTANT.  deleting the tty check reds TTY (and, fed through the pty, the key
#            is written); a config that prints the key reds NOLEAK.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/openrouter-key-unit.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# One environment, written to a file, so the pty driver below sources the SAME
# setup as this shell. CMD_FILE lets a mutant stand in for cmd_box_config.sh.
cat >"$TMP/env.sh" <<EOF
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh lib/audit.sh \\
         lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/verify_policy.sh \\
         lib/reflex.sh; do
  source "$ROOT/src/\$f"
done
source "\${CMD_FILE:-$ROOT/src/cmd_box_config.sh}"
STATE_DIR="$TMP/state"; TASKS_DIR="\$STATE_DIR/tasks"; TASKS_DB="\$TASKS_DIR/tasks.db"
export BOX_CONFIG="$TMP/box.json"
export FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/etc/reflex-openrouter.key"
CONNECTORS_DIR="$TMP/connectors"
REGISTRY="$TMP/agents.json"
require_root() { return 0; }   # the setter's logic is the subject, not sudo
audit_log() { return 0; }
chown() { return 0; }          # root:claude needs root; the mode is still asserted
EOF
mkdir -p "$TMP/state/tasks" "$TMP/etc" "$TMP/connectors"
printf '{"agents":{"dev":{}}}\n' >"$TMP/agents.json"
# shellcheck source=/dev/null
source "$TMP/env.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

cfg()  { ( JSON_MODE=1; cmd_box_config "$@" ) 2>&1; }
cfgt() { ( JSON_MODE=0; cmd_box_config ) 2>&1; }
get()  { ( JSON_MODE=1; cmd_box_config ) 2>/dev/null | jq -r ".data.$1"; }
F="$CONNECTORS_DIR/openrouter.env"

# voice's parser, verbatim from 5dive-plugins plugins/voice/lib/voice-backend.sh
# (voice_openrouter_key): the file this verb writes must be one voice reads.
voice_reads() {
  local k
  k=$(grep -m1 -E '^(OPENROUTER_API_KEY|OPENROUTER_KEY)=' "$F" 2>/dev/null | cut -d= -f2-)
  k="${k%\"}"; k="${k#\"}"; k="${k%\'}"; k="${k#\'}"
  printf '%s' "$k"
}

SECRET="sk-or-v1-SENTINEL$(date +%s%N)abcdef"
noleak() { # <label> <output>
  if grep -qF -e "$SECRET" -e "${SECRET:10:12}" <<<"$2"; then bad_t "NOLEAK: $1" "key material in output"
  else ok_t "NOLEAK: $1"; fi
}

echo "── WRITE ───────────────────────────────────────────────────────────────"
check "unset before any write (config --json carries openrouter_key)" "$([[ "$(get openrouter_key)" == unset ]]; echo $?)"
SET_OUT=$(printf '%s\n' "$SECRET" | cfg openrouter-key=-)
check "openrouter-key=- reads stdin and reads back as set" "$([[ "$(get openrouter_key)" == set ]]; echo $?)" "$SET_OUT"
check "the set's own --json says set and names openrouter-key as applied" \
  "$(jq -e '.data.openrouter_key == "set" and (.data.applied | index("openrouter-key"))' <<<"$SET_OUT" >/dev/null; echo $?)" "$SET_OUT"
check "the connector holds exactly OPENROUTER_API_KEY=<key>" "$([[ "$(cat "$F")" == "OPENROUTER_API_KEY=$SECRET" ]]; echo $?)"
check "the connector is mode 640" "$([[ "$(stat -c %a "$F")" == 640 ]]; echo $?)" "$(stat -c %a "$F")"
check "voice's own parser reads the key back" "$([[ "$(voice_reads)" == "$SECRET" ]]; echo $?)"
check "config (text) shows openrouter-key = set" "$(grep -qx 'openrouter-key = set' <<<"$(cfgt)"; echo $?)"
check "the key is not in box.json, and reflex's key file is untouched" \
  "$(! grep -qF "$SECRET" "$BOX_CONFIG" && [[ ! -e "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE" ]]; echo $?)"

printf 'OPENROUTER_API_KEY=old\nOPENROUTER_BASE_URL=https://example.test/v1\n' >"$F"
printf '%s\n' "$SECRET" | cfg openrouter-key=- >/dev/null
check "a set replaces the key line and keeps the file's other lines" \
  "$([[ "$(cat "$F")" == "OPENROUTER_API_KEY=$SECRET"$'\n'"OPENROUTER_BASE_URL=https://example.test/v1" ]]; echo $?)" "$(cat "$F")"
cfg openrouter-key=clear >/dev/null
check "clear removes only the key line when other lines exist" \
  "$([[ "$(cat "$F")" == "OPENROUTER_BASE_URL=https://example.test/v1" && "$(get openrouter_key)" == unset ]]; echo $?)" "$(cat "$F")"
rm -f "$F"; printf '%s\n' "$SECRET" | cfg openrouter-key=- >/dev/null
cfg openrouter-key=clear >/dev/null
check "clear on a key-only connector removes the file" "$([[ ! -e "$F" && "$(get openrouter_key)" == unset ]]; echo $?)"
printf '%s\n' "$SECRET" | cfg openrouter-key=- >/dev/null

echo "── NOLEAK / BAD ────────────────────────────────────────────────────────"
noleak "the set's own output" "$SET_OUT"
noleak "config --json" "$(cfg)"
noleak "config (text)" "$(cfgt)"
INLINE=$(cfg "openrouter-key=$SECRET"; echo "rc=$?")
noleak "the inline-value refusal" "$INLINE"
check "an inline key is refused" "$(! grep -q 'rc=0' <<<"$INLINE"; echo $?)" "$INLINE"
BADSTDIN=$(printf 'has spaces %s\n' "$SECRET" | cfg openrouter-key=-; echo "rc=$?")
noleak "the malformed-stdin refusal" "$BADSTDIN"
check "a malformed stdin key is refused and the old key stays" \
  "$([[ "$(voice_reads)" == "$SECRET" ]] && ! grep -q 'rc=0' <<<"$BADSTDIN"; echo $?)" "$BADSTDIN"
TWO=$(printf '%s\n' "$SECRET" | cfg reflex-key=- openrouter-key=-; echo "rc=$?")
noleak "the two-stdin-readers refusal" "$TWO"
check "reflex-key=- and openrouter-key=- in one call are refused, nothing written" \
  "$(! grep -q 'rc=0' <<<"$TWO" && [[ ! -e "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE" ]]; echo $?)" "$TWO"

echo "── TTY ─────────────────────────────────────────────────────────────────"
# A real pty on stdin: `script` runs the driver with its stdin on a terminal, and
# what we pipe into `script` is what a person would type at it.
cat >"$TMP/tty-driver.sh" <<EOF
source "$TMP/env.sh"
JSON_MODE=1
[[ -t 0 ]] && echo "DRIVER-STDIN-IS-A-TTY"
cmd_box_config openrouter-key=-
echo "driver-rc=\$?"
EOF
tty_run() { # [CMD_FILE] — prints what the pty showed
  local tty_key="sk-or-v1-TTYTYPED$(date +%s%N)xyz"
  rm -f "$F"
  TTY_OUT=$( { sleep 0.5; printf '%s\n' "$tty_key"; sleep 0.5; } \
    | CMD_FILE="${1:-}" script -qec "bash $TMP/tty-driver.sh" /dev/null 2>&1 )
  TTY_KEY="$tty_key"
}
tty_run
check "the driver's stdin really is a terminal (the arm is live)" "$(grep -q DRIVER-STDIN-IS-A-TTY <<<"$TTY_OUT"; echo $?)" "$TTY_OUT"
check "a terminal on stdin is refused, naming the pipe" "$(grep -q 'not a terminal' <<<"$TTY_OUT" && ! grep -q 'driver-rc=0' <<<"$TTY_OUT"; echo $?)" "$TTY_OUT"
check "a terminal on stdin writes nothing" "$([[ ! -e "$F" ]]; echo $?)"
check "the refusal output carries no key" "$(! grep -qF "${TTY_KEY:9:10}" <<<"$(sed -n '/driver-rc/p;/not a terminal/p' <<<"$TTY_OUT")"; echo $?)"
printf '%s\n' "$SECRET" | cfg openrouter-key=- >/dev/null

echo "── MUTANT ──────────────────────────────────────────────────────────────"
# 1. The tty check deleted: the same pty run must now READ the typed key and
#    write it (the hazard the check exists for), so the TTY arm above goes red.
M1="$TMP/mut-tty.sh"
grep -v 'reads the key from a pipe, not a terminal' src/cmd_box_config.sh >"$M1"
if cmp -s "$M1" src/cmd_box_config.sh; then
  bad_t "MUTANT tty: the anchor moved" "update the grep in this harness"
else
  tty_run "$M1"
  if ! grep -q 'not a terminal' <<<"$TTY_OUT" && [[ "$(voice_reads)" == "$TTY_KEY" ]]; then
    ok_t "MUTANT tty: without the check the typed key is read and written — the TTY arm catches it"
  else bad_t "MUTANT tty: deleting the check changed nothing the arm sees" "$TTY_OUT"; fi
fi
printf '%s\n' "$SECRET" | cfg openrouter-key=- >/dev/null
# 2. A config that prints the key: the NOLEAK probe must catch it.
M2="$TMP/mut-leak.sh"
sed 's/--arg ms "\$ms" --arg ok "\$ok_k"/--arg ms "$ms" --arg ok "$(cat "$(_openrouter_connector_file)")"/' \
  src/cmd_box_config.sh >"$M2"
if cmp -s "$M2" src/cmd_box_config.sh; then
  bad_t "MUTANT leak: the anchor moved" "update the sed in this harness"
else
  MOUT=$( ( source "$M2"; JSON_MODE=1; cmd_box_config ) 2>&1)
  if grep -qF "$SECRET" <<<"$MOUT"; then ok_t "MUTANT leak: a config that prints the key is caught by the NOLEAK probe"
  else bad_t "MUTANT leak: the leak mutant did not leak — the probe is not proven" "$MOUT"; fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
