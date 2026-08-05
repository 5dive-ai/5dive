## Unreleased — fix(task): the preservation is now ANNOUNCED, and the seam is dated (DIVE-2483)

DIVE-2483's guard preserves the prior result correctly. It also shipped the silence: a bare open-row close
printed exactly `ok - <ident> done` and nothing else — **byte-identical to the output that accompanied the
DIVE-2712 wipe**. The bytes were rescued and the thing that made their loss undetectable was not, so an
operator could not tell the fixed behaviour from the defect at the terminal.

The gate answer named four conditions. The two expressible as **DB column state** shipped (bytes preserved,
empty result refused); the two about **what the operator sees** were dropped — and the 24-arm harness had
zero arms on either, because every arm ended in `SELECT result FROM tasks`. That is the transferable part
and it is olivia's: *a state-asserting harness has no natural home for an output condition, so those are
exactly the conditions a maker's own harness declines to grade.*

- **The append is announced**, naming the prior **byte count** — the cheapest thing that makes the claim
  falsifiable at a glance. A reader who expected 2.6KB and sees 40 knows to look; one who sees nothing
  never does. On `task done` **and** `task verify`.
- **The seam is dated.** There is no `result_by` column — that was this row's first blocker — so the seam
  marker *is* the provenance, and an undated one says two texts were joined and nothing about when.
- **Six new arms in a section with a different assertion shape**, asserting stdout rather than the column,
  including a negative (no announcement when there was nothing to preserve) and the `verify` path.

## Three harnesses on main were reddened by the original fix, and they were a shipping freeze

`task_answer_closed_row_unit`, `task_reject_actor_and_closed_unit`, `task_verify_self_close_visibility_unit`
— none of them about the result column. Their **fixture** built "a closed, graded task" by having the
verifier's close destroy the maker's delivery, then asserted the destruction:

```bash
as dev  cmd_task_done "$id" --result="maker delivery v1"
as main cmd_task_done "$id" --result="$ACK"      # <- destroyed v1, pre-fix
...
[[ "$(res_of "$a")" == "$ACK" ]]
```

The fixture performed the exact data loss this row exists to stop. Since `release-cut.yml` refuses to tag
on a red tip, that froze shipping for everything merged after the fix.

Each red was judged rather than reverted — appending is *correct* in all three scenarios — so the
assertions moved to `contains` and each arm's real work (rc, status, audit rows, refusal text) is untouched.
Written up in `community/wiki/a-fixture-can-encode-the-defect-another-row-was-filed-to-fix.md`.

**How it got through:** before merging I ran five neighbouring harnesses chosen by subject. Enumerating
readers by *content* — every harness calling `cmd_task_done`/`verify`/`reject`/`answer` — finds **54**. A
fixture is a reader.
