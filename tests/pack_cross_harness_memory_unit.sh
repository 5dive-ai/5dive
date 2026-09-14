#!/usr/bin/env bash
# DIVE-4541 isolated unit harness for CROSS-HARNESS memory on export/import.
#
# The defect this grades: `5dive agent export codex --memory=raw` refused with
# "agent 'codex' has no persona memory to export" while 1.8 MB of memory sat in
# ~/.codex/memories — because _pack_memory_dir knew exactly one harness's path.
# The arms below grade the three claims the fix makes, not the prose:
#   1. the store RESOLVES per harness type, and an unknown type is answered
#      honestly (no store) rather than with the claude path;
#   2. a codex store CONVERTS into frontmattered atoms, and the distilled
#      conversion carries knowledge only — the user profile, the stated
#      preferences and the raw thread notes are NOT in it;
#   3. the converted atoms survive _pack_scope_memory unchanged, i.e. the
#      deny-by-default allowlist now actually holds over codex-sourced memory
#      instead of being unable to decide anything about it.
#
# Sources src/ directly (no root, no network).
# Run: bash tests/pack_cross_harness_memory_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/pack-xharness-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"

set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want [$3] got [$2]"; }

# --- fixtures ---------------------------------------------------------------
# registry_read is the ONLY thing _pack_agent_type reads; stub it so the arms
# grade the type mapping rather than whichever fleet the runner happens to be on.
REGFIX='{"agents":{"cx":{"type":"codex"},"cl":{"type":"claude"},"plain":{},"gx":{"type":"grok"}}}'
registry_read() { printf '%s\n' "$REGFIX"; }

# A codex store, same SHAPE as the measured one: `# Task Group:` sections whose
# knowledge subsections sit beside a private `## User preferences`.
STORE="$TMP/codex-store"; mkdir -p "$STORE"
cat > "$STORE/MEMORY.md" <<'MEM'
# Task Group: usage accounting for codex seats

scope: Add registered Codex-seat usage to `5dive usage`.
applies_to: cwd=/home/claude/projects/5dive

## Task 1: DIVE-4034 collect rollout usage

### rollout_summary_files

- rollout_summaries/2026-09-07T05-50-12-XwfR.md (thread_id=01a07a6a)

## User preferences

- SECRETPREF the user required "Work ONLY this one task".

## Reusable knowledge

- Codex `total_token_usage` is cumulative per rollout; summing snapshots multiplies usage.

## Failures and how to do differently

- Symptom: snapshot test is nondeterministic. Fix: strictly increasing timestamps.

# Task Group: operational-health repair

scope: Repair operational-health rendering through a maker/verifier loop.

## User preferences

- SECRETPREF stop at delivered rather than forcing done.

## Reusable knowledge

- A render contract is graded by the presenter, not by the writer.
MEM
cat > "$STORE/memory_summary.md" <<'SUM'
v1

## User Profile

PROFILEMARK Works extensively in /home/claude/projects/5dive across scoped board tasks.

## General Tips

- TIPMARK Locate the real checkout first; historical SHAs are routing hints.
SUM
cat > "$STORE/raw_memories.md" <<'RAW'
# Raw Memories

## Thread `019f605b-03f8-7e10-b54f-95728d8d92fe`

RAWMARK the seat could not reach the push rail without a gate.

## Thread `019f6ade-ac57-7c50-ae79-3b65edfbb16c`

RAWMARK the harness stage has a wall-clock cap.
RAW
mkdir -p "$STORE/rollout_summaries"
echo "- a per-session transcript summary" > "$STORE/rollout_summaries/2026-09-07.md"

# ============================ 1. type -> store ==============================
eq_t "codex seat maps to the codex store"    "$(_pack_memory_kind cx)"    "codex"
eq_t "claude seat maps to the claude store"  "$(_pack_memory_kind cl)"    "claude"
eq_t "a typeless registry entry is claude"   "$(_pack_memory_kind plain)" "claude"
# The whole point of the `none` answer: an unknown harness must NOT be handed
# the claude path. A wrong path here is how a pack ships a directory nobody
# meant to export, and it reads as success.
eq_t "an unknown harness has no known store" "$(_pack_memory_kind gx)"    "none"

# The store PATH is asked separately from the probe on purpose: this arm grades
# "never the claude path for a harness we do not know", with no filesystem at
# all. Probing instead would be vacuous — the fixture seat has no home either
# way, so a regression that reached for the claude path would still come back
# empty and read as a pass.
eq_t "a codex seat's store is ~/.codex/memories"  "$(_pack_memory_path cx)" "/home/agent-cx/.codex/memories"
eq_t "a claude seat's store is ~/.claude/projects" "$(_pack_memory_path cl)" "/home/agent-cl/.claude/projects"
out=$(_pack_memory_path gx 2>/dev/null); rc=$?
eq_t "an unknown harness yields NO store path"    "$out" ""
eq_t "an unknown harness's store lookup fails"    "$rc"  "1"
_pack_memory_dir gx >/dev/null 2>&1
eq_t "_pack_memory_dir refuses for an unknown harness" "$?" "1"

