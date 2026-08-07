#!/usr/bin/env bash
# DIVE-2818 isolated unit harness — the REPLY-TO-CLEAR prompt on high-stakes
# tier-2 gates, and the scope boundary lodar set on it.
#
# WHY THIS EXISTS (measured, DIVE-2802, 2026-08-05):
#   * `--channel-msg` is the one non-forgeable human clear on this rail: the cited
#     message is attested by Telegram, the single party the filing agent cannot
#     speak for. It shipped, it verifies, and it had ZERO callers — 0 of 94
#     deployed tna.ts emit the flag. The weak nonce path was the only REACHABLE
#     one, which is what made the gate class clearable by its own filer.
#   * The cheapest possible trial of the strong path was run and it LOST: lodar
#     was invited to answer DIVE-2802 by replying, with the exact string printed
#     in the ask, and he tapped the button anyway. `channel_session=0` still.
#     A path whose only invitation is a sentence competing with a button is not a
#     reachable path, so the DEFAULT prompt is the fix and documentation is not.
#   * lodar then scoped it (DIVE-2802 gate, answered 20:41): HIGH-STAKES ONLY,
#     spend / secrets / irreversible. Not every tier-2 gate. The freshness window
#     is a hardcoded 3600s ceiling nobody may widen, so a mandatory strong path
#     would reject genuine human answers (DIVE-525: a real human tap is NEVER
#     rejected) and a universal prompt is a tax on the routine case.
#
# WHAT IS PINNED HERE, and the ordering is deliberate:
#   H1-H9  the DISCRIMINATOR. High-stakes is DECLARED (--needs=<sealed capability>
#          or --type=secret), never inferred from the ask's wording — DIVE-2629
#          measured what inference costs on this exact rail, where the word
#          `teardown` inside a git BRANCH NAME moved a gate's tier. H9 is the
#          scope boundary itself: a bare approval gate must NOT get the prompt.
#   C1-C5  the COPY names the exact string to send. Condition 5 of
#          `_gate_channel_session_ok` needs BOTH the ident AND the answer value,
#          so copy that says "reply to confirm" produces a refusal.
#   R1-R4  THE ROUND TRIP, and it is the arm that matters. The string our DM tells
#          the human to send is fed to the REAL `_gate_channel_session_ok` with
#          only the Bot API stubbed. This grades the copy against the function
#          that will actually judge it, rather than against a re-implementation of
#          its rule — a mirrored comparison passes forever on the day the checker
#          tightens, which is precisely when a test should fail.
#   I1-I4  the WIRING. The helpers being correct proves nothing about whether the
#          composed alert carries them, and a suite that grades only its own new
#          functions would pass with the call sites never added.
#
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR —
# the live shared tasks.db is NEVER touched, and no network is reached (the one
# call that would leave the box, `_gate_channel_api`, is stubbed by name).
# Fixture ids are the reserved fakes: chat/sender 1234567890, never a real one.
# Run: bash tests/gate_reply_to_clear_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC="${GRTC_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/grtc-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

task_need_notify() { return 0; }

seed_gate() { # <ident> <need_type> [needs_capability] [options] [recommend]
  db "INSERT INTO tasks (ident, title, status, created_by, need_type, needs_capability, need_options, recommend)
      VALUES ('$1','t','blocked','main','$2',$( [[ -n "${3:-}" ]] && printf "'%s'" "$3" || printf 'NULL'),
              $( [[ -n "${4:-}" ]] && printf "'%s'" "$4" || printf 'NULL'),
              $( [[ -n "${5:-}" ]] && printf "'%s'" "$5" || printf 'NULL'));"
}
rid() { db "SELECT id FROM tasks WHERE ident='$1';"; }

# ==================== H: THE DISCRIMINATOR (declared, never guessed) ==========

seed_gate DIVE-9001 approval spend_authority
seed_gate DIVE-9002 secret   secret_provision
seed_gate DIVE-9003 decision human_tap "A|B" "A"
seed_gate DIVE-9004 secret   ""
seed_gate DIVE-9005 approval ""
seed_gate DIVE-9006 decision "" "A|B" ""
seed_gate DIVE-9007 manual   ""
seed_gate DIVE-9008 approval "Human-Tap"
seed_gate DIVE-9009 approval "delegated_push"

for spec in "DIVE-9001:spend_authority declares high-stakes" \
            "DIVE-9002:secret_provision declares high-stakes" \
            "DIVE-9003:human_tap declares high-stakes (lodar's 'irreversible')" \
            "DIVE-9004:--type=secret alone is high-stakes (the filer typed the type)"; do
  _i="${spec%%:*}"; _d="${spec#*:}"
  _task_gate_high_stakes "$(rid "$_i")" \
    && ok_t "H ${_d}" \
    || bad_t "H ${_d}" "expected high-stakes for $_i"
done

