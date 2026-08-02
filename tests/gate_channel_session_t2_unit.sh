#!/usr/bin/env bash
# DIVE-2412 (DIVE-2382 fix #4) isolated unit harness: a TIER-2 gate cleared by
# CHANNEL PROOF of the human's answer instead of a button tap.
#
# What is under test — `_gate_channel_session_ok` + its use in `task answer`:
#   * a tier-2 gate answered from the human's OWN verified DM, citing the
#     human's OWN message id, clears with NO tap and NO nonce, and the row
#     records WHICH form cleared it (human_evidence=channel-session),
#   * every way the citation can fail to attest REFUSES, each with its own
#     reason: no such message, wrong sender, hidden origin, stale, unrelated
#     text, unreadable token, un-allowlisted chat,
#   * the agent-relayed assertion — a chat id with no citation, i.e. "he told
#     me" — is still refused on tier 2, exactly as before DIVE-2412,
#   * the tier<2 chat-only form (DIVE-1305) is UNCHANGED and stays
#     distinguishable from this one on the row.
#
# The refusal arms assert MORE than a non-zero rc: they assert the guarded
# action never happened (the gate is still unanswered, no evidence recorded).
# An rc-only refusal arm stays green when the refusal's CONDITION is deleted.
# Their grading is tests/gate_channel_session_t2_mutation.sh, which deletes each
# condition in turn and requires the named arm below to go red.
#
# Isolation matches the sibling harnesses: source src/ libs, throwaway
# STATE_DIR, no network (the Bot API seam is stubbed), the live shared tasks.db
# is NEVER touched.  Run: bash tests/gate_channel_session_t2_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/gate-cs-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# The harness sources a COPY of src, and CS_SRC_DIR lets the mutation runner
# point it at a staged defect without touching the tree. CS_MUTATED is named in
# the banner, so a mutant log can never be mistaken for a clean run.
SRC="$TMP/src"
cp -r "${CS_SRC_DIR:-src}" "$SRC"
if [[ -n "${CS_MUTATED:-}" ]]; then
  printf 'NOTE: running against a MUTATED source (%s)\n' "$CS_MUTATED" >&2
