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
#   T8  DIVE-7765: a NON-ROOT relay onto a root-only ledger lands through the
#       root relay, or says tap_logged:false — never a raw shell error after OK;
#       T8k-n hold the relay's REAL sudo argv to the rendered standard-seat grant
#       (sudoers matches argv exactly) and drive root's stdin sink end to end
#   T9  DIVE-7765: --channel-proof=telegram:<id> is accepted; junk and group ids
#       are refused with a FORMAT reason, an allowFrom miss with the allowFrom one
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
# DIVE-4346: ABORT marker -- see the note in gate_evidence_form_unit.sh. A refused
# fixture gate must produce a RED verdict, never a silent run with no summary.
exec 8>&2
SUMMARY_PRINTED=0
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "${SUMMARY_PRINTED:-0}" == 1 ]] || printf "ABORTED - gate_tap_human_attribution_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
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
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
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
  cmd_task_need "$1" --type=decision --ask="ship it?" --options="A|B" --ask-ok="fixture gate: the options ARE the input under test, not prose a person reads (DIVE-4462)" --recommend="A" --tier=2 \
    --needs=human_tap \
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

# --- T8: DIVE-7765 — a NON-ROOT relay onto a ledger it cannot write. ----------
# Box bug 729: root created gate-taps.jsonl 0600 root:root, every later agent-run
# tap printed `OK`, then a raw "Permission denied", and wrote nothing. Modelled
# without root: the ledger is made unwritable for this (non-root) uid and the
# answer runs with _gate_is_root pinned false. The privileged relay is the seam
# `_gate_tap_priv_append`; it is stubbed in two modes — granted (records what
# root was handed) and refused.
if [[ $EUID -eq 0 ]]; then
  printf 'note - T8 skipped: running as root, an unwritable ledger cannot be modelled (root writes through 0400)\n'
