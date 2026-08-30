#!/usr/bin/env bash
# DIVE-3821 unit harness for TWO-STAGE memory recall:
#   stage 1  `memory search --index`  → index ROWS (slug + description + score)
#   stage 2  `memory get <slug>...`   → full bodies for the chosen slugs
#   plus     `memory router`          → MEMORY.md as a bounded router, not a
#                                        flat enumeration that outgrows the load
#                                        limit and loses its TAIL silently.
#
# Everything runs against synthetic stores in a tempdir — no root, no network,
# no real agent store touched.
# Run: bash tests/memory_two_stage_recall_unit.sh
#
# TIER: nightly — 1.8s measured, and ~1.5s of that is the 300-atom scale fixture
# that proves the router is bounded by its BUDGET and not by the atom count.
# That control is the assertion the row turns on, so it is not droppable, and
# the core tier is already at the cost its budget can carry — a new 1.8s guard
# there buys nothing the full sweep does not also buy a few hours later.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

command -v node >/dev/null 2>&1 || { echo "SKIP: node absent"; exit 0; }

TMP="$(mktemp -d /tmp/mem-twostage-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do source "$SRC/$f"; done
# shellcheck source=/dev/null
source "$SRC/cmd_memory.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

STORE="$TMP/proj/memory"; mkdir -p "$STORE"
# A realistic atom: the BODY is many times the description. A one-line body
# would make snippet mode look as cheap as an index row and grade a fixture, not
# the change — the saving being measured is exactly "description instead of body".
PAD="$(printf 'Mechanism, the measurement behind it, and the caveat that follows from it. %.0s' $(seq 1 12))"
mk() { # mk <slug> <type> <description> <body>
  cat > "$STORE/$1.md" <<EOF
---
name: $1
description: $3
metadata:
  type: $2
---

$4
$PAD
EOF
}
mk alpha_widget    project   "Widget calibration drifts after a sweep restart"      "The sweep re-reads the calibration table on restart."
mk beta_relay      reference "Only one box serves a relay; the other fifteen do not" "Relay presence is per box, never fleet-wide."
mk gamma_gate      feedback  "A gate whose ask names a component is unanswerable"    "Lead with the consequence, not the mechanism."
mk delta_tail      project   "An always-loaded index past the limit loses its tail"  "The loader drops the tail with no error line."
for i in 1 2 3 4 5 6 7 8; do mk "filler_$i" project "Filler fact number $i about unrelated plumbing" "Body $i."; done

# ── stage 1 ────────────────────────────────────────────────────────────────
out="$(_memory_search "widget calibration sweep" --index --roots="$STORE" 2>&1)"
grep -q 'alpha_widget' <<<"$out" \
  && ok_t "index: the matching slug is printed as a row" \
  || bad_t "index: matching slug missing" "$out"
grep -q 'Widget calibration drifts after a sweep restart' <<<"$out" \
  && ok_t "index: the row carries the one-line description" \
  || bad_t "index: description missing from row" "$out"
# The whole point: rows, NOT bodies. The body text must not appear.
grep -q 're-reads the calibration table' <<<"$out" \
  && bad_t "index: a BODY leaked into stage 1 (that is the flat-index cost this row removes)" "$out" \
  || ok_t "index: no body text in stage-1 output"
grep -q '5dive memory get' <<<"$out" \
  && ok_t "index: names the stage-2 verb" \
  || bad_t "index: no fetch instruction" "$out"

# A row must cost far less than the snippet it replaces, or two-stage is a
# rename. Same query, same roots, index vs default rendering.
# Compare at the SAME --limit: index mode deliberately defaults to a wider
# limit, so a raw total-token comparison would grade the default, not the
# rendering, and could read "more expensive" for a mode that is 4x cheaper.
idx8="$(_memory_search "widget calibration sweep" --index --limit=8 --roots="$STORE" 2>&1)"
snip="$(_memory_search "widget calibration sweep" --limit=8 --roots="$STORE" 2>&1)"
i_tok="$(grep -oE '~[0-9]+ tokens' <<<"$idx8" | head -1 | tr -dc 0-9)"
s_tok="$(grep -oE '~[0-9]+ tokens' <<<"$snip" | head -1 | tr -dc 0-9)"
if [ -n "$i_tok" ] && [ -n "$s_tok" ] && [ "$i_tok" -lt "$s_tok" ]; then
  ok_t "index: cheaper than snippet mode at the same limit ($i_tok vs $s_tok tokens)"
