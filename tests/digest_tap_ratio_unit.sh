#!/usr/bin/env bash
# DIVE-4346 isolated unit harness for the digest's TAPS-PER-SHIPPED-CHANGE line.
#
# WHY THIS FILE EXISTS: quinn's grading pass on DIVE-4346 confirmed the counter
# renders in a real built run and then said the thing that mattered — it had ZERO
# test arms, so nothing would notice if it stopped rendering, or started rendering
# a confident zero. A counter whose whole purpose is to be read as a ratio by a
# customer is exactly the kind of number that must not be able to lie quietly.
#
# Same method as tests/digest_autonomy_unit.sh: extract the digest's embedded
# python and drive it through the DIGEST_*_F env contract (no shell-out, no live
# DB). This one runs the TEXT branch, not DIGEST_JSON=1, because the ratio line is
# rendered prose and the rendering is the subject.
#
# THE ARM THAT CARRIES THE MOST WEIGHT IS T4, and it is not about arithmetic:
# `needs_capability` is on neither `task ls --json` nor `gate_history`, so the
# read can genuinely fail. When it does, the split must say "unknown" and never
# "0 named none" — a capability we could not count is not a capability that was
# not named (the DIVE-3228 lesson about the buzz count). A broken read that
# renders as a clean zero is the shape that makes a number worse than no number.
# Run: bash tests/digest_tap_ratio_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
exec 8>&2
SUMMARY_PRINTED=0
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "${SUMMARY_PRINTED:-0}" == 1 ]] || printf "ABORTED - digest_tap_ratio_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/digest-tap-ratio.XXXXXX)"

awk "/python3 - >.*<<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" src/cmd_digest.sh > "$TMP/digest.py"
[[ -s "$TMP/digest.py" ]] || { echo "FAIL - could not extract digest python"; exit 1; }

iso() { date -u -d "@$(( $(date +%s) - $1 ))" +%FT%TZ; }
D1=$(iso 86400); D2=$(iso 172800); D3=$(iso 259200)

echo '{"agents":[],"tasks":[]}' > "$TMP/usage.json"
: > "$TMP/hb.txt"
echo '{"loops":[]}'             > "$TMP/loops.json"

# 3 shipped, 2 gates answered by a person, inside the 7d window.
cat > "$TMP/tasks.json" <<JSON
{"tasks":[
  {"ident":"T-1","title":"ship a","status":"done","done_at":"$D1","assignee":"dev","kind":"task"},
  {"ident":"T-2","title":"ship b","status":"done","done_at":"$D1","assignee":"dev","kind":"task"},
  {"ident":"T-3","title":"ship c","status":"done","done_at":"$D2","assignee":"dev","kind":"task"},
  {"ident":"G-1","title":"gate a","status":"done","need_type":"decision","need_answered_by":"human:lodar","need_answered_at":"$D2","need_asked_at":"$D3","need_answer":"go","assignee":"main","kind":"task"},
  {"ident":"G-2","title":"gate b","status":"done","need_type":"approval","need_answered_by":"human:lodar","need_answered_at":"$D2","need_asked_at":"$D3","need_answer":"ok","assignee":"main","kind":"task"}
]}
JSON

