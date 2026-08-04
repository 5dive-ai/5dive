#!/usr/bin/env bash
# DIVE-2519 (v0.18 W3) — `whoami --for=<subject>` renders the RECORDED authority
# chain and EXITS NON-ZERO when a link that HAPPENED cannot be measured.
#
# The bar this harness has to clear is DIVE-2224's: the verdict must be
# derivable FROM THE RECORD ALONE. So every arm constructs the record it grades
# — a fixture DB with lifecycle_events rows written directly — rather than
# asserting against whatever the live board happens to hold today.
#
# THE ARM THAT MATTERS MOST IS G, the exit-0 control. Without it, a verb that
# returned "unmeasurable / exit 1" unconditionally would pass every other arm on
# this page. That is the exact shape this epoch exists to refuse — a control
# that reports a verdict while measuring nothing — and it would be absurd to
# ship it inside the check for it.
#
# Arms:
#   A  a happened-link with a real actor + authority        -> measured
#   B  a link the STATE says never happened                 -> n/a, NOT counted
#   C  post-ledger, transition happened, no event written   -> unmeasurable/no-recorded-event
#   D  row created before ledger_started                    -> unmeasurable/predates-ledger
#   E  actor is the literal placeholder 'cli' / 'unknown'   -> unmeasurable/actor-placeholder
#   F  actor is 'human:<x>'                                 -> unmeasurable/human-claim-undiscriminated
#   G  EVERY happened-link measured                         -> chain measured, EXIT 0   <-- the control
#   H  ledger_started marker absent                         -> unmeasurable/ledger-start-unknown
#   I  --for=gate:/task:/action: scopes the chain
#   J  a bad subject is exit 4, not a green empty chain
#   K  DIVE-2518 divergent --from claim  -> measured, DERIVED actor + claimed_by
#   L  divergent claim onto a placeholder-> unmeasurable  <-- K's differential
#   M  lead:<agent> vs human:<agent>     -> measured vs unmeasurable, as a PAIR
#
# Run: bash tests/whoami_for_chain_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

cd "$(dirname "$0")/.."

SRC=src
TMP="$(mktemp -d /tmp/whoami-for-chain-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_whoami.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

tasks_db_init

LEDGER_START='2026-07-30 00:40:06'
db "INSERT OR REPLACE INTO task_prefs(key,value) VALUES('ledger_started',$(sqlq "$LEDGER_START"));"

# cmd_task_add is the REAL verb, so it emits its own task.created ledger row.
# Every arm below is about the record, so the fixture has to OWN the record:
# without this clear, the arm's hand-written event is the SECOND row for the
# ident and the verb (ORDER BY id LIMIT 1) grades the harness's incidental one
# instead. That silently turned the placeholder and predates-ledger arms green
# on the wrong evidence the first time this file ran.
add() {
  local _i; _i=$(JSON_MODE=1 cmd_task_add "$@" 2>"$TMP"/err | jq -r '.data.ident // empty')
  db "DELETE FROM lifecycle_events WHERE ident=$(sqlq "$_i");"
  printf '%s' "$_i"
}

# Write the STATE row's transition columns directly. The state row is the
# discriminator between n/a and unmeasurable, so each arm has to be able to say
# "this transition DID happen" independently of whether an event exists.
state() { # state <ident> <col> <value>
  db "UPDATE tasks SET $2=$(sqlq "$3") WHERE ident=$(sqlq "$1");"
}
# Write a ledger event verbatim — actor and authority exactly as given.
ev() { # ev <ident> <kind> <actor> <authority> <ts>
  db "INSERT INTO lifecycle_events(ts,kind,ident,actor,authority,idem_key)
      VALUES($(sqlq "$5"),$(sqlq "$2"),$(sqlq "$1"),$(sqlq "$3"),$(sqlq "$4"),
             $(sqlq "$1-$2-$5-$RANDOM"));"
}
# Same, plus the DETAIL column. DIVE-2518 folds the MEASURED principal into
# detail as `derived_actor=<name>` whenever a --from claim DISAGREED with the
# derivation, leaving the claim in the `actor` column — so on those rows `actor`
# is the least reliable field in the row. Arms K and L grade which one the verb
# believes.
ev_d() { # ev_d <ident> <kind> <actor-claim> <authority> <ts> <detail>
  db "INSERT INTO lifecycle_events(ts,kind,ident,actor,authority,detail,idem_key)
      VALUES($(sqlq "$5"),$(sqlq "$2"),$(sqlq "$1"),$(sqlq "$3"),$(sqlq "$4"),
             $(sqlq "$6"),$(sqlq "$1-$2-$5-$RANDOM"));"
}
# Run the verb and capture BOTH the json and the exit code. JSON_MODE is set
# per-call, never globally, so the human render stays exercised too.
run_json() { JSON_MODE=1 cmd_whoami --for="$1" 2>"$TMP"/err; }
rc_of()    { JSON_MODE=1 cmd_whoami --for="$1" >/dev/null 2>"$TMP"/err; printf '%s' "$?"; }
v_of()     { printf '%s' "$1" | jq -r --arg l "$2" '.links[]|select(.link==$l)|.verdict'; }
r_of()     { printf '%s' "$1" | jq -r --arg l "$2" '.links[]|select(.link==$l)|.reason'; }
a_of()     { printf '%s' "$1" | jq -r --arg l "$2" '.links[]|select(.link==$l)|.event.actor'; }
c_of()     { printf '%s' "$1" | jq -r --arg l "$2" '.links[]|select(.link==$l)|.event.claimed_by'; }