else
  bad_t "index: not cheaper than snippet mode at the same limit" "index=$i_tok snippet=$s_tok"
fi

# The default limit is WIDER in index mode — that is the design (rows are cheap,
# so stage 1 should show enough candidates to choose between), and an explicit
# --limit must still win.
dflt="$(_memory_search "filler plumbing fact" --index --roots="$STORE" 2>&1 | grep -c '^\[')"
capped="$(_memory_search "filler plumbing fact" --index --limit=3 --roots="$STORE" 2>&1 | grep -c '^\[')"
[ "$dflt" -gt "$capped" ] && [ "$capped" -eq 3 ] \
  && ok_t "index: default limit is wider, an explicit --limit still binds ($dflt vs $capped)" \
  || bad_t "index: limit handling wrong" "default=$dflt capped=$capped"

# One row per FILE, not per chunk — a multi-heading atom must not print twice.
cat > "$STORE/multi_head.md" <<'EOF'
---
name: multi_head
description: A fact with several headings about zebra plumbing
metadata:
  type: project
---

## First
zebra zebra plumbing

## Second
zebra plumbing again
EOF
out2="$(_memory_search "zebra plumbing" --index --roots="$STORE" 2>&1)"
[ "$(grep -c '^\[.*multi_head' <<<"$out2")" -eq 1 ] \
  && ok_t "index: one row per file even when the atom has several headings" \
  || bad_t "index: duplicate rows for one file" "$out2"

# ── stage 2 ────────────────────────────────────────────────────────────────
g="$(_memory_get alpha_widget --roots="$STORE" 2>&1)"; grc=$?
grep -q 're-reads the calibration table' <<<"$g" \
  && ok_t "get: returns the full body stage 1 withheld" \
  || bad_t "get: body missing" "$g"
[ "$grc" -eq 0 ] && ok_t "get: exits 0 on a hit" || bad_t "get: nonzero rc on a hit" "rc=$grc"

# - and _ are interchangeable: a row prints the frontmatter name, which routinely
# differs from the basename by exactly that. An exact-only fetch would refuse a
# slug it had just printed.
g2="$(_memory_get alpha-widget --roots="$STORE" 2>&1)"
grep -q 're-reads the calibration table' <<<"$g2" \
  && ok_t "get: dash/underscore forms resolve to the same atom" \
  || bad_t "get: dashed slug did not resolve" "$g2"

g3="$(_memory_get no_such_slug --roots="$STORE" 2>&1)"; g3rc=$?
[ "$g3rc" -ne 0 ] && ok_t "get: nonzero rc when NOTHING resolved" || bad_t "get: rc 0 on a total miss" "$g3"
grep -q "no atom for 'no_such_slug'" <<<"$g3" \
  && ok_t "get: a miss names the slug it could not resolve" \
  || bad_t "get: miss is silent" "$g3"

# A partial fetch is a fetch — one good slug must not be lost to one bad one.
g4="$(_memory_get alpha_widget no_such_slug --roots="$STORE" 2>&1)"; g4rc=$?
[ "$g4rc" -eq 0 ] && grep -q 're-reads the calibration table' <<<"$g4" \
  && ok_t "get: partial fetch still delivers the hit, rc 0" \
  || bad_t "get: partial fetch failed" "rc=$g4rc $g4"