# $1 = tasks file, $2 = cap file (may be absent to grade the unset case)
# `env` rather than an assignment prefix: an assignment prefix is recognised
# before expansion, so a conditional `${2:+VAR=...}` would be taken as the COMMAND
# name and the harness would grade nothing. Stderr is kept — a python traceback
# here is the most informative failure this file can have.
render() {
  local -a e=(DIGEST_TASKS_F="$1" DIGEST_USAGE_F="$TMP/usage.json"
              DIGEST_HB_F="$TMP/hb.txt" DIGEST_LOOPS_F="$TMP/loops.json"
              DIGEST_WINDOW=604800 DIGEST_JSON=0)
  [[ -n "${2:-}" ]] && e+=(DIGEST_CAP_F="$2")
  env "${e[@]}" python3 "$TMP/digest.py"
}
ratio_line() { render "$@" | grep -F 'taps per shipped change'; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- T0 LIVENESS: the line renders at all. Without this every grep-for-substring
#     arm below would pass vacuously on a digest that dropped the counter.
printf '[{"cap":"human_tap","n":1},{"cap":"","n":1}]\n' > "$TMP/cap.json"
L=$(ratio_line "$TMP/tasks.json" "$TMP/cap.json")
[[ -n "$L" ]] \
  && ok_t "T0 liveness: the taps-per-shipped-change line is rendered ($L)" \
  || { bad_t "T0 liveness: no ratio line in the digest text output" "nothing below grades anything"; \
       printf '\ndigest_tap_ratio_unit: %d passed, %d failed\n' "$PASS" "$FAIL"; SUMMARY_PRINTED=1; exit 1; }

# --- T1 THE RATIO IS taps / shipped, to 2dp. 2 taps / 3 shipped = 0.67.
grep -qF '0.67 taps per shipped change' <<<"$L" \
  && ok_t "T1 ratio = 0.67 (2 human taps / 3 shipped)" \
  || bad_t "T1 ratio arithmetic" "got: $L"

# --- T2 THE SPLIT counts a named capability and a blank one separately.
grep -qF '1 named a capability, 1 named none' <<<"$L" \
  && ok_t "T2 capability split: 1 named, 1 none" \
  || bad_t "T2 capability split" "got: $L"

# --- T3 THE TAP COUNT AGREES WITH THE AUTONOMY LINE ABOVE IT. Two numbers for
#     the same fact on adjacent lines is how a counter goes quietly wrong.
grep -qE 'of 2 taps' <<<"$L" \
  && ok_t "T3 the line names the same 2 taps the autonomy line counted" \
  || bad_t "T3 tap count" "got: $L"

# --- T4 UNKNOWN IS NOT ZERO. A failed read yields null; it must render as
#     "unknown", never as "0 named none". This is the arm this file exists for.
printf 'null\n' > "$TMP/capnull.json"
L4=$(ratio_line "$TMP/tasks.json" "$TMP/capnull.json")
if grep -qF 'capability split: unknown' <<<"$L4" && ! grep -qF 'named none' <<<"$L4"; then
  ok_t "T4 an unreadable capability column renders 'unknown', NOT a confident zero"
else
  bad_t "T4 unknown-is-not-zero (DIVE-3228)" "got: $L4 — a failed read reported as 0 is worse than no counter"
fi

# --- T4b SAME, for the file being absent entirely (the env var never set).
L4b=$(ratio_line "$TMP/tasks.json")
grep -qF 'capability split: unknown' <<<"$L4b" \
  && ok_t "T4b no DIGEST_CAP_F at all is also 'unknown', not zero" \
  || bad_t "T4b unset cap file" "got: $L4b"

# --- T5 ZERO SHIPPED WITH TAPS IS NOT A DIVIDE BY ZERO, and it must not read as
#     0.00 either: taps against nothing shipped is the worst ratio there is.
python3 - "$TMP/tasks.json" "$TMP/noship.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["tasks"] = [t for t in d["tasks"] if not t["ident"].startswith("T-")]
json.dump(d, open(sys.argv[2], "w"))
PY
L5=$(ratio_line "$TMP/noship.json" "$TMP/cap.json")
grep -qF '∞ taps per shipped change' <<<"$L5" \
  && ok_t "T5 taps with nothing shipped renders ∞, not 0.00 and not a crash" \
  || bad_t "T5 zero-shipped" "got: $L5"

# --- T6 NO TAPS AND NOTHING SHIPPED IS 'n/a' — an honest absence of a ratio.
python3 - "$TMP/tasks.json" "$TMP/empty.json" <<'PY'
import json, sys
json.dump({"tasks": []}, open(sys.argv[2], "w"))
PY
L6=$(ratio_line "$TMP/empty.json" "$TMP/cap.json")
grep -qF 'n/a taps per shipped change' <<<"$L6" \
  && ok_t "T6 an empty window renders n/a, not 0.00" \
  || bad_t "T6 empty window" "got: $L6"

# --- T7 SINGULAR/PLURAL on the tap noun, because the line is read by a customer.
python3 - "$TMP/tasks.json" "$TMP/onetap.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["tasks"] = [t for t in d["tasks"] if t["ident"] != "G-2"]
json.dump(d, open(sys.argv[2], "w"))
PY
L7=$(ratio_line "$TMP/onetap.json" "$TMP/cap.json")
grep -qF 'of 1 tap,' <<<"$L7" \
  && ok_t "T7 one tap reads 'of 1 tap,' not 'of 1 taps,'" \
  || bad_t "T7 plural" "got: $L7"

# --- T8 DIVE-4346 iteration 3: a DERIVED capability is never reported as a
# declaration. A floor hit now derives the class and stores it, and a derived
# class is a GUESS read out of the ask's wording — counting it as "named" would
# hide exactly the mis-classification the split exists to make countable.
printf '[{"cap":"human_tap","derived":0,"n":1},{"cap":"spend_authority","derived":1,"n":1},{"cap":"","derived":0,"n":1}]\n' > "$TMP/capd.json"
L8=$(ratio_line "$TMP/tasks.json" "$TMP/capd.json")
grep -qF "1 named a capability, 1 named none (1 derived from the ask's wording, not declared)" <<<"$L8" \
  && ok_t "T8 a derived capability is rendered apart from a declared one" \
  || bad_t "T8 derived split" "got: $L8"
# CONTROL: a board with no derived taps must not carry the parenthetical at all.
grep -qF "derived from the ask" <<<"$L" \
  && bad_t "T8b no derived taps renders no derived clause" "got: $L" \
  || ok_t "T8b a window with no derived taps says nothing about derivation"

printf '\ndigest_tap_ratio_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" -eq 0 ]]