fi

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }
# Post-sudo human context: the immediate caller is root, which passes the
# DIVE-394 agent-uid block.
#
# THE SUDO-UID SEAM IS PINNED, and iteration 2 is where that stopped being
# optional. `_gate_sudo_uid_nonagent` (src/lib/tasks_db.sh) resolves the caller's
# uid through the HOST's passwd database and answers "is this a human?" with
# "the account is not named agent-*". Leaving it unstubbed did not model an agent
# caller — it modelled WHOEVER RAN THE SUITE. On an agent-* box it returned false
# and the evform arms read `channel-session` / `nonce` exactly; on a CI runner
# (account `runner`) the very same code returns TRUE, `_su=1`, and every human
# form silently gains `+sudo-uid`. Measured, not reasoned: run 30542542143 failed
# exactly the two exact-string arms with `sudo-uid+channel-session` and
# `nonce+sudo-uid`, and `sudo -u claude` on this box reproduces both. That is
# tests/test_that_needs_the_host_is_not_a_test — the arm graded the runner.
#
# So the answer is a pin, not a looser assertion: an agent-* caller is the
# PREMISE of this whole feature (the tier-2 citation exists because the caller is
# an agent that cannot speak for the human), and CS13 below flips the pin to the
# non-agent case so the pin is differential rather than a way to keep quiet.
# 1 = false = an agent-* caller contributes no sudo-uid evidence.
_PIN_SUDO_HUMAN=1
_gate_sudo_uid_nonagent() { return "$_PIN_SUDO_HUMAN"; }
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
# ...and the UID SEAM, which is what the human-only block actually reads since
# DIVE-2330 iteration 2 replaced its `id -un` with _gate_caller_uid (EUID). Pinning
# only the NAME above stopped modelling the caller at that point: on an agent-*
# runner the guard fired on the RUNNER'S OWN uid and `fail` exited this sourced
# harness mid-suite — the shape DIVE-2330's own comment names. Pinned the way the
# sibling harnesses do (gate_channel_proof_unit, gate_nonce_unit). 0 is the
# root-side invocation the channel forms run under: `task inbox --send` and the
# plugin's clear path are root-side, as the DIVE-1305 help line says. It grants
# nothing on its own — the sudo-uid form is pinned off above, so the CS1 evform
# arm below still requires channel-session ALONE.
_PIN_UID=0
_gate_caller_uid() { printf '%s' "$_PIN_UID"; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
answered() { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
prov()     { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
evform()   { db "SELECT COALESCE(human_evidence,'') FROM tasks WHERE ident='$1';"; }

# A tier-2 hard gate, seeded the way the sibling harness does it (file at tier 1,
# then set the stored tier) so the T2 category heuristic and the lead-routing
# path are not what is under test here.
seed_t2_approval() {
  seed_task "$1"
  cmd_task_need "$1" --type=approval --ask="ship it?" --recommend=approved --tier=1 >/dev/null 2>&1
  db "UPDATE tasks SET tier='2' WHERE ident='$1';"
}

# ── the paired human's verified DM, and the Bot API seam ──────────────────────
HUMAN_CHAT=555            # reserved fake; see CLAUDE.md "never use a real identifier"
ACCESS="$TMP/access.json"
printf '{"allowFrom":["555"],"groups":{"-100200":{}}}' > "$ACCESS"
CS_TOKEN="TESTTOKEN"
_task_owner_channel() { TASK_CH_ACCESS="$ACCESS"; TASK_CH_TOKEN="$CS_TOKEN"; TASK_CH_TYPE="claude"; return 0; }

API_LOG="$TMP/api.log"; : > "$API_LOG"
CS_RESP=""
_gate_channel_api() { # <token> <method> [args...]
  local method="$2"; shift 2
  printf '%s %s\n' "$method" "$*" >> "$API_LOG"
  case "$method" in
    forwardMessage) printf '%s' "$CS_RESP" ;;
    deleteMessage)  printf '{"ok":true,"result":true}' ;;
    *)              printf '{"ok":false,"description":"unexpected method"}' ;;
  esac
}

# Telegram's forwardMessage reply for a message sent <age>s ago.
fwd() { # <origin_type> <sender_id> <age_sec> <text>
  local now; now=$(date +%s)
  jq -nc --arg t "$1" --argjson s "$2" --argjson d "$(( now - $3 ))" --arg x "$4" \
    '{ok:true, result:{message_id:9001, text:$x, forward_origin:{type:$t, sender_user:{id:$s}, date:$d}}}'
}

touch "$GATE_PROOF_ENFORCE"   # enforcement ON for every clear below

# ── CS1 ACCEPT: a tier-2 gate clears from the channel, with no tap ────────────
# The live illustration from the ticket: the human says what they chose in their
# own chat, and that message — not a re-entered button press — is the evidence.
seed_t2_approval DIVE-2412001
CS_RESP=$(fwd user "$HUMAN_CHAT" 30 "DIVE-2412001 yes, approved - go ahead and ship it")
out=$(cmd_task_answer DIVE-2412001 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15495 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-2412001)" == "closed" ]] \
  && ok_t "CS1 tier-2 gate CLEARS on an attested channel citation (no tap, no nonce)" \
  || bad_t "CS1 tier-2 gate CLEARS on an attested channel citation (no tap, no nonce)" "rc=$rc state=$(answered DIVE-2412001) out=$out"
[[ "$(prov DIVE-2412001)" == human:* ]] \
  && ok_t "CS1 provenance is human-sourced" || bad_t "CS1 provenance is human-sourced" "got '$(prov DIVE-2412001)'"
# Non-vacuity anchor: the clear must be attributable to THIS form alone. If
# nonce or sudo-uid had also been present, the arm above would pass without the
# new code doing anything.
[[ "$(evform DIVE-2412001)" == "channel-session" ]] \
  && ok_t "CS1 records the form as channel-session ONLY (no nonce, no sudo-uid)" \
  || bad_t "CS1 records the form as channel-session ONLY (no nonce, no sudo-uid)" "got '$(evform DIVE-2412001)'"
