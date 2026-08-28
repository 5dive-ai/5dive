#!/usr/bin/env bash
# TIER: core — pure bash + stubs, no tmux, no agent, no network (<1s measured).
# DIVE-3791 — the 5dive-cli half of DIVE-3786/DIVE-1180.
#
# TWO-SIDED BY CONSTRUCTION:
#   BEHAVIOURAL — drive the real coldstart_kick_submit against a scripted tmux
#     stub and assert on what it SENT and what it RECORDED. A submit-verifier
#     that always returned 0 would pass any assertion about the return code of
#     the happy path alone, so every arm below pins the KEYSTROKE COUNTS and the
#     CAPTURE COUNT too: the defect being fixed is invisible in the exit status.
#     The FAIL_CAPTURE_AT knob is SWEPT across all four capture call sites, not
#     pointed at one — a FAIL_AT=<index> injector with a single arm grades a
#     single call site, and here the sites fail differently (a before-capture
#     fails safe, an after-capture fails SILENT). See 4d..4d4, and 4g/4h for the
#     same sweep over the other injectable site, the Enter send.
#   STATIC — the DIVE-1180 recursive-loop ban, ported to this repo.
#     test/rearm-loop-regression.test.ts in 5dive-ai/5dive-plugins bans the same
#     three patterns, but it reads `plugins/<fork>/` and CANNOT see this repo.
#     Both cold-start kicks here shipped with two of the banned phrases verbatim
#     for exactly that reason: a ban covering one of the two repos that carry the
#     pattern is a ban that drifts. Scope, not the two strings, is the fix.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
START="$SRC/5dive-agent-start"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
is(){ # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi
}

[[ -r "$START" ]] || { echo "PRECONDITION FAIL: $START unreadable"; exit 1; }

# ── The ban, verbatim from the plugins guard ────────────────────────────────
# NB the plugins suite excludes silence-watchdog.ts because its match is a code
# comment about ping backoff, not a model instruction. This repo has no such
# exemption and must not grow one: an explanatory comment that QUOTES a banned
# phrase reds this harness, and the correct fix is to describe the phrase rather
# than reproduce it (the ban is on the bytes, and a comment ships too).
BANNED=( 'again immediately' 'idle polling is cheap' 'keep looping' )
# Model-facing text this repo ships. 5dive-agent-start types the cold-start kick
# straight into the agent's composer; the CLAUDE.md/AGENTS templates are read by
# every seat the CLI creates.
MODEL_FACING=(
  5dive-agent-start
  telegram-agent-CLAUDE.md
  operational-comms-CLAUDE.md
  projects-CLAUDE.md
  model-tiering-CLAUDE.md
)

echo "== 1. STATIC: no recursive-loop instruction in model-facing text =="
for f in "${MODEL_FACING[@]}"; do
  if [[ ! -e "$SRC/$f" ]]; then
    # A vanished file must not read as a pass. Name it and fail.
    no "$f exists (model-facing file listed in this harness is missing)"
    continue
  fi
  for pat in "${BANNED[@]}"; do
    if grep -qiF "$pat" "$SRC/$f"; then
      no "$f has no '$pat'"
      grep -niF "$pat" "$SRC/$f" | sed 's/^/       /' >&2
    else
      ok "$f has no '$pat'"
    fi
  done
done
# Also sweep the skills the CLI installs into every seat, which are model-facing
# by definition. Reported as one arm so a new skill file is covered for free.
_skill_hits="$(grep -rliE "$(IFS='|'; echo "${BANNED[*]}")" "$SRC/skills" 2>/dev/null || true)"
if [[ -z "$_skill_hits" ]]; then ok "skills/ has no recursive-loop instruction"
else no "skills/ has no recursive-loop instruction ($_skill_hits)"; fi

echo "== 2. STATIC POSITIVE: the corrected instruction is present =="
# A ban on the old text alone is half a guard: deleting the fix's text passes it.
if grep -qF 'END YOUR TURN' "$START"; then ok "cold-start kick says END YOUR TURN"
else no "cold-start kick says END YOUR TURN"; fi

# The reasoning error is the bug. codex was excluded from the kick because a comment
# asserted its MCP server booting with the process made it reachable; it does not, and
# a revert of that comment is a revert of the fix's rationale. DIVE-3792.
if grep -qF 'Unlike codex (whose MCP server boots' "$START"; then
  no "no comment still claims codex needs no kick because its MCP server boots"
