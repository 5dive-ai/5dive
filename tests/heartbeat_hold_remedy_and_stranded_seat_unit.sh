#!/usr/bin/env bash
# DIVE-3501 unit: the tier guard's all-held branch — its ADVICE, and its VISIBILITY.
#
# THE DEFECTS. DIVE-1065 holds a row whose creator ranks below its assignee, and
# DIVE-2716 taught the picker to step PAST a held row. Neither addressed the case
# where EVERY candidate is held, and that case had three faults at once:
#
#   D1  the all-held branch named no remedy — it is the branch that strands a
#       seat forever and it was the one with no advice;
#   D2  the advice that DID exist (on the sibling scan-cap branch) named a `task`
#       subcommand that does not exist anywhere in the CLI except in that one
#       sentence, so following the guard's own advice produced an
#       unknown-subcommand error;
#   D3  a held row was invisible outside the log: status stays `todo`, the unit
#       reads `active`, quota is healthy. Measured 2026-08-16: dev2 held 5
#       runnable high rows every 5 minutes for six days, 7865 log lines, and no
#       surface anywhere said so.
#
# WHAT IS ASSERTED HERE
#   A. RUNTIME-GRADED VERB CHECK. Every `5dive <verb> <sub>` named in a LOG
#      STRING in src/cmd_heartbeat.sh is a subcommand the CLI's own `--help`
#      prints AT RUNTIME. The verb list is never hardcoded in this file: a
#      hand-maintained array is the same defect one layer up — it goes stale
#      silently and the test stays green. Positive control included: a fabricated
#      verb must be REJECTED by the same matcher, or the matcher proves nothing.
#   B. Both hold branches name at least one exit, and `heartbeat --help`
#      documents `wake-task` (which is dispatched and already called by
#      cmd_loop.sh, but was undocumented).
#   C. The stranded-seat predicate (cmd_heartbeat_held), extracted VERBATIM from
#      src/cmd_heartbeat.sh and driven with stubbed db()/_hb_pick_tasks()/
#      registry_read(): it fires only when EVERY runnable row is held AND the
#      seat is stale, and it reports the held idents.
#   D. MUTATION GRADE (acceptance #4 — grade absence assertions by mutation, not
#      by a green run). Each clause of the predicate is broken INDEPENDENTLY in
#      the extracted copy and arm C must go red on each: the rank comparison, the
#      "every" quantifier, and the staleness floor. A surfacing test that cannot
#      be made to fail is not evidence that it surfaces anything.
#
# NOT MEASURED, declared: this does NOT run a live tick, and it does not render a
# digest. It grades the predicate's decision and the advice strings. That the
# digest CONSUMES the predicate is asserted structurally (arm B4), not by running
# `digest`, which needs a real store and root.
#
# Pure: fixtures in a tmpdir, no root, no network, no tmux, no live db. Builds a
# throwaway bundle (~0.1s) only to read the CLI's own --help.
#   bash tests/heartbeat_hold_remedy_and_stranded_seat_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; return 0; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n' "$1"; }

HB_SRC=src/cmd_heartbeat.sh
DG_SRC=src/cmd_digest.sh

# ---------------------------------------------------------------------------
# A. Runtime-graded verb check.
# ---------------------------------------------------------------------------
# "Log string" = a string on a line that emits (`_hb_log` / `printf`). Scoped
# that way deliberately: comments in this file discuss the retired bad advice by
# name, and a whole-file scan would grade PROSE, not what an operator is told.
_log_verb_pairs() {
  grep -nE '_hb_log|printf' "$HB_SRC" \
    | grep -oE '5dive [a-z][a-z0-9-]+ [a-z][a-z0-9-]+' | sort -u
}

