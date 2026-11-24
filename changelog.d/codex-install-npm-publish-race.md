## Unreleased — fix(install): Codex and pi installs retry for a few minutes after a new release is published

For a few minutes after OpenAI publishes a new Codex release, npm can still be missing part of it, and hiring a Codex agent failed with "codex install failed". The install now waits a minute and tries again, then three minutes more for one last try, before it gives up. pi installs the same way.
