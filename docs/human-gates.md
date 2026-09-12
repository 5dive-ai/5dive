# Human gates: who reads a gate first, and whose bot rings

A human gate is a manual step counted against the autonomy number. A gate the box
could have cleared itself is therefore not a neutral cost — it is a regression in
the thing the fleet is measured on. Three mechanisms decide whether a person is
interrupted, and each one is a separate knob.

## 1. A secret you MINT is not a secret a person ISSUES

`--type=secret` is tier 2 by type, because the historical secret gate asks a human
for a credential only they can create (a Stripe key, an OAuth token). A value we
generate ourselves and place with credentials the box already holds is the
opposite shape, and it pages a person for no decision at all.

Declare it:

```bash
5dive task need DIVE-1234 --type=secret --self-minted \
  --secret-key=MARKETPLACE_REVALIDATE_SECRET --connector=vercel \
  --ask="Mint the revalidate token now, or wait for the next cut?"
```

The gate routes tier 1 — a lead review — instead of to the paired human. It is
**declared, never inferred**: the ask text is not read for phrases like "invent any
random string", because guessing a gate AWAY from a human is a far worse failure
than the keyword floor's habit of guessing one toward a human.

`--self-minted` lifts exactly one floor. A self-minted secret whose ask also asks
to spend money (`--needs=spend_authority`) is floored on *that* and still reaches
the person. It is refused, not ignored, on a gate type that has no secret value to
describe.

## 2. Every human-bound gate lands on the lead first

A tier-2 gate's **phone ping** is held for up to 30 minutes. The row itself is
written, blocked and pending before the hold: it is on the dashboard, in
`5dive task inbox`, in `5dive task queue`, and answerable by `5dive task answer`
the whole time. Only the buzz waits.

The hold closes early when the lead acts — clears the gate, withdraws it, or
forwards it — and the filer's explicit urgency (`--urgent`, or `priority=urgent`)
skips it outright, unchanged.

The lead's one exit:

```bash
5dive task need DIVE-1234 --escalate
```

No other flags. The gate keeps its ident, its ask, its recommendation and its
history; the tier goes to 2, the reason is recorded as `axis=lead-escalated`, and
the ping fires immediately (a gate a lead has already read does not need a second
window in front of it). Authorized on the trusted unix identity — the gate's
filer, their lead, the gate's routed reviewer, the org coordinator, or a human at
a real login session — never on `--from`, which is a self-declaration.

Every rung needs **both** sides to resolve: a caller the box cannot identify never
matches an authorizer it could not resolve either. The human rung takes the same
corroboration a human-only *clear* needs (`task answer`), so a root shell with no
session of its own, a CI container, or any other unenumerated principal is refused
rather than admitted by default.

## 3. Whose bot rings the phone

The tier-2 re-nag rides **one** sender rather than one per filer. Which one was,
until now, the resolved org *coordinator* — and that same resolver also picks the
default assignee for an unassigned row, the default planner for goals and
objectives, the reviewer fallback for a filer with no `reports_to`, the default
loop owner, and the owner of the pinned needs-you banner. Moving the phone ping by
re-tagging the coordinator moved all six.

The notifier is now its own knob, tagged the same way (a marker *inside* the role
prose, so the org chart's display text survives):

```bash
sudo 5dive org set main --role='engineering + infra + the 5dive CLI — gate notifier'
```

With that marker, the gate ping and its re-nags come from `main`'s bot while
`olivia` stays coordinator — so the ping and the conversation about it land in one
chat, with the seat that has the context. With **no** marker anywhere, the notifier
resolves to the coordinator and nothing changes. Two holders is ambiguous and
resolves to the coordinator too: a guess about who pages a person is the wrong
place to be clever.
