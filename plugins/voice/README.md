# voice — the reference implementation of the 5dive plugin contract

`voice` is a **channel** plugin: it adds a way for you and your agent to talk to
each other. Install it the way you will install every other plugin:

```
5dive market --kind=plugin        # see what exists
5dive plugin add voice            # read who published it and what it is handed, then agree
5dive plugin list                 # voice 1.0.0  official  channel
```

## Why this plugin exists in this repo and not in 5dive-plugins

Because it is the plugin the CLI is graded against. It ships **bundled** — the
CLI registers `plugins/` as a marketplace named `5dive` on first use — so
`5dive plugin add voice@5dive` resolves with **no network at all**. That makes
the local-path marketplace source the primary path rather than an afterthought,
and it means the contract can be exercised end to end on a box with no internet
and no GitHub credential.

## What it declares, and why each line is load-bearing

```json
"fivedive": {
  "contract": "1",
  "capabilities": ["channel"],
  "verbs": [{"name": "voice", "summary": "talk to your agent by voice", "installs": "channel"}],
  "grants": ["audio-io", "telegram-token"],
  "trust": {"publisher": "5dive", "did": "did:key:5dive", "review": "official"}
}
```

- **`capabilities: ["channel"]`** is the whole point. Contract §2 says *an
  undeclared surface is inert*: the installer registers what this array names and
  nothing else. If voice later ships an MCP server without adding `"mcp"` here,
  the MCP server is not registered — and `plugin add` says so out loud rather
  than dropping it silently.
- **`grants`** is the consent list. It is not documentation: `plugin add` prints
  it back in plain English ("your microphone and speakers", "your Telegram bot
  token") and will not install until you agree. A plugin that asks for nothing
  gets nothing beyond its own directory.
- **`trust.review: "official"`** is what makes voice installable today. 5dive
  currently installs `official` plugins only — see below.
- **`version`** is not cosmetic. The install path is keyed on it
  (`…/cache/5dive/voice/1.0.0/`), so **a change that does not bump `version`
  cannot arrive**. Bump it in the same commit as the change, every time.

## What this plugin does NOT do yet, stated plainly

**There is no audio runtime here.** Installing `voice` today registers a channel
and hands over the grants it declares; it does not yet capture speech or speak
back. Tap-to-talk dictation is tracked separately (MOB-4).

That boundary is deliberate for this row rather than an oversight, and it is
written here because the alternative — a plugin that looks like it works —
is worse than one that says what it is. What voice proves right now is the
**contract**: manifest validation, capability declaration, the consent screen,
version-keyed install, upgrade-then-flip, rollback, and total uninstall. That
machinery is what the browser plugin and every third-party plugin will ride on,
and it is what is graded.

## Why you cannot install someone else's plugin yet

A plugin runs **as your agent**, under your agent's user, with your agent's
credentials. There is no sandbox between them — that is a structural fact about
how agents load plugins, not a gap in our implementation. Opening that door to
third parties needs a way to prove who wrote a plugin and to switch a bad one
off after it is already installed. That machinery is specified (contract §5.1)
and is not built, so `5dive plugin add` installs `official` plugins only and
refuses the rest. There is deliberately no flag to override it.

## The full contract

`community/wiki/the-5dive-plugin-contract-v1.md`.
