#!/usr/bin/env bash
# TIER: core
# DIVE-4412 — A GATE THAT LOSES ITS KEYBOARD MUST NOT ALSO LOSE ITS OPTIONS.
#
# Customer report, forwarded by lodar 2026-09-13: a tier-1 decision gate with
# options A|B and a recommendation reached the human as
#
#     🙋 [DIVE-501] needs you
#     <ask> /task_508
#
# — an open question with nothing to choose from. The row was filed correctly.
#
# THE MECHANISM, and it is why these arms sit at the SEND boundary rather than on
# the renderer: since DIVE-3661 iteration 3 the renderer suppresses the numbered
# `Options:` list and the `✅ Recommended:` line whenever the keyboard it just
# COMPUTED already says those words. `_mirror_post`, on a Bot API rejection of
# `reply_markup`, retries once WITHOUT the keyboard — and used to re-send that
# same already-suppressed text. Both predicates were right about the message the
# renderer built and wrong about the message the human received. A harness that
# stubs `_task_send_owner` (the shape of every sibling gate harness) sees only the
# renderer's output and is blind to the entire defect, so every arm here drives
# the real _task_send_owner → _task_post_owner_target → _mirror_post chain and
# stubs only `_mirror_send`, the one call that talks to Telegram.
#
#   F1-F4  THE REJECTED KEYBOARD (decision). The first send carries a keyboard and
#          is refused 400; the second must carry the options, the ⭐ recommendation
#          and the on-box answer line. F4 is the arm that makes this more than a
#          tautology: the DELIVERED text must DIFFER from the attempted one, so a
#          "fix" that simply stopped suppressing (and duplicated the buttons on the
#          happy path) cannot pass F1 and F5 together.
#   F5-F6  THE HAPPY PATH IS UNCHANGED — one send, no Options list, no Recommended
#          line beside a ⭐ button. This is DIVE-3661's acceptance, re-pinned here
#          because it is what the cheap version of this fix breaks.
#   F7     APPROVAL, whose buttons are generic verbs: the recommendation is the
#          prose line's only copy on BOTH paths, and exactly once on each.
#   F8     THE NO-KEYBOARD CHANNEL (a type outside the tna allowlist) — the two
#          variants must be byte-identical, because there is nothing to suppress.
#   F9-F10 THE /inbox DIGEST re-send (`_task_inbox_send`), the second composer,
#          which carries its own copy of both suppressions (DIVE-1490's rule: the
#          first delivery and every re-send share the affordance). F10 is its
#          negative control.
#
# The re-nag batch (`_hb_gate_renag_batch_one`) emits Recommended and Options
# UNCONDITIONALLY already, so it has nothing to lose on the fallback; it is named
# here so the next reader does not re-derive that.
#
# Isolation: src/ sourced into a throwaway STATE_DIR, the shared tasks.db is never
# opened, no network. Fixture chat id is the reserved fake 1234567890.
# Run: bash tests/gate_keyboard_reject_fallback_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC="${GRTC_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/gate-kbreject.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

task_need_notify() { return 0; }
audit_log() { :; }
_task_gate_delivery_log() { :; }          # writes under /var/log on a real box
_mirror_log_button_reject() { :; }        # same; its content is DIVE-1338's arm
_human_registry_active() { return 1; }    # no human registry -> _task_send_owner

ACCESS="$TMP/access.json"
printf '%s' '{"allowFrom":["1234567890"],"groups":{}}' >"$ACCESS"
FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
CH_TYPE=claude
_task_owner_channel() { TASK_CH_TOKEN=stub; TASK_CH_ACCESS="$ACCESS"; TASK_CH_TYPE="$CH_TYPE"; TASK_CH_AGENT=t; return 0; }

