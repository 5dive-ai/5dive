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
