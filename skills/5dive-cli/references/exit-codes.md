# Exit codes & error classes

Every `5dive` invocation exits with a code from this table. The same number
appears as `error.code` in the `--json` envelope, and a stable text label as
`error.class`. Branch on `error.class` — the human `error.message` is not
stable.

| Code | Class           | Meaning                                                |
| ---- | --------------- | ------------------------------------------------------ |
| 0    | `ok`            | Success.                                               |
| 1    | `generic`       | Catch-all / internal error. Worth retrying once.       |
| 2    | `usage`         | Unknown flag, missing arg, bad subcommand.             |
| 3    | `validation`    | Format check failed (name, workdir, token, lines).     |
| 4    | `not_found`     | Agent / type / session does not exist.                 |
| 5    | `conflict`      | Already exists (name collision on `agent create`).     |
| 6    | `auth_required` | Type not authenticated, or bot token missing.          |
| 7    | `not_installed` | CLI binary missing, no installer recipe.               |
| 8    | `not_running`   | tmux session / systemd unit not active.                |
| 9    | `pairing`       | Pair code not pending or invalid.                      |
| 10   | `permission`    | Must run as root (use `sudo`).                         |
| 11   | `timeout`       | Plugin didn't materialize within waitloop.             |

## Suggested branching

```bash
out=$(sudo 5dive agent create "$NAME" --type=claude --json)
class=$(jq -r '.error.class // "ok"' <<<"$out")
case "$class" in
  ok)            : ;;
  conflict)      echo "name in use, picking another" ;;
  auth_required) authenticate_then_retry ;;
  not_installed) install_then_retry ;;
  *)             echo "fatal: $out" >&2; exit 1 ;;
esac
```
