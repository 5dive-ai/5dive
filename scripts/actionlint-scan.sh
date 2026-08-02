#!/usr/bin/env bash
# DIVE-2540 — workflow-file scanner. ONE implementation, shared by CI
# (.github/workflows/actionlint.yml) and the pre-push hook (scripts/git-hooks/
# pre-push), so neither can drift from the other.
#
# WHAT IT CLOSES. On 2026-08-02 an Actions expression delimiter written inside a
# SHELL COMMENT made release-cut.yml unparseable for 45 minutes (DIVE-2539).
# release-cut.yml is the only writer of a version anywhere in this repo, so no
# nightly cut could have fired, and nothing said so. Substitution is textual and
# happens BEFORE the shell exists, so `#` means nothing to it — the comment
# written to explain that the hazard had been avoided WAS the hazard. Full
# write-up: community/wiki/an-actions-expression-is-parsed-inside-shell-comments.md
#
# WHY NOTHING CAUGHT IT. `yaml.safe_load` ACCEPTS that file — it is valid YAML,
# and expression parsing is a second layer on top. shellcheck lints shell
# scripts, not `run:` blocks. And the run a broken workflow produces names
# nothing: zero jobs, 0s, and "This run likely failed because of a workflow file
# issue", with the check-runs and annotations APIs empty. actionlint names it in
# one run, with a byte offset that resolves to the comment.
#
# NARROWER THAN THE ROW WAS FILED, and this is main's own correction: a workflow
# edit CAN be validated on a branch today — push it and look for a zero-job
# failure run on that ref, which works even for a workflow with no `push`
# trigger. What was missing is (a) an instrument that NAMES the defect instead of
# a run that shrugs, and (b) anything that runs without a human remembering to
# probe. This is (a) and (b), not "no check was possible".
#
#   Usage:  scripts/actionlint-scan.sh [--with-shellcheck] [--no-canary] [FILES...]
#   Exit:   0 = clean   1 = findings   2 = COULD NOT SCAN
#
# THE CANARY IS THE POINT, not garnish. A green from a linter is worth exactly
# what the proof that the linter FIRED is worth, and every failure mode here —
# binary missing, wrong binary, arguments that silently lint nothing, a version
# whose expression checker moved — presents as "no findings". So before the tree
# is scanned, the same binary with the same flags is run against a fixture
# carrying the DIVE-2539 defect and a fixture that is known-good, and it must
# reject the first and accept the second. If it does not, this exits 2. A scanner
# that reports clean when it could not look is the defect this repo spent
# 2026-07-28 removing from six other controls, and an unproven instrument is that
# defect wearing a linter's name.
#
# EXIT 2 IS A THIRD OUTCOME, deliberately: "I could not tell" is neither pass nor
# fail, and folding it into either is the class this repo keeps re-learning
# (tests/lib/grading_tree.sh, DIVE-2274). An empty target set is exit 2 for the
# same reason — a rename of .github/workflows must not read as "clean".
#
# SHELLCHECK IS OFF BY DEFAULT, on purpose and only for now. actionlint shells
# out to shellcheck for `run:` bodies when it is on PATH (it is, on
# ubuntu-latest), and this tree emits three INFO findings today — SC2015 x2 in
# release-cut.yml and SC2153 in unit-tests.yml. Landing a gate that is red on
# arrival is how a gate gets disabled, and the class that BRICKS a workflow is
# the syntax/expression class, which needs none of it. `--with-shellcheck` is the
# whole tightening: fix the three, flip the flag.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || { echo "actionlint-scan: cannot resolve repo root" >&2; exit 2; }

# The binary. ACTIONLINT_BIN lets CI point at a pinned download and lets the unit
# harness point at a stub, so the harness never needs the real tool or a network.
BIN="${ACTIONLINT_BIN:-actionlint}"

CANARY_BAD="${ACTIONLINT_CANARY_BAD:-$ROOT/tests/fixtures/actionlint/canary-expression-in-run-comment.yml}"
CANARY_GOOD="${ACTIONLINT_CANARY_GOOD:-$ROOT/tests/fixtures/actionlint/known-good-yaml-level-comment.yml}"

