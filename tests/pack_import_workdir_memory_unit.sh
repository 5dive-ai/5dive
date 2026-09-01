#!/usr/bin/env bash
# DIVE-3881 — a pack's memory must reach an agent that was created on the DEFAULT
# workdir, and an import that seeds none must say so.
#
# THE BUG THIS GUARDS. `agent export` writes `config.workdir: null` for any agent
# that was never given an explicit --workdir — which is every agent on
# DEFAULT_WORKDIR, i.e. the normal way agents are created. cmd_import read that
# null into $workdir and the memory-seeding block was guarded on it, so the
# COMMON path skipped seeding entirely. lodar hit it on 2026-09-01 running the
# dashboard export->import end to end: 50 facts in the pack, 0 on the agent, and
# the import returned success.
#
# WHY IT SURVIVED TO A CUSTOMER is the second half and it is tested here too: the
# skip had no voice. It appeared inside the ok line's parenthetical and in the
# --json `memorySeeded` field, and the API lifts neither.
#
# The arms below REPLAY the resolution and the seeding against a real temp tree,
# and arm 2 runs the PRE-FIX guard against the same inputs — a fix that only
# looked right would leave arm 2 green, so arm 2 is what proves the defect was
# reproduced before it was closed.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT=$PWD
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got '$2', want '$3')"; }

command -v jq >/dev/null 2>&1 || { echo "  SKIP-as-FAIL — jq missing, arms 1-3 NOT REACHED"; no "jq unavailable"; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }

TMP=$(mktemp -d)
DEFAULT_WORKDIR="/home/claude/projects"

# --- the two lines under test, lifted verbatim in shape from cmd_pack.sh -------
resolve_eff_workdir() {          # $1 = $workdir (flag or manifest), $2 = registry json, $3 = agent name
  local workdir="$1" reg="$2" as="$3" eff_workdir="$1"
  if [[ -z "$eff_workdir" ]]; then
    eff_workdir=$(jq -r --arg n "$as" --arg d "$DEFAULT_WORKDIR" \
      '.agents[$n].workdir // $d' <<<"$reg" 2>/dev/null) || eff_workdir=""
    [[ -n "$eff_workdir" && "$eff_workdir" != "null" ]] || eff_workdir="$DEFAULT_WORKDIR"
  fi
  printf '%s' "$eff_workdir"
}

