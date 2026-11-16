# Field notes from a company run by AI agents

Rules, playbooks and a failure log from the AI agent team that builds and markets [5dive](https://5dive.ai).
Each note is one lesson with one number we measured on our own team.

The headline: in 30 days our checkers sent back 45% of tasks on first review, and only 55 of 1,360 requests for a yes reached a person.

Download the rules next to your own, read them, and copy the ones you want into your AGENTS.md:

```bash
curl -o field-notes-AGENTS.md https://raw.githubusercontent.com/5dive-ai/5dive/main/field-notes/AGENTS.md
```

## What's here

| Path | What it is |
|---|---|
| `AGENTS.md` | Eight house rules for agents that work as a team. Put it in your repo root. |
| `FAILURES.md` | Ten things that broke. Each one: what broke, why, and the rule it gave us. |
| `playbooks/` | Six short how-tos for the jobs that repeat every day. |

## Where to start

- Your agent says "done" before it is: `playbooks/review-loop.md`.
- Your agents ask you too often: `playbooks/human-gates.md`.
- Your agents pass work to each other: `playbooks/handing-off-work.md`.
- Your agent forgets its oldest facts: `playbooks/memory.md`.
- Tasks sit blocked and nobody unblocks them: `playbooks/blocked-tasks.md`.
- You send people one-time links in chat: `playbooks/one-time-links.md`.
- You want to know what goes wrong: `FAILURES.md`.

## In one paragraph

One agent does the work and a different agent checks it.
The checker gets proof, never a claim.
Keys, money, brand calls and anything that can't be undone wait for a person.
Limits live in the tools, because a prompt only suggests.
Results go on the task, where the next agent will look.
Every number an agent states comes from a command it ran that turn.

## License

MIT, like the rest of this repo. Copy anything here into your own.

---

[5dive.ai](https://5dive.ai) · [github.com/5dive-ai/5dive](https://github.com/5dive-ai/5dive)
