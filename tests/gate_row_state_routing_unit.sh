#!/usr/bin/env bash
# TIER: nightly — 29.1s measured locally on the control-plane VM. Core is the
# DEFAULT and a demotion argued from an unverified budget number is the failure
# DIVE-2828 records, so the reason here is per-HARNESS cost, not a claim about the
# corpus: 29s is ~10% of the whole 300s core budget in one file, the CI runner is a
# ~1.7x factor in the wrong direction, and the direct sibling this is modelled on
# (gate_ship_routing_unit.sh) was put on nightly by DIVE-2525 for a measured 27.5s —
# same fixture shape, same cost, same tier. `changed-harnesses` runs a touched
# harness at introduction whatever its tier, so this costs nothing at review time.
#
# Isolated unit harness, no network, no root, throwaway STATE_DIR.
#
# DIVE-3266. Two halves of one defect: a gate ROUTES to the filer's lead only if
# the ask or the row TITLE trips `_GATE_ENG_SHIP_RX`, and when it does not route
# it says NOTHING about that. `routed_reviewer` NULL is the first clause of
# cmd_task_inbox's human predicate, so an unrouted gate IS a founder gate — and
# the filer's receipt for that was a cheerful `OK — <id> needs a human`.
#
# Measured 2026-08-11 filing DIVE-3224's own push gate: "…and open both PRs?"
# lowercases to `prs` and the regex member is `\bpr\b`, so the word boundary
# fails on a sentence entirely about pushing a branch and opening PRs.
#
# What this grades:
#   A. the reproduction — that exact ask still misses the prose classifier
#      (guards the premise; if this ever passes the regex, cases B/C are testing
#      nothing and this harness says so instead of going quietly green),
#   B. ROW STATE routes it anyway — a `Branch:` binding is structured state, so
#      the same ask on a branch-bound row reaches the lead,
#   C. every guard the new kind must NOT cross — explicit --tier=2, the T2
#      category floor, a declared human capability, a filer with no lead,
#   D. eng-ship still wins the TRIGGER name when both apply (existing receipts
#      stay byte-for-byte),
#   E. the unrouted receipt now NAMES the axis that decided, and the four
#      reasons are distinguishable from each other.
#
# Run: bash tests/gate_row_state_routing_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-rowstate-unit.XXXXXX)"

# lib/broker.sh + cmd_push.sh are sourced because `_push_branch_from_body` is the
# helper under test on the read side — the SAME function `5dive push` uses to
# decide which branch this row is bound to. Re-implementing it here would grade a
# stub, and the whole point of routing on row state is that the router and the
# pusher read the one binding through the one parser.
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# The human-ping sentinel goes through a FILE, not a variable. Every case below
# captures the receipt with `OUT=$(file_gate …)`, and a command substitution is a
# SUBSHELL — a `HUMAN_PINGED=1` set inside it dies with the subshell and the
# parent reads the 0 it set beforehand. That reads as "the human was not pinged",
# which is the assertion half these cases make, so the variable form goes GREEN on
# the routed cases for the wrong reason and RED only on the one case that expects
# a ping. Measured here: B1 red, B2 falsely green. Same hazard the ROUTE_FILE
# note below describes for the detached send, one layer up.
PING_FILE="$TMP/ping.log"
_task_need_notify_deliver() { printf '1\n' >>"$PING_FILE"; }
human_pinged() { [[ -s "$PING_FILE" ]]; }
audit_log() { :; }
ROUTE_FILE="$TMP/route.log"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true

# Org chart: main is the lone root (coordinator); dev reports to main. `solo` has
# no lead at all, which is the second unrouted cause and takes the OPPOSITE remedy.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# The verbatim ask from the DIVE-3224 receipt, trimmed only of its tail clause.
ASK_MISS="Push dive-3224-inbox to 5dive-cli AND 5dive-plugins and open both PRs?"

