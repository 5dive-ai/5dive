# Captured `git push` rejection stderr — the input to scripts/git-push-reject-class.sh

Real captures, not hand-written approximations of what git "probably" says. A
classifier graded against invented text grades the invention.

| file | provenance |
|---|---|
| `protected-gh006.txt` | verbatim from run 30231912328 (`5dive-ai/5dive`, 2026-07-27 02:19), the failure that opened DIVE-2143. Includes the trailing whitespace GitHub's hook emits. |
| `race-fetch-first.txt` | captured locally: push a behind branch without fetching. |
| `race-non-fast-forward.txt` | captured locally: fetch first, then push a behind branch — git changes its wording, which is why both variants are here. |
| `unknown-transport.txt` | a transport failure: neither a gated ref nor a race. Present to prove `unknown` is reachable rather than theoretical. |

Adding a class to the classifier means adding a capture here. "I think git says
something like this" is how the paraphrase this ticket is about got written.

## These captures are a premise about someone else's wording, and it can expire

GitHub owns the GH006 text; git owns the race text. **If GitHub rewords GH006, every
arm in `tests/version_assign_push_unit.sh` keeps passing against a capture that no
longer resembles a real rejection**, while the live path quietly falls through to
`unknown`. We cannot test against a real remote — exercising the protection branch
means re-breaking main's protection — so arm P records the substrings each verdict
actually rests on and reds if they stop being load-bearing:

| file | verdict | anchors the verdict rests on |
|---|---|---|
| `protected-gh006.txt` | `protection` | `GH006`, `protected branch`, `required status check` |
| `race-fetch-first.txt` | `race` | `fetch first`, `Updates were rejected because` |
| `race-non-fast-forward.txt` | `race` | `non-fast-forward`, `Updates were rejected because` |

Arm P asserts each anchor is still present **and** that stripping all of them drops the
verdict to `unknown` — so the list cannot rot into a fiction while some other substring
silently carries the match.

**If arm P goes red, RECAPTURE from a real rejection.** Editing the anchor list to match
the fixture, or the fixture to match the list, removes the alarm and keeps the defect.
