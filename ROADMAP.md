# Roadmap

5dive's north star: **run a company of AI agents with humans only where humans are
genuinely needed.** Agents do the work; you appear for rare, well-formed, tamper-evident
decisions on your phone. Every item below is judged by one metric: fewer human touches
per unit of shipped work, without losing auditability.

No dates, no promises of order. Things ship when they're solid. Open an issue if you
want something pulled forward; real usage reports move items up the list.

## Reliability first

- [x] Unit test suite runs in CI on every PR (July 2026)
- [ ] Coverage expansion: task queue verbs, agent lifecycle
- [ ] `CONTRIBUTING.md` + contributor docs (build flow, bundle rule, test harness pattern)
- [ ] Internal refactors of the largest modules so contributions land on clean seams

## The company plans itself

- [ ] `5dive goal add "<outcome>"`: a planner agent decomposes a goal into tasks with
      dependencies, routes them through the org chart, and re-plans on failure
- [ ] Dependency-aware scheduling: the heartbeat wakes the critical path first
- [ ] Tasks without an assignee route by role, not to whoever filed them
- [ ] `5dive project show` renders the dependency graph at a glance

## Human gates 2.0

- [ ] Decision memory: past answers become precedent, so you are never asked the same
      question twice
- [ ] Gate SLAs: an unanswered gate escalates instead of silently blocking a lane
- [ ] One inbox for every open gate across all your boxes
- [ ] The zero-human KPI: human-touches-per-week in the daily digest, trending down
- [ ] Weekly autonomy report: "your company ran 7 days, shipped N tasks, asked you twice"

## Work that proves itself done

- [ ] Verifier-graded acceptance as the default for non-trivial tasks (maker never grades
      their own work)
- [ ] Supervisor recovery: restart, nudge, or escalate stuck agents automatically, every
      action logged
- [ ] Supervision for every runtime, not just Claude
- [ ] Enforceable per-loop token budgets

## Memory that compounds

- [ ] New agents inherit team memory on first boot: hire someone who already knows the company
- [ ] Memory hygiene in `5dive doctor`: stale facts, broken links, duplicates
- [ ] Opt-in, human-reviewed memory sharing for published agent packs (never automatic)

## An open ecosystem

- [ ] Agent packs: export a whole agent (skills, hooks, prompt) as a portable, versioned
      archive; import someone else's
- [ ] `5dive hire <role>` from the public character registry: open market to employed
      teammate in one command
- [ ] One company across many boxes: tasks, org chart, and gates span your whole fleet
- [ ] Every agent carries a portable identity card and a verifiable work history

---

The CLI stays one MIT binary with no open-core split. Everything here ships to
self-hosters the same day it ships to the managed platform.
