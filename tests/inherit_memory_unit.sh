#!/usr/bin/env bash
# DIVE-990 isolated unit harness for memory-as-onboarding
# (`agent create --inherit-memory=<scope>`).
#
# Sources the src/ libs directly (no root, no adduser, no network) and exercises
# the PURE seeding pieces against temp stores:
#   1. _seed_wiki_memory     — copies the shared wiki (index → wiki-index.md),
#                              dedups the double index glob match.
#   2. _seed_agent_memory    — copies ONLY a sibling's shareable facts
#                              (reference/project), never user/feedback (private),
#                              prefixed with the source name.
#   3. _resolve_inherit_sources — expands all/team against a registry, excludes
#                              self, dedups.
#   4. _rebuild_inherited_index — regenerates a MEMORY.md index over the seed.
# Run: bash tests/inherit_memory_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/inherit-mem-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_agent_create.sh (seed helpers) + cmd_pack.sh (_pack_* scoping) +
# cmd_memory.sh (_memory_wiki_root) are all function-defs-only at source time.
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_memory.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"

STATE_DIR="$TMP"
REGISTRY="$STATE_DIR/agents.json"
JSON_MODE=1
set +e   # header.sh enabled `set -e`; tests deliberately probe non-zero paths

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk_fact() { # $1=dir $2=name $3=type $4=extra-frontmatter-line (inside the block)
  cat > "$1/$2.md" <<EOF
---
name: $2
description: "desc for $2"
${4:+$4
}metadata:
  type: $3
---
body of $2
EOF
}

# ---- 1. _seed_wiki_memory: index first, deduped ----------------------------
WIKI="$TMP/wiki"; mkdir -p "$WIKI"
printf '# Team Wiki Index\n- overview here\n' > "$WIKI/index.md"
printf '# A2A backbone\n' > "$WIKI/a2a.md"
printf '# Funding radar\n' > "$WIKI/funding.md"
# Override the wiki-root resolver to point at our fixture (avoids depending on a
# real community/wiki checkout being present on the test box).
_memory_wiki_root() { echo "$WIKI"; }

TGT1="$TMP/store1/memory"; mkdir -p "$TGT1"
n=$(_seed_wiki_memory "$TGT1")
[[ "$n" == "3" ]] \
  && ok_t "_seed_wiki_memory seeds all 3 wiki files" \
  || bad_t "wiki seed count" "got '$n' (expected 3)"
[[ -f "$TGT1/wiki-index.md" ]] \
  && ok_t "wiki index.md → wiki-index.md (renamed entry point)" \
  || bad_t "wiki-index.md missing" "$(ls "$TGT1")"
[[ ! -f "$TGT1/index.md" ]] \
  && ok_t "no bare index.md left (dedup of double glob match)" \
  || bad_t "stray index.md present"
[[ -f "$TGT1/wiki-a2a.md" && -f "$TGT1/wiki-funding.md" ]] \
  && ok_t "wiki entries prefixed wiki-*" \
  || bad_t "wiki entries not prefixed"

# ---- 2. _seed_agent_memory: shareable only, name-prefixed ------------------
# Build a fake sibling store under a fake home so _pack_memory_dir finds it.
SIB_HOME="$TMP/home/agent-sibling/.claude/projects/proj/memory"
mkdir -p "$SIB_HOME"
mk_fact "$SIB_HOME" "how-company-works" "reference"
mk_fact "$SIB_HOME" "current-project"    "project"
mk_fact "$SIB_HOME" "who-the-human-is"   "user"        # private → must NOT copy
mk_fact "$SIB_HOME" "how-to-work-w-me"   "feedback"     # private → must NOT copy
mk_fact "$SIB_HOME" "secret-but-opted-out" "reference" "export: false"  # opt-out
# Point _pack_memory_dir at our fixture home layout.
_pack_memory_dir() { echo "$SIB_HOME"; }

TGT2="$TMP/store2/memory"; mkdir -p "$TGT2"
n=$(_seed_agent_memory "sibling" "$TGT2")
[[ "$n" == "2" ]] \
  && ok_t "_seed_agent_memory copies only 2 shareable facts" \
  || bad_t "agent seed count" "got '$n' (expected 2: reference+project)"
[[ -f "$TGT2/sibling-how-company-works.md" && -f "$TGT2/sibling-current-project.md" ]] \
  && ok_t "shareable facts copied, name-prefixed" \
  || bad_t "prefixed shareable facts missing" "$(ls "$TGT2")"
[[ ! -e "$TGT2/sibling-who-the-human-is.md" && ! -e "$TGT2/sibling-how-to-work-w-me.md" ]] \
  && ok_t "private user/feedback facts NOT leaked" \
  || bad_t "private fact leaked!" "$(ls "$TGT2")"
[[ ! -e "$TGT2/sibling-secret-but-opted-out.md" ]] \
  && ok_t "export:false opt-out honored" \
  || bad_t "opt-out fact leaked!"

# ---- 3. _resolve_inherit_sources: all/team expand, exclude self, dedup -----
cat > "$REGISTRY" <<'EOF'
{"agents":{"dev":{"type":"claude"},"marketing":{"type":"claude"},"newbie":{"type":"claude"}}}
EOF
mapfile -t srcs < <(_resolve_inherit_sources "all" "newbie")
joined="${srcs[*]}"
[[ "$joined" == *"wiki"* && "$joined" == *"dev"* && "$joined" == *"marketing"* ]] \
  && ok_t "'all' expands to wiki + siblings" \
  || bad_t "all-expansion wrong" "got: $joined"
[[ "$joined" != *"newbie"* ]] \
  && ok_t "'all' excludes the agent being created" \
  || bad_t "self not excluded" "got: $joined"
mapfile -t srcs2 < <(_resolve_inherit_sources "wiki,wiki,dev" "newbie")
[[ "$(printf '%s\n' "${srcs2[@]}" | grep -c '^wiki$')" == "1" ]] \
  && ok_t "duplicate tokens deduped" \
  || bad_t "dedup failed" "got: ${srcs2[*]}"

# ---- 4. _rebuild_inherited_index: browsable TOC over the seed --------------
_rebuild_inherited_index "$TGT2"
[[ -f "$TGT2/MEMORY.md" ]] \
  && ok_t "MEMORY.md index generated" \
  || bad_t "no MEMORY.md"
grep -q "sibling-how-company-works.md" "$TGT2/MEMORY.md" \
  && ok_t "index links a seeded fact" \
  || bad_t "index missing entry"
grep -q "DIVE-990" "$TGT2/MEMORY.md" \
  && ok_t "index header marks it as inherited onboarding" \
  || bad_t "index header missing marker"

echo
echo "── $PASS passed, $FAIL failed ──"
[[ $FAIL -eq 0 ]]
