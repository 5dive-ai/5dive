#!/usr/bin/env bash
# TIER: nightly — 23.1s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2410: a settled gate must stop showing a live-looking approve button.
#
# WHAT THIS GRADES, and why each arm exists rather than just "it edits something":
#   selection   the right messages, and ONLY those (four exclusions, each probed)
#   liveness    every exclusion is probed POSITIVELY too — an arm that asserts
#               "444 was not edited" is worthless unless another arm proves 444
#               CAN be edited. A filter that rejects everything passes the first
#               and fails the second.
#   substring   `tasks=` is a comma list; DIVE-A must not match DIVE-AA
#   wiring      the real `task answer` / `--withdraw` / done-moot paths CALL it.
#               A helper nobody calls is the bug with extra steps.
#   format      the wiring arm reads a log written by the REAL emitter, so the
#               awk parser is coupled to the producer, not to a format invented here
#   fence       a non-prod store makes zero edits, AND the same input under
#               dry-run makes edits (so the fence-holds arm is not vacuous)
#   dryrun      _mirror_edit_markup physically cannot reach Telegram under dry-run
#   token       the DELIVERING bot's token is used, not the caller's (message_id is
#               scoped to a bot-chat pair — the wrong token edits the wrong message)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-button-retire.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
chk() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-1506 positive allowlist: this harness deliberately drives the human-facing
# retire path, so declare its ISOLATED db as prod. Nothing here can reach Telegram
# — every edit is captured by the stub below, and the one arm that exercises the
# real primitive runs under FIVEDIVE_NOTIFY_DRYRUN with curl itself stubbed.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate >/dev/null 2>&1

LOG="$TMP/gate-notify.log"
FIVEDIVE_GATE_NOTIFY_LOG="$LOG"
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
printf 'TELEGRAM_BOT_TOKEN=tok-marketing\n' >"$CONNECTORS_DIR/telegram-marketing.env"
printf 'TELEGRAM_BOT_TOKEN=tok-creative\n'  >"$CONNECTORS_DIR/telegram-creative.env"

# Capture the edits instead of performing them. token|chat|message_id per line.
EDITS="$TMP/edits"; : >"$EDITS"
EDIT_RESP='{"ok":true}'
_mirror_edit_markup() {
  printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$EDITS"
  printf '%s' "$EDIT_RESP"
}
edits() { sort "$EDITS" | tr '\n' ' ' | sed 's/ $//'; }
reset_edits() { : >"$EDITS"; }

row() { # <result> <tasks> <chat> <message_id> <via>
  printf '2026-07-30T04:00:00Z gate-delivery result=%s tasks=%s chat=%s message_id=%s via=%s path=owner-dm detail=%q\n' \
    "$1" "$2" "$3" "$4" "$5" "confirmed Bot API send" >>"$LOG"
}

# ---------------------------------------------------------------- selection ---
: >"$LOG"
row ok    DIVE-A       424242       111  marketing   # retire
row ok    DIVE-A       424242       222  marketing   # retire
row ok    DIVE-A       424242       111  marketing   # duplicate -> dedup
row error DIVE-A       424242       none marketing   # no message exists
row ok    DIVE-A       agent:olivia 333  marketing   # verifier leg, not a chat
row ok    DIVE-A       424242       0    marketing   # dry-run receipt, not a message
row ok    DIVE-B       424242       444  creative    # a different task
row ok    DIVE-B,DIVE-A -1001       555  marketing   # batched re-nag, whole-field match
row ok    DIVE-AA      424242       666  marketing   # substring trap: DIVE-A is a prefix

reset_edits
_task_gate_retire_buttons DIVE-A "answered by human:test" >/dev/null 2>&1
chk "retires exactly this gate's real messages, deduped" \
    "tok-marketing|-1001|555 tok-marketing|424242|111 tok-marketing|424242|222" "$(edits)"

# LIVENESS for every exclusion above. Each excluded message_id is now REQUIRED to
# be editable when it is genuinely in scope, so "444 was skipped" is a property of
# the filter and not of a helper that edits nothing.
reset_edits
_task_gate_retire_buttons DIVE-B "answered by human:test" >/dev/null 2>&1
chk "liveness: the other task's 444 and the shared batch 555 ARE editable for DIVE-B" \
    "tok-creative|424242|444 tok-marketing|-1001|555" "$(edits)"

