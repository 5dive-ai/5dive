# House rules for an agent team

Put this file in your repo root.
Agents that read AGENTS.md, like Codex and Cursor, pick it up from there.
Each rule came from something that went wrong on our team. The "Why" line is what we measured.

## 1. Cap the rounds between agents

Every message wakes the other agent, and it goes back over its work.
Never reply to "ok", "thanks" or "agreed".
After two rounds on one topic, write it into the task instead.

Why: all the message text our agents sent each other was 0.43% of our tokens.
The cost is in the rounds.

## 2. Keys, money, brand calls and anything that can't be undone wait for a person

The agent decides routine work.
On a routine question it can answer, it acts and reports after.
A question that does go to a person can be answered with one tap.

Why: when our agents asked with a recommendation, 81% of the answers were that recommendation.

## 3. Give the checker proof

Say what changed, what ran, how many tests passed, and at which commit.
A claim with no proof is a fail. The checker doesn't go and research it.

Why: a review cost us $4.60 on average at list prices.
The cost follows how many turns the checker spends digging. The size of the change didn't predict it.

## 4. Start each routine task in a fresh session

A long session sends every earlier task to the model again on every call.

Why: one reviewer went from 0% to 98% of its 5-hour limit in 83 minutes, on four reviews.
Most of what it sent was old tasks.

## 5. Put limits in the tool

An agent reads "60 words at most" as a target.
Make the send tool refuse a long message and say how to fix it.

Why: with the limit only in the prompt, 27 of 30 rewritten replies were still over 60 words.

## 6. An error message is one line: what failed and what to do next

Leave out why the check exists. The agent reading it only needs the next step.

Why: 126 of our 128 long refusal messages came down to one line with nothing lost.

## 7. Don't spend model calls saying "still working"

Let the chat app show a typing status instead.

Why: about 1 call in 10 of a working session went on "still here" messages.

## 8. Hand off and move on

Push, hand the work to the checker, start the next task.
Don't sit in a loop waiting for a slow test run. The checker reads the result anyway.

Why: one agent spent about 43 minutes showing nothing but its own wait loops.
A person watching it thought it was stuck.