else
  _real_tap_log="$GATE_TAP_LOG"
  GATE_TAP_LOG="$TMP/ro/gate-taps.jsonl"; mkdir -p "$TMP/ro"
  printf '{"seed":1}\n' >"$GATE_TAP_LOG"; chmod 0400 "$GATE_TAP_LOG"; chmod 0500 "$TMP/ro"
  RELAYED="$TMP/relayed.jsonl"; : >"$RELAYED"
  PRIV_MODE=grant
  _gate_tap_priv_append() { [[ "$PRIV_MODE" == grant ]] || return 1; printf '%s\n' "$1" >>"$RELAYED"; }
  _gate_is_root() { return 1; }

  seed DIVE-305; t2gate DIVE-305
  out=$(cmd_task_answer DIVE-305 --value=A --human --human-proof="$KNOWN_NONCE" \
          --tap-uid="$TAP_UID" --tap-msg="$TAP_MSG" --relay-agent=relaybot 2>"$TMP/err305"); rc=$?
  [[ $rc -eq 0 && "$(answered DIVE-305)" == closed ]] \
    && ok_t "T8a a non-root relay onto a root-only ledger still answers the gate" \
    || bad_t "T8a answer lands" "rc=$rc state=$(answered DIVE-305) out=$out"
  grep -q 'Permission denied' "$TMP/err305" \
    && bad_t "T8b no raw shell error after OK" "stderr: $(cat "$TMP/err305")" \
    || ok_t "T8b no raw 'Permission denied' leaks after OK"
  _rel305=$(grep -F '"gate":"DIVE-305"' "$RELAYED")
  [[ "$_rel305" == *'"stamped_as":"human:tapper"'* ]] \
    && ok_t "T8c the record is handed to the root relay instead of being dropped" \
    || bad_t "T8c relayed record" "relayed=$(cat "$RELAYED")"
  [[ "$(jq -r '.data.tap_logged' <<<"$out" 2>/dev/null)" == "true" ]] \
    && ok_t "T8d the answer's JSON says tap_logged:true" \
    || bad_t "T8d tap_logged true" "out=$out"

  PRIV_MODE=refuse; : >"$AUDIT_LOG_FILE"
  seed DIVE-306; t2gate DIVE-306
  out=$(cmd_task_answer DIVE-306 --value=A --human --human-proof="$KNOWN_NONCE" \
          --tap-uid="$TAP_UID" --relay-agent=relaybot 2>"$TMP/err306"); rc=$?
  [[ $rc -eq 0 && "$(answered DIVE-306)" == closed ]] \
    && ok_t "T8e with no relay either, the human's answer still lands" \
    || bad_t "T8e answer lands" "rc=$rc out=$out"
  [[ "$(jq -r '.data.tap_logged' <<<"$out" 2>/dev/null)" == "false" && -n "$(jq -r '.data.tap_log_reason // empty' <<<"$out" 2>/dev/null)" ]] \
    && ok_t "T8f …and says so: tap_logged:false with a reason" \
    || bad_t "T8f tap_logged false + reason" "out=$out"
  grep -q 'Permission denied' "$TMP/err306" \
    && bad_t "T8g no raw shell error on the miss" "stderr: $(cat "$TMP/err306")" \
    || ok_t "T8g no raw 'Permission denied' on the miss either"
  grep -q 'task answer tap-ledger.*error.*task=DIVE-306' "$AUDIT_LOG_FILE" \
    && ok_t "T8h the miss is written to the audit log" \
    || bad_t "T8h miss audited" "audit=$(cat "$AUDIT_LOG_FILE")"

  # THE ROOT HALF. It appends only a line that matches an answer that landed.
  _gate_is_root() { return 0; }
  ROOTLOG="$TMP/root-taps.jsonl"; GATE_TAP_LOG="$ROOTLOG"
  _l305=$(grep -F '"gate":"DIVE-305"' "$RELAYED" | tail -1)
  SUDO_USER=agent-relaybot _gate_tap_append_root "$_l305"; _r1=$?
  _root305=$(grep -F '"gate":"DIVE-305"' "$ROOTLOG" 2>/dev/null)
  [[ $_r1 -eq 0 && "$_root305" == *'"appended_by":"agent-relaybot"'* ]] \
    && ok_t "T8i root appends a relayed record of a real answer, stamped with the relaying seat" \
    || bad_t "T8i root append" "rc=$_r1 log=$(cat "$ROOTLOG" 2>/dev/null)"
  _forged=$(jq -c '.stamped_as="human:someone-else"' <<<"$_l305")
  _before=$(wc -l <"$ROOTLOG" 2>/dev/null || echo 0)
  seed DIVE-307
  _unanswered=$(jq -c '.gate="DIVE-307"' <<<"$_l305")
  SUDO_USER=agent-relaybot _gate_tap_append_root "$_forged"; _r2=$?
  SUDO_USER=agent-relaybot _gate_tap_append_root "$_unanswered"; _r3=$?
  [[ $_r2 -ne 0 && $_r3 -ne 0 && "$(wc -l <"$ROOTLOG")" == "$_before" ]] \
    && ok_t "T8j root REFUSES a record whose stamp differs, or whose gate was never answered" \
    || bad_t "T8j root refuses forged lines" "r2=$_r2 r3=$_r3 lines $_before -> $(wc -l <"$ROOTLOG")"

  # THE CROSSING ITSELF (quinn, iteration 1). T8c-d stub the relay, so they could
  # not see that `sudo -n 5dive _audit_append gate-tap` never matches a standard
  # seat's grant: sudoers matches argv EXACTLY, and the grant has no argument.
  # These arms run the REAL relay against a sudo that records what it was asked,
  # and hold that argv to the line render_standard_sudoers actually writes.
  _real_priv_append_src=$(source "$SRC/task/answer.sh" >/dev/null 2>&1; declare -f _gate_tap_priv_append)
  eval "${_real_priv_append_src/_gate_tap_priv_append/_real_priv_append}"
  sudo() { printf '%s\n' "$*" >"$TMP/sudo-argv"; cat >"$TMP/sudo-stdin"; }
  _real_priv_append "$_l305"; _rk=$?
  _argv=$(cat "$TMP/sudo-argv" 2>/dev/null)
  [[ $_rk -eq 0 && "$_argv" == "-n /usr/local/bin/5dive _audit_append" ]] \
    && ok_t "T8k the relay asks sudo for EXACTLY '5dive _audit_append' (no argument), the sink rides stdin" \
    || bad_t "T8k relay argv" "rc=$_rk argv='$_argv'"
  _std=$( (source "$SRC/cmd_agent_create.sh" >/dev/null 2>&1; render_standard_sudoers agent-relaybot 0 0) 2>/dev/null)
  _cmd="${_argv#-n }"
  grep -qxF "agent-relaybot ALL=(root) NOPASSWD: ${_cmd}" <<<"$_std" \
    && ok_t "T8l a standard seat's rendered sudoers grants that exact command, so sudo will match it" \
    || bad_t "T8l rendered grant matches the relay" "cmd='$_cmd' grant lines: $(grep -F _audit_append <<<"$_std")"

  _gate_is_root() { return 0; }
  _before=$(wc -l <"$ROOTLOG")
  SUDO_USER=agent-relaybot _audit_append_stdin <"$TMP/sudo-stdin"; _rm=$?
  [[ $_rm -eq 0 && "$(wc -l <"$ROOTLOG")" == $((_before + 1)) && "$(tail -1 "$ROOTLOG")" == *'"gate":"DIVE-305"'*'"appended_by":"agent-relaybot"'* ]] \
    && ok_t "T8m root reads what the relay sent over stdin and lands it in the tap ledger" \
    || bad_t "T8m stdin sink end to end" "rc=$_rm lines $_before -> $(wc -l <"$ROOTLOG") tail=$(tail -1 "$ROOTLOG")"
  _real_audit_log="${AUDIT_LOG:-}"; AUDIT_LOG="$TMP/audit-root.log"; : >"$AUDIT_LOG"
  _orig_audit_init=$(declare -f audit_init); audit_init() { :; }
  _before=$(wc -l <"$ROOTLOG")
  printf '{"cmd":"task done","user":"spoofed"}\n' | SUDO_USER=agent-relaybot _audit_append_stdin; _rn1=$?
  printf '%s\n%s\n' "$AUDIT_SINK_GATE_TAP" "$_forged" | SUDO_USER=agent-relaybot _audit_append_stdin; _rn2=$?
  [[ $_rn1 -eq 0 && "$(jq -r .user "$AUDIT_LOG" 2>/dev/null)" == agent-relaybot && $_rn2 -ne 0 \
     && "$(wc -l <"$ROOTLOG")" == "$_before" ]] \
    && ok_t "T8n a headerless line still goes to the audit log (re-stamped); a forged tap over stdin is refused" \
    || bad_t "T8n audit path unchanged, forged tap refused" "rn1=$_rn1 rn2=$_rn2 audit=$(cat "$AUDIT_LOG") ledger $_before -> $(wc -l <"$ROOTLOG")"
  AUDIT_LOG="$_real_audit_log"; eval "$_orig_audit_init"; unset -f sudo

  _gate_is_root() { [[ $EUID -eq 0 ]]; }
  chmod 0700 "$TMP/ro"; GATE_TAP_LOG="$_real_tap_log"