BUNDLE="$TMP/5dive-under-test"
if BUILD_OUT="$BUNDLE" bash ./build.sh >/dev/null 2>&1 && [[ -s "$BUNDLE" ]]; then
  # The verb list comes from the CLI, at runtime, every run.
  _help_of() { bash "$BUNDLE" "$1" --help 2>&1; }
  _verb_known() {  # <top> <sub> -> 0 if `5dive <top> --help` prints <sub>
    local top="$1" sub="$2" help
    help="$(_help_of "$top")" || return 1
    grep -qE "(^|[^a-z0-9-])${sub}([^a-z0-9-]|$)" <<<"$help"
  }

  # POSITIVE CONTROL FIRST. Every way this arm can break — a bundle that fails to
  # run, an empty help, a matcher that matches anything — presents as "no bad
  # verbs found". So the matcher must first REJECT a verb that cannot exist. The
  # string is assembled at runtime so this file never itself contains a plausible
  # bad-verb literal for the next reader to copy.
  _fake="auth""orize-nonexistent-verb"
  if _verb_known task "$_fake"; then
    bad_t "A0 positive control: matcher accepts a fabricated task subcommand — arm A proves nothing"
  else
    ok_t "A0 positive control: the matcher rejects a fabricated subcommand"
  fi

  _pairs="$(_log_verb_pairs)"
  if [[ -z "$_pairs" ]]; then
    bad_t "A1 no '5dive <verb> <sub>' found in any log string" \
          "the advice was removed, or the scan stopped seeing log lines — either way the guard is unadvised"
  else
    _bad=0
    while read -r _ top sub; do
      [[ -n "${sub:-}" ]] || continue
      if _verb_known "$top" "$sub"; then
        ok_t "A1 log advice names a real verb: 5dive $top $sub"
      else
        _bad=1
        bad_t "A1 log string advises '5dive $top $sub', which '5dive $top --help' does not list" \
              "an operator following the guard's own advice gets an unknown-subcommand error (this is D2)"
      fi
    done <<<"$_pairs"
    (( _bad == 0 )) && ok_t "A2 no log string in $HB_SRC names a nonexistent verb"
  fi

  # B2 — wake-task documented (acceptance #2).
  if _verb_known heartbeat wake-task; then
    ok_t "B2 'heartbeat --help' documents wake-task"
  else
    bad_t "B2 'heartbeat --help' does not mention wake-task" \
          "it is dispatched (cmd_heartbeat.sh) and called by cmd_loop.sh, so undocumented = unfindable"
  fi
  if _verb_known heartbeat held; then
    ok_t "B3 'heartbeat --help' documents the stranded-seat source (held)"
  else
    bad_t "B3 'heartbeat --help' does not document 'held'" \
          "adding an undocumented verb repeats exactly the defect this ticket is about"
  fi
else
  skip_t "A/B runtime verb check — could not build a throwaway bundle (BUILD_OUT=./build.sh)"
fi

# ---------------------------------------------------------------------------
# B1. Both hold branches name an exit.
# ---------------------------------------------------------------------------
_allheld_line="$(grep -n 'tier guard held all .* runnable todo' "$HB_SRC" | head -1)"
_scancap_line="$(grep -n 'candidate(s) SCANNED' "$HB_SRC" | head -1)"
for _pair in "all-held:$_allheld_line" "scan-cap:$_scancap_line"; do
  _which="${_pair%%:*}"; _ln="${_pair#*:}"
  if [[ -z "$_ln" ]]; then
    bad_t "B1 the $_which branch log line was not found in $HB_SRC"
  elif grep -q '5dive task assign' <<<"$_ln" && grep -q '5dive heartbeat wake-task' <<<"$_ln"; then
    ok_t "B1 the $_which branch names both real exits"
  else
    bad_t "B1 the $_which branch names no exit (D1)" "line: ${_ln:0:120}"
  fi
done

# B4 — the digest actually consumes the predicate (structural; the render is not
# run here). Both halves: the source is invoked, and the seats reach the output.
if grep -q 'heartbeat held --json' "$DG_SRC" && grep -q 'held_seats' "$DG_SRC"; then
  ok_t "B4 the digest reads 'heartbeat held --json' and renders/reports the seats"
else
  bad_t "B4 the digest does not consume the stranded-seat source" \
        "acceptance #3 is 'observable from the digest'; a source with no reader is not a surface"
fi

# ---------------------------------------------------------------------------
# C/D. The predicate itself, extracted VERBATIM and driven with stubs.
# ---------------------------------------------------------------------------
# Extract the shipped function text so this harness cannot drift from the code
# that runs (same technique as tests/heartbeat_tier_guard_unmeasured_unit.sh).
# Literal line compare, not a regex: the function header is an exact string and
# an escaped-paren regex is the kind of thing that silently matches nothing.
_extract() { awk -v hdr="${2}() {" '$0 == hdr { on=1 } on { print } on && $0 == "}" { exit }' "$1"; }
HELD_FN="$(_extract "$HB_SRC" cmd_heartbeat_held)"
RANK_FN="$(_extract "$HB_SRC" _hb_tier_rank)"
if [[ -z "$HELD_FN" || -z "$RANK_FN" ]]; then
  bad_t "C0 could not extract cmd_heartbeat_held/_hb_tier_rank from $HB_SRC"
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