reset_edits
_task_gate_retire_buttons DIVE-AA "answered by human:test" >/dev/null 2>&1
chk "liveness: 666 IS editable for DIVE-AA (so its absence above is the whole-field match)" \
    "tok-marketing|424242|666" "$(edits)"

reset_edits
_task_gate_retire_buttons DIVE-NOSUCH "answered by human:test" >/dev/null 2>&1
chk "a task with no deliveries edits nothing" "" "$(edits)"

# ------------------------------------------------------------------- token ---
# message_id is scoped to a bot-chat PAIR. Using the caller's token instead of the
# delivering bot's edits a different message or nothing at all (DIVE-2073).
reset_edits
TELEGRAM_BOT_TOKEN=tok-CALLER
_task_gate_retire_buttons DIVE-B "answered by human:test" >/dev/null 2>&1
chk "uses the DELIVERING bot's token (via=), never the caller's" \
    "tok-creative|424242|444 tok-marketing|-1001|555" "$(edits)"
unset TELEGRAM_BOT_TOKEN

: >"$LOG"; row ok DIVE-T 424242 777 ghostagent
reset_edits
_task_gate_retire_buttons DIVE-T "answered by human:test" >/dev/null 2>&1
chk "an unresolvable delivering bot performs no edit (rather than a wrong one)" "" "$(edits)"

# --------------------------------------------------------- benign refusals ---
# Two Bot API refusals mean the button is ALREADY un-tappable, which is the desired
# end state. Grading them as failures would fill the audit with false alarms and
# train readers to ignore the row that matters.
: >"$LOG"; row ok DIVE-R 424242 888 marketing
for pair in \
  '{"ok":false,"description":"Bad Request: message is not modified"}|ok' \
  '{"ok":false,"description":"Bad Request: message to edit not found"}|ok' \
  '{"ok":false,"description":"Bad Request: chat not found"}|error'; do
  EDIT_RESP="${pair%|*}"; want="${pair##*|}"
  reset_edits
  out=$(_task_gate_retire_buttons DIVE-R "answered by human:test" 2>&1)
  got=ok; grep -q 'could not retire the gate button' <<<"$out" && got=error
  chk "Bot API '$(jq -r '.description // "ok"' <<<"${pair%|*}")' grades as $want" "$want" "$got"
done
EDIT_RESP='{"ok":true}'

# ------------------------------------------------------------------- fence ---
# Store identity first (DIVE-1968): a fixture store must not edit a real chat. The
# fence-HOLDS arm is paired with a fence-RELEASED arm on the SAME input, so a
# helper that silently edits nothing cannot pass the holds arm.
: >"$LOG"; row ok DIVE-F 424242 999 marketing
reset_edits
FIVEDIVE_PROD_TASKS_DB="$TMP/not-the-prod-store.db" \
  _task_gate_retire_buttons DIVE-F "answered by human:test" >/dev/null 2>&1
chk "fence holds: a non-prod store performs no edit" "" "$(edits)"

reset_edits
FIVEDIVE_PROD_TASKS_DB="$TMP/not-the-prod-store.db" FIVEDIVE_NOTIFY_DRYRUN=1 \
  _task_gate_retire_buttons DIVE-F "answered by human:test" >/dev/null 2>&1
chk "fence is not vacuous: the SAME input under dry-run does edit" \
    "tok-marketing|424242|999" "$(edits)"

# ------------------------------- the real primitive honours the dry-run rail ---
# _mirror_edit_markup is the one function that can physically reach Telegram, and
# it is what a fixture harness would reach through if its stub were missed. Prove
# the guard is inside the primitive by stubbing curl and asserting it never runs.
CURL_HIT="$TMP/curl-hit"; : >"$CURL_HIT"
curl() { printf 'CALLED %s\n' "$*" >>"$CURL_HIT"; printf '%s' '{"ok":true}'; }
unset -f _mirror_edit_markup
# shellcheck disable=SC1090
source "$SRC/cmd_agent_runtime.sh"
FIVEDIVE_NOTIFY_DRYRUN=1 FIVEDIVE_NOTIFY_DRYRUN_LOG="$TMP/dry.log" \
  _mirror_edit_markup tok-marketing 424242 111 >/dev/null 2>&1
chk "under dry-run the real _mirror_edit_markup never calls the Bot API" "" "$(cat "$CURL_HIT")"
chk "and it records the would-be edit" "1" \
    "$(grep -c 'edit_markup chat=424242 message_id=111 markup=strip' "$TMP/dry.log" 2>/dev/null)"

