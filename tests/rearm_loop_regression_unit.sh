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
#     Sections 5a/5b do the same for the OTHER reported fault, the kick that is
#     never TYPED (DIVE-3793), and 5c/5d/5e drive the three real BLOCK LOOPS —
#     because a warn that exists in a function but is never reached from the loop
#     is the silent failure with extra steps. 5f is the false-alarm control.
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
#
# DIVE-3793 added a third required guard to EVERY block: loop exhaustion must be
# REPORTED, not fallen through. Three lines per block, because three separate
# mutants live here — delete the warn call and the exhausted window goes silent
# again; delete the kicked marker and every HEALTHY boot cries wolf; delete the
# pane marker and an unreadable pane is reported as an absent marker, sending the
# reader to look at a fork that was probably fine.
_EXHAUST="coldstart_kick_never_typed|reports the exhausted window instead of falling through it
_kick_state=kicked|records that the kick WAS typed, so a landed kick does not also warn
_kick_state=pane|separates an unreadable pane from an absent marker"
declare -A _MUST=(
  [grok]="$_EXHAUST"
  [antigravity]="$_EXHAUST"
  # The wait_for_message guard's `then` now records the already-listening state
  # before it breaks, so this pattern must not pin `break` to the next token —
  # it would red on the very change that made the state reachable.
  [codex]="$_EXHAUST
grep -q .wait_for_message.;[[:space:]]*then.*break|does not type when the pane already shows wait_for_message (the plugin's inbound kick won the race)
_kick_state=listening|treats an already-listening pane as a success, not as a never-typed fault
grep -q .Hooks need review.;[[:space:]]*then[[:space:]]*continue|does not type while the first-run Hooks-need-review dialog is up
BIN.*CODEX_REAL_BIN|only the direct Codex TUI gets a cold-start kick (the app-server dispatcher owns its own input loop)"
)
kick_block_pattern() { # <type>
  case "$1" in
    codex)
      printf '%s\n' '^if \[\[ "\$TYPE" == "codex" && "\$CHANNELS" == "telegram" && "\$BIN" == "\$CODEX_REAL_BIN" \]\]; then$'
      ;;
    *)
      printf '%s\n' '^if \[\[ "\$TYPE" == "'"$1"'" && "\$CHANNELS" == "telegram" \]\]; then$'
      ;;
  esac
}
for _blk in grok antigravity codex; do
  _pat="$(kick_block_pattern "$_blk")"
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
    sed -n '/^coldstart_kick_never_typed()/,/^}/p'                             "$START"
  } | sed 's#/usr/bin/tmux#tmux#g'
}
_loaded="$(harness)"
for _fn in coldstart_kick_submit _coldstart_submit_once _coldstart_capture_pane \
           coldstart_kick_breadcrumb_path coldstart_kick_ok \
           coldstart_kick_never_typed; do
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

echo "== 5. BEHAVIOURAL: the exhausted window reports itself (DIVE-3793) =="
# 5a/5b grade the reporter. 5c..5f grade the WIRING, by running the real block
# loops — the fault being fixed is a code path nobody reached, so a test that
# only calls the function directly would pass on a source where no block calls it.

# 5a. Marker never appeared.
NT="$TD/nt-marker"; mkdir -p "$NT"
( set -uo pipefail; HOME="$NT"; export HOME
  eval "$_loaded"; coldstart_kick_never_typed grok marker; echo "RC=$?" ) >"$NT/out" 2>"$NT/err"
is "5a never-typed returns 1"          "$(cat "$NT/out")"  "RC=1"
if grep -q 'NEVER APPEARED' "$NT/.5dive-coldstart-kick-failed"; then
  ok "5a breadcrumb says the marker never appeared"
else no "5a breadcrumb says the marker never appeared (got '$(cat "$NT/.5dive-coldstart-kick-failed" 2>/dev/null)')"; fi
if grep -q 'NOT listening on Telegram' "$NT/.5dive-coldstart-kick-failed"; then
  ok "5a breadcrumb names the real state"
else no "5a breadcrumb names the real state"; fi
if grep -q 'NEVER TYPED' "$NT/err"; then ok "5a warns on stderr"
else no "5a warns on stderr (got '$(cat "$NT/err")')"; fi
# THE DISTINCTNESS ARM. Both faults park the agent, and a reader holding one
# breadcrumb must be able to tell which fault produced it. Assert it in BOTH
# directions against 4b's real submit-failure breadcrumb: a copy-pasted message
# would satisfy one direction and fail the other.
if grep -q 'NEVER OBSERVED' "$NT/.5dive-coldstart-kick-failed"; then
  no "5a never-typed text is distinct from the submit-failure text"
