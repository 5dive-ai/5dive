#!/usr/bin/env bash
# DIVE-1434 isolated unit harness for the transport-liveness canary decision.
#
# The initial gate ping delivers tap buttons via a direct curl, but the TAP that
# clears the gate arrives as a callback_query the agent's OWN getUpdates poller
# must consume. If that poller dies (restart left the DIVE-818 slot unacquired),
# buttons still SEND but taps never land. _hb_poller_verdict is the PURE decision:
# given (type, beacon mtime, now, allowFrom count, staleness threshold) it flags a
# DEAD poller, stays silent on healthy/not-applicable. This exercises exactly that
# logic — no registry, no channels, no network.
#
# Run: bash tests/poller_liveness_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
source "$SRC/header.sh"
set +e   # header.sh set -e; keep going so every assertion runs

# Pull just the pure helper out of cmd_heartbeat.sh without sourcing the whole
# file (which pulls in heavy deps). It's self-contained, so eval its definition.
eval "$(awk '/^_hb_poller_verdict\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")"

PASS=0; FAIL=0
NOW=1000000
THRESH=120
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fi
}
# A verdict is "dead" when it echoes a non-empty reason; "ok" when it echoes nothing.
verdict() { _hb_poller_verdict "$1" "$2" "$NOW" "$3" "$THRESH"; }

# 1. Fresh beacon on a paired claude agent -> healthy (silent).
check "fresh beacon healthy" "" "$(verdict claude $((NOW-3)) 1)"

# 2. Beacon just over threshold -> DEAD (non-empty reason).
r=$(verdict claude $((NOW-121)) 1); [[ -n "$r" ]] && r=DEAD || r=OK
check "stale beacon flagged dead" "DEAD" "$r"

# 3. Beacon exactly AT threshold (age==thresh, not >) -> still healthy.
check "beacon at threshold not flagged" "" "$(verdict claude $((NOW-120)) 1)"

# 4. Missing beacon (mtime 0) on a paired claude agent -> DEAD (never started).
r=$(verdict claude 0 1); [[ -n "$r" ]] && r=DEAD || r=OK
check "missing beacon flagged dead" "DEAD" "$r"

# 5. UNPAIRED agent (allowFrom 0) with a stale beacon -> skip (no human to deafen).
check "unpaired agent skipped" "" "$(verdict claude $((NOW-999)) 0)"

# 6. Non-claude runtime (codex) with no beacon -> skip (own liveness model).
check "codex runtime skipped" "" "$(verdict codex 0 1)"

# 7. Non-claude runtime (grok) even with a stale beacon -> skip.
check "grok runtime skipped" "" "$(verdict grok $((NOW-999)) 1)"

# 8. Operator-stopped / inactive-unit paired claude agent (supposed=0) with a
#    stale beacon -> skip. A stopped agent's beacon is stale by definition; that's
#    the supervisor's stuck class, not a dead transport. (Amendment: no alarm.)
check "stopped/inactive agent skipped" "" "$(_hb_poller_verdict claude $((NOW-999)) "$NOW" 1 "$THRESH" 0)"

# 9. Same agent but supposed=1 (desired-running + unit active) -> still DEAD, so
#    the skip is scoped to the stopped case only and doesn't mask a real death.
r=$(_hb_poller_verdict claude $((NOW-999)) "$NOW" 1 "$THRESH" 1); [[ -n "$r" ]] && r=DEAD || r=OK
check "running agent still flagged dead" "DEAD" "$r"

# ---------------------------------------------------------------------------
# DIVE-2384: restart grace on UNIT uptime (7th param).
#
# The bug: the plugin's shutdown() UNLINKS bot.heartbeat, and systemd reports the
# unit ACTIVE across a bounce, so a tick landing in the unlink->first-bump gap hit
# case 4 above and returned "no beacon" WITHOUT ever reading thresh. The 120s
# restart tolerance was unreachable on the path a restart actually takes.
#
# Both halves are graded below and BOTH are required. The cheap wrong fix is to
# mute the missing-beacon branch, which silently deletes real detection and leaves
# a canary that can never fire — case 21 is the half that forbids it.
uv() { _hb_poller_verdict claude "$1" "$NOW" 1 "$THRESH" 1 "$2"; }   # mtime uptime
dead_or_ok() { [[ -n "$1" ]] && printf DEAD || printf OK; }

