#!/usr/bin/env bash
# DIVE-3903: `5dive a2a rounds` — the read-only JSON view over the a2a round
# ledger that the floor projects.
#
# WHAT THIS GRADES AND WHY IT IS THE BUNDLE. Every assertion runs the BUILT
# binary against a ledger in a temp dir, not the sourced function, because this
# row's whole point is that a REMOTE caller (/shell/exec, which executes
# `5dive <verb>` argv) can get the ledger as JSON. A test that sources
# src/cmd_a2a.sh would pass on a verb that main.sh never dispatches and that
# build.sh never bundles — and "the wiring is missing" is exactly the failure
# mode for a new verb (DIVE-3902 constraint A: a field the floor cannot actually
# read is decoration).
#
# THE THREE SOURCE STATES are the assertions that matter most. `absent` and
# `unreadable` must not collapse into each other or into an idle fleet: an
# unreadable ledger and a silent one are byte-identical downstream, and the
# quiet one is the cheap wrong answer this codebase keeps paying for
# (DIVE-1927, DIVE-1989, DIVE-2073, DIVE-2210).
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path.

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# Build a throwaway bundle OUTSIDE the repo — build.sh refuses any in-tree name
# but ./5dive (DIVE-2681), and grading the tracked artifact would grade whatever
# happens to be on disk rather than this tree's src/.
BIN="$TMP/5dive-test"
if ! ( cd "$ROOT" && BUILD_OUT="$BIN" ./build.sh ) >"$TMP/build.log" 2>&1; then
  printf 'PRECONDITION-FAILED: build.sh did not produce a bundle\n'; sed -n '1,20p' "$TMP/build.log"; exit 1
fi
command -v jq >/dev/null 2>&1 || { printf 'PRECONDITION-FAILED: jq is required\n'; exit 1; }

L="$TMP/rounds.tsv"
NOW=$(date +%s)
{
  printf 'main\tquinn\tDIVE-1\t%s\n'  $((NOW-100))
  printf 'quinn\tmain\tDIVE-1\t%s\n'  $((NOW-90))
  printf 'main\tquinn\tDIVE-1\t%s\n'  $((NOW-80))
  printf 'olivia\tmain\tpair\t%s\n'   $((NOW-70))
  printf 'main\tolivia\tDIVE-9\t%s\n' $((NOW-200000))   # outside the 24h window
  printf 'this row has no tabs at all\n'                # malformed
  printf 'a\tb\tc\tnotanumber\n'                        # malformed timestamp
} > "$L"

run() { A2A_ROUND_LEDGER="$1" "$BIN" a2a rounds "${@:2}"; }
j()   { run "$@" --json; }

echo "== the verb is dispatched from the BUNDLE (not just present in src/) =="
out="$(j "$L" 2>/dev/null)"
check "emits parseable json"       "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)" "true"
check "verb is not 'unknown verb'" "$(printf '%s' "$out" | jq -r '.error.class // "none"')" "none"

echo "== window bounds the read, malformed rows are COUNTED not dropped =="
check "in-window rounds only"  "$(jq -r '.data.summary.rounds'            <<<"$out")" "4"
check "malformed rows counted" "$(jq -r '.data.source.malformedRows'      <<<"$out")" "2"
check "out-of-window topic absent" \
  "$(jq -r '[.data.seats[].topics[].topic] | index("DIVE-9") // "absent"' <<<"$out")" "absent"

echo "== per-seat group-by: who talked to whom =="
check "seat count"                "$(jq -r '.data.summary.seats' <<<"$out")" "3"
check "main sent"                 "$(jq -r '.data.seats[]|select(.seat=="main").sent'     <<<"$out")" "2"
check "main received"             "$(jq -r '.data.seats[]|select(.seat=="main").received' <<<"$out")" "2"
check "a receive-only seat is still a row" \
  "$(jq -r '[.data.seats[].seat]|index("olivia")|if .==null then "missing" else "present" end' <<<"$out")" "present"
check "partner rounds are bidirectional" \
  "$(jq -r '.data.seats[]|select(.seat=="main").partners[]|select(.seat=="quinn").rounds' <<<"$out")" "3"
check "topics carry a count" \
  "$(jq -r '.data.seats[]|select(.seat=="main").topics[]|select(.topic=="DIVE-1").rounds' <<<"$out")" "3"

echo "== nextSendWarns matches a2a_round_guard's own predicate =="
# The guard counts BEFORE it records, so a directed pair sitting at exactly the
# cap is one whose NEXT send warns. Asserting the field against the cap the
# bundle itself reports keeps the two from drifting apart.
cap="$(jq -r '.data.roundCap' <<<"$out")"
check "cap is reported"      "$cap" "2"
check "pair at cap warns"    "$(jq -r '.data.pairs[]|select(.from=="main" and .to=="quinn").nextSendWarns' <<<"$out")" "true"
check "pair under cap does not" \
  "$(jq -r '.data.pairs[]|select(.from=="olivia").nextSendWarns' <<<"$out")" "false"
check "over-cap count"       "$(jq -r '.data.summary.pairsOverCap' <<<"$out")" "1"

echo "== filters =="
check "--agent narrows to one seat" \
  "$(jq -r '.data.seats|length' <<<"$(j "$L" --agent=quinn)")" "1"
check "--agent records both directions" \
  "$(jq -r '.data.summary.rounds' <<<"$(j "$L" --agent=quinn)")" "3"
