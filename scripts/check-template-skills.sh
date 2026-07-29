#!/usr/bin/env bash
# DIVE-2347 — every skill a shipped template requests must exist in the repo it names.
#
# A template declares each role's skills as bare ids:
#
#     writer:
#       skills: [5dive-cli, deep-research]
#
# That id is a reference into a DIFFERENT repository (bare ids resolve to
# `<org>/skills` via parse_skill_spec), resolved at import time, on the customer's
# box, months after the template was written. Nothing validated it — not the schema,
# not a test, not CI. On 2026-07-29 all three shipped templates referenced skills that
# were not in the repo, six references in total, and it took a customer running an
# import to notice.
#
# It stayed invisible because the failure is deliberately non-fatal AND ambiguous: a
# flaked fetch and a skill that has never existed print the same warning and suggest the
# same futile rerun. This script removes the ambiguity by asking the repo directly.
#
# Usage:
#   scripts/check-template-skills.sh                     # fetch the live skill list via gh
#   scripts/check-template-skills.sh --skills-list=FILE   # grade against a list (offline/tests)
#   scripts/check-template-skills.sh --templates=DIR
#
# Exit: 0 all references resolve · 1 at least one does not · 2 could not check (SKIP).
#
# Exit 2 is deliberately NOT 0. An unresolvable precondition is not a pass: if gh is
# missing or unauthenticated we cannot tell a good template from a broken one, and
# saying "clean" there would reintroduce the exact silence this check exists to break.

set -uo pipefail

TEMPLATES_DIR=""
SKILLS_LIST=""
for arg in "$@"; do
  case "$arg" in
    --templates=*)   TEMPLATES_DIR="${arg#--templates=}" ;;
    --skills-list=*) SKILLS_LIST="${arg#--skills-list=}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [[ -z "$TEMPLATES_DIR" ]]; then
  TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/team-templates"
fi
[[ -d "$TEMPLATES_DIR" ]] || { printf 'SKIP — no templates dir at %s\n' "$TEMPLATES_DIR" >&2; exit 2; }

# --- what the templates ASK FOR ---------------------------------------------
# `skills: [a, b]` → one bare id per line. A `owner/repo:id` entry is stripped to the
# bare id: only that is ever the installed directory name, and only the default source
# is what we can check here.
requested() {
  grep -rhoE '^[[:space:]]*skills:[[:space:]]*\[[^]]*\]' "$TEMPLATES_DIR"/*.yaml 2>/dev/null \
    | sed 's/.*\[//; s/\]//' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^.*://' \
    | grep -v '^$' \
    | sort -u
}

# Which template asks for a given id — so a failure names the file to edit.
where() {
  grep -rlE "^[[:space:]]*skills:.*[][:space:],]$1[],]" "$TEMPLATES_DIR"/*.yaml 2>/dev/null \
    | xargs -r -n1 basename | paste -sd, -
}

# --- what the repo HAS -------------------------------------------------------
available() {
  if [[ -n "$SKILLS_LIST" ]]; then
    [[ -r "$SKILLS_LIST" ]] || return 1
    sort -u "$SKILLS_LIST"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  local org="${FIVE_GH_ORG:-5dive-ai}"
  gh api "repos/${org}/skills/contents" \
    --jq '.[] | select(.type=="dir") | .name' 2>/dev/null | sort -u
}

req=$(requested)
if [[ -z "$req" ]]; then
  printf 'SKIP — no skill references found in %s (parser or templates changed)\n' "$TEMPLATES_DIR" >&2
  exit 2
fi

avail=$(available)
if [[ -z "$avail" ]]; then
  printf 'SKIP — could not read the skill list (no gh, unauthenticated, or empty). NOT a pass.\n' >&2
  exit 2
fi

missing=$(comm -23 <(printf '%s\n' "$req") <(printf '%s\n' "$avail"))

if [[ -z "$missing" ]]; then
  printf 'ok — all %s skill reference(s) across %s template(s) resolve\n' \
    "$(printf '%s\n' "$req" | wc -l | tr -d ' ')" \
    "$(find "$TEMPLATES_DIR" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')"
  exit 0
fi

printf 'FAIL — %s skill reference(s) do not exist in the source repo.\n' \
  "$(printf '%s\n' "$missing" | wc -l | tr -d ' ')" >&2
printf '       Each one fails on EVERY import, forever, and tells the customer to rerun\n' >&2
printf '       a command that cannot work.\n\n' >&2
while IFS= read -r m; do
  [[ -n "$m" ]] || continue
  printf '  %-24s requested by: %s\n' "$m" "$(where "$m")" >&2
done <<<"$missing"
printf '\n       Fix: publish the skill, or change the template to one that exists.\n' >&2
exit 1
