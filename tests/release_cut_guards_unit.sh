#!/usr/bin/env bash
# TIER: nightly — 63.6s measured (DIVE-3941, 2026-09-03): does not fit the 300s PR core; the
# nightly sweep runs it. Was 42.8s (DIVE-2525); the same box measured 50.8s for the pre-DIVE-3941
# tree in the same session, so ~8s of the rise is the box and ~13s is this ticket's three new
# deadline arms, which can only be graded by letting a poll budget actually expire.
# DIVE-2144 — grade the two guards in .github/workflows/release-cut.yml.
#
# SHAPE, and it is deliberate (same as tests/install_pin_sha_unit.sh): this extracts
# the guard blocks VERBATIM from the shipped workflow by fence marker and runs those
# bytes. It does not re-implement them. A harness that re-implements the logic it
# grades is internally consistent and externally silent — it agrees with itself while
# the shipped file does something else. See community/wiki/fixture-shaped-like-the-parser-dive2144.md.
#
# WHAT THESE GUARDS ARE FOR: this workflow decides whether to PUBLISH. Both of its
# failure modes succeed and exit 0 —
#   (1) "no failing checks" is satisfied by "no checks at all", so an ungraded tree
#       publishes at exactly the moment grading is broken;
#   (2) a tag that does not win install.sh's `sort -V` publishes NOTHING while the
#       release page looks correct.
# Neither is visible downstream, which is why they are asserted here.
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
trap 'rc=$?; rm -rf "${POLLDIR:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

WF=.github/workflows/release-cut.yml
pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   - $1"; else fail=$((fail+1)); echo "FAIL - $1: got '$2' want '$3'"; fi; }

# Extract a fenced block verbatim and strip the workflow's 10-space run: indent.
extract(){ # $1 = fence name
  sed -n "/# >>> DIVE-2144 $1/,/# <<< DIVE-2144 $1/p" "$WF" \
    | sed '1d;$d' | sed 's/^          //'
}

GUARD=$(extract 'release-cut guard block')
SORTA=$(extract 'sort-assertion block')
[[ -n "$GUARD" && -n "$SORTA" ]] || { echo "FAIL - could not extract the fenced blocks from $WF"; exit 1; }

