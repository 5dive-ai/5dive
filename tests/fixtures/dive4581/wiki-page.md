---
title: A picker is not always a question — the usage-limit hold paged a human three times in one evening
date: 2026-09-16
row: DIVE-4581
author: agent-dev
tags: [supervisor, fleet-health, quota, false-positive, pane-classification]
links:
  - "[[bypass-mode-is-not-a-no-questions-mode-and-the-question-guard-lived-only-in-the-telegram-plugin]]"
  - "[[documenting-machinery-inside-its-own-data-store-manufactures-false-positives]]"
  - "[[rotation-not-quota-is-what-deafens-a-seat]]"
---

# A picker is not always a question

Three FLEET-HEALTH `blocked-on-prompt` pages reached lodar's phone on the evening of
2026-09-15 (quinn ~16:05Z, ops ~16:20Z, community ~01:00Z), all on the same exhausted
account, all for the same non-event. His read of it:

> false notification - the agent was sitting on 'You've hit your org's monthly spend limit
> … your weekly limit resets Sep 19, 12pm (UTC)' - so the blocked-on-prompt is wrong and
> shouldnt be alarmed

## The mechanism, and why it was invisible

When Claude Code is refused by a plan or org wall mid-turn it prints the refusal and
renders **its own** choice picker asking what to do about it. Three options — hold until
the reset, wait here and resume by itself at the printed time, upgrade the plan — under
the same footer the harness draws beneath `AskUserQuestion` and `ExitPlanMode`.

Every rule the supervisor had was satisfied by that pane and each one was answered
correctly:

1. the footer matched, so `_sup_prompt_match` said *picker*;
2. no option carried `(Recommended)`, so `_sup_prompt_recommended` refused to press a key
   — the DIVE-4293 safety rule, working as designed;
3. `blocked-on-prompt` therefore escalated with *"a person must choose"*.

Three correct rules composed into a false page, because **all three answer the question
"is a person needed to answer this picker?" and none of them asks "is this picker a
question at all?"** It is not. It is the capacity wall the same classifier already has a
class for (`quota-exhausted`), wearing a picker's footer, and it prints the time it ends.

## The generalisation

> **A pane's SHAPE is not its STATE.** Two states can render the same widget, and the
> remedy belongs to the state.

DIVE-4536 hit the mirror image and took the other exit: claude's tool-permission confirm
got a new *cause* under `blocked-on-prompt`, because there the state was genuinely the
same (a seat frozen on a keypress) and only the remedy differed. Here the STATE differs —
the seat is walled, not asked — so the fix is a re-CLASSIFICATION, not a cause. The test
for which exit you are taking: *would every surface that counts the existing class want to
count this too?* The board, `agent info`, the rotation branch and the DIVE-4052 quota
sentinel all want a walled seat counted as walled. None of them wants it counted as a
question.

## Why the page was the expensive part

`quota-exhausted` has had no human leg since DIVE-4052 — the audited event is the whole
policy — so the misreading was not merely a wrong word on a board. It routed a muted class
onto the one alerting class that still pages a phone, three times in one evening, for a
hold that was going to clear by itself. **The class a false positive lands IN is what makes
it expensive**; the same error inside `quota-exhausted` would have been a line in a digest.

## The rule the fix had to obey

The detector is a matcher over pane text, so it is subject to
[[documenting-machinery-inside-its-own-data-store-manufactures-false-positives]] — and
here the stakes are worse than DIVE-4536's, in both directions:

- a false positive **presses Enter** on an option a watchdog chose, and one of the options
  on this picker is *upgrade the plan*, i.e. a spend decision;
- a false positive also **silences** the page a genuine `AskUserQuestion` is owed.

So: the reading is attempted only on a pane the picker footer has already matched; it then
demands the wall's own two option lines, each a numbered option on its own line, in order,
immediately above that footer. And the keystroke is **cursor-relative** — the signed
distance from the cursor row to the auto-resume row — never a fixed `Down, Enter`, for the
reason DIVE-4536 refused to press a digit: a fixed count assumes an option ORDER, and an
order that ever changes turns the assumption into a purchase. No cursor on a numbered
option, or a distance beyond 4, and the class still flips (which is true, and quiet) while
no key is pressed at all.

The literals are deliberately broken up in this page — it is prose ABOUT the signature,
and prose that is a faithful transcript of a signature is indistinguishable from an
instance of it. `tests/supervisor_limit_picker_unit.sh` feeds this page and the verbatim
`task show DIVE-4581` output back through the matcher and asserts both stay silent.

## What to carry away

- Before adding a fourth reading of a pane, ask which STATE it evidences, not which widget
  it is. A widget-shaped classifier will keep composing correct rules into wrong pages.
- A watchdog that may press a key owes a cursor-relative plan, not a keystroke count.
- When a false positive is cheap in one class and expensive in another, the bug to fix is
  the routing, not the volume.
