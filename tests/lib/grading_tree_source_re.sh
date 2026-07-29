# shellcheck shell=bash
# DIVE-2286: the ONE spelling of "does this harness source
# tests/lib/grading_tree.sh" (the DIVE-2211 corpus invariant). Shared by the
# CI contract (tests/names_the_tree_contract_unit.sh, whole-corpus) and the
# push-time guard (scripts/harness-tree-guard.sh, added-files-only) so the
# two cannot independently drift into grading two different properties under
# the same name — a regex typed twice can diverge twice; sourced once, it
# cannot.
readonly GRADING_TREE_SOURCE_RE='(^|[[:space:]])(\.|source)[[:space:]].*lib/grading_tree\.sh'