else ok "no comment still claims codex needs no kick because its MCP server boots"; fi

echo "== 3. STRUCTURAL: all three kick blocks submit through the verifier =="
# The verified send is worthless if a call site still fires Enter itself. Read
# the three kick blocks only, so an unrelated Enter elsewhere in the script (the
# claude resume prompt, the codex trust-accepter) is not miscounted.
# The `if` line is matched WHOLE and asserted UNIQUE. An earlier draft matched a
# prefix and `head -1` silently graded the grok AUTH block 1100 lines up, which
# has no kick in it and passed every arm below vacuously.
# DIVE-3792 added codex, so the marker can no longer be a shared alternation:
# each block must carry ITS OWN ready marker, or a copy-pasted grok marker in the
# codex block would pass this arm while never matching a real codex pane.
declare -A _READY=( [grok]='Resume session' [antigravity]='for shortcuts' [codex]='>_ OpenAI Codex (v' )
# A block's GUARDS are graded per block too, because they are per block. DIVE-3792
# iteration 1 shipped codex's two guards UNGRADED: deleting either left the harness
# at 75/0, so a refactor could drop one silently and re-open the double-submit and
# type-into-the-dialog paths the row was filed to close. One `<regex>|<what it is>`
# per line; a block with no required guards declares none and this loop skips it.
declare -A _MUST=(
  [grok]=""
  [antigravity]=""
  [codex]="grep -q .wait_for_message.;[[:space:]]*then[[:space:]]*break|does not type when the pane already shows wait_for_message (the plugin's inbound kick won the race)
grep -q .Hooks need review.;[[:space:]]*then[[:space:]]*continue|does not type while the first-run Hooks-need-review dialog is up"
)
for _blk in grok antigravity codex; do
  _pat='^if \[\[ "\$TYPE" == "'"${_blk}"'" && "\$CHANNELS" == "telegram" \]\]; then$'
  _hits="$(grep -cE "$_pat" "$START")"
  if [[ "$_hits" != 1 ]]; then
    no "$_blk kick block is uniquely locatable (matched $_hits lines — reworded condition?)"
    continue
  fi
  _ln="$(grep -nE "$_pat" "$START" | cut -d: -f1)"
  _body="$(sed -n "${_ln},\$p" "$START" | awk 'NR>1 && /^fi$/{print;exit}{print}')"
  if grep -qF "${_READY[$_blk]}" <<<"$_body"; then
    ok "$_blk kick block body carries its own ready marker"
  else no "$_blk kick block body carries its own ready marker (want '${_READY[$_blk]}')"; fi
  if grep -q 'coldstart_kick_submit' <<<"$_body"; then ok "$_blk kick calls coldstart_kick_submit"
  else no "$_blk kick calls coldstart_kick_submit"; fi
  if grep -qE 'send-keys[^|]*Enter' <<<"$_body"; then
    no "$_blk kick fires no bare Enter of its own"
  else ok "$_blk kick fires no bare Enter of its own"; fi
  while IFS='|' read -r _gpat _gdesc; do
    [[ -n "$_gpat" ]] || continue
    if grep -qE "$_gpat" <<<"$_body"; then ok "$_blk kick $_gdesc"
    else no "$_blk kick $_gdesc"; fi
  done <<<"${_MUST[$_blk]}"
done
# One text, one definition — the duplicate is how the banned phrasing survived in
# both blocks.
is "kick text is defined exactly once" \
  "$(grep -c '^COLDSTART_KICK_TEXT=' "$START")" "1"

echo "== 4. BEHAVIOURAL: coldstart_kick_submit observes its own submit =="
# Load the helpers with the real bodies, replacing only the absolute tmux path
# (unstubbable inside a function) and the settle sleeps.
harness() {
  {
    sed -n '/^COLDSTART_KICK_TYPE_SETTLE=/,/^COLDSTART_KICK_SUBMIT_SETTLE=/p'   "$START"
    sed -n '/^COLDSTART_KICK_TEXT=/p'                                          "$START"
    sed -n '/^coldstart_kick_breadcrumb_path()/,/^}/p;/^coldstart_kick_ok()/p' "$START"
    sed -n '/^_coldstart_capture_pane()/,/^}/p'                                "$START"
    sed -n '/^_coldstart_submit_once()/,/^}/p'                                 "$START"
    sed -n '/^coldstart_kick_submit()/,/^}/p'                                  "$START"
  } | sed 's#/usr/bin/tmux#tmux#g'
}
_loaded="$(harness)"
for _fn in coldstart_kick_submit _coldstart_submit_once _coldstart_capture_pane \
           coldstart_kick_breadcrumb_path coldstart_kick_ok; do
  grep -q "^${_fn}()" <<<"$_loaded" || no "harness extracted $_fn"
