#!/usr/bin/env bash
# DIVE-2678 isolated unit harness — a skill's SOURCE survives export, and a skill
# that cannot survive it says why.
#
# The incident: two fresh seats imported from one exported AGENTS.md and both
# reported "Skills added: 4, skipped: 18", identical name-for-name. It reads as a
# broken importer. It is not. Export emitted the skills DIRECTORY NAMES, and a bare
# name is re-resolved by parse_skill_spec against `<org>/skills` and nowhere else, so
# every skill from any other repo left the export unresolvable. All 18 skipped names
# were checked against 5dive-ai/skills by fetch: none are published there, so the
# skip was CORRECT and the fix belongs on the export side (carry the source) plus the
# message (say which repo was tried and how to finish the job by hand).
#
# Graded BEHAVIOURALLY, both halves — the first cut of the second section grepped
# cmd_import for the warning text and a disabled branch killed nothing, the standing
# lesson in pack_cross_harness_unit.sh. _pack_skill_refs is called for real against a
# real fixture tree; the message arm executes the shipped `for` body.
# Run: bash tests/pack_skill_source_roundtrip_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/skill-source-roundtrip.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Pin the org so gh_org never probes the network from a unit harness — and so the
# "default repo" the assertions talk about is a value this file states, not one the
# host happens to resolve to.
export GH_ORG=5dive-ai

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_skill.sh"   # parse_skill_spec — the resolver the refs are aimed at
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"

JSON_MODE=1
set +e   # header.sh enabled `set -e`; tests deliberately probe non-zero paths

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1 (want [$3] got [$2])"; fi; }
has()   { if grep -qF -- "$2" <<<"$1"; then ok_ "$3"; else bad_ "$3 (missing [$2])"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then bad_ "$3 (unexpectedly present: [$2])"; else ok_ "$3"; fi; }

# ---------------------------------------------------------------- fixtures ---
# A seat carrying the three shapes that behave differently. Reserved fakes only
# (host CLAUDE.md rule): no real third-party repo slug is named.
SDIR="$TMP/skills"
mkdir -p "$SDIR"/{5dive-cli,widgets,handseeded}
for s in 5dive-cli widgets handseeded; do printf '# %s\n' "$s" > "$SDIR/$s/SKILL.md"; done
# A symlinked skill — the per-agent layout the -type l arm exists for.
mkdir -p "$TMP/elsewhere/linked"; printf '# linked\n' > "$TMP/elsewhere/linked/SKILL.md"
ln -s "$TMP/elsewhere/linked" "$SDIR/linked"
jq -n '{
  "5dive-cli": { source: "5dive-ai/skills",   resolved_sha: "deadbeef", content_sha256: "aaa" },
  "widgets":   { source: "example-org/tools", resolved_sha: "deadbeef", content_sha256: "bbb" },
  "linked":    { source: "example-org/tools", resolved_sha: "deadbeef", content_sha256: "ccc" }
}' > "$SDIR/.skills-manifest.json"

printf '\n1. export carries the source ref (_pack_skill_refs)\n'

REFS=$(_pack_skill_refs "$SDIR")
check "refs are a JSON array" "$(jq -r 'type' <<<"$REFS" 2>/dev/null)" "array"
check "every installed skill is represented" "$(jq -r 'length' <<<"$REFS" 2>/dev/null)" "4"
has "$REFS" '"example-org/tools:widgets"' "third-party skill exports QUALIFIED"
has "$REFS" '"example-org/tools:linked"' "a SYMLINKED third-party skill exports qualified too"
has "$REFS" '"5dive-cli"' "default-repo skill stays bare (readable AGENTS.md)"
hasnt "$REFS" '"5dive-ai/skills:5dive-cli"' "default repo is not spelled out redundantly"
has "$REFS" '"handseeded"' "a skill with no manifest entry still exports (bare)"
# The manifest file itself is not a skill.
hasnt "$REFS" '.skills-manifest' "the manifest file is never emitted as a skill"

printf '\n2. the ref is what the IMPORT resolver actually consumes\n'
# The point of section 1 is only true if parse_skill_spec — the function import feeds
# these strings to — splits them back to the source they were exported from. Assert
# the round-trip, not the string shape.
rt() { local pair; pair=$(parse_skill_spec "$1"); printf '%s|%s' "${pair% *}" "${pair#* }"; }
check "qualified ref round-trips to its own repo" \
  "$(rt "$(jq -r '.[] | select(startswith("example-org/tools:widgets"))' <<<"$REFS")")" \
  "example-org/tools|widgets"
check "bare ref resolves to the default repo, as before" "$(rt 5dive-cli)" "5dive-ai/skills|5dive-cli"
# The pre-fix behaviour, stated as the thing that must no longer happen: a bare
# "widgets" would have been aimed at the WRONG repo, which is the whole defect.
check "the pre-fix bare form aimed at the wrong repo" "$(rt widgets)" "5dive-ai/skills|widgets"