FIVEDIVE_NOTIFY_DRYRUN=0 _mirror_edit_markup tok-marketing 424242 111 >/dev/null 2>&1
chk "with dry-run off it DOES call editMessageReplyMarkup (guard is not always-on)" "1" \
    "$(grep -c 'editMessageReplyMarkup' "$CURL_HIT" 2>/dev/null)"
chk "and omits reply_markup, which is how the Bot API removes a keyboard" "0" \
    "$(grep -c 'reply_markup' "$CURL_HIT" 2>/dev/null)"
unset -f curl

# ------------------------------------------------------------------ wiring ---
# The arms above grade the helper. These grade whether the CLOSE PATHS call it —
# and they read a delivery log written by the REAL emitter, so the awk parser is
# coupled to its producer. A format drift in _task_gate_delivery_log breaks these,
# which is the point: the hand-built rows above cannot catch that.
_mirror_edit_markup() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$EDITS"; printf '%s' '{"ok":true}'; }
ACCESS="$TMP/access.json"
printf '%s\n' '{"allowFrom":["1234567890"],"groups":{}}' >"$ACCESS"
_task_owner_channel() { TASK_CH_TOKEN=tok-marketing TASK_CH_ACCESS="$ACCESS" TASK_CH_TYPE=claude TASK_CH_AGENT=marketing; return 0; }
_task_agent_channel() { _task_owner_channel; }
_mirror_send() { printf '%s' '{"ok":true,"result":{"message_id":15491}}'; }
_mirror_log_button_reject() { :; }
_mirror_follow_migration() { :; }

# cmd_task_answer fires a REAL inter-agent resume ping through cmd_send, and this
# harness declares its fixture store as prod to get past the DIVE-1506 send fence
# — so the ping is NOT fenced and lands in a live agent's inbox. Measured, not
# theorised: the first run of this file delivered
# "DIVE-1 gate cleared — your 'decision' ask was answered" to agent-dev, because a
# fresh store numbers from 1 and DIVE-1 is a plausible-looking real ident.
# Same reflex the fixture-identifier convention exists for. Stub it, and COUNT the
# calls so the stub cannot rot into a no-op nobody notices.
# Counted in a FILE, not a variable: every close path below runs in a subshell, so
# an in-shell counter increments in the child and is lost — which reads as "the
# stub was never reached" and would have retired this assertion as a false alarm.
PINGLOG="$TMP/pings"; : >"$PINGLOG"
cmd_send() { printf 'x\n' >>"$PINGLOG"; return 0; }

seed_gate() { # <title> -> ident on stdout; files a real gate through the real notify path
  local id ident
  id=$( ( JSON_MODE=1 cmd_task_add "$1" ) 2>/dev/null | jq -r '.data.id // empty')
  [[ -n "$id" ]] || { printf ''; return 1; }
  ident=$(db "SELECT ident FROM tasks WHERE id=${id};" 2>/dev/null)
  [[ -n "$ident" ]] || { printf ''; return 1; }
  : >"$LOG"
  ( cmd_task_need "$ident" --type=decision --ask="proceed?" --options="A|B" --recommend=A ) >/dev/null 2>&1
  printf '%s' "$ident"
}

for arm in answer withdraw done; do
  ident=$(seed_gate "DIVE-2410 wiring arm: $arm")
  if [[ -z "$ident" ]]; then chk "wiring/$arm: seeded a gate" "yes" "no"; continue; fi
  chk "wiring/$arm: the real emitter logged a retirable delivery" "1" \
      "$(_task_gate_deliveries "$ident" | grep -c '15491')"
  reset_edits
  case "$arm" in
    answer)   ( cmd_task_answer   "$ident" --value=A ) >/dev/null 2>&1 ;;
    withdraw) ( cmd_task_need     "$ident" --withdraw ) >/dev/null 2>&1 ;;
    done)     ( cmd_task_cancel   "$ident" --result="moot" ) >/dev/null 2>&1 ;;
  esac
  chk "wiring/$arm: the close path retired the delivered button" \
      "tok-marketing|1234567890|15491" "$(edits)"
done

# The stub above is load-bearing containment, not decoration: if cmd_send stops
# being the resume path, this reads 0 and the next reader learns the harness lost
# its containment BEFORE a fixture ident reaches a real inbox again.
chk "the resume ping went through the stub (containment is live, not rotted)" "1" \
    "$([[ -s "$PINGLOG" ]] && echo 1 || echo 0)"

