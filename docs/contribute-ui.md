# Build the open control plane for an agent company

5dive runs a company of agents: teammates with roles, a shared task queue, approvals, an audit
trail, on a Linux box you own. The runtime is open. The control plane on top of it is early,
and that is the honest reason this page exists.

`5dive ui` today is four read-only views — the org chart, the queue, the gates waiting on a
human, and the signed event triggers. That is a real start and it is not much. The roster, the
live view of what every agent is doing right now, the record of what was approved and by whom,
the same views on a phone: the runtime already emits what those screens need. Somebody has to
build the screens.

**Today**, the whole thing, running on the box this page was written from:

![The org chart view of `5dive ui`, showing the agent tree and how many live handoffs had no human in the path](ui-today.png)

**Wanted:** the views below, and the ones you think of that we did not.

Showing what exists is deliberate. Nobody contributes to a screenshot that already looks
finished.

## Why this is worth your evening

If you are reverse-engineering a closed product to get this, you are doing the hardest possible
version of the work, on a codebase whose licence does not let you keep it, for a runtime you
cannot change.

Here, the runtime is the part that is already open. You are not reconstructing behaviour from
the outside. You can read exactly what the thing does, change it, and see your change run.

## What you get to own

- A real surface, not a toy. People run their companies on this.
- Scoped issues, each with the data source named, so the first hour is building rather than
  archaeology.
- The runtime underneath stays yours: tasks, agents, permissions, audit and execution are
  inspectable and forkable. A frontend you can fork is worth much less than a runtime you can.

## Start here

Run it first. Everything below makes more sense once the page is open in front of you:

```bash
git clone https://github.com/5dive-ai/5dive.git && cd 5dive
./build.sh              # the bundle is generated, not committed
5dive ui --data         # the JSON every view renders
5dive ui --port=9000    # the page itself
```

Never installed 5dive? [Quickstart](../README.md#quickstart) is a one-liner and a few minutes.

### The scoped issues

| | Issue | Size |
|---|---|---|
| Roster | [Every agent on the box, and whether it is working right now](https://github.com/5dive-ai/5dive/issues/1065) | M |
| Live view | [Poll `/data` and surface the runs in flight](https://github.com/5dive-ai/5dive/issues/1066) | M |
| Queue | [Group the board by status instead of one flat table](https://github.com/5dive-ai/5dive/issues/1067) | **S — good first issue** |
| Gates | [Show the answered gates, not just the open ones](https://github.com/5dive-ai/5dive/issues/1068) | M |
| Mobile | [There is no width breakpoint — make the four views work on a phone](https://github.com/5dive-ai/5dive/issues/1069) | **S — good first issue** |

Every one of them names **what you see, where the data comes from, what done looks like, and
roughly how big it is.** If an issue ever sends you into archaeology to find out where a number
comes from, that is a bug in the issue — say so in the thread and we will fix it.

Two of the five are labelled [good first issue](https://github.com/5dive-ai/5dive/labels/good%20first%20issue),
because two of them are. A page where everything is tagged beginner-friendly is a page where
nothing was measured.

### Where the code is

All of it is [`src/cmd_ui.sh`](../src/cmd_ui.sh), one file:

- `_ui_state_json()` builds the view state from the local SQLite store and serves it at
  `GET /data`.
- `_ui_html()` emits the page — inline CSS and JS, no build step, no CDN, because the single-file
  bundle is the only artifact we ship.

[CONTRIBUTING.md](../CONTRIBUTING.md) covers the dev setup, the bundle rule and how to run the
tests. [What the runtime exposes](https://5dive.ai/docs/5dive-cli) is the CLI reference.

### Two lines this UI does not cross

1. **Read-only by construction.** The server answers `GET` and `HEAD` on exactly three paths and
   returns 405 for everything else, so no amount of client-side code can make it write. Anything
   that mutates state already has a CLI verb; this UI's job is to make the org layer *visible*.
2. **One host.** Every query reads the local store. There is no cross-box roll-up here, on
   purpose.

Both are argued at the top of `src/cmd_ui.sh`. A change that needs either one relaxed is worth
opening an issue about before you build it — not a no, but a conversation.

### Come argue with us

[Discord](https://discord.gg/aU2UQC9Myy). Bring the disagreement; the design notes in
[`docs/`](.) are where most of ours are already written down.
