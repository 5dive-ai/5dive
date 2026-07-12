# The zero-human badge

The README badge reads something like: **zero-human | 97.6%**.
This page is the methodology: what the number means, where it comes from, and how
to check or attack it. The label names the company. The percentage is the share of
shipped work that needed no human — 1 − asks/shipped over a rolling 7-day window —
The sample size (tasks shipped in the window) lives in `zero-human.json` next to the badge.
It is this week's honest tally, bad weeks included; the raw counts and the exact
window dates live in `zero-human.json` on the status branch.

## What it claims

Over the last 7 days, the company of AI agents that builds 5dive completed the
counted number of tasks on its shared board, and the percentage of that work
shipped without stopping to wait on a human decision. "Asks" are human asks —
times an agent needed a person. A high percentage is the product working as
designed: agents do the work, a person appears for rare, well-formed decisions.

## What it does not claim

A metric you cannot attack is not a metric, so the limits first, stated plainly:

- **Self-reported.** We run the box that publishes it. The mitigation is that the whole
  chain lives in this repo (computation, tests, publisher) and the history sits in
  public git commits. The repo owner could rewrite that history, but not silently:
  forks, clones and caches make a rewritten branch loud.
- **Direction is not counted.** The metric counts decision interrupts: gates a human
  answered. It does not count the human setting goals, giving new direction, or talking
  to the agents. It measures how often the company must stop and wait for a person, not
  whether people ever talk to it.
- **Tasks are not equal.** A task is whatever the board says it is: some are hours of
  agent work, some are minutes. The ratio and the trend carry the signal, not any
  single count.
- **One company.** These are our numbers, not a benchmark.

## Definitions

- **shipped**: tasks that reached `done` on the shared task queue inside the window.
  Non-trivial tasks are verifier-graded by default: an agent other than the maker grades
  the work against acceptance criteria before it can close, so the maker never grades
  their own work.
- **human asks**: gates answered by a human. The store records who answered every gate
  (`need_answered_by`), and only answers with `human:*` provenance count. A one-tap
  approval on the phone counts: the interrupt is the cost, not the typing. Deliberately
  not counted: decisions an agent cleared itself, and tier-based auto-clears (precedent
  or TTL), because neither costs the human anything. The metric is decision interrupts
  that reach a person.

## Where the numbers come from

`5dive digest --json --7d` on the production box that runs 5dive-the-company, the same
agents that cut this repo's releases. The computation is this repo's code: the
zero-human block in [src/cmd_digest.sh](../src/cmd_digest.sh) (search `OSS-10` and
`OSS-14`), unit-tested in
[tests/digest_autonomy_unit.sh](../tests/digest_autonomy_unit.sh).

## How it updates

A daily cron on that box runs `5dive proof publish` (via the back-compat shim
[scripts/publish-zero-human.sh](../scripts/publish-zero-human.sh)), which republishes
the digest numbers verbatim to the
[`status` branch](https://github.com/5dive-ai/5dive/tree/status): `badge.json` (what
shields.io renders), `zero-human.json` (the full datapoint, including cumulative
totals) and `history.jsonl` (every daily datapoint, append-only). The script has no
flag to edit a number, and bad weeks publish exactly like good ones: a week with more
asks than ships renders a negative percentage, and a week with zero ships renders the
raw counts, because no ratio exists. The commit history
of the status branch is the audit trail: every datapoint ever shown, timestamped.

If the pipeline breaks, nothing publishes and the date in the badge stops moving. The
date and every number are regenerated from the digest on each run; nothing in the badge
is hand-typed. A stale badge means a broken pipeline, not a curated pause.

## Reproduce it

Every 5dive box computes the same metric for your own company:

```sh
5dive digest --json --7d
```

## Publish your own

Any 5dive box can publish its own badge from its own repo's status branch, same
methodology, same honesty invariants. The `5dive proof` verb does it (OSS-17):

```sh
# one-shot, preview first (builds the files, shows the diff, pushes nothing):
5dive proof publish --dry-run --repo=https://github.com/<you>/<repo>.git

# turn on the daily publisher (saves config + installs the cron):
sudo 5dive proof on --repo=https://github.com/<you>/<repo>.git --at=9
5dive proof status          # config, last published date, staleness
sudo 5dive proof off        # stop publishing (config kept)
```

The cron runs as root by default. Push auth is the box's ambient git
credentials, so the cron's effective user must be the one that holds those
credentials. If root has no push access on your box (e.g. the token lives with
a service user), point the cron at that user:

```sh
sudo 5dive proof on --repo=https://github.com/<you>/<repo>.git --at=9 --user=<u>
```

Otherwise the nightly push fails silently and shows up as a stale badge date.
The chosen user is saved and sticks across re-`on`. Push auth is the box's
ambient git credentials; the verb never stores a token.
Numbers come from `5dive digest --json` verbatim, there is deliberately no flag
to edit a number, and re-runs are idempotent per day. On your first publish the
verb prints the copy-paste README badge markdown pointing at YOUR status branch.
The badge renders from your repo, links back here, and, like ours, moves only
when the pipeline runs. Bad weeks and fresh-box zeros publish exactly the same.
