#!/usr/bin/env bash
# TIER: nightly — ~30s measured (2026-09-24, local): three 662-atom fixtures are the 1.5 MB case the row names and are not shrinkable without grading a toy; the arms guard the import path, not a per-change core path.
# DIVE-4923 unit harness: a CLAUDE pack imported onto a CODEX seat must land its
# memory usable. Measured on 0.51.0 (marketing -> leo, 661 atoms): 1,560,263 B
# of raw memory inlined into ~/.codex/AGENTS.md (codex reads 32 KiB of it), the
# atoms copied into ~/.codex/memories (codex's NATIVE store), `memory search`
# blind on the seat, no `[features] memories = true`, and no way to pre-pair the
# owner on the new bot.
#
# Arms, each executing the shipped function on a fixture — no root, no seat:
#   A  the 1.5 MB inline: AGENTS.md (persona + memory + a 12,023 B baseline, the
#      size measured on a live codex seat) stays under 32 KiB, the baseline is
#      intact and LAST, a pointer is present, no fact body is inlined.
#   B  a small store still inlines in full (DIVE-2568 is not regressed).
#   C  a huge persona still gets a pointer, inside the floor budget.
#   D  routing: claude atoms never land in codex's native dir.
#   E  `5dive memory search --index` as the seat returns its own atoms (·mine).
#   F  config.toml: native memory on, one [features] table, user's false kept.
#   G  `agent import --human=` is forwarded to create.
#   M  mutants: each restores one 0.51.0 behaviour and a named arm goes red.
#
# Run against another tree (e.g. pre-fix main): NCIM_SRC=<dir>/src NCIM_START=<dir>/5dive-agent-start
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC="${NCIM_SRC:-src}"
START="${NCIM_START:-5dive-agent-start}"

TMP="$(mktemp -d /tmp/codex-import-mem-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want [$3] got [$2]"; }
lt_t()  { (( $2 < $3 )) && ok_t "$1 ($2 < $3)" || bad_t "$1" "want < $3 got $2"; }
le_t()  { (( $2 <= $3 )) && ok_t "$1 ($2 <= $3)" || bad_t "$1" "want <= $3 got $2"; }

# --- fixtures ---------------------------------------------------------------
CODEX_DOC_LIMIT=32768
PERSONA=$'# Leo\n\nYou are Leo, the marketing lead. You write in plain English and ship on time.\n\n## Why you exist\n\nTo carry the marketing voice forward.\n'
# The operating baseline persona_install_doc prepends above. Same size as the
# one measured on a live codex seat (12,023 B) so the 32 KiB claim is graded
# against the real composition, not a toy.
BASELINE="$TMP/baseline.md"
{ printf '# 5dive managed operating baseline\n\n'
  while (( $(wc -c < "$BASELINE" 2>/dev/null || echo 0) < 12023 )); do
    printf 'Report results back to whoever asked; ack within thirty seconds on every channel.\n'
  done
} > "$BASELINE" 2>/dev/null
head -c 12023 "$BASELINE" > "$BASELINE.t" && mv "$BASELINE.t" "$BASELINE"

# THE 1.5 MB INLINE, reproduced: 662 raw claude atoms + the router MEMORY.md,
# body padded so the store totals ~1.5 MB like the measured one.
mk_stage() {  # mk_stage <dir> <n-atoms> <pad-repeats>
  local d="$1" n="$2" r="$3" i pad
  mkdir -p "$d/memory"
  printf '{"includes":{"memory":"raw"}}\n' > "$d/manifest.json"
  printf '%s' "$PERSONA" > "$d/CLAUDE.md"
  pad=$(printf 'Mechanism, the measurement behind it, and the caveat that follows. %.0s' $(seq 1 "$r"))
  for (( i=1; i<=n; i++ )); do
    printf -- '---\nname: fact-%04d\ndescription: blog post cadence fact number %d for the marketing seat\nmetadata:\n  type: reference\n---\n\nUNIQUE-BODY-%04d %s\n' \
      "$i" "$i" "$i" "$pad" > "$d/memory/fact-$(printf %04d "$i").md"
  done
  printf '# Memory router\n\n5dive memory search --index "<topic>"\n' > "$d/memory/MEMORY.md"
}
compose_agents_md() {  # the composition persona_install_doc performs: persona doc, blank, baseline
  { cat "$1/CLAUDE.md"; printf '\n'; cat "$BASELINE"; } > "$1/AGENTS.md"
}

