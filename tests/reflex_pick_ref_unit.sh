#!/usr/bin/env bash
# DIVE-4929 — `5dive reflex pick-ref`: reflex drafts ONE recipe step by picking a
# ref out of a `browser snapshot` tree, in SHADOW. The code decides which
# elements are legal for the op; the model only picks; nothing is written.
#
# WHAT THIS GRADES
#  P1. The legal set. A fill is offered only text-entry roles, a click only
#      clickable ones. Nodes with no name, an over-long name, or no ref are never
#      offered, and a duplicate ref is offered once.
#  P2. The step. fake:first proposes {op, selector: "ref=<picked ref>"} with the
#      op's own argument (value / key / path), in the adapter step shape.
#  P3. Fail closed. A key that is not an option, a hang past --timeout, or no
#      answer proposes no step.
#  P4. What leaves the box: the site, the op, the intent, and each candidate's
#      role, name and ref. Not the tree's url or title, and not the non-candidates.
#  P5. review_required on a click whose intent or target sends or publishes; never
#      on a fill.
#  P6. The receipt: decision.browser-recipe-step, mode=shadow, a ref HASH, and no
#      names or intent text. `reflex log --policy=browser-recipe-step` lists it.
#  P7. Usage: fill without --value, press without --key, goto (takes a URL, not a
#      ref), and a file that is not a snapshot tree are all refused.
#  M.  Mutant: drop the role filter, and P1 goes red (with an unmutated control).
#
# Throwaway STATE_DIR and fake backends only: no root, no network, no key.
# Run: bash tests/reflex_pick_ref_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/reflex-pick-ref-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/reflex.sh \
         cmd_task.sh cmd_reflex.sh cmd_reflex_login_marker.sh cmd_reflex_pick_ref.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
JSON_MODE=0
audit_log() { return 0; }

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$STATE_DIR/agents.json"; BOX_CONFIG="$STATE_DIR/box.json"
mkdir -p "$TASKS_DIR"; printf '{"agents":{"main":{},"dev":{}}}\n' >"$REGISTRY"; printf '{}\n' >"$BOX_CONFIG"
tasks_db_init >/dev/null 2>&1
db() { sqlite3 "$TASKS_DB" "$1"; }

TREE="$TMP/tree.json"
LONG=$(printf 'x%.0s' $(seq 1 90))
cat >"$TREE" <<JSON
{"url":"https://example.test/compose-SECRETURL","title":"TREETITLE Compose","nodes":[
 {"ref":"link/Home","role":"link","name":"Home","tag":"a"},
 {"ref":"textbox/To","role":"textbox","name":"To","tag":"input"},
 {"ref":"textbox/Message","role":"textbox","name":"Message","tag":"textarea"},
 {"ref":"searchbox/Search","role":"searchbox","name":"Search","tag":"input"},
 {"ref":"button/Send","role":"button","name":"Send","tag":"button"},
 {"ref":"button/Send","role":"button","name":"Send","tag":"button"},
 {"ref":"heading/HEADINGTEXT","role":"heading","name":"HEADINGTEXT","tag":"h1"},
 {"ref":"link/","role":"link","name":"","tag":"a"},
 {"ref":"textbox/$LONG","role":"textbox","name":"$LONG","tag":"input"},
 {"role":"button","name":"NOREF","tag":"button"}]}
JSON

pr()  { ( JSON_MODE=0; FIVEDIVE_REFLEX_RECEIPTS=0 _reflex_pick_ref "$@" ) 2>"$TMP/err"; }
prj() { pr "$@" --json; }

# ── P1: the legal set ────────────────────────────────────────────────────────
p1_arm() {
  local f c
  f=$(prj example.test --tree="$TREE" --op=fill --value='{body}' --intent="type the body" --backend=fake:first) || return 1
  c=$(prj example.test --tree="$TREE" --op=click --intent="go home" --backend=fake:first) || return 1
  jq -e '[.candidates[].ref] == ["textbox/To","textbox/Message","searchbox/Search"]' <<<"$f" >/dev/null || return 1
  jq -e '[.candidates[].ref] == ["link/Home","button/Send"]' <<<"$c" >/dev/null
}
p1_arm; check "P1 fill offers only text-entry roles, click only clickable ones; no-name, long-name, no-ref and duplicate nodes are never offered" $?

# ── P2: the step ─────────────────────────────────────────────────────────────
R2=$(prj example.test --tree="$TREE" --op=fill --value='{body}' --intent="type the body" --backend=fake:first)
jq -e '.choice == "r1" and .step == {op: "fill", selector: "ref=textbox/To", value: "{body}"} and .written == false and .mode == "shadow"' <<<"$R2" >/dev/null
check "P2 fake:first proposes the adapter step shape, selector ref=<picked ref>, with the value" $? "$R2"
R2=$(prj example.test --tree="$TREE" --op=press --key=Enter --intent="submit the search" --backend='jq -c "{choice: \"r4\", confidence: 0.8}"')
jq -e '.step == {op: "press", selector: "ref=searchbox/Search", key: "Enter"} and .confidence == 0.8' <<<"$R2" >/dev/null
check "P2 a press step carries its key, and a backend's pick and confidence come through" $? "$R2"

