#!/usr/bin/env bash
# DIVE-7164 — two gaps from the Dropshipping trial's clean rerun (DIVE-6902), on a
# self-hosted box with no chat channel.
#
#   Y  ONE OWNER YES. The owner said yes on the row's gate and the browser then
#      stopped for its own approval, which only a shell user could give. A gate
#      filed with `task need --type=approval --browser-ask=<id>` is now that
#      approval: the owner's own yes runs `browser approve <id> --human-proof=…`
#      once and wakes the seat; a no declines it; an agent's or a lead's answer,
#      or a cited chat, approves nothing; a non-root answer settles nothing and
#      says the ask is still open.
#   M  THE REPLY. `agent send owner <text>` reaches the owner: the app chat on a
#      linked box, else the owner's inbox here, printed once at their next login
#      and by `task inbox --messages`. A message the owner sends says how to answer.
#
# Real cmd_task_need / cmd_task_answer against a temp tasks DB; the browser CLI,
# the app's API and passwd are seams. No root, no network.
#
# Run: bash tests/owner_one_yes_and_reply_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
exec 8>&2
SUMMARY_PRINTED=0
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "${SUMMARY_PRINTED:-0}" == 1 ]] || printf "ABORTED - owner_one_yes_and_reply_unit exited early (rc=%s) before its summary\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/owner-one-yes.XXXXXX)"

STATE_DIR="$TMP"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh constitution_kernel.sh \
         cmd_dashboard_relay.sh cmd_owner_ask.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"   # absent = not linked to the app
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"; touch "$GATE_PROOF_ENFORCE"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
audit_log() { :; }
task_need_notify() { return 0; }
_task_human_send_allowed() { return 0; }
_task_answer_ping_detached() { return 0; }

AGENT_UID=987654
AGENT_CG='/system.slice/system-5dive.slice/agent-fixture.service'
_gate_passwd_stream() {
  printf 'agent-fixture:x:%s:%s::/nonexistent:/bin/false\n' "$AGENT_UID" "$AGENT_UID"
  printf '%s\n' "$(</etc/passwd)"
}
getent() {
  if [[ "${1:-}" == passwd && "${2:-}" == "$AGENT_UID" ]]; then
    printf 'agent-fixture:x:%s:%s::/home/agent-fixture:/bin/bash\n' "$AGENT_UID" "$AGENT_UID"; return 0
  fi
  command getent "$@"
}
_gate_is_root() { return 0; }
as_agent() {   # agent-fixture, through its sudo grant
  export SUDO_UID="$AGENT_UID" SUDO_USER=agent-fixture; _gate_caller_uid() { printf '%s' "$AGENT_UID"; }
  _gate_caller_cgroup() { printf '%s' "$AGENT_CG"; }
}
as_root_login() {   # the owner, in root's login shell
  export SUDO_UID=0; unset SUDO_USER; _gate_caller_uid() { printf '0'; }
  _gate_caller_cgroup() { printf '%s' '/user.slice/user-0.slice/session-3.scope'; }
}

# The seat's approvals directory, where 5dive-browser writes an ask.
ME_UID=$(id -u) ME_GID=$(id -g)
: > "$TMP/passwd"
for u in agent-fixture agent-other; do
  mkdir -p "$TMP/home/$u/.5dive/browser-approvals"
  printf '%s:x:%s:%s::%s/home/%s:/bin/bash\n' "$u" "$ME_UID" "$ME_GID" "$TMP" "$u" >> "$TMP/passwd"
