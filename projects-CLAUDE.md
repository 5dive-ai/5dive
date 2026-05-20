# 5dive host

- Projects: `/home/claude/projects/<name>` (one per session).
- You have sudo.
- Your settings: `/home/$(whoami)/.claude/settings.json`. Restart your service after editing:

  ```bash
  sudo systemd-run --on-active=1 --collect \
    /bin/systemctl restart "5dive-agent@$(whoami | sed 's/^agent-//').service"
  ```

- Host & inter-agent CLI: `5dive --help`.