# actionlint tags each finding with its rule kind in brackets. The DIVE-2539
# class is [expression]. Matching the KIND rather than the prose means a reworded
# message still satisfies the canary, while a version whose expression checker
# has genuinely moved fails CLOSED (exit 2) and forces a re-measurement instead
# of quietly scanning with a checker that no longer looks.
CANARY_SIGNATURE='\[expression\]'

WITH_SHELLCHECK=0
RUN_CANARY=1
TARGETS=()
while (( $# )); do
  case "$1" in
    --with-shellcheck) WITH_SHELLCHECK=1 ;;
    # ONLY for the harness arms that grade the canary machinery itself. There is
    # no CI path that sets this, and there must not be one.
    --no-canary)       RUN_CANARY=0 ;;
    --help|-h)         sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    --*)               echo "actionlint-scan: unknown flag '$1'" >&2; exit 2 ;;
    *)                 TARGETS+=("$1") ;;
  esac
  shift
done

# Flags, assembled ONCE so the canary and the tree scan are provably the same
# invocation. A canary run under different flags proves nothing about the run
# that matters.
FLAGS=(-no-color -oneline)
if (( ! WITH_SHELLCHECK )); then
  FLAGS+=(-shellcheck= -pyflakes=)
fi

command -v "$BIN" >/dev/null 2>&1 || {
  echo "actionlint-scan: actionlint not found (looked for '$BIN') — REFUSING to report clean" >&2
  exit 2
}

# --- the canary: prove the instrument fires, and fires SPECIFICALLY ----------
if (( RUN_CANARY )); then
  for f in "$CANARY_BAD" "$CANARY_GOOD"; do
    [[ -r "$f" ]] || { echo "actionlint-scan: canary fixture unreadable ($f) — REFUSING to report clean" >&2; exit 2; }
  done

  bad_out="$("$BIN" "${FLAGS[@]}" "$CANARY_BAD" 2>&1)"; bad_rc=$?
  if (( bad_rc == 0 )); then
    echo "actionlint-scan: CANARY DID NOT FIRE — '$BIN' accepted a file carrying the DIVE-2539 defect." >&2
    echo "actionlint-scan: the instrument is dead or mis-invoked; a clean scan would mean nothing. REFUSING." >&2
    exit 2
  fi
  if ! grep -qE "$CANARY_SIGNATURE" <<<"$bad_out"; then
    echo "actionlint-scan: canary failed for the WRONG REASON — no [expression] finding in:" >&2
    printf '%s\n' "$bad_out" >&2
    echo "actionlint-scan: this binary rejects the fixture but not as an expression error. REFUSING." >&2
    exit 2
  fi

  # The other half, and it is not symmetry for its own sake: a scanner that
  # rejects EVERYTHING also passes the arm above. The known-good fixture carries
  # the same delimiter at YAML level, where it is a real comment and genuinely
  # harmless (pii-guard.yml has carried one for months). Rejecting it would mean
  # the instrument is a grep for the delimiter, which would make every honest
  # mention of the syntax unlandable — including this repo's own write-up of it.
  if ! good_out="$("$BIN" "${FLAGS[@]}" "$CANARY_GOOD" 2>&1)"; then
    echo "actionlint-scan: CANARY OVER-FIRES — '$BIN' rejected a known-good workflow:" >&2
    printf '%s\n' "$good_out" >&2
    echo "actionlint-scan: findings from this binary cannot be trusted. REFUSING." >&2
    exit 2
  fi
fi

# --- the actual scan ---------------------------------------------------------
if (( ! ${#TARGETS[@]} )); then
  shopt -s nullglob
  TARGETS=("$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml)
  shopt -u nullglob
fi

if (( ! ${#TARGETS[@]} )); then
  echo "actionlint-scan: no workflow files found under $ROOT/.github/workflows — REFUSING to report clean" >&2
  echo "actionlint-scan: an empty target set is 'I scanned nothing', not 'nothing is wrong'." >&2
  exit 2
fi

out="$("$BIN" "${FLAGS[@]}" "${TARGETS[@]}" 2>&1)"; rc=$?
case "$rc" in
  0) exit 0 ;;
  1) printf '%s\n' "$out"; exit 1 ;;
  *) printf '%s\n' "$out" >&2
     echo "actionlint-scan: '$BIN' exited $rc (usage/internal error, not a verdict) — REFUSING to report clean" >&2
     exit 2 ;;
esac
