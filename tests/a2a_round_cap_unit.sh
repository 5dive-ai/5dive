#!/usr/bin/env bash
# DIVE-3318: the a2a ROUND cap and the acknowledgement refusal.
#
# Grades the guard itself (src/lib/a2a_rounds.sh) against a ledger in a temp dir.
# Both send paths (`cmd_send`'s direct branch and `cmd_deliver`'s scoped branch)
# call `a2a_round_guard` and fail on its non-zero return, so the decision graded
# here IS the decision the fleet gets — the wiring is asserted separately below
# by grepping both call sites, because a guard nothing calls passes every test
# it has.
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits).

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# The HARNESS-RC trap above already owns EXIT, and a second `trap ... EXIT`
# REPLACES it rather than adding to it — which is exactly the
# cleanup-before-rc ordering tests/harness_rc_corpus_contract_unit.sh reports as
# MISSING. Chain the cleanup into one trap that still echoes the rc last.
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export A2A_ROUND_LEDGER="$TMP/rounds.tsv"
# shellcheck source=../src/lib/a2a_rounds.sh
. "$ROOT/src/lib/a2a_rounds.sh"
A2A_ROUND_LEDGER="$TMP/rounds.tsv"

echo "== topic extraction =="
check "task ident is the topic" "$(a2a_topic_of 'DIVE-3318 is the row')" "DIVE-3318"
check "first ident wins"        "$(a2a_topic_of 'per DIVE-100 see DIVE-200')" "DIVE-100"
check "no ident -> pair"        "$(a2a_topic_of 'hey are you around')" "pair"
check "non-DIVE prefix counts"  "$(a2a_topic_of 'CNCL-22 convene')" "CNCL-22"

echo "== acknowledgement detection =="
for m in "ack" "Ack." "acked" "agreed" "Agreed!" "taking it" "on it, will ping" \
         "thanks" "Thank you" "sgtm" "LGTM" "noted" "+1" "good catch" \
         "Got it — taking this one." ; do
  if a2a_is_ack "$m"; then ok "ack: $m"; else bad "ack: '$m' should be an ack"; fi
done
# The half that keeps a real message from being refused for its opening word.
for m in "agreed — RESULT: 12 of 12 harnesses green" \
         "ack, but EVIDENCE says otherwise: 3 rows failed" \
         "on it — do you want the 24h or the 7d window?" \
         "the release cut is blocked, see the run log" \
         "acking the release is not the same as an ack" ; do
  if a2a_is_ack "$m"; then bad "not-ack: '$m' must NOT be refused"; else ok "not-ack: ${m:0:34}…"; fi
done
# THE ARM THAT WAS MISSING (main2, iteration 1). The harness had a negative
# control in one direction — a message opening with "agreed" that carries our
# RESULT vocabulary — and NONE in the other: a CORRECTION in plain prose that
# opens with agreement. That is the nearest non-ack to an ack's surface, it is
# exactly what the gate answer protected by name, and the opener-word detector
# hard-refused every one of these. They are real messages from 2026-08-12, near
# verbatim. No house section word appears in any of them on purpose: this ships
# as an OSS CLI where nobody types "RESULT:", so passing must not depend on it.
for m in "good catch - it was 19,060 because --all counted the artifact rows too, on DIVE-3320." \
         "you're right, the sha is c391971 not c391972" \
         "confirmed - the ledger prunes at 24h, not 12h as you said" \
         "noted - DIVE-3320 is the precondition, not DIVE-3140" \
         "agreed. do not merge yet" \
         "ack, but the smoke never ran on that tree" \
         "thanks, though the count is off by one" \
         "on it — the origin is a local path, so those 502 commits are phantom" ; do
  if a2a_is_ack "$m"; then bad "correction refused as an ack: '$m'"; else ok "correction survives: ${m:0:38}…"; fi
done
# A long body is not an ack even if it opens like one.
long="agreed. $(printf 'x%.0s' {1..300})"
if a2a_is_ack "$long"; then bad "not-ack: a 300-char body is not an ack"; else ok "not-ack: long body"; fi
# The envelope must not defeat detection.
if a2a_is_ack "[5dive-msg from=main id=abc tier=admin] ack"; then
  ok "ack: survives the [5dive-msg] envelope"
else
  bad "ack: envelope-wrapped ack was not detected"
fi

