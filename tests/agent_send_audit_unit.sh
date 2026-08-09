#!/usr/bin/env bash
# DIVE-2797 — every inter-agent send leaves an audit row, and the row names the
# DERIVED caller independently of the forgeable --from label.
#
# THE DEFECT: `5dive agent send` set no AUDIT_CMD, so the dispatcher's EXIT trap
# wrote nothing. Measured on the live box before the fix: `"cmd":"agent send"` =
# 0 rows in /var/log/5dive/agent-audit.log while `"cmd":"task inbox send"` = 83
# rows in the SAME file with the SAME grep shape. The absence was the logging, not
# the traffic. Consequence: an admin-tier message labelled `from=main` steered a
# fleet notice and the scope of a HIGH row, and no artifact anywhere could say who
# sent it — `--from=` is caller-supplied and was the only provenance a recipient
# had. A recipient could re-verify the CLAIM and never the SOURCE.
#
# WHY THE ROW MUST NOT SIMPLY RECORD --from: logging the claim is logging the
# thing under suspicion. An audit trail built from it would look complete and
# establish nothing. Both halves are carried — `from_claimed` (asserted) and
# `from_derived` (measured, via the same _envelope_caller the rendered envelope
# uses) — so a divergence is greppable rather than a judgement call.
#
# WHY THREE VERBS AND NOT ONE: cmd_send reaches the scoped delivery primitive with
# `exec`, which REPLACES the process — the outer EXIT trap never fires. Wiring
# only `send` would have left every standard-tier a2a send audited by nobody,
# which is a guard covering a narrower population than its name (DIVE-2788). `ask`
# accepts the same forgeable --from one verb over.
#
# T9 is a PAIRED PRE-FIX MUTANT: the same assertions are re-run against a copy of
# the dispatcher with the new lines stripped, and are required to FAIL there.
# Without it this file cannot distinguish "the fix is present" from "the assertion
# matches anything".
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# src/header.sh sets `set -euo pipefail`; sourcing production code re-enables
# errexit and the first non-zero substitution kills the file. Grade the summary.
set +e

TMPD=""
trap 'rc=$?; [[ -n "$TMPD" ]] && rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REG="$ROOT/src/lib/registry.sh"
RUNTIME="$ROOT/src/cmd_agent_runtime.sh"
MAIN="$ROOT/src/main.sh"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# --- T0 the extractions, graded before anything depends on them --------------
# An extraction that silently yields nothing makes every arm below vacuous, and a
# vacuous arm reports as a pass. Grade the extraction itself first.
VIA_FN="$(awk '/^envelope_via\(\) \{/,/^\}/' "$REG")"
PROV_FN="$(awk '/^envelope_provenance\(\) \{/,/^\}/' "$REG")"
[[ -n "$VIA_FN" && "$VIA_FN" == *'unknown:no-caller'* ]] \
  && ok_t 'T0a envelope_via extracted and non-empty' \
  || bad_t 'T0a envelope_via not extractable — T1-T5 would be vacuous' "reg=$REG"
[[ -n "$PROV_FN" && "$PROV_FN" == *'corroborated'* ]] \
  && ok_t 'T0b envelope_provenance extracted and non-empty' \
  || bad_t 'T0b envelope_provenance not extractable — T1-T5 would be vacuous' "reg=$REG"
eval "$VIA_FN"; eval "$PROV_FN"

# --- T1-T5 the verdict vocabulary --------------------------------------------
# One resolver, composed over envelope_via, so the audit row and the rendered
# envelope can never disagree about whether a send was mislabeled.
v() { envelope_provenance "$1" "$2"; }

[[ "$(v dev dev)" == "corroborated" ]] \
  && ok_t 'T1 claimed == measured -> corroborated' \
  || bad_t 'T1 corroborated' "got=$(v dev dev)"

# The incident's exact shape: the admin-tier message labelled from=main, sent by
# somebody else. This is the row an operator greps for.
[[ "$(v main dev)" == "divergent" ]] \
  && ok_t 'T2 claimed != measured -> divergent (the mislabeled send)' \
  || bad_t 'T2 divergent' "got=$(v main dev)"

# --raw / --from= assert nothing, so there is nothing to contradict. Folding this
# into `divergent` would bury the rows that matter under every ordinary raw send.
[[ "$(v "" dev)" == "unclaimed" ]] \
  && ok_t 'T3 nothing claimed -> unclaimed, NOT divergent' \
  || bad_t 'T3 unclaimed' "got=$(v "" dev)"

# Nothing measured is not a verdict of innocence. envelope_via's reason string is
# passed through intact rather than collapsed to a bare "unknown".
[[ "$(v main "")" == "unknown:no-caller" ]] \
  && ok_t 'T4 nothing measured -> unknown:no-caller (reason preserved)' \
  || bad_t 'T4 unknown:no-caller' "got=$(v main "")"
[[ "$(v main "bad name")" == "unknown:malformed-caller" ]] \
  && ok_t 'T5 unmeasurable caller -> unknown:malformed-caller' \
  || bad_t 'T5 unknown:malformed-caller' "got=$(v main "bad name")"