# ======================== 2. conversion, knowledge mode ======================
DRAFT="$TMP/draft"
n=$(_pack_codex_to_atoms "$STORE" "$DRAFT" knowledge)
eq_t "knowledge mode writes one atom per task group" "$n" "2"

body_all="$(cat "$DRAFT"/*.md 2>/dev/null)"
case "$body_all" in
  *SECRETPREF*) bad_t "distilled conversion drops '## User preferences'" "SECRETPREF leaked into the draft" ;;
  *)            ok_t  "distilled conversion drops '## User preferences'" ;;
esac
case "$body_all" in
  *PROFILEMARK*|*TIPMARK*) bad_t "distilled conversion drops memory_summary.md" "the user profile leaked" ;;
  *)                       ok_t  "distilled conversion drops memory_summary.md" ;;
esac
case "$body_all" in
  *RAWMARK*) bad_t "distilled conversion drops raw_memories.md" "unreviewed stage-1 text leaked" ;;
  *)         ok_t  "distilled conversion drops raw_memories.md" ;;
esac
case "$body_all" in
  *"rollout_summaries/2026-09-07T05-50-12"*) bad_t "distilled conversion drops the per-task rollout ids" "operational detail leaked" ;;
  *)                                         ok_t  "distilled conversion drops the per-task rollout ids" ;;
esac
case "$body_all" in
  *"cumulative per rollout"*) ok_t  "distilled conversion KEEPS '## Reusable knowledge'" ;;
  *)                          bad_t "distilled conversion KEEPS '## Reusable knowledge'" "the knowledge subsection is missing" ;;
esac
case "$body_all" in
  *"strictly increasing timestamps"*) ok_t  "distilled conversion KEEPS '## Failures and how to do differently'" ;;
  *)                                  bad_t "distilled conversion KEEPS '## Failures and how to do differently'" "the failures subsection is missing" ;;
esac

