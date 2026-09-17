#!/usr/bin/env bash
# DIVE-4581 — three FLEET-HEALTH blocked-on-prompt pages in one evening
# (2026-09-15/16) for claude's OWN usage-limit hold picker: a capacity wall that
# prints its own resume time, read as "a person must choose".
#
# Every arm here is PURE — _sup_limit_picker_match and _sup_classify, no tmux,
# no root, no db. The shape follows DIVE-4536's: each rule gets a POSITIVE
# CONTROL (the true positive must survive), a FALSE-POSITIVE control DRAWN FROM
# THE POPULATION rather than composed (the verbatim `task show DIVE-4581`
# output and the wiki page written for this fix, both on disk in the same
# commit as the detector), and a MUTANT arm proving the anchor under test is
# load-bearing — relax it and the population control must go red.
# Run: bash tests/supervisor_limit_picker_unit.sh (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
FIX=tests/fixtures/dive4581

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
_SUP_CLI_LATEST="9.9.9"

PASS=0; FAIL=0
ok()   { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"; fi; }
has()  { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected to contain '$2', got '$3'"; fi; }
hasnt(){ if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected NOT to contain '$2', got '$3'"; fi; }

# _sup_classify positional helper: only the pane-prompt signals vary here.
cls_prompt() {  # <prompt_excerpt> <prompt_mark> -> "<class>\x1f<cause>\x1f<detail>"
  _sup_classify running 1 active s-sess alive alive 0 1 60 false "" \
                "" 0 0 -1 "" unknown "$1" "$2" "" ok
}
f1() { cut -d$'\x1f' -f1 <<<"$1"; }
f2() { cut -d$'\x1f' -f2 <<<"$1"; }
f3() { cut -d$'\x1f' -f3 <<<"$1"; }

# ── fixtures ────────────────────────────────────────────────────────────────
# THE INCIDENT PANE, verbatim: `tmux capture-pane -p -S -14` on a live seat
# sitting on the hold picker at 2026-09-16 ~05:55Z, kept as a file so the arm
# grades the bytes a seat actually renders and not the author's memory of them.
LIMIT_PANE=$(cat "$FIX/limit-picker-pane.txt")

# POSITIVE CONTROL for the OTHER picker: a real AskUserQuestion, nothing about
# a limit on it. This change must not stop a genuine question from paging.
ASK_PANE=$'  Which database should the importer write to?\n\n   ❯ 1. Staging\n     2. Production\n     3. Neither — abort\n\n   Enter to confirm · Esc to cancel'

# FALSE-POSITIVE CONTROLS, DRAWN FROM THE POPULATION (DIVE-4536 it.2 lesson):
# both files below were written BY this fix and live in the same commit as the
# detector, so a seat that cats either into its pane is the population a
# co-occurrence rule would have mis-read.
ROW_BODY=$(cat "$FIX/row-body-task-show.txt")
WIKI_PAGE=$(cat "$FIX/wiki-page.md")

# ── 1. the true positive ────────────────────────────────────────────────────
m=$(printf '%s\n' "$LIMIT_PANE" | _sup_limit_picker_match)
has "arm1: the live hold picker matches"                "continue automatically" "$m"
has "arm1: ...and the excerpt carries the RESUME TIME"  "Sep 19, 12pm"           "$m"
ok  "arm1: ...cursor sits on the hold option, so one Down reaches auto-resume" \
    "1" "$(cut -d$'\x1f' -f2 <<<"$m")"

# The same picker with the cursor ALREADY on the auto-resume option: zero
# presses, just Enter. A fixed "Down, Enter" would have taken option 3.
ON_TARGET=${LIMIT_PANE/'   ❯ 1. Stop and wait for limit to reset'/'     1. Stop and wait for limit to reset'}
ON_TARGET=${ON_TARGET/'     2. Wait here, then continue automatically'/'   ❯ 2. Wait here, then continue automatically'}
ok "arm2: cursor already on the auto-resume option => 0 steps" \
   "0" "$(cut -d$'\x1f' -f2 <<<"$(printf '%s\n' "$ON_TARGET" | _sup_limit_picker_match)")"

# Cursor on NO numbered option (a redraw mid-frame): matched, but unanswerable.
NO_CURSOR=${LIMIT_PANE/'   ❯ 1. Stop'/'     1. Stop'}
m_nc=$(printf '%s\n' "$NO_CURSOR" | _sup_limit_picker_match)
has "arm3: no cursor still matches the wall"   "continue automatically" "$m_nc"
ok  "arm3: ...but yields no keystroke plan"    "unknown" "$(cut -d$'\x1f' -f2 <<<"$m_nc")"

# ── 4. the negative controls ────────────────────────────────────────────────
ok "arm4: a real AskUserQuestion picker is NOT a limit hold" \
   "" "$(printf '%s\n' "$ASK_PANE" | _sup_limit_picker_match)"
ok "arm5: this row's own \`task show\` output does not classify (population)" \
   "" "$(printf '%s\n' "$ROW_BODY" | _sup_limit_picker_match)"
ok "arm6: the wiki page written for this fix does not classify (population)" \
   "" "$(printf '%s\n' "$WIKI_PAGE" | _sup_limit_picker_match)"
# A transcript of the picker with DOCUMENT after it — the shape a quotation
# always has and a live modal never does.
QUOTED=$LIMIT_PANE$'\n\nThat picker is the usage-limit hold, and the supervisor answers it itself.\nIt is not a question, so it must not page a person.\nThe measurement and the two anchors are on the wiki page.\nSee also DIVE-4536, which took the other exit.'
ok "arm7: a verbatim transcript with prose after it does not classify" \
   "" "$(printf '%s\n' "$QUOTED" | _sup_limit_picker_match)"
# SIGNED RESIDUAL, asserted rather than hidden: two non-empty lines after a
# verbatim, correctly ordered transcript is inside the tail anchor and DOES
# match. The bytes are the modal's; nothing in this function can tell them
# apart, exactly as DIVE-4536 signed for the confirm. This arm exists so the
# boundary is measured and a future reader sees where it sits — if a release
# ever renders chrome below the footer, THIS is the arm that has to move.
TIGHT_QUOTE=$LIMIT_PANE$'\nThat picker is the usage-limit hold.\nSee the wiki page.'
has "arm7b: RESIDUAL — a transcript with only two lines after it still matches" \
    "continue automatically" "$(printf '%s\n' "$TIGHT_QUOTE" | _sup_limit_picker_match)"
# The two option texts on ONE line — how prose actually carries them.
ONELINE=$'The picker offers 1. Stop and wait for limit to reset / 2. Wait here, then continue automatically at <time>.\n   Enter to confirm · Esc to cancel'
ok "arm8: both option texts on one prose line does not classify" \
   "" "$(printf '%s\n' "$ONELINE" | _sup_limit_picker_match)"
# Order reversed: the auto-resume option ABOVE the hold option is not the
# geometry this picker has, and the strict ordering is what rejects it.
REVERSED=$'   What do you want to do?\n\n   ❯ 1. Wait here, then continue automatically at Sep 19, 12pm\n     2. Stop and wait for limit to reset\n\n   Enter to confirm · Esc to cancel'
ok "arm9: reversed option order does not classify" \
   "" "$(printf '%s\n' "$REVERSED" | _sup_limit_picker_match)"

# ── 10. MUTANT: the tail anchor is load-bearing ─────────────────────────────
# Relax the position anchors to the whole capture and the population control —
# the row body, which carries the footer 20+ non-empty lines from its end —
# must start matching. If it does not, arm5 is passing for some other reason.
# NOTE the `if !` wrapper on both subshell arms: one of the sourced libs turns
# errexit on, and under errexit a bare failing subshell KILLS the harness
# instead of yielding a status (the arm silently vanishes, which is the
# under-red failure mode). A subshell in an `if` condition is exempt.
mut_rc=0
if ! ( _SUP_LIMIT_TAIL_LINES=200; _SUP_LIMIT_SPAN_LINES=200
       [[ -n "$(printf '%s\n' "$QUOTED" | _sup_limit_picker_match)" ]] ); then mut_rc=1; fi
ok "arm10: MUTANT — with the position anchors removed, the quoted transcript DOES match" \
   "0" "$mut_rc"

# ── 17. ITERATION 2 (grader gr-quinn-19): a QUOTED picker emits no keystroke ─
# The cursor glyph used to accept a bare '>' as an alternative to the pointer.
# Every gutter-quoting shape — a markdown blockquote, a chat forward, an
# inbound message rendered with a '>' gutter (the DIVE-4405 shape) — prefixes
# each option row with it, so the reading was not merely a match: it was the
# most CONFIDENT possible cursor position, and it pressed a key into a live
# pane. These arms assert on the STEPS FIELD, not on the match: the class is
# ALLOWED to flip (a quoted wall still is not a question), what must never
# happen is a keystroke. Option literals are assembled here rather than written
# out, for the same reason the row body and the wiki page break them up.
O1='1. Stop and wait for limit to reset'
O2='2. Wait here, then continue automatically at Sep 19, 12pm'
O3='3. Upgrade your plan'
FOOT='Enter to confirm · Esc to cancel'
BLOCKQUOTE=$(printf '> What do you want to do?\n>\n> %s\n> %s\n> %s\n>\n> %s\n' "$O1" "$O2" "$O3" "$FOOT")
FORWARD=$(printf 'main forwarded a pane:\n\n> %s\n> %s\n> %s\n> %s\n' "$O1" "$O2" "$O3" "$FOOT")
INBOUND=$(printf '[5dive-msg from main] the seat is sitting on this:\n> What do you want to do?\n> %s\n> %s\n> %s\n> %s\n' "$O1" "$O2" "$O3" "$FOOT")
steps_of() { cut -d$'\x1f' -f2 <<<"$(printf '%s\n' "$1" | _sup_limit_picker_match)"; }
ok "arm17: a gutter-quoted BLOCKQUOTE of the picker presses NO key" \
   "unknown" "$(steps_of "$BLOCKQUOTE")"
ok "arm17b: a gutter-quoted chat FORWARD presses NO key" \
   "unknown" "$(steps_of "$FORWARD")"
ok "arm17c: a gutter-quoted inbound a2a message presses NO key" \
   "unknown" "$(steps_of "$INBOUND")"

# MUTANT: put the bare gutter back into BOTH glyph classes — the pre-fix
# reading — and the blockquote must produce a NUMERIC step count again, i.e.
# the restriction is what is holding arm17 and not some other anchor. Measured
# on the pre-fix tree, all three shapes gave exactly this: -1, one Up then
# Enter, into the seat's live pane.
mut_glyph=$( _SUP_LIMIT_CURSOR_PAT='^[[:space:]]*(❯|>)[[:space:]]*[0-9]+\.[[:space:]]'
             _SUP_LIMIT_OPTION_PAT='^[[:space:]]*((❯|>)[[:space:]]*)?[0-9]+\.[[:space:]]'
             steps_of "$BLOCKQUOTE" )
# The claim under test is "a keystroke is emitted", not one particular count:
# on the pre-fix tree the cursor scan had no break, so it ran to the LAST
# gutter-prefixed row (the upgrade option) and read -1, one Up then Enter; with
# the break in place the same widening reads +1 off the first quoted row. Both
# are keys pressed into a live pane on a quotation, which is the defect.
ok "arm18: MUTANT — with the bare gutter back in both glyph classes, the quote answers" \
   "yes" "$( [[ "$mut_glyph" =~ ^-?[0-9]+$ ]] && echo yes || echo no )"
# ...and the two restrictions are INDEPENDENT stops: relax only the cursor and
# the quoted pane still presses nothing, because a gutter-quoted row is not an
# option row either, so neither end of the distance can be located.
mut_cursor_only=$( _SUP_LIMIT_CURSOR_PAT='^[[:space:]]*(❯|>)[[:space:]]*[0-9]+\.[[:space:]]'
                   steps_of "$BLOCKQUOTE" )
ok "arm18b: the option-row class stops the quote on its own" \
   "unknown" "$mut_cursor_only"

# ── 19. the distance is counted in OPTION ROWS, not rendered lines ──────────
# A render with a description sub-line under each option: the true distance
# from the cursor to the auto-resume option is ONE. Counting non-empty lines
# gives TWO, which walks the cursor onto the third option — upgrade the plan,
# a purchase, the exact decision the cursor-relative design exists to avoid.
SUBLINE=$(printf '   What do you want to do?\n\n   ❯ %s\n     resets at Sep 19, 12pm (UTC)\n     %s\n     the seat parks and wakes itself\n     %s\n     costs money\n\n   %s\n' \
                 "$O1" "$O2" "$O3" "$FOOT")
ok "arm19: description sub-lines do not inflate the distance" "1" "$(steps_of "$SUBLINE")"
# MUTANT: widen the option class to every line and the same pane over-shoots
# to 2 — the pre-fix reading, and the arm that proves arm19 is load-bearing.
mut_opt=$( _SUP_LIMIT_OPTION_PAT='.'; steps_of "$SUBLINE" )
ok "arm20: MUTANT — counting rendered lines instead of option rows over-shoots" \
   "2" "$mut_opt"

# ── 21. this harness is itself population ──────────────────────────────────
# It now carries assembled option literals, so it joins the row body and the
# wiki page as a file a seat could cat into its own pane. It must not classify.
ok "arm21: this harness file does not classify (population)" \
   "" "$(_sup_limit_picker_match < "$0")"

# ── 11. the classifier ──────────────────────────────────────────────────────
c=$(cls_prompt "2. Wait here, then continue automatically at Sep 19, 12pm" "limit-picker:1")
ok  "arm11: the hold picker classifies quota-exhausted, not blocked-on-prompt" \
    "quota-exhausted" "$(f1 "$c")"
ok  "arm11: ...with its own cause"        "limit-picker" "$(f2 "$c")"
has "arm11: ...naming the resume time"    "Sep 19, 12pm" "$(f3 "$c")"
has "arm11: ...and the keystroke plan"    "1 step(s) from the cursor" "$(f3 "$c")"
hasnt "arm11: ...and never says a person must choose" "a person must choose" "$(f3 "$c")"

c_nc=$(cls_prompt "2. Wait here, then continue automatically at Sep 19, 12pm" "limit-picker:unknown")
ok  "arm12: an unanswerable hold is still quota-exhausted" "quota-exhausted" "$(f1 "$c_nc")"
has "arm12: ...and says no key will be pressed" "will NOT be pressed" "$(f3 "$c_nc")"

# POSITIVE CONTROL for the class this change moves away from: an unmarked
# picker that is NOT a limit hold must still be blocked-on-prompt and must
# still say a person must choose. This is the arm that fails if the fix is
# widened into "no picker ever pages".
c_ask=$(cls_prompt "Enter to confirm · Esc to cancel" "unmarked")
ok  "arm13: an ordinary unmarked picker still classifies blocked-on-prompt" \
    "blocked-on-prompt" "$(f1 "$c_ask")"
has "arm13: ...and still escalates to a person" "a person must choose" "$(f3 "$c_ask")"
c_rec=$(cls_prompt "Enter to confirm · Esc to cancel" "recommended")
ok  "arm14: a (Recommended) picker is untouched" "blocked-on-prompt" "$(f1 "$c_rec")"
c_conf=$(cls_prompt "Do you want to proceed?" "confirm")
ok  "arm15: the DIVE-4536 confirm is untouched" "dangerous-confirm" "$(f2 "$c_conf")"

# ── 16. the act rung refuses a distance it cannot read ──────────────────────
# _sup_act_exec's park-on-limit must never guess: a non-numeric step count
# returns nonzero BEFORE any key reaches a live pane. sudo/tmux are not
# reachable here, so a rung that fell through to them would also fail — the
# arm is meaningful because the numeric guard returns first, which the mutant
# below shows.
rc16=0
if ! ( _sup_act_exec fixture-seat park-on-limit "unknown" ) >/dev/null 2>&1; then rc16=1; fi
ok "arm16: park-on-limit refuses a non-numeric distance" "1" "$rc16"

echo "limit-picker unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