# ── INSTRUMENT: the fixture writer actually lands rows ───────────────────────
# Without this, every "unmeasurable" arm below would pass on an empty table for
# the wrong reason — the verb would be reading a ledger the harness never wrote
# to, and no arm would notice.
I0=$(add "instrument row" --assignee=dev)
[[ "$(db "SELECT COUNT(*) FROM lifecycle_events WHERE ident=$(sqlq "$I0");")" == "0" ]] \
  && ok_t "INSTRUMENT: add() clears the real verb's own event, so arms grade the FIXTURE record" \
  || bad_t "INSTRUMENT: stale events survive add()" "arms would grade cmd_task_add's row, not the fixture's"
ev "$I0" task.created main self '2026-07-30 10:00:00'
[[ "$(db "SELECT COUNT(*) FROM lifecycle_events WHERE ident=$(sqlq "$I0");")" == "1" ]] \
  && ok_t "INSTRUMENT: the fixture writer lands lifecycle_events rows" \
  || bad_t "INSTRUMENT: fixture writer wrote nothing" "every unmeasurable arm below would be vacuous"

# ── A + B: measured, and n/a is not a failure ────────────────────────────────
A=$(add "A measured created" --assignee=dev)
state "$A" created_at '2026-07-30 10:00:00'
ev "$A" task.created olivia 'sudo:agent-olivia' '2026-07-30 10:00:00'
a=$(run_json "$A")
[[ "$(v_of "$a" created)" == "measured" ]] \
  && ok_t "A: a recorded event with a real actor+authority is 'measured'" \
  || bad_t "A: expected measured" "got '$(v_of "$a" created)'"
[[ "$(printf '%s' "$a" | jq -r '.links[]|select(.link=="created")|.event.authority')" == "sudo:agent-olivia" ]] \
  && ok_t "A: the recorded AUTHORITY is rendered, not just the actor" \
  || bad_t "A: authority not rendered" "$a"
[[ "$(v_of "$a" delivered)" == "n/a" && "$(r_of "$a" delivered)" == "did-not-happen" ]] \
  && ok_t "B: a transition the state row says never happened is n/a, not unmeasurable" \
  || bad_t "B: expected n/a/did-not-happen" "got '$(v_of "$a" delivered)'/'$(r_of "$a" delivered)'"

# ── C: post-ledger, it happened, nothing was recorded ────────────────────────
# The live instance of this arm is DIVE-2519 itself: started 2026-08-02 07:30:12
# with no task.started event on a row created after the ledger opened.
C=$(add "C started but unrecorded" --assignee=dev)
state "$C" created_at '2026-07-31 09:00:00'
state "$C" started_at '2026-07-31 09:05:00'
ev "$C" task.created main self '2026-07-31 09:00:00'
c=$(run_json "$C")
[[ "$(v_of "$c" started)" == "unmeasurable" && "$(r_of "$c" started)" == "no-recorded-event" ]] \
  && ok_t "C: a transition that happened post-ledger with no event is unmeasurable/no-recorded-event" \
  || bad_t "C: expected unmeasurable/no-recorded-event" "got '$(v_of "$c" started)'/'$(r_of "$c" started)'"
[[ "$(rc_of "$C")" == "1" ]] \
  && ok_t "C: exit 1 — a hole in the chain is a refusal, not a pass" \
  || bad_t "C: expected exit 1" "got $(rc_of "$C")"

