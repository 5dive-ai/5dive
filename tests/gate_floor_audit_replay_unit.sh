#!/usr/bin/env bash
# TIER: core
# DIVE-4346 iteration 3 — THE ARM THAT GRADES THE OUTCOME, NOT THE BRANCH.
#
# The matrix arm in gate_customer_tap_default_unit.sh grades the RULE (gate type x
# --needs x --recommend -> who is pinged) and it was green while the rule did not
# bite: quinn replayed the shipped predicate over this row's own audit population
# and found the floor exemption waiving the capability question on 14 of the 16
# needs-less taps the row exists to remove — on words like `spend` inside "spends
# some of our shared AI allowance" and `token` inside "tokenmaxxing".
#
# So this file replays DELIVERABLE 4 (the 7-day audit, verbatim asks off the board)
# through DELIVERABLE 1 (the capability default) and asserts the NUMBER. A gate
# that reaches the paired human must end in exactly one of two states:
#
#     REFUSED                       the filer must name what it consumes; or
#     FILED WITH A CAPABILITY       declared by the filer, or DERIVED from the
#                                   floor term and recorded as derived.
#
# The state this row exists to end — reaching the person with the column EMPTY —
# must be unreachable. That is the assertion; it cannot silently drift back.
#
# Run: bash tests/gate_floor_audit_replay_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-floor-replay.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
_tasks_db_migrate

