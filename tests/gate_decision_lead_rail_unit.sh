#!/usr/bin/env bash
# DIVE-4415 — A PLAIN TIER-1 `decision` GATE ENGAGES THE LEAD RAIL.
#
# THE INCIDENT (customer box teal-fox, 5dive 0.35.1, 2026-09-13). An agent
# (claude-swan) whose org row names a `reports_to` lead (claude-victor, under
# claude-alena) filed `task need --type=decision --tier=1 --options=… --recommend=…`
# on a real in-org scope fork. It went straight to the paired human. `gate_history`
# shows two epochs and `route_provenance` EMPTY on BOTH; the delivery log has no
# "lead-route gate QUEUED" line for it, only phone pings. The principal answered
# "the agent must decide by himself, this is just confusing noise for a human", and
# the lead settled it in one line once it reached him. The routing was the entire
# failure.
#
# THE CAUSE, and it is NOT the epoch machinery the first hypothesis blamed (epoch 1
# was equally unrouted): `_routable` is 1 for a tier<2 `decision`, but the routing
# block's condition is a DISJUNCTION OF KINDS and a plain decision matches none of
# them. The only clause that could fire for it was `gate_builder_routing == on` —
# DIVE-1243's rollout pref, default OFF, which nothing in provisioning turns on.
# Our own fleet ran `5dive task routing on` long ago, which is exactly why this was
# invisible from here: on every customer box, no in-org decision has ever reached a
# lead.
#
# WHY THE FIX IS A KIND AND NOT A DEFAULT FLIP. Flipping `gate_builder_routing` to
# `on` was the first cut and it reds six arms of gate_row_state_routing_unit.sh:
# DIVE-3266 deliberately keeps a ship-shaped APPROVAL with no structured binding on
# the human path. Reversing another row's decision as a side effect of fixing a
# different class is the widening this codebase keeps a rule against. Arm S below
# is the scope control that holds that line.
#
# THE ARMED CONTROLS (arms S and E). Every routed arm here would also pass against
# a build that routes EVERYTHING, and every human-path arm would also pass against
# a build that routes NOTHING. S files the same ask as an `approval` and requires
# the human; E requires the human for a tier-2 decision, a declared human
# capability, and a chart whose whole chain is unwakeable. Green on all of them at
# once is the only shape a correctly-scoped build can produce.
#
# Run: bash tests/gate_decision_lead_rail_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-decision-lead-rail.XXXXXX)"
SUMMARY_PRINTED=0
exec 8>&2
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "${SUMMARY_PRINTED:-0}" == 1 ]] || printf "ABORTED - gate_decision_lead_rail_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh lib/broker.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The human-ping sentinel is a FILE, not a variable: every receipt below is
# captured with `$( )`, which is a subshell, and a variable set inside one dies
# with it — the hazard measured and documented in gate_row_state_routing_unit.sh.
PING_FILE="$TMP/ping.log"
_task_need_notify_deliver() { printf '1\n' >>"$PING_FILE"; }
human_pinged() { [[ -s "$PING_FILE" ]]; }
AUDIT_FILE="$TMP/audit.log"
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_FILE"; return 0; }
audit_log() { :; }
ROUTE_FILE="$TMP/route.log"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true

# The customer's chart, verbatim in shape: alena is the lone root (so also the
# coordinator fallback), victor reports to alena, swan reports to victor.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('alena',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('victor','alena','head of research');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('swan','victor','builder');"

# A neutral in-org ask: it must miss the eng-ship classifier and the tier-2
# category floor, or these arms stop isolating the decision kind.
ASK="Which of the two shapes should we build for this scope fork?"

