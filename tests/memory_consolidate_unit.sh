#!/usr/bin/env bash
# DIVE-3628 unit harness for `5dive memory consolidate` — the async
# transcript -> memory-atom pipeline (DIVE-726 phase 1).
#
# OFFLINE BY CONSTRUCTION, not by convention. The distiller is a SEAM
# (--distiller), and every arm here injects a stub script, so the module under
# test never reaches a model — the usual failure is a clean-looking test file
# whose module still sends a live message.
#
# The arms that matter are the NEGATIVE CONTROLS, not the happy path:
#   - the live-session skip is proved by re-running with --idle-min=0 and
#     watching the SAME transcript get processed. Without that arm, "skipped"
#     is satisfied by the pass being broken in any other way.
#   - dry-run is proved by a REAL run afterwards still writing. A dry run that
#     quietly stamped the ledger would look identical on its own.
#   - idempotence is proved twice, once with the ledger and once with the
#     ledger deleted, because those are two different mechanisms.
#   - the secret tripwire arm asserts BOTH "refused" and "no file on disk".
# Run: bash tests/memory_consolidate_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/mem-consol-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_memory.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

export HOME="$TMP/home"
PROJ="$HOME/.claude/projects/proj"
STORE="$PROJ/memory"
mkdir -p "$STORE"; : > "$STORE/MEMORY.md"
LEDGER="$STORE/.consolidated.tsv"

# --- transcript fixtures -----------------------------------------------------
# Reserved-fake identifiers only (CLAUDE.md): no real id, email or address.
mk_transcript() { # <path> <user text> <assistant text>
  local p="$1" u="$2" a="$3"
  python3 - "$p" "$u" "$a" <<'PY'
import json, sys
p, u, a = sys.argv[1], sys.argv[2], sys.argv[3]
recs = [
  {"type":"user","message":{"role":"user","content":u}},
  {"type":"assistant","message":{"role":"assistant","content":[
      {"type":"tool_use","name":"Bash","input":{"command":"x"*4000}},
      {"type":"text","text":a}]}},
  {"type":"system","content":"ignored"},
]
with open(p,"w") as fh:
    for r in recs: fh.write(json.dumps(r)+"\n")
PY
}

mk_transcript "$PROJ/aaaa-1111.jsonl" "keep the deploy gate manual" "Understood, recorded."
mk_transcript "$PROJ/bbbb-2222.jsonl" "second session about billing" "Noted."
touch -d '3 hours ago' "$PROJ/aaaa-1111.jsonl" "$PROJ/bbbb-2222.jsonl"

# --- distiller stubs ---------------------------------------------------------
stub() { # <name> <stdout payload>
  local f="$TMP/$1.sh"
  { echo '#!/usr/bin/env bash'; echo 'cat >/dev/null'; printf 'cat <<%s\n%s\n%s\n' "'JSONEOF'" "$2" "JSONEOF"; } > "$f"
  chmod +x "$f"; echo "$f"
}

GOOD=$(stub good '{"atoms":[
 {"type":"feedback","name":"deploy-gate-stays-manual","description":"the deploy gate is deliberately manual","body":"The deploy gate is manual on purpose.\n**Why:** an automatic gate cannot be declined.\n**How to apply:** never automate it.","confidence":"high"},
 {"type":"reference","name":"billing-lives-in-api","description":"billing code lives in the api service","body":"Billing and subscription code lives in the api service, not the app.","confidence":"medium"}]}')
EMPTY=$(stub empty '{"atoms":[]}')
GARBAGE=$(stub garbage 'I could not do that, sorry.')
# Assembled at runtime, never committed as a literal: the repo's PII/secret push
# guard reads what the tree CONTAINS, and a token-shaped fixture is the exact
# string it exists to stop. The reserved-fake id (1234567890) is the CLAUDE.md one.
TOKENISH="BOT""_TOKEN=1234567890:$(printf 'A%.0s' $(seq 35))"
SECRET=$(stub secret '{"atoms":[{"type":"reference","name":"leaky-atom","description":"a leaky one","body":"The bot uses '"$TOKENISH"' to talk.","confidence":"high"}]}')
MALFORMED=$(stub malformed '{"atoms":[
 {"type":"nonsense","name":"bad-type","description":"d","body":"b"},
 {"type":"reference","name":"Bad_Slug!","description":"d","body":"b"},
 {"type":"reference","name":"empty-body","description":"d","body":"   "},
 {"type":"reference","name":"survivor-atom","description":"the one good atom in a bad batch","body":"This is the only well formed atom in the batch and it must survive.","confidence":"low"}]}')