grep -q "deleteMessage .*message_id=9001" "$API_LOG" \
  && ok_t "CS1 the forwarded probe copy is deleted (a probe, not a post)" \
  || bad_t "CS1 the forwarded probe copy is deleted (a probe, not a post)" "$(cat "$API_LOG")"

# ── CS2 REFUSE: the agent-relayed assertion — a chat id and no citation ───────
# This is the boundary the ticket says not to soften: `from=`/a quoted claim is
# caller-supplied. Nothing here attests the human spoke, so tier 2 refuses.
seed_t2_approval DIVE-2412002
out=$(cmd_task_answer DIVE-2412002 --value=approved --channel-proof=$HUMAN_CHAT 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412002)" == "open" ]] \
  && ok_t "CS2 agent-relayed assertion (chat id, no citation) is REFUSED on tier 2" \
  || bad_t "CS2 agent-relayed assertion (chat id, no citation) is REFUSED on tier 2" "rc=$rc state=$(answered DIVE-2412002) out=$out"
[[ -z "$(evform DIVE-2412002)" ]] \
  && ok_t "CS2 no evidence form was recorded for the refused relay" \
  || bad_t "CS2 no evidence form was recorded for the refused relay" "got '$(evform DIVE-2412002)'"

# ── CS3 REFUSE: the cited message does not exist ──────────────────────────────
seed_t2_approval DIVE-2412003
CS_RESP='{"ok":false,"description":"Bad Request: message to forward not found"}'
out=$(cmd_task_answer DIVE-2412003 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=999999 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412003)" == "open" ]] \
  && ok_t "CS3 an invented message id is REFUSED (Telegram says no such message)" \
  || bad_t "CS3 an invented message id is REFUSED (Telegram says no such message)" "rc=$rc state=$(answered DIVE-2412003) out=$out"
# The rc arm above is NOT the grader for the existence check, and this is
# measured, not assumed: with `.ok == true` deleted the run still refused (the
# error payload carries no forward_origin, so the attribution check fired) and
# the rc stayed non-zero. Only the REASON arm below distinguishes which refusal
# happened, which is why it exists.
[[ "$out" == *"not a live message"* ]] \
  && ok_t "CS3 the refusal names the condition (message not live)" \
  || bad_t "CS3 the refusal names the condition (message not live)" "out=$out"

# ── CS4 REFUSE: the cited message was sent by someone else (or by the bot) ────
seed_t2_approval DIVE-2412004
CS_RESP=$(fwd user 1234567890 30 "DIVE-2412004 approved, go ahead")
out=$(cmd_task_answer DIVE-2412004 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15496 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412004)" == "open" ]] \
  && ok_t "CS4 a message from a DIFFERENT sender is REFUSED" \
  || bad_t "CS4 a message from a DIFFERENT sender is REFUSED" "rc=$rc state=$(answered DIVE-2412004) out=$out"
[[ "$out" == *"not by the paired human"* ]] \
  && ok_t "CS4 the refusal names the condition (sender mismatch)" \
  || bad_t "CS4 the refusal names the condition (sender mismatch)" "out=$out"

# ── CS5 REFUSE: forward origin hidden by the sender's privacy setting ─────────
# THE FIXTURE CARRIES A MATCHING sender_user.id ON PURPOSE, and the reason is the
# whole value of this arm. A real hidden_user origin has no sender_user at all,
# so the natural fixture is refused by the SENDER check one condition down and
# this arm would grade that instead — measured: deleting the origin-type check
# left the suite green (M3). Pairing a non-user origin with a present, matching
# sender id isolates the one condition named here: the code must require an
# explicitly attributed USER origin, not merely a sender field that happens to
# sit next to an origin type Telegram did not attribute to a person.
seed_t2_approval DIVE-2412005
CS_RESP='{"ok":true,"result":{"message_id":9001,"text":"DIVE-2412005 approved","forward_origin":{"type":"hidden_user","sender_user_name":"Someone","sender_user":{"id":555},"date":'"$(date +%s)"'}}}'
out=$(cmd_task_answer DIVE-2412005 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15497 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412005)" == "open" ]] \
  && ok_t "CS5 a HIDDEN forward origin is REFUSED (it attests nobody)" \
  || bad_t "CS5 a HIDDEN forward origin is REFUSED (it attests nobody)" "rc=$rc state=$(answered DIVE-2412005) out=$out"
