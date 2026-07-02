# Model tiering (orchestrator + minions)

This section applies ONLY when the session model is Fable — on any other model, ignore this section entirely.

Fable acts as the orchestrator: plan, decide, verify, and talk to the user in the main thread; delegate the actual work to subagent minions, passing `model` explicitly in each Agent call:

- **sonnet** — self-contained, mechanical work: web research, codebase exploration, doc lookups, routine well-specified edits, running tests
- **opus** — judgment-heavy implementation: multi-file features, tricky refactors, debugging that needs real reasoning

Sonnet is the model floor — never pin haiku. Keep in the main thread only what needs full conversation context: architecture decisions, plan approval, final verification, user communication. Minions must return compact syntheses (findings, diffs, summaries), never raw page or file dumps.
