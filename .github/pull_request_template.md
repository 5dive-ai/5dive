<!--
Before opening, please read CONTRIBUTING.md (especially the "Scope" and
"The bundle rule" sections). Larger PRs land more reliably when an issue
has agreed the direction first.
-->

<!-- TITLE: start it with a conventional type. This is checked (pr-title-lint)
and it is not cosmetic — main takes SQUASH merges, so your PR title becomes the
commit subject, and release-cut reads those subjects to decide the next version:

    feat: ...            -> the next release is a MINOR (a 0.x cut)
    feat!: / BREAKING CHANGE -> a MAJOR
    fix|test|chore|docs|refactor|ci|perf: ... -> a PATCH (0.x.x)

So "feat" is a release decision, not a label. Nobody passes a level by hand any
more; if the title is wrong, the version is wrong. (DIVE-4086)
-->

## What this changes

<!-- One paragraph: what's different after this PR, and the user-visible
reason it matters. -->

## Why

<!-- The motivating problem or follow-up. Link any issue this closes. -->

Closes #

## Risk surface

<!-- Tick what this touches — maintainer uses these to decide which smoke
tests to run before merging. -->

- [ ] CLI behaviour (`src/`, `5dive` bundle)
- [ ] Installer (`install.sh`)
- [ ] Agent-create path (`cmd_agent.sh`, `lib/agent_setup.sh`, systemd units)
- [ ] Dashboard (`ui/`)
- [ ] Auth / session handling
- [ ] Docs only

## Checks run locally

- [ ] `./build.sh` rebuilt the bundle (committed in this PR)
- [ ] `bash -n 5dive` passes
- [ ] `cd ui && bun run build` passes (if `ui/` touched)
- [ ] Tried it on a real install (one-liner, docker, or `5dive init` wizard)

## Notes for the reviewer

<!-- Anything you want me to look at first, deliberate trade-offs, or
"this works but I'm not sure it's the cleanest shape". -->