check "--topic narrows to one topic" \
  "$(jq -r '.data.summary.topics' <<<"$(j "$L" --topic=pair)")" "1"
check "--agent is echoed back in the payload" \
  "$(jq -r '.data.filter.agent' <<<"$(j "$L" --agent=quinn)")" "quinn"

echo "== THE THIRD STATE: absent, unreadable and idle are three answers =="
out_abs="$(j "$TMP/never-written.tsv")"
check "absent state"          "$(jq -r '.data.source.state'     <<<"$out_abs")" "absent"
check "absent is rc 0"        "$(A2A_ROUND_LEDGER="$TMP/never-written.tsv" "$BIN" a2a rounds >/dev/null 2>&1; echo $?)" "0"
check "absent carries a note" "$(jq -r '.data.source.note|length>0' <<<"$out_abs")" "true"

: > "$TMP/idle.tsv"
check "an EMPTY ledger reads, it is not absent" \
  "$(jq -r '.data.source.state' <<<"$(j "$TMP/idle.tsv")")" "read"
check "an empty ledger is zero rounds" \
  "$(jq -r '.data.summary.rounds' <<<"$(j "$TMP/idle.tsv")")" "0"

U="$TMP/forbidden.tsv"; printf 'a\tb\tDIVE-1\t%s\n' "$NOW" > "$U"; chmod 000 "$U"
if [ -r "$U" ]; then
  printf '  SKIP unreadable arm (running as root: chmod 000 is still readable)\n'
else
  out_un="$(j "$U" 2>/dev/null)"
  check "unreadable state"    "$(jq -r '.data.source.state' <<<"$out_un")" "unreadable"
  check "unreadable is NOT rendered as zero traffic, it exits 3" \
    "$(A2A_ROUND_LEDGER="$U" "$BIN" a2a rounds >/dev/null 2>&1; echo $?)" "3"
  # The note must report the mode it STATTED, not the mode the writer intends —
  # the interesting case is the file that is NOT 0660 root:claude (DIVE-3658).
  check "unreadable note names the observed mode" \
    "$(jq -r '.data.source.note|test("it is 0 ")' <<<"$out_un")" "true"
  # A payload the caller cannot distinguish from an idle fleet is the defect.
  check "unreadable still says ok:true so the caller can read the state" \
    "$(jq -r '.ok' <<<"$out_un")" "true"
fi

echo "== the window cannot exceed what the ledger keeps =="
wide="$(j "$L" --window=168)"
check "wide window is flagged" "$(jq -r '.data.source.windowExceedsRetention' <<<"$wide")" "true"
check "default window is not"  "$(jq -r '.data.source.windowExceedsRetention' <<<"$out")"  "false"
check "retention is reported"  "$(jq -r '.data.source.retentionSec' <<<"$out")" "86400"
check "text mode prints the mislabel out loud" \
  "$(run "$L" --window=168 2>/dev/null | grep -c 'labelled wider')" "1"

echo "== READ-ONLY: the verb must not write, prune or re-mode the ledger =="
cp "$L" "$TMP/before.tsv"
before_mode="$(stat -c '%a' "$L")"
run "$L" >/dev/null 2>&1; j "$L" >/dev/null 2>&1; run "$L" --window=168 >/dev/null 2>&1
check "ledger bytes unchanged" "$(cmp -s "$L" "$TMP/before.tsv" && echo same || echo CHANGED)" "same"
check "ledger mode unchanged"  "$(stat -c '%a' "$L")" "$before_mode"
# The out-of-window row is the tell: a2a_round_prune would have removed it.
check "the pruner did not run" "$(grep -c 'DIVE-9' "$L")" "1"

echo "== usage / bad input =="
check "bad window refused"      "$(A2A_ROUND_LEDGER="$L" "$BIN" a2a rounds --window=0 2>&1 >/dev/null | grep -c 'positive whole number')" "1"
check "unknown flag refused"    "$(A2A_ROUND_LEDGER="$L" "$BIN" a2a rounds --nope 2>&1 >/dev/null | grep -c "unknown argument")" "1"
check "unknown subcommand refused" "$(A2A_ROUND_LEDGER="$L" "$BIN" a2a bogus 2>&1 >/dev/null | grep -c 'unknown subcommand')" "1"
# Presence, not an exact count: an exact grep count asserts how many times the
# help text happens to spell the verb, which any wording edit breaks for no
# reason. What must hold is that the verb is REACHABLE from both help surfaces —
# a verb nobody can find is the same defect as a verb nobody dispatches.
# The output is captured BEFORE it is grepped. Under `pipefail` a
# `"$BIN" ... | grep -q` pipeline carries the BINARY's status, and bare `5dive`
# exits E_USAGE(2) by design after printing its usage — so the pipeline read as
# a failed match on a help text that contained the verb three times. The
# harness was wrong, not the wiring; a probe whose plumbing can fabricate a
# negative is the class this repo keeps paying for.
help_a2a="$("$BIN" a2a 2>/dev/null)"
help_top="$("$BIN" 2>&1 || true)"
check "bare 'a2a' prints its own usage" \
  "$(case "$help_a2a" in *'5dive a2a rounds'*) echo yes ;; *) echo no ;; esac)" "yes"
check "the verb is advertised in the top-level usage" \
  "$(case "$help_top" in *'5dive a2a rounds'*) echo yes ;; *) echo no ;; esac)" "yes"

echo
printf 'a2a rounds json: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
