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
# 2 task groups x (knowledge atom + private atom) + 2 summary sections + 2
# threads. The leading `# Raw Memories` banner is not a section and must not
# become an atom. The task groups count TWICE because one codex task group
# carries both classes and they must not land in one file: see the typing arms
# below.
eq_t "all mode converts every section of all three documents" "$n2" "8"
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

# THE SAME PROPERTY, INSIDE A TASK GROUP — and this is the half that was wrong.
# memory_summary.md is a whole private document, so typing it was easy. A codex
# TASK GROUP mixes the classes in one section: `## Reusable knowledge` beside
# `## User preferences` and the per-task rollout ids. Folding all of it into the
# `reference` atom types private text public, and the next distilled export of
# the seat it landed on publishes it — the allowlist reads the atom's type, and
# the atom said reference.
sp=$(grep -l 'SECRETPREF' "$FULL"/*.md | head -1)
if [[ -n "$sp" ]] && grep -q '^  type: user$' "$sp"; then
  ok_t "a task group's '## User preferences' lands typed 'user', not 'reference'"
else
  bad_t "a task group's '## User preferences' lands typed 'user', not 'reference'" "got: ${sp:-none} $(grep '^  type:' "${sp:-/dev/null}" 2>/dev/null)"
fi
# The knowledge atom must be CLEAN, not merely accompanied by a private one.
kn=$(grep -l 'cumulative per rollout' "$FULL"/*.md | head -1)
if [[ -n "$kn" ]] && ! grep -q 'SECRETPREF' "$kn"; then
  ok_t "the knowledge atom of that task group carries no private text"
else
  bad_t "the knowledge atom of that task group carries no private text" "SECRETPREF is inside ${kn:-none}"
fi
# The per-task rollout/thread ids are the other private class in a task group.
rid=$(grep -l 'rollout_summaries/2026-09-07T05-50-12' "$FULL"/*.md | head -1)
if [[ -n "$rid" ]] && grep -q '^  type: user$' "$rid"; then
  ok_t "the per-task rollout ids land typed 'user'"
else
  bad_t "the per-task rollout ids land typed 'user'" "got: ${rid:-none} $(grep '^  type:' "${rid:-/dev/null}" 2>/dev/null)"
fi
# THE WHOLE POINT, stated as the round trip it protects: a distilled export of
# the seat this store landed on must publish exactly the knowledge and nothing
# else. This is _pack_scope_memory over the IMPORTED atoms, which is what a
# later `agent export <new-seat> --memory=distilled` runs.
REEXPORT="$TMP/reexport"
recounts=$(_pack_scope_memory "$FULL" "$REEXPORT")
re_all="$(cat "$REEXPORT"/*.md 2>/dev/null)"
leaked=""
for mark in SECRETPREF PROFILEMARK TIPMARK; do
  case "$re_all" in *"$mark"*) leaked="$leaked $mark" ;; esac
done
[[ -z "$leaked" ]] \
  && ok_t "a later distilled re-export of the landed seat publishes no private text (kept/excluded: $recounts)" \
  || bad_t "a later distilled re-export of the landed seat publishes no private text" "published:$leaked"
case "$re_all" in
  *"cumulative per rollout"*) ok_t "that re-export still publishes the knowledge" ;;
  *)                          bad_t "that re-export still publishes the knowledge" "the knowledge atom was excluded too" ;;
esac

# ============================ 5. the index ==================================
_pack_atoms_index "$FULL" "Memory Index (imported from a codex store)"
[[ -f "$FULL/MEMORY.md" ]] && ok_t "conversion regenerates MEMORY.md" || bad_t "conversion regenerates MEMORY.md" "absent"
idx_lines=$(grep -c '^- \[' "$FULL/MEMORY.md")
eq_t "the index names every atom" "$idx_lines" "8"
# The reason the index exists at all: the source MEMORY.md is 143 KB on a real
# seat and a claude loader drops the TAIL past its limit with no error. The
# property that buys is SCALE INVARIANCE — the index grows with how many atoms
# there are, never with how big they are. Graded by growing the bodies and
# requiring the index not to move. (This replaces an `index < store` byte
# comparison: over a 1.3 KB fixture store that arm graded the fixture's size,
# not the writer, and it flipped the moment the atom count changed.)
idx_bytes=$(wc -c < "$FULL/MEMORY.md")
BLOAT="$TMP/bloat"; rm -rf "$BLOAT"; mkdir -p "$BLOAT"
for f in "$FULL"/*.md; do
  [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
  cp "$f" "$BLOAT/"
  head -c 5000 /dev/zero | tr '\0' 'x' >> "$BLOAT/$(basename "$f")"
done
_pack_atoms_index "$BLOAT" "Memory Index (imported from a codex store)"
bloat_bytes=$(wc -c < "$BLOAT/MEMORY.md")
eq_t "the index does not grow when the atoms do (${idx_bytes} B either way)" "$bloat_bytes" "$idx_bytes"
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

# ================= 7. RAW STAGING TAKES THE STORE, NOT ITS SUBDIRS ===========
# The rollout_summaries/ exclusion is a DECISION (per-session transcript
# summaries carrying rollout paths and thread ids), and until now it was carried
# by a `-maxdepth 1` and a comment. A comment is not a grade: widening the walk
# to -maxdepth 2 ships 65 of those files inside a raw codex export and every
# other arm stays green.
RAWSTAGE="$TMP/rawstage"
rawcounts=$(_pack_raw_memory "$STORE" "$RAWSTAGE")
eq_t "raw staging takes the three top-level codex documents" "${rawcounts%% *}" "3"
if [[ -e "$RAWSTAGE/2026-09-07.md" ]] || grep -rqs 'a per-session transcript summary' "$RAWSTAGE"; then
  bad_t "raw staging EXCLUDES rollout_summaries/" "a rollout summary was staged into the pack"
else
  ok_t "raw staging EXCLUDES rollout_summaries/"
fi

# ============ 8. THE MANIFEST WRITER: the field the landing turns on =========
# cmd_import routes CONVERT-vs-copy off includes.memoryShape. Nothing graded it,
# so a mutant flipping the writer's "codex-docs" to "atoms" reinstated the exact
# failure this change exists to prevent — a 143 KB MEMORY.md cp'd into a claude
# memory dir, tail dropped with no error — and left every arm green.
#
# Graded through the REAL seal path (--approve-memory skips the draft phase's
# writes under /home/agent-*), so what is read back is the manifest cmd_export
# actually wrote, not a string in the source.
require_root()        { :; }
require_agent()       { :; }
_pack_agent_config()  { printf '{"type":"codex"}\n'; }
_pack_skill_refs()    { printf '[]\n'; }
_agent_to_persona()   { return 1; }

# A clean approve dir shaped like a codex store (the seal copies it verbatim
# under --memory=raw); kept free of the fixture's credential-shaped marks so the
# arm grades the manifest and not the tripwire.
APPROVE_DOCS="$TMP/approve-docs"; mkdir -p "$APPROVE_DOCS"
printf '# Task Group: a\n\n## Reusable knowledge\n\n- a fact\n' > "$APPROVE_DOCS/MEMORY.md"
printf '## User Profile\n\nworks in one repo\n'                 > "$APPROVE_DOCS/memory_summary.md"

seal_shape() { # <agent> <mode> <approve-dir> -> echoes manifest includes.memoryShape
  local ag="$1" mode="$2" dir="$3"
  local out="$TMP/shape-$ag-$mode.tar.gz" x="$TMP/xs-$ag-$mode"
  cmd_export "$ag" --memory="$mode" --audience=self --approve-memory="$dir" -o "$out" \
    >"$TMP/shape-$ag-$mode.out" 2>&1
  mkdir -p "$x"
  tar -xzf "$out" -C "$x" 2>/dev/null || return 1
  jq -r '.includes.memoryShape' "$x/manifest.json" 2>/dev/null
}

got=$(seal_shape cx raw "$APPROVE_DOCS")
eq_t "a RAW export from a codex seat declares memoryShape=codex-docs" "$got" "codex-docs"
# THE CONTROL, and it is the half that stops "label everything codex-docs" from
# passing: the same flags on a claude seat must still say atoms, or every legacy
# pack would be routed through a conversion it does not need.
got=$(seal_shape cl raw "$APPROVE_DOCS")
eq_t "control: a RAW export from a claude seat still declares memoryShape=atoms" "$got" "atoms"
# Distilled from a codex seat is ALREADY atoms — the draft converted it — so the
# shape is a property of the staged bytes, not of the source harness.
got=$(seal_shape cx distilled "$DRAFT")
eq_t "a DISTILLED codex export declares memoryShape=atoms (the bytes are atoms)" "$got" "atoms"
# An old pack carries no field at all; the importer must read that as atoms
# rather than as "unknown", or every pack written before this change stops
# landing.
NOFIELD="$TMP/nofield"; mkdir -p "$NOFIELD"
echo '{"packFormat":1,"includes":{"memory":"distilled","persona":false}}' > "$NOFIELD/manifest.json"
eq_t "a pack with no memoryShape field reads as atoms" "$(_pack_manifest_memory_shape "$NOFIELD")" "atoms"
NULLF="$TMP/nullf"; mkdir -p "$NULLF"
echo '{"includes":{"memory":false,"memoryShape":null}}' > "$NULLF/manifest.json"
eq_t "an explicit null memoryShape reads as atoms" "$(_pack_manifest_memory_shape "$NULLF")" "atoms"

# =============== 9. THE IMPORT SIDE ROUTES ON THAT FIELD =====================
# This is the consumer of arm 8. It grades the branch, not the converter: the
# converter was already graded above by direct call, and a direct call is
# exactly what a mutant in the ROUTING leaves untouched.
SEED_IN="$TMP/seed-in"; mkdir -p "$SEED_IN"
cp "$STORE/MEMORY.md" "$STORE/memory_summary.md" "$STORE/raw_memories.md" "$SEED_IN/"
SEED_OUT="$TMP/seed-out"
packed=$(_pack_seed_claude_memory "$SEED_IN" "$SEED_OUT" codex-docs)
atoms=$(find "$SEED_OUT" -maxdepth 1 -type f -name '*.md' ! -name MEMORY.md | wc -l)
# NOT `>1` alone — three staged documents copied verbatim also leave two files
# beside the index, so a count-only arm passes on the exact regression this
# grades. What separates convert from copy is that every landed file is an ATOM:
# frontmatter with a name and a type. A codex document has neither.
notatoms=0
for f in "$SEED_OUT"/*.md; do
  [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
  head -1 "$f" | grep -qx -- '---' && grep -q '^name: ' "$f" && grep -q '^  type: ' "$f" || notatoms=$((notatoms+1))
done
[[ "$atoms" -gt 3 && "$notatoms" -eq 0 ]] \
  && ok_t "a codex-docs pack lands as MANY frontmattered atoms on a claude seat ($atoms)" \
  || bad_t "a codex-docs pack lands as MANY frontmattered atoms on a claude seat" \
           "got $atoms file(s) beside the index, $notatoms of them not atoms (3 documents were staged)"
[[ -f "$SEED_OUT/MEMORY.md" ]] \
  && ok_t "a codex-docs landing regenerates an index" \
  || bad_t "a codex-docs landing regenerates an index" "no MEMORY.md written"
seed_idx=$(wc -c < "$SEED_OUT/MEMORY.md")
[[ "$seed_idx" -le "$_PACK_INDEX_BUDGET" ]] \
  && ok_t "the landed index is inside the always-loaded budget ($seed_idx <= $_PACK_INDEX_BUDGET B)" \
  || bad_t "the landed index is inside the always-loaded budget" "$seed_idx B"
# The failure mode in one assertion: the source MEMORY.md must NOT be sitting in
# the seat's memory dir verbatim. On the real store that file is 143 KB and the
# loader drops its tail with no error, so "present" reads as success and is not.
if grep -qs '^# Task Group: usage accounting for codex seats' "$SEED_OUT/MEMORY.md"; then
  bad_t "the codex MEMORY.md is NOT copied through verbatim" "the store's own index landed as the seat's index"
else
  ok_t "the codex MEMORY.md is NOT copied through verbatim"
fi
eq_t "the landing reports the atoms it wrote, plus its index" "$packed" "$(( atoms + 1 ))"

# THE CONTROL for arm 9: atoms in, atoms out, byte-for-byte — a claude-sourced
# pack must not be dragged through the codex conversion.
ATOM_IN="$TMP/atom-in"; mkdir -p "$ATOM_IN"
printf -- '---\nname: a-fact\ndescription: d\nmetadata:\n  type: reference\n---\n\nUNTOUCHED body\n' > "$ATOM_IN/a-fact.md"
printf '# Memory Index\n- [a-fact](a-fact.md) — d\n' > "$ATOM_IN/MEMORY.md"
ATOM_OUT="$TMP/atom-out"
packed2=$(_pack_seed_claude_memory "$ATOM_IN" "$ATOM_OUT" atoms)
eq_t "control: an atoms pack copies verbatim, count unchanged" "$packed2" "2"
if cmp -s "$ATOM_IN/a-fact.md" "$ATOM_OUT/a-fact.md" && cmp -s "$ATOM_IN/MEMORY.md" "$ATOM_OUT/MEMORY.md"; then
  ok_t "control: an atoms pack's files are byte-identical after landing"
else
  bad_t "control: an atoms pack's files are byte-identical after landing" "the conversion branch ran on claude-shaped memory"
fi

# ============ 10. a present-but-empty MEMORY.md does not kill the export =====
# `grep -c` prints 0 AND exits 1 on a file with no matches, so the old
# `$(grep -c … || echo 0)` yielded TWO zeros and the arithmetic around it died
# with "syntax error in expression". The seat this bites is a real one: a codex
# store whose MEMORY.md has not accumulated a task group yet.
EMPTYTG="$TMP/empty-tg"; mkdir -p "$EMPTYTG"
printf '## Reusable knowledge\n\n- a fact with no task-group heading\n' > "$EMPTYTG/MEMORY.md"
_pack_memory_kind() { printf 'codex\n'; }
_pack_memory_dir()  { printf '%s\n' "$EMPTYTG"; }
# The draft phase's ONE write outside the pack. Point it at the fixture: this
# harness is run as root by the pre-push rail, and the un-stubbed path would
# create /home/agent-cx on a real host.
_pack_draft_dir()   { printf '%s\n' "$TMP/draft-phase"; }
out=$(cmd_export cx --memory=distilled --audience=self 2>&1); rc=$?
case "$out" in
  *"syntax error in expression"*) bad_t "a zero-task-group codex MEMORY.md does not crash the draft" "$out" ;;
  *)                              ok_t  "a zero-task-group codex MEMORY.md does not crash the draft" ;;
esac

# ====== 11. THE EXCLUSION MUST COVER THE METADATA, NOT JUST THE BODY ========
# The shipped fixture above opens every task group with a `scope:` line, and
# that is what made the "drops '## User preferences'" arm green: the desc
# capture ran BEFORE the keep test, so it happened to land on the scope line.
# Vary the fixture and the same code publishes the private line as the atom's
# `description:` and as its MEMORY.md index line while the body stays clean.
# So: a task group whose FIRST content is the excluded subsection.
LEADSTORE="$TMP/lead-store"; mkdir -p "$LEADSTORE"
cat > "$LEADSTORE/MEMORY.md" <<'LEAD'
# Task Group: billing reconciliation

## User preferences

- LEAKMARK4541 never page the user before breakfast.

## Reusable knowledge

- Reconcile by invoice id, not by amount.
LEAD
LEADDRAFT="$TMP/lead-draft"
_pack_memory_dir() { printf '%s\n' "$LEADSTORE"; }
_pack_draft_dir()  { printf '%s\n' "$LEADDRAFT"; }
# The REAL path, not the helper: cmd_export's own draft phase, the bytes a
# reviewer would be shown and then seal.
out=$(cmd_export cx --memory=distilled --audience=publish 2>&1); rc=$?
if grep -rq 'LEAKMARK4541' "$LEADDRAFT" 2>/dev/null; then
  bad_t "no private line reaches a distilled draft, INCLUDING its frontmatter and index" \
        "$(grep -rn 'LEAKMARK4541' "$LEADDRAFT" | head -3)"
else
  ok_t "no private line reaches a distilled draft, INCLUDING its frontmatter and index"
fi
# ...and the atom is still described, not blanked: an empty description is how
# this arm would be passed without fixing anything.
d=$(awk -F': ' '/^description: /{print $2; exit}' "$LEADDRAFT"/codex-tg-*.md 2>/dev/null)
[[ -n "${d//\"/}" ]] \
  && ok_t "the atom still carries a description drawn from what it DOES carry ($d)" \
  || bad_t "the atom still carries a description drawn from what it DOES carry" "empty description (rc=$rc): $out"
if grep -rq 'Reconcile by invoice id' "$LEADDRAFT" 2>/dev/null; then
  ok_t "the knowledge subsection is still exported from that task group"
else
  bad_t "the knowledge subsection is still exported from that task group" "rc=$rc: $out"
fi

# THE IMPORT SIDE of the same property. Raw DOES carry the private line — it is
# the operator's own backup — so the claim is not "it disappears", it is "it
# lands TYPED private", and the grade is what the next distilled export of the
# destination seat would publish.
LEAD_IN="$TMP/lead-in"; mkdir -p "$LEAD_IN"; cp "$LEADSTORE/MEMORY.md" "$LEAD_IN/"
LEAD_MEM="$TMP/lead-mem"
_pack_seed_claude_memory "$LEAD_IN" "$LEAD_MEM" codex-docs >/dev/null
grep -rq 'LEAKMARK4541' "$LEAD_MEM" \
  && ok_t "an import carries the private line onto the seat (it is a move, not a filter)" \
  || bad_t "an import carries the private line onto the seat (it is a move, not a filter)" "the line was dropped instead of typed"
LEAD_PUB="$TMP/lead-pub"
leadcounts=$(_pack_scope_memory "$LEAD_MEM" "$LEAD_PUB")
if grep -rq 'LEAKMARK4541' "$LEAD_PUB"; then
  bad_t "a distilled export of the seat it landed on withholds it (kept/excluded: $leadcounts)" \
        "$(grep -rn 'LEAKMARK4541' "$LEAD_PUB" | head -3)"
else
  ok_t "a distilled export of the seat it landed on withholds it (kept/excluded: $leadcounts)"
fi
eq_t "that export still publishes the task group's knowledge" "${leadcounts%% *}" "1"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
