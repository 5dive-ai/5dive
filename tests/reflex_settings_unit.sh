#!/usr/bin/env bash
# DIVE-4915 unit: reflex's box settings — `5dive config reflex-receipts=`,
# `reflex-model=`, `reflex-key=-` — and `5dive reflex status`.
#
# WHAT IS ASSERTED HERE (the row's acceptance, one arm each)
#   ROUND.   every key round-trips through `config --json`: receipts on/off/default,
#            model set/default, key set/clear (read back as set/unset only).
#   ENV.     FIVEDIVE_REFLEX_RECEIPTS=0 beats reflex-receipts=on, and `config`
#            names the environment as the source; with no env the box setting
#            actually stops a receipt from being written.
#   NOLEAK.  the key never appears in any output: config (text and --json), the
#            set's own output, reflex status, and the refusals (inline value,
#            malformed stdin). The file holds it, mode 600.
#   BAD.     bad values are refused and nothing is written.
#   STATUS.  `reflex status --json` shape, decisions in the last 24h, last replay.
#   MUTANT.  a config that prints the key in --json reds NOLEAK.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/reflex-settings-unit.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/verify_policy.sh \
         lib/reflex.sh cmd_box_config.sh cmd_reflex.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export BOX_CONFIG="$TMP/box.json"
export FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/etc/reflex-openrouter.key"
mkdir -p "$TASKS_DIR" "$TMP/etc"
REGISTRY="$TMP/agents.json"; printf '{"agents":{"dev":{}}}\n' >"$REGISTRY"
unset FIVEDIVE_REFLEX_RECEIPTS
require_root() { return 0; }   # the setter's logic is the subject, not sudo
audit_log() { return 0; }
JSON_MODE=0
set +e
tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

# Each call in a subshell: `fail` exits the shell it runs in.
cfg()  { ( JSON_MODE=1; cmd_box_config "$@" ) 2>&1; }
cfgt() { ( JSON_MODE=0; cmd_box_config ) 2>&1; }
get()  { ( JSON_MODE=1; cmd_box_config ) 2>/dev/null | jq -r ".data.$1"; }

echo "── ROUND ───────────────────────────────────────────────────────────────"
check "receipts default is on, source default" \
  "$([[ "$(get reflex_receipts)" == on && "$(get reflex_receipts_source)" == "default (on)" ]]; echo $?)"
cfg reflex-receipts=off >/dev/null
check "reflex-receipts=off round-trips, source box setting" \
  "$([[ "$(get reflex_receipts)" == off && "$(get reflex_receipts_source)" == "box setting" ]]; echo $?)"
cfg reflex-receipts=default >/dev/null
check "reflex-receipts=default clears the key (file no longer carries it)" \
  "$([[ "$(get reflex_receipts)" == on && "$(jq 'has("reflex_receipts")' "$BOX_CONFIG")" == false ]]; echo $?)"
check "model default is typesafe/jev-1.13" \
  "$([[ "$(get reflex_model)" == typesafe/jev-1.13 && "$(get reflex_model_source)" == default ]]; echo $?)"
cfg reflex-model=openai/gpt-5.1-mini >/dev/null
check "reflex-model=<id> round-trips" \
  "$([[ "$(get reflex_model)" == openai/gpt-5.1-mini && "$(get reflex_model_source)" == "box setting" ]]; echo $?)"
cfg reflex-model=default >/dev/null
check "reflex-model=default restores the default" "$([[ "$(get reflex_model)" == typesafe/jev-1.13 ]]; echo $?)"
check "key unset before any write" "$([[ "$(get reflex_key)" == unset ]]; echo $?)"

SECRET="sk-or-v1-SENTINEL$(date +%s%N)abcdef"
SET_OUT=$(printf '%s\n' "$SECRET" | cfg reflex-key=-)
check "reflex-key=- reads stdin and reads back as set" "$([[ "$(get reflex_key)" == set ]]; echo $?)" "$SET_OUT"
check "the key file holds exactly the key" "$([[ "$(cat "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE")" == "$SECRET" ]]; echo $?)"
check "the key file is mode 600" "$([[ "$(stat -c %a "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE")" == 600 ]]; echo $?)"
check "the key is not in box.json" "$(grep -qF "$SECRET" "$BOX_CONFIG"; [[ $? -ne 0 ]]; echo $?)"

