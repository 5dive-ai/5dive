# `5dive host` — remediation for a privileged seat, without a privileged grant

A devops agent needs to repoint a unit off a dev checkout, read a journal, and diff another user's
crontab. The obvious way to give it that is a sudoers tier scoped to `systemctl`, `daemon-reload`,
writes under `/etc/systemd/system` and `crontab`. **Do not.** Each of those four is an independent
one-line root escape, and three were already on the excluded list this repo has carried since
DIVE-1088:

| grant | escape |
|---|---|
| `journalctl` | pages through `less` by default → `!sh` |
| `systemctl status` | same pager → `!sh` |
| write `/etc/systemd/system` + `daemon-reload` + `start` | author any `ExecStart`, run it as root |
| `crontab -e` for another user | `EDITOR=/bin/sh`; if the target is `claude`, that seat is `NOPASSWD: ALL` |

A tier carrying those would print `host-admin` in `agent info` and mean `root-all`. `5dive host` is
the route that needs no tier at all.

## Why no sudoers change is required

An `admin` agent already holds, measured live:

```
agent-<name> ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *
```

The trailing `*` covers **subcommands that do not exist yet**. Probe it as the seat rather than
reading the drop-in — the gap between "what the file says" and "what the user can do" is where the
wrong answer lives:

```console
$ sudo -u agent-ops sudo -n /usr/local/bin/5dive host unit list
error: unknown command: host          # reached the CLI as root; the CLI refused, sudo did not
$ sudo -u agent-ops sudo -n systemctl daemon-reload
sudo: a password is required          # the raw binary is denied, and stays denied
```

So a new verb is remediation capability with **no new sudoers class, no new tier, no drop-in edit,
and nothing for the next `agent create` to silently revert.** `5dive agent _svc` is the precedent.

## The verbs

```
5dive host unit list [--pattern=<unit-glob>]
5dive host unit show --unit=<unit>
5dive host unit repoint --unit=<u>.service --workdir=<abs-path> [--no-restart]
5dive host unit revert  --unit=<u>.service [--no-restart]
5dive host journal --unit=<unit> [--lines=N] [--since=<N>m|<N>h|<N>d]
5dive host cron show|snapshot|diff --user=<user>
```

`unit list` and `unit show` need no root (systemd exposes them unprivileged); everything else does,
and an admin agent reaches it through the grant above.

Repointing a unit off a dev checkout, end to end:

```console
$ sudo 5dive host unit show --unit=5dive-frontend.service | grep -E '^(User|WorkingDirectory)='
User=claude
WorkingDirectory=/home/claude/projects/5dive/5dive-frontend

$ sudo 5dive host unit repoint --unit=5dive-frontend.service --workdir=/opt/5dive-frontend/current
OK — repointed '5dive-frontend.service' WorkingDirectory:
     /home/claude/projects/5dive/5dive-frontend -> /opt/5dive-frontend/current
     (drop-in /etc/systemd/system/5dive-frontend.service.d/50-5dive-workdir.conf; restarted=true)

$ sudo 5dive host unit revert --unit=5dive-frontend.service     # undo, same audited path
```

## The security model, stated as a finite set

Granting the whole CLI as root is a boundary **only** because of one standing invariant, written
above `write_admin_sudoers`: *no 5dive subcommand may exec agent-controlled input as root.* The day
one does, `cli-root` becomes `root-all` for every admin agent on the box at once — not just the
devops seat. So the review bar for this surface is that a reader can name, per verb, everything it
can exec:

| verb | what it can exec as root | what it can write |
|---|---|---|
| `unit list` | `systemctl list-units --type=service --all [<validated-glob>]` | — |
| `unit show` | `systemctl show <validated-unit> -p <fixed property list>` | — |
| `unit repoint` | `systemctl show`, `systemctl daemon-reload`, `systemctl restart <validated-unit>` | one file: `<unit>.d/50-5dive-workdir.conf`, one `[Service]` section, one `WorkingDirectory=` line |
| `unit revert` | same three | removes exactly that basename; `rmdir` (never `rm -r`) the `.d` |
| `journal` | `journalctl -u <validated-unit> -n <int> [--since "<int> <one of three words> ago"]` | — |
| `cron show/snapshot` | `crontab -l -u <validated-user>` | `$STATE_DIR/host-cron/<user>.cron` (0600) |
| `cron diff` | `diff -u` over two CLI-owned files | — |

No `eval`, no `sh -c`, no editor, no caller-supplied path, no caller-supplied unit-file content, and
no pager anywhere. `tests/host_verbs_unit.sh` asserts each of those as a grep over the source, so a
verb added later that breaks one is a red harness rather than a review someone had to remember.

### Three refusals worth knowing before you hit them

**`repoint` refuses a unit that runs as root.** A unit's `WorkingDirectory` *is* a code pointer
whenever its `ExecStart` carries a relative argument — `5dive-api.service` runs `node dist/index.js`,
resolved against the cwd. Pointing a root unit's cwd at a caller-chosen directory is "exec
agent-controlled input as root" with two extra steps. An empty `User=` is treated as root, because
that is systemd's default for a system unit and reading empty as "not root" would disable the guard
on nearly every unit on the box. A root unit's cwd is a human/root operation: file a gate.

**`crontab` is read-only.** `-l -u <user>` and nothing else. There is no `-e`, no `-r`, no write
path. `cron diff` compares the live crontab against a snapshot the CLI itself wrote under
`$STATE_DIR`, so "diff against this file" can never become "read any file as root". A write path
needs its own design pass and its own gate.

**`--since` does not accept `journalctl` time syntax.** `journalctl` understands `yesterday`,
`@<epoch>` and a good deal more; that is caller text landing in a root process's argv. The flag takes
`<N>m`, `<N>h` or `<N>d` and is mapped here to one of three literal phrases.

### What this does not close

`repoint` accepts any existing absolute directory for a **non-root** unit, including one the calling
seat can write. That is deliberate: the unit already runs as its own user, so the reachable outcome
is that user's own privilege, and an allowlist of blessed roots would refuse the real deploy targets
on this host (`/opt/5dive-api/releases/<sha>` is `claude`-owned and group-writable). If a unit runs
as a root-equivalent account, treat repointing it as the root case above.

Further reading:
`community/wiki/a-devops-tier-scoped-to-systemctl-journalctl-and-crontab-is-root-in-a-costume.md` ·
`community/wiki/the-top-isolation-tier-no-longer-reproduces-the-oldest-agents-grant.md`
