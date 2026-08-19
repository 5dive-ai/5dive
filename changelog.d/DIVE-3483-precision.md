## Unreleased — fix(heartbeat): the stranded alarm must not assert more than its query measured (DIVE-3483 follow-up)

DIVE-3483's stranded-row alarm reports a symptom it measures and a *cause* it
mostly does not. Precision audit over every firing in the board's history
(`stranded_pinged_at`), 2026-08-19: 37 pings, 31 of them the one-time backfill
when the arm shipped, and **0 of the remaining 6 were the shape the arm exists to
detect**. Three separate over-claims, each fixed here, each graded by a new arm in
`heartbeat_stall_sweep_unit.sh` with a positive control beside it.

- **The seat's load counted the stranded row itself.** `sload` was an unfiltered
  `COUNT(*) … status='todo' AND assignee=<seat>`, and the stranded row is *itself*
  todo — so a seat holding nothing else reported "holds **1 other** todo row(s)",
  the alarm offering the row as evidence of its own lane congestion. Measured on
  DIVE-3375 (olivia, 2026-08-19 00:00:08Z): every other row she held was
  `blocked`, that count was the stranded row, and it was the *only* support the
  verdict had. Now `id<>` the row, and a genuine 0 renders as absent — `"$sload"`
  is a string, so the old `${sload:+…}` expanded on `"0"` too and could print
  "holds 0 other todo row(s)" as lane evidence.

- **"without being started" was false for half the population.** The query
  deliberately selects a row *started once and dropped* as well as one never
  touched, and dates it from the drop (arm E9, DIVE-3330's shape) — while the
  sentence asserted a single fixed "without being started". 4 of the 6
  post-backfill pings were on rows already started, one of them 5 days before its
  own never-started sentence. This is DIVE-2207's defect one field over, and it
  fails expensively: *untouched* is the claim that makes a reader reach for
  cancel. The sentence now branches on `first_started_at`.

- **The verdict is withheld when neither signal is present.** `sbusy` and `sload`
  are the whole evidentiary basis for "this is a LANE problem, not a priority
  problem, and re-pinging the same seat will not clear it". With both empty the
  clause was a guess — and it is the clause that prescribed reassign-or-cancel on
  DIVE-3375, a row that started 17 seconds later exactly as its body said it
  would. The symptom is still reported; the cause now says READ THE ROW.

The remedy list also gains its third branch. Both original branches are wrong, in
opposite directions, for a row waiting on a date or an event — reassign
re-strands it on the next seat, cancel destroys live work — and that shape is now
measured three times in two days (DIVE-3429 started 9s after its ping, DIVE-3375
17s, DIVE-2037 was event-blocked). Every one was a wait written only in the row
body, where no rail reads it. The alarm now names `5dive task park --wake=`, which
sets `parked_at` and is already excluded by this same query (arm E8).

Selection is unchanged: no row that used to be surfaced is now silent, and none
that used to be silent is now surfaced. This is entirely what the alarm *says*
about the rows it picks.
