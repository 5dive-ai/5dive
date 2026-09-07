# voice — the reference implementation of the 5dive plugin contract

Speak to your agent and hear it talk back. Install it the way you will install
every other plugin:

```
5dive market --kind=plugin        # see what exists
5dive plugin add voice            # read who published it and what it is handed, then agree
sudo 5dive-setup-voice            # the host-level engine — you run this, not us (see below)
5dive plugin list                 # voice 1.0.0  official  channel,verb
5dive voice                       # the verb the plugin registers
```

## What the voice runtime actually is

Not a stub. `5dive-setup-voice` installs, on your own box:

- **ffmpeg** (apt) for audio conversion;
- **faster-whisper** and **edge-tts** into `/home/claude/.venv`;
- **`whisper-service`**, a warm transcription HTTP service on **port 8765**, as a
  systemd unit — warm because loading the model per utterance is the difference
  between a conversation and a wait;
- **`5dive-transcribe`**, a single wrapper binary so an agent can pre-allow
  `Bash(5dive-transcribe:*)` instead of being prompted for `cp` and `curl` on
  every voice message;
- a Voice section appended to `projects/CLAUDE.md`, so the agent knows it can
  hear and speak.

Speech never leaves the box: whisper runs locally. It is also the same thing the
dashboard offers as the **Voice** connector — this plugin is the CLI path to it,
for the self-hosters who have no dashboard.

## Why `plugin add` does not run the setup for you

`fivedive.setup` in the manifest carries a `hint` and a `command`, and `plugin
add` **prints** them. It does not execute them, and it must never learn to.

Executing a string out of a manifest at install time is arbitrary code execution
chosen by the publisher — the exact door contract §5 keeps shut. It would in
fact be *worse* than that door, because it would run before you had seen what you
installed. So the plugin tells you the command and you run it. `voice` is
5dive's own plugin and gets no exception; an exception for the first plugin is
how the rule ends up meaning nothing for the tenth.

(That `setup` block is a **proposed addendum to contract §6**. It is not in v1 as
written — it is here because "installed — now what?" is the same dead end the
`plugin` verb exists to remove, one step later.)

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

- **`capabilities: ["channel", "verb"]`** is the whole point. Contract §2: *an
  undeclared surface is inert.* The installer registers what this array names and
  nothing else. If voice later ships an MCP server without adding `"mcp"` here,
  that server is not registered — and `plugin add` says so out loud rather than
  dropping it silently. `verb` arrived in DIVE-4035; before it, this manifest
  named a verb without declaring the capability, so `5dive voice` did not exist
  — correct under §2, and silent about it, which is the half the amendment fixed.
- **`bin/voice`** is where the verb resolves, and 5dive picked that path, not the
  manifest. The manifest names `voice`; it never says what to run. A command line
  out of `plugin.json` would be arbitrary code chosen by the publisher — the same
  door `setup` is printed rather than executed to keep shut. `5dive voice` runs
  `bin/voice` with your argv as a vector, and it can only ever be reached after
  every builtin 5dive command has already had its chance, so a plugin cannot take
  `5dive task` from you.
- **`grants`** is the consent list, not documentation. `plugin add` prints it
  back in plain English ("your microphone and speakers") and will not install
  until you agree. A plugin that asks for nothing gets nothing beyond its own
  directory.
- **`trust.review: "official"`** is what makes voice installable today.
- **`version`** is not cosmetic. The install path is keyed on it
  (`…/cache/5dive/voice/1.0.0/`), so **a change that does not bump `version`
  cannot arrive.** Bump it in the same commit as the change, every time.

## Why this plugin lives in the CLI repo and not in 5dive-plugins

Because it is the plugin the CLI is graded against. It ships **bundled** — the
CLI registers `plugins/` as a marketplace named `5dive` on first use — so
`5dive plugin add voice@5dive` resolves with **no network at all**. That makes
the local-path marketplace source the primary path rather than an afterthought,
and it lets the contract be exercised end to end on a box with no internet and
no GitHub credential.

## Why you cannot install someone else's plugin yet

A plugin runs **as your agent**, under your agent's user, with your agent's
credentials. There is no sandbox between them — a structural fact about how
agents load plugins, not a gap in our implementation. Opening that door to third
parties needs a way to prove who wrote a plugin and to switch a bad one off after
it is installed. That machinery is specified (contract §5.1) and is not built, so
`5dive plugin add` installs `official` plugins only and refuses the rest. There
is deliberately no flag to override it.

## The full contract

`community/wiki/the-5dive-plugin-contract-v1.md`.
