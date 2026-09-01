#!/usr/bin/env bash
# DIVE-3872 isolated unit harness for --memory=raw on the EXPORT path.
#
# lodar, 2026-09-01: "some users just want raw memory. but warn them." Raw is the
# deliberate complement to the deny-by-default scoping, so what needs grading is
# not that it copies files — it is that the THREE properties keeping it honest
# actually hold, and that the distilled path is untouched by its existence:
#   1. raw copies VERBATIM — every type, MEMORY.md, opt-outs included.
#   2. raw is SELF-ONLY — --audience=publish refuses BEFORE any bytes move.
#   3. distilled still excludes exactly what it always did (the control; without
#      it this harness would pass on a build where scoping had been deleted).
#
# Sources src/ directly (no root, no network). Run: bash tests/pack_raw_memory_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/pack-raw-unit.XXXXXX)"

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

# ---- fixture: one of every disposition the scoper cares about --------------
MEM="$TMP/memory"; mkdir -p "$MEM"
mk() { printf -- '---\nname: %s\nmetadata:\n  type: %s\n%s---\n\nbody of %s\n' "$1" "$2" "${3:-}" "$1" > "$MEM/$1.md"; }
mk keep-ref     reference
mk keep-proj    project
mk private-user user                       # excluded by type
mk private-fb   feedback                   # excluded by type
mk opted-out    reference "export: false\n" # excluded by opt-out
printf -- '---\nname: no-type\n---\n\nunknown type\n' > "$MEM/no-type.md"   # excluded fail-safe
printf '# Memory Index\n- [keep-ref](keep-ref.md)\n' > "$MEM/MEMORY.md"     # skipped by scoping

TOTAL_MD=$(find "$MEM" -maxdepth 1 -name '*.md' | wc -l)   # 7

# ---- 1. RAW takes everything ----------------------------------------------
RAWOUT="$TMP/raw"
counts=$(_pack_raw_memory "$MEM" "$RAWOUT")
kept="${counts%% *}"; excl="${counts##* }"
got=$(find "$RAWOUT" -maxdepth 1 -name '*.md' | wc -l)
[[ "$got" -eq "$TOTAL_MD" ]] \
  && ok_t "raw copies every .md ($got of $TOTAL_MD)" \
  || bad_t "raw copies every .md" "got $got of $TOTAL_MD"
[[ "$kept" -eq "$TOTAL_MD" && "$excl" -eq 0 ]] \
  && ok_t "raw reports kept=$kept excluded=0" \
  || bad_t "raw counts" "kept=$kept excluded=$excl"

for f in private-user private-fb opted-out no-type MEMORY; do
  [[ -f "$RAWOUT/$f.md" ]] \
    && ok_t "raw carries $f.md (the whole point of a backup)" \
    || bad_t "raw carries $f.md" "missing"
done

# The bytes must be IDENTICAL, not merely present — a backup that rewrites
# frontmatter on the way out is not one.
if diff -r "$MEM" "$RAWOUT" >/dev/null 2>&1; then
  ok_t "raw output is byte-identical to the source dir"
else
  bad_t "raw output is byte-identical to the source dir" "$(diff -rq "$MEM" "$RAWOUT" 2>&1 | head -3)"
fi

# ---- 2. DISTILLED is unchanged — the control -------------------------------
# Without this arm the suite would still pass on a tree where scoping had been
# deleted outright, which is the failure raw could plausibly cause.
DISOUT="$TMP/distilled"
dcounts=$(_pack_scope_memory "$MEM" "$DISOUT")
dkept="${dcounts%% *}"
[[ "$dkept" -eq 2 ]] \
  && ok_t "distilled still keeps exactly the 2 knowledge facts" \
  || bad_t "distilled keeps 2" "kept=$dkept"
for f in private-user private-fb opted-out no-type; do
  [[ ! -f "$DISOUT/$f.md" ]] \
    && ok_t "distilled still excludes $f.md" \
    || bad_t "distilled still excludes $f.md" "leaked"
done
# scoping writes its OWN index over only what it kept, so MEMORY.md exists but
# must not be the source's.
if ! grep -q 'private-user' "$DISOUT/MEMORY.md" 2>/dev/null; then
  ok_t "distilled index names no excluded fact"
else
  bad_t "distilled index names no excluded fact" "private title leaked via index"
fi

