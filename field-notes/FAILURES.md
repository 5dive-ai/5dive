# Failure log

Ten things that broke on our agent team.
Each one: what broke, why, and the rule it gave us.

## 1. Every health check said fine. The agent did nothing for four days.

**What broke.** One agent finished nothing for four days while 20 tasks queued behind it.

**Why.** Its model quota had run out.
Six health checks watched whether it was running. None watched what it finished.
A person spotted it by looking at the queue.

**Rule.** Alert on output, like tasks closed per day, not only on whether the process is up.

## 2. 933 green tests, and the plugin could not load

**What broke.** A pull request put a broken import line in our chat plugin's main file.
Released, it would have cut every agent's Telegram chat on its next start.

**Why.** The tests covered small modules only. Nothing ever loaded the main file.
The reviewer caught it in review, before release, by building the file.

**Rule.** CI builds every entry point, however small the change.

## 3. The maker and the checker ran the test the same wrong way

**What broke.** Both ran a new test file by hand and got 12/12. The checker passed it.
CI was red on eight checks on the same commit.

**Why.** The test named a test tier that doesn't exist.
Running the file by hand skips the step that decides what CI runs.

**Rule.** Grade through CI's own entry point, and treat zero tests run as a fail.

## 4. A finished report sat in a folder for 28 hours

**What broke.** An approved change waited 28 hours.
The report it waited on was written 13 minutes after the approval.

**Why.** The report went into a file in the writer's own folder.
Three other agents kept reading the task as blocked.

**Rule.** Results go on the task itself, where the next agent looks.

## 5. "Stop" written into a task did not stop the agent on it

**What broke.** "Parked, stop" was added to a task about 3 minutes after an agent started it.
The agent built about 700 lines anyway.

**Why.** An agent reads the task text once, when it starts.

**Rule.** To stop a running agent, change the task's state or message the agent directly.

## 6. A safety guard that never let go

**What broke.** A guard fired 56 times and let go zero times.
One session made 2,120 API calls for seven tasks.

**Why.** Its condition stayed true from turn to turn.
The fix had been released but never installed.
It is fixed now: our hosts run a later release that has it.

**Rule.** Give every guard a limit, count its releases as well as its fires, and check the fix is running.

## 7. An agent told others the wrong time for hours

**What broke.** An agent said it was "roughly 05:00 UTC" in messages to others. It was 22:20 UTC.

**Why.** A number you never measured feels remembered, so you never doubt it.

**Rule.** Every time, count or version an agent states comes from a command it ran that turn.

## 8. A rule in the handbook never reached the keystroke

**What broke.** Our handbook told agents to use a flag that skips the question when they had a recommendation.
In 346 questions, agents used that flag zero times.

**Why.** An agent reads a policy when it thinks about that topic.
The act happens mid-task, at one flag.

**Rule.** Enforce a rule at the act itself, with a refusal that names the way out.

## 9. The lightest user of a shared budget lost the most

**What broke.** A daily loop failed three days in a row. Its budget was already spent.

**Why.** It drew on the same budget as the engineering agents.
Four of them used 98.7% of it.

**Rule.** Give scheduled loops their own budget, or keep a share back for them.

## 10. Agents acted without looking at what they acted on

**What broke.** In one night, an auto-merge landed while tests were still running.
A task proposed pushing 220 local branches to our public repo.

**Why.** Each agent assumed what guards the thing, what else writes to it and what is in it.

**Rule.** Before you act on something, check those three.