for spec in "DIVE-9005:a bare approval gate is NOT high-stakes (the scope boundary)" \
            "DIVE-9006:a bare decision gate is NOT high-stakes" \
            "DIVE-9007:a bare manual gate is NOT high-stakes"; do
  _i="${spec%%:*}"; _d="${spec#*:}"
  _task_gate_high_stakes "$(rid "$_i")" \
    && bad_t "H ${_d}" "$_i was treated as high-stakes; lodar scoped this OUT" \
    || ok_t "H ${_d}"
done

# The DIVE-2241 near-miss class, one layer up: `needs_capability` is stored
# VERBATIM, so a discriminator that compares against the sealed list directly
# would make a typo silently NOT high-stakes — the filer believes they declared
# spend and the prompt quietly does not appear.
_task_gate_high_stakes "$(rid DIVE-9008)" \
  && ok_t "H8 --needs=Human-Tap still declares high-stakes (case + separator normalised)" \
  || bad_t "H8 --needs=Human-Tap still declares high-stakes (case + separator normalised)" "normalisation not applied"

_task_gate_high_stakes "$(rid DIVE-9009)" \
  && bad_t "H9 an AGENT capability (delegated_push) is not high-stakes" "delegated_push must fall through untouched" \
  || ok_t "H9 an AGENT capability (delegated_push) is not high-stakes"

# ==================== C: THE COPY NAMES THE EXACT STRING =====================

txt=$(_task_gate_reply_cta DIVE-9001 approval "" "")
[[ "$txt" == *"DIVE-9001 approved"* && "$txt" == *"DIVE-9001 denied"* ]] \
  && ok_t "C1 an approval CTA prints both exact strings (approved / denied)" \
  || bad_t "C1 an approval CTA prints both exact strings (approved / denied)" "text: $txt"

txt=$(_task_gate_reply_cta DIVE-9007 manual "" "")
[[ "$txt" == *"DIVE-9007 done"* ]] \
  && ok_t "C2 a manual CTA prints the exact string (done)" \
  || bad_t "C2 a manual CTA prints the exact string (done)" "text: $txt"

# The secret CTA must offer `provided` — the tap path's own value — and must NEVER
# invite the credential into the chat log. DIVE-2232 is the live case: main nearly
# received a raw credential in a persistent DM.
txt=$(_task_gate_reply_cta DIVE-9002 secret "" "")
[[ "$txt" == *"DIVE-9002 provided"* ]] && [[ "$txt" != *"paste"* ]] \
  && ok_t "C3 a secret CTA offers 'provided' and never invites the credential into chat" \
  || bad_t "C3 a secret CTA offers 'provided' and never invites the credential into chat" "text: $txt"

txt=$(_task_gate_reply_cta DIVE-9003 decision "A|B" "B")
[[ "$txt" == *"DIVE-9003 B"* ]] \
  && ok_t "C4 a decision CTA leads with the RECOMMENDED option value" \
  || bad_t "C4 a decision CTA leads with the RECOMMENDED option value" "text: $txt"

txt=$(_task_gate_reply_cta DIVE-9006 decision "A|B" "")
[[ "$txt" == *"DIVE-9006 A"* ]] \
  && ok_t "C5 a decision CTA with no recommendation falls back to the first option" \
  || bad_t "C5 a decision CTA with no recommendation falls back to the first option" "text: $txt"

# ==================== R: THE ROUND TRIP against the REAL checker ==============
# Only the Bot API is stubbed. Conditions 1-5 of `_gate_channel_session_ok` run
# for real against the very string the DM tells the human to send.
CHAT=1234567890
_gate_channel_proof_ok() { TASK_CH_TOKEN=stub-token; return 0; }
STUB_TEXT=""; STUB_AGE=0
_gate_channel_api() { # <token> <method> ...
  case "$2" in
    forwardMessage)
      printf '{"ok":true,"result":{"message_id":999,"text":%s,"forward_origin":{"type":"user","sender_user":{"id":%s},"date":%s}}}' \
        "$(printf '%s' "$STUB_TEXT" | jq -Rs .)" "$CHAT" "$(( $(date +%s) - STUB_AGE ))" ;;
    *) printf '{"ok":true}' ;;
  esac
}

# Extract the reply line our copy prints, exactly as a human would copy it.
cta_line() { # <ident> <need_type> <options> <recommend>
  _task_gate_reply_cta "$1" "$2" "${3:-}" "${4:-}" \
    | grep -oE "$1 [^)]*" | head -1 | sed 's/[[:space:]]*$//'
}

STUB_TEXT="$(cta_line DIVE-9001 approval)"; STUB_AGE=60
if _gate_channel_session_ok "$CHAT" 4242 "approved" "DIVE-9001"; then
  ok_t "R1 the exact string our approval DM prints CLEARS the real checker (${STUB_TEXT})"
else
  bad_t "R1 the exact string our approval DM prints CLEARS the real checker" "text='$STUB_TEXT' reason=${TASK_CS_REASON:-}"
fi

