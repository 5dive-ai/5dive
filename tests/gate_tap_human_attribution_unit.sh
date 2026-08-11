#!/usr/bin/env bash
# DIVE-3128 isolated unit harness: a tier-2 gate answered by a BUTTON TAP must
# name the person who tapped, and must never name a roster AGENT as the human.
#
# THE DEFECT. `cmd_task_answer` built its provenance stamp as
# `human:$(task_actor …)` — the `human:` prefix pasted onto the identity of the
# PROCESS that ran the command. On the Telegram tap path that process is a bot,
# so a gate delivered through an agent's bot and tapped by a person landed as
# `need_answered_by='human:<agent name>'`. Nothing was forged: it is the honest
# output of asking the wrong question. But tier 2 exists for exactly one reason —
# to prove a human was in the loop — and `need_answered_by` is the one field
# whose whole job is to carry that proof, so a value that cannot distinguish
# "a human tapped, relayed through that agent's bot" from "that agent cleared its
# own human gate" is the control failing at its only task.
#
# THE REFERENCE CASE is the DIVE-3045 record: a stamp naming a roster agent as
# the human, alongside a `need_answered_uid` belonging to an AGENT account. That
# shape is modelled below with reserved fakes — a fixture registry whose agent is
# `relaybot` and Telegram id 1234567890 — per this repo's no-real-identifiers
# rule. The real names and ids from that incident are deliberately NOT copied in;
# what is reproduced is the SHAPE, which is what the guard keys on.
#
# WHAT IS PINNED:
#   T1  a tap carrying --tap-uid stamps THE TAPPER, not the relaying process
#   T2  the relay is recorded in its own column, not folded into the stamp
#   T3  the tap is written to the tap ledger (uid, message id, gate, verdict)
#   T4  an unnamed tapper degrades to `human:tg:<uid>` — never to the relay's name
#   T5  MUTATION-GRADED: a `human:` stamp naming a ROSTER AGENT is refused and
#       stored as `unattributed:<name>`, with an audit row saying why
#   T6  the refusal is not a blanket ban on the word: the same run, same registry,
#       a NON-roster name still stamps `human:` — so T5 cannot pass by refusing
#       everything
#   T7  the guard is MEASURED, not assumed: `actor_name_is_registered_agent`
#       separates "is an agent", "measured, is not" and "could not look"
#
# Isolation: source src/ libs, throwaway STATE_DIR and a FIXTURE registry — the
# live shared tasks.db and the box's real agents.json are NEVER touched.
# Run: bash tests/gate_tap_human_attribution_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-3128-unit.XXXXXX)"

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
# THE REGISTRY IS REDIRECTED, and this is load-bearing rather than tidy. header.sh
# computes REGISTRY at SOURCE time from the default STATE_DIR, so a harness that
# only moves STATE_DIR afterwards leaves the roster guard reading /var/lib/5dive
# — i.e. grading against whichever agents happen to exist on the box running the
# suite. Every arm below would then be host-dependent, and T6 in particular would
# pass or fail on an accident.
REGISTRY="$TMP/agents.json"
HUMANS_MAP="$TMP/humans.json"
GATE_TAP_LOG="$TMP/gate-taps.jsonl"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
touch "$GATE_PROOF_ENFORCE"   # tier-2 enforcement ON

# THE FIXTURE ROSTER. `relaybot` stands in for the agent whose bot relayed the
# DIVE-3045 tap. Reserved-fake name on purpose: the guard keys on "this name is
# under .agents", not on any particular name, so a fake exercises the same code.
cat >"$REGISTRY" <<'REG'
{"schemaVersion": 1, "agents": {"relaybot": {"isolation": "vm", "type": "claude"}}}
REG

# Reserved fakes only (repo convention): Telegram ids -> 1234567890.
TAP_UID="1234567890"
TAP_UID_UNNAMED="1234567891"
TAP_MSG="4242"

cat >"$HUMANS_MAP" <<REG
{"humans": {"$TAP_UID": "tapper"}}
REG