# ── D: predates the ledger ───────────────────────────────────────────────────
D=$(add "D predates the ledger" --assignee=dev)
state "$D" created_at '2026-07-01 00:00:00'
d=$(run_json "$D")
[[ "$(r_of "$d" created)" == "predates-ledger" ]] \
  && ok_t "D: a row created before ledger_started reads predates-ledger, not no-recorded-event" \
  || bad_t "D: expected predates-ledger" "got '$(r_of "$d" created)'"
[[ "$(printf '%s' "$d" | jq -r '.predates_ledger')" == "true" ]] \
  && ok_t "D: --json exposes predates_ledger so a reader can tell the two silences apart" \
  || bad_t "D: predates_ledger flag wrong" "$d"

# ── E: placeholder actors ────────────────────────────────────────────────────
# 'cli' is task_actor's literal else-branch: derivation FAILED and recorded a
# value anyway. It is on the live board 2026-08-02 (DIVE-2457 et al).
for ph in cli unknown; do
  E=$(add "E placeholder $ph" --assignee=dev)
  state "$E" created_at '2026-07-31 10:00:00'
  ev "$E" task.created "$ph" self '2026-07-31 10:00:00'
  e=$(run_json "$E")
  [[ "$(v_of "$e" created)" == "unmeasurable" && "$(r_of "$e" created)" == "actor-placeholder:$ph" ]] \
    && ok_t "E: actor '$ph' is a failed derivation, reported unmeasurable (not laundered green)" \
    || bad_t "E[$ph]: expected unmeasurable/actor-placeholder:$ph" "got '$(v_of "$e" created)'/'$(r_of "$e" created)'"
done

# ── F: a human: claim carries no discriminator ───────────────────────────────
# gate-record-cannot-distinguish-tap-from-selfclear: no field separates an
# authorized human tap from an agent self-clear. UNMEASURABLE, not forged.
F=$(add "F human claim" --assignee=dev)
state "$F" created_at '2026-07-31 11:00:00'
state "$F" need_answered_at '2026-07-31 11:30:00'
ev "$F" task.created main self '2026-07-31 11:00:00'
ev "$F" gate.answered 'human:main' self '2026-07-31 11:30:00'
f=$(run_json "$F")
[[ "$(v_of "$f" answered)" == "unmeasurable" && "$(r_of "$f" answered)" == "human-claim-undiscriminated" ]] \
  && ok_t "F: a human:* actor is unmeasurable — the record cannot grade the claim" \
  || bad_t "F: expected unmeasurable/human-claim-undiscriminated" "got '$(v_of "$f" answered)'/'$(r_of "$f" answered)'"

# ── G: THE CONTROL — a fully measured chain must EXIT 0 ──────────────────────
# If this arm ever fails, nothing else on this page means anything: a verb that
# always says "unmeasurable" would satisfy every arm above it.
G=$(add "G fully measured" --assignee=dev)
state "$G" created_at   '2026-07-31 12:00:00'
state "$G" started_at   '2026-07-31 12:01:00'
state "$G" done_at      '2026-07-31 12:02:00'
ev "$G" task.created main self          '2026-07-31 12:00:00'
ev "$G" task.started dev  'sudo:agent-dev' '2026-07-31 12:01:00'
ev "$G" task.done    dev  self          '2026-07-31 12:02:00'
g=$(run_json "$G")
[[ "$(printf '%s' "$g" | jq -r '.chain')" == "measured" ]] \
  && ok_t "G/CONTROL: a chain whose every happened-link is recorded reads 'measured'" \
  || bad_t "G/CONTROL: expected chain=measured" "$g"
[[ "$(rc_of "$G")" == "0" ]] \
  && ok_t "G/CONTROL: EXIT 0 — the verb is not a constant refusal" \
  || bad_t "G/CONTROL: expected exit 0" "got $(rc_of "$G") — every arm above is now vacuous"
[[ "$(printf '%s' "$g" | jq -r '.counts.na')" == "2" ]] \
  && ok_t "G: the two n/a links do NOT count against the chain verdict" \
  || bad_t "G: n/a count wrong" "$g"