STUB_TEXT="$(cta_line DIVE-9003 decision "A|B" "B")"; STUB_AGE=60
_gate_channel_session_ok "$CHAT" 4242 "B" "DIVE-9003" \
  && ok_t "R2 the exact string our decision DM prints CLEARS the real checker (${STUB_TEXT})" \
  || bad_t "R2 the exact string our decision DM prints CLEARS the real checker" "text='$STUB_TEXT' reason=${TASK_CS_REASON:-}"

# NON-VACUITY. If a bare "yes" also cleared, R1/R2 would be proving nothing about
# the copy's specificity — the whole reason the DM must print the value is that
# naming the gate alone leaves `--value` coming from the agent.
STUB_TEXT="DIVE-9001 yes"; STUB_AGE=60
_gate_channel_session_ok "$CHAT" 4242 "approved" "DIVE-9001" \
  && bad_t "R3 a reply naming the gate but NOT the answer is refused" "it cleared; the copy's specificity is not load-bearing" \
  || ok_t "R3 a reply naming the gate but NOT the answer is refused (${TASK_CS_REASON:0:48}...)"

# The 1-hour claim in our copy is a real bound, not decoration.
STUB_TEXT="$(cta_line DIVE-9001 approval)"; STUB_AGE=3700
_gate_channel_session_ok "$CHAT" 4242 "approved" "DIVE-9001" \
  && bad_t "R4 a reply older than the 3600s ceiling is refused" "a stale reply cleared" \
  || ok_t "R4 a reply older than the 3600s ceiling is refused (the copy's '1 hour' is real)"

unset -f _gate_channel_proof_ok _gate_channel_api

# ==================== I: THE WIRING ==========================================
# Helpers that are never called are a suite grading itself. These arms compose the
# real alert and read the text that would be sent.
CAPTURED=""; CAPTURED_KB=""
_task_send_owner() { CAPTURED="$1"; CAPTURED_KB="${2:-}"; TASK_SEND_DELIVERED=1; return 0; }
_task_owner_channel() { TASK_CH_TOKEN=stub; TASK_CH_ACCESS=/dev/null; TASK_CH_TYPE=claude; TASK_CH_AGENT=t; return 0; }

CAPTURED=""
_task_need_notify_deliver DIVE-9001 approval "approve the spend" "" "" "" "" "" >/dev/null 2>&1
if [[ "$CAPTURED" == *"High-stakes gate"* && "$CAPTURED" == *"DIVE-9001 approved"* ]]; then
  ok_t "I1 a high-stakes gate's ALERT TEXT carries the reply-to-clear prompt"
else
  bad_t "I1 a high-stakes gate's ALERT TEXT carries the reply-to-clear prompt" "text: ${CAPTURED:0:400}"
fi

# The tap must survive beside it. DIVE-525: a real human tap is NEVER rejected,
# and the 3600s ceiling guarantees some genuine answers must fall back to it.
[[ "$CAPTURED_KB" == *'"tna:'*':approved'* ]] \
  && ok_t "I2 the tap button survives alongside the prompt (the fallback is intact)" \
  || bad_t "I2 the tap button survives alongside the prompt (the fallback is intact)" "markup: $CAPTURED_KB"

CAPTURED=""
_task_need_notify_deliver DIVE-9005 approval "approve the routine thing" "" "" "" "" "" >/dev/null 2>&1
[[ "$CAPTURED" != *"High-stakes gate"* ]] \
  && ok_t "I3 a routine tier-2 approval gate's alert does NOT carry the prompt (lodar's scope)" \
  || bad_t "I3 a routine tier-2 approval gate's alert does NOT carry the prompt (lodar's scope)" "text: ${CAPTURED:0:400}"

# A prompt on a channel whose plugin has no inbound handler is a dead affordance
# the human only discovers AFTER typing. This allowlist is NARROWER than the tap
# buttons' (claude|codex|grok|antigravity) because the DIVE-2818 inbound handler
# ships on the CLAUDE plugin only: the runtimes do not share a server (the
# generator builds agy/qwen from telegram-grok, and codex/pi/opencode are separate
# trees again), so each fork is its own job. codex is the arm that matters here —
# it HAS a `tna:` handler, so a reader who assumed "tap list == prompt list" would
# have shipped a dead prompt to it.
for _ct in codex grok antigravity opencode; do
  eval "_task_owner_channel() { TASK_CH_TOKEN=stub; TASK_CH_ACCESS=/dev/null; TASK_CH_TYPE=$_ct; TASK_CH_AGENT=t; return 0; }"
  CAPTURED=""
  _task_need_notify_deliver DIVE-9001 approval "approve the spend" "" "" "" "" "" >/dev/null 2>&1
  [[ "$CAPTURED" != *"High-stakes gate"* ]] \
    && ok_t "I4 no prompt on channel type '$_ct' (tap handler yes, inbound handler no)" \
    || bad_t "I4 no prompt on channel type '$_ct' (tap handler yes, inbound handler no)" "text: ${CAPTURED:0:400}"
done

printf '\ngate reply-to-clear unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