done
grep -q 'COLDSTART_KICK_TEXT=' <<<"$_loaded" || no "harness extracted COLDSTART_KICK_TEXT"

TD="$(mktemp -d)"; trap 'rc=$?; rm -rf "$TD"; echo "HARNESS-RC=$rc"' EXIT

# scenario runner: PANES is a newline-separated script of capture-pane outputs,
# consumed one per call. FAIL_CAPTURE_AT / FAIL_TYPE inject rc 1.
run_case() { # <name> <panes-file> <fail_capture_at|0> <fail_type|0> [fail_enter_at|0]
  local box="$TD/$1"; mkdir -p "$box"
  PANE_SCRIPT="$2" FAIL_CAPTURE_AT="$3" FAIL_TYPE="$4" FAIL_ENTER_AT="${5:-0}" BOX="$box" \
  bash -c '
    set -uo pipefail
    HOME="$BOX"; export HOME
    # The capture runs inside $( ), i.e. a SUBSHELL, so the call counter cannot
    # live in a variable — it would reset on every capture and every pane would
    # read line 1, i.e. every submit would look unobserved. File-backed.
    printf 0 > "$BOX/n"; printf 0 > "$BOX/e"
    sleep(){ :; }
    tmux(){
      local n
      case " $* " in
        *" capture-pane "*)
          n=$(( $(cat "$BOX/n") + 1 )); printf %s "$n" > "$BOX/n"
          [[ "$FAIL_CAPTURE_AT" != 0 && "$n" == "$FAIL_CAPTURE_AT" ]] && return 1
          sed -n "${n}p" "$PANE_SCRIPT"; return 0 ;;
        *" -l "*)
          printf "TYPE\n" >> "$BOX/sent"
          [[ "$FAIL_TYPE" == 1 ]] && return 1
          return 0 ;;
        *" Enter "*|*" Enter")
          # Counted OUTSIDE a subshell here, but file-backed like the capture
          # counter so both knobs index the same way and neither can silently
          # reset if a call site later moves inside a $( ).
          printf "ENTER\n" >> "$BOX/sent"
          n=$(( $(cat "$BOX/e") + 1 )); printf %s "$n" > "$BOX/e"
          [[ "$FAIL_ENTER_AT" != 0 && "$n" == "$FAIL_ENTER_AT" ]] && return 1
          return 0 ;;
      esac
      return 0
    }
    '"$_loaded"'
    coldstart_kick_submit agent-x grok; echo "RC=$?"
  ' 2>"$box/err"
}
count(){ local n; n="$(grep -c "^$2$" "$TD/$1/sent" 2>/dev/null)"; printf %s "${n:-0}"; }
bc_of(){ cat "$TD/$1/.5dive-coldstart-kick-failed" 2>/dev/null || true; }
# How many times capture-pane was called. Every arm pins this: a FAIL_CAPTURE_AT
# knob only grades the call sites that EXIST when the arm is written, so a third
# capture added later would sit ungraded behind the same index sweep. Pinning the
# count makes adding one red until its own arm is written.
caps(){ cat "$TD/$1/n" 2>/dev/null || printf 0; }

# 4a. Enter lands on the first try: pane changes across the submit.
printf 'composer: kick text\nturn started\n' > "$TD/p-ok"
r="$(run_case ok "$TD/p-ok" 0 0)"
is "4a landed submit returns 0"        "$r"                 "RC=0"
is "4a typed the prompt once"          "$(count ok TYPE)"   "1"
is "4a sent exactly one Enter"         "$(count ok ENTER)"  "1"
is "4a leaves no breadcrumb"           "$(bc_of ok)"        ""
is "4a captured the pane twice"        "$(caps ok)"         "2"