# A RE-FILED gate replaces the old one, so the outgoing gate's button asks a question
# the task no longer holds. Ordering is the correctness condition: retirement must
# run BEFORE the new delivery, or the fresh button is stripped by its own filing.
ident=$(seed_gate "DIVE-2410 wiring arm: refile")
if [[ -z "$ident" ]]; then chk "wiring/refile: seeded a gate" "yes" "no"; else
  reset_edits
  ( cmd_task_need "$ident" --type=approval --ask="really proceed?" ) >/dev/null 2>&1
  chk "wiring/refile: the outgoing gate's button was retired" \
      "tok-marketing|1234567890|15491" "$(edits)"
  chk "wiring/refile: and the REPLACEMENT gate's own button survives its filing" "1" \
      "$(_task_gate_deliveries "$ident" | grep -c '15491')"
fi

# park and verifier-reject are the two wirings the first pass shipped UNGRADED
# (olivia, iteration 1: deleting either call left 26/26 green). Both need setup the
# loop above cannot express — park REFUSES a live gate, and reject needs a
# maker→verifier loop — so they get their own arms rather than a fourth loop case.
#
# park: the gate must already be ANSWERED (cmd_task_park refuses to park over a live
# one, DIVE-1453), so the answer retires the button first. reset_edits AFTER that, so
# what this arm sees is park's OWN retire re-reading the same delivery log — not the
# answer's edit leaking forward.
ident=$(seed_gate "DIVE-2410 wiring arm: park")
if [[ -z "$ident" ]]; then chk "wiring/park: seeded a gate" "yes" "no"; else
  ( cmd_task_answer "$ident" --value=A ) >/dev/null 2>&1
  reset_edits
  ( cmd_task_park "$ident" --reason="fixture park" --wake=+7d ) >/dev/null 2>&1
  chk "wiring/park: park NULLs the gate columns and retires the delivered button" \
      "tok-marketing|1234567890|15491" "$(edits)"
fi

# verifier auto:reject: the gate is still OPEN and the reject stamps it
# '(superseded — task rejected, bounced to maker)' with provenance 'auto:reject'.
# Worst stale button of the set: a human tapping it would believe they authorized
# something an agent closed on their behalf. The maker must NOT be this harness's
# actor — a maker reject is refused as self-grading (DIVE-2112), which would make
# the arm pass on a refusal instead of on the retire.
ident=$(seed_gate "DIVE-2410 wiring arm: reject")
if [[ -z "$ident" ]]; then chk "wiring/reject: seeded a gate" "yes" "no"; else
  db "UPDATE tasks SET maker_agent='fixture-maker', verifier=$(sqlq "$(task_actor "")"),
        status='todo' WHERE ident=$(sqlq "$ident");"
  reset_edits
  ( cmd_task_reject "$ident" --feedback="fixture bounce" ) >/dev/null 2>&1
  chk "wiring/reject: auto:reject supersedes the gate and retires its button" \
      "tok-marketing|1234567890|15491" "$(edits)"
  chk "wiring/reject: and the gate really was superseded (the arm graded the retire, not a refusal)" \
      "auto:reject" \
      "$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident=$(sqlq "$ident");")"
fi

