# The board read contract (`5dive board`)

**Status:** accepted, version 1. Decided on DIVE-4779 step 1, 2026-09-21.
**Supersedes:** nothing. **Blocks:** DIVE-4779 steps 2–4, and arm 1 of the open-runtime campaign.

## The problem this decides

`5dive ui` is leaving core to become a standalone plugin (`5dive-ai/5dive-ui`), so that an outside
developer can fork, run and send a PR to the control plane without cloning 121k lines of core. The
port exists (PR #1, +1445) and is not installable, for one reason: **it does not read core through a
seam at all.** It opens core's private sqlite store and issues five queries naming `tasks`,
`agents_org`, `event_triggers`, `event_deliveries` and roughly thirty columns — two of them derived
expressions (`handoff_state`, `gate_live`) that exist nowhere but inside those query strings.

That coupling is a **string**. Nothing in core can see it break: not a compiler, not `declare -F`,
not a test in either repo. Rename a column in core and the plugin keeps building, keeps installing,
and fails in a browser. Advertising `plugin add` before this is settled converts a reviewable risk
into a silent fleet-wide one.

## The decision

**Core owns the DOCUMENT. The plugin owns the PRESENTATION.**

`5dive board` emits one versioned JSON document describing this host's board. A consumer renders it
and never opens the store.

```
$ 5dive board --contract-version
1
$ 5dive board --json | jq -c '.data.contract'
{"name":"5dive.board","version":1}
```

**Document keys (version 1):** `contract{name,version}`, `scope`, `store`, `host`, `generated_at`,
`org[]`, `queue[]`, `gates[]`, `flows[]`, `triggers[]`, `deliveries[]`, `stats{}`. This is
byte-for-byte what `5dive ui --data` and `/api/state` already served; the only addition is
`contract`. There is one producer (`_board_state_json`), so while both the in-core UI and the plugin
UI exist they cannot disagree about what a board is.

**Versioning.** The integer moves on a **break** — a field removed, renamed, or retyped — and never
on a **growth**: new fields are additive and leave it alone. A consumer pins the versions it
understands and refuses an unknown one by name. Every change to the document's shape owes an entry
in the log at the bottom of this file; `tests/board_contract_unit.sh` reds if the constant in
`src/cmd_board.sh` and the number here disagree.

**Negotiation is one exec, and it happens before the browser.** `--contract-version` prints the bare
integer and reads no store at all — deliberately, because a consumer must be able to ask on a box
whose store is absent, unreadable or mid-migration, which are exactly the boxes where getting the
answer wrong costs most. A box too old to carry the verb fails the exec, which is the same answer in
the same place.

## The alternatives not taken

### A published read-only SQL view — REFUSED

The shape the row named first. It **renames the coupling instead of removing it**: the plugin still
opens `tasks.db` directly, so it still needs the path, the `sqlite3` binary, read permission on a
`640 root:claude` file, and the box's migration state. Column names stabilise; nothing else does.

The fatal part is the last of those. **A view arrives by migration, and a migration is exactly what
an installed box may not have run.** A plugin on a box whose core predates the views discovers that
by returning `no such table` into a browser at request time — and there is no way to *ask* a view
which contract it serves without already being able to read the store, so the discovery cannot be
moved earlier. That is DIVE-2512's class of failure, shipped to every box at once. Version 1's
`--contract-version` exists precisely to make that class unreachable.

A view also cannot carry `flows`, which is derived in bash from `queue` and `org` after the queries
run, so the plugin would still have to reimplement a piece of core's semantics.

### A schema-version floor over the plugin's own SQL — REFUSED

Core publishes a schema version; the plugin keeps its five queries and asserts a floor at startup.
Cheapest to build, and it **detects** drift instead of **removing** it: the thirty-column coupling
survives intact, and every core schema change still has to reason about a consumer in another repo.
It converts a silent break into a loud one, which is worth something — so the loud-refusal half was
kept, as `--contract-version`, on top of the seam that removes the coupling rather than instead of it.

### Keeping the UI in core — REFUSED

Not seriously in contention, but worth writing down as the thing being bought: it is the status quo
the axis rejects. A contributor who wants to change a layout clones 121k lines.

## The objection this decision has to answer

*"If core owns the document, a contributor who wants a new field must still PR core — which is what
the move was meant to avoid."*

**It is the right boundary, and the trade is the whole win.** A new field is a new *fact about the
board*, and the board is core's data model; the plugin cannot invent one. What the move was meant to
avoid is cloning core to change a layout, a route, a render, a stylesheet or an interaction — and
under this contract every one of those is 100% plugin-side. The residual core work is an additive
one-liner in a documented place, reviewed by people who already own that data. Trading *"every UI
change needs a core clone"* for *"a new field needs a core one-liner"* is the trade being made
deliberately.

Second objection, on cost: shelling out per request. The plugin already spawns `sqlite3` five times
per request and then runs the `flows` derivation in bash. One `5dive board` exec replaces all six.
It is cheaper, not dearer.

## What this unblocks, in order

2. The plugin drops its five queries and its SELECT-only DB reader for one `5dive board` call, pins
   `contract.version`, and refuses an unknown version with a message naming both numbers. **It cannot
   be proven installable until a core release carrying `board` is on the box** — the verb is not in
   any cut release as of this decision.
3. `ui` leaves `FIVEDIVE_BUILTIN_VERBS` and the `main.sh` case table behind the moved-verb shim.
   Must not land before step 2's install is proven, or a box loses the UI with nothing to replace it.
4. The contributor page and issues #1065–#1069 move to the plugin repo, leaving a one-line pointer.

## Change log

| Version | Date | Change |
|---|---|---|
| 1 | 2026-09-21 | Initial contract. The document `5dive ui --data` already served, plus `contract{name,version}`. |