# 4b. Enter NEVER lands: pane byte-identical across every submit. This is the
# defect. Pre-fix it returned success and recorded nothing.
printf 'composer: kick text\ncomposer: kick text\ncomposer: kick text\ncomposer: kick text\n' > "$TD/p-wedged"
r="$(run_case wedged "$TD/p-wedged" 0 0)"
is "4b unobserved submit returns 1"    "$r"                     "RC=1"
is "4b retried the Enter"              "$(count wedged ENTER)"  "2"
is "4b did NOT retype the prompt"      "$(count wedged TYPE)"   "1"
if grep -q 'NOT listening' <<<"$(bc_of wedged)"; then
  ok "4b breadcrumb names the real state"
else no "4b breadcrumb names the real state (got '$(bc_of wedged)')"; fi
if grep -q 'not accepting input' "$TD/wedged/err"; then ok "4b warns on stderr"
else no "4b warns on stderr"; fi
is "4b captured the pane four times"   "$(caps wedged)"         "4"

# 4c. First Enter dropped, second lands — the case the retry exists for.
printf 'composer: kick text\ncomposer: kick text\ncomposer: kick text\nturn started\n' > "$TD/p-retry"
r="$(run_case retry "$TD/p-retry" 0 0)"
is "4c retry that lands returns 0"     "$r"                    "RC=0"
is "4c sent two Enters"                "$(count retry ENTER)"  "2"
is "4c still typed the prompt ONCE"    "$(count retry TYPE)"   "1"
is "4c leaves no breadcrumb"           "$(bc_of retry)"        ""
is "4c captured the pane four times"   "$(caps retry)"         "4"

# 4d..4d4. Unreadable pane must NOT read as a landed submit (DIVE-2159's lesson
# on this same script: could-not-measure rendered as measured-and-fine).
#
# SWEEP THE INDEX, do not grade one call site. There are FOUR capture calls in a
# full run — before/after of the first submit, before/after of the retry — and
# they do NOT fail the same way. A failed BEFORE capture fails safe: the compare
# never runs. A failed AFTER capture is the silent one, because the empty result
# compares UNEQUAL to a non-empty before and so reads as "the pane changed", i.e.
# as a landed submit. FAIL_CAPTURE_AT=1 alone (the original arm) graded only a
# safe-failing site, and a mutant deleting `|| return 1` from the after-capture
# survived it green. The after positions (2 and 4) are also the more likely ones
# in the field: the pane can vanish mid-turn.
printf 'composer: kick text\nturn started\nturn started\nturn started\n' > "$TD/p-blind"
r="$(run_case blind "$TD/p-blind" 1 0)"
is "4d capture 1 (submit before) unreadable returns 1"  "$r"              "RC=1"
if [[ -n "$(bc_of blind)" ]]; then ok "4d unreadable pane is recorded"
else no "4d unreadable pane is recorded"; fi
is "4d sent no Enter for the failed submit"  "$(count blind ENTER)"  "1"
is "4d captured the pane three times"        "$(caps blind)"         "3"

# 4d2. AFTER capture of the FIRST submit is unreadable. The retry then sees a
# byte-identical pane, so the whole call must still report failure. Deleting
# `|| return 1` from the after-capture makes this arm return RC=0.
printf 'composer: kick text\nUNREAD\ncomposer: kick text\ncomposer: kick text\n' > "$TD/p-blind2"
r="$(run_case blind2 "$TD/p-blind2" 2 0)"
is "4d2 capture 2 (submit after) unreadable returns 1"  "$r"             "RC=1"
if [[ -n "$(bc_of blind2)" ]]; then ok "4d2 unreadable after-capture is recorded"
else no "4d2 unreadable after-capture is recorded"; fi
is "4d2 retried the Enter"                   "$(count blind2 ENTER)" "2"
is "4d2 did NOT retype the prompt"           "$(count blind2 TYPE)"  "1"
is "4d2 captured the pane four times"        "$(caps blind2)"        "4"

