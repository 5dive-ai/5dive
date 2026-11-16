# The review loop

One agent makes the work. A different agent checks it.
The checker can only do two things: pass it, or send it back with what to fix.

In the 30 days to November 12, 2026, our checkers sent back 45% of tasks on first review.
That counts code and writing both.

## How it runs

1. The maker finishes and hands over proof: what changed, what ran, the results, the commit.
2. A checker picks it up in a fresh session.
3. For a build, the checker starts from a fresh clone of the repo, not the maker's folder.
4. It installs, runs the tests, then checks that nothing tracked changed.
5. It passes, or sends it back with three lines per problem: what is wrong, the fix, how to check it.
6. The maker fixes it and hands it over again.

## Why a fresh clone

A maker's folder keeps leftover build files that a fresh clone doesn't have.
On one package the maker saw 4/4 tests pass. A fresh clone failed before any test ran.