echo "== the round cap WARNS, it does not refuse (main, gate answer 2026-08-12) =="
# The row as filed said "Refuse, not warn". Overturned on the gate: on DIVE-3320 the
# same day, every message that made the work right arrived at round 3 or later, so a
# hard cap would have shipped a wrong recipe to eight seats. A counter cannot tell
# agreement from a correction; the ack detector CAN tell, so it still refuses. These
# arms encode that split, and they are the arms that must fail if anyone re-hardens
# the counter without re-arguing it.
out="$(a2a_round_guard main dev2 'DIVE-3318 first pass, here is the plan' 2>/dev/null)"
check "round 1 allowed, silent" "$?:$out" "0:"
out="$(a2a_round_guard main dev2 'DIVE-3318 second pass with the numbers' 2>/dev/null)"
check "round 2 allowed, silent" "$?:$out" "0:"
# Round 3: rc MUST be 0 (the send proceeds) and stdout MUST be empty (nothing for the
# caller to fail on) — the warning goes to stderr.
err="$(a2a_round_guard main dev2 'DIVE-3318 third pass' 2>&1 >/dev/null)"; rc=$?
check "round 3 is ALLOWED (rc 0 — the send proceeds)" "$rc" "0"
out="$(a2a_round_guard main dev2 'DIVE-3318 fourth pass' 2>/dev/null)"
check "over-cap stdout stays EMPTY (a caller must not fail on it)" "$out" ""
case "$err" in
  *"a2a round cap"*"round 3"*"DIVE-3318"*"task set-body"*)
    ok "the warning names the count, the row and the remedy" ;;
  *) bad "warning text is missing the count, row or remedy: $err" ;;
esac
case "$err" in
  *refused*) bad "the round warning must not call itself a refusal: $err" ;;
  *) ok "the round warning does not claim to be a refusal" ;;
esac
# The one case the counter cannot see must be blessed in the text itself, or the
# warning talks a correction out of being sent — which is the exact loss the gate
# answer was about.
case "$err" in
  *CORRECTION*|*correction*) ok "the warning explicitly blesses a correction" ;;
  *) bad "the warning does not tell a correction to send anyway: $err" ;;
esac

echo "== the counter still COUNTS past the cap (the digest needs it) =="
: > "$A2A_ROUND_LEDGER"
for i in 1 2 3 4; do a2a_round_guard main dev2 "DIVE-5 pass $i" >/dev/null 2>&1; done
check "all 4 rounds recorded, not stopped at the cap" "$(a2a_round_count main dev2 DIVE-5)" "4"

echo "== the cap is per topic, per direction, per pair =="
: > "$A2A_ROUND_LEDGER"
for i in 1 2; do a2a_round_guard main dev2 "DIVE-3318 pass $i" >/dev/null 2>&1; done
warns() {  # <from> <to> <msg> -> "warn" | "quiet"
  local e; e="$(a2a_round_guard "$1" "$2" "$3" 2>&1 >/dev/null)"
  [[ "$e" == *"a2a round cap"* ]] && printf 'warn' || printf 'quiet'
}
check "a different TOPIC does not warn"          "$(warns main dev2 'DIVE-9999 a different row')" "quiet"
check "the reverse DIRECTION has its own count"  "$(warns dev2 main 'DIVE-3318 the reply')"       "quiet"
check "a different PAIR does not warn"           "$(warns main quinn 'DIVE-3318 other peer')"     "quiet"
check "each side gets two turns before warning"  "$(warns dev2 main 'DIVE-3318 second reply')"    "quiet"
check "the fifth message on the topic WARNS"     "$(warns dev2 main 'DIVE-3318 a third reply')"   "warn"

echo "== no sender is exempt by role =="
# main was 49% of the measured volume; a lead exemption exempts the problem.
: > "$A2A_ROUND_LEDGER"
for i in 1 2; do a2a_round_guard main dev2 "DIVE-1 pass $i" >/dev/null 2>&1; done
check "the lead is warned like everyone else" "$(warns main dev2 'DIVE-1 pass 3')" "warn"

echo "== an ack is refused before it is counted =="
: > "$A2A_ROUND_LEDGER"
out="$(a2a_round_guard main dev2 'ack')"; rc=$?
check "an ack is still REFUSED (the detector can see it carries nothing)" "$rc" "1"
case "$out" in *refused*) ok "the ack refusal goes to STDOUT so the caller can fail on it" ;;
  *) bad "ack refusal not on stdout: $out" ;; esac
check "an ack does not consume a round" "$(a2a_round_count main dev2 pair)" "0"

echo "== rounds age out =="
: > "$A2A_ROUND_LEDGER"
printf 'main\tdev2\tDIVE-7\t1\nmain\tdev2\tDIVE-7\t2\n' > "$A2A_ROUND_LEDGER"
check "epoch-1 rounds are outside the window" "$(a2a_round_count main dev2 DIVE-7)" "0"
check "an aged-out topic is quiet again" "$(warns main dev2 'DIVE-7 after the window')" "quiet"

echo "== the notification rail is neither refused nor warned =="
: > "$A2A_ROUND_LEDGER"
for i in 1 2 3 4; do
  e="$(_5DIVE_A2A_NOTIFY=1 a2a_round_guard main dev2 "DIVE-8 gate routed to you" 2>&1 >/dev/null)"; rc=$?
  check "gate handoff $i is never refused" "$rc" "0"
  check "gate handoff $i is not even warned about" "${e:-quiet}" "quiet"
