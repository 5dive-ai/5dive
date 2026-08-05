## Unreleased — fix(objective): the planner could not see that its own task was dead (OSS-37)

`task reject` at `max_iterations` does not close or reopen the row. It writes the
feedback, files a `manual` gate on a human, and returns — so the task stays **open**
at `status='blocked'`.

The objective planner reads its open originated tasks as a status column, where that
row renders `(blocked, high)` — byte-identical to a task blocked on a sibling
dependency, which is a row you wait for. So the planner waited. A task whose whole
maker→verifier budget is spent counted as in-flight progress, cycle after cycle, and
the objective re-planned around work that was never coming: the "just parks" failure
OSS-19 phase A2 names.

Nothing was broken enough to report. The gate reached a human, the loop stopped
bouncing, the audit row was written — every mechanism did its job, and the only
casualty was the one reader that had no way to ask.

The injected context now marks such a row `** STUCK: verifier rejected it N/Nx, the
loop is spent **`, and names the unanswered human gate when one is parked on it. The
contract tells the planner what that obliges: re-plan around it — cancel it (it is
its own) and/or originate a smaller approach — and that the human gate is **not**
its to clear, answer, or wait on.

The predicate itself moved to `_task_stuck_loop_pred` (`lib/tasks_db.sh`), which
`task loops --stuck` / `--escalate-stuck` and the planner now BOTH call. The first
draft of this change re-typed it inline and the commit message claimed "one definition
serves board and planner" — it did not. Two textual copies that agree today buy
*does-not-currently-drift*; only a shared definition buys *cannot-drift*, and the two
are indistinguishable on the day you write them. The copies were not even identical:
the inline one dropped `AND status NOT IN ('done','cancelled')` because the local
`WHERE` already covered it, which is exactly how a second copy starts. This repo had
already written the lesson down 300 lines away (DIVE-1963, `_gate_bind_slug` in
`cmd_push.sh`: "they agreed, but that is parallel derivation").

The property is now graded rather than asserted: a test arm overrides
`_task_stuck_loop_pred` with a never-true predicate and requires BOTH consumers to go
dark. A consumer that re-typed it would be untouched by the override and stay marked.

Read-only: this changes what the planner is **told**, not what it may **do**. Every
anti-Goodhart guard is untouched — cancel/reprioritize stay restricted to the
objective's own originated tasks, origination still rides the count checkpoint, and
a T2 create still gates hard.