# Every atom must be a real atom: frontmatter with name/description/type, or the
# claude-side store cannot index, search or re-scope it.
badfm=0
for f in "$DRAFT"/*.md; do
  head -1 "$f" | grep -qx -- '---' || badfm=$((badfm+1))
  grep -q '^name: ' "$f"        || badfm=$((badfm+1))
  grep -q '^description: .' "$f" || badfm=$((badfm+1))
  grep -q '^  type: reference$' "$f" || badfm=$((badfm+1))
done
eq_t "every distilled atom carries name/description/metadata.type" "$badfm" "0"
# An atom must also keep its own section heading. Frontmatter alone makes the
# file indexable; the heading is what makes the fact self-describing once it is
# read out of the index, and dropping it is invisible to every arm above.
noheads=0
for f in "$DRAFT"/*.md; do
  sed -n '8,10p' "$f" | grep -q '^# Task Group: ' || noheads=$((noheads+1))
done
eq_t "every converted atom keeps its own section heading" "$noheads" "0"

# ============ 3. the allowlist now HOLDS over codex-sourced memory ===========
# This is the arm that matters for the seal phase: cmd_export re-applies
# _pack_scope_memory to whatever dir is approved. Before the conversion that
# filter could not read a type off a codex document and excluded the lot.
SEALED="$TMP/sealed"
counts=$(_pack_scope_memory "$DRAFT" "$SEALED")
eq_t "seal-time scoping keeps every converted atom" "${counts%% *}" "2"
eq_t "seal-time scoping excludes none of them"      "${counts##* }" "0"

# ======================== 4. conversion, all mode ============================
FULL="$TMP/full"
n2=$(_pack_codex_to_atoms "$STORE" "$FULL" all)
# 2 task groups + 2 summary sections + 2 threads. The leading `# Raw Memories`
# banner is not a section and must not become an atom.
eq_t "all mode converts every section of all three documents" "$n2" "6"
full_all="$(cat "$FULL"/*.md)"
for mark in SECRETPREF PROFILEMARK TIPMARK RAWMARK; do
  case "$full_all" in
    *"$mark"*) ok_t "all mode carries $mark" ;;
    *)         bad_t "all mode carries $mark" "missing from the converted store" ;;
  esac
done
# rollout_summaries/ is excluded by decision, not by accident.
case "$full_all" in
  *"a per-session transcript summary"*) bad_t "all mode excludes rollout_summaries/" "a subdir file was converted" ;;
  *)                                    ok_t  "all mode excludes rollout_summaries/" ;;
esac
# Private codex text must land TYPED private, or a later distilled re-export of
# this seat would publish the user's profile.
grep -lq 'PROFILEMARK' "$FULL"/*.md >/dev/null 2>&1
pf=$(grep -l 'PROFILEMARK' "$FULL"/*.md | head -1)
grep -q '^  type: user$' "$pf" && ok_t "the imported user profile is typed 'user'" \
  || bad_t "the imported user profile is typed 'user'" "got: $(grep '^  type:' "$pf")"
tf=$(grep -l 'TIPMARK' "$FULL"/*.md | head -1)
grep -q '^  type: feedback$' "$tf" && ok_t "imported general tips are typed 'feedback'" \
  || bad_t "imported general tips are typed 'feedback'" "got: $(grep '^  type:' "$tf")"

# ============================ 5. the index ==================================
_pack_atoms_index "$FULL" "Memory Index (imported from a codex store)"
[[ -f "$FULL/MEMORY.md" ]] && ok_t "conversion regenerates MEMORY.md" || bad_t "conversion regenerates MEMORY.md" "absent"
idx_lines=$(grep -c '^- \[' "$FULL/MEMORY.md")
eq_t "the index names every atom" "$idx_lines" "6"
# The reason the index exists at all: the source MEMORY.md is 143 KB on a real
# seat and a claude loader drops the TAIL past its limit with no error. A router
# over the same store has to be an order of magnitude smaller than the store.
idx_bytes=$(wc -c < "$FULL/MEMORY.md")
store_bytes=$(cat "$STORE/MEMORY.md" "$STORE/memory_summary.md" "$STORE/raw_memories.md" | wc -c)
[[ "$idx_bytes" -lt "$store_bytes" ]] \
  && ok_t "the regenerated index is smaller than the store it indexes ($idx_bytes < $store_bytes B)" \
  || bad_t "the regenerated index is smaller than the store it indexes" "index $idx_bytes B vs store $store_bytes B"
# The index carries one capped DESCRIPTION per atom and no body structure. A
# router that grows bodies is the failure this whole conversion exists to avoid,
# and it shows up as long lines and as copied `##` headings, not as a byte total.
eq_t "the index copies no section headings from the store" \
     "$(grep -c '^#\{2,\} ' "$FULL/MEMORY.md")" "0"
longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' "$FULL/MEMORY.md")
[[ "$longest" -le 320 ]] \
  && ok_t "no index line carries more than a capped description ($longest chars)" \
  || bad_t "no index line carries more than a capped description" "longest line is $longest chars"

# ===================== 6. the index stays inside the budget ==================
# NON-DEGENERATE ON PURPOSE. Six atoms fit in any budget; the real codex store
# converts to 104, and at 104 the full-description form measured 23 KB — over
# the always-loaded limit, where the loader drops the TAIL with no error. So the
# arm that matters is the big one: the writer must degrade and SAY it degraded,
# never emit a file that reads complete and is truncated.
BIG="$TMP/big"; mkdir -p "$BIG"
i=0
while [[ $i -lt 400 ]]; do
  i=$((i+1))
  printf -- '---\nname: atom-%03d-a-reasonably-long-slug-like-the-real-ones-carry\ndescription: %s\nmetadata:\n  type: reference\n---\n\nbody\n' \
    "$i" "a description of roughly the length the converter emits for a real codex task group section, which is what makes the full form overflow"     > "$BIG/atom-$(printf '%03d' $i).md"
done
_pack_atoms_index "$BIG" "Memory Index (big)"
big_bytes=$(wc -c < "$BIG/MEMORY.md")
[[ "$big_bytes" -le "$_PACK_INDEX_BUDGET" ]] \
  && ok_t "a 400-atom index stays inside the always-loaded budget ($big_bytes <= $_PACK_INDEX_BUDGET B)" \
  || bad_t "a 400-atom index stays inside the always-loaded budget" "$big_bytes B > $_PACK_INDEX_BUDGET B"
grep -q 'are not named above' "$BIG/MEMORY.md" \
  && ok_t "a cut index SAYS how many atoms it did not name" \
  || bad_t "a cut index SAYS how many atoms it did not name" "no disclosure line in the index"
# The blank line after the preamble is structure, not cosmetics: without it the
# first list item is swallowed into the preceding paragraph.
grep -q '^- \[atom-001' "$BIG/MEMORY.md" \
  && ok_t "the cut index's first entry starts its own line" \
  || bad_t "the cut index's first entry starts its own line" "$(sed -n '8,10p' "$BIG/MEMORY.md")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