[[ "$out" == *"not a named user"* ]] \
  && ok_t "CS5 the refusal names the condition (origin attributed to no user)" \
  || bad_t "CS5 the refusal names the condition (origin attributed to no user)" "out=$out"

# ── CS6 REFUSE: a stale message replayed onto a newer gate ───────────────────
seed_t2_approval DIVE-2412006
CS_RESP=$(fwd user "$HUMAN_CHAT" 7200 "DIVE-2412006 approved")
out=$(cmd_task_answer DIVE-2412006 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15498 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412006)" == "open" ]] \
  && ok_t "CS6 a STALE cited message is REFUSED (no replay onto a newer gate)" \
  || bad_t "CS6 a STALE cited message is REFUSED (no replay onto a newer gate)" "rc=$rc state=$(answered DIVE-2412006) out=$out"
[[ "$out" == *"limit 3600s"* ]] \
  && ok_t "CS6 the refusal names the condition (age vs limit)" \
  || bad_t "CS6 the refusal names the condition (age vs limit)" "out=$out"

# ── CS7 REFUSE: a real, fresh human message about something else ─────────────
seed_t2_approval DIVE-2412007
CS_RESP=$(fwd user "$HUMAN_CHAT" 30 "morning, what is on the board today")
out=$(cmd_task_answer DIVE-2412007 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15499 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412007)" == "open" ]] \
  && ok_t "CS7 a human message naming neither the answer nor the task is REFUSED" \
  || bad_t "CS7 a human message naming neither the answer nor the task is REFUSED" "rc=$rc state=$(answered DIVE-2412007) out=$out"
# ── CS7 REFUSE: it names the ANSWER but no gate — the shared-value replay ────
# olivia's iteration-1 note: a value is unique to NO gate. "approved"/"yes" fits
# every open approval, so accepting it made an ordinary old agreement in the
# human's chat sufficient for a gate they never saw. The ident is required.
seed_t2_approval DIVE-2412015
CS_RESP=$(fwd user "$HUMAN_CHAT" 30 "yes, approved, go ahead")
out=$(cmd_task_answer DIVE-2412015 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15504 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412015)" == "open" ]] \
  && ok_t "CS7 a message naming the ANSWER VALUE only is REFUSED (a value is unique to no gate)" \
  || bad_t "CS7 a message naming the ANSWER VALUE only is REFUSED (a value is unique to no gate)" "rc=$rc state=$(answered DIVE-2412015) out=$out"
[[ "$out" == *"does not name DIVE-2412015"* ]] \
  && ok_t "CS7 the refusal names the condition (ident missing)" \
  || bad_t "CS7 the refusal names the condition (ident missing)" "out=$out"

# ── CS7 REFUSE: it names the GATE but not the answer — `--value` is the agent's ─
# The ident alone attests only that the human spoke ABOUT this gate. The answer
# still arrives from the agent, so a human writing "DIVE-x, no" would otherwise
# clear it with --value=yes.
seed_t2_approval DIVE-2412008
CS_RESP=$(fwd user "$HUMAN_CHAT" 30 "go ahead on DIVE-2412008")
out=$(cmd_task_answer DIVE-2412008 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15500 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412008)" == "open" ]] \
  && ok_t "CS7 a message naming the IDENT only is REFUSED (it does not attest WHICH answer)" \
  || bad_t "CS7 a message naming the IDENT only is REFUSED (it does not attest WHICH answer)" "rc=$rc state=$(answered DIVE-2412008) out=$out"
[[ "$out" == *"not the answer"* ]] \
  && ok_t "CS7 the refusal names the condition (answer missing)" \
  || bad_t "CS7 the refusal names the condition (answer missing)" "out=$out"