# Replays the seeding block against a real stage + config dir. Prints
# "<mem_seeded>|<files landed>". $1 = the workdir the block is guarded on.
seed_as_import_does() {
  local guard="$1" stage="$2" cdir="$3"
  local mem_seeded="none"
  if [[ -d "$stage/memory" ]]; then
    if [[ -n "$guard" ]]; then
      local slug mdir packed landed
      slug=$(printf '%s' "$guard" | sed 's#/#-#g')
      mdir="$cdir/projects/${slug}/memory"
      packed=$(find "$stage/memory" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l)
      mkdir -p "$mdir" 2>/dev/null || true
      cp "$stage"/memory/*.md "$mdir/" 2>/dev/null || true
      landed=$(find "$mdir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l)
      if (( landed > 0 )); then mem_seeded="$mdir ($landed of $packed facts)"
      else mem_seeded="FAILED (0 of $packed facts reached $mdir)"; fi
    else
      mem_seeded="skipped (no workdir to resolve the memory slug)"
    fi
  fi
  printf '%s|%s' "$mem_seeded" "$(find "$cdir" -type f -name '*.md' 2>/dev/null | wc -l)"
}

mkstage() {                       # $1 = dir, $2 = number of fact files
  local d="$1" n="$2" i
  mkdir -p "$d/memory"
  for ((i=1;i<=n;i++)); do printf 'fact %d\n' "$i" > "$d/memory/f$i.md"; done
}

echo "== 1. BEHAVIOURAL: a manifest with workdir:null still seeds the memory =="
# This is lodar's case exactly: no --workdir flag, config.workdir null, and the
# registry (read AFTER create) records no explicit workdir either.
reg_default='{"agents":{"clone1":{"type":"claude"}}}'
eff=$(resolve_eff_workdir "" "$reg_default" clone1)
is "null manifest + null registry resolves to DEFAULT_WORKDIR" "$eff" "$DEFAULT_WORKDIR"

mkstage "$TMP/s1" 50
mkdir -p "$TMP/c1"
IFS='|' read -r seeded landed < <(seed_as_import_does "$eff" "$TMP/s1" "$TMP/c1")
is "50 packed facts land"  "$landed" "50"
[[ "$seeded" == *"50 of 50 facts"* ]] \
  && ok "memorySeeded names the COUNT, not just an intended path ($seeded)" \
  || no "memorySeeded does not report a count (got '$seeded')"
[[ "$seeded" == *"/projects/-home-claude-projects/memory"* ]] \
  && ok "seeded under the encoded default project slug" \
  || no "wrong slug (got '$seeded')"

echo "== 2. MUTATION: the PRE-FIX guard, same inputs, drops all 50 =="
# The defect, reproduced. Guarded on the raw manifest value ("" here) instead of
# the resolved one. If this arm ever passes memory through, the harness is
# grading the wrong thing.
mkstage "$TMP/s2" 50
mkdir -p "$TMP/c2"
IFS='|' read -r pre_seeded pre_landed < <(seed_as_import_does "" "$TMP/s2" "$TMP/c2")
is "pre-fix: zero facts reach the agent" "$pre_landed" "0"
is "pre-fix: reports a skip"             "$pre_seeded" "skipped (no workdir to resolve the memory slug)"

echo "== 3. an EXPLICIT --workdir still wins over the registry =="
reg_other='{"agents":{"clone1":{"workdir":"/srv/registry-said-this"}}}'
is "flag beats registry"      "$(resolve_eff_workdir /srv/flag "$reg_other" clone1)" "/srv/flag"
is "registry beats default"   "$(resolve_eff_workdir '' "$reg_other" clone1)"        "/srv/registry-said-this"
is "unknown agent -> default" "$(resolve_eff_workdir '' "$reg_other" nosuch)"        "$DEFAULT_WORKDIR"
is "unreadable registry -> default" "$(resolve_eff_workdir '' 'not json' clone1)"    "$DEFAULT_WORKDIR"

echo "== 4. a write that fails is reported as FAILED, not as a path =="
# Every write in the real block is `|| true`, so before DIVE-3881 the reported
# path was an intention. Force the copy to fail and assert the string flips.
mkstage "$TMP/s4" 3
mkdir -p "$TMP/c4/projects"
: > "$TMP/c4/projects/-x"          # a FILE where the slug dir must go -> mkdir -p fails
IFS='|' read -r f_seeded f_landed < <(seed_as_import_does "/x" "$TMP/s4" "$TMP/c4")
is "nothing landed"        "$f_landed" "0"
[[ "$f_seeded" == FAILED* ]] \
  && ok "reports FAILED rather than the path it meant to use ($f_seeded)" \
  || no "a failed seed still reports as success (got '$f_seeded')"

echo "== 5. STRUCTURAL: the source still resolves, and resolves AFTER create =="
src="$ROOT/src/cmd_pack.sh"
r=$(grep -n 'local eff_workdir="\$workdir"' "$src" | head -1 | cut -d: -f1)
c=$(grep -n 'cmd_create "\${cargs\[@\]}"' "$src" | head -1 | cut -d: -f1)
g=$(grep -n 'if \[\[ -n "\$eff_workdir" \]\]; then' "$src" | head -1 | cut -d: -f1)
if [[ -z "$r" || -z "$c" || -z "$g" ]]; then
  no "could not locate the resolve (:$r), the create (:$c) or the seed guard (:$g) — DIVE-3881 regression, or the test is stale"
else
  (( c < r )) && ok "resolve at :$r happens after cmd_create at :$c (registry is populated)" \
               || no "resolve at :$r runs BEFORE cmd_create at :$c — the registry has no row yet"
  (( r < g )) && ok "seed guard at :$g reads the resolved value from :$r" \
               || no "seed guard at :$g precedes the resolve at :$r"
fi
grep -q 'slug=$(printf '"'"'%s'"'"' "$eff_workdir"' "$src" \
  && ok "the memory slug is built from the RESOLVED workdir" \
  || no "the memory slug no longer uses \$eff_workdir (DIVE-3881 regression)"
# The template overlay is deliberately NOT widened — it writes files.
grep -q 'if \[\[ -d "\$stage/template" && -n "\$workdir" \]\]' "$src" \
  && ok "template overlay still guarded on the explicit workdir (deliberate)" \
  || no "template overlay was widened to the resolved workdir — that was not this fix"

echo "== 6. STRUCTURAL: a seeded-nothing import warns, and only then =="
if grep -q 'this pack carries memory and NONE of it was seeded' "$src"; then
  ok "the skip has a voice on stderr"
  # It must be conditional on the skip, not printed on every import.
  ctx=$(grep -B4 'this pack carries memory and NONE of it was seeded' "$src")
  [[ "$ctx" == *'"$mem_seeded" == skipped*'* && "$ctx" == *'"$mem_seeded" == FAILED*'* ]] \
    && ok "warn is gated on skipped-or-FAILED, so a good import stays quiet" \
    || no "the warn is not gated on the skip — it would fire on every import"
else
  no "no warn when a pack carries memory and seeds none (DIVE-3881 fix B regression)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
