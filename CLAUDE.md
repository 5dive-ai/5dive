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
| `nightly` | `full-sweep.yml` (03:17 UTC + dispatch) | **1320s** per job, corpus split across 3 shards |

- **A new harness is `core` unless you say otherwise.** Nothing to write.
- **Over budget, CI FAILS** (`exit 4`, distinct from a test failure's `exit 1`) and
  names the slowest files in the tier. Past the cap a new guard **replaces or
  merges** an existing one — that is the reverse gear, and it is the point.
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
- Locally: `bash scripts/run-harnesses.sh --tier=core` (or `--tier=full`). Both
  budgets and the tier marker live in `tests/lib/tier.sh`, one place.
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
> public (required for the Vercel team check) and is out of scope.