echo "── NOLEAK ──────────────────────────────────────────────────────────────"
noleak() { # <label> <output>
  if grep -qF "$SECRET" <<<"$2" || grep -qF "${SECRET:10:12}" <<<"$2"; then bad_t "NOLEAK: $1" "key material in output"
  else ok_t "NOLEAK: $1"; fi
}
noleak "the set's own output" "$SET_OUT"
noleak "config --json" "$(cfg)"
noleak "config (text)" "$(cfgt)"
noleak "reflex status --json" "$( ( JSON_MODE=1; _reflex_status --json ) 2>&1)"
noleak "reflex status (text)" "$( ( JSON_MODE=0; _reflex_status ) 2>&1)"
INLINE=$(cfg "reflex-key=$SECRET"; echo "rc=$?")
noleak "the inline-value refusal" "$INLINE"
check "an inline key is refused" "$(grep -q 'rc=0' <<<"$INLINE"; [[ $? -ne 0 ]]; echo $?)" "$INLINE"
BADSTDIN=$(printf 'has spaces %s\n' "$SECRET" | cfg reflex-key=-; echo "rc=$?")
noleak "the malformed-stdin refusal" "$BADSTDIN"
check "a malformed stdin key is refused and the old key stays" \
  "$([[ "$(cat "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE")" == "$SECRET" ]] && ! grep -q 'rc=0' <<<"$BADSTDIN"; echo $?)"

echo "── ENV ─────────────────────────────────────────────────────────────────"
cfg reflex-receipts=on >/dev/null
E=$( ( export FIVEDIVE_REFLEX_RECEIPTS=0; JSON_MODE=1; cmd_box_config ) 2>/dev/null)
check "FIVEDIVE_REFLEX_RECEIPTS=0 beats reflex-receipts=on" "$([[ "$(jq -r .data.reflex_receipts <<<"$E")" == off ]]; echo $?)"
check "config names the environment as the source" \
  "$(jq -r .data.reflex_receipts_source <<<"$E" | grep -q '^FIVEDIVE_REFLEX_RECEIPTS=0'; echo $?)"
E1=$( ( export FIVEDIVE_REFLEX_RECEIPTS=1; cfg reflex-receipts=off >/dev/null; JSON_MODE=1; cmd_box_config ) 2>/dev/null)
check "FIVEDIVE_REFLEX_RECEIPTS=1 beats reflex-receipts=off" "$([[ "$(jq -r .data.reflex_receipts <<<"$E1")" == on ]]; echo $?)"
# Behaviour, not just the readout: the box setting stops a real receipt.
n0=$(db "SELECT COUNT(*) FROM lifecycle_events WHERE kind LIKE 'decision.%';")
( unset _REFLEX_BOX_RECEIPTS; reflex_receipt policy=task-route result=dev task_id=1 )
n1=$(db "SELECT COUNT(*) FROM lifecycle_events WHERE kind LIKE 'decision.%';")
check "reflex-receipts=off: a decision point writes no receipt" "$([[ "$n1" == "$n0" ]]; echo $?)" "$n0 -> $n1"
cfg reflex-receipts=on >/dev/null
( unset _REFLEX_BOX_RECEIPTS; reflex_receipt policy=task-route result=dev task_id=1 )
n2=$(db "SELECT COUNT(*) FROM lifecycle_events WHERE kind LIKE 'decision.%';")
check "reflex-receipts=on: the same call writes one" "$([[ "$n2" == $((n1 + 1)) ]]; echo $?)" "$n1 -> $n2"

echo "── BAD ─────────────────────────────────────────────────────────────────"
before=$(cat "$BOX_CONFIG")
for bad in reflex-receipts=maybe "reflex-model=no spaces/allowed" reflex-model=noslash \
           "reflex-model=a/$(printf 'x%.0s' {1..120})"; do
  out=$(cfg "$bad"; echo "rc=$?")
  check "refused: ${bad:0:40}" "$(grep -q 'rc=0' <<<"$out"; [[ $? -ne 0 ]]; echo $?)" "$out"