# --- T6 the dispatcher wires all three verbs ---------------------------------
# Scoped to the dispatch ARM, not to the file: a file-wide grep for the string is
# satisfied by an occurrence anywhere, including a comment.
# Deliberately NOT anchored with `$`: the pre-fix arms were one-liners
# (`send)    cmd_send "$@" ;;`) and an end-anchored pattern extracts nothing from
# them. That would make this harness report "not extractable" against the very
# tree whose real defect is "unaudited verb" — a misdiagnosis of the thing it
# exists to catch.
arm() { awk -v pat="^        $1\\\\)" '$0 ~ pat {f=1} f {print} f && /;;$/ {exit}' "${2:-$MAIN}"; }
for pair in "send|agent send" "ask|agent ask" "_deliver|agent _deliver"; do
  verb="${pair%%|*}"; want="${pair##*|}"
  block="$(arm "$verb")"
  if [[ -z "$block" ]]; then
    bad_t "T6 dispatch arm '$verb' not extractable" "the assertion below would be vacuous"
  elif [[ "$block" == *"AUDIT_CMD=\"$want\""* ]]; then
    ok_t "T6 dispatch arm '$verb' sets AUDIT_CMD=\"$want\""
  else
    bad_t "T6 dispatch arm '$verb' sets no AUDIT_CMD" "unaudited verb: $block"
  fi
done

# --- T7 each handler populates the row with the MEASURED caller ---------------
# The dispatcher can only set a placeholder — it cannot tell a target from a
# `--message=` body — so the handler must rewrite AUDIT_ARGS after parsing.
fn() { awk -v pat="^$1\\\\(\\\\) \\\\{" '$0 ~ pat {f=1} f {print} f && /^\}$/ {exit}' "$RUNTIME"; }
for h in cmd_send cmd_ask cmd_deliver; do
  body="$(fn "$h")"
  if [[ -z "$body" ]]; then
    bad_t "T7 $h not extractable" "the assertions below would be vacuous"
    continue
  fi
  [[ "$body" == *"AUDIT_ARGS=("* ]] \
    && ok_t "T7 $h rewrites AUDIT_ARGS after parsing" \
    || bad_t "T7 $h leaves the dispatcher placeholder" "row would say to=<unparsed>"
  [[ "$body" == *"from_derived="* && "$body" == *"provenance="* ]] \
    && ok_t "T7 $h records BOTH from_derived and provenance" \
    || bad_t "T7 $h records no independent derivation" "a row carrying only the claim is a copy of the claim"
done

# --- T8 the message body never reaches the log --------------------------------
# agent-audit.log is readable by anyone on the box and world-appendable through
# the privileged fallback. Message bodies carry gate asks and pasted output; the
# attribution question is answered by who/to-whom, never by the text.
body_leak=0
for h in cmd_send cmd_ask cmd_deliver; do
  args_block="$(fn "$h" | awk '/AUDIT_ARGS=\(/,/^  \)$/')"
  [[ -n "$args_block" ]] || continue
  # `${#message}` is a length and is fine; a bare `$message`/`${message}` is the leak.
  printf '%s' "$args_block" | grep -qE '\$\{?message\}?([^[:alnum:]_]|$)' \
    && { body_leak=1; bad_t "T8 $h puts the message body in the audit row" "$args_block"; }
done
(( body_leak )) || ok_t 'T8 no handler logs the message body (bytes only)'

# --- T9 PAIRED PRE-FIX MUTANT -------------------------------------------------
# Re-run T6 against a dispatcher with the DIVE-2797 lines removed. It must fail
# there. Without this arm, T6 cannot tell "the fix is present" from "the pattern
# matches anything".
TMPD="$(mktemp -d)"
MUT="$TMPD/main.sh"
# The mutant is the fix REMOVED and nothing else: delete exactly the three lines
# this ticket added. The arms keep their shape, so they still extract — which is
# the point. A mutant that failed to extract would "fail" for the wrong reason and
# say nothing about whether T6 discriminates.
sed -E -e '/AUDIT_CMD="agent (send|ask|_deliver)"/d' "$MAIN" > "$MUT"
mut_hits=0
for pair in "send|agent send" "ask|agent ask" "_deliver|agent _deliver"; do
  verb="${pair%%|*}"; want="${pair##*|}"
  block="$(arm "$verb" "$MUT")"
  [[ "$block" == *"AUDIT_CMD=\"$want\""* ]] && mut_hits=$((mut_hits+1))
done
# The mutant's arms are one-liners, so `arm` returns the line itself — non-empty
# extraction, zero AUDIT_CMD. Both properties are required: a mutant that extracts
# nothing would "fail" for the wrong reason and prove nothing about T6.
mut_extracted=0
for verb in send ask _deliver; do [[ -n "$(arm "$verb" "$MUT")" ]] && mut_extracted=$((mut_extracted+1)); done
if (( mut_extracted != 3 )); then
  bad_t 'T9 mutant arms not extractable' "extracted=$mut_extracted/3 — the mutant proves nothing"
elif (( mut_hits == 0 )); then
  ok_t 'T9 pre-fix mutant: all 3 arms extract and NONE sets AUDIT_CMD (T6 discriminates)'
else
  bad_t 'T9 pre-fix mutant still satisfies T6' "hits=$mut_hits — T6 does not discriminate"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