# ---- 3. RAW IS SELF-ONLY, refused before any bytes move --------------------
# cmd_export needs root and a real agent; stub only those, so the arm grades the
# audience guard and nothing else.
require_root() { :; }
require_agent() { :; }
# ASSERT ON THE MESSAGE, NEVER ON rc ALONE. cmd_export exits non-zero here for
# several reasons (the stubbed agent does not exist, no memory dir, ...), so an
# rc-only arm passes for the WRONG reason and grades nothing. Mutation-checked:
# deleting the audience guard left an rc-only arm GREEN.
refuses_with() { # <expected substring> <label> -- <argv...>
  local want="$1" label="$2"; shift 3
  local o rc; o=$(cmd_export "$@" 2>&1); rc=$?
  if [[ $rc -ne 0 ]] && grep -qi -- "$want" <<<"$o"; then
    ok_t "$label"
  else
    bad_t "$label" "rc=$rc; wanted /$want/; got: $(head -2 <<<"$o" | tr '\n' ' ')"
  fi
}

refuses_with 'cannot be published' \
  "raw + --audience=publish REFUSES, and says why" \
  -- ceo --memory=raw --audience=publish

# Default audience is publish, so a bare --memory=raw must refuse identically —
# raw must not escape through the default.
refuses_with 'cannot be published' \
  "bare --memory=raw refuses too (publish is the DEFAULT audience)" \
  -- ceo --memory=raw

refuses_with '--memory must be' \
  "an unknown --memory mode refuses rather than falling through to a mode" \
  -- ceo --memory=bogus --audience=self

# ---- 4. DIVE-3877: the pack is LABELLED with the mode it was packed in ------
# A raw pack that declares includes.memory="distilled" is indistinguishable on
# the wire from a publishable one — --json says distilled, the manifest says
# distilled, and import re-reports it. So the thing to grade is the SEALED
# BYTES, not a string in the source: drive the real seal path with only the
# agent-home reads stubbed, then read the label back out of the tarball export
# actually wrote. Mutation-checked: restoring the hardcoded mem_inc="distilled"
# turns arm 4a red and leaves the 4b control green.
_pack_agent_config() { printf '{"type":"claude"}\n'; }
_pack_skill_refs()   { printf '[]\n'; }
_agent_to_persona()  { return 1; }

seal_label() { # <mode> -> echoes manifest includes.memory ('' if nothing sealed)
  local mode="$1" out="$TMP/sealed-$1.tar.gz" x="$TMP/x-$1"
  cmd_export ceo --memory="$mode" --audience=self --approve-memory="$MEM" -o "$out" \
    >"$TMP/seal-$1.out" 2>&1
  mkdir -p "$x"
  tar -xzf "$out" -C "$x" 2>/dev/null || return 1
  jq -r '.includes.memory' "$x/manifest.json" 2>/dev/null
}

lab=$(seal_label raw)
if [[ "$lab" == "raw" ]]; then
  ok_t "a raw pack declares includes.memory=\"raw\" (not 'distilled')"
else
  bad_t "a raw pack declares includes.memory=\"raw\" (not 'distilled')" \
        "manifest says '${lab:-<no pack written>}'; $(tail -2 "$TMP/seal-raw.out" | tr '\n' ' ')"
fi

# The CONTROL. Without it this arm would pass on a build that had simply
# renamed every pack 'raw'.
lab=$(seal_label distilled)
if [[ "$lab" == "distilled" ]]; then
  ok_t "control: a distilled pack is still labelled distilled"
else
  bad_t "control: a distilled pack is still labelled distilled" \
        "manifest says '${lab:-<no pack written>}'; $(tail -2 "$TMP/seal-distilled.out" | tr '\n' ' ')"
fi

# The operator-facing line is the other half of the same lie: "exported ...
# (with distilled persona memory)" over a verbatim private backup.
if grep -qi 'RAW persona memory' "$TMP/seal-raw.out"; then
  ok_t "the raw export's success line says RAW, and says it is self-only"
else
  bad_t "the raw export's success line says RAW, and says it is self-only" \
        "got: $(grep -i exported "$TMP/seal-raw.out" | head -1)"
fi

printf '\n%s\n' "----- pack_raw_memory_unit: PASS=$PASS FAIL=$FAIL -----"
[[ $FAIL -eq 0 ]]
