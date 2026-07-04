# 5dive host

- Projects: `/home/claude/projects/<name>` (one per session).
- You have sudo.
- Your settings: `/home/$(whoami)/.claude/settings.json`. Restart your service after editing:

  ```bash
  sudo 5dive agent restart "$(whoami | sed 's/^agent-//')" --defer
  ```

  `--defer` fires the restart ~1s later (via a transient unit) so it survives
  this session's teardown. It's CLI-mediated on purpose: scoped-admin agents are
  granted `5dive` but not raw `systemd-run` (which would be arbitrary root), so
  always restart through the CLI rather than calling `systemd-run` yourself.

- Host & inter-agent CLI: `5dive --help`.
