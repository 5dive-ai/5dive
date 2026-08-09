#!/usr/bin/env bash
# DIVE-3017 item 3: ASSERT THE OUTCOME, NOT THE DECLARATION.
#
# The first version of this check was going to extend the bundle-precondition
# enumerator — assert that every harness-running job DECLARES its dependency.
# olivia disproved that with evidence already in the run it was quoting: unit-tests
# job `test` HAS a step named "Install bun (harness precondition)", that step
# reported SUCCESS, and acp_stdio_unit.sh failed anyway, because the resolver
# declined to look where setup-bun had installed it. An inspecting check cannot see
# a resolver that does not look. The declaration assertion would have passed on a
# red job.
#
# So this asserts what the harness ACTUALLY DID, read back out of the run-harnesses
# TSV that CI already uploads:
#
#   the named harness RAN, exited rc=0, and took at least --min-ms
#
# The duration floor is the part that carries the real weight, and it is not a
# performance assertion. acp_stdio_unit.sh has three exits that all look healthy to
# a status-only reader:
#
#   PASS - 21 checks ................. rc=0, 4337ms   <- the only one that graded anything
#   PARTIAL (ACP_ALLOW_SKIP=1) ....... rc=0,   37ms   <- 3 preflight checks, stdio NOT run
#   FAIL (no bun, no escape) ......... rc=1,   64ms
#
# rc alone cannot separate row 1 from row 2 — that is the whole point of
# community/wiki/a-skip-that-exits-zero-is-a-pass-in-the-verdict.md. And a duration
# bar alone cannot separate a fast pass from a fast FAILURE, which is the amendment
# main's TSV forced (64ms rc=1 and 264ms rc=1 both read as "fast" to anyone not also
# reading column 2). Both columns, together, are satisfied only by the server having
# genuinely been driven.
#
# The TSV is a TIMING report — `ms<TAB>rc<TAB>path` plus `#` headers — so the literal
# PARTIAL/SKIP token is NOT in it and cannot be grepped here. The floor stands in for
# it, and it is the stronger form: it keeps holding if a future skip path prints some
# other word, or no word at all.
#
# FAILS CLOSED, on the same reasoning as harness-verdict-union.sh: a missing,
# unreadable or headerless report, or a corpus in which the harness does not appear
# at all, is exit 1. A check whose "everything is fine" state is reachable by the
# report never arriving would have the exact hole it exists to close.
#
# Sharding: pass every shard report for an environment. The harness lands in exactly
# one shard, so most reports legitimately do not carry the row — but the UNION must,
# and every row that IS present must be clean.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE THE `../`, and it is not cosmetic. The contract's canonical spelling is
# `$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh`, which is correct for a file
# directly in tests/ — from tests/meta/ it resolves to tests/meta/lib/grading_tree.sh,
# a path that cannot exist, so the literal block would satisfy the guard's regex and
# then print UNRESOLVED on every single invocation. That is the guard passing while
# the property it guards is absent, which is the same shape as everything else this
# file exists to catch. GRADING_TREE_SOURCE_RE matches `.*lib/grading_tree\.sh`, so
# the correct path satisfies it too — there is no trade here, only a wrong default.
# No `2>/dev/null` on the source: swallowing the helper's stderr would discard the
# line that IS the payload.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

HARNESS=""; MIN_MS=""; REPORTS=()
for a in "$@"; do
  case "$a" in
    --harness=*) HARNESS="${a#--harness=}" ;;
    --min-ms=*)  MIN_MS="${a#--min-ms=}" ;;
    --*) printf 'harness-graded-union: unknown flag %s\n' "$a" >&2; exit 2 ;;
    *) REPORTS+=("$a") ;;
  esac
done

if [[ -z "$HARNESS" || -z "$MIN_MS" || ${#REPORTS[@]} -eq 0 ]]; then
  printf 'usage: harness-graded-union.sh --harness=<basename> --min-ms=<n> <report.tsv>...\n' >&2
  exit 2
fi
if ! [[ "$MIN_MS" =~ ^[0-9]+$ ]]; then
  printf 'harness-graded-union: --min-ms must be an integer, got %s\n' "$MIN_MS" >&2
  exit 2
fi

fail=0
note() { printf '%s\n' "$*"; }
bad()  { printf 'FAIL - %s\n' "$*" >&2; fail=1; }

rows=0
for r in "${REPORTS[@]}"; do
  if [[ ! -r "$r" ]]; then
    bad "report not readable: $r (a lane that died must red this check, not shrink the corpus it claims)"
    continue
  fi
  # A headerless file is not an empty corpus, it is an unparseable one. Refuse it
  # rather than read zero rows out of it and call that a clean union.
  if ! grep -q '^# run-harnesses report' "$r"; then
    bad "report has no run-harnesses header: $r"
    continue
  fi
  # ms <TAB> rc <TAB> path — match the harness on its BASENAME so a corpus-dir move
  # cannot silently stop matching and read as "not in this shard".
  while IFS=$'\t' read -r ms rc path; do
    [[ "$(basename "${path:-}")" == "$HARNESS" ]] || continue
    rows=$(( rows + 1 ))
    note "  $r: $HARNESS  rc=$rc  ${ms}ms"
    if [[ "$rc" != "0" ]]; then
      bad "$HARNESS exited rc=$rc in $r — it ran and did not pass"
    elif (( ms < MIN_MS )); then
      bad "$HARNESS exited rc=0 in ${ms}ms, under the ${MIN_MS}ms floor in $r — rc=0 that fast is a skip/partial, not a graded run"
    fi
  done < <(grep -v '^#' "$r")
done

if (( rows == 0 )); then
  bad "$HARNESS appears in NONE of the ${#REPORTS[@]} report(s) — it was not selected by any shard, so nothing graded it"
fi

if (( fail )); then
  printf 'FAIL - %s was not graded in this run\n' "$HARNESS" >&2
  exit 1
fi
printf 'PASS - %s graded: %d row(s), all rc=0 and >= %sms\n' "$HARNESS" "$rows" "$MIN_MS"