# --- harness: run the extracted bytes against a fixture -----------------------
# DIVE-2466: the guard now POLLS. RELEASE_CUT_POLL_SECONDS=0 pins these two helpers
# to a SINGLE look, which is exactly the behaviour every assertion below was written
# against — so they keep their original meaning verbatim rather than being loosened to
# accommodate the loop. Polling is graded separately, in its own section further down.
verdict(){ # $1 = check-runs TSV ; echoes NOT-REACHED|IN-FLIGHT|RED|GREEN
  local out rc
  out=$(runs="$1" sha=deadbeefcafe tag=v9.9.9 RELEASE_CUT_POLL_SECONDS=0 bash -c "
    set -uo pipefail
    $GUARD
  " 2>&1); rc=$?
  if (( rc != 0 )); then
    grep -q 'CI NOT REACHED'   <<<"$out" && { echo NOT-REACHED; return; }
    grep -q 'CI still IN FLIGHT'<<<"$out" && { echo IN-FLIGHT;   return; }
    grep -q 'CI is RED'         <<<"$out" && { echo RED;         return; }
    echo "OTHER-FAIL:$out"; return
  fi
  grep -q 'CI green on' <<<"$out" && echo GREEN || echo "OTHER-OK:$out"
}
# DIVE-2466 iter3: PIN the GitHub-provided env, never inherit it. On a real runner
# GITHUB_JOB and GITHUB_RUN_ID are both set, and the guard block under test reads
# them — so without this the harness grades the RUNNER's environment instead of its
# own fixtures. It went 40/0 here and 30/10 in CI for exactly that reason: the
# unit-tests job is named `test`, several fixtures carry a row named `test`, and the
# guard deleted them. Any helper that drives the block must neutralise both.
export GITHUB_JOB=""
export GITHUB_RUN_ID=""

verdict_run(){ # $1 = check-runs TSV (4-col), $2 = GITHUB_RUN_ID ; echoes like verdict()
  local out rc
  out=$(runs="$1" sha=deadbeefcafe tag=v9.9.9 GITHUB_RUN_ID="$2" RELEASE_CUT_POLL_SECONDS=0 bash -c "
    set -uo pipefail
    $GUARD
  " 2>&1); rc=$?
  if (( rc != 0 )); then
    grep -q 'CI NOT REACHED'    <<<"$out" && { echo NOT-REACHED; return; }
    grep -q 'CI still IN FLIGHT' <<<"$out" && { echo IN-FLIGHT;   return; }
    grep -q 'CI is RED'          <<<"$out" && { echo RED;         return; }
    echo "OTHER-FAIL:$out"; return
  fi
  grep -q 'CI green on' <<<"$out" && echo GREEN || echo "OTHER-OK:$out"
}

# DIVE-2238 fixtures. Column 4 is details_url, which is how a check-run is traced
# back to the workflow run that owns it.
SELF_URL='https://github.com/5dive-ai/5dive/actions/runs/30332498204/job/90190441674'
OTHER_URL='https://github.com/5dive-ai/5dive/actions/runs/99999999999/job/1'
# This job's own row (in_progress, forever, because it IS the running job) plus a
# fully green board — the EXACT shape of run 30332498204 that refused to publish.
SELF_INFLIGHT=$(printf 'cut\tin_progress\tpending\t%s\ntest\tcompleted\tsuccess\t%s\nscan\tcompleted\tsuccess\t%s' "$SELF_URL" "$OTHER_URL" "$OTHER_URL")
# Same board, but the in-flight check belongs to a DIFFERENT run. Must still block.
OTHER_INFLIGHT=$(printf 'test\tin_progress\tpending\t%s\nscan\tcompleted\tsuccess\t%s' "$OTHER_URL" "$OTHER_URL")
# Nothing but our own rows: after filtering there is no evidence at all.
ONLY_SELF=$(printf 'cut\tin_progress\tpending\t%s' "$SELF_URL")

cut_decision(){ # $1 = incumbent, $2 = candidate ; echoes CUT|REFUSE
  incumbent="$1" tag="$2" bash -c "set -uo pipefail; $SORTA" >/dev/null 2>&1 && echo CUT || echo REFUSE
}

echo "== guard A: the CI verdict must never read absence as green =="
ok "ZERO check-runs -> NOT-REACHED, not GREEN"  "$(verdict "")" "NOT-REACHED"
ok "all success -> GREEN"                       "$(verdict "$(printf 'test\tcompleted\tsuccess\nscan\tcompleted\tsuccess')")" "GREEN"
ok "skipped and neutral count as green"         "$(verdict "$(printf 'test\tcompleted\tsuccess\nhook\tcompleted\tskipped\nx\tcompleted\tneutral')")" "GREEN"
ok "one failure -> RED"                         "$(verdict "$(printf 'test\tcompleted\tsuccess\nscan\tcompleted\tfailure')")" "RED"
ok "cancelled -> RED"                           "$(verdict "$(printf 'test\tcompleted\tcancelled')")" "RED"
ok "timed_out -> RED"                           "$(verdict "$(printf 'test\tcompleted\ttimed_out')")" "RED"
ok "still in_progress -> IN-FLIGHT, not GREEN"  "$(verdict "$(printf 'test\tin_progress\tpending\nscan\tcompleted\tsuccess')")" "IN-FLIGHT"
ok "queued -> IN-FLIGHT"                        "$(verdict "$(printf 'test\tqueued\tpending')")" "IN-FLIGHT"

echo "== DIVE-2238: the job must not count ITSELF as unfinished CI =="
ok "own in_progress row is excluded -> GREEN"   "$(verdict_run "$SELF_INFLIGHT"  30332498204)" "GREEN"
ok "ANOTHER run's in_progress still blocks"     "$(verdict_run "$OTHER_INFLIGHT" 30332498204)" "IN-FLIGHT"
ok "only our own rows -> NOT-REACHED, not GREEN" "$(verdict_run "$ONLY_SELF"     30332498204)" "NOT-REACHED"
# Without a run id (local/manual invocation) nothing is filtered and the old
# behaviour stands, so the filter can never silently swallow a real in-flight run.
ok "no GITHUB_RUN_ID -> nothing filtered"       "$(verdict_run "$SELF_INFLIGHT"  '')"          "IN-FLIGHT"

# --- DIVE-2466 iter2: a SIBLING release-cut must not be graded either ----------
# olivia's reject (07-31) named the gap this closes and the gap in the OLD coverage.
# The `MUTANT drop self-filter` arm below only ever proved the job ignores ITSELF;
# nothing proved it ignores ANOTHER run of the same workflow on the same sha. The
# live failure was exactly that: the 02:37 primary died after its check-run named
# `cut` had already completed FAILED, and the 03:43 re-arm read that corpse as a
# third-party red and refused in 9s. So an all-green sha was declared RED by the
# residue of a previous attempt, permanently, because the RED branch exits before
# polling and cannot be waited out.
#
# SIB_URL is a DIFFERENT run id from SELF_URL on purpose — that difference is the
# entire bug. Matching on run id alone lets this row through.
SIB_URL='https://github.com/5dive-ai/5dive/actions/runs/30607923668/job/2'
FOREIGN_CUT=$(printf 'test\tcompleted\tsuccess\t%s\ncut\tcompleted\tfailure\t%s\ncut\tin_progress\tpending\t%s' \
  "$OTHER_URL" "$SIB_URL" "$SELF_URL")
ok "sibling release-cut failure is NOT graded (the 07-31 poisoned re-arm)" \
   "$(verdict_run "$FOREIGN_CUT" '30332498204')" "GREEN"

# The same fixture with a NON-release-cut red must still refuse — the exclusion is
# scoped to this workflow and must not have widened into "ignore reds".
POISON_PLUS_REAL_RED=$(printf 'test\tcompleted\tfailure\t%s\ncut\tcompleted\tfailure\t%s\ncut\tin_progress\tpending\t%s' \
  "$OTHER_URL" "$SIB_URL" "$SELF_URL")
ok "a genuine third-party red still REFUSES with the sibling filter on" \
   "$(verdict_run "$POISON_PLUS_REAL_RED" '30332498204')" "RED"

echo "== guard B: the candidate must WIN install.sh's sort, not merely exist =="
ok "v0.16.32 over v0.15.34 -> CUT"              "$(cut_decision v0.15.34 v0.16.32)" "CUT"
ok "no incumbent -> CUT"                        "$(cut_decision '' v0.16.32)"       "CUT"
ok "v0.9.9 under v0.15.34 -> REFUSE"            "$(cut_decision v0.15.34 v0.9.9)"   "REFUSE"
ok "equal -> REFUSE (never re-point a tag)"     "$(cut_decision v0.16.32 v0.16.32)" "REFUSE"

echo "== guard C: the cutter's incumbent rule agrees with install.sh's shipped one =="
# install.sh's resolve_gh_tag and this workflow are one rule implemented twice. If
# they diverge, the cutter publishes a tag the installer will not select.
inst_rule=$(grep -oE "grep -E '\^v\[0-9\]\+\\\\\.\[0-9\]\+\\\\\.\[0-9\]\+\\\$'" install.sh | head -1)
ok "install.sh still filters ^v<n>.<n>.<n>$"    "$([[ -n "$inst_rule" ]] && echo yes || echo no)" "yes"
ok "install.sh still sorts with sort -V"        "$(grep -c 'sort -V' install.sh | awk '{print ($1>0)?"yes":"no"}')" "yes"
ok "the workflow sorts with sort -V too"        "$(grep -c 'sort -V' "$WF" | awk '$1>0{print "yes"}')" "yes"

echo "== DIVE-2466: the guard POLLS instead of refusing on the first look =="
# A nightly that lands while CI on the newest merge is still running used to skip the
# whole day. These arms drive the extracted block with a STUBBED _ci_fetch_runs that
# hands back a different board on each look, so what is graded is the retry itself and
# not a re-implementation of it. The stub is why the block defines the fetch as a
# function outside the fence: with no stub these would hit the network, and a deleted
# stub fails loudly rather than quietly grading one look.
POLLDIR=$(mktemp -d /tmp/relcut-poll.XXXXXX)

poll_run(){ # $1.. = one check-runs fixture per look ; echoes "<verdict> looks=<n>"
  local i=0 f out rc
  rm -f "$POLLDIR"/look.* "$POLLDIR"/n
  for f in "$@"; do i=$((i+1)); printf '%s' "$f" > "$POLLDIR/look.$i"; done
  printf '1' > "$POLLDIR/n"
  # Budget 30s at a 1s interval: enough looks to settle, short enough that a REGRESSION
  # (a guard that waits when it should not) shows up as a slow test rather than a hang.
  # Past the last fixture the stub REPEATS the final board rather than running dry.
  # First cut of this returned empty once the list was exhausted, and the guard read
  # that — correctly — as NOT-REACHED, so the never-settles arm graded the stub's
  # bug and not the guard's behaviour.
  out=$(runs="$1" sha=deadbeefcafe tag=v9.9.9 POLLDIR="$POLLDIR" NFIX="$#" \
        GITHUB_RUN_ID="${POLL_RUNID:-}" \
        RELEASE_CUT_POLL_SECONDS="${POLL_BUDGET:-30}" RELEASE_CUT_POLL_INTERVAL=1 bash -c '
    set -uo pipefail
    _ci_fetch_runs(){
      local n; n=$(cat "$POLLDIR/n"); n=$((n+1))
      (( n > NFIX )) && n=$NFIX
      printf "%s" "$n" > "$POLLDIR/n"
      cat "$POLLDIR/look.$n" 2>/dev/null
    }
    '"$GUARD"'
  ' 2>&1); rc=$?
  local looks; looks=$(grep -c '\[look ' <<<"$out")
  local v
  if (( rc != 0 )); then
    if   grep -q 'CI NOT REACHED'    <<<"$out"; then v=NOT-REACHED
    elif grep -q 'CI still IN FLIGHT' <<<"$out"; then v=IN-FLIGHT
    elif grep -q 'CI is RED'          <<<"$out"; then v=RED
    else v="OTHER-FAIL"; fi
  else
    grep -q 'CI green on' <<<"$out" && v=GREEN || v="OTHER-OK"
  fi
  echo "$v looks=$looks"
}

INFLIGHT=$(printf 'test\tin_progress\tpending\nscan\tcompleted\tsuccess')
GREENB=$(printf 'test\tcompleted\tsuccess\nscan\tcompleted\tsuccess')
REDB=$(printf 'test\tcompleted\tfailure\nscan\tcompleted\tsuccess')

# THE WHOLE POINT OF THE TICKET: in-flight on the first look must not end the day.
ok "in-flight then green -> GREEN on the 2nd look" "$(poll_run "$INFLIGHT" "$GREENB")" "GREEN looks=2"
# The branch that is easy to miss: zero check-runs also polls. Its own error text used
# to tell a human to "let it complete, then re-run this job" — the retry it declined.
ok "zero check-runs then green -> GREEN"           "$(poll_run "" "$GREENB")"           "GREEN looks=2"
ok "in-flight twice then green -> GREEN"           "$(poll_run "$INFLIGHT" "$INFLIGHT" "$GREENB")" "GREEN looks=3"
# RED IS FINAL AND IS NEVER WAITED OUT — one look, even with 30s of budget left.
ok "RED refuses IMMEDIATELY, one look, no waiting" "$(poll_run "$REDB" "$GREENB")"      "RED looks=1"
# A red that appears LATER must still stop the cut rather than being polled past.
ok "in-flight then RED -> RED"                     "$(poll_run "$INFLIGHT" "$REDB")"    "RED looks=2"
# Fail-closed survives: an expiry is still a non-zero refusal, with the same message.
# A short budget here: the assertion is that expiry REFUSES, not how long it waits.
ok "never settles -> still refuses at the deadline" "$(POLL_BUDGET=3 poll_run "$INFLIGHT" | cut -d' ' -f1)" "IN-FLIGHT"
ok "never reached -> still refuses at the deadline" "$(POLL_BUDGET=3 poll_run "" | cut -d' ' -f1)" "NOT-REACHED"

echo "== DIVE-2466: an UNATTRIBUTABLE red is deferred, not acted on =="
# The window nobody had exercised. Every poll arm above runs with GITHUB_RUN_ID UNSET,
# so the self/sibling filter never engages in them; every sibling arm above hands the
# board over in ONE look, so the filter always has the self row. The race lives in the
# intersection: filter ON, self row NOT YET in the board. Then `_self_name` is empty,
# sibling `cut` rows are not dropped, and the RED branch used to exit on look 1 before
# any re-fetch could find the self row — the self-latching poison this ticket exists to
# kill, alive in the one place the suite could not see.
# MEASURED against the pristine block 2026-08-02: RED, looks=1, rc=1.
RACE_L1=$(printf 'scan\tcompleted\tsuccess\t%s\ncut\tcompleted\tfailure\t%s' "$OTHER_URL" "$SIB_URL")
RACE_L2=$(printf 'scan\tcompleted\tsuccess\t%s\ncut\tcompleted\tfailure\t%s\ncut\tin_progress\tpending\t%s' "$OTHER_URL" "$SIB_URL" "$SELF_URL")
# DIVE-3314 RETUNED, DELIBERATELY: 2 -> 3. `looks` counts '[look ' lines, and a deferral
# prints a second one in the same iteration, so the old "GREEN looks=2" was ONE iteration:
# the block deferred the red and then broke out GREEN on that same pass, because the green
# test asked only "all completed?" and never "and nothing bad?". The verdict was right by
# luck — the outstanding row was the sibling corpse — but a deferred red reaching the green
# branch at all is the hole DIVE-3314 closes, and it is load-bearing on a re-targeted sha
# where our own in_progress row is not there to keep `incomplete` non-empty. It now does
# what its own name says: defers on look 1, re-reads, drops the sibling on look 2 (2+1=3).
ok "self row absent on look 1 -> defer the red, drop the sibling on look 2" \
   "$(POLL_RUNID=30332498204 poll_run "$RACE_L1" "$RACE_L2")" "GREEN looks=3"
# The deferral must NOT have widened into "ignore reds while unattributable forever":
# once our own row is present the sibling is droppable and a THIRD-PARTY red still bites.
RACE_REAL=$(printf 'test\tcompleted\tfailure\t%s\ncut\tin_progress\tpending\t%s' "$OTHER_URL" "$SELF_URL")
ok "a third-party red still REFUSES once the self row is visible" \
   "$(POLL_RUNID=30332498204 poll_run "$RACE_REAL" "$RACE_REAL")" "RED looks=1"
# And with no run id at all the deferral is inert — unchanged behaviour for that path.
ok "no GITHUB_RUN_ID -> a red is still immediate" \
   "$(poll_run "$REDB" "$GREENB")" "RED looks=1"

echo "== DIVE-2466: the poll budget is a CEILING the env knob can only tighten =="
# A caller that could WIDEN it could park this job on a runner for hours. Tightening is
# the safe direction; widening and garbage both fall back to the hardcoded ceiling.
clamp(){ RELEASE_CUT_POLL_SECONDS="$1" bash -c '
  set -uo pipefail
  _POLL_CEILING=2700
  _poll_max="${RELEASE_CUT_POLL_SECONDS:-$_POLL_CEILING}"
  [[ "$_poll_max" =~ ^[0-9]+$ ]] || _poll_max="$_POLL_CEILING"
  (( _poll_max > _POLL_CEILING )) && _poll_max="$_POLL_CEILING"
  echo "$_poll_max"'; }
ok "a smaller budget is honoured (tighten)"   "$(clamp 120)"      "120"
ok "a larger budget CLAMPS to the ceiling"    "$(clamp 99999)"    "2700"
ok "a non-numeric budget falls back, not 0"   "$(clamp 'abc')"    "2700"
# And the ceiling is really in the shipped file, not only in this harness's copy.
ok "the ceiling is hardcoded in the workflow" "$(grep -c '_POLL_CEILING=2700' "$WF")" "1"

echo "== DIVE-2466 ARM 1: the cron is off the top of the hour, and armed twice =="
ok "no cron at the top of an hour"  "$(grep -cE "cron: '0 " "$WF")" "0"
ok "two schedule entries"           "$(grep -cE "^    - cron: '" "$WF")" "2"

echo "== DIVE-3314: a sha ABANDONED by a newer merge is re-targeted, not refused forever =="
# full-sweep collapses the older of two close merges into the newer tip's run BY DESIGN,
# so an overtaken sha's verdict never arrives and a cut pointed at it refuses PERMANENTLY.
# Measured 2026-08-12: v0.19.26 uncut on run 31563209367 with three `cancelled`
# harness-verdict rows, 3 of the last 4 pushes to main cancelled the same way.
# `_retarget_tip` is stubbed here for the same reason `_ci_fetch_runs` is: the block must
# not reach git or the network from a unit harness, and its absence must REFUSE, not cut.
retarget_run(){ # $1 = tip the stub offers ('' = none) ; $2.. = one fixture per look
  local tip="$1"; shift
  local i=0 f out rc
  rm -f "$POLLDIR"/look.* "$POLLDIR"/n
  for f in "$@"; do i=$((i+1)); printf '%s' "$f" > "$POLLDIR/look.$i"; done
  printf '1' > "$POLLDIR/n"
  out=$(runs="$1" sha=deadbeefcafe tag=v9.9.9 POLLDIR="$POLLDIR" NFIX="$#" TIP="$tip" \
        GITHUB_RUN_ID="${POLL_RUNID:-}" cut_from="${CUT_FROM:-}" \
        RELEASE_CUT_POLL_SECONDS="${POLL_BUDGET:-30}" RELEASE_CUT_POLL_INTERVAL=1 bash -c '
    set -uo pipefail
    _ci_fetch_runs(){
      local n; n=$(cat "$POLLDIR/n"); n=$((n+1))
      (( n > NFIX )) && n=$NFIX
      printf "%s" "$n" > "$POLLDIR/n"
      cat "$POLLDIR/look.$n" 2>/dev/null
    }
    _retarget_tip(){ [[ -n "$TIP" ]] && printf "%s\n" "$TIP"; return 0; }
    '"$GUARD"'
  ' 2>&1); rc=$?
  local n_rt; n_rt=$(grep -c 'Re-targeting the cut' <<<"$out")
  local v
  if (( rc != 0 )); then
    if   grep -q 'CI NOT REACHED'    <<<"$out"; then v=NOT-REACHED
    elif grep -q 'CI still IN FLIGHT' <<<"$out"; then v=IN-FLIGHT
    elif grep -q 'CI is RED'          <<<"$out"; then v=RED
    else v="OTHER-FAIL:$out"; fi
  else
    if   grep -q 'CI green on'         <<<"$out"; then v=GREEN
    elif grep -q 'nothing to publish'  <<<"$out"; then v=NOTHING
    else v="OTHER-OK:$out"; fi
  fi
  echo "$v retargets=$n_rt"
}
# The three cancelled harness-verdict rows of run 31563209367, verbatim in shape.
CANCELLED=$(printf 'test\tcompleted\tsuccess\nharness-verdict-union\tcompleted\tcancelled\nharness-verdict-installed\tcompleted\tcancelled\nharness-verdict-pristine\tcompleted\tcancelled')
NEWTIP=ef471d6a1111
# THE TICKET: the abandoned sha is re-graded at the descendant that subsumed it.
ok "all-cancelled + a descendant tip -> retarget, then GREEN on the descendant" \
   "$(retarget_run "$NEWTIP" "$CANCELLED" "$GREENB")" "GREEN retargets=1"
# NO descendant (main did not move) -> the pre-DIVE-3314 behaviour EXACTLY. `cancelled`
# on a sha nothing overtook is a red with no excuse and must still refuse on look 1.
ok "all-cancelled + NO newer tip -> still RED, immediately, no retarget" \
   "$(retarget_run "" "$CANCELLED" "$GREENB")" "RED retargets=0"
# The narrowness that makes this safe: only a MISSING verdict is retargetable. A real
# failure sitting beside the cancellations refuses even though a descendant is on offer.
CANCELLED_PLUS_RED=$(printf 'harness-verdict-union\tcompleted\tcancelled\nfull-shard-3\tcompleted\tfailure')
ok "a genuine failure among the cancellations -> RED even with a descendant available" \
   "$(retarget_run "$NEWTIP" "$CANCELLED_PLUS_RED" "$GREENB")" "RED retargets=0"
ok "timed_out is not a cancellation -> RED with a descendant available" \
   "$(retarget_run "$NEWTIP" "$(printf 'harness-verdict-union\tcompleted\ttimed_out')" "$GREENB")" "RED retargets=0"
# The descendant's own verdict is graded, not assumed: a red THERE still refuses.
ok "retarget onto a descendant that is itself RED -> refuses" \
   "$(retarget_run "$NEWTIP" "$CANCELLED" "$REDB")" "RED retargets=1"
# ...and an in-flight descendant is waited for, which is the entire point of retargeting.
ok "retarget onto an in-flight descendant -> polls, then GREEN" \
   "$(retarget_run "$NEWTIP" "$CANCELLED" "$INFLIGHT" "$GREENB")" "GREEN retargets=1"
# BOUNDED. A main merging faster than a sweep completes must refuse, not chase forever.
ok "a main that keeps moving is chased at most twice, then REFUSES" \
   "$(retarget_run "$NEWTIP" "$CANCELLED")" "RED retargets=2"
ok "the cap is hardcoded in the workflow"  "$(grep -c '_RETARGET_MAX=2' "$WF")" "1"
# The retarget re-opens "has main moved?", so the answer is re-asserted: if the tip we
# would move to is the commit the incumbent tag was already cut from, publish nothing.
ok "descendant == the incumbent's cut_from -> exit 0, publish nothing" \
   "$(CUT_FROM="$NEWTIP" retarget_run "$NEWTIP" "$CANCELLED" "$GREENB")" "NOTHING retargets=0"
# --- main's three merge-gate checks, 2026-08-12, pinned as arms ---------------
# (1) CANCELLED vs QUEUED (dev's catch). cancelled = no verdict will ever exist; queued = one is
# coming. THIS ARM FAILED WHEN FIRST WRITTEN and bought the `-z "$incomplete"` precondition: a
# queued row is `$2 != completed`, so it is not in `bad` and condition 1 CANNOT SEE IT — the board
# retargeted twice while work on the sha being abandoned was still running, which is exactly the
# impatient-hop main named. The retarget now requires a SETTLED board, so this refuses instead.
CANCELLED_PLUS_QUEUED=$(printf 'harness-verdict-union\tcompleted\tcancelled\nharness-verdict-slow\tqueued\tpending')
# DIVE-3941 CHANGED THE VERDICT STRING HERE AND NOT THE PROPERTY. Both halves of what
# this arm was bought to pin still hold: it does NOT retarget (retargets=0), and it does
# NOT publish (`retarget_run` only ever reports IN-FLIGHT on rc != 0, i.e. a refusal).
# What changed is WHICH refusal: an all-cancelled red beside a live board is now waited
# out to the deadline instead of refused on look 1, because `cancelled` is an absent
# verdict and the queued row is the thing producing the real one. The impatient hop this
# arm was written against is still impossible.
ok "a QUEUED row beside cancellations -> REFUSES at the deadline, never retargets" \
   "$(POLL_BUDGET=3 retarget_run "$NEWTIP" "$CANCELLED_PLUS_QUEUED")" "IN-FLIGHT retargets=0"
ok "...and the same board with the queued row FINISHED does retarget (the control)" \
   "$(retarget_run "$NEWTIP" "$(printf 'harness-verdict-union\tcompleted\tcancelled\nharness-verdict-slow\tcompleted\tsuccess')" "$GREENB")" "GREEN retargets=1"
ok "the settled-board precondition is in the workflow" \
   "$(grep -c 'z "\$_uncancelled" \]\] && (( _ncancelled > 0 )) && \[\[ -z "\$incomplete"' "$WF")" "1"
# (2) TERMINATION AT THE DESCENDANT. The red case is arm'd above; this is the other half — an
# in-flight descendant is polled to the deadline and refused there. It does NOT walk further.
ok "a descendant that never settles -> refuses at the deadline, no second hop" \
   "$(POLL_BUDGET=4 retarget_run "$NEWTIP" "$CANCELLED" "$INFLIGHT")" "IN-FLIGHT retargets=1"
# (3) VACUOUS-TRUE ON AN EMPTY SET. "every red is cancelled" is true of no reds at all, and
# DIVE-2867 is a cut printing 'CI is RED ... Failing:' with an empty list. The block now counts
# cancellations positively; the shape that can reach it looking empty is a bad row with a BLANK
# conclusion, which must refuse rather than retarget.
ok "a red row with a BLANK conclusion -> RED, never retargets on nothing" \
   "$(retarget_run "$NEWTIP" "$(printf 'ghost\tcompleted\t')" "$GREENB")" "RED retargets=0"
# DIVE-3941: TWO branches now consume the positive count -- the retarget (settled board)
# and the deferral (unsettled board). The number is the point: if a third consumer appears
# without an arm, or one of these two loses its count and goes vacuous-true on an empty
# set, this moves.
ok "the positive cancellation count is in the workflow, once per consumer" \
   "$(grep -c '(( _ncancelled > 0 ))' "$WF")" "2"


echo "== DIVE-3941: a cancellation SUPERSEDED on the same sha is not a red, and a cancelled-only red on a LIVE board is waited out =="
# MEASURED 2026-09-03, run 33732579500. full-sweep's concurrency group is keyed on the REF,
# not the sha, so the daily scheduled sweep and the `push: main` sweep for the SAME commit
# collide: the scheduled one cancelled the push one (8 `harness-verdict-*` rows) and then
# completed SUCCESS on the identical tree 19 minutes later. The cut read the 8 corpses,
# found no descendant to retarget to (main never moved), and refused in 11s. That refusal
# is PERMANENT — nothing can ever clear a cancelled row from a sha's board — so main's tip
# was latched uncuttable while main was green. Two independent fixes, graded separately.
#
# (A) SUPERSESSION. Settled boards only, so `verdict()`'s single look is the right driver
# and no retarget stub is needed (its absence refuses, which every arm below relies on).
SUP_GREEN=$(printf 'harness-verdict-slow\tcompleted\tcancelled\nharness-verdict-slow\tcompleted\tsuccess\ntest\tcompleted\tsuccess')
ok "cancelled + a same-name SUCCESS on the same sha -> GREEN (the 09-03 board)" \
   "$(verdict "$SUP_GREEN")" "GREEN"
# THE ARM THAT MAKES (A) SAFE. A `failure` is itself completed and non-cancelled, so it
# supersedes the cancellation and then stays in `bad` on its own account. Supersession can
# narrow WHICH rows are red; it can never make a real red green.
ok "cancelled + a same-name FAILURE -> RED, never green" \
   "$(verdict "$(printf 'harness-verdict-slow\tcompleted\tcancelled\nharness-verdict-slow\tcompleted\tfailure')")" "RED"
# NAME-SCOPED. A completed row under a DIFFERENT name says nothing about this one.
ok "cancelled + a success under a DIFFERENT name -> RED" \
   "$(verdict "$(printf 'harness-verdict-slow\tcompleted\tcancelled\ntest\tcompleted\tsuccess')")" "RED"
# THE CONTROL, and it is the pre-DIVE-3941 behaviour verbatim: with no completed sibling
# the cancellation is left exactly as red as it was.
ok "cancelled with NO sibling row -> RED, unchanged" \
   "$(verdict "$(printf 'harness-verdict-slow\tcompleted\tcancelled\ntest\tcompleted\tsuccess\nscan\tcompleted\tsuccess')")" "RED"
ok "cancelled + a same-name SKIPPED -> GREEN (skipped is already a verdict here)" \
   "$(verdict "$(printf 'shard\tcompleted\tcancelled\nshard\tcompleted\tskipped\ntest\tcompleted\tsuccess')")" "GREEN"
# ONLY A COMPLETED ROW SUPERSEDES. A re-run of the same name still IN FLIGHT is not a
# verdict either, so the board is unsettled and (B) waits rather than publishing.
ok "cancelled + the same name still in_progress -> not superseded, waits, then refuses" \
   "$(POLL_BUDGET=3 retarget_run "" "$(printf 'shard\tcompleted\tcancelled\nshard\tin_progress\tpending')")" "IN-FLIGHT retargets=0"
#
# (B) DEFERRAL. The 09-03 replay: look 1 is what the cut actually read at 08:17:54Z (the
# cancellations beside a sweep still running), look 2 is the same board after that sweep
# finished at 08:36:29Z. The fix is that look 2 is ever reached.
D3941_L1=$(printf 'harness-verdict-slow\tcompleted\tcancelled\nharness-verdict-union\tcompleted\tcancelled\nfull-pristine (3)\tin_progress\tpending\ntest\tcompleted\tsuccess')
D3941_L2=$(printf 'harness-verdict-slow\tcompleted\tcancelled\nharness-verdict-union\tcompleted\tcancelled\nharness-verdict-slow\tcompleted\tsuccess\nharness-verdict-union\tcompleted\tsuccess\nfull-pristine (3)\tcompleted\tsuccess\ntest\tcompleted\tsuccess')
ok "the 2026-09-03 board: cancelled beside a live sweep -> polls, then GREEN, no retarget" \
   "$(retarget_run "" "$D3941_L1" "$D3941_L2")" "GREEN retargets=0"
# THE NARROWNESS. One genuine failure beside the cancellations and the deferral is not
# entered at all: refuse now, on look 1, exactly as before.
ok "a genuine failure beside cancelled+in-flight -> RED immediately, never deferred" \
   "$(retarget_run "" "$(printf 'harness-verdict-slow\tcompleted\tcancelled\nfull-shard-3\tcompleted\tfailure\nfull-pristine (3)\tin_progress\tpending')" "$D3941_L2")" "RED retargets=0"
# FAIL-CLOSED. A board that never settles refuses at the deadline; nothing publishes.
ok "cancelled + a board that never settles -> refuses at the deadline" \
   "$(POLL_BUDGET=3 retarget_run "" "$D3941_L1")" "IN-FLIGHT retargets=0"
# ...and the deferral must not eat the SETTLED all-cancelled case, which is the retarget's.
ok "a SETTLED all-cancelled board with no descendant still refuses on look 1" \
   "$(retarget_run "" "$CANCELLED" "$GREENB")" "RED retargets=0"

# A deferred red must never fall through the green test. Before DIVE-3314 the only thing
# stopping that was our own in_progress row keeping `incomplete` non-empty — a property of
# the sha we were TRIGGERED on, which a re-targeted sha does not have.
DEFERRED_ALL_DONE=$(printf 'scan\tcompleted\tsuccess\t%s\ncut\tcompleted\tfailure\t%s' "$OTHER_URL" "$SIB_URL")
ok "a deferred red on a fully-completed board is NOT green" \
   "$(POLL_RUNID=30332498204 POLL_BUDGET=3 poll_run "$DEFERRED_ALL_DONE" | cut -d' ' -f1)" "IN-FLIGHT"

echo "== non-vacuity: each guard must RED when mutated =="
# DIVE-2238: this helper used to announce a no-op mutation with `echo` and bump
# `fail` — but every call site is `m=$(mutate ...)`, so the warning was CAPTURED
# INTO THE VARIABLE instead of printed, and the increment happened in a subshell
# and was discarded. A mutation that stopped applying therefore made its whole arm
# VANISH: no FAIL, no ok, just one fewer assertion in a total nobody diffs. That is
# the vacuous-control shape (community/wiki/a-vacuously-passing-control-is-invisible-in-a-failure-list.md)
# living inside the machinery written to prevent it. Measured: running this suite
# against the pre-fix workflow printed "20 passed, 2 failed" — 22 of 23 arms, with
# the 23rd gone silently. The warning now goes to STDERR (never capturable into $m)
# and each call site registers its own explicit failure.
mutate(){ # $1 = sed expr applied to the extracted block var named by $2
  local expr="$1" var="$2" before after
  before="${!var}"
  after=$(sed "$expr" <<<"$before")
  [[ "$after" == "$before" ]] && { printf 'mutation did not apply: %s\n' "$expr" >&2; return 1; }
  printf '%s' "$after"
}
vacuous(){ fail=$((fail+1)); echo "FAIL - $1: mutation did not apply, so this arm graded NOTHING (VACUOUS)"; }

# (a) drop the zero-check: absence must stop reading as green
if m=$(mutate 's/if (( total == 0 )); then/if false; then/' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop zero-check: empty runs no longer NOT-REACHED" \
     "$([[ "$(verdict "")" == "NOT-REACHED" ]] && echo caught-nothing || echo mutant-detected)" "mutant-detected"
  GUARD="$GUARD_SAVE"
else
  vacuous "drop zero-check"
fi
# (a2b) DIVE-2466: drop the SIBLING filter — the poisoned re-arm must come back.
# Without this arm the sibling exclusion is unpinned and a refactor removes it silently,
# which is how the original gap survived a 37/0 suite.
if m=$(mutate 's|runs=$(awk -F.\\t. -v jn="$_self_name" ..1 != jn. <<<"$runs")|:|' GUARD); then
  ok "MUTANT drop sibling filter: poisoned re-arm returns" \
     "$(GUARD="$m" verdict_run "$FOREIGN_CUT" '30332498204')" "RED"
else
  vacuous "drop sibling filter"
fi

# (a2) DIVE-2238: drop the self-filter — the job must go back to blocking on itself.
# This is the arm that proves the fix is load-bearing rather than decorative: before
# the fix this fixture returned IN-FLIGHT and the job could never publish.
if m=$(mutate 's|if \[\[ -n "${GITHUB_RUN_ID:-}" \]\]; then|if false; then|' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop self-filter: job blocks on itself again" \
     "$([[ "$(verdict_run "$SELF_INFLIGHT" 30332498204)" == "GREEN" ]] && echo caught-nothing || echo mutant-detected)" "mutant-detected"
  GUARD="$GUARD_SAVE"
else
  vacuous "drop self-filter"
fi
# (b) drop the in-flight arm: a running check must stop reading as green
if m=$(mutate '/incomplete=\$(awk/s/\$2 != "completed"/1==0/' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop in-flight arm: running check no longer IN-FLIGHT" \
     "$([[ "$(verdict "$(printf 'test\tin_progress\tpending')")" == "IN-FLIGHT" ]] && echo caught-nothing || echo mutant-detected)" "mutant-detected"
  GUARD="$GUARD_SAVE"
else
  vacuous "drop in-flight arm"
fi
# (c) lexical sort: this is olivia's measured v0.9.9 downgrade, in the cutter
if m=$(mutate 's/sort -V/sort/' SORTA); then
  SORTA_SAVE="$SORTA"; SORTA="$m"
  ok "MUTANT lexical sort: v0.9.9 stops being refused" \
     "$(cut_decision v0.15.34 v0.9.9)" "CUT"
  SORTA="$SORTA_SAVE"
else
  vacuous "lexical sort"
fi

# (d) DIVE-2466: drop the RE-READ. The loop still spins, but on stale bytes, so a
# board that goes green on look 2 is never seen and the day is skipped exactly as
# before the fix. This is the arm that proves the polling is the fix rather than the
# loop being decorative.
# (a4) DIVE-2466: remove the unattributable-red deferral — the latch must return.
# Without this arm the deferral is unpinned and the next refactor re-introduces a
# permanent self-latch that only fires on a race nobody reproduces by hand.
if m=$(mutate 's|if \[\[ -n "$bad" && -n "${GITHUB_RUN_ID:-}" && -z "$_self_name" \]\]; then|if false; then|' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop the unattributable-red deferral: the latch returns" \
     "$(POLL_RUNID=30332498204 poll_run "$RACE_L1" "$RACE_L2")" "RED looks=1"
  GUARD="$GUARD_SAVE"
else
  vacuous "drop the unattributable-red deferral"
fi

# (a5) DIVE-3941: remove the SUPERSESSION filter — the 2026-09-03 latch must return.
# Without this arm the filter is unpinned, and what comes back is not a red build: it is a
# sha that can never be cut again, which no board row can see.
if m=$(mutate 's|if \[\[ -n "$_superseded" \]\]; then|if false; then|' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop the supersession filter: the 09-03 board latches red again" \
     "$(verdict "$SUP_GREEN")" "RED"
  GUARD="$GUARD_SAVE"
else
  vacuous "drop the supersession filter"
fi
# (a6) DIVE-3941: remove the CANCELLED-ONLY DEFERRAL. The board still goes green on look 2;
# the mutant is that look 2 is never reached, which is precisely how the 08:17Z run refused
# in 11 seconds while the verdict it wanted was 19 minutes out.
if m=$(mutate 's|elif \[\[ -n "$bad" && -z "$_uncancelled" \]\]|elif [[ -z "$bad" ]]|' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop the cancelled-only deferral: the 09-03 replay refuses on look 1" \
     "$(retarget_run "" "$D3941_L1" "$D3941_L2")" "RED retargets=0"
  GUARD="$GUARD_SAVE"
else
  vacuous "drop the cancelled-only deferral"
fi

if m=$(mutate 's/runs=\$(_ci_fetch_runs)$/:/' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop the re-read: in-flight then green stops reaching GREEN" \
     "$([[ "$(poll_run "$INFLIGHT" "$GREENB")" == "GREEN looks=2" ]] && echo caught-nothing || echo mutant-detected)" "mutant-detected"
  GUARD="$GUARD_SAVE"
else
  vacuous "drop the re-read"
fi

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