# ── H: the ledger start marker itself is missing ─────────────────────────────
# REACHABILITY FIRST. Deleting the pref and calling cmd_whoami does NOT reach
# this branch: cmd_whoami calls tasks_db_init, which INSERT OR IGNOREs the marker
# straight back (tasks_db.sh:1456). The first cut of this arm did exactly that
# and read 'predates-ledger' — it would have graded a branch it never entered.
# So H is asserted TWICE: once that the marker self-heals through the verb, and
# once on the branch itself, entered through the tasks_db_init seam.
db "DELETE FROM task_prefs WHERE key='ledger_started';"
h_healed=$(run_json "$D")
[[ "$(r_of "$h_healed" created)" == "predates-ledger" ]] \
  && ok_t "H/REACHABILITY: through the verb the marker SELF-HEALS (tasks_db_init) — the branch below is not reachable this way" \
  || bad_t "H/REACHABILITY: marker did not self-heal" "got '$(r_of "$h_healed" created)'"
db "DELETE FROM task_prefs WHERE key='ledger_started';"
h=$( tasks_db_init() { :; }; JSON_MODE=1 _whoami_for "$D" 2>/dev/null )
[[ "$(r_of "$h" created)" == "ledger-start-unknown" ]] \
  && ok_t "H: with no start marker we say we cannot TELL, rather than guessing predates-ledger" \
  || bad_t "H: expected ledger-start-unknown" "got '$(r_of "$h" created)'"
db "INSERT OR REPLACE INTO task_prefs(key,value) VALUES('ledger_started',$(sqlq "$LEDGER_START"));"

# ── I: class scoping ─────────────────────────────────────────────────────────
i_gate=$(JSON_MODE=1 cmd_whoami --for="gate:$F" 2>/dev/null)
[[ "$(printf '%s' "$i_gate" | jq -r '[.links[].link]|join(",")')" == "answered" ]] \
  && ok_t "I: --for=gate:<ident> scopes the chain to the gate link" \
  || bad_t "I: gate scope wrong" "$i_gate"
i_task=$(JSON_MODE=1 cmd_whoami --for="task:$G" 2>/dev/null)
[[ "$(printf '%s' "$i_task" | jq -r '[.links[].link]|join(",")')" == "created,started,delivered" ]] \
  && ok_t "I: --for=task:<ident> scopes to the task-lifecycle links" \
  || bad_t "I: task scope wrong" "$i_task"
i_act=$(JSON_MODE=1 cmd_whoami --for="action:$G" 2>/dev/null)
[[ "$(printf '%s' "$i_act" | jq -r '[.links[].link]|join(",")')" == "closed" ]] \
  && ok_t "I: --for=action:<ident> scopes to the terminal action" \
  || bad_t "I: action scope wrong" "$i_act"

# ── J: an unknown subject must not read as a clean empty chain ───────────────
( JSON_MODE=1 cmd_whoami --for=DIVE-99999 ) >/dev/null 2>&1; j_rc=$?
[[ "$j_rc" != "0" ]] \
  && ok_t "J: an unresolvable subject exits non-zero (rc=$j_rc), never a green empty chain" \
  || bad_t "J: unknown subject exited 0" "an empty chain that exits 0 is the failure mode this verb exists to remove"

# ── K: DIVE-2518 — a --from claim that DISAGREED with the derivation ─────────
# W2 made `--from` a claim rather than an override: when it diverges,
# ledger_record folds the MEASURED principal into detail as `derived_actor=<x>`
# and leaves the CLAIM in the actor column (tasks_db.sh:2110). olivia's draft of
# this verb predates W2 and would have rendered the claim as the answer.
# The link is MEASURED — we know exactly who ran it — but the row is attributed
# to somebody else, and both facts have to survive the render.
K=$(add "K divergent claim" --assignee=dev)
state "$K" created_at '2026-07-31 13:00:00'
ev_d "$K" task.created olivia 'sudo:agent-dev' '2026-07-31 13:00:00' 'derived_actor=dev'
k=$(run_json "$K")
[[ "$(v_of "$k" created)" == "measured" ]] \
  && ok_t "K: a divergent claim is MEASURED — we know who ran it; it is the attribution that disagrees" \
  || bad_t "K: expected measured" "got '$(v_of "$k" created)'"
[[ "$(a_of "$k" created)" == "dev" ]] \
  && ok_t "K: the DERIVED actor is rendered, not the claim in the actor column" \
  || bad_t "K: rendered the wrong principal" "got '$(a_of "$k" created)', want the derived 'dev'"
[[ "$(c_of "$k" created)" == "olivia" ]] \
  && ok_t "K: the claim survives as claimed_by — dropping it would destroy the only record of the disagreement" \
  || bad_t "K: claimed_by lost" "got '$(c_of "$k" created)'"
