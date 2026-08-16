# 5dive CLI — contributor rules

## The test corpus is TIERED and BUDGETED IN WALL-CLOCK (DIVE-2525)

`tests/*.sh` went 96 → 267 harnesses in 13 days against four harness deletions
ever. A guard is bought once and paid for on **every future change, forever**,
while its benefit stays fixed — so the ledger tilts by construction and no single
decision to add one is ever wrong on its own merits. See
`community/wiki/guards-compound-in-cost-and-nothing-ever-retires-one.md`.

| tier | runs | budget |
|---|---|---|
| `core` (**the default**) | every PR, both CI environments | **300s** per job |
| `nightly` | `full-sweep.yml` — 03:17 UTC, dispatch, **every push to main** (DIVE-2667), and **every PR touching `build.sh`, `install.sh` or `src/**`** (DIVE-2789) | **1320s** per job, corpus split across 3 shards |

- **The PR trigger is ADVISORY. It does not block a merge**, and it is deliberately not
  a required context: it is paths-filtered, so it is absent from ~28% of PRs, and GitHub
  leaves a required check that never reports pending forever. A red there is a signal to
  read, not a gate. It also covers ONE axis — a regression in the harness corpus outside
  the core tier — and **not** the release path (`release-cut.yml` never runs on a PR) or
  the selfcheck probe class, which the corpus never reaches. Do not read "full-sweep runs
  on branches" as "a tree-level regression can no longer land behind a green PR".
- **The nightly tier is not a cheap subset**: 25% of the corpus by file count and **81%
  of it by wall-clock** (1210s of 1481s, measured DIVE-2789), because membership is
  selected on cost. Cost any plan that leans on the core/nightly split in seconds, not in
  files — `community/wiki/a-demoted-tier-is-not-a-cheap-subset-it-holds-almost-all-the-cost.md`.