# 4d3. BEFORE capture of the RETRY is unreadable: fails safe, no second Enter.
printf 'composer: kick text\ncomposer: kick text\nUNREAD\nx\n' > "$TD/p-blind3"
r="$(run_case blind3 "$TD/p-blind3" 3 0)"
is "4d3 capture 3 (retry before) unreadable returns 1"  "$r"             "RC=1"
if [[ -n "$(bc_of blind3)" ]]; then ok "4d3 unreadable retry-before is recorded"
else no "4d3 unreadable retry-before is recorded"; fi
is "4d3 sent no Enter for the failed retry"  "$(count blind3 ENTER)" "1"
is "4d3 captured the pane three times"       "$(caps blind3)"        "3"

# 4d4. AFTER capture of the RETRY is unreadable — the last chance to report the
# truth, and the second position the surviving mutant flipped to green.
printf 'composer: kick text\ncomposer: kick text\ncomposer: kick text\nUNREAD\n' > "$TD/p-blind4"
r="$(run_case blind4 "$TD/p-blind4" 4 0)"
is "4d4 capture 4 (retry after) unreadable returns 1"   "$r"             "RC=1"
if [[ -n "$(bc_of blind4)" ]]; then ok "4d4 unreadable retry-after is recorded"
else no "4d4 unreadable retry-after is recorded"; fi
is "4d4 retried the Enter"                   "$(count blind4 ENTER)" "2"
is "4d4 captured the pane four times"        "$(caps blind4)"        "4"

# 4g/4h. The SAME sweep for the other injectable call site: the Enter send.
# `send-keys ... Enter || return 1` is a second guard on the same path, and it
# was ungraded — the stub never failed an Enter, so deleting its `|| return 1`
# survived the suite green. A failed Enter that is not returned on falls through
# to the after-capture, and any pane redraw from an UNRELATED source then reads
# as a landed submit. The capture-count pins below are what catch it: a returned
# -on failure never reaches the after-capture, so the counts differ.
#
# 4g. The FIRST Enter send fails. Pane lines 1/2 deliberately DIFFER, so a
# fall-through would report the submit landed on a keystroke never delivered.
printf 'composer: kick text\nturn started\nturn started\nx\n' > "$TD/p-noent1"
r="$(run_case noent1 "$TD/p-noent1" 0 0 1)"
is "4g failed first Enter returns 1"         "$r"                     "RC=1"
is "4g attempted two Enters"                 "$(count noent1 ENTER)"  "2"
is "4g did NOT retype the prompt"            "$(count noent1 TYPE)"   "1"
is "4g skipped the after-capture it never earned" "$(caps noent1)"    "3"
if [[ -n "$(bc_of noent1)" ]]; then ok "4g failed first Enter is recorded"
else no "4g failed first Enter is recorded"; fi

# 4h. The RETRY's Enter send fails — the last send on the path.
printf 'composer: kick text\ncomposer: kick text\ncomposer: kick text\nturn started\n' > "$TD/p-noent2"
r="$(run_case noent2 "$TD/p-noent2" 0 0 2)"
is "4h failed retry Enter returns 1"         "$r"                     "RC=1"
is "4h attempted two Enters"                 "$(count noent2 ENTER)"  "2"
is "4h skipped the after-capture it never earned" "$(caps noent2)"    "3"
if [[ -n "$(bc_of noent2)" ]]; then ok "4h failed retry Enter is recorded"
else no "4h failed retry Enter is recorded"; fi

# 4e. The type itself fails: no Enter should be sent at all.
printf 'x\nx\nx\nx\n' > "$TD/p-notype"
r="$(run_case notype "$TD/p-notype" 0 1)"
is "4e failed type returns 1"          "$r"                     "RC=1"
is "4e sends no Enter after a failed type" "$(count notype ENTER)" "0"
if [[ -n "$(bc_of notype)" ]]; then ok "4e failed type is recorded"
else no "4e failed type is recorded"; fi
is "4e captures nothing after a failed type" "$(caps notype)"        "0"

# 4f. Recovery clears a stale breadcrumb, so a healed boot stops reporting.
mkdir -p "$TD/healed"; printf 'stale\n' > "$TD/healed/.5dive-coldstart-kick-failed"
printf 'composer: kick text\nturn started\n' > "$TD/p-healed"
r="$(run_case healed "$TD/p-healed" 0 0)"
is "4f healed boot returns 0"          "$r"              "RC=0"
is "4f healed boot clears the breadcrumb" "$(bc_of healed)" ""

printf '\n%s: pass=%d fail=%d\n' "$(basename "$0")" "$pass" "$fail"
[[ "$fail" == 0 ]]