elif grep -q 'NEVER TYPED' <<<"$(bc_of wedged)"; then
  no "5a submit-failure text is distinct from the never-typed text"
else ok "5a the two faults are worded apart in both directions"; fi

# 5b. Pane unreadable — a DIFFERENT fault from an absent marker, and the message
# must not claim the marker was missing when we never got to look.
NP="$TD/nt-pane"; mkdir -p "$NP"
( set -uo pipefail; HOME="$NP"; export HOME
  eval "$_loaded"; coldstart_kick_never_typed codex pane; echo "RC=$?" ) >"$NP/out" 2>"$NP/err"
is "5b unreadable pane returns 1"      "$(cat "$NP/out")"  "RC=1"
if grep -q 'could not READ' "$NP/.5dive-coldstart-kick-failed"; then
  ok "5b breadcrumb names the unreadable pane"
else no "5b breadcrumb names the unreadable pane (got '$(cat "$NP/.5dive-coldstart-kick-failed" 2>/dev/null)')"; fi
if grep -q 'NEVER APPEARED' "$NP/.5dive-coldstart-kick-failed"; then
  no "5b does NOT claim the marker was absent when the capture failed"
else ok "5b does NOT claim the marker was absent when the capture failed"; fi

# ── the block loops, for real ───────────────────────────────────────────────
# Extract a kick block by its UNIQUE `if` line (same locator section 3 asserts
# unique) and run it with the tmux/sleep stubs. The block backgrounds its own
# subshell, so `wait` is what makes the assertion possible at all.
block_of() { # <blk>
  local _pat _ln
  _pat="$(kick_block_pattern "$1")"
  _ln="$(grep -nE "$_pat" "$START" | cut -d: -f1)"
  [[ -n "$_ln" ]] || { echo "echo BLOCK-NOT-FOUND >&2; exit 9"; return; }
  sed -n "${_ln},\$p" "$START" | awk 'NR>1 && /^fi$/{print;exit}{print}' \
    | sed 's#/usr/bin/tmux#tmux#g'
}
run_block() { # <name> <blk> <panes-file> <fail_capture_at|0> [direct|dispatcher]
  local box="$TD/blk-$1"; mkdir -p "$box"
  PANE_SCRIPT="$3" FAIL_CAPTURE_AT="$4" BOX="$box" _BTYPE="$2" _RUNMODE="${5:-direct}" \
  bash -c '
    set -uo pipefail
    HOME="$BOX"; export HOME
    TYPE="$_BTYPE"; CHANNELS=telegram; SESSION=agent-x
    CODEX_REAL_BIN=/usr/bin/codex
    if [[ "$_RUNMODE" == dispatcher ]]; then BIN=/usr/bin/bun; else BIN="$CODEX_REAL_BIN"; fi
    printf 0 > "$BOX/n"; printf 0 > "$BOX/e"
    sleep(){ :; }
    tmux(){
      local n
      case " $* " in
        *" capture-pane "*)
          n=$(( $(cat "$BOX/n") + 1 )); printf %s "$n" > "$BOX/n"
          [[ "$FAIL_CAPTURE_AT" != 0 && "$n" == "$FAIL_CAPTURE_AT" ]] && return 1
          sed -n "${n}p" "$PANE_SCRIPT"; return 0 ;;
        *" -l "*) printf "TYPE\n" >> "$BOX/sent"; return 0 ;;
        *" Enter "*|*" Enter") printf "ENTER\n" >> "$BOX/sent"; return 0 ;;
      esac
      return 0
    }
    '"$_loaded"'
    '"$(block_of "$2")"'
    wait
  ' 2>"$box/err"
}
berr(){ cat "$TD/blk-$1/err" 2>/dev/null || true; }
bbc(){ cat "$TD/blk-$1/.5dive-coldstart-kick-failed" 2>/dev/null || true; }
bsent(){ local n; n="$(grep -c "^$2$" "$TD/blk-$1/sent" 2>/dev/null)"; printf %s "${n:-0}"; }

