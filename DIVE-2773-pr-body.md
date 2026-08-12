# DIVE-2773 — a FIRST close must carry a reason, on BOTH verbs; a cancel no longer deletes a live human gate

The row was filed as *"`task done` refuses a blank result, `task cancel` accepts one"*.
**That asymmetry does not exist.** olivia caught it; confirmed at source and empirically.
`_task_guard_result_over_closed` returns early when the row carries no result yet — it is
destroy-protection, and with nothing recorded there are no bytes at risk:

```sh
if [[ -z "$_cl_prev" || "$_cl_prev" == "$result" ]]; then
  _TASK_GUARDED_RESULT="$result"; return 0
fi
```

So a **first** close with a blank reason was accepted by both verbs all along (demonstrated on
DIVE-2774). Shipping the filed fix — *"give cancel the check done already has"* — would have
missed every blank first close and left `done`, the commoner verb, just as open, while reading
in the diff like a fix.

## What this changes (`src/cmd_task.sh`)

1. **A first close requires a non-empty reason, on both verbs.** A new predicate keyed on
   *"this row is being closed and nothing has ever been written about why"* — not a port of
   DIVE-2483's check, which returns early on exactly this population. No flag bypasses it.
   The refusal names the **shape** of a good reason (DIVE-2472's text is quoted as the model),
   because a caller under load writes "n/a" unless told otherwise.
   Scoped so no false refusal is possible: a maker→verifier **delivery** routes and returns
   above the check (a bare `task done` handoff is untouched); an already-closed row keeps its
   idempotent bare re-close; a row that already carries text is the other guard's population.

2. **Both close verbs now refuse over a PENDING gate** — kept separate from the reason
   requirement, and firing *with* a good reason attached. This is the second, worse cost: the
   06:18:33 empty cancel of DIVE-2758 destroyed a live tier-2 human gate (buttons retired, row
   still reads `pending`). A cancel does not answer a question — it deletes it.
   DIVE-555's refusal text, which named `task cancel` as its sanctioned exit, is corrected: it
   was publishing the exact route DIVE-2758 took. Both refusals name
   `5dive task need <id> --withdraw` — a recorded withdrawal, never an answer put in anyone's
   mouth — because refusing both verbs with no exit leaves a gated row with no close verb at
   all and sends the next agent to invent one.

3. **`task reject` routes through `_task_guard_result_over_closed`** instead of its private copy
   of the superseded predicate. It asks the guard to APPEND, which is load-bearing: the guard's
   default on a closed row is to REFUSE, and that would have broken DIVE-2112's legitimate
   reopen (a recorded verifier withdrawing their own grade) — the very case the private branch
   existed to serve. The private copy keyed on `status=='done'`, but a row delivered to a
   verifier is `todo` **by the rail's own contract**, so on every ordinary bounce it replaced
   the maker's result silently, wearing a `DIVE-2067` marker that made it look handled.
   Repro run rather than reasoned (arm K), through the real rail.

## Tests

`tests/task_close_needs_a_reason_unit.sh` — 19 arms, **19 passed / 0 failed** at `034ba26`
(TIER: nightly, 36s on the control-plane VM). The 19/19 was first measured at `a5fa1db` and
re-run after the rebase onto current `origin/main`; `034ba26` is the sha this PR merges, so
that is the one quoted.
Arms **B** and **D** are the ones a port-of-the-existing-check leaves red while looking like a
fix. **E/E2/F/G** are the non-vacuity half. **H/H2/I** grade the gate refusal *and* the
reachability of the exit it names. **K/L** grade the reject path against a fixture asserted to
be the exact shape the old predicate skipped.

## Blast radius — measured, not assumed

Every harness touching a close was run on this branch; anything red was re-run on a pristine
`origin/main` worktree at the same sha with the same actor. **11 harnesses adapted** (bare
fixture closes given a reason; `gate_button_retire`'s `done` arm **inverted** rather than
deleted — over a live gate the cancel is refused and the button must SURVIVE).
Two harnesses are red on pristine main too and are **not** this branch:
`actor_claim_corroboration_unit.sh`, and `task_answer_closed_row_unit.sh`
("sudo: a password is required", a scoped-agent limit).

## Two consequences named rather than left to be found

- The DIVE-2410 retire-buttons-on-close block is now **unreachable by construction** (both close
  verbs refuse above it). Kept, commented as such, and argued in place: idempotent and free on
  the reachable path, and the backstop if either refusal is later scoped narrower.
- `cmd_objective.sh:888` auto-cancels objective-owned rows and increments `OBJ_APPLIED_CANCEL`
  **unconditionally**. It always supplies a reason so (1) never bites it, but a gated row's
  auto-cancel is now refused, swallowed by its `|| true`, and still counted as applied. The
  over-count is pre-existing (the counter never checked the rc); this adds one more trigger.
  Deliberately not ridden along.
- **Observable record change:** on a closed row, `reject` now writes the shared guard's
  `--- appended by a later close (DIVE-2464) ---` seam instead of its private
  `--- superseded result (DIVE-2067, preserved) ---` one. `task verify`'s closed path still
  writes the DIVE-2067 marker, so a grep for superseded records wants **both** strings.

## Independent re-measurement by the reviewer (main)

The blast-radius sweep above was measured on the PRE-rebase base and named as such by the
author rather than buried. Closed at source instead of banked: the nine other harnesses this
diff touches were re-run on the rebased tree at `034ba26` —
`heartbeat_reclaim_verifier_handoff` 6, `heartbeat_stall_sweep` 34, `task_cascade_unblock` 16,
`task_close_preserves_done_at` 16, `task_deliver_merge_gate` 43,
`task_done_ack_before_merge_gate` 11, `task_merge_gate_autodetect` 18,
`task_merge_gate_gh_resolve` 7, `task_merge_gate_multirepo` 39 — all green, **190 arms**, on
top of the author's four (**120**). **310 arms on the sha that merges**, no stale base.

Knowledge compiled: `community/wiki/a-guard-cited-by-name-covers-less-than-its-name-claims.md`
(indexed).
