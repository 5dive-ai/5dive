#!/usr/bin/env bash
# TIER: nightly — PR core candidate; runs in about the same time as its sibling secret_gate_delivery_path_unit.sh.
# DIVE-8709 — a NO to a key ask. The app's Skip answers an ask "won't do it";
# on a secret gate that is `task answer <id> --value=declined`. Before this, a
# secret gate refused every --value and, once it named a store, refused to close
# until the key was in it, so the owner could only paste a key or leave the
# agent stuck.
#   D1  a drop-target gate with NO key in its store closes on "declined"
#   D2  ...stores the word, so a no is told apart from a key that landed
#   D3  ...writes nothing to the store
#   D4  ...pings the seat that the owner said no (not "is set in your environment")
#   D5  ...reports declined:true in --json
#   D6  any other --value on a secret gate is still refused and the row does not move
#   D7  "Declined" in another case is the same word
#   D8  a plain 'provided' with no key is still refused (DIVE-6856 kept)
# Mutation check: run with DECLINE_SRC_DIR=<a copy of origin/main's src> and
# D1-D5/D7 go red.
# Run: bash tests/secret_gate_decline_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC="${DECLINE_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/sgdecline-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
GATE_SEAM_INPROCESS=1
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
NONCE=""
task_need_notify() { NONCE="${8:-}"; return 0; }
_PIN_UID=987654
_gate_caller_uid() { printf '%s' "$_PIN_UID"; }
_gate_passwd_stream() {
  printf '%s:x:%s:%s::/nonexistent:/bin/false\n' "human-fixture" "$_PIN_UID" "$_PIN_UID"
  printf '%s\n' "$(</etc/passwd)"
}
# The resume ping goes through cmd_send; record it instead of sending.
PINGS="$TMP/pings"; : > "$PINGS"
cmd_send() { local a; for a in "$@"; do [[ "$a" == --message=* ]] && printf '%s\n' "${a#--message=}" >> "$PINGS"; done; return 0; }
seed_task() { db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('$1','t','todo','main','olivia');"; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

seed_task DIVE-8801
cmd_task_need DIVE-8801 --type=secret --ask="the GH_BOT_TOKEN" --secret-key=GH_BOT_TOKEN --connector=github-bot >/dev/null 2>&1
out=$(cmd_task_answer DIVE-8801 --from=main --human --human-proof="$NONCE" --value=declined 2>&1); rc=$?
[[ $rc -eq 0 && "$(field DIVE-8801 need_answered_at)" != "∅" ]] \
  && ok_t "D1 a drop-target gate with no key closes on 'declined'" \
  || bad_t "D1 a drop-target gate with no key closes on 'declined'" "rc=$rc out=$out"
[[ "$(field DIVE-8801 need_answer)" == "declined" ]] \
  && ok_t "D2 the row stores 'declined'" || bad_t "D2 the row stores 'declined'" "need_answer=$(field DIVE-8801 need_answer)"
[[ ! -e "$CONNECTORS_DIR/github-bot.env" ]] \
  && ok_t "D3 nothing was written to the store" || bad_t "D3 nothing was written to the store" "$(cat "$CONNECTORS_DIR/github-bot.env")"
ping=$(cat "$PINGS")
[[ "$ping" == *"DIVE-8801 secret gate DECLINED"*"GH_BOT_TOKEN"* && "$ping" != *"is set in your environment"* && "$ping" != *"provided"* ]] \
  && ok_t "D4 the seat is told the owner said no" || bad_t "D4 the seat is told the owner said no" "ping=$ping"
[[ "$out" == *'"declined":true'* || "$out" == *'"declined": true'* ]] \
  && ok_t "D5 --json says declined:true" || bad_t "D5 --json says declined:true" "out=$out"

seed_task DIVE-8802
cmd_task_need DIVE-8802 --type=secret --ask="the GH_BOT_TOKEN" --secret-key=GH_BOT_TOKEN --connector=github-bot >/dev/null 2>&1
out=$(cmd_task_answer DIVE-8802 --from=main --human --human-proof="$NONCE" --value=nope 2>&1); rc=$?
[[ $rc -ne 0 && ( "$out" == *"do not pass --value"* || "$out" == *"The key isn't saved yet"* ) && "$(field DIVE-8802 need_answered_at)" == "∅" && "$(field DIVE-8802 status)" == "blocked" ]] \
  && ok_t "D6 any other --value on a secret gate is still refused, row unmoved" \
  || bad_t "D6 any other --value on a secret gate is still refused, row unmoved" "rc=$rc out=$out"

seed_task DIVE-8803
cmd_task_need DIVE-8803 --type=secret --ask="drop it" --out-of-band="in my .env on this box" >/dev/null 2>&1
out=$(cmd_task_answer DIVE-8803 --from=main --human --human-proof="$NONCE" --value=Declined 2>&1); rc=$?
[[ $rc -eq 0 && "$(field DIVE-8803 need_answer)" == "declined" ]] \
  && ok_t "D7 'Declined' (any case) is the same word" || bad_t "D7 'Declined' (any case) is the same word" "rc=$rc need_answer=$(field DIVE-8803 need_answer) out=$out"

seed_task DIVE-8804
cmd_task_need DIVE-8804 --type=secret --ask="the GH_BOT_TOKEN" --secret-key=GH_BOT_TOKEN --connector=github-bot >/dev/null 2>&1
out=$(cmd_task_answer DIVE-8804 --from=main --human --human-proof="$NONCE" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"The key isn't saved yet"* && "$(field DIVE-8804 need_answered_at)" == "∅" ]] \
  && ok_t "D8 'provided' with no key is still refused" || bad_t "D8 'provided' with no key is still refused" "rc=$rc out=$out"

printf '\nsecret-gate decline unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