# ------------------------------------------ file-time settle site: tier-0 ----
# olivia's open question on iteration 1: cmd_task_need can itself SETTLE a gate at
# FILE time — the DIVE-891 tier-0 auto-clear — and it is wired to no retire. That is
# correct only because such a gate never DELIVERS: it self-answers and returns before
# task_need_notify, so there is no button of its own to retire, and any button the
# OUTGOING gate left is already stripped by the re-file retire that runs first. If
# that stops holding it becomes a seventh settle path closing a delivered gate with
# no retire — a silent no-op, which is the whole failure mode of this ticket.
#
# Graded behaviourally on purpose, and the observable was chosen the hard way — TWO
# drafts of this arm passed against a file whose tier-0 return had been deleted:
#   1. Static (assert the `return` sits above the first notify). `the first bare
#      return after the write` just re-resolved to the NEXT branch's return, still
#      above the notify. A reachability claim needs the run, not the line order.
#   2. Behavioural but reading `_task_gate_deliveries`. That view DEDUPES identical
#      lines (see the first arm in this file), and the mock Bot API hands back the
#      same message_id every time — so a genuine SECOND delivery collapsed into the
#      first and the count never moved. A deduped view cannot count deliveries.
# Measured 2026-07-31 by deleting the `return` that closes cmd_task_need's
# `if [[ "$tier" == "0" ]]` auto-clear block (named by target, not by line: a cited
# line number rots the moment anything above it moves, which is how olivia's :5437
# ended up pointing at unrelated code by the time this was written). Deleting it
# takes task_need_notify calls 1 -> 2 and the RAW log 1 -> 2, while the deduped view
# stays 1 either way. So the raw undeduped log below is the differential observable,
# and the tier-0 return is confirmed load-bearing — deleting it puts a real second
# button in the chat.
ident=$(seed_gate "DIVE-2410 file-time arm: tier0")
if [[ -z "$ident" ]]; then chk "file-time/tier-0: seeded a gate" "yes" "no"; else
  reset_edits
  ( cmd_task_need "$ident" --type=decision --ask="t0 proceed?" \
      --options="A|B" --recommend=A --tier=0 ) >/dev/null 2>&1
  chk "file-time/tier-0: the OUTGOING gate's button was retired by the re-file retire" \
      "tok-marketing|1234567890|15491" "$(edits)"
  chk "file-time/tier-0: and the auto-cleared gate delivered NO button of its own" "1" \
      "$(grep -c 'gate-delivery result=ok' "$LOG")"
  chk "file-time/tier-0: it really did auto-clear (the arm graded a settle, not a refusal)" \
      "auto:t0" \
      "$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident=$(sqlq "$ident");")"
fi

# ---------------------------------------- file-time settle site: precedent ---
# The OSS-21 tier-1 precedent auto-clear is the OTHER file-time settle site. It is
# pref-gated OFF by default, and an earlier draft of this file leaned on that and left
# the path ungraded. A default is a posture, not a proof: the pref is fleet-settable,
# so "cannot fire today" is not "cannot deliver an unretired button". Graded properly.
#
# Enumerated by target, not by line: the two writes of need_answered_by inside
# cmd_task_need are 'auto:t0' and 'auto:precedent' — those are the only file-time
# settle sites, so with both graded there is no seventh settle path.
chk "file-time/precedent: OSS-21 auto-clear is inert by default (the shipped posture)" \
    "off" "$(_p=$(_task_pref_get precedent_autoclear); printf '%s' "${_p:-off}")"
# LIVENESS for the arm above. Its `${_p:-off}` fallback is exactly the shape that
# passes when the reader is broken: a _task_pref_get that errored, was renamed, or
# returned nothing collapses to "off" and the inertness arm stays green while
# grading nothing. So prove the reader can report the OTHER value before trusting it
# to report this one — without this arm, the fence claim above is unfalsifiable.
_task_pref_set precedent_autoclear on >/dev/null 2>&1
chk "file-time/precedent: liveness — the pref reader really reads (not a stuck default)" \
    "on" "$(_p=$(_task_pref_get precedent_autoclear); printf '%s' "${_p:-off}")"

# Now turn the fence OFF and actually drive the path. Two prior gates on an IDENTICAL
# ask_shape, each answered by a nonce-verified human with the SAME answer, is what
# qualifies a precedent; the harness files them for real and then stamps the human
# provenance the human rail would have written. ask_shape is copied off a real filed
# gate rather than recomputed, so the arm cannot drift from the CLI's own hashing.
_pshape=""
for _i in 1 2; do
  _pid=$(seed_gate "DIVE-2410 precedent seed $_i")
  [[ -n "$_pid" ]] || continue
  db "UPDATE tasks SET need_answer='A', need_answered_at=datetime('now','-1 day'),
        need_answered_by='human:1234567890', human_nonce_hash='deadbeef',
        precedent_kind=NULL, tier=1 WHERE ident=$(sqlq "$_pid");"
  _pshape=$(db "SELECT COALESCE(ask_shape,'') FROM tasks WHERE ident=$(sqlq "$_pid");")
done
_tid=$( ( JSON_MODE=1 cmd_task_add "DIVE-2410 precedent target" ) 2>/dev/null | jq -r '.data.id // empty')
_tident=$(db "SELECT ident FROM tasks WHERE id=${_tid};" 2>/dev/null)
if [[ -z "$_pshape" || -z "$_tident" ]]; then
  chk "file-time/precedent: seeded two nonce-verified precedents" "yes" "no"