# The ceiling must TRUNCATE loudly, never drop content silently — that silent
# drop is the exact defect this row exists to remove.
g5="$(_memory_get alpha_widget beta_relay gamma_gate --roots="$STORE" --max-tokens=30 2>&1)"
grep -qE 'TRUNCATED|SKIPPED' <<<"$g5" \
  && ok_t "get: the token ceiling announces itself" \
  || bad_t "get: ceiling dropped content silently" "$g5"

# get and search must read the SAME roots, or stage 2 is a different store.
grep -q '_memory_resolve_roots' "$SRC/cmd_memory.sh" \
  && [ "$(grep -c '_memory_resolve_roots "\$store" "\$agent" "\$roots"' "$SRC/cmd_memory.sh")" -ge 2 ] \
  && ok_t "search and get resolve roots through the same helper" \
  || bad_t "root resolution is not shared between search and get"

# ── router ─────────────────────────────────────────────────────────────────
cat > "$STORE/MEMORY.md" <<'EOF'
# Old flat index
- [alpha](alpha_widget.md) — a hook
- [beta](beta_relay.md) — another hook
<!-- router:keep-start -->
## Standing
- pinned line that a description cannot re-derive
<!-- router:keep-end -->
EOF
before=$(wc -c < "$STORE/MEMORY.md")
atoms_before=$(ls -1 "$STORE"/*.md | wc -l)
r="$(_memory_router --root="$STORE" --recent=3 2>&1)"
grep -q 'dry run' <<<"$r" && ok_t "router: dry-run by default" || bad_t "router: no dry-run notice" "$r"
[ "$(wc -c < "$STORE/MEMORY.md")" -eq "$before" ] \
  && ok_t "router: a dry run does not touch MEMORY.md" \
  || bad_t "router: dry run wrote the file"

w="$(_memory_router --root="$STORE" --recent=3 --write 2>&1)"
after=$(wc -c < "$STORE/MEMORY.md")
grep -q "MEMORY.md" <<<"$w" && ok_t "router: --write reports the file it wrote" \
  || bad_t "router: --write printed no target" "$w"
ls "$STORE"/MEMORY.md.pre-router-* >/dev/null 2>&1 \
  && ok_t "router: the previous index is backed up" \
  || bad_t "router: no backup written" "$w"
# NOTHING is deleted: shrinking by deleting atoms would pass every size check
# and destroy the store. Count them.
[ "$(ls -1 "$STORE"/*.md | wc -l)" -eq "$atoms_before" ] \
  && ok_t "router: no atom deleted (${atoms_before} files before and after)" \
  || bad_t "router: the atom count changed"
grep -q 'pinned line that a description cannot re-derive' "$STORE/MEMORY.md" \
  && ok_t "router: the router:keep block is carried over verbatim" \
  || bad_t "router: keep block lost" "$(cat "$STORE/MEMORY.md")"
grep -q 'memory search --index' "$STORE/MEMORY.md" \
  && ok_t "router: the generated index states the recall protocol" \
  || bad_t "router: protocol missing from the router"
# A router that named every atom would just be the flat index again.
[ "$(grep -c '^- `' "$STORE/MEMORY.md")" -le 5 ] \
  && ok_t "router: names only the newest N atoms, not all of them" \
  || bad_t "router: enumerated too many atoms"

# The budget is the whole point: it must bind.
b="$(_memory_router --root="$STORE" --recent=20 --budget=1200 --write 2>&1)"
sz=$(wc -c < "$STORE/MEMORY.md")
[ "$sz" -le 1400 ] \
  && ok_t "router: --budget binds the output size ($sz B under a 1200 B budget)" \
  || bad_t "router: budget ignored" "$sz B; $b"

# A store the caller cannot read is an error, not an empty router.
# In a subshell: `fail` exits, and an exiting assertion would take the harness
# with it — the run would end mid-file looking like a pass.
( _memory_router --root="$TMP/nope" ) >/dev/null 2>&1
[ $? -ne 0 ] && ok_t "router: a missing root fails loudly" || bad_t "router: missing root passed"

# ── the property the whole row turns on ────────────────────────────────────
# The router's size must be bounded by the BUDGET, not by the atom count. A
# flat one-line-per-atom index is bounded by the atom count, which is why it
# outgrew the ~24.4 KB load limit and started losing its tail. Grow the store
# by 20x and assert the router does not grow with it.
BIG="$TMP/big/memory"; mkdir -p "$BIG"
for i in $(seq 1 300); do
  cat > "$BIG/project_scaled_$i.md" <<EOF
---
name: project_scaled_$i
description: Scaled synthetic fact number $i about provisioning, gates and verifier rounds
metadata:
  type: project
---

Body $i.
EOF
done
# What the OLD shape would have cost, built the way the old index was built.
: > "$BIG/flat.txt"
for f in "$BIG"/project_scaled_*.md; do
  b=$(basename "$f" .md)
  echo "- [$b]($b.md) — Scaled synthetic fact about provisioning, gates and verifier rounds" >> "$BIG/flat.txt"
done
flat=$(wc -c < "$BIG/flat.txt")
_memory_router --root="$BIG" --recent=20 --write >/dev/null 2>&1
router=$(wc -c < "$BIG/MEMORY.md")
LIMIT=24400
[ "$flat" -gt "$LIMIT" ] \
  && ok_t "control: a flat index over 300 atoms does exceed the load limit ($flat B > $LIMIT)" \
  || bad_t "control did not reproduce the defect — the size assertion below proves nothing" "flat=$flat"
[ "$router" -lt "$LIMIT" ] \
  && ok_t "router: bounded by the budget, not the atom count ($router B for 300 atoms)" \
  || bad_t "router: grew past the load limit" "$router B"
[ "$(ls -1 "$BIG"/project_scaled_*.md | wc -l)" -eq 300 ] \
  && ok_t "router: all 300 atoms still on disk after the rebuild" \
  || bad_t "router: atoms lost at scale"

# ── the router must not turn `memory doctor` into noise ────────────────────
# A router names few atoms on purpose. The unindexed-file warn fires once per
# unnamed atom, so without this the fix buries every real hygiene finding.
DOC="$TMP/doc/memory"; mkdir -p "$DOC"
for i in 1 2 3 4 5 6; do
  printf -- '---\nname: doc_atom_%s\ndescription: doc fact %s\nmetadata:\n  type: project\n---\n\nBody %s.\n' "$i" "$i" "$i" > "$DOC/doc_atom_$i.md"
done
# Control: a FLAT index that omits them must still warn — or the assertion below
# is passing because the check is dead, not because the router is exempt.
printf '# Index\n- [one](doc_atom_1.md) — hook\n' > "$DOC/MEMORY.md"
flatout="$(_memory_scan_json "$TMP/no-code-root" "$DOC")"
grep -q 'index-drift' <<<"$flatout" \
  && ok_t "control: a flat index that omits atoms still reports index-drift" \
  || bad_t "control: index-drift never fires — the router exemption below is untested" "$flatout"
_memory_router --root="$DOC" --recent=2 --write >/dev/null 2>&1
routout="$(_memory_scan_json "$TMP/no-code-root" "$DOC")"
n_drift="$(grep -o 'index-drift' <<<"$routout" | wc -l)"
[ "$n_drift" -eq 0 ] \
  && ok_t "router: doctor does not warn once per unnamed atom (0 index-drift findings)" \
  || bad_t "router: doctor floods with index-drift" "$n_drift findings"
# A router that links a MISSING file is still drift — the exemption is scoped to
# the unindexed-file warn, not to the whole check.
sed -i 's|_Generated by|- [ghost](doc_ghost.md) — points nowhere\n\n_Generated by|' "$DOC/MEMORY.md"
ghost="$(_memory_scan_json "$TMP/no-code-root" "$DOC")"
grep -q 'doc_ghost.md' <<<"$ghost" \
  && ok_t "router: a dead link in a router is still an index-drift error" \
  || bad_t "router: dead link went unreported" "$ghost"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
