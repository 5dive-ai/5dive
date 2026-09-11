#!/usr/bin/env bash
# DIVE-4001 isolated unit harness for the PRICE CONTEXT REQUIREMENT and the
# PRICE APPEAL PATH on the tier-2 category floor
# (src/task/need.sh _gate_redact_bare_price / _gate_tier2_floor_hit /
#  _gate_tier2_floor_term / _GATE_FLOOR_APPEALABLE_RX).
#
# THE DEFECT, measured 2026-09-06. The floor is a bare case-insensitive substring
# match over ask and title, so `price` cannot tell "approve this spend" from "a
# price is missing from our public pricing board". We SHIP a pricing product, so
# every row about /models or /tokenmaxxing floored — DIVE-4000 floored by TITLE,
# which a filer cannot word around without mistitling their own ticket, and
# `price|pricing` sat on the NON-APPEALABLE list while `token` and `secret` did
# not, so the escalation was permanent. It reached the paired human with no agent
# able to clear it, twice in 70 minutes.
#
# THE POSTURE IS UNCHANGED AND T2/T3 ARE WHY. DIVE-891's bias toward false
# positives stays: this row does not remove a term from the floor. T2 asserts
# every OTHER money term still fires BARE, and T3 asserts a real spend ask still
# floors and is still refused an appeal. A "fix" that deleted `price` from the
# floor, or that carved the money class into the appealable half, goes red there.
#
# MUTATION GRADE:
#   * delete the `_gate_redact_bare_price` call from _gate_tier2_floor_hit -> T1 red.
#   * delete it from _gate_tier2_floor_term only -> T4 red (the reported term must
#     never name a word the floor itself no longer matches).
#   * drop the spend-signal test from _gate_redact_bare_price (redact always) -> T3 red.
#   * put `price|pricing` back on _GATE_FLOOR_NONAPPEALABLE_RX / take it off the
#     appealable half -> T5 red.
#   * drop the `$floor_rx == $_GATE_T2_FLOOR_RX` guard -> T6 red (a sealed
#     constitution's own `price` term is enforced verbatim, unqualified).
#
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR —
# the live shared tasks.db is NEVER touched. Run:
#   bash tests/gate_price_spend_signal_unit.sh    (no root, no network)
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in the tempdir cleanup so the two EXIT traps don't clobber each other.

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-price-signal-unit.XXXXXX)"

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

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
clean_t() {   # <label> <text>  — must NOT floor
  _gate_tier2_floor_hit "$2" \
    && bad_t "$1" "still floors on '$(_gate_tier2_floor_term "$2")': $2" \
    || ok_t "$1"
}
floor_t() {   # <label> <text>  — must floor
  _gate_tier2_floor_hit "$2" \
    && ok_t "$1 (term '$(_gate_tier2_floor_term "$2")')" \
    || bad_t "$1" "no longer floors: $2"
}

# --- T1: THE REPORTED FALSE POSITIVES. Both are verbatim from 2026-09-06 —
#     DIVE-4000's ask (an inert push-for-review approval) and its TITLE, the axis
#     a filer cannot re-word around. Neither names a spend. ------------------
clean_t "T1 DIVE-4000 ask: a missing price on the public models board does not floor" \
  "Approve delegated push for review of branch dive-4000 (5dive-frontend). A model on the public models board shows no price at all; this fills it in"
clean_t "T1 DIVE-4000 title: 'renders with no price on /models' does not floor" \
  "Qwen3.8 Max renders with no price on /models — the catalog join misses a dated permaslug"
clean_t "T1 our own pricing surface: a render bug on the pricing table does not floor" \
  "the pricing table renders a stale value for one row"
clean_t "T1 'prices' inflection is covered by the same redaction" \
  "the board shows no prices for three models"
clean_t "T1 a null price COLUMN is a datum, not a deal" \
  "the price column on the models board is null for three rows"

# --- T2: EVERY OTHER MONEY TERM STILL FIRES BARE. This is the arm that fails
#     against the tempting wrong fix (delete `price` from the floor, or make the
#     whole money class contextual). None of these carries the word price. -----
floor_t "T2 a currency figure still floors bare"          'approve $500 for the ads campaign'
floor_t "T2 'invoice' still floors bare"                  "approve the vendor invoice"
floor_t "T2 'billing' still floors bare"                  "switch the billing account over"
floor_t "T2 'charge' still floors bare"                   "charge the customer for the overage"
floor_t "T2 'payment' still floors bare"                  "release the payment to the contractor"
floor_t "T2 'subscription' still floors bare"             "cancel the subscription"
floor_t "T2 'spend' still floors bare"                    "authorise the extra spend"
floor_t "T2 'refund' still floors bare"                   "issue the refund"
floor_t "T2 the secret class is untouched"                "rotate the stripe api key"
floor_t "T2 the destructive class is untouched"           "delete the production database"

