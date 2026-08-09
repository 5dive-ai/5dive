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
