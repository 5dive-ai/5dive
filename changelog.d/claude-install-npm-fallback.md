## Unreleased — fix(install): Claude Code installs from npm when Anthropic's download server refuses the box

Some servers get a "403 refused" from Anthropic's Claude Code download server while npm still reaches the same build. Hiring a Claude agent on such a server failed every time, Retry after Retry. Installing Claude Code (a hire, `5dive agent install claude`, `5dive doctor --repair`) now falls back to the npm package when the native installer leaves no binary, and links it where agents start from. A working Claude Code is never replaced, and when both routes fail the install says so instead of reporting success.

The Antigravity install had the same hidden flaw: when its installer put `agy` somewhere else, the step meant to link it to where agents start from never ran. It does now.