seed() {  # seed <ident> <title> [branch]
  local body=''; [[ -n "${3:-}" ]] && body="some context${NL:-
}Branch: $3"
  db "INSERT INTO tasks(ident,title,status,created_by,body) VALUES('$1',$(sqlq "$2"),'todo','main',$(sqlq "$body"));"
}
reviewerof() { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
provof()     { db "SELECT COALESCE(route_provenance,'') FROM tasks WHERE ident='$1';"; }
tierof()     { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }

# file_gate <ident> <actor> <args...> -> echoes the receipt (stdout+stderr).
# Truncates both sentinel files first, so `human_pinged` / the route log describe
# THIS filing. Safe to call in a command substitution: the sentinels are files.
file_gate() {
  local ident="$1" who="$2"; shift 2
  : >"$PING_FILE"; : >"$ROUTE_FILE"
  actor_seam_as "$who"
  cmd_task_need "$ident" "$@" --from="$who" 2>&1
}

# ---------------------------------------------------------------------------
# A. THE PREMISE. If this ask ever starts matching the prose classifier, cases
#    B and D stop grading what they claim to grade. Assert the miss directly on
#    the predicate rather than inferring it from a routing outcome.
# ---------------------------------------------------------------------------
if _gate_eng_ship_hit "$ASK_MISS"; then
  bad_t "premise: the DIVE-3224 ask misses _GATE_ENG_SHIP_RX" \
    "the regex NOW MATCHES '$ASK_MISS' — the prose classifier changed; cases B/D below no longer isolate row-state routing and must be re-based on a fresh miss"
else
  ok_t "premise: the DIVE-3224 ask misses _GATE_ENG_SHIP_RX (\`prs\` fails \\bpr\\b)"
fi
# And the same text as a TITLE misses too — _gate_hit_either is per-field, so a
# title hit would route case B for the wrong reason.
_gate_eng_ship_hit "$ASK_MISS" || ok_t "premise: it misses as a TITLE as well (per-field _gate_hit_either)"

# ---------------------------------------------------------------------------
# B. ROW STATE ROUTES IT. Same ask, same type, same tier, same filer — the only
#    difference is the `Branch:` line.
# ---------------------------------------------------------------------------
seed DIVE-101 'gate routing bug report'                              # no binding
seed DIVE-102 'gate routing bug report' dive-3224-inbox              # bound

OUT=$(file_gate DIVE-101 dev --type=approval --tier=1 --ask="$ASK_MISS")
[[ -z "$(reviewerof DIVE-101)" ]] \
  && ok_t "B1 negative control: unbound row + prose-missing ask does NOT route" \
  || bad_t "B1 unbound row must not route" "routed_reviewer='$(reviewerof DIVE-101)'"
human_pinged \
  && ok_t "B1 negative control: the human WAS pinged (this is the founder gate)" \
  || bad_t "B1 human ping expected" "ping file empty"

OUT=$(file_gate DIVE-102 dev --type=approval --tier=1 --ask="$ASK_MISS")
[[ "$(reviewerof DIVE-102)" == "main" ]] \
  && ok_t "B2 branch-bound row routes to the lead on the SAME ask" \
  || bad_t "B2 branch-bound row must route to main" "routed_reviewer='$(reviewerof DIVE-102)'; out=$OUT"
human_pinged \
  && bad_t "B2 human must not be pinged on a routed gate" "the human path ran" \
  || ok_t "B2 the human was NOT pinged"
[[ "$OUT" == *"routed to main for lead review"* ]] \
  && ok_t "B2 receipt names the reviewer" \
  || bad_t "B2 receipt must say 'routed to main for lead review'" "out=$OUT"
[[ "$OUT" == *"row-ship-state"* ]] \
  && ok_t "B2 receipt names the trigger 'row-ship-state'" \
  || bad_t "B2 receipt must name the new trigger" "out=$OUT"
# The TARGET still came from the org chart, so the provenance column must not
# claim a new source. Routing basis and routing trigger are different facts.
[[ "$(provof DIVE-102)" == "chart" ]] \
  && ok_t "B2 route_provenance stays 'chart' (the target came from the chart)" \
  || bad_t "B2 provenance must stay chart" "got '$(provof DIVE-102)'"

# decision type takes the same route (the three routable types, not just approval).
seed DIVE-103 'gate routing bug report' dive-3224-inbox
OUT=$(file_gate DIVE-103 dev --type=decision --ask="$ASK_MISS" --options="A|B" --recommend="A")
[[ "$(reviewerof DIVE-103)" == "main" ]] \
  && ok_t "B3 --type=decision on a bound row routes too" \
  || bad_t "B3 decision must route" "routed_reviewer='$(reviewerof DIVE-103)'; out=$OUT"

# ---------------------------------------------------------------------------
# C. THE GUARDS. A routing kind derived from row state must cross none of the
#    controls that make a gate human-only. Each of these is a case where the
#    founder SHOULD be woken.
# ---------------------------------------------------------------------------
seed DIVE-110 'gate routing bug report' dive-3224-inbox
OUT=$(file_gate DIVE-110 dev --type=approval --tier=2 --ask="$ASK_MISS")
[[ -z "$(reviewerof DIVE-110)" ]] \
  && ok_t "C1 explicit --tier=2 still vetoes the route (DIVE-1957)" \
  || bad_t "C1 --tier=2 must not route" "routed_reviewer='$(reviewerof DIVE-110)'"

seed DIVE-111 'gate routing bug report' dive-3224-inbox
OUT=$(file_gate DIVE-111 dev --type=approval --ask="Push the branch and approve the \$900 vercel invoice?")
[[ -z "$(reviewerof DIVE-111)" ]] \
  && ok_t "C2 the T2 category floor still wins on a bound row (money)" \
  || bad_t "C2 floored gate must not route" "routed_reviewer='$(reviewerof DIVE-111)'; out=$OUT"
[[ "$(tierof DIVE-111)" == "2" ]] \
  && ok_t "C2 and it is still floored to tier 2" \
  || bad_t "C2 tier must be 2" "got '$(tierof DIVE-111)'"

seed DIVE-112 'gate routing bug report' dive-3224-inbox
OUT=$(file_gate DIVE-112 dev --type=approval --ask="$ASK_MISS" --needs=human_tap)
[[ -z "$(reviewerof DIVE-112)" ]] \
  && ok_t "C3 a declared human-class capability still wins (DIVE-2241)" \
  || bad_t "C3 human-class must not route" "routed_reviewer='$(reviewerof DIVE-112)'; out=$OUT"

seed DIVE-113 'gate routing bug report' dive-3224-inbox
OUT=$(file_gate DIVE-113 dev --type=secret --ask="$ASK_MISS" --secret-key=DEPLOY_KEY --connector=fixture)
[[ -z "$(reviewerof DIVE-113)" ]] \
  && ok_t "C4 secret is human-only by type on a bound row too" \
  || bad_t "C4 secret must not route" "routed_reviewer='$(reviewerof DIVE-113)'"

# The root of the chart has no lead, so a bound row cannot manufacture one.
seed DIVE-114 'gate routing bug report' dive-3224-inbox
OUT=$(file_gate DIVE-114 main --type=approval --ask="$ASK_MISS")
[[ -z "$(reviewerof DIVE-114)" ]] \
  && ok_t "C5 a filer with no lead still falls through to the human" \
  || bad_t "C5 root filer must not route" "routed_reviewer='$(reviewerof DIVE-114)'"

# A body that merely TALKS about a branch is not a binding. This is the whole
# distinction the ticket rests on: structured state, not prose that mentions one.
db "INSERT INTO tasks(ident,title,status,created_by,body) VALUES('DIVE-115','gate routing bug report','todo','main',$(sqlq 'I pushed everything to the branch dive-3224-inbox earlier today.'));"
OUT=$(file_gate DIVE-115 dev --type=approval --tier=1 --ask="$ASK_MISS")
[[ -z "$(reviewerof DIVE-115)" ]] \
  && ok_t "C6 prose MENTIONING a branch is not a binding (no 'Branch:' line → no route)" \
  || bad_t "C6 a prose mention must not route" "routed_reviewer='$(reviewerof DIVE-115)'; out=$OUT"

# ---------------------------------------------------------------------------
# D. TRIGGER ORDERING. When both apply, eng-ship keeps the name — every receipt
#    that exists today is unchanged, and `row-ship-state` appears only where the
#    prose classifier came up empty.
# ---------------------------------------------------------------------------
seed DIVE-120 'gate routing bug report' dive-3224-inbox
OUT=$(file_gate DIVE-120 dev --type=approval --ask="Push-for-review: land the branch and open a pull request?")
[[ "$(reviewerof DIVE-120)" == "main" ]] \
  && ok_t "D1 an eng-ship ask on a bound row still routes" \
  || bad_t "D1 must route" "routed_reviewer='$(reviewerof DIVE-120)'; out=$OUT"
[[ "$OUT" == *"eng-ship"* && "$OUT" != *"row-ship-state"* ]] \
  && ok_t "D1 the trigger stays 'eng-ship' (existing receipts byte-for-byte)" \
  || bad_t "D1 eng-ship must win the trigger name" "out=$OUT"

# ---------------------------------------------------------------------------
# E. THE UNROUTED RECEIPT IS LEGIBLE. Four causes, four distinguishable reasons.
#    The bug was not that the receipt was WRONG — it is that a reader cannot see
#    an absent clause, so "routed" and "landed on the founder" looked the same.
# ---------------------------------------------------------------------------
seed DIVE-130 'gate routing bug report'
OUT=$(file_gate DIVE-130 dev --type=approval --tier=1 --ask="$ASK_MISS")
[[ "$OUT" == *"NOT ROUTED"* && "$OUT" == *"PAIRED HUMAN"* ]] \
  && ok_t "E1 the unrouted receipt says NOT ROUTED and names who it lands on" \
  || bad_t "E1 unrouted receipt must be explicit" "out=$OUT"
[[ "$OUT" == *"no routing kind matched"* && "$OUT" == *"main was never considered"* ]] \
  && ok_t "E1 it names the cause (no kind matched) and the lead that was skipped" \
  || bad_t "E1 must name the skipped lead" "out=$OUT"
[[ "$OUT" == *"set-branch"* ]] \
  && ok_t "E1 it names the remedy that removes the class, not just a re-wording" \
  || bad_t "E1 must offer the binding remedy" "out=$OUT"

seed DIVE-131 'gate routing bug report'
OUT=$(file_gate DIVE-131 main --type=approval --ask="$ASK_MISS")
[[ "$OUT" == *"NOT ROUTED"* && "$OUT" == *"resolves no lead above main"* ]] \
  && ok_t "E2 the no-lead cause is reported distinctly (opposite remedy)" \
  || bad_t "E2 no-lead cause must be distinct" "out=$OUT"
[[ "$OUT" != *"no routing kind matched"* ]] \
  && ok_t "E2 and it does NOT tell the root to re-word (that would not help)" \
  || bad_t "E2 must not offer the re-word remedy to the root" "out=$OUT"

seed DIVE-132 'gate routing bug report'
OUT=$(file_gate DIVE-132 dev --type=approval --ask="approve the \$5000 ad spend budget?")
[[ "$OUT" == *"NOT ROUTED"* && "$OUT" == *"T2 category floor"* ]] \
  && ok_t "E3 a floored gate says so (human-only by class, not an accident)" \
  || bad_t "E3 floored cause must be named" "out=$OUT"

seed DIVE-133 'gate routing bug report'
OUT=$(file_gate DIVE-133 dev --type=approval --tier=2 --ask="make the final go/no-go call?")
[[ "$OUT" == *"NOT ROUTED"* && "$OUT" == *"--tier=2"* ]] \
  && ok_t "E4 an explicitly pinned gate says the pin is why" \
  || bad_t "E4 tier-2 pin cause must be named" "out=$OUT"

# The routed arm must NOT gain the note — a routed gate is not on the human.
seed DIVE-134 'gate routing bug report' dive-3224-inbox
OUT=$(file_gate DIVE-134 dev --type=approval --tier=1 --ask="$ASK_MISS")
[[ "$OUT" != *"NOT ROUTED"* ]] \
  && ok_t "E5 a ROUTED gate carries no NOT-ROUTED note" \
  || bad_t "E5 routed gate must not claim it landed on the human" "out=$OUT"

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