done
out=$(cfg reflex-model=openai/ok reflex-receipts=maybe; echo "rc=$?")
check "a bad value writes nothing, even beside a valid one" "$([[ "$(cat "$BOX_CONFIG")" == "$before" ]]; echo $?)"

echo "── STATUS ──────────────────────────────────────────────────────────────"
db "INSERT INTO lifecycle_events (ts, kind, detail) VALUES (datetime('now','-2 days'), 'decision.stuck', '{}');" >/dev/null 2>&1
S=$( ( JSON_MODE=1; _reflex_status --json ) 2>&1)
check "status carries receipts/model/key/decisions_24h/last_replay" \
  "$(jq -e 'has("receipts") and has("receipts_source") and has("model") and has("model_source") and .key == "set" and has("last_replay")' <<<"$S" >/dev/null; echo $?)" "$S"
check "decisions_24h counts only the last day" "$([[ "$(jq .decisions_24h <<<"$S")" == "$n2" ]]; echo $?)" "$S (want $n2)"
check "no replay yet -> last_replay null" "$([[ "$(jq -c .last_replay <<<"$S")" == null ]]; echo $?)"
_reflex_record_last_replay '{"generated_at":"2026-09-24T04:00:00Z","backend":"bash /x/reflex-openrouter-backend.sh --model=typesafe/jev-1.13","policies":[{"cases":3},{"cases":4}]}'
S=$( ( JSON_MODE=1; _reflex_status --json ) 2>&1)
check "a replay is recorded: at, decisions, and a backend LABEL (script + model, no path)" \
  "$([[ "$(jq -c .last_replay <<<"$S")" == '{"at":"2026-09-24T04:00:00Z","backend":"reflex-openrouter-backend.sh typesafe/jev-1.13","decisions":7}' ]]; echo $?)" "$S"
_reflex_record_last_replay '{"generated_at":"2026-09-24T05:00:00Z","backend":"fake:echo","policies":[{"cases":2}]}'
check "a fake backend records as itself" \
  "$([[ "$( ( JSON_MODE=1; _reflex_status --json ) 2>/dev/null | jq -r .last_replay.backend)" == fake:echo ]]; echo $?)"
S=$( ( TASKS_DB="$TMP/none.db"; JSON_MODE=1; _reflex_status --json ) 2>&1; echo "rc=$?")
check "an unreadable store is decisions_24h null, not an error" "$(grep -q '"decisions_24h":null' <<<"$S" && grep -q 'rc=0' <<<"$S"; echo $?)" "$S"
printf '%s\n' "x" | cfg reflex-key=clear >/dev/null
check "reflex-key=clear removes the file and reads back unset" \
  "$([[ ! -e "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE" && "$(get reflex_key)" == unset ]]; echo $?)"

echo "── MUTANT ──────────────────────────────────────────────────────────────"
# The row's own mutant: a config that prints the key in --json. The NOLEAK
# probe must catch it, or the arms above prove nothing.
printf '%s\n' "$SECRET" | cfg reflex-key=- >/dev/null
M=$(mktemp "$TMP/mut.XXXXXX.sh")
sed 's/--arg rk "\$rk" --arg p "\$(_box_config_path)"/--arg rk "$(cat "$(_reflex_key_file)")" --arg p "$(_box_config_path)"/' \
  src/cmd_box_config.sh >"$M"
if cmp -s "$M" src/cmd_box_config.sh; then
  bad_t "MUTANT: the anchor for the leak mutant moved" "update the sed in this harness"
else
  MOUT=$( ( source "$M"; JSON_MODE=1; cmd_box_config ) 2>&1)
  if grep -qF "$SECRET" <<<"$MOUT"; then ok_t "MUTANT: a config that prints the key is caught by the NOLEAK probe"
  else bad_t "MUTANT: the leak mutant did not leak — the probe is not proven" "$MOUT"; fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
