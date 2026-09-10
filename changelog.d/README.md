# changelog.d/ — conflict-free changelog entries (DIVE-2582)

Editing the top of `CHANGELOG.md` directly still works exactly as before — this
is an *additional*, optional path, not a replacement.

**Why it exists:** every PR that inserts a new section at the top of
`CHANGELOG.md` collides with every other open PR that also did — measured five
times in one session on 2026-08-03. Two PRs each adding a *different file* here
never collide, because there is no shared line range for git to conflict on.

**How to use it:** instead of editing `CHANGELOG.md`, add one file:

```
changelog.d/<ident>.md      # e.g. changelog.d/DIVE-2582.md
```

containing exactly what you would otherwise have typed at the top of
`CHANGELOG.md` — the file's first non-blank line must be a heading of the form:

```
## Unreleased — <type>(<scope>): <headline> (<ident>)
```

(a bare `## Unreleased` with no dash is also accepted), followed by the body
prose, same as today's convention.

**What happens to it:** `scripts/fold-changelog-fragments.sh` runs at release-cut
time (same place `scripts/stamp-changelog.sh` runs — the detached release
commit, never main), folds every fragment here into `CHANGELOG.md`'s top
(newest filename first), and removes the folded files *from that commit's
tree only*. Fragments are not deleted from main by this step — same
"Unreleased never clears off main" property `CHANGELOG.md` itself already has
(see the header of `scripts/stamp-changelog.sh`); this is not a new limitation.

**So how does the next cut not fold it twice?** It checks (DIVE-2702). A fragment
still sitting on main that is *byte-identical* to the copy the previous release
tag's parent carried has already shipped, so the fold skips it. Two consequences
worth knowing when you write one:

- Leaving your fragment on main after it ships is expected. Nothing to clean up.
- **Editing** a fragment after it shipped makes it new content, so it folds again
  and the entry appears in a second release's notes. If that is not what you want,
  write a new fragment instead of editing the shipped one.

**The heading is enforced, at the door and at the cut (DIVE-4177).** Both halves
exist because a fragment without that first line was silently *skipped* by the fold
and its entry never reached a release page — v0.29.0 published two entries and no
feature for a cut correctly derived MINOR from three `feat` commits, and v0.30.0
omitted the very commit that forced its own minor.

- **At PR time**, `scripts/lint-changelog-fragments.sh` runs inside the required
  `title` check: every fragment your PR adds or edits must start with the heading
  above, and a `feat`/`fix` PR must add a fragment at all (`test`, `ci`, `chore`,
  `docs`, `refactor` and `perf` only get a warning). It grades *your* files, not the
  whole directory, so nobody else's fragment can red your PR.
- **At cut time**, the fold now *refuses* rather than skipping: a malformed fragment
  fails the release instead of quietly dropping its entry. With the lint in place that
  is a tripwire, not a gate.

Locally, before you push:

```sh
git diff --name-only origin/main... \
  | bash scripts/lint-changelog-fragments.sh --title="$(git log -1 --format=%s)" --changed-from=-
```
