# The 5dive plugin standard (contract v1)

A 5dive plugin is a Claude Code / Codex plugin with a short 5dive section in its
manifest. That section is what 5dive calls "following the standard": it tells 5dive,
before any of your code runs, what the plugin adds and what it needs, so the person
installing it can see both and agree.

Any repository that follows it installs with one command:

```sh
sudo 5dive plugin add <owner>/<repo>             # one plugin in the repo
sudo 5dive plugin add <owner>/<repo>/<plugin>    # pick one from several
```

**Start from the template.** [5dive-ai/5dive-plugin-template](https://github.com/5dive-ai/5dive-plugin-template)
is the smallest plugin that installs: one verb, one skill and one setting, with a README
that walks through renaming it. Press **Use this template** on GitHub, or ask your agent to
build your plugin from it.

## Repository shape

```
.claude-plugin/marketplace.json      # lists the plugins in this repo
<plugin>/.claude-plugin/plugin.json  # the manifest (below)
<plugin>/bin/<verb>                  # only if the plugin adds a 5dive verb
```

`marketplace.json` names each plugin and where it lives:

```json
{ "name": "acme-tools", "owner": {"name": "Acme"},
  "plugins": [ {"name": "weather", "description": "…", "source": "./weather"} ] }
```

Put the plugin in its own directory, not at the repository root. `.5dive-plugin/` and
`.codex-plugin/` are accepted in place of `.claude-plugin/` for the manifest.

## The manifest

```json
{
  "name": "weather",
  "version": "1.0.0",
  "description": "one line",
  "author": {"name": "Acme"},
  "fivedive": {
    "contract": "1",
    "capabilities": ["verb"],
    "verbs": [{"name": "weather", "summary": "today's forecast"}],
    "grants": ["network"],
    "trust": {"publisher": "Acme"}
  }
}
```

- **`name`** must equal the plugin's directory name.
- **`version`** is required. The install path is keyed on it, so a change you publish
  without bumping `version` does not reach anyone who already has the plugin.
- **`fivedive.contract`** is `"1"`; any other value is refused. **A manifest with no
  `fivedive` block, or an empty one, is refused.** That is the standard. A plain Claude Code
  plugin has declared nothing for 5dive to show or register.
- **`fivedive.capabilities`** lists every surface the plugin adds: `channel`, `mcp`,
  `skill`, `verb`, `hook`. **An undeclared surface is inert.** If you ship an MCP
  server or skills without declaring them, 5dive does not register them, and says so
  at install.
- **`fivedive.verbs`**: with the `verb` capability, each name becomes a top-level
  `5dive <name>` command. 5dive runs `<plugin>/bin/<name>` with the user's arguments
  and nothing else. The manifest names the verb and never supplies a command line.
  A verb that is a builtin 5dive command, or one another installed plugin already
  claims, is refused at install. So is a verb with no executable `bin/<name>`.
- **`fivedive.grants`** lists the host resources the plugin needs:
  `telegram-token`, `audio-io`, `agent-credentials`, `fs-home`, `network`,
  `browser-profiles`. These appear in plain English on the consent screen. If you
  leave this out, the plugin gets nothing beyond its own directory.
- **`fivedive.setup`** (optional, `{"hint": "…", "command": "…"}`) is a one-time
  host step. 5dive prints it after install and never runs it by itself. The user
  runs `sudo 5dive plugin setup <plugin>`.

## Official and community

The tier is decided by **where the plugin comes from**, never by what its manifest
says:

| tier | when |
|---|---|
| `official` | the repository belongs to `github.com/5dive-ai` |
| `community` | any other owner, a fork of one of ours, or a local directory |

`fivedive.trust.review` in the manifest can **lower** a plugin's tier and never raise
it. A manifest that says `"official"` from anywhere else installs as `community`.

A community plugin installs after a consent screen. The screen shows the repository
and the commit, marks the manifest's publisher line as the plugin's own claim, lists
what the plugin is handed, and says:

> Not from 5dive. It runs with your agents' access; there is no sandbox.

`--yes` accepts that screen non-interactively. Without it, a session with no terminal
is refused. The dashboard's one-click install passes `--official-only` and takes only
official plugins; community plugins are installed from the command line.

## What 5dive cannot do for you yet

There is no signing and no remote revocation. If a community plugin turns out to be
bad, 5dive cannot switch it off on your server. The off switch is on the server:

```sh
sudo 5dive plugin disable <plugin>@<marketplace>   # stop it, keep the code
sudo 5dive plugin remove  <plugin>@<marketplace>   # every version, gone
```

Install community plugins from publishers you would trust with your agents'
credentials.

## Lifecycle

```sh
sudo 5dive plugin list
sudo 5dive plugin upgrade <plugin>@<marketplace>     # installs alongside, then flips
sudo 5dive plugin rollback <plugin>@<marketplace>    # flips back
sudo 5dive plugin enable|disable <plugin>@<marketplace>
sudo 5dive plugin remove <plugin>@<marketplace>
```