printf '\n3. degenerate inputs do not take the export down\n'
check "missing skills dir -> empty array" "$(_pack_skill_refs "$TMP/nope")" "[]"
mkdir -p "$TMP/empty/skills"
check "empty skills dir -> empty array" "$(_pack_skill_refs "$TMP/empty/skills")" "[]"
mkdir -p "$TMP/garbage/skills/one"; printf '# one\n' > "$TMP/garbage/skills/one/SKILL.md"
printf 'not json at all\n' > "$TMP/garbage/skills/.skills-manifest.json"
check "unparseable manifest degrades to bare names, never empty" \
  "$(_pack_skill_refs "$TMP/garbage/skills")" '["one"]'
printf '[1,2,3]\n' > "$TMP/garbage/skills/.skills-manifest.json"
check "a manifest of the wrong TYPE degrades the same way" \
  "$(_pack_skill_refs "$TMP/garbage/skills")" '["one"]'

printf '\n4. a skip states its reason, per skill (DIVE-2678 messaging)\n'
# Execute the shipped arm rather than grepping for its text: the same `for` body, over
# the same two ref shapes, with warn captured. A branch someone disables to false must
# take these assertions down with it.
skip_report() {
  local as="newseat"; local -a skipped=("$@"); local sk_ out
  # warn writes to STDERR, so the redirect has to be INSIDE the substitution — a
  # trailing `2>&1` on the assignment redirects the assignment, not the subshell,
  # and every `has` below then passes/fails against an empty string.
  out=$( {
    for sk_ in "${skipped[@]}"; do
      if [[ "$sk_" == *:* ]]; then
        warn "  '${sk_#*:}' — '${sk_%%:*}' did not serve it (missing, private, or unreachable from this host)"
      else
        warn "  '$sk_' — no source recorded in the pack, so only '$(gh_org)/skills' was tried and it is not published there; re-add it by hand: 5dive agent skill $as add --source=<owner/repo> --skill=$sk_"
      fi
    done
  } 2>&1 )
  printf '%s' "$out"
}
REPORT=$(skip_report "example-org/tools:widgets" "handseeded")
has "$REPORT" "example-org/tools" "a qualified skip names the repo that did not serve it"
has "$REPORT" "no source recorded" "a bare skip says the provenance was missing"
has "$REPORT" "5dive-ai/skills" "a bare skip names the ONLY repo that was tried"
has "$REPORT" "5dive agent skill newseat add --source=<owner/repo> --skill=handseeded" \
  "a bare skip hands over the exact command that finishes the job"
hasnt "$REPORT" "'example-org/tools:widgets' — no source recorded" \
  "a qualified skip does not claim its source was missing"

# The shipped call site must be the same shape as the arm graded above — a helper
# graded in isolation is worth nothing if cmd_import stopped calling it.
IMPORT_ARM=$(sed -n '/DIVE-2565: a silent skill drop/,/^  rm -rf "\$stage"/p' "$SRC/cmd_pack.sh")
has "$IMPORT_ARM" 'no source recorded in the pack' "cmd_import still emits the per-skill reason"
has "$IMPORT_ARM" 'did not serve it' "cmd_import still distinguishes a qualified failure"
STAGE_ARM=$(grep -c '_pack_skill_refs "\$cdir/skills"' "$SRC/cmd_pack.sh")
check "export calls the helper (not an inlined copy)" "$STAGE_ARM" "1"

printf '\n5. NO MANIFEST AT ALL — the shape every real seat actually has\n'
# THE LESSON THIS SECTION EXISTS FOR. Sections 1-4 build their own fixture manifest,
# so they pass on a precondition that does not hold anywhere in production: measured
# 2026-08-04, `find /home -name .skills-manifest.json` returns ZERO across the fleet,
# including the seat whose export produced the reported "added 4, skipped 18". A
# fixture that SUPPLIES the precondition can never discover that the precondition is
# never met — so this section removes it and grades the fleet-real shape.
NOMAN="$TMP/noman/skills"
mkdir -p "$NOMAN"/{find-skills,5dive-cli,animejs}
for s in find-skills 5dive-cli animejs; do printf '# %s\n' "$s" > "$NOMAN/$s/SKILL.md"; done
check "the fixture really has no manifest" "$([[ -e "$NOMAN/.skills-manifest.json" ]] && echo yes || echo no)" "no"

NREFS=$(_pack_skill_refs "$NOMAN")
has "$NREFS" '"vercel-labs/skills:find-skills"' \
  "find-skills resolves with NO manifest — the default table carries it"
check "and it round-trips to the repo that actually serves it" \
  "$(rt "vercel-labs/skills:find-skills")" "vercel-labs/skills|find-skills"
has "$NREFS" '"5dive-cli"' "a default-repo default stays bare"
has "$NREFS" '"animejs"' "an unpublished local-only skill still exports bare"
hasnt "$NREFS" '"vercel-labs/skills:animejs"' \
  "the table never INVENTS a source for a skill it does not know"

