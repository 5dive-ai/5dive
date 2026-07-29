#!/usr/bin/env bash
# DIVE-2338 — a skill id must not be able to name a directory outside the skills dir.
#
# THE DEFECT: valid_skill_id was `^[A-Za-z0-9._-]+$`. It rejects a SLASH, which is what
# made it look safe, and accepts `.` and `..`, which are the entire traversal token. No
# slash is needed because the CALLER supplies the separator — cmd_skill_rm builds
# `target="$INSTALL_DIR/$SKILL"` and then `rm -rf "$target"`:
#     SKILL=..  -> .claude/skills/..  -> ~/.claude   (settings, credentials, projects, memory)
#     SKILL=.   -> .claude/skills/.   -> every installed skill
# and `skill` is reachable from the dashboard exec tunnel (allowlisted in 5dive-api
# routes/agents.ts; `..` passes AGENT_ARG_RE).
#
# WHY TWO CHECKS AND TWO ARMS FOR EACH: `.` is a legitimate character in a skill id AND
# the whole attack, so a character-class allowlist cannot separate them. The name check
# (valid_skill_id) refuses the tokens exactly; the structural check (skill_target_within)
# re-derives the concatenated path and asserts containment. The second is the one that
# still holds if somebody widens the regex later, so both are graded independently — a
# suite that only exercised the name check would go green against a reverted containment
# guard, and vice versa.
#
# NOTHING HERE DELETES ANYTHING. Every arm is the validator, the containment predicate,
# or a string resolution under a scratch dir. The destructive path is never invoked.

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2328/dev: src/header.sh sets `set -euo pipefail`, so sourcing production code
# re-enables errexit and the first non-zero command substitution kills the file.
set +e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_skill.sh"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# Extract the two predicates without executing the module.
FN_ID="$(awk '/^valid_skill_id\(\) \{/,/^\}/' "$SRC")"
FN_IN="$(awk '/^skill_target_within\(\) \{/,/^\}/' "$SRC")"
[[ -n "$FN_ID" ]] \
  && ok_t 'T0a valid_skill_id is present and extractable' \
  || bad_t 'T0a valid_skill_id not found — the name arms below are vacuous' "src=$SRC"
[[ -n "$FN_IN" ]] \
  && ok_t 'T0b skill_target_within is present and extractable' \
  || bad_t 'T0b containment predicate not found — the structural arms below are vacuous' "src=$SRC"
eval "$FN_ID"; eval "$FN_IN"

BASE="$(mktemp -d)/skills"; mkdir -p "$BASE"
trap 'rm -rf "$(dirname "$BASE")"' EXIT

# --- T1 the NAME check refuses the traversal tokens --------------------------
for tok in ".." "."; do
  if valid_skill_id "$tok"; then
    bad_t "T1 valid_skill_id ACCEPTED '$tok' — this is the DIVE-2338 defect" ''
  else
    ok_t "T1 valid_skill_id refuses '$tok'"
  fi
done
# `...` is not a traversal to readlink, but a name a normaliser might walk up. Refused
# by the all-dots rule, so the name check does not depend on which resolver runs later.
valid_skill_id "..." \
  && bad_t 'T1c an all-dots name is accepted' '' \
  || ok_t 'T1c valid_skill_id refuses an all-dots name (...) — not resolver-dependent'

# --- T2 ANCHOR: ordinary ids still pass, so T1 is not just "refuse everything" ---
for good in "normal-skill" "a.b" "no-ai-slop" "x_1"; do
  valid_skill_id "$good" \
    && ok_t "T2 ANCHOR ordinary id '$good' still accepted — T1 is not blanket refusal" \
    || bad_t "T2 ANCHOR ordinary id '$good' was REFUSED — the fix broke real skill ids" ''
done