# ── P3: fail closed ──────────────────────────────────────────────────────────
R3=$(prj example.test --tree="$TREE" --op=click --intent="x" --backend='echo "{\"choice\":\"r99\"}"')
jq -e '.choice == "none" and .error == "invalid_choice" and .step == null' <<<"$R3" >/dev/null
check "P3 a key that is not an option proposes no step" $?
t0=$(date +%s); R3=$(prj example.test --tree="$TREE" --op=click --intent="x" --backend='sleep 30' --timeout=1); t1=$(date +%s)
jq -e '.error == "timeout" and .step == null' <<<"$R3" >/dev/null && (( t1 - t0 < 10 ))
check "P3 a hang is cut off at --timeout and proposes no step" $?
R3=$(prj example.test --tree="$TREE" --op=select --value=a --intent="pick a country" --backend=fake:first)
jq -e '.error == "no_candidates" and .step == null and (.candidates | length) == 0' <<<"$R3" >/dev/null
check "P3 no element can take the op: nothing is asked and no step is proposed" $?

# ── P4: what leaves the box ──────────────────────────────────────────────────
export RX_REQ_LOG="$TMP/req.jsonl"; : >"$RX_REQ_LOG"
pr example.test --tree="$TREE" --op=click --intent="INTENTTEXT go home" --backend='tee -a "$RX_REQ_LOG" | jq -c "{choice: .options[0]}"' >/dev/null
jq -e '.state == {site: "example.test", op: "click", intent: "INTENTTEXT go home"}
       and .options == ["r1","r2","none"] and (.criteria.r1 | test("link \"Home\"")) and (.criteria.r2 | test("ref=button/Send"))' "$RX_REQ_LOG" >/dev/null \
  && ! grep -qE 'SECRETURL|TREETITLE|HEADINGTEXT|NOREF|textbox/To' "$RX_REQ_LOG"
check "P4 the request carries the intent and the candidates only, not the tree's url/title or non-candidates" $? "$(cat "$RX_REQ_LOG")"

# ── P5: review_required ──────────────────────────────────────────────────────
R5a=$(prj example.test --tree="$TREE" --op=click --intent="go home" --backend='jq -c "{choice: \"r2\"}"')
R5b=$(prj example.test --tree="$TREE" --op=click --intent="go home" --backend=fake:first)
R5c=$(prj example.test --tree="$TREE" --op=fill --value=x --intent="type the message to send" --backend=fake:first)
jq -e '.review_required == true' <<<"$R5a" >/dev/null && jq -e '.review_required == false' <<<"$R5b" >/dev/null \
  && jq -e '.review_required == false' <<<"$R5c" >/dev/null
check "P5 a click on Send needs review; a click on Home does not; a fill never does" $?
grep -q 'REVIEW REQUIRED' <<<"$(pr example.test --tree="$TREE" --op=click --intent="send it" --backend='jq -c "{choice: \"r2\"}"')"
check "P5 the human report says REVIEW REQUIRED" $?

# ── P6: the receipt ──────────────────────────────────────────────────────────
( JSON_MODE=0; _reflex_pick_ref example.test --tree="$TREE" --op=click --intent="INTENTTEXT send" --backend='jq -c "{choice: \"r2\", confidence: 0.7}"' ) >/dev/null 2>&1
RC6=$(db "SELECT detail FROM lifecycle_events WHERE kind='decision.browser-recipe-step' ORDER BY id DESC LIMIT 1;")
jq -e '.mode == "shadow" and .result == "r2" and .confidence == 0.7 and .effect.acted == false and .effect.written == false
       and (.effect.ref_hash | test("^sha256:[0-9a-f]{16}$")) and .effect.review_required == true
       and .signals == {site: "example.test", op: "click", n_candidates: 2}' <<<"$RC6" >/dev/null \
  && ! grep -qE 'INTENTTEXT|Send|Home' <<<"$RC6"
check "P6 a shadow receipt with a ref hash and no names or intent text" $? "$RC6"
LOG=$( ( JSON_MODE=0; _reflex_log --policy=browser-recipe-step ) 2>&1 ); rc=$?
(( rc == 0 )) && grep -q 'browser-recipe-step' <<<"$LOG"
check "P6 reflex log --policy=browser-recipe-step lists it" $? "$LOG"

# ── P7: usage ────────────────────────────────────────────────────────────────
pr example.test --tree="$TREE" --op=fill --intent=x --backend=fake:first >/dev/null; r1=$?
pr example.test --tree="$TREE" --op=press --intent=x --backend=fake:first >/dev/null; r2=$?
pr example.test --tree="$TREE" --op=goto --intent=x --backend=fake:first >/dev/null; r3=$?
printf '{"nope":1}\n' >"$TMP/bad.json"
pr example.test --tree="$TMP/bad.json" --op=click --intent=x --backend=fake:first >/dev/null; r4=$?
(( r1 == E_USAGE && r2 == E_USAGE && r3 == E_VALIDATION && r4 == E_VALIDATION ))
check "P7 fill without --value, press without --key, goto, and a non-tree file are refused" $? "$r1 $r2 $r3 $r4"
( FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/nokey" pr example.test --tree="$TREE" --op=click --intent=x >/dev/null ); rc=$?
(( rc == E_PERMISSION )) && grep -q 'sudo' "$TMP/err"
check "P7 the built-in backend with no readable key refuses and names sudo" $?

# ── M: mutant ────────────────────────────────────────────────────────────────
MUT="$TMP/mut.sh"
sed 's/^        | select((.role \/\/ "") as \$x | \$r | index(\[\$x\]) != null)$/        | select(true)/' "$SRC/cmd_reflex_pick_ref.sh" >"$MUT"
if cmp -s "$MUT" "$SRC/cmd_reflex_pick_ref.sh"; then bad_t "M the mutant did not apply"; else
  ( source "$MUT"; p1_arm ); MRC=$?
  check "M with the role filter dropped, P1 goes RED" "$(( MRC != 0 ? 0 : 1 ))"
fi
( p1_arm ); check "M control: the unmutated source stays green on P1" $?

echo
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