# ...and BOTH together clear, which is what keeps the two arms above binding
# checks rather than a suite that refuses everything.
seed_t2_approval DIVE-2412016
CS_RESP=$(fwd user "$HUMAN_CHAT" 30 "on DIVE-2412016: approved, go ahead")
out=$(cmd_task_answer DIVE-2412016 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15505 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-2412016)" == "closed" ]] \
  && ok_t "CS7 a message naming BOTH the ident and the answer is accepted (binding, not text luck)" \
  || bad_t "CS7 a message naming BOTH the ident and the answer is accepted (binding, not text luck)" "rc=$rc state=$(answered DIVE-2412016) out=$out"

# ── CS8 REFUSE: the citation cannot be attested at all ───────────────────────
seed_t2_approval DIVE-2412009
CS_TOKEN=""; CS_RESP=$(fwd user "$HUMAN_CHAT" 30 "DIVE-2412009 approved")
out=$(cmd_task_answer DIVE-2412009 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15501 2>&1); rc=$?
CS_TOKEN="TESTTOKEN"
[[ $rc -ne 0 && "$(answered DIVE-2412009)" == "open" ]] \
  && ok_t "CS8 an UNATTESTABLE citation (no token) REFUSES rather than assumes" \
  || bad_t "CS8 an UNATTESTABLE citation (no token) REFUSES rather than assumes" "rc=$rc state=$(answered DIVE-2412009) out=$out"

# ── CS9 REFUSE: a chat that is not the paired human's DM ─────────────────────
seed_t2_approval DIVE-2412010
CS_RESP=$(fwd user 999 30 "DIVE-2412010 approved")
out=$(cmd_task_answer DIVE-2412010 --value=approved --channel-proof=999 --channel-msg=15502 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412010)" == "open" ]] \
  && ok_t "CS9 a citation in a NON-allowlisted chat is REFUSED" \
  || bad_t "CS9 a citation in a NON-allowlisted chat is REFUSED" "rc=$rc state=$(answered DIVE-2412010) out=$out"

# ── CS10 DISTINCTNESS: the three human forms stay tellable apart on the row ──
# Without this, "records which form" would pass on a column that says the same
# thing for a tap, a dashboard clear and a channel citation.
seed_task DIVE-2412011
cmd_task_need DIVE-2412011 --type=decision --ask="pick" --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
cmd_task_answer DIVE-2412011 --value=A --channel-proof=$HUMAN_CHAT >/dev/null 2>&1
[[ "$(answered DIVE-2412011)" == "closed" && "$(evform DIVE-2412011)" == "channel-chat" ]] \
  && ok_t "CS10 the tier<2 chat-only form (DIVE-1305) still clears and records channel-chat" \
  || bad_t "CS10 the tier<2 chat-only form (DIVE-1305) still clears and records channel-chat" "state=$(answered DIVE-2412011) form='$(evform DIVE-2412011)'"

seed_t2_approval DIVE-2412012
db "UPDATE tasks SET human_nonce_hash=$(sqlq "$(_human_nonce_sha NONCE123)") WHERE ident='DIVE-2412012';"
cmd_task_answer DIVE-2412012 --value=approved --human --human-proof=NONCE123 >/dev/null 2>&1
[[ "$(answered DIVE-2412012)" == "closed" && "$(evform DIVE-2412012)" == "nonce" ]] \
  && ok_t "CS10 a real TAP records nonce — distinct from channel-session" \
  || bad_t "CS10 a real TAP records nonce — distinct from channel-session" "state=$(answered DIVE-2412012) form='$(evform DIVE-2412012)'"