# 20. RESTART RACE — the reported defect. Beacon unlinked (mtime 0), unit active
#     for 6s (measured: the fleet-wide fire ran 1s before the new pollers existed).
#     -> NO verdict.
check "restart race (no beacon, unit up 6s) not flagged" "" "$(uv 0 6)"

# 21. GENUINELY DEAD poller — beacon absent and the unit has been active an hour.
#     -> STILL alarms. Detection must survive the fix.
check "no beacon on a long-active unit still flagged dead" "DEAD" "$(dead_or_ok "$(uv 0 3600)")"

# 22/23. Grace boundary is thresh itself (<=, so 120 is graced, 121 is not) —
#     the same constant the author wrote for riding a restart, now reachable.
check "uptime AT thresh graced"          ""     "$(uv 0 "$THRESH")"
check "uptime one past thresh flagged"   "DEAD" "$(dead_or_ok "$(uv 0 $((THRESH+1)))")"

# 24/25/26. UNRESOLVABLE uptime is NOT graced. Empty (no such unit / systemd
#     unreachable), non-numeric, and negative (clock skew) all fall through to the
#     alarm, so a broken probe degrades to the pre-fix behaviour rather than
#     silently muting the canary.
check "empty uptime still flagged"       "DEAD" "$(dead_or_ok "$(uv 0 '')")"
check "non-numeric uptime still flagged" "DEAD" "$(dead_or_ok "$(uv 0 'n/a')")"
check "negative uptime still flagged"    "DEAD" "$(dead_or_ok "$(uv 0 -5)")"

# 27/28. The grace is on the whole verdict, not just the missing-beacon branch: a
#     rough kill (SIGKILL, no shutdown handler) leaves the file STALE instead of
#     absent, which is the same race with a different symptom.
check "stale beacon inside grace not flagged" "" "$(_hb_poller_verdict claude $((NOW-999)) "$NOW" 1 "$THRESH" 1 6)"
check "stale beacon past grace still flagged" "DEAD" \
  "$(dead_or_ok "$(_hb_poller_verdict claude $((NOW-999)) "$NOW" 1 "$THRESH" 1 3600)")"

# 29. Back-compat: the 7th param is optional and its absence means "not graced",
#     so any caller still passing 6 args behaves exactly as before.
check "omitted uptime arg still flagged" "DEAD" "$(dead_or_ok "$(_hb_poller_verdict claude 0 "$NOW" 1 "$THRESH" 1)")"