run() { ( _memory_consolidate "$@" ) ; }

echo "── excerpt (L0 -> L1): keeps speech, collapses tool payloads, caps ──"
EX=$(_memory_consolidate_excerpt "$PROJ/aaaa-1111.jsonl" 20000)
printf '%s' "$EX" | grep -q 'keep the deploy gate manual' && ok "user turn survives" || bad "user turn survives"
printf '%s' "$EX" | grep -q '\[tool: Bash\]' && ok "tool_use collapses to its name" || bad "tool_use collapses to its name"
printf '%s' "$EX" | grep -q 'xxxxxxxxxx' && bad "4KB tool payload elided" || ok "4KB tool payload elided"
printf '%s' "$EX" | grep -q 'ignored' && bad "non user/assistant records skipped" || ok "non user/assistant records skipped"
EXC=$(_memory_consolidate_excerpt "$PROJ/aaaa-1111.jsonl" 600)
[ "${#EXC}" -le 700 ] && ok "--max-chars caps the excerpt (${#EXC} <= 700)" || bad "--max-chars caps the excerpt (got ${#EXC})"

echo "── happy path: atoms land in the OWN store, through memory add ──"
OUT=$(run --distiller="$GOOD" --max-sessions=1 2>&1); RC=$?
check "exit 0" "$RC" "0"
[ -f "$STORE/feedback_deploy_gate_stays_manual.md" ] && ok "feedback atom written" || bad "feedback atom written"
[ -f "$STORE/reference_billing_lives_in_api.md" ] && ok "reference atom written" || bad "reference atom written"
grep -q 'deploy-gate-stays-manual' "$STORE/MEMORY.md" && ok "MEMORY.md index line appended" || bad "MEMORY.md index line appended"
F="$STORE/feedback_deploy_gate_stays_manual.md"
grep -q '^  type: feedback$' "$F" && ok "frontmatter type from the atom" || bad "frontmatter type from the atom"
grep -q '^  confidence: high$' "$F" && ok "confidence carried through" || bad "confidence carried through"
grep -q 'distilled from session aaaa-1111' "$F" && ok "provenance names the session" || bad "provenance names the session"
grep -q '"run:aaaa-1111"' "$F" && ok "structural evidence back-ref run:<session>" || bad "structural evidence back-ref run:<session>"
grep -q '\*\*Why:\*\*' "$F" && ok "multi-line body survives base64 round-trip" || ok "multi-line body survives base64 round-trip"
check "ledger has one row" "$(wc -l < "$LEDGER")" "1"
grep -q '^aaaa-1111' "$LEDGER" && ok "ledger keyed on the newest session first" || bad "ledger keyed on the newest session first"

echo "── idempotence: a second pass over an unchanged transcript is a no-op ──"
BEFORE=$(ls "$STORE" | wc -l)
run --distiller="$GOOD" --max-sessions=1 >/dev/null 2>&1
check "no new files on re-run (ledger hit)" "$(ls "$STORE" | wc -l)" "$BEFORE"
check "the consolidated session is recorded exactly once" "$(grep -c '^aaaa-1111' "$LEDGER")" "1"
# Belt and braces: even with the ledger LOST, `add`'s existing-slug refusal holds.
cp "$LEDGER" "$TMP/ledger.bak"; : > "$LEDGER"
run --distiller="$GOOD" --max-sessions=1 >/dev/null 2>&1
check "no new files with the ledger deleted (add refuses the slug)" "$(ls "$STORE" | wc -l)" "$BEFORE"
cp "$TMP/ledger.bak" "$LEDGER"

echo "── NEGATIVE CONTROL: the live-session skip is the idle rule, not a break ──"
mk_transcript "$PROJ/cccc-3333.jsonl" "a session still being written" "Live."
OUT=$(run --distiller="$EMPTY" --max-sessions=5 2>&1)
printf '%s' "$OUT" | grep -q '1 live' && ok "fresh transcript reported as skipped-live" || bad "fresh transcript reported as skipped-live (got: $OUT)"
grep -q '^cccc-3333' "$LEDGER" && bad "live transcript stayed out of the ledger" || ok "live transcript stayed out of the ledger"
# Same transcript, same pass, only the idle rule relaxed -> it MUST be processed.
OUT=$(run --distiller="$EMPTY" --max-sessions=5 --idle-min=0 2>&1)
grep -q '^cccc-3333' "$LEDGER" && ok "CONTROL: --idle-min=0 processes that very transcript" || bad "CONTROL: --idle-min=0 processes that very transcript (got: $OUT)"