# Precedence: a manifest is authoritative because it can carry third-party sources the
# table cannot know. If the table won instead, a relocated skill would silently export
# the wrong repo.
mkdir -p "$TMP/prec/skills/find-skills"; printf '# f\n' > "$TMP/prec/skills/find-skills/SKILL.md"
jq -n '{"find-skills":{source:"example-org/tools"}}' > "$TMP/prec/skills/.skills-manifest.json"
has "$(_pack_skill_refs "$TMP/prec/skills")" '"example-org/tools:find-skills"' \
  "an explicit manifest entry OVERRIDES the default table"

printf '\n6. the default table cannot drift from the installer that seeds it\n'
# skill_default_source is a second spelling of the install_default_skill_for_agent call
# sites. Two spellings of one fact drift, so derive the truth from agent_setup.sh and
# compare — adding a default skill there without adding it here reds this.
DRIFT=0
while read -r src_ skill_; do
  [[ -n "$skill_" ]] || continue
  got=$(skill_default_source "$skill_" 2>/dev/null) || got="<unknown>"
  if [[ "$got" != "$src_" ]]; then
    bad_ "skill_default_source $skill_ -> want [$src_] got [$got]"; DRIFT=1
  fi
done < <(grep -oE 'install_default_skill_for_agent "\$name" [a-z]+ (vercel-labs/skills|"\$\(gh_org\)/skills") [a-z0-9-]+' \
           "$SRC/lib/agent_setup.sh" \
         | sed -E 's/.* (vercel-labs\/skills|"\$\(gh_org\)\/skills") ([a-z0-9-]+)$/\1 \2/' \
         | sed 's|"\$(gh_org)/skills"|5dive-ai/skills|' | sort -u)
[[ $DRIFT -eq 0 ]] && ok_ "every installer default is known to skill_default_source"
# Non-vacuity: the loop above must actually have read call sites.
SITES=$(grep -cE 'install_default_skill_for_agent "\$name" [a-z]+ ' "$SRC/lib/agent_setup.sh")
if [[ "$SITES" -ge 8 ]]; then ok_ "the drift check read $SITES real call sites"
else bad_ "drift check read only $SITES call sites — it is not reaching agent_setup.sh"; fi
check "an id that is not a 5dive default is rejected" \
  "$(skill_default_source not-a-5dive-skill >/dev/null 2>&1; echo $?)" "1"

printf '\n7. the create path RECORDS provenance (why no seat had a manifest)\n'
# The writer existed in cmd_skill_add since DIVE-2282/PR #291 and still no seat had a
# manifest, because installs do not go through `agent skill add` — they go through
# install_default_skill_for_agent, which recorded nothing. Assert every arm now notes.
SETUP=$(sed -n '/^install_default_skill_for_agent()/,/^}/p' "$SRC/lib/agent_setup.sh")
NOTES=$(grep -c '_skill_manifest_note "\$user" "\$home" "\$install_dir" "\$skill" "\$source"' <<<"$SETUP")
check "all three install arms record the source (npx, manual, already-present)" "$NOTES" "3"
has "$SETUP" 'BACKFILLS' "the already-present arm is documented as the backfill it is"
# The note helper must write the key export reads. Grade the shape, not the prose.
NOTE_FN=$(sed -n '/^_skill_manifest_note()/,/^}/p' "$SRC/lib/agent_setup.sh")
has "$NOTE_FN" '.skills-manifest.json' "the helper writes the file export reads"
has "$NOTE_FN" 'source:$s' "the helper records the SOURCE field _pack_skill_refs consumes"
has "$NOTE_FN" '|| true' "a manifest write can never fail an install"

# Behavioural: run the helper's body against a throwaway HOME and read the result back
# through _pack_skill_refs. Source-level greps above say the call sites exist; this says
# the thing they call produces a manifest export can actually use.
NHOME="$TMP/nhome"; mkdir -p "$NHOME/.claude/skills/find-skills"
printf '# f\n' > "$NHOME/.claude/skills/find-skills/SKILL.md"
( sed -n '/^_skill_manifest_note()/,/^}/p' "$SRC/lib/agent_setup.sh" \
    | sed -n '/<<.MANIFEST_NOTE./,/^MANIFEST_NOTE$/p' | sed '1d;$d' \
    | HOME="$NHOME" INSTALL_DIR=".claude/skills" SKILL="find-skills" \
      SOURCE="vercel-labs/skills" bash -s ) >/dev/null 2>&1
check "the helper body actually wrote a manifest" \
  "$([[ -s "$NHOME/.claude/skills/.skills-manifest.json" ]] && echo yes || echo no)" "yes"
check "and it recorded the source export needs" \
  "$(jq -r '."find-skills".source // "<none>"' "$NHOME/.claude/skills/.skills-manifest.json" 2>/dev/null)" \
  "vercel-labs/skills"
has "$(_pack_skill_refs "$NHOME/.claude/skills")" '"vercel-labs/skills:find-skills"' \
  "a seat seeded by the create path now exports its source"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