done
check "and it records no rounds" "$(a2a_round_count main dev2 DIVE-8)" "0"

echo "== missing ledger fails OPEN, not closed =="
rm -f "$A2A_ROUND_LEDGER"
check "no ledger counts zero" "$(a2a_round_count main dev2 DIVE-3318)" "0"

echo "== the guard is actually wired into BOTH delivery paths =="
rt="$ROOT/src/cmd_agent_runtime.sh"
n="$(grep -c 'a2a_round_guard' "$rt")"
if [ "$n" -ge 2 ]; then ok "a2a_round_guard called $n× in cmd_agent_runtime.sh"; else
  bad "a2a_round_guard must be called on both cmd_send and cmd_deliver (found $n)"; fi
# Slice ONE top-level function body: from its `name() {` line to the next
# top-level definition (or EOF). `~` binds TIGHTER than concatenation in awk, so
# the parens around the built pattern are load-bearing: without them the match is
# `$0 ~ "^"` — true on every line — and the extractor silently returns nothing,
# which reads as "the guard is not wired" against a call site that is plainly
# there. A naive `/^name\(\)/,/^}/` range stops at the
# first column-0 `}` INSIDE the function, which for cmd_send is a nested block —
# it reported "not enforced" against a call site that is plainly there. The
# assertion below is only meaningful if the extractor can be wrong in the other
# direction too, so both a positive and a negative control run first.
# NOTE: callers must NOT pipe this into `grep -q`. Under `set -o pipefail`, grep -q
# exits at the first match, awk takes SIGPIPE, and the pipeline reports 141 — so a
# SUCCESSFUL match reads as a failed assertion. Capture the body first, then match.
_fn_body() {  # <file> <fn>
  awk -v fn="$2" '
    $0 ~ ("^" fn "\\(\\) \\{") { inside=1; next }
    inside && /^[a-z_][a-z0-9_]*\(\) \{/ { inside=0 }
    inside { print }
  ' "$1"
}
# Controls: the extractor must find a string that IS in cmd_send and must NOT
# find one that belongs to a different function.
_send_body="$(_fn_body "$rt" cmd_send)"
_deliver_body="$(_fn_body "$rt" cmd_deliver)"
if printf '%s' "$_send_body" | grep -q 'msg_src'; then
  ok "control: the function extractor finds cmd_send's own code"
else
  bad "control: the extractor cannot read cmd_send — every wiring assertion below is void"
fi
if printf '%s' "$_send_body" | grep -q 'require_root "agent _deliver"'; then
  bad "control: the extractor leaked cmd_deliver's body into cmd_send"
else
  ok "control: the extractor does not leak across function boundaries"
fi
# The scoped path is the one every standard-isolation agent takes. A cap enforced
# only in cmd_send is a cap on admins, i.e. on nobody being counted.
if printf '%s' "$_deliver_body" | grep -q 'a2a_round_guard'; then
  ok "cmd_deliver (the scoped path) enforces the cap"
else
  bad "cmd_deliver does not enforce the cap — scoped agents would bypass it"
fi
if printf '%s' "$_send_body" | grep -q 'a2a_round_guard'; then
  ok "cmd_send (the direct path) enforces the cap"
else
  bad "cmd_send does not enforce the cap"
fi
# The notify marker must survive the sudo re-exec, or a gate ping gets refused.
if grep -q '_deliver --notify' "$rt"; then
  ok "the notify marker is carried across the sudo re-exec"
else
  bad "sudo scrubs the env — _5DIVE_A2A_NOTIFY must be passed as --notify"
fi
if grep -q '\-\-notify) _5DIVE_A2A_NOTIFY=1' "$rt"; then
  ok "cmd_deliver accepts --notify"
else
  bad "cmd_deliver does not parse --notify"
fi
# And the in-repo notification rails set it.
# src/cmd_council.sh is GENERATED from src/council/cli.mjs by src/council/gen_cmd.mjs,
# and tests/council_cli_contract.mjs re-runs the generator — so a hand-edit to the
# generated file is silently reverted mid-suite and the marker vanishes. Assert the
# CANONICAL source too, or this check passes on an edit that cannot survive.
for f in src/cmd_supervisor.sh src/task/notify.sh src/council/cli.mjs src/cmd_council.sh; do
  if grep -qE "_5DIVE_A2A_NOTIFY=1 5dive agent send|_5DIVE_A2A_NOTIFY: '1'" "$ROOT/$f"; then
    ok "$f marks its notification sends"
  else
    bad "$f sends unmarked — its one-way notices would be counted as rounds"
  fi
done
# The bundle must carry the lib, or none of the above exists at runtime.
if grep -q 'src/lib/a2a_rounds.sh' "$ROOT/build.sh"; then
  ok "build.sh bundles src/lib/a2a_rounds.sh"
else
  bad "src/lib/a2a_rounds.sh is not in build.sh — the guard is absent from the shipped CLI"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