cmd_send()               { return 0; }
_task_agent_channel()    { return 0; }
_task_send_owner()       { return 0; }
task_need_notify()       { return 0; }
_task_gate_retire_buttons() { return 0; }
audit_log()              { return 0; }
_task_store_audit_log()  { return 0; }
# No lead above the filer: every gate below really does reach the paired human,
# which is the population the audit measured.
_gate_route_reviewer()   { printf ''; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

# ============ A. the incidental substrings quinn printed ======================
# Not inferred — each is the matched context quinn printed from their own snapshot
# of the board, plus two fresh asks they wrote. The floor must stop reading a
# reserved class out of an unrelated stem.
while IFS='|' read -r name text; do
  if _gate_tier2_floor_hit "$text"; then
    bad_t "A-neg: $name no longer reads a reserved class" "floored on '$(_gate_tier2_floor_term "$text")': $text"
  else ok_t "A-neg: $name no longer reads a reserved class"; fi
done <<'NEG'
DIVE-4218 spends/AI-allowance|Should I switch us to starting a reviewer on demand the moment work is handed in? It is faster, but every hand-in then spends some of our shared AI allowance.
DIVE-4028 tokenmaxxing|approve delegated push for review of branch dive-4028 - the tokenmaxxing board now describes an agent running around the clock at both ends
DIVE-4060 tokenmaxxing|Approve delegated push for review of branch dive-4060-volume-anchor (tokenmaxxing volume anchor). Nothing goes live: it opens a PR for quinn to grade.
DIVE-4052 push-rail credential|Approve delegated push for review of branch dive-4052-quota-alert-opt-in? Implementation and harness are ready; direct GitHub push lacks credentials.
DIVE-4125 push-rail credential|Approve ops force-updating PR #56's branch to rebased head? Direct push lacks credentials and delegated push refuses the required non-fast-forward update.
quinn fresh: price parser|Rename the price parser module?
quinn fresh: token limit|Which token limit should the summariser use, 8k or 16k?
suspend (DIVE-2301 family)|Stop forging a suspension notice in the installer?
NEG

# ============ B. the classes that MUST still floor ============================
# The boundary must not buy its false positives back with false negatives. Every
# line here is a real reserved-class ask and must still trip the floor.
while IFS='|' read -r name text; do
  if _gate_tier2_floor_hit "$text"; then ok_t "B-pos: $name still floors"
  else bad_t "B-pos: $name still floors" "missed: $text"; fi
done <<'POS'
money, currency amount|Approve $480 a month for the paid Hetzner plan?
money, verb|Should we spend on a second build machine?
money, inflected|Approve the monthly spending on the paid plan?
billing|Switch our billing to annual?
destructive, inflected|The cleanup deleted the wrong rows last night - approve re-running it?
destructive, present|Approve a job that will delete every retired box?
secret, plural|Rotate the two leaked bot credentials and send me the new ones?
secret, api key|Paste a fresh api key for the mail provider?
public comms|Publish today's post without an image, or hold while I make one?
irreversible|This is irreversible once applied - go ahead?
POS

# ============ C. the audit population, replayed end to end ===================
# Every needs-less tier-2 gate in the 7 days to 2026-09-12, asks as filed. The
# assertion is per gate AND in aggregate.
N=0; UNCOUNTED=0; REFUSED=0; DERIVED=0
seed() { N=$((N+1)); db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status)
      VALUES ('$1', 'an audit-window row', 'medium', 'dev', 'main', 'standard', 'todo');"; }
replay() {
  local id="AUD-$1" ask="$2" rc=0
  seed "$id"
  ( cmd_task_need "$id" --from=dev --type="${3:-approval}" --tier=2 --ask="$ask" ) >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then
    REFUSED=$((REFUSED+1)); printf 'ok   - C[%s]: REFUSED (the filer must name the capability)\n' "$1"; PASS=$((PASS+1)); return 0
  fi
  local cap prov; cap="$(field "$id" needs_capability)"; prov="$(field "$id" floor_provenance)"
  if [[ "$cap" == "∅" || -z "${cap//[[:space:]]/}" ]]; then
    UNCOUNTED=$((UNCOUNTED+1))
    bad_t "C[$1]: filed reaching the human with an EMPTY capability column" "prov=$prov"
    return 0
  fi
  DERIVED=$((DERIVED+1))
  case "$prov" in
    *needs=derived:*) ok_t "C[$1]: filed carrying a DERIVED capability ($cap), recorded as derived" ;;
    *) bad_t "C[$1]: derivation is countable" "capability=$cap but floor_provenance does not say it was derived: $prov" ;;
  esac
}
replay 4028 "approve delegated push for review of branch dive-4028 - the tokenmaxxing board now describes an agent running around the clock at both ends instead of a person chatting at one end"
replay 4060 "Approve delegated push for review of branch dive-4060-volume-anchor (tokenmaxxing volume anchor). Nothing goes live: it opens a PR for quinn to grade."
replay 4052 "Approve delegated push for review of branch dive-4052-quota-alert-opt-in? Implementation and a 139-assertion harness are ready; direct GitHub push lacks credentials."
replay 4076 "Publish today's post without an image, or hold while I make one?" decision
replay 4166 "Should I spend ~20 short build jobs to measure the product-free baseline now? This avoids merging an intentionally inert interim baseline." decision
replay 4125 "Approve ops force-updating PR #56's branch to rebased head? Direct push lacks credentials and delegated push refuses the required non-fast-forward update."
replay 4195 "Should we email our 8 never-charged subscribers a start-paying upsell sequence? The council already voted no on this." decision
replay 4177 "Approve pushing the branch that stops release notes from silently dropping features. Say yes and a feature that never wrote a changelog entry can no longer be merged."
replay 4206 "Push this fix up for review? It stops the fleet from throwing away half of every coder's work - today a coder that is waiting on its subscription to reset has its work taken away."
replay 4208 "Right now most code changes are only checked after they are submitted, and each failure costs the team 20-45 minutes of rework. This change moves those checks onto the engineer's own machine."
replay 4229 "Approve opening this change for review: our release check currently refuses to publish when a test machine runs slowly, even though every test passed."
replay 4214 "Our agents message each other by typing straight into whichever agent is on the other end, even when that agent is in the middle of a job."
replay 4218 "Finished work now waits on one of two fixed reviewers, so reviews queue for hours. Should I switch us to starting a reviewer on demand? Every hand-in then spends some of our shared AI allowance."
replay 4138 "Approve deleting the retired test rows?" decision

eq_t "C-AGG: ZERO gates reach the paired human with an empty capability column" "$UNCOUNTED" "0"
if (( REFUSED >= 5 )); then
  ok_t "C-AGG: the floor exemption no longer waives the question wholesale (refused=$REFUSED of $N)"
else
  bad_t "C-AGG: the floor exemption no longer waives the question wholesale" \
        "only $REFUSED of $N refused; iteration 2 exempted 14 of these and quinn required a material drop"
fi
printf '# replay: %s audit gates -> %s refused, %s filed with a derived capability, %s uncounted\n' \
       "$N" "$REFUSED" "$DERIVED" "$UNCOUNTED"

# ============ D. a DECLARED capability is never overwritten ===================
seed DECL-1
DOUT=$( cmd_task_need DECL-1 --from=dev --type=approval --tier=2 --needs=human_tap \
    --ask='Approve 480 dollars a month for the paid plan?' 2>&1 )
eq_t "D: --needs= wins over any derivation" "$(field DECL-1 needs_capability)" "human_tap"
[[ "$(field DECL-1 needs_capability)" == "human_tap" ]] || printf '   (filing said: %s)\n' "$DOUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