# ---------------------------------------------------------------------------
# MUTATION ARM (DIVE-2384). Cases 20 and 27 assert an ABSENCE (empty output) and
# those pass trivially — a verdict that returned early for any unrelated reason,
# or a function that failed to eval at all, would satisfy them. So neutralize the
# fix two ways and require the paired assertion to go RED. A mutation that changes
# nothing is reported as a harness failure, not skipped.
MUT_FAIL=0
mut_check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); MUT_FAIL=1
    printf 'FAIL (mutation): %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fi
}
DEF=$(awk '/^_hb_poller_verdict\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")
if [[ -z "$DEF" ]]; then
  printf 'FAIL (mutation): could not extract _hb_poller_verdict from %s/cmd_heartbeat.sh\n' "$SRC"
  FAIL=$((FAIL+1)); MUT_FAIL=1
fi
# Run <mutated-source> against args in a subshell, under a different name so the
# real definition above is never clobbered.
run_mut() { local d="$1"; shift; ( eval "$(sed 's/^_hb_poller_verdict() {/_mut() {/' <<<"$d")"; _mut "$@" ); }

# Mutation A — REVERT the fix: make the grace window unreachable. Case 20 (the
# restart race) must come back DEAD. This proves the grace guard is what silences
# it, not some unrelated early return.
MUT_A=$(sed 's/(( uptime <= thresh ))/(( uptime <= -1 ))/' <<<"$DEF")
mut_check "mutation A landed (grace neutralized)" "changed" \
  "$([[ "$MUT_A" != "$DEF" ]] && printf changed || printf UNCHANGED)"
mut_check "mutation A: restart race goes RED" "DEAD" "$(dead_or_ok "$(run_mut "$MUT_A" claude 0 "$NOW" 1 "$THRESH" 1 6)")"
# ...and A must NOT disturb the detection half, or it is not a targeted mutation.
mut_check "mutation A: real death still detected" "DEAD" "$(dead_or_ok "$(run_mut "$MUT_A" claude 0 "$NOW" 1 "$THRESH" 1 3600)")"

# Mutation B — the CHEAP WRONG FIX: mute the missing-beacon branch outright. Case
# 21 (a genuinely dead poller) must come back OK. This is the whole risk of this
# change: if B fails to flip, the canary can no longer fire at all and the real
# failure it guards — a deaf channel, gates unclearable from the phone — goes
# unwatched.
MUT_B=$(sed 's/echo "no beacon (poller never started)"/:/' <<<"$DEF")
mut_check "mutation B landed (detection deleted)" "changed" \
  "$([[ "$MUT_B" != "$DEF" ]] && printf changed || printf UNCHANGED)"
mut_check "mutation B: real death goes RED (undetected)" "OK" "$(dead_or_ok "$(run_mut "$MUT_B" claude 0 "$NOW" 1 "$THRESH" 1 3600)")"
# ...and B must leave the restart race silent, so the two mutations are distinct.
mut_check "mutation B: restart race still silent" "OK" "$(dead_or_ok "$(run_mut "$MUT_B" claude 0 "$NOW" 1 "$THRESH" 1 6)")"

# ---------------------------------------------------------------------------
# REMEDY TEXT (DIVE-2384, second defect; REVISED by DIVE-3753). The alarm's
# prescribed remedy was "Fix: restart the agent(s)" — unconditional and PLURAL
# on a fleet-wide alarm, which is a fleet-wide restart. That half is still the
# defect and arms 37/39 still guard it.
#
# What DIVE-3753 changes is the RATIONALE and the confirm step, because DIVE-2384
# reasoned from the beacon and got the poller wrong:
#
#   - retired: "a restart deletes the beacon and re-arms this alarm". True of the
#     beacon (shutdown() unlinks it), false of the poller. Measured 2026-08-26 on
#     two seats: launcher=0/server=0 before, 1/1 nine seconds after a restart.
#     Recency-of-restart correlates with the broken state because the failure
#     happens AT channel start — the correlate points at the moment of the defect,
#     not at its cause, and reading it as causal made the only working remedy a
#     prohibition.
#   - retired: bot.pid + bot.heartbeat as the confirm step. The beacon collapses
#     three distinguishable states into one string (never started / dependency
#     failure / genuinely dead), so it cannot tell a human which one they have.
#     The process table can, and `bun (start|server)\.ts` is the only clean
#     count — DIVE-3754: `start.ts` is the recording launcher DIVE-3752 put in
#     front of the poller, `server.ts` is what an older plugin cache and every
#     telegram-<x> variant still run. A remedy naming one of them reads ZERO on
#     the other half of the fleet.
#
# The alarm must now agree with the supervisor ladder, which restarts a
# poller-dead seat at rung 4 (DIVE-3753). Two texts prescribing opposite actions
# for the same seat is the state this pairing exists to prevent, so these arms
# are DIRECTIONAL: they assert the retired claims are ABSENT and the new ones
# present, and mutation D restores the retired rationale and requires a red.
#
# That text is prose inside a cmd_send string: nothing else in this repo asserts
# it, so it can silently regress. These arms are its only guard.
#
# LIVENESS FIRST. The arms below are mostly NEGATIVE ("must not say X"), and a
# negative assertion over an empty haystack passes for free — a renamed function,
# a moved string or a changed grep would make all of them vacuous. So prove the
# extraction actually found the alarm before grading its contents.
REMEDY=$(awk '/^_hb_poller_liveness_sweep\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh" \
         | grep -F 'Telegram poller DEAD on:')
has() { [[ "$2" == *"$1"* ]] && printf yes || printf no; }

# 36. Liveness: the alarm string is reachable at all.
check "remedy: alarm string extracted" "yes" "$(has 'Gate-ping tap buttons still SEND' "$REMEDY")"

# 37. The self-perpetuating remedy is GONE. This is the defect.
check "remedy: no unconditional restart instruction" "no" "$(has 'Fix: restart the agent(s)' "$REMEDY")"

# 38. And it is replaced by a confirmation step, not just deleted — an alarm with
#     no remedy at all is a different failure, not a fix. DIVE-3753: the check is
#     the PROCESS TABLE, because the beacon cannot separate the three states it
#     reports identically.
check "remedy: names a confirm-first check" "yes" "$(has 'CONFIRM BEFORE ACTING' "$REMEDY")"
check "remedy: confirmation is the process table" "yes" \
  "$(has "pgrep -u agent-<name> -f 'bun (start|server)\\.ts'" "$REMEDY")"

# 38a (DIVE-3754). DIRECTIONAL, like 37 and 38b: the SINGLE-name pattern must be
#     gone. Arm 38 above already proves the pgrep line is in the haystack, so
#     this negative is not vacuous. Either single name is wrong on half the
#     fleet — `bun server.ts` reads zero on a seat carrying DIVE-3752's
#     launcher, `bun start.ts` reads zero on an older plugin cache and on all
#     five telegram-<x> variants — and a confirm step that reads zero on a
#     healthy seat tells the human to restart it.
check "remedy: the single-name server.ts pattern is retired" "no" \
  "$(has "-f 'bun server.ts'" "$REMEDY")"
check "remedy: the single-name start.ts pattern is not its replacement" "no" \
  "$(has "-f 'bun start.ts'" "$REMEDY")"

# 38b (DIVE-3753). The RETIRED rationale must be gone. It is false about the
#     poller and it contradicts the ladder's rung 4, and while it stands a reader
#     who follows the alarm undoes what the supervisor just did.
check "remedy: the false beacon rationale is retired" "no" \
  "$(has 'a restart deletes the beacon and re-arms this alarm' "$REMEDY")"
check "remedy: the beacon is no longer offered as the discriminator" "no" \
  "$(has 'is bot.pid' "$REMEDY")"

# 38c (DIVE-3753). And the alarm must SAY the ladder acts on its own, or a human
#     reading it cannot tell an un-restarted seat from one whose budget is spent —
#     the difference between "wait" and "this one needs you".
check "remedy: names the automatic rung-4 restart" "yes" \
  "$(has 'The supervisor restarts a poller-dead seat on its own at rung 4' "$REMEDY")"
check "remedy: names the rate-limit window" "yes" \
  "$(has 'once per seat per 6h' "$REMEDY")"

# 39. Scoped to the ONE named subject. A plural remedy on a fleet-wide alarm is a
#     fleet-wide action — the 17:00:05 fire named all six agents in one line.
check "remedy: scopes the restart to THAT ONE agent" "yes" "$(has 'restart THAT ONE agent' "$REMEDY")"

# 40. DIVE-818 / DIVE-1434 are provenance refs from code comments, not board rows.
#     Unlabelled, a reader follows them and hits "no such task".
check "remedy: labels the DIVE refs as code provenance" "yes" "$(has 'not board rows' "$REMEDY")"

# Mutation C — restore the loop. Put the old remedy back and require arm 37 to go
# RED. Without this, arm 37 is an absence over a string that nothing proves is the
# remedy at all.
MUT_C=${REMEDY/CONFIRM BEFORE ACTING/Fix: restart the agent(s)}
mut_check "mutation C landed (old remedy restored)" "changed" \
  "$([[ "$MUT_C" != "$REMEDY" ]] && printf changed || printf UNCHANGED)"
mut_check "mutation C: unconditional-restart arm goes RED" "yes" \
  "$(has 'Fix: restart the agent(s)' "$MUT_C")"
# ...and C must leave the liveness arm alone, or it is not targeted.
mut_check "mutation C: liveness arm unaffected" "yes" \
  "$(has 'Gate-ping tap buttons still SEND' "$MUT_C")"

# Mutation D (DIVE-3753) — restore the RETIRED rationale and require arm 38b to
# go RED. Arms 38b are absences, and an absence over the wrong haystack passes
# for free; C only proves the extraction is live for the arm-37 string. Without
# D, the retired-rationale arms are unfalsifiable.
MUT_D=${REMEDY/CONFIRM BEFORE ACTING/do NOT blanket-restart: a restart deletes the beacon and re-arms this alarm. CONFIRM BEFORE ACTING}
mut_check "mutation D landed (retired rationale restored)" "changed" \
  "$([[ "$MUT_D" != "$REMEDY" ]] && printf changed || printf UNCHANGED)"
mut_check "mutation D: retired-rationale arm goes RED" "yes" \
  "$(has 'a restart deletes the beacon and re-arms this alarm' "$MUT_D")"
# ...and D must leave the rung-4 arm alone, or it is not targeted.
mut_check "mutation D: rung-4 arm unaffected" "yes" \
  "$(has 'The supervisor restarts a poller-dead seat on its own at rung 4' "$MUT_D")"

if (( MUT_FAIL )); then
  printf '\nMUTATION ARM FAILED — the green above is NOT evidence.\n'
fi

printf '\npoller-liveness unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