# The only stub on the send chain: the HTTP call itself. REJECT_KB=1 makes the
# Bot API refuse any send carrying a reply_markup — the customer's box, whatever
# its cause (a closed forum topic, an oversized keyboard, a stale chat).
# The capture goes to FILES, not variables: _mirror_post calls this inside a
# command substitution, so a counter incremented here dies with the subshell —
# an in-variable capture reads as "zero sends" for every arm, pass or fail.
SENDS=0; SENT_1=""; SENT_2=""; KB_1=""; KB_2=""; REJECT_KB=0
SENDLOG="$TMP/sends"
_mirror_send() { # <token> <chat> <thread> <text> <markup>
  local n; mkdir -p "$SENDLOG"; n=$(( $(ls "$SENDLOG" 2>/dev/null | grep -c '^text\.') + 1 ))
  printf '%s' "$4" >"$SENDLOG/text.$n"; printf '%s' "${5:-}" >"$SENDLOG/kb.$n"
  if [[ "$(cat "$SENDLOG/reject" 2>/dev/null)" == "1" ]] && [[ -n "${5:-}" ]]; then
    printf '%s' '{"ok":false,"error_code":400,"description":"Bad Request: BUTTON_DATA_INVALID"}'
  else
    printf '%s' '{"ok":true,"result":{"message_id":'"$n"'}}'
  fi
}
reset_capture() { rm -rf "$SENDLOG"; mkdir -p "$SENDLOG"; printf '%s' "$REJECT_KB" >"$SENDLOG/reject"; }
read_capture() {
  SENDS=$(ls "$SENDLOG" 2>/dev/null | grep -c '^text\.')
  SENT_1=$(cat "$SENDLOG/text.1" 2>/dev/null); KB_1=$(cat "$SENDLOG/kb.1" 2>/dev/null)
  SENT_2=$(cat "$SENDLOG/text.2" 2>/dev/null); KB_2=$(cat "$SENDLOG/kb.2" 2>/dev/null)
}

seed_gate() { # <ident> <need_type> <options> <recommend>
  db "INSERT INTO tasks (ident, title, status, priority, assignee, created_by, need_type, tier,
                         ask, need_options, recommend, need_asked_at)
      VALUES ($(sqlq "$1"),'t','blocked','high','dev','main',$(sqlq "$2"),1,
              'ship it as a dark launch or hold for the on-box arm',
              $(sqlq "$3"), $(sqlq "$4"), datetime('now','-2 hours'));"
}
# need_asked_at two hours back: DIVE-4154's undo window holds a freshly filed
# gate and a held ping composes no text at all, which would pass every negative
# arm below vacuously.

deliver() { # <ident> <type> <options> <recommend>
  reset_capture
  _task_need_notify_deliver "$1" "$2" "ship it as a dark launch or hold for the on-box arm" "$3" "$4" "" "" "" >/dev/null 2>&1
  read_capture
}

# ==================== F1-F4: the rejected keyboard, decision ==================
seed_gate DIVE-9411 decision 'Ship it dark|Hold for the on-box arm' 'Ship it dark'
REJECT_KB=1
deliver DIVE-9411 decision 'Ship it dark|Hold for the on-box arm' 'Ship it dark'

(( SENDS == 2 )) && [[ -n "$KB_1" && -z "$KB_2" ]] \
  && ok_t "F1 a refused keyboard produces exactly one keyboard-less retry" \
  || bad_t "F1 a refused keyboard produces exactly one keyboard-less retry" "sends=$SENDS kb1=[${KB_1:0:60}] kb2=[${KB_2:0:60}]"

[[ "$SENT_2" == *"Options:"* && "$SENT_2" == *"1. Ship it dark ⭐"* && "$SENT_2" == *"2. Hold for the on-box arm"* ]] \
  && ok_t "F2 the DELIVERED fallback carries the numbered options with the ⭐" \
  || bad_t "F2 the DELIVERED fallback carries the numbered options with the ⭐" "text: ${SENT_2}"

[[ "$SENT_2" == *"✅ Recommended: Ship it dark"* && "$SENT_2" == *"Answer on the box: sudo 5dive task answer DIVE-9411"* ]] \
  && ok_t "F3 the fallback also carries the recommendation and the on-box answer line" \
  || bad_t "F3 the fallback also carries the recommendation and the on-box answer line" "text: ${SENT_2}"

