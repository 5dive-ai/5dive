#!/usr/bin/env bash
# 5.7s measured on the 5dive control plane (agent-dev seat, 2026-08-09, two runs
# 5.66s/5.48s) — fits the 300s core budget, so no TIER marker: core is the default.
# It was 50s before the capture-shape note below; that 44x is not sqlite, it is
# nine detached children each holding a command substitution's pipe open for 5s.
# DIVE-2093 isolated unit harness — `task need` must say WHO it routed to and WHY,
# at FILE TIME, and must say at file time when the routed seat cannot SIGN.
#
# THE DEFECT. The routed ok line has always named the reviewer and the ROLE
# ("routed to main2 for verifier review"). It never named the PROPERTY that chose
# that reviewer. Five instances across four agents (dev3/DIVE-2084,
# main/DIVE-2146, olivia right behind, main2/DIVE-2798 and DIVE-2808) filed a gate
# asking for an ACTION and had it land on the loop's verifier, who could judge the
# work and could not perform the act. Each cost a round trip, and NONE was visible
# on the board: a gate pending on the wrong principal renders exactly like a gate
# pending on the right one. The filer is the only party who knows what the ask
# needs, and filing is the only moment at which re-filing is free.
#
# WHY THE MUTATION ARM IS THE LOAD-BEARING ONE (case 3). "The ok line mentions the
# verifier" was ALREADY true before this change — the old line said "for verifier
# review". So a grep for the reviewer's name, or for the word verifier, passes on
# a build with no fix in it at all. The mutation arm neuters `_gate_route_why` and
# requires the why-clause assertions to go RED while routing itself stays green;
# without it every assertion here would be an echoed expectation.
#
# WHY THE POLARITY ARMS EXIST (cases 6-7). The signing check reads a PEER's sudo
# grant, which DIVE-2135 made possible and did not make guaranteed. An
# unmeasurable grant must resolve to UNKNOWN and never to `no` (DIVE-2318): a
# false `no` sends a filer to re-route a gate that would have cleared fine. And a
# non-push-shaped ask must print no require_sig clause at all — a notice that
# fires on every gate is wallpaper (DIVE-1955) and stops being read.
#
# Isolation mirrors the sibling gate harnesses: source src/ libs, throwaway
# STATE_DIR, FIVEDIVE_GATE_NOTIFY_LOG at a temp file so no prod telemetry is
# touched. Run: bash tests/gate_route_why_unit.sh (no root, no network).
#
# ENV NOTE — and the correction that cost this harness a REJECT (main2, 2026-08-10).
# This header used to cite DIVE-2007 and tell you to repro the CI shape with
#   env -u SUDO_USER -u SUDO_UID USER=runner bash tests/gate_route_why_unit.sh
# THAT IS NOT A CROSS-SEAT INSTRUMENT, AND HAS NOT BEEN SINCE DIVE-2518: the
# derivation stopped reading USER and SUDO_* altogether (that env path WAS the
# forgery it closed), so the command above re-shapes nothing the code consults and
# still runs as the caller's real uid. It reported 40/40 while this file was green
# if and only if the runner happened to be agent-dev. The seam below is the only
# instrument that moves the derived actor.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
# DIVE-2518: `--from` is provenance; TIER/ROUTING read the uid derivation, so an arm
# impersonating a filer must DERIVE as them. tests/lib/actor_seam.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-route-why-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e

NOTIFY_LOG="$TMP/gate-notify.log"; : >"$NOTIFY_LOG"
export FIVEDIVE_GATE_NOTIFY_LOG="$NOTIFY_LOG"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- THE SEAM, ARMED AND GRADED ----------------------------------------------
# Every `need` below files `--from=dev`. `--from` is PROVENANCE ONLY: since
# DIVE-2518 the routing AND the why-clause both read the UID DERIVATION
# (`task_actor`; cmd_task.sh resolves the reviewer the same way), which ignores
# `--from` by design — "a claim, never an override". So case 2's expected string
# "main is the lead dev reports to" is one only the DERIVED actor can produce,
# and before this pin the file was green exactly when the runner's uid happened
# to be agent-dev. It carries no TIER marker, so it is CORE, and full-sweep runs
# it on a GitHub runner whose uid is not agent-dev: a red on merge, not a local
# quirk. Pinning here rather than per-arm keeps the derived actor and the `--from`
# provenance one coherent caller across every case.
#
# The selftest is a GRADED ARM, not a precondition printf, because an
# impersonation harness that silently stops impersonating turns every arm below
# it green-and-vacuous — the one failure mode the seam exists to make loud.
actor_seam_selftest dev \
  && ok_t "SEAM: the sealed derivation resolves to 'dev' under the pin — the arms below grade the product, not the runner's uid" \
  || bad_t "the actor seam is INERT" "task_actor did not resolve to 'dev' under actor_seam_as; every routing arm below this line is vacuous"