# No DM on gate filing. Capture audit rows to a file so the refusal arm can
# assert the forensic row exists, not merely that a string changed.
task_need_notify() { :; }
AUDIT_LOG_FILE="$TMP/audit.log"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }
# DIVE-2010 fence: gate rows route through `_task_store_audit_log`, which emits
# only on the PRODUCTION store. On a fixture DB the row is deliberately withheld,
# which would make the audit assertion structurally unsatisfiable. Open it for
# this fixture; the stub above stays the sink.
_task_human_send_allowed() { return 0; }

# Deterministic nonce so every arm can present the tap's real --human-proof.
KNOWN_NONCE="deadbeefdeadbeefdeadbeefdeadbeef"
_human_nonce_mint() { printf '%s' "$KNOWN_NONCE"; }

# The tap path's OWN shape: the immediate caller IS an agent (the bot), which is
# why the nonce is the evidence form and why the actor is the wrong thing to
# stamp. Pinned to 0 so no arm depends on which uid runs the suite.
FAKE_NONAGENT=0
_gate_sudo_uid_nonagent() { [[ "$FAKE_NONAGENT" == "1" ]]; }
_gate_caller_cgroup() {
  if [[ "$FAKE_NONAGENT" == "1" ]]; then printf '%s' '/system.slice/shelld.service'
  else printf '%s' '/system.slice/system-5dive.slice/5dive-agent@relaybot.service'; fi
}
# LIVENESS BOTH WAYS before anything leans on the switch (the sense-inversion trap
# tests/gate_tier2_nonce_evidence_unit.sh records).
FAKE_NONAGENT=1; _gate_human_principal \
  || { printf 'NOT OK - human-principal pin inert: FAKE_NONAGENT=1 did not read as human\n'; exit 1; }
FAKE_NONAGENT=0; _gate_human_principal \
  && { printf 'NOT OK - human-principal pin inert: FAKE_NONAGENT=0 read as human\n'; exit 1; }

# THE ACTOR THE OLD CODE WOULD HAVE STAMPED. A synthetic passwd row makes this
# harness name `relaybot` as the acting agent on ANY host, including a CI runner
# where no agent-* account exists — so the defect being graded is reproduced here
# rather than borrowed from the box.
_gate_passwd_stream() { printf 'agent-relaybot:x:424242:424242::/nonexistent:/bin/false\n'; }
_gate_caller_uid()    { printf '%s' 424242; }
_probe="$(_gate_uid_to_agent 424242)"
[[ "$_probe" == "relaybot" ]] \
  || { printf 'NOT OK - the identity resolver is not live: _gate_uid_to_agent returned %s (expected relaybot). Is lib/actor.sh sourced?\n' "'$_probe'"; exit 1; }
# And the derivation really does reach the answer path as `relaybot` — otherwise
# T5 would be grading a stamp nobody would ever have written.
_board="$(task_actor "")"
[[ "$_board" == "relaybot" ]] \
  || { printf 'NOT OK - actor derivation inert: task_actor returned %s (expected relaybot)\n' "'$_board'"; exit 1; }