# --- T3: THE TRUE POSITIVES FOR `price` ITSELF. A spend signal anywhere in the
#     field re-enables the bare noun. The price-CHANGE verbs are in the signal
#     list on purpose: "should we raise prices" names no currency figure and is
#     exactly the commercial call that must still reach a person. -------------
floor_t "T3 a price with a currency figure floors"        'raise the price of the pro plan to $49'
floor_t "T3 a price-change ask with no figure floors"     "should we raise prices on the pro plan"
floor_t "T3 'lower our pricing' floors"                   "lower our pricing for the annual tier"
floor_t "T3 a purchase near a price floors"               "buy the add-on, the price is 200 eur"
floor_t "T3 an upgrade near a price floors"               "upgrade our plan at the listed price"
floor_t "T3 'what should we charge' floors (on charge, independently)" \
  "what price should we charge for the pro plan"
# T3b: the COMMERCIAL OBJECT arm. These name no money verb and no currency
# figure — "approve the new plan price" is an approval of a commercial number and
# must still reach a person. Found by asking what a real spend ask can say using
# ONLY the bare noun; the answer is that it names what the price is FOR.
floor_t "T3b 'approve the new plan price' floors"        "approve the new plan price"
floor_t "T3b 'sign off on the enterprise price' floors"  "sign off on the enterprise price"
floor_t "T3b a price against a pro tier floors"          "approve the price for the pro tier"
floor_t "T3b a price on a customer contract floors"      "approve the price on the customer contract"

# --- T4: THE REPORTING HELPER TRACKS THE MATCHER. _gate_tier2_floor_term must
#     never name a term the floor no longer matches (the DIVE-2629 invariant),
#     and must still name `price` when the context DOES arm it. ---------------
_t4=$(_gate_tier2_floor_term "Qwen3.8 Max renders with no price on /models" 2>/dev/null)
[[ -z "$_t4" ]] \
  && ok_t "T4 floor_term reports nothing for a redacted bare price" \
  || bad_t "T4 floor_term/floor_hit drift" "hit=no but term='$_t4'"
_t4b=$(_gate_tier2_floor_term "should we raise prices on the pro plan" 2>/dev/null)
[[ "$_t4b" == "price" ]] \
  && ok_t "T4 floor_term still reports 'price' when a spend signal arms it" \
  || bad_t "T4 floor_term on an armed price" "expected 'price', got '$_t4b'"

# --- T5: THE APPEAL PATH. `price|pricing` moved to the APPEALABLE half, so a
#     floored DESIGN decision can be appealed exactly as a `token` one can. The
#     money core is NOT carved out with it — the residual re-test still refuses
#     an appeal on spend/refund/$-figure. -------------------------------------
appeal_t() {   # <label> <text> <allow|refuse>
  local r; r=$(_gate_floor_appeal_residual "$2")
  if _gate_tier2_floor_hit "$r"; then
    [[ "$3" == refuse ]] && ok_t "$1" || bad_t "$1" "appeal REFUSED, residual '$r' hits '$(_gate_tier2_floor_term "$r")'"
  else
    [[ "$3" == allow ]] && ok_t "$1" || bad_t "$1" "appeal ALLOWED, residual '$r' no longer hits"
  fi
}
# The arm that discriminates: this one FLOORS (the price-change verb arms the
# noun) and is nonetheless appealable, which is the whole point of the move — a
# floored commercial-vocabulary DECISION gets a lead, not a permanent human gate.
appeal_t "T5 a floored repricing discussion can now be appealed" \
  "should we raise prices on the pro plan" allow
appeal_t "T5 a pricing design discussion can now be appealed" \
  "should we change our pricing tiers" allow
appeal_t "T5 a price discussion can be appealed, like a token one" \
  "the price column on the models board" allow
appeal_t "T5 a token discussion still appeals (unchanged control)" \
  "the telegram bot token in the template" allow
appeal_t "T5 REAL SPEND is still refused an appeal ('spend')" \
  "approve the extra spend on ads" refuse
appeal_t "T5 REAL SPEND is still refused an appeal (currency figure)" \
  'approve $500 and change the price' refuse
appeal_t "T5 a refund decision is still refused an appeal" \
  "should we refund these customers and change the price" refuse
# The invariant the subtraction rests on, re-asserted for the two new terms:
# no APPEALABLE term may be a substring of a NON-APPEALABLE one.
_viol=""
IFS='|' read -r -a _app <<< "$_GATE_FLOOR_APPEALABLE_RX"
IFS='|' read -r -a _non <<< "$_GATE_FLOOR_NONAPPEALABLE_RX"
for a in "${_app[@]}"; do
  [[ "$a" =~ ^[a-z\ ]+$ ]] || continue
  for n in "${_non[@]}"; do
    [[ "$n" =~ ^[a-z\ ]+$ ]] || continue
    [[ "$n" == *"$a"* ]] && _viol="${_viol} '${a}' inside '${n}';"
  done
done
[[ -z "$_viol" ]] \
  && ok_t "T5 appealable/non-appealable substring invariant still holds after the move" \
  || bad_t "T5 substring invariant" "violations:${_viol}"
