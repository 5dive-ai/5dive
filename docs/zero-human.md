# The zero-human badge

The README badge reads something like: **zero human | 7d: 127 shipped, 3 asks**.
This page is the methodology: what the numbers mean, where they come from, and how
to check or attack them. The label names the company; the numbers are this week's
honest tally, bad weeks included. "Asks" are human asks — times an agent needed a
person; the exact window dates live in `zero-human.json` on the status branch.

## What it claims

Over the last 7 days, the company of AI agents that builds 5dive completed that many
tasks on its shared board, and stopped to wait on a human decision that many times.
That ratio is the product working as designed: agents do the work, a person appears
for rare, well-formed decisions.

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

A daily cron on that box runs
[scripts/publish-zero-human.sh](../scripts/publish-zero-human.sh), which republishes
the digest numbers verbatim to the
[`status` branch](https://github.com/5dive-ai/5dive/tree/status): `badge.json` (what
shields.io renders), `zero-human.json` (the full datapoint, including cumulative
totals) and `history.jsonl` (every daily datapoint, append-only). The script has no
flag to edit a number, and bad weeks publish exactly like good ones. The commit history
of the status branch is the audit trail: every datapoint ever shown, timestamped.

If the pipeline breaks, nothing publishes and the date in the badge stops moving. The
date and every number are regenerated from the digest on each run; nothing in the badge
is hand-typed. A stale badge means a broken pipeline, not a curated pause.

## Reproduce it

Every 5dive box computes the same metric for your own company:

```sh
5dive digest --json --7d
```

Publishing your own badge from your own box is on the [roadmap](../ROADMAP.md).