# 5c. THE DEFECT, per block: the ready marker never shows for the whole window.
# Pre-fix every one of these arms is silent — empty stderr, no breadcrumb.
printf 'booting, no marker here\n' > "$TD/p-nomarker"
for _blk in grok antigravity codex; do
  run_block "ex-$_blk" "$_blk" "$TD/p-nomarker" 0
  if grep -q 'NEVER TYPED' <<<"$(berr "ex-$_blk")"; then
    ok "5c $_blk exhausted window warns on stderr"
  else no "5c $_blk exhausted window warns on stderr (got '$(berr "ex-$_blk")')"; fi
  if grep -q 'NEVER APPEARED' <<<"$(bbc "ex-$_blk")"; then
    ok "5c $_blk exhausted window leaves a breadcrumb naming the absent marker"
  else no "5c $_blk exhausted window leaves a breadcrumb naming the absent marker (got '$(bbc "ex-$_blk")')"; fi
  is "5c $_blk typed nothing"  "$(bsent "ex-$_blk" TYPE)"  "0"
done

# 5d. Capture fails on the first poll: the loop breaks MID-window and lands in
# the same arm. It must report the blindness, NOT an absent marker.
for _blk in grok antigravity codex; do
  run_block "cap-$_blk" "$_blk" "$TD/p-nomarker" 1
  if grep -q 'could not READ' <<<"$(bbc "cap-$_blk")"; then
    ok "5d $_blk unreadable pane is reported as unreadable"
  else no "5d $_blk unreadable pane is reported as unreadable (got '$(bbc "cap-$_blk")')"; fi
  if grep -q 'NEVER APPEARED' <<<"$(bbc "cap-$_blk")"; then
    no "5d $_blk does not blame the marker for a failed capture"
  else ok "5d $_blk does not blame the marker for a failed capture"; fi
done

# 5e. FALSE-ALARM CONTROL, per block: the marker DOES show and the submit lands.
# The kick must fire and NOTHING must claim it was never typed. A `case` whose
# healthy arm was dropped reds here and only here.
# One pane per capture call, so each fork's ready markers must share ONE line —
# codex needs the splash AND the composer caret in the same pane, and on a real
# box they are two rows of the same capture.
printf 'Resume session\ncomposer\nturn started\n'                    > "$TD/p-ok-grok"
printf '? for shortcuts\ncomposer\nturn started\n'                   > "$TD/p-ok-antigravity"
printf '>_ OpenAI Codex (v0.150.1) ›\ncomposer\nturn started\n' > "$TD/p-ok-codex"
for _blk in grok antigravity codex; do
  run_block "ok-$_blk" "$_blk" "$TD/p-ok-$_blk" 0
  is "5e $_blk healthy boot types the kick once" "$(bsent "ok-$_blk" TYPE)" "1"
  if grep -q 'NEVER TYPED' <<<"$(berr "ok-$_blk")"; then
    no "5e $_blk healthy boot does NOT warn never-typed"
  else ok "5e $_blk healthy boot does NOT warn never-typed"; fi
  is "5e $_blk healthy boot leaves no breadcrumb" "$(bbc "ok-$_blk")" ""
done

# 5f. codex only: the plugin's inbound kick already armed the listen loop. That
# is a success reached by a DIFFERENT break, and it must not report a fault.
printf 'wait_for_message\n' > "$TD/p-listening"
run_block listening codex "$TD/p-listening" 0
is "5f codex already-listening pane types nothing" "$(bsent listening TYPE)" "0"
if grep -q 'NEVER TYPED' <<<"$(berr listening)"; then
  no "5f codex already-listening pane does NOT warn never-typed"
else ok "5f codex already-listening pane does NOT warn never-typed"; fi
is "5f codex already-listening pane leaves no breadcrumb" "$(bbc listening)" ""

# 5g. DIVE-3961: channel-backed Codex now runs the app-server dispatcher rather
# than the interactive TUI. It owns inbound delivery itself, so typing the TUI
# listen-loop kick into the dispatcher's log pane would be both useless and a
# false success. The BIN identity guard is the behavioral discriminator.
run_block dispatcher codex "$TD/p-ok-codex" 0 dispatcher
is "5g codex dispatcher types no TUI kick" "$(bsent dispatcher TYPE)" "0"
if grep -q 'NEVER TYPED' <<<"$(berr dispatcher)"; then
  no "5g codex dispatcher does not report a skipped TUI kick as failure"
else ok "5g codex dispatcher does not report a skipped TUI kick as failure"; fi
is "5g codex dispatcher leaves no kick breadcrumb" "$(bbc dispatcher)" ""

printf '\n%s: pass=%d fail=%d\n' "$(basename "$0")" "$pass" "$fail"
[[ "$fail" == 0 ]]