[[ "$_GATE_FLOOR_NONAPPEALABLE_RX" != *"price"* ]] \
  && ok_t "T5 price is off the non-appealable half" \
  || bad_t "T5 price still non-appealable" "$_GATE_FLOOR_NONAPPEALABLE_RX"

# --- T6: A SEALED CONSTITUTION'S OWN `price` IS ENFORCED VERBATIM. The context
#     requirement is OURS, not an org's. When the policy regex has been replaced
#     wholesale (DIVE-1695/2301), the loaded terms are matched unqualified —
#     otherwise this change would silently weaken a hard class an org sealed. --
printf 'hard_gates: {}\n' > "$TMP/constitution.yaml"
_council_constitution_path() { printf '%s' "$TMP/constitution.yaml"; }
_council_hard_gate_rx()      { printf 'price|press'; }
floor_t "T6 a constitution-loaded 'price' floors with NO spend signal" \
  "the board shows no price for that model"
unset -f _council_constitution_path _council_hard_gate_rx
clean_t "T6 and the shipped default is contextual again once the policy is gone" \
  "the board shows no price for that model"

# --- T7: END TO END through cmd_task_need — the tier the filer actually gets.
#     T1..T6 grade the helpers; this grades the decision, on BOTH axes (ask and
#     title), because DIVE-4000 floored by TITLE. ------------------------------
db "INSERT INTO tasks (ident, title, status, created_by) VALUES
     ('DIVE-4090','Qwen3.8 Max renders with no price on /models','todo','main');"
( cmd_task_need DIVE-4090 --type=approval \
  --ask="Approve delegated push for review of branch dive-4090 (5dive-frontend). A model on the public models board shows no price at all; this fills it in" \
  --recommend="approve" ) >/dev/null 2>&1
_tier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-4090';")
_prov=$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='DIVE-4090';")
[[ "$_tier" != "2" ]] \
  && ok_t "T7 e2e: DIVE-4000 replayed is NOT floored to tier 2 (tier $_tier, $_prov)" \
  || bad_t "T7 e2e price no longer floors" "got tier 2, provenance '$_prov'"

db "INSERT INTO tasks (ident, title, status, created_by) VALUES
     ('DIVE-4091','pro plan repricing','todo','main');"
# DIVE-4175 arm C: this suite's subject is the price/spend SIGNAL — whether the
# predicate can tell a commercial call from a row about /models. That question is
# untouched: `floor_provenance` still records the axis and the term. What the tier
# can no longer show is whether the signal REACHED a person, so the two halves are
# now asserted separately — the signal off the stamp, the reach off the declaration.
( cmd_task_need DIVE-4091 --type=decision --ask="should we raise prices on the pro plan" \
  --options="A|B" --recommend="A" ) >/dev/null 2>&1
_prov=$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='DIVE-4091';")
[[ "$_prov" == axis=ask* ]] \
  && ok_t "T7 e2e: a real repricing decision is still DETECTED as a price call ($_prov)" \
  || bad_t "T7 e2e repricing floor" "got provenance '$_prov' — a commercial price call stopped being detected at all"
db "INSERT INTO tasks (ident, title, status, created_by) VALUES
     ('DIVE-4095','pro plan repricing','todo','main');"
( cmd_task_need DIVE-4095 --type=decision --needs=spend_authority --ask="should we raise prices on the pro plan" \
  --options="A|B" --recommend="A" ) >/dev/null 2>&1
[[ "$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-4095';")" == "2" ]] \
  && ok_t "T7 e2e: a DECLARED repricing decision reaches a person (tier 2)" \
  || bad_t "T7 e2e repricing declared" "got tier $(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-4095';")"

db "INSERT INTO tasks (ident, title, status, created_by) VALUES
     ('DIVE-4092','ads budget','todo','main');"
( cmd_task_need DIVE-4092 --type=decision --ask='approve $500 for the ads campaign' \
  --options="A|B" --recommend="A" ) >/dev/null 2>&1
_prov=$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='DIVE-4092';")
[[ "$_prov" == axis=ask* ]] \
  && ok_t "T7 e2e: a real spend is still DETECTED (negative control, $_prov)" \
  || bad_t "T7 e2e spend floor" "got provenance '$_prov'"

db "INSERT INTO tasks (ident, title, status, created_by) VALUES
     ('DIVE-4093','key rotation','todo','main');"
( cmd_task_need DIVE-4093 --type=secret --ask="provision the stripe api key" \
  --secret-key=STRIPE_KEY --connector=env ) >/dev/null 2>&1
_tier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-4093';")
[[ "$_tier" == "2" ]] \
  && ok_t "T7 e2e: a credential provision still floors to tier 2 (negative control)" \
  || bad_t "T7 e2e secret floor" "got tier '$_tier' (empty = the gate never filed)"

printf '\n%s\n' "-------- gate price spend signal (DIVE-4001): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
