# Contributing to 5dive

Thanks for the interest. This is a solo-maintained project — reviews can be
slow, and not every idea will land. If you're planning more than a small
fix, open an issue first so we can sanity-check fit before you sink time
into it.

## Scope

5dive's core mission is **spawning and managing AI coding agents on a
host**. Features that directly serve that (new agent types, better
isolation, better visibility into running agents, smoother install/upgrade)
are in scope. Features that drift into adjacent territory — full IdP,
package registries, monitoring stacks, GUI installers — usually aren't,
and we'll point at upstream tools instead. If you're not sure, ask in an
issue before building.

## Dev setup

Requirements:

- Linux host (Ubuntu/Debian-flavoured tested; other distros likely work
  but the installer assumes apt).
- `bash` 4.x+, `bun` (for the UI), `git`.
- Optional: a throwaway VM if you're touching the install path — see
  Testing below.

Clone and build the CLI bundle:

```bash
git clone https://github.com/5dive-ai/5dive.git
cd 5dive
./build.sh        # concatenates src/ into the single-file `5dive` bundle
bash -n 5dive     # syntax-check the bundle
```

## Project layout

```
src/              # CLI source — split for readability
  header.sh       # set -euo pipefail, globals, declare -A maps (must be first)
  lib/*.sh        # error_codes, output, validation, state/audit/registry, agent_setup
  cmd_*.sh        # one file per top-level subcommand
  main.sh         # usage(), main(), EXIT trap (must be last)
5dive             # built bundle — committed, kept in sync with src/ by CI
install.sh        # one-liner installer fetched by curl
systemd/          # unit files installed for agents
hooks/            # shell hooks the CLI drops into the user's $HOME
docker/           # demo container for tire-kickers
skills/           # agent skills installed alongside the CLI
.github/workflows # CI
```

See the README's **Contributing** section for the rationale behind the
single-file bundle and `./build.sh`.

## The bundle rule (please read)

`./build.sh` concatenates `src/` into the committed `5dive` bundle. **Both
files are tracked** — CI's `bundle-drift` job runs `./build.sh && git diff
--exit-code 5dive` and fails any PR where they disagree. Two rules:

- Edit `src/`, never the bundle. The bundle is generated.
- After editing `src/`, run `./build.sh` and commit the regenerated `5dive`
  in the same PR.

If `bundle-drift` fails, you forgot the rebuild. Run `./build.sh`, commit,
push again.

## Testing

Lightweight checks (always run before opening a PR):

```bash
./build.sh        # rebuilds the bundle
bash -n 5dive     # bundle syntax check
```

Heavyweight smoke test: if you touched `install.sh`, `src/cmd_agent.sh`,
`src/lib/agent_setup.sh`, or anything else on the agent-create path, a
maintainer will run a full-VM smoke (provisions a real cloud box, runs the
agent matrix, purges) before merging. Flag the affected path in the PR
description so it doesn't get missed.

If you have a throwaway VM of your own, the manual equivalent is: run
`install.sh` against a fresh box, then `5dive agent create test --type=claude`
and `5dive doctor`. Anything red there is what the smoke test would have
caught.

## Pull requests

- One concern per PR. Reviewers spend more time on a 200-line PR with mixed
  concerns than on two 100-line PRs.
- Commit message style follows the existing log. Skim `git log --oneline`
  for the pattern — typically a short prefix (`cli:`, `ui:`, `docs:`,
  `install:`, `build:`) followed by a one-line summary, then a paragraph
  on the *why* if it isn't obvious.
- No `--no-verify` on commits — CI runs the same checks anyway, you'll
  just learn about the failure later.
- Don't bump the version in your PR. `FIVE_VERSION` is bumped at release
  time, not per-merge.

## Reporting bugs / requesting features

Open a GitHub issue. For security issues, use [GitHub's private vulnerability
reporting](https://github.com/5dive-ai/5dive/security/advisories/new) —
**do not** open a public issue for a vulnerability.

## License

By contributing, you agree your contributions are licensed under the
project's [MIT license](LICENSE).