seed()    { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','relaybot');"; }
t2gate()  {
  cmd_task_need "$1" --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 \
    --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
}
answered(){ db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
provby()  { db "SELECT COALESCE(need_answered_by,'')      FROM tasks WHERE ident='$1';"; }
relayof() { db "SELECT COALESCE(need_answered_relay,'')   FROM tasks WHERE ident='$1';"; }
tapuidof(){ db "SELECT COALESCE(need_answered_tap_uid,'') FROM tasks WHERE ident='$1';"; }

# --- T1: THE TAPPER IS STAMPED, not the relaying process. --------------------
# The old code produced `human:relaybot` here; `relaybot` is the actor pinned
# above, and it is also on the fixture roster, so under the fix it is refused
# twice over. What must land is the PERSON.
seed DIVE-301; t2gate DIVE-301
out=$(cmd_task_answer DIVE-301 --value=A --human --human-proof="$KNOWN_NONCE" \
        --tap-uid="$TAP_UID" --tap-username=tapperhandle --tap-msg="$TAP_MSG" \
        --relay-agent=relaybot 2>&1); rc=$?
[[ "$(answered DIVE-301)" == "closed" && $rc -eq 0 ]] \
  && ok_t "T1a a genuine tap still CLEARS the tier-2 gate (no regression on the real path)" \
  || bad_t "T1a tap clears" "rc=$rc state=$(answered DIVE-301) out=$out"
[[ "$(provby DIVE-301)" == "human:tapper" ]] \
  && ok_t "T1b the stamp names the TAPPING HUMAN (human:tapper), not the relay" \
  || bad_t "T1b tapper stamped" "need_answered_by='$(provby DIVE-301)' (expected human:tapper)"
[[ "$(provby DIVE-301)" == *relaybot* ]] \
  && bad_t "T1c relay name must not appear in the human stamp" "need_answered_by='$(provby DIVE-301)'" \
  || ok_t "T1c the relaying agent's name is ABSENT from need_answered_by"

# --- T2: the relay is recorded SEPARATELY, not conflated. --------------------
# The point of the ticket is not that the relay is unimportant — it is that it is
# a DIFFERENT FACT. If it were dropped entirely the record would lose the audit
# trail; if it were folded back in, the defect returns.
[[ "$(relayof DIVE-301)" == "relaybot" ]] \
  && ok_t "T2a the relaying agent is recorded in need_answered_relay" \
  || bad_t "T2a relay column" "need_answered_relay='$(relayof DIVE-301)' (expected relaybot)"
[[ "$(tapuidof DIVE-301)" == "$TAP_UID" ]] \
  && ok_t "T2b the tapping telegram uid is recorded in need_answered_tap_uid" \
  || bad_t "T2b tap uid column" "need_answered_tap_uid='$(tapuidof DIVE-301)'"

# --- T3: the tap is AUDITABLE FROM THE RECORD ALONE. -------------------------
# Before this the button tap was the least-logged path in the system for the most
# rigorously evidenced control: reconstructing it meant reading someone's shell
# history. Assert the fields a reader would need, individually — a bare
# "the file is non-empty" would green on a line containing none of them.
if [[ -s "$GATE_TAP_LOG" ]]; then
  _rec=$(grep -F '"gate":"DIVE-301"' "$GATE_TAP_LOG" | tail -1)
  _miss=""
  for _pair in "\"tap_uid\":\"$TAP_UID\"" "\"tap_message_id\":\"$TAP_MSG\"" \
               "\"relay_agent\":\"relaybot\"" "\"stamped_as\":\"human:tapper\"" \
               "\"resolved_human\":\"tapper\"" "\"resolved_via\":\"resolved\"" \
               "\"human_proof\":\"presented\"" "\"verdict\":\"stored\""; do
    [[ "$_rec" == *"$_pair"* ]] || _miss+=" $_pair"
  done
  [[ -z "$_miss" ]] \
    && ok_t "T3 the tap ledger records uid, message id, gate, relay, stamp and verdict" \
    || bad_t "T3 tap ledger fields" "missing:$_miss  line=$_rec"
else
  bad_t "T3 tap ledger written" "$GATE_TAP_LOG is empty or absent"
fi

# --- T4: an UNNAMED tapper degrades to tg:<uid>, never to the relay. ---------
# The failure mode this ticket closes is naming the WRONG principal, not naming
# nobody. `human:tg:<id>` is an honest partial answer a reader can chase; falling
# back to the relay's name is the original bug wearing a fallback's clothes.
seed DIVE-302; t2gate DIVE-302
cmd_task_answer DIVE-302 --value=A --human --human-proof="$KNOWN_NONCE" \
  --tap-uid="$TAP_UID_UNNAMED" --relay-agent=relaybot >/dev/null 2>&1
[[ "$(provby DIVE-302)" == "human:tg:${TAP_UID_UNNAMED}" ]] \
  && ok_t "T4a an unmapped tapper stamps human:tg:<uid> (honest partial identity)" \
  || bad_t "T4a unnamed tapper" "need_answered_by='$(provby DIVE-302)' (expected human:tg:${TAP_UID_UNNAMED})"
[[ "$(relayof DIVE-302)" == "relaybot" ]] \
  && ok_t "T4b …and the relay is still recorded separately" \
  || bad_t "T4b relay on unnamed tap" "need_answered_relay='$(relayof DIVE-302)'"

# --- T5: MUTATION-GRADED. The DIVE-3045 SHAPE — a `human:` stamp naming a name
#     that is on the AGENT ROSTER — is REFUSED. -------------------------------
# This is the arm that reds if the guard is deleted. It answers WITHOUT a tap, so
# `$answered_by` is the derived actor `relaybot`, which the fixture registry lists
# as an agent. Delete `actor_human_name_ok` from the stamp block and the row goes
# back to reading `human:relaybot` — T5a fails on the value it now holds, T5b
# fails on the value it now lacks, and T5c fails because the forensic row is gone.
# Three independent failures, so a partial revert cannot leave this green.
: >"$AUDIT_LOG_FILE"
seed DIVE-303; t2gate DIVE-303
out=$(cmd_task_answer DIVE-303 --value=A --human --human-proof="$KNOWN_NONCE" 2>&1); rc=$?
_p303="$(provby DIVE-303)"
[[ "$_p303" != human:* ]] \
  && ok_t "T5a a stamp that would name a ROSTER AGENT as the human is REFUSED" \
  || bad_t "T5a roster-agent human stamp refused" "need_answered_by='$_p303' — the guard did not fire; a roster agent is recorded as the human"
[[ "$_p303" == "unattributed:relaybot" ]] \
  && ok_t "T5b …and is stored as unattributed:<name>, keeping what WAS measured" \
  || bad_t "T5b unattributed stamp" "need_answered_by='$_p303' (expected unattributed:relaybot)"
grep -q 'task answer human-attribution.*error.*reason=roster-agent' "$AUDIT_LOG_FILE" \
  && ok_t "T5c …and the refusal wrote a forensic audit row naming the reason" \
  || bad_t "T5c refusal audit row" "no human-attribution error row in $AUDIT_LOG_FILE"
# The answer itself must still LAND. Refusing the write would discard a decision a
# person may really have made and leave a tier-2 gate permanently unanswerable —
# what is refused is the CLAIM, not the answer.
[[ "$(answered DIVE-303)" == "closed" ]] \
  && ok_t "T5d the answer still lands — the CLAIM is refused, not the decision" \
  || bad_t "T5d answer lands" "gate is $(answered DIVE-303)"

# --- T6: NON-VACUITY. The guard is not "refuse every human stamp". -----------
# Same run, same fixture registry, a name that is NOT on it. Without this arm,
# T5 is satisfied by a mutation that simply never writes `human:` at all — which
# would destroy the control while turning every assertion above green.
seed DIVE-304; t2gate DIVE-304
cmd_task_answer DIVE-304 --value=A --human --human-proof="$KNOWN_NONCE" \
  --tap-uid="$TAP_UID" --relay-agent=relaybot >/dev/null 2>&1
[[ "$(provby DIVE-304)" == "human:tapper" ]] \
  && ok_t "T6 a NON-roster name still stamps human: (the guard discriminates, it does not blanket-refuse)" \
  || bad_t "T6 non-roster name still stamps human:" "need_answered_by='$(provby DIVE-304)'"

# --- T7: the roster predicate reports THREE states, not two. ----------------
# "could not look at the roster" must not read like "looked, it is not an agent"
# — fold them and an unreadable registry silently switches the guard off. Graded
# directly because no arm above can distinguish the two through cmd_task_answer.
actor_name_is_registered_agent relaybot; _rc_agent=$?
actor_name_is_registered_agent tapper;   _rc_human=$?
( REGISTRY="$TMP/does-not-exist.json"; actor_name_is_registered_agent relaybot ); _rc_blind=$?
[[ $_rc_agent -eq 0 ]] \
  && ok_t "T7a a roster name MEASURES as an agent (rc 0)" \
  || bad_t "T7a roster name" "rc=$_rc_agent (expected 0)"
[[ $_rc_human -eq 1 ]] \
  && ok_t "T7b a non-roster name MEASURES as not-an-agent (rc 1)" \
  || bad_t "T7b non-roster name" "rc=$_rc_human (expected 1)"
[[ $_rc_blind -eq 2 ]] \
  && ok_t "T7c an unreadable roster is UNMEASURED (rc 2), not silently 'not an agent'" \
  || bad_t "T7c unmeasurable roster" "rc=$_rc_blind (expected 2)"

echo "-----"
printf 'gate_tap_human_attribution_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