fi

# --- T9: DIVE-7765 — `--channel-proof=telegram:<id>`. -----------------------
# The prefixed form our own surfaces print was refused as "not in allowFrom"
# while the id WAS in allowFrom. The fixture channel lists TAP_UID only.
cat >"$TMP/access.json" <<ACC
{"allowFrom": ["$TAP_UID"], "groups": {}}
ACC
_task_owner_channel() { TASK_CH_ACCESS="$TMP/access.json"; TASK_CH_TOKEN=""; return 0; }
sudo() { return 1; }   # no privileged rails on a fixture: keep every answer in-process
t1gate() {
  cmd_task_need "$1" --type=decision --ask="ship it?" --options="A|B" --ask-ok="fixture gate (DIVE-4462)" \
    --recommend="A" --tier=1 >/dev/null 2>&1
}
seed DIVE-310; t1gate DIVE-310
out=$(cmd_task_answer DIVE-310 --value=A --channel-proof="telegram:$TAP_UID" 2>&1); rc=$?
# `human_evidence` names the form that cleared it; `channel-chat` is set ONLY when
# _gate_channel_proof_ok verified the chat (the roster guard may still rename the
# stamp, which is T5's business, not this arm's).
_ev310=$(db "SELECT COALESCE(human_evidence,'') FROM tasks WHERE ident='DIVE-310';")
[[ $rc -eq 0 && "$(answered DIVE-310)" == closed && "$_ev310" == *channel-chat* ]] \
  && ok_t "T9a telegram:<id> is ACCEPTED as channel proof when <id> is in allowFrom (evidence=channel-chat)" \
  || bad_t "T9a telegram:<id> accepted" "rc=$rc state=$(answered DIVE-310) evidence=$_ev310 out=$out"
seed DIVE-311; t1gate DIVE-311
out=$( (cmd_task_answer DIVE-311 --value=A --channel-proof="telegram:9876543210" --channel-msg=5) 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-311)" == open && "$out" == *"not in access.json allowFrom"* ]] \
  && ok_t "T9b telegram:<id> NOT in allowFrom is refused with the allowFrom reason" \
  || bad_t "T9b allowFrom miss reason" "rc=$rc state=$(answered DIVE-311) out=$out"
for _bad in abc -1001234567890 "telegram:-100123" "telegram:12a"; do
  out=$( (cmd_task_answer DIVE-310 --value=A --channel-proof="$_bad") 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"takes the chat id as a number"* && "$out" != *allowFrom* ]] \
    && ok_t "T9c '$_bad' is refused with the FORMAT reason, not the allowFrom one" \
    || bad_t "T9c format reason for '$_bad'" "rc=$rc out=$out"
done
(_gate_channel_proof_parse "telegram:$TAP_UID"; [[ "$TASK_CP_CHAT" == "$TAP_UID" ]]) \
  && ok_t "T9d the parser strips exactly the telegram: prefix and keeps the number" \
  || bad_t "T9d parser" "TASK_CP_CHAT did not come back as $TAP_UID"

echo "-----"
SUMMARY_PRINTED=1
printf 'gate_tap_human_attribution_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