done
_owner_ask_passwd() { if (( $# )); then grep "^$1:" "$TMP/passwd"; else cat "$TMP/passwd"; fi; }
_owner_ask_is_root() { return 0; }
_owner_ask_cat_as() { cat -- "$2"; }
# The CLI the settle runs: records the argv, and answers as 5dive-browser would.
RUNLOG="$TMP/run.log"; : > "$RUNLOG"
_owner_ask_run() { shift; printf '%s\n' "$*" >> "$RUNLOG"; return 0; }
mkreq() { # <seat> <hex> <class> -> the ask id
  local d="$TMP/home/$1/.5dive/browser-approvals"
  jq -n --arg id "$1-$2" --arg s "$1" --arg c "$3" --argjson at "$(date +%s)" \
    '{id:$id, seat:$s, site:"strabella.example", hash:"abc", steps:[{op:"click"}], class:$c, label:"Pay now",
      step:"3", asked_at:$at, payload:{payee:"strabella.example", amount:"USD 60.64"}}' > "$d/$1-$2.json"
  printf '%s' "$1-$2"
}
reqf() { printf '%s/home/%s/.5dive/browser-approvals/%s.json' "$TMP" "${1%-*}" "$1"; }
seed_task() { db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('$1','t','in_progress','fixture','fixture');"; }
idof()      { db "SELECT id FROM tasks WHERE ident='$1';"; }
answered()  { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
ASK='Pay 60.64 USD on the supplier checkout for the test order?'

# ── Y: one owner yes ───────────────────────────────────────────────────────
as_agent
seed_task DIVE-2
A2=$(mkreq agent-fixture 0123456789ab pay)
out=$(cmd_task_need DIVE-2 --type=approval --browser-ask="$A2" --ask="$ASK" --from=fixture 2>&1); rc=$?
row=$(db "SELECT COALESCE(tier,'')||' '||COALESCE(needs_capability,'') FROM tasks WHERE ident='DIVE-2';")
[[ $rc -eq 0 && "$row" == "2 spend_authority" && "$(answered DIVE-2)" == open ]] \
  && ok_t "Y1 a pay ask on a gate makes it a person's gate (tier 2, spend_authority)" \
  || bad_t "Y1 pay ask gate" "rc=$rc row=$row out=$out"
B2="$TMP/owner-ask-gates/$(idof DIVE-2).json"
nh=$(jq -r '.nonce_hash // ""' "$(reqf "$A2")"); nonce=$(jq -r '.nonce // ""' "$B2" 2>/dev/null)
[[ "$nh" =~ ^[0-9a-f]{64}$ && "$(_human_nonce_sha "$nonce")" == "$nh" && "$(stat -c %a "$B2")" == 600 && "$out" == *"is on this gate"* ]] \
  && ok_t "Y2 the request carries the proof's hash; the proof is kept root-only beside the row" \
  || bad_t "Y2 proof bound" "nh=$nh mode=$(stat -c %a "$B2" 2>&1) out=$out"

: > "$RUNLOG"
out=$( (cmd_task_answer DIVE-2 --value=approve --human --from=fixture) 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-2)" == open && ! -s "$RUNLOG" ]] \
  && ok_t "Y3 the seat answering its own gate is refused, and nothing is approved" \
  || bad_t "Y3 seat cannot approve" "rc=$rc state=$(answered DIVE-2) run=$(cat "$RUNLOG")"

as_root_login
out=$( (cmd_task_answer DIVE-2 --value="yes, fill it and pay" --human) 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-2)" == closed ]] \
  && ok_t "Y4 the owner's yes from their login shell clears the gate" || bad_t "Y4 owner clears" "rc=$rc out=$out"
[[ "$(grep -c '^browser approve' "$RUNLOG")" == 1 && "$(grep '^browser approve' "$RUNLOG")" == "browser approve $A2 --human-proof=$nonce" ]] \
  && ok_t "Y5 ...and that one yes approves the browser ask, with the owner's proof" \
  || bad_t "Y5 browser approve from the gate" "run=$(cat "$RUNLOG")"
grep -q "^agent send fixture --message=.*--approved=$A2" "$RUNLOG" && [[ ! -e "$B2" ]] \
  && ok_t "Y6 the seat is told to re-run with --approved=<id>, and the proof is spent" \
  || bad_t "Y6 wake + spent" "run=$(cat "$RUNLOG") bind=$(ls "$TMP/owner-ask-gates" 2>&1)"

as_agent; seed_task DIVE-3
A3=$(mkreq agent-fixture 1111111111aa pay)
cmd_task_need DIVE-3 --type=approval --browser-ask="$A3" --ask="$ASK" --from=fixture >/dev/null 2>&1
as_root_login; : > "$RUNLOG"
cmd_task_answer DIVE-3 --value=no --human >/dev/null 2>&1
[[ "$(grep '^browser approve' "$RUNLOG")" == "browser approve $A3 --human-proof="*" --deny" ]] \
  && ok_t "Y7 the owner's no declines the browser ask" || bad_t "Y7 no -> deny" "run=$(cat "$RUNLOG")"

# Answers that are a person's in name only, set on the row as task answer stores them.
settle_as() { # <ident> <answered_by> <evidence> <value>
  local id; id=$(idof "$1")
  db "UPDATE tasks SET need_answered_by='$2', human_evidence='$3' WHERE id=$id;"
  : > "$RUNLOG"; _owner_ask_gate_settle "$id" "$1" "$4" 2>"$TMP/err"
}
bindrow() { # <ident> <hex> — a fresh gate with a bound ask
  as_agent; seed_task "$1"
  local a; a=$(mkreq agent-fixture "$2" pay)
  cmd_task_need "$1" --type=approval --browser-ask="$a" --ask="$ASK" --from=fixture >/dev/null 2>&1
  as_root_login
}
bindrow DIVE-4 2222222222bb
settle_as DIVE-4 lead:clip lead approve
[[ ! -s "$RUNLOG" && "$(cat "$TMP/err")" == *"NOT approved"* ]] \
  && ok_t "Y8 a lead's clear approves no browser step, and says so" || bad_t "Y8 lead" "run=$(cat "$RUNLOG") err=$(cat "$TMP/err")"
settle_as DIVE-4 human:lodar channel-session approve
[[ ! -s "$RUNLOG" ]] && ok_t "Y9 an agent citing the owner's chat approves nothing either" || bad_t "Y9 cited chat" "run=$(cat "$RUNLOG")"
settle_as DIVE-4 human:lodar sudo-uid "maybe later"
[[ ! -s "$RUNLOG" && "$(cat "$TMP/err")" == *"neither a yes nor a no"* ]] \
  && ok_t "Y10 an answer that is neither yes nor no leaves the ask as it was" || bad_t "Y10 unclear" "run=$(cat "$RUNLOG")"
settle_as DIVE-4 human:lodar nonce+channel-session ok
[[ "$(grep -c '^browser approve' "$RUNLOG")" == 1 ]] \
  && ok_t "Y11 the owner's tap (nonce) approves" || bad_t "Y11 tap" "run=$(cat "$RUNLOG")"

bindrow DIVE-8 6666666666ff
( _owner_ask_is_root() { return 1; }; settle_as DIVE-8 human:lodar sudo-uid approve )
[[ ! -s "$RUNLOG" && "$(cat "$TMP/err")" == *"browser ask is still open"* ]] \
  && ok_t "Y17 a non-root answer settles no browser ask, and says the ask is still open" || bad_t "Y17 non-root" "run=$(cat "$RUNLOG") err=$(cat "$TMP/err")"

# MUTANT: the evidence check removed — Y9's cited chat then approves a payment.
bindrow DIVE-5 3333333333cc
( eval "$(declare -f _owner_ask_gate_settle | sed 's/|| ! "+${ev}+" =~ [^]]*\]\]/]]/')"
  settle_as DIVE-5 human:lodar channel-session approve; grep -c '^browser approve' "$RUNLOG" ) > "$TMP/mut" 2>/dev/null
[[ "$(tail -1 "$TMP/mut")" == 1 ]] \
  && ok_t "Y12 MUTANT: with the evidence check gone a cited chat approves — Y9 is what catches it" \
  || bad_t "Y12 mutant did not bite" "$(cat "$TMP/mut")"

as_agent; seed_task DIVE-6
AO=$(mkreq agent-other 4444444444dd pay)
out=$( (cmd_task_need DIVE-6 --type=approval --browser-ask="$AO" --ask="$ASK" --from=fixture) 2>&1); rc=$?
[[ $rc -ne 0 && "$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='DIVE-6';")" == "" && "$out" == *"cannot put agent-other"* ]] \
  && ok_t "Y13 a seat cannot put another seat's browser ask on its gate (nothing is filed)" \
  || bad_t "Y13 foreign ask" "rc=$rc out=$out"
out=$( (cmd_task_need DIVE-6 --type=decision --options="a|b" --browser-ask="$A2" --ask="$ASK" --from=fixture) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"approval gate"* ]] && ok_t "Y14 --browser-ask goes on an approval gate only" || bad_t "Y14 decision" "rc=$rc out=$out"
out=$( (cmd_task_need DIVE-6 --type=approval --browser-ask=agent-fixture-ffffffffffff --ask="$ASK" --from=fixture) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"no pending browser ask"* ]] && ok_t "Y15 an ask that is not waiting is refused before the gate is written" || bad_t "Y15 missing ask" "rc=$rc out=$out"
A7=$(mkreq agent-fixture 5555555555ee send); seed_task DIVE-7
cmd_task_need DIVE-7 --type=approval --browser-ask="$A7" --ask="Send the order confirmation to the test buyer?" --from=fixture >/dev/null 2>&1
[[ "$(db "SELECT COALESCE(needs_capability,'') FROM tasks WHERE ident='DIVE-7';")" == human_tap ]] \
  && ok_t "Y16 a non-pay ask declares human_tap" || bad_t "Y16 human_tap" "$(db "SELECT needs_capability FROM tasks WHERE ident='DIVE-7';")"

# ── M: the reply reaches the owner ─────────────────────────────────────────
as_root_login
out=$(_owner_note_send clip $'Store renamed.\e]0;pwned\a Three drafts are up.' 2>&1)
[[ "$out" == *"waits in their inbox"* && "$(wc -l < "$TMP/owner-inbox.jsonl")" == 1 ]] \
  && ok_t "M1 no chat for the owner: the reply waits in their inbox on this box" || bad_t "M1 inbox" "out=$out"
out=$(cmd_task_inbox --login 2>&1)
[[ "$out" == *"1 new message from your agents"* && "$out" == *"clip ("*"Store renamed."*"Three drafts are up."* && "$out" == *"agent send <name> --from=owner"* ]] \
  && ok_t "M2 the owner's next login shows it, who sent it, and how to answer" || bad_t "M2 login" "out=$out"
[[ "$out" != *$'\e'* && "$out" != *$'\a'* ]] && ok_t "M3 an agent's control bytes never reach the owner's terminal" || bad_t "M3 control bytes" "$(printf '%q' "$out")"
out=$(cmd_task_inbox --login 2>&1)
[[ "$out" != *"new message"* ]] && ok_t "M4 shown once: the next login is quiet" || bad_t "M4 once" "out=$out"
out=$(cmd_task_inbox --messages 2>&1)
[[ "$out" == *"Store renamed."* ]] && ok_t "M5 task inbox --messages shows it again on demand" || bad_t "M5 --messages" "out=$out"

# A box linked to the app: the reply is an agent message in the app chat.
printf 'CONNECTORD_TOKEN=tok-fixture\n' > "$FIVEDIVE_CONNECTORD_ENV"
printf 'API=https://api.example.test\n' > "$FIVEDIVE_CHAT_ONLY_MARK"
APP_CODE=201
_dash_relay_curl() {   # <method> <url> <token> <out> <maxt> <curl args…>
  printf '%s %s\n' "$1" "$2" >> "$TMP/app.log"; printf '%s' "$3" > "$TMP/app.tok"
  local a; for a in "$@"; do [[ "$a" == @* ]] && cp -- "${a#@}" "$TMP/app.body"; done; printf '%s' "$APP_CODE"; }
: > "$TMP/app.log"; n0=$(wc -l < "$TMP/owner-inbox.jsonl")
out=$(_owner_note_send clip "Currency is USD now." 2>&1)
[[ "$out" == *"app chat"* && "$(cat "$TMP/app.log")" == "POST https://api.example.test/server/messages/event" \
   && "$(jq -r '.agent+"|"+.body' "$TMP/app.body")" == "clip|Currency is USD now." && "$(cat "$TMP/app.tok")" == tok-fixture && "$(wc -l < "$TMP/owner-inbox.jsonl")" == "$n0" ]] \
  && ok_t "M6 linked to the app: the reply is clip's message in the app chat, not the box inbox" \
  || bad_t "M6 app" "out=$out log=$(cat "$TMP/app.log") body=$(cat "$TMP/app.body" 2>&1)"
APP_CODE=502
out=$(_owner_note_send clip "Second note." 2>&1)
[[ "$out" == *"waits in their inbox"* && "$(wc -l < "$TMP/owner-inbox.jsonl")" == $((n0 + 1)) ]] \
  && ok_t "M7 the app refusing it: the reply falls back to the inbox, never dropped" || bad_t "M7 fallback" "out=$out"
rm -f "$FIVEDIVE_CONNECTORD_ENV" "$FIVEDIVE_CHAT_ONLY_MARK"

# The send verbs: `owner` is the owner unless a seat is really called that.
require_root() { :; }
actor_routing_agent() { printf 'clip'; }
n0=$(wc -l < "$TMP/owner-inbox.jsonl")
out=$( (cmd_deliver owner "From the scoped grant.") 2>&1); rc=$?
[[ $rc -eq 0 && "$(tail -1 "$TMP/owner-inbox.jsonl" | jq -r '.from+"|"+.text')" == "clip|From the scoped grant." ]] \
  && ok_t "M8 a standard seat's send (agent _deliver owner) reaches the owner as itself" || bad_t "M8 _deliver" "rc=$rc out=$out"
printf '{"agents":{"owner":{}}}\n' > "$REGISTRY"
_owner_is_send_target owner && bad_t "M9 an agent named owner" "treated as the box owner" \
  || ok_t "M9 a seat really named 'owner' keeps its name"
rm -f "$REGISTRY"
grep -q '_owner_is_send_target "\$name"' "$SRC/cmd_agent_runtime.sh" \
  && grep -q 'To answer the owner: 5dive agent send owner' "$SRC/cmd_agent_runtime.sh" \
  && ok_t "M10 agent send routes owner, and a person's message says how to answer" || bad_t "M10 cmd_send wiring" ""

SUMMARY_PRINTED=1
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