actor_seam_as dev

tasks_db_init

AUDIT_LOG_FILE="$TMP/audit.log"; : >"$AUDIT_LOG_FILE"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }

ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() {
  if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then
    printf '%s\n' "${3:-}" >>"$ROUTE_FILE"
  fi
  return 0
}

# THE SIGNING SEAM. `agent_sudo_grant` lives in cmd_agent_create.sh, which this
# harness deliberately does not source: the real classifier is graded by that
# file's own harnesses, and what is under test HERE is the yes/no/unknown mapping
# and what the two call sites do with it. Stubbed per-arm via $GRANT so one seam
# drives every polarity. The empty default is the "function not available" shape,
# which must also read as unknown.
GRANT=""
agent_sudo_grant() { [[ -n "$GRANT" ]] && printf '%s\n' "$GRANT"; return 0; }

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('olivia','main','qa');"

# A task carrying a LIVE maker→verifier loop: dev makes, olivia verifies. Without
# maker_agent + verifier the verifier-route never engages and the arms below would
# pass vacuously against the lead rail.
seed_loop() {
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,verifier,maker_agent)
      VALUES('$1',$(sqlq "${2:-a routine ticket}"),'todo','main','dev','olivia','dev');"
}
# A task with NO loop, so the same filer's gate resolves through the org chart.
seed_plain() {
  db "INSERT INTO tasks(ident,title,status,created_by,assignee)
      VALUES('$1',$(sqlq "${2:-a routine ticket}"),'todo','main','dev');"
}
reset_log() { : >"$NOTIFY_LOG"; : >"$ROUTE_FILE"; : >"$AUDIT_LOG_FILE"; GRANT=""; }
reviewer_of() { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
JSON_MODE=0

# CAPTURE SHAPE, and it is worth 48 of the 50 seconds this harness used to take.
# The routed rail detaches a child that sleeps 5s before removing its own scratch
# dir, and that child INHERITS the stdout of whatever captured the parent — so
# `OUT=$(cmd_task_need ...)` blocks for the full 5s per call after the command has
# already returned. Measured 5.43s/call here and 5.43s/call against unmodified
# origin/main, so it is a property of the CAPTURE, not of this change. Writing to
# a file leaves the child no pipe to hold open: 9 filings, 49s -> ~1s.
OUT=""; ERR=""
need() { cmd_task_need "$@" >"$TMP/out" 2>"$TMP/err"; local rc=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err"); return $rc; }

# --- 0. the seat->signing mapping, directly ----------------------------------
# root-all/cli-root sign; cli-scoped/none do not. Everything else is the ABSENCE
# of a measurement and must come back `unknown`, never `no`.
seat() { GRANT="$1"; _gate_seat_can_sign somebody; }
[[ "$(seat 'root-all|any|0')"   == "yes|root-all"     ]] && ok_t "root-all seat signs"   || bad_t "root-all signs" "got '$(seat 'root-all|any|0')'"
[[ "$(seat 'cli-root|root|0')"  == "yes|cli-root"     ]] && ok_t "cli-root seat signs"   || bad_t "cli-root signs" "got '$(seat 'cli-root|root|0')'"
[[ "$(seat 'cli-scoped|root|0')" == "no|cli-scoped"   ]] && ok_t "cli-scoped seat does NOT sign" || bad_t "cli-scoped no" "got '$(seat 'cli-scoped|root|0')'"
[[ "$(seat 'none|-|0')"         == "no|none"          ]] && ok_t "a seat with no sudo does NOT sign" || bad_t "none no" "got '$(seat 'none|-|0')'"
[[ "$(seat 'custom|root|0')"    == "unknown|custom"   ]] && ok_t "a CUSTOM grant is unknown, not a no (entries this CLI did not write)" || bad_t "custom unknown" "got '$(seat 'custom|root|0')'"
[[ "$(seat 'unknown|-|0')"      == "unknown|unknown"  ]] && ok_t "an UNREADABLE grant is unknown, not a no (DIVE-2318)" || bad_t "unknown unknown" "got '$(seat 'unknown|-|0')'"
[[ "$(seat '')"                 == "unknown|unknown"  ]] && ok_t "a measurement that produced NOTHING is unknown, not a no" || bad_t "empty unknown" "got '$(seat '')'"
GRANT=""
[[ "$(_gate_seat_can_sign '')"  == "unknown|unknown"  ]] && ok_t "an EMPTY seat name is unknown — absent is not non-holding" || bad_t "empty name unknown" "got '$(_gate_seat_can_sign '')'"

# --- 1. VERIFIER ROUTE: the ok line names the deciding property ---------------
reset_log; seed_loop DIVE-8001
need DIVE-8001 --type=decision --ask="pick option A or B for the retry backoff" --options="A|B" --recommend="A" --from=dev; OUT_V="$OUT"; ERR_V="$ERR"
[[ "$(reviewer_of DIVE-8001)" == "olivia" ]] \
  && ok_t "verifier route is live here (routed_reviewer=olivia)" \
  || bad_t "verifier route live" "routed_reviewer='$(reviewer_of DIVE-8001)' out=$OUT_V err=$ERR_V"
grep -q 'why: routed by LOOP MEMBERSHIP' <<<"$OUT_V" \
  && ok_t "the ok line names the BASIS — routed by LOOP MEMBERSHIP" \
  || bad_t "basis named" "out: $OUT_V"
grep -q 'tasks.verifier' <<<"$OUT_V" \
  && ok_t "the ok line names the COLUMN the target came from (tasks.verifier), so the claim is checkable" \
  || bad_t "column named" "out: $OUT_V"
grep -q 'trigger=verifier-route' <<<"$OUT_V" \
  && ok_t "the ok line names the routable KIND (trigger=verifier-route)" \
  || bad_t "trigger named" "out: $OUT_V"
grep -q 'NO information about which capabilities' <<<"$OUT_V" \
  && ok_t "the ok line states the consequence — loop membership says nothing about capability" \
  || bad_t "consequence stated" "out: $OUT_V"
# The pre-existing surface must survive verbatim: sibling harnesses grep it.
grep -q 'routed to olivia for verifier review (decision, tier 1)' <<<"$OUT_V" \
  && ok_t "the pre-existing 'routed to X for Y review (type, tier N)' text is unchanged" \
  || bad_t "legacy ok text preserved" "out: $OUT_V"

# --- 2. LEAD ROUTE: a different basis, named as such --------------------------
reset_log; seed_plain DIVE-8002
need DIVE-8002 --type=approval --ask="approve the merge of the parser refactor" --recommend="yes" --from=dev; OUT_L="$OUT"; ERR_L="$ERR"
[[ "$(reviewer_of DIVE-8002)" == "main" ]] \
  && ok_t "no loop ⇒ the org chart resolves the lead (routed_reviewer=main)" \
  || bad_t "lead route live" "routed_reviewer='$(reviewer_of DIVE-8002)' out=$OUT_L err=$ERR_L"
grep -q 'why: routed by the ORG CHART' <<<"$OUT_L" \
  && ok_t "the lead rail names its own basis — routed by the ORG CHART" \
  || bad_t "lead basis named" "out: $OUT_L"
grep -q 'agents_org.reports_to' <<<"$OUT_L" \
  && ok_t "the lead rail names the column too (agents_org.reports_to)" \
  || bad_t "lead column named" "out: $OUT_L"
grep -q 'main is the lead dev reports to' <<<"$OUT_L" \
  && ok_t "the lead rail names BOTH ends of the edge (main ← dev), not just the target" \
  || bad_t "edge named" "out: $OUT_L"
grep -q 'trigger=eng-ship' <<<"$OUT_L" \
  && ok_t "the trigger reported is the SPECIFIC kind (eng-ship), not the pref that also applied" \
  || bad_t "specific trigger" "out: $OUT_L"
grep -q 'LOOP MEMBERSHIP' <<<"$OUT_L" \
  && bad_t "the two bases must not be confusable" "the lead line claimed loop membership: $OUT_L" \
  || ok_t "the lead rail does NOT claim loop membership — the two bases are distinguishable"

# --- 3. MUTATION ARM: neuter the why and the arms above must go RED -----------
# Run in a subshell so the neutering cannot leak into later cases. Routing itself
# must stay green: the requirement is that these assertions read the NEW artifact,
# not that the harness can break routing.
(
  _gate_route_why() { printf ''; }
  reset_log; seed_loop DIVE-8003
  need DIVE-8003 --type=decision --ask="pick option A or B for the retry backoff" --options="A|B" --recommend="A" --from=dev
  printf 'REVIEWER=%s\n%s\n' "$(reviewer_of DIVE-8003)" "$OUT" >"$TMP/mut"
)
MUT=$(cat "$TMP/mut")
grep -q 'REVIEWER=olivia' <<<"$MUT" \
  && ok_t "MUTANT: routing still works with the why-clause neutered (the mutation is scoped to the artifact under test)" \
  || bad_t "mutant still routes" "mut: $MUT"
grep -q 'why: routed by' <<<"$MUT" \
  && bad_t "MUTANT still prints a why clause" "the case-1 assertions would pass on a build with no fix: $MUT" \
  || ok_t "MUTANT: no why clause — so case 1 is reading the NEW artifact, not 'for verifier review' (which the old build also printed)"
grep -q 'routed to olivia for verifier review' <<<"$MUT" \
  && ok_t "MUTANT: the OLD text is still there — which is exactly why a grep for it proves nothing" \
  || bad_t "mutant keeps legacy text" "mut: $MUT"

# --- 4. require_sig, NON-SIGNING seat: loud at file time ----------------------
reset_log; seed_loop DIVE-8004; GRANT='cli-scoped|root|0'
need DIVE-8004 --type=approval --ask="authorize the delegated push of this branch for review" --recommend="yes" --from=dev
OUT_N="$OUT"; ERR_N="$ERR"
grep -q 'CANNOT sign this closure (grant=cli-scoped)' <<<"$OUT_N" \
  && ok_t "non-signing seat: the ok line carries the require_sig verdict and the grant that produced it" \
  || bad_t "require_sig verdict on ok line" "out: $OUT_N"
grep -q 'CANNOT MINT A CLOSURE SIGNATURE' <<<"$ERR_N" \
  && ok_t "non-signing seat: a loud warn fires at FILE time, before anyone has read a diff" \
  || bad_t "warn fires" "err: $ERR_N"
grep -q 'need_answer_sig lands EMPTY' <<<"$ERR_N" \
  && ok_t "the warn states the SILENT failure mode (an approved-looking gate with an empty signature)" \
  || bad_t "warn states failure mode" "err: $ERR_N"
grep -q 'not a re-sign verb' <<<"$ERR_N" \
  && ok_t "the warn states that the late repair does not exist — task answer cannot re-sign (DIVE-2808 step 4)" \
  || bad_t "warn states no late repair" "err: $ERR_N"
grep -qi 'do not grant .*gate-proof sign.* to a cli-scoped' <<<"$ERR_N" \
  && ok_t "the warn forecloses the WRONG fix (granting the signing verb to a cli-scoped seat is a forgery primitive)" \
  || bad_t "warn forecloses wrong fix" "err: $ERR_N"
[[ "$(reviewer_of DIVE-8004)" == "olivia" ]] \
  && ok_t "the gate still FILED and still routed — this is a warn, never a fail (a gate no broker checks is unharmed)" \
  || bad_t "gate still files" "routed_reviewer='$(reviewer_of DIVE-8004)'"

# --- 5. require_sig, SIGNING seat: says so, and says nothing alarming ---------
reset_log; seed_loop DIVE-8005; GRANT='root-all|any|0'
need DIVE-8005 --type=approval --ask="authorize the delegated push of this branch for review" --recommend="yes" --from=dev; OUT_S="$OUT"; ERR_S="$ERR"
grep -q 'can sign this closure (grant=root-all)' <<<"$OUT_S" \
  && ok_t "signing seat: the ok line says so positively (silence would be ambiguous with 'not checked')" \
  || bad_t "signing verdict" "out: $OUT_S"
grep -q 'CANNOT MINT' <<<"$ERR_S" \
  && bad_t "signing seat must not warn" "err: $ERR_S" \
  || ok_t "signing seat: no warn — the notice fires only where something is actually wrong"

# --- 6. require_sig, UNMEASURABLE: unknown is NOT a no (DIVE-2318) -----------
reset_log; seed_loop DIVE-8006; GRANT='unknown|-|0'
need DIVE-8006 --type=approval --ask="authorize the delegated push of this branch for review" --recommend="yes" --from=dev; OUT_U="$OUT"; ERR_U="$ERR"
grep -q 'NOT MEASURABLE from this seat' <<<"$OUT_U" \
  && ok_t "unmeasurable grant: reported as not measurable, on the record" \
  || bad_t "unknown reported" "out: $OUT_U"
grep -q 'unknown, not a no' <<<"$OUT_U" \
  && ok_t "unmeasurable grant: the line says so IN THOSE WORDS, so a reader cannot round it down to a refusal" \
  || bad_t "unknown polarity stated" "out: $OUT_U"
grep -q 'CANNOT' <<<"$OUT_U$ERR_U" \
  && bad_t "an unmeasured grant must never render as CANNOT sign" "out: $OUT_U err: $ERR_U" \
  || ok_t "unmeasurable grant does NOT produce the non-signing warn — a false 'no' costs a needless re-route"

# --- 7. NARROWNESS: an ordinary ask gets no require_sig clause at all ---------
# Same non-signing seat as case 4. The ONLY difference is the ask's shape. If this
# arm also printed the clause, the notice would be on every gate and read by nobody.
reset_log; seed_loop DIVE-8007; GRANT='cli-scoped|root|0'
need DIVE-8007 --type=decision --ask="pick option A or B for the retry backoff" --options="A|B" --recommend="A" --from=dev; OUT_O="$OUT"; ERR_O="$ERR"
grep -q 'require_sig' <<<"$OUT_O$ERR_O" \
  && bad_t "a non-push ask must print NO require_sig clause" "out: $OUT_O err: $ERR_O" \
  || ok_t "NARROWNESS: a non-push ask to the same non-signing seat prints no require_sig clause and no warn (DIVE-1955)"
grep -q 'why: routed by LOOP MEMBERSHIP' <<<"$OUT_O" \
  && ok_t "...while the WHY clause still prints — the two notices are independent" \
  || bad_t "why still prints" "out: $OUT_O"

# --- 8. the machine-readable half carries it too ------------------------------
reset_log; seed_loop DIVE-8008; GRANT='cli-scoped|root|0'
JSON_MODE=1
need DIVE-8008 --type=approval --ask="authorize the delegated push of this branch for review" --recommend="yes" --from=dev; OUT_J="$OUT"
JSON_MODE=0
[[ "$(jq -r '.data.route_basis' <<<"$OUT_J" 2>/dev/null)" == "verifier" ]] \
  && ok_t "JSON: route_basis=verifier — a dashboard can flag a misroute without parsing prose" \
  || bad_t "json route_basis" "out: $OUT_J"
[[ "$(jq -r '.data.route_trigger' <<<"$OUT_J" 2>/dev/null)" == "verifier-route" ]] \
  && ok_t "JSON: route_trigger=verifier-route" || bad_t "json route_trigger" "out: $OUT_J"
[[ "$(jq -r '.data.require_sig_seat' <<<"$OUT_J" 2>/dev/null)" == "no" ]] \
  && ok_t "JSON: require_sig_seat=no" || bad_t "json require_sig_seat" "out: $OUT_J"
reset_log; seed_loop DIVE-8009
JSON_MODE=1
need DIVE-8009 --type=decision --ask="pick option A or B for the retry backoff" --options="A|B" --recommend="A" --from=dev; OUT_J2="$OUT"
JSON_MODE=0
[[ "$(jq -r '.data.require_sig_seat' <<<"$OUT_J2" 2>/dev/null)" == "null" ]] \
  && ok_t "JSON: require_sig_seat is NULL when the check did not apply — not-checked and can-sign stay distinguishable" \
  || bad_t "json require_sig_seat null" "out: $OUT_J2"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
