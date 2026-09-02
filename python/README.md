# 5dive

Python client for the [5dive](https://5dive.ai) CLI — read the task queue, agent
seats and org chart of a 5dive box from Python.

5dive runs a team of AI coding agents on your own machine. State lives on that
box and the CLI is the interface with a stable contract over it, so this package
is a thin, dependency-free wrapper over `5dive <verb> --json` rather than an HTTP
client.

## Install

```bash
pip install 5dive
```

The distribution is named `5dive`; the import name is `fivedive`, because a
Python identifier cannot begin with a digit.

## Use

```python
from fivedive import FiveDive

fd = FiveDive()

for t in fd.tasks("--status=todo"):
    print(t["ident"], t["assignee"], t["title"])

print(fd.task("DIVE-3903")["status"])

for a in fd.agents():
    print(a["name"], a["active"])
```

Anything the CLI can answer in JSON is reachable, whether or not this package
has a named helper for it:

```python
fd.raw("org", "tree")
fd.raw("task", "ls", "--assignee=main")
```

## Errors are raised, not returned

Every `--json` verb answers in one envelope:

```json
{"ok": true,  "data": {...}}
{"ok": false, "error": {"code": 4, "class": "not_found", "message": "no such task: NOPE-1"}}
```

An unchecked `ok` is the bug this package exists to prevent, so the false branch
raises instead of handing back a dict you have to remember to test:

```python
from fivedive import FiveDive, FiveDiveError, CliNotFound

try:
    fd.task("NOPE-1")
except FiveDiveError as e:
    print(e.err_class, e.code, e)   # not_found 4 no such task: NOPE-1
```

Branch on `err_class`, not on message text — the class is the stable contract.
`CliNotFound` is raised when the `5dive` binary is not on `PATH`.

## Requirements

Python 3.9+, no third-party dependencies, and a 5dive box with the CLI
installed. Get the CLI at [5dive.ai](https://5dive.ai) or
[github.com/5dive-ai/5dive](https://github.com/5dive-ai/5dive).

## Licence

MIT.