# F4 the arm that keeps F2 from being satisfied by "never suppress anything":
# the keyboard-bearing attempt must still be the SHORT one.
[[ "$SENT_1" != *"Options:"* && "$SENT_1" != *"✅ Recommended:"* && "$SENT_1" != "$SENT_2" ]] \
  && ok_t "F4 the keyboard-bearing attempt is unchanged — the two texts DIFFER" \
  || bad_t "F4 the keyboard-bearing attempt is unchanged — the two texts DIFFER" "attempt1: ${SENT_1}"

# ==================== F5-F6: the happy path is untouched =====================
REJECT_KB=0
deliver DIVE-9411 decision 'Ship it dark|Hold for the on-box arm' 'Ship it dark'
(( SENDS == 1 )) && [[ -n "$KB_1" ]] \
  && ok_t "F5 a keyboard that LANDS is sent once, with its buttons" \
  || bad_t "F5 a keyboard that LANDS is sent once, with its buttons" "sends=$SENDS"
[[ "$SENT_1" != *"Options:"* && "$SENT_1" != *"✅ Recommended:"* && "$SENT_1" != *"Answer on the box"* ]] \
  && ok_t "F6 a landed keyboard still suppresses the duplicate prose (DIVE-3661)" \
  || bad_t "F6 a landed keyboard still suppresses the duplicate prose (DIVE-3661)" "text: ${SENT_1}"

# ==================== F7: approval — generic verbs on the buttons ============
seed_gate DIVE-9412 approval '' 'merge both'
REJECT_KB=1
deliver DIVE-9412 approval '' 'merge both'
_n1=$(grep -c 'Recommended: merge both' <<<"$SENT_1"); _n2=$(grep -c 'Recommended: merge both' <<<"$SENT_2")
[[ "$_n1" == "1" && "$_n2" == "1" && "$SENT_2" == *"--value=approved"* ]] \
  && ok_t "F7 an approval's recommendation survives on both paths, exactly once each" \
  || bad_t "F7 an approval's recommendation survives on both paths, exactly once each" "n1=$_n1 n2=$_n2 text2: ${SENT_2}"

# ==================== F8: a channel that gets no keyboard at all =============
# Nothing is suppressed there, so the two variants must be byte-identical — the
# control proving the fallback text is a RENDERING of the same message and not a
# second, divergent composition.
CH_TYPE=opencode
REJECT_KB=1
deliver DIVE-9411 decision 'Ship it dark|Hold for the on-box arm' 'Ship it dark'
(( SENDS == 1 )) && [[ -z "$KB_1" && "$SENT_1" == *"Options:"* ]] \
  && ok_t "F8 a no-keyboard channel sends once and already carries the options" \
  || bad_t "F8 a no-keyboard channel sends once and already carries the options" "sends=$SENDS kb=[${KB_1:0:40}]"
CH_TYPE=claude

# ==================== F9-F10: the /inbox digest re-send ======================
# Same chain, different composer. The subshell is required: _task_inbox_send
# finishes through `ok`, which exits.
run_digest() { # <ident> <reject>
  REJECT_KB="$2"; reset_capture
  ( require_root() { :; }; _task_inbox_send "" "ident=$(sqlq "$1")" "ORDER BY created_at" ) >/dev/null 2>&1
  read_capture
}
run_digest DIVE-9411 1; _d1="$SENT_1"; _d2="$SENT_2"
[[ -n "$_d2" && "$_d2" == *"Options: Ship it dark|Hold for the on-box arm"* && "$_d2" == *"✅ Recommended: Ship it dark"* ]] \
  && ok_t "F9 the /inbox digest fallback carries the options and the recommendation" \
  || bad_t "F9 the /inbox digest fallback carries the options and the recommendation" "d2: ${_d2}"
[[ -n "$_d1" && "$_d1" != *"Options: "* && "$_d1" != *"✅ Recommended:"* ]] \
  && ok_t "F10 the digest's keyboard-bearing attempt is unchanged" \
  || bad_t "F10 the digest's keyboard-bearing attempt is unchanged" "d1: ${_d1}"

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
