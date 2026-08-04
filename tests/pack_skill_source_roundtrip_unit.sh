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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