# Fixture board. dev2: three rows, ALL created by a lower tier -> stranded.
# dev9: three rows, one created by an EQUAL tier -> the quantifier must clear it.
# dev7: all held but woken 1h ago -> the staleness floor must clear it.
cat >"$TMP/fixture.sh" <<'FIX'
E_USAGE=64
JSON_MODE=0
fail() { printf 'fail: %s\n' "${2:-}" >&2; return 1; }
tier_unmeasured() { [[ "$1" == unknown:* ]] && ! [[ "$1" == unknown:unregistered ]]; }
agent_tier() {
  case "$1" in
    dev2|dev7|dev9) echo admin ;;
    quinn|main2)    echo standard ;;
    boss)           echo admin ;;
    *)              echo unknown:unregistered ;;
  esac
}
# id -> creator, ident
_row_creator() { case "$1" in 1|2|3) echo quinn ;; 4|5) echo main2 ;; 6) echo boss ;; 7|8) echo quinn ;; esac; }
_row_ident()   { echo "DIVE-30$1"; }
db() {
  local q="$*"
  local id="${q##*id=}"; id="${id%%;*}"
  if [[ "$q" == *created_by* ]]; then _row_creator "$id"; else _row_ident "$id"; fi
}
_hb_pick_tasks() {
  case "$1" in
    dev2) printf '1\n2\n3\n' ;;   # all quinn(standard) -> all held
    dev9) printf '4\n5\n6\n' ;;   # 6 is boss(admin) == dev9(admin) -> NOT held
    dev7) printf '7\n8\n' ;;      # all held, but woken recently
    *)    printf '' ;;
  esac
}
registry_read() {
  local now; now=$(date +%s)
  jq -cn --argjson old "$(( now - 6*24*3600 ))" --argjson fresh "$(( now - 3600 ))" \
    '{agents:{dev2:{heartbeat:{lastRunAt:$old}}, dev9:{heartbeat:{lastRunAt:$old}}, dev7:{heartbeat:{lastRunAt:$fresh}}}}'
}
FIX

# `run_pred <mutated-fn-text>` -> the JSON the predicate emits.
run_pred() {
  local fn="$1"
  { cat "$TMP/fixture.sh"; printf '%s\n%s\n' "$RANK_FN" "$fn"; \
    printf 'cmd_heartbeat_held --json --stalled-hours=6\n'; } >"$TMP/drive.sh"
  bash "$TMP/drive.sh" 2>/dev/null
}

_seats_of() { jq -r '[.data.seats[].agent] | sort | join(",")' <<<"${1:-{\}}" 2>/dev/null; }

OUT="$(run_pred "$HELD_FN")"
SEATS="$(_seats_of "$OUT")"
if [[ "$SEATS" == "dev2" ]]; then
  ok_t "C1 exactly the stranded seat is reported (dev2; dev9 cleared by one unheld row, dev7 by the staleness floor)"
else
  bad_t "C1 wrong seat set: expected 'dev2', got '${SEATS:-<none>}'" "raw: ${OUT:0:200}"
fi

_IDENTS="$(jq -r '.data.seats[0].idents | sort | join(",")' <<<"$OUT" 2>/dev/null)"
if [[ "$_IDENTS" == "DIVE-301,DIVE-302,DIVE-303" ]]; then
  ok_t "C2 the held idents are reported, not just a count (D3: an aggregate with no idents is not a surface)"
else
  bad_t "C2 idents missing/wrong: got '${_IDENTS:-<none>}'"
fi

if [[ "$(jq -r '.data.seats[0].heldCount' <<<"$OUT" 2>/dev/null)" == "3" && \
      "$(jq -r '.data.seats[0].stalledHours' <<<"$OUT" 2>/dev/null)" -ge 24 ]]; then
  ok_t "C3 heldCount and stalledHours are carried"
else
  bad_t "C3 heldCount/stalledHours missing or wrong" "raw: ${OUT:0:200}"
fi

# D. MUTATION GRADE. Break one clause at a time and require C1 to go red. A
# mutation that leaves the arm green means that clause is not being tested.
_mutate_and_expect_red() {
  local label="$1" sed_expr="$2" mutated seats
  mutated="$(sed "$sed_expr" <<<"$HELD_FN")"
  if [[ "$mutated" == "$HELD_FN" ]]; then
    bad_t "D $label — the mutation did not apply (the clause it targets has moved)" \
          "an inapplicable mutation is an UNGRADED clause, not a pass"
    return 0
  fi
  seats="$(_seats_of "$(run_pred "$mutated")")"
  if [[ "$seats" == "dev2" ]]; then
    bad_t "D $label — mutant still reports exactly 'dev2'; the clause is not graded"
  else
    ok_t "D $label — mutant changes the answer to '${seats:-<none>}' (clause is graded)"
  fi
}
# The rank comparison: hold when the creator ranks ABOVE the assignee instead.
_mutate_and_expect_red "rank comparison (_cr < _ar -> _cr > _ar)" 's/_cr < _ar/_cr > _ar/'
# The universal quantifier: fire when ANY row is held instead of EVERY row.
_mutate_and_expect_red "quantifier (held == cand -> held > 0)" 's/held == cand/held > 0/'
# The staleness floor: fire regardless of how recently the seat was woken.
_mutate_and_expect_red "staleness floor (>= hours*3600 -> >= 0)" 's/stalledSec >= hours \* 3600/stalledSec >= 0/'

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
exit $(( FAIL > 0 ? 1 : 0 ))
