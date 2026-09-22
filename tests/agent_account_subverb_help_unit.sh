#!/usr/bin/env bash
# Every `5dive agent` and `5dive account` SUBVERB answers `--help` with its own
# usage — the way every `5dive task` subverb has since PR-1000.
#
# THE DEFECT this pins (verified on 0.44.1): PR-1000 fixed ONE surface. `agent`
# and `account` were dispatched straight into per-verb flag loops that all end in
# `-*) fail "$E_USAGE" "unknown flag: $1"`, so the question an operator actually
# types read as a typo:
#
#   5dive agent info --help     -> error: unknown flag: --help            rc 2
#   5dive agent rm --help       -> error: unknown flag '--help' — usage…  rc 2
#   5dive agent skill --help    -> error: no agent named '--help'         rc 4
#   5dive account set --help    -> the set usage, rc 2
#   5dive account --help        -> error: unknown account command: --help rc 2
#
# WHAT THIS GRADES, and why it walks the case statements instead of a list: the
# fix answers in ONE place per surface (before the dispatch) and READS the text
# from the surface usage or from the verb's own `usage:` literal. A list of verbs
# in here would go stale exactly when a new verb is added without either — which
# is the case this is built to catch. So the labels come out of
# `_agent_verb_dispatch` / `_account_verb_dispatch`'s own `case` in src/main.sh,
# every one of them is asked for help, and the counts are printed so a shrinking
# corpus is visible rather than silent.
#
# It grades the BUILT BUNDLE rather than sourced functions, for two reasons: it
# is the artifact that ships, and src/main.sh ends in `main "$@"`, so a harness
# that sourced it would run the CLI. The run is read-only — the intercept answers
# before any verb is dispatched — and needs no root, no network and no install
# (arm L proves that rather than asserting it).
#
#   bash tests/agent_account_subverb_help_unit.sh
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-account-help.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

# --- the artifact ------------------------------------------------------------
BUNDLE="$TMP/5dive"
if ! BUILD_OUT="$BUNDLE" ./build.sh >"$TMP/build.log" 2>&1; then
  bad_t "P0: a bundle builds (every arm below runs against it)" "$(tail -3 "$TMP/build.log")"
  echo "-----"; printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"; exit 1
fi
ok_t "P0: a bundle builds (the artifact the fix actually ships in)"

