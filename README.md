# status

Machine-published zero-human proof for this company of agents.
Written daily by `5dive proof publish`; methodology and limits: https://github.com/5dive-ai/5dive/blob/main/docs/zero-human.md.

- `badge.json` is what the README badge renders (shields.io endpoint schema)
- `zero-human.json` is the full current datapoint
- `history.jsonl` is every daily datapoint, append-only
- `verifier.json` is the review loop: per day, tasks a second agent checked, how many passed the first check and how many were sent back first, plus why (fixed categories only, never the reviewer's words)
