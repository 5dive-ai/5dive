#!/usr/bin/env bash
# stamp-changelog.sh — rewrite `## Unreleased` headings to the version being cut
# (DIVE-2452, second half).
#
# THE PROBLEM. Every section heading in CHANGELOG.md reads `## Unreleased` — eight
# of them in the first 300 lines at v0.17.9 — so the file cannot answer "what
# shipped in 0.17.9 versus what is still pending". Neither could the release page.
# The only record of 0.17.1..0.17.9's contents was the git range itself.
#
# WHERE THE STAMP LANDS, and why it is not main. `release-cut.yml` builds a
# DETACHED release commit whose parent is main's tip, assigns FIVE_VERSION onto it,
# and tags that. It deliberately never pushes to main: DIVE-2247 established that a
# `github.token` push to a protected branch is rejected and no retry fixes it, so
# the design stopped needing the push. This stamp follows the same rule — it is
# applied to the release commit's tree only.
#
# The consequence, stated so nobody reads the result as a bug: `CHANGELOG.md` ON
# MAIN still says `Unreleased` for everything. What changes is that
# `git show v0.17.11:CHANGELOG.md` now answers the question, and the release page
# carries the same prose. The boundary between versions is the git range either
# way (see scripts/release-notes.sh), so nothing downstream depends on the heading
# text being stamped on main.
#
# At the release commit, "pending" is empty by construction: every section present
# in that tree is shipping in that tag. So rewriting EVERY `Unreleased` heading is
# correct here in a way it would not be on main.
#
# Usage: stamp-changelog.sh <version> [changelog-path]
#        rewrites in place; prints the number of headings stamped.
set -uo pipefail

version="${1-}"
changelog="${2:-CHANGELOG.md}"

if [[ -z "$version" ]]; then
  echo "usage: stamp-changelog.sh <version> [changelog-path]" >&2
  exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "stamp-changelog: version must be MAJOR.MINOR.PATCH — got '${version}'" >&2
  exit 2
fi
if [[ ! -f "$changelog" ]]; then
  echo "stamp-changelog: ${changelog} does not exist" >&2
  exit 2
fi

# Count first, from the same pattern the rewrite uses, so the reported number
# describes what was actually matched rather than what we hoped to match.
before=$(grep -cE '^## +Unreleased([ 	]|$)' "$changelog" || true)

# Two forms, and the em-dash separator is preserved verbatim: `## Unreleased — X`
# becomes `## v1.2.3 — X`, and a bare `## Unreleased` becomes `## v1.2.3`.
# Anchored at line start, so a mention of "Unreleased" inside prose is untouched.
tmp="$(mktemp)"
sed -E "s/^## +Unreleased([ 	]+[-—–].*)$/## v${version}\1/; s/^## +Unreleased *$/## v${version}/" \
  "$changelog" > "$tmp"
mv "$tmp" "$changelog"

after=$(grep -cE '^## +Unreleased([ 	]|$)' "$changelog" || true)
stamped=$(( before - after ))

# An anchor that matched nothing is reported, never silently accepted: a stamp that
# did nothing looks exactly like one that worked.
if [[ "$after" -ne 0 ]]; then
  echo "stamp-changelog: ${after} 'Unreleased' heading(s) survived the rewrite in ${changelog} — the pattern drifted" >&2
  exit 1
fi

echo "$stamped"