- **A new harness is `core` unless you say otherwise.** Nothing to write.
- **Over budget, CI FAILS** (`exit 4`, distinct from a test failure's `exit 1`) and
  names the slowest files in the tier. Past the cap a new guard **replaces or
  merges** an existing one — that is the reverse gear, and it is the point.
- **A budget red confirms itself first** (DIVE-2592). PR #395 went red at 356s and
  green at 289s on the *same commit, no rebase* — a 67s swing, all of it in one
  network-priced harness. So when the sum comes in over, the runner **re-times the
  3 slowest files and keeps the smaller sample per file**: noise is one-sided
  (contention and a slow remote only *add* time), so the low sample is the least
  contaminated estimate, while real growth appears in both samples and survives.
  Paid only on the red path; a green run re-times nothing. `--confirm-top=0`
  disables it, which can only make the gate **stricter** — there is no flag that
  confirms more, and no CI job passes one.
- **A budget red says it is a budget red.** `exit 4` beside "0 failed" reads as
  systemic to the author and as flake to the next reader; it is neither. The
  message now states that no test failed, whether the number was confirmed twice,
  and **the smallest set of harnesses that covers the overage** — the actionable
  set, not the top-10 leaderboard.
- **Three ways out, in order:** merge by subject (hundreds of harness *files* for
  one CLI means the unit of organisation is the incident, not the subject —
  folding two files about one subject reclaims their setup cost and drops no
  assertion); retire a guard whose class can no longer occur; or demote:

  ```sh
  # TIER: nightly — 14.3s measured: does not fit the 300s PR core; the nightly sweep runs it.
  ```

  In the harness header (first 40 lines). **The reason is mandatory** — a bare
  `# TIER: nightly` is a refusal, not a default. Demotion moves the cost, it does
  not delete it, which is why it is third and why it must be argued in the diff.
- **Say WHERE you measured, and expect the number to be graded** (DIVE-2555). The
  runner compares every `Ns measured` claim against the clock in the run it is
  already doing: 10% under is reported with the replacement line, 50%-and-3s under
  is `exit 5` (its own code — the remedy is "correct a number", not "fix a test" or
  "retire a guard"). A figure with no environment on it cannot be refuted by the
  next reading, only silently disagreed with: one header claimed `300.0s` while
  the same file measured 335s and 378s on the control plane.
- **Editing a harness always runs it**, whatever its tier: the `changed-harnesses`
  job runs and verdict-probes every harness your diff touches. Tier membership is
  a default, and a default loses to an explicit signal.
- **The budget is spent in a RELATIVE unit** (DIVE-2728). PR #461 red-gated at 322s
  with 234 of 234 harnesses passing and a diff worth +0.1s, while unrelated files ran
  10-36% slower and the file the diff touched moved +0.3%. With 9% headroom against a
  10-36% platform draw, the cap had stopped measuring the corpus. So the runner now
  **times a small calibration workload in the same job** — process spawn, bash
  startup, the CLI's own startup, small file I/O, auto-sized to ~10s, min of 2 — and
  spends the cap in units of it. A uniformly slow VM scales both sides and cancels.
  - **Clamped to 100-150%.** The floor means a fast VM never *tightens* the agreed
    cap; the ceiling is the escape-hatch guard, because a cap that grows without
    limit with the runner draw licenses an arbitrarily larger corpus.
  - **Past the ceiling, or with a probe that cannot run, the verdict is
    UNDETERMINED — `exit 6`, never green and never `exit 4`.** "The corpus is over
    its cap" and "this box could not measure that cap" are different events with
    different remedies (re-run, not retire a guard). A *failing harness still exits
    1*: a slow box must never hide a broken test.
  - **Read the two percentages together.** Every run prints the run against the raw
    cap and against the effective one: **raw high + effective low = the VM was slow;
    both high = the corpus grew.** That separation is the deliverable.
  - Calibration time is **not** counted toward the total. `TIER_CAL_BASELINE_US` is
    graded against itself every run and says RE-BASELINE past 25% drift — a runner
    image change is exactly the event that moves it.
  - **The baseline is a CI number and carries its environment** (DIVE-2736): 119000,
    the median of six `ubuntu-latest` readings. The 173000 it replaced was measured on
    the control plane, and the failure that produced was **silent** — every CI probe
    read as a *fast* runner, the 100% floor clamped all six, and the relative budget
    stopped existing while still printing a ratio. **A local run now prints
    RE-BASELINE, and that is correct**; do not re-derive it from the box you are on.
  - **Two probes, one verdict** (DIVE-2736). A second probe runs *after* the corpus
    and **grades nothing** — it exists because on one run the probe read 30% fast
    while the corpus ran 90s slow, and nothing noticed a ratio whose halves moved in
    opposite directions. `cal_post_delta_pct` is signed; **post slower than pre** is
    the clean signal, because the corpus warms what the probe pays for and biases the
    second reading fast, so *agreement* is weak evidence rather than a clearance.
    `--no-cal-post` skips it. Across runs: `scripts/tier-cal-window.sh <reports…>`
    (normalises wall-clock to µs/harness first, or deleting a harness reads as
    anti-correlation).
  - **A stale `# TIER:` header is a CROSS-JOB verdict, not a per-job exit** (DIVE-3163
    → DIVE-3188). One box cannot separate a stale claim from a slow runner, so
    `run-harnesses.sh` only warns. The verdict lives in `tier-cal-window.sh`: the same
    named file `WRONG` on **>=2 distinct jobs** is a STALE CLAIM; one job is a stopwatch
    disagreement. Identity is `harvest_run_id`/`harvest_job` (every GitHub job is its own
    VM), never `--runner-id` — full-sweep passes none. `header-drift-window.yml` runs it
    nightly and lands the verdict on an issue; it **never reds**, because `release-cut.yml`
    refuses to cut on any red on main's tip. `--drift-strict` and `--drift-fatal=required`
    exist for humans and no workflow may pass either (`tests/header_drift_window_unit.sh`).
  - `--no-calibrate` grades against the raw cap (useful with no built bundle). The
    clamp floor is 1.0, so that is the **strictest** this gate gets, never a
    relaxation. `--cal-us=` / `--cal-baseline-us=` / `--cal-cli=` are harness seams;
    no workflow passes them, for the same reason no workflow passes `--budget`.
- Locally: `bash scripts/run-harnesses.sh --tier=core` (or `--tier=full`). Both
  budgets, the calibration constants and the tier marker live in `tests/lib/tier.sh`,
  one place.
- **The nightly is sharded, not given a bigger number.** The cap is per job, so
  splitting the sweep cuts each job's wall-clock without relaxing it. Aggregate
  capacity is 3 x 1320s and the shard count is fixed in the matrix, so adding a
  shard is as visible a policy decision as raising the ceiling. `budget-report`
  re-sums the shards and prints the **un-sharded** total, because that total is the
  number the tiering exists to make legible and sharding is how you lose it.

## Workflow files are linted, and the linter proves it fired (DIVE-2540)

`yaml.safe_load` **accepts** a workflow file that GitHub cannot parse — expression
substitution is a second layer on top of YAML, and it happens **before the shell
exists**, so an Actions expression template inside a `#` comment in a `run:` block
is still parsed.
That made `release-cut.yml` — the only writer of a version in this repo —
unparseable for 45 minutes on 2026-08-02 (DIVE-2539), and the run it produced said
only *"This run likely failed because of a workflow file issue"*.

- **`actionlint` is the only instrument that names it.** `.github/workflows/actionlint.yml`
  runs it on every PR and every push to main; `scripts/git-hooks/pre-push` runs the
  same script over the pushed revision when a push touches `.github/workflows`.
- Locally: `bash scripts/actionlint-scan.sh` (exit **0** clean, **1** findings,
  **2** *could not scan* — which is never a pass).
- **The scan self-tests before it trusts a clean result.** Every way this gate can
  break — missing binary, wrong flags, empty target set, a checker whose rule moved —
  presents as "no findings", so the same binary with the same flags must first reject
  `tests/fixtures/actionlint/canary-expression-in-run-comment.yml` *as an
  `[expression]` error* and accept the known-good fixture next to it. If it does not,
  the scan exits 2.
- **shellcheck integration is off for now** (`--with-shellcheck` turns it on). The
  tree emits three INFO findings today; a gate that is red on arrival gets disabled.
- **Never write the expression delimiter literally inside a `run:` block**, including
  in comments and error strings. At YAML level (`env:`, `with:`) it is a real comment
  and harmless. Full write-up:
  `community/wiki/an-actions-expression-is-parsed-inside-shell-comments.md`.

## Hard rule: no real PII in public artifacts (DIVE-1774)

Never put real user ids, emails, phone numbers, or customer PII in anything that
becomes public: PR titles/bodies, commit messages, release notes (`CHANGELOG.md`),
code, or tests. Use placeholders instead:

- Telegram / user ids → `1234567890` (or `<user-id>`)
- Emails → `user@example.com`
- Phones → `+1-555-0100`

This is enforced, not advisory. The `pii-guard` GitHub Action scans every PR
(title, body, commit messages, added diff lines) and the release notes against a
hashed denylist (`.github/pii-denylist.txt`); a hit **fails the check and blocks
merge**. Run it locally before pushing:

```bash
git diff origin/main | grep -E '^\+' | sed 's/^+//' | bash scripts/pii-scan.sh
bash scripts/pii-scan.sh CHANGELOG.md
```

To denylist a new identifier, add its hash (never the plaintext) — see the header
of `.github/pii-denylist.txt`.

> Exception: the commit **author** email `markounik@gmail.com` is intentionally
> public (it is the pinned commit-author identity — a readable authorship
> trail, NOT a deploy gate; measured, DIVE-3113) and is out of scope.