seed()       { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1','decision lead rail fixture','todo','swan');"; }
reviewerof() { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
provof()     { db "SELECT COALESCE(route_provenance,'') FROM tasks WHERE ident='$1';"; }
tierof()     { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
file_gate() { local ident="$1" who="$2"; shift 2; : >"$PING_FILE"; : >"$ROUTE_FILE"; : >"$AUDIT_FILE"
              actor_seam_as "$who"; cmd_task_need "$ident" "$@" --from="$who" 2>&1; }

# ── P. THE PREMISE ───────────────────────────────────────────────────────────
# Assert the ask misses both classifiers on the PREDICATE, not by inferring it
# from an outcome — otherwise a regex change silently turns every arm below into
# a test of something else.
if _gate_eng_ship_hit "$ASK"; then
  bad_t "premise: the ask misses the eng-ship classifier" "the regex NOW MATCHES '$ASK' — re-base these arms on a fresh miss"
else ok_t "premise: the ask is not eng-ship shaped, so any route below is the decision kind's"; fi

# ── D. THE DEFAULT PREF DID NOT MOVE ─────────────────────────────────────────
# The fix is a routable KIND. If a later change flips the pref default instead,
# this arm is the one that says so — and DIVE-3266's six arms are what it costs.
[[ "$(_gate_routing_pref)" == "off" ]] \
  && ok_t "D1 an unset gate_builder_routing still reads 'off' — the DIVE-1243 rollout pref did not silently flip" \
  || bad_t "D1 pref default" "_gate_routing_pref printed '$(_gate_routing_pref)', want off"
_task_pref_set gate_builder_routing bogus
[[ "$(_gate_routing_pref)" == "off" ]] \
  && ok_t "D2 an unrecognised stored value reads as the default, not as a third state" \
  || bad_t "D2 pref garbage" "printed '$(_gate_routing_pref)'"
_task_pref_set gate_builder_routing on
[[ "$(_gate_routing_pref)" == "on" ]] || bad_t "D3 explicit on" "printed '$(_gate_routing_pref)'"
_task_pref_set gate_builder_routing off
[[ "$(_gate_routing_pref)" == "off" ]] \
  && ok_t "D3 an explicit on/off still round-trips through the single reader" \
  || bad_t "D3 explicit off" "printed '$(_gate_routing_pref)'"

# ── R. THE REGRESSION — the customer's filing, on the customer's default ─────
# gate_builder_routing is OFF for every arm from here down. That is the whole
# point: on the fleet where this was written it is ON, which is why the bug was
# invisible from here for the pref's entire life.
seed DIVE-501
OUT=$(file_gate DIVE-501 swan --type=decision --tier=1 --options="widen now|split" --recommend="split" --ask="$ASK")
[[ "$(reviewerof DIVE-501)" == "victor" ]] \
  && ok_t "R1 a plain tier-1 decision routes to the filer's reports_to lead with the pref OFF" \
  || bad_t "R1 tier-1 decision must reach the lead" "routed_reviewer='$(reviewerof DIVE-501)'; out=$OUT"
human_pinged && bad_t "R2 the human must NOT be pinged" "ping file non-empty; out=$OUT" \
  || ok_t "R2 the paired human was NOT pinged — the question stayed in the org"
[[ "$(provof DIVE-501)" == "chart" ]] \
  && ok_t "R3 route_provenance names the source that picked the lead (chart)" \
  || bad_t "R3 provenance" "got '$(provof DIVE-501)'"
grep -q 'decision-tier1' <<<"$OUT" \
  && ok_t "R4 the receipt names the KIND that routed it, not the pref (which is off)" \
  || bad_t "R4 trigger" "out=$OUT"
grep -q 'routed to victor' <<<"$OUT" \
  && ok_t "R5 the filer is told WHO it went to, in the ok line" \
  || bad_t "R5 receipt names the recipient" "out=$OUT"
[[ "$(tierof DIVE-501)" == "1" ]] \
  && ok_t "R6 the tier is untouched — routing moved the recipient, not the gate's weight" \
  || bad_t "R6 tier" "got '$(tierof DIVE-501)'"

# ── F. THE FILING IS ON THE RECORD ───────────────────────────────────────────
# `task need --withdraw` NULLs need_type/tier/options/recommend off the row, and on
# the incident box agent-audit.log held ZERO `task need` rows — so after a withdraw
# there was no record anywhere of the tier/needs/urgent triple that decides routing.
grep -qE 'task need filed .*task=DIVE-501 type=decision tier=1 .*needs=<none>' "$AUDIT_FILE" \
  && ok_t "F1 the filing itself is audit-logged with the args routing was decided on" \
  || bad_t "F1 filing row" "audit=$(cat "$AUDIT_FILE")"

# ── E2. THE SECOND EPOCH ─────────────────────────────────────────────────────
# The incident re-filed 10s later and the second epoch was human-bound too. A
# re-file must resolve its OWN route rather than inherit whatever the last one had.
OUT=$(file_gate DIVE-501 swan --type=decision --tier=1 --options="widen now|split" --recommend="split" --ask="$ASK")
[[ "$(reviewerof DIVE-501)" == "victor" && "$(provof DIVE-501)" == "chart" ]] \
  && ok_t "E2 a re-file 10s later routes identically — the route is per-EPOCH, not once per gate" \
  || bad_t "E2 re-file" "reviewer='$(reviewerof DIVE-501)' prov='$(provof DIVE-501)'; out=$OUT"
human_pinged && bad_t "E2 re-file must not ping the human" "out=$OUT" \
  || ok_t "E2 the re-filed epoch did not reach the human either"

# ── S. SCOPE CONTROL — approval is NOT swept in with decision ────────────────
# DIVE-3266's population. If this goes green-routed, the fix has widened past the
# class it was filed for and six arms of gate_row_state_routing_unit.sh are next.
seed DIVE-502
OUT=$(file_gate DIVE-502 swan --type=approval --tier=1 --ask="$ASK")
[[ -z "$(reviewerof DIVE-502)" ]] \
  && ok_t "S1 an unbound tier-1 APPROVAL from the same seat still does NOT route (DIVE-3266 unchanged)" \
  || bad_t "S1 approval must not route" "routed_reviewer='$(reviewerof DIVE-502)'; out=$OUT"
human_pinged \
  && ok_t "S2 …and it still reaches the human — the harness CAN observe an unrouted outcome" \
  || bad_t "S2 approval must ping the human" "out=$OUT"
[[ "$(provof DIVE-502)" == human:* ]] \
  && ok_t "S3 the human path now RECORDS its route too: '$(provof DIVE-502)' (was NULL, indistinguishable from no routing code)" \
  || bad_t "S3 human provenance" "got '$(provof DIVE-502)'"

# ── E. THE DISQUALIFIERS STILL DISQUALIFY ────────────────────────────────────
seed DIVE-503
# `--ask-ok=` is how a tier-2 gate that names no capability is filed at all: the
# DIVE-4176 refusal fires BEFORE the write otherwise, which is itself worth
# pinning here — a bare `--tier=2` decision cannot reach this code path.
OUT=$(file_gate DIVE-503 swan --type=decision --tier=2 --ask-ok="the customer's principal wants this one himself" --ask="$ASK")
[[ -z "$(reviewerof DIVE-503)" && "$(provof DIVE-503)" == "human:tier2-pinned" ]] \
  && ok_t "E1 a PINNED --tier=2 decision is the filer saying 'a person must see this' — unrouted, and the row says why" \
  || bad_t "E1 tier-2 pinned" "reviewer='$(reviewerof DIVE-503)' prov='$(provof DIVE-503)'; out=$OUT"

seed DIVE-504
OUT=$(file_gate DIVE-504 swan --type=decision --tier=1 --needs=human_tap --ask="$ASK")
[[ -z "$(reviewerof DIVE-504)" && "$(provof DIVE-504)" == human:needs-capability:* ]] \
  && ok_t "E2 a DECLARED human capability is unrouted whatever the tier says, and names the capability" \
  || bad_t "E2 declared capability" "reviewer='$(reviewerof DIVE-504)' prov='$(provof DIVE-504)'; out=$OUT"

# The wakeability rider. Without it, routing a decision by kind would park it on a
# seat that cannot answer for the full 24h agent rail before the re-nag escalates —
# strictly worse than the human ping it replaced.
_task_doctor_lane_wakeable() { return 1; }   # 1 == unwakeable, per _task_verify_unwakeable
seed DIVE-505
OUT=$(file_gate DIVE-505 swan --type=decision --tier=1 --ask="$ASK")
[[ -z "$(reviewerof DIVE-505)" && "$(provof DIVE-505)" == "human:no-lead" ]] \
  && ok_t "E3 a chart whose whole chain is unwakeable falls through to the human AT FILE TIME, not after a 24h rail" \
  || bad_t "E3 unwakeable chain" "reviewer='$(reviewerof DIVE-505)' prov='$(provof DIVE-505)'; out=$OUT"
human_pinged && ok_t "E3 …and the human really was pinged for it" || bad_t "E3 unwakeable must ping" "out=$OUT"
unset -f _task_doctor_lane_wakeable

# ── C. THE T2 CATEGORY FLOOR IS THE ONE THING THE TIER HALF OF THE KIND GUARDS ─
# `_decision_route` is `[[ $type == decision && $tier != 2 ]]`, and quinn's mutant
# (iteration 1) dropped the tier half: the harness stayed 20/0 while a money
# decision moved onto the lead's queue. Nothing here saw it because E1 covers the
# PINNED `--tier=2` case, and that one is independently blocked one layer down by
# `[[ "$tier_arg" == "2" ]] && _routable=0` (need.sh) — so E1 passes with or
# without the guard. There is no `tier_floored -> _routable=0` line anywhere: the
# floor works by setting `tier=2`, and `[[ "$_decision_route" == "1" ]] &&
# _routable=1` sits BELOW the `case` that read `$tier`, so it OVERRIDES the floor's
# routability the moment its own tier test is gone. The FLOORED population is what
# the tier half uniquely protects, and the floor exists precisely to force
# money/secret/irreversible asks to a person.
FLOOR_ASK="Refund the customer and charge the invoice to our card, or hold the charge?"
# The predicate first, the mirror of arm P: assert the ask really DOES trip the
# floor, so a regex change cannot quietly turn the arms below into a test of an
# ordinary unfloored decision that routes for the ordinary reason.
[[ "$(_gate_floor_axis "$FLOOR_ASK" "decision lead rail fixture")" == "ask" ]] \
  && ok_t "C0 premise: the floor classifier really does hit this ask on the ASK axis" \
  || bad_t "C0 premise: the floor must hit the ask" "_gate_floor_axis printed '$(_gate_floor_axis "$FLOOR_ASK" "decision lead rail fixture")' — re-base C on an ask that still trips the floor"
seed DIVE-506
OUT=$(file_gate DIVE-506 swan --type=decision --tier=1 --options="refund now|hold the charge" --recommend="hold the charge" --ask="$FLOOR_ASK")
[[ "$(tierof DIVE-506)" == "2" ]] \
  && ok_t "C1 a tier-1 decision whose ask names money is FLOORED to tier 2 — the filer does not get to lower it" \
  || bad_t "C1 category floor must elevate the tier" "tier='$(tierof DIVE-506)'; out=$OUT"
[[ -z "$(reviewerof DIVE-506)" ]] \
  && ok_t "C2 …and it is NOT on the lead rail: a floored decision has no routed_reviewer" \
  || bad_t "C2 a floored decision must not reach a lead" "routed_reviewer='$(reviewerof DIVE-506)' — the tier half of _decision_route is gone; out=$OUT"
[[ "$(provof DIVE-506)" == "human:category-floor" ]] \
  && ok_t "C3 …and the row records WHY it stayed human: the category floor, not a missing lead" \
  || bad_t "C3 floored provenance" "got '$(provof DIVE-506)', want human:category-floor; out=$OUT"
human_pinged \
  && ok_t "C4 …and the paired human really WAS pinged — the floored gate reached a person" \
  || bad_t "C4 a floored decision must ping the human" "ping file empty; out=$OUT"

# ── T. THE OPERATOR-FACING TEXT SAYS WHAT THE CODE DOES ──────────────────────
# `task routing off|status` is the only place an operator learns who a gate reaches.
# After this ticket `decision` routes by KIND and never reads the pref, so the old
# off line ("decision gates ping the human directly … an explicit opt-out FROM the
# default") was false in both halves: the default did not move, and the one class it
# named as human-bound is the class that now goes to the lead. Nothing asserted
# either string before — grep across tests/ for "explicit opt-out" returned only
# unrelated verify_optout matches — which is why an operator could run the command,
# be told it worked, and be wrong. These arms are the reason the next edit cannot
# re-break it silently.
OUT=$(cmd_task_routing off 2>&1)
grep -qi 'explicit opt-out' <<<"$OUT" \
  && bad_t "T1 'routing off' must not call itself an opt-out from a default that never moved" "out=$OUT" \
  || ok_t "T1 'routing off' no longer claims to be an opt-out FROM the default — the default is still off (arm D1)"
grep -qi 'decision gates ping the human directly' <<<"$OUT" \
  && bad_t "T2 'routing off' must not claim decision gates reach the human" "the class it names is the class this ticket routed; out=$OUT" \
  || ok_t "T2 'routing off' no longer promises the human a class that now goes to the lead"
grep -q 'routes to the org lead BY KIND' <<<"$OUT" \
  && ok_t "T3 'routing off' names the bypass explicitly: a tier<2 decision routes by KIND" \
  || bad_t "T3 'routing off' must name the kind bypass" "out=$OUT"
grep -q 'approval or manual' <<<"$OUT" \
  && ok_t "T4 …and it still names what the pref DOES govern, so off is not read as a no-op" \
  || bad_t "T4 'routing off' must name the population it still governs" "out=$OUT"
OUT=$(cmd_task_routing status 2>&1)
grep -q 'routes to the org lead BY KIND' <<<"$OUT" \
  && ok_t "T5 'routing status' carries the same exception — the printed value is not the whole answer" \
  || bad_t "T5 'routing status' must say decision no longer honours the value it prints" "out=$OUT"
_task_pref_set gate_builder_routing off

printf '\n%s: %d passed, %d failed\n' "$(basename "$0" .sh)" "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == 0 ]]
