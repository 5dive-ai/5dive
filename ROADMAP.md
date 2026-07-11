# Roadmap

5dive's north star: **run a company of AI agents with humans only where humans are
genuinely needed.** Agents do the work; you appear for rare, well-formed, auditable
decisions on your phone. Every item below is judged by one metric: fewer human touches
per unit of shipped work, without losing auditability.

Most of the first wave is now live. Checked items ship in the CLI today; open boxes link
to a tracked issue, so you can see what is coming and shape it. No dates, no promises of
order: things ship when they're solid. Comment on an issue to pull it forward, or open a
new one; real usage reports move items up the list.

## Reliability first

- [x] Unit test suite runs in CI on every PR
- [x] Coverage expansion: task queue verbs, agent lifecycle, gates, heartbeat, digest
- [x] `CONTRIBUTING.md` + contributor docs (build flow, bundle rule, test harness pattern)
- [x] Modularize core internals so contributions land on clean seams

## The company plans itself

- [x] `5dive goal add "<outcome>"`: a planner agent decomposes a goal into tasks with
      dependencies, routes them through the org chart, and re-plans on failure
- [x] Dependency-aware scheduling: the heartbeat wakes the critical path first
- [x] Tasks without an assignee route by role, not to whoever filed them
- [x] `5dive project show` renders the dependency graph at a glance

## Human gates 2.0

- [x] Decision memory: past answers become precedent, so you are never asked the same
      question twice
- [x] Gate SLAs: an unanswered gate escalates instead of silently blocking a lane
- [ ] One inbox for every open gate across all your boxes (#15)
- [x] The zero-human KPI: human-touches-per-week in the daily digest, trending down
- [x] Weekly autonomy report: "your company ran 7 days, shipped N tasks, asked you twice"

## Work that proves itself done

- [x] Verifier-graded acceptance as the default for non-trivial tasks (maker never grades
      their own work)
- [x] Supervisor recovery: restart, nudge, or escalate stuck agents automatically, every
      action logged
- [ ] Supervision for every runtime, not just Claude (#16)
- [ ] Enforceable per-loop token budgets (#17)

## Memory that compounds

- [x] New agents inherit team memory on first boot: hire someone who already knows the company
- [x] Memory hygiene in `5dive doctor`: stale facts, broken links, duplicates
- [ ] Opt-in, human-reviewed memory sharing for published agent packs, never automatic (#18)

## An open ecosystem

- [x] Agent packs: export a whole agent (skills, hooks, prompt) as a portable, versioned
      archive; import someone else's
- [x] `5dive hire <role>` from the public character registry: open market to employed
      teammate in one command
- [ ] One company across many boxes: tasks, org chart, and gates span your whole fleet (#19)
- [x] Every agent carries a portable identity card and a verifiable work history

---

The CLI stays one MIT binary with no open-core split. Everything here ships to
self-hosters the same day it ships to the managed platform.