# --- T3 the STRUCTURAL check refuses an escaping path ------------------------
# Graded separately from T1 on purpose: this is the arm that survives someone widening
# the character class, and T1 is the arm that survives someone dropping this predicate.
for tok in ".." "."; do
  if skill_target_within "$BASE" "$tok"; then
    bad_t "T3 skill_target_within ACCEPTED '$tok' — containment not enforced" \
          "resolves to $(readlink -m -- "$BASE/$tok")"
  else
    ok_t "T3 skill_target_within refuses '$tok' (resolves to $(readlink -m -- "$BASE/$tok"))"
  fi
done
skill_target_within "$BASE" "normal-skill" \
  && ok_t 'T3c ANCHOR containment ACCEPTS an ordinary id — T3 is not blanket refusal' \
  || bad_t 'T3c containment refused an ordinary id' ''

# --- T4 the two checks are INDEPENDENT --------------------------------------
# The point of the pair is that either alone would have shipped the hole once the other
# drifted. Assert that neither predicate is merely calling the other.
if grep -A6 '^valid_skill_id() {' "$SRC" | grep -q 'skill_target_within'; then
  bad_t 'T4 valid_skill_id delegates to the containment check — they are not independent' ''
else
  ok_t 'T4 the name check does not delegate to the containment check — independently gradeable'
fi

# --- T5 the rm site actually CALLS the containment check ---------------------
# A predicate nothing invokes is documentation. Grade the wiring, not just the helper.
grep -q 'skill_target_within "\$home/\$install_dir" "\$skill"' "$SRC" \
  && ok_t 'T5 cmd_skill_rm calls skill_target_within before the removal heredoc' \
  || bad_t 'T5 the containment check is defined but never called on the rm path' \
           "$(grep -n 'skill_target_within' "$SRC" | head -3)"

# --- T6 the heredoc re-asserts containment where the rm ACTUALLY runs --------
# The heredoc is a separate bash and cannot see the caller's functions. A guard that lives
# only in the caller protects every path except the one doing the deleting.
#
# REWRITTEN after dev's review of PR #311. The first cut RE-IMPLEMENTED the predicate
# inside the heredoc, which meant two copies of one control that could drift — and worse,
# a mutation table that looked like independence when it was really duplication: reverting
# skill_target_within left the heredoc copy still guarding, so the arms went red
# separately and read as two belts. They are not two belts. They are ONE control applied
# at two sites, and they must fail together.
#
# The fix is to SERIALIZE rather than copy: `declare -f skill_target_within` ships the
# function's own source into the heredoc, so there is exactly one implementation and drift
# is impossible by construction instead of by discipline.
grep -q 'CONTAINMENT_FN="\$(declare -f skill_target_within)"' "$SRC" \
  && ok_t 'T6 the caller SERIALIZES the real predicate into the heredoc (declare -f), not a copy' \
  || bad_t 'T6 the heredoc does not receive the real function — likely a re-implementation' \
           "$(grep -n 'CONTAINMENT_FN' "$SRC" | head -3)"

grep -q 'skill_target_within "\$INSTALL_DIR" "\$SKILL"' "$SRC" \
  && ok_t 'T6b the heredoc CALLS skill_target_within at the rm site rather than re-deriving the path' \
  || bad_t 'T6b the heredoc re-derives containment instead of calling the shipped predicate' ''

# T6c — FAIL CLOSED. If the predicate is not supplied the heredoc must refuse, not proceed
# to rm -rf. `${CONTAINMENT_FN:?...}` is what makes an absent guard fatal instead of empty.
grep -q 'CONTAINMENT_FN:?' "$SRC" \
  && ok_t 'T6c a missing predicate ABORTS the heredoc (:?) — an absent guard cannot read as a passing one' \
  || bad_t 'T6c the heredoc would proceed with no containment predicate' ''

# T6d — the heredoc must NOT carry its own readlink-based reimplementation any more.
if grep -A12 "bash -s >&2 <<'SKILL_REMOVE'" "$SRC" | grep -q '_rbase="\$(readlink'; then
  bad_t 'T6d a second readlink implementation survives inside the heredoc — the copy is back' ''
else
  ok_t 'T6d no duplicate readlink predicate inside the heredoc — one implementation only'
fi

echo "-----"
echo "skill_id_traversal_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