# Every invocation is sandboxed: its own HOME and STATE_DIR, nothing of this
# box's install in scope. Arm L proves that is real rather than decorative.
run() { ( HOME="$TMP/home" STATE_DIR="$TMP/state" "$BUNDLE" "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
out() { cat "$TMP/out"; }
err() { cat "$TMP/err"; }
first() { head -1 "$TMP/out"; }
mkdir -p "$TMP/home" "$TMP/state"

# --- 0) The corpus: every label each dispatcher's own case dispatches ---------
# Read out of the FILE, not out of the runtime, so a fix that broke the runtime
# reader could not also shrink the list it is graded against. Each line is
# "<label> <canonical>" — the canonical spelling is the group's first alternate,
# which is what the answer must name for an alias.
labels() {
  awk -v fn="$1" '
    $0 == fn "() {" { f = 1; next }
    f && /^\}/      { exit }
    f && /^        [a-z0-9|_-]+\)/ {
      lab = $1; sub(/\)$/, "", lab)
      n = split(lab, alt, "|")
      for (i = 1; i <= n; i++) print alt[i], alt[1]
    }' "$SRC/main.sh"
}
mapfile -t AGENT_LABELS   < <(labels _agent_verb_dispatch)
mapfile -t ACCOUNT_LABELS < <(labels _account_verb_dispatch)
(( ${#AGENT_LABELS[@]} >= 45 )) \
  && ok_t "P1: _agent_verb_dispatch's case dispatches ${#AGENT_LABELS[@]} subverb labels" \
  || bad_t "P1: the agent case enumerates its subverbs" "found only ${#AGENT_LABELS[@]}"
(( ${#ACCOUNT_LABELS[@]} >= 10 )) \
  && ok_t "P2: _account_verb_dispatch's case dispatches ${#ACCOUNT_LABELS[@]} subverb labels" \
  || bad_t "P2: the account case enumerates its subverbs" "found only ${#ACCOUNT_LABELS[@]}"
{ grep -qx 'fire rm' <<<"$(printf '%s\n' "${AGENT_LABELS[@]}")" \
  && grep -qx 'rm remove' <<<"$(printf '%s\n' "${ACCOUNT_LABELS[@]}")"; } \
  && ok_t "P3: the corpus carries aliases too (agent fire->rm, account rm->remove)" \
  || bad_t "P3: aliases are in the corpus" "fire/rm missing"

# --- A/B) EVERY public label answers --help, with ITS OWN usage --------------
# `_`-prefixed verbs are deliberately undocumented internals (the same carve-out
# tests/usage_enumeration_completeness_unit.sh states); arm C pins what they do.
# `-h|--help|help` is the SURFACE's own help arm; arm E grades it.
sweep() {
  local surface="$1"; shift
  local -n LABS="$1"
  local lab canon rc line
  ASKED=0; ANSWERED=0; BAD_RC=(); BAD_LINE=()
  for pair in "${LABS[@]}"; do
    read -r lab canon <<<"$pair"
    [[ -n "$lab" ]] || continue
    case "$lab" in _*|-h|--help|help) continue ;; esac
    ASKED=$((ASKED+1))
    rc="$(run "$surface" "$lab" --help)"
    [[ "$rc" == "0" ]] || { BAD_RC+=("$lab(rc=$rc: $(err | head -1))"); continue; }
    line="$(first)"
    case "$line" in
      "usage: 5dive $surface $canon"*) ANSWERED=$((ANSWERED+1)) ;;
      *) BAD_LINE+=("$lab -> ${line:-<empty>}") ;;
    esac
  done
}
for surface in agent account; do
  case "$surface" in agent) sweep agent AGENT_LABELS ;; account) sweep account ACCOUNT_LABELS ;; esac
  tag=$([[ $surface == agent ]] && echo A || echo B)
  (( ${#BAD_RC[@]} == 0 )) \
    && ok_t "${tag}1: all $ASKED public '$surface' labels exit 0 on --help" \
    || bad_t "${tag}1: --help exits 0 for every public '$surface' label" "${#BAD_RC[@]} did not: ${BAD_RC[*]}"
  (( ${#BAD_LINE[@]} == 0 && ANSWERED == ASKED )) \
    && ok_t "${tag}2: all $ANSWERED of them open with 'usage: 5dive $surface <verb>'" \
    || bad_t "${tag}2: every label prints its own usage line" "${#BAD_LINE[@]} wrong: ${BAD_LINE[*]}"
done

# A3: the answer is the verb's OWN usage, not the whole surface — the failure a
# "print usage for everything" fix would pass A1 and A2 with.
run agent types --help >/dev/null
SURFACE_LINES=$( ( HOME="$TMP/home" "$BUNDLE" --help 2>/dev/null ) | grep -c '')
TYPES_LINES=$(out | grep -c '')
{ (( TYPES_LINES > 0 && SURFACE_LINES > 100 && TYPES_LINES < SURFACE_LINES / 10 )); } \
  && ok_t "A3: 'agent types --help' is its own entry ($TYPES_LINES lines), not the $SURFACE_LINES-line surface" \
  || bad_t "A3: the answer is scoped to the verb" "$TYPES_LINES lines against a $SURFACE_LINES-line surface"

# A4: a verb the top-level usage does NOT document falls back to its own
# `usage:` literal. `agent export` is that case; without the fallback it answers
# nothing at all.
rc="$(run agent export --help)"
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive agent export'; } \
  && ok_t "A4: an undocumented-on-the-surface verb falls back to its own literal (agent export)" \
  || bad_t "A4: the own-literal fallback answers" "rc=$rc first: $(first)"
! ( HOME="$TMP/home" "$BUNDLE" --help 2>/dev/null ) | grep -qE '^  5dive agent export' \
  && ok_t "A4b: ... and 'agent export' really is absent from the surface (A4 is not vacuous)" \
  || bad_t "A4b: agent export is absent from the surface usage" "it is documented there, so A4 proves nothing"

# B3: the surface-wide guard string must not be mistaken for a verb's own line.
# `usage: 5dive account list|show|usage|add|…` is what the no-arg call prints;
# answering `account list --help` with it would be the invented-answer failure.
rc="$(run account list --help)"
{ [[ "$rc" == "0" ]] && ! has "$(first)" 'list|show|usage'; } \
  && ok_t "B3: 'account list --help' is list's line, not the surface-wide guard string" \
  || bad_t "B3: the guard string is not reused as a verb's usage" "rc=$rc first: $(first)"

# --- C) The internals that document themselves NOWHERE, pinned by name -------
# They are refused BY NAME rather than answered with an invented line. Pinned so
# the list cannot quietly grow — a new PUBLIC verb landing in it would be a
# missing usage entry, which is the defect class this harness exists for.
UNDOC=()
for lab in _self_restart _default_skills _sync_codex_baseline _reconcile_sudoers _reconcile_coauthors; do
  rc="$(run agent "$lab" --help)"
  { [[ "$rc" != "0" ]] && has "$(err)" 'no usage text'; } || UNDOC+=("$lab(rc=$rc)")
done
(( ${#UNDOC[@]} == 0 )) \
  && ok_t "C1: the 5 undocumented internals are refused BY NAME, not answered with an invented line" \
  || bad_t "C1: an undocumented verb is refused by name" "${UNDOC[*]}"
C_GREW=()
for pair in "${AGENT_LABELS[@]}"; do
  read -r lab _ <<<"$pair"
  case "$lab" in _self_restart|_default_skills|_sync_codex_baseline|_reconcile_sudoers|_reconcile_coauthors) continue ;; _*) ;; *) continue ;; esac
  rc="$(run agent "$lab" --help)"
  [[ "$rc" == "0" ]] || C_GREW+=("$lab(rc=$rc)")
done
(( ${#C_GREW[@]} == 0 )) \
  && ok_t "C2: ... and every OTHER internal does answer, so C1's list is exactly 5 and not 'whatever failed'" \
  || bad_t "C2: the undocumented list is exactly those 5" "these also failed: ${C_GREW[*]}"

# --- D) The flag is a question, not a seat name ------------------------------
# `agent skill` takes an agent NAME first, so the unfixed tree read `--help` as
# the seat to operate on and answered "no agent named '--help'" (rc 4).
rc="$(run agent skill --help)"
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive agent skill' && ! has "$(err)" 'no agent named'; } \
  && ok_t "D1: 'agent skill --help' is a question, not a seat named '--help'" \
  || bad_t "D1: --help is not taken as a positional" "rc=$rc first: $(first) err: $(err | head -1)"

# --- E) The surfaces themselves ----------------------------------------------
rc="$(run account --help)"
{ [[ "$rc" == "0" ]] && has "$(out)" '5dive account list'; } \
  && ok_t "E1: '5dive account --help' answers at all (it had no help arm — rc 2, 'unknown account command')" \
  || bad_t "E1: the account surface answers --help" "rc=$rc first: $(first)"
rc="$(run agent --help)"
{ [[ "$rc" == "0" ]] && has "$(out)" '5dive agent list'; } \
  && ok_t "E2: '5dive agent --help' is unchanged" \
  || bad_t "E2: the agent surface still answers --help" "rc=$rc first: $(first)"
rc="$(run task ls --help)"
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive task ls'; } \
  && ok_t "E3: 'task ls --help' still answers — the surface this generalised out of" \
  || bad_t "E3: no regression on the task surface" "rc=$rc first: $(first)"

# --- F) Aliases answer with the verb they actually run -----------------------
F_BAD=()
for spec in "agent fire|usage: 5dive agent rm" "account rm|usage: 5dive account remove"; do
  cmd="${spec%%|*}"; want="${spec#*|}"
  # shellcheck disable=SC2086
  rc="$(run $cmd --help)"
  { [[ "$rc" == "0" ]] && has "$(first)" "$want"; } || F_BAD+=("$cmd(rc=$rc: $(first))")
done
(( ${#F_BAD[@]} == 0 )) \
  && ok_t "F1: both aliases answer with the canonical verb's usage" \
  || bad_t "F1: aliases resolve to the verb they run" "${F_BAD[*]}"

# --- G) Where help STOPS being a question ------------------------------------
rc="$(run agent info -h)"
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive agent info'; } \
  && ok_t "G1: -h is the same question as --help" \
  || bad_t "G1: -h answers" "rc=$rc first: $(first)"
rc="$(run agent info -- --help)"
{ [[ "$rc" != "0" ]] && ! has "$(first)" 'usage: 5dive agent info'; } \
  && ok_t "G2: '--' ends the flags: --help after it is an ARGUMENT, not a question" \
  || bad_t "G2: -- stops the help scan" "rc=$rc first: $(first)"
# G3: an ordinary call is not swallowed. The intercept prints to STDOUT and
# exits 0; the real arguments check prints to STDERR and exits non-zero, so the
# stream is the discriminator and not the text.
rc="$(run account show)"
{ [[ "$rc" != "0" ]] && [[ -z "$(out)" ]] && has "$(err)" 'usage: 5dive account show'; } \
  && ok_t "G3: an ordinary call is not swallowed — 'account show' still refuses on stderr" \
  || bad_t "G3: the intercept only fires on --help" "rc=$rc out: $(first) err: $(err | head -1)"

# --- H) MUTANT: take the intercept out and the defect comes back -------------
# BEFORE/AFTER on purpose: "the intercept is gone" is also true of a sed that
# matched nothing, which would make every arm below vacuous.
mutant() {
  local surface="$1" mut="$TMP/5dive.mut-$1"
  # The bundle carries `if …; then return 0; fi` on ONE line (unlike `declare -f`,
  # which pretty-prints it over three), so the replacement keeps the tail: a
  # mutant that merely failed to PARSE would exit non-zero for the wrong reason
  # and say nothing about whether the intercept is what answers.
  sed "s|^\(\s*\)if _verb_help_intercept \"5dive $surface\".*|\1if false; then return 0; fi|" "$BUNDLE" >"$mut"
  printf '%s' "$mut"
}
for surface in agent account; do
  MUT="$(mutant "$surface")"
  grep -q "if _verb_help_intercept \"5dive $surface\"" "$BUNDLE" \
    && ok_t "H0a-$surface: BEFORE — the shipped bundle really does intercept --help on '$surface'" \
    || bad_t "H0a-$surface: the bundle intercepts --help" "no intercept found; the mutant arms below are vacuous"
  ! grep -q "if _verb_help_intercept \"5dive $surface\"" "$MUT" \
    && ok_t "H0b-$surface: AFTER — the mutation really removed it (the sed matched)" \
    || bad_t "H0b-$surface: the mutation removed the intercept" "the sed did not match; the mutant is not mutated"
  # The verb per surface is chosen so the mutant's refusal is deterministic and
  # ROOT-FREE — most arms of both surfaces call require_root before they parse a
  # flag at all, so on an unprivileged runner they would refuse for a reason that
  # has nothing to do with this fix. `agent logs` reaches its flag loop; no
  # `account` verb does, so account's defect is graded in its other shape: the
  # flag swallowed as the positional the verb was waiting for.
  case "$surface" in
    agent)   v=(agent logs);  want='unknown flag: --help' ;;
    account) v=(account show); want='invalid account name' ;;
  esac
  ( HOME="$TMP/home" STATE_DIR="$TMP/state" bash "$MUT" "${v[@]}" --help ) >"$TMP/out" 2>"$TMP/err"; rc=$?
  [[ "$rc" != "0" ]] \
    && ok_t "H1-$surface: MUTANT — '5dive ${v[*]} --help' fails again (A1/B1 would be red on it)" \
    || bad_t "H1-$surface: mutant fails on ${v[*]} --help" "it exited 0: $(first)"
  has "$(err)" "$want" \
    && ok_t "H2-$surface: MUTANT — and the operator is back to '$want' (the defect)" \
    || bad_t "H2-$surface: mutant prints the original error" "wanted '$want', stderr: $(err | head -1)"
  # The OTHER surface is untouched by this mutant: the two intercepts are
  # independent calls, not one switch.
  case "$surface" in agent) o=(account show) ;; account) o=(agent logs) ;; esac
  ( HOME="$TMP/home" STATE_DIR="$TMP/state" bash "$MUT" "${o[@]}" --help ) >"$TMP/out" 2>"$TMP/err"; rc=$?
  [[ "$rc" == "0" ]] \
    && ok_t "H3-$surface: ... and '5dive ${o[*]} --help' still answers (the surfaces are independent)" \
    || bad_t "H3-$surface: the other surface is unaffected" "rc=$rc err: $(err | head -1)"
done

# --- I) The shared helper's pure predicate -----------------------------------
# Sourced rather than run: `--help` inside a VALUE is the one case a bundle run
# cannot show cheaply, and it is the case that made `--` load-bearing.
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh; do source "$SRC/$f"; done
set +e
! _verb_help_wanted '--message=ship it --help me decide' \
  && ok_t "I1: a --help INSIDE a value is a value, not a question" \
  || bad_t "I1: --help inside a value is not a question" "it was taken as one"
_verb_help_wanted --lines=5 --help \
  && ok_t "I2: ... and a real --help after other flags still is one" \
  || bad_t "I2: --help after other flags is a question" "it was not"

# --- L) CI IS PRISTINE: no install, no root, no box paths --------------------
# marcus/DIVE-562: a predicate that short-circuits on an installed binary or a
# root-only path passes at a desk and reds on the runner. Every arm above ran
# with HOME and STATE_DIR inside the tempdir; this one removes the rest.
L_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx '/usr/local/bin' | paste -sd:)"
( PATH="$L_PATH" HOME="$TMP/home" STATE_DIR="$TMP/state" XDG_CONFIG_HOME="$TMP/home/.config" \
    "$BUNDLE" agent info --help ) >"$TMP/out" 2>"$TMP/err"; rc=$?
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive agent info'; } \
  && ok_t "L1: answers with /usr/local/bin off PATH and no state dir — nothing here needs this box's install" \
  || bad_t "L1: the arms do not depend on an installed 5dive" "rc=$rc first: $(first) err: $(err | head -1)"
# The pattern lives in a variable so the arm cannot match its OWN literal — the
# first version of this line reported itself as the violation.
_boxpat='/etc/5dive|/var/lib/5dive|/usr/local/bin/5dive'
_boxhits="$(grep -nE "$_boxpat" "$0" | grep -v '_boxpat=')"
[[ -z "$_boxhits" ]] \
  && ok_t "L2: ... and this harness names no box path at all (L1 is not the only thing holding that)" \
  || bad_t "L2: the harness reads no box path" "$_boxhits"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