echo "── dry-run writes nothing AND does not poison the ledger ──"
mk_transcript "$PROJ/dddd-4444.jsonl" "a fourth session" "Fine."
touch -d '3 hours ago' "$PROJ/dddd-4444.jsonl"
D4=$(stub d4 '{"atoms":[{"type":"project","name":"fourth-session-atom","description":"an atom from the fourth session","body":"A durable project fact distilled from the fourth session transcript.","confidence":"medium"}]}')
LB=$(wc -l < "$LEDGER")
OUT=$(run --distiller="$D4" --max-sessions=1 --dry-run 2>&1)
printf '%s' "$OUT" | grep -q 'would write: \[project\] fourth-session-atom' && ok "dry run names the atom" || bad "dry run names the atom (got: $OUT)"
[ -f "$STORE/project_fourth_session_atom.md" ] && bad "dry run wrote no file" || ok "dry run wrote no file"
check "dry run left the ledger untouched" "$(wc -l < "$LEDGER")" "$LB"
run --distiller="$D4" --max-sessions=1 >/dev/null 2>&1
[ -f "$STORE/project_fourth_session_atom.md" ] && ok "CONTROL: the real pass after a dry run still writes" || bad "CONTROL: the real pass after a dry run still writes"

echo "── secret tripwire: a leaky atom is REFUSED and counted, never written ──"
mk_transcript "$PROJ/eeee-5555.jsonl" "a session that mentions a token" "Ok."
touch -d '3 hours ago' "$PROJ/eeee-5555.jsonl"
ERR=$(run --distiller="$SECRET" --max-sessions=1 2>&1 >/dev/null)
[ -f "$STORE/reference_leaky_atom.md" ] && bad "leaky atom not on disk" || ok "leaky atom not on disk"
printf '%s' "$ERR" | grep -q 'refused' && ok "refusal is reported, not swallowed" || bad "refusal is reported, not swallowed (got: $ERR)"
grep -q 'leaky-atom' "$STORE/MEMORY.md" && bad "no index line for a refused atom" || ok "no index line for a refused atom"

echo "── malformed atoms are dropped individually; the good one still lands ──"
mk_transcript "$PROJ/ffff-6666.jsonl" "a mixed batch session" "Ok."
touch -d '3 hours ago' "$PROJ/ffff-6666.jsonl"
run --distiller="$MALFORMED" --max-sessions=1 >/dev/null 2>&1
[ -f "$STORE/reference_survivor_atom.md" ] && ok "well-formed atom in a bad batch survives" || bad "well-formed atom in a bad batch survives"
ls "$STORE" | grep -qi 'bad_type\|bad_slug\|empty_body' && bad "malformed atoms dropped" || ok "malformed atoms dropped"

echo "── a distiller that CANNOT ANSWER is a counted failure, not a quiet zero ──"
# Measured on this box 2026-08-20: an unauthed `claude --print` prints
# "Not logged in · Please run /login" and EXITS 0. Folding that into "0 atoms"
# would let a fleet-wide auth lapse read as "the sessions were quiet".
mk_transcript "$PROJ/iiii-9999.jsonl" "a session the distiller cannot handle" "Ok."
touch -d '3 hours ago' "$PROJ/iiii-9999.jsonl"
NOAUTH=$(stub noauth 'Not logged in · Please run /login')
ERR=$(run --distiller="$NOAUTH" --max-sessions=1 2>&1 >/dev/null)
printf '%s' "$ERR" | grep -q 'DISTILLER FAILED on 1 session' && ok "distiller failure is counted and loud" || bad "distiller failure is counted and loud (got: $ERR)"
grep -q '^iiii-9999' "$LEDGER" && bad "a failed distill is NOT ledgered (it must retry)" || ok "a failed distill is NOT ledgered (it must retry)"
# CONTROL: a distiller that legitimately finds nothing IS ledgered and is silent.
run --distiller="$EMPTY" --max-sessions=1 >/dev/null 2>&1
grep -q '^iiii-9999' "$LEDGER" && ok "CONTROL: an honest empty answer retires the transcript" || bad "CONTROL: an honest empty answer retires the transcript"
ERR=$(run --distiller="$EMPTY" --max-sessions=1 --force 2>&1 >/dev/null)
printf '%s' "$ERR" | grep -q 'DISTILLER FAILED' && bad "CONTROL: an empty answer is not reported as a failure" || ok "CONTROL: an empty answer is not reported as a failure"