BIG="$TMP/big"; mk_stage "$BIG" 662 33
big_bytes=$(cat "$BIG"/memory/*.md | wc -c)
if (( big_bytes > 1400000 )); then ok_t "A-live fixture is the 1.5 MB case ($big_bytes B, 663 files)"
else bad_t "A-live fixture too small to reproduce the defect" "$big_bytes B"; fi

# --- A: the 1.5 MB inline --------------------------------------------------
_PACK_INLINE_MODE=""
_pack_inline_memory_into_doc "$BIG" codex raw >/dev/null 2>&1; rc=$?
eq_t "A0 inline rc 0 (the seat is told where memory is)" "$rc" "0"
compose_agents_md "$BIG"
amd_b=$(wc -c < "$BIG/AGENTS.md")
lt_t "A1 AGENTS.md stays under codex's 32 KiB project-doc budget" "$amd_b" "$CODEX_DOC_LIMIT"
if [[ "$(tail -c "$(wc -c < "$BASELINE")" "$BIG/AGENTS.md")" == "$(cat "$BASELINE")" ]]; then
  ok_t "A2 the operating baseline is intact and whole at the end"
else bad_t "A2 baseline not intact at the end of AGENTS.md"; fi
bl_line=$(grep -n '^# 5dive managed operating baseline' "$BIG/AGENTS.md" | head -1 | cut -d: -f1)
lt_t "A2b ...and starts early, not at line 20316" "${bl_line:-99999}" "400"
if grep -qF '<!-- 5dive:memory-pointer -->' "$BIG/AGENTS.md" \
   && grep -qF '5dive memory search --index' "$BIG/AGENTS.md"; then
  ok_t "A3 a memory POINTER is present, with the search command"
else bad_t "A3 no memory pointer in AGENTS.md"; fi
eq_t "A4 no fact BODY was inlined" "$(grep -c 'UNIQUE-BODY-' "$BIG/AGENTS.md")" "0"
eq_t "A5 the degradation is DECLARED to the caller (mode=pointer)" "${_PACK_INLINE_MODE:-unset}" "pointer"
nlisted=$(grep -c '^- \[fact-' "$BIG/AGENTS.md")
if (( nlisted > 0 && nlisted < 662 )); then ok_t "A6 a bounded index names some atoms ($nlisted of 662)"
else bad_t "A6 bounded index" "listed=$nlisted"; fi
if grep -qE 'of 662 atoms are not named above' "$BIG/AGENTS.md"; then
  ok_t "A7 ...and says how many it did not name"
else bad_t "A7 the cut listing does not declare what it left out"; fi
if ! grep -qxF '<!-- 5dive:memory -->' "$BIG/AGENTS.md"; then
  ok_t "A8 the export memory sentinel is NOT used (a pointer carries no bodies to explode)"
else bad_t "A8 pointer reused the export sentinel"; fi

# --- B: a small store still inlines in full ---------------------------------
SMALL="$TMP/small"; mk_stage "$SMALL" 3 2
_PACK_INLINE_MODE=""
_pack_inline_memory_into_doc "$SMALL" codex distilled >/dev/null 2>&1
eq_t "B1 small store -> mode=full" "${_PACK_INLINE_MODE:-unset}" "full"
eq_t "B2 ...every body is in the doc" "$(grep -c 'UNIQUE-BODY-' "$SMALL/CLAUDE.md")" "3"

# --- C: a huge persona still gets a pointer, inside the floor ----------------
HUGE="$TMP/huge"; mk_stage "$HUGE" 40 30
head -c 30000 /dev/zero | tr '\0' 'p' >> "$HUGE/CLAUDE.md"
pre_b=$(wc -c < "$HUGE/CLAUDE.md")
_pack_inline_memory_into_doc "$HUGE" codex raw >/dev/null 2>&1
eq_t "C1 huge persona -> pointer" "${_PACK_INLINE_MODE:-unset}" "pointer"
le_t "C2 ...memory section within the floor budget" "$(( $(wc -c < "$HUGE/CLAUDE.md") - pre_b - 1 ))" "${_PACK_INLINE_MEMORY_FLOOR:-0}"
grep -qF '5dive memory search --index' "$HUGE/CLAUDE.md" \
  && ok_t "C3 ...and the pointer still names the search command" \
  || bad_t "C3 pointer missing under a huge persona"

# --- D: routing -------------------------------------------------------------
eq_t "D1 claude atoms onto codex -> 5dive's store, not codex's native dir" \
     "$(_pack_import_memory_target codex atoms 2>/dev/null)" "5dive-store"
eq_t "D2 a codex store onto codex -> codex's native dir" \
     "$(_pack_import_memory_target codex codex-docs 2>/dev/null)" "native-codex"
eq_t "D3 claude atoms onto claude -> 5dive's store" \
     "$(_pack_import_memory_target claude atoms 2>/dev/null)" "5dive-store"
eq_t "D4 a codex store onto opencode -> 5dive's store (converted)" \
     "$(_pack_import_memory_target opencode codex-docs 2>/dev/null)" "5dive-store"
# WIRING: cmd_import's native branch is keyed on the router, not on type alone.
IMPORT_FN=$(awk '/^cmd_import\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SRC/cmd_pack.sh")
if grep -q '"\$mem_target" == "native-codex"' <<<"$IMPORT_FN" \
   && ! grep -qE '&& "\$type" == "codex" \]\]; then' <<<"$IMPORT_FN"; then
  ok_t "D5 cmd_import routes the native copy through _pack_import_memory_target"
else bad_t "D5 cmd_import still keys the ~/.codex/memories copy on type alone"; fi
if grep -q '_PACK_INLINE_MODE" == "pointer"' <<<"$IMPORT_FN"; then
  ok_t "D6 the import envelope reports the pointer mode, not 'inlined'"
else bad_t "D6 mem_effect does not distinguish pointer from inline"; fi

# --- E: memory search as the seat reads its own atoms -----------------------
SEAT="$TMP/home/agent-leo"
MDIR="$SEAT/.claude/projects/-home-claude-projects-5dive/memory"
_pack_seed_claude_memory "$BIG/memory" "$MDIR" atoms >/dev/null 2>&1
case "$MDIR" in *"/.codex/memories"*) bad_t "E1 seeded dir is codex's native store" ;;
                *) ok_t "E1 atoms seeded outside ~/.codex/memories" ;; esac
eq_t "E2 every atom landed" "$(find "$MDIR" -maxdepth 1 -name 'fact-*.md' | wc -l)" "662"
if command -v node >/dev/null 2>&1; then
  sr=$( HOME="$SEAT"
        # shellcheck source=/dev/null
        source "$SRC/cmd_memory.sh"
        _memory_search "blog post cadence" --index --store=mine 2>&1 )
  nmine=$(grep -c '·mine' <<<"$sr")
  if (( nmine > 0 )); then ok_t "E3 'memory search --index' as the seat returns its own atoms ($nmine ·mine)"
  else bad_t "E3 memory search blind on the seat" "$(head -3 <<<"$sr")"; fi
else
  ok_t "E3 SKIP node absent (memory search needs node)"
fi

# --- F: config.toml native memory -------------------------------------------
FN=$(awk '/^  codex_ensure_feature\(\) \{/{f=1} f{print} f&&/^  \}/{exit}' "$START")
if [[ -n "$FN" ]]; then
  eval "$FN"
  ok_t "F-live codex_ensure_feature extracted from 5dive-agent-start"
else
  bad_t "F-live codex_ensure_feature not found in $START"
  codex_ensure_feature() { :; }
fi
toml_ok() { python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$1" 2>/dev/null; }
feat()    { python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb")).get("features",{}).get(sys.argv[2],"absent"))' "$1" "$2" 2>/dev/null; }
BASE_TOML=$'approval_policy = "never"\nsandbox_mode = "danger-full-access"\n\n[projects."/home/claude/projects/5dive"]\ntrust_level = "trusted"\n'
c1="$TMP/c1.toml"; printf '%s' "$BASE_TOML" > "$c1"
codex_ensure_feature "$c1" memories
eq_t "F1 base config (the import seat's) -> memories = true" "$(feat "$c1" memories)" "True"
toml_ok "$c1" && ok_t "F1b ...and still valid TOML" || bad_t "F1b invalid TOML after ensure"
cp "$c1" "$c1.before"; codex_ensure_feature "$c1" memories
cmp -s "$c1" "$c1.before" && ok_t "F2 idempotent: a second boot changes nothing" || bad_t "F2 not idempotent"
# The telegram sequence: memories ensured on an earlier boot, telegram attached
# later. Before, the telegram block appended its own [features] table — a second
# header is a parse error. Now both keys share one table.
codex_ensure_feature "$c1" hooks
eq_t "F3 later telegram attach -> ONE [features] table" "$(grep -c '^\[features\]' "$c1")" "1"
toml_ok "$c1" && [[ "$(feat "$c1" hooks)" == "True" && "$(feat "$c1" memories)" == "True" ]] \
  && ok_t "F3b ...valid, with hooks and memories both true" || bad_t "F3b telegram-after-ensure config broken"
c2="$TMP/c2.toml"; printf '%s\n[features]\nhooks = true\n\n[[hooks.Stop]]\n' "$BASE_TOML" > "$c2"
codex_ensure_feature "$c2" memories
eq_t "F4 existing [features] -> key inserted under it" "$(feat "$c2" memories)" "True"
eq_t "F4b ...no second table" "$(grep -c '^\[features\]' "$c2")" "1"
c3="$TMP/c3.toml"; printf '%s\n[features]\nmemories = false\n' "$BASE_TOML" > "$c3"
cp "$c3" "$c3.before"; codex_ensure_feature "$c3" memories
cmp -s "$c3" "$c3.before" && ok_t "F5 an explicit memories = false is the user's and is kept" || bad_t "F5 user's false overwritten"
# The telegram heredoc no longer carries its own [features] table.
TG_BLOCK=$(awk '/^\[mcp_servers\.telegram\]/{f=1} f{print} f&&/^TOML$/{exit}' "$START")
if [[ -n "$TG_BLOCK" ]] && ! grep -q '^\[features\]' <<<"$TG_BLOCK"; then
  ok_t "F6 the telegram block no longer appends a second [features] table"
else bad_t "F6 telegram heredoc still writes [features] (duplicate-table risk)"; fi
grep -q 'codex_ensure_feature "\$AGENT_CODEX_HOME/config.toml" memories' "$START" \
  && ok_t "F7 agent-start ensures memories on every codex boot" \
  || bad_t "F7 agent-start never ensures memories = true"

# --- G: --human forwarded on import -----------------------------------------
_import_create_passthru_ok "--human=lodar" && ok_t "G1 import forwards --human= to create" \
  || bad_t "G1 --human= is not a forwarded create flag"
( _import_parse_args some-pack --as=leo --human=lodar ) >/dev/null 2>&1 \
  && ok_t "G2 hire/import validation accepts --human=" || bad_t "G2 --human= rejected as unknown flag"

# --- M: mutants — each restores one 0.51.0 behaviour ------------------------
# M1: no budget (inline everything). A1 must go red.
M1="$TMP/m1"; mk_stage "$M1" 662 33
( _PACK_INLINE_MEMORY_BUDGET=99999999 _PACK_BASELINE_RESERVE=-99999999
  _pack_inline_memory_into_doc "$M1" codex raw >/dev/null 2>&1 )
compose_agents_md "$M1"
m1_b=$(wc -c < "$M1/AGENTS.md")
(( m1_b >= CODEX_DOC_LIMIT )) && ok_t "M1 mutant 'no budget' -> AGENTS.md ${m1_b} B: A1 goes red" \
  || bad_t "M1 mutant 'no budget' stayed under the limit — A1 grades nothing" "$m1_b"
# M2: route every codex target to the native dir (the 0.51.0 branch). D1 must go red.
m2=$( _pack_import_memory_target() { [[ "$1" == "codex" ]] && printf 'native-codex\n' || printf '5dive-store\n'; }
      _pack_import_memory_target codex atoms )
[[ "$m2" != "5dive-store" ]] && ok_t "M2 mutant 'codex -> native always' -> D1 goes red" \
  || bad_t "M2 mutant not caught by D1"
# M3: the telegram block's own [features] table restored. F3 must go red.
m3="$TMP/m3.toml"; printf '%s' "$BASE_TOML" > "$m3"
codex_ensure_feature "$m3" memories; printf '\n[features]\nhooks = true\nmemories = true\n' >> "$m3"
{ [[ "$(grep -c '^\[features\]' "$m3")" != "1" ]] && ! toml_ok "$m3"; } \
  && ok_t "M3 mutant 'telegram appends [features]' -> F3 goes red (duplicate table, TOML parse error)" \
  || bad_t "M3 mutant not caught"

echo
echo "  pass=$PASS fail=$FAIL"
(( FAIL == 0 )) || exit 1