# ── CS11 the MOTIVATING SHAPE: a tier-2 DECISION gate, not an approval ───────
# Every arm above uses a tier-2 approval, and that is NOT the case the ticket was
# filed from. DIVE-2247 was a `decision` gate floored to tier 2, and decision
# takes a different route through cmd_task_answer: the approval/secret/manual
# evidence block is skipped entirely, so the tier-2 provenance floor is the only
# thing standing there. A suite that only ever files approvals would leave the
# path this feature exists for ungraded in both directions.
seed_task DIVE-2412013
cmd_task_need DIVE-2412013 --type=decision --ask="ship tonight or hold?" --options="ship-now|hold-schedule" --recommend="hold-schedule" --tier=1 >/dev/null 2>&1
db "UPDATE tasks SET tier='2' WHERE ident='DIVE-2412013';"
CS_RESP=$(fwd user "$HUMAN_CHAT" 45 "DIVE-2412013: went with hold-schedule, do that")
out=$(cmd_task_answer DIVE-2412013 --value=hold-schedule --channel-proof=$HUMAN_CHAT --channel-msg=15503 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-2412013)" == "closed" && "$(evform DIVE-2412013)" == "channel-session" ]] \
  && ok_t "CS11 a tier-2 DECISION gate (the DIVE-2247 shape) clears on the citation" \
  || bad_t "CS11 a tier-2 DECISION gate (the DIVE-2247 shape) clears on the citation" "rc=$rc state=$(answered DIVE-2412013) form='$(evform DIVE-2412013)' out=$out"

seed_task DIVE-2412014
cmd_task_need DIVE-2412014 --type=decision --ask="ship tonight or hold?" --options="ship-now|hold-schedule" --recommend="hold-schedule" --tier=1 >/dev/null 2>&1
db "UPDATE tasks SET tier='2' WHERE ident='DIVE-2412014';"
out=$(cmd_task_answer DIVE-2412014 --value=hold-schedule --channel-proof=$HUMAN_CHAT 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2412014)" == "open" ]] \
  && ok_t "CS11 the same tier-2 DECISION gate REFUSES the uncited relay" \
  || bad_t "CS11 the same tier-2 DECISION gate REFUSES the uncited relay" "rc=$rc state=$(answered DIVE-2412014) out=$out"

# ── CS12 RED TEAM: the CALLER cannot widen the freshness window ──────────────
# olivia's iteration-1 reject, reproduced as an arm. `task answer` is run BY the
# agent, so a window read from the caller's environment is a bypass with no
# forgery in it — measured on 8312851: a 400-day-old "approved" in the human's own
# chat refused at the default and CLEARED under
# GATE_CHANNEL_SESSION_MAX_AGE=999999999, recording human_evidence=channel-session
# for a gate no human had touched. `export` here is deliberate: it is exactly the
# environment `task answer` inherits from the agent that runs it.
#
# The REASON arm carries as much weight as the rc one (see
# feedback_refusal_graded_by_rc_alone_passes_the_wrong_refusal): if the refusal
# fired on some other condition, an rc-only arm would stay green while the clamp
# did nothing. "limit 3600s" is only printable if the ceiling — not the caller's
# 999999999 — is what bounded the comparison.
seed_t2_approval DIVE-2412017
CS_RESP=$(fwd user "$HUMAN_CHAT" 34560000 "DIVE-2412017 approved")   # 400 days old
export GATE_CHANNEL_SESSION_MAX_AGE=999999999
out=$(cmd_task_answer DIVE-2412017 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15506 2>&1); rc=$?
unset GATE_CHANNEL_SESSION_MAX_AGE
[[ $rc -ne 0 && "$(answered DIVE-2412017)" == "open" && -z "$(evform DIVE-2412017)" ]] \
  && ok_t "CS12 a caller-WIDENED window does NOT clear the gate (the bound is not the caller's to set)" \
  || bad_t "CS12 a caller-WIDENED window does NOT clear the gate (the bound is not the caller's to set)" "rc=$rc state=$(answered DIVE-2412017) form='$(evform DIVE-2412017)' out=$out"
[[ "$out" == *"limit 3600s"* ]] \
  && ok_t "CS12 the limit that fired is the hardcoded ceiling, not the caller's value" \
  || bad_t "CS12 the limit that fired is the hardcoded ceiling, not the caller's value" "out=$out"

# LIVENESS, so the clamp is not "ignore the env entirely": an env value BELOW the
# ceiling must still apply, because a deployment wanting a stricter window is the
# legitimate use of this knob. Graded against the anchor below — without it, code
# that refused every 300s citation would pass this arm.
seed_t2_approval DIVE-2412018
CS_RESP=$(fwd user "$HUMAN_CHAT" 300 "DIVE-2412018 approved")
export GATE_CHANNEL_SESSION_MAX_AGE=60
out=$(cmd_task_answer DIVE-2412018 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15507 2>&1); rc=$?
unset GATE_CHANNEL_SESSION_MAX_AGE
[[ $rc -ne 0 && "$(answered DIVE-2412018)" == "open" && "$out" == *"limit 60s"* ]] \
  && ok_t "CS12 a TIGHTER window from the env still applies (the knob can only narrow, it is not ignored)" \
  || bad_t "CS12 a TIGHTER window from the env still applies (the knob can only narrow, it is not ignored)" "rc=$rc state=$(answered DIVE-2412018) out=$out"