else
  : >"$LOG"          # fresh target, never gated before: ANY delivery here is its own
  reset_edits
  ( cmd_task_need "$_tident" --type=decision --ask="proceed?" \
      --options="A|B" --recommend=A --tier=1 ) >/dev/null 2>&1
  chk "file-time/precedent: it really did auto-clear (the arm graded a settle, not a refusal)" \
      "auto:precedent" \
      "$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident=$(sqlq "$_tident");")"
  chk "file-time/precedent: and the auto-cleared gate delivered NO button of its own" "0" \
      "$(grep -c 'gate-delivery result=ok' "$LOG")"
fi
_task_pref_set precedent_autoclear off >/dev/null 2>&1

# ------------------------------------------------- blind-log observability ---
# The delivery log is the ONLY record of which messages a gate put in a chat, so an
# unreadable one makes retirement a total silent no-op. Absence and denial must not
# share an answer: a MISSING log is silent (nothing was ever delivered), an
# EXISTING-but-unreadable one warns.
reset_edits
out=$(FIVEDIVE_GATE_NOTIFY_LOG="$TMP/never-written.log" _task_gate_retire_buttons DIVE-A x 2>&1)
chk "a MISSING delivery log is silent (nothing was delivered — not a fault)" "0" \
    "$(grep -c 'cannot read the gate-delivery log' <<<"$out")"

# chmod is inert against root, so this arm cannot be arranged as uid 0. Skip it
# LOUDLY rather than let it pass vacuously — a silent skip reads as coverage.
BLIND="$TMP/blind.log"; printf 'x\n' >"$BLIND"; chmod 000 "$BLIND"
if [[ "$(id -u)" == "0" ]] || [[ -r "$BLIND" ]]; then
  printf 'SKIP an unreadable delivery log warns — cannot make a file unreadable as uid %s\n' "$(id -u)"
else
  _TASK_GATE_RETIRE_BLIND=""
  out=$(FIVEDIVE_GATE_NOTIFY_LOG="$BLIND" _task_gate_retire_buttons DIVE-A x 2>&1)
  chk "an EXISTING but unreadable delivery log warns (the no-op is observable)" "1" \
      "$(grep -c 'cannot read the gate-delivery log' <<<"$out")"
fi

# --- DIVE-2712: /inbox sends ONE MESSAGE PER GATE, first pings, rest silent -----
# The defect: every gate shared ONE message with one merged keyboard, so answering
# any gate retired the keyboard for ALL of them (retire edits the message that
# delivered the gate, and that message was everyone's). Graded on the SHAPE OF THE
# SENDS, not by reading the code — the send stub records one line per call.
SENDS="$TMP/sends.log"; : >"$SENDS"
_mirror_send() {
  printf 'send silent=%s markup=%s\n' \
    "$([[ -n "${FIVEDIVE_NOTIFY_SILENT:-}" && "${FIVEDIVE_NOTIFY_SILENT}" != "0" ]] && echo yes || echo no)" \
    "$([[ -n "${5:-}" ]] && echo yes || echo no)" >>"$SENDS"
  printf '%s' '{"ok":true,"result":{"message_id":15491}}'
}
seed_gate() { # <id> <ident> <type>
  db "INSERT INTO tasks (id,ident,title,status,priority,assignee,need_type,tier,ask,recommend,need_options,created_at)
      VALUES ($1,'$2','t','blocked','high','main','$3',2,'ask?','A','A|B',datetime('now'));" 2>/dev/null
}
db "DELETE FROM tasks;" 2>/dev/null
seed_gate 9001 DIVE-9001 decision
seed_gate 9002 DIVE-9002 approval
seed_gate 9003 DIVE-9003 decision
# Subshell: cmd_task_inbox ends in ok/fail, which exit — `|| true` cannot catch an
# exit in the current shell, and the harness must survive either outcome.
( cmd_task_inbox --send ) >/dev/null 2>&1 || true
chk "3 open gates produce 3 SEPARATE messages, not one digest" "3" "$(grep -c '^send ' "$SENDS" 2>/dev/null || echo 0)"
chk "the FIRST gate message pings the human" "silent=no" "$(head -1 "$SENDS" 2>/dev/null | grep -o 'silent=[a-z]*')"
chk "every message after the first is SILENT (one buzz, not N)" "2" "$(tail -n +2 "$SENDS" 2>/dev/null | grep -c 'silent=yes')"
chk "each gate carries its OWN keyboard" "3" "$(grep -c 'markup=yes' "$SENDS" 2>/dev/null || echo 0)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