[[ "$(r_of "$k" created)" == "claim-divergent:olivia" && "$(printf '%s' "$k" | jq -r '.counts.claim_divergent')" == "1" ]] \
  && ok_t "K: the divergence is COUNTED and named, not silently absorbed into a green" \
  || bad_t "K: divergence not surfaced" "$k"

# ── L: the DIFFERENTIAL arm for K ────────────────────────────────────────────
# K alone passes for a verb that renders whichever principal happens to be the
# derived one. L inverts the pair: the CLAIM is a real agent name and the DERIVED
# actor is the `cli` placeholder. A verb that grades the actor column reads a
# clean 'olivia' and returns measured/exit 0; the correct one grades the derived
# value, finds a failed derivation wearing a name, and refuses.
L=$(add "L divergent onto a placeholder" --assignee=dev)
state "$L" created_at '2026-07-31 14:00:00'
ev_d "$L" task.created olivia self '2026-07-31 14:00:00' 'derived_actor=cli'
l=$(run_json "$L")
[[ "$(v_of "$l" created)" == "unmeasurable" && "$(r_of "$l" created)" == "actor-placeholder:cli" ]] \
  && ok_t "L/DIFFERENTIAL: grading the DERIVED value catches a placeholder the actor column hides" \
  || bad_t "L/DIFFERENTIAL: expected unmeasurable/actor-placeholder:cli" "got '$(v_of "$l" created)'/'$(r_of "$l" created)' — the verb is reading the CLAIM"
[[ "$(rc_of "$L")" == "1" ]] \
  && ok_t "L/DIFFERENTIAL: exit 1 — a clean-looking claim over a failed derivation is still a hole" \
  || bad_t "L/DIFFERENTIAL: expected exit 1" "got $(rc_of "$L")"

# ── M: `lead:<agent>` is MEASURED where `human:<agent>` is not ───────────────
# This distinction is LIVE, not hypothetical: DIVE-2517's gate.answered row on
# this very board carries actor `lead:olivia`. It is also entirely a judgement,
# so it gets an arm rather than an inference from the placeholder list.
#
# WHY THEY DIFFER. `human:<x>` is unmeasurable because NO field separates an
# authorised human tap from an agent self-clear — `human=1` is a self-assertable
# flag (gate-record-cannot-distinguish-tap-from-selfclear.md), and every `human:*`
# name on the live board is an agent short-name. `lead:<x>` claims something
# weaker and checkable: an AGENT cleared this in a lead role. The principal named
# is a real board agent, so the chain can attribute it. Nothing about the ROLE is
# verified here and this arm does not claim otherwise — only that the ACTOR is an
# identity, which is the question --for asks.
#
# Asserted as a PAIR on the same fixture shape. Alone, the lead arm passes for a
# verb that grades nothing at all; the human arm is what proves the two names take
# genuinely different paths through the same check.
M=$(add "M lead vs human on the same link" --assignee=dev)
state "$M" created_at       '2026-07-31 15:00:00'
state "$M" need_answered_at '2026-07-31 15:30:00'
ev "$M" task.created  main          self '2026-07-31 15:00:00'
ev "$M" gate.answered 'lead:olivia' self '2026-07-31 15:30:00'
m=$(run_json "$M")
[[ "$(v_of "$m" answered)" == "measured" ]] \
  && ok_t "M: lead:<agent> is MEASURED — the actor is a real board identity, whatever the role claims" \
  || bad_t "M: expected measured for lead:olivia" "got '$(v_of "$m" answered)'/'$(r_of "$m" answered)'"
[[ "$(a_of "$m" answered)" == "lead:olivia" ]] \
  && ok_t "M: the lead: prefix is preserved in the render, not silently stripped to a bare agent name" \
  || bad_t "M: lead prefix lost" "got '$(a_of "$m" answered)'"

MH=$(add "M/pair human on the same link" --assignee=dev)
state "$MH" created_at       '2026-07-31 15:00:00'
state "$MH" need_answered_at '2026-07-31 15:30:00'
ev "$MH" task.created  main           self '2026-07-31 15:00:00'
ev "$MH" gate.answered 'human:olivia' self '2026-07-31 15:30:00'
mh=$(run_json "$MH")
[[ "$(v_of "$mh" answered)" == "unmeasurable" && "$(v_of "$m" answered)" == "measured" ]] \
  && ok_t "M/PAIR: the SAME name under human: is unmeasurable and under lead: is measured — the prefix is what moves the verdict" \
  || bad_t "M/PAIR: the two prefixes did not diverge" "lead='$(v_of "$m" answered)' human='$(v_of "$mh" answered)' — one of them is grading nothing"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
