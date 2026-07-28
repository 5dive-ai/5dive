#!/usr/bin/env bash
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
verdict(){ # $1 = check-runs TSV ; echoes NOT-REACHED|IN-FLIGHT|RED|GREEN
  local out rc
  out=$(runs="$1" sha=deadbeefcafe tag=v9.9.9 bash -c "
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

echo "== non-vacuity: each guard must RED when mutated =="
mutate(){ # $1 = sed expr applied to the extracted block var named by $2
  local expr="$1" var="$2" before after
  before="${!var}"
  after=$(sed "$expr" <<<"$before")
  [[ "$after" == "$before" ]] && { echo "FAIL - mutation '$expr' did not apply (arm is VACUOUS)"; fail=$((fail+1)); return 1; }
  printf '%s' "$after"
}

# (a) drop the zero-check: absence must stop reading as green
if m=$(mutate 's/if (( total == 0 )); then/if false; then/' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop zero-check: empty runs no longer NOT-REACHED" \
     "$([[ "$(verdict "")" == "NOT-REACHED" ]] && echo caught-nothing || echo mutant-detected)" "mutant-detected"
  GUARD="$GUARD_SAVE"
fi
# (b) drop the in-flight arm: a running check must stop reading as green
if m=$(mutate '/incomplete=\$(awk/s/\$2 != "completed"/1==0/' GUARD); then
  GUARD_SAVE="$GUARD"; GUARD="$m"
  ok "MUTANT drop in-flight arm: running check no longer IN-FLIGHT" \
     "$([[ "$(verdict "$(printf 'test\tin_progress\tpending')")" == "IN-FLIGHT" ]] && echo caught-nothing || echo mutant-detected)" "mutant-detected"
  GUARD="$GUARD_SAVE"
fi
# (c) lexical sort: this is olivia's measured v0.9.9 downgrade, in the cutter
if m=$(mutate 's/sort -V/sort/' SORTA); then
  SORTA_SAVE="$SORTA"; SORTA="$m"
  ok "MUTANT lexical sort: v0.9.9 stops being refused" \
     "$(cut_decision v0.15.34 v0.9.9)" "CUT"
  SORTA="$SORTA_SAVE"
fi

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