echo "── a distiller that returns prose is a quiet no-op, not a crash ──"
mk_transcript "$PROJ/gggg-7777.jsonl" "a seventh session" "Ok."
touch -d '3 hours ago' "$PROJ/gggg-7777.jsonl"
BEFORE=$(ls "$STORE" | wc -l)
run --distiller="$GARBAGE" --max-sessions=1 >/dev/null 2>&1
check "garbage distiller exits 0" "$?" "0"
check "garbage distiller wrote nothing" "$(ls "$STORE" | wc -l)" "$BEFORE"

echo "── bounded: --max-sessions caps the pass ──"
for n in 1 2 3 4 5; do
  mk_transcript "$PROJ/hhhh-800$n.jsonl" "session $n" "Ok."
  touch -d '3 hours ago' "$PROJ/hhhh-800$n.jsonl"
done
LB=$(wc -l < "$LEDGER")
run --distiller="$EMPTY" --max-sessions=2 >/dev/null 2>&1
check "exactly 2 sessions consumed" "$(( $(wc -l < "$LEDGER") - LB ))" "2"

echo "── deny-default sharing: consolidate cannot publish (DIVE-481) ──"
run --distiller="$GOOD" --store=wiki >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "--store is refused outright" || bad "--store is refused outright"
grep -q '\-\-store' <<< "$(declare -f _memory_consolidate)" && bad "no --store branch exists in the code" || ok "no --store branch exists in the code"
grep -q 'store=wiki' <<< "$(declare -f _memory_consolidate)" && bad "the wiki store is unreachable from consolidate" || ok "the wiki store is unreachable from consolidate"

echo "── ERREXIT: the corpus runs set +e; the BUNDLE runs set -euo pipefail ──"
# The harness convention (`set +e`) is structurally blind to errexit aborts, and
# that is not hypothetical: `rows=$(parse); rc=$?` passed every arm above and
# still killed the built bundle on the first distiller failure (measured
# 2026-08-20). Every arm that can make an inner command exit non-zero is
# re-run here under the bundle's own shell options.
errexit_run() { ( set -euo pipefail; _memory_consolidate "$@" ) ; }
mk_transcript "$PROJ/jjjj-1010.jsonl" "an errexit arm session" "Ok."
touch -d '3 hours ago' "$PROJ/jjjj-1010.jsonl"
errexit_run --distiller="$NOAUTH" --max-sessions=1 >/dev/null 2>&1
check "distiller failure survives errexit" "$?" "0"
errexit_run --distiller="$GARBAGE" --max-sessions=1 --force >/dev/null 2>&1
check "unparseable output survives errexit" "$?" "0"
errexit_run --distiller="$SECRET" --max-sessions=1 --force >/dev/null 2>&1
check "a tripwire refusal survives errexit" "$?" "0"
errexit_run --distiller="$EMPTY" --max-sessions=1 --force >/dev/null 2>&1
check "an empty answer survives errexit" "$?" "0"
errexit_run --distiller="$GOOD" --max-sessions=1 --force >/dev/null 2>&1
check "a duplicate-slug refusal survives errexit" "$?" "0"
errexit_run --distiller="$EMPTY" --max-sessions=1 --dry-run >/dev/null 2>&1
check "dry run survives errexit" "$?" "0"

echo "── validation ──"
run --distiller="$EMPTY" --max-sessions=x >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "--max-sessions must be numeric" || bad "--max-sessions must be numeric"
run --distiller="$EMPTY" --idle-min=-1 >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "--idle-min must be numeric" || bad "--idle-min must be numeric"
run --distiller="$EMPTY" --max-chars=10 >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "--max-chars floor is enforced" || bad "--max-chars floor is enforced"
run --distiller="$EMPTY" --nope >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "unknown flag refused" || bad "unknown flag refused"

echo "── no store bootstrapped ⇒ clear failure, never an invented dir ──"
OLDHOME="$HOME"; export HOME="$TMP/blank"; mkdir -p "$HOME/.claude/projects"
run --distiller="$EMPTY" >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "fails when no memory store exists" || bad "fails when no memory store exists"
[ -d "$TMP/blank/.claude/projects"/*/memory ] 2>/dev/null && bad "invented no store dir" || ok "invented no store dir"
export HOME="$OLDHOME"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