seed_t2_approval DIVE-2412019
CS_RESP=$(fwd user "$HUMAN_CHAT" 300 "DIVE-2412019 approved")
out=$(cmd_task_answer DIVE-2412019 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15508 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-2412019)" == "closed" ]] \
  && ok_t "CS12 ANCHOR: the same 300s-old citation DOES clear at the default window" \
  || bad_t "CS12 ANCHOR: the same 300s-old citation DOES clear at the default window" "rc=$rc state=$(answered DIVE-2412019) out=$out"

# A junk value must fall back to the ceiling rather than brick the rail or open it.
seed_t2_approval DIVE-2412020
CS_RESP=$(fwd user "$HUMAN_CHAT" 300 "DIVE-2412020 approved")
export GATE_CHANNEL_SESSION_MAX_AGE=not-a-number
out=$(cmd_task_answer DIVE-2412020 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15509 2>&1); rc=$?
unset GATE_CHANNEL_SESSION_MAX_AGE
[[ $rc -eq 0 && "$(answered DIVE-2412020)" == "closed" ]] \
  && ok_t "CS12 a NON-NUMERIC window falls back to the ceiling (neither wider nor bricked)" \
  || bad_t "CS12 a NON-NUMERIC window falls back to the ceiling (neither wider nor bricked)" "rc=$rc state=$(answered DIVE-2412020) out=$out"

# ── CS13 the sudo-uid pin is DIFFERENTIAL, not a way to keep the harness quiet ─
# Every exact-string evform arm above depends on `_PIN_SUDO_HUMAN=1`. A pin that
# is never flipped is indistinguishable from deleting the condition it pins, so
# flip it: model the non-agent caller (the CI runner, a dashboard exec) and
# require the column to GAIN the sudo-uid term and keep the citation term. This
# is the state run 30542542143 was actually in, so the arm doubles as the
# regression the iteration-2 CI red is named after: if the pin ever stops
# controlling this, one of the two directions goes red instead of the host
# deciding which.
seed_t2_approval DIVE-2412021
CS_RESP=$(fwd user "$HUMAN_CHAT" 30 "DIVE-2412021 approved")
_PIN_SUDO_HUMAN=0
out=$(cmd_task_answer DIVE-2412021 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15510 2>&1); rc=$?
_PIN_SUDO_HUMAN=1
[[ $rc -eq 0 && "$(evform DIVE-2412021)" == "sudo-uid+channel-session" ]] \
  && ok_t "CS13 a NON-agent caller records sudo-uid ALONGSIDE channel-session (the pin is live)" \
  || bad_t "CS13 a NON-agent caller records sudo-uid ALONGSIDE channel-session (the pin is live)" "rc=$rc form='$(evform DIVE-2412021)' out=$out"

# ...and the agent-caller direction re-asserted on a FRESH gate, so the pair is a
# genuine A/B on one seam rather than one measurement and one memory.
seed_t2_approval DIVE-2412022
CS_RESP=$(fwd user "$HUMAN_CHAT" 30 "DIVE-2412022 approved")
out=$(cmd_task_answer DIVE-2412022 --value=approved --channel-proof=$HUMAN_CHAT --channel-msg=15511 2>&1); rc=$?
[[ $rc -eq 0 && "$(evform DIVE-2412022)" == "channel-session" ]] \
  && ok_t "CS13 the SAME citation as an agent-* caller records channel-session ALONE" \
  || bad_t "CS13 the SAME citation as an agent-* caller records channel-session ALONE" "rc=$rc form='$(evform DIVE-2412022)' out=$out"

printf '\ngate_channel_session_t2_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
